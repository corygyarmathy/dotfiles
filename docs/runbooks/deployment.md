# Deployment pipeline

Both servers follow the promoted `deploy` ref nightly (ADR 0001): CI builds
every host and runs the VM-test checks before `deploy` moves; upgrades run at
04:00 / 04:15 AWST with reboots confined to 04:00-05:00. Activation
verification (`nixos-upgrade-verify`) checks a generation's critical units
came up healthy after switching; boot counting lets systemd skip a kernel
that repeatedly fails to reach userspace. Rollback-to-previous-generation is
**currently disarmed** on both hosts - verification reports, it does not
revert.

Telemetry lives in the `nixos_deploy_*` / `nixos_verify_*` metrics, visible
on Fleet Overview's "Pipeline health" panel.

## NixosUpgradeFailed

**Severity:** warning · **Fires when:** the `nixos-upgrade.service` unit is
in failed state.

### Do now

- `ssh <host> journalctl -u nixos-upgrade -n 100 --since yesterday`
- Distinguish: build failure (network/nixpkgs), activation failure, or
  post-activation check tripping because some unrelated unit was already
  failing. The service exits non-zero if any unit fails once activation has
  finished - that usually means the new generation activated fine and
  something else is unhappy.

### Fix

- Read which generation is running first:
  `readlink /run/current-system`. Fix forward via the repo; do not hand-rebuild
  over the fleet mechanism unless recovering.

## NixosDeployFailed

**Severity:** warning · **Fires when:** the last upgrade run recorded
failure for 10+ minutes.

### Do now

Same as [NixosUpgradeFailed](#nixosupgradefailed) - they describe the same
event from metric and unit angles.

## NixosDeployStale

**Severity:** warning · **Fires when:** no upgrade run of any outcome has
been recorded in 48 hours. This is the silence-catcher: a stopped timer,
broken network, dead GitHub ref or dead host raises nothing else.

### Do now

- `ssh <host> systemctl list-timers nixos-upgrade*` - when does it say it
  will next run / when did it last fire?
- `systemctl status nixos-upgrade.timer nixos-upgrade.service`
- Can the host reach github.com? `curl -sI https://github.com | head -1`
- Is `deploy` still moving? If YOU paused merges, expect this alert and
  silence it rather than fixing.

## NixosRebootPending

**Severity:** warning · **Fires when:** a generation with a new kernel is
staged but never activated for 26+ hours. The usual cause: the nightly build
ran long enough to miss the 04:00-05:00 reboot window, and nixos-upgrade
reports success while the new kernel waits for the next reboot.

### Do now

- `ssh <host> nixos-version` vs what `deploy` points at; confirm staged vs
  booted kernel: the two `readlink`s from deploy-metrics
  (`/run/booted-system` vs profile).
- Harmless to leave for days UNLESS the staged change matters (security
  fix). Reboot inside the window, or accept until tomorrow night.

### Fix

- Chronic misses mean builds are too slow for the window: widen the window or
  start the upgrade earlier. Change in `hosts/<host>/default.nix`.

## NixosVerifyFailed

**Severity:** critical (buzzes) · **Fires when:** activation verification
found critical units failing that were not failing before the upgrade - the
new generation came up broken.

### Do now

- `ssh <host> journalctl -u nixos-upgrade-verify.service` - it names the
  failing units.
- Is the host serving? Fleet Overview probe table + tunnel connections answer
  faster than ssh.
- Check whether this generation was applied by hand
  (`nixos_verify_manual_generation` metric / verify journal): hand-applied
  generations are judged but never rolled back.

### Fix

- Identify the failing unit, fix in repo, push through the normal gate. The
  previous generation is still fine to fall back to manually
  (`sudo /nix/var/nix/profiles/system-<n>-link/bin/switch-to-configuration switch`)
  if the breakage is urgent and the fix is not.

## NixosRollbackFailed

**Severity:** critical · **Fires when:** verification decided to revert and
could not complete the revert. Currently disarmed rollback means this should
not fire; if it does, someone armed rollback and it misfired - treat as the
most serious deployment alert there is.

### Do now

- `journalctl -u nixos-upgrade-verify.service`. The alert text distinguishes
  failed-generation-still-running (act now) from services-reverted-but-
  bootloader-not (fix before next reboot).

## NixosVerifyStale

**Severity:** warning · **Fires when:** a generation was activated and
verification has not recorded a result within 6 hours - the safety net itself
stopped running. Absence of verify failures means nothing if verification is
dead; that is why this exists.

### Do now

- `ssh <host> systemctl status nixos-upgrade-verify.timer` and its journal.
- Hand-applied generations are now re-checked on a schedule, so a manual
  rebuild should NOT cause this anymore - if it does, the recheck timer is
  the thing that broke.

## NixosRolledBack

**Severity:** critical · **Fires when:** a host actually reverted itself to
its previous generation. Like RollbackFailed: impossible while rollback is
disarmed, so firing means rollback got armed and worked - the host is running
older code than `deploy` and will be offered the same revision again tonight.

### Do now

- Find WHY verification rejected it (verify journal), fix forward in the repo,
  and make sure the fix reaches `master` + promotion BEFORE tonight's run or
  the host will bounce between generations nightly.
