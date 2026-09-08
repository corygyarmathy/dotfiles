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
# itself is item 5, and lands in pieces: this file carries poll -> denylist ->
# claim -> isolate (#171), and the implement stage on top of it (#172). It
# stops with a ticket claimed and a gate-passing commit on an `afk/*` branch.
# The review stage (#173), the push and PR (#174) and the stuck path that
# cleans up after a failure (#175) each extend the same script.
#
# Nothing here pushes, opens a pull request, or writes to the tracker past the
# claim. That is not an omission: those verbs belong to the stages above, and
# the implement session is denied them (`permissionOverlay`) rather than merely
# asked not to use them.
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

  # The model and reasoning effort item 1's pilot settled on, over
  # `deepseek-v4-pro` and `deepseek-v4-flash`: cheapest per converged run by
  # 15-25x, 6/6 convergence, first and third of six candidates in the blind
  # ranking, and the only arm to get the holdout's edge case right. `high` over
  # `low` or `max` because correctness did not vary across the three - the
  # variant moved scope, not accuracy - and `high` is what the ranking and the
  # holdout were actually run against. `deepseek-v4-pro` is the recorded
  # fallback if this ever regresses. Plain bindings rather than options for the
  # same reason `repository` above is one: one fleet, one value, and swapping
  # them is a text edit rather than a configuration a host supplies.
  model = "opencode-go/glm-5.3-flash";
  variant = "high";

  # Who the commits are by. ADR 0004 §4 rules out a second GitHub account, so
  # everything this pipeline produces - the branch, the PR, and the commits on
  # it - is already attributable to one person; naming that person here is what
  # makes the commits match the PR that carries them rather than an accident of
  # whatever git could infer.
  #
  # It has to be said explicitly because git cannot infer it. The unit runs
  # with `environment.HOME` pointed at its StateDirectory and no XDG variables
  # set, so there is no global config to read, and git's fallback - username at
  # hostname - is refused as an author identity on a host whose hostname has no
  # domain. Left unset, every attempt commits nothing, and the retry budget is
  # spent three times over on the same error.
  commitName = "Cory Gyarmathy";
  commitEmail = "cory.gyarmathy@gmail.com";

  # ADR 0004 §6's retry budget, whose number plan item 5 owns: two retries,
  # three attempts. At the pilot's measured 4-6 cents per attempt this cannot
  # meaningfully threaten OpenCode Go's $12-per-5-hours cap, which is the only
  # constraint that would argue for a smaller one.
  maxAttempts = 3;

  # Per-attempt ceiling. Every converged pilot run finished inside 12-36
  # minutes; the one run that reached 3600s had made no progress at all, so a
  # longer ceiling buys nothing a retry would not buy better. It exists so that
  # a stuck attempt fails the runner's own way - countable, and about to become
  # item 8's stuck path - rather than by systemd killing the unit mid-ticket
  # and leaving behind the worktree the in-flight guard above then trips over.
  # `maxRuntime` has to stay clear of maxAttempts * this, plus the gate.
  attemptTimeout = 3600;

  # Ceiling on one run of the gate, for the same reason `attemptTimeout` exists
  # and pointed at the other half of an attempt. Without it the arithmetic
  # under `maxRuntime` is not arithmetic at all: three serial `nix flake
  # check`s and three sets of host builds have no bound, so a slow gate reaches
  # `TimeoutStartSec` and systemd kills the unit mid-ticket - which is exactly
  # the outcome the per-attempt ceiling exists to avoid. A gate that runs long
  # is instead one failed attempt, countable and retried.
  #
  # Most of what it runs substitutes from the cache CI pushes to, so this is
  # generous rather than tight; if it is ever hit routinely that is a fact
  # about the gate worth knowing, not a number to raise reflexively.
  gateTimeout = 2700;

  # How much of a failing gate's output is handed back on a retry. The gate
  # logs a whole `nix flake check`, and the part that says what went wrong is
  # at the end of it.
  gateTailLines = 200;

  # The instructions the session is opened with: item 1's frozen pilot prompt,
  # which was written to become this, plus the two things the pilot found were
  # missing from it - the `ci.yml` matrix exception, without which "follow the
  # checks/ pattern" is advice that cannot pass CI, and the failure reasons its
  # own runs kept reproducing.
  #
  # A file in the store rather than anything the script quotes. Prose this
  # shape does not survive being a shell literal: backticks inside single
  # quotes fail shellcheck, and a heredoc's terminator inside a Nix indented
  # string is coupled to Nix's dedent rule, so an edit to the prose can break
  # the script without looking like it could. `ISSUE` is substituted at run
  # time; nothing else in it varies.
  implementPrompt = pkgs.writeText "afk-agent-implement-prompt" ''
    Implement GitHub issue #ISSUE in this repository.

    Use the `implement` skill, by name - call it rather than improvising
    something equivalent. Read the ticket first: `gh issue view ISSUE`.

    Scope:

    - Work only inside this directory. Do not read, write or reason about any
      checkout above or beside it.
    - Do not touch `secrets/`, `.sops.yaml`, or anything under
      `.github/workflows/` - with exactly one exception. If your change adds a
      file under `checks/`, add that check's name to
      `jobs.checks.strategy.matrix.check` in `.github/workflows/ci.yml` and
      change nothing else in that file: no other key, no existing entry
      altered or removed. The name must match ^[a-z][a-z0-9-]*$ and must be a
      check the flake actually exposes. A new check that is not in that matrix
      never runs, and CI fails the build for saying so.
    - Do not push, do not open a pull request, and do not edit, close or
      comment on the issue. Later stages do all of that.
    - Do not run `code-review`. Review is a separate pass, in its own context,
      after this one.
    - Commit your work to this branch before you finish. Uncommitted work does
      not exist: the next stage pushes commits, and nothing else.

    The gate your work has to pass is this repository's own: `nix fmt -- --ci`,
    `nix flake check`, a build of every host, and agreement between the checks
    the flake exposes and the matrix in `ci.yml`. `AGENTS.md` is the rest of
    the house style. You will be told what the gate said and given two further
    attempts to fix it.

    Five ways real runs of this pipeline have produced work that looked
    finished and was not. They are measured, not hypothetical:

    - Sourcing a value from the right file is not the same as sourcing a value
      the consuming format can parse. Render the output and read it against
      the grammar of the tool that consumes it.
    - An invariant explained correctly in a comment is not an invariant
      enforced in the right place. Check where the code runs, not what the
      prose beside it claims.
    - "I verified this" is a claim to check, not a fact. Re-run the thing.
    - A discrepancy noticed mid-run is routinely lost by the time the closing
      summary is written. Derive that summary from what you did, not from what
      the ticket said before you started.
    - Narrow scope wins. A check that needs no separate script or package
      beats a wider one that is equally correct.
  '';

  # What the implement session may not do, denied through OpenCode's own
  # permission layer rather than only asked for in the prompt. The pilot
  # verified that an inline `OPENCODE_CONFIG_CONTENT` merges after the
  # repository's own rules and that last match wins, so these take effect.
  #
  # It is a soft control - a pattern match on a command line, not a capability
  # boundary - and this process holds a PAT that can push. That is why the
  # `enable` option below says to leave the service off until item 7 (#174)
  # lands the gate that reads the diff itself.
  permissionOverlay = builtins.toJSON {
    permission.bash = {
      "git push*" = "deny";
      "gh pr*" = "deny";
      "gh issue edit*" = "deny";
      "gh issue close*" = "deny";
      "gh issue comment*" = "deny";
    };
  };

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

      # Exported rather than written into the checkout's config, so that it
      # covers every `git` the agent runs as well as every one this script
      # runs, and so that nothing has to be undone if a worktree outlives the
      # run that made it.
      export GIT_AUTHOR_NAME=${lib.escapeShellArg commitName}
      export GIT_AUTHOR_EMAIL=${lib.escapeShellArg commitEmail}
      export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
      export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

      # OpenCode reads its provider credentials from a file under the data
      # directory, not from the environment, and this account has never run
      # `opencode auth login` - the pilot ran as a person who had. So the
      # credential item 11 hands over is written into the shape opencode looks
      # for, on every run rather than once, so that a rotated secret takes
      # effect at the next poll rather than at whatever point somebody
      # remembers this file exists. 0600 through the unit's UMask, under
      # StateDirectory 0700; the value is never echoed.
      #
      # `opencode-username` is deliberately not wired to anything. Nothing on
      # the headless path consumes it - not `opencode run`, not `opencode
      # session`, not `opencode export`; the `--username` flag belongs to
      # `--attach`, which this never uses. It stays declared and asserted
      # because item 4 recorded it as a question rather than a decision, and
      # dropping a credential a later stage might want is the harder mistake to
      # undo. Plan item 5 says where to drop it once somebody confirms.
      auth_dir="$state_dir/.local/share/opencode"
      mkdir -p "$auth_dir"
      jq -n --arg key "$(cat "$creds/opencode-api-key")" \
        '{"opencode-go": {type: "api", key: $key}}' > "$auth_dir/auth.json"

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

      # --- implement, on a bounded retry budget -----------------------------
      #
      # ADR 0004 §6: a retry happens *inside* the session that produced the
      # failure, because a retry that cannot see what it is retrying against is
      # close to useless. `opencode run --session` is what makes that literal.
      # The model keeps its own transcript, so the only thing this has to hand
      # back across the boundary is the verdict it could not see for itself:
      # this repository's gate, and what it said.
      #
      # Three attempts, two retries. The budget lives in plan item 5 rather
      # than in the ADR because it is a cost parameter, not a decision: at the
      # pilot's measured 4-6 cents per attempt, three of them cannot
      # meaningfully threaten OpenCode Go's $12-per-5-hours cap.
      #
      # Nothing here is written inside the worktree. A prompt or a log that
      # landed there would show up in the diff being gated, and then in the
      # pull request.
      run_dir="$state_dir/run"
      rm -rf "$run_dir"
      mkdir -p "$run_dir"

      sed "s/ISSUE/$number/g" ${implementPrompt} > "$run_dir/prompt"

      export OPENCODE_CONFIG_CONTENT=${lib.escapeShellArg permissionOverlay}

      # The gate. Deliberately this repository's own CI gate rather than a
      # cheaper proxy: the entire value of an unattended runner is that it does
      # not hand a human a red pull request, and an attempt costs cents.
      #
      # `nix flake check` and the host builds are CI's `checks` and `build`
      # matrices. The checks-versus-matrix audit is CI's lint job, reproduced
      # here because it is the one gate `nix flake check` cannot see: adding
      # `checks/foo.nix` without adding `foo` to ci.yml's hand-written matrix
      # passes every Nix-level check and still fails CI. The pilot found exactly
      # that, on a diff that was otherwise correct (plan item 1, the
      # review-stage finding), and it is why the prompt above carries the narrow
      # ci.yml exception docs/agents/afk-eligibility.md defines.
      #
      # Reproducing a CI step here can drift from the step it copies. That drift
      # is visible rather than silent - it shows up as a branch that is green
      # here and red on the pull request - which is the acceptable direction for
      # it to fail, and there is no way to invoke a GitHub Actions step from
      # outside GitHub Actions.
      #
      # Whether the ci.yml exception was *honoured* - a diff that adds matrix
      # entries and does nothing else - is a different question, asked of the
      # diff before the push, and belongs to item 7 (#174).
      #
      # Hosts are discovered from the branch under test rather than listed, so a
      # ticket that adds a host is gated on the host it added. CI names them by
      # hand because discovery would cost it a serialised job ahead of a
      # parallel matrix; nothing here is parallel, so nothing here pays for it.
      #
      # Every step ends in `|| exit 1` instead of leaning on `set -e`, and that
      # is load-bearing rather than belt-and-braces. Bash switches errexit off
      # inside any command used as a condition, and it stays off all the way
      # down - through the function, through the subshell, past an explicit
      # `set -e` written inside that subshell. The only place this is ever
      # called from is `if ! gate`, so written the obvious way it would run
      # every step, ignore every failure, and return the status of the last one:
      # a `for` loop over a host list that the failed discovery step above it
      # left empty, which is to say success. A gate that passes because
      # everything before it failed is the exact shape of a gate that has
      # stopped gating, and it was a check expecting a retry and getting none
      # that found it, not reading the code.
      gate() {
        (
          cd "$worktree" || exit 1
          set -x

          # One deadline for the whole gate, rather than a ceiling on each
          # step. Per-step ceilings multiply where this adds, and what has to
          # fit under `maxRuntime` is three attempts *and* three gates, not any
          # single command. `step` spends whatever is left of the budget on the
          # command it is given, and refuses once there is none.
          SECONDS=0
          step() {
            local left=$(( ${toString gateTimeout} - SECONDS ))
            [ "$left" -gt 0 ] || return 1
            timeout "$left" "$@"
          }

          step nix fmt -- --ci || exit 1

          step nix eval --raw .#checks.x86_64-linux \
            --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)' \
            | LC_ALL=C sort > "$run_dir/flake-checks" || exit 1
          step yq -r '.jobs.checks.strategy.matrix.check[]' .github/workflows/ci.yml \
            | LC_ALL=C sort > "$run_dir/matrix-checks" || exit 1
          step diff -u "$run_dir/flake-checks" "$run_dir/matrix-checks" || exit 1

          step nix flake check || exit 1

          local hosts
          hosts="$(step nix eval --raw .#nixosConfigurations \
            --apply 'cs: builtins.concatStringsSep " " (builtins.attrNames cs)')" || exit 1
          read -r -a host_list <<<"$hosts"
          # A discovery that came back with nothing is a gate that built
          # nothing, which must not read as a gate that passed.
          [ "''${#host_list[@]}" -gt 0 ] || exit 1
          for host in "''${host_list[@]}"; do
            step nix build --no-link \
              ".#nixosConfigurations.$host.config.system.build.toplevel" || exit 1
          done
        ) > "$run_dir/gate.log" 2>&1
      }

      attempt=1
      session=""
      message="$(cat "$run_dir/prompt")"

      while :; do
        log "#$number: implement attempt $attempt of ${toString maxAttempts}"

        # `--title` on the first attempt is what makes the session findable
        # again; `--session` on every attempt after it is ADR 0004 §6.
        opencode_args=(--agent build --model ${model} --variant ${variant})
        if [ -n "$session" ]; then
          opencode_args+=(--session "$session")
        else
          opencode_args+=(--title "$slug")
        fi

        # `|| exit 1` on the `cd` for the same reason as in the gate: this
        # subshell is the left side of a `||`, so errexit is off inside it, and
        # a failed `cd` would otherwise run the session against whatever
        # directory the runner happened to be in.
        attempt_rc=0
        (
          cd "$worktree" || exit 1
          timeout ${toString attemptTimeout} opencode run --auto "''${opencode_args[@]}" "$message"
        ) || attempt_rc=$?

        # Four ways an attempt fails, in the order they can be told apart. The
        # middle two are not defensive padding: the pilot measured runs that
        # exited 0 having explained what they would do rather than doing it, and
        # work left in the working tree is work that the push in item 7 (#174)
        # would silently drop.
        reason=""
        committed="$(git -C "$worktree" rev-list --count "origin/$base_branch..HEAD")"
        if [ "$attempt_rc" -eq 124 ]; then
          reason="it ran past its ${toString attemptTimeout}s ceiling and was stopped"
        elif [ "$attempt_rc" -ne 0 ]; then
          reason="opencode exited $attempt_rc"
        elif [ "$committed" -eq 0 ]; then
          reason="nothing was committed to $branch"
        elif [ -n "$(git -C "$worktree" status --porcelain)" ]; then
          reason="$(printf 'work was left uncommitted:\n%s' \
            "$(git -C "$worktree" status --porcelain)")"
        elif ! gate; then
          reason="$(printf 'the gate failed. Its last ${toString gateTailLines} lines:\n\n%s' \
            "$(tail -n ${toString gateTailLines} "$run_dir/gate.log")")"
        fi

        if [ -z "$reason" ]; then
          log "#$number: implemented on $branch, in $attempt attempt(s)"
          break
        fi

        log "#$number: attempt $attempt did not pass, because $reason"

        if [ "$attempt" -ge ${toString maxAttempts} ]; then
          die "#$number: ${toString maxAttempts} attempts and no passing implementation; handing the ticket back is the stuck path, item 8 (#175)"
        fi

        # Read back once and then reused: the id does not change, and
        # `session list` is a question with a cost.
        if [ -z "$session" ]; then
          session="$(
            cd "$worktree" \
              && opencode session list -n 20 --format json \
              | jq -r --arg t "$slug" 'map(select(.title == $t)) | .[0].id // empty'
          )"
        fi

        # Whether there is a session to continue decides both what the next
        # attempt is addressed to and what it is told, and the two have to move
        # together: a fresh session handed a message about a failure it cannot
        # see would be worse than either.
        #
        # The messages are built with printf rather than written as literals
        # spanning lines. A continuation line would have to start in column 0
        # to keep the script's own indentation out of the text, and a column-0
        # line inside a Nix indented string collapses the dedent for the whole
        # script - which is not theoretical, it happened while writing this.
        if [ -n "$session" ]; then
          log "#$number: retrying inside session $session"
          message="$(printf '%s\n\n%s' \
            "Attempt $attempt of ${toString maxAttempts} did not pass, because $reason" \
            "Fix that here, in this worktree, and commit the fix. The gate is the only thing that decides whether this ticket is done.")"
        elif [ "$attempt_rc" -eq 0 ] || [ "$committed" -gt 0 ]; then
          # An attempt that exited cleanly, or committed, plainly had a session.
          # Not being able to find it means the next attempt would re-read the
          # ticket in a fresh context with no idea what just failed, which is
          # the degrade ADR 0004 §6 rules out rather than a lesser form of it.
          die "#$number: attempt $attempt ran, but no session titled '$slug' can be found to continue; refusing to retry in a fresh context (ADR 0004 §6)"
        else
          # Nothing to continue, and nothing lost by not continuing: the attempt
          # failed before it opened a session, so there is no transcript for a
          # retry to carry. The next one is the first real attempt rather than a
          # context-free retry, so it gets the original prompt back.
          log "#$number: attempt $attempt opened no session; the next one starts one"
          message="$(cat "$run_dir/prompt")"
        fi

        attempt=$((attempt + 1))
      done

      log "stopping here: the review stage is item 6 (#173) and is not wired in yet"
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
      default = "6h";
      example = "90min";
      description = ''
        Ceiling on a single run, as `TimeoutStartSec` (systemd.time(7)).

        This is not decoration. A `oneshot` unit defaults to a 90-second start
        timeout, which would kill every real run: the pilot measured 15-60
        minutes per `opencode run`, and the implement stage allows two retries
        on top of that. The ceiling still has to exist, because concurrency
        here is one unit - a run that hangs blocks every later poll until
        something stops it, and "something" should not have to be a person.

        The default has to clear three attempts at their own hour-long ceiling
        with a gate after each, which is why it is no longer the 4h item 4
        guessed at before the implement stage existed. It is the outer bound
        rather than an expected duration: a run that reaches it is killed
        mid-ticket and leaves a worktree behind, which the in-flight guard then
        refuses to poll past until item 8 (#175) can clear it.
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
