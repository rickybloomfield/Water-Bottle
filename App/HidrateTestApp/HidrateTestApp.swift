import HidrateKit
import SwiftUI

@main
struct HidrateTestApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView()
                    .tabItem { Label("Today", systemImage: "drop.fill") }
                HistoryView()
                    .tabItem { Label("Progress", systemImage: "chart.bar.fill") }
                BottleTabView()
                    .tabItem { Label("Bottle", systemImage: "waterbottle") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            .tint(.blue)
            .environment(app)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                app.model.client.nudgeReconnect()
                Task { await app.refreshHealthTotal() }
            }
        }
    }
}
