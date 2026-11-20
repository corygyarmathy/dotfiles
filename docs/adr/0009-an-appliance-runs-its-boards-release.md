# ADR 0009: An appliance runs its board's release, unprotected

- **Status:** Accepted
- **Date:** 2026-11-20
- **Related Artefacts:**
    - Departs from: ADR 0002 decision 2 (protection at activation), for `appliance` hosts only
    - Introduced in: #435 (rpi01)

## Context

rpi01 is a Raspberry Pi 4 driving an Adafruit RGB Matrix Bonnet. The matrix library (hzeller/rpi-rgb-led-matrix) drives the BCM2711's GPIO and PWM registers directly and is developed against the Raspberry Pi Foundation's vendor kernel and device tree. nvmd/nixos-raspberrypi packages that stack for NixOS and serves it prebuilt from its own cache, but it maintains it only against the stable NixOS release, and unstable's NixOS modules do not evaluate against its kernel. Until now every host was built from one nixpkgs, one home-manager and one stylix, and every host followed `deploy` with the activation protection of ADR 0002.

Nothing else in the fleet depends on the Pi. It hosts no data, serves no other host, and losing it for a day costs a dark sign.

## Decision

**1. A host may be built from a different release channel.** A fleet entry may name a `channel`, which picks a release-matched set of nixpkgs, home-manager and stylix in `mkHost`. Hosts default to unstable. A host on another channel imports the shared `modules/nixos` modules by name, and only modules that evaluate on both releases.

**2. Board support comes from the vendor's flake, which keeps its own nixpkgs.** `nixos-raspberrypi` does not follow our nixpkgs, so its kernel stays a cache hit instead of a long build on every lock bump.

**3. `appliance` is a third host kind.** An appliance has a reserved address so it resolves by name, but it is not scraped, peered or backed up, and nothing may assume it is up.

**4. An appliance follows `deploy` and reboots unattended, without activation protection.** It has no boot counting (extlinux, not systemd-boot), no upgrade verification and no monitoring. A revision that fails to boot leaves it offline until someone notices. This is accepted because nothing depends on it and recovery is reflashing an SD card from a CI-built image.

## Consequences

**Positive**

- The vendor kernel and firmware substitute from a cache rather than being compiled, on CI's arm64 runner and on the laptop.
- The appliance stays on the same pipeline as every other host: built by CI, promoted through `deploy`, deployable with deploy-rs.

**Negative**

- Two releases of nixpkgs, home-manager and stylix are locked and move independently.
- A shared module that every host must evaluate has to be added to the appliance's import list by hand, and has to evaluate on both releases.
- The appliance's build is part of the gate, so a vendor flake bump that outruns its cache slows promotion for the whole fleet.
- README's promise that a host which stops updating raises an alert does not cover an appliance.

## Alternatives considered

- **nixpkgs' generic aarch64 SD image with nixos-hardware's `raspberry-pi-4` on unstable.** One channel and no hand-kept module list, but a kernel the matrix library is not developed against, and no verified hardware run.
- **Leave the Pi out of the flake.** No coupling to the gate, but its configuration would drift outside CI, SOPS and the deploy pipeline.
- **Stage updates without rebooting.** Safer against a bad kernel, but it leaves the Pi running an old kernel until someone reboots it by hand, for a host where a failed boot costs little.
