# Fleet map

The two-sentence version of every machine, for orientation mid-incident.
Detailed rationale lives in the host configs (`hosts/<host>/default.nix`) and
the ADRs.

## homelab01 - 10.20.2.85 (Optiplex 5080)

Compute + streaming. Runs: Caddy (every public hostname terminates here),
cloudflared tunnel, Jellyfin + the *arr stack, AdGuard (primary DNS), Grafana,
Prometheus + Alertmanager, ntfy, Miniflux/Wallabag, digital garden.
Mounts `/srv/media` from homelab02 over NFS.

- Nightly upgrade at 04:00 AWST, reboots only inside 04:00-05:00.
- `criticalUnits` for activation verification: caddy, jellyfin, srv-media.automount.

## homelab02 - 10.20.2.130 (Elitedesk 800 G6)

Storage + downloads. Holds the ZFS pool `tank` mounted at `/srv/media`
(2x4TB mirror), exports it via NFS to homelab01 only. Runs qBittorrent
inside Gluetun, cross-seed/unpackerr, Grimmory/Shelfmark/Suwayomi,
AdGuard (secondary), its own Prometheus + Alertmanager pair.

- Nightly upgrade at 04:15 AWST (15 min offset so both servers never reboot
  into a new kernel simultaneously), same reboot window.
- `criticalUnits`: zfs-import-tank, nfs-server, caddy.

## Network shape

- Both hosts publish through homelab01's Cloudflare Tunnel; LAN clients
  resolve `*.gyarmathy.co` via AdGuard wildcard to homelab01 (or homelab02 for
  the five explicitly rewritten subdomains).
- Monitoring UIs are LAN-only: prometheus./alertmanager./grafana. respond 403
  from outside 10.20.2.0/24. Remote access = ssh tunnel as usual.
- Prometheus scrapes both hosts' node_exporter (:9100) and smartctl (:9633)
  from BOTH servers; Alertmanager runs as a two-node cluster and dedupes.

## Where notifications go

- Criticals: ntfy push, urgent (phone buzzes) + email archive.
- Warnings: ntfy push, silent, muted 22:00-07:00 AWST + email archive.
- Inhibition: a host that stops answering suppresses its own child alerts;
  a downed tunnel suppresses probe failures; pool-level ZFS failures suppress
  their per-symptom alerts. If you see one of these root causes fire alone,
  that is why its children went quiet.

## Standing dashboards

- Grafana > Fleet Overview: firing alerts, targets down, deploy/verify/backup
  verdicts, CPU/mem/disk, probe table.
- Prometheus UI (LAN): ad-hoc queries; every alert's expression is copyable
  from `/alerts`.
