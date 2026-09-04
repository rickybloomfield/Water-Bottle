import Foundation
import Observation
import WatchConnectivity

/// The watch's view of today. It draws whatever the phone last sent, plus anything tapped
/// here that the phone hasn't confirmed yet, so a tap counts immediately even out of range.
@MainActor
@Observable
final class WatchHydrationModel {
    /// One instance, started at launch rather than when a view appears: the watch is often
    /// woken in the background to take delivery of a snapshot, and the session has to be
    /// listening by then or the payload waits for the next time someone opens the app.
    static let shared = WatchHydrationModel()

    private(set) var snapshot = HydrationStore.currentSnapshot()
    private(set) var pendingCount = HydrationStore.pendingDrinks().count

    private let link = WatchPhoneLink()

    private var started = false

    func start() {
        guard !started else { return refresh() }
        started = true
        link.activate(onSnapshot: { [weak self] snapshot in self?.adopt(snapshot) })
        refresh()
    }

    /// Called when the app comes back to the front: re-read the store and ask the phone
    /// for anything logged on it since.
    func refresh() {
        snapshot = HydrationStore.currentSnapshot()
        pendingCount = HydrationStore.pendingDrinks().count
        link.requestSnapshot()
    }

    func log(volumeML: Double) {
        let drink = HydrationStore.addPendingDrink(volumeML: volumeML, origin: .watch)
        refresh()
        HydrationStore.reloadWidgets()
        link.send(drink)
    }


    private func adopt(_ incoming: HydrationSnapshot) {
        HydrationStore.save(incoming)
        // The phone has taken these over; they're in its total now, so stop adding them.
        HydrationStore.removePending(ids: incoming.acknowledgedDrinkIDs)
        snapshot = HydrationStore.currentSnapshot()
        pendingCount = HydrationStore.pendingDrinks().count
        HydrationStore.reloadWidgets()
    }
}

/// The watch's half of the link.
@MainActor
private final class WatchPhoneLink: NSObject {
    private var onSnapshot: ((HydrationSnapshot) -> Void)?

    func activate(onSnapshot: @escaping (HydrationSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // A context that arrived while the app was not running is waiting here.
        deliver(session.receivedApplicationContext)
    }

    /// Two routes on purpose. The queued transfer always lands eventually, even out of
    /// range; the live message lands now when the phone is reachable. The phone keys
    /// drinks by id, so arriving twice costs nothing and is far better than arriving late.
    func send(_ drink: PendingDrink) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let payload = WatchMessage.encode(drink, forKey: WatchMessage.drinkKey)
        let session = WCSession.default
        session.transferUserInfo(payload)
        guard session.isReachable else { return }
        // `@Sendable` matters: written bare inside a @MainActor type, the closure is
        // inferred main-actor isolated, and WatchConnectivity calls it back on its own
        // operation queue — which trips the isolation check and traps. Decode here, hop
        // with the value.
        session.sendMessage(payload, replyHandler: { @Sendable [weak self] reply in
            guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: reply, key: WatchMessage.snapshotKey) else { return }
            Task { @MainActor in self?.onSnapshot?(snapshot) }
        }, errorHandler: nil)
    }

    /// Ask the phone what today looks like. The phone catches up before it answers, so
    /// this is also how a drink tapped on the widget reaches the watch.
    func requestSnapshot() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage([WatchMessage.requestKey: true], replyHandler: { @Sendable [weak self] reply in
            guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: reply, key: WatchMessage.snapshotKey) else { return }
            Task { @MainActor in self?.onSnapshot?(snapshot) }
        }, errorHandler: nil)
    }

    fileprivate func deliver(_ payload: [String: Any]) {
        guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: payload, key: WatchMessage.snapshotKey) else { return }
        onSnapshot?(snapshot)
    }
}

extension WatchPhoneLink: WCSessionDelegate {
    /// The phone came back into range; pull whatever changed while it was away.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.requestSnapshot() }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.deliver(WCSession.default.receivedApplicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: applicationContext, key: WatchMessage.snapshotKey) else { return }
        Task { @MainActor in self.onSnapshot?(snapshot) }
    }

    /// A complication transfer: the phone woke us so the face can be redrawn.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: userInfo, key: WatchMessage.snapshotKey) else { return }
        Task { @MainActor in self.onSnapshot?(snapshot) }
    }
}
