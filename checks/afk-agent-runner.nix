# checks/afk-agent-runner.nix
#
# The AFK runner's poll -> denylist -> claim -> isolate logic (#171) and the
# implement stage that follows it (#172), tested at the level they live at.
#
# NOT A VM TEST, and not for the usual reason. checks/afk-agent.nix already
# boots this module both ways; what it cannot do is exercise the runner, which
# talks to the GitHub API and clones a repository - neither of which exists
# inside the Nix build sandbox. So `gh` is mocked and `origin` is a fixture
# repository on disk, while `git` is the real thing: the branch and the
# worktree this asserts are genuine git objects, not a recorded intention.
# checks/download-root-canary-script.nix set this shape; this is the second
# use of it, and the first outside a monitored service.
#
# The script under test is taken from the module's own evaluated ExecStart -
# never a copy - and driven through the two environment overrides it supports.
#
# What is under test here is the part of the pipeline that is irreversible from
# the outside. A wrong claim writes to a tracker a human shares, and a wrong
# eligibility decision is how a workflow edit reaches a branch that runs with
# the repository's secrets (docs/agents/afk-eligibility.md). The cases below
# are chosen for that: which tickets are picked, which are refused, that the
# claim lands before anything else is touched, and that a second ticket cannot
# start while a first is unfinished.
#
# The implement stage adds a second thing worth pinning, and it is a *bound*
# rather than a behaviour: a loop around a paid API that retries until it
# succeeds has no natural stopping point, and the only observable difference
# between "it is still trying" and "it will never stop" is the count. So the
# retry cases assert the exact number of attempts, from both ends - a ticket
# that converges on the third attempt and one that never converges have to be
# told apart by the count alone.
#
# `opencode` is mocked the way `gh` is, with one addition: its mock does real
# work in the worktree, because what the runner decides about an attempt is
# read out of git and out of the gate rather than out of anything opencode
# said. The mock's `broken` step commits a file the `nix` mock refuses to
# build, so a failing gate here is a gate that actually failed.
{
  inputs,
  pkgs,
  self,
}:
let
  # Two evaluations of the same module: the production default - no quiet-hours
  # windows, what homelab01 evaluates to - and one with the quiet-hours
  # fixture windows set (#211). Every case written before the gate existed
  # runs against the default and proves the empty list gates nothing; the
  # quiet-hours cases below run against the quiet eval's script, because a
  # gate whose list is empty has nothing to gate with and the harness must
  # not be free to reach for a value the module did not supply.
  mkEval =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit self inputs;
      };
      modules = [
        inputs.sops-nix.nixosModules.sops
        ../modules/services/afk-agent.nix
        # The runner reads two values from the modules that own them - the ntfy
        # server's port (ntfy.nix) and the push lane's topic
        # (monitoring.nix) - so both are imported here for their declarations,
        # exactly as download-root-canary-script.nix imports monitoring.nix for
        # its canary's read. Neither is enabled: only the option defaults are
        # read, which is what production evaluates to on the one host this
        # service runs on.
        ../modules/services/ntfy.nix
        ../modules/services/monitoring/monitoring.nix
        {
          cg.service.afk-agent.instances.afk-agent.enable = true;
          system.stateVersion = "24.11";
        }
      ]
      ++ extra;
    };

  eval = mkEval [ ];

  # The fixture windows: one that ends before midnight and one that spans
  # it, which are the two shapes the gate's comparison has to tell apart.
  # Deliberately disjoint - 04:00-05:00 must sit outside the overnight
  # span, or the boundary cases below could not tell which window they
  # were on the edge of.
  quietEval = mkEval [
    {
      cg.service.afk-agent.instances.afk-agent.quietHours = [
        "04:00-05:00"
        "23:30-03:30"
      ];
    }
  ];

  runnerScript = eval.config.systemd.services.afk-agent.serviceConfig.ExecStart;
  quietRunnerScript = quietEval.config.systemd.services.afk-agent.serviceConfig.ExecStart;

  # The unit's own PATH, taken from the same evaluation the script comes from
  # rather than restated here. `systemd.services.<name>.path` is already the
  # module's toolchain plus the default a NixOS unit gets (coreutils,
  # findutils, gnugrep, gnused, systemd), so this is exactly what the runner
  # will find at 04:00 on homelab01, and it cannot drift from it.
  unitPath = pkgs.lib.makeBinPath eval.config.systemd.services.afk-agent.path;

  # The instance-name gate (#275), from the failing side. An instance name
  # outside the `afk-agent(-<suffix>)?` shape must fail the evaluation rather
  # than quietly create a unit, an account and a state directory named after
  # whatever was typed - and it must do so even while the instance is
  # disabled, because the name is malformed config either way. The gate
  # lives in the module's config generation, not on the option's type: the
  # module system skips a type's check when an option has exactly one
  # definition, which would have made a type check a comment pretending to
  # be a gate. Proven with tryEval because the property under test is that
  # the evaluation *fails*; the eval differs from `eval` above only by the
  # bad name, so a failure here is attributable to it.
  badNameEval = mkEval [
    {
      cg.service.afk-agent.instances.bogus.enable = false;
    }
  ];
  badNameFails =
    !(builtins.tryEval (builtins.deepSeq badNameEval.config.users.users badNameEval.config.users.users))
    .success;
in
pkgs.runCommand "check-afk-agent-runner"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
    ];
    script = builtins.toString runnerScript;
    quietScript = builtins.toString quietRunnerScript;
    eligibilityDoc = ../docs/agents/afk-eligibility.md;
    badNameFails = pkgs.lib.boolToString badNameFails;
  }
  ''
    set -euo pipefail

    fail() { echo "FAIL: $*" >&2; exit 1; }

    if [ "$badNameFails" != true ]; then
      fail "an afk-agent instance named outside the afk-agent(-<suffix>)? shape evaluated instead of failing"
    fi

    work=$PWD/work
    mkdir -p "$work"
    export HOME=$work/home
    mkdir -p "$HOME"

    git config --global user.email "afk-agent@example.invalid"
    git config --global user.name "afk agent test"
    git config --global init.defaultBranch master
    git config --global protocol.file.allow always

    # ...and a second home, with everything above except an identity, for the
    # runs. The unit gives the runner `HOME` pointed at its StateDirectory and
    # sets no XDG variables, so in production git finds no global config and no
    # `user.email`; a harness that leaves its own identity lying around where
    # the runner can read it cannot see that. The settings that are about
    # plumbing rather than identity stay, because the fixture origin is a local
    # path and the runner has to be able to clone it.
    mkdir -p "$work/home-run"
    cat > "$work/home-run/.gitconfig" <<'GITCFG'
    [init]
      defaultBranch = master
    [protocol "file"]
      allow = always
    GITCFG

    # --- the fixture the runner clones -----------------------------------
    #
    # A real repository, so `git worktree add -b afk/<slug> <path>
    # origin/master` either produces a branch and a checked-out tree or fails
    # for a reason worth knowing about.
    #
    # It carries a `.github/workflows/ci.yml` with a checks matrix in it, which
    # is not decoration: item 7's pre-push gate reads that file with the real
    # `yq` on both sides of the diff, so the one exception the denylist has
    # (docs/agents/afk-eligibility.md) is exercised against a real document
    # rather than against a mock's idea of one. The matrix names the checks the
    # `nix` mock reports the flake exposing, so the implement gate's own
    # checks-versus-matrix comparison agrees to begin with and every case below
    # starts from a repository that is internally consistent.
    mkdir -p "$work/seed"
    (
      cd "$work/seed"
      git init -q -b master
      echo "fixture" > README.md
      mkdir -p .github/workflows
      cat > .github/workflows/ci.yml <<'YAML'
    name: ci
    on:
      pull_request: {}
    jobs:
      checks:
        strategy:
          matrix:
            check: [alpha, beta]
        steps:
          - run: echo checking
      lint:
        steps:
          - run: echo linting
    YAML
      git add -A
      git commit -qm "seed"
    )
    git clone -q --bare "$work/seed" "$work/origin.git"
    export AFK_REPO_URL="file://$work/origin.git"

    # --- the credentials item 4 hands over -------------------------------
    mkdir -p "$work/creds"
    echo "not-a-real-key"   > "$work/creds/github-app-key"
    echo "not-a-real-key"   > "$work/creds/opencode-api-key"
    echo "not-a-real-user"  > "$work/creds/opencode-username"
    echo "not-a-real-token" > "$work/creds/ntfy-token"
    export CREDENTIALS_DIRECTORY="$work/creds"

    # The runner mints its own GitHub token from an App private key (ADR 0006),
    # which needs a real key and a real API. This is the only part of the
    # credential path the check stubs; that the key is *required*, and that the
    # push refreshes before it runs, are both still asserted below.
    export AFK_GH_TOKEN="not-a-real-token"

    # --- the mocks --------------------------------------------------------
    #
    # `gh` answers `issue list` from whichever fixture the case selected and
    # records every invocation, so an assertion can be made about what the
    # runner asked the tracker to do as well as about what it did locally.
    # `issue edit` can be made to fail, which is the only way to observe that
    # the claim really does come before the worktree.
    #
    # Anything else exits 64: a runner that grew a `gh` call nobody thought
    # about should fail this test rather than quietly succeed through a
    # permissive mock.
    mkdir -p "$work/bin"

    cat > "$work/bin/gh" <<'MOCK'
    #!/bin/sh
    echo "gh $*" >> "$GH_LOG"

    # Keep the value that followed a flag, so a case can assert on it later.
    # `--body-file` is copied rather than recorded, because the runner renders
    # the body twice over the same path and the first one would not survive,
    # and the comment files are asserted on after their runs end.
    keep_arg() {
      dest=$1
      flag=$2
      shift 2
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "$flag" ]; then
          if [ "$flag" = "--body-file" ]; then cp "$2" "$dest"; else printf '%s\n' "$2" > "$dest"; fi
          return 0
        fi
        shift
      done
    }

    case "$1 $2" in
      "issue list")
        cat "$GH_ISSUES"
        ;;
      "issue edit")
        if [ -n "''${GH_EDIT_FAIL:-}" ]; then
          echo "mock gh: refusing to relabel" >&2
          exit 1
        fi
        ;;
      # Item 8's hand-back comment, recorded like every other verb and
      # failable, because the relabel that follows it must not depend on it.
      "issue comment")
        if [ -n "''${GH_COMMENT_FAIL:-}" ]; then
          echo "mock gh: refusing to comment" >&2
          exit 1
        fi
        keep_arg "$OC_STATE/stuck-body" --body-file "$@"
        ;;
      # What the dead-run hand-back reads a ticket's labels from, to keep a
      # hand-back whose teardown failed last poll from commenting twice.
      "issue view")
        if [ -n "''${GH_STUCK_ALREADY:-}" ]; then
          printf '{"labels":[{"name":"agent-stuck"}]}\n'
        else
          printf '{"labels":[{"name":"agent-working"}]}\n'
        fi
        ;;
      # The other question the dead-run hand-back asks before tearing a branch
      # down: a leftover beside an open pull request is a finished ticket's
      # orphaned worktree, not a stuck ticket's.
      #
      # Two callers reach this verb since the revision lane landed, and they
      # are told apart by `--label`: the revision frontier asks by label and
      # the guard asks by head branch. The guard's answer carries the PR's
      # labels since the revision loop's restore reads them, and
      # GH_PR_CLAIMED says the pull request is carrying the claim - the
      # shape a revision run that died mid-round leaves.
      "pr list")
        case "$*" in
          *--label*)
            cat "$GH_PRS"
            ;;
          *)
            if [ -n "''${GH_PR_OPEN:-}" ]; then
              if [ -n "''${GH_PR_CLAIMED:-}" ]; then
                printf '[{"number":999,"labels":[{"name":"agent-revising"}]}]\n'
              else
                printf '[{"number":999,"labels":[]}]\n'
              fi
            else
              printf '[]\n'
            fi
            ;;
        esac
        ;;
      # The revision poll's comment source (#196): review summaries
      # and issue comments in one document, pointed at a per-case fixture.
      # The one verb item 7 adds, and the only one that produces something a
      # person has to act on. It prints a URL because the runner logs one, and
      # it can be made to fail, which is how the case below observes that a
      # pull request that never opened does not tear the worktree down.
      #
      # The body it is handed is copied aside rather than only logged. Item 13
      # renders the body twice - once here without the review, once again at
      # the hand-off with it - over the same path, so the creation-time body
      # does not survive to be asserted on unless it is kept now.
      "pr create")
        if [ -n "''${GH_PR_FAIL:-}" ]; then
          echo "mock gh: refusing to open a pull request" >&2
          exit 1
        fi
        keep_arg "$OC_STATE/pr-create-body" --body-file "$@"
        # The branch the pull request is on. `pr view` below needs it to answer
        # about the right commit, and a run that works a second ticket leaves
        # two `afk/*` refs in the fixture origin - so guessing at "the one that
        # is there" stops working exactly when a second poll succeeds.
        keep_arg "$OC_STATE/pr-branch" --head "$@"
        echo "https://github.com/corygyarmathy/dotfiles/pull/999"
        ;;
      # Item 13's two new verbs. `pr view` is the CI watch - it answers from a
      # per-case plan, one line per poll, repeating the last line once the plan
      # runs out so that "never settles" is a one-word plan rather than
      # forty-five of them. `pr edit` is the hand-off.
      #
      # Two callers reach this verb since the revision lane landed, told
      # apart by the fields they ask for: the revision frontier wants the
      # review summaries and comments, and the watch wants the rollup. The
      # frontier's call is peeled off first and answered from
      # `$GH_PR_COMMENTS`.
      "pr view")
        case "$*" in
          *reviews*)
            cat "$GH_PR_COMMENTS"
            exit 0
            ;;
        esac
        polls=$(( $(cat "$OC_STATE/ci-polls" 2>/dev/null || echo 0) + 1 ))
        echo "$polls" > "$OC_STATE/ci-polls"
        step="$(sed -n "''${polls}p" "$CI_PLAN" 2>/dev/null)"
        [ -n "$step" ] || step="$(tail -n 1 "$CI_PLAN")"
        echo "pr view answered $step" >> "$GH_LOG"

        # The commit the answer is about, taken from the fixture origin rather
        # than made up: the runner refuses a rollup whose `headRefOid` is not
        # the commit it just pushed, and a mock that invented one could not
        # tell the difference between that working and it not.
        sha="$(git --git-dir="$CI_ORIGIN" \
          rev-parse "refs/heads/$(cat "$OC_STATE/pr-branch")")"

        case "$step" in
          # GitHub could not be asked at all, which from the runner's side has
          # to count as one poll that saw nothing rather than kill it.
          apifail) echo "mock gh: the API is unavailable" >&2; exit 1 ;;
          # A rollup on some *other* commit: the head GitHub answers with is
          # not the commit that was pushed. `moved`-versus-staleness is the
          # watch's own fact - see the header in 110-ci.sh.
          stale) sha=0000000000000000000000000000000000000000 ;;
          # The moved-head word, with a red rollup instead of green: the
          # verdict the watch hands back on is fed back to the model only
          # when it is about the commit the runner pushed.
          movedred) sha=0000000000000000000000000000000000000000 ;;
          # A head that is not a commit at all. Not a head anybody can be
          # watching, so the watch has to read it as nothing rather than
          # follow it into a value that matches nothing.
          badsha) sha=not-a-sha ;;
        esac

        case "$step" in
          none)      rollup='[]' ;;
          red | movedred) rollup='[{"__typename":"CheckRun","name":"check afk-agent-runner","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
          pending)   rollup='[{"__typename":"CheckRun","name":"nixos ci","status":"IN_PROGRESS","conclusion":null}]' ;;
          cancelled) rollup='[{"__typename":"CheckRun","name":"nixos ci","status":"COMPLETED","conclusion":"CANCELLED"}]' ;;
          # Green, and deliberately both kinds of entry GitHub reports through
          # this field: a CheckRun with a status/conclusion pair and a legacy
          # StatusContext with a single state. The runner reads one field for
          # both, so the happy path has to exercise both branches of it.
          *)         rollup='[{"__typename":"CheckRun","name":"nixos ci","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"legacy status","state":"SUCCESS"}]' ;;
        esac

        jq -n --arg sha "$sha" --argjson rollup "$rollup" \
          '{ headRefOid: $sha, statusCheckRollup: $rollup }'
        ;;
      "pr edit")
        if [ -n "''${GH_PR_EDIT_FAIL:-}" ]; then
          echo "mock gh: refusing to edit the pull request" >&2
          exit 1
        fi
        keep_arg "$OC_STATE/pr-edit-body" --body-file "$@"
        ;;
      # The stuck path's second half on a run that failed past the push: the
      # pull request gets the same story the issue does, and is left open.
      # The revision lane's claim reply and round comment, the hand-off's
      # findings comment (#202) and the hand-back reach the same verb, and
      # each is asserted on, so every body is kept: the latest one at
      # `pr-comment-body`, and every one in posting order at
      # `pr-comment-N-body`.
      "pr comment")
        # Refusals are countable: a value of N refuses the next N `pr
        # comment` calls and lets the ones after through. A case that
        # wants only the findings comment to fail says so with 1, so the
        # hand-back's own comment is genuinely delivered and asserted on
        # instead of silently sharing the refusal.
        if [ "''${GH_PR_COMMENT_FAIL:-0}" -gt "$(cat "$OC_STATE/pr-comment-refused" 2>/dev/null || echo 0)" ]; then
          echo $(( $(cat "$OC_STATE/pr-comment-refused" 2>/dev/null || echo 0) + 1 )) >"$OC_STATE/pr-comment-refused"
          echo "mock gh: refusing to comment on the pull request" >&2
          exit 1
        fi
        n=$(( $(cat "$OC_STATE/pr-comment-count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$OC_STATE/pr-comment-count"
        keep_arg "$OC_STATE/pr-comment-body" --body-file "$@"
        keep_arg "$OC_STATE/pr-comment-$n-body" --body-file "$@"
        ;;
      # The inline review comments the revision poll reads beside the
      # pull request's summaries and comments. Pointed at a per-case
      # fixture, defaulting to none.
      api*)
        if [ -n "''${GH_INLINE:-}" ]; then
          cat "$GH_INLINE"
        else
          printf '[]\n'
        fi
        ;;
      *)
        echo "mock gh: unexpected invocation: $*" >&2
        exit 64
        ;;
    esac
    MOCK

    # `opencode` answers `run` from a per-case plan - one line per attempt - and
    # each step does to the worktree what a real session would have done, since
    # every verdict the runner reaches is read back out of git and the gate
    # rather than out of anything opencode printed. `broken` commits a file the
    # `nix` mock below refuses to build; `repair` removes it.
    #
    # Arguments are recorded one per line rather than as a flat command line:
    # the message is multi-line prose, and a flat log could not be searched for
    # a flag without matching the prose as well.
    #
    # The mocks run under the same restricted PATH as the runner does, so they
    # are held to the same toolset. That is deliberate rather than awkward: a
    # mock free to reach for anything stdenv has would be a poor stand-in for a
    # binary the unit invokes.
    #
    # TWO KINDS OF `run` reach this mock since the review stage landed, and they
    # are told apart by the prompt rather than by the flags: the review prompt
    # is the only one that opens with "Review the work on this branch".
    # Detecting on the payload rather than on `--title` is deliberate - a runner
    # that stopped titling its review session would then fail the cases below
    # rather than quietly fall through to the implement path and pass.
    #
    # The review half answers from `$OC_REVIEW` and is read back through
    # `export`, not through anything it prints, because that is how the runner
    # reads it: the log is human-formatted and the transcript is the record.
    # Each plan below is one way item 1 measured this stage failing, or one way
    # it could fail silently.
    cat > "$work/bin/opencode" <<'MOCK'
    #!/bin/sh
    is_review=no
    is_revise=no
    is_rebase=no
    for a in "$@"; do
      case "$a" in
        "Review the work on this branch."*) is_review=yes ;;
        # The revision lane's opening message and its two continuation
        # messages: the gate retry and the red-CI fix. Told apart from the
        # ticket lane's by the payload, exactly as the review session is -
        # a runner that stopped addressing the model as a revision would
        # then fail the cases below rather than quietly fall through to
        # the implement path and pass.
        "Address the review comments"*) is_revise=yes ;;
        "Revision attempt"*) is_revise=yes ;;
        "The revision on this branch"*) is_revise=yes ;;
        # The rebase-conflict session (#242): detected on the payload like
        # the two above, so a runner that stopped addressing the model as
        # a conflict resolution would fail the cases below rather than
        # quietly fall through to the implement path and pass.
        "Finish the rebase"*) is_rebase=yes ;;
      esac
    done

    case "$1" in
      run)
        if [ "$is_review" = yes ]; then
          printf '%s\n' "$@" > "$OC_STATE/review-args"
          printf '%s\n' "''${OPENCODE_CONFIG_CONTENT:-}" > "$OC_STATE/review-overlay"
          # What the tracker had already been told by the time this session
          # started. It is the only way to observe item 13's ordering from
          # inside a mock: the pull request has to exist before the review
          # runs, and the hand-off has to arrive after it.
          grep -c "pr create" "$GH_LOG" > "$OC_STATE/review-saw-pr" || true
          grep -c "pr edit" "$GH_LOG" > "$OC_STATE/review-saw-edit" || true
          plan="''${OC_REVIEW:-pass}"
          printf '%s\n' "$plan" > "$OC_STATE/review-plan"
          case "$plan" in
            # Ran past its ceiling, and crashed: both must stop the ticket
            # rather than retry, since review has no budget to spend.
            timeout) exit 124 ;;
            crash)   exit 7 ;;
            # Exited cleanly having opened nothing findable afterwards, which
            # leaves the runner with no transcript to verify the review from.
            nosession) exit 0 ;;
            # A review that wrote and committed anyway. `edit: deny` and
            # `git commit*: deny` are pattern matches on a command line, not
            # capability boundaries, and this is what gets past them: the
            # commit is real, the tree it leaves is clean, and nothing before
            # the push would otherwise notice.
            commits) echo sneaky > sneaky.txt
                     git add -A
                     git commit -qm "review: an edit it was told not to make"
                     sed -n '/^--title$/{n;p;q}' "$OC_STATE/review-args" \
                       > "$OC_STATE/review-title" ;;
            *) sed -n '/^--title$/{n;p;q}' "$OC_STATE/review-args" \
                 > "$OC_STATE/review-title" ;;
          esac
          exit 0
        fi
        if [ "$is_revise" = yes ]; then
          # The revision lane's sessions: counted and recorded separately
          # from the ticket lane's, so a case that runs both flows in one
          # state directory can assert on each lane's sessions without one
          # count eating the other.
          n=$(( $(cat "$OC_STATE/revise-attempts" 2>/dev/null || echo 0) + 1 ))
          echo "$n" > "$OC_STATE/revise-attempts"
          printf '%s\n' "$@" > "$OC_STATE/revise-args-$n"
          printf '%s\n' "''${OPENCODE_CONFIG_CONTENT:-}" > "$OC_STATE/revise-overlay-$n"
          pwd > "$OC_STATE/revise-cwd"
          git rev-parse --abbrev-ref HEAD > "$OC_STATE/revise-branch" 2>/dev/null || true
          opened=yes
          case "$(sed -n "''${n}p" "$OC_PLAN")" in
            good)   echo fix > "fix-$n.txt"; git add -A; git commit -qm "afk: revise" ;;
            broken) echo x > BROKEN;    git add -A; git commit -qm "afk: broken revision" ;;
            repair) git rm -q BROKEN;               git commit -qm "afk: repair" ;;
            none)   : ;;
            dirty)  echo a > a.txt; git add -A; git commit -qm "afk: partial"; echo b > stray.txt ;;
            tidy)   git add -A; git commit -qm "afk: tidy" ;;
            lost)   echo x > BROKEN; git add -A; git commit -qm "afk: broken revision"; opened=no ;;
            error)  exit 3 ;;
            secret) mkdir -p secrets; printf 'nothing\n' > secrets/new.yaml
                    git add -A; git commit -qm "afk: revise into a denied path" ;;
            # The rewrite the revision lane's push now permits (ADR 0007 §4,
            # amended): amend the branch's own pushed commit rather than
            # stacking a fixup on it. The push must land despite being
            # non-fast-forward, because its lease still holds.
            amend)  echo amended > fix-amend.txt; git add -A
                    git commit -q --amend -m "afk: revise (amended)" ;;
            # The lease's negative case: while the round ran, somebody pushed
            # a commit of their own to the branch; the session here rewrites
            # the pre-foreign head anyway. The leased push must refuse - a
            # foreign push holds everything back - and the round hands back
            # with nothing pushed.
            foreign)
              new="$(git commit-tree "HEAD^{tree}" -p HEAD -m "afk: a foreign push while this round ran")"
              git push -q "$CI_ORIGIN" "$new:refs/heads/$(cat "$OC_STATE/pr-branch")"
              echo amended > fix-amend.txt; git add -A
              git commit -q --amend -m "afk: revise (amended over a moved head)" ;;

            *)      echo "mock opencode: no revise plan step $n" >&2; exit 64 ;;
          esac
          if [ "$opened" = yes ] && [ ! -s "$OC_STATE/revise-title" ]; then
            sed -n '/^--title$/{n;p;q}' "$OC_STATE/revise-args-1" > "$OC_STATE/revise-title"
          fi
          exit 0
        fi
        if [ "$is_rebase" = yes ]; then
          # The conflict session (#242): one run, no retry, so the plan is
          # a single step rather than one per attempt. Recorded like the
          # review's, one argument per line, with the overlay and the
          # working directory beside it - every assertion below about this
          # session is read back from here rather than from what it said.
          printf '%s\n' "$@" > "$OC_STATE/rebase-args"
          printf '%s\n' "''${OPENCODE_CONFIG_CONTENT:-}" > "$OC_STATE/rebase-overlay"
          pwd > "$OC_STATE/rebase-cwd"
          plan="$(cat "$OC_REBASE_PLAN" 2>/dev/null)"
          [ -n "$plan" ] || plan=resolve
          case "$plan" in
            # What the skill's steps add up to here: see the state, resolve
            # the hunk keeping both intents, and continue the rebase. The
            # two content lines are the same two the `advance` and
            # `touch-readme` implement steps write - one to master, one to
            # the branch - so the resolution is the honest combine and the
            # cases below can assert both survived.
            resolve) printf 'fixture\nlanded on master meanwhile\ntouched by the ticket\n' > README.md
                     git add -A
                     git -c core.editor=true rebase --continue ;;
            # An exited session that left the replay where it stopped: the
            # runner must refuse this, not push past it.
            none)   : ;;
            # The abort dressed up as a resolution: a clean tree, a finished
            # session, and a branch exactly as stale as before.
            abort)  git rebase --abort ;;
            *) echo "mock opencode: no rebase plan step $plan" >&2; exit 64 ;;
          esac
          exit 0
        fi
        n=$(( $(cat "$OC_STATE/attempts" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$OC_STATE/attempts"
        printf '%s\n' "$@" > "$OC_STATE/args-$n"
        grep -c "pr create" "$GH_LOG" > "$OC_STATE/implement-saw-pr-$n" || true
        printf '%s\n' "''${OPENCODE_CONFIG_CONTENT:-}" > "$OC_STATE/overlay-$n"
        # Where the runner put this attempt, recorded from inside it: every
        # exit past the isolation - a pull request, and every kind of
        # hand-back - tears the worktree down now, so this record is the only
        # way to assert what the stage worked in.
        pwd > "$OC_STATE/worktree-cwd"
        git rev-parse --abbrev-ref HEAD > "$OC_STATE/worktree-branch" 2>/dev/null
        [ -f README.md ] && : > "$OC_STATE/worktree-tree"
        opened=yes
        case "$(sed -n "''${n}p" "$OC_PLAN")" in
          good)   echo fix > "fix-$n.txt"; git add -A; git commit -qm "afk: implement" ;;
          broken) echo x > BROKEN;    git add -A; git commit -qm "afk: broken" ;;
          repair) git rm -q BROKEN;               git commit -qm "afk: repair" ;;
          none)   : ;;
          # The world moving underneath the ticket (#242): another account
          # lands a commit on master while this run works. The session this
          # stands in for never pushes - the tracker verbs are denied to it
          # - so this is the harness playing everybody else, not the model.
          # It commits nothing in the worktree, which is what makes it the
          # first step of a two-attempt plan rather than a whole attempt.
          advance) rm -rf "$OC_STATE/advance"
                   git clone -q "$CI_ORIGIN" "$OC_STATE/advance"
                   printf 'landed on master meanwhile\n' >> "$OC_STATE/advance/README.md"
                   git -C "$OC_STATE/advance" commit -qam "afk: land on master meanwhile"
                   git -C "$OC_STATE/advance" push -q origin master ;;
          # The branch-side half of a conflict: the ticket's own commit
          # touches the same file the advance above did.
          touch-readme) printf 'touched by the ticket\n' >> README.md
                   git add -A; git commit -qm "afk: implement" ;;
          dirty)  echo a > a.txt; git add -A; git commit -qm "afk: partial"; echo b > stray.txt ;;
          tidy)   git add -A; git commit -qm "afk: tidy" ;;
          # Committed work whose session cannot be found afterwards - the one
          # shape the runner must refuse rather than retry.
          lost)   echo x > BROKEN; git add -A; git commit -qm "afk: broken"; opened=no ;;
          # Exits before recording a session, which is what a run that failed
          # before it opened one looks like from the outside.
          error)  exit 3 ;;
          # Diffs item 7's pre-push gate has to judge. Each writes what a real
          # session would have written, because that gate reads the diff rather
          # than anything the session said - and each is engineered to pass the
          # implement gate first, since a diff that fails that never reaches
          # the push at all.
          matrix) mkdir -p checks; echo "{ }" > checks/gamma.nix
                  sed -i 's/\[alpha, beta\]/[alpha, beta, gamma]/' .github/workflows/ci.yml
                  git add -A; git commit -qm "afk: add the gamma check" ;;
          matrixdrop) sed -i 's/\[alpha, beta\]/[alpha]/' .github/workflows/ci.yml
                  git add -A; git commit -qm "afk: stop running beta" ;;
          matrixbad) mkdir -p checks; echo "{ }" > checks/Gamma.nix
                  sed -i 's/\[alpha, beta\]/[alpha, beta, Gamma]/' .github/workflows/ci.yml
                  git add -A; git commit -qm "afk: add a check" ;;
          matrixplus) mkdir -p checks; echo "{ }" > checks/gamma.nix
                  sed -i -e 's/\[alpha, beta\]/[alpha, beta, gamma]/' \
                    -e 's/echo linting/echo pwned/' .github/workflows/ci.yml
                  git add -A; git commit -qm "afk: add the gamma check" ;;
          workflow) printf 'name: other\n' > .github/workflows/other.yml
                  git add -A; git commit -qm "afk: add a workflow" ;;
          secret) mkdir -p secrets; printf 'nothing\n' > secrets/new.yaml
                  git add -A; git commit -qm "afk: add a secret" ;;
          sops)   printf 'creation_rules: []\n' > .sops.yaml
                  git add -A; git commit -qm "afk: add a recipient" ;;
          *)      echo "mock opencode: no plan step $n" >&2; exit 64 ;;
        esac
        # The title is taken from whichever attempt first opened a session, and
        # kept: a retry is addressed by id and carries no title of its own.
        if [ "$opened" = yes ] && [ ! -s "$OC_STATE/title" ]; then
          sed -n '/^--title$/{n;p;q}' "$OC_STATE/args-$n" > "$OC_STATE/title"
        fi
        ;;
      session)
        # A `session list` that fails outright, which has to reach the caller's
        # own "no session" die rather than abort the runner inside a command
        # substitution.
        if [ "$(cat "$OC_STATE/review-plan" 2>/dev/null)" = listfail ]; then
          echo "mock opencode: session list unavailable" >&2
          exit 9
        fi
        # An empty list until some attempt has actually opened one, so the
        # runner's two no-session paths - start a fresh one, or refuse - are
        # both reachable from here. The review session joins it once opened,
        # under whatever title the runner asked for. The revision lane's
        # fresh session joins it the same way; a round that continues the
        # ticket's implement session instead finds that one, under its
        # original title.
        jq -n \
          --arg it "$(cat "$OC_STATE/title" 2>/dev/null)" \
          --arg rt "$(cat "$OC_STATE/review-title" 2>/dev/null)" \
          --arg vt "$(cat "$OC_STATE/revise-title" 2>/dev/null)" \
          '[ (if $it != "" then { id: "ses_fixture", title: $it } else empty end),
             (if $rt != "" then { id: "ses_review",  title: $rt } else empty end),
             (if $vt != "" then { id: "ses_revise",  title: $vt } else empty end) ]'
        ;;
      export)
        # The review transcript, in the shape the real `opencode export`
        # produces: tool calls at .messages[].parts[] with .type == "tool", and
        # the closing report as the last assistant text part. Everything the
        # runner decides about a review is read from here. Any other session's
        # export is never read: the runner only exports the review session.
        # The revision lane exports its own session for the round report, and
        # a round that continued the implement session exports that one - the
        # report text is the same stand-in for both.
        if [ "$2" != ses_review ]; then
          if [ "$2" = ses_revise ] || [ "$2" = ses_fixture ]; then
            if [ "$(cat "$OC_STATE/revise-report" 2>/dev/null)" = empty ]; then
              printf '{"messages":[]}\n'
            else
              printf '{"messages":[{"info":{"role":"assistant"},"parts":[{"type":"text","text":"Addressed the review comment: bumped the pin.\\n\\nNot addressed: nothing."}]}]}\n'
            fi
            exit 0
          fi
          printf '{"messages":[]}\n'
          exit 0
        fi
        plan="$(cat "$OC_STATE/review-plan" 2>/dev/null || echo pass)"
        # A transcript that stopped mid-object, which is what item 1 measured
        # `opencode export` doing on a large session - and only sometimes.
        if [ "$plan" = truncated ]; then
          printf '{"info":{"cost":0.004},"messages":[{"info":{"role":"assist'
          exit 0
        fi
        # Valid JSON of the wrong shape, which `jq -e .` alone is happy with
        # and every shape query below would then abort on.
        if [ "$plan" = badshape ]; then
          printf '{"foo":1}\n'
          exit 0
        fi
        # And an export that simply fails, which must reach the transcript
        # check rather than kill the runner at its redirection.
        if [ "$plan" = exportfail ]; then
          echo "mock opencode: export unavailable" >&2
          exit 9
        fi
        skill_name=code-review
        skill_status=completed
        axes=2
        case "$plan" in
          # The skill was called and errored, which is what item 1 measured:
          # the model then wrote a review of its own and reported it as the
          # skill's.
          noskill)    skill_status=error ;;
          # Called, and completed, but not the skill this stage is about.
          wrongskill) skill_name=implement ;;
          # The two axes collapsed into the parent context - `subagents=0` in
          # item 1's terms, which failed silently rather than erroring.
          oneaxis)    axes=1 ;;
          noaxes)     axes=0 ;;
        esac
        # What the two sub-agents were sent to do, which is what separates a
        # two-axis review from a session that simply fanned out twice. The
        # labels are the ones every measured run actually produced.
        axis_one="Standards axis review"
        axis_two="Spec axis review"
        if [ "$plan" = wrongaxes ]; then
          axis_one="Explore the repository layout"
          axis_two="Summarise the commit history"
        fi
        # Built with printf rather than written as literals spanning lines, for
        # the reason the module's own retry messages are: a continuation line
        # would have to start in column 0 to keep this file's indentation out
        # of the text, and a column-0 line inside a Nix indented string
        # collapses the dedent for the whole harness.
        # The closing report, which since the stage went advisory (plan item 6)
        # is the entire thing the runner takes from a review. There is no
        # verdict in any of these and no runner branch reads for one: the two
        # that matter are a report with something in it and a report with
        # nothing in it.
        case "$plan" in
          # A review that found something serious. It reports it and says so
          # plainly, and the ticket carries on regardless - which is the whole
          # of what "advisory" means and is asserted below.
          critical) text="$(printf '## Spec\n\nThe diff never implements acceptance criterion 3.\n\nSummary: Standards - nothing. Spec - the diff does not do what the ticket asked.')" ;;
          # No closing report whatsoever: verifiably ran, produced nothing for
          # the pull request to carry.
          emptyreport) text="" ;;
          *) text="$(printf '## Standards\n\nOne judgement call: the check duplicates a derivation.\n\n## Spec\n\nNo findings.\n\nSummary: Standards - a duplicated derivation. Spec - nothing.')" ;;
        esac
        jq -n \
          --arg status "$skill_status" \
          --arg skill "$skill_name" \
          --argjson axes "$axes" \
          --arg a1 "$axis_one" \
          --arg a2 "$axis_two" \
          --arg text "$text" \
          '{ info: { cost: 0.004 },
             messages: [
               { info: { role: "assistant" },
                 parts: (
                   [ { type: "tool", tool: "skill",
                       state: { status: $status, input: { name: $skill } } } ]
                   + [ [$a1, $a2][0:$axes][]
                       | { type: "tool", tool: "task",
                           state: { status: "completed",
                                    input: { description: ., prompt: . } } } ]
                   + (if $text == "" then []
                      else [ { type: "text", text: $text } ] end)
                 ) }
             ] }'
        ;;
      *)
        echo "mock opencode: unexpected invocation: $*" >&2
        exit 64
        ;;
    esac
    MOCK

    # `nix` fails whenever the tree still holds the file `broken` committed,
    # which is what makes a failing gate in these cases a gate that failed on
    # the worktree's actual contents. It answers the host discovery with one
    # fixture host, so the host-build half of the gate is reachable too.
    cat > "$work/bin/nix" <<'MOCK'
    #!/bin/sh
    printf '%s\n' "nix $*" >> "$NIX_LOG"
    if [ -e BROKEN ]; then
      # The message carries an `&` and a `\` on purpose: this text is what a
      # failing gate puts in gate.log, which is what the verdict splices into
      # the exhaustion hand-back. In a ''${var/pat/repl} splice, both would be
      # special in the replacement - `&` re-expands the match, `\` escapes -
      # so the hand-back body carrying this line verbatim is the regression
      # test for the split-and-concatenate splice in 65-attempt-loop.sh.
      printf '%s\n' "mock nix: the tree still contains BROKEN & \\ (refused to build)" >&2
      exit 1
    fi
    if [ "$1" = "eval" ]; then
      case "$*" in
        *".#nixosConfigurations "*)
          [ -n "''${NIX_NO_HOSTS:-}" ] || printf 'fixturehost' ;;
        # What the flake exposes, which the seed's ci.yml matrix names exactly
        # - so the implement gate's checks-versus-matrix comparison agrees
        # until a case deliberately moves one of them. Item 7's cases move both
        # together, because a diff has to pass that gate before it can reach
        # the pre-push one.
        *".#checks.x86_64-linux "*)
          printf '%s' "''${NIX_CHECKS:-alpha beta}" | tr ' ' '\n' ;;
      esac
    fi
    exit 0
    MOCK

    # `curl` is mocked the way `gh` is, for the notification POST (item 9,
    # #176): every invocation is recorded one-per-line so a case can assert
    # on the exact request the runner would have made - URL, headers, and the
    # body's content, copied out of the `--data-binary @file` it is handed -
    # and it can be made to fail, which is how the best-effort guarantee is
    # exercised. The auth header reaches curl as `-H @file`, so the mock
    # never sees the token; the file it points at is asserted to exist and to
    # carry a Bearer line, its value never printed.
    #
    # The real curl is never reachable here: the App token mint that used it
    # is stubbed through `AFK_GH_TOKEN`, and it left the runner's
    # `runtimeInputs` for exactly this reason.
    cat > "$work/bin/curl" <<'MOCK'
    #!/bin/sh
    printf '%s\n' "curl $*" >> "$NTFY_LOG"
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--data-binary" ]; then
        printf '%s\n' "body:" >> "$NTFY_LOG"
        cat "''${a#@}" >> "$NTFY_LOG" 2>/dev/null
        printf '%s\n' "" >> "$NTFY_LOG"
      fi
      prev="$a"
    done
    if [ -n "''${NTFY_FAIL:-}" ]; then
      echo "mock curl: ntfy is unreachable" >&2
      exit 7
    fi
    MOCK

    # `yq` is deliberately NOT mocked: it is the real yq-go from the unit's own
    # path, reading the real ci.yml in the fixture repository. Item 7's gate
    # decides whether a ci.yml diff is additions-only to one list by comparing
    # what yq makes of both sides, and a mock standing in for it would be this
    # harness agreeing with itself about a question the whole exception turns
    # on (docs/agents/afk-eligibility.md).

    chmod +x "$work/bin"/*

    # --- the PATH the runner sees -----------------------------------------
    #
    # The unit's own, not this build environment's: `$work/bin` for the mocks
    # to shadow the three binaries that cannot run here, then the module's
    # evaluated `path` verbatim.
    #
    # This is the difference between a harness that proves the runner's logic
    # and one that proves it will run at all. Inheriting stdenv's PATH hides
    # every tool the module forgot to declare, because stdenv has most of them
    # - and that is not hypothetical: the gate reached for `diff`, which is in
    # neither the module's toolchain nor a NixOS unit's default path, and would
    # have failed every attempt of every ticket while passing here.
    unit_path="$work/bin:${unitPath}"

    # --- fixtures ---------------------------------------------------------
    #
    # `blockedBy` carries every dependency edge with its state, closed ones
    # included, which is why the runner counts open blockers rather than
    # trusting `totalCount`. #301 and #302 are that distinction: one open
    # blocker versus one closed blocker, identical in `totalCount`.
    mkdir -p "$work/fixtures"

    cat > "$work/fixtures/mixed.json" <<'JSON'
    [
      { "number": 303, "title": "Later but clean", "body": "Touch modules/services only.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } },
      { "number": 300, "title": "Already claimed", "body": "Nothing denied here.",
        "assignees": [{ "login": "corygyarmathy" }], "blockedBy": { "nodes": [], "totalCount": 0 } },
      { "number": 301, "title": "Still blocked", "body": "Nothing denied here.",
        "assignees": [], "blockedBy": { "nodes": [{ "number": 299, "state": "OPEN" }], "totalCount": 1 } },
      { "number": 302, "title": "Unblocked at last", "body": "Nothing denied here.",
        "assignees": [], "blockedBy": { "nodes": [{ "number": 298, "state": "CLOSED" }], "totalCount": 1 } }
    ]
    JSON

    cat > "$work/fixtures/denied-then-clean.json" <<'JSON'
    [
      { "number": 310, "title": "Shard the CI matrix", "body": "Edit .github/workflows/ci.yml to add a job.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } },
      { "number": 311, "title": "Clean follow-up", "body": "Only modules/nixos changes.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    cat > "$work/fixtures/denied-workflows.json" <<'JSON'
    [
      { "number": 312, "title": "Shard the CI matrix", "body": "Edit .github/workflows/ci.yml to add a job.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    cat > "$work/fixtures/denied-secrets.json" <<'JSON'
    [
      { "number": 313, "title": "Rotate the tunnel token", "body": "Re-encrypt secrets/homelab01.yaml.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    cat > "$work/fixtures/denied-sops.json" <<'JSON'
    [
      { "number": 314, "title": "Add a recipient", "body": "A new age key belongs in .sops.yaml.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    cat > "$work/fixtures/denied-in-title.json" <<'JSON'
    [
      { "number": 315, "title": "Tidy .github/workflows/ci.yml", "body": "No detail given.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    cat > "$work/fixtures/denied-by-intent-only.json" <<'JSON'
    [
      { "number": 317, "title": "Add a job to the CI matrix", "body": "The build matrix in the CI workflow needs one more entry.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    cat > "$work/fixtures/none.json" <<'JSON'
    []
    JSON

    cat > "$work/fixtures/all-taken.json" <<'JSON'
    [
      { "number": 316, "title": "Taken", "body": "Nothing denied.",
        "assignees": [{ "login": "corygyarmathy" }], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    cat > "$work/fixtures/punctuation-title.json" <<'JSON'
    [
      { "number": 320, "title": "Fix: the *bar*, //again// (v2)!", "body": "Nothing denied.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    # A title with nothing slugifiable in it: the slug collapses to the bare
    # number plus a trailing dash, which the runner's own slug check refuses.
    # It is the cheapest ticket that gets claimed and then cannot even name a
    # branch, and the stuck path has to work without a worktree to tear down.
    cat > "$work/fixtures/unsafe-slug.json" <<'JSON'
    [
      { "number": 321, "title": "!!!", "body": "Nothing denied.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    cat > "$work/fixtures/second-ticket.json" <<'JSON'
    [
      { "number": 330, "title": "A different ticket", "body": "Nothing denied.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    # --- the revision lane's fixtures -------------------------------------
    #
    # The frontier the revision pick reads (`gh pr list --label`, the
    # hand-off-labelled pull requests this runner opened), and the comment
    # documents `pr view --json reviews,comments` answers with. The pull
    # request is the one the ticket lane's own run would have opened:
    # #999, from `afk/302-unblocked-at-last` - so a revise case and a
    # ticket case can share one fixture origin, and the assertions about
    # what the flow resumed are read out of git rather than out of the
    # tracker.
    cat > "$work/fixtures/revise-pr.json" <<'JSON'
    [
      { "number": 999, "title": "Unblocked at last",
        "headRefName": "afk/302-unblocked-at-last" }
    ]
    JSON

    cat > "$work/fixtures/none-prs.json" <<'JSON'
    []
    JSON

    # One review summary and one issue comment, both by the reviewer, and
    # the bare `/revise` that starts the round. The bot-authored comment
    # is the advisory findings comment the hand-off posted (#202): the
    # author filter must drop it exactly as it drops the round comments,
    # or the agent's own critique of its own work becomes an instruction
    # to itself. With no human comment acknowledged, the bare command
    # falls back to the review comments behind it as the round's input.
    cat > "$work/fixtures/revise-comments.json" <<'JSON'
    {
      "reviews": [
        { "author": { "login": "corygyarmathy" },
          "state": "CHANGES_REQUESTED",
          "submittedAt": "2026-09-10T11:00:00Z",
          "body": "The check name does not match what the check builds." }
      ],
      "comments": [
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-10T09:00:00Z",
          "body": "## The advisory review's findings\n\nOne judgement call: the check duplicates a derivation." },
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T12:00:00Z",
          "body": "Please also bump the flake lock file." },
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T13:00:00Z",
          "body": "/revise" }
      ]
    }
    JSON

    # And the inline half, which `pr view` does not carry: read from the
    # REST endpoint the frontier asks beside it.
    cat > "$work/fixtures/revise-inline.json" <<'JSON'
    [
      { "user": { "login": "corygyarmathy" },
        "created_at": "2026-09-10T12:30:00Z",
        "path": "checks/alpha.nix",
        "line": 12,
        "body": "This assertion is backwards." }
    ]
    JSON

    # The acceptance criterion that must start no session: comments, but
    # only the agent's own. Both shapes it takes now: the round comments
    # this loop posts, and the advisory findings comment the hand-off
    # posted (#202) - both by the agent's account, both dropped by the
    # author filter.
    cat > "$work/fixtures/revise-bot-only.json" <<'JSON'
    {
      "reviews": [],
      "comments": [
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-10T11:00:00Z",
          "body": "## The advisory review's findings\n\nOne judgement call: the check duplicates a derivation." },
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-10T12:00:00Z",
          "body": "AFK agent: revision round 1 of 3." }
      ]
    }
    JSON

    # The other shape that starts no session: review comments by a human,
    # but no `/revise` command anywhere - a review without the request is
    # not a trigger, however full of findings it is.
    cat > "$work/fixtures/revise-no-command.json" <<'JSON'
    {
      "reviews": [
        { "author": { "login": "corygyarmathy" },
          "state": "CHANGES_REQUESTED",
          "submittedAt": "2026-09-10T11:00:00Z",
          "body": "The check name does not match what the check builds." }
      ],
      "comments": [
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T12:00:00Z",
          "body": "Please also bump the flake lock file." }
      ]
    }
    JSON

    # The last shape that starts no session: a bare `/revise`, with nothing
    # behind it - no instruction in the comment, and no review comment the
    # fallback could feed the round.
    cat > "$work/fixtures/revise-empty.json" <<'JSON'
    {
      "reviews": [],
      "comments": [
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T12:00:00Z",
          "body": "/revise" }
      ]
    }
    JSON

    # A pull request the stuck path handed back: the hand-back comment is the
    # runner's own and carries the anchor, so the watermark moves past the
    # `/revise` the previous round was started with. Returned to the frontier,
    # that stale request starts nothing.
    cat > "$work/fixtures/revise-handback-stale.json" <<'JSON'
    {
      "reviews": [],
      "comments": [
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T12:00:00Z",
          "body": "/revise" },
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-10T13:00:00Z",
          "body": "AFK agent: revision handed back. The run could not push." }
      ]
    }
    JSON

    # And what re-enters it: a fresh `/revise`, written after the hand-back,
    # with an instruction of its own - a round runs from that text.
    cat > "$work/fixtures/revise-handback-fresh.json" <<'JSON'
    {
      "reviews": [],
      "comments": [
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T12:00:00Z",
          "body": "/revise" },
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-10T13:00:00Z",
          "body": "AFK agent: revision handed back. The run could not push." },
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T14:00:00Z",
          "body": "/revise assume the worktree never knew about the fixup; try again" }
      ]
    }
    JSON

    # A `/revise` that carries an instruction of its own: the text after
    # the command drives the round, and the review comments behind it do
    # not cross.
    cat > "$work/fixtures/revise-instructed.json" <<'JSON'
    {
      "reviews": [
        { "author": { "login": "corygyarmathy" },
          "state": "CHANGES_REQUESTED",
          "submittedAt": "2026-09-10T11:00:00Z",
          "body": "The check name does not match what the check builds." }
      ],
      "comments": [
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T12:00:00Z",
          "body": "Please also bump the flake lock file." },
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T13:00:00Z",
          "body": "/revise address the inline comment only" }
      ]
    }
    JSON

    # The budget: three round comments the runner left and a `/revise`
    # written after the last of them, still unacknowledged. A fourth round
    # does not run.
    cat > "$work/fixtures/revise-exhausted.json" <<'JSON'
    {
      "reviews": [],
      "comments": [
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T09:00:00Z",
          "body": "Still not right." },
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-10T10:00:00Z",
          "body": "AFK agent: revision round 1 of 3." },
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-11T10:00:00Z",
          "body": "AFK agent: revision round 2 of 3." },
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-12T10:00:00Z",
          "body": "AFK agent: revision round 3 of 3." },
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-13T10:00:00Z",
          "body": "/revise" }
      ]
    }
    JSON

    # The watermark: a human `/revise` after the last round comment starts
    # round 2, and it is bare, so the one comment written after it is the
    # round's input. A round is fed only what its watermark has not seen -
    # the author filter is what keeps the agent's own words out, and the
    # watermark is what keeps last round's work from being re-fed as an
    # instruction.
    cat > "$work/fixtures/revise-round2.json" <<'JSON'
    {
      "reviews": [],
      "comments": [
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-10T08:00:00Z",
          "body": "OLD: addressed in the round this comment predates." },
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-10T10:00:00Z",
          "body": "AFK agent: revision round 1 of 3." },
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-11T08:00:00Z",
          "body": "/revise" },
        { "author": { "login": "corygyarmathy" },
          "createdAt": "2026-09-11T09:00:00Z",
          "body": "NEW: left after the last round comment." }
      ]
    }
    JSON

    # --- the harness ------------------------------------------------------
    #
    # Each case gets its own state directory unless it deliberately inherits
    # one, because the runner's own memory between polls *is* that directory.
    state=""
    rc=0

    # `plan` is one opencode step per attempt, defaulting to a single clean
    # one so that every case written before the implement stage existed still
    # reads as "the ticket got worked". `review` is the same idea for the stage
    # after it, defaulting to a clean pass for the same reason. `rebase` is
    # the conflict session's plan (#242): a single step, defaulting to the
    # resolution, so a case that forgets to set it still exercises the path
    # the session is for.
    run() {
      local name=$1 fixture=$2 reuse=''${3:-fresh} plan=''${4:-good} review=''${5:-pass} ci=''${6:-green} rebase=''${7:-} which=''${8:-default}
      # The quiet-hours cases (the 8th argument) drive the quiet eval's
      # script, whose module carries the fixture windows; everything else
      # drives the production default, proving the empty quietHours list
      # gates nothing by every case here reaching its poll.
      local under_test="$script"
      if [ "$which" = quiet ]; then
        under_test="$quietScript"
      fi
      state="$work/state/$name"
      if [ "$reuse" = "fresh" ]; then
        rm -rf "$state"
        # A fresh origin as well as fresh state. Several cases below push, and
        # a bare repository shared between them would refuse the second push of
        # the same branch for a reason that has nothing to do with the case
        # doing the pushing.
        rm -rf "$work/origin.git"
        git clone -q --bare "$work/seed" "$work/origin.git"
      fi
      mkdir -p "$state"

      export AFK_STATE_DIR="$state"
      export GH_ISSUES="$work/fixtures/$fixture"
      export GH_LOG="$state/gh.log"
      export OC_STATE="$state"
      export OC_PLAN="$state/opencode.plan"
      export OC_REBASE_PLAN="$state/rebase.plan"
      export OC_REVIEW="$review"
      export NIX_LOG="$state/nix.log"
      export CI_PLAN="$state/ci.plan"
      export NTFY_LOG="$state/ntfy.log"
      export CI_ORIGIN="$work/origin.git"
      : > "$GH_LOG"
      : > "$NIX_LOG"
      : > "$NTFY_LOG"
      rm -f "$state"/args-* "$state"/overlay-* "$state/attempts" "$state/title" \
        "$state"/review-* "$state/ci-polls" "$state"/pr-*-body "$state/pr-branch" \
        "$state"/implement-saw-pr-* "$state"/revise-* "$state"/rebase-* \
        "$state"/pushed-readme "$state/pr-comment-count"
      # Unquoted on purpose: a plan is a whitespace-separated list of steps and
      # this is what turns it into one line each.
      # shellcheck disable=SC2086
      printf '%s\n' $plan > "$OC_PLAN"
      # The conflict session's answer, one step. An empty file reads as the
      # resolution inside the mock, the same default the review plan's
      # `pass` is.
      # shellcheck disable=SC2086
      printf '%s\n' $rebase > "$OC_REBASE_PLAN"
      # The CI watch's answers, one per poll, in the same shape and for the
      # same reason. The mock repeats the last line once this runs out, so
      # "never settles" is `pending` rather than forty-five of them.
      # shellcheck disable=SC2086
      printf '%s\n' $ci > "$CI_PLAN"

      # The revision lane's cases need the pull request to already exist on
      # the fixture origin: the flow resumes a branch the original run
      # pushed. Built here, per fresh origin, in the same shape a real run
      # leaves behind - one commit on top of master. Skipped when the reuse
      # path already pushed it, which is what the continuation case below
      # depends on.
      if [ -n "''${REVISE_SETUP:-}" ]; then
        printf '%s\n' "afk/$ticket" > "$state/pr-branch"
        if ! git -C "$work/origin.git" show-ref --verify --quiet "refs/heads/afk/$ticket"; then
          rm -rf "$work/prwork"
          git clone -q "$work/origin.git" "$work/prwork"
          (
            cd "$work/prwork"
            git checkout -q -b "afk/$ticket" origin/master
            echo fix > fix-0.txt
            git add -A
            git commit -qm "afk: implement"
            git push -q origin "HEAD:refs/heads/afk/$ticket"
          )
        fi
      fi
      # A session titled like the ticket's work: what a run that built this
      # branch left in the session store, and what the continuation case
      # needs the runner to find.
      if [ -n "''${REVISE_SESSION:-}" ]; then
        printf '%s\n' "$ticket" > "$state/title"
      fi

      set +e
      HOME="$work/home-run" PATH="$unit_path" "$under_test" \
        > "$state/out.log" 2> "$state/err.log"
      rc=$?
      set -e
    }

    # The one seam item 13's watch needs, and the reason its two bounds are
    # counted in polls rather than seconds: at zero the harness exercises the
    # real numbers - ten polls with nothing reported, forty-five without a
    # settle - at no wall-clock cost. A bound written in seconds would have had
    # to be overridden too, and then the number under test would be this file's
    # rather than production's.
    export AFK_CI_POLL_INTERVAL=0

    # The revision frontier's fixtures, defaulted to an empty queue so that
    # every case written before the lane existed falls through it quietly -
    # the revise cases below point these at their own fixtures.
    export GH_PRS="$work/fixtures/none-prs.json"
    export GH_PR_COMMENTS="$work/fixtures/none-prs.json"

    ghlog() { cat "$state/gh.log"; }
    # The notifications the runner asked for (item 9, #176), recorded by the
    # curl mock one invocation per `curl ...` line with the body appended
    # under a `body:` line.
    ntfylog() { cat "$state/ntfy.log"; }
    ntfy_posts() { grep -c '^curl ' "$state/ntfy.log" 2>/dev/null || true; }
    # How many times the runner asked GitHub about its checks.
    ci_polls() { cat "$state/ci-polls" 2>/dev/null || echo 0; }
    # What actually reached the fixture origin, as a count of commits on the
    # ticket branch: the only way to tell a fix that was pushed from one that
    # merely exists locally.
    pushed_commits() {
      git -C "$work/origin.git" rev-list --count "master..refs/heads/afk/$ticket" 2>/dev/null || echo 0
    }
    # The value opencode was given for a flag, read out of the recorded
    # arguments. One line per argument is what makes this possible, and a
    # helper is what keeps the same awk out of four places - including out of
    # the failure messages, which need the same answer they just asserted on.
    flag_value() { awk -v f="$2" '$0 == f { getline; print; exit }' "$1"; }
    claims() { grep -c "issue edit" "$state/gh.log" || true; }
    worktrees() { find "$state/worktrees" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort; }
    # Scoped to refs/heads/afk: the clone brings its own `master` along, and
    # what is under test is which branch the runner cut, not that a clone has
    # the branch it was cloned from.
    branches() { git -C "$state/checkout" for-each-ref --format='%(refname:short)' refs/heads/afk 2>/dev/null | sort; }
    # The other side of the push: what actually reached the fixture origin,
    # which is the only place a refusal can be observed as an absence.
    pushed() { git -C "$work/origin.git" for-each-ref --format='%(refname:short)' refs/heads/afk 2>/dev/null | sort; }
    attempts() { cat "$state/attempts" 2>/dev/null || echo 0; }
    revise_attempts() { cat "$state/revise-attempts" 2>/dev/null || echo 0; }
    # Every case below that reaches the implement stage runs `mixed.json`, which
    # claims #302; this is the worktree that ticket lands in.
    ticket=302-unblocked-at-last

    echo "case: the plumbing is asserted before anything is polled"
    run plumbing none.json
    [ "$rc" -eq 0 ] || fail "an empty tracker should be a quiet success, got $rc: $(cat "$state/err.log")"
    for credential in github-app-key opencode-api-key opencode-username; do
      grep -q "credential '$credential' present" "$state/out.log" \
        || fail "$credential was not asserted before the poll"
    done
    for tool in git gh opencode nix jq openssl curl; do
      grep -q "tool '$tool' present" "$state/out.log" || fail "$tool was not asserted before the poll"
    done
    [ "$(claims)" -eq 0 ] || fail "claimed something from an empty tracker"
    # And nothing to notify about: the three conditions (item 9, #176) are
    # all downstream of a claim, and an empty poll has none of them.
    [ "$(ntfy_posts)" -eq 0 ] || fail "an empty poll published a notification: $(ntfylog)"

    echo "case: a poll inside a quiet-hours window starts nothing (quiet hours, #211)"
    # The gate sits at the front of the poll, so a run inside a window
    # does nothing at all: no frontier query, no dead-run guard, no claim,
    # no session, no notification - and exits 0, because nothing being
    # scheduled is the window working, not a failure. The windows are the
    # quiet eval's fixture (04:00-05:00 and the midnight-spanning
    # 23:30-03:30), read through AFK_NOW rather than the wall clock, which
    # would be testing the time of day this check happened to run at.
    #
    # Driven against the quiet eval's script (the 8th argument): the
    # production default carries an empty quietHours list, and that nothing
    # gates there is what every other case here already proves by
    # reaching its poll.
    export AFK_NOW="04:30"
    run quiet-window none.json fresh "" "" "" "" quiet
    unset AFK_NOW
    [ "$rc" -eq 0 ] || fail "a blocked poll should be a quiet success, got $rc: $(cat "$state/err.log")"
    grep -qF "quiet hours: inside a quiet-hours window; starting nothing this poll" "$state/out.log" \
      || fail "the poll did not say why it started nothing: $(cat "$state/out.log")"
    [ ! -s "$state/gh.log" ] || fail "a poll inside a quiet-hours window asked the tracker something: $(ghlog)"
    [ "$(ntfy_posts)" -eq 0 ] || fail "a poll inside a quiet-hours window published a notification: $(ntfylog)"
    [ "$(attempts)" -eq 0 ] || fail "a session was opened inside a quiet-hours window"

    echo "case: a window's start minute is inside it, and its end minute is not"
    # Both ends of the boundary, pinned: the gate reads the window as
    # half-open, [start, end), and a comparison written the other way
    # round would either block longer than the window says or start a
    # session on the exact minute the window opens.
    export AFK_NOW="04:00"
    run quiet-at-start none.json fresh "" "" "" "" quiet
    unset AFK_NOW
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    [ ! -s "$state/gh.log" ] || fail "the window's start minute was not inside it: $(ghlog)"
    export AFK_NOW="05:00"
    run quiet-at-end mixed.json fresh good "" "" "" quiet
    unset AFK_NOW
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    grep -q "gh issue edit 302 " "$state/gh.log" \
      || fail "the window's end minute was still inside it: $(ghlog)"

    echo "case: a window that spans midnight is read the way it is written"
    # 23:30-03:30: blocked from both ends of the span, open at midday -
    # the comparison a start-before-end assumption would get wrong in
    # both directions.
    export AFK_NOW="23:45"
    run quiet-late-night none.json fresh "" "" "" "" quiet
    unset AFK_NOW
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    [ ! -s "$state/gh.log" ] || fail "the late side of the span was not inside it: $(ghlog)"
    export AFK_NOW="01:15"
    run quiet-early-hours none.json fresh "" "" "" "" quiet
    unset AFK_NOW
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    [ ! -s "$state/gh.log" ] || fail "the early side of the span was not inside it: $(ghlog)"
    export AFK_NOW="12:00"
    run quiet-midday mixed.json fresh good "" "" "" quiet
    unset AFK_NOW
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    grep -q "gh issue edit 302 " "$state/gh.log" \
      || fail "midday was read as inside the overnight window: $(ghlog)"

    echo "case: the option's windows reached the script the quiet eval runs"
    # The blocked cases above prove a window fired; this proves the one
    # the option supplied is the one the script carries, verbatim - and
    # not that the gate would block on some value the harness invented.
    grep -qF '"04:00-05:00"' "$quietScript" && grep -qF '"23:30-03:30"' "$quietScript" \
      || fail "the quiet eval's script does not carry the option's windows verbatim"

    echo "case: the query asks the tracker for the right issues in the first place"
    # The mock answers `issue list` from a fixture whatever it is asked, which
    # is what lets the filtering cases below be written - and also means the
    # query itself is only under test if something reads it back. Without this
    # the runner could stop asking for the label entirely, poll every open
    # issue in the repository, and every other case here would still pass.
    run query mixed.json
    grep -q -- "--label ready-for-agent" "$state/gh.log" || fail "the poll no longer filters by label: $(ghlog)"
    grep -q -- "--state open" "$state/gh.log" || fail "the poll no longer filters to open issues: $(ghlog)"
    # Oldest-first has to be asked of the API. `gh issue list` returns newest
    # first, so past --limit it is the oldest tickets that fall off the end -
    # and this claims the oldest survivor. A local sort cannot recover a ticket
    # that was never in the page.
    grep -q -- "--search sort:created-asc" "$state/gh.log" \
      || fail "the poll no longer asks for oldest-first, so a long backlog would hide its own front: $(ghlog)"

    echo "case: only unassigned, unblocked issues are picked up, oldest first"
    run mixed mixed.json
    [ "$rc" -eq 0 ] || fail "a clean run exited $rc: $(cat "$state/err.log")"
    [ "$(claims)" -eq 1 ] || fail "expected exactly one claim, got: $(ghlog)"
    # Both halves of the claim, in one edit (ADR 0006). Dropping the label is
    # what locks the ticket - a runner that only added `agent-working` would
    # claim the same ticket again on the next poll - and adding it is what a
    # human sees. Asserted on one line because two `gh issue edit` calls would
    # leave a window where the ticket carries neither.
    grep -q "gh issue edit 302 .* --remove-label ready-for-agent --add-label agent-working" "$state/gh.log" \
      || fail "did not claim #302 with the documented convention: $(ghlog)"
    if grep -q -- "--add-assignee" "$state/gh.log"; then
      fail "claimed by assignee, which GitHub refuses a GitHub App: $(ghlog)"
    fi
    # The three it must not have touched, each for its own reason: assigned,
    # open blocker, and simply later in the queue.
    for skipped in 300 301 303; do
      if grep -q "gh issue edit $skipped " "$state/gh.log"; then fail "claimed #$skipped"; fi
    done
    [ "$(branches)" = "afk/302-unblocked-at-last" ] || fail "branch not cut: $(branches)"
    # And with no upstream. `git worktree add -b <b> <path> origin/master`
    # tracks origin/master unless told not to, which would make item 7's push -
    # under git's default push.default of `simple` - aim at master. The
    # explicit refspec that push uses is the other half of not depending on
    # that, and neither would be noticed before a push was attempted.
    upstream="$(git -C "$state/checkout" for-each-ref \
      --format='%(upstream:short)' refs/heads/afk/302-unblocked-at-last)"
    [ -z "$upstream" ] || fail "the ticket branch tracks $upstream"

    # The PR-ready notification (item 9, #176), exactly once and at the lane's
    # informational level: a handed-over pull request is not an incident, so
    # it gets the priority warnings get - low, silent - and is told apart by
    # title and tag. The URL and topic are read out of the modules that own
    # them at eval time, so what is asserted here is what production posts.
    [ "$(ntfy_posts)" -eq 1 ] || fail "a handed-over pull request published $(ntfy_posts) notification(s): $(ntfylog)"
    grep -qF "http://127.0.0.1:2586/alerts" "$state/ntfy.log" \
      || fail "the notification did not go to the push lane's server and topic: $(ntfylog)"
    grep -qF -- "-H Priority: low" "$state/ntfy.log" || fail "PR-ready was not low priority: $(ntfylog)"
    grep -qF -- "-H Tags: white_check_mark" "$state/ntfy.log" || fail "PR-ready carried no tag: $(ntfylog)"
    grep -qF -- "-H Title: AFK agent: PR ready for review (#302)" "$state/ntfy.log" \
      || fail "PR-ready was not named after its ticket: $(ntfylog)"
    grep -qF -- "-H @" "$state/ntfy.log" || fail "the token did not travel as a header file: $(ntfylog)"
    grep -q '^Authorization: Bearer ' "$state/run/ntfy-auth" \
      || fail "the ntfy auth header file is missing or malformed"
    grep -qF "https://github.com/corygyarmathy/dotfiles/pull/999" "$state/ntfy.log" \
      || fail "the notification did not lead with the pull request: $(ntfylog)"
    grep -qF "Unblocked at last" "$state/ntfy.log" || fail "the notification did not name the ticket: $(ntfylog)"

    echo "case: the ticket is worked in a real, isolated checkout of the base branch"
    # Asked of a run that hands its ticket back at the end, because every exit
    # past the isolation - a pull request, and every kind of hand-back - takes
    # the worktree with it now. Three attempts that exit non-zero without
    # committing is the cheapest way to get there, and what the implement
    # stage worked in is asserted from the record the mock kept from inside
    # the worktree the runner put it in: the directory, the branch, and a
    # working tree with the seed's files in it.
    run isolate mixed.json fresh "error error error"
    [ "$rc" -ne 0 ] || fail "an implementation that never ran was reported as done"
    grep -qx "$state/worktrees/$ticket" "$state/worktree-cwd" \
      || fail "the implement attempt did not run in the isolated worktree: $(cat "$state/worktree-cwd" 2>/dev/null)"
    grep -qx "afk/$ticket" "$state/worktree-branch" \
      || fail "the worktree was not on its own branch: $(cat "$state/worktree-branch" 2>/dev/null)"
    [ -f "$state/worktree-tree" ] || fail "the worktree has no working tree"
    [ -z "$(worktrees)" ] || fail "a handed-back ticket left its worktree: $(worktrees)"

    # The stuck notification (item 9, #176), silent like the PR-ready one and
    # told apart by title and tag - a stuck ticket needs a human's eyes, not
    # their phone buzzing at 03:00.
    [ "$(ntfy_posts)" -eq 1 ] || fail "a handed-back ticket published $(ntfy_posts) notification(s): $(ntfylog)"
    grep -qF -- "-H Priority: low" "$state/ntfy.log" || fail "stuck was not at the silent, informational level: $(ntfylog)"
    grep -qF -- "-H Tags: octagonal_sign" "$state/ntfy.log" || fail "stuck carried no tag: $(ntfylog)"
    grep -qF -- "-H Title: AFK agent stuck on #302" "$state/ntfy.log" \
      || fail "the stuck notification was not named after its ticket: $(ntfylog)"
    grep -qF "Ticket: https://github.com/corygyarmathy/dotfiles/issues/302" "$state/ntfy.log" \
      || fail "the stuck notification did not point at the ticket: $(ntfylog)"

    echo "case: a ticket whose scope names a denied path is refused before the claim"
    run denied-then-clean denied-then-clean.json
    [ "$rc" -eq 0 ] || fail "the fall-through should succeed, got $rc: $(cat "$state/err.log")"
    if grep -q "gh issue edit 310 " "$state/gh.log"; then fail "claimed a denylisted ticket"; fi
    grep -q "skipping #310" "$state/out.log" || fail "the rejection was not reported"
    grep -q "gh issue edit 311 " "$state/gh.log" || fail "did not fall through to the clean ticket"
    [ "$(branches)" = "afk/311-clean-follow-up" ] || fail "worked the wrong ticket: $(branches)"

    echo "case: each denied path is refused on its own, in the body or in the title"
    for case_name in denied-workflows denied-secrets denied-sops denied-in-title; do
      run "$case_name" "$case_name.json"
      [ "$rc" -eq 0 ] || fail "$case_name exited $rc: $(cat "$state/err.log")"
      [ "$(claims)" -eq 0 ] || fail "$case_name claimed a denylisted ticket: $(ghlog)"
      [ -z "$(worktrees)" ] || fail "$case_name isolated a denylisted ticket"
      if [ -d "$state/checkout" ]; then fail "$case_name cloned before deciding eligibility"; fi
    done

    echo "case: the denylist reads words, not intent - and this pins the limit"
    # Not a bug being blessed: a record of how far this control reaches, so the
    # cases above cannot be read as proving more than they do. #317 plainly
    # means to edit .github/workflows/ci.yml and never writes the path, so the
    # pre-claim check does not see it - matching prose is all that is possible
    # before a line of code exists. What catches it is the pre-push gate on the
    # actual diff (item 7, #174) and triage before that. If a future change
    # makes this rejected, this expectation is what will say so, and it should
    # be flipped rather than deleted.
    run denied-by-intent-only denied-by-intent-only.json
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    [ "$(claims)" -eq 1 ] \
      || fail "the prose check has changed reach - update this case rather than removing it: $(ghlog)"

    echo "case: a tracker with nothing claimable is a quiet success"
    run all-taken all-taken.json
    [ "$rc" -eq 0 ] || fail "exited $rc on an all-assigned tracker"
    [ "$(claims)" -eq 0 ] || fail "claimed an assigned issue"
    grep -q "nothing to claim" "$state/out.log" || fail "said nothing about an idle poll"

    echo "case: the claim happens before anything local is touched"
    # The only way to observe ordering from outside: make the claim fail and
    # check that nothing local survived it. A runner that cut the branch first
    # would leave one behind.
    export GH_EDIT_FAIL=1
    run claim-first mixed.json
    unset GH_EDIT_FAIL
    [ "$rc" -ne 0 ] || fail "a failed claim was reported as success"
    [ -z "$(worktrees)" ] || fail "a worktree exists for a ticket that was never claimed"
    if [ -d "$state/checkout" ]; then fail "cloned before the claim landed"; fi

    echo "case: an issue title only ever becomes a safe branch name"
    run punctuation punctuation-title.json
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    [ "$(branches)" = "afk/320-fix-the-bar-again-v2" ] \
      || fail "unsafe or unexpected branch name: $(branches)"

    echo "case: a ticket that cannot even name a branch is still handed back"
    # The hand-back starts before the worktree does. The claim has landed by
    # the time a slug is refused, so a title with nothing slugifiable in it
    # must still end in a comment, a relabel and a clean state - and the
    # teardown must have nothing to trip over.
    run stuck-unsafe-slug unsafe-slug.json
    [ "$rc" -ne 0 ] || fail "an unnameable ticket was reported as done"
    grep -q "not a safe slug" "$state/err.log" \
      || fail "did not say why it stopped: $(cat "$state/err.log")"
    grep -q "gh issue comment 321 " "$state/gh.log" \
      || fail "no comment was left on the ticket: $(ghlog)"
    grep -q "gh issue edit 321 .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the ticket was not relabelled: $(ghlog)"
    [ -z "$(worktrees)" ] || fail "a worktree exists for a branch that was never cut"
    [ -z "$(branches)" ] || fail "a branch was cut anyway"

    echo "case: a clean first attempt is one attempt, and the gate is what says so"
    run implement-first mixed.json fresh good
    [ "$rc" -eq 0 ] || fail "a converging ticket exited $rc: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 1 ] || fail "expected one attempt, got $(attempts)"
    grep -qx -- --title "$state/args-1" || fail "the first attempt did not title its session"
    if grep -qx -- --session "$state/args-1"; then
      fail "the first attempt continued a session that cannot exist yet"
    fi
    # And it is aimed at the worktree explicitly rather than by whatever
    # directory the `cd` above it left behind. opencode resolves its project -
    # and with it which `.agents/skills/` it can see - from the launch
    # directory, so this is the flag that decides whether the session can find
    # the `implement` skill it is told to use at all. Item 1's review-stage run
    # is what that costs when it goes wrong.
    [ "$(flag_value "$state/args-1" --dir)" = "$state/worktrees/$ticket" ] \
      || fail "the implement attempt was not pinned to its worktree with --dir: $(flag_value "$state/args-1" --dir)"
    # Read out of the checkout rather than out of the worktree, here and
    # below: a run that reaches the push takes its worktree with it, and the
    # branch is what is left.
    [ "$(git -C "$state/checkout" rev-list --count "origin/master..afk/$ticket")" -eq 1 ] \
      || fail "no commit landed on the ticket branch"

    # And it is attributable. Nothing above would notice the difference between
    # a commit by the right person and a commit by whoever the machine guessed,
    # but git refuses to guess at all on a host with no domain in its hostname
    # - so without an identity the runner supplies, every attempt commits
    # nothing and the budget is spent three times on one error. Read out of the
    # script rather than written down twice, for the reason checks/afk-agent.nix
    # gives: a copy here would go on passing after the original changed.
    want_author="$(sed -n "s/^ *export GIT_AUTHOR_EMAIL='\\?\\([^']*\\)'\\?$/\\1/p" "$script")"
    [ -n "$want_author" ] || fail "the runner exports no author identity for git to commit under"
    got_author="$(git -C "$state/checkout" log -1 --format=%ae "origin/master..afk/$ticket")"
    [ "$got_author" = "$want_author" ] \
      || fail "the commit is authored by '$got_author', not '$want_author'"
    # The gate is this repository's own gate, not a cheaper proxy standing in
    # for it. Each of these is a CI job that would otherwise go red on a branch
    # this stage had already called finished.
    grep -q -- "nix fmt -- --ci" "$state/nix.log" || fail "the gate does not check formatting"
    # One `nix build` per check rather than one `nix flake check`, which is
    # what CI's own `checks` matrix does and, since 2026-09-10, what this gate
    # does too: `nix flake check` evaluates every output of this flake in one
    # process and reached 8.3 GB on homelab01, taking the run with it. Asserted
    # as "built at least one check, and did not reach for the single-process
    # form" - the exact set is the `diff` against ci.yml's matrix two lines
    # above, which is a stronger statement than a list repeated here.
    grep -q -- "nix build --no-link .#checks" "$state/nix.log" \
      || fail "the gate does not build the flake's checks"
    ! grep -q -- "nix flake check" "$state/nix.log" \
      || fail "the gate ran 'nix flake check', which is what exhausted the host on 2026-09-10"
    grep -q "nixosConfigurations.fixturehost.config.system.build.toplevel" "$state/nix.log" \
      || fail "the gate did not build the hosts it discovered: $(cat "$state/nix.log")"
    # The one gate `nix flake check` cannot see: a check added under checks/
    # without a matching entry in ci.yml's hand-written matrix passes every
    # Nix-level check and still fails CI (plan item 1, review-stage finding).
    grep -q "checks.x86_64-linux" "$state/nix.log" || fail "the gate did not read the flake's checks"
    [ "$(cat "$state/run/matrix-checks")" = "$(printf 'alpha\nbeta')" ] \
      || fail "the gate did not read ci.yml's matrix: $(cat "$state/run/matrix-checks")"
    # The credential item 11 loads has to actually reach opencode, and loading
    # it is not the same as handing it over: opencode reads providers from a
    # file under its data directory, and this account has never run `opencode
    # auth login`. Asserted on shape, and then asserted absent from the log,
    # which is the other half of item 11's "done when".
    jq -e '."opencode-go".type == "api" and (."opencode-go".key | length > 0)' \
      "$state/.local/share/opencode/auth.json" > /dev/null \
      || fail "opencode was never given the credential the unit loads for it"
    if grep -q not-a-real-key "$state/out.log" "$state/err.log"; then
      fail "the opencode credential was written to the journal"
    fi

    # Nothing the stage writes for itself may reach the diff it is gating: a
    # prompt or a gate log inside the worktree would end up in the pull request.
    [ "$(git -C "$state/checkout" diff --name-only "origin/master...afk/$ticket")" = "fix-1.txt" ] \
      || fail "the branch carries more than the work: $(git -C "$state/checkout" diff --name-only "origin/master...afk/$ticket")"

    echo "case: a failing gate is retried inside the session that failed"
    # ADR 0004 §6. A retry that cannot see what it is retrying against is close
    # to useless, and the model's own transcript is where that context lives -
    # so the retry has to continue the session rather than open a new one, and
    # the gate's verdict, which is the one thing the model could not see, has to
    # cross back.
    run implement-retry mixed.json fresh "broken repair"
    [ "$rc" -eq 0 ] || fail "the repaired ticket exited $rc: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 2 ] || fail "expected two attempts, got $(attempts)"
    grep -qx -- --session "$state/args-2" || fail "the retry opened a fresh session (ADR 0004 §6)"
    [ "$(flag_value "$state/args-2" --session)" = ses_fixture ] \
      || fail "the retry continued a session other than the one that failed"
    if grep -qx -- --title "$state/args-2"; then fail "the retry titled a second session"; fi
    grep -q "the gate failed" "$state/args-2" || fail "the retry was not told what the gate said"

    echo "case: a ticket that only converges on the third attempt still converges"
    run implement-third mixed.json fresh "broken broken repair"
    [ "$rc" -eq 0 ] || fail "exited $rc on the third attempt: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 3 ] || fail "expected three attempts, got $(attempts)"

    echo "case: a ticket that exhausts its retries is handed back - comment, relabel, teardown, no PR"
    # The implement stage's bound, and item 8's acceptance criterion in the
    # plan's own test shape: a ticket engineered to fail, as three attempts
    # that can never pass the gate. What must come out the other end is on the
    # tracker and in git, not in the exit code alone: a comment carrying the
    # gate's verdict, `agent-working` swapped for `agent-stuck` in one edit,
    # and neither a worktree, a branch, a push, nor a pull request left
    # behind. The count below is still the implement stage's bound: the
    # hand-back starts only after it.
    run stuck-exhausted mixed.json fresh "broken broken broken"
    [ "$rc" -ne 0 ] || fail "a ticket that never passed the gate was reported as done"
    [ "$(attempts)" -eq 3 ] || fail "expected exactly three attempts, got $(attempts)"
    grep -q "3 attempts" "$state/err.log" \
      || fail "did not say the budget ran out: $(cat "$state/err.log")"
    grep -q "gh issue comment 302 " "$state/gh.log" \
      || fail "no comment was left on the ticket: $(ghlog)"
    grep -q "the gate failed" "$state/stuck-body" \
      || fail "the comment does not say why the run stopped: $(cat "$state/stuck-body" 2>/dev/null)"
    # The gate's own words, through the splice. The mock nix's failure line
    # carries an `&` and a `\` (see the mock above); in a ''${var/pat/repl}
    # splice the `&` would re-expand the matched text and drop them, so this
    # fixed-string match is what pins the splice to plain concatenation.
    gate_words="mock nix: the tree still contains BROKEN & \\ (refused to build)"
    grep -qF -- "$gate_words" "$state/stuck-body" \
      || fail "the hand-back body mangled the gate's words: $(cat "$state/stuck-body" 2>/dev/null)"
    grep -q "agent-stuck" "$state/stuck-body" \
      || fail "the comment does not say what the ticket was relabelled to: $(cat "$state/stuck-body")"
    grep -q "gh issue edit 302 .* --remove-label agent-working --add-label agent-stuck" "$state/gh.log" \
      || fail "the ticket was not relabelled away from the runner's claim: $(ghlog)"
    [ -z "$(worktrees)" ] || fail "a handed-back ticket left its worktree: $(worktrees)"
    [ -z "$(branches)" ] || fail "a handed-back ticket left its branch: $(branches)"
    [ -z "$(pushed)" ] || fail "a handed-back ticket pushed something: $(pushed)"
    if grep -q "pr create" "$state/gh.log"; then fail "a pull request was opened for a stuck ticket: $(ghlog)"; fi

    echo "case: a comment that cannot be posted does not stop the hand-back"
    # The relabel is the part that outlives the run; the comment is the part
    # that explains it. A comment the tracker refused must still end in a
    # handed-back ticket and a clean state, with the reason in the journal -
    # which is why the hand-back's tracker writes are guarded rather than
    # fatal, and the exit is red either way.
    export GH_COMMENT_FAIL=1
    run stuck-comment-fails mixed.json fresh "broken broken broken"
    unset GH_COMMENT_FAIL
    [ "$rc" -ne 0 ] || fail "a failed comment was reported as success"
    grep -q "gh issue edit 302 .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the relabel did not survive a failed comment: $(ghlog)"
    [ -z "$(worktrees)" ] || fail "the teardown did not survive a failed comment"
    [ -z "$(branches)" ] || fail "the branch survived a failed comment"

    echo "case: a notification that cannot be sent does not stop the hand-back"
    # The ntfy push is best-effort by design (item 9, #176): a run that could
    # not publish must still end in exactly the hand-back it would have made,
    # with the failure in the journal.
    export NTFY_FAIL=1
    run stuck-ntfy-fails mixed.json fresh "broken broken broken"
    unset NTFY_FAIL
    [ "$rc" -ne 0 ] || fail "a failed notification was reported as success"
    grep -q "gh issue edit 302 .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the relabel did not survive a failed notification: $(ghlog)"
    [ -z "$(worktrees)" ] || fail "the teardown did not survive a failed notification"
    if grep -q "the comment could not be posted" "$state/err.log"; then
      fail "the issue comment failed without GH_COMMENT_FAIL"
    fi
    grep -q "could not be published" "$state/err.log" \
      || fail "the failed notification was not reported to the journal: $(cat "$state/err.log")"

    echo "case: exiting 0 without committing is a failure, not a success"
    # Measured in the pilot rather than imagined: runs that finished by
    # explaining what they would do. Nothing downstream can tell that apart from
    # a ticket that needed no change.
    run implement-nocommit mixed.json fresh "none good"
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 2 ] || fail "a run that committed nothing was accepted"
    grep -q "nothing was committed" "$state/out.log" || fail "did not say why the attempt failed"

    echo "case: work left in the working tree is a failure - item 7 pushes commits"
    run implement-dirty mixed.json fresh "dirty tidy"
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 2 ] || fail "uncommitted work was accepted as finished"
    grep -q "left uncommitted" "$state/out.log" || fail "did not say why the attempt failed"

    echo "case: work still in the tree when the budget runs out is rescued, not deleted"
    # The pre-push half of the same rescue. `attempt_verdict` fails an attempt
    # whose changes are still in the working tree, so a ticket can exhaust all
    # three attempts while holding real work - "none of the three passed" and
    # "there is nothing here worth keeping" are different statements, and the
    # hand-back used to conflate them and delete the branch.
    #
    # `dirty none none` rather than `dirty dirty dirty`: a second `dirty`
    # commits the stray file the first one left and then rewrites it with the
    # same bytes, so the tree comes back clean and the ticket converges on
    # attempt 2. This plan leaves the stray file untouched across all three.
    run implement-dirty-out mixed.json fresh "dirty none none"
    [ "$rc" -ne 0 ] || fail "a ticket that never passed the gate was not handed back"
    [ "$(attempts)" -eq 3 ] || fail "expected the budget to run out, got $(attempts) attempt(s)"
    grep -q "gh issue edit 302 .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the ticket was not handed back: $(ghlog)"
    [ -z "$(worktrees)" ] || fail "the worktree survived the hand-back: $(worktrees)"
    [ "$(branches)" = "afk/302-unblocked-at-last" ] \
      || fail "the branch holding the rescued work was deleted: $(branches)"
    [ -z "$(pushed)" ] || fail "rescued work was pushed without passing the gate: $(pushed)"
    grep -q "unpushed" "$state/stuck-body" \
      || fail "the hand-back comment does not say where the work was kept: $(cat "$state/stuck-body")"

    echo "case: a non-zero exit is a failure, and opens a session rather than continuing one"
    # The one place ADR 0004 §6 does not apply, because there is nothing for it
    # to apply to: an attempt that failed before opening a session left no
    # transcript, so the next attempt is the first real one and gets the
    # original prompt back rather than a message about a failure it cannot see.
    run implement-error mixed.json fresh "error good"
    [ "$rc" -eq 0 ] || fail "exited $rc: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 2 ] || fail "expected a retry after a failed run, got $(attempts) attempt(s)"
    grep -q "opencode exited 3" "$state/out.log" || fail "did not report the exit status"
    grep -q "opened no session" "$state/out.log" || fail "did not say the attempt left nothing to continue"
    grep -qx -- --title "$state/args-2" || fail "the second attempt did not open a session of its own"
    if grep -qx -- --session "$state/args-2"; then fail "continued a session that was never opened"; fi
    grep -q "Implement GitHub issue #302" "$state/args-2" || fail "the fresh attempt was not given the prompt"

    echo "case: a session that ran and cannot be found afterwards stops the ticket"
    # The other side of that branch, and the one ADR 0004 §6 does rule out. An
    # attempt that committed plainly had a session; not finding it means the
    # next attempt would re-read the ticket knowing nothing about the failure,
    # so the runner refuses rather than quietly degrading into that.
    run implement-lost mixed.json fresh "lost repair"
    [ "$rc" -ne 0 ] || fail "retried in a fresh context after losing the session"
    [ "$(attempts)" -eq 1 ] || fail "expected one attempt, got $(attempts)"
    grep -q "refusing to retry in a fresh context" "$state/err.log" \
      || fail "did not say why it stopped: $(cat "$state/err.log")"

    echo "case: a gate that discovers no hosts has not passed"
    # The gate's one branch that decides pass/fail without running anything. A
    # host list that came back empty means nothing was built, and a gate that
    # built nothing must not read as a gate that agreed.
    export NIX_NO_HOSTS=1
    run implement-nohosts mixed.json fresh "good good good"
    unset NIX_NO_HOSTS
    [ "$rc" -ne 0 ] || fail "a gate that built no hosts was treated as a pass"
    [ "$(attempts)" -eq 3 ] || fail "expected the budget to run out, got $(attempts) attempt(s)"
    grep -q "the gate failed" "$state/out.log" || fail "the empty host list was not reported as a gate failure"
    # Narrowed to *host* builds on 2026-09-10, when the gate stopped running
    # one `nix flake check` and started building each check with its own `nix
    # build`. Those run before host discovery, so a bare "nix build" search
    # now finds them and reads a working gate as a broken one. The property
    # this case exists for is unchanged and still asserted: an empty host list
    # fails the gate, and no host was built from it.
    if grep -q -- "nix build --no-link .#nixosConfigurations" "$state/nix.log"; then
      fail "something was built from an empty host list"
    fi

    echo "case: the session is opened with the verbs it must not use denied"
    # Read back from what the mock actually received, rather than grepped out of
    # the script: what matters is that the guard reached the model, not that a
    # string exists somewhere in a file. The prompt asks for the same things;
    # this is the half that does not depend on the model reading it.
    run implement-guard mixed.json fresh good
    for verb in "git push*" "gh pr *" "gh issue edit*" "gh issue comment*" "gh issue close*"; do
      jq -e --arg v "$verb" '.permission.bash[$v] == "deny"' "$state/overlay-1" > /dev/null \
        || fail "the implement session was not denied '$verb'"
    done
    # Read access: `gh pr view` is the one tracker verb allowed, so a
    # session can read the pull request it is working on by number. The
    # deny is written `gh pr *` - with the subcommand's separating space,
    # which every real invocation carries - because the rules arrive
    # sorted and the allow has to sort after the deny to win: opencode
    # evaluates the LAST matching rule. A deny written `gh pr*` (no
    # space) would sort after every gh pr-subcommand allow and starve it.
    jq -e '.permission.bash["gh pr view*"] == "allow"' "$state/overlay-1" > /dev/null \
      || fail "the implement session was not allowed to read its pull request"
    # And the order that makes it win, asserted against the order the mock
    # actually received, so a reordering that re-opens the write verbs is
    # caught here rather than in production.
    jq -e '.permission.bash | keys_unsorted as $keys
      | ($keys | index("gh pr view*")) > ($keys | index("gh pr *"))' "$state/overlay-1" > /dev/null \
      || fail "the gh pr view allow is not ordered after the gh pr deny"

    echo "case: the prompt names the skill, the ticket, and both halves of the denylist"
    # Discovery is not invocation. OpenCode exposes skills through a `skill` tool
    # the model chooses to call, and item 1 found a real session on this
    # repository that made 41 tool calls without ever calling it - so naming the
    # skill explicitly is the whole mitigation, and it is worth pinning.
    run implement-prompt mixed.json fresh good
    grep -q 'implement` skill' "$state/args-1" || fail "the prompt does not name the skill to use"
    grep -q "issue #302" "$state/args-1" || fail "the ticket number was not substituted in"
    grep -q "gh issue view 302" "$state/args-1" || fail "the prompt does not say how to read the ticket"
    for path in ".github/workflows/" "secrets/" ".sops.yaml"; do
      grep -qF -- "$path" "$state/args-1" || fail "the prompt does not carry the denied path $path"
    done
    # And the exception, without which "follow the checks/ pattern" is advice
    # that cannot pass CI - the collision item 2 settled on 2026-09-08.
    grep -q "jobs.checks.strategy.matrix.check" "$state/args-1" \
      || fail "the prompt does not carry the ci.yml matrix exception"

    echo "case: a clean implementation is reviewed in a fresh session and proceeds"
    # Item 6's second acceptance criterion. The review is a new session against
    # the same worktree - never `--session`, however many attempts the
    # implementation took - because a self-review in the context that just
    # wrote the code is the form ADR 0004 §6 rules out.
    run review-clean mixed.json fresh good pass
    [ "$rc" -eq 0 ] || fail "a clean implementation did not survive review: $(cat "$state/err.log")"
    [ -s "$state/review-args" ] || fail "no review session was opened at all"
    if grep -qx -- --session "$state/review-args"; then
      fail "the review continued the implement session instead of opening a fresh one (ADR 0004 §6)"
    fi
    grep -qx -- --title "$state/review-args" || fail "the review session is untitled, so nothing can find it again"
    [ "$(flag_value "$state/review-args" --title)" = "$ticket-review" ] \
      || fail "the review session is titled $(flag_value "$state/review-args" --title)"
    grep -q "review ran and left" "$state/out.log" || fail "the stage did not report that the review ran"
    grep -q "does not gate" "$state/out.log" || fail "the stage did not record that the review is advisory"

    echo "case: the review is aimed at its worktree explicitly, not by working directory"
    # The root cause of item 1's entire review-stage finding, and the one
    # assertion that would have caught it. opencode resolves its project - and
    # with it skill discovery - from the directory it is launched in, so a
    # session that inherits the wrong one loses the `code-review` skill and
    # gains a view of every sibling checkout. Passing `--dir` is what makes
    # that unrepeatable; a `cd` alone is what did not.
    [ "$(flag_value "$state/review-args" --dir)" = "$state/worktrees/$ticket" ] \
      || fail "the review was not pinned to its worktree with --dir: $(flag_value "$state/review-args" --dir)"

    echo "case: the review session cannot edit, commit, push or touch the issue"
    # Report-only, enforced through the permission layer rather than asked for
    # in the prompt. A review that quietly fixed what it was meant to report
    # would produce a commit nothing in this pipeline reviewed.
    jq -e '.permission.edit == "deny"' "$state/review-overlay" > /dev/null \
      || fail "the review session was allowed to edit files"
    for verb in "git push*" "git commit*" "gh pr*" "gh issue edit*" "gh issue comment*" "gh issue close*"; do
      jq -e --arg v "$verb" '.permission.bash[$v] == "deny"' "$state/review-overlay" > /dev/null \
        || fail "the review session was not denied '$verb'"
    done

    echo "case: the findings are kept for the pull request, and stay out of the diff"
    # They are worth more to the human who merges this than they are as a gate,
    # so item 7 (#174) attaches them - but a findings file written inside the
    # worktree would show up in the diff it is describing.
    [ -s "$state/run/review/findings.md" ] || fail "the review's findings were not kept anywhere"
    grep -q "duplicated derivation" "$state/run/review/findings.md" \
      || fail "the findings file is not the review's closing report: $(cat "$state/run/review/findings.md")"
    [ "$(git -C "$state/checkout" diff --name-only "origin/master...afk/$ticket")" = "fix-1.txt" ] \
      || fail "the review stage wrote into the diff: $(git -C "$state/checkout" diff --name-only "origin/master...afk/$ticket")"
    # That it left the working tree clean is enforced rather than observed: the
    # teardown at the end of a run is `git worktree remove` without --force,
    # which refuses a dirty tree - so this run reaching a pull request at all
    # is the assertion, and it holds in production rather than only here.
    [ -z "$(worktrees)" ] \
      || fail "the run did not finish, so nothing here says the review left the tree clean"

    echo "case: a critical review does not stop the ticket, and its findings travel anyway"
    # Item 6's first acceptance criterion as it now reads, and the assertion
    # that pins the advisory decision in the code rather than only in the
    # prose. The stage measured 0 catches in 9 runs on the one diff in this
    # repository with a graded answer, and the rubric that refused most often
    # refused the correct diff too (plan item 6, "The rubric experiment, run").
    # So a review with a serious finding in it reports that finding and the
    # ticket carries on to the pull request, where a person reads it.
    run review-critical mixed.json fresh good critical
    [ "$rc" -eq 0 ] || fail "a review with a serious finding stopped the ticket: $(cat "$state/err.log")"
    grep -q "acceptance criterion 3" "$state/run/review/findings.md" \
      || fail "the critical finding did not reach the findings file"
    grep -q "review ran and left" "$state/out.log" || fail "the stage did not report the review running"
    # And it is not retried. Review has no budget (ADR 0004 §6), and a finding
    # is never handed back to the model that wrote the code, so exactly one
    # review session runs and the implement count is untouched.
    [ "$(attempts)" -eq 1 ] || fail "a critical review re-ran the implement stage: $(attempts) attempt(s)"

    echo "case: a review that cannot be shown to have happened has not passed"
    # Every way item 1 saw this stage fail was silent - the skill error went to
    # the model and to nobody else, the collapsed axes left a number in an
    # export nobody read, and the substituted review looked exactly like a real
    # one. Two of those stayed fatal: the skill call may not be the skill's
    # output at all, and an empty report is nothing to post. The collapsed
    # shapes are the exception now (#269): they degrade the certification
    # rather than the run, and are pinned below with the caveats on their
    # face.
    #
    # `noskill` is the measured one: the `skill` tool was called with
    # `code-review` and errored, and the session wrote its own review instead.
    run review-noskill mixed.json fresh good noskill
    [ "$rc" -ne 0 ] || fail "a review whose skill call failed was accepted as a review"
    grep -q "never completed a" "$state/err.log" || fail "did not say the skill never ran: $(cat "$state/err.log")"

    echo "case: a review that cannot be shown to have run leaves the pull request open"
    # Item 13 changed what this failure means. It used to mean no pull request;
    # it now means one nobody has handed over, because the push came first
    # (ADR 0007 §2). What has to hold is that the pull request is left alone,
    # nothing merges it, and the hand-off label is withheld - which is the only
    # thing that says any of this from outside.
    grep -q "gh pr create" "$state/gh.log" || fail "no pull request was left for a human: $(ghlog)"
    if grep -q -- "--add-label agent-ready-for-review" "$state/gh.log"; then
      fail "a ticket whose review never ran was handed over: $(ghlog)"
    fi
    if grep -qE "pr close|pr merge" "$state/gh.log"; then
      fail "the runner closed or merged the pull request it could not finish: $(ghlog)"
    fi
    grep -q "is open and green, without the agent-ready-for-review label" "$state/err.log" \
      || fail "the refusal did not say what state it left the pull request in: $(cat "$state/err.log")"
    # And the hand-back was addressed to the pull request, not the ticket
    # (#271): the story, the stuck label and the claim loss land where the
    # work is, and the issue's thread stays silent. The shared skeleton
    # helper is defined further down with the other past-the-push cases, so
    # the routing is asserted inline here.
    grep -q "gh pr comment" "$state/gh.log" \
      || fail "no comment was left on the pull request: $(ghlog)"
    grep -q "gh pr edit .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the pull request was not relabelled: $(ghlog)"
    grep -q "gh issue edit 302 .* --remove-label agent-working" "$state/gh.log" \
      || fail "the ticket's claim was not undone: $(ghlog)"
    if grep -q "gh issue comment 302 " "$state/gh.log"; then
      fail "the hand-back was posted on the issue as well: $(ghlog)"
    fi
    if grep -q "gh pr close\\|gh pr merge" "$state/gh.log"; then
      fail "the hand-back closed or merged the pull request: $(ghlog)"
    fi

    echo "case: a skill call for something else is not a code-review"
    run review-wrongskill mixed.json fresh good wrongskill
    [ "$rc" -ne 0 ] || fail "a session that ran some other skill passed as a code review"

    echo "case: a collapsed fan-out degrades the hand-off, it does not stop the run"
    # #269: `subagents=0` in item 1's terms - standards and spec collapsing
    # into the parent context used to fail the run fail-closed. The stage is
    # advisory (ADR 0007 §3), so now the findings carry the degradation on
    # their face and the ticket hands over normally: the label asserts a
    # review ran, and the caveat keeps that sentence true whatever shape it
    # ran in.
    for collapsed in oneaxis noaxes; do
      run "review-$collapsed" mixed.json fresh good "$collapsed"
      [ "$rc" -eq 0 ] || fail "$collapsed: a degraded review stopped the hand-off: $(cat "$state/err.log")"
      grep -q "degrades rather than stops" "$state/out.log" \
        || fail "$collapsed: did not report the degradation: $(cat "$state/out.log")"
      grep -q "performed inline in the parent context" "$state/run/findings-comment.md" \
        || fail "$collapsed: the caveat is not on the findings' face: $(cat "$state/run/findings-comment.md")"
      # The collapse sentence must not leak into the caveat the pull request
      # carries: that prose describes the certification, not the failure.
      if grep -q "degraded_what" "$state/run/findings-comment.md"; then
        fail "$collapsed: an unrendered variable reached the comment: $(cat "$state/run/findings-comment.md")"
      fi
      # The caveat names the subject actually missing rather than claiming
      # both are absent: a one-axis transcript still shows a standards
      # subject, and "neither ... nor ..." would lie about that (#269).
      if [ "$collapsed" = oneaxis ]; then
        grep -q "no spec subject is identifiable" "$state/run/findings-comment.md" \
          || fail "$collapsed: the caveat did not name the missing subject: $(cat "$state/run/findings-comment.md")"
        if grep -qE "neither a standards nor a spec subject" "$state/run/findings-comment.md"; then
          fail "$collapsed: the caveat claims both subjects are absent when a standards subject is shown: $(cat "$state/run/findings-comment.md")"
        fi
      fi
      grep -q -- "--add-label agent-ready-for-review" "$state/gh.log" \
        || fail "$collapsed: the degraded run was not handed over: $(ghlog)"
      grep -q "ready for review, degraded" "$state/ntfy.log" \
        || fail "$collapsed: the degradation did not reach the notification: $(ntfylog)"
      grep -q "performed inline in the parent context" "$state/ntfy.log" \
        || fail "$collapsed: the notification did not repeat the caveat: $(ntfylog)"
    done

    echo "case: two sub-agents sent elsewhere degrade the certification, not the run"
    # The count on its own would be satisfied by a session that fanned out
    # twice for its own reasons, and the separation - not the fan-out - is
    # what the certification asserts. Same trade as the collapsed cases
    # (#269): what can be shown is reported, what cannot is not claimed.
    run review-wrongaxes mixed.json fresh good wrongaxes
    [ "$rc" -eq 0 ] || fail "two unrelated sub-agents stopped the hand-off: $(cat "$state/err.log")"
    grep -q "degrades rather than stops" "$state/out.log" \
      || fail "did not report the degradation: $(cat "$state/out.log")"
    grep -q "not shown to be independently derived" "$state/run/findings-comment.md" \
      || fail "the caveat is not on the findings' face: $(cat "$state/run/findings-comment.md")"
    grep -q -- "--add-label agent-ready-for-review" "$state/gh.log" \
      || fail "a degraded review was not handed over: $(ghlog)"
    grep -q "ready for review, degraded" "$state/ntfy.log" \
      || fail "the degradation did not reach the notification: $(ntfylog)"
    grep -q "not shown to be independently derived" "$state/ntfy.log" \
      || fail "the notification did not repeat the caveat: $(ntfylog)"

    echo "case: a review that produced no report has produced nothing, and stops the ticket"
    # The one thing about the closing report that survived dropping the verdict.
    # The findings are now the entire output of this stage, so a session that
    # verifiably ran and then said nothing has left the pull request nothing to
    # carry - which is the same silent failure the provenance checks above
    # refuse, arriving one step later.
    #
    # Tested for content rather than size, because `jq -r` on a `// ""` fallback
    # still emits a newline: the no-report case is a one-byte file that `[ -s ]`
    # would call a report.
    run review-emptyreport mixed.json fresh good emptyreport
    [ "$rc" -ne 0 ] || fail "a review with no closing report was accepted"
    grep -q "no closing report" "$state/err.log" \
      || fail "did not say the report was empty: $(cat "$state/err.log")"

    echo "case: a transcript of the wrong shape is a failure, not an abort"
    # Valid JSON is not a session. `jq -e .` is happy with any parseable
    # document, and the shape queries that follow exit 5 against one with no
    # `messages` array - which would abort the runner with none of the
    # diagnosis this stage exists to print.
    run review-badshape mixed.json fresh good badshape
    [ "$rc" -ne 0 ] || fail "a transcript of the wrong shape was accepted"
    grep -q "not a readable session" "$state/err.log" \
      || fail "did not name the transcript as unreadable: $(cat "$state/err.log")"

    echo "case: opencode failing to answer is reported, not silently fatal"
    # Two command substitutions stand between the review and its findings, and
    # under `set -euo pipefail` either would abort the runner mid-stage before
    # the message written to explain it could run. Both have to arrive at their
    # own die instead.
    run review-exportfail mixed.json fresh good exportfail
    [ "$rc" -ne 0 ] || fail "a failed export was treated as a pass"
    grep -q "not a readable session" "$state/err.log" \
      || fail "a failed export did not reach the transcript check: $(cat "$state/err.log")"

    run review-listfail mixed.json fresh good listfail
    [ "$rc" -ne 0 ] || fail "a failed session list was treated as a pass"
    grep -q "no session titled" "$state/err.log" \
      || fail "a failed session list did not reach its own die: $(cat "$state/err.log")"

    echo "case: a transcript that did not survive being exported is a failure"
    # Everything this stage verifies is read out of the export, so an export
    # that cannot be parsed is a stage that cannot verify anything - and item 1
    # recorded that a truncated one fails as a parse error only sometimes,
    # which is the worse of the two. Named rather than left to abort the runner
    # through an unguarded jq.
    run review-truncated mixed.json fresh good truncated
    [ "$rc" -ne 0 ] || fail "an unparseable review transcript was accepted"
    grep -q "not a readable session" "$state/err.log" \
      || fail "did not say the transcript was unreadable: $(cat "$state/err.log")"

    echo "case: a review that hangs or crashes stops the ticket without retrying"
    # Review has no retry budget at all (ADR 0004 §6): a retry is an implement
    # concept, because a retry needs a failure to work against and there is
    # nothing here to fix. So each of these is one review session and then a
    # stop, never a second.
    run review-timeout mixed.json fresh good timeout
    [ "$rc" -ne 0 ] || fail "a review that ran past its ceiling was treated as a pass"
    grep -q "ceiling" "$state/err.log" || fail "did not report the review timeout: $(cat "$state/err.log")"
    run review-crash mixed.json fresh good crash
    [ "$rc" -ne 0 ] || fail "a review that exited non-zero was treated as a pass"
    grep -q "exited 7" "$state/err.log" || fail "did not report the review's exit status: $(cat "$state/err.log")"

    echo "case: a review session that cannot be found afterwards stops the ticket"
    # The same shape the implement stage refuses, for the same reason: there is
    # no transcript, so there is nothing to verify the review from and no
    # findings to carry.
    run review-nosession mixed.json fresh good nosession
    [ "$rc" -ne 0 ] || fail "a review with no findable session was accepted"
    grep -q "no session titled" "$state/err.log" || fail "did not say the session was unfindable: $(cat "$state/err.log")"

    echo "case: review spends none of the implement stage's budget"
    # A ticket that only just converged still gets a full review, and whatever
    # that review finds does not send it back for a fourth attempt - the two
    # stages have separate outcomes, which is what makes ADR 0004 §6's "review
    # is always a separate pass" true of the code rather than only of the prose.
    run review-after-retries mixed.json fresh "broken broken repair" critical
    [ "$rc" -eq 0 ] || fail "a ticket that converged on its last attempt failed review: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 3 ] || fail "expected exactly three implement attempts, got $(attempts)"
    [ -s "$state/review-args" ] || fail "a ticket that converged on its last attempt was never reviewed"

    echo "case: an implementation that never converged is never reviewed"
    # Nothing to review, and a review of a gate-failing tree would be spend
    # with no decision attached to it.
    run review-unreached mixed.json fresh "broken broken broken" pass
    [ "$rc" -ne 0 ] || fail "an unconverged ticket was reported as done"
    [ ! -s "$state/review-args" ] || fail "reviewed a ticket that never passed the gate"

    echo "case: the review prompt carries the clauses each measured failure needs"
    run review-prompt mixed.json fresh good pass
    grep -q 'code-review` skill' "$state/review-args" || fail "the review prompt does not name the skill to use"
    grep -q "issue #302" "$state/review-args" || fail "the ticket number was not substituted into the review prompt"
    grep -q "origin/master" "$state/review-args" || fail "the review prompt does not pin a fixed point"
    # Abort rather than substitute, which is the behaviour item 1's run did not
    # have; and containment, which the permission layer does not buy - `bash`
    # and `cd` are unrestricted whatever `--dir` says.
    grep -q "stop immediately" "$state/review-args" || fail "the review prompt does not say to stop when the skill is missing"
    grep -q "do not \`cd\` out of it" "$state/review-args" || fail "the review prompt does not contain the session to its worktree"

    echo "case: the review prompt asks for findings and never for a verdict"
    # The measured outcome of plan item 6, pinned where it can regress. Across
    # 25 runs on the holdout pair, no model and no rubric ever refused the
    # defective diff for the defect in it, and the rubric that refused most
    # reliably refused the correct diff too. A verdict this stage cannot act on
    # is worse than none: item 7 puts these findings in front of a person, and
    # a stray "pass" in them reads to that person as a decision that was made.
    grep -q "advisory" "$state/review-args" || fail "the review prompt does not say the review is advisory"
    grep -q "do not return a verdict" "$state/review-args" || fail "the review prompt does not forbid a verdict"
    # Negated with `!` rather than `grep ... && fail`, which under this script's
    # `set -e` would abort on the passing branch: a `grep` that finds nothing
    # exits 1, and that is the outcome this line wants.
    ! grep -q "AFK-REVIEW-VERDICT" "$state/review-args" \
      || fail "the review prompt still asks for a verdict line"
    # What replaced it: the closing summary, which is what a human merging
    # actually reads, and the severity ordering that keeps taste findings in
    # their place without making them an outcome.
    grep -q "most serious finding on each axis" "$state/review-args" \
      || fail "the review prompt does not ask for a closing summary"
    grep -q "worth less" "$state/review-args" || fail "the review prompt does not rank taste findings below the rest"

    echo "case: the review prompt forbids certifying what it did not run"
    # The largest quality defect in the 25 measured runs, and the one the
    # verdict machinery was structurally blind to: 9 of 15 runs on the flawed
    # subject certified the criterion that diff breaks, and 4 of the 5 runs
    # that found the defect certified it anyway in the same report. Every one
    # of those emitted a well-formed verdict line while doing it.
    grep -q "unless you ran something that shows it" "$state/review-args" \
      || fail "the review prompt does not forbid unverified certification"
    grep -q "did not check it" "$state/review-args" \
      || fail "the review prompt does not invite the reviewer to say what it left unchecked"

    echo "case: review runs on its own model, not the implement stage's"
    # Settled by different measurements answering different questions: item 1's
    # ranking measured implementation, item 6's arms measured review. Review is
    # one pass with no retry budget, which is what makes the expensive model
    # affordable there and not here. A future edit that collapses these back
    # into one binding fails this rather than silently doubling ticket cost or
    # silently halving review quality.
    review_model="$(flag_value "$state/review-args" --model)"
    implement_model="$(flag_value "$state/args-1" --model)"
    [ -n "$review_model" ] || fail "the review session was launched with no --model"
    [ "$review_model" != "$implement_model" ] \
      || fail "review and implement ran the same model ($review_model); item 6 settled them separately"

    echo "case: a clean ticket is pushed, opened as a pull request, and leaves nothing behind"
    # Item 7's whole job, end to end. Everything before this line is reversible
    # by deleting a directory; this is the step that puts work somewhere a
    # person has to act on.
    run raise mixed.json fresh good pass
    [ "$rc" -eq 0 ] || fail "a clean ticket did not reach a pull request: $(cat "$state/err.log")"
    [ "$(pushed)" = "afk/$ticket" ] || fail "the branch did not reach origin: $(pushed)"
    # And what reached origin is the reviewed commit, not some other tip.
    [ "$(git -C "$work/origin.git" rev-parse "refs/heads/afk/$ticket")" \
      = "$(git -C "$state/checkout" rev-parse "refs/heads/afk/$ticket")" ] \
      || fail "origin carries a different commit than the branch that was gated and reviewed"
    grep -q "gh pr create" "$state/gh.log" || fail "no pull request was opened: $(ghlog)"
    grep -q -- "--base master" "$state/gh.log" || fail "the pull request does not target master: $(ghlog)"
    grep -q -- "--head afk/$ticket" "$state/gh.log" || fail "the pull request is not from the ticket branch: $(ghlog)"
    grep -q -- "--repo corygyarmathy/dotfiles" "$state/gh.log" || fail "the pull request was opened against some other repository: $(ghlog)"

    echo "case: the pull request carries the afk-agent label"
    # Plan item 3 asks the label for the same at-a-glance distinction `deps/*`
    # gives `FLAKE_UPDATE_TOKEN`, and item 3's finding gives it a second job:
    # no ruleset can stop this token merging its own pull request, so a merge
    # that did happen has to be attributable by looking.
    grep -q -- "--label afk-agent" "$state/gh.log" || fail "the pull request was not labelled: $(ghlog)"

    echo "case: auto-merge is never armed on this path"
    # ADR 0004 §9. The static half of this - no `gh pr merge` anywhere in the
    # script - is asserted further down; this is the other half, read from what
    # `gh` was actually called with, so a merge assembled at run time out of
    # something the grep would not recognise fails here.
    if grep -q "pr merge" "$state/gh.log"; then fail "the runner merged its own pull request: $(ghlog)"; fi
    if grep -q -- "--auto" "$state/gh.log"; then fail "auto-merge was armed: $(ghlog)"; fi

    echo "case: the body links back to the source issue, and stays about the change"
    # The body is rendered at creation and re-rendered at the hand-off, and
    # it carries no review-shaped prose at either call: the issue link, the
    # provenance, and what the branch says it does. The findings travel as
    # a comment (#202). The mock kept a copy of each body, because the
    # runner writes both over the same path.
    created="$state/pr-create-body"
    body="$state/run/pr-body.md"
    [ -s "$created" ] || fail "no pull request body was assembled at creation time"
    [ -s "$body" ] || fail "no pull request body was assembled"
    grep -qx "Closes #302." "$created" || fail "the body does not link back to the source issue: $(cat "$created")"
    grep -q -- "--body-file $body" "$state/gh.log" || fail "the pull request was opened with some other body: $(ghlog)"
    grep -q "No person has read this diff" "$created" || fail "the body does not say the diff is unread"
    grep -q "afk/$ticket" "$created" || fail "the body does not name the branch"
    # The creation-time body cannot carry findings, because nothing has
    # reviewed anything yet - and it says where they will arrive instead of
    # leaving a reader to wonder whether a section is missing or absent on
    # purpose.
    if grep -q "duplicated derivation" "$created"; then
      fail "the body carried the review's findings before the review had run"
    fi
    grep -q "findings arrive as a comment" "$created" \
      || fail "the body does not say where the review's findings arrive: $(cat "$created")"
    grep -q "agent-ready-for-review" "$created" \
      || fail "the body does not say what a missing hand-off means: $(cat "$created")"
    # And the re-rendered body is the same shape: what the branch says it
    # does, with the review's findings still nowhere in it.
    grep -q "What the branch says it does" "$body" \
      || fail "the final body has no claims section: $(cat "$body")"
    if grep -q "duplicated derivation" "$body"; then
      fail "the body carried the review's findings, which travel as a comment"
    fi

    echo "case: the body says what the branch does, in the implementer's own words"
    # The reviewer's prose used to be the only generated text in the body, so a
    # reader got someone's critique of a diff they had not been told the shape
    # of. The commit messages are quoted rather than summarised: a summary
    # would be another paid call producing prose nothing checks, and these are
    # already audited - the review prompt asks for any claim in them that is
    # not true of the diff.
    grep -qx "### afk: implement" "$created" \
      || fail "the branch's own commit messages did not reach the body: $(cat "$created")"
    grep -q "What the branch says it does" "$created" || fail "the body has no section for them"

    echo "case: the findings arrive as a comment, with the caveat above them"
    # #202's point: the findings sit in the comment channel the reviewer
    # is already in, so a reader who has considered one can dismiss it -
    # not resolve it, which GitHub only lets a review thread do - and the
    # body stays about the change. The caveat travels with the findings
    # rather than with the body. A reader who takes them for an approval
    # is making exactly the mistake dropping the verdict was meant to
    # prevent.
    [ -s "$state/pr-comment-body" ] || fail "no findings comment was posted: $(ghlog)"
    grep -q "duplicated derivation" "$state/pr-comment-body" \
      || fail "the review's findings did not travel to the comment: $(cat "$state/pr-comment-body")"
    grep -q "advisory" "$state/pr-comment-body" \
      || fail "the comment does not say what the review is not"
    grep -q "never once refused that diff" "$state/pr-comment-body" \
      || fail "the comment does not carry the measured caveat the findings travel with"
    # And in the right order: the caveat is what a reader meets first.
    caveat_at="$(grep -n "never once refused that diff" "$state/pr-comment-body" | cut -d: -f1)"
    findings_at="$(grep -n "duplicated derivation" "$state/pr-comment-body" | cut -d: -f1)"
    [ -n "$caveat_at" ] && [ -n "$findings_at" ] \
      || fail "the comment is missing the caveat or the findings: $(cat "$state/pr-comment-body")"
    [ "$caveat_at" -lt "$findings_at" ] \
      || fail "the review's findings come before the caveat that carries them"

    echo "case: the title of a one-commit branch is that commit's subject"
    # A squash merge takes the pull request title as its commit subject, so it
    # ends up in master's history. One commit means the implement stage already
    # wrote one in this repository's house style, and the gate passed on it.
    grep -q -- "--title afk: implement" "$state/gh.log" || fail "the pull request title is not the commit's subject: $(ghlog)"

    echo "case: the pull request is opened before any review session starts"
    # Item 13's first acceptance criterion, and the only way to observe an
    # ordering between two different mocks: each one records, as it runs, what
    # the tracker had already been told. The implement session must not see a
    # pull request; the review session must.
    [ "$(cat "$state/implement-saw-pr-1")" -eq 0 ] \
      || fail "a pull request existed before the implementation had converged"
    [ "$(cat "$state/review-saw-pr")" -ge 1 ] \
      || fail "the review ran before the pull request was opened (ADR 0007)"
    [ "$(cat "$state/review-saw-edit")" -eq 0 ] \
      || fail "the hand-off edit landed before the review had run"

    echo "case: CI is watched on the commit that was pushed, before the review"
    grep -q "pr view" "$state/gh.log" || fail "CI was never watched: $(ghlog)"
    [ "$(ci_polls)" -ge 1 ] || fail "the checks were never polled"
    grep -q "CI is green" "$state/out.log" || fail "the run did not report CI going green: $(cat "$state/out.log")"

    echo "case: the findings comment is posted before the hand-off edit lands"
    # The label says a review has run; a pull request carrying it while the
    # findings were still in flight would be saying something untrue for as
    # long as the second call took. The comment goes first; the edit that
    # re-renders the body and applies the label goes second.
    comment_at="$(grep -n "gh pr comment" "$state/gh.log" | head -1 | cut -d: -f1)"
    edit_at="$(grep -n "gh pr edit" "$state/gh.log" | head -1 | cut -d: -f1)"
    [ -n "$comment_at" ] && [ -n "$edit_at" ] \
      || fail "the hand-off never reached the tracker: $(ghlog)"
    [ "$comment_at" -lt "$edit_at" ] \
      || fail "the hand-off label was applied before the findings comment: $(ghlog)"
    [ "$(grep -c "gh pr edit" "$state/gh.log")" -eq 1 ] \
      || fail "the hand-off was not a single edit: $(ghlog)"
    grep -q -- "--add-label agent-ready-for-review" "$state/gh.log" \
      || fail "the hand-off label was never applied: $(ghlog)"
    if grep -q "duplicated derivation" "$state/pr-edit-body"; then
      fail "the hand-off edit carried the review's findings, which travel as a comment: $(cat "$state/pr-edit-body")"
    fi

    echo "case: the denylist gate and the push are one function, with nothing between"
    # ADR 0007 §6, asserted structurally rather than behaviourally, because
    # what it forbids is a future edit rather than an input. The push now
    # happens more than once per run, so "the gate runs immediately before the
    # push" has to be a property of the code that pushes rather than of the one
    # place it used to be written.
    # Column zero, like the `denied=(` read further down: a Nix indented
    # string is dedented on its way into the store, so the script on disk does
    # not carry this file's indentation.
    sed -n '/^push_branch() {$/,/^}$/p' "$script" > "$work/push-branch"
    [ -s "$work/push-branch" ] || fail "there is no push_branch function to read"
    grep -q "push_gate" "$work/push-branch" || fail "push_branch does not run the denylist gate"
    grep -q "push origin" "$work/push-branch" || fail "push_branch does not push"
    if grep -qE 'opencode|gh pr|gh issue|review' "$work/push-branch"; then
      fail "something has been put between the gate and the push: $(cat "$work/push-branch")"
    fi
    # And it is the only thing in the runner that pushes.
    [ "$(grep -c "push origin" "$script")" -eq 1 ] \
      || fail "the runner pushes from somewhere other than push_branch"

    echo "case: a finished ticket leaves nothing in flight, and the next poll runs"
    # The in-flight guard refuses to poll past a leftover worktree, so a
    # successful run that left one behind would be a pipeline that works
    # exactly once. Asserted by actually polling again rather than by looking
    # at the directory.
    [ -z "$(worktrees)" ] || fail "a finished ticket left its worktree in flight: $(worktrees)"
    # The local branch stays, which is what makes the half-worked check above
    # refuse a ticket whose pull request is still open.
    [ "$(branches)" = "afk/$ticket" ] || fail "the pushed branch was deleted locally: $(branches)"
    run raise second-ticket.json reuse
    [ "$rc" -eq 0 ] || fail "the poll after a finished ticket refused to start: $(cat "$state/err.log")"
    grep -q "gh issue edit 330 " "$state/gh.log" || fail "the next ticket was never claimed: $(ghlog)"
    grep -q "gh pr create" "$state/gh.log" || fail "the second ticket reached no pull request: $(ghlog)"

    echo "case: a multi-attempt branch is titled after its ticket instead"
    # Three commits, no one of which describes the branch. The ticket's own
    # title is the honest answer, and it is the branch this case exists to
    # distinguish - not a preference about wording.
    run raise-retried mixed.json fresh "broken broken repair" pass
    [ "$rc" -eq 0 ] || fail "a ticket that converged on its last attempt did not reach a pull request: $(cat "$state/err.log")"
    grep -q -- "--title Unblocked at last" "$state/gh.log" \
      || fail "a multi-commit branch was not titled after its ticket: $(ghlog)"

    echo "case: a base branch that moved under a clean ticket is replayed before the pull request"
    # #242. Attempt 1 is the world moving - another account lands a commit on
    # master while the run works - and attempt 2 is the ticket. What comes out
    # the other end is a branch replayed onto the new tip before anything was
    # pushed: no conflict session paid for, the gate run a second time on the
    # tree the replay produced (attempt 2's gate and the replay's gate are the
    # two `nix fmt` lines), and the pull request opened from a branch that is
    # not stale.
    run rebase-clean mixed.json fresh "advance good" pass green
    [ "$rc" -eq 0 ] || fail "a clean replay did not finish: $(cat "$state/err.log")"
    [ ! -s "$state/rebase-args" ] || fail "a clean replay started a conflict session: $(cat "$state/rebase-args")"
    [ "$(grep -c "nix fmt -- --ci" "$state/nix.log")" -eq 2 ] \
      || fail "the gate did not re-run on the replayed tree: $(grep -c "nix fmt" "$state/nix.log") gate run(s)"
    [ "$(pushed_commits)" -eq 1 ] || fail "the replayed branch did not reach origin"
    git -C "$work/origin.git" merge-base --is-ancestor master "refs/heads/afk/$ticket" \
      || fail "the pushed branch is not on the new master tip - the stale pull request #242 exists to prevent"
    grep -q "replayed onto the new master tip" "$state/out.log" \
      || fail "a replaying run did not say what it did: $(cat "$state/out.log")"

    echo "case: the base-branch comparison can see a base that did not move"
    # The other half of the same fetch: the ordinary case, where the stage
    # fetches, answers "nothing to replay", and no second gate is paid for.
    run rebase-idle mixed.json fresh good pass green
    [ "$rc" -eq 0 ] || fail "the idle case exited $rc: $(cat "$state/err.log")"
    grep -q "nothing to replay" "$state/out.log" \
      || fail "the comparison did not say the base had not moved: $(cat "$state/out.log")"
    [ "$(grep -c "nix fmt -- --ci" "$state/nix.log")" -eq 1 ] \
      || fail "a base that did not move paid for a second gate: $(grep -c "nix fmt" "$state/nix.log") gate run(s)"

    echo "case: a conflict is finished by a fresh session that calls the skill, not by a hand-back"
    # #242's whole point. Attempt 1 is the world moving; attempt 2 commits the
    # ticket's half of a conflict; the replay stops; and what happens next is
    # a new session - not the implement session continued, not the stuck path.
    # Asserted from outside: the session ran in the worktree, titled and
    # overlay-denied like every other session, the replay landed on the new
    # master tip with both intents preserved, and no hand-back was written.
    run rebase-conflict mixed.json fresh "advance touch-readme" pass green resolve
    [ "$rc" -eq 0 ] || fail "a resolvable conflict stopped the ticket: $(cat "$state/err.log")"
    [ -s "$state/rebase-args" ] || fail "no conflict session was started at all"
    [ "$(flag_value "$state/rebase-args" --title)" = "$ticket-rebase" ] \
      || fail "the conflict session is titled $(flag_value "$state/rebase-args" --title)"
    [ "$(flag_value "$state/rebase-args" --dir)" = "$state/worktrees/$ticket" ] \
      || fail "the conflict session was not pinned to its worktree with --dir: $(flag_value "$state/rebase-args" --dir)"
    [ "$(cat "$state/rebase-cwd")" = "$state/worktrees/$ticket" ] \
      || fail "the conflict session did not run in the worktree: $(cat "$state/rebase-cwd")"
    jq -e --arg v "git push*" '.permission.bash[$v] == "deny"' "$state/rebase-overlay" >/dev/null \
      || fail "the conflict session was not denied the tracker verbs"
    # The gate ran on the resolved replay: attempt 2's and the rebase's.
    [ "$(grep -c "nix fmt -- --ci" "$state/nix.log")" -eq 2 ] \
      || fail "the gate did not re-run on the resolved replay: $(grep -c "nix fmt" "$state/nix.log") gate run(s)"
    [ "$(pushed_commits)" -eq 1 ] || fail "the resolved branch did not reach origin"
    git -C "$work/origin.git" merge-base --is-ancestor master "refs/heads/afk/$ticket" \
      || fail "the resolved branch is not on the new master tip"
    # Both intents survived the resolution, which is the whole of what the
    # skill asks a resolution to be.
    git -C "$work/origin.git" show "refs/heads/afk/$ticket:README.md" > "$state/pushed-readme"
    grep -q "landed on master meanwhile" "$state/pushed-readme" \
      || fail "the resolution dropped the side that landed on master: $(cat "$state/pushed-readme")"
    grep -q "touched by the ticket" "$state/pushed-readme" \
      || fail "the resolution dropped the ticket's side: $(cat "$state/pushed-readme")"
    if grep -q "gh issue comment 302 " "$state/gh.log"; then
      fail "a resolved conflict was handed back anyway: $(ghlog)"
    fi

    echo "case: a conflict session that does not finish hands the ticket back"
    # One session, no retry: the work behind the conflict already passed the
    # gate, so the failure is going backwards, and what is owed is a human.
    # The replay is aborted before the hand-back - mid-replay the branch ref
    # still points at the gated tip while HEAD is detached, and the rescue
    # inside hand_back must not meet the conflicted tree.
    run rebase-unfinished mixed.json fresh "advance touch-readme" pass green none
    [ "$rc" -ne 0 ] || fail "an unfinished replay was reported as done"
    grep -q "still in progress" "$state/err.log" \
      || fail "did not say the replay was unfinished: $(cat "$state/err.log")"
    grep -q "gh issue comment 302 " "$state/gh.log" \
      || fail "no comment was left on the ticket: $(ghlog)"
    grep -q "gh issue edit 302 .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the ticket was not relabelled: $(ghlog)"
    [ "$(pushed_commits)" -eq 0 ] || fail "an unresolved replay was pushed: $(pushed_commits) commit(s) there"
    if grep -q "pr create" "$state/gh.log"; then
      fail "a pull request was opened for an unresolved replay: $(ghlog)"
    fi
    [ -z "$(worktrees)" ] || fail "the worktree survived the hand-back: $(worktrees)"
    [ -z "$(branches)" ] || fail "the branch survived a hand-back whose replay never finished: $(branches)"

    echo "case: a session that aborts the replay cannot push a stale branch"
    # The trap: `git rebase --abort` leaves a clean tree, an exited session
    # and a branch exactly as stale as the pull request #242 exists to
    # prevent - which a tree- and exit-code-only verdict would call success.
    # The merge base is what says the replay happened, and it is checked
    # rather than assumed.
    run rebase-aborted mixed.json fresh "advance touch-readme" pass green abort
    [ "$rc" -ne 0 ] || fail "an aborted replay was reported as done"
    grep -q "without landing" "$state/err.log" \
      || fail "did not say the replay never happened: $(cat "$state/err.log")"
    [ "$(pushed_commits)" -eq 0 ] || fail "a stale branch was pushed: $(pushed_commits) commit(s)"
    if grep -q "pr create" "$state/gh.log"; then
      fail "a pull request was opened from a stale branch: $(ghlog)"
    fi

    echo "case: a red CI run is fixed inside the implement session and pushed to the same branch"
    # Item 13's third acceptance criterion, and ADR 0004 §6 applied to a
    # failure it did not anticipate: the fix happens in the session that wrote
    # the failing commit, because a fix that cannot see what it is fixing is
    # close to useless. The plan is one clean implementation and one clean fix;
    # the CI plan is red on the first watch and green on the second.
    run ci-fix mixed.json fresh "good good" pass "red green"
    [ "$rc" -eq 0 ] || fail "a branch CI could fix did not finish: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 2 ] || fail "expected one implementation and one CI fix, got $(attempts) session(s)"
    grep -qx -- --session "$state/args-2" || fail "the CI fix opened a fresh session (ADR 0004 §6)"
    [ "$(flag_value "$state/args-2" --session)" = ses_fixture ] \
      || fail "the CI fix continued a session other than the one that wrote the commit"
    # And it was told what CI said, which is the one thing the model could not
    # see for itself.
    grep -q "CI on it is red" "$state/args-2" || fail "the fix was not told CI was red: $(cat "$state/args-2")"
    grep -q "check afk-agent-runner" "$state/args-2" \
      || fail "the fix was not told which check was not green: $(cat "$state/args-2")"
    grep -q "gh run view" "$state/args-2" || fail "the fix was not told how to read the failing log"
    # The fix round's session shape, pinned for the same reason the loop
    # above is: the revision lane and the ticket lane run the same fix
    # round, and the shape has to move together or not at all (#243). The
    # fix is aimed at the worktree explicitly, and carries the same
    # permission overlay every other build session gets.
    [ "$(flag_value "$state/args-2" --dir)" = "$state/worktrees/$ticket" ] \
      || fail "the CI fix was not pinned to its worktree with --dir: $(flag_value "$state/args-2" --dir)"
    jq -e --arg v "git push*" '.permission.bash[$v] == "deny"' "$state/overlay-2" >/dev/null \
      || fail "the CI fix session was not denied the tracker verbs"
    # The fix reached the same branch on origin, as a second commit rather than
    # as a replacement: never a force-push (ADR 0007 §4).
    [ "$(pushed_commits)" -eq 2 ] \
      || fail "the fix did not reach origin as a further commit: $(pushed_commits) commit(s) there"
    if grep -qE -- '--force|\+refs/' "$state/gh.log"; then fail "the branch was force-pushed"; fi
    # One pull request, not two: the second push goes to the branch the first
    # one opened.
    [ "$(grep -c "gh pr create" "$state/gh.log")" -eq 1 ] \
      || fail "a second pull request was opened for the fix: $(ghlog)"
    grep -q "where the local gate passed" "$state/out.log" \
      || fail "the runner did not record what CI caught that the local gate did not"

    echo "case: the CI fix round's push is gated too"
    # ADR 0007 §6. The push happens more than once now, and the second one is
    # every bit as capable of putting a workflow file on a branch that runs
    # with this repository's secrets. The fix here writes into secrets/, which
    # passes the local gate and must not reach origin.
    run ci-fix-denied mixed.json fresh "good secret" pass "red green"
    [ "$rc" -ne 0 ] || fail "a CI fix touching a denied path was pushed anyway"
    grep -qF "secrets/new.yaml" "$state/err.log" \
      || fail "the refusal did not name the path: $(cat "$state/err.log")"
    [ "$(pushed_commits)" -eq 1 ] || fail "the denied fix reached origin: $(pushed_commits) commit(s) there"

    echo "case: a CI fix that fails the local gate stops the run without a retry"
    # A deliberate asymmetry with the implement stage rather than an oversight
    # (ADR 0007 §5): the local gate has already passed on this branch, so a fix
    # that fails it is the model going backwards rather than failing to
    # converge - and unlike the implement stage there is now a pull request a
    # human can pick up, which is most of what a retry budget was buying.
    run ci-fix-broken mixed.json fresh "good broken repair" pass "red green"
    [ "$rc" -ne 0 ] || fail "a CI fix that failed the gate was pushed"
    [ "$(attempts)" -eq 2 ] || fail "the CI fix was retried: $(attempts) session(s)"
    grep -q "no retry" "$state/err.log" || fail "did not say the fix gets one session: $(cat "$state/err.log")"
    [ "$(pushed_commits)" -eq 1 ] || fail "the failed fix reached origin"

    echo "case: CI rounds do not spend the implement stage's retry budget"
    # The budgets bound different failures, which is why they are separate
    # (ADR 0007, "Alternatives considered"). This ticket uses all three
    # implement attempts to converge and then still gets its CI round - which
    # a shared budget would have refused, exactly where it was most likely to
    # be earned.
    run ci-budget mixed.json fresh "broken broken repair good" pass "red green"
    [ "$rc" -eq 0 ] || fail "a ticket that converged on its last attempt got no CI round: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 4 ] \
      || fail "expected three implement attempts and one CI fix, got $(attempts) session(s)"
    [ "$(pushed_commits)" -eq 3 ] || fail "the CI fix did not reach origin: $(pushed_commits) commit(s) there"

    echo "case: a run that exhausts its CI rounds stops, and leaves the pull request open"
    # Item 13's fourth acceptance criterion. Nothing merges, nothing is closed,
    # and the hand-off label is withheld - which is the whole of what says from
    # outside that nobody has finished with this (ADR 0007 §2 and §7).
    run ci-exhausted mixed.json fresh "good good" pass "red red"
    [ "$rc" -ne 0 ] || fail "a branch that never went green was reported as done"
    [ "$(attempts)" -eq 2 ] || fail "expected exactly one CI fix, got $(attempts) session(s)"
    grep -q "CI round(s)" "$state/err.log" || fail "did not say the rounds ran out: $(cat "$state/err.log")"
    grep -q "gh pr create" "$state/gh.log" || fail "the pull request is not open for a human to pick up: $(ghlog)"
    if grep -q -- "--add-label agent-ready-for-review" "$state/gh.log"; then
      fail "a branch that never went green was handed over: $(ghlog)"
    fi
    if grep -q "pr merge" "$state/gh.log"; then fail "the runner merged a red pull request"; fi
    # And no review was paid for on a branch that cannot merge.
    [ ! -s "$state/review-args" ] || fail "reviewed a branch whose CI never went green"

    echo "case: a check that never arrives is told apart from a slow one"
    # The hard half of watching CI, and there is no fact that separates them -
    # only a bound. A workflow that was never triggered is a configuration
    # problem rather than a problem with the diff, so it stops the run rather
    # than being fed back to a model with nothing to fix.
    run ci-absent mixed.json fresh good pass none
    [ "$rc" -ne 0 ] || fail "a pull request with no checks at all was handed over"
    [ "$(ci_polls)" -eq 10 ] || fail "expected ten polls before calling it absent, got $(ci_polls)"
    grep -q "nothing has reported" "$state/err.log" \
      || fail "did not say the checks never arrived: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 1 ] || fail "a workflow that never ran was fed back to the model"

    echo "case: a slow one is waited for, and then bounded"
    run ci-unsettled mixed.json fresh good pass pending
    [ "$rc" -ne 0 ] || fail "a run that never settled was handed over"
    [ "$(ci_polls)" -eq 45 ] || fail "expected forty-five polls before giving up, got $(ci_polls)"
    grep -q "has not settled" "$state/err.log" \
      || fail "did not say the checks never settled: $(cat "$state/err.log")"

    echo "case: a green rollup on some other commit is waited out, not accepted"
    # The trap that would otherwise bite hardest right after a fix is pushed:
    # for a window, GitHub still reports the previous commit's checks. Reading
    # the rollup beside `headRefOid` in one snapshot is what makes the verdict
    # arrive with the commit it belongs to, and a window's worth of answers
    # about the wrong commit is waited through - never accepted, never fed
    # back - before the real one arrives.
    run ci-stale mixed.json fresh good pass "stale stale stale green"
    [ "$rc" -eq 0 ] || fail "a transient stale window was not waited out: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 1 ] || fail "a stale window was fed to the model as a failure"
    if grep -q "head has moved" "$state/out.log"; then
      fail "a three-poll staleness window was treated as a moved head: $(cat "$state/out.log")"
    fi

    echo "case: a head somebody else pushed is followed, not abandoned"
    # #248. The word `stale` answers about a stranger head on every poll -
    # a whole window's worth - so the watch follows it; from then on the
    # same word is this branch's own rollup, and it is green.
    run ci-moved mixed.json fresh good pass stale
    [ "$rc" -eq 0 ] || fail "a pull request whose head was rebased was abandoned: $(cat "$state/err.log")"
    grep -q "head has moved to 0000000000000000000000000000000000000000" "$state/out.log" \
      || fail "did not say it was following the moved head: $(cat "$state/out.log")"
    [ "$(ci_polls)" -eq 11 ] \
      || fail "expected the first-check bound waited out before following, got $(ci_polls) poll(s)"
    [ "$(attempts)" -eq 1 ] \
      || fail "the moved head's green run was fed back to the model as a failure"
    grep -q -- "--add-label agent-ready-for-review" "$state/gh.log" \
      || fail "the run following a moved head never reached the hand-off: $(ghlog)"

    echo "case: a moved head whose run is red is handed back, not fixed against the old commit"
    # The half the green follow above cannot show: a red verdict is fed
    # back to the session only on the commit the local gate passed, and a
    # followed head is not that. The run ends in a hand-back before any
    # fix round is paid for or judged against the stale pushed head.
    run ci-moved-red mixed.json fresh good pass movedred
    [ "$rc" -ne 0 ] || fail "a red run on a followed head was treated as done: $(cat "$state/err.log")"
    grep -q "head has moved to 0000000000000000000000000000000000000000" "$state/out.log" \
      || fail "did not say it was following the moved head: $(cat "$state/out.log")"
    grep -q "somebody else pushed while this run was watching" "$state/err.log" \
      || fail "did not hand back on the followed head's red run: $(cat "$state/err.log")"
    [ "$(ci_polls)" -eq 11 ] \
      || fail "expected the first-check bound waited out before following, got $(ci_polls) poll(s)"
    [ "$(attempts)" -eq 1 ] \
      || fail "a fix round was paid for against the old commit: $(cat "$state/out.log")"
    if grep -q -- "--add-label agent-ready-for-review" "$state/gh.log"; then
      fail "a red run on a followed head was handed over: $(ghlog)"
    fi

    echo "case: a head that is not a commit is not a move to follow"
    # The fail-closed half of the same seam. A snapshot whose head is not a
    # 40-hex sha is an answer nobody can watch: following it would compare
    # every later snapshot against a value that matches nothing, so it reads
    # as nothing, and the absent bound - not an adoption - is what stops the
    # run.
    run ci-badsha mixed.json fresh good pass badsha
    [ "$rc" -ne 0 ] || fail "a garbage head was adopted as this branch's CI"
    grep -q "nothing has reported" "$state/err.log" \
      || fail "did not say the checks never arrived: $(cat "$state/err.log")"
    [ "$(ci_polls)" -eq 10 ] || fail "expected ten polls before calling it absent, got $(ci_polls)"

    echo "case: a cancelled run reaches no verdict, and is not fed back"
    run ci-cancelled mixed.json fresh good pass cancelled
    [ "$rc" -ne 0 ] || fail "a cancelled CI run was treated as green"
    grep -q "was cancelled" "$state/err.log" || fail "did not say the run was cancelled: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 1 ] || fail "a cancelled run was fed back to the model, which has nothing to fix"

    echo "case: an API that cannot be asked counts as a poll, not as a failure"
    # Under `set -euo pipefail` a `gh` inside a command substitution takes the
    # runner with it. One unavailable answer has to travel back as one poll
    # that saw nothing, so that the bounds above are what stop the run.
    run ci-apifail mixed.json fresh good pass "apifail apifail green"
    [ "$rc" -eq 0 ] || fail "two unavailable answers killed the run: $(cat "$state/err.log")"
    [ "$(ci_polls)" -eq 3 ] || fail "expected three polls, got $(ci_polls)"

    # The skeleton the two pre-push hand-backs share: the run ends in
    # failure with no pull request anywhere (the branch never opened one),
    # the worktree goes, the branch survives locally and on origin, and
    # the ticket carries the story and the stuck label. Each case still
    # asserts its own message and its own particulars around this.
    assert_hand_back_on_issue() {
      [ -z "$(worktrees)" ] || fail "the hand-back left its worktree: $(worktrees)"
      [ "$(branches)" = "afk/$ticket" ] \
        || fail "the pushed branch did not survive the hand-back: $(branches)"
      [ "$(pushed)" = "afk/$ticket" ] || fail "the branch left origin: $(pushed)"
      grep -q "gh issue comment 302 " "$state/gh.log" \
        || fail "no comment was left on the ticket: $(ghlog)"
      grep -q "gh issue edit 302 .* --add-label agent-stuck" "$state/gh.log" \
        || fail "the ticket was not relabelled: $(ghlog)"
      if grep -qE "pr close|pr merge" "$state/gh.log"; then
        fail "the hand-back closed or merged the pull request: $(ghlog)"
      fi
    }

    # The same skeleton past the push (#271): the hand-back lives on the
    # open pull request - comment and stuck label there, the issue touched
    # only to lose its claim marker, the issue's thread silent - and the
    # pull request is left open, never closed or merged.
    assert_hand_back_on_pr() {
      [ -z "$(worktrees)" ] || fail "the hand-back left its worktree: $(worktrees)"
      [ "$(branches)" = "afk/$ticket" ] \
        || fail "the pushed branch did not survive the hand-back: $(branches)"
      [ "$(pushed)" = "afk/$ticket" ] || fail "the branch left origin: $(pushed)"
      grep -q "gh pr comment" "$state/gh.log" \
        || fail "no comment was left on the pull request: $(ghlog)"
      grep -q "gh pr edit .* --add-label agent-stuck" "$state/gh.log" \
        || fail "the pull request was not relabelled: $(ghlog)"
      grep -q "gh issue edit 302 .* --remove-label agent-working" "$state/gh.log" \
        || fail "the ticket's claim was not undone: $(ghlog)"
      if grep -q "gh issue comment 302 " "$state/gh.log"; then
        fail "the hand-back was posted on the issue as well: $(ghlog)"
      fi
      if grep -q "gh issue edit 302 .* agent-stuck" "$state/gh.log"; then
        fail "the stuck label reached the issue: $(ghlog)"
      fi
      if grep -qE "pr close|pr merge" "$state/gh.log"; then
        fail "the hand-back closed or merged the pull request: $(ghlog)"
      fi
    }

    echo "case: a findings comment that cannot be posted hands the ticket back"
    # The findings are the output of the review stage, and a pull request
    # labelled ready without them would be saying something untrue. So a
    # failed comment is a failed run rather than a quiet one - and the
    # failure is past the push, so the hand-back lives on the pull request:
    # comment and stuck label there, the claim off the issue (#271), the
    # pull request left open without the hand-off label, the worktree gone
    # and the branch untouched. The refusal here is countable, so the only
    # `pr comment` the mock delivers is the hand-back's, and the read below
    # sees a body that was actually posted - caught against a mock that
    # refused the delivered comment, an earlier revision of this case passed
    # on the failed findings attempt alone.
    export GH_PR_COMMENT_FAIL=1
    run ci-commentfail mixed.json fresh good pass green
    unset GH_PR_COMMENT_FAIL
    [ "$rc" -ne 0 ] || fail "a hand-off that never landed was reported as success"
    grep -q "could not be posted on it" "$state/err.log" \
      || fail "did not say the hand-off failed: $(cat "$state/err.log")"
    assert_hand_back_on_pr "the post the findings could not reach"
    [ "$(cat "$state/pr-comment-count")" = "1" ] \
      || fail "expected only the hand-back's comment on the pull request, got $(cat "$state/pr-comment-count")"
    grep -q "stopped work on this ticket" "$state/pr-comment-body" \
      || fail "the delivered comment was not the hand-back's story: $(cat "$state/pr-comment-body")"
    if grep -q -- "--add-label agent-ready-for-review" "$state/gh.log"; then
      fail "the hand-off label was applied without the findings: $(ghlog)"
    fi

    echo "case: a hand-off edit that cannot land hands the ticket back"
    # The other half: the findings are on the pull request but the label is
    # not - still a failed run, since the label is what says from outside
    # that somebody has finished with this, and the message says which half
    # landed.
    export GH_PR_EDIT_FAIL=1
    run ci-editfail mixed.json fresh good pass green
    unset GH_PR_EDIT_FAIL
    [ "$rc" -ne 0 ] || fail "a hand-off that never landed was reported as success"
    grep -q "label could not be applied" "$state/err.log" \
      || fail "did not say the hand-off failed: $(cat "$state/err.log")"
    assert_hand_back_on_pr "the pull request the label could not reach"

    echo "case: a pull request that could not be opened hands the ticket back"
    # The branch is pushed by then, so there is no pull request for the
    # hand-back to reach - which is why this stays on the issue under the
    # #271 split: the work it holds passed the gate, so the branch stays on
    # origin and locally, with the comment saying a pull request can be
    # opened from it by hand. The worktree is the only thing that goes.
    export GH_PR_FAIL=1
    run raise-prfail mixed.json fresh good pass
    unset GH_PR_FAIL
    [ "$rc" -ne 0 ] || fail "a pull request that was never opened was reported as success"
    grep -q "could not be opened" "$state/err.log" \
      || fail "did not say the pull request failed: $(cat "$state/err.log")"
    assert_hand_back_on_issue "the branch the pull request could not be made from"
    grep -q "reached origin and is kept there" "$state/stuck-body" \
      || fail "the comment does not say the pushed branch was kept: $(cat "$state/stuck-body")"
    if grep -q "pr comment" "$state/gh.log"; then fail "commented on a pull request that never opened: $(ghlog)"; fi

    echo "case: a review that committed anyway cannot reach the pull request"
    # Report-only is a pattern match on a command line, not a capability
    # boundary - `git -C . commit` matches neither the prompt's request nor
    # `reviewOverlay`'s deny - and this is what gets past both. Under #174 that
    # was fatal, because the push came afterwards and the commit would have
    # gone out ungated. Item 13 moved the push in front of the review, so the
    # guarantee is now the shape of the run: the branch is already on origin,
    # nothing pushes it again, and the commit stays local.
    #
    # This case is that inversion. It used to assert a refusal; it now asserts
    # that the ticket finishes and the extra commit is nowhere near the pull
    # request - which is a stronger property than the check it replaced,
    # because it holds without anything having to notice.
    run review-commits mixed.json fresh good commits
    [ "$rc" -eq 0 ] || fail "a review that committed stopped the ticket: $(cat "$state/err.log")"
    [ "$(pushed_commits)" -eq 1 ] \
      || fail "the review's commit reached origin: $(pushed_commits) commit(s) on the branch there"
    [ "$(git -C "$state/checkout" rev-list --count "origin/master..afk/$ticket")" -eq 2 ] \
      || fail "the review's commit is not on the local branch, so this case is testing nothing"
    # Not a gate any more, but not silent either: a session that got past both
    # controls is worth a line, since it leaves a clean tree and is otherwise
    # invisible.
    grep -q "moved afk/$ticket" "$state/out.log" \
      || fail "did not record that the review moved the branch: $(cat "$state/out.log")"

    echo "case: a diff that touches a denied path is refused at the push"
    # docs/agents/afk-eligibility.md rule 1, asked of the diff. #302's prose
    # names nothing denied - it is the diff that does, which is precisely what
    # the pre-claim check cannot see and what this gate exists for. Nothing
    # reaches origin in any of these, which is the property that matters: a
    # pushed branch runs its own workflow with this repository's secrets before
    # anybody reads it.
    for denied in secret:secrets/new.yaml sops:.sops.yaml workflow:.github/workflows/other.yml; do
      denied_plan="''${denied%%:*}"
      denied_path="''${denied#*:}"
      run "push-denied-$denied_plan" mixed.json fresh "$denied_plan"
      [ "$rc" -ne 0 ] || fail "$denied_plan: a diff touching $denied_path was pushed anyway"
      grep -qF "$denied_path" "$state/err.log" \
        || fail "$denied_plan: the refusal did not name the path: $(cat "$state/err.log")"
      [ -z "$(pushed)" ] || fail "$denied_plan: the branch reached origin: $(pushed)"
      if grep -q "pr create" "$state/gh.log"; then fail "$denied_plan: a pull request was opened for a refused diff"; fi
    done

    echo "case: the one exception - a diff that only adds a checks-matrix entry is pushed"
    # The collision item 2 settled: a check added under checks/ has to be added
    # to ci.yml's hand-written matrix too, in an otherwise denied file, or no
    # AFK ticket could ever add a check. This is that exception being taken.
    export NIX_CHECKS="alpha beta gamma"
    run push-matrix mixed.json fresh matrix pass
    unset NIX_CHECKS
    [ "$rc" -eq 0 ] || fail "an additions-only ci.yml diff was refused: $(cat "$state/err.log")"
    [ "$(pushed)" = "afk/$ticket" ] || fail "the branch taking the exception did not reach origin: $(pushed)"
    grep -q "additions-only" "$state/out.log" || fail "the gate did not say what it allowed: $(cat "$state/out.log")"
    # And it checked the added entry against the flake's own checks rather than
    # against the file the implement gate left behind. The implement gate
    # already demands the two agree exactly, which makes that check redundant
    # today - the point is that this one does not inherit it.
    [ "$(grep -c "checks.x86_64-linux" "$state/nix.log")" -ge 2 ] \
      || fail "the pre-push gate did not list the flake's checks for itself: $(cat "$state/nix.log")"

    echo "case: a ci.yml diff that changes anything else is refused"
    # The clause the whole exception rests on. Steps, permissions, triggers and
    # secrets stay untouchable; an added matrix entry can only cause an
    # existing sandboxed derivation to be built.
    export NIX_CHECKS="alpha beta gamma"
    run push-matrix-plus mixed.json fresh matrixplus pass
    unset NIX_CHECKS
    [ "$rc" -ne 0 ] || fail "a ci.yml diff that edited a run step was pushed"
    grep -q "outside jobs.checks.strategy.matrix.check" "$state/err.log" \
      || fail "did not say the diff left the exception: $(cat "$state/err.log")"
    [ -z "$(pushed)" ] || fail "the branch reached origin: $(pushed)"

    echo "case: a ci.yml diff that removes a matrix entry is refused"
    # An entry removed silently stops a check from running, which is the
    # failure ci.yml's own lint job exists to catch - so additions only, and an
    # entry altered is a removal and an addition.
    export NIX_CHECKS="alpha"
    run push-matrix-drop mixed.json fresh matrixdrop pass
    unset NIX_CHECKS
    [ "$rc" -ne 0 ] || fail "a ci.yml diff that dropped a check was pushed"
    grep -q "beta" "$state/err.log" || fail "the refusal did not name the entry removed: $(cat "$state/err.log")"
    [ -z "$(pushed)" ] || fail "the branch reached origin: $(pushed)"

    echo "case: an added matrix entry outside the character class is refused"
    # A matrix entry is interpolated straight into a `run:` script by the
    # workflow, so it is shell context rather than data, and "it names a real
    # check" is not on its own enough to make the string safe - the agent
    # writes checks/default.nix too, and Nix attribute names can be quoted.
    export NIX_CHECKS="alpha beta Gamma"
    run push-matrix-bad mixed.json fresh matrixbad pass
    unset NIX_CHECKS
    [ "$rc" -ne 0 ] || fail "an unsafe matrix entry was pushed"
    grep -q "not a safe name" "$state/err.log" || fail "did not refuse the entry by name: $(cat "$state/err.log")"
    [ -z "$(pushed)" ] || fail "the branch reached origin: $(pushed)"

    echo "case: a dead run that never pushed is handed back, and the next ticket runs"
    # Item 8's other half: a worktree on disk beside a claimed ticket is what
    # a run killed mid-ticket looks like to the next poll. The guard hands it
    # back - comment, relabel, teardown - and the poll carries on to #330,
    # which is the difference between a pipeline that wedges on its first
    # casualty and one that does not. Built here the way a kill would leave
    # it: a finished ticket's worktree put back by hand, with its branch
    # struck from origin so nothing was ever pushed.
    run stuck-guard mixed.json fresh good pass
    git -C "$work/origin.git" update-ref -d "refs/heads/afk/$ticket"
    git -C "$state/checkout" worktree add "$state/worktrees/$ticket" "afk/$ticket"
    run stuck-guard second-ticket.json reuse
    [ "$rc" -eq 0 ] || fail "the poll after a dead run refused to start: $(cat "$state/err.log")"
    grep -q "gh issue comment 302 " "$state/gh.log" \
      || fail "the dead run's ticket got no comment: $(ghlog)"
    grep -q "gh issue edit 302 .* --remove-label agent-working --add-label agent-stuck" "$state/gh.log" \
      || fail "the dead run's ticket was not relabelled: $(ghlog)"
    grep -q "gh issue edit 330 .* --remove-label ready-for-agent" "$state/gh.log" \
      || fail "the next ticket was never claimed: $(ghlog)"
    grep -q "gh pr create" "$state/gh.log" \
      || fail "the next ticket reached no pull request: $(ghlog)"
    [ -z "$(worktrees)" ] \
      || fail "the dead run's worktree survived the hand-back: $(worktrees)"
    [ "$(branches)" = "afk/330-a-different-ticket" ] \
      || fail "the handed-back ticket's branch survived, or the next ticket's did not: $(branches)"
    [ "$(pushed)" = "afk/330-a-different-ticket" ] \
      || fail "expected only the next ticket's branch on origin: $(pushed)"
    if git -C "$work/origin.git" show-ref --verify --quiet "refs/heads/afk/$ticket"; then
      fail "the dead run's branch survived on origin"
    fi

    echo "case: a dead run's uncommitted work is rescued onto its branch, not deleted"
    # The case this pipeline paid for. On 2026-09-10 a run implemented its
    # ticket, wrote six new harness cases, got all six passing, and was killed
    # by the kernel's OOM killer while proving it. The guard found the worktree,
    # saw no pull request and an unpushed branch, and deleted both - 1462
    # insertions, gone, because the model had not reached its commit yet.
    #
    # Same shape as the case above, with the one difference that mattered:
    # there is work in the worktree when the guard arrives.
    run stuck-rescue mixed.json fresh good pass
    git -C "$work/origin.git" update-ref -d "refs/heads/afk/$ticket"
    git -C "$state/checkout" worktree add "$state/worktrees/$ticket" "afk/$ticket"
    printf 'work a run died holding\n' > "$state/worktrees/$ticket/rescued.txt"
    printf 'and an edit to a tracked file\n' >> "$state/worktrees/$ticket/README.md"
    run stuck-rescue second-ticket.json reuse
    [ "$rc" -eq 0 ] || fail "the poll after a dead run refused to start: $(cat "$state/err.log")"

    # The branch survives, because it is now the only copy of that work.
    [ "$(branches)" = "$(printf 'afk/302-unblocked-at-last\nafk/330-a-different-ticket')" ] \
      || fail "the rescued branch was deleted with the worktree: $(branches)"
    [ -z "$(worktrees)" ] || fail "the worktree survived the rescue: $(worktrees)"

    # Both the untracked file and the edit to the tracked one are on it.
    rescued_files="$(git -C "$state/checkout" show --name-only --format= "afk/$ticket" | LC_ALL=C sort)"
    [ "$rescued_files" = "$(printf 'README.md\nrescued.txt')" ] \
      || fail "the rescue commit does not carry the worktree's work: $rescued_files"
    git -C "$state/checkout" log -1 --format=%s "afk/$ticket" | grep -q "passed no gate" \
      || fail "the rescue commit does not say it passed nothing: $(git -C "$state/checkout" log -1 --format=%s "afk/$ticket")"

    # And it is never pushed. The pre-push gate is the only thing that may
    # authorise a push, and this work did not go through it - so a rescue that
    # reached origin would be the one outcome worse than deleting it.
    [ "$(pushed)" = "afk/330-a-different-ticket" ] \
      || fail "rescued work was pushed without passing the gate: $(pushed)"

    # The ticket still ends stuck, and its comment says where the work is.
    grep -q "gh issue edit 302 .* --remove-label agent-working --add-label agent-stuck" "$state/gh.log" \
      || fail "the rescued ticket was not handed back: $(ghlog)"
    grep -q "unpushed" "$state/stuck-body" \
      || fail "the hand-back comment does not say the work was kept unpushed: $(cat "$state/stuck-body")"
    grep -q "passed nothing" "$state/stuck-body" \
      || fail "the hand-back comment does not warn that the rescued commit passed no gate"

    echo "case: a hand-back that already happened is not commented twice"
    # The relabel lands before the teardown, so a hand-back whose teardown
    # failed last poll leaves exactly this shape: an `agent-stuck` ticket and
    # a worktree. The next pass must finish the teardown and write nothing.
    run stuck-guard-already mixed.json fresh good pass
    git -C "$work/origin.git" update-ref -d "refs/heads/afk/$ticket"
    git -C "$state/checkout" worktree add "$state/worktrees/$ticket" "afk/$ticket"
    export GH_STUCK_ALREADY=1
    run stuck-guard-already second-ticket.json reuse
    unset GH_STUCK_ALREADY
    [ "$rc" -eq 0 ] \
      || fail "the poll after a partial hand-back refused to start: $(cat "$state/err.log")"
    if grep -q "gh issue comment 302 " "$state/gh.log"; then
      fail "a handed-back ticket was commented on twice: $(ghlog)"
    fi
    if grep -q "gh issue edit 302 " "$state/gh.log"; then
      fail "a handed-back ticket was relabelled twice: $(ghlog)"
    fi
    [ -z "$(worktrees)" ] || fail "the teardown did not finish: $(worktrees)"
    grep -q "gh issue edit 330 " "$state/gh.log" \
      || fail "the next ticket was never claimed: $(ghlog)"

    echo "case: a dead run's pushed branch is kept, not torn down"
    # A run killed between the push and the pull request leaves a branch on
    # origin holding work the gate passed on. The hand-back asks origin
    # directly - the dead run left no memory of what it did - and keeps
    # pushed work, locally and on origin, with the comment saying a pull
    # request can be opened from it by hand.
    run stuck-guard-remote mixed.json fresh good pass
    git -C "$state/checkout" worktree add "$state/worktrees/$ticket" "afk/$ticket"
    run stuck-guard-remote second-ticket.json reuse
    [ "$rc" -eq 0 ] || fail "the poll refused to start: $(cat "$state/err.log")"
    grep -q "gh issue comment 302 " "$state/gh.log" \
      || fail "the dead run's ticket got no comment: $(ghlog)"
    grep -q "gh issue edit 302 .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the dead run's ticket was not relabelled: $(ghlog)"
    [ -z "$(worktrees)" ] || fail "the dead run's worktree survived: $(worktrees)"
    [ "$(branches)" = "$(printf 'afk/302-unblocked-at-last\nafk/330-a-different-ticket')" ] \
      || fail "the pushed branch did not survive the hand-back locally: $(branches)"
    [ "$(pushed)" = "$(printf 'afk/302-unblocked-at-last\nafk/330-a-different-ticket')" ] \
      || fail "the pushed branch did not survive the hand-back on origin: $(pushed)"

    echo "case: a leftover beside an open pull request is cleared, not handed back"
    # A run that finished but whose worktree removal failed leaves a worktree
    # next to an open pull request. Relabelling that ticket `agent-stuck`
    # under its own open pull request would be a lie, so the guard asks
    # instead of assuming: a PR open means clear the worktree, leave the
    # ticket and the branch alone, and move on.
    run stuck-guard-pr-open mixed.json fresh good pass
    git -C "$state/checkout" worktree add "$state/worktrees/$ticket" "afk/$ticket"
    export GH_PR_OPEN=1
    run stuck-guard-pr-open second-ticket.json reuse
    unset GH_PR_OPEN
    [ "$rc" -eq 0 ] \
      || fail "the poll after a finished-but-unclean run refused to start: $(cat "$state/err.log")"
    if grep -q "gh issue comment 302 " "$state/gh.log"; then
      fail "a finished ticket was handed back as stuck: $(ghlog)"
    fi
    if grep -q "gh issue edit 302 " "$state/gh.log"; then
      fail "a finished ticket was relabelled: $(ghlog)"
    fi
    grep -q "gh issue edit 330 " "$state/gh.log" \
      || fail "the next ticket was never claimed: $(ghlog)"
    [ -z "$(worktrees)" ] || fail "the orphaned worktree survived: $(worktrees)"
    [ "$(branches)" = "$(printf 'afk/302-unblocked-at-last\nafk/330-a-different-ticket')" ] \
      || fail "the pushed branch was deleted, or the next ticket's branch is missing: $(branches)"
    [ "$(pushed)" = "$(printf 'afk/302-unblocked-at-last\nafk/330-a-different-ticket')" ] \
      || fail "the finished ticket's branch left origin, or the next ticket's is missing: $(pushed)"

    echo "case: a leftover the runner cannot identify stops the run"
    # Tearing down something unidentified is the one thing this path must not
    # do, so it refuses loudly instead of working around it.
    run stuck-junk mixed.json fresh good pass
    mkdir -p "$state/worktrees/junk"
    run stuck-junk second-ticket.json reuse
    [ "$rc" -ne 0 ] || fail "an unidentifiable leftover was worked around"
    grep -q "does not name a ticket" "$state/err.log" \
      || fail "did not say why it refused: $(cat "$state/err.log")"

    echo "case: a run that cannot start hands the claim back instead of stranding it"
    # The clone is infrastructure the ticket did not choose: nothing was
    # tried, so nothing is handed back to a human. Undoing the claim returns
    # the ticket to the next poll; leaving it `agent-working` would strand it
    # - invisible to the frontier query, and with no worktree behind it,
    # invisible to the guard too.
    export AFK_REPO_URL="file://$work/does-not-exist.git"
    run stuck-clone-fails mixed.json fresh good pass
    export AFK_REPO_URL="file://$work/origin.git"
    [ "$rc" -ne 0 ] || fail "a failed clone was reported as success"
    grep -q "gh issue edit 302 .* --remove-label agent-working --add-label ready-for-agent" "$state/gh.log" \
      || fail "the claim was not undone: $(ghlog)"
    [ -z "$(worktrees)" ] || fail "a worktree exists for a ticket that never started"
    [ -z "$(branches)" ] || fail "a branch was cut for a ticket that never started"

    echo "case: a hand-back does not delete a branch the run did not cut"
    # The half-worked ticket: a branch with this slug already exists when the
    # runner arrives - from an earlier run whose worktree somebody cleared by
    # hand. The ticket is handed back, and the branch is left exactly as it
    # was found: it may be the branch a pull request is open from, and the
    # runner has no way to know.
    run stuck-foreign-branch mixed.json fresh good pass
    git -C "$work/origin.git" update-ref -d "refs/heads/afk/$ticket"
    run stuck-foreign-branch mixed.json reuse
    [ "$rc" -ne 0 ] || fail "a half-worked ticket was reported as done"
    grep -q "already exists" "$state/err.log" \
      || fail "did not say why it stopped: $(cat "$state/err.log")"
    grep -q "gh issue comment 302 " "$state/gh.log" \
      || fail "no comment was left on the ticket: $(ghlog)"
    grep -q "gh issue edit 302 .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the ticket was not relabelled: $(ghlog)"
    [ "$(branches)" = "afk/$ticket" ] \
      || fail "the pre-existing branch was disturbed: $(branches)"

    echo "case: the revision loop claims the pull request, resumes its head, and hands it back green"
    # Plan item 12's whole job, end to end, and every acceptance criterion
    # it can be pinned with in one run: the frontier finds the unacknowledged
    # `/revise` comment before any ticket is claimed, the claim swaps the
    # labels on the pull request itself, the session is fed the reviewer's
    # comments and nothing else, the commit lands on the pull request's
    # branch, the round comment says what was addressed, and the hand-off
    # label comes back in one edit once CI is green.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-comments.json"
    export GH_INLINE="$work/fixtures/revise-inline.json"
    export REVISE_SETUP=1
    run revise-clean none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS GH_INLINE REVISE_SETUP
    [ "$rc" -eq 0 ] || fail "a revisable pull request did not finish: $(cat "$state/err.log")"
    # The frontier's own query: the hand-off label and the App's authorship
    # are what put a pull request in it, not a person's label.
    grep -q "gh pr list .* --label agent-ready-for-review --author corygyarmathy-afk-agent\[bot\]" "$state/gh.log" \
      || fail "the frontier no longer filters by the hand-off label and the App's authorship: $(ghlog)"
    # The claim, one edit on the pull request, never on the issue.
    grep -q "gh pr edit 999 .* --remove-label agent-ready-for-review --add-label agent-revising" "$state/gh.log" \
      || fail "the pull request was not claimed with the documented convention: $(ghlog)"
    if grep -q "gh issue edit 302 " "$state/gh.log"; then fail "the revision lane touched the issue: $(ghlog)"; fi
    [ "$(revise_attempts)" -eq 1 ] || fail "expected one revision session, got $(revise_attempts)"
    # The reply to the `/revise` comment, posted where the request was made.
    grep -q "in reply to @corygyarmathy's \`/revise\` comment" "$state/pr-comment-1-body" \
      || fail "the claim reply did not answer the request: $(cat "$state/pr-comment-1-body")"
    # The reviewer's words reached the model: the review summary, the issue
    # comment, and the inline comment from the REST endpoint.
    grep -q "Please also bump the flake lock file" "$state/revise-args-1" \
      || fail "the reviewer's comment never reached the session: $(cat "$state/revise-args-1")"
    grep -q "The check name does not match" "$state/revise-args-1" \
      || fail "the reviewer's review summary never reached the session"
    grep -q "This assertion is backwards" "$state/revise-args-1" \
      || fail "the inline review comment never reached the session"
    grep -q "corygyarmathy" "$state/revise-args-1" \
      || fail "the comments were not attributed to their author"
    # And the advisory findings did not: the comment carrying them is the
    # agent's own, which the author filter drops before anything is
    # rendered. The findings fixture above is how this is a test rather
    # than a tautology.
    if grep -q "duplicated derivation" "$state/revise-args-1"; then
      fail "the advisory findings were fed back, which is the thing item 6 rejected"
    fi
    # Fresh session, titled so the round report can be found again, with
    # the permission overlay scoped to the one command.
    grep -qx -- --title "$state/revise-args-1" || fail "the revision session is untitled"
    [ "$(flag_value "$state/revise-args-1" --title)" = "$ticket-revise" ] \
      || fail "the revision session is titled $(flag_value "$state/revise-args-1" --title)"
    if grep -qx -- --session "$state/revise-args-1"; then
      fail "a round with nothing to continue opened with --session"
    fi
    jq -e --arg v "git push*" '.permission.bash[$v] == "deny"' "$state/revise-overlay-1" >/dev/null \
      || fail "the revision session was not denied the tracker verbs"
    jq -e '.permission.bash["gh pr view*"] == "allow"' "$state/revise-overlay-1" >/dev/null \
      || fail "the revision session was not allowed to read its pull request"
    # It ran in the worktree named after the branch, on the branch itself.
    [ "$(cat "$state/revise-cwd")" = "$state/worktrees/$ticket" ] \
      || fail "the revision did not run in the resumed worktree: $(cat "$state/revise-cwd")"
    [ "$(cat "$state/revise-branch")" = "afk/$ticket" ] \
      || fail "the revision did not run on the pull request's branch: $(cat "$state/revise-branch")"
    # The revised commit reached the same branch on origin, on top of what
    # the reviewer read, and origin carries the same tip the local branch
    # was reset to and pushed from.
    [ "$(pushed_commits)" -eq 2 ] \
      || fail "the revision did not reach origin as a further commit: $(pushed_commits) commit(s) there"
    [ "$(git -C "$work/origin.git" rev-parse "refs/heads/afk/$ticket")" \
      = "$(git -C "$state/checkout" rev-parse "refs/heads/afk/$ticket")" ] \
      || fail "origin and the local branch disagree after the revision"
    # The round comment: the durable record, and what the next poll counts
    # the rounds from. The claim reply was the first comment on the pull
    # request, so the round comment is the second.
    [ "$(cat "$state/pr-comment-count")" -eq 2 ] \
      || fail "expected a claim reply and a round comment, posted $(cat "$state/pr-comment-count") comment(s): $(ghlog)"
    if grep -q "revision round" "$state/pr-comment-1-body"; then
      fail "the claim reply was written as a round comment: $(cat "$state/pr-comment-1-body")"
    fi
    grep -q "gh pr comment 999 " "$state/gh.log" || fail "no round comment was posted: $(ghlog)"
    grep -q "revision round 1 of 3" "$state/pr-comment-body" \
      || fail "the round comment does not name itself, so the next poll cannot count it: $(cat "$state/pr-comment-body")"
    grep -q "Addressed the review comment" "$state/pr-comment-body" \
      || fail "the session's own report did not travel to the pull request"
    grep -q "Not addressed: nothing." "$state/pr-comment-body" \
      || fail "the report's other half - what the round did not address - did not travel: $(cat "$state/pr-comment-body")"
    # Handed back to the reviewer in one edit, with the notification.
    grep -q "gh pr edit 999 .* --remove-label agent-revising --add-label agent-ready-for-review" "$state/gh.log" \
      || fail "the hand-off label did not go back on: $(ghlog)"
    [ "$(ntfy_posts)" -eq 1 ] || fail "a revised pull request published $(ntfy_posts) notification(s): $(ntfylog)"
    grep -qF -- "-H Title: AFK agent: PR revised (#999)" "$state/ntfy.log" \
      || fail "the revision notification was not named: $(ntfylog)"
    [ -z "$(worktrees)" ] || fail "a revised pull request left its worktree: $(worktrees)"
    [ "$(branches)" = "afk/$ticket" ] || fail "the branch was disturbed: $(branches)"

    echo "case: a revision that rewrites the branch's own head is pushed behind the lease"
    # ADR 0007 §4, amended: the revise lane may amend or replay what the
    # agent itself pushed, and the lease makes that land - a rewritten head
    # is not a rejected one unless the remote moved. This is the shape a
    # plain push rejected on #263, burning a whole revision round.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-comments.json"
    export REVISE_SETUP=1
    run revise-amend none.json fresh amend pass green
    unset GH_PRS GH_PR_COMMENTS REVISE_SETUP
    [ "$rc" -eq 0 ] || fail "a leased rewrite did not finish: $(cat "$state/err.log")"
    [ "$(revise_attempts)" -eq 1 ] || fail "expected one revision session, got $(revise_attempts)"
    # The push landed: origin carries the amended commit, and the amended
    # commit is pushed, not the pre-rewrite head it replaced - one push is
    # what tells the amend from a fixup stacked beside it.
    [ "$(pushed_commits)" -eq 1 ] \
      || fail "the rewrite did not reach origin whole: $(pushed_commits) commit(s) there"
    [ "$(git -C "$work/origin.git" rev-parse "refs/heads/afk/$ticket")" \
      = "$(git -C "$state/checkout" rev-parse "refs/heads/afk/$ticket")" ] \
      || fail "origin and the local branch disagree after the rewrite"
    # The old head did not quietly get a sibling commit: the pushed tree
    # carries the amend's marker file.
    git -C "$work/origin.git" cat-file -p "refs/heads/afk/$ticket:fix-amend.txt" >/dev/null 2>&1 \
      || fail "the amended tree did not reach origin"
    grep -q "revision round 1 of 3" "$state/pr-comment-body" \
      || fail "the round comment did not name itself: $(cat "$state/pr-comment-body")"
    grep -q "gh pr edit 999 .* --remove-label agent-revising --add-label agent-ready-for-review" "$state/gh.log" \
      || fail "a rewritten branch was not handed back to the reviewer: $(ghlog)"

    echo "case: a foreign push while the round ran holds the rewrite back"
    # The other half of the lease, and why the old rule existed at all: the
    # remote moved after the round resumed, the session still rewrote the
    # pre-foreign head, and the leased push must refuse it. The hand-back
    # shape is the revision lane's usual one - nothing pushed, the round
    # comment never posted, the stuck path reaches the pull request.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-comments.json"
    export REVISE_SETUP=1
    run revise-lease-refused none.json fresh foreign pass green
    unset GH_PRS GH_PR_COMMENTS REVISE_SETUP
    [ "$rc" -ne 0 ] || fail "a rewrite over a foreign push was pushed: $(cat "$state/err.log")"
    grep -q "did not push, so the CI fix never reached" "$state/err.log" \
      || fail "did not say why it stopped: $(cat "$state/err.log")"
    # The only commits beyond master on origin are the ticket's own and the
    # foreign one - the session's rewrite never landed, and the foreign
    # commit is what now sits at the tip.
    [ "$(pushed_commits)" -eq 2 ] \
      || fail "origin does not carry just the ticket's and the foreign commit: $(pushed_commits) commit(s) there"
    [ "$(git -C "$work/origin.git" log --format=%s -1 "refs/heads/afk/$ticket")" \
      = "afk: a foreign push while this round ran" ] \
      || fail "the foreign commit was not left at the tip: $(git -C "$work/origin.git" log --format=%s -1 "refs/heads/afk/$ticket")"
    if git -C "$work/origin.git" cat-file -e "refs/heads/afk/$ticket:fix-amend.txt" 2>/dev/null; then
      fail "the rewritten tree overrode the foreign push"
    fi
    # Exactly two comments reach the pull request - the claim reply and the
    # hand-back - never a round comment for a push that never happened.
    [ "$(grep -c "gh pr comment" "$state/gh.log")" -eq 2 ] \
      || fail "a round comment was posted for a push that never happened: $(ghlog)"
    grep -q "Nothing was pushed" "$state/pr-comment-body" \
      || fail "the hand-back does not say what state it left: $(cat "$state/pr-comment-body")"
    grep -q "gh pr edit 999 .* --remove-label agent-revising --add-label agent-stuck" "$state/gh.log" \
      || fail "the pull request was not relabelled on the stuck path: $(ghlog)"

    echo "case: a /revise with an instruction of its own drives the round from that text"
    # The inline text is the request; the review comments behind it are
    # not re-fed with it. One of the two ways a `/revise` can carry a
    # round's input.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-instructed.json"
    export REVISE_SETUP=1
    run revise-instructed none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS REVISE_SETUP
    [ "$rc" -eq 0 ] || fail "an instructed revision did not finish: $(cat "$state/err.log")"
    grep -q "address the inline comment only" "$state/revise-args-1" \
      || fail "the /revise instruction never reached the session: $(cat "$state/revise-args-1")"
    grep -q "/revise instruction" "$state/revise-args-1" \
      || fail "the instruction was not framed as what it is: $(cat "$state/revise-args-1")"
    if grep -q "Please also bump the flake lock file" "$state/revise-args-1"; then
      fail "the review comments were fed back behind an instruction that replaced them"
    fi
    if grep -q "The check name does not match" "$state/revise-args-1"; then
      fail "the review summary was fed back behind an instruction that replaced it"
    fi

    echo "case: the revision continues the session that built the branch"
    # ADR 0004 §6, applied to the reviewer's comments: the failure is in
    # the work the session wrote, and the session that wrote it can still
    # be found - the revise worktree is the same path the original ran in,
    # so the project-scoped session list can see it. Continued rather than
    # re-opened, and never both.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-comments.json"
    export REVISE_SETUP=1 REVISE_SESSION=1
    run revise-continues none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS REVISE_SETUP REVISE_SESSION
    [ "$rc" -eq 0 ] || fail "a revisable pull request did not finish: $(cat "$state/err.log")"
    grep -q "continuing the session that built this branch" "$state/out.log" \
      || fail "did not say the round continued the earlier session"
    [ "$(flag_value "$state/revise-args-1" --session)" = ses_fixture ] \
      || fail "the round opened a fresh session beside one it could have continued: $(flag_value "$state/revise-args-1" --session)"
    if grep -qx -- --title "$state/revise-args-1"; then fail "a continued session was titled a second time"; fi

    echo "case: a pull request whose only comments are the agent's own starts no session"
    # The acceptance criterion that keeps the loop from teaching itself:
    # without the author filter, the agent's own round comments - and the
    # advisory findings comment the hand-off posted, now in the same
    # channel the reviewer's comments arrive through (#202) - would be an
    # instruction to the model that wrote them.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-bot-only.json"
    run revise-bot-only none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS
    [ "$rc" -eq 0 ] || fail "an agent-only comment thread stopped the poll: $(cat "$state/err.log")"
    [ "$(revise_attempts)" -eq 0 ] || fail "a session started for the agent's own comments"
    if grep -q "gh pr edit 999 " "$state/gh.log"; then fail "claimed a pull request it will not revise: $(ghlog)"; fi
    grep -q "starting no session" "$state/out.log" \
      || fail "did not say why it skipped: $(cat "$state/out.log")"

    echo "case: a review comment without a /revise command starts no session"
    # The other half of the same criterion: the human's review comments
    # are the round's fallback input, not its trigger. A review without
    # the request - however full of findings - is a review, not a
    # revision request.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-no-command.json"
    run revise-untriggered none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS
    [ "$rc" -eq 0 ] || fail "an unrevised review stopped the poll: $(cat "$state/err.log")"
    [ "$(revise_attempts)" -eq 0 ] || fail "a session started without a /revise comment"
    if grep -q "gh pr edit 999 " "$state/gh.log"; then fail "claimed a pull request nobody asked it to revise: $(ghlog)"; fi
    grep -q "starting no session" "$state/out.log" \
      || fail "did not say why it skipped: $(cat "$state/out.log")"

    echo "case: a bare /revise with nothing behind it starts no session"
    # The trigger answers, but there is nothing to run the round on: no text
    # in the comment, and no review comment left behind for the fallback.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-empty.json"
    run revise-empty none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS
    [ "$rc" -eq 0 ] || fail "an empty request stopped the poll: $(cat "$state/err.log")"
    [ "$(revise_attempts)" -eq 0 ] || fail "a session started with nothing to feed it"
    if grep -q "gh pr edit 999 " "$state/gh.log"; then fail "claimed a pull request before anything to revise arrived: $(ghlog)"; fi
    grep -q "no instruction and no review comment" "$state/out.log" \
      || fail "did not say why it skipped: $(cat "$state/out.log")"

    echo "case: a /revise the last round already consumed does not re-trigger after a hand-back"
    # Re-entry, the negative half: the hand-back comment carries the anchor,
    # so the watermark moves past the `/revise` the last round was started
    # with, and returning the pull request to the frontier on that stale
    # request alone starts nothing.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-handback-stale.json"
    run revise-handback-stale none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS
    [ "$rc" -eq 0 ] || fail "a returned hand-back stopped the poll: $(cat "$state/err.log")"
    [ "$(revise_attempts)" -eq 0 ] || fail "a session started on a request the last round consumed"
    if grep -q "gh pr edit 999 " "$state/gh.log"; then fail "claimed a hand-back whose request was already consumed: $(ghlog)"; fi
    grep -q "starting no session" "$state/out.log" \
      || fail "did not say why it skipped: $(cat "$state/out.log")"

    echo "case: a fresh /revise after a hand-back re-enters the loop"
    # Re-entry, the positive half: the hand-off label re-applied and a new
    # `/revise`, written after the hand-back comment, spend another round
    # from the comment's own instruction.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-handback-fresh.json"
    export REVISE_SETUP=1
    run revise-handback-fresh none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS REVISE_SETUP
    [ "$rc" -eq 0 ] || fail "a re-entered revision did not finish: $(cat "$state/err.log")"
    [ "$(revise_attempts)" -eq 1 ] || fail "the fresh /revise did not start a session"
    grep -q "assume the worktree never knew about the fixup" "$state/revise-args-1" \
      || fail "the re-entry instruction never reached the session: $(cat "$state/revise-args-1")"

    echo "case: a fourth revision round does not run; the pull request goes to the stuck path"
    # Three round comments on the pull request and a `/revise` written
    # after the last of them, still unacknowledged: the budget is read
    # from the tracker - the runner has no memory between runs - and the
    # stuck path reaches the pull request itself, since that is where the
    # reviewer is.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-exhausted.json"
    run revise-exhausted none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS
    [ "$rc" -ne 0 ] || fail "a spent budget was reported as a quiet poll"
    [ "$(revise_attempts)" -eq 0 ] || fail "a fourth revision session ran"
    grep -q "gh pr edit 999 .* --remove-label agent-ready-for-review --add-label agent-stuck" "$state/gh.log" \
      || fail "the pull request was not relabelled to the stuck label: $(ghlog)"
    grep -q "gh pr comment 999 " "$state/gh.log" || fail "the hand-back never reached the pull request: $(ghlog)"
    grep -q "will not start another round" "$state/pr-comment-body" \
      || fail "the comment does not say what another /revise would do: $(cat "$state/pr-comment-body")"
    [ "$(ntfy_posts)" -eq 1 ] || fail "a stuck pull request published $(ntfy_posts) notification(s): $(ntfylog)"
    grep -qF "Pull request: https://github.com/corygyarmathy/dotfiles/pull/999" "$state/ntfy.log" \
      || fail "the stuck notification did not point at the pull request: $(ntfylog)"

    echo "case: a round is fed only the comments its watermark has not seen"
    # Round 2 of a review: the comment the first round already addressed is
    # not an instruction any more, and re-feeding it would spend the round
    # re-answering it. A bare `/revise` after the last round comment starts
    # the round and falls back to the review comments written since - only
    # what the reviewer wrote after the last round comment crosses.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-round2.json"
    export REVISE_SETUP=1
    run revise-watermark none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS REVISE_SETUP
    [ "$rc" -eq 0 ] || fail "the second round did not finish: $(cat "$state/err.log")"
    grep -q "NEW: left after the last round comment" "$state/revise-args-1" \
      || fail "the newer comment did not reach the session: $(cat "$state/revise-args-1")"
    if grep -q "OLD: addressed in the round" "$state/revise-args-1"; then
      fail "a comment the last round predates was fed back as new"
    fi
    # And the round this poll runs is counted from the tracker, not from
    # local memory: the comment says round 2 because round 1's comment is
    # on the pull request.
    grep -q "revision round 2 of 3" "$state/pr-comment-body" \
      || fail "the round was not counted from the tracker: $(cat "$state/pr-comment-body")"

    echo "case: a revision that fails its gate consumes a retry, not a round"
    # The acceptance criterion the round budget turns on: a gate failure
    # inside the round is the implement stage's retry shape - same session,
    # gate tail handed across - and the round only counts once its commit
    # is pushed.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-comments.json"
    export REVISE_SETUP=1
    run revise-retry none.json fresh "broken repair" pass green
    unset GH_PRS GH_PR_COMMENTS REVISE_SETUP
    [ "$rc" -eq 0 ] || fail "a repaired revision did not finish: $(cat "$state/err.log")"
    [ "$(revise_attempts)" -eq 2 ] || fail "expected two attempts, got $(revise_attempts)"
    grep -qx -- --session "$state/revise-args-2" || fail "the retry opened a fresh session (ADR 0004 §6)"
    [ "$(flag_value "$state/revise-args-2" --session)" = ses_revise ] \
      || fail "the retry continued a session other than the one that failed"
    grep -q "the gate failed" "$state/revise-args-2" || fail "the retry was not told what the gate said"
    [ "$(pushed_commits)" -eq 3 ] || fail "the retry did not reach origin"
    grep -q "revision round 1 of 3" "$state/pr-comment-body" \
      || fail "a failed gate consumed a round: $(cat "$state/pr-comment-body")"

    echo "case: red CI on the revised commit is fixed inside the revision session"
    # The same asymmetry the ticket lane's fix rounds run on: one session,
    # judged once, pushed to the same branch, then handed back green.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-comments.json"
    export REVISE_SETUP=1
    run revise-ci-fix none.json fresh "good good" pass "red green"
    unset GH_PRS GH_PR_COMMENTS REVISE_SETUP
    [ "$rc" -eq 0 ] || fail "a revisable, fixable branch did not finish: $(cat "$state/err.log")"
    [ "$(revise_attempts)" -eq 2 ] || fail "expected one revision and one CI fix, got $(revise_attempts) session(s)"
    [ "$(flag_value "$state/revise-args-2" --session)" = ses_revise ] \
      || fail "the CI fix opened a fresh session (ADR 0004 §6)"
    grep -q "These checks are not green" "$state/revise-args-2" \
      || fail "the fix was not told what CI said: $(cat "$state/revise-args-2")"
    # The fix round's session shape, pinned beside the ticket lane's: one
    # copy of the shape is what the two lanes share (#243), so both are
    # asserted rather than only the lane whose loop is being reshaped.
    [ "$(flag_value "$state/revise-args-2" --dir)" = "$state/worktrees/$ticket" ] \
      || fail "the revision's CI fix was not pinned to its worktree with --dir: $(flag_value "$state/revise-args-2" --dir)"
    jq -e --arg v "git push*" '.permission.bash[$v] == "deny"' "$state/revise-overlay-2" >/dev/null \
      || fail "the revision's CI fix session was not denied the tracker verbs"
    jq -e '.permission.bash["gh pr view*"] == "allow"' "$state/revise-overlay-2" >/dev/null \
      || fail "the revision's CI fix session was not allowed to read its pull request"
    [ "$(pushed_commits)" -eq 3 ] || fail "the fix did not reach origin"
    grep -q "gh pr edit 999 .* --add-label agent-ready-for-review" "$state/gh.log" \
      || fail "the branch did not come back to the reviewer: $(ghlog)"

    echo "case: the revision's push is gated against the revised diff"
    # The denylist is re-derived, not inherited: this diff touches
    # secrets/, the local gate passes on it, and the pre-push gate must
    # refuse it exactly as it would a first push. Nothing reaches origin,
    # the round comment never posts, and the stuck path reaches the pull
    # request - the revision lane's own hand-back shape.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-comments.json"
    export REVISE_SETUP=1
    run revise-push-denied none.json fresh secret pass green
    unset GH_PRS GH_PR_COMMENTS REVISE_SETUP
    [ "$rc" -ne 0 ] || fail "a revision touching a denied path was pushed"
    grep -qF "secrets/new.yaml" "$state/err.log" \
      || fail "the refusal did not name the path: $(cat "$state/err.log")"
    [ "$(pushed_commits)" -eq 1 ] || fail "the denied revision reached origin: $(pushed_commits) commit(s) there"
    # Exactly two pull request comments: the claim reply and the hand-back's
    # - not a round comment for a push that never happened.
    [ "$(grep -c "gh pr comment" "$state/gh.log")" -eq 2 ] \
      || fail "a round comment was posted for a push that never happened: $(ghlog)"
    if grep -q "revision round" "$state/pr-comment-1-body"; then
      fail "the claim reply was written as a round comment: $(cat "$state/pr-comment-1-body")"
    fi
    grep -q "gh pr edit 999 .* --remove-label agent-revising --add-label agent-stuck" "$state/gh.log" \
      || fail "the pull request was not relabelled on the stuck path: $(ghlog)"
    grep -q "Nothing was pushed" "$state/pr-comment-body" \
      || fail "the hand-back does not say what state it left: $(cat "$state/pr-comment-body")"

    echo "case: a waiting revision is ahead of a backlog ticket in the same poll"
    # #247's ordering: both lanes are live in one poll, and the human
    # waiting on a revision is served before a backlog ticket is claimed.
    # One poll, one lane - the ticket stays in its queue for the next one.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-comments.json"
    export GH_INLINE="$work/fixtures/revise-inline.json"
    export REVISE_SETUP=1
    run revise-first mixed.json fresh good pass green
    unset GH_INLINE REVISE_SETUP
    # The frontier scan runs in every poll now, so the two fixtures it
    # reads are restored to the defaults rather than left unset - a mock
    # asked to cat an unset fixture would answer an empty queue with an
    # error, and every case after this one polls it first.
    export GH_PRS="$work/fixtures/none-prs.json"
    export GH_PR_COMMENTS="$work/fixtures/none-prs.json"
    [ "$rc" -eq 0 ] || fail "a revision ahead of a backlog did not finish: $(cat "$state/err.log")"
    [ "$(revise_attempts)" -eq 1 ] || fail "the revision did not run: $(revise_attempts) session(s)"
    [ "$(pushed_commits)" -eq 2 ] \
      || fail "the revision did not reach origin: $(pushed_commits) commit(s) there"
    if grep -q "gh issue list" "$state/gh.log"; then
      fail "the ticket queue was polled beside a waiting revision: $(ghlog)"
    fi
    if grep -q "gh issue edit 302 " "$state/gh.log"; then
      fail "a ticket was claimed beside a waiting revision: $(ghlog)"
    fi
    grep -q "gh pr edit 999 .* --remove-label agent-revising --add-label agent-ready-for-review" "$state/gh.log" \
      || fail "the revision did not hand back: $(ghlog)"

    echo "case: a revision run that died mid-round has its claim undone by the guard"
    # The revision lane's claim lives on the pull request - the ticket
    # lane's lives on the issue - so a dead revision run leaves exactly one
    # fingerprint: an open pull request carrying `agent-revising` beside a
    # leftover worktree. The guard swaps the labels back, so the pull
    # request returns to the revision frontier - the unacknowledged
    # `/revise` comment is still on it - and the next ticket is never
    # blocked by it.
    run revise-guard mixed.json fresh good pass green
    git -C "$state/checkout" worktree add "$state/worktrees/$ticket" "afk/$ticket"
    export GH_PR_OPEN=1 GH_PR_CLAIMED=1
    run revise-guard second-ticket.json reuse
    unset GH_PR_OPEN GH_PR_CLAIMED
    [ "$rc" -eq 0 ] || fail "the poll after a dead revision run refused to start: $(cat "$state/err.log")"
    grep -q "gh pr edit 999 .* --remove-label agent-revising --add-label agent-ready-for-review" "$state/gh.log" \
      || fail "the dead run's claim was not undone: $(ghlog)"
    if grep -q "gh issue comment 302 " "$state/gh.log"; then
      fail "a mid-revision pull request was handed back as a stuck ticket: $(ghlog)"
    fi
    [ -z "$(worktrees)" ] || fail "the dead run's worktree survived: $(worktrees)"
    grep -q "gh issue edit 330 " "$state/gh.log" \
      || fail "the next ticket was never claimed: $(ghlog)"

    echo "case: merge is never in the runner's command surface"
    # ADR 0004 §9 - merge stays a human act - is enforced by nothing else.
    # Item 3 found that no GitHub ruleset can carry it here: ADR 0004 §4 rules
    # out a second account, so an AFK PR is authored by the person who would
    # approve it, and GitHub does not let an author approve their own PR. This
    # grep is the whole control.
    if grep -qE 'gh[[:space:]]+pr[[:space:]]+merge' "$script"; then
      fail "the runner can merge its own pull request"
    fi
    # `--auto` was grepped for unconditionally here until the implement stage
    # landed, as the flag `gh pr merge` takes to merge the moment the checks go
    # green. It is also `opencode run`'s unattended-approval flag, which an
    # unattended runner cannot work without - so the assertion is narrowed
    # rather than dropped: every `--auto` in the script has to be opencode's.
    # `opencode run` and not merely `opencode`: the loose form would be
    # satisfied by a comment that happened to mention opencode on the same line.
    while IFS= read -r auto_line; do
      case "$auto_line" in
        *"opencode run"*) ;;
        *) fail "an --auto that is not opencode's: $auto_line" ;;
      esac
    done < <(grep -F -- '--auto' "$script")

    echo "case: the runner's denylist still matches the document it implements"
    # Two independent readings of one rule (ADR 0004 §5) only stay independent
    # while they agree. This compares the runner's own array against rule 1's
    # list in docs/agents/afk-eligibility.md, so a path added or dropped in one
    # place fails here rather than in production, silently, months later.
    mapfile -t doc_paths < <(
      awk '
        /^No AFK-produced diff may touch:$/ { in_list = 1; next }
        in_list && /^- / { print; next }
        in_list && NF { exit }
      ' "$eligibilityDoc" | grep -o '`[^`]*`' | tr -d '`' | sort
    )
    mapfile -t script_paths < <(
      sed -n '/^denied=($/,/^)$/p' "$script" | grep -o '"[^"]*"' | tr -d '"' | sort
    )
    [ "''${#doc_paths[@]}" -gt 0 ] \
      || fail "could not read rule 1's path list out of afk-eligibility.md - has it been reformatted?"
    [ "''${#script_paths[@]}" -gt 0 ] \
      || fail "could not read the denied= array out of the runner - has it been restructured?"
    [ "''${doc_paths[*]}" = "''${script_paths[*]}" ] \
      || fail "denylist drift: the document says [''${doc_paths[*]}], the runner enforces [''${script_paths[*]}]"

    touch $out
  ''
