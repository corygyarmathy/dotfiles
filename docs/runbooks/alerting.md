# Alerting

Alerts about the alerting pipeline itself. Push goes to ntfy on homelab01 through a local `alertmanager-ntfy` bridge on each host; email is sent by each host's Alertmanager straight to Proton. Context: [fleet-map.md](fleet-map.md).

## AlertPushFailing

**Severity:** warning · **Lane:** email only (push is the thing that is broken) **Fires when:** a host's Alertmanager has had failed webhook deliveries to its ntfy bridge in every 10-minute window for 20 minutes. Short failures while ntfy restarts in the 04:00 upgrade window do not last long enough to fire it.

While this is firing, every alert is reaching you by email only. Check your inbox for what push would have told you.

### Do now

- On the host named by the alert: `journalctl -u alertmanager-ntfy -n 50`. `502 Bad Gateway` means the bridge reached Caddy but ntfy behind it is down; `connection refused` means the bridge itself is down.
- On homelab01: `systemctl status ntfy-sh`. A failed server here fails push for both hosts.
- `curl -sI https://ntfy.gyarmathy.co` from anywhere: if this fails too, see [tunnel-and-probes.md](tunnel-and-probes.md).

### Fix

- ntfy-sh failed after an upgrade: read its journal and fix the cause; the 2026-09-25 case was a missing `ntfy-sh` user after a nixpkgs bump (#316).
- Bridge failing on auth (`401`/`403`): the token in `monitoring/ntfy/alerts-token` no longer matches a user in ntfy's `user.db`; re-create it as in the header of `modules/services/ntfy.nix`.
- Resolves on its own within about 10 minutes of push working again.
