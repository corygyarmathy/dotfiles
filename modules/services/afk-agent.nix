# The AFK agent: an unattended runner for `ready-for-agent` tickets.
#
# Item 4 of docs/plans/afk-agent-pipeline.md, implementing ADR 0004 §1, §3
# and §7: the pipeline runs on homelab01, it is triggered by a polling systemd
# timer rather than a webhook, and it is a real NixOS module so that turning it
# off in an emergency is one boolean rather than remembering which script to
# kill. `cg.service.afk-agent.enable = false` removes the timer, the unit and
# the service account, which is what checks/afk-agent.nix pins.
#
# WHAT THIS MODULE OWNS, AND WHAT IT DOES NOT. This is the unit around the
# runner, not the runner. The poll -> claim -> worktree -> implement loop is
# item 5 and is deliberately a separate piece of work: it is script logic
# driving `gh` and `opencode`, neither of which can run inside the Nix build
# sandbox, so it gets a script-level test harness rather than a VM test. What
# is settled here is everything that surrounds it - the schedule, the runtime
# ceiling, the service account, the credentials, the sandbox, and the toolchain
# on its PATH - so that item 5 writes logic against plumbing that is already
# proven rather than plumbing and logic at once.
#
# Until item 5 lands, ExecStart is a placeholder that checks that plumbing and
# then exits non-zero. That is on purpose: a host that switches this on early
# should get a red unit saying why, not a green one that silently does
# nothing. There is a real ordering constraint behind it - see the `enable`
# option's description.
#
# CONCURRENCY IS ONE, and it is systemd that enforces it rather than anything
# in the runner: a single non-templated unit cannot have two live instances, so
# a poll that fires while a ticket is still being worked cannot start a second
# one. ADR 0004 §8 fixes the principle; raising it later means templating this
# unit, which is a deliberate act rather than an oversight.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.afk-agent;

  stateDir = "/var/lib/afk-agent";

  # The credentials this unit runs on: the name systemd exposes them under in
  # $CREDENTIALS_DIRECTORY, mapped to the sops key each one is read from.
  # Written once because three places need the same answer - the `sops.secrets`
  # declarations, the `LoadCredential` list, and the preflight below - and a
  # set that drifts between them fails at 04:00 on a host rather than here.
  credentials = {
    github-token = "gh-ci/dotfiles-afk-agent-PAT";
    opencode-api-key = "opencode/api-key";
    opencode-username = "opencode/username";
  };

  # The binaries the runner drives, keyed by the name it will invoke: `gh` for
  # the claim, the PR and the relabel, `git` for the worktree, `opencode` for
  # the work itself, and `nix` because the checks it has to pass before pushing
  # are this repository's own. Keyed rather than listed for the same reason as
  # above - the unit's PATH and the preflight's assertions are one list.
  toolchain = {
    git = pkgs.git;
    gh = pkgs.gh;
    opencode = pkgs.opencode;
    jq = pkgs.jq;
    nix = config.nix.package;
  };

  # The stand-in for item 5's runner.
  #
  # Named `preflight` rather than `poll` because it polls nothing: it asserts
  # the two things this module is responsible for handing over - the
  # credentials and the toolchain - and names each one it found, so
  # checks/afk-agent.nix can assert the wiring from the outside without a
  # runner existing. The name is what `systemctl cat afk-agent` shows, so it
  # should say what is actually there.
  #
  # It prints names only, never values: this unit reads a PAT that can push to
  # this repository, and the system journal is not a place to put it.
  #
  # Item 5 replaces this with the real loop and updates that check with it.
  preflight = pkgs.writeShellApplication {
    name = "afk-agent-preflight";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      creds="''${CREDENTIALS_DIRECTORY:?systemd passed no credentials directory}"

      require_credential() {
        if [ ! -s "$creds/$1" ]; then
          echo "afk-agent: credential '$1' is missing or empty" >&2
          exit 1
        fi
        echo "afk-agent: credential '$1' present"
      }

      require_tool() {
        if ! command -v "$1" >/dev/null; then
          echo "afk-agent: tool '$1' is not on this unit's PATH" >&2
          exit 1
        fi
        echo "afk-agent: tool '$1' present"
      }

      ${lib.concatMapStringsSep "\n" (name: "require_credential ${name}") (lib.attrNames credentials)}

      ${lib.concatMapStringsSep "\n" (name: "require_tool ${name}") (lib.attrNames toolchain)}

      echo "afk-agent: runner not implemented yet - this is the item 4 scaffold." >&2
      echo "afk-agent: see docs/plans/afk-agent-pipeline.md, item 5." >&2
      exit 1
    '';
  };
in
{
  options.cg.service.afk-agent = {
    enable = lib.mkEnableOption ''
      the unattended AFK ticket runner.

      Leave this off until item 5 of docs/plans/afk-agent-pipeline.md has
      landed its pre-push denylist gate. That is an ordering constraint rather
      than a preference: `AFK_AGENT_TOKEN` carries the Workflows permission
      (item 3), so nothing at GitHub's end stops this service pushing a branch
      that edits `.github/workflows/`, and a pushed branch runs its own
      workflow with the repository's secrets before anyone reads the PR. The
      gate has to exist, and has to run before the push, or the denylist in
      docs/agents/afk-eligibility.md is enforced by nothing
    '';

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*:0/15";
      example = "hourly";
      description = ''
        How often to poll for eligible tickets, as a systemd calendar
        expression (systemd.time(7)).

        ADR 0004 §3 accepts up to one interval of latency between a ticket
        becoming eligible and work starting, so this trades promptness against
        how often the GitHub API is asked a question whose answer is almost
        always "nothing to do". A quarter hour is well inside that tolerance
        and well inside any rate limit.
      '';
    };

    maxRuntime = lib.mkOption {
      type = lib.types.str;
      default = "4h";
      example = "90min";
      description = ''
        Ceiling on a single run, as `TimeoutStartSec` (systemd.time(7)).

        This is not decoration. A `oneshot` unit defaults to a 90-second start
        timeout, which would kill every real run: the pilot measured 15-60
        minutes per `opencode run`, and item 5 allows two retries on top of
        that. The ceiling still has to exist, because concurrency here is one
        unit - a run that hangs blocks every later poll until something stops
        it, and "something" should not have to be a person.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The three credentials this service needs (item 11), read from the file
    # homelab01 itself decrypts. No `owner`: they are handed to the unit with
    # `LoadCredential`, which systemd reads as root and copies into the unit's
    # private credentials directory before it drops to the account below - so
    # the sops-nix defaults (root:root 0400) are exactly right, and there is
    # no per-secret ownership for this module to get wrong.
    sops.secrets = lib.genAttrs (lib.attrValues credentials) (_: { });

    # A dedicated account rather than root. It is the boundary around a
    # process that runs generated code with repo-write credentials, which is
    # the added blast radius ADR 0004 names in its consequences.
    users.users.afk-agent = {
      isSystemUser = true;
      group = "afk-agent";
      home = stateDir;
      description = "Unattended AFK ticket runner";
    };
    users.groups.afk-agent = { };

    systemd.services.afk-agent = {
      description = "Work one ready-for-agent ticket, unattended";

      # No `wantedBy`. The timer is the only thing that starts this, and a
      # coding agent that also ran on every boot would be a surprise.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # coreutils on top of the toolchain proper: not something the runner
      # drives by name, just the shell utilities any script assumes.
      path = lib.attrValues toolchain ++ [ pkgs.coreutils ];

      # opencode and gh both keep state under $HOME; without this they resolve
      # it from the account's passwd entry, which is the same directory - but
      # only by coincidence, and only until someone changes one of them.
      environment.HOME = stateDir;

      serviceConfig = {
        Type = "oneshot";
        User = "afk-agent";
        Group = "afk-agent";
        StateDirectory = "afk-agent";
        StateDirectoryMode = "0700";
        WorkingDirectory = stateDir;
        UMask = "0077";
        TimeoutStartSec = cfg.maxRuntime;

        LoadCredential = lib.mapAttrsToList (
          alias: name: "${alias}:${config.sops.secrets.${name}.path}"
        ) credentials;

        ExecStart = lib.getExe preflight;

        # Hardening, bounded by what the job actually is. This unit exists to
        # run a coding agent: it needs the network, it needs to write a
        # checkout, and it needs to build. The strict posture the other
        # services here get is not available, so what is left is the subset
        # that costs nothing.
        #
        # Proven against the placeholder below, not against a real run. The
        # syscall filter in particular has only ever seen a shell script; item
        # 5 is where a full `opencode run` first meets it, and loosening a line
        # here is a legitimate outcome of that.
        NoNewPrivileges = true;
        ProtectSystem = "full";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          # Go and Node both enumerate interfaces and read resolver state over
          # netlink, so `gh` and `opencode` need this even though nothing in
          # this unit opens a netlink socket deliberately. Left in rather than
          # discovered on the first real run.
          "AF_NETLINK"
        ];

        # Two settings above are weaker than the obvious choice, both
        # deliberately:
        #
        # ProtectSystem is "full" rather than "strict". Every `nix build` this
        # runs is a client of the Nix daemon, and connecting to a unix socket
        # needs write access to the socket inode - which lives under /nix/var,
        # and which "strict" would remount read-only.
        #
        # MemoryDenyWriteExecute is absent entirely. opencode is a JIT'd
        # JavaScript runtime and needs writable-executable pages; the digital
        # garden dropped the same exemption when its Node toolchain went away,
        # and this is that exemption coming back for the same reason.
      };
    };

    systemd.timers.afk-agent = {
      description = "Poll for ready-for-agent tickets";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;

        # Explicitly not Persistent, unlike every other timer in this
        # repository. Those catch up work that had to happen (a backup, a
        # cleanup); a poll has nothing to catch up on. The tickets a missed
        # poll would have found are still open at the next tick, and a
        # Persistent timer would instead start a coding agent the moment a
        # host finishes booting - including the reboot at the end of every
        # nightly upgrade.
        Persistent = false;
      };
    };
  };
}
