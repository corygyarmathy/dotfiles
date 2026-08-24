# Caddy starts with the generated config, and routes to a backend over TLS.
#
# Every publicly reachable service on this fleet sits behind this module, and
# a routing regression is completely invisible to a build: reverse-proxy.nix
# assembles a Caddyfile out of options, and Caddy only reads it at activation.
# A malformed directive, a plugin that stopped providing `rate_limit`, a
# header block that no longer parses - all of them build perfectly and take
# every service on the host down when they land.
#
# The only substitution this test makes is the certificate issuer. Production
# gets an individual Let's Encrypt certificate per vhost over the ACME DNS-01
# challenge against Cloudflare, which needs the network the sandbox does not
# have; `tls internal` puts Caddy's own CA in its place, through the module's
# existing per-service `extraConfig` rather than by overriding anything. So
# the sites are still served over HTTPS on 443, and everything except
# issuance is the configuration the hosts actually run.
#
# `auto_https off` was the first attempt and is the wrong tool: it stops
# certificate provisioning but does not move the listener, so Caddy sits on
# 443 with no certificate and every request fails. Worth recording, since the
# option name suggests otherwise.
{
  name = "reverse-proxy";

  nodes.machine =
    { config, pkgs, ... }:
    let
      backendPort = 8123;

      # Echoes the request headers back as JSON, so the test can assert on
      # what the proxy actually forwarded rather than only on a status code.
      # The `header_up` lines in mkProxyHost are the part of that module most
      # likely to be edited by someone with no easy way to check the result.
      backend = pkgs.writeText "backend.py" ''
        import json
        from http.server import BaseHTTPRequestHandler, HTTPServer


        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps({
                    "path": self.path,
                    "headers": {k.lower(): v for k, v in self.headers.items()},
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass


        HTTPServer(("127.0.0.1", ${toString backendPort}), Handler).serve_forever()
      '';

      # 40 characters of [A-Za-z0-9_-], because that is the shape of a
      # Cloudflare API token and caddy-dns/cloudflare validates it while
      # provisioning the TLS app - before any request is served, and even
      # though nothing here will ever call the API with it. A placeholder that
      # does not parse takes Caddy down at startup, which is worth knowing
      # about the real secret too.
      token = "TESTONLY-not-a-real-cloudflare-token-abc";
    in
    {
      imports = [
        ../modules/services/reverse-proxy.nix
        (import ./stub-secrets.nix {
          secrets."cloudflare/api-token" = token;
          templates."caddy-cloudflare-env" = "CF_API_TOKEN=${token}\n";
        })
      ];

      cg.service.reverse-proxy = {
        enable = true;
        email = "test@example.invalid";
        # Exactly how the hosts wire it (hosts/homelab01/default.nix:370), so
        # the test breaks if that indirection changes.
        cloudflareTokenFile = config.sops.templates."caddy-cloudflare-env".path;

        services = {
          # The common case: a LAN-only service. mkProxyHost's allowlist
          # includes 127.0.0.1, so a request from inside the VM is permitted.
          internal = {
            subdomain = "internal";
            port = backendPort;
            localOnly = true;
            extraConfig = "tls internal";
          };

          # An internet-facing service, which takes the other branch of
          # mkProxyHost entirely: security headers and the rate_limit
          # directive - the latter being the one thing here that depends on
          # the Caddy build actually carrying the caddy-ratelimit plugin.
          public = {
            subdomain = "public";
            port = backendPort;
            localOnly = false;
            rateLimitProfile = "media";
            extraConfig = "tls internal";
          };
        };
      };

      systemd.services.test-backend = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${backend}";
      };
    };

  testScript = ''
    import json

    # --resolve rather than a Host header: the vhosts are matched on SNI, and
    # -H 'Host:' does not set it. -k because the certificate is issued by
    # Caddy's own CA, which is the whole point of `tls internal` here.
    def curl(host, args="", path="/"):
        return "curl -sk {} --resolve {}:443:127.0.0.1 https://{}{}".format(
            args, host, host, path
        )

    def get(host, path="/"):
        return json.loads(machine.succeed(curl(host, "-f", path)))

    # Lowercased, because these vhosts are served over TLS and therefore
    # HTTP/2, where header names are lowercase on the wire. Comparing against
    # the mixed case written in reverse-proxy.nix does not merely fail - the
    # "these headers are absent" subtest below would pass for every input,
    # which is worse.
    def headers_of(host):
        return machine.succeed(curl(host, "-o /dev/null -D -")).lower()

    machine.wait_for_unit("test-backend.service")
    machine.wait_for_open_port(${toString 8123})

    with subtest("caddy accepts the generated config"):
        # The assertion that pays for this whole test. Caddy validates its
        # config at startup and refuses to run on a bad one, so a unit that
        # reaches active means every directive the module emitted parsed -
        # including the ones reachable only through a rate limit profile.
        machine.wait_for_unit("caddy.service")
        machine.wait_for_open_port(443)

        # An open 443 does not mean a certificate exists. `tls internal` has
        # Caddy issue one per vhost from its own CA, and that happens after the
        # listener comes up - so a request sent in between fails the handshake
        # with curl exit 35, several subtests before anything about routing is
        # actually wrong. Waiting on a real handshake is the readiness signal;
        # the port is only the start of one.
        #
        # Both vhosts, because Caddy issues their certificates independently
        # and either one can be the straggler.
        #
        # Without -f, so this waits on TLS alone and does not quietly double as
        # an assertion about the response.
        for host in ["internal.gyarmathy.co", "public.gyarmathy.co"]:
            machine.wait_until_succeeds(curl(host, "-o /dev/null"), timeout=60)

    with subtest("a LAN-only service routes to its backend"):
        body = get("internal.gyarmathy.co", "/some/path")
        assert body["path"] == "/some/path", body

    with subtest("the upstream sees the headers mkProxyHost sets"):
        headers = get("internal.gyarmathy.co")["headers"]
        # header_up Host {host}: the backend must see the original vhost, not
        # 127.0.0.1. Getting this wrong breaks every service that builds an
        # absolute URL, which is most of them.
        assert headers["host"] == "internal.gyarmathy.co", headers
        assert headers["x-forwarded-proto"] == "https", headers
        assert "x-real-ip" in headers, headers
        assert "x-forwarded-for" in headers, headers

    with subtest("an internet-facing service gets the security headers"):
        response = headers_of("public.gyarmathy.co")
        for expected in [
            "x-frame-options: sameorigin",
            "x-content-type-options: nosniff",
            "referrer-policy: strict-origin-when-cross-origin",
            "strict-transport-security:",
        ]:
            assert expected in response, f"{expected!r} missing from:\n{response}"

    with subtest("a LAN-only service does not get them"):
        # Not pedantry: localOnly selects between two branches of mkProxyHost,
        # so a service silently flipping branch shows up as headers appearing
        # or disappearing rather than as anything failing outright.
        response = headers_of("internal.gyarmathy.co")
        assert "x-frame-options" not in response, response

    with subtest("an unconfigured host is not routed anywhere"):
        machine.fail(curl("nothing-here.gyarmathy.co", "-f"))
  '';
}
