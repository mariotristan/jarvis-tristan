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

/// An argument is the empty string. Foundation.Process on Windows leaves it out of the command line, which would
/// silently shift every argument after it, so the launch is refused instead.
package struct EmptyArgument: Error, Equatable, LocalizedError {
    package let tool: String
    package init(tool: String) { self.tool = tool }
    package var errorDescription: String? {
        "refusing to start \(tool) with an empty argument: Windows would drop it and shift the arguments after it"
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
    /// Throws `ToolNotFound` or (Windows only) `UnsafeArguments` or `EmptyArgument`.
    /// `addToolPaths: false` leaves the environment inherited exactly as the parent has it (extra variables still apply).
    package static func prepare(_ tool: String, _ arguments: [String], directory: URL?, extraEnvironment: [String: String],
                                addToolPaths: Bool = true) throws -> Process {
        let plan = try plan(tool, arguments, environment: ProcessInfo.processInfo.environment, windows: isWindows,
                            isFile: isLaunchable, readFile: readText)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        if addToolPaths {
            process.environment = plan.environment.merging(extraEnvironment) { _, extra in extra }
        } else if !extraEnvironment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, extra in extra }
        }
        if let directory { process.currentDirectoryURL = directory }
        return process
    }

    /// The program `prepare` would start for `tool`, or nil when it is not installed (`tristan providers` uses this).
    package static func locate(_ tool: String) -> String? {
        try? plan(tool, [], environment: ProcessInfo.processInfo.environment, windows: isWindows,
                  isFile: isLaunchable, readFile: readText).executable
    }

    /// Resolves `tool` the way `prepare` does, with the file system passed in.
    static func plan(_ tool: String, _ arguments: [String], environment: [String: String], windows: Bool,
                     isFile: (String) -> Bool, readFile: (String) -> String?) throws -> Plan {
        if windows, arguments.contains(where: \.isEmpty) { throw EmptyArgument(tool: tool) }
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

    /// How a file is named on a command line: `url.path` on the Mac and Linux; on Windows the file system's own
    /// spelling (`C:\Users\...`), which other programs can open whatever form Foundation's `path` takes there.
    package static func nativePath(_ url: URL) -> String {
        #if os(Windows)
        return url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
        #else
        return url.path
        #endif
    }

    /// Creates a scratch folder for a provider run (logs, request files). On the Mac and Linux only the owner may open
    /// it (mode 0700). Windows has no mode bits: the folder lives in the user's own temp folder, whose access list
    /// already limits it to that user (and administrators), so no attributes are passed there.
    package static func createPrivateFolder(_ url: URL, windows: Bool = isWindows) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: windows ? nil : [.posixPermissions: 0o700])
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

/// Holds a process that is created after cancellation handlers are installed, so a cancel that arrives first, or while
/// the process is starting, still stops it (with its children). Live boxes are registered so a command-line Ctrl+C
/// can stop every provider process at once.
package final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: ProcessBox] = [:]

    package init() {}

    /// Starts the process unless the box was already cancelled; false means it was not started. `run()` happens under
    /// the box's lock, so a `terminate()` racing with the start waits for it and then stops the started process.
    /// Attach pipes and handlers before calling this.
    package func start(_ process: Process) throws -> Bool {
        try start(process, launch: { try $0.run() })
    }

    /// `launch` starts the process; tests slow it down to land a cancel in the middle.
    func start(_ process: Process, launch: (Process) throws -> Void) throws -> Bool {
        lock.lock()
        guard !cancelled else { lock.unlock(); return false }
        do { try launch(process) } catch { lock.unlock(); throw error }
        self.process = process
        lock.unlock()
        // Registered outside the box's lock: pruning takes other boxes' locks, never while holding this one.
        Self.registryLock.lock()
        Self.live = Self.live.filter { $0.value.isRunning }
        Self.live[ObjectIdentifier(self)] = self
        Self.registryLock.unlock()
        return true
    }

    /// Pruning keeps a cancelled box until its process is gone, so `terminateAll()` still reaches a tree whose
    /// background kill has not finished.
    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Stops the process and its descendants (or keeps it from ever starting). Returns at once: the tree is killed
    /// on a background queue, because cancels arrive on the caller's thread (the Mac app's main thread on Abort).
    package func terminate() {
        guard let process = cancel() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessTree.terminate(process)
            self.unregister()
        }
    }

    /// Like `terminate()`, but returns only once the tree has been stopped. For paths that exit the process next.
    package func terminateAndWait() {
        guard let process = cancel() else { return }
        ProcessTree.terminate(process)
        unregister()
    }

    private func cancel() -> Process? {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        return process
    }

    private func unregister() {
        Self.registryLock.lock()
        Self.live[ObjectIdentifier(self)] = nil
        Self.registryLock.unlock()
    }

    /// Stops every running box and waits until their trees are gone (the command-line tool's Ctrl+C, before exiting).
    package static func terminateAll() {
        registryLock.lock()
        let boxes = Array(live.values)
        registryLock.unlock()
        for box in boxes { box.terminateAndWait() }
    }
}
