# Water Bottle: HidrateKit

Talk to a HidrateSpark PRO water bottle directly over Bluetooth, without the official app.

* **`HidrateKit`** (Swift package, iOS 17+ / macOS 14+): CoreBluetooth client, protocol
  decoding (handshake, sip records, weight, cap state, LED), two-point calibration,
  stable-reading filter, drink detection, and a HealthKit water logger.
* **`hidrate-cli`** (macOS): scan and monitor a bottle from the terminal.
* **`App/HidrateTestApp`** (iOS): connect, calibrate empty/full, watch live weight,
  auto-detect drinks, and write them to Health as water intake.
* **`docs/PROTOCOL.md`**: everything known about the BLE protocol.
  **`docs/FIRMWARE.md`**: what changing the firmware would actually take.

## Quick start (iOS app)

```bash
cd App && xcodegen generate && open HidrateTestApp.xcodeproj
```

Run on a real iPhone (CoreBluetooth does not work in the Simulator). Before connecting,
force-quit the official Hidrate app: the bottle only accepts one connection.

1. **Bottle tab → Scan**, tap your `h2o…` bottle.
2. **Calibrate tab**: capture empty (dry, lid on, on a table), then capture full. Save.
3. **Intake tab → Allow Health access.**
4. Drink, set the bottle down. After ~6 s of stable readings the drop is logged and
   written to Health as water.

## Quick start (Mac CLI)

```bash
swift build && .build/debug/hidrate-cli scan
.build/debug/hidrate-cli monitor
```

The first run prompts for Bluetooth access for your terminal app.

## Using the SDK in another app

```swift
import HidrateKit

let model = HidrateBottleModel()           // @MainActor, @Observable
model.calibration = BottleCalibration(emptyRaw: 35880, fullRaw: 36690, capacityML: 621)
model.onLevelChange = { event in
    if case .drink(let ml, _, _) = event.change {
        Task { try await HealthKitWaterLogger().logWater(milliliters: ml, at: event.date) }
    }
}
model.startScanning()
// when a bottle shows up in model.bottles:
model.connect(model.bottles[0])
```

Lower level: `HidrateBottleClient` exposes `events()` as an `AsyncStream<BottleEvent>`
plus raw `read/write/setNotify` for exploration.

## Tests

```bash
swift test
```

## Troubleshooting a session

The app writes every event to `Documents/hidrate-session.log` inside its container.
Export it from **Explore → ⋯ → Share session log**, or pull it over USB:

```bash
xcrun devicectl device copy from --device 00008140-000A7DD422D8801C \
  --domain-type appDataContainer --domain-identifier com.rickybloomfield.HidrateTestApp \
  --source Documents/hidrate-session.log --destination ./hidrate-session.log
```

If the bottle disconnects and stays in "Connecting": the bottle only advertises while no
central is connected, so first make sure the official Hidrate app is force-quit (it
reconnects in the background otherwise). Lifting the bottle or opening the cap usually
wakes it up. **Retry now** cancels the pending connect and issues a fresh one.
