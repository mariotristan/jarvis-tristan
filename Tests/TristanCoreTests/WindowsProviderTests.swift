#if os(Windows)
import XCTest
import WinSDK
@testable import TristanCore

/// Plan Tasks 13–16 on a real Windows machine: each provider's command-line tool is found and started through
/// `ProcessLauncher` (npm `.cmd` shims, the `az.cmd` batch file, `aws`), against the fakes in scripts/ci/fakes, and,
/// where the runner has them, against the real `az` and `aws`.
final class WindowsProviderTests: XCTestCase {
    private var folder: URL!
    private var fakes: FakeCLIs!
    private var savedNoKeychain = false

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-winprov-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fakes = FakeCLIs()
        savedNoKeychain = NoKeychain.enabled
        NoKeychain.enabled = true   // no Credential Manager entry may decide these tests (one test turns it off itself)
    }

    override func tearDown() {
        fakes.restore()
        NoKeychain.enabled = savedNoKeychain
        try? FileManager.default.removeItem(at: folder)
    }

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func code(_ events: [AgentEvent]) -> String {
        events.compactMap { event -> String? in if case .code(let text) = event { return text } else { return nil } }.joined()
    }

    private func final(_ events: [AgentEvent]) -> String {
        for event in events.reversed() {
            if case .done(let text) = event { return "done: \(text)" }
            if case .failed(let text) = event { return "failed: \(text)" }
        }
        return "none"
    }

    /// Runs a program to the end with the fakes off PATH (the runner's real tools), returning stdout and stderr.
    private func runReal(_ tool: String, _ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, out: String, err: String) {
        let process = try ProcessLauncher.prepare(tool, arguments, directory: folder, extraEnvironment: environment)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // stderr is drained on its own thread so a full pipe can never stall the program.
        let errDone = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var errData = Data()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        let outText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        errDone.wait()
        process.waitUntilExit()
        return (process.terminationStatus, outText, String(decoding: errData, as: UTF8.self))
    }

    // MARK: - Azure OpenAI (Task 13)

    func testAzureTokenComesFromAzCmdThroughCmdExe() async throws {
        let az = try XCTUnwrap(ProcessLauncher.locate("az"))
        XCTAssertEqual(az.lowercased(), (FakeCLIs.folder + "\\az.cmd").lowercased(), "az must be the batch file, started through cmd.exe")
        let token = try await AzureAuth.azureCLIToken()
        XCTAssertEqual(token, "fake-az-token-0123456789", "the CR LF az prints must be trimmed")
    }

    func testAzureNotLoggedInThroughFakeAz() async {
        fakes.set("FAKE_AZ_LOGGED_OUT", "1")
        do {
            _ = try await AzureAuth.azureCLIToken()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not logged in"), error.localizedDescription)
        }
    }

    func testMissingAzOnWindowsSaysWinget() async {
        fakes.set("Path", "C:\\tristan-no-such-folder")
        do {
            _ = try await AzureAuth.azureCLIToken()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("winget install -e --id Microsoft.AzureCLI"), error.localizedDescription)
        }
    }

    /// The runner's real Azure CLI (az.cmd running Python) is not logged in: the answer must be "not logged in", which
    /// proves az.cmd was found and run with these arguments, not "not found".
    func testRealAzureCLIIsFoundAndAnswers() async throws {
        fakes.restore()
        guard ProcessLauncher.locate("az") != nil else { throw XCTSkip("the Azure CLI is not installed") }
        do {
            let token = try await AzureAuth.azureCLIToken()
            XCTAssertFalse(token.isEmpty)   // a logged-in machine
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "No API key is set and the Azure CLI is not logged in. Run `az login`, or add an API key in Configuration.")
        }
    }

    func testAzureProviderUsesTheAzTokenOverHTTP() async throws {
        let client = AzureStub.start()
        defer { AzureStub.stop() }
        let events = await collect(AzureOpenAIProvider(mode: .ask, client: client).run(task: "write hello.txt", workingDirectory: folder) { _ in true })
        XCTAssertTrue(final(events).hasPrefix("done"), final(events))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("hello.txt"), encoding: .utf8), "hi from azure")
        XCTAssertEqual(AzureStub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fake-az-token-0123456789")
        XCTAssertNil(AzureStub.requests.first?.value(forHTTPHeaderField: "api-key"))
        XCTAssertTrue(code(events).contains("hello.txt written."), code(events))
    }

    /// The key stored in Credential Manager wins over az. Any key already stored on this machine is put back.
    func testAzureAPIKeyFromCredentialManager() async throws {
        NoKeychain.enabled = false
        let previous = KeychainStore.get(AzureConfig.keychainAccount)
        defer { KeychainStore.set(previous ?? "", account: AzureConfig.keychainAccount) }
        XCTAssertTrue(KeychainStore.set("cred-manager-key", account: AzureConfig.keychainAccount))
        let client = AzureStub.start()
        defer { AzureStub.stop() }
        let events = await collect(AzureOpenAIProvider(mode: .yolo, client: client).run(task: "write hello.txt", workingDirectory: folder) { _ in true })
        XCTAssertTrue(final(events).hasPrefix("done"), final(events))
        XCTAssertEqual(AzureStub.requests.first?.value(forHTTPHeaderField: "api-key"), "cred-manager-key")
        XCTAssertNil(AzureStub.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    /// Windows' own `cmdkey` stores a generic credential's password as UTF-16; `KeychainStore` must read it as text.
    func testKeyStoredWithCmdkeyIsReadable() throws {
        NoKeychain.enabled = false
        let account = "tristan-test-cmdkey-\(UUID().uuidString.prefix(6))"
        let target = "com.tristan.app/\(account)"
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        func cmdkey(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: root + "\\System32\\cmdkey.exe")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        // A throwaway test value; a real key should never be typed on a command line.
        XCTAssertEqual(try cmdkey(["/generic:\(target)", "/user:tristan", "/pass:abc-123-XYZ"]), 0)
        defer { _ = try? cmdkey(["/delete:\(target)"]) }
        // What cmdkey wrote: 11 characters as UTF-16 are 22 bytes.
        var credential: PCREDENTIALW? = nil
        if target.withCString(encodedAs: UTF16.self, { CredReadW($0, DWORD(1), 0, &credential) }), let credential {
            let size = Int(credential.pointee.CredentialBlobSize)
            CredFree(UnsafeMutableRawPointer(credential))
            print("cmdkey stored a \(size)-byte blob for an 11-character password")
            XCTAssertEqual(size, 22, "cmdkey stores UTF-16")
        } else {
            XCTFail("cmdkey's credential was not found")
        }
        XCTAssertEqual(KeychainStore.get(account), "abc-123-XYZ")
        // What tristan writes itself (UTF-8) still reads back unchanged.
        XCTAssertTrue(KeychainStore.set("utf8-value", account: account))
        XCTAssertEqual(KeychainStore.get(account), "utf8-value")
        XCTAssertEqual(WindowsCredentialStore.decode(Array("ab".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), "ab")
        XCTAssertEqual(WindowsCredentialStore.decode(Array("ab".utf8)), "ab")
    }

    // MARK: - Bedrock (Task 14)

    private var bedrockConfig: BedrockConfig { BedrockConfig(model: "anthropic.fake-model-v1:0", region: "us-east-1", profile: "") }

    func testBedrockCLIFallbackSendsAWindowsFileURL() async throws {
        let log = folder.appendingPathComponent("argv.jsonl")
        fakes.set("FAKE_ARGV_LOG", FakeCLIs.native(log))
        let response = try await AWSCLIConverseClient(config: bedrockConfig).converse(
            ["messages": [["role": "user", "content": [["text": "say hello"]]]]])
        let content = (((response["output"] as? [String: Any])?["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        XCTAssertEqual(content.first?["text"] as? String, "Hello from fake Bedrock.")
        let call = try XCTUnwrap(FakeCLIs.argvLog(log).first { $0.tool == "aws" })
        let input = try XCTUnwrap(call.argv.firstIndex(of: "--cli-input-json").map { call.argv[$0 + 1] })
        XCTAssertTrue(input.range(of: #"\Afile://[A-Za-z]:/[^\\]+/request\.json\z"#, options: .regularExpression) != nil, input)
    }

    func testBedrockCredentialsFromFakeAWSWithCRLF() async throws {
        let credentials = try await AWSCLICredentials(profile: "").credentials()
        XCTAssertEqual(credentials.accessKey, "AKIAFAKEFAKEFAKEFAKE")
        XCTAssertEqual(credentials.secretKey, "fake/secret/key")
        XCTAssertEqual(credentials.sessionToken, "fake-session-token")
        XCTAssertNotNil(credentials.expiration)
    }

    func testBedrockErrorsFromTheCLIAreExplained() async {
        do {
            _ = try await AWSCLIConverseClient(config: BedrockConfig(model: "bad-model", region: "us-east-1", profile: "")).converse(
                ["messages": [["role": "user", "content": [["text": "x"]]]]])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Bedrock rejected the model id"), error.localizedDescription)
        }
        fakes.set("FAKE_AWS_NO_CREDENTIALS", "1")
        do {
            _ = try await AWSCLICredentials(profile: "").credentials()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AWS credentials are missing or expired"), error.localizedDescription)
        }
    }

    func testBedrockProviderAnswersThroughTheCLIFallback() async throws {
        fakes.set("FAKE_AWS_NO_CREDENTIALS", "1")   // streaming cannot sign, so the CLI answers
        let prompts = Counter()
        let client = FallbackConverseClient(primary: BedrockStreamingClient(config: bedrockConfig, credentialProvider: AWSCLICredentials(profile: "")),
                                            fallback: AWSCLIConverseClient(config: bedrockConfig))
        let events = await collect(BedrockProvider(mode: .ask, client: client).run(task: "write hello.txt", workingDirectory: folder) { _ in
            prompts.add(); return true
        })
        XCTAssertEqual(final(events), "done: Bedrock fake: finished after the tool ran.")
        XCTAssertEqual(prompts.value, 1)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("hello.txt"), encoding: .utf8), "hi from bedrock")
    }

    /// How the real AWS CLI v2 on the runner takes `--cli-input-json file://...` with a Windows path. The request
    /// goes to a closed local port, so a parse failure and a connection failure are told apart by the message.
    func testRealAWSCLIReadsTheWindowsFileURL() throws {
        fakes.restore()
        guard ProcessLauncher.locate("aws") != nil else { throw XCTSkip("the AWS CLI is not installed") }
        let request = folder.appendingPathComponent("request.json")
        try Data(#"{"modelId":"anthropic.fake-model-v1:0","messages":[{"role":"user","content":[{"text":"hi"}]}]}"#.utf8).write(to: request)
        let environment = ["AWS_ACCESS_KEY_ID": "AKIAFAKEFAKEFAKEFAKE", "AWS_SECRET_ACCESS_KEY": "fake-secret", "AWS_MAX_ATTEMPTS": "1",
                           "AWS_EC2_METADATA_DISABLED": "true", "AWS_CONFIG_FILE": FakeCLIs.native(folder.appendingPathComponent("none-config")),
                           "AWS_SHARED_CREDENTIALS_FILE": FakeCLIs.native(folder.appendingPathComponent("none-credentials"))]
        func converse(_ input: String) throws -> (Int32, String) {
            let result = try runReal("aws", ["bedrock-runtime", "converse", "--cli-input-json", input, "--region", "us-east-1",
                                             "--endpoint-url", "http://127.0.0.1:9", "--cli-connect-timeout", "2", "--output", "json"],
                                     environment: environment)
            return (result.status, result.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let native = FakeCLIs.native(request)
        let ours = AWSCLIConverseClient.inputArgument(for: native, windows: true)
        let (status, message) = try converse(ours)
        print("aws converse with \(ours): exit \(status): \(message)")
        XCTAssertNotEqual(status, 0)
        // "Could not connect to the endpoint URL" or "Connect timeout on endpoint URL": either way the file was read.
        XCTAssertTrue(message.contains("endpoint URL: \"http://127.0.0.1:9/model/"), "the file must be read before connecting: \(message)")
        XCTAssertFalse(message.contains("paramfile"), message)
        // Recorded for the spike notes, not asserted: the other spellings.
        for other in ["file://" + native, "file:///" + native.replacingOccurrences(of: "\\", with: "/")] {
            let (otherStatus, otherMessage) = try converse(other)
            print("aws converse with \(other): exit \(otherStatus): \(otherMessage.prefix(200))")
        }

        // The real `aws configure export-credentials` output (CR LF on Windows) parses.
        let exported = try runReal("aws", ["configure", "export-credentials", "--format", "process"], environment: environment)
        print("aws configure export-credentials: exit \(exported.status), CR LF: \(exported.out.contains("\r\n")), \(exported.out.count) chars")
        XCTAssertEqual(exported.status, 0, exported.err)
        let credentials = try AWSCredentials.parse(Data(exported.out.utf8))
        XCTAssertEqual(credentials.accessKey, "AKIAFAKEFAKEFAKEFAKE")
        XCTAssertEqual(credentials.secretKey, "fake-secret")
    }

    // MARK: - Copilot (Task 15)

    /// cmd.exe would expand `%PATH%` and act on `&`, `^` and quotes; through the parsed npm shim node gets them as is.
    private let trickyTask = #"say "hi" & echo 100% %PATH% ^caret café 日本"#

    func testCopilotRunsThroughTheNpmShimWithTheTaskUnchanged() async throws {
        let log = folder.appendingPathComponent("argv.jsonl")
        fakes.set("FAKE_ARGV_LOG", FakeCLIs.native(log))
        let events = await collect(CopilotProvider(mode: .yolo, model: "").run(task: trickyTask, workingDirectory: folder) { _ in true })
        XCTAssertTrue(final(events).hasPrefix("done: ") && final(events).hasSuffix("Final answer: hello from fake copilot"), final(events))
        let text = code(events)
        XCTAssertTrue(text.contains("TASK<\(trickyTask)>\n"), text)
        XCTAssertTrue(text.contains("Working on it\n"), "ANSI codes stripped: \(text)")
        XCTAssertFalse(text.contains("\r") || text.contains("\u{1B}"), text.debugDescription)
        XCTAssertTrue(text.contains("tools: all"), text)
        let call = try XCTUnwrap(FakeCLIs.argvLog(log).first { $0.tool == "copilot" })
        XCTAssertEqual(call.argv[0...1], ["-p", trickyTask])
        let logDir = try XCTUnwrap(call.argv.firstIndex(of: "--log-dir").map { call.argv[$0 + 1] })
        XCTAssertTrue(logDir.contains("\\tristan-copilot-logs-"), logDir)
        // Removed when the provider's task ends, just after the stream finishes.
        XCTAssertTrue(FakeCLIs.eventually(5) { !FileManager.default.fileExists(atPath: logDir) }, "the log folder is removed after the run")
    }

    func testCopilotAskModeApprovalGatesTheRun() async {
        let denied = await collect(CopilotProvider(mode: .ask, model: "").run(task: "list files", workingDirectory: folder) { _ in false })
        XCTAssertEqual(final(denied), "failed: Denied by operator")
        XCTAssertTrue(code(denied).isEmpty)
        let allowed = await collect(CopilotProvider(mode: .ask, model: "").run(task: "list files", workingDirectory: folder) { _ in true })
        XCTAssertTrue(final(allowed).hasPrefix("done: ") && final(allowed).hasSuffix("Final answer: hello from fake copilot"), final(allowed))
    }

    func testCopilotFailureReportsStderr() async {
        let events = await collect(CopilotProvider(mode: .yolo, model: "").run(task: "please fail", workingDirectory: folder) { _ in true })
        XCTAssertEqual(final(events), "failed: Error: fake copilot is not logged in")
    }

    /// A copilot.cmd that is not an npm shim cannot be resolved to node, so cmd.exe would see the task: refused.
    func testCopilotUnparsedShimRefusesUnsafeTask() async throws {
        let other = folder.appendingPathComponent("other-copilot", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("@ECHO off\r\nCALL \"%~dp0real-copilot.bat\" %*\r\n".utf8).write(to: other.appendingPathComponent("copilot.cmd"))
        fakes.set("Path", FakeCLIs.native(other) + ";" + (FakeCLIs.get("PATH") ?? ""))
        let events = await collect(CopilotProvider(mode: .yolo, model: "").run(task: "fix a & b", workingDirectory: folder) { _ in true })
        XCTAssertEqual(final(events), "failed: Could not launch the Copilot CLI safely: refusing to pass text containing % ^ & | < > \" "
                       + "or a line break to copilot through cmd.exe. Remove those characters from the task and retry.")
        XCTAssertFalse(events.contains { if case .status("ONLINE") = $0 { return true } else { return false } })
    }

    func testCopilotNotInstalledSaysNpm() async {
        fakes.set("Path", "C:\\tristan-no-such-folder")
        let events = await collect(CopilotProvider(mode: .yolo, model: "").run(task: "x", workingDirectory: folder) { _ in true })
        XCTAssertTrue(final(events).contains("npm install -g @github/copilot"), final(events))
        XCTAssertTrue(final(events).contains("Node.js"), final(events))
    }

    // MARK: - Claude Code (Task 16)

    func testClaudeRunsThroughTheNpmShimAndParsesCRLFStreamJSON() async throws {
        let log = folder.appendingPathComponent("argv.jsonl")
        fakes.set("FAKE_ARGV_LOG", FakeCLIs.native(log))
        let events = await collect(ClaudeCodeProvider(mode: .yolo).run(task: trickyTask, workingDirectory: folder) { _ in false })
        XCTAssertEqual(final(events), "done: created hello.txt")
        XCTAssertTrue(code(events).contains("Task: \(trickyTask)\n"), code(events))
        XCTAssertTrue(events.contains { if case .log("Session started") = $0 { return true } else { return false } })
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("hello.txt"), encoding: .utf8), "hi")
        let call = try XCTUnwrap(FakeCLIs.argvLog(log).first { $0.tool == "claude" })
        XCTAssertEqual(call.argv[0...1], ["-p", trickyTask])
    }

    func testClaudeFailureAndNotFound() async {
        let failed = await collect(ClaudeCodeProvider(mode: .yolo).run(task: "please fail", workingDirectory: folder) { _ in false })
        XCTAssertEqual(final(failed), "failed: fake claude failed on purpose")
        fakes.set("Path", "C:\\tristan-no-such-folder")
        let missing = await collect(ClaudeCodeProvider(mode: .yolo).run(task: "x", workingDirectory: folder) { _ in false })
        XCTAssertTrue(final(missing).contains("Git for Windows"), final(missing))
    }

    // MARK: - Cancel stops the whole tree (review focus 5)

    private func checkCancelStopsTree(_ stream: @escaping () -> AsyncStream<AgentEvent>) async throws {
        let pidFile = folder.appendingPathComponent("pids-\(UUID().uuidString.prefix(6)).txt")
        fakes.set("FAKE_PID_FILE", FakeCLIs.native(pidFile))
        let consumer = Task { for await _ in stream() {} }
        XCTAssertTrue(FakeCLIs.eventually(20) { FakeCLIs.pids(in: pidFile) != nil }, "the fake never wrote its pids")
        let pids = try XCTUnwrap(FakeCLIs.pids(in: pidFile))
        XCTAssertTrue(pids.allSatisfy(FakeCLIs.isAlive))
        consumer.cancel()
        _ = await consumer.value
        XCTAssertTrue(FakeCLIs.eventually(10) { !pids.contains(where: FakeCLIs.isAlive) }, "still running after cancel: \(pids.filter(FakeCLIs.isAlive))")
    }

    func testCancelStopsCopilotTree() async throws {
        try await checkCancelStopsTree { CopilotProvider(mode: .yolo, model: "").run(task: "sleep", workingDirectory: self.folder) { _ in true } }
    }

    func testCancelStopsClaudeTree() async throws {
        try await checkCancelStopsTree { ClaudeCodeProvider(mode: .yolo).run(task: "sleep", workingDirectory: self.folder) { _ in true } }
    }

    func testCancelStopsTheAWSCLITree() async throws {
        let config = bedrockConfig
        try await checkCancelStopsTree {
            BedrockProvider(mode: .yolo, client: AWSCLIConverseClient(config: config)).run(task: "sleep", workingDirectory: self.folder) { _ in true }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
#endif
