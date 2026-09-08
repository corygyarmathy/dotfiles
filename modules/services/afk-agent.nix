# The AFK agent: an unattended runner for `ready-for-agent` tickets.
#
# Items 4 and 5 of docs/plans/afk-agent-pipeline.md, implementing ADR 0004 §1,
# §3, §5, §7 and §8: the pipeline runs on homelab01, it is triggered by a
# polling systemd timer rather than a webhook, eligibility is re-checked
# against the path denylist rather than trusted from the label, and the whole
# thing is a real NixOS module so that turning it off in an emergency is one
# boolean rather than remembering which script to kill.
# `cg.service.afk-agent.enable = false` removes the timer, the unit and the
# service account, which is what checks/afk-agent.nix pins.
#
# WHAT THIS MODULE OWNS, AND HOW FAR THE RUNNER GETS. Item 4 settled everything
# around the runner - the schedule, the runtime ceiling, the service account,
# the credentials, the sandbox, and the toolchain on its PATH. The runner
# itself is item 5, and lands in pieces: this file currently carries the
# poll -> denylist -> claim -> isolate half (#171). It stops with a ticket
# claimed and an empty worktree on an `afk/*` branch, and says so. The implement
# stage (#172), the review stage (#173), the push and PR (#174) and the stuck
# path that cleans up after a failure (#175) each extend the same script.
#
# The script is written so that its whole state is relocatable through the
# environment, which is how checks/afk-agent-runner.nix drives this exact
# script - never a copy - against a fixture origin repository and a mocked
# `gh`. It follows download-root-canary.nix, which does the same for the same
# reason: neither script's real behaviour is reachable from a VM test.
#
# CONCURRENCY IS ONE, and it is systemd that enforces it rather than anything
# in the runner: a single non-templated unit cannot have two live instances, so
# a poll that fires while a ticket is still being worked cannot start a second
# one. ADR 0004 §8 fixes the principle; raising it later means templating this
# unit, which is a deliberate act rather than an oversight. The runner adds one
# thing systemd cannot: a guard against a *dead* run's leftovers, since a unit
# that was killed mid-ticket leaves a worktree behind and systemd would happily
# start the next poll on top of it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.afk-agent;

  stateDir = "/var/lib/afk-agent";

  # The `owner/name` this runner polls, claims from, and clones. One value
  # rather than two, because `gh` and `git` need the same answer and a runner
  # pointed at one repository's tracker while working another's checkout would
  # be a confusing way to find that out. Not an option: there is one fleet
  # here and one value, and an option nobody sets is a claim about
  # configurability the repository does not honour.
  repository = "corygyarmathy/dotfiles";

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

  # Rule 1 of docs/agents/afk-eligibility.md, held here as the runner's own
  # copy so that ADR 0004 §5's "enforced twice" is two independent readings
  # rather than one list consulted twice. checks/afk-agent-runner.nix asserts
  # this list and the document's still agree, because a denylist that has
  # quietly drifted from the document it implements is a control that has
  # stopped controlling anything without anybody noticing.
  #
  # Matched against the ticket's *prose* - its title and body - which is all
  # there is to read before a line of code has been written. That is a blunt
  # instrument, and deliberately biased: a ticket that merely mentions
  # `secrets/` in passing is rejected along with one that means to edit it.
  # A false rejection costs one ticket being worked by a human; a false accept
  # costs a workflow edit that runs with the repository's secrets before
  # anybody reads the PR (see afk-eligibility.md, "Why these three"). The
  # diff-shaped half of the denylist - including the narrow `ci.yml` matrix
  # exception, which cannot be judged from prose at all - is a pre-push gate
  # and belongs to item 7 (#174).
  deniedPaths = [
    ".github/workflows/"
    "secrets/"
    ".sops.yaml"
  ];

  runner = pkgs.writeShellApplication {
    name = "afk-agent-run";

    # Deliberately only coreutils. The tools the runner drives arrive from the
    # unit's PATH (see `path` below) rather than being baked in here, so that
    # the check can substitute a mocked `gh` for the real one - a runtimeInput
    # would be prepended to PATH and shadow it. `require_tool` below is what
    # turns that looser coupling into something that still fails loudly.
    runtimeInputs = [ pkgs.coreutils ];

    text = ''
      # Everything the runner keeps outside its own process is relocatable, so
      # that the check can point it at a scratch directory and a fixture origin
      # repository. Nothing else is overridable: the label, the branch prefix
      # and the denylist are the behaviour under test, not the fixture around
      # it.
      state_dir="''${AFK_STATE_DIR:-${stateDir}}"
      repo="${repository}"
      repo_url="''${AFK_REPO_URL:-https://github.com/${repository}.git}"

      label="ready-for-agent"
      base_branch="master"
      branch_prefix="afk/"

      checkout="$state_dir/checkout"
      worktrees="$state_dir/worktrees"

      denied=(
        ${lib.concatMapStringsSep "\n        " (p: ''"${p}"'') deniedPaths}
      )

      log() { echo "afk-agent: $*"; }
      die() { echo "afk-agent: $*" >&2; exit 1; }

      # --- what item 4 hands over ------------------------------------------
      #
      # Asserted before anything is polled or claimed, so that a missing
      # credential or a tool that fell off the unit's PATH fails on an empty
      # tracker rather than halfway through a claimed ticket. Names only, never
      # values: this unit reads a PAT that can push to this repository, and the
      # system journal is not a place to put it.

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

      ${lib.concatMapStringsSep "\n      " (name: "require_credential ${name}") (
        lib.attrNames credentials
      )}

      ${lib.concatMapStringsSep "\n      " (name: "require_tool ${name}") (lib.attrNames toolchain)}

      export GH_TOKEN
      GH_TOKEN="$(cat "$creds/github-token")"
      export GH_PROMPT_DISABLED=1
      export GH_NO_UPDATE_NOTIFIER=1

      # --- one ticket at a time --------------------------------------------
      #
      # systemd already makes two live runs impossible (see the module header),
      # but it has nothing to say about a run that died: a unit killed by the
      # runtime ceiling, or by the kill switch, leaves its worktree behind, and
      # the next poll would otherwise claim a second ticket beside the wreckage
      # of the first. Refusing to start is the conservative half of that; the
      # other half - deciding whether to resume or to tear it down - is the
      # stuck path, item 8 (#175). Until that exists this goes red on every poll, which
      # is the intended noise: a wedged pipeline should be loud, not quiet.
      mkdir -p "$worktrees"
      leftover="$(find "$worktrees" -mindepth 1 -maxdepth 1 -print -quit)"
      if [ -n "$leftover" ]; then
        die "a worktree from an earlier run is still here ($leftover); a run died mid-ticket. Clean-up is item 8 (#175); until then, remove it by hand"
      fi

      # --- poll -------------------------------------------------------------
      #
      # Unassigned, because the assignee *is* the claim (docs/agents/issue-tracker.md)
      # and so also the lock that stops a ticket being worked twice - by this
      # runner on a later poll, or by a human right now.
      #
      # Unblocked has a trap in it worth naming: `blockedBy.totalCount` counts
      # every dependency edge, closed ones included, so it is not the gate it
      # looks like. The open ones have to be counted from the nodes.
      #
      # `sort:created-asc` is doing real work, and is not the same thing as the
      # `sort_by` below. `gh issue list` returns newest first, so past the
      # limit it is the *oldest* tickets that fall off the end - and this
      # claims the oldest survivor, so without it the ticket at the front of
      # the queue would become permanently unreachable at exactly the point a
      # backlog got long enough to matter. The search decides which hundred
      # come back; the `sort_by` decides the order among them, and is kept so
      # the ordering holds whatever the API does.
      log "polling $repo for unassigned, unblocked '$label' issues"

      candidates="$(
        gh issue list \
          --repo "$repo" \
          --label "$label" \
          --state open \
          --search "sort:created-asc" \
          --limit 100 \
          --json number,title,body,assignees,blockedBy \
          | jq -c '
              [ .[]
                | select((.assignees | length) == 0)
                | select([.blockedBy.nodes[]? | select(.state == "OPEN")] | length == 0)
              ] | sort_by(.number)
            '
      )"

      total="$(jq 'length' <<<"$candidates")"
      log "$total eligible candidate(s)"

      # --- re-check the denylist, then claim the first survivor -------------
      #
      # Oldest first, which is the only ordering the tracker offers that is
      # stable across polls. A ticket rejected here is skipped rather than
      # relabelled: telling the tracker about it is the stuck path (#175), and
      # a rejection that stopped the poll would let one ineligible ticket block
      # every eligible one behind it.
      first_denied() {
        local text=$1 path
        for path in "''${denied[@]}"; do
          if printf '%s' "$text" | grep -qiF -- "$path"; then
            printf '%s' "$path"
            return 0
          fi
        done
        return 1
      }

      picked=""
      index=0
      while [ "$index" -lt "$total" ]; do
        candidate="$(jq -c ".[$index]" <<<"$candidates")"
        index=$((index + 1))

        scope="$(jq -r '.title + "\n" + (.body // "")' <<<"$candidate")"

        if denied_path="$(first_denied "$scope")"; then
          log "skipping #$(jq -r '.number' <<<"$candidate"): its scope names the denied path '$denied_path' (docs/agents/afk-eligibility.md rule 1)"
          continue
        fi

        picked="$candidate"
        break
      done

      if [ -z "$picked" ]; then
        log "nothing to claim this poll"
        exit 0
      fi

      number="$(jq -r '.number' <<<"$picked")"
      title="$(jq -r '.title' <<<"$picked")"

      # Everything past this point has a claimed ticket behind it, and nothing
      # here gives it back: a failure below leaves #$number assigned, which is
      # also what filters it out of every later poll. That is the stuck path's
      # job (#175, plan item 8) and is the main reason this half is not enough
      # to switch the service on by itself.
      log "claiming #$number: $title"
      gh issue edit "$number" --repo "$repo" --add-assignee @me

      # --- isolate ----------------------------------------------------------
      #
      # AGENTS.md's worktree-isolation pattern, with the worktrees gathered
      # under one directory rather than dropped beside the checkout as siblings:
      # that form exists for a human's interactive tree, and here it is what
      # both the in-flight guard above and item 8 (#175)'s clean-up need to be able to
      # enumerate.
      #
      # The branch is cut from `origin/$base_branch` rather than from whatever
      # the checkout happens to be sitting on, so a checkout left dirty or
      # detached by an earlier run cannot leak into the next ticket's diff.
      slugify() {
        printf '%s' "$1" \
          | tr '[:upper:]' '[:lower:]' \
          | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//' \
          | cut -c1-48 \
          | sed -e 's/-\+$//'
      }

      slug="$number-$(slugify "$title")"

      # The slug becomes both a git ref and a directory name, and its input is
      # an issue title. Checked rather than trusted, and checked against what
      # is allowed rather than against a list of what is not.
      if ! [[ "$slug" =~ ^[0-9]+(-[a-z0-9]+)*$ ]]; then
        die "refusing to build a branch name from #$number: '$slug' is not a safe slug"
      fi

      branch="$branch_prefix$slug"
      worktree="$worktrees/$slug"

      if [ ! -d "$checkout/.git" ]; then
        log "cloning $repo_url into $checkout"
        git clone "$repo_url" "$checkout"
      fi

      git -C "$checkout" fetch --prune origin

      if git -C "$checkout" show-ref --verify --quiet "refs/heads/$branch"; then
        die "branch $branch already exists in $checkout; #$number looks half-worked"
      fi

      # --no-track is not a detail. Without it git sets the new branch's
      # upstream to origin/master, and item 7 (#174)'s push - with git's default
      # push.default of `simple` - would then aim at master rather than at the
      # branch. Protection on master would refuse it, so the failure would be
      # loud rather than dangerous, but a runner whose push target depends on a
      # branch protection rule holding is the wrong shape.
      git -C "$checkout" worktree add --no-track -b "$branch" "$worktree" "origin/$base_branch"

      log "claimed #$number, isolated on $branch at $worktree"
      log "stopping here: the implement stage is item 5's second half (#172) and is not wired in yet"
    '';
  };
in
{
  options.cg.service.afk-agent = {
    enable = lib.mkEnableOption ''
      the unattended AFK ticket runner.

      Leave this off until item 7 (#174) has landed its pre-push denylist gate. That is
      an ordering constraint rather than a preference: `AFK_AGENT_TOKEN`
      carries the Workflows permission (item 3), so nothing at GitHub's end
      stops this service pushing a branch that edits `.github/workflows/`, and
      a pushed branch runs its own workflow with the repository's secrets
      before anyone reads the PR. The pre-claim denylist below is a scope check
      on ticket prose and does not replace it: the gate has to run against the
      diff, before the push, or the `ci.yml` exception in
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

        ExecStart = lib.getExe runner;

        # Hardening, bounded by what the job actually is. This unit exists to
        # run a coding agent: it needs the network, it needs to write a
        # checkout, and it needs to build. The strict posture the other
        # services here get is not available, so what is left is the subset
        # that costs nothing.
        #
        # Proven against the poll/claim/isolate half, not against a full run.
        # The syscall filter in particular has still never seen an `opencode
        # run`; #172 is where it first does, and loosening a line here is a
        # legitimate outcome of that.
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
