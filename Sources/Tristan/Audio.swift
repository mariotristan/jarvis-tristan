import AVFoundation

/// Moments Tristan makes a sound for.
enum Cue: CaseIterable {
    case listenStart, listenStop, missionStart, approvalNeeded, approved, denied, missionComplete, missionFailed
}

/// Sci-fi UI sounds synthesised in code (no audio assets) plus short spoken lines in a British voice.
@MainActor
final class SoundFX {
    private struct Note {
        var start: Double       // seconds from cue start
        var duration: Double
        var from: Double        // Hz at the start of the note
        var to: Double          // Hz at the end (a sweep when different)
        var gain: Double = 0.5
        var shimmer: Double = 0.25   // level of the octave-up overtone
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 44_100.0
    private var started = false
    private let speaker = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegate()
    /// Called with true when a spoken line starts and false when it ends or is cut off.
    var onSpeaking: ((Bool) -> Void)? {
        didSet { speechDelegate.onChange = onSpeaking }
    }

    var soundsOn = true
    var voiceOn = true

    init() { speaker.delegate = speechDelegate }

    // MARK: sounds

    func play(_ cue: Cue) {
        guard soundsOn, let buffer = buffer(for: cue) else { return }
        guard startEngineIfNeeded() else { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func startEngineIfNeeded() -> Bool {
        if started { return engine.isRunning }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.6
        started = true
        do { try engine.start() } catch { return false }
        return true
    }

    private func notes(for cue: Cue) -> [Note] {
        switch cue {
        case .listenStart:   // rising two-step chirp
            return [Note(start: 0, duration: 0.10, from: 520, to: 980), Note(start: 0.09, duration: 0.12, from: 980, to: 1560, gain: 0.45)]
        case .listenStop:    // falling chirp
            return [Note(start: 0, duration: 0.16, from: 1300, to: 620, gain: 0.45)]
        case .missionStart:  // power-up sweep with a shimmer on top
            return [Note(start: 0, duration: 0.55, from: 180, to: 1100, gain: 0.35, shimmer: 0.5),
                    Note(start: 0.30, duration: 0.30, from: 880, to: 1760, gain: 0.25, shimmer: 0.4)]
        case .approvalNeeded:  // two-tone attention ping
            return [Note(start: 0, duration: 0.11, from: 880, to: 880, gain: 0.45), Note(start: 0.14, duration: 0.16, from: 660, to: 660, gain: 0.45)]
        case .approved:
            return [Note(start: 0, duration: 0.09, from: 660, to: 990, gain: 0.4)]
        case .denied:
            return [Note(start: 0, duration: 0.22, from: 230, to: 170, gain: 0.5, shimmer: 0)]
        case .missionComplete:  // bright rising arpeggio, long tail
            let freqs = [523.25, 659.25, 783.99, 1046.5]
            return freqs.enumerated().map { Note(start: Double($0.offset) * 0.09, duration: $0.offset == 3 ? 0.7 : 0.25, from: $0.element, to: $0.element, gain: 0.32, shimmer: 0.35) }
        case .missionFailed:   // descending, dissonant
            return [Note(start: 0, duration: 0.35, from: 440, to: 220, gain: 0.45, shimmer: 0.1),
                    Note(start: 0.12, duration: 0.45, from: 415, to: 160, gain: 0.35, shimmer: 0)]
        }
    }

    func buffer(for cue: Cue) -> AVAudioPCMBuffer? {
        let notes = notes(for: cue)
        let total = (notes.map { $0.start + $0.duration }.max() ?? 0.2) + 0.05
        let frames = AVAudioFrameCount(total * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { out[i] = 0 }

        for note in notes {
            let begin = Int(note.start * sampleRate)
            let count = Int(note.duration * sampleRate)
            var phase = 0.0
            for n in 0..<count where begin + n < Int(frames) {
                let t = Double(n) / Double(count)
                let freq = note.from + (note.to - note.from) * t
                phase += 2 * .pi * freq / sampleRate
                // Quick attack, exponential-ish decay.
                let envelope = min(1, Double(n) / (0.006 * sampleRate)) * pow(1 - t, 1.6)
                let wave = sin(phase) + note.shimmer * sin(phase * 2)
                out[begin + n] += Float(wave * note.gain * envelope)
            }
        }
        for i in 0..<Int(frames) { out[i] = max(-1, min(1, out[i])) }
        return buffer
    }

    // MARK: voice

    /// Kids mode: a bright, upbeat voice instead of the butler.
    var kidsVoice = false

    /// Speaks a line in a British English voice (Jarvis-style) when available, or a cheerful one in kids mode.
    func say(_ text: String, interrupt: Bool = true) {
        guard voiceOn, !text.isEmpty else { return }
        // Stopping at the end of the word, not mid-sample, avoids a click when one line cuts off another.
        if interrupt, speaker.isSpeaking { speaker.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        if kidsVoice {
            utterance.voice = Self.kidsPreferredVoice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.0
            utterance.pitchMultiplier = 1.3
        } else {
            utterance.voice = Self.preferredVoice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
            utterance.pitchMultiplier = 0.92
        }
        speaker.speak(utterance)
    }

    func stopSpeaking() { speaker.stopSpeaking(at: .immediate) }

    /// True when the voice used for speech is a compact one (the lowest quality). Those render at 22 kHz and tend to
    /// sound rough or crackly; an Enhanced or Premium voice from System Settings fixes it.
    static var voiceIsCompact: Bool { (preferredVoice?.quality.rawValue ?? 0) < AVSpeechSynthesisVoiceQuality.enhanced.rawValue }

    private static let preferredVoice: AVSpeechSynthesisVoice? = {
        let british = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        // Prefer the highest quality male-sounding voice we can find, falling back to any en-GB voice.
        let preferredNames = ["Daniel", "Oliver", "Arthur", "Malcolm"]
        for name in preferredNames {
            if let voice = british.filter({ $0.name.contains(name) }).max(by: { $0.quality.rawValue < $1.quality.rawValue }) { return voice }
        }
        return british.max(by: { $0.quality.rawValue < $1.quality.rawValue }) ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// The youngest, brightest voice installed: the macOS child-like voices first, then friendly American ones.
    private static let kidsPreferredVoice: AVSpeechSynthesisVoice? = {
        let american = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        for name in ["Junior", "Kathy", "Samantha", "Ava", "Allison", "Nicky"] {
            if let voice = american.filter({ $0.name.contains(name) }).max(by: { $0.quality.rawValue < $1.quality.rawValue }) { return voice }
        }
        return american.max(by: { $0.quality.rawValue < $1.quality.rawValue }) ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    // MARK: lines

    static let startLines = ["On it, sir.", "Right away.", "Working on it.", "Consider it done."]
    static let approvalLines = ["Authorization required.", "I need your permission, sir.", "Awaiting your approval."]
    static let doneLines = ["Mission complete.", "All done, sir.", "As always, sir, a great pleasure watching you work.", "Task complete.", "Done, sir."]
    static let kidsStartLines = ["Ready! Let's go!", "On it! No job is too big!", "Let's find out together!", "Here we go!"]
    static let kidsApprovalLines = ["I need a grown-up to say okay.", "Ask a grown-up to say yes, please."]
    static let kidsDoneLines = ["All done! Great job!", "Mission complete! Awesome!", "We did it! Hooray!"]
    static let kidsFailLines = ["Oops! That didn't work. Let's ask a grown-up.", "Uh oh! Let's try again with a grown-up."]
    static let failLines = ["Mission failed.", "I'm afraid that didn't work, sir.", "Something went wrong."]
}

/// Bridges AVSpeechSynthesizer callbacks (which arrive on arbitrary threads) to the main actor.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onChange: ((Bool) -> Void)?

    private func notify(_ speaking: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onChange?(speaking) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { notify(true) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { notify(false) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { notify(false) }
}
