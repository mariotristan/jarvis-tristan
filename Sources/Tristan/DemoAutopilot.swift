import Foundation

/// `Tristan --demo` plays this scenario by itself so a screen recording needs no hands: a task with the big orb and its
/// effects, the microphone refusing to start while Tristan answers, the orb filling the screen, then kids safe mode with
/// the parent unlock. `--manual` turns it off. Prints DEMO_DONE when it is finished.
@MainActor
enum DemoAutopilot {
    static func run(on session: Session) async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

        func type(_ text: String) async {
            session.draft = ""
            for character in text {
                session.draft.append(character)
                await pause(0.05)
            }
            await pause(0.5)
            let task = session.draft
            session.draft = ""
            session.submit(task)
        }

        /// Waits for the mission to end, approving whatever it asks for after a moment so the prompt is visible.
        func finish() async {
            for _ in 0..<400 {
                if session.pending != nil { await pause(1.5); session.resolve(true) }
                if !session.busy { return }
                await pause(0.1)
            }
        }

        // Never drive a real agent: every task below goes to the stand-in provider.
        guard session.provider == .demo else { print("DEMO_ABORT provider is \(session.provider.rawValue), not DEMO"); fflush(stdout); return }
        await pause(3)
        session.orbEffects = .full
        session.orbFillsScreen = false
        await type("write a README for this folder")
        await pause(3)
        session.startListening()          // refused: the microphone is shut while Tristan answers
        await finish()
        await pause(2.5)

        session.orbFillsScreen = true
        await type("now add tests for it")
        await finish()
        await pause(2)
        session.orbFillsScreen = false
        await pause(1.5)

        ParentPIN.set("2468")
        session.parentAuth = .pin
        session.kidsMode = true
        await pause(2)
        session.openSettings()            // asks for the parent PIN
        await pause(3.5)
        _ = session.submitParentPIN("2468")
        await pause(4)
        session.kidsMode = false
        session.closeSettings()
        await pause(2.5)

        print("DEMO_DONE")
        fflush(stdout)
    }
}
