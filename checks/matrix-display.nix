# checks/matrix-display.nix
#
# Behaviour test for rpi01's renderer as cg.service.matrix-display ships it.
#
# The sink cannot run here (a VM has no BCM registers, see ./led-matrix.nix),
# so a stand-in takes its place through led-matrix's `command`: it gets the
# real socket from the real unit, speaks the sink's side of the protocol
# (matrix-display's sink/PROTOCOL.md) and logs what it receives. What this
# proves is the wiring the panels depend on and nothing on rpi01 shows as an
# error: that the confined renderer, as an unprivileged user, can reach the
# socket through its group, read its location through LoadCredential, and
# send frames that are not black.
#
# The location is Greenwich, as matrix-display's own tests use, never rpi01's.
#
# Presence (matrix-display#8) does not exist upstream yet. When it does, this
# grows a mock Home Assistant and asserts the frames go black and back.
{ pkgs, ... }:
let
  # 256x64, rpi01's canvas, so the frames are the size rpi01's are.
  fakeSink = pkgs.writers.writePython3 "fake-matrix-sink" { } ''
    import socket
    import struct
    import sys

    WIDTH, HEIGHT = 256, 64
    FRAME = 16 + WIDTH * HEIGHT * 3 * 2

    # systemd passes the listening socket as fd 3; the --led-* flags it also
    # passes are for the real sink.
    listener = socket.socket(fileno=3)
    while True:
        conn, _ = listener.accept()
        conn.send(b"MDSF" + struct.pack("<III", 1, WIDTH, HEIGHT))
        frames = 0
        while True:
            msg = conn.recv(FRAME + 1)
            if not msg:
                break
            if len(msg) != FRAME or msg[:4] != b"MDSF":
                print(f"bad message of {len(msg)} bytes", flush=True)
                continue
            frames += 1
            if frames % 50 == 0:
                brightest = max(memoryview(msg)[16:].cast("H"))
                print(f"frames={frames} brightest={brightest}", flush=True)
        conn.close()
        print("renderer disconnected", flush=True)
    sys.exit(1)
  '';
in
{
  name = "matrix-display";

  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/services/led-matrix.nix
        ../modules/services/matrix-display.nix
        (import ./stub-secrets.nix {
          secrets."matrix-display/location" = "51.4769, -0.0005\n";
        })
      ];

      system.stateVersion = "26.05";

      cg.service.led-matrix = {
        enable = true;
        command = [ "${fakeSink}" ];
      };
      cg.service.matrix-display.enable = true;
    };

  testScript = ''
    machine.wait_for_unit("matrix-display.service")

    with subtest("the renderer runs unprivileged, in the socket's group"):
        user = machine.succeed("systemctl show -P User matrix-display.service").strip()
        assert user == "matrix-display", f"runs as {user!r}"
        groups = machine.succeed("systemctl show -P SupplementaryGroups matrix-display.service").split()
        assert "led-matrix" in groups, f"supplementary groups are {groups!r}"

    with subtest("frames reach the sink, and they are not black"):
        line = machine.wait_until_succeeds(
            "journalctl -u led-matrix.service -o cat | grep -m1 -E '^frames=[0-9]+ brightest=[1-9]'",
            timeout=60,
        )
        print(line)
        machine.fail("journalctl -u led-matrix.service -o cat | grep -q 'bad message'")

    with subtest("only the renderer can read its location"):
        machine.fail("runuser -u nobody -- cat /run/credentials/matrix-display.service/location")

    with subtest("the renderer comes back with the socket"):
        machine.succeed("systemctl stop led-matrix.socket")
        machine.wait_until_fails("systemctl is-active matrix-display.service")
        machine.succeed("systemctl start led-matrix.socket")
        machine.wait_for_unit("matrix-display.service")
  '';
}
