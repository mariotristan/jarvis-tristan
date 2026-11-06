import AVFoundation
import Speech

/// Push-to-talk speech recognition. Partial transcripts stream to `onText` while listening.
@MainActor
final class VoiceInput {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(onText: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speech in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                Task { @MainActor in
                    guard speech == .authorized else { onError("Speech recognition is not allowed. Enable it in System Settings > Privacy & Security."); return }
                    guard mic else { onError("Microphone access is not allowed. Enable it in System Settings > Privacy & Security."); return }
                    self.begin(onText: onText, onError: onError)
                }
            }
        }
    }

    private func begin(onText: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else { onError("Speech recognizer is unavailable"); return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        task = recognizer.recognitionTask(with: request) { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in onText(text) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            onError("Could not start the microphone: \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
    }
}
