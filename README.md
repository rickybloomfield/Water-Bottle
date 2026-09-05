# Water Bottle: HidrateKit

Talk to a HidrateSpark PRO water bottle directly over Bluetooth, without the official app.

* **`HidrateKit`** (Swift package, iOS 17+ / macOS 14+): CoreBluetooth client, protocol
  decoding (handshake, sip records, weight, cap state, LED), two-point calibration,
  stable-reading filter, drink detection, and a HealthKit water logger.
* **`hidrate-cli`** (macOS): scan and monitor a bottle from the terminal.
* **`App/HidrateTestApp`** (iOS): a daily-use hydration app. **Today** shows progress
  toward your goal and an animated bottle whose water sloshes with device tilt and
  ripples when tapped, draining as you drink, with a celebration when you hit the goal.
  Swipe right to step back through the last month, or pick a day from the strip along the
  top; a past day drops the bottle and the connection line, which are only true of now.
  That sideways swipe is why a drink row has none of its own: delete one from the drink
  itself, or from its long-press menu.
  Any drink can be tapped for its details — where it came from and whether it reached
  Apple Health. One you logged by hand, in the app or on the widget or watch, can also be corrected
  there; one the bottle weighed cannot, since editing a measurement would quietly disagree
  with the level the app is tracking, and one from Health belongs to the app that wrote it.
  **Progress** charts daily/weekly/monthly intake from Apple Health with streaks and
  stats, and leads to every day there is — filter to the ones that missed the goal, and
  open one to see what it holds and to add, correct or remove drinks on it, the same as
  Today. Days load a season at a time as you scroll back. **Bottle** is the list of bottles
  you own — one opens onto its water level, its calibration, what it is, and the red
  Disconnect button. **Settings**
  holds your goal, units (oz or mL), drink reminders, the bottle's lights, Health
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

The circular complication takes its size from a gauge and everything else from us. A
complication's circle is not the size of its slot — measured off a photograph of a real
face, every system complication on it is a 45 pt circle with a 5 pt stroke, and none of
them fills the slot it sits in — and nothing inside a widget can be asked how big that
circle is. Filling the slot came out heavier than everything beside it. Measuring a gauge's
ideal size in the app and drawing to that came out a tenth of the size, because a gauge
reports about 50 pt of ideal size in an app and about 10 pt in a widget.

What works is what the first version of the view did: give a gauge a real label and let it
lay itself out. That was the right size; it was only white and had no pace dot, because a
gauge draws its own ring and takes its colour from the widget rather than from us. So the
gauge is kept for its layout and hidden, and the ring is drawn into it. Two things are
load-bearing: the gauge's label is an image and not an `EmptyView`, which is what collapsed
it to a dot, and there is no `fixedSize`, because that is the app's number and not the
widget's.

Past the goal the ring keeps going, in one shade the whole way round — it should read as
one ring that went further, not as a ring that started over. What separates the second lap
from the first is a soft shadow laid just ahead of its leading end. A shadow rather than a
second colour, because a watch face and the lock screen render a complication in a single
colour: a difference in brightness survives that, a difference in hue does not.

Every ring carries a tick showing where the day's pace says you should be by
now, spread evenly across the drink window from the reminder settings — ahead of the tick
you're on track, behind it you're falling back. The complication has no room for a unit, so it shows
the number alone; whether that number is ounces or millilitres follows the app's setting. The phone spends a budgeted
complication transfer only when the number on the face would actually change.

The number inside a ring is sized for three digits and left there, rather than sized for
the ring and shrunk to fit: `minimumScaleFactor` only ever shrinks, so a font big enough to
need it at 103 did not need it at 52, and the number grew and shrank as the day went on.
The temperature in Weather's circle holds still, and so does this.

The home-screen sizes are dark whatever the phone's appearance, to sit with the widgets
they sit among. The lock-screen sizes are left to the system, which renders those itself.

## One question, one answer

How much water was drunk on a given day is asked in three places — Today, a day opened
from Progress, and the row in the day list — and for a while they answered differently.
The row read a HealthKit statistics collection query; the others summed the samples. On a
real account the collection query came back with exactly the day's samples *minus the ones
this app had written*: two days checked, each short by precisely our own contribution,
while a sample query over the same window returned all of them. Whatever the cause, the
lesson stands on its own — `dailyTotalsML` now buckets the samples itself, so every screen
is answered by one query under one rule.

`AppState.dailyTotals(days:)` adds the drinks this app holds that never reached Health, the
same as a single day does, so a failed write cannot put a row out of step with the day it
opens either.

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

## More than one bottle

The Bottle tab is a list, and **Add Bottle** appends to it. Each row opens onto everything
about that bottle: what's in it, when it was calibrated, its model, firmware and serial,
a name you can give it, and the two ways of being done with it — Forget This Bottle, and
a red Disconnect at the bottom that stops the app connecting to it until you tap Connect
again.

Exactly one bottle is in use at a time, marked **Active** in the list, and the app picks
it: the closest one. Everything about that is per bottle — a bottle's calibration, its
level and the baseline the tracker measures against live under its own keys, and switching
points the model at another set of them, because a reading is only meaningful through the
calibration of the bottle it came from. The bottle carried over from before there was a
list keeps the keys it already had, so nothing about it is lost.

The identity a bottle is filed under is its **advertised name** (`h2oDB618BB`), not its
CoreBluetooth identifier: a PRO 2 changes its Bluetooth address every quarter of an hour,
so the identifier is only ever the address it happened to be wearing. The address is kept
alongside as a hint and replaced whenever the bottle turns up under a new one.

### Which one is closest

Radio strength stands in for distance, and it is a noisy stand-in: two bottles on the same
desk trade places several times a minute, and every trade would cost a disconnect, a
handshake and a hole in the weight stream. So `ProximitySelector` makes a challenger earn
it. It has to be heard **8 dB louder**, keep that lead for **30 seconds**, and wait until
the bottle in possession has had a **two-minute turn**. Two bottles the same distance apart
therefore never trade — the margin is never met — while one you actually pick up takes over
within half a minute. A bottle that has gone quiet for three minutes hands over at once,
with no margin and no waiting, and one you pick by hand gets a full turn before the radio
is allowed to change its mind.

Hearing the other bottles takes a scan, and a scan costs battery, so it is duty-cycled:
six seconds of listening every forty-five, and only when there is more than one bottle to
choose between. The connected bottle stops advertising, so it can't be heard that way —
it is asked directly with `readRSSI()` at the top of each window, which is the only reading
comparable with the ones that are still advertising.

CoreBluetooth allows one scan at a time and three things want one — the Add Bottle sheet,
a reconnect chasing an address change, and this — so the client holds them as a set of
purposes and the widest wins. Only the sheet asks for repeat advertisements, because only
it is showing live signal strength; the other two get one sighting per scan, which is far
less radio and far less log.

## Calibration, and the zero that won't sit still

Two numbers describe the bottle's scale: how many raw units a millilitre is worth, and
where empty sits. Only the first is stable. Measured across a morning's session log, the
resting reading drifts about **5 mL a minute** while nothing is happening, and it changes
sign — it ran +3 mL/min before the bottle was emptied and −5 to −9 mL/min for an hour
afterwards, decaying as it went. That is load-cell creep after a change in weight, not
noise, and it means an absolute calibration is stale within the hour.

So the app stops treating a full calibration as the fix for drift:

* **Re-zeroing keeps the scale and moves only the empty point** — `rezeroed(toEmptyRaw:)`.
  A drink measured before a re-zero measures the same after it, because only the origin
  moved, so the tracker carries on uninterrupted.
* **A bottle's page has a one-tap "Bottle is empty — set the zero"**, which is the whole
  correction. Measuring full again is unnecessary.
* **It also happens on its own.** A bottle cannot hold less than nothing, so settled
  readings that stay more than 25 mL below empty for three samples and 45 seconds mean the
  zero has moved; the app moves it back and logs that it did. Before this, every one of
  those readings was discarded as "bottle lifted" and nothing was logged at all — one real
  session sat at −675 mL, tracking nothing, for over an hour.
* **Unless it stepped there.** A bottle held in a hand also reads below empty, also holds
  still, and does it for as long as you carry it. It is told apart by how it arrived:
  drift creeps a millilitre or two per reading, while picking the bottle up is a cliff of
  several hundred in one fifteen-second step, and no drink can match it — a bottle already
  reading near empty has nothing like that left to give. See below for what happens when
  this rule isn't there.

The trade: if the bottle drifts down far enough while it still holds water, the automatic
re-zero will call that empty and the displayed level will be wrong until the next refill.
Intake is unaffected — the tracker measures differences, and a drink after a re-zero still
reads as a drink — and being wrong about the level beats discarding every reading.

The zero also creeps *upward*, and there is no matching fix: a zero is captured from an
empty bottle, and one with water in it has nothing to say about where empty sits. So when
the scale reads more than the bottle can hold, the Bottle tab says so and asks for the one
thing that settles it — an empty bottle and the button above.

Calibrating itself is two numbered steps — empty, then full — each with one button, and it
saves the moment both readings are in and make sense. The raw units, the span and the
scale that used to be on that screen are diagnostics rather than instructions, and they
have moved to **Settings → Debug → Calibration**.

## Picking the bottle up

Nothing the water does can move more of it than the bottle holds, so a reading that moves
further than that between two readings taken seconds apart is the bottle itself being
picked up or set down. The tracker calls that *handled*: no drink, no refill, and the
baseline is held where it was so that setting the bottle back down is a change of nothing.

That one rule is the whole of it for a full bottle, whose lift displaces more than a
bottleful. A nearly empty one displaces less, but lands far below empty, where the older
lifted-reading rule has it. What falls between the two is a drop of half a bottle or so
that still looks plausible — and those are held back and only logged once they have stayed
down for a minute. A bottle that was only carried comes back long before that; water that
was drunk never does. Ordinary sips are logged the moment they are seen, as before: it is
only drops past half the bottle that wait, and they are rare.

The one thing that shape cannot separate is drinking half the bottle and refilling it to
the same level inside that minute, which is a lift as far as the scale is concerned; that
drink is dropped and has to be logged by hand. It is the right way round to be wrong. A
missed drink is visible and can be added; an invented one is written to Apple Health
without anyone being asked.

This is worth the machinery because of what one lift did on 4 September. The bottle was
picked up at 13:28 and held for two and a half minutes; every reading came back 1 117 mL
below where it had been resting, which is the weight of the bottle and its water and not a
possible amount of drinking. The old code discarded each of those readings as "lifted" and
then handed the same readings to the automatic re-zero, which found three of them, 45
seconds apart, below empty — and moved the zero onto a bottle that was in the air.

From that moment the scale read about 1 100 mL in a 621 mL bottle. Every reading was wrong
by the weight of the bottle, and nothing said so. Being permanently past the fill line,
each 15 mL of ordinary upward creep counted as topping the bottle off, ratcheting the
baseline from 804 mL to 1 209 mL over the afternoon. And the next two lifts — the bottle
picked up by its lid, at 17:17 and 17:22 — measured drops of 737 mL and 735 mL against
that baseline, which the app logged as drinks and wrote to Apple Health as 24.9 oz each.

Replaying that session log through the rules above produces neither the re-zero nor either
drink, and leaves every real drink of the previous two days standing. Three more phantoms
of the same shape (531 mL, 598 mL, 763 mL) and a second corrupting re-zero go with them.

## The level the app shows

Not the one on the scale. The scale's zero creeps by hundreds of millilitres an hour, so
the app carries a level forward instead: it starts from a known point and moves only when
the tracker reports a drink or a refill. Differences are taken over seconds, where creep
is nothing, so the displayed level holds still while the bottle does.

It comes back into step at two moments. Emptying the bottle re-zeros it to nothing, and
adding most of a bottleful in one go sets it to full — the water had nowhere else to go,
so that is the one refill whose result is known from a difference alone. A smaller top-up
only adds what went in.

Between those, a missed event leaves it out of step, and the Bottle tab shows what the
scale says alongside it once the two differ by more than 20 mL.

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

## The bottle's light

The bottle only lights up for three things: a drink the app logged, reaching the day's
goal, and its own scheduled glow reminders, which the firmware runs from the slot table
written during the connection handshake.

The handshake also left the light doing something on every connect. Since the PRO 2 drops
the link roughly every fifteen minutes, that is a flash four times an hour for nothing, so
the client writes a byte of its own as soon as the handshake finishes: the off byte
(`0x00`) by default, or the green glow (`0xB4`) with **Settings → Bottle light → Glow when
connected** turned on. It is off by default, for the same four-times-an-hour reason. The
three lights above all happen after that point, so none of them are affected.

Settings offers the three lights and nothing else. The colours are firmware presets and
picking between them is a thing to test rather than a thing to set, so the list of them —
each firing on the connected bottle when tapped — is in **Settings → Debug → Light
patterns**, along with the raw byte for the drink light.

## When a drink goes missing

Every settled reading now gets a line in the session log when there is anything to say
about it — the first of a session, one taken with no baseline to compare against, one
below empty, or one that recovered a drink across a disconnect. A drink that is silently
dropped otherwise leaves no trace at all, which made the first real report of one take a
log dump and a lot of arithmetic to explain.

Two things were dropping them. The drift correction assumed the resting reading falls
15 mL a minute, which over the bottle's usual quarter-hour disconnect subtracted 225 mL
from any observed drop — more than a third of the bottle, so a drink taken while it was
away was corrected out of existence. Session logs put the real figure nearer 3 mL a
minute, wandering up as readily as down, so that is the default now, capped at 40 mL
however long the gap.

The other is worse and quieter. CoreBluetooth relaunches this app when the bottle
reconnects, and that often happens while the phone is locked — where its stored
preferences read back empty. The app then comes up with no calibration, and `trackLevel`
returns at its first guard: the level looks right on screen but every reading is dropped
and nothing is ever logged. `reloadPersistedStateIfNeeded()` re-reads what was missing
when protected data becomes available, when the app comes forward, and on every
background refresh.

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

1. **Bottle tab → Add Bottle**, tap your `h2o…` bottle. Add as many as you own; the
   closest one is the one in use.
2. **Bottle tab → your bottle → Calibration**: take the empty reading (dry, lid on, on a
   table), then the full one. It saves itself and the bottle glows green.
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
