import SwiftUI

@main
struct TristanApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.mission)
                .preferredColorScheme(.dark)
                .onOpenURL { model.handle(url: $0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var mission: MissionModel

    var body: some View {
        ZStack {
            Backdrop().ignoresSafeArea()
            if mission.mode == .remote && model.pairing == nil { PairingView() } else { MissionView() }
        }
        .sheet(isPresented: $model.showHistory) { HistoryView() }
        .sheet(isPresented: $model.showSettings) { SettingsSheet() }
    }
}
