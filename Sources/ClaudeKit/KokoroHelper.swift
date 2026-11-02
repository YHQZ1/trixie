import Foundation

public struct KokoroSettings {
    /// The folder with server.py, the Python environment and the model files.
    public var directory: URL
    public var voice: String
    public var speed: Double
    public var language: String

    public init(directory: URL, voice: String = "af_heart", speed: Double = 1.0, language: String = "en-us") {
        self.directory = directory; self.voice = voice; self.speed = speed; self.language = language
    }

    /// Use Kokoro if its files are in place; otherwise return nil and the caller falls back to the macOS voice.
    public static func detect(_ env: [String: String]) -> KokoroSettings? {
        if env["CLAUDE_ENGINE"] == "say" { return nil }
        let fm = FileManager.default
        // 1) CLAUDE_TTS_DIR, 2) the tts folder next to the app (build/Trixie.app -> ../../tts), 3) the current folder.
        let candidates: [URL] = [
            env["CLAUDE_TTS_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tts"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("tts"),
        ].compactMap { $0 }
        let dir = candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("server.py").path) }
            ?? candidates[0]
        guard fm.isExecutableFile(atPath: dir.appendingPathComponent(".venv/bin/python").path),
              fm.fileExists(atPath: dir.appendingPathComponent("server.py").path),
              fm.fileExists(atPath: dir.appendingPathComponent("kokoro-v1.0.onnx").path) else { return nil }
        let voice = env["CLAUDE_KOKORO_VOICE"] ?? "af_heart"
        return KokoroSettings(
            directory: dir,
            voice: voice,
            speed: Double(env["CLAUDE_KOKORO_SPEED"] ?? "") ?? 1.06,   // a touch quicker sounds more like chat
            language: voice.hasPrefix("b") ? "en-gb" : "en-us"
        )
    }
}

/// Runs the Python voice helper (tts/server.py) in the background and talks to it
/// with one JSON message per line. The model loads once, so replies start quickly.
public final class KokoroHelper: @unchecked Sendable {
    public let settings: KokoroSettings
    public var onIdle: (() -> Void)?
    public var onSpeaking: ((Bool) -> Void)?

    /// "Jessica" when the ElevenLabs voice is set up (a voice in tts/voice.json and a key in the
    /// Keychain); otherwise nil and the local Kokoro voice is used.
    public let cloudVoiceName: String?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writeLock = NSLock()

    public init?(settings: KokoroSettings) {
        self.settings = settings
        self.cloudVoiceName = Self.detectCloud(in: settings.directory)
        process.executableURL = settings.directory.appendingPathComponent(".venv/bin/python")
        process.arguments = [settings.directory.appendingPathComponent("server.py").path]
        process.currentDirectoryURL = settings.directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Read the helper's events with a plain callback (not an async stream), so this
        // reader stays completely separate from the one that reads Claude's answer.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consume(chunk)
        }
    }

    private var pending = Data()

    private func consume(_ chunk: Data) {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch obj["event"] as? String {
            case "cloud_down":
                let why = obj["reason"] as? String ?? "unknown"
                print("\u{1B}[2m(cloud voice unavailable: \(why), using the local voice for now)\u{1B}[0m")
            case "speaking": onSpeaking?(true)
            case "idle": onSpeaking?(false); onIdle?()
            default: break
            }
        }
    }

    private static func detectCloud(in dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("voice.json")),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = cfg["voice_id"] as? String, !id.isEmpty else { return nil }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        check.arguments = ["find-generic-password", "-s", "elevenlabs-api-key"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return nil }
        check.waitUntilExit()
        return check.terminationStatus == 0 ? (cfg["voice_name"] as? String ?? "cloud voice") : nil
    }

    public func say(_ text: String) {
        send(["cmd": "say", "text": text, "voice": settings.voice,
              "speed": settings.speed, "lang": settings.language])
    }

    public func stop() { send(["cmd": "stop"]) }

    public func shutdown() {
        send(["cmd": "quit"])
        process.terminate()
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        writeLock.lock(); defer { writeLock.unlock() }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }
}
