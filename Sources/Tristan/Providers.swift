import Foundation
import TristanCore

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude = "CLAUDE"
    case copilot = "COPILOT"
    case bedrock = "BEDROCK"
    case azure = "AZURE"
    case ollama = "OLLAMA"
    case demo = "DEMO"

    var id: String { rawValue }

    func makeProvider(mode: ApprovalMode) -> AgentProvider? {
        switch self {
        case .claude: return ClaudeCodeProvider(mode: mode)
        case .bedrock: return BedrockProvider.standard(mode: mode)
        case .demo: return DemoProvider(skipApproval: mode == .yolo)
        case .azure: return AzureOpenAIProvider(mode: mode)
        case .copilot: return CopilotProvider(mode: mode)
        case .ollama: return OllamaProvider(mode: mode)
        }
    }

    /// The model a mission on this provider will use, for the HUD, as exactly as can be known without running one.
    /// Claude Code leaves the choice to its command: a model pinned in its settings wins, then the one it reported
    /// last time (`remembered`), then "default". Ollama shows the installed model it will pick when `installed` is known.
    /// `setting` reads a saved setting by key, so tests need no real settings.
    func modelLabel(setting: (String) -> String? = { Settings.string($0) }, remembered: String? = nil,
                    pinned: String? = nil, installed: [String]? = nil) -> String {
        func value(_ key: String) -> String? {
            let text = (setting(key) ?? "").trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        switch self {
        case .claude: return pinned ?? remembered ?? "default"
        case .copilot: return value("copilot.model") ?? "default"
        case .bedrock: return value("bedrock.model") ?? BedrockConfig.defaultModel
        case .azure: return value("azure.deployment") ?? "not set"
        case .ollama:
            guard let installed else { return value("ollama.model") ?? "auto" }
            return OllamaStatus.resolveModel(chosen: value("ollama.model") ?? "", installed: installed) ?? "none installed"
        case .demo: return "scripted"
        }
    }

    /// A model that the user pinned for Claude Code, in `ANTHROPIC_MODEL` or the `model` key of its settings file.
    static func claudePinnedModel(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  settingsFile: URL = FileManager.default.homeDirectoryForCurrentUser
                                      .appendingPathComponent(".claude/settings.json")) -> String? {
        if let env = environment["ANTHROPIC_MODEL"]?.trimmingCharacters(in: .whitespaces), !env.isEmpty { return env }
        guard let data = try? Data(contentsOf: settingsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        return model
    }
}

/// Scripted provider so the HUD can be played with without spending tokens.
/// Scripted answers for the recorded demo (`Tristan --demo --kids`), matched by a few words in the question.
enum DemoAnswers {
    /// The prompt may carry the session's memory briefing in front; the question itself follows "Current task:".
    static func question(in prompt: String) -> String {
        guard let marker = prompt.range(of: "Current task:", options: .backwards) else { return prompt }
        return prompt[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func answer(for task: String) -> String? {
        let q = task.lowercased()
        if q.contains("times") || q.contains("7 x 8") {
            return "## 7 × 8 = 56\n\nHere is a trick: **5, 6, 7, 8**.\n\n- Say it in order: *five, six, seven, eight*\n- That gives you **56 = 7 × 8**\n\nTry **7 × 9** next. What do you think it is?\n"
        }
        if q.contains("sky") {
            return "## Why is the sky blue?\n\nSunlight looks white, but it is made of **all the colors** of the rainbow.\n\n- Light bumps into the tiny bits of air\n- **Blue** light bounces around the most\n- So blue comes at your eyes from every part of the sky\n\nAt sunset the light travels farther, so we see **red and orange** instead.\n"
        }
        if q.contains("planet") {
            return "## The biggest planet is **Jupiter**\n\n- It is so big that **1,300 Earths** could fit inside it\n- It has a giant storm called the **Great Red Spot**\n- It has at least **95 moons**\n\n> Fun fact: a day on Jupiter is only about 10 hours long!\n"
        }
        if q.contains("spider") || q.contains("insect") {
            return "## Is a spider an insect?\n\n**No!** A spider is an *arachnid*.\n\n| | Insect | Spider |\n|:--|:--:|:--:|\n| Legs | 6 | 8 |\n| Body parts | 3 | 2 |\n| Antennae | yes | no |\n\nCount the legs and you can always tell.\n"
        }
        return nil
    }
}

struct DemoProvider: AgentProvider {
    /// YOLO skips every permission check, the demo's one prompt included.
    var skipApproval = false

    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            let worker = Task {
                func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
                // School-style questions get a scripted, friendly answer and need no approval.
                let question = DemoAnswers.question(in: task)
                if let answer = DemoAnswers.answer(for: question) {
                    c.yield(.status("THINKING"))
                    c.yield(.log("Question received: \(question)"))
                    await pause(2200)
                    c.yield(.status("ANSWERING"))
                    for ch in answer {
                        if Task.isCancelled { c.finish(); return }
                        c.yield(.code(String(ch)))
                        await pause(16)
                    }
                    await pause(800)
                    c.yield(.done("Answered"))
                    c.finish()
                    return
                }
                c.yield(.status("PLANNING"))
                c.yield(.log("Task received: \(question)"))
                await pause(900)
                guard !Task.isCancelled else { c.finish(); return }
                c.yield(.log("Scanning \(workingDirectory.lastPathComponent)"))
                await pause(900)
                guard !Task.isCancelled else { c.finish(); return }
                c.yield(.status("AWAITING AUTHORIZATION"))
                let ok = skipApproval ? true : await approve(ApprovalRequest(summary: "Write Sources/auth.ts", detail: "Create a new file in \(workingDirectory.path)"))
                guard ok else { c.yield(.failed("Denied by operator")); c.finish(); return }
                c.yield(.status("WRITING CODE"))
                c.yield(.log("Writing Sources/auth.ts"))
                let intro = "## Adding login\n\nI'll create **Sources/auth.ts** with a `login` function:\n"
                let snippet = intro + CodeFence.block(path: "Sources/auth.ts", content: """
                import { sign } from "./jwt";

                export function login(user: User): string {
                  const token = sign({ sub: user.id, role: user.role });
                  audit("login", user.id);
                  return token;
                }
                """)
                for ch in snippet {
                    if Task.isCancelled { c.finish(); return }
                    c.yield(.code(String(ch)))
                    await pause(18)
                }
                c.yield(.status("RUNNING TESTS"))
                c.yield(.log("npm test: 12 passed"))
                await pause(1200)
                c.yield(.done("1 file changed, tests green"))
                c.finish()
            }
            c.onTermination = { _ in worker.cancel() }
        }
    }
}
