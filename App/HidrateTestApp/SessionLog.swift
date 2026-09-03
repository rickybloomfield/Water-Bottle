import Foundation
import HidrateKit

/// Appends a plain-text record of every SDK event to Documents/hidrate-session.log so
/// a session can be reviewed after the fact (Explore tab → Share log, or pulled over USB
/// with `xcrun devicectl device copy from`).
@MainActor
final class SessionLog {
    static let fileName = "hidrate-session.log"
    let url: URL
    private var handle: FileHandle?
    private let maxBytes: UInt64 = 8 * 1024 * 1024
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init() {
        let documents = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = documents.appendingPathComponent(Self.fileName)
        open()
        write("---- app launched ----")
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        guard let handle else { return }
        let text = "\(formatter.string(from: Date())) \(line)\n"
        if let data = text.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        if let size = try? handle.offset(), size > maxBytes { rotate() }
    }

    func record(_ event: BottleEvent) {
        switch event {
        case .bluetoothState(let state): write("bluetooth state=\(state.rawValue)")
        case .scanning(let on): write("scanning \(on)")
        case .discovered(let bottle): write("discovered \(bottle.name) rssi=\(bottle.rssi) id=\(bottle.id) services=\(bottle.advertisedServices) mfg=\(bottle.manufacturerData?.hexString ?? "-")")
        case .connection(let state): write("connection \(state.label)")
        case .gatt(let inventory):
            write("gatt services=\(inventory.services.count) characteristics=\(inventory.characteristics.count)")
            for service in inventory.services {
                write("  service \(service) \(HidrateUUID.name(for: service) ?? "")")
                for c in inventory.characteristics(in: service) {
                    write("    char \(c.uuid) [\(c.propertyList)] \(c.name ?? "")")
                }
            }
        case .deviceInformation(let info): write("deviceInfo \(info.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))")
        case .battery(let level): write("battery \(level)%")
        case .weight(let sample): write("weight raw=\(sample.raw) hex=\(sample.payload.hexString)")
        case .cap(let state): write("cap \(state.rawValue)")
        case .sip(let record): write("sip pct=\(record.percentOfCapacity) total=\(record.cumulativePercent) pending=\(record.pendingCount) flags=\(record.flags) before=\(record.rawWeightBefore ?? -1) after=\(record.rawWeightAfter ?? -1) raw=\(record.hexString)")
        case .rawValue(let value): write("value \(value.name ?? value.uuid) \(value.data.hexString)")
        case .log(let entry): write("log.\(entry.level) \(entry.message)")
        }
    }

    func clear() {
        try? handle?.close()
        try? FileManager.default.removeItem(at: url)
        open()
        write("---- log cleared ----")
    }

    private func rotate() {
        try? handle?.close()
        let previous = url.deletingLastPathComponent().appendingPathComponent("hidrate-session.previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        open()
        write("---- rotated ----")
    }

    var sizeDescription: String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
