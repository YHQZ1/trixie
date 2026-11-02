import Foundation
import ClaudeKit

// Step 1: the "text brain". Type a message, Claude answers, and the answer is
// spoken out loud while it streams. No microphone and no pet.
//
// Optional settings (environment variables):
//   CLAUDE_VOICE=Samantha   which macOS voice to use (try `say -v '?'`)
//   CLAUDE_RATE=190         words per minute
//   CLAUDE_MUTE=1           print only, don't speak
//   CLAUDE_CWD=~/Developer  the folder Claude can read

let env = ProcessInfo.processInfo.environment
setvbuf(stdout, nil, _IOLBF, 0)   // show each line right away, even when output is redirected

var config = ClaudeConfig()
if let cwd = env["CLAUDE_CWD"] {
    config.workingDirectory = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
}
let session = ClaudeSession(config: config)
let speaker = Speaker(
    voice: env["CLAUDE_VOICE"],
    rate: Int(env["CLAUDE_RATE"] ?? "") ?? 190,
    muted: env["CLAUDE_MUTE"] == "1"
)

func dim(_ s: String) -> String { "\u{1B}[2m\(s)\u{1B}[0m" }

// Use the natural Kokoro voice when it's installed; otherwise the macOS voice.
if let settings = KokoroSettings.detect(env), let helper = KokoroHelper(settings: settings) {
    await speaker.attach(helper)
}

print(dim("Trixie — type a message, or /new to start over, /quit to leave."))
print(dim("Voice: \(await speaker.engineName)"))
print(dim("Reading only: \(config.tools.joined(separator: ", ")) in \(config.workingDirectory.path)\n"))

while true {
    print("you> ", terminator: "")
    fflush(stdout)
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { break }
    if line.isEmpty { continue }
    if line == "/quit" || line == "/exit" { break }
    if line == "/new" { session.reset(); print(dim("(new conversation)\n")); continue }

    print("claude> ", terminator: "")
    fflush(stdout)
    let r = await runTurn(
        line, session: session, speaker: speaker,
        minSentence: await speaker.usesCloud ? 34 : 14,
        onText: { print($0, terminator: ""); fflush(stdout) },
        onTool: { print(dim("[\($0)] "), terminator: ""); fflush(stdout) }
    )
    print()
    if r.failed { print(dim("(something went wrong — is `claude` installed and logged in?)")) }
    if let u = r.usage { print(dim(u)) }
    await speaker.waitUntilDone()
    print()
}
await speaker.shutdown()
