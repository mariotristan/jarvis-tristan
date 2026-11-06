import AVFoundation
import Speech
import UIKit

/// Tap-to-dictate: the transcript streams into `text` while listening.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var listening = false
    @Published var text = ""
    @Published private(set) var problem: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        listening ? stop() : start()
    }

    func start() {
        problem = nil
        SFSpeechRecognizer.requestAuthorization { speech in
            AVAudioApplication.requestRecordPermission { mic in
                Task { @MainActor in
                    guard speech == .authorized else { self.problem = "Speech recognition is off. Allow it in Settings."; return }
                    guard mic else { self.problem = "The microphone is off. Allow it in Settings."; return }
                    self.begin()
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { problem = "Speech recognition is not available right now."; return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            problem = "Could not use the microphone: \(error.localizedDescription)"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let spoken = result?.bestTranscription.formattedString { self?.text = spoken }
                if error != nil || result?.isFinal == true { self?.stop() }
            }
        }
        do {
            engine.prepare()
            try engine.start()
            listening = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            problem = "Could not start the microphone: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        guard listening || engine.isRunning else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
