import Foundation

/// The tool is not on `PATH` (with Homebrew's folders added on the Mac, `PATHEXT` suffixes tried on Windows).
package struct ToolNotFound: Error, Equatable, LocalizedError {
    package let name: String
    package init(name: String) { self.name = name }
    package var errorDescription: String? { "\(name) was not found on PATH" }
}

/// The tool is a Windows `.cmd`/`.bat` file that cannot be resolved to its real program, and an argument contains
/// characters cmd.exe would interpret. Refusing is the only safe choice: cmd.exe re-parses the whole command line.
package struct UnsafeArguments: Error, Equatable, LocalizedError {
    package let tool: String
    package init(tool: String) { self.tool = tool }
    package var errorDescription: String? {
        "refusing to pass text containing % ^ & | < > \" or a line break to \(tool) through cmd.exe"
    }
}

/// Finds a program on a search path. Pure, so Windows rules are testable anywhere.
package enum ExecutableResolver {
    /// A name containing a path separator is returned as is. On Windows a name without one of the `pathExt` suffixes
    /// is tried with each suffix in order, folder by folder; the current folder is never searched.
    package static func resolve(_ name: String, searchPath: [String], pathExt: [String], isFile: (String) -> Bool, windows: Bool) -> String? {
        if hasSeparator(name, windows: windows) { return name }
        guard !name.isEmpty else { return nil }
        let candidates: [String]
        if windows {
            let ext = fileExtension(name).uppercased()
            candidates = !ext.isEmpty && pathExt.contains(where: { $0.uppercased() == ext }) ? [name] : pathExt.map { name + $0.lowercased() }
        } else {
            candidates = [name]
        }
        for folder in searchPath where !folder.isEmpty {
            for candidate in candidates {
                let full = join(folder, candidate, windows: windows)
                if isFile(full) { return full }
            }
        }
        return nil
    }

    static func hasSeparator(_ name: String, windows: Bool) -> Bool {
        name.contains("/") || (windows && name.contains("\\"))
    }

    static func join(_ folder: String, _ name: String, windows: Bool) -> String {
        if windows {
            return folder.hasSuffix("\\") || folder.hasSuffix("/") ? folder + name : folder + "\\" + name
        }
        return folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// `.cmd` for `C:\npm\copilot.cmd`; empty when the last component has no dot.
    static func fileExtension(_ path: String) -> String {
        let last = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
        return String(last[dot...])
    }
}

/// cmd.exe expands `%VAR%`, treats `^ & | < >` as syntax and `"` as quoting, and ends a command at a line break.
/// Any of them in an argument handed to a `.cmd`/`.bat` file could run something else.
package enum CmdShimGuard {
    static let unsafe: Set<Character> = ["%", "^", "&", "|", "<", ">", "\"", "\n", "\r", "\r\n"]

    package static func isSafe(_ arguments: [String]) -> Bool {
        !arguments.contains { argument in
            argument.contains(where: { unsafe.contains($0) }) || argument.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        }
    }
}

/// Reads the `.cmd` shims npm writes for global packages (`copilot.cmd`, `claude.cmd`), so the real `node <script>`
/// can be launched directly and cmd.exe never sees the arguments.
package enum CmdShim {
    // "%_prog%" (current npm), "%dp0%\node.exe" / "%~dp0\node.exe" (older npm) or a bare node, then the quoted script
    // relative to the shim's folder, then %*.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:"%_prog%"|"%~?dp0%?\\node\.exe"|(?<![\w.\\])node(?:\.exe)?)\s+"%~?dp0%?\\([^"%\r\n]+\.(?:js|cjs|mjs))"\s+%\*"#,
        options: [.caseInsensitive])

    /// The full path of the script the shim runs with node, or nil when the text is not a node shim.
    package static func nodeScript(shimText: String, shimPath: String) -> String? {
        let range = NSRange(shimText.startIndex..., in: shimText)
        guard let match = pattern.firstMatch(in: shimText, range: range),
              let relative = Range(match.range(at: 1), in: shimText) else { return nil }
        return folder(of: shimPath) + "\\" + shimText[relative]
    }

    static func folder(of path: String) -> String {
        guard let cut = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return "." }
        return String(path[..<cut])
    }
}

/// The one place CLI tools (`claude`, `copilot`, `aws`, `az`, ...) are started from.
package enum ProcessLauncher {
    /// What to start; `environment` is the full environment before the caller's extra variables.
    struct Plan: Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    #if os(Windows)
    static let isWindows = true
    #else
    static let isWindows = false
    #endif

    /// A configured process that has not been started. Callers attach pipes and call `run()`.
    /// Throws `ToolNotFound` or (Windows only) `UnsafeArguments`.
    package static func prepare(_ tool: String, _ arguments: [String], directory: URL?, extraEnvironment: [String: String]) throws -> Process {
        let plan = try plan(tool, arguments, environment: ProcessInfo.processInfo.environment, windows: isWindows,
                            isFile: isLaunchable, readFile: readText)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = plan.environment.merging(extraEnvironment) { _, extra in extra }
        if let directory { process.currentDirectoryURL = directory }
        return process
    }

    /// Resolves `tool` the way `prepare` does, with the file system passed in.
    static func plan(_ tool: String, _ arguments: [String], environment: [String: String], windows: Bool,
                     isFile: (String) -> Bool, readFile: (String) -> String?) throws -> Plan {
        var environment = environment
        if !windows {
            // Same PATH the app always gave its tools: an app started from the Dock has a short one.
            environment["PATH"] = macPATH(inherited: environment["PATH"])
        }
        let search = searchPath(value(of: "PATH", in: environment, windows: windows) ?? "", windows: windows)
        let extensions = windows ? pathExtensions(value(of: "PATHEXT", in: environment, windows: true)) : []
        guard let executable = ExecutableResolver.resolve(tool, searchPath: search, pathExt: extensions, isFile: isFile, windows: windows) else {
            throw ToolNotFound(name: tool)
        }
        guard windows else { return Plan(executable: executable, arguments: arguments, environment: environment) }

        let ext = ExecutableResolver.fileExtension(executable).lowercased()
        guard ext == ".cmd" || ext == ".bat" else { return Plan(executable: executable, arguments: arguments, environment: environment) }

        if let text = readFile(executable), let script = CmdShim.nodeScript(shimText: text, shimPath: executable) {
            // node itself must be a real program: a node.cmd/node.bat earlier on PATH would put cmd.exe back in the middle.
            let local = CmdShim.folder(of: executable) + "\\node.exe"
            let node = isFile(local) ? local
                : ExecutableResolver.resolve("node", searchPath: search, pathExt: [".EXE", ".COM"], isFile: isFile, windows: true)
            if let node { return Plan(executable: node, arguments: [script] + arguments, environment: environment) }
            // No real node: the shim finds its own (or fails), so treat it like any other batch file.
        }
        guard CmdShimGuard.isSafe(arguments) else { throw UnsafeArguments(tool: tool) }
        return Plan(executable: executable, arguments: arguments, environment: environment)
    }

    static func macPATH(inherited: String?) -> String {
        "/opt/homebrew/bin:/usr/local/bin:" + (inherited ?? "/usr/bin:/bin")
    }

    /// On Windows only absolute folders are kept (`C:\x`, `C:/x`, `\\server\share`): a relative entry such as `.` or `bin`
    /// would let a tool planted in the working folder be picked.
    static func searchPath(_ path: String, windows: Bool) -> [String] {
        path.split(separator: windows ? ";" : ":", omittingEmptySubsequences: true).map { entry in
            var folder = String(entry)
            if windows, folder.count >= 2, folder.hasPrefix("\""), folder.hasSuffix("\"") { folder = String(folder.dropFirst().dropLast()) }
            return folder
        }.filter { !$0.isEmpty && (!windows || isAbsoluteWindowsPath($0)) }
    }

    static func isAbsoluteWindowsPath(_ path: String) -> Bool {
        if path.hasPrefix("\\\\") || path.hasPrefix("//") { return true }
        let chars = Array(path)
        return chars.count >= 3 && chars[0].isASCII && chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/")
    }

    static func pathExtensions(_ value: String?) -> [String] {
        let parsed = (value ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parsed.isEmpty ? [".COM", ".EXE", ".BAT", ".CMD"] : parsed
    }

    /// Windows environment names ignore case (`Path` is common).
    static func value(of name: String, in environment: [String: String], windows: Bool) -> String? {
        if let exact = environment[name] { return exact }
        guard windows else { return nil }
        return environment.first { $0.key.uppercased() == name.uppercased() }?.value
    }

    private static func isLaunchable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        #if os(Windows)
        return true
        #else
        return FileManager.default.isExecutableFile(atPath: path)
        #endif
    }

    private static func readText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count < 64 * 1024 else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// Holds a process that is created after cancellation handlers are installed, so a cancel that arrives first still
/// stops it (or stops it from being used at all).
package final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    package init() {}

    /// Stores the process. False when the box was already cancelled; the caller should then not start it.
    package func set(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        return !cancelled
    }

    package func terminate() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}
