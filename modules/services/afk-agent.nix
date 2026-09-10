# The AFK agent: an unattended runner for `ready-for-agent` tickets.
#
# ADR 0004 (pipeline shape) and ADR 0007 (CI gates, review advises): the
# pipeline runs on homelab01, triggered by a polling systemd timer rather
# than a webhook, with eligibility re-checked against the path denylist
# rather than trusted from the label. A real NixOS module so that turning
# it off in an emergency is one boolean: `enable = false` removes the
# timer, the unit and the service account (pinned by checks/afk-agent.nix).
#
# Pipeline order:
#
#   claim -> isolate -> implement until the local gate agrees
#     -> denylist gate on the diff -> push -> open the pull request
#     -> watch its CI -> feed a red run back into the implement session
#        and push the fix to the same branch, up to a bounded number of rounds
#     -> review in a fresh context
#     -> write the findings onto the pull request and label it
#     -> tear the worktree down
#
# Success ends with a pull request open, green, carrying the review's
# findings and the hand-off label. Anything else ends on the stuck path: a
# comment saying what was tried, `agent-working` swapped for `agent-stuck`,
# and nothing left behind (past the push, the pull request is commented on
# and left open without the hand-off label instead; ADR 0007 §2). Both
# endings send a low-priority ntfy notification; a runner that dies outright
# leaves the unit failed, which the existing monitoring already reports.
# OpenCode usage caps are tracked against OpenCode's own usage API (see
# #221), not by this runner.
#
# The review stage is advisory, not a gate (measured; see the findings note
# and ADR 0007). The model never pushes: both sessions are denied the
# tracker verbs through OpenCode's permission layer, and the runner pushes
# from outside the session, only past the pre-push gate. Nothing here merges
# (ADR 0004 §9); the hand-off label is a signal, not a control (ADR 0007 §7).
#
# The runner's whole state is relocatable through the environment, which is
# how checks/afk-agent-runner.nix drives the assembled script - never a
# copy - against a fixture origin and a mocked `gh`.
#
# Concurrency is one, enforced by systemd (a single non-templated unit;
# ADR 0004 §8). The runner adds a guard against a *dead* run's leftovers,
# which systemd would otherwise start the next poll on top of.
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
  # The runner's own GitHub identity (ADR 0006). The App is installed on this
  # repository and no other, which is what makes its reach a property of the
  # installation rather than of a scope list somebody has to keep right. The id
  # is the one in the App's settings URL and is not a secret - the private key
  # under `credentials` is the whole of what has to stay one.
  #
  # `botUserId` is not decoration. GitHub resolves a noreply address to an
  # account by the id in front of the `+`, so without it the commits below are
  # authored by a name that links to nothing.
  appId = "4882603";
  botLogin = "corygyarmathy-afk-agent[bot]";
  botUserId = "326868600";

  credentials = {
    github-app-key = "gh-ci/afk-agent-app-private-key";
    opencode-api-key = "opencode/api-key";
    opencode-username = "opencode/username";
    # The push lane's own token, reused rather than standing up a second
    # credential; a token is only as broad as its ntfy user.
    ntfy-token = "monitoring/ntfy/alerts-token";
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
    # Both belong to the credential: `openssl` signs the App JWT and `curl`
    # exchanges it for an installation token. Neither is reachable through
    # `gh`, which can only speak as an already-minted token.
    openssl = pkgs.openssl;
    curl = pkgs.curl;
    # For the checks-versus-matrix half of the gate, which reads ci.yml.
    # The same tool ci.yml's own lint job uses, so the two readings of that
    # file cannot disagree about what the file says.
    yq = pkgs.yq-go;
    # And what compares the two lists it produces. Named here rather than
    # assumed, because a NixOS unit's default path is coreutils, findutils,
    # gnugrep, gnused and systemd - `diff` is in none of them, and in none of
    # the packages above either. Left out, the gate would have failed with
    # "command not found" on every attempt of every ticket, and the check could
    # not have caught it: the build sandbox has stdenv's `diff` on PATH.
    diff = pkgs.diffutils;
    nix = config.nix.package;
    # Not a tool the runner drives - a tool the *model* drives, through
    # opencode's bash tool, and the reason it is pinned here is that leaving it
    # implicit cost a live run. opencode spawns `$SHELL` for every bash call it
    # makes; systemd sets `$SHELL` from the service account's passwd entry; and
    # `isSystemUser` accounts get `nologin`. So every command the model ran came
    # back "This account is currently not available." while the runner's own
    # `gh` and `git` calls, which never go through a shell, worked perfectly -
    # a ticket that claims, clones and isolates and then cannot read a file.
    # `environment.SHELL` below points at this, so the account keeps `nologin`
    # and stays unloginnable; the shell is a property of the unit, not of the
    # user.
    bash = pkgs.bashInteractive;
  };

  # Rule 1 of docs/agents/afk-eligibility.md, held here as the runner's own
  # copy so that ADR 0004 §5's "enforced twice" is two independent readings.
  # checks/afk-agent-runner.nix asserts this list and the document still
  # agree. Prose matching happens here; the diff-shaped half (including the
  # narrow `ci.yml` matrix exception) is the pre-push gate, against the
  # diff, immediately before the push.
  deniedPaths = [
    ".github/workflows/"
    "secrets/"
    ".sops.yaml"
  ];

  # Read from the modules that own them (ntfy.nix, monitoring.nix) rather
  # than restated. Loopback URL: the runner shares a host with the server,
  # so notifications must not depend on the tunnel standing up.
  ntfyUrl = "http://127.0.0.1:${toString config.cg.service.ntfy.port}";
  ntfyTopic = config.cg.service.monitoring.alertmanager.ntfy.topic;

  # Who the commits are by: the agent's, not the operator's (ADR 0006).
  # Explicit because git cannot infer it here - HOME is the StateDirectory
  # with no global config, and the hostname has no domain, so the fallback
  # identity is refused. `botUserId` is what links the noreply address to
  # the account.
  commitName = botLogin;
  commitEmail = "${botUserId}+${botLogin}@users.noreply.github.com";

  # Watching CI is bounded in POLLS, not seconds (ADR 0007): the harness
  # drives this script with the interval at zero, so second-denominated
  # bounds would test the fixture's numbers instead of production's.

  # The implement session's instructions: the pilot prompt plus the `ci.yml`
  # matrix exception and the failure modes real runs kept reproducing.
  # A file in the store rather than a shell literal, which prose this shape
  # does not survive; only `ISSUE` varies at run time.
  implementPrompt = pkgs.writeText "afk-agent-implement-prompt" (
    builtins.readFile ./afk-agent/lib/prompts/implement.md
  );

  # What the implement session may not do, denied through OpenCode's own
  # permission layer rather than only asked for in the prompt. The pilot
  # verified that an inline `OPENCODE_CONFIG_CONTENT` merges after the
  # repository's own rules and that last match wins, so these take effect.
  #
  # It is a soft control - a pattern match on a command line, not a capability
  # boundary - and this process holds a PAT that can push. What does not depend
  # on the model behaving is `push_gate` below, which reads the diff itself
  # immediately before the push.
  #
  # Deliberately not an option (#210), and not only because there is one fleet:
  # a per-host override of what the agent may not do is exactly what the soft
  # control above makes it look like it can be, and widening it would weaken
  # the one bound (`permissionOverlay` and `reviewOverlay` together) that
  # stops the agent doing its own writeback. Change here must land here, in
  # review, where the denial pattern is read as a decision.
  permissionOverlay = builtins.toJSON {
    permission.bash = {
      "git push*" = "deny";
      "gh pr*" = "deny";
      "gh issue edit*" = "deny";
      "gh issue close*" = "deny";
      "gh issue comment*" = "deny";
    };
  };

  # The review stage's instructions. Same shape as the implement prompt;
  # every clause is here because a measured run went wrong without it (see
  # the findings note). There is deliberately no verdict line: asking for
  # one produced confident decisions about the wrong thing, so the prompt
  # asks for findings only. `ISSUE` and `BASE` are substituted at run time.
  reviewPrompt = pkgs.writeText "afk-agent-review-prompt" (
    builtins.readFile ./afk-agent/lib/prompts/review.md
  );

  # Report-only, enforced through the permission layer rather than only asked
  # for in the prose above. `edit` denied outright is what makes "change no
  # files" a property of the session instead of a request to it: a review pass
  # that quietly fixed what it was supposed to report would produce a commit
  # nothing in this pipeline reviewed, and the gate would bless it.
  #
  # The bash denials are the implement stage's, unchanged, plus `git commit`,
  # which the implement session needs and this one must not have.
  #
  # Same soft-control caveat as `permissionOverlay`: this is a pattern match
  # on a command line, not a capability boundary. Deliberately not an option,
  # for the same reason `permissionOverlay` is not one (see its comment
  # above).
  reviewOverlay = builtins.toJSON {
    permission = {
      edit = "deny";
      bash = {
        "git push*" = "deny";
        "git commit*" = "deny";
        "gh pr*" = "deny";
        "gh issue edit*" = "deny";
        "gh issue close*" = "deny";
        "gh issue comment*" = "deny";
      };
    };
  };

  # The pull request body, written in two passes (ADR 0007): `prIntro` plus
  # the branch's commit messages at creation, `prHandoff` appended once CI
  # is green and the review verified. The commit messages are quoted rather
  # than summarised: a summary would be unchecked prose about its own work,
  # the shape this pipeline refuses everywhere else. `ISSUE`, `BRANCH`,
  # `IMPLEMODEL`, `REVIEWMODEL`, `ATTEMPTS`, `CIROUNDS` and `HANDOFF` are
  # substituted at run time; no token is a substring of another, which keeps
  # one `sed` expression from eating the next. A closing keyword in a commit
  # message still closes the issue on squash-merge; scrubbing them would
  # make the body disagree with the commit.
  prIntro = pkgs.writeText "afk-agent-pr-intro" (
    builtins.readFile ./afk-agent/lib/prompts/pr-intro.md
  );

  prHandoff = pkgs.writeText "afk-agent-pr-handoff" (
    builtins.readFile ./afk-agent/lib/prompts/pr-handoff.md
  );

  runner = pkgs.writeShellApplication {
    name = "afk-agent-run";

    # Deliberately only coreutils. The tools the runner drives arrive from the
    # unit's PATH (see `path` below) rather than being baked in here, so that
    # the check can substitute a mocked `gh` for the real one - a runtimeInput
    # would be prepended to PATH and shadow it. `require_tool` below is what
    # turns that looser coupling into something that still fails loudly.
    #
    # `openssl` is the one exception, and it is here *because* a runtimeInput
    # cannot be shadowed: the JWT it signs is the credential-critical path, so
    # the check asserting the real binary by name is a property worth keeping.
    # `curl` used to sit beside it, and moved out when the ntfy notifications
    # #176 became the one thing the check has to be able to
    # intercept - with the App token mint stubbed through `AFK_GH_TOKEN`,
    # curl's only reachable use in a check run is the notification POST, and
    # the harness records those calls exactly like it records `gh`'s. In
    # production curl is on the unit's PATH through `toolchain` either way.
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];

    text = import ./afk-agent/lib/runner.nix {
      inherit
        lib
        stateDir
        repository
        ntfyUrl
        ntfyTopic
        deniedPaths
        appId
        commitName
        commitEmail
        implementPrompt
        prIntro
        prHandoff
        reviewPrompt
        permissionOverlay
        reviewOverlay
        ;
      inherit (cfg)
        model
        variant
        reviewModel
        maxAttempts
        attemptTimeout
        gateTimeout
        gateTailLines
        reviewTimeout
        ciPollInterval
        ciFirstCheckPolls
        ciSettlePolls
        maxCiRounds
        sessionListDepth
        reviewAxes
        label
        baseBranch
        branchPrefix
        prLabel
        workingLabel
        stuckLabel
        handoffLabel
        ;
      credentialNames = lib.attrNames credentials;
      toolNames = lib.attrNames toolchain;
    };
  };
in
{
  options.cg.service.afk-agent = {
    enable = lib.mkEnableOption ''
      the unattended AFK ticket runner.

      The pre-push denylist gate this switch used to wait on has landed (#174),
      and so has the stuck path (#175): a ticket the runner
      cannot carry to a hand-off is commented on, relabelled `agent-stuck`,
      and torn down - so a failure neither wedges the next poll nor strands a
      claimed ticket. Past the push the hand-back reaches the pull request
      too: it is commented on and left open without the hand-off label, since
      it holds real work (ADR 0007 §2). Notifications through the self-hosted
      ntfy server (#176) - a handed-over pull request and a handed-back
      ticket, both at the lane's silent, informational level - are wired to
      the same switch and go off with it. OpenCode Go usage approaching a cap
      is tracked separately against OpenCode's own usage API (see #221),
      not by a ledger this runner keeps.

      Nothing argues for leaving it off any more. The last thing that did was
      #190 - whether `deploy` should restrict who may push, `deploy` being a
      shorter route to the fleet than any workflow edit - and it is answered
      and shipped: `restrict-deploy-updates` allows the `update` rule to be
      bypassed by a deploy key alone, so `ci-promote-deploy` moves `deploy`
      and no token this pipeline can hold does (ADR 0005). homelab01 turned
      the switch on 2026-09-10.
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
      default = "9h";
      example = "90min";
      description = ''
        Ceiling on a single run, as `TimeoutStartSec` (systemd.time(7)).

        This is not decoration. A `oneshot` unit defaults to a 90-second start
        timeout, which would kill every real run: the pilot measured 15-60
        minutes per `opencode run`, and the implement stage allows two retries
        on top of that. The ceiling still has to exist, because concurrency
        here is one unit - a run that hangs blocks every later poll until
        something stops it, and "something" should not have to be a person.

        The default is the sum of every ceiling underneath it, which is what
        makes it an honest bound rather than a guess. Three implement attempts
        at an hour each with a gate after each is 5h15m; watching CI twice at
        forty-five minutes a watch is 1h30m; the one CI fix round between those
        watches is another attempt and another gate, 1h45m; and the review pass
        is 30m. Nine hours.

        # It grew with the pipeline - the CI rounds in particular - so
        # re-derive it from the ceilings above rather than raising it
        # reflexively if runs start hitting it.

        This is the outer bound rather than an expected duration - every
        measured run of every stage is far inside it - but it is not free.
        Concurrency here is one (ADR 0004 §8), so a run that hangs blocks every
        later poll until this ceiling stops it, and a run that reaches it is
        killed mid-ticket; the next poll's guard finds the worktree it left
        and hands that ticket back (#175) - leaving an open pull
        request untouched too, past the push (ADR 0007).
      '';
    };

    maxMemory = lib.mkOption {
      type = lib.types.str;
      default = "6G";
      example = "4G";
      description = ''
        Ceiling on a single run's memory, as `MemoryMax` (systemd.resource-control(5)).

        `maxRuntime` above bounds how long a run may take and nothing bounded
        how much of the host it may take while doing it. On 2026-09-10 a run
        that had already implemented its ticket and passed its own tests was
        killed proving it: `nix flake check` reached 8.3 GB resident on a 15 GB
        host with no swap, and the kernel's OOM killer fired with
        `CONSTRAINT_NONE` - a global out-of-memory, not a cgroup one. It chose
        the biggest process, which happened to be this unit's. It could as
        easily have chosen Grafana, Prometheus or Jellyfin: an unattended
        coding agent had become a denial-of-service risk to every other service
        on the machine.

        This is the containment for that, and the per-check gate above is what
        makes it comfortable rather than tight. Scope it honestly: a `nix
        build` hands the work to `nix-daemon.service`, which has a cgroup of
        its own, so what this actually bounds is the evaluator, opencode, and
        anything the model runs directly - which is precisely what overran.

        The default leaves roughly 9 GB for everything else on homelab01,
        whose other services sit at about 6 GB. Reaching it kills inside this
        cgroup: the run dies, its worktree is left, and the next poll's guard
        hands the ticket back (#175) - the same ending as the runtime
        ceiling, and a far better one than taking the host with it.

        `MemoryHigh` is deliberately not set alongside it. `MemoryHigh`
        throttles and reclaims before killing, which earns its place when
        there is swap to reclaim into; homelab01 has none, and the memory in
        question is a Nix evaluator's anonymous heap. It would buy a stall
        rather than a survival.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "opencode-go/glm-5.3-flash";
      description = ''
        Model the implement stage (and the CI fix round) runs.
        Settled by the pilot's cost/convergence measurements; see
        docs/research/afk-agent-pilot-findings.md.
      '';
    };

    variant = lib.mkOption {
      type = lib.types.str;
      default = "high";
      description = "Reasoning variant passed to opencode for every session this runner opens.";
    };

    reviewModel = lib.mkOption {
      type = lib.types.str;
      default = "opencode-go/deepseek-v4-pro";
      description = ''
        Model the advisory review pass runs. Chosen for findings quality
        rather than gating; see ADR 0007 and
        docs/research/afk-agent-pilot-findings.md.
      '';
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "ready-for-agent";
      description = "Issue label the runner polls and claims (ADR 0004 §3, §5).";
    };

    baseBranch = lib.mkOption {
      type = lib.types.str;
      default = "master";
      description = "Branch the runner clones and the pull request targets.";
    };

    branchPrefix = lib.mkOption {
      type = lib.types.str;
      default = "afk/";
      description = "Prefix for the per-ticket branch the runner creates.";
    };

    prLabel = lib.mkOption {
      type = lib.types.str;
      default = "afk-agent";
      description = "Label applied to pull requests the runner opens.";
    };

    workingLabel = lib.mkOption {
      type = lib.types.str;
      default = "agent-working";
      description = ''
        Label a claimed ticket carries while the runner works it (ADR 0006;
        see docs/agents/triage-labels.md).
      '';
    };

    stuckLabel = lib.mkOption {
      type = lib.types.str;
      default = "agent-stuck";
      description = ''
        Label a handed-back ticket carries instead of `workingLabel`
        (see docs/agents/triage-labels.md).
      '';
    };

    handoffLabel = lib.mkOption {
      type = lib.types.str;
      default = "agent-ready-for-review";
      description = ''
        Label applied to the pull request together with the review findings,
        once CI is green. A signal, not a merge control (ADR 0007 §7).
      '';
    };

    maxAttempts = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Implement attempts per ticket: the first try plus two retries (ADR 0004 §6).";
    };

    attemptTimeout = lib.mkOption {
      type = lib.types.int;
      default = 3600;
      description = "Ceiling in seconds on one implement attempt, so a stuck attempt fails countable rather than by the unit timeout.";
    };

    gateTimeout = lib.mkOption {
      type = lib.types.int;
      default = 2700;
      description = "Ceiling in seconds on one run of the local gate (the other half of an attempt).";
    };

    gateTailLines = lib.mkOption {
      type = lib.types.int;
      default = 200;
      description = "How many trailing lines of a failing gate's log are handed back to the model on a retry.";
    };

    reviewTimeout = lib.mkOption {
      type = lib.types.int;
      default = 1800;
      description = "Ceiling in seconds on the review pass. The review does not retry (ADR 0004 §6).";
    };

    ciPollInterval = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Seconds between polls when watching the branch's CI.";
    };

    ciFirstCheckPolls = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Polls to wait for CI's first check before calling it absent rather than slow (ADR 0007).";
    };

    ciSettlePolls = lib.mkOption {
      type = lib.types.int;
      default = 45;
      description = "Ceiling in polls on one CI watch (ADR 0007).";
    };

    maxCiRounds = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "CI watches per ticket: the initial watch plus one fix-and-rewatch round (ADR 0007).";
    };

    sessionListDepth = lib.mkOption {
      type = lib.types.int;
      default = 20;
      description = "How deep to look when turning an opencode session title back into a session id.";
    };

    reviewAxes = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Sub-agent contexts a genuine `code-review` pass fans out into: standards and spec.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The three credentials this service needs, read from the file
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

      # opencode spawns `$SHELL` for every bash call the model makes. Left
      # unset, systemd fills it in from the service account's passwd entry,
      # which is `nologin` for an `isSystemUser` account - so this is set here
      # rather than by giving the account a login shell it has no other use
      # for. See `toolchain.bash`, and `require_shell` in the preflight, which
      # is what turns getting this wrong into a failed empty poll rather than a
      # ticket claimed and then abandoned.
      environment.SHELL = lib.getExe toolchain.bash;

      serviceConfig = {
        Type = "oneshot";
        User = "afk-agent";
        Group = "afk-agent";
        StateDirectory = "afk-agent";
        StateDirectoryMode = "0700";
        WorkingDirectory = stateDir;
        UMask = "0077";
        TimeoutStartSec = cfg.maxRuntime;

        # See `maxMemory`. The runtime ceiling's counterpart: this unit runs a
        # coding agent that builds things, and until 2026-09-10 nothing stopped
        # it exhausting the host's memory and taking unrelated services down
        # with it.
        MemoryMax = cfg.maxMemory;

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
        # Loosening a line here because a run demonstrably needs more is a
        # legitimate outcome, not a failure of this posture.
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
