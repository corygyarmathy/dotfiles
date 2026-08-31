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

  # ==========================================================================
  # 3. Every server is watched from outside itself (item 9 of the
  #    deployment-hardening plan)
  # ==========================================================================
  #
  # `httpProbes` runs on the host it is watching, so a host cut off from its
  # network still believes it is fine. That gap is covered by `remoteProbes` -
  # the peer's public endpoints, probed by a different machine that is still
  # up. The point of this check is that the wiring cannot silently decay:
  #
  #   - a host that stops declaring remoteProbes loses its outside-the-host
  #     watch entirely, with a clean build and no symptom to explain it;
  #   - a remoteProbe pointing at anything that is not an actual public
  #     hostname would page on the first quiet night for a reason unrelated to
  #     reachability;
  #   - a remoteProbe watching the wrong host (itself, or a workstation that is
  #     never expected to answer) would alert about nothing real;
  #   - a duplicate name or URL silently double-scrapes the same target.
  #
  # So each fleet server must name a peer, and every URL must resolve to a
  # subdomain this fleet deliberately exposes (`localOnly = false`). A word on
  # what it deliberately does *not* verify: `cg.publish` records the routing
  # owner - the host whose tunnel/Caddy serve the subdomain - not the host that
  # runs the service. With the single tunnel on homelab01, every public
  # subdomain is routed by homelab01 even when its service (grimmory, storage)
  # runs on homelab02, so "who owns the subdomain" cannot prove "who runs it".
  # The runner association lives in the service modules, not `cg.publish`, and
  # is intentionally out of scope. The check therefore pins that the graph is a
  # real cross-server pair through a public https hostname - it cannot confirm
  # the URL runs on the named peer, and the host config comments carry that
  # promise instead.
  # The real fleet's host configs, and the hosts it marks as servers.
  # Hoisted so both the cross-host port pin and the remote-probe invariant
  # read the same servers - no one host is pinned as the source of truth, so
  # the checks keep covering the fleet if a host is renamed or replaced.
  hosts = self.nixosConfigurations;

  serverNames = lib.attrNames (
    lib.filterAttrs (n: fleetHosts: (fleetHosts.${n} or { }).kind == "server") (
      lib.mapAttrs (_: h: h.config.cg.fleet.hosts) hosts
    )
  );

  # The two servers' host-alive beacons (modules/services/host-alive.nix) must
  # sit on the same port, because the tunnel owner's route to the peer reads
  # its *own* `host-alive.port`. With the shared module default both agree by
  # construction; pinning it here means moving one without the other is a
  # check failure rather than a silently dead beacon.
  alivePortDiffer =
    lib.length (lib.unique (map (n: hosts.${n}.config.cg.service.host-alive.port) serverNames)) != 1;

  remoteFailures =
    let
      # The subdomains this fleet serves to the internet, from whichever host
      # declares them. Both servers' public entries live on the tunnel owner
      # because that is where the tunnel is; sourced from the whole fleet so a
      # future host that publishes its own public service is covered too.
      publicSet = lib.genAttrs (lib.concatMap (
        n:
        lib.mapAttrsToList (_: svc: svc.subdomain) (
          lib.filterAttrs (_: svc: !svc.localOnly) hosts.${n}.config.cg.publish
        )
      ) serverNames) (_: true);

      checkHost =
        name:
        let
          cfg = hosts.${name}.config;
          remote = cfg.cg.service.monitoring.remoteProbes;
          ownName = cfg.networking.hostName;
          peerNames = lib.remove name serverNames;
        in
        lib.optional (cfg.cg.service.monitoring.enable && remote == [ ])
          "${name}: monitoring is on but it declares no remoteProbes - it has no outside-the-host reachability watch"
        ++ lib.concatMap (
          p:
          let
            isHttps = lib.hasPrefix "https://" p.url;
            selfHost = lib.removeSuffix ".${cfg.cg.fleet.domain}" (lib.removePrefix "https://" p.url);
            nameOnce = lib.length (lib.filter (q: q.name == p.name) remote) == 1;
            urlOnce = lib.length (lib.filter (q: q.url == p.url) remote) == 1;
          in
          lib.optional (p.name == ownName) "${name}: remoteProbe watches itself (${p.name})"
          ++ lib.optional (
            !(lib.elem p.name peerNames)
          ) "${name}: remoteProbe names '${p.name}' which is not another fleet server"
          ++ lib.optional (!nameOnce) "${name}: remoteProbe '${p.name}' is declared more than once"
          ++ lib.optional (!urlOnce) "${name}: remoteProbe URL ${p.url} is declared more than once"
          ++ lib.optional (!isHttps) "${name}: remoteProbe URL is not https: ${p.url}"
          ++ lib.optional (
            isHttps && !(builtins.hasAttr selfHost publicSet)
          ) "${name}: remoteProbe URL is not a public hostname: ${p.url}"
        ) remote;
    in
    lib.concatMap checkHost serverNames;

  failures =
    fixtureFailures
    ++ lib.concatMap hostFailures [
      "homelab01"
      "homelab02"
    ]
    ++ remoteFailures
    ++ lib.optional alivePortDiffer "server host-alive ports disagree - the tunnel owner's route to the peer reads its own host's port, so both servers must match";
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
      remote probes: ${
        toString (
          lib.length (
            self.nixosConfigurations.homelab01.config.cg.service.monitoring.remoteProbes
            ++ self.nixosConfigurations.homelab02.config.cg.service.monitoring.remoteProbes
          )
        )
      }
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
