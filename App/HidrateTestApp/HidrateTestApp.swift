import HidrateKit
import SwiftUI

@main
struct HidrateTestApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared
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
            switch phase {
            case .active:
                app.reloadPersistedBottleState()
                app.model.client.nudgeReconnect()
                // Drinks tapped in the widget, water logged elsewhere in Health.
                Task { await app.catchUp() }
            case .background:
                // Leave a refresh queued so the widget and the watch keep moving.
                AppDelegate.scheduleRefresh()
            default:
                break
            }
        }
    }
}
