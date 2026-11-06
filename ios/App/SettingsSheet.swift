import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var mission: MissionModel
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop().ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        modePicker
                        if mission.mode == .remote { remoteSection } else { StandaloneSettings() }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showSettings = false } } }
        }
        .preferredColorScheme(.dark)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHERE DO MISSIONS RUN?")
                .font(.system(size: 10, design: .monospaced)).tracking(2).foregroundStyle(Theme.cyan.opacity(0.7))
            Picker("", selection: Binding(get: { mission.mode }, set: { model.use($0) })) {
                Text("ON MY MAC").tag(MissionModel.Mode.remote)
                Text("ON THIS DEVICE").tag(MissionModel.Mode.standalone)
            }
            .pickerStyle(.segmented)
            Text(mission.mode == .remote
                 ? "Tristan on your Mac does the work with Claude Code, Copilot, Bedrock or Azure. This device is the remote."
                 : "This device talks straight to Azure OpenAI or Bedrock and can read and write files in one folder. It cannot run commands or tests.")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.6))
        }
    }

    @ViewBuilder private var remoteSection: some View {
        GlowPanel(title: "PAIRED MAC") {
            VStack(alignment: .leading, spacing: 6) {
                row("Name", model.pairing?.name ?? "—")
                row("Address", model.pairing.map { "\($0.host):\($0.port)" } ?? "—")
                row("Connection", stateText)
                row("This device", mission.deviceName)
                row("Protocol", "version \(remoteProtocolVersion)")
            }
        }
        .frame(height: 180)

        HStack(spacing: 10) {
            hudButton("RECONNECT", tint: Theme.cyan) { model.connect() }
            if confirmUnpair {
                hudButton("CONFIRM UNPAIR", tint: Theme.red) { confirmUnpair = false; model.showSettings = false; model.unpair() }
            } else {
                hudButton("UNPAIR", tint: Theme.amber) { confirmUnpair = true }
            }
        }
        Text("Unpairing removes the secret from this device's Keychain. To lock out every device at once, use NEW SECRET in the Mac's Remote settings.")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))

        GlowPanel(title: "GOOD TO KNOW") {
            Text("Approvals only reach this device while Tristan is open in front. iOS pauses background apps, so keep it open during a mission. The Mac must be awake and on the same network (or reachable over a VPN such as Tailscale).")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.7))
        }
        .frame(height: 150)
    }

    private var stateText: String {
        switch mission.remote.state {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .disconnected: return "disconnected"
        case .failed(let message): return "failed — \(message)"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5)).frame(width: 90, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan)
        }
    }
}

/// Provider details for missions that run on this device. Secrets go to the Keychain, never to preferences.
struct StandaloneSettings: View {
    @EnvironmentObject var mission: MissionModel
    @AppStorage("azure.endpoint") private var azureEndpoint = ""
    @AppStorage("azure.deployment") private var azureDeployment = ""
    @AppStorage("azure.apiVersion") private var azureAPIVersion = ""
    @AppStorage("bedrock.region") private var bedrockRegion = ""
    @AppStorage("bedrock.model") private var bedrockModel = ""
    @State private var azureKey = ""
    @State private var awsKeyID = ""
    @State private var awsSecret = ""
    @State private var awsToken = ""
    @State private var stored = Stored()

    struct Stored { var azure = false; var aws = false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GlowPanel(title: "AZURE OPENAI") {
                VStack(alignment: .leading, spacing: 8) {
                    field("Endpoint", $azureEndpoint, "https://my-resource.openai.azure.com", keyboard: .URL)
                    field("Deployment name", $azureDeployment, "gpt-4o")
                    field("API version", $azureAPIVersion, AzureConfig.defaultAPIVersion)
                    secret("API key \(stored.azure ? "(saved in the Keychain)" : "")", $azureKey)
                    HStack(spacing: 8) {
                        hudButton("SAVE KEY", tint: Theme.green) {
                            if !azureKey.isEmpty { KeychainStore.set(azureKey, account: AzureConfig.keychainAccount) }
                            azureKey = ""
                            reload()
                        }
                        if stored.azure { hudButton("REMOVE", tint: Theme.red) { KeychainStore.set("", account: AzureConfig.keychainAccount); reload() } }
                    }
                }
            }
            .frame(minHeight: 330)

            GlowPanel(title: "AWS BEDROCK") {
                VStack(alignment: .leading, spacing: 8) {
                    field("Region", $bedrockRegion, "us-east-1")
                    field("Model id", $bedrockModel, BedrockConfig.defaultModel)
                    secret("Access key id \(stored.aws ? "(saved)" : "")", $awsKeyID)
                    secret("Secret access key", $awsSecret)
                    secret("Session token (recommended for temporary keys)", $awsToken)
                    HStack(spacing: 8) {
                        hudButton("SAVE KEYS", tint: Theme.green) {
                            if !awsKeyID.isEmpty { KeychainStore.set(awsKeyID, account: KeychainAWSCredentials.accessKeyAccount) }
                            if !awsSecret.isEmpty { KeychainStore.set(awsSecret, account: KeychainAWSCredentials.secretKeyAccount) }
                            KeychainStore.set(awsToken, account: KeychainAWSCredentials.sessionTokenAccount)
                            awsKeyID = ""; awsSecret = ""; awsToken = ""
                            reload()
                        }
                        if stored.aws {
                            hudButton("REMOVE", tint: Theme.red) {
                                for account in [KeychainAWSCredentials.accessKeyAccount, KeychainAWSCredentials.secretKeyAccount, KeychainAWSCredentials.sessionTokenAccount] {
                                    KeychainStore.set("", account: account)
                                }
                                reload()
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 450)

            GlowPanel(title: "CONVERSATION") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(mission.local.memory.isEmpty
                         ? "Tristan has nothing to remember yet. Missions you run in the same folder build on each other."
                         : "Tristan remembers \(mission.local.memory.exchanges.count) earlier mission(s) and uses them as context for the next one.")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.7))
                    hudButton("NEW CONVERSATION", tint: Theme.amber) { mission.local.forgetConversation() }
                }
            }
            .frame(minHeight: 130)

            GlowPanel(title: "GOOD TO KNOW") {
                Text("Keys stay in this device's Keychain and are only sent to Azure or AWS. Use an AWS key that can only call Bedrock, and prefer temporary keys with a session token over long-lived ones. Files live in Workspace (visible in the Files app under Tristan) or in a folder you pick. There is no shell here, so Tristan cannot run commands or tests.")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.7))
            }
            .frame(minHeight: 170)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        stored.azure = KeychainStore.get(AzureConfig.keychainAccount)?.isEmpty == false
        stored.aws = KeychainStore.get(KeychainAWSCredentials.accessKeyAccount)?.isEmpty == false
    }

    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan)
                .padding(8).overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
        }
    }

    private func secret(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
            SecureField("Paste it here", text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan)
                .padding(8).overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
        }
    }
}
