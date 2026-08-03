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
                return "Phona needs Microphone access in System Settings, Privacy & Security."
            case .engine(let detail):
                return detail
            }
        }
    }

    /// The waveform meter, written by the tap and read by the HUD.
    ///
    /// Both live behind `meterLock` because the tap callback runs on an audio thread while the
    /// HUD reads them from a timer on the main thread. Unsynchronised they are a data race, and
    /// a torn read would show the HUD a level or a readiness flag that was never set.
    ///
    /// A separate lock from `lock`, which guards the file. Sharing one would make the HUD's
    /// thirty-times-a-second read wait behind a disk write for no reason.
    private let meterLock = NSLock()
    private var meterLevel: Double = 0
    private var meterHasAudio = false

    /// 0...1 loudness for the waveform, updated on every buffer.
    var level: Double {
        meterLock.lock()
        defer { meterLock.unlock() }
        return meterLevel
    }

    /// True once a real buffer has arrived, so the HUD knows whether a flat waveform means
    /// silence or means the device has not finished opening yet. Those look identical on
    /// screen, and on an idle device the second one lasts over half a second.
    var hasAudio: Bool {
        meterLock.lock()
        defer { meterLock.unlock() }
        return meterHasAudio
    }

    private func setMeter(level: Double? = nil, hasAudio: Bool? = nil) {
        meterLock.lock()
        if let level { meterLevel = level }
        if let hasAudio { meterHasAudio = hasAudio }
        meterLock.unlock()
    }

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

    /// Open the input and begin writing 16-bit PCM wav, which is what the Whisper path
    /// on the daemon side expects.
    func start() throws {
        guard !engine.isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Failure.noPermission
        }
        setMeter(level: 0, hasAudio: false)

        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0 else {
            throw Failure.engine("the input device reported no sample rate")
        }

        let url = Paths.base.appendingPathComponent("take-\(UUID().uuidString).wav")
        outputURL = url

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

        /// Smaller than the 2048 it used to be, because the first buffer is what the speaker is
        /// waiting for. At 48 kHz, 2048 frames is 43 ms of audio before anything is handed over,
        /// against 21 ms at 1024. The engine treats the size as a hint and may decline it. When
        /// it does honour it the callback runs twice as often, which is more CPU on an audio
        /// thread, and that is the price of halving the wait for the first buffer.
        input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in
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

        setMeter(level: 0, hasAudio: false)
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
        setMeter(level: 0, hasAudio: false)
        startedAt = nil
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
    }

    /// Open and immediately close the device so the first real dictation is not delayed.
    ///
    /// Both halves run on the caller's queue, which is the same serial queue the real start and
    /// stop use. Hopping to the main thread for the close would let a warm-up cancel land in the
    /// middle of a real open.
    func warm() {
        try? start()
        Thread.sleep(forTimeInterval: 0.4)
        cancel()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        setMeter(hasAudio: true)
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
        guard rms > 0 else { setMeter(level: 0); return }

        let db = 20 * log10(Double(rms))
        let floorDb = -52.0, ceilDb = -12.0
        setMeter(level: min(1, max(0, (db - floorDb) / (ceilDb - floorDb))))
    }
}
