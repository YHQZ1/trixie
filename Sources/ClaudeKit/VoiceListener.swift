import AVFoundation
import Foundation
import Speech

/// Listens to the microphone while you hold the hotkey and turns your speech
/// into text using macOS's own speech recognition, on your laptop when possible.
public final class VoiceListener: @unchecked Sendable {
    /// Words the recogniser should expect, so "Kubernetes" doesn't become "cooper nettys".
    public static let vocabulary = [
        "Trixie", "Claude", "Kubernetes", "Hatch", "Kprobe", "Escrow", "Provenance", "TraceLink", "Uttkarsh",
        "GitHub", "LinkedIn", "Kafka", "Postgres", "Docker", "Swift", "Rust", "eBPF",
    ]

    public var onPartial: ((String) -> Void)?
    public var runsOnDevice: Bool { recognizer.supportsOnDeviceRecognition }

    /// For troubleshooting: the loudest the microphone got this time (0...1) and any recogniser error.
    public private(set) var peakLevel: Float = 0
    public private(set) var lastError: String?
    public var isAvailable: Bool { recognizer.isAvailable }
    public var localeIdentifier: String { recognizer.locale.identifier }

    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var waiter: CheckedContinuation<String, Never>?

    public init?(locale: Locale = Locale(identifier: "en-IN")) {
        guard let r = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else { return nil }
        recognizer = r
    }

    /// Ask macOS for permission. Returns a message if something is blocked, or nil if all is well.
    public static func requestPermissions() async -> String? {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            return "Speech Recognition is not allowed. Turn it on in System Settings > Privacy & Security > Speech Recognition."
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return "Microphone access is not allowed. Turn it on in System Settings > Privacy & Security > Microphone."
        }
        return nil
    }

    /// Start listening (call when the hotkey goes down).
    public func start(forceOnDevice: Bool? = nil) throws {
        latest = ""
        lastError = nil
        peakLevel = 0
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = forceOnDevice ?? recognizer.supportsOnDeviceRecognition
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = Self.vocabulary
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.latest = result.bestTranscription.formattedString
                    self.onPartial?(self.latest)
                    if result.isFinal { self.complete() }
                } else if let error {
                    self.lastError = (error as NSError).localizedDescription + " [\((error as NSError).domain) \((error as NSError).code)]"
                    self.complete()
                }
            }
        }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            req.append(buffer)
            // Measure how loud the microphone is, to tell "silence" from "can't understand".
            if let data = buffer.floatChannelData?[0] {
                var peak: Float = 0
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
                DispatchQueue.main.async { if let self, peak > self.peakLevel { self.peakLevel = peak } }
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stop listening (call when the hotkey goes up) and get what you said.
    public func finish() async -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        return await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                self.waiter = cont
                // If the final result is slow, use what we already have.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.complete() }
            }
        }
    }

    private func complete() {
        guard let w = waiter else { return }
        waiter = nil
        task?.cancel()
        w.resume(returning: latest)
    }
}
