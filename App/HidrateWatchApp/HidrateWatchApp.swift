import SwiftUI
import WatchKit

/// Starts the phone link at launch, so a background wake-up — a snapshot pushed for the
/// complication — is picked up without waiting for someone to open the app.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        MainActor.assumeIsolated { WatchHydrationModel.shared.start() }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            MainActor.assumeIsolated {
                WatchHydrationModel.shared.refresh()
                HydrationStore.reloadWidgets()
            }
            task.setTaskCompletedWithSnapshot(false)
        }
    }
}

@main
struct HidrateWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var model = WatchHydrationModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchTodayView()
                .environment(model)
                .task { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }
}
