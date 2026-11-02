import AppKit
import ClaudeKit

// Trixie, the pet. Hold the hotkey, or just say "hey Trixie", and a little creature appears,
// listens, thinks, talks back and then goes to sleep. Pressing the hotkey interrupts her.
//
// Settings (environment variables):
//   CLAUDE_HOTKEY=option+space   hold-to-talk shortcut
//   CLAUDE_LANG=en-IN            speech recognition language (en-US, en-GB, ...)
//   CLAUDE_KOKORO_VOICE=af_heart / CLAUDE_KOKORO_SPEED=1.0 / CLAUDE_ENGINE=say
//   CLAUDE_MUTE / CLAUDE_CWD     as in trixie-talk (CLAUDE_CWD defaults to your home folder)
//   CLAUDE_BLOCK_EXTRA=~/a/**,~/b/**   more places she can't read;  CLAUDE_BLOCK_NONE=1 removes the default list
//
// `trixie --preview out.png` draws every mood to a picture and exits.

let env = ProcessInfo.processInfo.environment
setvbuf(stdout, nil, _IOLBF, 0)   // show each line right away, even when output is redirected

if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { PetPreview.render(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

func dim(_ s: String) -> String { "\u{1B}[2m\(s)\u{1B}[0m" }

@MainActor
final class Controller {
    let session: ClaudeSession
    let speaker: Speaker
    let listener: VoiceListener
    let pet: PetWindowController
    let wake: WakeListener?
    var wakeEnabled = UserDefaults.standard.object(forKey: "wakeEnabled") as? Bool ?? true
    var busy = false                  // a conversation turn is in progress, so don't listen for the wake phrase
    var followUpPending = false       // after her answer, keep listening for a reply without her name
    let followUpSeconds = Double(env["CLAUDE_FOLLOWUP_SECONDS"] ?? "") ?? 8   // 0 turns follow-ups off
    var wakeResume: Task<Void, Never>?
    var turn: Task<Void, Never>?
    var settle: Task<Void, Never>?
    var recording = false
    var turnRunning = false
    var speaking = false
    var lastActivity = Date()
    var timer: Timer?

    init(session: ClaudeSession, speaker: Speaker, listener: VoiceListener, pet: PetWindowController, wake: WakeListener?) {
        self.session = session; self.speaker = speaker; self.listener = listener; self.pet = pet; self.wake = wake
        listener.onPartial = { text in
            print("\r\u{1B}[2K" + dim("… \(text)"), terminator: ""); fflush(stdout)
        }
        wake?.onWake = { [weak self] followUp in
            guard let self else { return }
            self.busy = true
            self.settle?.cancel()
            self.pet.show(); self.mood(.listening); self.touch()
            if !followUp { NSSound(named: "Tink")?.play() }
            print(dim(followUp ? "listening…" : "heard “hey Trixie”, listening…"))
        }
        wake?.onFollowUpOpen = { [weak self] in
            guard let self else { return }
            self.settle?.cancel()
            self.mood(.listening); self.touch()     // hand stays at her ear: she's still listening
            print(dim("(still listening, go ahead)"))
        }
        wake?.onFollowUpExpired = { [weak self] in
            guard let self else { return }
            if self.pet.model.mood == .listening { self.mood(.idle) }
            self.touch()
            print(dim("(conversation over, say “hey Trixie” to start again)"))
        }
        wake?.onPartialCommand = { text in
            print("\r\u{1B}[2K" + dim("… \(text)"), terminator: ""); fflush(stdout)
        }
        wake?.onCommand = { [weak self] text in
            guard let self else { return }
            print("\r\u{1B}[2K", terminator: "")
            NSSound(named: "Pop")?.play()
            // "Thanks", "that's all", "okay": end the conversation without spending a question on it.
            if Self.isDismissal(text) {
                print(dim("you> \(text)  (ok, ending the conversation)"))
                self.finished(followUp: false)
                return
            }
            self.mood(.thinking); self.touch()
            self.ask(text)
        }
        wake?.onCancel = { [weak self] in
            guard let self else { return }
            print("\r\u{1B}[2K" + dim("(heard her name but no question)"))
            self.confusedMoment()
        }
        // Fall asleep after a quiet while, then go away.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    private func mood(_ m: PetMood) { pet.model.mood = m }

    // MARK: - Always-on "hey Trixie"

    var shouldListenForWake: Bool {
        wake != nil && wakeEnabled && !busy && !recording && !turnRunning && !speaking
    }

    /// Start or stop the wake-word listening to match what Trixie is doing right now.
    func updateWake() {
        guard let wake else { return }
        wakeResume?.cancel()
        if !shouldListenForWake {
            if wake.isRunning { wake.stop() }
            return
        }
        if wake.isRunning { return }
        // A short pause first, so the tail of her own voice isn't mistaken for you.
        wakeResume = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled, self.shouldListenForWake, !wake.isRunning else { return }
            let window: TimeInterval? = self.followUpPending ? self.followUpSeconds : nil
            self.followUpPending = false
            do { try wake.start(followUpWindow: window) } catch { print("Couldn't start always-on listening: \(error.localizedDescription)") }
        }
    }

    func setWakeEnabled(_ on: Bool) {
        wakeEnabled = on
        if !on { followUpPending = false }
        UserDefaults.standard.set(on, forKey: "wakeEnabled")
        print(dim(on ? "Listening for “hey Trixie” again." : "No longer listening for “hey Trixie”."))
        updateWake()
    }
    private func touch() { lastActivity = Date() }

    func showPet() {
        pet.show(); mood(.idle); touch()
    }

    private func checkIdle() {
        guard pet.isShown, !recording, !turnRunning, !speaking else { return }
        let quiet = Date().timeIntervalSince(lastActivity)
        if quiet > 90 { pet.hide() }
        else if quiet > 30, pet.model.mood == .idle { mood(.sleeping) }
    }

    func speakingChanged(_ on: Bool) {
        speaking = on
        touch()
        if on {
            settle?.cancel()
            mood(.talking)
        } else if turnRunning {
            mood(.thinking)           // between sentences, still working on the rest
        } else {
            finished()
        }
    }

    /// Didn't catch that, or something went wrong: just settle back to idle.
    func confusedMoment() {
        busy = false
        updateWake()
        mood(.idle)
        touch()
    }

    /// True for short sign-offs that just end the conversation.
    static func isDismissal(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init)
        let cleaned = words.filter { $0 != "trixie" && $0 != "hey" }.joined(separator: " ")
        return ["thanks", "thank you", "thanks a lot", "thank you so much", "okay thanks", "ok thanks", "okay thank you",
                "cool thanks", "that's all", "that is all", "that's it", "never mind", "nevermind", "bye", "goodbye",
                "okay", "ok", "cool", "nice", "great", "got it", "alright", "all right", "okay cool", "okay great"].contains(cleaned)
    }

    /// All done: a short happy moment, then back to idle. After a real answer she keeps
    /// listening for a reply (the follow-up window); pass `followUp: false` to end the conversation.
    func finished(followUp: Bool = true) {
        busy = false
        followUpPending = followUp && wakeEnabled && wake != nil && followUpSeconds > 0
        updateWake()
        mood(.happy)
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !Task.isCancelled, self?.pet.model.mood == .happy { self?.mood(.idle) }
            self?.touch()
        }
    }

    func pressed() {
        guard !recording else { return }
        // Pressing again interrupts whatever Claude is saying or doing.
        turn?.cancel(); session.cancel(); settle?.cancel()
        turnRunning = false
        busy = true
        followUpPending = false
        wakeResume?.cancel(); wake?.stop()      // the hotkey takes over the microphone
        let speaker = self.speaker
        Task { await speaker.stop() }
        pet.show()
        do {
            try listener.start()
            recording = true
            mood(.listening); touch()
            NSSound(named: "Tink")?.play()
            print(dim("listening…"))
        } catch {
            mood(.idle)
            print("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    func released() {
        guard recording else { return }
        recording = false
        NSSound(named: "Pop")?.play()
        mood(.thinking); touch()
        turn = Task { [self] in
            let text = await listener.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            print("\r\u{1B}[2K", terminator: "")
            guard !text.isEmpty else {
                let level = String(format: "%.3f", listener.peakLevel)
                print(dim("(didn't catch anything — mic peak \(level), recogniser \(listener.localeIdentifier) available=\(listener.isAvailable), error: \(listener.lastError ?? "none"))"))
                confusedMoment()
                return
            }
            await runAsk(text)
        }
    }

    /// Ask Trixie something typed or spoken by any route and speak the answer.
    func ask(_ text: String) {
        turn = Task { [self] in await runAsk(text) }
    }

    func runAsk(_ text: String) async {
        busy = true
        print("you> \(text)")
        print("Trixie> ", terminator: ""); fflush(stdout)
        turnRunning = true
        let r = await runTurn(
            text, session: session, speaker: speaker,
            minSentence: await speaker.usesCloud ? 34 : 14,
            onText: { print($0, terminator: ""); fflush(stdout) },
            onTool: { [self] name in
                print(dim("[\(name)] "), terminator: ""); fflush(stdout)
                Task { @MainActor in if !self.speaking { self.mood(.working) } }
            }
        )
        print()
        if r.failed && !Task.isCancelled { print(dim("(something went wrong — is `claude` installed and logged in?)")) }
        if let u = r.usage { print(dim(u)) }
        print()
        turnRunning = false
        touch()
        if r.failed && !Task.isCancelled { confusedMoment(); return }
        // If the voice is already quiet (or never spoke), celebrate now; otherwise
        // the "finished speaking" event does it.
        if !speaking, !Task.isCancelled { finished() }
    }
}

// MARK: - Start up

var config = ClaudeConfig()
if env["CLAUDE_BLOCK_NONE"] == "1" { config.blocked = [] }
if let extra = env["CLAUDE_BLOCK_EXTRA"] {
    config.blocked += extra.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}
if let cwd = env["CLAUDE_CWD"] {
    config.workingDirectory = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
}
let session = ClaudeSession(config: config)
let speaker = Speaker(
    voice: env["CLAUDE_VOICE"],
    rate: Int(env["CLAUDE_RATE"] ?? "") ?? 190,
    muted: env["CLAUDE_MUTE"] == "1"
)

// Use the natural Kokoro voice when it's installed; otherwise the macOS voice.
if let settings = KokoroSettings.detect(env), let helper = KokoroHelper(settings: settings) {
    Task { await speaker.attach(helper) }
}

let hotkeyText = env["CLAUDE_HOTKEY"] ?? "option+space"
guard let combo = HotKey.parse(hotkeyText) else {
    print("Couldn't understand CLAUDE_HOTKEY=\(hotkeyText). Try something like option+space or ctrl+shift+k.")
    exit(1)
}
guard let listener = VoiceListener(locale: Locale(identifier: env["CLAUDE_LANG"] ?? "en-IN")) else {
    print("Speech recognition isn't available for that language."); exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
signal(SIGINT) { _ in exit(0) }

@MainActor enum Keep { static var items: [AnyObject] = [] }

Task { @MainActor in
    print(dim("Asking macOS for microphone and speech permission (click Allow if it asks)…"))
    if let problem = await VoiceListener.requestPermissions() { print(problem); exit(1) }

    let pet = PetWindowController()
    let wake = WakeListener(locale: Locale(identifier: env["CLAUDE_LANG"] ?? "en-IN"))
    let controller = Controller(session: session, speaker: speaker, listener: listener, pet: pet, wake: wake)
    await speaker.setSpeakingHandler { on in
        Task { @MainActor in controller.speakingChanged(on) }
    }
    let menu = StatusMenu(
        wakeOn: controller.wakeEnabled && wake != nil,
        onShow: { controller.showPet() },
        onWakeToggle: { controller.setWakeEnabled($0) },
        onQuit: { Task { await speaker.shutdown(); exit(0) } }
    )
    guard let hotkey = HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers) else {
        print("Couldn't register \(hotkeyText) — another app may be using it. Set CLAUDE_HOTKEY to something else.")
        exit(1)
    }
    hotkey.onPress = { controller.pressed() }
    hotkey.onRelease = { controller.released() }
    Keep.items = [pet, controller, menu, hotkey]

    print("Trixie — hold \(hotkeyText), speak, then let go. Quit from the menu bar icon or Ctrl-C.")
    print(dim("Speech recognition runs \(listener.runsOnDevice ? "on your Mac" : "using Apple's servers"). Reading only: \(config.tools.joined(separator: ", ")) in \(config.workingDirectory.path), \(config.blocked.count) sensitive places blocked.\n"))
    print(dim("Voice: \(await speaker.engineName)\n"))

    if wake == nil {
        print(dim("“Hey Trixie” needs on-device speech recognition, which isn't available here. The hotkey still works."))
    } else if controller.wakeEnabled {
        print(dim("Always listening for “hey Trixie” (on your Mac only). Switch it off from the menu bar icon."))
    }
    controller.showPet()   // say hello once so you can see it's alive
    controller.updateWake()
}
app.run()
