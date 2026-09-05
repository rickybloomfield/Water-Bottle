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
    /// Where to write what the link is doing: the session log, in practice.
    private var log: ((String) -> Void)?
    private var latest: HydrationSnapshot?
    /// A publish that arrived before the session was ready, to send once it is.
    private var heldForActivation: HydrationSnapshot?
    private static let lastComplicationKey = "watch.lastComplicationFingerprint"
    /// What the face was last given, so a budgeted transfer is only spent when it would
    /// look different. Persisted: kept in memory, every launch of this app started from
    /// nothing and spent one on numbers the face already had — and this app is launched
    /// dozens of times on a day it is being worked on, against a budget of fifty.
    private var lastComplicationFingerprint: String? {
        get { UserDefaults.standard.string(forKey: Self.lastComplicationKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastComplicationKey) }
    }

    func activate(onDrink: @escaping (PendingDrink) -> Void,
                  currentSnapshot: @escaping () async -> HydrationSnapshot,
                  log: @escaping (String) -> Void) {
        self.onDrink = onDrink
        self.currentSnapshot = currentSnapshot
        self.log = log
        guard WCSession.isSupported() else { return log("watch: WCSession unsupported") }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Latest wins: the watch only ever needs the current state, never the history of it.
    ///
    /// `force` sends a context the watch already holds; otherwise one is skipped. Every
    /// context wakes the watch app in the background, this app publishes on every launch,
    /// and a handful of wakes in a minute is enough for watchOS to stop waking it
    /// promptly — which held up a real change by twenty seconds.
    func publish(_ snapshot: HydrationSnapshot, force: Bool = false) {
        latest = snapshot
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            heldForActivation = snapshot
            return log?("watch: publish held until activation; \(Self.describe(session))") ?? ()
        }
        heldForActivation = nil
        let sent = WatchMessage.decode(HydrationSnapshot.self, from: session.applicationContext, key: WatchMessage.snapshotKey)
        if !force, sent?.displayFingerprint == snapshot.displayFingerprint {
            return log?("watch: context unchanged, not re-sent [\(snapshot.summary)]") ?? ()
        }
        let payload = WatchMessage.encode(snapshot, forKey: WatchMessage.snapshotKey)
        var route = "context"
        do {
            try session.updateApplicationContext(payload)
        } catch {
            // The context is the fast path and it can refuse (a session that has just
            // gone inactive, for one). Fall back to a queued transfer rather than
            // silently dropping the update until something else changes.
            route = "userInfo, context refused: \(error.localizedDescription)"
            session.transferUserInfo(payload)
        }

        // The application context only reaches the watch when its app runs, which would
        // leave the complication showing this morning's number all day. A complication
        // transfer wakes the watch — but the daily budget is small, so spend one only
        // when the number on the face changes.
        let changed = lastComplicationFingerprint != snapshot.displayFingerprint
        let spend = session.isComplicationEnabled && session.remainingComplicationUserInfoTransfers > 0 && changed
        log?("watch: published [\(snapshot.summary)] via \(route); \(Self.describe(session)); faceWouldChange=\(changed) -> \(spend ? "complication transfer" : "no complication transfer")")
        guard spend else { return }
        lastComplicationFingerprint = snapshot.displayFingerprint
        session.transferCurrentComplicationUserInfo(payload)
    }

    /// What was held for activation; with `force`, the latest state regardless, for a
    /// watch app that has just been (re)installed and holds nothing.
    private func republish(force: Bool = false) {
        if let held = heldForActivation {
            publish(held, force: force)
        } else if force, let latest {
            publish(latest, force: true)
        }
    }

    nonisolated static func describe(_ session: WCSession) -> String {
        "state=\(label(session.activationState)) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) complicationEnabled=\(session.isComplicationEnabled) remainingComplicationTransfers=\(session.remainingComplicationUserInfoTransfers) reachable=\(session.isReachable) outstanding=\(session.outstandingUserInfoTransfers.count) contentPending=\(session.hasContentPending)"
    }

    nonisolated static func label(_ state: WCSessionActivationState) -> String {
        switch state {
        case .notActivated: "notActivated"
        case .inactive: "inactive"
        case .activated: "activated"
        @unknown default: "unknown(\(state.rawValue))"
        }
    }
}

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let line = "watch: activation \(Self.label(activationState)) error=\(error.map { "\($0)" } ?? "none"); \(Self.describe(session))"
        Task { @MainActor in
            self.log?(line)
            self.republish()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in self.log?("watch: session inactive") }
    }

    /// Happens when the user switches watches; reactivate for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in self.log?("watch: session deactivated; reactivating") }
        WCSession.default.activate()
    }

    /// Pairing, installation or the complication's presence on the active face changed.
    /// A (re)installed watch app holds no context, so it gets the latest regardless.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let line = "watch: state changed; \(Self.describe(session))"
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.log?(line)
            if installed { self.republish(force: true) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let line = "watch: reachable=\(session.isReachable)"
        Task { @MainActor in self.log?(line) }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let line = "watch: transfer finished complication=\(userInfoTransfer.isCurrentComplicationInfo) error=\(error.map { "\($0)" } ?? "none"); remainingComplicationTransfers=\(session.remainingComplicationUserInfoTransfers)"
        let failedComplication = userInfoTransfer.isCurrentComplicationInfo && error != nil
        Task { @MainActor in
            self.log?(line)
            // The face never got it; let the next publish try again.
            if failedComplication { self.lastComplicationFingerprint = nil }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // The watch's diagnostic log, shipped here because here is where it can be read.
        if let text = userInfo[WatchMessage.logKey] as? String {
            let lines = text.split(separator: "\n").map(String.init)
            Task { @MainActor in
                for line in lines { self.log?("watchlog \(line)") }
            }
            return
        }
        guard let drink = WatchMessage.decode(PendingDrink.self, from: userInfo, key: WatchMessage.drinkKey) else { return }
        Task { @MainActor in
            self.log?("watch: drink \(Int(drink.volumeML))mL arrived as userInfo")
            self.onDrink?(drink)
        }
    }

    /// The watch asking for the current numbers, with somewhere to put the answer. This
    /// is the path that carries a drink tapped on the widget through to the wrist: the
    /// message wakes this app, which adopts the pending drink before it replies.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let drink = WatchMessage.decode(PendingDrink.self, from: message, key: WatchMessage.drinkKey)
        let reply = UncheckedBox(replyHandler)
        let keys = Array(message.keys).sorted()
        Task { @MainActor in
            self.log?("watch: message \(keys) wants a reply")
            if let drink { self.onDrink?(drink) }
            let snapshot = await self.currentSnapshot?() ?? self.latest
            reply.value(snapshot.map { WatchMessage.encode($0, forKey: WatchMessage.snapshotKey) } ?? [:])
            self.log?("watch: replied [\(snapshot?.summary ?? "nothing")]")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message[WatchMessage.requestKey] != nil else { return }
        Task { @MainActor in
            self.log?("watch: request without a reply handler; republishing")
            self.republish(force: true)
        }
    }
}

/// WatchConnectivity hands back a plain closure, which Swift 6 won't let cross to the
/// main actor on its own. It is only ever called once, from one place.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) { self.value = value }
}
