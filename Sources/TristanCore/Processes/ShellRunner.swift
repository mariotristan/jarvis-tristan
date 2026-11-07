import Foundation

/// Builds the command line that runs a piece of shell text.
package enum ShellRunner {
    /// `isAvailable` says whether a program name resolves on PATH; it decides between `pwsh` and Windows PowerShell.
    package static func command(for text: String, flavor: ShellFlavor,
                                isAvailable: (String) -> Bool = ShellRunner.isOnPath) -> (tool: String, arguments: [String]) {
        switch flavor {
        case .posix:
            return ("/bin/zsh", ["-c", text])
        case .powershell:
            let tool = isAvailable("pwsh") ? "pwsh" : "powershell.exe"
            return (tool, ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", text])
        }
    }

    package static func isOnPath(_ name: String) -> Bool {
        (try? ProcessLauncher.prepare(name, [], directory: nil, extraEnvironment: [:])) != nil
    }
}
