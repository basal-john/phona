import Foundation

/// Talks to the Python vfix daemon over its unix socket.
///
/// The daemon owns the warm Whisper and grammar models. Keeping it means the pipeline
/// that was measured and tuned stays exactly as it is, and this app only replaces the
/// interface around it.
enum DaemonClient {
    struct Result {
        let state: String
        let raw: String
        let text: String
        let sttSeconds: Double
        let llmSeconds: Double
    }

    enum Failure: LocalizedError {
        case notRunning
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return "The vfix daemon is not running."
            case .transport(let detail):
                return detail
            }
        }
    }

    static let socketPath = Paths.base.appendingPathComponent("vfixd.sock").path

    /// Send one JSON line and read one JSON line back.
    static func request(_ payload: [String: Any], timeout: TimeInterval = 900) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.transport("could not create socket") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Failure.transport("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.notRunning }

        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        try line.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.send(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent, 0)
                if n <= 0 { throw Failure.transport("send failed") }
                sent += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
            if response.last == 0x0A { break }
        }
        guard !response.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw Failure.transport("no reply from the daemon")
        }
        return obj
    }

    static func isAlive() -> Bool {
        guard let reply = try? request(["cmd": "PING"], timeout: 5) else { return false }
        return (reply["state"] as? String) == "ready"
    }

    /// Ask the daemon to transcribe and correct a recording.
    static func process(url: URL, seconds: Double, mode: String?) throws -> Result {
        var payload: [String: Any] = ["cmd": "PROCESS", "path": url.path, "seconds": seconds]
        if let mode { payload["mode"] = mode }
        let reply = try request(payload)
        if let error = reply["error"] as? String { throw Failure.transport(error) }
        return Result(
            state: reply["state"] as? String ?? "error",
            raw: reply["raw"] as? String ?? "",
            text: reply["text"] as? String ?? "",
            sttSeconds: reply["stt_secs"] as? Double ?? 0,
            llmSeconds: reply["llm_secs"] as? Double ?? 0
        )
    }

    static func fix(text: String, mode: String?) throws -> Result {
        var payload: [String: Any] = ["cmd": "FIX", "text": text]
        if let mode { payload["mode"] = mode }
        let reply = try request(payload)
        return Result(
            state: reply["state"] as? String ?? "error",
            raw: reply["raw"] as? String ?? "",
            text: reply["text"] as? String ?? "",
            sttSeconds: 0,
            llmSeconds: reply["llm_secs"] as? Double ?? 0
        )
    }

    /// Launch the daemon and wait for it to warm up. First run loads two models.
    @discardableResult
    static func startAndWait(timeout: TimeInterval = 240) -> Bool {
        if isAlive() { return true }
        let task = Process()
        task.executableURL = Paths.python
        task.arguments = [Paths.daemon.path]
        try? task.run()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAlive() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }
}
