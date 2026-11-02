import Foundation

/// Things that happen while Claude is answering. The pet UI will later turn
/// these into animations (thinking, working, talking).
public enum ClaudeEvent {
    case session(String)                         // conversation id, used to continue the chat
    case text(String)                            // a small piece of the reply, as it streams
    case toolUse(String)                         // Claude started using a tool (Read, Glob, ...)
    case usage(fiveHour: Double?, sevenDay: Double?)  // subscription usage, 0...1
    case finished(costUSD: Double?, failed: Bool)
}

public struct ClaudeConfig {
    /// Folder Claude works in. File tools are limited to this folder plus `extraDirectories`.
    public var workingDirectory: URL
    public var extraDirectories: [URL]
    /// Places she may NOT read, even inside the folder above (patterns like "~/.ssh/**").
    public var blocked: [String]
    /// Built-in tools Claude may use. Read-only for now; anything that changes
    /// things will come later, behind a confirmation.
    public var tools: [String]
    public var voiceStyle: String

    public init(
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraDirectories: [URL] = [],
        blocked: [String] = ClaudeConfig.defaultBlocked,
        tools: [String] = ["Read", "Glob", "Grep"],
        voiceStyle: String = ClaudeConfig.defaultVoiceStyle
    ) {
        self.workingDirectory = workingDirectory
        self.extraDirectories = extraDirectories
        self.blocked = blocked
        self.tools = tools
        self.voiceStyle = voiceStyle
    }

    /// Keys, credentials, shell history, app data and ID documents stay off-limits even though she
    /// can read the rest of your home folder. Change with CLAUDE_BLOCK_EXTRA or CLAUDE_BLOCK_NONE=1.
    public static let defaultBlocked: [String] = [
        // keys and cloud credentials
        "~/.ssh/**", "~/.aws/**", "~/.gnupg/**", "~/.kube/**", "~/.docker/**", "~/.config/gh/**",
        "~/.cloudflared/**", "~/.ngrok/**", "~/.pgadmin/**", "~/.mongodb/**", "~/.netrc", "~/.npmrc", "~/.pypirc",
        // other AI tools' stored sessions and logins
        "~/.claude/**", "~/.claude.json", "~/.copilot/**", "~/.gemini/**",
        // shell and database history
        "~/.zsh_history", "~/.bash_history", "~/.python_history", "~/.node_repl_history",
        "~/.mysql_history", "~/.psql_history", "~/.rediscli_history", "~/.lesshst", "~/.pig_history",
        // app data and ID documents
        "~/Library/**", "~/Documents/Personal Documents/**",
        // secrets wherever they sit
        "**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/*.p12", "**/id_rsa*", "**/id_ed25519*",
    ]

    public static let defaultVoiceStyle = """
    Your name is Trixie. You are a little pixel pet on Uttkarsh's desktop, powered by Claude, and he talks to \
    you out loud. If he asks who you are, say you're Trixie. Everything you write is spoken by a voice, so \
    talk like a friend chatting, not like you're writing.
    - Use contractions and everyday words. Short sentences, sometimes just a fragment. Things like \
    "Yeah, it's a deploy tool.", "Oh nice.", "Okay so...", "Hm, let me see."
    - React first when it fits, like "oh nice", "ah, got it", "hm, good question". Not every time.
    - Never use formal connectors like "additionally", "however" or "furthermore". Never use lists, \
    headings, markdown, emoji, brackets, colons, semicolons or dashes. Plain commas and full stops only.
    - Say things the way you'd say them out loud. Round numbers ("about forty"). Never read out file \
    paths, version numbers or long names; say "the roadmap doc", not "docs/05-roadmap.md".
    - Usually one to three short sentences. A quick follow-up question now and then is fine, but not every time.
    - If code or a long list is needed, say you'll put it on screen and keep the spoken part short.
    - Right now you can only read files, not change anything; if he asks for a change, say you can't do \
    that yet. Check his files instead of guessing. Some private places (keys, credentials, ID documents) \
    are blocked for you; if a read is denied, just say that spot is protected.
    - Never go quiet while you work: BEFORE you use any tool, first say one short natural line about what \
    you're about to do, like "Let me check the docs" or "One sec, looking at that now", and only then use \
    the tool. Keep that line under ten words and vary it. After the tool results come back, give the answer.
    """
}

/// One ongoing conversation with the `claude` CLI. Each `send` starts a CLI
/// process and streams its answer back; the conversation id is remembered so
/// the next question continues the same chat.
public final class ClaudeSession: @unchecked Sendable {
    public let config: ClaudeConfig
    public private(set) var sessionID: String?
    private var process: Process?
    private let lock = NSLock()

    public init(config: ClaudeConfig = ClaudeConfig()) {
        self.config = config
    }

    public func reset() { sessionID = nil }

    /// Stop the current answer (used later when you interrupt the pet).
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
    }

    // Plain (non-async) helper so the lock is never held across an await.
    private func setProcess(_ p: Process?) {
        lock.lock(); defer { lock.unlock() }
        process = p
    }

    public func send(_ prompt: String) -> AsyncStream<ClaudeEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(prompt, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel(); self.cancel() }
        }
    }

    // MARK: - Running the CLI

    /// An app started from Finder or `open` gets a tiny PATH, so look for the
    /// CLI in the usual places instead of relying on it.
    static func findClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.claude/local/claude",
        ]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_BIN"] { candidates.insert(custom, at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// A short map of the folders under her working folder, so she goes straight to the right place
    /// instead of guessing names. Her search tool only lists files and is case-sensitive, so without
    /// this she can miss a folder like "Academic" by searching for "academic".
    func homeMapPrompt() -> String {
        let fm = FileManager.default
        let root = config.workingDirectory
        let home = fm.homeDirectoryForCurrentUser.path
        // Directory prefixes she's not allowed into, from the blocked list ("~/Documents/Personal Documents/**").
        let blockedPrefixes = config.blocked.compactMap { rule -> String? in
            guard rule.hasPrefix("~/") else { return nil }
            var p = home + "/" + rule.dropFirst(2)
            if p.hasSuffix("/**") { p = String(p.dropLast(3)) }
            return p
        }
        func visibleFolders(in dir: URL) -> [URL] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])) ?? []
            return items
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .filter { url in !blockedPrefixes.contains { url.path == $0 || url.path.hasPrefix($0 + "/") } }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        }
        let skip: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public"]
        var lines: [String] = []
        for top in visibleFolders(in: root) where !skip.contains(top.lastPathComponent) {
            let subs = visibleFolders(in: top).prefix(14).map { $0.lastPathComponent }
            lines.append(subs.isEmpty ? "\(top.path)" : "\(top.path): \(subs.joined(separator: ", "))")
        }
        guard !lines.isEmpty else { return "" }
        return """
        Map of his folders under \(root.path) (folders only, two levels, private places left out). Use it to go \
        straight to the right place. Your search tool only lists files and is case-sensitive, so don't guess \
        names: point it at a folder from this map with its exact capitalisation, for example path set to that \
        folder and the pattern **/*. If something isn't in the map or isn't there, say you couldn't find it.
        \(lines.joined(separator: "\n"))
        """
    }

    private func arguments() -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            // Keep the setup small and fast (about 5k tokens instead of 20k+).
            "--tools", config.tools.joined(separator: ","),
            "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "",
            "--append-system-prompt", config.voiceStyle + "\n" + homeMapPrompt(),
        ]
        if !config.blocked.isEmpty {
            args += ["--disallowedTools"] + config.blocked.map { "Read(\($0))" }
        }
        for dir in config.extraDirectories { args += ["--add-dir", dir.path] }
        if let id = sessionID { args += ["--resume", id] }
        return args
    }

    private func run(_ prompt: String, _ out: AsyncStream<ClaudeEvent>.Continuation) async {
        let p = Process()
        if let exe = Self.findClaude() {
            p.executableURL = exe
            p.arguments = arguments()
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["claude"] + arguments()
        }
        p.currentDirectoryURL = config.workingDirectory
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout
        // Errors go to a file for troubleshooting. (A pipe nobody reads can fill up and freeze the CLI.)
        let errPath = "/tmp/claude-cli.err"
        FileManager.default.createFile(atPath: errPath, contents: nil)
        p.standardError = FileHandle(forWritingAtPath: errPath) ?? FileHandle.nullDevice

        setProcess(p)
        Self.debug("spawning \(p.executableURL?.path ?? "?")")
        do { try p.run() } catch {
            Self.debug("spawn failed: \(error)")
            out.yield(.finished(costUSD: nil, failed: true)); return
        }
        Self.debug("spawned pid \(p.processIdentifier)")
        // The question goes in through stdin so odd characters can't be mistaken for flags.
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        var sawResult = false
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                Self.debug("line: \(line.prefix(60))")
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let ev = Self.parse(obj) {
                    if case .session(let id) = ev { sessionID = id }
                    if case .finished = ev { sawResult = true }
                    out.yield(ev)
                }
            }
        } catch {}
        p.waitUntilExit()
        if !sawResult { out.yield(.finished(costUSD: nil, failed: true)) }
    }

    public static func debug(_ s: String) {
        if ProcessInfo.processInfo.environment["CLAUDE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[debug] \(s)\n".utf8))
        }
    }

    /// Turn one line of the CLI's JSON stream into an event we care about.
    static func parse(_ o: [String: Any]) -> ClaudeEvent? {
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init", let id = o["session_id"] as? String { return .session(id) }
        case "stream_event":
            guard let e = o["event"] as? [String: Any] else { return nil }
            switch e["type"] as? String {
            case "content_block_delta":
                if let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                   let t = d["text"] as? String { return .text(t) }
            case "content_block_start":
                if let b = e["content_block"] as? [String: Any], b["type"] as? String == "tool_use",
                   let n = b["name"] as? String { return .toolUse(n) }
            default: break
            }
        case "rate_limit_event":
            let w = ((o["rate_limit_info"] as? [String: Any])?["unifiedWindows"]) as? [String: Any]
            let five = (w?["five_hour"] as? [String: Any])?["utilization"] as? Double
            let seven = (w?["seven_day"] as? [String: Any])?["utilization"] as? Double
            return .usage(fiveHour: five, sevenDay: seven)
        case "result":
            let failed = (o["is_error"] as? Bool) ?? (o["subtype"] as? String != "success")
            return .finished(costUSD: o["total_cost_usd"] as? Double, failed: failed)
        default: break
        }
        return nil
    }
}
