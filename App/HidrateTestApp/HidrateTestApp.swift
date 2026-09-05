import HidrateKit
import SwiftUI

@main
struct HidrateTestApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared
    @State private var tab = Tab.launchTab
    @Environment(\.scenePhase) private var scenePhase

    enum Tab: String {
        case today, progress, bottle, settings

        /// Dev only: launch with `-startTab settings` to open straight onto a tab, for
        /// looking at one in the Simulator without walking to it.
        static var launchTab: Tab {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-startTab"), i + 1 < args.count else { return .today }
            return Tab(rawValue: args[i + 1]) ?? .today
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                TodayView()
                    .tabItem { Label("Today", systemImage: "drop.fill") }
                    .tag(Tab.today)
                HistoryView()
                    .tabItem { Label("Progress", systemImage: "chart.bar.fill") }
                    .tag(Tab.progress)
                BottleTabView()
                    .tabItem { Label("Bottle", systemImage: "waterbottle") }
                    .tag(Tab.bottle)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
                    .tag(Tab.settings)
            }
            .tint(.blue)
            .environment(app)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                app.reloadPersistedBottleState()
                // Coming back to the app is exactly when you might have picked up the
                // other bottle.
                app.reconsiderTheClosestBottle()
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
