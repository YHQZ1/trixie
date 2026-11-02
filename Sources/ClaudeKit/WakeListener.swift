import AVFoundation
import Foundation
import Speech

/// Hands the microphone audio from the audio thread to whichever recognition request is current.
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = new; lock.unlock()
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }
}

/// Always-on listening for "hey Trixie".
///
/// It listens through Apple's speech recogniser **on your Mac only** (it refuses to start if that
/// isn't available, so nothing is ever sent to a server). While scanning it throws everything away
/// except the wake phrase. When it hears "hey Trixie", it keeps listening and collects whatever you
/// say next as your question, finishing when you pause.
@MainActor
public final class WakeListener {
    /// Called when she starts hearing a question. `followUp` is true when you just carried on
    /// the conversation without saying her name.
    public var onWake: ((_ followUp: Bool) -> Void)?
    public var onFollowUpOpen: (() -> Void)?
    public var onFollowUpExpired: (() -> Void)?
    public var onPartialCommand: ((String) -> Void)?
    public var onCommand: ((String) -> Void)?
    public var onCancel: (() -> Void)?
    public private(set) var isRunning = false

    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private let box = RequestBox()
    private var task: SFSpeechRecognitionTask?
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?

    private enum State { case scanning, followUp, capturing }
    private var state = State.scanning
    private var sessionStart = Date()
    private var wakeTime = Date()
    private var lastChange = Date()
    private var command = ""          // everything heard so far after the wake phrase
    private var committed = ""        // earlier pieces of the question (you paused mid-sentence)
    private var segment = ""          // the piece currently being heard
    private var ticker: Timer?
    private var followUpDeadline = Date.distantPast

    // "hey trixie" (plus the ways a recogniser tends to mis-hear the name), or her name on its own
    // at the very start of a phrase: "Trixie, what's the time?"
    private static let wakePattern = try! NSRegularExpression(
        pattern: #"(?:\b(?:hey|hi|hello|okay|ok|yo)[\s,.!]*(?:trixie|trixy|trixi|tricksy|tricksie|tricky|trix)\b|^\s*(?:trixie|trixy|trixi|tricksy|tricksie)\b)[\s,.!?]*"#,
        options: [.caseInsensitive]
    )

    /// nil if this Mac can't recognise speech on-device (then we never listen continuously).
    public init?(locale: Locale = Locale(identifier: "en-IN")) {
        guard let r = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              r.supportsOnDeviceRecognition else { return nil }
        recognizer = r
    }

    /// "uh", "hmm" and friends shouldn't start a question.
    static func isFiller(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.isEmpty || (words.count == 1 && ["uh", "um", "uhh", "umm", "hmm", "mm", "mmm", "ah", "er", "erm"].contains(words[0]))
    }

    /// The words after the last "hey Trixie" in `text`, or nil if the wake phrase isn't there.
    static func command(after text: String) -> String? {
        let ns = text as NSString
        let all = wakePattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = all.last else { return nil }
        return ns.substring(from: last.range.location + last.range.length)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?").union(.whitespacesAndNewlines))
    }

    // MARK: - Start and stop

    /// Start listening. With `followUpWindow`, anything you say in the next few seconds counts as
    /// your next question (no "hey Trixie" needed); after that she goes back to waiting for her name.
    public func start(followUpWindow: TimeInterval? = nil) throws {
        guard !isRunning else { return }
        state = followUpWindow == nil ? .scanning : .followUp
        if let window = followUpWindow { followUpDeadline = Date().addingTimeInterval(window) }
        command = ""; committed = ""; segment = ""
        beginSession()

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { [box] buffer, _ in
            box.append(buffer)
        }
        engine.prepare()
        try engine.start()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        isRunning = true
        if followUpWindow != nil { onFollowUpOpen?() }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        ticker?.invalidate(); ticker = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        box.set(nil)
        activeRequest?.endAudio()
        task?.cancel()
        task = nil; activeRequest = nil
    }

    // MARK: - Recognition sessions

    /// Start a fresh recognition request. The previous one is closed shortly after, so there's no
    /// gap in which a word could fall between the two.
    private func beginSession() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = false
        req.taskHint = .dictation
        req.contextualStrings = ["Trixie", "Hey Trixie"]

        let oldRequest = activeRequest, oldTask = task
        activeRequest = req
        box.set(req)
        sessionStart = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(text: text, final: final, failed: failed, from: req) }
            }
        }
        if let oldRequest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { oldRequest.endAudio(); oldTask?.cancel() }
        }
    }

    private func handle(text: String?, final: Bool, failed: Bool, from request: SFSpeechAudioBufferRecognitionRequest) {
        guard isRunning, request === activeRequest else { return }   // ignore leftovers from an old session

        if let text {
            let afterName = Self.command(after: text)    // nil if her name isn't in this transcript
            if state == .followUp {
                // Mid-conversation: whatever you say is the question (unless it's just "uh").
                let spoken = afterName ?? text
                if afterName != nil || !Self.isFiller(spoken) {
                    state = .capturing
                    wakeTime = Date(); lastChange = Date()
                    committed = ""; segment = spoken; command = spoken
                    onWake?(afterName == nil)
                    if !spoken.isEmpty { onPartialCommand?(spoken) }
                }
            } else if state == .scanning {
                if let spoken = afterName {
                    state = .capturing
                    wakeTime = Date(); lastChange = Date()
                    committed = ""; segment = spoken; command = spoken
                    onWake?(false)
                    if !spoken.isEmpty { onPartialCommand?(spoken) }
                } else if ProcessInfo.processInfo.environment["CLAUDE_DEBUG"] != nil, !text.isEmpty {
                    ClaudeSession.debug("heard: \(text.suffix(70))")
                }
            } else {
                // After a pause the recogniser starts a new transcript that no longer contains her name.
                // That new phrase is the question; if it replaces a longer piece, keep the old piece too.
                let current = afterName ?? text
                if afterName == nil, current.count + 8 < segment.count { committed += segment + " " }
                segment = current
                let full = (committed + segment).trimmingCharacters(in: .whitespacesAndNewlines)
                if full != command {
                    command = full
                    lastChange = Date()
                    if !full.isEmpty { onPartialCommand?(full) }
                }
            }
        }

        if final || failed {
            if state == .capturing { finishCapture() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.restartIfStillScanning() } }
        }
    }

    private func restartIfStillScanning() {
        if isRunning, state == .scanning || state == .followUp { beginSession() }
    }

    // MARK: - Timing

    private func tick() {
        let now = Date()
        switch state {
        case .scanning:
            // Recognisers don't like running forever, so quietly start a new session now and then.
            if now.timeIntervalSince(sessionStart) > 55 { beginSession() }
        case .followUp:
            if now >= followUpDeadline {          // nobody spoke: back to waiting for her name
                state = .scanning
                onFollowUpExpired?()
            }
        case .capturing:
            let quiet = now.timeIntervalSince(lastChange)
            if !command.isEmpty, quiet > 1.4 { finishCapture() }                       // you paused: that's the question
            else if command.isEmpty, now.timeIntervalSince(wakeTime) > 6 { finishCapture() }   // only said her name
            else if now.timeIntervalSince(wakeTime) > 30 { finishCapture() }          // far too long
        }
    }

    private func finishCapture() {
        let spoken = command.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()   // the controller decides when to start listening again
        if spoken.isEmpty { onCancel?() } else { onCommand?(spoken) }
    }
}
