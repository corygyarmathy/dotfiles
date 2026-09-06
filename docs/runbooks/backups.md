# Backups

Restic runs on both hosts: a cross-server repo (to the *other* host, over
sftp) and an offsite OneDrive repo via rclone. Schedules are 02:30
(cross-server) and 03:00 (offsite); homelab02's MariaDB dump for Grimmory
lands at 02:00 so the 02:30 snapshot captures a consistent dump.

Metrics per job/repo: `restic_backup_last_run_success` and
`..._last_run_timestamp_seconds`.

## ResticBackupFailed

**Severity:** warning · **Fires when:** the last run of a named backup job
failed. The notification names the job (`cross-server` / `onedrive`) and host.

### Do now

- `ssh <host> systemctl status restic-<job>.service`
- `journalctl -u restic-<job>.service -n 100` - the tail usually says it all:
  lock contention (two jobs overlapping), network/sftp failure to the peer,
  rclone quota/auth failure for onedrive.

### Dig deeper

- Cross-server failing on BOTH hosts at once = one of them is down or their
  sftp path broke; check the other host first.
- A failed run does not lose old snapshots - this alert says the safety net
  has stopped advancing, and its staleness sibling tells you how long you
  have before that matters.

### Fix

- Transient (network/lock): `systemctl start restic-<job>.service` after the
  cause clears and confirm success.
- Auth/quota: fix credentials in sops (`backups/*` keys), re-run.
- If a repo is corrupted (`restic check` fails), restore-from-the-other-copy
  thinking applies: cross-server and offsite are independent repos.

## ResticBackupStale

**Severity:** warning · **Fires when:** no successful-or-failed run recorded
for 26+ hours - the job stopped running entirely (missed schedules count as
stale only if nothing was recorded; a nightly timer missing once still logs).

### Do now

- `ssh <host> systemctl list-timers 'restic-*'` - last/next trigger times.
- Timer dead vs service never finishing (a hung rclone upload shows as stale,
  not failed): `journalctl -u restic-<job>.service --since yesterday | tail`.
- Is the machine even awake/up overnight? Correlate with UnexpectedReboot /
  TargetDown history.

### Fix

- Restart the timer/service; investigate hangs with `restic stats`-style
  checks only after killing the stuck unit.
