# A service's port reaches all three consumers, and nothing is published
# without being watched.
#
# `cg.publish` exists because the same port used to be written down in the
# module that runs a service and again in the host's proxy block, with nothing
# to notice when the two disagreed - and because the probe lists, a third
# copy, had already drifted six entries apart with seven proxied hostnames
# probed from nowhere. Neither failure is visible in a build: both produce a
# configuration that evaluates, realises and deploys, and then quietly answers
# nothing or watches nothing.
#
# So this pins the two properties that replace the transcription:
#
#   1. One port, three consumers. A module changing its own port option moves
#      the Caddy vhost, the tunnel ingress and the blackbox probe with it.
#      Asserted against a stand-in service module rather than a real one, so
#      the test says what the registry does rather than what sonarr's default
#      happens to be.
#
#   2. The fleet's own publications are complete. Every vhost the two hosts
#      serve is probed, and every hostname in the tunnel is a vhost on the
#      host that carries it. This is the assertion that would have caught the
#      original drift, so it runs against the real hosts, not a fixture.
#
# Evaluation only, no VM: everything here is a question about generated
# configuration, and checks/reverse-proxy.nix already boots Caddy against a
# `cg.publish` registry to prove the vhosts it generates actually serve.
{
  pkgs,
  self,
  inputs,
}:
let
  inherit (pkgs) lib;

  # ==========================================================================
  # 1. One port, three consumers
  # ==========================================================================

  # Stands in for a service module: it owns a port option and publishes
  # itself, which is the whole of what a real one does here.
  fakeService =
    { config, ... }:
    {
      imports = [ ../modules/nixos/publish.nix ];

      options.cg.service.widget.port = lib.mkOption {
        type = lib.types.port;
        default = 1234;
      };

      config.cg.publish.widget = {
        subdomain = "widget";
        port = config.cg.service.widget.port;
      };
    };

  fixture = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      inputs.sops-nix.nixosModules.sops
      ../modules/services/reverse-proxy.nix
      ../modules/services/cloudflare-tunnel.nix
      ../modules/services/monitoring/monitoring.nix
      fakeService
      (
        { config, ... }:
        {
          # A fleet that is not this one, for the reason checks/
          # reverse-proxy.nix gives: the assertions below are about the
          # registry, not about gyarmathy.co.
          cg.fleet = {
            domain = "example.test";
            lan.cidr = "10.0.0.0/24";
            hosts = { };
            roles = { };
          };

          # The port a real module would carry in its own option. Nothing
          # below repeats the number; the point is that changing it here
          # changes all three consumers.
          cg.service.widget.port = 9999;

          cg.publish = {
            widget.localOnly = false;

            # LAN-only: a vhost and a probe, but no ingress.
            inside = {
              port = 4444;
              localOnly = true;
            };

            # Published but deliberately unwatched, which is the only way to
            # be published and unprobed.
            quiet = {
              port = 5555;
              probe = false;
            };
          };

          cg.service = {
            reverse-proxy = {
              enable = true;
              email = "test@example.invalid";
              cloudflareTokenFile = "/dev/null";
            };
            cloudflare-tunnel.enable = true;
            monitoring = {
              enable = true;
              prometheus.enable = true;
            };
          };
        }
      )
    ];
  };

  fixtureCfg = fixture.config;

  ingressOf =
    cfg:
    lib.filter (rule: rule ? hostname)
      (builtins.fromJSON cfg.sops.templates."cloudflared-config.yml".content).ingress;

  fixtureIngress = ingressOf fixtureCfg;
  fixtureProbes = map (p: p.url) fixtureCfg.cg.service.monitoring.httpProbes;
  fixtureVhosts = fixtureCfg.services.caddy.virtualHosts;

  has = needle: haystack: lib.hasInfix needle haystack;

  fixtureFailures =
    lib.optional (
      !(has "reverse_proxy localhost:9999" fixtureVhosts."widget.example.test".extraConfig)
    ) "the proxy did not follow the module's port to 9999"
    ++ lib.optional (
      !(lib.any (r: r.service == "http://localhost:9999") fixtureIngress)
    ) "the tunnel ingress did not follow the module's port to 9999"
    ++ lib.optional (
      !(lib.elem "https://widget.example.test" fixtureProbes)
    ) "the published service was not probed"
    ++ lib.optional (!(fixtureVhosts ? "inside.example.test")) "a LAN-only service did not get a vhost"
    ++ lib.optional (lib.any (
      r: r.hostname == "inside.example.test"
    ) fixtureIngress) "a LAN-only service reached the tunnel ingress"
    ++ lib.optional (
      !(lib.elem "https://inside.example.test" fixtureProbes)
    ) "a LAN-only service was not probed"
    ++ lib.optional (
      !(fixtureVhosts ? "quiet.example.test")
    ) "probe = false removed the vhost as well as the probe"
    ++ lib.optional (lib.elem "https://quiet.example.test" fixtureProbes) "probe = false was ignored";

  # ==========================================================================
  # 2. The fleet's own publications are complete
  # ==========================================================================

  hostFailures =
    name:
    let
      cfg = self.nixosConfigurations.${name}.config;
      domain = cfg.cg.fleet.domain;

      vhosts = lib.attrNames cfg.services.caddy.virtualHosts;
      probed = map (p: p.url) cfg.cg.service.monitoring.httpProbes;

      # Published without `probe = false`, so it must be watched. Written from
      # the registry rather than from the vhost list so the message can name
      # the entry a reader would go and edit.
      shouldProbe = lib.filterAttrs (_: svc: svc.probe) cfg.cg.publish;

      unprobed = lib.filterAttrs (
        _: svc: !(lib.elem "https://${svc.subdomain}.${domain}${svc.probePath}" probed)
      ) shouldProbe;

      ingress = if cfg.cg.service.cloudflare-tunnel.enable then ingressOf cfg else [ ];
      unserved = lib.filter (rule: !(lib.elem rule.hostname vhosts)) ingress;
    in
    map (entry: "${name}: cg.publish.${entry} is published but not probed") (lib.attrNames unprobed)
    ++ map (
      rule: "${name}: ${rule.hostname} is in the tunnel but this host's Caddy does not serve it"
    ) unserved;

  failures =
    fixtureFailures
    ++ lib.concatMap hostFailures [
      "homelab01"
      "homelab02"
    ];
in
pkgs.runCommand "check-publish"
  {
    passAsFile = [ "failures" ];
    failures = lib.concatStringsSep "\n" failures;
    # Reported so a passing run says what it covered rather than only that it
    # passed; a count that quietly falls to zero is the way this check would
    # stop meaning anything.
    counts = ''
      fixture: ${toString (lib.length fixtureProbes)} probes, ${toString (lib.length fixtureIngress)} ingress rules
      homelab01: ${toString (lib.length (lib.attrNames self.nixosConfigurations.homelab01.config.cg.publish))} published
      homelab02: ${toString (lib.length (lib.attrNames self.nixosConfigurations.homelab02.config.cg.publish))} published
    '';
  }
  ''
    if [ -s "$failuresPath" ]; then
      echo "cg.publish invariants violated:" >&2
      cat "$failuresPath" >&2
      exit 1
    fi
    printf '%s\n' "$counts"
    touch $out
  ''
