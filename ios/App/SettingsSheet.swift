import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var client: RemoteClient
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop().ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GlowPanel(title: "PAIRED MAC") {
                            VStack(alignment: .leading, spacing: 6) {
                                row("Name", model.pairing?.name ?? "—")
                                row("Address", model.pairing.map { "\($0.host):\($0.port)" } ?? "—")
                                row("Connection", stateText)
                                row("This device", client.deviceName)
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
                    .padding(16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showSettings = false } } }
        }
        .preferredColorScheme(.dark)
    }

    private var stateText: String {
        switch client.state {
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
