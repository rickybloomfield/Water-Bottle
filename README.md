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
* **`App/HidrateWidgets`** (iOS widget): the day's ring on the home screen, with one-tap
  amounts on the medium size, plus lock-screen accessory sizes.
* **`App/HidrateWatchApp`** (watchOS) and **`App/HidrateWatchWidgets`**: the same ring and
  the same one-tap amounts on the wrist, and a complication showing the ring with the
  number inside it.
* **`docs/PROTOCOL.md`**: everything known about the BLE protocol.
  **`docs/FIRMWARE.md`**: what changing the firmware would actually take.

## The widget, the watch and the complication

All three draw the same thing: today's total as a ring against your goal, and the amounts
from the app's log sheet as one-tap buttons.

They share one small value, `HydrationSnapshot` — today's total, the goal, your unit — that
the phone app writes to the `group.com.rickybloomfield.HidrateTestApp` app group after
every change, and pushes to the watch over WatchConnectivity. Nothing else crosses the
boundary, so the widget and the watch never need HidrateKit, Bluetooth or Health.

A tap on the widget or the watch does not wait for the app. It goes into a pending queue
next to the snapshot and counts toward the displayed total straight away; when the phone
app next runs it adopts those drinks into its history and writes them to Apple Health,
then echoes their ids back so the sender stops counting them itself. So a drink logged on
a watch out of range of the phone still lands, exactly once.

Keeping the three of them agreeing takes three rules:

* **The phone publishes only when the numbers change.** Widget reloads come out of a daily
  budget. Republishing on every Health re-read and every scene change spent that budget on
  nothing, and then a real change had no reload left to spend.
* **The watch asks, rather than only waiting to be told.** When the watch app opens, or the
  phone comes back into range, it sends a message — which wakes the phone, has it adopt
  anything sitting in the widget's queue, and replies with the result. That is the path a
  widget tap takes to the wrist.
* **A drink from the watch goes out twice**, as a live message and as a queued transfer.
  The phone keys drinks by id, so arriving twice costs nothing, and arriving late does.

Every ring carries a tick showing where the day's pace says you should be by now, spread
evenly across the drink window from the reminder settings — ahead of the tick you're on
track, behind it you're falling back. The complication has no room for a unit, so it shows
the number alone; whether that number is ounces or millilitres follows the app's setting. The phone spends a budgeted
complication transfer only when the number on the face would actually change.

## Keeping up while nothing is on screen

Four things wake the app, and each ends in the same place — republish the snapshot, reload
the widget, push to the watch:

* **CoreBluetooth restoration.** The client is created with a restore identifier, so iOS
  relaunches the app when the bottle reconnects and hands the peripheral back.
* **A drink from the watch**, delivered by WatchConnectivity even if the phone was asleep.
* **Water logged in Health by another app.** Background delivery is enabled on the water
  type, so the observer fires without the app being open.
* **A background refresh**, roughly every fifteen minutes when iOS feels like it, which
  adopts anything tapped on the widget, prods a stalled bottle connection, and re-reads
  Health.

All of them need `AppState` to exist before any view does, so it is a single instance built
by the app delegate at launch rather than by the first view. The watch app does the same
with its `WKApplicationDelegate`: the phone link is listening from launch, so a snapshot
pushed for the complication is taken in the background instead of waiting for someone to
open the app.

The widget's timeline asks to be woken hourly and exactly at midnight — midnight so it
never shows yesterday's number, hourly as a safety net for a day when the app never runs.

## When the level reads below empty

The bottle's scale drifts: over days its zero creeps down, so the raw reading can sit
*below* the calibrated empty point while there is still water in it. The conversion is
deliberately unclamped inside `HidrateKit` — drink detection wants the real number, and
a little negative is ordinary noise — but nothing shown to a person uses it any more.
`clampedLevelML` is what the app displays, and when the reading is genuinely under empty
the Bottle tab says by how much and suggests recapturing the empty point.

The level the app shows before the bottle reconnects is stored as the last settled *raw*
reading rather than as millilitres. Recalibrating then reinterprets it instead of
invalidating it, and a bottle whose zero has drifted — every sample below the "lifted"
threshold, so nothing counted as settled — still leaves something to draw. Both of those
used to end the same way: an empty bottle on the Today tab until the bottle reconnected.

## The water

The bottle on the Today tab holds an animated water surface: a one-dimensional
heightfield whose columns are coupled to their neighbours (so ripples travel), pulled
toward an equilibrium that follows the device's real gravity vector, and damped. The
surface stays perpendicular to gravity and preserves volume at any angle, so turning the
phone pools the water against the side or the cap, tapping ripples it, and it drains
smoothly as you drink. It's a stylised model tuned to feel like water, not a fluid solver.

## Quick start (iOS app)

```bash
cd App && xcodegen generate && open HidrateTestApp.xcodeproj
```

This builds the app, the widget, the watch app and the complication. Run on a real iPhone
(CoreBluetooth does not work in the Simulator). Before connecting, force-quit the official
Hidrate app: the bottle only accepts one connection.

1. **Bottle tab → Find bottle**, tap your `h2o…` bottle.
2. **Bottle tab → Calibrate**: capture empty (dry, lid on, on a table), then capture full.
   It saves itself and the bottle glows green.
3. **Settings → Allow Health access**, set your goal and units. The reminder window's
   **From** and **Until** times set the day's pace: reminders are only sent when you're
   behind it, and the tick on every ring marks it.
4. Long-press the home screen to add the **Hydration** widget, and add the complication
   from the watch face editor.
5. Drink and set the bottle down. The drop is logged, written to Health, and the bottle
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
