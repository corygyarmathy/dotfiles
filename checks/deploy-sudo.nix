# checks/deploy-sudo.nix
#
# Behaviour test for item 10 of docs/plans/deployment-hardening.md: the deploy
# user's sudo is confined to the activation path, and nothing else changed
# around it.
#
# The two ways this change can go wrong are both silent in a build. Too narrow
# and the first real `deploy` dies at the copy step or the activation step with
# a sudo error; too wide and the "scoped exception" is the old `sudo ALL`
# wearing different clothes. Neither shows up until someone runs deploy-rs
# against a host, so this boots the module and drives the *exact* command
# shapes deploy-rs emits:
#
#   - `activate` / `wait` / `revoke` are one binary - <closure>/activate-rs -
#     with different subcommands, escalated via `sudo -u root`;
#   - magicRollback's confirmation is `sudo -u root rm /tmp/deploy-rs-canary-<hash>`.
#
# The fake closure is a store path whose name matches the real deploy-rs
# closure (`activatable-nixos-system-…`) and whose only content is an
# `activate-rs` that records how it ran - so the sudoers wildcard is exercised
# against a path with the real shape, and "it ran as root" is asserted, not
# assumed.
{
  lib,
  pkgs,
  ...
}:
let
  fakeClosure = pkgs.runCommand "activatable-nixos-system-deploy-sudo" { } ''
    mkdir -p $out
    cat > $out/activate-rs <<'EOF'
    #!/bin/sh
    printf 'ran as %s: %s\n' "$(id -u)" "$*" > /tmp/activate-rs-ran
    EOF
    chmod +x $out/activate-rs
  '';
in
{
  name = "deploy-sudo";

  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/nixos/deploy-rs.nix
        ../modules/nixos/ssh-hardening.nix
      ];

      networking.hostName = "deploy-sudo";
      system.stateVersion = "24.11";

      cg.deploy-rs = {
        enable = true;
        # Fixture only - this VM never runs sshd, so the key content is unused.
        authorizedKeys = [ "ssh-ed25519 AAAA... deploy@xps15" ];
      };

      # A human, wheel member, with a password - the account whose sudo must
      # still prompt. The `%wheel` rule must survive the deploy rule next to
      # it, and this user is the check.
      users.users.coryg = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        password = "coryg-password";
      };

      # Both servers run user-security with execWheelOnly (the setuid sudo
      # wrapper is wheel-exec only). The deploy user is not in wheel, so this
      # is the setting that decides whether the module's wrapper-group grant
      # lets it execute sudo at all - omitting it would make the test green
      # while every real deploy dies at the first escalation.
      security.sudo.execWheelOnly = true;
      security.sudo.wheelNeedsPassword = true;

      # Referenced so the fake closure is present in the VM's store; the
      # system-path symlink is a side effect, the assertion only needs the
      # path to exist.
      environment.systemPackages = [ fakeClosure ];
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")

    # Nix-interpolated once here so the f-strings below only reference Python
    # variables (the test driver type-checks the script as Python).
    FAKE = "${fakeClosure}/activate-rs"
    CLOSURE = "${fakeClosure}"
    COREUTILS_ECHO = "${pkgs.coreutils}/bin/echo"

    with subtest("the deploy account is out of wheel and passwordless"):
        groups = machine.succeed("id deploy")
        assert "wheel" not in groups, groups
        # NixOS marks a passwordless system account locked ("L") rather than
        # "NP"; either way the point is that no password stands behind the
        # sudo rule.
        status = machine.succeed("passwd -S deploy").split()[1]
        assert status != "P", status

    with subtest("sudo -n as deploy reaches activate-rs and nothing else"):
        # The three deploy-rs escalation shapes, verbatim except for the
        # closure path.
        machine.succeed(
            f"su deploy -c 'sudo -n -u root {FAKE} activate {CLOSURE} "
            "--profile-path /nix/var/nix/profiles/system --temp-path /tmp "
            "--confirm-timeout 30 --magic-rollback'"
        )
        machine.succeed(f"su deploy -c 'sudo -n -u root {FAKE} wait {CLOSURE} --temp-path /tmp'")
        machine.succeed(f"su deploy -c 'sudo -n -u root {FAKE} revoke --profile-path /nix/var/nix/profiles/system'")
        assert machine.succeed("cat /tmp/activate-rs-ran").startswith("ran as 0")

        # Everything else is refused, passwordlessly and without a rule.
        machine.fail("su deploy -c 'sudo -n -u root /bin/sh -c id'")
        machine.fail(f"su deploy -c 'sudo -n -u root {COREUTILS_ECHO} hi'")
        machine.fail("su deploy -c 'sudo -n -u root id'")

    with subtest("magicRollback's confirmation rm is scoped to the canary"):
        canary = "/tmp/deploy-rs-canary-0123456789abcdef0123456789abcdef"
        machine.succeed(f"touch {canary}")
        machine.succeed(f"su deploy -c 'sudo -n -u root rm {canary}'")
        machine.fail(f"test -e {canary}")

        # The regex is anchored: a name sharing the prefix is not covered (a
        # second dash is outside [a-z0-9]), and a second argument cannot ride
        # along.
        machine.succeed("touch /tmp/deploy-rs-canary-not-a-canary")
        machine.fail("su deploy -c 'sudo -n -u root rm /tmp/deploy-rs-canary-not-a-canary'")
        machine.fail("su deploy -c 'sudo -n -u root rm /tmp/deploy-rs-canary-aa /etc/hostname'")
        machine.succeed("rm /tmp/deploy-rs-canary-not-a-canary")

    with subtest("sudo -l for deploy lists only the scoped commands"):
        listing = machine.succeed("su deploy -c 'sudo -l -n'")
        assert "NOPASSWD:" in listing, listing
        assert "activate-rs" in listing, listing
        assert "deploy-rs-canary" in listing, listing
        assert "(ALL" not in listing, listing

    with subtest("coryg's own sudo still requires a password"):
        # `-S` feeds the password over stdin: this both proves the prompt is
        # still there (without -S and without a TTY, sudo would fail before
        # listing) and that the wheel rule still works for the human.
        listing = machine.succeed(
            "su coryg -c \"printf 'coryg-password\\n' | sudo -S -l\""
        )
        # The %wheel rule is present (NixOS renders it with its default
        # SETENV tag) and carries no NOPASSWD - it must still prompt.
        assert "(ALL : ALL)" in listing, listing
        assert "NOPASSWD" not in listing, listing
        machine.fail("su coryg -c 'sudo -n true'")

    with subtest("deploy stays a trusted nix user for the copy step"):
        # Item 10 drops deploy from wheel, which is also what made the deploy
        # *copy* work (unsigned closures need a trusted user on the receiving
        # daemon). The module must grant that explicitly or every deploy fails
        # at the copy step with "lacks a signature by a trusted key". The
        # `@wheel` half of the host setting comes from flake.nix, not from
        # this module, so the assertion is that deploy is listed at all.
        trusted = machine.succeed("awk '/^trusted-users/ {print}' /etc/nix/nix.conf")
        assert "deploy" in trusted, trusted
        assert "root" in trusted, trusted
  '';
}
