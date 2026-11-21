# ADR 0010: The LED matrix maps its registers through relaxed /dev/mem

- **Status:** Proposed
- **Date:** 2026-11-21
- **Related Artefacts:**
    - Builds on: ADR 0009 (rpi01 runs its board's release)
    - Implemented in: `modules/services/led-matrix.nix`, `packages/rpi-rgb-led-matrix`

## Context

rpi01's matrix library (hzeller/rpi-rgb-led-matrix) drives the panels by mapping the BCM2711's registers through `/dev/mem`. The vendor kernel from ADR 0009 is built with `CONFIG_IO_STRICT_DEVMEM`, under which `/dev/mem` refuses to map any region a driver has claimed - even to root. Run as root on rpi01, the library could not map the GPIO block (claimed by pinctrl) or the clock manager (claimed by the clock driver); the 1MHz counter and the PWM block, which nothing claims while onboard audio is off, mapped fine. The bonnet has GPIO4 bridged to GPIO18, so the PWM block can time the panels' output-enable pulses - the library's fix for flicker, which matters at the 30-40Hz four chained 64x64 panels refresh at. That pulse generator needs the clock manager.

## Decision

GPIO comes through `/dev/gpiomem`, by a patch to the library that falls back to it when `/dev/mem` refuses the GPIO block. The clock manager comes through `/dev/mem` with the kernel parameter `iomem=relaxed`, which the service module adds only for the hardware-pulsing mapping. The service holds root only to initialise, inside a unit bounded to `CAP_SYS_RAWIO`, `CAP_SYS_NICE`, `CAP_SETUID` and `CAP_SETGID`, then drops to its own user.

## Consequences

**Positive**

- Hardware pulsing works with no kernel rebuild and no out-of-tree driver.
- What `relaxed` gives back is little on this host: it applies to root only, and rpi01 does not lock module loading or enable lockdown, so root could already load a module that maps anything.

**Negative**

- rpi01 departs from the fleet's strict `/dev/mem` default; a root compromise there can rewrite any claimed device's registers without loading a module.
- If module loading is ever locked on rpi01 (`kernel-hardening`'s `paranoid` level, or #394's lockdown), this becomes the widest root-to-kernel path left there, and should be revisited then.
- The library carries a local patch.

## Alternatives considered

- **The plain `adafruit-hat` mapping, strict /dev/mem kept.** Needs only the patch and leaves the kernel default alone, but times the pulses in software on a display already refreshing slowly enough to flicker.
- **The kernel's own PWM driver and clock framework.** The supported route to the same hardware, but the library has no backend for it, and binding the driver would claim the PWM block and close the one register range that maps today.
- **A kernel built without `IO_STRICT_DEVMEM`.** The same exposure as `relaxed`, but a kernel no cache has prebuilt (ADR 0009 depends on nixos-raspberrypi's cache).
