import SwiftUI
import WatchConnectivity
import WatchKit

/// Starts the phone link at launch, so a background wake-up — a snapshot pushed for the
/// complication — is picked up without waiting for someone to open the app.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// Connectivity tasks are handed over before the session has delivered what woke us,
    /// and completing one suspends the app with the payload still in flight — which is
    /// how a complication transfer arrived, woke the app, and was never received. They
    /// are held here until the session says nothing is pending, or a deadline passes.
    private var connectivityTasks: [WKWatchConnectivityRefreshBackgroundTask] = []

    func applicationDidFinishLaunching() {
        // Hopped rather than asserted: `assumeIsolated` traps outright if watchOS ever
        // calls this off the main actor, and a trap at launch is a crash on launch.
        Task { @MainActor in
            DiagnosticLog.write("applicationDidFinishLaunching \(AppVersion.short) app=\(DiagnosticLog.appState)")
            let model = WatchHydrationModel.shared
            model.onConnectivityActivity = { [weak self] in self?.settleConnectivityTasks(reason: "delivery") }
            model.start()
            Self.scheduleNextRefresh()
        }
    }

    /// Ask watchOS to wake us now and then, as a safety net for a delivery that never
    /// woke the app on its own. Launching runs `start()`, which activates the session and
    /// takes whatever the phone has been holding; adopting that reloads the complication
    /// only if the face would change, so the wake itself costs nothing from the budget.
    @MainActor
    static func scheduleNextRefresh(after interval: TimeInterval = 60 * 60) {
        let date = Date().addingTimeInterval(interval)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date, userInfo: nil) { error in
            DiagnosticLog.write("scheduleBackgroundRefresh for \(DiagnosticLog.stamp(date)): \(error.map { "error \($0)" } ?? "ok")")
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        let kinds = backgroundTasks.map { String(describing: type(of: $0)) }.sorted().joined(separator: ",")
        DiagnosticLog.write("handle tasks=[\(kinds)] app=\(DiagnosticLog.appState)")
        let model = WatchHydrationModel.shared
        model.refresh()
        // Only an app-refresh task earns the next one; a snapshot task is watchOS asking
        // for a picture, not a turn to do work.
        if backgroundTasks.contains(where: { $0 is WKApplicationRefreshBackgroundTask }) {
            model.reloadComplicationIfNeeded(reason: "background refresh")
            Self.scheduleNextRefresh()
        }
        for task in backgroundTasks {
            switch task {
            case let snapshot as WKSnapshotRefreshBackgroundTask:
                // A snapshot task has its own completion and raises if finished with the
                // general one — and watchOS schedules a snapshot right after launching
                // the app from a complication, which is exactly when this was crashing.
                snapshot.setTaskCompleted(restoredDefaultState: true,
                                          estimatedSnapshotExpiration: .distantFuture,
                                          userInfo: nil)
            case let connectivity as WKWatchConnectivityRefreshBackgroundTask:
                connectivityTasks.append(connectivity)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        guard !connectivityTasks.isEmpty else { return }
        // Not settled at the handover even when nothing is reported pending: the context
        // that woke the app has been seen to land a tenth of a second later, with
        // `hasContentPending` already false. A delivery settles them; failing that, a
        // short grace period does, and failing everything the deadline.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.settleConnectivityTasks(reason: "grace period")
            try? await Task.sleep(for: .seconds(17))
            self.settleConnectivityTasks(reason: "deadline", force: true)
        }
    }

    /// Finish the held connectivity tasks once the session has delivered everything.
    private func settleConnectivityTasks(reason: String, force: Bool = false) {
        guard !connectivityTasks.isEmpty else { return }
        let session = WCSession.default
        let drained = session.activationState == .activated && !session.hasContentPending
        guard drained || force else {
            return DiagnosticLog.write("connectivity tasks still held (\(reason)): contentPending=\(session.hasContentPending)")
        }
        DiagnosticLog.write("completing \(connectivityTasks.count) connectivity task(s) (\(reason)) contentPending=\(session.hasContentPending)")
        for task in connectivityTasks { task.setTaskCompletedWithSnapshot(false) }
        connectivityTasks.removeAll()
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
            DiagnosticLog.write("scenePhase -> \(phase)")
            if phase == .active { model.refresh() }
        }
    }
}
