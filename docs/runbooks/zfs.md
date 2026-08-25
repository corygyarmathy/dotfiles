# ZFS pool

The pool (`tank`) lives on homelab02 only: two 4TB HDDs in a mirror, mounted
at `/srv/media`, exported over NFS to homelab01, backed up offsite via restic.
Metrics come from the `zfs-health-exporter` textfile collector. If a
pool-level alert fired alone, its checksum/I/O symptom alerts are inhibited -
by design.

## ZfsPoolDegraded

**Severity:** critical (buzzes) · **Fires when:** the pool is DEGRADED - one
mirror member has failed but the pool still serves data.

### Do now

- `ssh homelab02 zpool status -v tank` - it names the failed device and why.
- Order/beg/borrow a replacement 4TB drive same-day. You are one disk failure
  from data loss while degraded.

### Fix

- `zpool replace tank <failed-device> /dev/disk/by-id/<new-device>`, then let
  resilver finish (hours for 4TB; `zpool status` shows progress).
- Afterwards: clear the old SMART alert if one fired, confirm scrub passes,
  and note whether SMART warned before the death (if not, tighten thresholds).

## ZfsPoolFaulted

**Severity:** critical · **Fires when:** the pool is FAULTED - data loss may
have occurred. This is the worst alert in the fleet.

### Do now

- Stop. Do not run destructive commands. `zpool status -v tank` and
  `zpool import` (if unimported) to see what is visible.
- Check both disks physically present/spinning: `ls -l /dev/disk/by-id/`.
- If both members show ONLINE-ish but the pool faulted, try
  `zpool clear tank` then `zpool import tank` - power events can fault a pool
  that is actually intact.

### Fix

- Recoverable (transient): import + scrub + breathe.
- Real failure of both members: restore from backups. Restic snapshots exist
  on homelab01's cross-server repo AND Google Drive; the restore procedure is
  restic's, pointed at whichever copy survives. Verify what you restored
  before declaring victory.

## ZfsPoolUnhealthy

**Severity:** critical · **Fires when:** the pool reports any state other than
ONLINE that isn't DEGRADED/FAULTED (SUSPENDED, UNAVAIL, REMOVED...).

### Do now

- `ssh homelab02 zpool status -v tank`. SUSPENDED usually means I/O hung -
  often a dying cable/controller or the host nearly out of memory.
- UNAVAIL after a reboot means an import problem: check
  `journalctl -u zfs-import-cache`, and that `/etc/hostid` matches
  (networking.hostId in the config).

### Fix

- SUSPENDED: fix the underlying I/O path, then `zpool clear tank`.

## ZfsChecksumErrors / ZfsIOErrors

**Severity:** warning · **Fires when:** the pool accumulates checksum or
read/write errors. These are counters since import - nonzero is always worth
understanding.

### Do now

- `ssh homelab02 zpool status -v tank` shows which disk and how many.
- One disk accumulating errors while its mirror partner stays clean = that
  disk is failing. Start [DiskSmartUnhealthy](node.md#disksmartunhealthy)
  thinking even if SMART still says healthy.

### Fix

- Errors confined to one disk: replace it (see Degraded runbook).
- Errors on both / no pattern: cables/controller first, then scrub to force
  full reads: `zpool scrub tank`.

## ZfsScrubErrors

**Severity:** warning · **Fires when:** the last completed scrub repaired or
found errors.

### Do now

- Same as ChecksumErrors: `zpool status -v tank` for the per-disk breakdown.
- Scrub runs weekly automatically (Sunday-ish); errors found during scrub with
  no live I/O errors usually mean a marginal disk caught before it died.

### Fix

- As above - single-disk pattern means replace; clean repair counts on both
  disks after a power event can be ignored once.

## ZfsScrubOverdue

**Severity:** warning · **Fires when:** no completed scrub in 14+ days.

### Do now

- `ssh homelab02 zpool status tank` - was the last scrub interrupted? Did
  autoscrub stop being scheduled?
- Kick one manually: `sudo zpool scrub tank` (it will not slow the box much;
  media serving may stutter slightly).

### Fix

- Recurring overdue = the weekly timer is broken or scrubs keep getting
  interrupted by reboots/upgrades. Fix the schedule, don't just scrub by hand.
