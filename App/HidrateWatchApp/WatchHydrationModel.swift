import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

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
    /// The last state a reload was asked for, so the several deliveries a launch
    /// produces — the stored context, the same context again, the phone's reply — cost
    /// one request rather than one each.
    private var lastReloadRequest: String?
    /// Set by the app delegate: connectivity content has been taken delivery of, so a
    /// background task waiting on it can be finished.
    var onConnectivityActivity: (() -> Void)?

    func start() {
        guard !started else { return refresh() }
        started = true
        DiagnosticLog.write("start \(AppVersion.short) app=\(DiagnosticLog.appState) stored=[\(HydrationStore.storedSnapshot().summary)]")
        link.activate(onSnapshot: { [weak self] snapshot, route in self?.adopt(snapshot, via: route) })
        link.onActivity = { [weak self] in self?.onConnectivityActivity?() }
        refresh()
    }

    /// Called when the app comes back to the front: re-read the store and ask the phone
    /// for anything logged on it since.
    func refresh() {
        snapshot = HydrationStore.currentSnapshot()
        pendingCount = HydrationStore.pendingDrinks().count
        DiagnosticLog.write("refresh app=\(DiagnosticLog.appState) showing=[\(snapshot.summary)] pending=\(pendingCount) lastGetTimeline=[\(HydrationStore.lastTimelineRun)] \(link.stateDescription)")
        link.requestSnapshot()
        Self.logConfiguredWidgets()
        link.shipDiagnostics()
    }

    /// What WidgetKit believes is on a face right now. Empty means a reload has nothing
    /// to reload, whatever the face is showing.
    private static func logConfiguredWidgets() {
        WidgetCenter.shared.getCurrentConfigurations { @Sendable result in
            switch result {
            case .success(let infos):
                DiagnosticLog.write("configured widgets: \(infos.isEmpty ? "none" : infos.map { "\($0.kind)/\($0.family)" }.joined(separator: ","))")
            case .failure(let error):
                DiagnosticLog.write("getCurrentConfigurations failed: \(error)")
            }
        }
    }

    func log(volumeML: Double) {
        let drink = HydrationStore.addPendingDrink(volumeML: volumeML, origin: .watch)
        refresh()
        reloadComplicationIfNeeded(reason: "logged \(Int(volumeML))mL")
        link.send(drink)
    }

    /// Ask WidgetKit to re-run the timeline, but only when what it would draw has
    /// changed since it last drew — and only once per state from this process.
    func reloadComplicationIfNeeded(reason: String) {
        let state = HydrationStore.currentSnapshot().displayFingerprint
        if state == lastReloadRequest {
            return DiagnosticLog.write("reload not requested (\(reason)): already asked for this state")
        }
        if state == HydrationStore.renderedFingerprint {
            return DiagnosticLog.write("reload not requested (\(reason)): the face already shows this state")
        }
        lastReloadRequest = state
        DiagnosticLog.write("reloadWidgets requested (\(reason)) app=\(DiagnosticLog.appState) lastGetTimeline=[\(HydrationStore.lastTimelineRun)]")
        HydrationStore.reloadWidgets()
    }

    private func adopt(_ incoming: HydrationSnapshot, via route: String) {
        let stored = HydrationStore.storedSnapshot()
        defer {
            onConnectivityActivity?()
            link.shipDiagnostics()
        }
        // The context waiting at activation can predate a reply already taken; going
        // backwards would put an older number on the face until the next message.
        guard incoming.updated >= stored.updated else {
            return DiagnosticLog.write("adopt via \(route) ignored: incoming=[\(incoming.summary)] is older than stored=[\(stored.summary)]")
        }
        HydrationStore.save(incoming)
        // The phone has taken these over; they're in its total now, so stop adding them.
        HydrationStore.removePending(ids: incoming.acknowledgedDrinkIDs)
        snapshot = HydrationStore.currentSnapshot()
        pendingCount = HydrationStore.pendingDrinks().count
        DiagnosticLog.write("adopt via \(route) app=\(DiagnosticLog.appState) incoming=[\(incoming.summary)] over stored=[\(stored.summary)]")
        reloadComplicationIfNeeded(reason: "adopt via \(route)")
    }
}

/// The watch's half of the link.
@MainActor
private final class WatchPhoneLink: NSObject {
    /// The snapshot and which route it came by, for the log.
    private var onSnapshot: ((HydrationSnapshot, String) -> Void)?

    /// Anything arriving over the session, snapshot or not: the app delegate uses it to
    /// find out when a background delivery has finished.
    var onActivity: (() -> Void)?

    func activate(onSnapshot: @escaping (HydrationSnapshot, String) -> Void) {
        self.onSnapshot = onSnapshot
        guard WCSession.isSupported() else { return DiagnosticLog.write("WCSession unsupported") }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        DiagnosticLog.write("session.activate() called; \(stateDescription) contextWaiting=\(!session.receivedApplicationContext.isEmpty)")
        // A context that arrived while the app was not running is waiting here.
        deliver(session.receivedApplicationContext, route: "receivedApplicationContext@activate")
    }

    var stateDescription: String {
        guard WCSession.isSupported() else { return "session=unsupported" }
        let s = WCSession.default
        return "session=\(Self.label(s.activationState)) reachable=\(s.isReachable) companion=\(s.isCompanionAppInstalled) contentPending=\(s.hasContentPending) outstanding=\(s.outstandingUserInfoTransfers.count)"
    }

    nonisolated static func label(_ state: WCSessionActivationState) -> String {
        switch state {
        case .notActivated: "notActivated"
        case .inactive: "inactive"
        case .activated: "activated"
        @unknown default: "unknown(\(state.rawValue))"
        }
    }

    /// Two routes on purpose. The queued transfer always lands eventually, even out of
    /// range; the live message lands now when the phone is reachable. The phone keys
    /// drinks by id, so arriving twice costs nothing and is far better than arriving late.
    func send(_ drink: PendingDrink) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            return DiagnosticLog.write("send drink skipped: \(stateDescription)")
        }
        let payload = WatchMessage.encode(drink, forKey: WatchMessage.drinkKey)
        let session = WCSession.default
        session.transferUserInfo(payload)
        DiagnosticLog.write("send drink \(Int(drink.volumeML))mL queued; reachable=\(session.isReachable)")
        guard session.isReachable else { return }
        // `@Sendable` matters: written bare inside a @MainActor type, the closure is
        // inferred main-actor isolated, and WatchConnectivity calls it back on its own
        // operation queue — which trips the isolation check and traps. Decode here, hop
        // with the value.
        session.sendMessage(payload, replyHandler: { @Sendable [weak self] reply in
            guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: reply, key: WatchMessage.snapshotKey) else {
                return DiagnosticLog.write("drink reply carried no snapshot: keys=\(Array(reply.keys))")
            }
            Task { @MainActor in self?.onSnapshot?(snapshot, "reply(drink)") }
        }, errorHandler: { @Sendable error in DiagnosticLog.write("drink message failed: \(error)") })
    }

    /// Ask the phone what today looks like. The phone catches up before it answers, so
    /// this is also how a drink tapped on the widget reaches the watch.
    func requestSnapshot() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            return DiagnosticLog.write("requestSnapshot skipped: \(stateDescription)")
        }
        DiagnosticLog.write("requestSnapshot sent")
        session.sendMessage([WatchMessage.requestKey: true], replyHandler: { @Sendable [weak self] reply in
            guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: reply, key: WatchMessage.snapshotKey) else {
                return DiagnosticLog.write("request reply carried no snapshot: keys=\(Array(reply.keys))")
            }
            Task { @MainActor in self?.onSnapshot?(snapshot, "reply(request)") }
        }, errorHandler: { @Sendable error in DiagnosticLog.write("request failed: \(error)") })
    }

    /// Ship whatever the diagnostic log holds to the phone, where it lands in the session
    /// log. Queued, so it goes even with the phone out of range.
    func shipDiagnostics() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        guard let text = DiagnosticLog.drain() else { return }
        WCSession.default.transferUserInfo([WatchMessage.logKey: text])
    }

    fileprivate func deliver(_ payload: [String: Any], route: String) {
        guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: payload, key: WatchMessage.snapshotKey) else { return }
        onSnapshot?(snapshot, route)
    }
}

extension WatchPhoneLink: WCSessionDelegate {
    /// The phone came back into range; pull whatever changed while it was away.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DiagnosticLog.write("reachability changed: \(reachable)")
        guard reachable else { return }
        Task { @MainActor in self.requestSnapshot() }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DiagnosticLog.write("activation completed: \(Self.label(activationState)) error=\(error.map { "\($0)" } ?? "none") reachable=\(session.isReachable) companion=\(session.isCompanionAppInstalled) contextWaiting=\(!session.receivedApplicationContext.isEmpty) contentPending=\(session.hasContentPending)")
        Task { @MainActor in
            self.deliver(WCSession.default.receivedApplicationContext, route: "receivedApplicationContext@activated")
            self.onActivity?()
            self.shipDiagnostics()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: applicationContext, key: WatchMessage.snapshotKey) else {
            DiagnosticLog.write("applicationContext carried no snapshot: keys=\(Array(applicationContext.keys))")
            Task { @MainActor in self.onActivity?() }
            return
        }
        DiagnosticLog.write("didReceiveApplicationContext")
        Task { @MainActor in self.onSnapshot?(snapshot, "applicationContext") }
    }

    /// A complication transfer: the phone woke us so the face can be redrawn.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let snapshot = WatchMessage.decode(HydrationSnapshot.self, from: userInfo, key: WatchMessage.snapshotKey) else {
            DiagnosticLog.write("userInfo carried no snapshot: keys=\(Array(userInfo.keys))")
            Task { @MainActor in self.onActivity?() }
            return
        }
        DiagnosticLog.write("didReceiveUserInfo (complication transfer)")
        Task { @MainActor in self.onSnapshot?(snapshot, "userInfo") }
    }
}
