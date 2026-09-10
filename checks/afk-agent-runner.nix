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
  eval = inputs.nixpkgs.lib.nixosSystem {
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
        cg.service.afk-agent.enable = true;
        system.stateVersion = "24.11";
      }
    ];
  };

  runnerScript = eval.config.systemd.services.afk-agent.serviceConfig.ExecStart;

  # The unit's own PATH, taken from the same evaluation the script comes from
  # rather than restated here. `systemd.services.<name>.path` is already the
  # module's toolchain plus the default a NixOS unit gets (coreutils,
  # findutils, gnugrep, gnused, systemd), so this is exactly what the runner
  # will find at 04:00 on homelab01, and it cannot drift from it.
  unitPath = pkgs.lib.makeBinPath eval.config.systemd.services.afk-agent.path;
in
pkgs.runCommand "check-afk-agent-runner"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
    ];
    script = builtins.toString runnerScript;
    eligibilityDoc = ../docs/agents/afk-eligibility.md;
  }
  ''
    set -euo pipefail

    fail() { echo "FAIL: $*" >&2; exit 1; }

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
    # the body twice over the same path and the first one would not survive.
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
      # are told apart by `--label`: the revise poll asks by label and the
      # guard asks by head branch. The guard's answer carries the PR's
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
                printf '[{"number":999,"labels":[{"name":"agent-working"}]}]\n'
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
      # apart by the fields they ask for: the revise poll wants the review
      # summaries and comments, and the watch wants the rollup. The poll's
      # call is peeled off first and answered from `$GH_PR_COMMENTS`.
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
          # not the commit that was pushed. For a poll or two after a fix is
          # pushed that is the API's own staleness; held for a whole
          # first-check window it is a head somebody else pushed (#248),
          # and the watch follows it rather than calling the run absent.
          stale) sha=0000000000000000000000000000000000000000 ;;
          # A head that is not a commit at all. Not a head anybody can be
          # watching, so the watch has to read it as nothing rather than
          # follow it into a value that matches nothing.
          badsha) sha=not-a-sha ;;
        esac

        case "$step" in
          none)      rollup='[]' ;;
          red)       rollup='[{"__typename":"CheckRun","name":"check afk-agent-runner","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
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
      # The revision lane's round comment and hand-back reach the same verb,
      # and the round comment is asserted on, so its body is kept too.
      "pr comment")
        if [ -n "''${GH_PRCOMMENT_FAIL:-}" ]; then
          echo "mock gh: refusing to comment on the pull request" >&2
          exit 1
        fi
        keep_arg "$OC_STATE/pr-comment-body" --body-file "$@"
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
    for a in "$@"; do
      case "$a" in
        "Review the work on this branch."*) is_review=yes ;;
        # The revision lane's opening message and its two continuation
        # messages: the gate retry and the red-CI fix. Told apart from the
        # ticket lane's by the payload, exactly as the review session is -
        # a runner that stopped addressing the model as a revision would
        # then fail the cases below rather than quietly fall through to
        # the implement path and pass.
        "Address the human review comments"*) is_revise=yes ;;
        "Revision attempt"*) is_revise=yes ;;
        "The revision on this branch"*) is_revise=yes ;;
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
            *)      echo "mock opencode: no revise plan step $n" >&2; exit 64 ;;
          esac
          if [ "$opened" = yes ] && [ ! -s "$OC_STATE/revise-title" ]; then
            sed -n '/^--title$/{n;p;q}' "$OC_STATE/revise-args-1" > "$OC_STATE/revise-title"
          fi
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
      echo "mock nix: the tree still contains BROKEN" >&2
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
    # The queue the revise poll reads (`gh pr list --label`), and the
    # comment documents `pr view --json reviews,comments` answers with.
    # The pull request is the one the ticket lane's own run would have
    # opened: #999, from `afk/302-unblocked-at-last` - so a revise case and
    # a ticket case can share one fixture origin, and the assertions about
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

    # One review summary and one issue comment, both by the reviewer, both
    # at the watermark's floor: with no bot comments on the pull request,
    # every human comment is in.
    cat > "$work/fixtures/revise-comments.json" <<'JSON'
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

    # And the inline half, which `pr view` does not carry: read from the
    # REST endpoint the poll asks beside it.
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
    # only the agent's own.
    cat > "$work/fixtures/revise-bot-only.json" <<'JSON'
    {
      "reviews": [],
      "comments": [
        { "author": { "login": "corygyarmathy-afk-agent[bot]" },
          "createdAt": "2026-09-10T12:00:00Z",
          "body": "AFK agent: revision round 1 of 3." }
      ]
    }
    JSON

    # The budget: three round comments the runner left, one human comment
    # still outstanding. A fourth round does not run.
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
          "body": "AFK agent: revision round 3 of 3." }
      ]
    }
    JSON

    # The watermark: one human comment from before the last round comment
    # and one from after. A round is fed only the newer one - the author
    # filter is what keeps the agent's own words out, and the watermark is
    # what keeps last round's work from being re-fed as an instruction.
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
    # after it, defaulting to a clean pass for the same reason.
    run() {
      local name=$1 fixture=$2 reuse=''${3:-fresh} plan=''${4:-good} review=''${5:-pass} ci=''${6:-green}
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
        "$state"/implement-saw-pr-* "$state"/revise-*
      # Unquoted on purpose: a plan is a whitespace-separated list of steps and
      # this is what turns it into one line each.
      # shellcheck disable=SC2086
      printf '%s\n' $plan > "$OC_PLAN"
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
      HOME="$work/home-run" PATH="$unit_path" "$script" \
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

    # The revision poll's fixtures, defaulted to an empty queue so that every
    # case written before the lane existed falls through it quietly - the
    # revise cases below point these at their own fixtures.
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
    for verb in "git push*" "gh pr*" "gh issue edit*" "gh issue comment*" "gh issue close*"; do
      jq -e --arg v "$verb" '.permission.bash[$v] == "deny"' "$state/overlay-1" > /dev/null \
        || fail "the implement session was not denied '$verb'"
    done

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
    # one. So each is asserted from outside, out of the transcript, and each is
    # fatal in the fail-closed direction.
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

    echo "case: a skill call for something else is not a code-review"
    run review-wrongskill mixed.json fresh good wrongskill
    [ "$rc" -ne 0 ] || fail "a session that ran some other skill passed as a code review"

    echo "case: the two axes have to be two contexts, not one"
    # `subagents=0` in item 1's terms: standards and spec collapsing into the
    # parent context is the premise of this stage failing rather than erroring.
    for collapsed in oneaxis noaxes; do
      run "review-$collapsed" mixed.json fresh good "$collapsed"
      [ "$rc" -ne 0 ] || fail "$collapsed: collapsed axes were accepted as a two-axis review"
      grep -q "collapsed into one context" "$state/err.log" \
        || fail "$collapsed: did not say the axes collapsed: $(cat "$state/err.log")"
    done

    echo "case: two sub-agents sent elsewhere are not the two axes"
    # The count on its own would be satisfied by a session that fanned out
    # twice for its own reasons. What ADR 0004 §6 asks for is the separation of
    # standards from spec, so that is what is checked.
    run review-wrongaxes mixed.json fresh good wrongaxes
    [ "$rc" -ne 0 ] || fail "two unrelated sub-agents were accepted as a two-axis review"
    grep -q "is identifiable across them" "$state/err.log" \
      || fail "did not say the axes were unidentifiable: $(cat "$state/err.log")"

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

    echo "case: the body links back to the source issue, and carries the findings after the review"
    # Two bodies now, and they are different documents (item 13). At creation
    # time the review has not run, so there are no findings to carry; the
    # hand-off edit renders the whole body again with them in it. The mock kept
    # a copy of each, because the runner writes both over the same path.
    created="$state/pr-create-body"
    body="$state/run/pr-body.md"
    [ -s "$created" ] || fail "no pull request body was assembled at creation time"
    [ -s "$body" ] || fail "no pull request body was assembled"
    grep -qx "Closes #302." "$created" || fail "the body does not link back to the source issue: $(cat "$created")"
    grep -q -- "--body-file $body" "$state/gh.log" || fail "the pull request was opened with some other body: $(ghlog)"
    grep -q "No person has read this diff" "$created" || fail "the body does not say the diff is unread"
    grep -q "afk/$ticket" "$created" || fail "the body does not name the branch"
    # The creation-time body cannot carry findings, because nothing has
    # reviewed anything yet - and it says so, rather than leaving a reader to
    # wonder whether the section is missing or absent on purpose.
    if grep -q "duplicated derivation" "$created"; then
      fail "the body carried the review's findings before the review had run"
    fi
    grep -q "Handed over" "$created" \
      || fail "the creation-time body does not say what a missing hand-off section means: $(cat "$created")"
    # And the final body does carry them (item 6): they are the entire output
    # of the review stage, and the pull request is the only place they are
    # worth anything.
    grep -q "duplicated derivation" "$body" || fail "the review's findings did not travel to the pull request"
    # With the caveat attached to them. A reader who takes them for an approval
    # is making exactly the mistake dropping the verdict was meant to prevent.
    grep -q "advisory" "$body" || fail "the body does not say what the review is not"
    grep -q "never once refused that diff" "$body" \
      || fail "the body does not carry the measured caveat the findings travel with"

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
    # And in the right order: what it claims, then what CI and the review made
    # of it.
    claims_at="$(grep -n "What the branch says it does" "$body" | cut -d: -f1)"
    review_at="$(grep -n "^## Handed over" "$body" | cut -d: -f1)"
    [ -n "$review_at" ] || fail "the final body has no hand-off section: $(cat "$body")"
    [ "$claims_at" -lt "$review_at" ] \
      || fail "the review's findings come before what the branch claims to do"

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

    echo "case: the findings and the hand-off label arrive in one edit, at the end"
    # One `gh pr edit` rather than two, for the reason the claim is one `gh
    # issue edit`: a pull request carrying the label while its body still had
    # no findings under it would be saying something untrue for as long as the
    # second call took.
    [ "$(grep -c "gh pr edit" "$state/gh.log")" -eq 1 ] \
      || fail "the hand-off was not a single edit: $(ghlog)"
    grep -q -- "--add-label agent-ready-for-review" "$state/gh.log" \
      || fail "the hand-off label was never applied: $(ghlog)"
    grep -q "duplicated derivation" "$state/pr-edit-body" \
      || fail "the edit did not carry the review's findings: $(cat "$state/pr-edit-body")"

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
    # #248, measured: a rebase while the watch runs moves the pull request's
    # head off the commit this runner pushed, every snapshot answers about a
    # commit this runner has never heard of, and the run that used to end in
    # "nothing has reported" and exit 1 while GitHub was still working. The
    # mismatch persisting a whole first-check window is what tells a moved
    # head from the staleness case above, and the watch follows the new run
    # and hands the ticket over on its verdict - never a hand-back mid-work.
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

    echo "case: a hand-off that could not be written hands the ticket back"
    # The findings are the output of the review stage, and a pull request
    # labelled ready without them would be saying something untrue. So a
    # failed edit is a failed run rather than a quiet one - and the failure is
    # past the push, so the hand-back reaches the pull request too: the same
    # story on both, the pull request left open without the hand-off label,
    # the worktree gone and the branch untouched.
    export GH_PR_EDIT_FAIL=1
    run ci-editfail mixed.json fresh good pass green
    unset GH_PR_EDIT_FAIL
    [ "$rc" -ne 0 ] || fail "a hand-off that never landed was reported as success"
    grep -q "could not be written onto it" "$state/err.log" \
      || fail "did not say the hand-off failed: $(cat "$state/err.log")"
    [ -z "$(worktrees)" ] || fail "the hand-back left its worktree: $(worktrees)"
    [ "$(branches)" = "afk/$ticket" ] \
      || fail "the pushed branch did not survive the hand-back: $(branches)"
    [ "$(pushed)" = "afk/$ticket" ] || fail "the branch left origin: $(pushed)"
    grep -q "gh issue comment 302 " "$state/gh.log" \
      || fail "no comment was left on the ticket: $(ghlog)"
    grep -q "gh pr comment" "$state/gh.log" \
      || fail "the pull request was never told what stopped: $(ghlog)"
    grep -q "gh issue edit 302 .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the ticket was not relabelled: $(ghlog)"
    if grep -qE "pr close|pr merge" "$state/gh.log"; then
      fail "the hand-back closed or merged the pull request: $(ghlog)"
    fi

    echo "case: a pull request that could not be opened hands the ticket back"
    # The branch is pushed by then, so there is no pull request for the
    # hand-back to reach - but the work it holds passed the gate, so the
    # branch stays on origin and locally, with the comment saying a pull
    # request can be opened from it by hand. The worktree is the only thing
    # that goes.
    export GH_PR_FAIL=1
    run raise-prfail mixed.json fresh good pass
    unset GH_PR_FAIL
    [ "$rc" -ne 0 ] || fail "a pull request that was never opened was reported as success"
    grep -q "could not be opened" "$state/err.log" \
      || fail "did not say the pull request failed: $(cat "$state/err.log")"
    grep -q "gh issue comment 302 " "$state/gh.log" \
      || fail "no comment was left on the ticket: $(ghlog)"
    grep -q "gh issue edit 302 .* --add-label agent-stuck" "$state/gh.log" \
      || fail "the ticket was not relabelled: $(ghlog)"
    grep -q "reached origin and is kept there" "$state/stuck-body" \
      || fail "the comment does not say the pushed branch was kept: $(cat "$state/stuck-body")"
    if grep -q "pr comment" "$state/gh.log"; then fail "commented on a pull request that never opened: $(ghlog)"; fi
    [ -z "$(worktrees)" ] || fail "the worktree survived the hand-back"
    [ "$(branches)" = "afk/$ticket" ] \
      || fail "the pushed branch did not survive the hand-back: $(branches)"
    [ "$(pushed)" = "afk/$ticket" ] || fail "the pushed branch left origin: $(pushed)"

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
    # it can be pinned with in one run: the claim swaps the labels on the
    # pull request itself, the session is fed the reviewer's comments and
    # nothing else, the commit lands on the pull request's branch, the
    # round comment says what was addressed, and the hand-off label comes
    # back in one edit once CI is green.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-comments.json"
    export GH_INLINE="$work/fixtures/revise-inline.json"
    export REVISE_SETUP=1
    run revise-clean none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS GH_INLINE REVISE_SETUP
    [ "$rc" -eq 0 ] || fail "a revisable pull request did not finish: $(cat "$state/err.log")"
    # The claim, one edit on the pull request, never on the issue.
    grep -q "gh pr edit 999 .* --remove-label agent-revise --add-label agent-working" "$state/gh.log" \
      || fail "the pull request was not claimed with the documented convention: $(ghlog)"
    if grep -q "gh issue edit 302 " "$state/gh.log"; then fail "the revision lane touched the issue: $(ghlog)"; fi
    [ "$(revise_attempts)" -eq 1 ] || fail "expected one revision session, got $(revise_attempts)"
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
    # And the advisory findings did not: the body is never requested.
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
    # the rounds from.
    grep -q "gh pr comment 999 " "$state/gh.log" || fail "no round comment was posted: $(ghlog)"
    grep -q "revision round 1 of 3" "$state/pr-comment-body" \
      || fail "the round comment does not name itself, so the next poll cannot count it: $(cat "$state/pr-comment-body")"
    grep -q "Addressed the review comment" "$state/pr-comment-body" \
      || fail "the session's own report did not travel to the pull request"
    grep -q "Not addressed: nothing." "$state/pr-comment-body" \
      || fail "the report's other half - what the round did not address - did not travel: $(cat "$state/pr-comment-body")"
    # Handed back to the reviewer in one edit, with the notification.
    grep -q "gh pr edit 999 .* --remove-label agent-working --add-label agent-ready-for-review" "$state/gh.log" \
      || fail "the hand-off label did not go back on: $(ghlog)"
    [ "$(ntfy_posts)" -eq 1 ] || fail "a revised pull request published $(ntfy_posts) notification(s): $(ntfylog)"
    grep -qF -- "-H Title: AFK agent: PR revised (#999)" "$state/ntfy.log" \
      || fail "the revision notification was not named: $(ntfylog)"
    [ -z "$(worktrees)" ] || fail "a revised pull request left its worktree: $(worktrees)"
    [ "$(branches)" = "afk/$ticket" ] || fail "the branch was disturbed: $(branches)"

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
    # advisory findings quoted in the body it never reads - would be an
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

    echo "case: a fourth revision round does not run; the pull request goes to the stuck path"
    # Three round comments on the pull request and a reviewer still
    # waiting: the budget is read from the tracker - the runner has no
    # memory between runs - and the stuck path reaches the pull request
    # itself, since that is where the reviewer is.
    export GH_PRS="$work/fixtures/revise-pr.json"
    export GH_PR_COMMENTS="$work/fixtures/revise-exhausted.json"
    run revise-exhausted none.json fresh good pass green
    unset GH_PRS GH_PR_COMMENTS
    [ "$rc" -ne 0 ] || fail "a spent budget was reported as a quiet poll"
    [ "$(revise_attempts)" -eq 0 ] || fail "a fourth revision session ran"
    grep -q "gh pr edit 999 .* --remove-label agent-revise --add-label agent-stuck" "$state/gh.log" \
      || fail "the pull request was not relabelled to the stuck label: $(ghlog)"
    grep -q "gh pr comment 999 " "$state/gh.log" || fail "the hand-back never reached the pull request: $(ghlog)"
    grep -q "will not start another round" "$state/pr-comment-body" \
      || fail "the comment does not say what re-applying the label would do: $(cat "$state/pr-comment-body")"
    [ "$(ntfy_posts)" -eq 1 ] || fail "a stuck pull request published $(ntfy_posts) notification(s): $(ntfylog)"
    grep -qF "Pull request: https://github.com/corygyarmathy/dotfiles/pull/999" "$state/ntfy.log" \
      || fail "the stuck notification did not point at the pull request: $(ntfylog)"

    echo "case: a round is fed only the comments its watermark has not seen"
    # Round 2 of a review: the comment the first round already addressed is
    # not an instruction any more, and re-feeding it would spend the round
    # re-answering it. Only what the reviewer wrote after the last round
    # comment crosses.
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
    # Exactly one pull request comment: the hand-back's, not a round
    # comment for a push that never happened.
    [ "$(grep -c "gh pr comment" "$state/gh.log")" -eq 1 ] \
      || fail "a round comment was posted for a push that never happened: $(ghlog)"
    grep -q "gh pr edit 999 .* --remove-label agent-working --add-label agent-stuck" "$state/gh.log" \
      || fail "the pull request was not relabelled on the stuck path: $(ghlog)"
    grep -q "Nothing was pushed" "$state/pr-comment-body" \
      || fail "the hand-back does not say what state it left: $(cat "$state/pr-comment-body")"

    echo "case: a revision run that died mid-round has its claim undone by the guard"
    # The revision lane's claim lives on the pull request - the ticket
    # lane's lives on the issue - so a dead revision run leaves exactly one
    # fingerprint: an open pull request carrying `agent-working` beside a
    # leftover worktree. The guard swaps the labels back, so the reviewer's
    # trigger label survives a run that did not, and the next ticket is
    # never blocked by it.
    run revise-guard mixed.json fresh good pass green
    git -C "$state/checkout" worktree add "$state/worktrees/$ticket" "afk/$ticket"
    export GH_PR_OPEN=1 GH_PR_CLAIMED=1
    run revise-guard second-ticket.json reuse
    unset GH_PR_OPEN GH_PR_CLAIMED
    [ "$rc" -eq 0 ] || fail "the poll after a dead revision run refused to start: $(cat "$state/err.log")"
    grep -q "gh pr edit 999 .* --remove-label agent-working --add-label agent-revise" "$state/gh.log" \
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
