# checks/media-nfs-recovery.nix
#
# Behaviour test for an NFS media client coming up before its server can be
# reached - homelab01 after the 2026-09-28 power cut, when the switch was
# still booting and every mount attempt failed instantly with "Network is
# unreachable". Four things went wrong there, and each is asserted here:
#
#   - the burst of failed mount attempts spent the mount unit's start limit,
#     and the automount failed for good (media-stack.nix: no start limit);
#   - that failure never paged, because node_exporter's systemd collector
#     drops .mount/.automount units by default (monitoring.nix);
#   - containers binding the media tree started against the bare mountpoint
#     and stayed on it (media-stack.nix: the guard before every such
#     container);
#   - the canary treated the client's root filesystem as the store, tried to
#     prime it, and reported the sentinel missing (download-root-canary.nix).
#
# The unreachable network is an `unreachable` route to the server, added
# before anything touches the mount and removed by the test: the same instant
# ENETUNREACH homelab01 saw, and the recovery is asserted to need nothing more
# than the route coming back.
#
# The container is a local image loaded from the store, so it runs without a
# registry; it binds the media tree exactly as sonarr/radarr/bazarr do, which
# is what makes media-stack give it the guard.
{
  name = "media-nfs-recovery";

  nodes = {
    server = {
      networking.hostName = "server";
      system.stateVersion = "24.11";

      services.nfs.server = {
        enable = true;
        exports = ''
          /srv/media *(rw,no_subtree_check,no_root_squash)
        '';
      };
      networking.firewall.allowedTCPPorts = [ 2049 ];

      systemd.tmpfiles.rules = [
        "d /srv/media 0777 root root -"
        "d /srv/media/downloads 0777 root root -"
        "f /srv/media/downloads/from-server 0644 root root -"
      ];
    };

    client =
      {
        config,
        nodes,
        pkgs,
        ...
      }:
      let
        probeImage = pkgs.dockerTools.buildImage {
          name = "probe";
          tag = "latest";
          copyToRoot = [ pkgs.busybox ];
          config.Cmd = [
            "sleep"
            "infinity"
          ];
        };
      in
      {
        imports = [
          ../modules/services/media-stack/media-stack.nix
          ../modules/services/media-stack/download-root-canary.nix
          ../modules/services/monitoring/monitoring.nix
          ../modules/services/nas-storage.nix
        ];

        networking.hostName = "client";
        system.stateVersion = "24.11";

        cg.service.media-stack = {
          enable = true;
          storage = {
            type = "nfs";
            nfsServer = "server";
          };
        };
        cg.service.media-stack.canary.enable = true;
        cg.service.monitoring.enable = true;

        # The test VM swaps `fileSystems` for this wholesale, so the module's
        # mount has to be handed over explicitly.
        virtualisation.fileSystems."/srv/media" = config.cg.service.media-stack.storage.nfsFileSystem;

        # The switch that had not come back yet: no carrier, so no route to
        # the server at all. A routing *rule* of type unreachable is what
        # returns that errno (ENETUNREACH); an unreachable *route* returns
        # EHOSTUNREACH, which mount.nfs retries until the mount times out, and
        # only instant failures spend the start limit. Both families: the test
        # framework's /etc/hosts gives `server` an IPv6 address as well.
        networking.localCommands = ''
          ip rule add to ${nodes.server.networking.primaryIPAddress} unreachable priority 100
          ip -6 rule add to ${nodes.server.networking.primaryIPv6Address} unreachable priority 100
        '';

        virtualisation.oci-containers.containers.probe = {
          image = "probe:latest";
          imageFile = probeImage;
          volumes = [ "/srv/media:/data" ];
        };

        virtualisation.memorySize = 2048;
      };
  };

  testScript =
    { nodes, ... }:
    ''
      server_ip = "${nodes.server.networking.primaryIPAddress}"
      server_ip6 = "${nodes.server.networking.primaryIPv6Address}"
      metrics = "/var/lib/prometheus-node-exporter/download_root_canary.prom"

      start_all()
      server.wait_for_unit("nfs-server.service")
      client.wait_for_unit("multi-user.target")

      with subtest("the automount survives a burst of instant mount failures"):
          client.succeed(f"(ip route get {server_ip} 2>&1 || true) | grep -q 'Network is unreachable'")
          client.succeed("for i in $(seq 10); do ls /srv/media >/dev/null 2>&1 || true; done")
          client.succeed("journalctl -u srv-media.mount | grep -q 'Network is unreachable'")
          client.succeed("systemctl is-active srv-media.automount")
          client.fail("findmnt --types nfs,nfs4 --mountpoint /srv/media")

      with subtest("the failed mount reaches node_exporter, so SystemdUnitFailed can see it"):
          client.wait_for_open_port(9100)
          # To a file, not piped into grep: pipefail plus grep -q's early exit
          # hands curl an EPIPE. Same shape as checks/monitoring.nix.
          client.wait_until_succeeds(
              "curl -sf -o /tmp/node-metrics http://localhost:9100/metrics "
              "&& grep -F 'node_systemd_unit_state{name=\"srv-media.mount\",state=\"failed\",type=\"nfs\"} 1' /tmp/node-metrics",
              timeout=60,
          )
          client.succeed(
              "grep -F 'node_systemd_unit_state{name=\"srv-media.automount\",state=\"active\"' /tmp/node-metrics"
          )

      with subtest("a container binding the media tree does not start against the bare mountpoint"):
          client.wait_until_succeeds(
              "journalctl -u podman-probe.service | grep -q 'not NFS-mounted'", timeout=120
          )
          client.succeed('test -z "$(podman ps --quiet --filter name=^probe$)"')

      with subtest("the canary reports an unreachable store as unconfirmed and never primes it"):
          client.succeed("systemctl start download-root-canary.service")
          client.succeed(f"grep -q 'download_root_canary_present 1' {metrics}")
          client.fail("test -e /run/download-root-canary-primed")

      with subtest("a failed automount's bare mountpoint is neither primed nor reported wiped"):
          client.succeed("systemctl stop srv-media.automount")
          # What homelab01's root filesystem would have needed for the old
          # canary to prime it: the directory the sentinel lives in.
          client.succeed("mkdir -p /srv/media/downloads")
          client.succeed("systemctl start download-root-canary.service")
          client.succeed(f"grep -q 'download_root_canary_present 1' {metrics}")
          client.fail("test -e /srv/media/downloads/.download-root-canary")
          client.fail("test -e /run/download-root-canary-primed")
          # How homelab01's containers got onto the bare directory: a start
          # while the automount was gone. Without the guard podman binds the
          # local mountpoint here within a second or two.
          client.succeed("systemctl reset-failed podman-probe.service || true")
          client.succeed("systemctl restart --no-block podman-probe.service")
          client.sleep(20)
          client.succeed('test -z "$(podman ps --quiet --filter name=^probe$)"')
          client.succeed("rmdir /srv/media/downloads")
          client.succeed("systemctl start srv-media.automount")

      with subtest("the network coming back is all it takes to recover"):
          client.succeed(f"ip rule del to {server_ip} unreachable priority 100")
          client.succeed(f"ip -6 rule del to {server_ip6} unreachable priority 100")
          client.wait_until_succeeds(
              "podman exec probe test -e /data/downloads/from-server", timeout=180
          )
          client.succeed("findmnt --types nfs,nfs4 --mountpoint /srv/media")
          client.succeed("systemctl is-active srv-media.automount")
    '';
}
