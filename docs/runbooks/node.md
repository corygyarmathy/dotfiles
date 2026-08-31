# Node vitals

Host-level alerts: reachability, systemd units, disks, memory, CPU,
temperature, reboots. Context: [fleet-map.md](fleet-map.md).

## TargetDown

**Severity:** critical (buzzes) · **Fires when:** Prometheus cannot scrape a
target for 5 minutes. `job="node"` means a host's node_exporter is unreachable

- either the host is down or the network path broke.

### Do now

- Which instance? The alert names it (`homelab01:9100`). If the *host itself*
  is down, everything sourced from it is inhibited - this alert is the one
  thing you get.
- Ping/ssh it: `ssh coryg@<host>`. If ssh works, check the exporter:
  `systemctl status prometheus-node-exporter` and
  `curl -s localhost:9100/metrics | head`.
- Both hosts down at once = power/network event, not two coincidences. Check
  the switch/UPS first.

### Dig deeper

- A host that rebooted into a broken kernel should have been caught by boot
  counting; if you are reading this after a reboot that did not come back,
  it needs hands (or WoL + physical console). `wake-on-lan` is enabled.

### Fix

- Exporter crashed: `systemctl restart prometheus-node-exporter`, then find
  out why from its journal.
- Host down: recover it. There is no remote fix for a dead box in the cupboard.

## SystemdUnitFailed

**Severity:** warning · **Fires when:** any systemd unit has been in failed
state for 5+ minutes. The unit name is in the notification.

### Do now

- The notification carries the unit's last few journal lines when the
  journal-tail exporter managed to capture them - obvious failures (a
  traceback, a non-zero exit line) often need nothing more than reading the
  alert.
- For full history: `ssh <host> journalctl -u <unit> -n 100` (and
  `systemctl status <unit>` for restart counts). Capture is best-effort: if
  the alert says no output was captured, the unit logged nothing this boot.
- Oneshot units (backups, exporters, garden builds) failing is normal noise;
  long-running services failing is the real signal. The unit name tells you
  which kind.

### Dig deeper

- Failed NFS mount units on homelab01 usually mean homelab02 or its pool was
  down - cross-check ZFS and TargetDown alerts before chasing the mount.
- If a unit failed during last night's upgrade window, read
  [deployment.md](deployment.md) first.

### Fix

- `systemctl restart <unit>` for transient failures; something deterministic
  (config error, missing file) needs the repo fixed and redeployed.

## DiskSpaceLow / DiskSpaceCritical

**Severity:** warning / critical · **Fires when:** a filesystem drops under
10% free (critical under 5%). Only one fires at a time - the critical inhibits
the warning.

### Do now

- `ssh <host> df -h | grep -v tmpfs`
- Biggest offenders: `du -x --max-depth=2 / 2>/dev/null | sort -h | tail -20`

### Dig deeper

- homelab01: `/srv/media` fills via NFS (downloads land there), Jellyfin
  transcodes live under `/var/lib/jellyfin/transcodes` (excluded from backup,
  safe to clear), nix store grows until weekly GC.
- `/nix/store`: `nix-collect-garbage -d` reclaims old generations; the fleet
  GCs weekly (`--delete-older-than 14d`) so chronic growth means something
  new is big.

### Fix

- Clear transcodes/regenerables first. Deleting media is a decision, not an
  emergency response - critical gives you ~hours, not seconds, on these pool
  sizes.
- Chronic: grow the pool or add exclusion/cleanup; do not just delete.

## DiskSmartUnhealthy

**Severity:** critical (buzzes) · **Fires when:** SMART reports a disk not
healthy. This is hardware telling you it is dying.

### Do now

- `ssh homelab02 sudo smartctl -a /dev/<device> | grep -E "overall|Reallocated|Pending"`
  (pool disks are on homelab02; the alert names device and instance).
- Identify which pool member: `zpool status tank`.

### Fix

- Have a spare 4TB on hand before touching anything (the pool is a mirror of
  two - one more failure during replacement loses data).
- Replace the disk, then `zpool replace tank <old> <new>`; resilver takes
  hours. Order the replacement same-day, run it when convenient - degraded is
  survivable, degraded-then-failed is not.

## HighMemoryUsage / HighCpuUsage

**Severity:** warning · **Fires when:** memory >90% for 10m; CPU >95% for 30m
(deliberately tolerant of transcoding).

### Do now

- `ssh <host>` then `systemd-cgtop -m` (or htop). Memory pressure with swap
  churning shows here long before OOM kills.
- CPU on homelab01 in the evening is probably Jellyfin transcoding - check
  active streams before treating it as a fault.

### Fix

- Identify the service, decide: restart, tune, or accept. A runaway container
  is `podman restart <name>`; a genuinely leaky service is an upstream issue
  to file.

## HighDriveTemperature / HighSystemTemperature

**Severity:** warning · **Fires when:** a drive exceeds 55C for 10m or an
hwmon sensor exceeds 90C for 5m.

### Do now

- Drives: `smartctl -A /dev/<device> | grep Temperature`. Systems: `sensors`.
- Both boxes are SFF desktops in a cupboard - airflow and dust are the usual
  answers. Summer in Perth matters.

### Fix

- Clean filters/fans, check the cupboard isn't closed up, verify the fan
  curve. Sustained 55C+ drives shorten life; treat as maintenance, not outage.

## UnexpectedReboot

**Severity:** info · **Fires when:** a host booted within the last 10 minutes
and the boot happened outside the 04:00-05:00 maintenance window.

### Do now

- `ssh <host> uptime && last reboot | head -3`. Was it you? Did fwupd apply
  firmware? Did the power blink?
- Check why it went down: `journalctl --list-boots`, previous boot's tail
  (`journalctl -b -1 -n 50`) if it did not shut down cleanly.

### Fix

- Unexplained = watch it. One clean surprise reboot is data, not an incident;
  a pattern is hardware (PSU/RAM) and deserves a scheduled downtime.
