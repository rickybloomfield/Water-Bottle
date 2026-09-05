import BackgroundTasks
import HidrateKit
import UIKit

/// Keeps the app useful while it isn't on screen.
///
/// Three things wake it: CoreBluetooth restoring the bottle connection, WatchConnectivity
/// delivering a drink from the wrist, and HealthKit reporting water logged by another app.
/// All three need `AppState` to exist before the UI does, which is what this delegate is
/// for. On top of them, a periodic refresh catches whatever slipped through — drinks tapped
/// on the widget, a bottle whose connection went stale.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTaskIdentifier = "com.rickybloomfield.HidrateTestApp.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Building it here rather than waiting for the first view means a background
        // launch still re-creates the central manager and activates the watch session.
        let app = AppState.shared
        if launchOptions?[.bluetoothCentrals] != nil {
            app.sessionLog.write("relaunched by CoreBluetooth")
        }

        // Registration has to happen before this method returns.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { task in
            Self.handle(task)
        }
        return true
    }

    private static func handle(_ task: BGTask) {
        // Ask for the next one first: if this pass is cut short, the chain still continues.
        scheduleRefresh()
        let work = Task { @MainActor in
            await AppState.shared.backgroundRefresh()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Ask for a pass in about fifteen minutes. iOS decides when it actually runs, based
    /// on how the app is used; asking more often than this does not make it any sooner.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Not one refresh has run in days of logs; if the ask itself is refused, say so.
            let reason = "\(error)"
            Task { @MainActor in AppState.shared.sessionLog.write("background refresh not scheduled: \(reason)") }
        }
    }
}
