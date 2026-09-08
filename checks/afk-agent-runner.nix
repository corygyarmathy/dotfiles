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

    # --- the fixture the runner clones -----------------------------------
    #
    # A real repository, so `git worktree add -b afk/<slug> <path>
    # origin/master` either produces a branch and a checked-out tree or fails
    # for a reason worth knowing about.
    mkdir -p "$work/seed"
    (
      cd "$work/seed"
      git init -q -b master
      echo "fixture" > README.md
      git add README.md
      git commit -qm "seed"
    )
    git clone -q --bare "$work/seed" "$work/origin.git"
    export AFK_REPO_URL="file://$work/origin.git"

    # --- the credentials item 4 hands over -------------------------------
    mkdir -p "$work/creds"
    echo "not-a-real-token" > "$work/creds/github-token"
    echo "not-a-real-key"   > "$work/creds/opencode-api-key"
    echo "not-a-real-user"  > "$work/creds/opencode-username"
    export CREDENTIALS_DIRECTORY="$work/creds"

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
    case "$1 $2" in
      "issue list")
        cat "$GH_ISSUES"
        ;;
      "issue edit")
        if [ -n "''${GH_EDIT_FAIL:-}" ]; then
          echo "mock gh: refusing to assign" >&2
          exit 1
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
    cat > "$work/bin/opencode" <<'MOCK'
    #!/bin/sh
    case "$1" in
      run)
        n=$(( $(cat "$OC_STATE/attempts" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$OC_STATE/attempts"
        printf '%s\n' "$@" > "$OC_STATE/args-$n"
        printf '%s\n' "''${OPENCODE_CONFIG_CONTENT:-}" > "$OC_STATE/overlay-$n"
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
          *)      echo "mock opencode: no plan step $n" >&2; exit 64 ;;
        esac
        # The title is taken from whichever attempt first opened a session, and
        # kept: a retry is addressed by id and carries no title of its own.
        if [ "$opened" = yes ] && [ ! -s "$OC_STATE/title" ]; then
          sed -n '/^--title$/{n;p;q}' "$OC_STATE/args-$n" > "$OC_STATE/title"
        fi
        ;;
      session)
        # An empty list until some attempt has actually opened one, so the
        # runner's two no-session paths - start a fresh one, or refuse - are
        # both reachable from here.
        if [ -s "$OC_STATE/title" ]; then
          printf '[{"id":"ses_fixture","title":"%s"}]\n' "$(cat "$OC_STATE/title")"
        else
          printf '[]\n'
        fi
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
      esac
    fi
    exit 0
    MOCK

    # Prints nothing, so the flake's checks and ci.yml's matrix compare equal
    # and that half of the gate passes. Logged, because "the gate read ci.yml
    # at all" is the assertion, not what it found there.
    cat > "$work/bin/yq" <<'MOCK'
    #!/bin/sh
    printf '%s\n' "yq $*" >> "$NIX_LOG"
    MOCK

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

    cat > "$work/fixtures/second-ticket.json" <<'JSON'
    [
      { "number": 330, "title": "A different ticket", "body": "Nothing denied.",
        "assignees": [], "blockedBy": { "nodes": [], "totalCount": 0 } }
    ]
    JSON

    # --- the harness ------------------------------------------------------
    #
    # Each case gets its own state directory unless it deliberately inherits
    # one, because the runner's own memory between polls *is* that directory.
    state=""
    rc=0

    # `plan` is one opencode step per attempt, defaulting to a single clean
    # one so that every case written before the implement stage existed still
    # reads as "the ticket got worked".
    run() {
      local name=$1 fixture=$2 reuse=''${3:-fresh} plan=''${4:-good}
      state="$work/state/$name"
      if [ "$reuse" = "fresh" ]; then rm -rf "$state"; fi
      mkdir -p "$state"

      export AFK_STATE_DIR="$state"
      export GH_ISSUES="$work/fixtures/$fixture"
      export GH_LOG="$state/gh.log"
      export OC_STATE="$state"
      export OC_PLAN="$state/opencode.plan"
      export NIX_LOG="$state/nix.log"
      : > "$GH_LOG"
      : > "$NIX_LOG"
      rm -f "$state"/args-* "$state"/overlay-* "$state/attempts" "$state/title"
      # Unquoted on purpose: a plan is a whitespace-separated list of steps and
      # this is what turns it into one line each.
      # shellcheck disable=SC2086
      printf '%s\n' $plan > "$OC_PLAN"

      set +e
      PATH="$unit_path" "$script" > "$state/out.log" 2> "$state/err.log"
      rc=$?
      set -e
    }

    ghlog() { cat "$state/gh.log"; }
    claims() { grep -c "issue edit" "$state/gh.log" || true; }
    worktrees() { find "$state/worktrees" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort; }
    # Scoped to refs/heads/afk: the clone brings its own `master` along, and
    # what is under test is which branch the runner cut, not that a clone has
    # the branch it was cloned from.
    branches() { git -C "$state/checkout" for-each-ref --format='%(refname:short)' refs/heads/afk 2>/dev/null | sort; }
    attempts() { cat "$state/attempts" 2>/dev/null || echo 0; }
    # Every case below that reaches the implement stage runs `mixed.json`, which
    # claims #302; this is the worktree that ticket lands in.
    ticket=302-unblocked-at-last

    echo "case: the plumbing is asserted before anything is polled"
    run plumbing none.json
    [ "$rc" -eq 0 ] || fail "an empty tracker should be a quiet success, got $rc: $(cat "$state/err.log")"
    for credential in github-token opencode-api-key opencode-username; do
      grep -q "credential '$credential' present" "$state/out.log" \
        || fail "$credential was not asserted before the poll"
    done
    for tool in git gh opencode nix jq; do
      grep -q "tool '$tool' present" "$state/out.log" || fail "$tool was not asserted before the poll"
    done
    [ "$(claims)" -eq 0 ] || fail "claimed something from an empty tracker"

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
    grep -q "gh issue edit 302 .* --add-assignee @me" "$state/gh.log" \
      || fail "did not claim #302 with the documented convention: $(ghlog)"
    # The three it must not have touched, each for its own reason: assigned,
    # open blocker, and simply later in the queue.
    for skipped in 300 301 303; do
      if grep -q "gh issue edit $skipped " "$state/gh.log"; then fail "claimed #$skipped"; fi
    done
    [ "$(worktrees)" = "302-unblocked-at-last" ] || fail "worktree not isolated: $(worktrees)"
    [ "$(branches)" = "afk/302-unblocked-at-last" ] || fail "branch not cut: $(branches)"
    # An isolated worktree, not just a directory: a real checkout of the base
    # branch, on its own branch, with nothing of the seed's history missing.
    [ -f "$state/worktrees/302-unblocked-at-last/README.md" ] \
      || fail "the worktree has no working tree"
    head="$(git -C "$state/worktrees/302-unblocked-at-last" rev-parse --abbrev-ref HEAD)"
    [ "$head" = "afk/302-unblocked-at-last" ] || fail "worktree is on $head"
    # And with no upstream. `git worktree add -b <b> <path> origin/master`
    # tracks origin/master unless told not to, which would make #174's push -
    # under git's default push.default of `simple` - aim at master. Nothing
    # else in this pipeline would notice before the push was attempted.
    upstream="$(git -C "$state/checkout" for-each-ref \
      --format='%(upstream:short)' refs/heads/afk/302-unblocked-at-last)"
    [ -z "$upstream" ] || fail "the ticket branch tracks $upstream"

    echo "case: a ticket whose scope names a denied path is refused before the claim"
    run denied-then-clean denied-then-clean.json
    [ "$rc" -eq 0 ] || fail "the fall-through should succeed, got $rc: $(cat "$state/err.log")"
    if grep -q "gh issue edit 310 " "$state/gh.log"; then fail "claimed a denylisted ticket"; fi
    grep -q "skipping #310" "$state/out.log" || fail "the rejection was not reported"
    grep -q "gh issue edit 311 " "$state/gh.log" || fail "did not fall through to the clean ticket"
    [ "$(worktrees)" = "311-clean-follow-up" ] || fail "isolated the wrong ticket: $(worktrees)"

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

    echo "case: a clean first attempt is one attempt, and the gate is what says so"
    run implement-first mixed.json fresh good
    [ "$rc" -eq 0 ] || fail "a converging ticket exited $rc: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 1 ] || fail "expected one attempt, got $(attempts)"
    grep -qx -- --title "$state/args-1" || fail "the first attempt did not title its session"
    if grep -qx -- --session "$state/args-1"; then
      fail "the first attempt continued a session that cannot exist yet"
    fi
    [ "$(git -C "$state/worktrees/$ticket" rev-list --count origin/master..HEAD)" -eq 1 ] \
      || fail "no commit landed on the ticket branch"
    # The gate is this repository's own gate, not a cheaper proxy standing in
    # for it. Each of these is a CI job that would otherwise go red on a branch
    # this stage had already called finished.
    grep -q -- "nix fmt -- --ci" "$state/nix.log" || fail "the gate does not check formatting"
    grep -q -- "nix flake check" "$state/nix.log" || fail "the gate does not run the checks"
    grep -q "nixosConfigurations.fixturehost.config.system.build.toplevel" "$state/nix.log" \
      || fail "the gate did not build the hosts it discovered: $(cat "$state/nix.log")"
    # The one gate `nix flake check` cannot see: a check added under checks/
    # without a matching entry in ci.yml's hand-written matrix passes every
    # Nix-level check and still fails CI (plan item 1, review-stage finding).
    grep -q "checks.x86_64-linux" "$state/nix.log" || fail "the gate did not read the flake's checks"
    grep -q "^yq " "$state/nix.log" || fail "the gate did not read ci.yml's matrix"
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
    [ "$(git -C "$state/worktrees/$ticket" diff --name-only origin/master..HEAD)" = "fix-1.txt" ] \
      || fail "the branch carries more than the work: $(git -C "$state/worktrees/$ticket" diff --name-only origin/master..HEAD)"

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
    awk '/^--session$/{getline; print; exit}' "$state/args-2" | grep -qx ses_fixture \
      || fail "the retry continued a session other than the one that failed"
    if grep -qx -- --title "$state/args-2"; then fail "the retry titled a second session"; fi
    grep -q "the gate failed" "$state/args-2" || fail "the retry was not told what the gate said"

    echo "case: a ticket that only converges on the third attempt still converges"
    run implement-third mixed.json fresh "broken broken repair"
    [ "$rc" -eq 0 ] || fail "exited $rc on the third attempt: $(cat "$state/err.log")"
    [ "$(attempts)" -eq 3 ] || fail "expected three attempts, got $(attempts)"

    echo "case: the loop stops after two retries rather than running on"
    # The bound, and the reason this file exists at all for the implement stage:
    # nothing else distinguishes a loop that is still trying from one that will
    # never stop, and each turn of it spends money against OpenCode Go's cap.
    run implement-exhausted mixed.json fresh "broken broken broken"
    [ "$rc" -ne 0 ] || fail "a ticket that never passed the gate was reported as done"
    [ "$(attempts)" -eq 3 ] || fail "expected exactly three attempts, got $(attempts)"
    grep -q "3 attempts" "$state/err.log" || fail "did not say the budget ran out: $(cat "$state/err.log")"

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
    if grep -q "nix build" "$state/nix.log"; then fail "something was built from an empty host list"; fi

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

    echo "case: one ticket at a time - a live worktree stops the next poll"
    # Reusing the state the `mixed` case left behind: #302 is claimed and its
    # worktree is on disk. systemd cannot prevent this on its own - two runs
    # never overlap, but a run that died leaves exactly this behind - so the
    # runner has to refuse, loudly, rather than start a second ticket beside it.
    run mixed second-ticket.json reuse
    [ "$rc" -ne 0 ] || fail "started a second ticket while one was still in flight"
    [ "$(claims)" -eq 0 ] || fail "claimed #330 with #302 unfinished: $(ghlog)"
    grep -qi "still here" "$state/err.log" || fail "did not say why it refused: $(cat "$state/err.log")"
    [ "$(worktrees)" = "302-unblocked-at-last" ] || fail "the in-flight worktree was disturbed"

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
