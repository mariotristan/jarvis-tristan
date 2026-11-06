import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var client: RemoteClient
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var filter: HistoryFilter = .all

    private var shown: [MissionRecord] { client.history.filtered(query: query, status: filter) }
    private var busy: Bool { client.snapshot?.phase == .working || client.snapshot?.phase == .awaitingApproval }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop().ignoresSafeArea()
                VStack(spacing: 10) {
                    TextField("Search missions", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.cyan)
                        .padding(10).overlay(Rectangle().stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
                    Picker("", selection: $filter) {
                        ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if shown.isEmpty {
                        Text(client.history.isEmpty ? "No missions yet." : "Nothing matches.")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5)).padding(.top, 30)
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(spacing: 8) { ForEach(shown) { row($0) } }
                        }
                    }
                }
                .padding(14)
            }
            .navigationTitle("Mission history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showHistory = false } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { client.requestHistory() }
    }

    private func row(_ record: MissionRecord) -> some View {
        let tint: Color = record.status == "done" ? Theme.green : record.status == "failed" ? Theme.red : Theme.amber
        return HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.task).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.cyan).lineLimit(2)
                Text(record.summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.6)).lineLimit(2)
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.provider) · \(record.mode)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.4))
            }
            Spacer()
            hudButton("RE-RUN", tint: Theme.cyan) {
                client.setProvider(record.provider)
                client.submit(record.task)
                model.showHistory = false
            }
            .disabled(busy)
        }
        .padding(8).overlay(Rectangle().stroke(Theme.cyan.opacity(0.25), lineWidth: 1))
    }
}
