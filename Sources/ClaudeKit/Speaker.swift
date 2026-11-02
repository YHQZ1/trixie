import Foundation

/// Speaks sentences one after another. It uses the Kokoro neural voice when that
/// is set up (see `attach`), and otherwise falls back to the macOS `say` command.
/// Sentences queue up, so Claude can start talking while it is still writing.
public actor Speaker {
    public var voice: String?
    public var rate: Int
    public var muted: Bool
    public private(set) var engineName = "macOS voice"
    public private(set) var usesCloud = false

    private var kokoro: KokoroHelper?
    private var speakingHandler: (@Sendable (Bool) -> Void)?
    private var kokoroBusy = false

    private var queue: [String] = []
    private var current: Process?
    private var draining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(voice: String? = nil, rate: Int = 190, muted: Bool = false) {
        self.voice = voice; self.rate = rate; self.muted = muted
    }

    /// Get told when speech starts and stops (the pet uses this to move its mouth).
    public func setSpeakingHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        speakingHandler = handler
    }

    private func notifySpeaking(_ on: Bool) { speakingHandler?(on) }

    /// Switch to the Kokoro neural voice.
    public func attach(_ helper: KokoroHelper) {
        kokoro = helper
        usesCloud = helper.cloudVoiceName != nil
        engineName = helper.cloudVoiceName.map { "ElevenLabs (\($0)), with Kokoro as backup" }
            ?? "Kokoro (\(helper.settings.voice))"
        helper.onSpeaking = { [weak self] on in
            guard let self else { return }
            Task { await self.notifySpeaking(on) }
        }
        helper.onIdle = { [weak self] in
            guard let self else { return }
            Task { await self.kokoroBecameIdle() }
        }
    }

    public func say(_ text: String) {
        guard !muted, !text.isEmpty else { return }
        if let kokoro {
            kokoroBusy = true
            kokoro.say(text)
            return
        }
        queue.append(text)
        if !draining { draining = true; Task { await self.drain() } }
    }

    /// Wait until everything queued has been spoken.
    public func waitUntilDone() async {
        if let _ = kokoro {
            if !kokoroBusy { return }
        } else if !draining && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Stop talking immediately and forget what was queued.
    public func stop() {
        queue.removeAll()
        current?.terminate()
        if let kokoro {
            kokoro.stop()
            kokoroBusy = false
            wakeWaiters()
        }
    }

    /// Call when the app quits.
    public func shutdown() {
        stop()
        kokoro?.shutdown()
    }

    // MARK: - Kokoro

    private func kokoroBecameIdle() {
        kokoroBusy = false
        wakeWaiters()
    }

    // MARK: - macOS voice (fallback)

    private func drain() async {
        notifySpeaking(true)
        while !queue.isEmpty {
            let text = queue.removeFirst()
            await speakOne(text)
        }
        draining = false
        notifySpeaking(false)
        wakeWaiters()
    }

    private func wakeWaiters() {
        let waiters = idleWaiters; idleWaiters = []
        for w in waiters { w.resume() }
    }

    private func speakOne(_ text: String) async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args = ["-r", String(rate)]
        if let v = voice { args += ["-v", v] }
        p.arguments = args
        let input = Pipe()
        p.standardInput = input
        current = p
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in done.resume() }
            do {
                try p.run()
                input.fileHandleForWriting.write(Data(text.utf8))
                try? input.fileHandleForWriting.close()
            } catch { done.resume() }
        }
        current = nil
    }
}
