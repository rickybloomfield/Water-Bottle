import Foundation
#if os(watchOS)
import WatchKit
#endif

/// A plain-text log in the app group container, which every process sharing the group can
/// append to: the watch app and its complication, the phone app and its widget. It exists
/// to answer questions the session log cannot, because that lives in the phone app's
/// Documents and only the phone app writes it — chiefly, when the complication's timeline
/// is actually re-run, and what it read when it was.
///
/// The watch ships it to the phone (`WatchPhoneLink.shipDiagnostics`), where it is copied
/// into the session log, each line prefixed `watchlog`. On the phone it can be pulled
/// straight out of the group container:
/// `xcrun devicectl device copy from --domain-type appGroupDataContainer
///   --domain-identifier group.com.rickybloomfield.HidrateTestApp --source diagnostics.log`.
enum DiagnosticLog {
    static let fileName = "diagnostics.log"

    private static let lock = NSLock()
    /// Nobody draining it means nobody is reading it; start over rather than grow forever.
    private static let maxBytes: UInt64 = 256 * 1024

    // DateFormatter has been thread-safe since iOS 7.
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Which process wrote the line, from its bundle id, plus the pid so two launches of
    /// the same one can be told apart.
    static let process: String = {
        let id = Bundle.main.bundleIdentifier ?? "?"
        let name = if id.hasSuffix(".watchkitapp.Widgets") { "watch-widget" }
                   else if id.hasSuffix(".watchkitapp") { "watch-app" }
                   else if id.hasSuffix(".Widgets") { "phone-widget" }
                   else { "phone-app" }
        return "\(name):\(ProcessInfo.processInfo.processIdentifier)"
    }()

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: HydrationStore.appGroupID)?
            .appendingPathComponent(fileName)
    }

    static func stamp(_ date: Date) -> String { formatter.string(from: date) }

    static func write(_ line: String) {
        guard let url else { return }
        let text = Data("\(stamp(Date())) [\(process)] \(line)\n".utf8)
        lock.lock(); defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? text.write(to: url)
            return
        }
        defer { try? handle.close() }
        if let end = try? handle.seekToEnd(), end > maxBytes {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: text)
    }

    /// Everything written so far, and the file emptied, for shipping to wherever it can be
    /// read. Nil when there is nothing to ship.
    static func drain() -> String? {
        guard let url else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        try? Data().write(to: url)
        return String(decoding: data, as: UTF8.self)
    }

    #if os(watchOS)
    /// "active", "background"…, for lines that only mean something with it.
    @MainActor static var appState: String {
        switch WKApplication.shared().applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
    #endif
}

extension HydrationSnapshot {
    /// The fields that matter when reading a log: whose day it is, the numbers, and when
    /// the phone wrote it.
    var summary: String {
        "day=\(DiagnosticLog.stamp(day).prefix(10)) total=\(Int(totalML.rounded()))mL goal=\(Int(goalML.rounded()))mL acks=\(acknowledgedDrinkIDs.count) updated=\(DiagnosticLog.stamp(updated))"
    }
}
