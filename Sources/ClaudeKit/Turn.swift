import Foundation

public struct TurnResult {
    public var usage: String?
    public var failed: Bool
}

/// One question and answer: send the prompt, show the text as it streams, and
/// speak it sentence by sentence. Shared by the text and the voice programs.
public func runTurn(
    _ prompt: String,
    session: ClaudeSession,
    speaker: Speaker,
    minSentence: Int = 14,
    onText: (String) -> Void,
    onTool: (String) -> Void
) async -> TurnResult {
    var splitter = SentenceSplitter(minLength: minSentence)
    var result = TurnResult(usage: nil, failed: false)
    let started = Date()

    func speak(_ text: String) async {
        ClaudeSession.debug(String(format: "[%.1fs] speaking: %@", Date().timeIntervalSince(started), String(text.prefix(50))))
        await speaker.say(text)
    }

    for await event in session.send(prompt) {
        if Task.isCancelled { break }
        switch event {
        case .text(let chunk):
            onText(chunk)
            for sentence in splitter.push(chunk) { await speak(sentence) }
        case .toolUse(let name):
            // Claude is about to go and look at something. Say whatever it has said so far
            // right now ("let me take a look"), instead of waiting until it comes back.
            if let spoken = splitter.flush() { await speak(spoken) }
            ClaudeSession.debug(String(format: "[%.1fs] tool: %@", Date().timeIntervalSince(started), name))
            onTool(name)
        case .usage(let five, let seven):
            func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "?" }
            result.usage = "usage: 5h \(pct(five)) · 7d \(pct(seven))"
        case .finished(_, let failed):
            result.failed = failed
        case .session:
            break
        }
    }
    if !Task.isCancelled, let rest = splitter.flush() { await speak(rest) }
    return result
}
