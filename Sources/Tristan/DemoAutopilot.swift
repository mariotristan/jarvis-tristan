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

    /// The kids version: Paw Patrol theme, kids safe mode on, school questions, and a try at Settings that needs a parent.
    static func runKids(on session: Session) async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func type(_ text: String) async {
            session.draft = ""
            for character in text {
                session.draft.append(character)
                await pause(0.06)
            }
            await pause(0.6)
            let task = session.draft
            session.draft = ""
            session.submit(task)
        }
        func finish() async {
            for _ in 0..<400 {
                if !session.busy { return }
                await pause(0.1)
            }
        }
        guard session.provider == .demo else { print("DEMO_ABORT provider is \(session.provider.rawValue), not DEMO"); fflush(stdout); return }

        session.themeChoice = "pawpatrol"
        session.orbEffects = .full
        session.orbFillsScreen = false
        ParentPIN.set("2468")
        session.parentAuth = .pin
        session.kidsMode = true
        await pause(4)

        await type("What is 7 times 8?")
        await pause(3)
        session.startListening()          // refused while Tristan answers
        await finish()
        await pause(3)

        await type("Why is the sky blue?")
        await finish()
        await pause(3)

        // The orb takes over the screen while the biggest question is answered.
        session.orbFillsScreen = true
        await type("What is the biggest planet?")
        await finish()
        session.orbFillsScreen = false
        await pause(3)

        // Trying to change settings (or switch on YOLO) needs a parent.
        session.openSettings()
        await pause(2.5)
        _ = session.submitParentPIN("1234")   // wrong guess
        await pause(2.5)
        session.cancelParentPrompt()
        await pause(1.5)

        await type("Is a spider an insect?")
        await finish()
        await pause(4)

        print("DEMO_DONE")
        fflush(stdout)
    }
}
