# Tunnel and service probes

Everything public reaches the fleet through homelab01's cloudflared tunnel,
then Caddy, then the actual service. A probe failure can be any of those
layers - the alerts are ordered to tell you which. Context:
[fleet-map.md](fleet-map.md).

## CloudflareTunnelDown / CloudflareTunnelServiceFailed

**Severity:** critical (buzzes) · **Fires when:** cloudflared stops answering
its metrics endpoint, or its systemd unit enters failed state. While this
fires, every public hostname is dark and all ServiceDown probes are inhibited -
this alert is deliberately the only *service* page you get. `HostUnreachableFromOutside`
is *not* inhibited: the away-host beacon is what still pages when the tunnel
owner itself is gone, since this alert's metric lives on that host and may
never reach an operator.

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
is down (you'd get the tunnel alert instead). Excludes *remote* probes -
those are the reachability alert below, so one away-host outage does not fire
both.

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

## HostUnreachableFromOutside

**Severity:** critical (buzzes) · **Fires when:** a *peer* server cannot get
HTTP 200 from this host's dedicated host-alive beacon
(`alive-<host>.<domain>`, a dependency-free 200-responder — see
`modules/services/host-alive.nix`) for 5 minutes. This is the reachability
check (item 9): every other probe runs on the machine it watches, so a host
cut off from its network still believes, locally, that everything is fine.
These probes run on the *other* server, so they keep answering when this one
cannot. Because the target is the beacon and not one of its services, a plain
service crash does not raise this — only the host itself genuinely being out
of reach does.

Two servers: homelab01 probes homelab02 at `alive-homelab02.gyarmathy.co`,
homelab02 probes homelab01 at `alive-homelab01.gyarmathy.co`. The
notification's `host` label names who stopped answering; the `instance` label
is the beacon URL probed. **Not** inhibited while the tunnel is down: when the
tunnel owner itself dies, this beacon is what still pages (its own tunnel
metrics may never reach an operator).

The probe URL is public, but the path the probe takes is not fixed. The fleet
resolver answers `alive-*` with the LAN address, so normally the probe crosses
the LAN to the peer's beacon through Caddy; if the probing host resolves
publicly instead, the same URL rides the tunnel to Cloudflare's edge. Either
way the *observer* is a different machine. The path matters when reading the
alert, because each direction observes a different set of failure modes:

- **LAN path** fires when the peer's host/Caddy/network is down; it does *not*
  see a pure tunnel/egress fault, because the peer still answers on the LAN.
- **Tunnel path** also sees a pure tunnel/egress fault.

Both paths share one hop: they transit **homelab01** — its Caddy on the LAN
path, its tunnel on the public path. So a failure on homelab01 itself can fire
this alert from *both* Prometheus instances at once, and the instance running
on homelab01 will misname homelab02 (which is healthy). When both fire
together, the cause is almost always the shared hop — homelab01's Caddy, tunnel
or network — not two dead hosts. The direction that stayed green names the
healthy peer.

### Do now

- This means the named host is not answering along the probe's path, even
  though its own probes and alerts still look healthy. Do **not** trust the
  local view.
- Confirm from a second vantage point: `curl -sk -o /dev/null -w '%{http_code}'
  <instance url>` from the *other* server, and `ping`/`ssh` the host. If the
  peer still reaches it over the LAN but not publicly, that is an egress/tunnel
  fault on homelab01, not a dead host.
- If both beacons fire at once, suspect the shared hop — homelab01's Caddy,
  tunnel or network — rather than two dead hosts, and cross-check which
  direction fired versus which stayed green.

### Dig deeper

- Usually a firewall, interface, sshd/networking change, or a reboot that did
  not come back cleanly - something that cut the host off while leaving
  systemd and its local services "fine".
- Check whether the named host signs in fresh: staying dark across several
  minutes rules out a transient probe blip.

### Fix

- This may need a trip to the cupboard: power-cycle or re-attach the host and
  watch whether the alert clears and the peer-side probe returns to 200.
- After it recovers, find the root cause (a failed sshd, a firewall rule, a
  flat interface) before treating it as resolved.
