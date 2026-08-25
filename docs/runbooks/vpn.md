# VPN (Gluetun)

homelab02's qBittorrent (and Shelfmark's UI) run inside a Gluetun container:
all egress goes through a WireGuard VPN, and qBittorrent's listening port is
forwarded through it. Metrics come from the `gluetun-health-exporter`
textfile collector polling Gluetun's control API.

## GluetunVpnDisconnected

**Severity:** critical (buzzes) · **Fires when:** Gluetun reports no active
VPN connection for 2+ minutes. Downloads stall; nothing else in the fleet
depends on it.

### Do now

- `ssh homelab02 podman logs --tail 50 gluetun` - auth expiry, server
  unreachable, or WireGuard handshake failure all read clearly here.
- `podman restart gluetun` is the standard first move; Gluetun re-establishes
  on its own most of the time.

### Dig deeper

- Recurring disconnects: the chosen VPN endpoint may be flaky - rotating to a
  different server/region in the media-stack config is the fix.
- If the container will not start at all after a config change, validate the
  settings against Gluetun's docs for that provider.

### Fix

- Restart; escalate to endpoint rotation. Not urgent beyond "downloads are
  paused" unless you are mid-something time-sensitive.

## GluetunPortNotForwarded

**Severity:** warning · **Fires when:** the VPN is connected but the forwarded
port reads 0 for 5 minutes. qBittorrent shows as firewalled: seeding and many
private-tracker swarms degrade.

### Do now

- `ssh homelab02 podman logs --tail 30 gluetun | grep -i port`
- The provider's port-forwarding API sometimes needs a nudge - restarting
  gluetun re-requests the forward.

### Fix

- Restart; if chronic on this endpoint, rotate endpoints. Some providers
  periodically revoke ports; check whether the provider requires periodic
  renewal.
