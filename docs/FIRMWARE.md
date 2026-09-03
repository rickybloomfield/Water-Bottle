# Firmware: what is realistic

## What we know about the hardware

* **PRO v1 / Steel** pucks (community, firmware `80.18`) run a **Nordic nRF52832** and
  expose Nordic **Secure DFU** (`FE59`). Secure DFU packages are signed (ECDSA P-256) with
  the vendor's key; the bootloader rejects anything else.
* **PRO 2** (Ricky's bottle, model `HidrateSpark PRO 2`, hardware `Sensor-SM-V1`, firmware
  `100.64.0`, read 2026-09-03) is different: no Nordic services at all, but it exposes the
  **Telink OTA service** (`00010203-0405-0607-0809-0A0B0C0D1912` / `…2B12`). That is the
  stock OTA profile from the Telink BLE SDK (TLSR825x / TLSR9 family). This changes the
  picture considerably:
  * Telink's classic OTA protocol is simple and documented by the SDK: `FF00` firmware
    version query, `FF01` OTA start, then 20-byte packets (2-byte index, 16 data bytes,
    CRC16), `FF02` OTA end. It is what the community web flashers for Telink-based
    thermometers (pvvx's ATC firmware) use.
  * Whether *this* bootloader verifies a signature is unknown. Older Telink SDKs only
    check a CRC and a firmware "flag" byte; newer ones support secure boot. The first
    experiment is to read the OTA characteristic and issue `FF00` to see if a version
    comes back; the second is a teardown or the FCC ID to identify the exact SoC.
  * Telink chips are programmed over a single-wire "SWS" interface with a cheap
    programmer, and flash readback is possible unless protected. A dump of the shipping
    firmware makes the OTA path far safer (you can always restore it).
  * Risk: a failed unsigned OTA can brick the puck. Do not push anything until you have
    a full flash dump via SWS and know the bootloader's expectations.

## Paths to custom firmware

1. **SWD access.** Open the puck, find the SWD test pads (SWDIO/SWCLK/GND/VDD), attach a
   J-Link or a Raspberry Pi Debug Probe, and try `nrfjprog --readback` / OpenOCD. If
   `APPROTECT` is disabled you can dump the application and softdevice, reverse them in
   Ghidra (the nRF52 SVD files help), patch, and reflash. If APPROTECT is enabled the
   nRF52832 is vulnerable to a well-documented voltage-glitch bypass (LimitedResults,
   2020); that needs a glitcher (e.g. a ChipWhisperer or a PicoEMP) and patience.
2. **Replace the firmware entirely.** Once you have SWD, you can also drop in your own
   Zephyr or nRF Connect SDK application that reads the load cell / capacitive sensor,
   exposes a clean GATT service, and behaves nicely as a peripheral (sane advertising
   interval, no aggressive connection-parameter requests). You lose the official app
   for good, but you were planning to.
3. **Leave the firmware alone and fix the central.** Most "the bottle breaks Bluetooth
   on my iPhone" symptoms are caused by the official app: it scans continuously, keeps a
   background connection open, and reconnects aggressively. A well-behaved central
   (connect, sync, use a modest connection interval, disconnect when idle or keep one
   quiet link) usually makes the problem disappear without touching the puck.

## Update: custom firmware is not needed for intake

An HCI sniff of the official app (see PROTOCOL.md) showed the PRO 2 streams live weight and
emits sip records once it receives the app's full init, and that the sip drain byte is
`0x55`/`0x33`. HidrateKit now replays that init and reads intake directly. Firmware work is
now optional, for fixing the annoyances below rather than for basic function.

## A concrete firmware defect worth fixing

The PRO 2 puck drops its connection and changes its Bluetooth device address roughly every
15 minutes without offering a bond (see PROTOCOL.md). Address rotation is a privacy feature, but it is only workable
when the peripheral bonds so the phone can resolve the new address; without that, every
reconnect needs a full scan, which is exactly the behaviour that keeps the official app
busy and the iOS Bluetooth stack under load. If custom firmware ever happens, the fix is
either a random static address that never changes, or LE Secure Connections bonding with a
resolvable private address. Until then, the SDK works around it by scanning.

## Recommended order

1. Use `HidrateTestApp` to characterise the current behaviour: firmware revision, GATT
   table, whether DFU is exposed, how often it notifies, and whether the iOS Bluetooth
   issues persist with the official app closed and this app connected.
2. Capture a Bluetooth trace on the Mac (Xcode → Additional Tools → PacketLogger, or
   `sudo log stream --predicate 'subsystem == "com.apple.bluetooth"'`) while the official
   app is running and again with this app, and diff the connection parameters and
   advertising behaviour. That tells you whether the fault is firmware or app.
3. Only if the firmware itself misbehaves (e.g. requests a 7.5 ms connection interval
   forever, or floods advertisements) is opening the puck worth it. At that point start
   with SWD readback.

## Not in scope for this SDK

The SDK deliberately does not implement Nordic DFU. If a use case for pushing official
signed packages appears (e.g. updating without the official app), Nordic's
`iOSDFULibrary` can be added as a dependency and driven with the `.zip` the official app
downloads.
