# A host's own reachability beacon.
#
# "Is this machine up" used to be answered, for the outside-the-host watch,
# by probing a real service on the peer (grimmory here, garden there). That
# ties "host is down" to "this one service is running": moving or disabling
# the service silently takes the reachability watch down with it, and nobody
# alerts about a host that stayed up but lost its one public endpoint.
#
# So each server runs a tiny actually-dedicated endpoint instead. It is not a
# service and has nothing to do with the applications - it is a fixed, never
# disabled, dependency-free HTTP responder that returns 200 to every request.
# The peer's probes (cg.service.monitoring.remoteProbes) point at it, so
# "HostUnreachableFromOutside" now means the host itself stopped answering,
# independent of what it happens to be serving.
#
# WHY NOT CADDY. The Cloudflare tunnel routes each public subdomain directly to
# its origin (see modules/services/cloudflare-tunnel.nix); public traffic never
# passes through Caddy. A reachable-from-outside endpoint must therefore be a
# real origin the tunnel can dial over the LAN, not a Caddy vhost. So this is
# a standalone listener, decoupled from both Caddy and the apps.
#
# "Decoupled from Caddy" is about how the endpoint runs, not how the peer's
# probe reaches it: on the LAN path the probe still transits the routing
# host's Caddy (the wildcard resolves alive-* there), so a Caddy crash on the
# routing host darkens the beacon even though socat itself never went down.
# The item 9 section of the hardening plan and the tunnel runbook spell out
# the failure modes that implies.
#
# The responder is socat replying with a fixed 200. It has no config, no state,
# no backing service, and nothing to go wrong except the host itself - which is
# the property the probe is meant to watch.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.host-alive;

  # The fixed 200 response, as a tiny script socat runs once per connection.
  # A separate script rather than an inline `SYSTEM:'...'` because systemd's
  # ExecStart tokenizer mangles shell quoting and backslash escapes: the \r\n
  # framing becomes literal control characters and the quotes are stripped, so
  # the reply turns into a stream of "command not found" errors and the client
  # gets nothing. `EXEC:` runs the script directly - no shell, no quoting to
  # survive - and the store path is one space-free argument.
  responder = pkgs.writeShellScript "host-alive-responder" ''
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'
  '';
in
{
  # Reads config.cg.publish to contribute its own entry - see
  # modules/nixos/publish.nix. Does not read cg.fleet itself; the host that
  # routes this endpoint (the tunnel owner) pulls its address from the fleet.
  imports = [ ../nixos/publish.nix ];

  options.cg.service.host-alive = {
    enable = lib.mkEnableOption "dependency-free host-alive endpoint for cross-host reachability";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9080;
      description = ''
        Port the host-alive responder listens on.

        One number used everywhere, never copied: a host's own responder,
        its reverse-proxy vhost, and the tunnel owner's route to it all read
        this. Because the endpoint is a fixed fleet-wide beacon and carries
        nothing to vary, the default is the only value either server uses; a
        later change must move both hosts together, which the publish check
        (checks/publish.nix) pins.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Publishes the endpoint into the same registry the reverse proxy, tunnel
    # and probes read. `probe = false`: it is not a service to watch through
    # ServiceDown - it is the peer's host-reachability target, watched
    # deliberately by the peer via remoteProbes. `localOnly` is left to the
    # host (the publish convention): the tunnel owner sets it false so the
    # beacon is published publicly (put into the tunnel ingress). Which path
    # the peer's probe takes to reach it - over the LAN, or out to Cloudflare
    # and back - is a matter of fleet DNS resolution, not a promise made here.
    cg.publish.alive = {
      subdomain = "alive-${config.networking.hostName}";
      port = cfg.port;
      probe = false;
    };

    # A tiny always-on 200 responder. Listens on all interfaces so the tunnel
    # owner's cloudflared can reach it across the LAN even though that peer is
    # a different host.
    systemd.services.host-alive = {
      description = "Host-alive reachability endpoint";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString cfg.port},bind=0.0.0.0,reuseaddr,fork EXEC:${responder}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    # Open the beacon to the LAN so the local reverse proxy - and, through it,
    # the peer - can reach it. It carries no data, so this is not an exposure.
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
