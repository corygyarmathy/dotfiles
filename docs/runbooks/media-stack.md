# Media stack runbook

What to do when alerts about the media stack fire.

## DownloadRootCanaryMissing

**What this is.** A sentinel file
(`/srv/media/downloads/.download-root-canary`) is primed and checked on a timer
(`download-root-canary.service`/`.timer`, first run 5min after boot, then every
10min). Its presence is published to node_exporter's textfile collector as
`download_root_canary_present` and this alert fires when that metric reads 0
for 20+ minutes. This is **detection, not prevention**: the download root is a
shared mutable directory several services are configured, in their own
databases, to write to, and nothing claims to stop a misconfiguration from
emptying it. What is promised is that it will not be *quietly* empty.

**Do now.**

1. Confirm the sentinel is actually gone (not a mount problem). Check the
   canary's own logging:
   `journalctl -u download-root-canary -b --no-pager`. The metric only reads 0
   when the check reached a **mounted** filesystem and saw a definite "No such
   file". If instead you see `sentinel unreachable (... not mounted)` or
   `sentinel check timed out - reporting present rather than missing`, the
   mount is in play, not a wiped root - deal with the NFS/ZFS outage, not
   this alert.
2. Check the download root itself:
   `ls -la /srv/media/downloads` and
   `du -sh /srv/media/downloads/*`. An empty or near-empty `downloads/` while
   the pool/NFS is healthy is the event this alert exists to surface.
3. Identify the writer. Look for a service whose output or post-processing
   directory now points at the download root or an ancestor of it. Check the
   PostgreSQL/SQLite-backed configs the Nix-level `download-root-safety`
   assertion cannot see (that is the class the incidents of 2026-07-25 /
   2026-07-27 belonged to): Sonarr/Radarr/whisparr post-processing, unpackerr,
   cross-seed linking, punish/prowlarr automation, qBittorrent save paths.
   `cg.service.suwayomi.downloadPath` and `cg.service.shelfmark.ingestPath`
   are the only Nix-level paths the assertion can watch.
4. Restore the sentinel. Only the store owner primes (homelab02, whose ZFS
   holds the export), so back it into place as the media-owning user rather
   than as root - root cannot write into a `root_squash`'d export:
   `sudo -u coryg touch /srv/media/downloads/.download-root-canary && sudo systemctl start download-root-canary.service`
   This works on either host's view of the same file. A plain reboot on
   homelab02 also restores it (the first timer run primes it).
5. Fix the root cause before it empties the root again - the sentinel does
   nothing to stop it, by design.

**Dig deeper.**

- The canary reports 0 only on a confirmed "No such file" against a real,
  mounted filesystem. If the sentinel's store is an unmounted automount (the
  NFS server unreachable - the stat sees the same ENOENT as a wiped root) the
  exporter publishes 1 and logs why; a dead mount server pages through its
  own systemd/ZFS/node-reachability alerts instead, and `TargetDown`
  inhibition keeps the noise down. A hung stat (hard-mounted NFS, `intr` on
  this fleet) is bounded by `timeout(1)`, reported as unconfirmed, and has
  the same story. If this alert fired alongside the mount's own alerts, start
  with the mount.
- The sentinel is a single file shared by both hosts, and only the store
  owner (homelab02) primes it; homelab01's canary is read-only observer. It
  is not re-created after a boot's priming (a `/run` marker scopes priming to
  one owner boot). That is deliberate: an exporter that re-created it would
  hand it back to a wiping service at every check, keep the series at 1, and
  the `for:` would never mature. Deleting it by hand, waiting out the timer
  plus the 20m `for:`, and watching `DownloadRootCanaryMissing` fire is the
  documented hand test for this stack.
- The static side lives in the same module: a NixOS assertion that no
  service-declared output/post-processing option covers the download root or
  an ancestor of it, by path segment. It evaluates on every host build and is
  pinned by `checks/download-root-safety.nix`; the runtime script's storage
  behaviour is pinned by `checks/download-root-canary-script.nix`. See the
  module header for the honest scope of what has to be registered there.
