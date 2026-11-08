import ArgumentParser
import Foundation
import TristanCore

/// The five providers, named as on the command line. Built exactly as the Mac app builds them.
enum CLIProvider: String, CaseIterable, ExpressibleByArgument {
    case claude, copilot, bedrock, azure, ollama

    func make(mode: ApprovalMode) -> AgentProvider {
        switch self {
        case .claude: return ClaudeCodeProvider(mode: mode)
        case .copilot: return CopilotProvider(mode: mode)
        case .bedrock: return BedrockProvider.standard(mode: mode)
        case .azure: return AzureOpenAIProvider(mode: mode)
        case .ollama: return OllamaProvider(mode: mode)
        }
    }
}
