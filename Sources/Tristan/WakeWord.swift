import AVFoundation
import Speech

/// Finds "hey Tristan" (and common mishearings) and returns what was said after the last occurrence.
enum WakeWordMatcher {
    private static let pattern = try! NSRegularExpression(pattern: #"\b(?:hey|hi|ok|okay)[\s,]+(?:tristan|tristen|tristin|kristan|christian)\b[\s,.:;!?-]*"#,
                                                          options: [.caseInsensitive])

    /// nil when the wake phrase is absent; an empty string when it was said with nothing after it yet.
    static func command(in transcript: String) -> String? {
        let range = NSRange(transcript.startIndex..., in: transcript)
        guard let last = pattern.matches(in: transcript, range: range).last,
              let end = Range(last.range, in: transcript)?.upperBound else { return nil }
        return String(transcript[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Decides when a spoken command starts and ends. Pure (time is passed in), so it can be tested without a microphone.
struct WakeCapture {
    enum Output: Equatable { case none, started, update(String), submit(String), cancelled }

    var silenceTimeout: TimeInterval = 1.8
    var initialTimeout: TimeInterval = 5      // how long to wait for words after only "hey Tristan"
    private(set) var capturing = false
    private var text = ""
    private var lastChange = Date.distantPast

    mutating func feed(transcript: String, now: Date) -> Output {
        guard let command = WakeWordMatcher.command(in: transcript) else { return .none }
        if !capturing {
            capturing = true
            text = command
            lastChange = now
            return .started
        }
        guard command != text else { return .none }
        text = command
        lastChange = now
        return .update(command)
    }

    mutating func tick(now: Date) -> Output {
        guard capturing else { return .none }
        let limit = text.isEmpty ? initialTimeout : silenceTimeout
        guard now.timeIntervalSince(lastChange) > limit else { return .none }
        let spoken = text
        reset()
        return spoken.isEmpty ? .cancelled : .submit(spoken)
    }

    mutating func reset() {
        capturing = false
        text = ""
        lastChange = .distantPast
    }
}

/// Always-listening "Hey Tristan" detector. Uses on-device recognition only, so audio never leaves the Mac.
@MainActor
final class WakeListener {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var capture = WakeCapture()
    private var timer: Timer?
    private var restartAt = Date.distantFuture
    private(set) var running = false

    var onStarted: (() -> Void)?
    var onUpdate: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((String) -> Void)?

    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func setRunning(_ shouldRun: Bool) {
        if shouldRun, !running { start() } else if !shouldRun, running { stop() }
    }

    private func start() {
        guard supportsOnDevice else {
            onError?("Wake word needs on-device speech recognition, which is not available for this language.")
            return
        }
        running = true
        SFSpeechRecognizer.requestAuthorization { speech in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                Task { @MainActor in
                    guard self.running else { return }
                    guard speech == .authorized, mic else {
                        self.running = false
                        self.onError?("Wake word needs microphone and speech recognition permission.")
                        return
                    }
                    self.begin()
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { running = false; onError?("Speech recognizer is unavailable"); return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        capture.reset()

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.running else { return }
                if let text = result?.bestTranscription.formattedString { self.handle(text) }
                if error != nil || result?.isFinal == true { self.restartSoon() }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            running = false
            onError?("Could not start the microphone for the wake word: \(error.localizedDescription)")
            return
        }
        // Recognition requests expire after about a minute, so recycle them while idle.
        restartAt = Date().addingTimeInterval(50)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func handle(_ transcript: String) {
        apply(capture.feed(transcript: transcript, now: Date()))
    }

    private func tick() {
        apply(capture.tick(now: Date()))
        if !capture.capturing, Date() > restartAt { restartSoon() }
    }

    private func apply(_ output: WakeCapture.Output) {
        switch output {
        case .none: break
        case .started: onStarted?()
        case .update(let text): onUpdate?(text)
        case .submit(let text): onSubmit?(text); restartSoon()
        case .cancelled: onCancel?(); restartSoon()
        }
    }

    private func restartSoon() {
        guard running else { return }
        teardown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.running else { return }
            self.begin()
        }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    func stop() {
        running = false
        teardown()
        capture.reset()
    }
}
