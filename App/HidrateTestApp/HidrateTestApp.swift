import HidrateKit
import SwiftUI

@main
struct HidrateTestApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
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

/// The tabs, with the launch splash over them until it has finished. The splash's state
/// lives in a view rather than in the `App`: `withAnimation` on `@State` declared on an
/// `App` doesn't animate.
struct RootView: View {
    @State private var tab = Tab.launchTab
    @State private var contentAppeared = false
    @State private var splashFinished = false

    enum Tab: String {
        case today, progress

        /// Dev only: launch with `-startTab progress` to open straight onto a tab, for
        /// looking at one in the Simulator without walking to it.
        static var launchTab: Tab {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-startTab"), i + 1 < args.count else { return .today }
            return Tab(rawValue: args[i + 1]) ?? .today
        }
    }

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                TodayView()
                    .tabItem { Label("Today", systemImage: "drop.fill") }
                    .tag(Tab.today)
                HistoryView()
                    .tabItem { Label("Progress", systemImage: "chart.bar.fill") }
                    .tag(Tab.progress)
            }
            .tint(.blue)
            .onAppear { contentAppeared = true }

            if !splashFinished {
                LaunchSplash(isReady: contentAppeared, onFinished: { splashFinished = true })
                    .transition(.identity)
            }
        }
    }
}
