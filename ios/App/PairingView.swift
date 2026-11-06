import SwiftUI

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var mission: MissionModel
    @State private var showScanner = false
    @State private var showManual = false
    @State private var host = ""
    @State private var port = ""
    @State private var secret = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ReactorView(active: false, size: 120).padding(.top, 40)
                Text("T.R.I.S.T.A.N.")
                    .font(.system(size: 22, weight: .bold, design: .monospaced)).tracking(6)
                    .foregroundStyle(Theme.cyan).shadow(color: Theme.cyan, radius: 6)
                Text("Pair with the Tristan app on your Mac")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.amber)

                GlowPanel(title: "ON YOUR MAC") {
                    VStack(alignment: .leading, spacing: 8) {
                        step("1", "Open Tristan, then Configuration (the gear).")
                        step("2", "Switch REMOTE CONTROL on.")
                        step("3", "Scan the QR code below, or copy the link and paste it here.")
                    }
                }
                .frame(maxHeight: 150)

                VStack(spacing: 12) {
                    hudButton("SCAN QR CODE", tint: Theme.cyan) { showScanner = true }
                    hudButton("PASTE PAIRING LINK", tint: Theme.amber) { pasteLink() }
                    hudButton("USE WITHOUT A MAC", tint: Theme.green) { mission.mode = .standalone }
                    Button { withAnimation { showManual.toggle() } } label: {
                        Text(showManual ? "HIDE MANUAL ENTRY" : "ENTER DETAILS BY HAND")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.7))
                    }
                }

                if showManual {
                    VStack(spacing: 10) {
                        field("Mac address (for example my-mac.local or 192.168.1.20)", text: $host, keyboard: .URL)
                        field("Port", text: $port, keyboard: .numberPad)
                        field("Pairing secret (64 characters)", text: $secret, keyboard: .asciiCapable)
                        hudButton("PAIR", tint: Theme.green) { pairManually() }
                    }
                    .padding(14)
                    .overlay(Rectangle().stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
                }

                if let error = model.pairingError {
                    Text(error).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.red).multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showScanner) {
            ZStack(alignment: .topTrailing) {
                QRScanner { code in
                    showScanner = false
                    if let url = URL(string: code) { model.handle(url: url) } else { model.pairingError = "That QR code is not a Tristan pairing code." }
                }
                .ignoresSafeArea()
                Button("Close") { showScanner = false }.padding().buttonStyle(.borderedProminent)
            }
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.amber)
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.85))
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard)
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan)
            .padding(10).overlay(Rectangle().stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
    }

    private func pasteLink() {
        guard let text = UIPasteboard.general.string, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            model.pairingError = "The clipboard does not hold a pairing link. Copy it from the Mac first."
            return
        }
        model.handle(url: url)
    }

    private func pairManually() {
        guard PairingLink.isPlausibleHost(host), let portNumber = UInt16(port), portNumber > 0, let data = PairingSecret.data(fromHex: secret) else {
            model.pairingError = "Check the address, the port and that the secret is 64 hex characters."
            return
        }
        model.pair(PairingLink(name: host, host: host, port: portNumber, secret: data))
    }
}
