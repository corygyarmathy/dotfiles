# checks/host-alive.nix
#
# Behaviour test for the host-alive beacon (modules/services/host-alive.nix,
# item 9 of docs/plans/deployment-hardening.md).
#
# The beacon is the endpoint every item-9 probe actually depends on: a socat
# 200-responder that is never moved or disabled with a service. The
# `monitoring` test only proves the remoteProbe *wiring* - that a remote target
# is scraped and labelled kind="remote" - because its sandbox has no network,
# so it points the remote probe at Prometheus's own /-/healthy endpoint rather
# than at a real beacon. Nothing there proves the beacon itself starts, binds,
# and answers 200. That is the exact class of thing this harness exists to
# prove, and the module's "nothing to go wrong except the host itself" is an
# assertion that should be exercised, not assumed.
#
# No network, no Caddy, no tunnel: this boots the module alone and checks the
# unit is active and the responder returns its fixed body. The publish side is
# pinned by checks/publish.nix (the beacon is registered and both servers agree
# on a port); the probe side is pinned by checks/monitoring.nix. This is the
# middle layer between them: the thing being probed answers.
{
  name = "host-alive";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ../modules/services/host-alive.nix ];

      networking.hostName = "host-alive";
      system.stateVersion = "24.11";

      cg.service.host-alive.enable = true;
    };

  testScript = ''
    machine.wait_for_unit("host-alive.service")
    machine.wait_for_open_port(9080)

    with subtest("the beacon answers 200 with its fixed body"):
        # `-f` fails on a non-200 status, so reaching the body assertion means
        # the responder returned 200. The body is asserted too, not just the
        # status: a responder that started answering something else would
        # still be a regression the alert would not catch, since the probes
        # only care about probe_success.
        out = machine.succeed("curl -sf http://127.0.0.1:9080/")
        assert out == "ok", f"unexpected beacon body: {out!r}"
  '';
}
