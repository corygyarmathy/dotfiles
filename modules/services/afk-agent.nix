# The AFK agent: `afk work` from corygyarmathy/afk-agent, run as a service.
#
# The Go successor to the bash prototype that lived at this path until #283.
# Its design is that repository's ADR 0001; what it needs from a host is its
# docs/agents/review.md and docs/agents/implement.md. This module is where it
# is packaged and configured, and nowhere else: the binary holds no defaults,
# every parameter is a flag with an environment variable beside it, and
# `afk help` is the list of record.
#
# The tuning options below have no defaults either, for the same reason. A
# limit an unattended agent runs with should be read where the host is
# configured, not inherited from a module nobody opens. What the module decides
# itself is plumbing with one right answer: where the store lives, which
# credentials arrive and how, which opencode runs, and where ntfy is.
#
# `afk work` is a long-running pool, not a oneshot on a timer: it polls on its
# own (`poll`) and every transition is its own crash boundary, so a restart -
# a rebuild, a rotated secret, a reboot - costs at most the transitions in
# flight and nothing else (ADR 0001 §2, §7).
#
# checks/afk-agent.nix boots this module with stub credentials and asserts the
# unit, and a hand-run of an implement transition, each get past every
# parameter to their first request to GitHub.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.cg.service.afk-agent;

  stateDir = "/var/lib/afk-agent";
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.afk-agent;

  # The credentials this unit runs on: the name systemd exposes each under in
  # $CREDENTIALS_DIRECTORY, mapped to the sops key it is read from. Written once
  # because three places need the same answer - the `sops.secrets`
  # declarations, `LoadCredential`, and the environment below.
  #
  # Each reaches the binary as a path, never a value: an argument is visible in
  # `ps` and an environment variable in /proc (its ADR 0005 §6).
  credentials = {
    # The runner's GitHub identity is the App (this repository's ADR 0006). The
    # binary mints its own installation tokens from this key and reads its
    # `[bot]` login from GitHub, so the key and `appId` are the whole of it.
    app-key = "gh-ci/afk-agent-app-private-key";
    # One key, two readers: the usage endpoint the budget is observed from, and
    # opencode itself, through the auth.json `opencodeAuth` writes.
    opencode-api-key = "opencode/api-key";
    # The alerting stack's publish token, reused rather than standing up a
    # second ntfy account; the topic is what keeps the two streams apart.
    ntfy-token = "monitoring/ntfy/alerts-token";
  };

  credential = name: "%d/${name}";

  # The whole of model eligibility (its docs/agents/model-enrolment.md). Mapped
  # field by field so the file carries exactly the schema's fields: the decoder
  # refuses any other.
  enrolment = pkgs.writeText "afk-agent-enrolment.json" (
    builtins.toJSON {
      tiers = map (tier: { inherit (tier) name models; }) cfg.tiers;
    }
  );

  # opencode reads provider credentials from its own auth.json, and the binary
  # does not provision them. Written before every start from the credential,
  # so a rotated key is picked up by the restart sops-nix triggers. `--rawfile`
  # rather than `--arg "$(cat ...)"`, which would put the key in jq's argv.
  #
  # Only `opencode-go` is written because it is the only provider the key is
  # for. Enrolling a model from any other provider needs its credential added
  # here too, or every run on that model fails as transient.
  opencodeAuth = pkgs.writeShellApplication {
    name = "afk-agent-opencode-auth";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      dir="$HOME/.local/share/opencode"
      mkdir -p "$dir"
      jq -n --rawfile key "$CREDENTIALS_DIRECTORY/opencode-api-key" \
        '{"opencode-go": {type: "api", key: ($key | sub("\\s+$"; ""))}}' >"$dir/auth.json.tmp"
      mv "$dir/auth.json.tmp" "$dir/auth.json"
    '';
  };

  # Go's `time.ParseDuration` shapes, checked here so a typo fails evaluation
  # rather than the unit's first start.
  duration = lib.types.strMatching "([0-9]+(\\.[0-9]+)?(ns|us|ms|s|m|h))+" // {
    description = "Go duration (e.g. 90s, 1h30m)";
  };

  toEnv = lib.mapAttrs (_: toString);

  # The local gate an implement session has to pass before anything is pushed
  # (`--gate`): this repository's own CI, read from the workspace's ci.yml
  # rather than restated here, so the two cannot drift apart. A branch the
  # gate passes and CI fails costs a fix round and a CI run; one it fails
  # costs a session, which is cheaper.
  #
  # The lint job's `run:` steps run as a runner runs a step with no `shell:`
  # (`bash -e`), then one `nix build` per entry of the `checks` and `build`
  # matrices. CI's shape, not `nix flake check`: that evaluates every output
  # in one process, and on 2026-09-10 the prototype's run of it reached 8.3 GB
  # and took a global OOM on homelab01. A lint step with anything a runner
  # alone can read - an Actions expression, `shell:`, `env:`, `if:` - fails
  # the gate rather than running as something it is not; so does an empty
  # list, which is a gate that ran nothing.
  #
  # A session can edit ci.yml and pass its own gate, which is why the
  # assertion below keeps .github/workflows on the denylist: the push is then
  # handed back.
  #
  # `nix fmt` formats in place before it fails, so a formatting failure also
  # leaves the workspace dirty - which the agent hands back to the session as
  # uncommitted changes, the right answer either way. The lint steps write
  # under /tmp, which the unit's gates share; `heavy-build` runs one at a time.
  gate = pkgs.writeShellApplication {
    name = "afk-agent-gate";
    runtimeInputs = [
      config.nix.package
      pkgs.bash
      pkgs.coreutils
      pkgs.diffutils
      pkgs.yq-go
    ];
    text = ''
      ci=.github/workflows/ci.yml
      lint='.jobs.lint.steps | map(select(has("run")))'

      odd="$(yq "(.jobs.lint | keys - [\"name\", \"runs-on\", \"steps\"] | length) + ($lint | map(select(keys - [\"name\", \"run\"] | length > 0)) | length)" "$ci")"
      if [ "$odd" -ne 0 ]; then
        echo "afk-agent-gate: ci.yml's lint job uses keys only a runner reads" >&2
        exit 1
      fi

      steps="$(yq "$lint | length" "$ci")"
      [ "$steps" -gt 0 ]
      for ((i = 0; i < steps; i++)); do
        run="$(yq -r "$lint | .[$i].run" "$ci")"
        case "$run" in
          *\$\{\{*)
            echo "afk-agent-gate: lint step $i uses an Actions expression" >&2
            exit 1
            ;;
        esac
        bash -e -c "$run"
      done

      checks="$(yq -r '.jobs.checks.strategy.matrix.check[]' "$ci")"
      hosts="$(yq -r '.jobs.build.strategy.matrix.host[]' "$ci")"
      [ -n "$checks" ]
      [ -n "$hosts" ]
      for check in $checks; do
        nix build --no-link ".#checks.x86_64-linux.$check"
      done
      for host in $hosts; do
        nix build --no-link ".#nixosConfigurations.$host.config.system.build.toplevel"
      done
    '';
  };

  # The unit's confinement, shared with `afk-agent-run` below so that a
  # hand-run is the unit in every respect but its lifetime.
  sandbox = {
    User = "afk-agent";
    Group = "afk-agent";
    StateDirectory = "afk-agent";
    StateDirectoryMode = "0700";
    WorkingDirectory = stateDir;
    UMask = "0077";

    LoadCredential = lib.mapAttrsToList (
      name: secret: "${name}:${config.sops.secrets.${secret}.path}"
    ) credentials;

    MemoryMax = cfg.maxMemory;

    # Hardening, bounded by what the job is: a network client that runs
    # opencode, which is a JIT'd JavaScript runtime (so no
    # MemoryDenyWriteExecute), and a gate that builds through the Nix daemon.
    NoNewPrivileges = true;
    # "strict" still lets a Nix client connect to the daemon's socket: a
    # read-only mount does not refuse connect(2). The prototype ran with
    # "full" believing otherwise, and checks/afk-agent.nix pins that it is not
    # needed.
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
      # Go and Node read interface and resolver state over netlink.
      "AF_NETLINK"
    ];
  };

  # A command run as the unit runs: its account, environment, credentials and
  # confinement, in a transient unit. What afk-agent's docs/agents/implement.md
  # means by "with the parameters in the environment", e.g.
  #
  #   sudo afk-agent-run afk run implement --issue 7
  #
  # Any command, not just `afk`, so the same wrapper answers "can the unit
  # reach X" - which is how checks/afk-agent.nix asks it of the Nix daemon.
  runAsUnit = pkgs.writeShellApplication {
    name = "afk-agent-run";
    text =
      let
        property = name: value: "-p ${lib.escapeShellArg "${name}=${value}"}";
        properties = lib.concatLists (
          lib.mapAttrsToList (
            name: value:
            if name == "LoadCredential" then
              map (property name) value
            else if lib.isList value then
              [ (property name (lib.concatStringsSep " " value)) ]
            else if lib.isBool value then
              [ (property name (lib.boolToString value)) ]
            else if lib.isString value || lib.isInt value then
              [ (property name (toString value)) ]
            else
              throw "afk-agent-run: no -p encoding for sandbox.${name}"
          ) sandbox
        );
        # Double-quoted rather than escapeShellArg'd, so the one expansion left
        # in is the credentials directory: `--setenv` is literal, and the `%d`
        # the unit's credential paths are written with is not expanded there.
        quote =
          v:
          ''"${
            lib.replaceStrings [ "%d" ] [ "$credentials" ] (
              lib.replaceStrings [ "\\" ''"'' "$" "`" ] [ "\\\\" ''\"'' "\\$" "\\`" ] v
            )
          }"'';
        unitEnv = config.systemd.services.afk-agent.environment;
        environment = lib.mapAttrsToList (name: value: "--setenv=${quote "${name}=${value}"}") unitEnv;
      in
      ''
        if [ "$#" -eq 0 ]; then
          echo "usage: afk-agent-run <command> [args...], e.g. afk-agent-run afk run implement --issue 7" >&2
          exit 2
        fi
        # systemd-run finds the command on its own PATH, not the unit's, so it
        # is resolved here: on the unit's PATH, with `afk` added - there and
        # not in the unit, where the model's shell would find it too.
        command="$(PATH=${lib.getBin package}/bin:${unitEnv.PATH} command -v "$1")" || {
          echo "afk-agent-run: $1: not on the unit's PATH" >&2
          exit 127
        }
        shift
        unit="afk-agent-run-$$"
        credentials="/run/credentials/$unit.service"
        exec ${config.systemd.package}/bin/systemd-run --quiet --pipe --wait --collect \
          --unit="$unit" --service-type=exec \
          ${lib.concatStringsSep " \\\n  " (properties ++ environment)} \
          -- "$command" "$@"
      '';
  };
in
{
  options.cg.service.afk-agent = {
    enable = lib.mkEnableOption ''
      the AFK agent, `afk work`.

      The kill switch: `false` plus a rebuild removes the unit and the service
      account (checks/afk-agent.nix pins that). The job store is left on disk;
      delete ${stateDir} by hand to lose the dedup history too
    '';

    repo = lib.mkOption {
      type = lib.types.strMatching "[^/]+/[^/]+";
      example = "corygyarmathy/dotfiles";
      description = ''
        The one repository commands are read from (`--repo`). The App must be
        installed on it, and it must be public: a review's `git fetch` sends no
        credentials.
      '';
    };

    appId = lib.mkOption {
      type = lib.types.str;
      example = "4882603";
      description = "The GitHub App's app ID or client ID (`--app-id`). Not a secret; the key is.";
    };

    workers = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Transitions executing at once (`--workers`).";
    };

    poll = lib.mkOption {
      type = duration;
      description = "How long the pool waits when nothing is due (`--poll`).";
    };

    lease = lib.mkOption {
      type = duration;
      description = ''
        How long a worker's lease on a job is held, and the longest an effect
        may run (`--lease`). Should be longer than a transition - an implement
        run is up to two model runs of `modelTimeout` each - than the implement
        gate and than a push: a lease that lapses mid-transition lets another
        worker take the job, and the first worker's work is thrown away.
      '';
    };

    retry = lib.mkOption {
      type = lib.types.nullOr duration;
      description = ''
        When a failed job re-enters (`--retry`). `null`, with `maxAttempts`
        null, parks a job on its first failure - which notifies.
      '';
    };

    maxAttempts = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      description = "Attempts before a failed job parks and notifies (`--max-attempts`).";
    };

    tokenWait = lib.mkOption {
      type = duration;
      description = "How long a worker waits for a resource token (`--token-wait`). Must be shorter than `lease`.";
    };

    tokens = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      example = {
        heavy-build = 1;
      };
      description = ''
        Resource token capacities (`--token`): named permits for a host
        constraint. `implement-run` and `implement-gate` hold `heavy-build`,
        and `afk work` refuses to start when a transition asks for a token
        with no capacity.
      '';
    };

    budget = {
      age = lib.mkOption {
        type = duration;
        description = "How long a usage observation is reused (`--budget-age`); a floor on how often the endpoint is asked.";
      };

      threshold = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 1 100);
        description = ''
          Percentage of any usage window that stops new jobs (`--budget-at`).
          `null` stops work only on a window that is actually rate-limited.
        '';
      };
    };

    notifyTopic = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      description = ''
        ntfy topic on this host's server that a parked job, a spent budget and
        a tier that stays exhausted are published to. A topic of its own,
        rather than the alerting stack's, so either can be muted on the phone
        without muting the other.
      '';
    };

    tierNotifyAfter = lib.mkOption {
      type = lib.types.ints.positive;
      description = ''
        Exhaustions of a job's tier, in one episode, before the operator is
        told (`--tier-notify-after`). Each is a `tierWait` deferral, so this
        is roughly how many of those a job sits through before anyone hears.
      '';
    };

    tiers = lib.mkOption {
      type = lib.types.nonEmptyListOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.strMatching ".+";
              description = "Tier name. Not ordered, and not known to the code.";
            };
            models = lib.mkOption {
              type = lib.types.nonEmptyListOf (lib.types.strMatching "[^/]+/.+");
              description = "`provider/model` references, in the order they are tried.";
            };
          };
        }
      );
      description = ''
        The enrolment file: every model the agent may ever choose, by tier. A
        model absent here is never a candidate, whatever the catalogue says.
        See afk-agent's docs/agents/model-enrolment.md.
      '';
    };

    review = {
      tier = lib.mkOption {
        type = lib.types.str;
        description = "The tier a review draws its models from (`--review-tier`). Must name one of `tiers`.";
      };

      needs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        example = [ "tool_call" ];
        description = "Capabilities a review's model must have (`--review-needs`), as models.dev names them.";
      };
    };

    implement = {
      branchPrefix = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9._/-]+";
        example = "afk/";
        description = "Begins every branch the agent pushes, as `<prefix><issue>-<k>` (`--branch-prefix`).";
      };

      tier = lib.mkOption {
        type = lib.types.str;
        description = "The tier implementing draws its models from (`--implement-tier`). Must name one of `tiers`.";
      };

      needs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        example = [ "tool_call" ];
        description = "Capabilities an implementing model must have (`--implement-needs`), as models.dev names them.";
      };

      gateAttempts = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Sessions the local gate may fail before a hand-back (`--gate-attempts`).";
      };

      handOffLabel = lib.mkOption {
        type = lib.types.str;
        description = "The label the hand-off applies to the pull request: CI green and a review posted (`--hand-off-label`).";
      };

      denylist = lib.mkOption {
        type = lib.types.nonEmptyListOf (lib.types.strMatching "[^,]+");
        description = ''
          Paths no pushed commit may touch (`--denylist`), as globs: `**` spans
          directories and `*` stays in one segment. A commit touching one hands
          back rather than pushing.
        '';
      };

      ciWait = lib.mkOption {
        type = duration;
        description = "How often unfinished CI, or a review not yet posted, is read again (`--ci-wait`).";
      };

      ciCeiling = lib.mkOption {
        type = duration;
        description = "How long after a push CI may take before a hand-back (`--ci-ceiling`).";
      };

      ciFixes = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Red CI runs sent back to the session before a hand-back (`--ci-fixes`).";
      };
    };

    effectRounds = lib.mkOption {
      type = lib.types.ints.positive;
      description = ''
        Times a push, a pull request, a comment or a label is made before it
        counts as never landing (`--effect-rounds`), for both job kinds.
      '';
    };

    handBackLabel = lib.mkOption {
      type = lib.types.str;
      description = "The label a hand-back applies, on an issue or a pull request (`--hand-back-label`).";
    };

    commitIdentity = {
      name = lib.mkOption {
        type = lib.types.str;
        example = "my-app[bot]";
        description = ''
          Author and committer name of the agent's commits. The agent sets
          none of its own, and the service account has no git configuration.
        '';
      };

      email = lib.mkOption {
        type = lib.types.str;
        example = "12345+my-app[bot]@users.noreply.github.com";
        description = "Author and committer email of the agent's commits.";
      };
    };

    modelAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      description = ''
        Candidates tried before a tier is exhausted, and posts of a reply before
        it is handed back (`--model-attempts`).
      '';
    };

    tierWait = lib.mkOption {
      type = duration;
      description = "How long an exhausted tier defers a job (`--tier-wait`).";
    };

    modelTimeout = lib.mkOption {
      type = duration;
      description = ''
        The longest one model run may take (`--model-timeout`), for both job
        kinds. A run still going is killed with everything it started, and the
        job's next run tries the next candidate.
      '';
    };

    catalogueAge = lib.mkOption {
      type = duration;
      description = "How long the cached models.dev catalogue is used before it is fetched again (`--catalogue-age`).";
    };

    maxMemory = lib.mkOption {
      type = lib.types.str;
      example = "4G";
      description = ''
        `MemoryMax` for the unit. opencode and the language servers it starts
        are in this cgroup; on a host with no headroom for them, the ceiling is
        what makes a runaway run the agent's problem rather than every other
        service's.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.cg.service.ntfy.enable;
        message = "cg.service.afk-agent publishes to this host's ntfy over loopback; enable cg.service.ntfy too";
      }
      {
        assertion = lib.any (tier: tier.name == cfg.review.tier) cfg.tiers;
        message = "cg.service.afk-agent.review.tier '${cfg.review.tier}' is not one of the enrolled tiers";
      }
      {
        assertion = lib.any (tier: tier.name == cfg.implement.tier) cfg.tiers;
        message = "cg.service.afk-agent.implement.tier '${cfg.implement.tier}' is not one of the enrolled tiers";
      }
      {
        assertion = lib.elem ".github/workflows/**" cfg.implement.denylist;
        message = "cg.service.afk-agent.implement.denylist must keep .github/workflows/**: the gate runs the workspace's own ci.yml, so a session that edits it would gate itself";
      }
      {
        assertion = cfg.tokens ? heavy-build;
        message = "cg.service.afk-agent.tokens needs a heavy-build capacity: implement-run and implement-gate hold it, and afk work refuses to start without one";
      }
      {
        assertion = (cfg.retry == null) == (cfg.maxAttempts == null);
        message = "cg.service.afk-agent: set retry and maxAttempts together, or neither (a failure then parks at once)";
      }
    ];

    # The binary reads each secret once, at startup (its ADR 0005 §6), so a
    # rotation only takes effect through a restart. No `owner`: `LoadCredential`
    # is read by systemd as root before the unit drops privileges, so sops-nix's
    # root-only defaults are exactly right.
    sops.secrets = lib.genAttrs (lib.attrValues credentials) (_: {
      restartUnits = [ "afk-agent.service" ];
    });

    # A dedicated account: the process runs a model with the App's key in reach.
    users.users.afk-agent = {
      isSystemUser = true;
      group = "afk-agent";
      home = stateDir;
      description = "AFK agent";
    };
    users.groups.afk-agent = { };

    # The skills opencode runs with, from the same afk-agent revision as the
    # binary. The repository it works on carries no copy of its own, so they
    # arrive through opencode's per-user skills directory under $HOME.
    systemd.tmpfiles.rules = [
      "d ${stateDir}/.agents 0700 afk-agent afk-agent -"
      "L+ ${stateDir}/.agents/skills - - - - ${package.src}/.agents/skills"
    ];

    environment.systemPackages = [ runAsUnit ];

    systemd.services.afk-agent = {
      description = "AFK agent work pool";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # git for the checkouts and the push, sh for the gate, and nix for the
      # model's own work on this repository; the rest for opencode's tools.
      path = [
        pkgs.git
        pkgs.bashInteractive
        pkgs.coreutils
        config.nix.package
      ];

      # Paths and tuning only - no value in here is a secret, which
      # checks/afk-agent.nix asserts rather than trusts.
      environment = toEnv (
        {
          AFK_STORE = "${stateDir}/state.db";
          AFK_LEASE = cfg.lease;
          AFK_WORKERS = cfg.workers;
          AFK_POLL = cfg.poll;
          AFK_TOKEN_WAIT = cfg.tokenWait;

          AFK_BUDGET_KEY = credential "opencode-api-key";
          AFK_BUDGET_AGE = cfg.budget.age;

          AFK_NOTIFY_URL = "http://127.0.0.1:${toString config.cg.service.ntfy.port}/${cfg.notifyTopic}";
          AFK_NOTIFY_KEY = credential "ntfy-token";
          AFK_TIER_NOTIFY_AFTER = cfg.tierNotifyAfter;

          AFK_OPENCODE = lib.getExe pkgs.opencode;
          AFK_ENROLMENT = enrolment;
          AFK_REVIEW_TIER = cfg.review.tier;
          AFK_MODEL_ATTEMPTS = cfg.modelAttempts;
          AFK_TIER_WAIT = cfg.tierWait;
          AFK_MODEL_TIMEOUT = cfg.modelTimeout;
          AFK_CATALOGUE_AGE = cfg.catalogueAge;

          AFK_EFFECT_ROUNDS = cfg.effectRounds;
          AFK_HAND_BACK_LABEL = cfg.handBackLabel;

          AFK_BRANCH_PREFIX = cfg.implement.branchPrefix;
          AFK_GATE = lib.getExe gate;
          AFK_GATE_ATTEMPTS = cfg.implement.gateAttempts;
          AFK_IMPLEMENT_TIER = cfg.implement.tier;
          AFK_HAND_OFF_LABEL = cfg.implement.handOffLabel;
          AFK_DENYLIST = lib.concatStringsSep "," cfg.implement.denylist;
          AFK_CI_WAIT = cfg.implement.ciWait;
          AFK_CI_CEILING = cfg.implement.ciCeiling;
          AFK_CI_FIXES = cfg.implement.ciFixes;

          # The model's sessions commit as whatever git finds, and the agent
          # sets nothing. The environment rather than a gitconfig under HOME,
          # so it covers every git the model runs without a file to keep.
          GIT_AUTHOR_NAME = cfg.commitIdentity.name;
          GIT_AUTHOR_EMAIL = cfg.commitIdentity.email;
          GIT_COMMITTER_NAME = cfg.commitIdentity.name;
          GIT_COMMITTER_EMAIL = cfg.commitIdentity.email;

          AFK_REPO = cfg.repo;
          AFK_APP_ID = cfg.appId;
          AFK_APP_KEY = credential "app-key";

          # opencode keeps its auth, config and caches under $HOME; pinned to
          # the state directory rather than left to the passwd entry.
          HOME = stateDir;
          # opencode spawns $SHELL for every bash call a model makes, and an
          # `isSystemUser` account's passwd shell is nologin. The prototype
          # lost a live run to exactly that.
          SHELL = lib.getExe pkgs.bashInteractive;
        }
        # Unset rather than empty: the binary reads an unset parameter as
        # "not configured", and these three have a meaning when they are not.
        // lib.optionalAttrs (cfg.retry != null) { AFK_RETRY = cfg.retry; }
        // lib.optionalAttrs (cfg.maxAttempts != null) { AFK_MAX_ATTEMPTS = cfg.maxAttempts; }
        // lib.optionalAttrs (cfg.budget.threshold != null) { AFK_BUDGET_AT = cfg.budget.threshold; }
        // lib.optionalAttrs (cfg.tokens != { }) {
          AFK_TOKENS = lib.concatStringsSep "," (
            lib.mapAttrsToList (name: n: "${name}=${toString n}") cfg.tokens
          );
        }
        // lib.optionalAttrs (cfg.review.needs != [ ]) {
          AFK_REVIEW_NEEDS = lib.concatStringsSep "," cfg.review.needs;
        }
        // lib.optionalAttrs (cfg.implement.needs != [ ]) {
          AFK_IMPLEMENT_NEEDS = lib.concatStringsSep "," cfg.implement.needs;
        }
      );

      serviceConfig = sandbox // {
        Type = "simple";

        ExecStartPre = lib.getExe opencodeAuth;
        ExecStart = "${lib.getExe package} work";

        # A GitHub outage at startup is a failed start (its ADR 0005), so come
        # back and try again. A usage error is a configuration this module got
        # wrong, and restarting it only fills the journal.
        Restart = "on-failure";
        RestartSec = "1min";
        RestartPreventExitStatus = [ 2 ];

        # SIGTERM stops the pool between transitions; a worker mid-run finishes
        # first. systemd's default stop timeout is deliberately left to cut
        # that short: a killed transition costs itself and nothing else, and a
        # rebuild should not wait out a forty-minute model run.
      };
    };
  };
}
