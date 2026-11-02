import Foundation

/// Claude's replies stream in as small pieces. To start talking early we cut
/// them into sentences, and we clean each sentence so it sounds natural when
/// read aloud (no asterisks, no code, no links read out letter by letter).
public struct SentenceSplitter {
    private var buffer = ""
    private var inCodeFence = false
    private let minLength: Int   // avoids splitting on things like "e.g." (and tiny fragments)

    public init(minLength: Int = 14) { self.minLength = minLength }

    /// Feed a streamed chunk; get back any complete sentences ready to speak.
    public mutating func push(_ chunk: String) -> [String] {
        buffer += chunk
        var ready: [String] = []
        while let end = nextBoundary() {
            let piece = String(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex..<end)
            if let spoken = speakable(piece) { ready.append(spoken) }
        }
        return ready
    }

    /// Call when the reply is finished to get whatever is left.
    public mutating func flush() -> String? {
        defer { buffer = ""; inCodeFence = false }
        return speakable(buffer)
    }

    private func nextBoundary() -> String.Index? {
        var i = buffer.startIndex
        var count = 0
        while i < buffer.endIndex {
            let c = buffer[i]
            count += 1
            let next = buffer.index(after: i)
            if c == "\n" && count >= 2 { return next }
            if ".!?".contains(c), next < buffer.endIndex, buffer[next].isWhitespace, count >= minLength {
                return next
            }
            i = next
        }
        return nil
    }

    /// Returns the text to say for a piece, or nil if there is nothing to say.
    private mutating func speakable(_ raw: String) -> String? {
        var kept = ""
        let parts = raw.components(separatedBy: "```")
        for (idx, part) in parts.enumerated() {
            if idx > 0 { inCodeFence.toggle() }
            if !inCodeFence { kept += part }
        }
        let cleaned = SpeechText.clean(kept)
        return cleaned.isEmpty ? nil : cleaned
    }
}

public enum SpeechText {
    public static func clean(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*•]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        for ch in ["**", "__", "*", "_", "#", ">", "|", "~"] { s = s.replacingOccurrences(of: ch, with: " ") }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
