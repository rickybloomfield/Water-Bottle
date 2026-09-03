import CoreBluetooth
import Foundation
import HidrateKit

// A small macOS tool for poking at the bottle without deploying to a phone.
//
//   hidrate-cli scan [seconds]                 list bottles (or everything with --all)
//   hidrate-cli monitor [name|uuid] [flags]    connect, handshake, and print every event
//
// Flags for monitor: --no-handshake  --computed-handshake  --no-drain  --quiet
//
// The first run asks for Bluetooth permission on behalf of the terminal app.

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let positional = arguments.dropFirst().filter { !$0.hasPrefix("--") }

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func stamp() -> String { timeFormatter.string(from: Date()) }

func makeOptions() -> BottleClientOptions {
    var options = BottleClientOptions()
    options.onlyBottles = !flags.contains("--all")
    if flags.contains("--no-handshake") { options.handshake = .none }
    if flags.contains("--computed-handshake") { options.handshake = .computed }
    options.autoDrainSips = !flags.contains("--no-drain")
    return options
}

func printEvent(_ event: BottleEvent, quiet: Bool) {
    switch event {
    case .bluetoothState(let state):
        print("[\(stamp())] bluetooth state \(state.rawValue)")
    case .scanning(let on):
        print("[\(stamp())] scanning \(on ? "started" : "stopped")")
    case .discovered(let bottle):
        print("[\(stamp())] found \(bottle.name)  rssi=\(bottle.rssi)  id=\(bottle.id)  services=\(bottle.advertisedServices)  mfg=\(bottle.manufacturerData?.hexString ?? "-")")
    case .connection(let state):
        print("[\(stamp())] connection: \(state.label)")
    case .gatt(let inventory):
        print("[\(stamp())] GATT table:")
        for service in inventory.services {
            print("  service \(service)  \(HidrateUUID.name(for: service) ?? "")")
            for c in inventory.characteristics(in: service) {
                print("    \(c.uuid)  [\(c.propertyList)]  \(c.name ?? "")")
            }
        }
    case .deviceInformation(let info):
        print("[\(stamp())] device info: \(info.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
    case .battery(let level):
        print("[\(stamp())] battery \(level)%")
    case .weight(let sample):
        print("[\(stamp())] weight raw=\(sample.raw) (0x\(String(sample.raw, radix: 16))) hi=\(sample.highByte) lo=\(sample.lowByte)")
    case .cap(let state):
        print("[\(stamp())] cap \(state.rawValue)")
    case .sip(let record):
        print("[\(stamp())] SIP \(record.percentOfCapacity)%  dayTotal=\(record.cumulativePercent)%  pending=\(record.pendingCount)  flags=\(record.flags)  weight \(record.rawWeightBefore.map(String.init) ?? "-")→\(record.rawWeightAfter.map(String.init) ?? "-")  raw=\(record.hexString)")
    case .rawValue(let value):
        print("[\(stamp())] value \(value.name ?? value.uuid): \(value.data.hexString)")
    case .log(let entry):
        if quiet, entry.level < .info { return }
        print("[\(stamp())] \(entry.level) \(entry.message)")
    }
}

switch command {
case "scan":
    let seconds = positional.first.flatMap(Double.init) ?? 15
    let client = HidrateBottleClient(options: makeOptions())
    let task = Task {
        for await event in client.events() {
            if case .discovered = event { printEvent(event, quiet: true) }
            if case .bluetoothState(let s) = event, s == .unauthorized || s == .unsupported || s == .poweredOff {
                print("Bluetooth is not usable (state \(s.rawValue)). Grant Bluetooth access to your terminal in System Settings → Privacy & Security → Bluetooth.")
                exit(1)
            }
        }
    }
    client.startScanning()
    print("Scanning for \(Int(seconds)) s…")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    client.stopScanning()
    task.cancel()
    exit(0)

case "monitor":
    let wanted = positional.first?.lowercased()
    let client = HidrateBottleClient(options: makeOptions())
    let quiet = flags.contains("--quiet")
    var connecting = false
    let task = Task {
        for await event in client.events() {
            printEvent(event, quiet: quiet)
            if case .discovered(let bottle) = event, !connecting {
                let matches = wanted.map { bottle.name.lowercased().contains($0) || bottle.id.uuidString.lowercased() == $0 } ?? true
                if matches {
                    connecting = true
                    print("Connecting to \(bottle.name)…")
                    client.connect(to: bottle.id)
                }
            }
            if case .bluetoothState(let s) = event, s == .unauthorized || s == .unsupported || s == .poweredOff {
                print("Bluetooth is not usable (state \(s.rawValue)). Grant Bluetooth access to your terminal in System Settings → Privacy & Security → Bluetooth.")
                exit(1)
            }
        }
    }
    signal(SIGINT) { _ in
        print("\nDisconnecting…")
        exit(0)
    }
    client.startScanning()
    print("Waiting for a bottle\(wanted.map { " matching \"\($0)\"" } ?? "")… (Ctrl-C to stop)")
    RunLoop.main.run()
    task.cancel()

default:
    print("""
    hidrate-cli — talk to a HidrateSpark bottle from the Mac

      hidrate-cli scan [seconds] [--all]
      hidrate-cli monitor [name|uuid] [--no-handshake] [--computed-handshake] [--no-drain] [--quiet]
    """)
}
