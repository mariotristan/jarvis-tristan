// Records one app's window and that app's own audio into an mp4, in sync. Used by record-demo.sh.
//   record-window <out.mp4> <max-seconds> <pid>
// Stops at the time limit or on SIGINT/SIGTERM, whichever comes first. Needs Screen Recording permission for the
// terminal that runs it. Only the app's audio is captured, so nothing else playing on the Mac ends up in the file.
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)
// ScreenCaptureKit needs a connection to the window server, which a command-line tool only gets this way.
_ = NSApplication.shared
let arguments = CommandLine.arguments
guard arguments.count == 4, let maxSeconds = Double(arguments[2]), let pid = Int32(arguments[3]) else {
    FileHandle.standardError.write(Data("usage: record-window <out.mp4> <max-seconds> <pid>\n".utf8))
    exit(2)
}
let outURL = URL(fileURLWithPath: arguments[1])

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "record-window")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private var sessionStart: CMTime?
    private var videoFrames = 0
    private var audioBuffers = 0
    private var nextAudioPTS: CMTime?
    private var audioTimingFaults = 0
    private(set) var stream: SCStream?

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
        ])
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(audio)
        super.init()
    }

    func begin(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Only finished frames carry a picture; the others report that nothing changed.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if sessionStart == nil {
                guard writer.startWriting() else { return }
                sessionStart = sampleBuffer.presentationTimeStamp
                writer.startSession(atSourceTime: sessionStart!)
            }
            if video.isReadyForMoreMediaData, video.append(sampleBuffer) { videoFrames += 1 }
        case .audio:
            // Audio before the first picture would start the file with sound and no image, so it is dropped.
            guard let start = sessionStart, sampleBuffer.presentationTimeStamp >= start else { return }
            // Count timing problems in the audio the system hands over: a gap or overlap between buffers is heard as a click.
            let pts = sampleBuffer.presentationTimeStamp
            if let expected = nextAudioPTS {
                let delta = (pts - expected).seconds
                if abs(delta) > 0.001 { audioTimingFaults += 1; if audioTimingFaults <= 10 { print("AUDIO_TIMING_FAULT at \(String(format: "%.3f", (pts - start).seconds))s off by \(String(format: "%.1f", delta * 1000)) ms") } }
            }
            nextAudioPTS = pts + sampleBuffer.duration
            if audio.isReadyForMoreMediaData, audio.append(sampleBuffer) { audioBuffers += 1 }
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("capture stopped: \(error.localizedDescription)\n".utf8))
    }

    func finish() async -> Bool {
        try? await stream?.stopCapture()
        return await withCheckedContinuation { continuation in
            queue.async {
                guard self.sessionStart != nil else { continuation.resume(returning: false); return }
                self.video.markAsFinished()
                self.audio.markAsFinished()
                self.writer.finishWriting {
                    print("RECORDED video_frames=\(self.videoFrames) audio_buffers=\(self.audioBuffers) audio_timing_faults=\(self.audioTimingFaults)")
                    continuation.resume(returning: self.writer.status == .completed)
                }
            }
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let content: SCShareableContent
do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
catch { fail("Could not list windows (\(error.localizedDescription)). Allow Screen Recording for this terminal in System Settings > Privacy & Security.") }

// The app's biggest window is its HUD.
var target: SCWindow?
for _ in 0..<25 {
    let found = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    target = found.windows.filter { $0.owningApplication?.processID == pid && $0.frame.width > 400 }
        .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    if target != nil { break }
    try await Task.sleep(for: .milliseconds(200))
}
guard let window = target else { fail("No window found for process \(pid).") }

let filter = SCContentFilter(desktopIndependentWindow: window)
let scale = Double(filter.pointPixelScale)
let width = Int(window.frame.width * scale) / 2 * 2
let height = Int(window.frame.height * scale) / 2 * 2

let configuration = SCStreamConfiguration()
configuration.width = width
configuration.height = height
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
configuration.pixelFormat = kCVPixelFormatType_32BGRA
configuration.showsCursor = false
configuration.capturesAudio = true
configuration.sampleRate = 48_000
configuration.channelCount = 2
configuration.excludesCurrentProcessAudio = true
configuration.ignoreShadowsSingleWindow = true
let background = CGColor(gray: 0, alpha: 1)   // the property does not retain it, so keep our own reference
configuration.backgroundColor = background

let recorder: Recorder
do { recorder = try Recorder(url: outURL, width: width, height: height) } catch { fail("Could not create the file: \(error.localizedDescription)") }
do { try await recorder.begin(filter: filter, configuration: configuration) } catch { fail("Could not start capture: \(error.localizedDescription)") }
print("RECORDING \(width)x\(height)")

// Stop on the time limit or on SIGINT/SIGTERM.
var signalSources: [DispatchSourceSignal] = []
let stop = AsyncStream<Void> { continuation in
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { continuation.yield(); continuation.finish() }
        source.resume()
        signalSources.append(source)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds) { continuation.yield(); continuation.finish() }
}
for await _ in stop { break }

let ok = await recorder.finish()
exit(ok ? 0 : 1)
