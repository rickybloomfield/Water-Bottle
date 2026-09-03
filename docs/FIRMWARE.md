# Firmware: what is realistic

## What we know about the hardware

* The sensor puck runs a **Nordic nRF52832** (community-confirmed on the Steel/PRO puck
  reporting firmware `80.18`). The PRO 2 puck is believed to be the same family; the
  Explore tab's Device Information readout will tell you the exact firmware string.
* The GATT table includes a Nordic UART service, and community bottles expose the Nordic
  **Secure DFU** service (`FE59`). Secure DFU packages are signed (ECDSA P-256) with the
  vendor's private key; the bootloader rejects anything else. That is why "improve the
  firmware and push it over the air" is not an option without Hidrate's key.

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

## A concrete firmware defect worth fixing

The PRO 2 puck changes its Bluetooth device address between sessions without offering a
bond (see PROTOCOL.md). Address rotation is a privacy feature, but it is only workable
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
