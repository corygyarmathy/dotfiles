# How a service asks to be published.
#
# A port used to be written down twice: once in the module that runs the
# service, and again as a literal in the host's reverse-proxy block. Changing
# the module's port produced no error - it produced a proxy pointing at
# nothing. The probe lists were a third copy, hand-maintained per host, and
# had already drifted: seven proxied hostnames were probed from nowhere, two
# of them published to the internet.
#
# So the direction is inverted. The module that runs a service is the only
# thing that knows its port, so it is the thing that declares how it should be
# published:
#
#   cg.publish.sonarr = {
#     subdomain = "sonarr";
#     port = cfg.port;        # the module's own option, never a copy
#     rateLimitProfile = "admin";
#   };
#
# and the three consumers read this registry instead of a hand-written list:
#
# - modules/services/reverse-proxy.nix builds a Caddy vhost per entry.
# - modules/services/cloudflare-tunnel.nix builds its ingress from the
#   entries with `localOnly = false`.
# - modules/services/monitoring/monitoring.nix derives `httpProbes` from all
#   of them, which is what closes the drift: a service that is published and
#   not probed is no longer expressible.
#
# WHAT DOES NOT BELONG HERE. `localOnly` is the exception that proves the
# rule. Whether a service answers from outside the LAN is a policy choice
# about this fleet, not a property of the software, so modules leave it alone
# and each host states its own set in one block. It defaults to `true`:
# forgetting to decide keeps a service off the internet.
#
# KEEP THIS SMALL. It is a piece of framework, and framework attracts
# features. Every option below is read by one of the three consumers named
# above; nothing here exists to be general.
#
# This declaration is imported by the modules that contribute to it as well as
# by the ones that read it, for the reason modules/nixos/fleet.nix gives: a
# check that instantiates a single service module has to get the option along
# with it. Importing the same path from several modules is free.
{ lib, ... }:
{
  options.cg.publish = lib.mkOption {
    default = { };
    description = ''
      Services this host publishes, keyed by the module that runs them. The
      reverse proxy, the Cloudflare tunnel and the blackbox probes are all
      derived from this; see `modules/nixos/publish.nix` for what belongs in
      an entry.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            subdomain = lib.mkOption {
              type = lib.types.str;
              default = name;
              defaultText = lib.literalExpression "the attribute name";
              description = ''
                Hostname this service answers to, without the domain. Defaults
                to the attribute name, which is the module's name -- several
                services are known to users by something else (`requests` for
                seerr, `read` for wallabag), and those say so.
              '';
            };

            port = lib.mkOption {
              type = lib.types.port;
              description = ''
                Port the service listens on. Always the module's own port
                option, never a copy of its value: a copy is what this
                registry exists to remove.
              '';
            };

            upstream = lib.mkOption {
              type = lib.types.str;
              default = "localhost";
              example = "10.20.2.130";
              description = ''
                Host the service actually runs on. Defaults to this machine.
                Set it to another node's address to proxy a service hosted
                there -- the traffic crosses the LAN in the clear, so this is
                for links inside the trusted network only. Take the address
                from `config.cg.fleet`, not from a literal.
              '';
            };

            localOnly = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Restrict this service to the local network. `false` also puts
                it into the Cloudflare tunnel's ingress, which is what makes
                it reachable from the internet.

                A host decides this, not the module that publishes the
                service. The default is the safe direction on purpose.
              '';
            };

            rateLimitProfile = lib.mkOption {
              type = lib.types.enum [
                "media"
                "admin"
                "none"
              ];
              default = "admin";
              description = ''
                Rate limiting profile the proxy applies to internet-facing
                requests. A property of the traffic the service sees, so the
                module that runs it chooses.
              '';
            };

            probe = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Whether blackbox_exporter probes this service. Leave it on
                unless the service has no useful GET, and say why when
                turning it off.
              '';
            };

            probePath = lib.mkOption {
              type = lib.types.str;
              default = "";
              example = "/health";
              description = ''
                Path the probe requests, appended to the URL. Only worth
                setting when the service has a readiness endpoint that says
                more than its front page does.

                Empty rather than `/` for the default, which is not cosmetic:
                the probe URL becomes the `instance` label on every series
                blackbox_exporter produces, so a trailing slash would rename
                the lot and cut every existing dashboard and alert off from
                its own history.
              '';
            };

            extraConfig = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = "Additional Caddy configuration for this vhost";
            };

            proxyExtraConfig = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = "Additional Caddy config inside the reverse_proxy block";
            };
          };
        }
      )
    );
  };
}
