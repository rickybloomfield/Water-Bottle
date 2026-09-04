# Water Bottle: HidrateKit

Talk to a HidrateSpark PRO water bottle directly over Bluetooth, without the official app.

* **`HidrateKit`** (Swift package, iOS 17+ / macOS 14+): CoreBluetooth client, protocol
  decoding (handshake, sip records, weight, cap state, LED), two-point calibration,
  stable-reading filter, drink detection, and a HealthKit water logger.
* **`hidrate-cli`** (macOS): scan and monitor a bottle from the terminal.
* **`App/HidrateTestApp`** (iOS): a daily-use hydration app. **Today** shows progress
  toward your goal and an animated bottle whose water sloshes with device tilt and
  ripples when tapped, draining as you drink, with a celebration when you hit the goal.
  **Progress** charts daily/weekly/monthly intake from Apple Health with streaks and
  stats. **Bottle** covers connection, hardware details, and calibration. **Settings**
  holds your goal, units (oz or mL), drink reminders, the bottle's drink light, Health
  access, and a Debug area with the engineering tools.
* **`docs/PROTOCOL.md`**: everything known about the BLE protocol.
  **`docs/FIRMWARE.md`**: what changing the firmware would actually take.

## The water

The bottle on the Today tab holds a real fluid simulation, not an animation: a 2D
Position-Based Fluids solver (Macklin & Müller) with incompressibility enforced like water,
driven by the device's actual gravity vector at 9.81 m/s² scaled to the bottle's real
dimensions, and water-like viscosity. It pools against whichever wall is down, sloshes,
splashes when tapped, and drains or pours as the level changes. The vessel walls come
from a signed-distance field of the drawn silhouette, and the particles render as one
liquid through a metaball filter. A headless harness (see `docs/PHYSICS.md`) checks
containment, density error, surface flatness, and behaviour at 90° and 180°.

## Quick start (iOS app)

```bash
cd App && xcodegen generate && open HidrateTestApp.xcodeproj
```

Run on a real iPhone (CoreBluetooth does not work in the Simulator). Before connecting,
force-quit the official Hidrate app: the bottle only accepts one connection.

1. **Bottle tab → Find bottle**, tap your `h2o…` bottle.
2. **Bottle tab → Calibrate**: capture empty (dry, lid on, on a table), then capture full.
   It saves itself and the bottle glows green.
3. **Settings → Allow Health access**, set your goal and units.
4. Drink and set the bottle down. The drop is logged, written to Health, and the bottle
   glows blue. The Today tab's bottle drains to match.

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
