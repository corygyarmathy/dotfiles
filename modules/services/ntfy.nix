# ntfy - self-hosted push notifications
#
# Publishes to phone/desktop clients over HTTP(S); topics are the only
# credential, so this instance runs deny-by-default auth and is reachable
# from outside the LAN only through its own authentication.
#
# ROLE IN THE FLEET:
# The alerting stack's page channel. Alertmanager (both hosts) delivers to
# a local alertmanager-ntfy bridge, which publishes here as the
# `alerts` topic; critical alerts arrive urgent, warnings silent. See
# modules/services/monitoring/monitoring.nix for the routing design.
#
# SETUP AFTER FIRST DEPLOYMENT (interactive, one-time):
#  1. Create your user and an access token:
#       sudo -u ntfy-sh ntfy user add --role=admin cory \
#         --config /etc/ntfy/server.yml
#       sudo -u ntfy-sh ntfy token add cory \
#         --config /etc/ntfy/server.yml
#     (`--config` matters: without it these commands create a fresh,
#      empty user database somewhere else and appear to do nothing.)
#  2. Put the token into sops as `monitoring/ntfy/alerts-token`
#     (secrets/secrets.yaml), along with a generated password in
#     `monitoring/ntfy/webhook-password`, e.g.:
#       openssl rand -hex 24   # once per secret
#     then re-run the deploy so the bridges pick them up.
#  3. In the ntfy app add server https://ntfy.gyarmathy.co, log in with
#     the user from step 1, and subscribe to the `alerts` topic.
#
# The auth database lives in /var/lib/ntfy-sh/user.db. It is not in the
# declarative config and not backed up by the restic paths - if this host
# is ever rebuilt, step 1 recreates it.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.ntfy;
in
{
  options.cg.service.ntfy = {
    enable = lib.mkEnableOption "ntfy self-hosted push notification server";

    port = lib.mkOption {
      type = lib.types.port;
      default = 2586;
      description = "Port ntfy listens on (localhost only, behind Caddy)";
    };

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "ntfy";
      description = "Subdomain published through the reverse proxy and tunnel";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.cg.service.reverse-proxy.enable;
        message = "ntfy requires the reverse proxy to be enabled (cg.service.reverse-proxy.enable = true) - phone clients reach it through the tunnel";
      }
    ];

    services.ntfy-sh = {
      enable = true;

      settings = {
        # What clients see in messages' links and what iOS-style instant
        # delivery would key off; must match the public URL.
        base-url = "https://${cfg.subdomain}.gyarmathy.co";
        listen-http = "127.0.0.1:${toString cfg.port}";

        # We sit behind Caddy, which already terminates TLS and applies its
        # own rate limiting; ntfy's rate limits stay at their generous
        # defaults rather than fighting the bridge's retry behaviour during
        # an alert storm - that is exactly when delivery matters most.
        behind-proxy = true;

        # Topics are effectively passwords: nobody may publish or subscribe
        # without an account. Sign-up stays off; accounts are created by hand
        # per the header instructions.
        auth-file = "/var/lib/ntfy-sh/user.db";
        auth-default-access = "deny-all";
        enable-login = true;
        enable-signup = false;
      };
    };

    # Published for phones on mobile data; authentication is ntfy's own job,
    # not the proxy's.
    cg.service.reverse-proxy.services.ntfy = {
      subdomain = cfg.subdomain;
      port = cfg.port;
      localOnly = false;
      rateLimitProfile = "none"; # alert storms must not be rate-limited
    };

    # No firewall rule: ntfy binds 127.0.0.1, Caddy proxies to it locally,
    # and external traffic arrives through the tunnel, not direct ports.

    # The upstream module runs the server under a DynamicUser while also
    # declaring a static ntfy-sh user and shipping /etc/ntfy/server.yml
    # "to configure access control via the cli". Those conflict: the state
    # directory ends up owned by a transient UID, so `sudo -u ntfy-sh ntfy
    # user add` cannot read or create anything in it, and the one-time
    # bootstrap this module documents is impossible. Pinning the service to
    # the static user reconciles them; everything else in the unit's
    # hardening block stands.
    #
    # The Z tmpfiles rule recursively reasserts ownership on every boot and
    # switch: a host that ever ran the dynamic-user incarnation keeps files
    # chowned to a UID that no longer exists, which surfaces as sqlite's
    # "attempt to write a readonly database".
    systemd.tmpfiles.rules = [ "Z /var/lib/ntfy-sh 0700 ntfy-sh ntfy-sh -" ];

    systemd.services.ntfy-sh.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = lib.mkForce "ntfy-sh";
      Group = lib.mkForce "ntfy-sh";
    };
  };
}
