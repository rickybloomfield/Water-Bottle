# HidrateSpark BLE protocol notes

Everything here is reverse engineered by the community and by this project. Nothing is
vendor documented, and firmware revisions differ. Field-verified statements are marked
**verified**; the rest are hypotheses to test with the Explore tab or `hidrate-cli`.

Sources: [HydroSync](https://github.com/maxperron/HydroSync) (handshake bytes),
[wban-python](https://github.com/choonkiatlee/wban-python) (Spark 3 decompile notes),
[HidrateSpark-MQTT-bridge](https://github.com/loryanstrant/HidrateSpark-MQTT-bridge) and
[HA-HidrateSpark-Bluetooth-Proxy](https://github.com/loryanstrant/HA-HidrateSpark-Bluetooth-Proxy)
(PRO firmware 80.18 on nRF52832: weight, cap, frame layout).

## Discovery

* Advertised local name starts with `h2o`, e.g. `h2oDB618BB`. **verified**
* The bottle accepts **one central at a time**. While the official app holds the link,
  nothing else can connect. Close the app (or revoke its Bluetooth permission). **verified**
* The bottle keeps advertising after it has been paired with the official app. No BLE
  bonding is required; all characteristics are open. **verified**
* Advertisements carry the Reference service UUID `45855422-…`, so a central can scan for
  that service (this also works from the iOS background). **verified** on a PRO 2
  (`h2o00008823`, 2026-09-03).
* **The bottle changes its Bluetooth address.** Observed on 2026-09-03: after a disconnect
  the PRO 2 came back under a different CoreBluetooth identifier (`3540F042…` became
  `97E619C6…`). Without bonding, iOS cannot recognise the new address as the same device,
  so a pending `connect()` to the old identifier never completes. Any client must re-scan
  by name (`h2o…`) or service and connect to whatever identifier it finds. This is almost
  certainly why the official app scans constantly and why it feels flaky. `HidrateBottleClient`
  scans for the service while a connect is pending and switches automatically. **verified**

## Services and characteristics

| Service | Characteristic | Props | Meaning |
|---|---|---|---|
| `BF2D1BA0-C473-49F2-9571-0CE69036C642` User | `BF2D1BA1-…` | notify, write | Sip records (modern firmware). Write `0x57` to drain one record. |
| `45855422-6565-4CD7-A2A9-FE8AF41B85E8` Reference | `016E11B1-6C8A-4074-9E5A-076053F93784` | notify, write | Sip records (legacy, present on 80.18). Same drain protocol. |
| Reference | `B44B03F0-B850-4090-86EB-72863FB3618D` | write | Set Point: time of day, reminder schedule, glow. |
| Reference | `316C4914-…` | read, write | 6 bytes, unknown. |
| `593F756E-FAFC-49BA-8695-B39CA851B00B` Debug (Spark 3) or Reference (PRO) | `E3578B0D-CAA7-46D6-B7C2-7331C08DE044` | write, notify | Handshake writes; notifies cap state. |
| `F65399A1-D953-472D-8CA9-1AC71C4FFCB8` Sensor | `1807A063-4E2D-4636-981A-35E93D1C7B94` | notify | Weight, u16 big-endian, ~every 2 s. |
| Sensor | `68485D94-…` / `13220723-…` / `603FC2C1-…` | | Accelerometer X/Y/Z (Spark 3). |
| `4F817071-4180-434A-982B-422B4C9E6611` LED | `A1D9A5BF-F5D8-49F3-A440-E6BF27440CB0` | write | LED pattern byte. `0x02` short white pulse, `0x34` three triple pulses, `0x16` red strobe. |
| LED | `B810E826-…` | read | LED state readback. |
| `180F` Battery | `2A19` | read, notify | Percent. |
| `181A` Environmental | `2A6E` | notify | Temperature, never seen firing. |
| `6E400001-…` Nordic UART | `6E400003-…` | notify | Never seen firing on 80.18. |
| `75C276C3-…`, `22669E4C-…`, `8D53DC1D-…` | various | notify | Unknown, never seen firing. |
| `FE59` Nordic Secure DFU | | | If present, firmware updates are signed Nordic DFU packages (see FIRMWARE.md). |

The SDK subscribes to every notifying characteristic and surfaces the unknown ones as
"undecoded values" so new firmware behaviour is visible immediately.

## HidrateSpark PRO 2 (firmware 100.64.0) GATT table

Read from Ricky's bottle `h2o00008823` on 2026-09-03 (Device Information: manufacturer
`HidrateSmart LLC`, model `HidrateSpark PRO 2`, hardware `Sensor-SM-V1`, firmware
`100.64.0`). It differs materially from the community's PRO v1 / 80.18 table above:

| Service | Characteristics | Notes |
|---|---|---|
| `87290102-3C51-43B1-A1A9-11B9DC38478B` | `6AA50001…000A` (9 × read) | Unknown read-only block (vendor / calibration data?). |
| `1804` Tx Power | `2A07` read | Standard. |
| `00010203-0405-0607-0809-0A0B0C0D1912` | `…0C0D2B12` read, writeNR, notify | **Telink OTA service.** The puck is a Telink SoC (see FIRMWARE.md). |
| `3BBD83E0-09BD-4B2D-A4E2-03E37694252B` | `…83E1` write; `…83E2` read/write/writeNR | Unknown command channel A. |
| `3BBD83F0-…` | `…83F1` write; `…83F2` read/write/writeNR | Unknown command channel B. |
| `180A` Device Information | 2A24, 2A25, 2A26, 2A27, 2A29 | As above. |
| `180F` Battery | `2A19` read/notify | 86 % at the time. |
| `45855422-…` Reference | `016E11B1` read/write/notify (Data Point, **legacy path**); `316C4914` read/write; `B44B03F0` write/**notify** (Set Point) | No `BF2D1BA0` user service, so the legacy sip channel is used. Set Point can notify (command replies?). |
| `4F817071-…` LED | `A1D9A5BF` write; `B810E826` read/write | As above. |
| `593F756E-…` Debug | `E3578B0D` read/write/notify | Own service, like the Spark 3. |
| `F65399A1-…` Sensor | `1807A063` read/notify (weight); `2007A063` read/notify (unknown) | Weight notifies only every ~15 s (raw ≈ 24990 at the time), so the SDK polls it by reading every 3 s. |

Absent: Nordic DFU (`FE59`), Nordic UART, Environmental Sensing, accelerometer characteristics.

Open questions being logged by the app: whether `0x57` on Data Point returns records on
this firmware (the first drain got no reply), what Set Point notifies, and what
`2007A063`, the `3BBD…` channels and the `6AA5…` block contain.

## Handshake (required before sip records flow)

13 writes, 50 ms apart, captured from the official app and replayed verbatim by every
community client. **verified** to unlock sip notifications on Spark 3 and PRO.

| # | Char | Bytes | Decoded (hypothesis) |
|---|---|---|---|
| 1 | Debug | `21 00 d1` | unknown |
| 2 | Set Point | `92` | "SetGoalGlow" in the decompiled app |
| 3 | Debug | `22 00 f7` | unknown |
| 4 | Set Point | `77 00 00 00 32 d7 00 00` | opcode `0x77` SetTimeInSec, bytes 4..7 LE u32 = 55090 s = 15:18:10 |
| 5 | Set Point | `00 34 1b 00 e0 79 00 00` | slot 0, opcode `0x34`, target 27, 31200 s = 08:40 |
| 6 | Set Point | `02 34 52 00 c0 a8 00 00` | slot 2, target 82, 12:00 |
| 7 | Set Point | `03 34 6e 00 30 c0 00 00` | slot 3, target 110, 13:40 |
| 8 | Set Point | `04 34 89 00 a0 d7 00 00` | slot 4, target 137, 15:20 |
| 9 | Set Point | `05 34 a5 00 10 ef 00 00` | slot 5, target 165, 17:00 |
| 10 | Set Point | `06 34 c0 00 80 06 01 00` | slot 6, target 192, 18:40 |
| 11 | Set Point | `07 34 dc 00 f0 1d 01 00` | slot 7, target 220, 20:20 |
| 12 | Set Point | `08 34 00 00 00 00 00 00` | slot 8 unused |
| 13 | Set Point | `09 34 00 00 00 00 00 00` | slot 9 unused |

Decoding evidence: the eight `0x34` slots are evenly spaced (100 min apart from 08:40 to
20:20) with targets rising in equal steps of 27.5 to 220, so they are almost certainly
the glow-reminder schedule (cumulative goal target per checkpoint). Slot 1 (10:20, 55)
is missing from the original capture; the bottle does not care. The `0x77` time field
shares the same offset and the same LE u32 seconds-since-midnight encoding.

`HidrateHandshake.computed()` builds the same sequence with the real time of day and
empty reminder slots. It is exposed as an option, not the default, until it is proven
on your bottle. Note that replaying the captured bytes sets the bottle's clock to 15:18
on every connection; whether that matters depends on what the firmware uses its clock for
(likely only the glow reminders, since sip records carry no timestamp).

## Sip records

Subscribe to the data characteristic (modern or legacy), then write `0x57`. Each drain
returns one 20-byte frame; keep draining while byte 0 is non-zero. A frame with byte 0 =
0 and all zeros means the queue is empty. After a drink the bottle spontaneously sends
`0N 00 00 …` (N pending, no payload); drain to fetch the records. **verified**

```
[0]      records still pending (after this one)
[1]      sip volume as percent of the bottle's configured capacity
[2..3]   running total for the day, LE u16, a sum of the percent field (resets around midnight)
[4]      flags: 1, 4, 8 observed
[5..7]   00 00 00
[8..11]  75 87 2a 8b, constant on the logged bottle
[12..13] raw weight before the sip, LE u16
[14..15] raw weight after the sip, LE u16
[16..19] 00 00 00 00
```

Evidence: consecutive frames chain (`after` of one equals `before` of the next), the
running total increases by exactly the percent field, and raw delta per percent is
9.5–10.5 across every good frame. There is no timestamp anywhere in the frame; earlier
decoders read the constant at [8] as "seconds ago" and back-dated every sip by 117 s.
A corrupt frame with percent = 100 has been seen in the wild; `SipRecord.isPlausible`
rejects it by cross-checking the weight pair.

The percent field depends on the bottle size configured in the bottle by the official
app. The weight pair does not, which is why this SDK prefers calibrated weight.

## Weight

Two bytes, big-endian, roughly every 2 seconds while connected. The full u16 rises
linearly with water volume at about **1.305 raw units per mL** (946 mL bottle: empty
35880, full 37115). Readings while the bottle is lifted, tilted or being set down are
garbage; there is no reliable orientation flag, so `StableWeightFilter` waits for N
consecutive samples within a small tolerance. **verified** on 80.18 (Steel/PRO).

An earlier reading of this stream treated the high byte as orientation (`0x8A` upright,
`0x84` tilted, `0x88` settling) and the low byte as weight. That breaks as soon as the
low byte wraps, so it was superseded; the high byte is exposed on `WeightSample` in case
it turns out to carry state on other firmware.

## Cap state

Notifications on the Debug characteristic: `81 02 00 00` open, `80 02 00 00` closed.
Bit 0 of byte 0 is the flag. **verified** on 80.18.

## Things worth trying with the Explore tab

* Read the Device Information service (`180A`) to confirm the firmware revision.
* Check whether `FE59` (Secure DFU) is in the GATT table.
* Watch the undecoded-values list while opening the cap, shaking the bottle and
  charging; anything new goes in this file.
* Switch the handshake to "computed" and confirm sip records still arrive.
