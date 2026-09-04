import Foundation
import WatchConnectivity

/// The phone's half of the watch link: it pushes today's snapshot to the wrist and takes
/// delivery of drinks tapped there. Delivery is queued by WatchConnectivity, so a drink
/// logged on the watch with the phone in a pocket arrives when the phone next wakes.
@MainActor
final class PhoneWatchLink: NSObject {
    static let shared = PhoneWatchLink()

    private var onDrink: ((PendingDrink) -> Void)?
    /// Brings the app up to date and hands back the result, for answering the watch.
    private var currentSnapshot: (() async -> HydrationSnapshot)?
    private var latest: HydrationSnapshot?
    /// The numbers behind the last complication push, so a budgeted transfer is only
    /// spent when the face would actually look different.
    private var lastComplicationTotals: (total: Double, goal: Double)?

    func activate(onDrink: @escaping (PendingDrink) -> Void,
                  currentSnapshot: @escaping () async -> HydrationSnapshot) {
        self.onDrink = onDrink
        self.currentSnapshot = currentSnapshot
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Latest wins: the watch only ever needs the current state, never the history of it.
    func publish(_ snapshot: HydrationSnapshot) {
        latest = snapshot
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let payload = WatchMessage.encode(snapshot, forKey: WatchMessage.snapshotKey)
        do {
            try session.updateApplicationContext(payload)
        } catch {
            // The context is the fast path and it can refuse (a session that has just
            // gone inactive, for one). Fall back to a queued transfer rather than
            // silently dropping the update until something else changes.
            session.transferUserInfo(payload)
        }

        // The application context only reaches the watch when its app runs, which would
        // leave the complication showing this morning's number all day. A complication
        // transfer wakes the watch — but the daily budget is small, so spend one only
        // when the number on the face changes.
        let totals = (snapshot.totalML, snapshot.goalML)
        guard session.isComplicationEnabled,
              session.remainingComplicationUserInfoTransfers > 0,
              lastComplicationTotals?.total != totals.0 || lastComplicationTotals?.goal != totals.1
        else { return }
        lastComplicationTotals = totals
        session.transferCurrentComplicationUserInfo(payload)
    }

    private func republish() {
        if let latest { publish(latest) }
    }
}

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.republish() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Happens when the user switches watches; reactivate for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let drink = WatchMessage.decode(PendingDrink.self, from: userInfo, key: WatchMessage.drinkKey) else { return }
        Task { @MainActor in self.onDrink?(drink) }
    }

    /// The watch asking for the current numbers, with somewhere to put the answer. This
    /// is the path that carries a drink tapped on the widget through to the wrist: the
    /// message wakes this app, which adopts the pending drink before it replies.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let drink = WatchMessage.decode(PendingDrink.self, from: message, key: WatchMessage.drinkKey)
        let reply = UncheckedBox(replyHandler)
        Task { @MainActor in
            if let drink { self.onDrink?(drink) }
            let snapshot = await self.currentSnapshot?() ?? self.latest
            reply.value(snapshot.map { WatchMessage.encode($0, forKey: WatchMessage.snapshotKey) } ?? [:])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message[WatchMessage.requestKey] != nil else { return }
        Task { @MainActor in self.republish() }
    }
}

/// WatchConnectivity hands back a plain closure, which Swift 6 won't let cross to the
/// main actor on its own. It is only ever called once, from one place.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) { self.value = value }
}
