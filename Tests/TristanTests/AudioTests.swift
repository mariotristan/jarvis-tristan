import XCTest
import AVFoundation
@testable import Tristan
@testable import TristanCore

@MainActor
final class AudioTests: XCTestCase {
    func testEveryCueSynthesisesAudibleUnclippedAudio() throws {
        let fx = SoundFX()
        for cue in Cue.allCases {
            let buffer = try XCTUnwrap(fx.buffer(for: cue), "\(cue) produced no buffer")
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            let peak = samples.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.05, "\(cue) is silent")
            XCTAssertLessThanOrEqual(peak, 1.0, "\(cue) clips")
            XCTAssertTrue(samples.allSatisfy { $0.isFinite }, "\(cue) has invalid samples")
            XCTAssertLessThan(Double(buffer.frameLength) / 44_100, 2.0, "\(cue) is too long for a UI sound")
        }
    }

    func testVoiceLinesAreNeverEmpty() {
        for lines in [SoundFX.startLines, SoundFX.approvalLines, SoundFX.doneLines, SoundFX.failLines] {
            XCTAssertFalse(lines.isEmpty)
            XCTAssertTrue(lines.allSatisfy { !$0.isEmpty })
        }
    }

    func testDisabledSoundAndVoiceDoNothing() {
        let fx = SoundFX()
        fx.soundsOn = false
        fx.voiceOn = false
        fx.play(.missionComplete)   // must not start the audio engine or crash
        fx.say("Silent")
    }
}
