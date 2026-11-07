import Foundation

/// Which shell the agent's `run_command` tool talks to: zsh on the Mac, PowerShell on Windows.
package enum ShellFlavor {
    case posix, powershell

    package static var current: ShellFlavor {
        #if os(Windows)
        return .powershell
        #else
        return .posix
        #endif
    }

    /// The tool name approval rules use for shell commands.
    package var ruleToolName: String {
        switch self {
        case .posix: return "Bash"
        case .powershell: return "PowerShell"
        }
    }
}
