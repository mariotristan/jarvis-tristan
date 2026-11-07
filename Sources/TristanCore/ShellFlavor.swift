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

    /// The flavor whose rules apply to an approval-rule tool name, or nil for tools that are not shells.
    package init?(ruleToolName: String) {
        switch ruleToolName {
        case "Bash": self = .posix
        case "PowerShell": self = .powershell
        default: return nil
        }
    }
}

// MARK: - Approval policy

extension ShellFlavor {
    /// Programs whose name alone is never turned into an Always-allow rule.
    /// The POSIX list is the Mac's list, unchanged. PowerShell keeps it and adds Windows names.
    package var neverGeneralise: Set<String> {
        switch self {
        case .posix: return Self.posixNeverGeneralise
        case .powershell: return Self.posixNeverGeneralise.union(Self.windowsNeverGeneralise)
        }
    }

    /// Text that makes a command more than one plain program call, so it always asks.
    /// PowerShell matches these case-insensitively (`-EncodedCommand`).
    package var operators: [String] {
        switch self {
        case .posix: return Self.posixOperators
        case .powershell: return Self.posixOperators + Self.powershellOperators
        }
    }

    private static let posixNeverGeneralise: Set<String> = [
        "rm", "sudo", "dd", "chmod", "chown", "mv", "kill", "killall", "shred", "mkfs", "diskutil",
        "launchctl", "curl", "wget", "sh", "bash", "zsh", "eval", "exec", "ssh", "scp", "env", "xargs",
    ]

    private static let posixOperators = [";", "&", "|", ">", "<", "`", "$(", "\n", "\\"]

    private static let windowsNeverGeneralise: Set<String> = [
        // The Task 8 brief's list.
        "del", "erase", "rd", "rmdir", "remove-item", "ri", "invoke-expression", "iex", "invoke-webrequest", "iwr",
        "invoke-restmethod", "irm", "curl", "curl.exe", "wget", "powershell", "pwsh", "cmd", "reg", "format",
        "taskkill", "stop-process", "start-process", "set-executionpolicy", "net", "netsh", "schtasks", "sc",
        "bitsadmin", "certutil", "mshta", "wscript", "cscript", "rundll32", "regsvr32", "ssh", "scp", "sh", "bash",
        "env", "xargs",
        // Windows counterparts of Mac entries the brief's list does not name, so Windows asks wherever the Mac
        // would: mv, kill, sudo, chmod/chown, shred, mkfs/diskutil, launchctl, exec/eval, sh, and `>`.
        "move", "mi", "move-item", "spps", "start", "saps", "invoke-item", "ii", "invoke-command", "icm",
        "start-job", "sajb", "add-type", "wsl", "runas", "gsudo", "icacls", "cacls", "takeown", "attrib", "cipher",
        "sdelete", "diskpart", "mountvol", "bcdedit", "vssadmin", "shutdown", "restart-computer", "stop-computer",
        "wmic", "msiexec", "net1", "register-scheduledtask", "new-service", "set-service", "start-bitstransfer",
        "invoke-wmimethod", "invoke-cimmethod", "set-content", "add-content", "ac", "out-file", "clear-content",
        "clc", "set-itemproperty", "sp", "remove-itemproperty", "rp",
        // Fix round 1: more counterparts (mv, mkfs/diskutil, launchctl, chmod) and launchers.
        "ren", "rni", "rename-item", "format-volume", "clear-disk", "initialize-disk", "remove-partition",
        "stop-service", "spsv", "remove-service", "restart-service", "set-acl", "conhost", "explorer", "forfiles",
        "wt", "pwsh-preview",
        // PowerShell keywords: as a first word they start a statement, not a program call
        // (`return 'C:/x' -as [IO.StreamWriter]` creates a file; `using module` loads code).
        "return", "throw", "exit", "break", "continue", "using", "data", "trap", "filter", "function", "param",
        "begin", "process", "end", "dynamicparam", "switch", "foreach", "for", "while", "do", "until", "if", "try",
        "class", "enum", "configuration", "workflow", "parallel", "sequence", "inlinescript",
    ]

    /// `(` and `[` are not in the brief's list but are needed: in PowerShell `git (Remove-Item x)` runs Remove-Item,
    /// and `[IO.StreamWriter]` type literals reach .NET. `-encodedcommand` is also caught by its abbreviations
    /// (see `hasEncodedCommandFlag`).
    private static let powershellOperators = ["$", "{", "}", "@(", "(", "[", "-encodedcommand", "\r"]

    /// True if any space-separated word is `-EncodedCommand` or an abbreviation PowerShell accepts for it
    /// (`-e`, `-ec`, `-en`, `-enc`, ... `-encodedcommand`), with `-`, en dash, em dash or horizontal bar, any case,
    /// with or without a `:value` suffix. Over-matching (`git -e`) only makes the command ask.
    static func hasEncodedCommandFlag(_ text: String) -> Bool {
        let dashes: Set<Character> = ["-", "\u{2013}", "\u{2014}", "\u{2015}"]
        return text.split(separator: " ").contains { word in
            guard let first = word.first, dashes.contains(first) else { return false }
            let name = word.dropFirst().prefix { $0 != ":" }.lowercased()
            return !name.isEmpty && ("encodedcommand".hasPrefix(name) && name.hasPrefix("e") || name == "ec")
        }
    }

    /// True if the text holds a character PowerShell might read as a statement separator or hide: any control
    /// character (tab included; a plain command uses spaces), or any non-ASCII whitespace, separator or format
    /// character (U+0085, U+00A0, U+2028, U+2029, U+3000, U+200B-U+200F, U+FEFF, ...).
    static func hasUnsafeCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            if s.value < 0x20 || s.value == 0x7F { return true }
            if s.isASCII { return false }
            switch s.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator: return true
            default: return s.properties.isWhitespace
            }
        }
    }

    /// Extensions Windows runs a program through (PATHEXT plus `.ps1`), stripped before the name is compared.
    /// Broader than `.exe .cmd .bat .ps1` on purpose: `format.com` is the real `format`.
    private static let programExtensions = [
        ".exe", ".com", ".cmd", ".bat", ".ps1", ".vbs", ".vbe", ".js", ".jse", ".wsf", ".wsh", ".msc", ".cpl",
        ".scr", ".pif",
    ]

    /// The name a command's first word is compared and keyed by, or nil if it is not a plain program name.
    /// Without Windows rules this is today's check, unchanged. With them the name is lower-cased, program
    /// extensions are stripped (repeatedly), and the name must start with an ASCII letter: a leading `-`, digit,
    /// `_` or dot puts PowerShell in expression mode (`-join ...`, `1..9`) or dot-sources a script (`. x.ps1`).
    /// Names ending with a dot (`rm.`) are refused.
    static func programName(_ word: String, windowsRules: Bool) -> String? {
        guard word.range(of: #"\A[A-Za-z0-9._-]+\z"#, options: .regularExpression) != nil else { return nil }
        guard windowsRules else { return word }
        guard let first = word.unicodeScalars.first, ("a"..."z").contains(first) || ("A"..."Z").contains(first) else {
            return nil
        }
        var name = word.lowercased()
        guard !name.hasPrefix("."), !name.hasSuffix(".") else { return nil }
        while let ext = programExtensions.first(where: { name.hasSuffix($0) }) {
            name.removeLast(ext.count)
        }
        guard !name.isEmpty, !name.hasSuffix(".") else { return nil }
        return name
    }
}
