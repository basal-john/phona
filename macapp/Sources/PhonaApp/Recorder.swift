import AVFoundation
import Foundation
import PhonaCore

/// Captures the microphone straight into a 16 kHz mono wav and publishes a live level.
///
/// This replaces shelling out to ffmpeg. AVAudioEngine hands us buffers as they arrive,
/// so the level meter is the actual signal rather than a re-read of a file being written,
/// and stopping is immediate instead of a signal plus a wait.
///
/// Every take gets its own `AVAudioEngine`. An earlier version kept one for the life of the
/// app and called `reset()` before each take on the belief that this refreshed the graph after
/// an input device change. It does not. `AVAudioEngine.h` says `reset` "will reset all of the
/// nodes in the engine. This is useful, for example, for silencing reverb and delay tails",
/// and that is all it does: it removes no taps and re-reads no hardware format. So a take that
/// followed a route change installed a second tap on a bus that still had the first, or
/// installed one whose format disagreed with the hardware, and `installTapOnBus` answers both
/// by throwing an Objective-C exception that Swift cannot catch and the process aborts on.
/// A new engine has no taps and materialises an input node that asks the hardware fresh, which
/// is the only thing that actually makes both true again.
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
    /// Whether any buffer arrived during this take.
    ///
    /// Separate from `meterHasAudio`, which `stop` clears so the next dictation starts dim.
    /// This one survives the stop, because the interesting question is asked afterwards:
    /// a take that captured nothing at all means the capture layer is dead, not that the
    /// speaker was quiet, and those need different things said to the user.
    private var receivedAnyAudio = false

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
        if let hasAudio {
            meterHasAudio = hasAudio
            if hasAudio { receivedAnyAudio = true }
        }
        meterLock.unlock()
    }

    /// True when at least one buffer arrived during the take that just ended.
    var capturedAnyAudio: Bool {
        meterLock.lock()
        defer { meterLock.unlock() }
        return receivedAnyAudio
    }

    /// Guards the engine, the tapped node and the take's identity.
    ///
    /// `start`, `stop` and `cancel` are already serialised by the caller's audio queue. This
    /// exists for the one thing that is not on that queue: the configuration-change
    /// notification, which CoreAudio posts on a thread of its own choosing and which tears the
    /// same state down.
    private let engineLock = NSLock()
    private var engine: AVAudioEngine?
    private var tapped: AVAudioInputNode?

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var startedAt: Date?
    /// Guards the file, which the tap callback writes to from an audio thread.
    private let lock = NSLock()
    private var outputURL: URL?
    /// Set when a route change ended the take early, so the partial wav is still delivered
    /// rather than reported as a microphone that never opened.
    private var interrupted = false

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// True while a take is open.
    ///
    /// Deliberately not `engine.isRunning`. The engine stops itself on a route change, and a
    /// take whose engine has died is still a take with a wav on disk that has to be closed and
    /// handed back. Asking the engine was what let the old `stop` return early and leave the
    /// tap installed for the next `start` to collide with.
    var isRecording: Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        return outputURL != nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

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

    /// The input device changed under a live take.
    ///
    /// `AVAudioEngine.h`: "When the engine's I/O unit observes a change to the audio input or
    /// output hardware's channel count or sample rate, the engine stops itself and issues this
    /// notification." So there is nothing left to salvage on the old device. Closing the take
    /// here keeps what was said up to the switch, which is most of a sentence, and leaves no
    /// tap behind for the next take to collide with. Doing nothing was the old behaviour, and
    /// that is what produced the crash one dictation later.
    ///
    /// The teardown is handed to another queue rather than run here, because the same header
    /// warns that "the engine must not be deallocated from within the client's notification
    /// handler because the callback happens on an internal dispatch queue and can deadlock
    /// while trying to synchronously teardown the engine". Dropping the last reference inline
    /// would trade the crash for a hang, which is the worse of the two.
    @objc private func configurationChanged(_ note: Notification) {
        engineLock.lock()
        /// The notification must be for the engine this recorder is currently holding.
        /// `removeObserver` stops future deliveries but does nothing about one already in
        /// flight, and this handler blocks on `engineLock` while `stop` and `start` run. A
        /// notification for the engine that just died could therefore wake up holding the
        /// lock after its replacement was published, and tear down a take that had only just
        /// begun. Identity is checked here, inside the lock, because that is the only place
        /// the answer cannot change underneath the check.
        guard let current = engine, (note.object as AnyObject?) === current else {
            engineLock.unlock()
            return
        }
        let live = outputURL != nil
        if live { interrupted = true }
        let doomed: AVAudioEngine? = current
        let node = tapped
        engine = nil
        tapped = nil
        if let doomed {
            NotificationCenter.default.removeObserver(
                self, name: .AVAudioEngineConfigurationChange, object: doomed)
        }
        engineLock.unlock()

        guard doomed != nil || node != nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            node?.removeTap(onBus: 0)
            if let doomed, doomed.isRunning { doomed.stop() }
            self?.closeFile()
            _ = doomed
        }
        if live { Paths.log("the input device changed mid-dictation, keeping what was captured") }
    }

    /// Drop the tap and the engine. Safe to call when there is neither.
    ///
    /// The tap comes off the node this recorder installed it on rather than off
    /// `engine.inputNode`, and it comes off whether or not the engine is still running. Both
    /// were the bug: a stopped engine skipped the removal, and the tap then survived into a
    /// take that installed a second one on the same bus.
    private func releaseEngineLocked() {
        if let tapped {
            tapped.removeTap(onBus: 0)
            self.tapped = nil
        }
        if let engine {
            NotificationCenter.default.removeObserver(
                self, name: .AVAudioEngineConfigurationChange, object: engine)
            if engine.isRunning { engine.stop() }
            self.engine = nil
        }
    }

    private func closeFile() {
        lock.lock()
        file = nil          // closing the AVAudioFile flushes the header
        lock.unlock()
    }

    /// Open the input and begin writing 16-bit PCM wav, which is what the Whisper path
    /// on the daemon side expects.
    func start() throws {
        guard !isRecording else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Failure.noPermission
        }
        setMeter(level: 0, hasAudio: false)
        meterLock.lock()
        receivedAnyAudio = false
        meterLock.unlock()

        engineLock.lock()
        releaseEngineLocked()
        interrupted = false
        engineLock.unlock()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw Failure.engine("the input device reported no usable format")
        }

        /// Installed immediately after the format is read, with nothing in between.
        /// `hardware` is a snapshot, and `installTapOnBus` aborts the process when the format
        /// it is handed disagrees with the node. Opening the wav and building the converter
        /// first left a window where a route change could invalidate the snapshot before it
        /// was used, which is a smaller version of the bug this whole file exists to fix. The
        /// tap block cannot run before `engine.start()`, so the file and the converter it
        /// reads are free to be built afterwards.
        ///
        /// The frame count follows the device's rate to stay inside the window
        /// `installTapOnBus` documents, because the same 1024 frames is 21 ms on the USB
        /// microphone and 43 ms on the AirPods. `CaptureBuffer` holds that arithmetic.
        let frames = AVAudioFrameCount(CaptureBuffer.frames(forSampleRate: hardware.sampleRate))
        input.installTap(onBus: 0, bufferSize: frames, format: hardware) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        let url = Paths.base.appendingPathComponent("take-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            lock.lock()
            self.file = file
            lock.unlock()
            self.converter = AVAudioConverter(from: hardware, to: Self.targetFormat)

            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            closeFile()
            try? FileManager.default.removeItem(at: url)
            self.converter = nil
            throw Failure.engine(error.localizedDescription)
        }

        engineLock.lock()
        self.engine = engine
        self.tapped = input
        outputURL = url
        /// Scoped to this engine, the way the header's own example registers it. A process-wide
        /// registration would let a notification for the engine that just died tear down the
        /// one that replaced it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
        engineLock.unlock()
        startedAt = Date()
    }

    /// Stop and hand back the finished file, or nil when nothing usable was captured.
    ///
    /// Keyed on whether a take is open rather than on whether the engine is still running, so
    /// a take a route change cut short still comes back with its audio instead of being
    /// reported as a device that never opened.
    func stop() -> (url: URL, seconds: Double)? {
        engineLock.lock()
        releaseEngineLocked()
        let url = outputURL
        outputURL = nil
        let wasInterrupted = interrupted
        interrupted = false
        engineLock.unlock()

        closeFile()
        converter = nil
        setMeter(level: 0, hasAudio: false)
        let seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        guard let url else { return nil }
        if wasInterrupted { Paths.log("delivering the part of the take captured before the switch") }
        return (url, seconds)
    }

    func cancel() {
        engineLock.lock()
        releaseEngineLocked()
        let url = outputURL
        outputURL = nil
        interrupted = false
        engineLock.unlock()

        closeFile()
        converter = nil
        setMeter(level: 0, hasAudio: false)
        startedAt = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Open and immediately close the device so the first real dictation is not delayed.
    ///
    /// Both halves run on the caller's queue, which is the same serial queue the real start and
    /// stop use. Hopping to the main thread for the close would let a warm-up cancel land in the
    /// middle of a real open.
    func warm() {
        /// Only ever cancel what this call opened. `start` returns without error when a take is
        /// already open, so warming during a live dictation used to stop it, delete the wav in
        /// progress and lose what the speaker had already said. The launch warm-up fires 1.5 s
        /// in, which is comfortably inside the window where someone can already be holding the
        /// key.
        guard !isRecording else { return }
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
