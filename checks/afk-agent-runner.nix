# checks/afk-agent-runner.nix
#
# The AFK runner's poll -> denylist -> claim -> isolate logic (#171), tested at
# the level it actually lives at.
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

    # The runner asserts these are on its PATH before it does anything. Nothing
    # here invokes them, so a stub that exists is the whole requirement - and
    # is a great deal cheaper than putting a real `nix` in a test closure.
    for stub in opencode nix; do
      printf '#!/bin/sh\nexit 0\n' > "$work/bin/$stub"
    done

    chmod +x "$work/bin"/*
    export PATH="$work/bin:$PATH"

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

    run() {
      local name=$1 fixture=$2 reuse=''${3:-fresh}
      state="$work/state/$name"
      if [ "$reuse" = "fresh" ]; then rm -rf "$state"; fi
      mkdir -p "$state"

      export AFK_STATE_DIR="$state"
      export GH_ISSUES="$work/fixtures/$fixture"
      export GH_LOG="$state/gh.log"
      : > "$GH_LOG"

      set +e
      "$script" > "$state/out.log" 2> "$state/err.log"
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
    if grep -qE 'gh[[:space:]]+pr[[:space:]]+merge|--auto' "$script"; then
      fail "the runner can merge its own pull request"
    fi

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
