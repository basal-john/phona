import AVFoundation
import Foundation

/// Captures the microphone straight into a 16 kHz mono wav and publishes a live level.
///
/// This replaces shelling out to ffmpeg. AVAudioEngine hands us buffers as they arrive,
/// so the level meter is the actual signal rather than a re-read of a file being written,
/// and stopping is immediate instead of a signal plus a wait.
final class Recorder {
    enum Failure: LocalizedError {
        case noPermission
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "vfix needs Microphone access in System Settings, Privacy & Security."
            case .engine(let detail):
                return detail
            }
        }
    }

    /// 0...1 loudness for the waveform, updated on every buffer.
    private(set) var level: Double = 0

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var startedAt: Date?
    private let lock = NSLock()
    private var outputURL: URL?

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    var isRecording: Bool { engine.isRunning }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    func start() throws {
        guard !engine.isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Failure.noPermission
        }

        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0 else {
            throw Failure.engine("the input device reported no sample rate")
        }

        let url = Paths.base.appendingPathComponent("take-\(UUID().uuidString).wav")
        outputURL = url

        // Write real 16-bit PCM wav, which is what the daemon's Whisper path expects.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
        converter = AVAudioConverter(from: hardware, to: Self.targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: hardware) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engine(error.localizedDescription)
        }
        startedAt = Date()
    }

    /// Stop and hand back the finished file, or nil when nothing usable was captured.
    func stop() -> (url: URL, seconds: Double)? {
        guard engine.isRunning else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        file = nil          // closing the AVAudioFile flushes the header
        lock.unlock()

        level = 0
        let seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        guard let url = outputURL else { return nil }
        outputURL = nil
        return (url, seconds)
    }

    func cancel() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock()
        file = nil
        lock.unlock()
        level = 0
        startedAt = nil
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
    }

    /// Open and immediately close the device so the first real dictation is not delayed.
    func warm() {
        try? start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.cancel()
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        updateLevel(buffer)

        guard let converter, let target = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: AVAudioFrameCount(
                Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 1024
        ) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, target.frameLength > 0 else { return }

        lock.lock()
        try? file?.write(from: target)
        lock.unlock()
    }

    /// Map RMS onto the same dB window the Lua HUD used, so the waveform feels identical.
    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for i in stride(from: 0, to: count, by: 4) {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(max(1, count / 4)))
        guard rms > 0 else { level = 0; return }

        let db = 20 * log10(Double(rms))
        let floorDb = -52.0, ceilDb = -12.0
        level = min(1, max(0, (db - floorDb) / (ceilDb - floorDb)))
    }
}
