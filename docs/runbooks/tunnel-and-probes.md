# Tunnel and service probes

Everything public reaches the fleet through homelab01's cloudflared tunnel,
then Caddy, then the actual service. A probe failure can be any of those
layers - the alerts are ordered to tell you which. Context:
[fleet-map.md](fleet-map.md).

## CloudflareTunnelDown / CloudflareTunnelServiceFailed

**Severity:** critical (buzzes) · **Fires when:** cloudflared stops answering
its metrics endpoint, or its systemd unit enters failed state. While this
fires, every public hostname is dark and all ServiceDown probes are inhibited
- this alert is deliberately the only one you get.

### Do now

- `ssh homelab01 systemctl status cloudflared-tunnel`
  `journalctl -u cloudflared-tunnel -n 50` - auth failures vs network failures
  read very differently.
- `curl -s localhost:20241/metrics | grep ha_connections`

### Dig deeper

- Credential problems (tunnel-credentials/origin-cert in sops) usually follow
  a secrets change or a botched restore.
- If the unit is healthy but connections are down, it is egress: check
  outbound internet from homelab01.

### Fix

- Restart usually clears transient states: `systemctl restart cloudflared-tunnel`.
- Persistent auth failure: verify the sops secrets exist and match the tunnel
  ID; re-running `cloudflared tunnel route dns` (the
  cloudflared-route-dns.service does this at boot) re-registers hostnames.

## CloudflareTunnelNoConnections / CloudflareTunnelDegraded

**Severity:** critical / warning · **Fires when:** HA connections drop below
1 (or below 3, degraded). cloudflared maintains four edge connections.

### Do now

- Same first steps as TunnelDown. Degraded-but-up is often a single edge
  region issue on Cloudflare's side - check
  [cloudflarestatus.com](https://www.cloudflarestatus.com) before blaming the
  box.

### Fix

- Local: restart the unit. Cloudflare-side: wait it out; degraded with 2-3
  connections is serving fine.

## CloudflareTunnelHighErrorRate

**Severity:** warning · **Fires when:** request errors through the tunnel
exceed ~10% for 5 minutes.

### Do now

- This is usually an *upstream service* misbehaving, not the tunnel. Which
  services? Cross-reference the probe table on Fleet Overview.
- `journalctl -u caddy -n 100 | grep -i error` on homelab01 names the failing
  upstreams.

### Fix

- Restart whichever backend is throwing; if one service dominates errors
  chronically, fix that service rather than watching the tunnel alert.

## ServiceDown

**Severity:** warning · **Fires when:** a blackbox probe cannot get HTTP 200
from a public service URL for 5 minutes. Suppressed entirely while the tunnel
is down (you'd get the tunnel alert instead).

### Do now

- The probe URL in the notification identifies the service. Walk the chain
  from inside out:
  1. Is the service up? `ssh <host> systemctl status <service>` (arr units
     live on their documented hosts; podman-backed ones via
     `podman ps -a | grep <name>`).
  2. Is Caddy reaching it? `curl -s -o /dev/null -w '%{http_code}'
     http://localhost:<port>` **on the service's host**.
  3. Is Caddy serving? `curl -sk -o /dev/null -w '%{http_code}'
     https://<subdomain>.gyarmathy.co` from homelab01 itself (LAN source, so
     localOnly rules allow it).
- One service down = that service. Several at once = Caddy or the tunnel
  (but then you'd have gotten the tunnel alert).

### Fix

- Restart the dead service; investigate why from its journal/podman logs
  (`podman logs --tail 100 <name>`).
