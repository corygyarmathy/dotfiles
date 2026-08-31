# Runbooks

What to do when an alert fires. Every alert in
`modules/services/monitoring/alert-rules.yml` carries a `runbook_url`
annotation pointing at a heading in one of the files below, so the link in a
notification lands on the right section directly.

## Index

| Runbook | Covers |
| --- | --- |
| [fleet-map.md](fleet-map.md) | What runs where - read once, keep in mind during any incident |
| [node.md](node.md) | Host vitals: TargetDown, systemd units, disk/memory/CPU/temperature, unexpected reboots |
| [zfs.md](zfs.md) | Pool health, checksum and I/O errors, scrubs |
| [tunnel-and-probes.md](tunnel-and-probes.md) | Cloudflare Tunnel health, external service probes |
| [deployment.md](deployment.md) | The nightly NixOS deploy pipeline, activation verification, rollbacks |
| [backups.md](backups.md) | Restic backup runs |
| [vpn.md](vpn.md) | Gluetun VPN connectivity and port forwarding |
| [digital-garden.md](digital-garden.md) | Garden build and Obsidian sync |
| [media-stack.md](media-stack.md) | The download-root canary: a wiped/emptied shared download root |

## Conventions

- **Grouped by subsystem, not per alert.** Related alerts describe the same
  machine from different angles; their runbooks share context.
- **Sections are named after the alert** (`## ZfsPoolFaulted`) so annotation
  anchors stay stable. Adding an alert means adding a section and wiring its
  `runbook_url`.
- **"Do now" is written for 3am**: copy-pasteable commands, no archaeology.
  Anything that needs thought belongs under "Dig deeper".
- Facts about the fleet live in [fleet-map.md](fleet-map.md), not repeated per
  runbook. If you change the fleet, update the map.

## Adding a new alert

1. Write the alert in `alert-rules.yml` as usual.
2. Add a `## <AlertName>` section to the matching runbook file (or open a new
   file and index it above).
3. Add `runbook_url` to its annotations:
   `https://github.com/corygyarmathy/dotfiles/blob/master/docs/runbooks/<file>#<alertname-lowercase>`
4. `promtool check rules` (or let CI do it) and note the anchor only works
   once the section exists on `master`.

The repo is public: runbooks may contain hostnames, LAN addresses and commands,
never credentials or secret material.
