// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "trixie",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything reusable: talking to the claude CLI, cleaning text for speech, speaking,
        // listening, and the global hotkey.
        .target(name: "ClaudeKit"),
        // Step 1: a terminal "text brain" to prove the loop works.
        .executableTarget(name: "trixie-talk", dependencies: ["ClaudeKit"]),
        // Step 2: hold a hotkey, speak, hear the answer. This one must run as a real Mac app
        // (see scripts/run.sh) so macOS asks permission for the microphone and speech itself.
        .executableTarget(name: "trixie", dependencies: ["ClaudeKit"]),
    ]
)
