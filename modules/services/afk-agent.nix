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
# itself is item 5, and landed in pieces: poll -> denylist -> claim -> isolate
# (#171), the implement stage on top of it (#172), the review stage after that
# (#173, item 6), the push and pull request that end a run (#174, item 7), the
# reorder that put them in the order below (#201, item 13), and the
# notifications that tell a person not watching GitHub how it ended (#176,
# item 9).
#
# THE ORDER IS THE POINT OF #201, so it is worth reading once in full:
#
#   claim -> isolate -> implement until the local gate agrees
#     -> denylist gate on the diff -> push -> open the pull request
#     -> watch its CI -> feed a red run back into the implement session
#        and push the fix to the same branch, up to a bounded number of rounds
#     -> review in a fresh context
#     -> write the findings onto the pull request and label it
#     -> tear the worktree down
#
# It used to be implement -> review -> push -> pull request, which was decided
# when the review was a gate. Item 6 measured that gate away, so the ordering
# it forced was inheritance. ADR 0007 settles the replacement: CI is the
# correctness gate, the review is a quality pass, and the review runs after the
# push - which makes it structurally unable to change what is in the pull
# request rather than merely denied the verbs to.
#
# A successful ticket ends with a pull request open, green, carrying the
# review's findings and the hand-off label, the worktree gone, and nothing in
# flight. A ticket that cannot get there ends on the stuck path (#175, item
# 8): a comment on the ticket saying what was tried and why it stopped,
# `agent-working` swapped for `agent-stuck`, and nothing of the run left
# behind. Where the failure came after the push, the hand-back reaches the
# pull request too - a comment on it, and it is left open without the
# hand-off label, because it holds real work (ADR 0007 §2). No pull request
# is ever opened by the hand-back itself.
#
# BOTH ENDINGS push a ntfy notification (item 9, #176): a pull request handed
# over, and a ticket handed back stuck. They publish straight to the
# self-hosted ntfy server this host already runs, at the push lane's own
# severity conventions, rather than through Alertmanager - these are pipeline
# events only the runner knows about, not metric states for Prometheus to
# scrape. Both arrive at the lane's informational level (priority low, silent)
# and are told apart by title and tag, because neither should buzz a phone:
# nothing here is wrong, and a stuck ticket still needs a human to read it
# rather than be woken by it. What does route through the existing stack is a
# runner that dies outright: a `die` leaves the unit failed, which
# SystemdUnitFailed and the journal-tail enrichment already report. The third
# condition item 9 names - OpenCode Go usage approaching a cap - is tracked
# separately, against OpenCode's own usage API rather than a ledger the runner
# keeps (#176 closed without it; see #221).
#
# THE REVIEW STAGE IS ADVISORY, AND THAT IS A MEASURED DECISION RATHER THAN A
# GAP. It proves, from the session transcript rather than from the session's
# own account, that the `code-review` skill ran in a fresh contained context
# across its two axes, and it fails closed when it cannot. It does not decide
# whether the diff is correct, and it no longer asks for a verdict at all.
#
# Fifteen runs against the one diff in this repository with an independently
# graded defect - two models, three prompts, five arms - never once refused it
# *for the defect in it* (plan item 6). Five of the fifteen saw the defect and
# none gated on it. The rubric that gated most reliably gated on the correct
# implementation too, for reasons neither model endorsed. So a refusal here
# would have been noise with a human hand-off attached to it.
#
# What the stage is worth is the contained, verified pass itself and the
# findings it leaves for whoever merges - which a re-grade of all 25 arm runs
# found to be accurate: nine recurring finding-themes checked against source,
# nine true, on both models. This stage does not invent defects. What it did do
# was vouch for what it had not tested - 9 of those 15 runs certified the very
# criterion the diff breaks - which is what the prompt's certification clause
# below now forbids. The hand-off writes these findings onto the pull request
# that is already open; it does not read them as a decision, there is no longer
# a verdict for it to mistake for one, and `prHandoff` spends a paragraph
# telling the person who does read them what they are not.
#
# THE MODEL NEVER PUSHES; THE RUNNER DOES. Both sessions are denied `git push`,
# `gh pr` and every tracker verb through OpenCode's own permission layer
# (`permissionOverlay`, `reviewOverlay`) rather than merely asked not to use
# them, and the script pushes afterwards, from outside the session, only past
# the pre-push gate that reads the diff. That holds for the CI fix round's push
# as well: `push_branch` is the gate and the push and nothing else, and it is
# the only thing in this script that pushes. Nothing anywhere here merges or
# arms auto-merge: ADR 0004 §9 cannot be a ruleset in this repository (plan
# item 3), so it is a property of this script, asserted from outside by the
# harness - and the hand-off label is a signal rather than a control for the
# other half of the same reason (ADR 0007 §7).
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
    # For the notifications (item 9, #176): the ntfy access token the push
    # lane already publishes with. The alertmanager-ntfy bridge on this host
    # uses exactly this token to reach exactly this server, so reusing it is
    # the difference between wiring notifications and standing up a second
    # credential - and a token is only ever as broad as the ntfy user it
    # belongs to, which is the same user every push already goes out under.
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
  # exception, which cannot be judged from prose at all - is `push_gate` below,
  # against the diff, immediately before the push.
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
  #
  # This is the IMPLEMENT model. Review uses a different one - see below, and
  # the two are separate bindings rather than one because they were settled by
  # different measurements answering different questions.
  model = "opencode-go/glm-5.3-flash";
  variant = "high";

  # The REVIEW model, and the one place in this pipeline where the expensive
  # option is the right one. Item 1's ranking measured implementation, and item
  # 6's arms then measured review; they are not the same skill and they did not
  # give the same answer.
  #
  # The recorded reason to refuse `deepseek-v4-pro` here was that it "gates no
  # more reliably at 15-25x the cost". That reason died with the verdict: this
  # stage no longer gates, so the only thing its output has to be is *worth a
  # person's reading time*, which is a different question and was re-graded
  # against the 25 runs already paid for (plan item 6, "Re-graded on findings
  # quality"). What that found:
  #
  # - `deepseek-v4-pro` checked its own claims. It ran `nix build`/`nix eval`
  #   in 8 of 15 runs; `glm-5.3-flash` did in 2 of 10. Four of those ten
  #   `glm-5.3-flash` runs wrote a full review report having personally read
  #   nothing, run nothing and searched nothing - relaying their sub-agents
  #   wholesale. No `deepseek-v4-pro` run did that. For a stage whose entire
  #   output is notes a human reads, that is the difference that matters.
  # - It found the one thing nobody else did, including the human grading: that
  #   the *clean* subject uses `""` as a live collision key and over-refuses two
  #   folders that both slugify to nothing. One run in twenty-five.
  #
  # Cost: about 10c a review against implement's 4-9c, so roughly double a
  # ticket and still a rounding error against OpenCode Go's $12-per-5-hours.
  # That is affordable *because* review is one pass with no retry budget.
  #
  # What this is NOT evidence for: that it reviews better in general. Detection
  # of the graded defect was 2/3 for this model on the base prompt and 0/3 under
  # the R3 rubric, where `glm-5.3-flash` managed 1/3 - n=3 cells pointing both
  # ways. The verification counts above are the only part that is not noise.
  reviewModel = "opencode-go/deepseek-v4-pro";

  # Where the notifications publish (item 9, #176). Both values are read from
  # the modules that own them rather than restated, for the same reason
  # `repository` above gives for its own single value - a value restated in a
  # second module is a value that drifts: ntfy.nix owns the server and its
  # port, and monitoring.nix's push lane owns the topic the phone subscribes
  # to. This module is evaluated standalone by its two checks, and both import
  # the two modules these read from - the shape download-root-canary's check
  # already uses for its monitoring read.
  #
  # The URL is loopback rather than the public base URL the bridges use,
  # because the runner lives on the same host as the server: its notifications
  # should not depend on the tunnel standing up, which is exactly what a
  # tunnel-outage alert would be competing with.
  ntfyUrl = "http://127.0.0.1:${toString config.cg.service.ntfy.port}";
  ntfyTopic = config.cg.service.monitoring.alertmanager.ntfy.topic;

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
  # The agent's commits say they are the agent's (ADR 0006). Until #200 this
  # was the operator's name and address, which meant `git log` could not
  # distinguish a commit a person wrote from one generated overnight - the
  # ambiguity that ADR existed to remove, sitting in the one place a reviewer
  # actually looks.
  commitName = botLogin;
  commitEmail = "${botUserId}+${botLogin}@users.noreply.github.com";

  # ADR 0004 §6's retry budget, whose number plan item 5 owns: two retries,
  # three attempts. At the pilot's measured 4-6 cents per attempt this cannot
  # meaningfully threaten OpenCode Go's $12-per-5-hours cap, which is the only
  # constraint that would argue for a smaller one.
  maxAttempts = 3;

  # Per-attempt ceiling. Every converged pilot run finished inside 12-36
  # minutes; the one run that reached 3600s had made no progress at all, so a
  # longer ceiling buys nothing a retry would not buy better. It exists so that
  # a stuck attempt fails the runner's own way - countable, and handed back by
  # the stuck path when the budget runs out - rather than by systemd killing
  # the unit mid-ticket and leaving behind the worktree the in-flight guard
  # above then trips over.
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

  # Ceiling on the review pass (item 6, #173), for the same reason
  # `attemptTimeout` exists: a stage that hangs should fail the runner's own
  # way, countable, rather than by systemd killing the unit mid-ticket and
  # leaving a worktree for the in-flight guard to hand back later.
  #
  # Measured runs of this stage finished in 2-10 minutes across both models and
  # all 25 arm runs, so this is generous by an order of magnitude rather than
  # tight. It matches the ceiling item 1's pilot used for the same call, which
  # is the only number with real runs behind it. Left unchanged when review
  # moved to `deepseek-v4-pro`: that model's slowest measured run was 10
  # minutes, still a third of this.
  reviewTimeout = 1800;

  # --- watching the branch's own CI (ADR 0007, plan item 13) --------------
  #
  # The pull request now opens before the review, so CI is what decides
  # whether the branch is correct and the review is a quality pass on top of
  # it. That turns "has CI finished?" into a question the runner has to answer
  # for itself, and the hard half of it is that a required check which never
  # arrives looks exactly like one that is slow.
  #
  # Both bounds are therefore counted in POLLS rather than written as
  # deadlines in seconds, and that is not a stylistic choice. The harness
  # drives this exact script with the interval overridden to zero, so a bound
  # expressed in seconds would either take three quarters of an hour to test or
  # would have to be overridden too - at which point the number under test is
  # the fixture's rather than production's. Counted in polls, the harness
  # exercises the real numbers at no wall-clock cost.
  ciPollInterval = 60;

  # How many polls a run may go without any check appearing for the commit
  # that was just pushed, before the runner calls it absent rather than slow.
  # Ten minutes at the interval above. A workflow that was never triggered is
  # a configuration problem rather than a problem with the diff, so it stops
  # the run instead of being fed back to the model, which would have nothing
  # to fix.
  ciFirstCheckPolls = 10;

  # And the ceiling on one whole watch: forty-five minutes at the interval
  # above. This repository's gate is a 22-way check matrix and three host
  # builds against a warm Cachix cache; every run measured has been well
  # inside this, and a run that is not has stopped reporting rather than
  # slowed down.
  ciSettlePolls = 45;

  # How many times CI is watched before the runner gives up: an initial watch
  # and, if that one is red, one fix and one re-watch.
  #
  # Its own budget rather than a draw against `maxAttempts`, and ADR 0007
  # records why: the two bound different failures. `maxAttempts` bounds "the
  # model cannot converge against the local gate"; a round here bounds "the
  # local gate and CI disagree". A ticket that needed all three attempts is if
  # anything more likely to earn a CI round, so a shared budget would deny
  # rounds exactly where they are most likely to be deserved.
  #
  # Two rather than three, which is where `maxAttempts` sits, because nobody
  # knows yet how often CI is red on a branch this gate already passed - that
  # is what plan item 13 asks the runner to record. Two is the smallest number
  # that lets a red run be fixed at all. Raising it costs an hour of ceiling
  # each and should be paid for with evidence rather than with a guess.
  maxCiRounds = 2;

  # The hand-off, applied to the pull request in the same `gh pr edit` that
  # writes the findings into its body, so a labelled pull request is one whose
  # body carries them. Deliberately not `ready-for-human`, which is an issue
  # triage role meaning "requires human implementation" and would read on an
  # agent's own pull request as "an agent could not do this"
  # (docs/agents/triage-labels.md).
  #
  # A signal, not a control: nothing here or at GitHub's end stops a merge
  # before it is applied, and ADR 0007 §7 says why that is the right way round.
  handoffLabel = "agent-ready-for-review";

  # How deep to look when turning a session title back into a session id.
  # A named binding rather than a bare `-n 20` at two call sites, because every
  # other number in this file is one: the runner opens at most two sessions per
  # ticket, so this is generous, and the only thing that would argue for more is
  # a session list shared with work this unit did not do.
  sessionListDepth = 20;

  # How many sub-agent contexts a real `code-review` pass fans out into:
  # standards and spec, which is the whole reason the skill exists rather than
  # one prompt asking for both. Written down because the stage below asserts
  # it rather than assuming it - item 1 measured a run where the two collapsed
  # into a single context, and it failed silently instead of erroring.
  reviewAxes = 2;

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
  # boundary - and this process holds a PAT that can push. What does not depend
  # on the model behaving is `push_gate` below, which reads the diff itself
  # immediately before the push.
  permissionOverlay = builtins.toJSON {
    permission.bash = {
      "git push*" = "deny";
      "gh pr*" = "deny";
      "gh issue edit*" = "deny";
      "gh issue close*" = "deny";
      "gh issue comment*" = "deny";
    };
  };

  # The review stage's instructions (#173, item 6). Its shape is the same as
  # the implement prompt's and for the same reasons - a file in the store, one
  # substituted token - but what it asks for is narrower, and every clause in
  # it is here because a measured run went wrong without it.
  #
  # `ISSUE` and `BASE` are substituted at run time; nothing else in it varies.
  #
  # NAMING THE SKILL is the whole mitigation for discovery-is-not-invocation,
  # exactly as in the implement prompt. What is new here is the sentence after
  # it: item 1's review-stage run called the `skill` tool correctly, got
  # `Skill "code-review" not found`, and then wrote a review of its own and
  # reported it as though the skill had run. A hand-rolled review presented as
  # the skill's is worse than no review, because the stage below cannot tell
  # the difference - so the prompt asks it to stop, and the stage verifies the
  # skill fired rather than believing either answer.
  #
  # THE CONTAINMENT CLAUSE is not decoration either. The same run reviewed a
  # sibling checkout instead of its own. The cause was ambient - opencode took
  # its project from the working directory, and the pilot's harness launched it
  # one level too high - and `--dir` below is the real fix. This clause is the
  # belt to that braces: `bash` and `cd` are unrestricted in any case, so a
  # session that reasons its way toward a neighbouring tree is not contained
  # from reaching it by permissions alone.
  #
  # THERE IS NO VERDICT LINE, AND ASKING FOR ONE WAS THE MISTAKE THIS PROMPT
  # USED TO MAKE. Earlier drafts closed with `AFK-REVIEW-VERDICT: pass|fail`,
  # because a shell script cannot read prose and the stage wanted one bit out
  # of a page of English. It got the bit; the bit was not about the diff.
  #
  # Measured across twenty-five runs on the pilot's holdout pair, over two
  # models and three fail rubrics (plan item 6). The rubric that produced
  # `fail` most reliably produced it on the correct implementation too, and
  # every refusal of the defective one was grounded on something other than
  # its defect - twice on a missing CI matrix entry a `grep` finds every time
  # and item 5's gate already catches. Asking a reviewer for a decision it
  # cannot make does not get a worse decision, it gets a confident one.
  #
  # So this prompt asks for findings and a summary of them, and nothing that
  # reads as an outcome. What replaced the verdict is the closing summary
  # below: naming the worst finding on each axis is the thing every measured
  # run did well and did unprompted, and it is what the human merging wants
  # from a page of review prose.
  #
  # THE CERTIFICATION CLAUSE is the largest single quality defect the 25 runs
  # showed, and it is the one that survives dropping the verdict. Re-grading
  # those runs on findings quality rather than on verdicts (plan item 6) found
  # that **9 of 15 runs on the flawed subject affirmatively wrote that the
  # criterion that diff breaks is satisfied** - "renders exactly as today", a
  # tick against the acceptance criterion, "behaviorally unchanged". Worse:
  #
  #   4 of the 5 runs that DID find the defect also certified, elsewhere in the
  #   same report, that the criterion it breaks holds.
  #
  # A person reading that report gets the bug and its refutation with nothing
  # to separate them, which is worse than a report that missed it. Nothing in
  # the verdict machinery could see this, because every one of those runs
  # emitted a perfectly well-formed verdict line.
  #
  # The accuracy of the findings themselves was not the problem: nine recurring
  # finding-themes were checked against both subjects' source and all nine were
  # true, on both models. This stage does not invent defects. It vouches for
  # things it did not test, so that is what the clause forbids.
  reviewPrompt = pkgs.writeText "afk-agent-review-prompt" ''
    Review the work on this branch. The fixed point is BASE. The spec is
    GitHub issue #ISSUE; read it with `gh issue view ISSUE`.

    Use the `code-review` skill, by name - call it rather than improvising
    something equivalent. If the `skill` tool reports that `code-review` is
    not available, stop immediately and say so as your entire answer. Do not
    substitute a review of your own: a hand-rolled review reported as if it
    were the skill's is worse than no review, because nothing downstream can
    tell the difference.

    Scope:

    - Work only inside this directory. Do not read, write or reason about any
      checkout above or beside it, and do not `cd` out of it. If this
      directory looks like the wrong target, say so and stop rather than
      looking for a better one.
    - Report findings only. Change no files, commit nothing, push nothing,
      and do not edit, close or comment on the issue.

    Your review is advisory. It does not decide whether this branch merges,
    and nothing downstream reads it as a decision - a person does, next to
    the diff. So do not return a verdict, a pass/fail, an approval or a
    recommendation to merge or not to merge, and do not rank the diff as
    acceptable or unacceptable overall. Report what you found.

    Two kinds of finding are worth the most to that person, so say plainly
    when you have one:

    - the diff does not do what the ticket asked, or does it wrongly
    - a claim in a commit message on this branch is not true of the diff

    Style, naming, structure and taste findings are worth reporting too, and
    are worth less. Judge the code, not the commit message's prose.

    Do not write that a requirement is met, satisfied, verified, correct or
    unchanged unless you ran something that shows it. If you checked it by
    reading, say that you checked it by reading and say how far that goes. If
    you did not check it, say you did not check it. "I did not verify this" is
    a useful sentence here and an honest one; a tick against a criterion you
    inferred is neither.

    Finish with a short summary naming the most serious finding on each axis,
    or saying that the axis found nothing.
  '';

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
  # on a command line, not a capability boundary.
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

  # The pull request's body, which is now written in TWO PASSES rather than
  # assembled once. Files in the store with substituted tokens, for the same
  # reason the two prompts above are: this is prose, and prose does not survive
  # being a shell literal in a script this one's shape.
  #
  # ADR 0007 is what split it. The pull request opens before the review runs,
  # so at creation time there are no findings to carry and no CI outcome to
  # report - `prIntro` plus the branch's own commit messages is the whole of
  # what is known. `prHandoff` is appended afterwards, by `gh pr edit`, once CI
  # has settled green and the review has been verified to have run.
  #
  # That leaves a window in which a reader can meet a body with no hand-off
  # section under it, so `prIntro` says what that means rather than leaving it
  # to be inferred. A body without one is a run that has not finished, and the
  # absence of `agent-ready-for-review` says the same thing from the outside.
  #
  # `ISSUE`, `BRANCH`, `IMPLEMODEL`, `REVIEWMODEL`, `ATTEMPTS`, `CIROUNDS` and
  # `HANDOFF` are substituted at run time; nothing else in them varies. No
  # token is a substring of another, which is what keeps one `sed` expression
  # from eating the next.
  #
  # WHAT THE BODY IS FOR. One person reads this, once, next to a diff nobody
  # else has read, and decides whether to merge it (ADR 0004 §9). So it says
  # where the branch came from, what the branch claims to do, what was already
  # checked and by what, and - at more length than reads comfortably - what the
  # review under it is not. Item 6 measured that stage vouching for criteria it
  # never tested in 9 of 15 runs, four of them in the same report as the defect
  # they were refuting. A reader who takes the findings as a verdict is making
  # exactly the mistake the verdict was dropped to prevent, so the caveat
  # travels with them rather than living in a plan document.
  #
  # THE COMMIT MESSAGES ARE THE IMPLEMENTER'S HALF, and they are quoted rather
  # than summarised. A summary would be another paid call producing prose
  # nothing checks, which is the shape item 6 spent twenty-five runs learning
  # to distrust - and a summary of its own work by the session that did it is
  # the self-account this pipeline refuses everywhere else. The commit messages
  # are already the one piece of the implementer's prose that gets audited: the
  # review prompt names "a claim in a commit message on this branch is not true
  # of the diff" as one of the two findings worth the most. So they arrive
  # having been read against the diff, and they are what `git log` keeps after
  # a squash merge anyway.
  #
  # One known property, pre-existing rather than introduced here: a closing
  # keyword written into a commit message closes that issue on merge whether or
  # not this body repeats it, because the squash commit carries the message.
  # Scrubbing them here would make the body disagree with the commit, which is
  # worse than the thing it would prevent.
  prIntro = pkgs.writeText "afk-agent-pr-intro" ''
    Closes #ISSUE.

    Opened unattended by the AFK agent (ADR 0004). The work on `BRANCH` was
    claimed from `ready-for-agent`, implemented by `IMPLEMODEL` across ATTEMPTS
    session(s), and pushed only once this repository's own gate passed on the
    commit at the head of the branch: `nix fmt -- --ci`, `nix flake check`, a
    build of every host, and agreement between the checks the flake exposes and
    the matrix in `ci.yml`. The diff was checked against the path denylist in
    `docs/agents/afk-eligibility.md` immediately before every push, as well as
    before the claim.

    **No person has read this diff.** Nothing in this pipeline merges and no
    auto-merge is armed on this path: merging is a human act (ADR 0004 §9).

    This pull request was opened *before* its review ran, which is the order
    ADR 0007 settled: CI on this branch is what decides correctness, and the
    review is a quality pass whose findings are appended to this body once it
    has run. **If there is no "Handed over" section below this one, the run has
    not finished** - CI never went green, the review could not be shown to have
    happened, or the runner died in between. The `HANDOFF` label says the same
    thing from the outside, and is applied in the same edit that appends the
    section.

    ## What the branch says it does

    Quoted from its own commit messages, unedited.

  '';

  prHandoff = pkgs.writeText "afk-agent-pr-handoff" ''
    ## Handed over: CI is green, and the review below is advisory

    CI on this branch went green, over CIROUNDS watch(es) of its checks. That
    is the correctness gate on this path (ADR 0007) - the runner's own local
    gate is a reproduction of CI's steps and can drift from them, and CI runs
    what only CI runs: a cold runner, the sharded check matrix, and every host
    built from an empty store.

    `code-review` then ran against this branch on `REVIEWMODEL`, in a fresh
    context, across its standards and spec axes. The runner verified that from
    the session transcript rather than from the session's own account of
    itself, and would not have applied `HANDOFF` otherwise. It decided nothing,
    and nothing downstream read it as a decision
    (`docs/plans/afk-agent-pipeline.md`, item 6).

    It also could not have changed what is in this pull request. It ran after
    the push, against a branch nothing pushes again, so its report is the
    entirety of what it was able to affect (ADR 0007).

    Two measured things are worth holding while reading it. Its findings are
    accurate - nine recurring themes across 25 runs were checked against
    source and all nine were true - but across 15 runs on a diff with an
    independently graded defect it never once refused that diff for the defect
    in it, and it has repeatedly written that a criterion holds without
    running anything that shows it. A finding here is worth reading. A silence
    here is worth nothing. It was asked, among other things, to report any
    claim in a commit message above that is not true of the diff.

    ---

  '';

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
    # (item 9, #176) became the one thing the check has to be able to
    # intercept - with the App token mint stubbed through `AFK_GH_TOKEN`,
    # curl's only reachable use in a check run is the notification POST, and
    # the harness records those calls exactly like it records `gh`'s. In
    # production curl is on the unit's PATH through `toolchain` either way.
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];

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
      pr_label="afk-agent"
      # The claim (ADR 0006). It replaces the assignee the tracker used to
      # carry here, because GitHub will not assign an issue to a GitHub App.
      working_label="agent-working"
      # What a handed-back ticket carries instead. The stuck path (#175, item
      # 8) swaps `$working_label` for this in one edit, next to the comment
      # that says why the run stopped. Deliberately not `$label`: re-applying
      # the claim marker would send a ticket the runner cannot finish straight
      # round the frontier query again, to burn its retry budget on the same
      # failure every poll. A human decides what happens to an
      # `$stuck_label` ticket (docs/agents/triage-labels.md).
      stuck_label="agent-stuck"

      checkout="$state_dir/checkout"
      worktrees="$state_dir/worktrees"

      # The ntfy server and topic the two notifications publish to (item 9,
      # #176). Deliberately not an environment seam: the URL and topic are the
      # behaviour under test, and the check asserts the exact POST the runner
      # would make against the values the module evaluated.
      ntfy_url="${ntfyUrl}"
      ntfy_topic="${ntfyTopic}"

      denied=(
        ${lib.concatMapStringsSep "\n        " (p: ''"${p}"'') deniedPaths}
      )

      log() { echo "afk-agent: $*"; }
      die() { echo "afk-agent: $*" >&2; exit 1; }

      # Turn a session title back into a session id, or print nothing.
      #
      # Written once because both stages need it and the pipeline is not
      # trivial. `|| true` on the end is load-bearing rather than tidy, for the
      # reason the review stage's own greps carry one: this is only ever
      # called inside a
      # command substitution, and under `set -euo pipefail` an `opencode` that
      # fails or a `jq` that finds nothing would abort the runner right there -
      # before either caller's own `die` could say which session it was looking
      # for and why that matters. An empty answer has to travel back as an
      # empty answer.
      session_id_for() {
        (
          cd "$1" \
            && opencode session list -n ${toString sessionListDepth} --format json \
            | jq -r --arg t "$2" 'map(select(.title == $t)) | .[0].id // empty'
        ) 2>/dev/null || true
      }

      # --- notifications (item 9, #176) --------------------------------------
      #
      # Two conditions have to reach a person who is not watching GitHub: a
      # pull request is ready for review, and the pipeline is stuck on a
      # ticket and needs a decision. They publish straight to the self-hosted
      # ntfy server and topic the push lane already uses, at the priority that
      # lane's conventions give each kind of event - the same vocabulary the
      # alertmanager-ntfy bridge speaks, minus the criticals: both arrive at
      # the informational level (priority low, silent, the level warnings get)
      # because neither is wrong and neither should buzz a phone at 03:00, and
      # they are told apart by title and tag so the phone still distinguishes
      # a ticket that needs a read from a pull request that needs a review.
      #
      # Best-effort, like every other write this script makes from inside a
      # run that has already decided its outcome: a notification that cannot
      # be sent is one line in this unit's journal, and nothing downstream of
      # it changes. The events it reports are already on the tracker or in
      # this journal by the time it fires.
      #
      # The token reaches curl as a header file rather than as an argument,
      # for the reason the App token reaches `gh` through the environment: a
      # command line is readable by every process on the host through /proc,
      # and neither credential is ever a log line or an argv element. The
      # header file is written once per run next to `run_dir` below, 0600
      # under the unit's umask inside a 0700 state directory.
      notify() {
        local priority=$1 tag=$2 title body
        title="$(printf '%s' "$3" | tr -d '\r\n')"
        body="$run_dir/ntfy-body"
        # ntfy refuses a body over 4 KB. `|| true` because a body longer than
        # the cap makes `head` close the pipe early, and a notification
        # truncated at 3.8 KB is still a notification.
        printf '%s\n' "$4" | head -c 3800 > "$body" || true
        if ! curl -sS -m 30 \
          -H "@$run_dir/ntfy-auth" \
          -H "Title: $title" \
          -H "Priority: $priority" \
          -H "Tags: $tag" \
          --data-binary "@$body" \
          "$ntfy_url/$ntfy_topic"
        then
          echo "afk-agent: the ntfy notification '$title' could not be published; the event it reports is in this journal" >&2
        fi
      }

      # The stuck notification the two stuck paths share (item 8/9): one title,
      # tag and priority, differing only in the prose that names the ticket.
      # The ticket URL is the one line both must carry - a stuck notification
      # that does not point at its ticket is a phone alert pointing at nothing.
      notify_stuck() {
        local reason=$1 status=$2
        notify low octagonal_sign "AFK agent stuck on #$number" \
          "$(printf '%s\n%s\n%s' \
            "$reason" \
            "$status" \
            "$(printf 'Ticket: https://github.com/%s/issues/%s' "$repo" "$number")")"
      }

      # --- the stuck path (item 8, #175) ------------------------------------
      #
      # A claimed ticket that cannot be carried to a hand-off is handed back
      # rather than dropped: the reason goes to this unit's journal AND to the
      # ticket as a comment, `$working_label` becomes `$stuck_label` in one
      # edit, and everything the run built that nothing points at is torn
      # down. No pull request is ever opened here, and the next poll starts
      # clean - which is what makes it safe for the success path to leave
      # nothing behind either.
      #
      # The two halves the plan item 8 spells out, split by the push because
      # ADR 0007 moved the pull request in front of the review:
      #
      # - Before the push, ADR 0004 §6's "never a PR" holds in full, and so
      #   does the plan's "no WIP branch left dangling for a run that never
      #   pushed": the worktree and the local branch go, and nothing reaches
      #   origin.
      # - Past the push there is a pull request to reach. It is commented on
      #   as well as the issue, and left open without the hand-off label -
      #   which is the only signal, from outside, that nobody has finished
      #   with it (ADR 0007 §2). It holds real work, so the branch stays on
      #   origin and locally, and only the worktree goes.
      #
      # The order inside is load-bearing. The tracker writes come first
      # because they are the part that outlives this process: a teardown that
      # fails once is retried by the next poll's guard, but a comment that was
      # never written is gone for good, and a ticket still carrying
      # `$working_label` once its worktree is gone is stranded silently -
      # invisible to the frontier query, missed by the guard, and known to
      # nobody. The ntfy push (item 9, #176) comes after the tracker writes
      # for the same reason - the phone's copy is a pointer at the durable
      # half, not a substitute for it - and before the teardown, which is the
      # slow part. `exit 1` at the end keeps the unit red: the hand-back is the
      # designed outcome, and it is still a failure somebody has to act on.

      # The tracker writes every hand-back shares, so the two stuck paths do
      # not each restate them. Relabel is the durable half - it is what takes
      # the ticket out of the frontier query - the comment is the explanation,
      # and the closing paragraph names the decision a human now owes the
      # ticket. A failed comment is non-fatal because the reason is already in
      # this unit's journal; a failed relabel is the caller's call, because
      # only the caller knows whether a ticket left carrying `$working_label`
      # is about to be retried by the guard or stranded by a teardown.
      stuck_closing() {
        printf '%s\n' "The ticket is relabelled \`$stuck_label\`. It needs a human decision: reshape it and re-apply \`$label\`, or take it by hand (docs/agents/triage-labels.md)."
      }

      post_issue_comment() {
        if ! gh issue comment "$number" --repo "$repo" --body-file "$1"; then
          echo "afk-agent: #$number: the comment could not be posted; the reason above is in this unit's journal" >&2
        fi
      }

      relabel_stuck() {
        gh issue edit "$number" --repo "$repo" \
          --remove-label "$working_label" --add-label "$stuck_label"
      }

      hand_back() {
        local reason=$1
        local body="$run_dir/stuck.md"

        echo "afk-agent: #$number: $reason" >&2

        {
          printf '%s\n' \
            "The AFK agent stopped work on this ticket and is handing it back, without opening a pull request."
          printf '%s\n' ""
          printf '%s\n' "Why it stopped:"
          printf '%s\n' ""
          printf '%s\n' "$reason"
          printf '%s\n' ""
          if [ "$pr_url" != "" ]; then
            printf '%s\n' \
              "The pull request ($pr_url) is left open without the \`${handoffLabel}\` label: it holds the branch's work, and the label's absence is what says from outside that nobody has finished with it (ADR 0007 §2). The worktree is removed and the branch is left untouched."
          elif [ "$pushed" -eq 1 ]; then
            printf '%s\n' \
              "The worktree is removed. The branch \`$branch\` reached origin and is kept there - it holds the work the gate passed on, and a pull request can be opened from it by hand."
          elif [ "$branch_created" -eq 1 ]; then
            printf '%s\n' "The worktree and the branch \`$branch\` are removed."
          else
            printf '%s\n' "Nothing of this run was left behind."
          fi
          printf '%s\n' ""
          stuck_closing
        } > "$body"

        post_issue_comment "$body"

        # The other half of reaching a run that failed past the push (plan
        # item 8): the pull request gets the same story the issue does, so a
        # reader who arrives at the pull request rather than the ticket is
        # not left guessing. A comment on a pull request is reportable and
        # removable; the hand-off label's absence is still what says this
        # pull request is not finished.
        if [ "$pr_url" != "" ]; then
          if ! gh pr comment "$pr_url" --repo "$repo" --body-file "$body"; then
            echo "afk-agent: #$number: the pull request comment could not be posted" >&2
          fi
        fi

        # One edit, like the claim, so the ticket is never briefly carrying
        # both labels or neither. A failure here is not fatal to what
        # follows - the teardown still runs - but the journal says the ticket
        # is stranded with its claim marker on, which is the loudness a
        # half-handed-back ticket deserves.
        if ! relabel_stuck; then
          echo "afk-agent: #$number: could not relabel to $stuck_label; the ticket still carries $working_label and is invisible to the frontier query" >&2
        fi

        # The notification (item 9, #176). The tracker writes above are the
        # durable half of the hand-back; this is the half that reaches
        # somebody who is not looking at GitHub, at the lane's informational
        # level (priority low, silent) - a stuck pipeline stops work until a
        # human reads the ticket, but it should not wake them up to do it.
        notify_stuck "$reason" \
          "$(if [ "$pr_url" != "" ]; then printf '%s is open and unfinished' "$pr_url"; fi)"

        if [ "$pushed" -eq 0 ]; then
          remove_worktree_and_branch "$worktree" "$branch" "$branch_created"
        else
          # Pushed work stays: it is what the pull request is made of, and
          # the success path keeps its local branch for the same reason.
          remove_worktree_and_branch "$worktree" "$branch" 0
        fi
        exit 1
      }

      # The teardown both stuck paths share. Worktree first - a branch checked
      # out in a living worktree cannot be deleted - then the local branch
      # when the caller says so, which is only ever for a run that never
      # pushed. Every step is guarded rather than fatal, because a teardown
      # that half-fails must not stop the ticket being handed back; the next
      # poll's guard retries whatever is left.
      #
      # --force on the worktree, where the success path's removal has none:
      # a stuck run's tree is by definition not a tree anything vouched for,
      # and a dirty one is exactly what a run killed mid-edit leaves.
      remove_worktree_and_branch() {
        local wt=$1 branch_name=$2 delete_local=$3

        if [ -d "$wt" ]; then
          git -C "$checkout" worktree remove --force "$wt" \
            || echo "afk-agent: could not remove $wt; remove it by hand before the next poll" >&2
        fi

        if [ "$delete_local" -eq 1 ] \
          && git -C "$checkout" show-ref --verify --quiet "refs/heads/$branch_name"; then
          git -C "$checkout" branch -D "$branch_name" \
            || echo "afk-agent: could not delete the local branch $branch_name" >&2
        fi
      }

      # The other half of the stuck path, run by the in-flight guard below: a
      # worktree on disk from a run that died before it could hand its ticket
      # back. The ticket number is read out of the worktree's name, which is
      # the slug the dead run built, so nothing has to have survived the run
      # that died.
      #
      # The decision item 8 owns here is tear-down, not resume: the dead
      # run's prompt, logs and attempt count died with it, and resuming
      # unattended work nobody can vouch for is the shape ADR 0004 §6 exists
      # to prevent. The comment says what is known, which is not much, and
      # says it rather than guessing.
      hand_back_dead_run() {
        local path=$1 name number branch pushed_branch open_prs ls_rc body

        name="$(basename "$path")"
        number="''${name%%-*}"
        branch="$branch_prefix$name"

        # The slug is validated below as digits first, so what is in front of
        # the first dash is the ticket number. A directory that does not
        # parse is not this runner's worktree, and tearing down something
        # unidentified is the one thing this path must not do.
        if ! [[ "$number" =~ ^[0-9]+$ ]]; then
          die "a worktree from an earlier run is still here ($path) but its name does not name a ticket; remove it by hand"
        fi

        # An open pull request for this branch means the run finished and only
        # its worktree survived - the ticket is done, not stuck, and
        # relabelling it under its own open pull request would be a lie. The
        # worktree is cleared, the branch stays (it is what the pull request
        # is from), and the ticket is not touched.
        open_prs="$(gh pr list --repo "$repo" --head "$branch" --state open --json number \
          | jq 'length')" \
          || die "#$number: could not ask the tracker whether a pull request is open for $branch"

        if [ "$open_prs" -gt 0 ]; then
          log "#$number: a pull request is open for $branch, so the run finished and only its worktree survived; clearing it and moving on"
          remove_worktree_and_branch "$path" "$branch" 0
          return 0
        fi

        # Whether the dead run's branch reached origin. A run killed between
        # the push and the pull request leaves exactly that, and pushed work
        # is kept - it is what a pull request can be opened from, the same
        # rule the hand-back above follows past the push.
        pushed_branch=0
        if git -C "$checkout" ls-remote --exit-code origin "refs/heads/$branch" > /dev/null 2>&1; then
          pushed_branch=1
        else
          ls_rc=$?
          if [ "$ls_rc" -ne 2 ]; then
            die "#$number: could not ask origin whether $branch is there"
          fi
        fi

        # The tracker writes first, for the reason hand_back gives - and are
        # skipped when the ticket already carries `$stuck_label`, which is
        # the shape a hand-back whose teardown failed last poll leaves.
        # Relabel before comment here, unlike hand_back: a relabel that fails
        # dies before anything is written, so the next poll retries both
        # together rather than posting the comment a second time.
        if gh issue view "$number" --repo "$repo" --json labels \
          | jq -e "any(.labels[]?; .name == \"$stuck_label\")" > /dev/null 2>&1; then
          log "#$number: already carries $stuck_label; clearing what is left of the dead run without writing to the tracker again"
        else
          if ! relabel_stuck; then
            die "#$number: could not relabel to $stuck_label; refusing to start a new ticket beside a dead run's wreckage"
          fi

          body="$run_dir/stuck-leftover.md"
          {
            printf '%s\n' \
              "The AFK agent found this ticket still claimed (\`$working_label\`) with a worktree left on disk by an earlier run that died before it could hand the ticket back. No pull request was open for \`$branch\`."
            printf '%s\n' ""
            if [ "$pushed_branch" -eq 1 ]; then
              printf '%s\n' \
                "The worktree is removed. The branch reached origin and is kept there - it holds the work the gate passed on, and a pull request can be opened from it by hand. Nothing of the dead run's state was kept: it did not survive the run, and resuming unattended work nobody can vouch for is the shape ADR 0004 §6 exists to prevent."
            else
              printf '%s\n' \
                "The worktree and the branch are removed. Nothing of the dead run was kept: its state did not survive it, and resuming unattended work nobody can vouch for is the shape ADR 0004 §6 exists to prevent."
            fi
            printf '%s\n' ""
            stuck_closing
          } > "$body"

          post_issue_comment "$body"

          notify_stuck \
            "An earlier run of the AFK agent died on this ticket with a worktree left behind; the ticket has been handed back for a human decision." \
            "$(if [ "$pushed_branch" -eq 1 ]; then printf '%s reached origin and is kept' "$branch"; else printf 'Nothing of the dead run was kept.'; fi)"
        fi

        remove_worktree_and_branch "$path" "$branch" "$(( 1 - pushed_branch ))"
      }

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

      # A shell that will actually run a command, which is not the same
      # question as `bash` being on the PATH above and is why this is asked
      # separately. opencode spawns `$SHELL` for every bash call the model
      # makes, so a `$SHELL` that refuses leaves the model unable to read a
      # file, run a test or make a commit - while every `gh` and `git` call
      # this script makes itself keeps working, because none of them go
      # through a shell. That asymmetry is what made it expensive to find: the
      # run claims a ticket, clones, cuts a worktree, and only then discovers
      # that the agent inside it can do nothing.
      #
      # Executable is not enough to test: `nologin` is executable, and exits 1
      # with a message. So run something through it.
      require_shell() {
        if [ -z "''${SHELL:-}" ]; then
          echo "afk-agent: SHELL is unset; opencode's bash tool has no shell to spawn" >&2
          exit 1
        fi
        if ! "$SHELL" -c 'exit 0' >/dev/null 2>&1; then
          echo "afk-agent: SHELL is '$SHELL', which will not run a command - opencode's bash tool cannot work through it" >&2
          exit 1
        fi
        echo "afk-agent: shell '$SHELL' runs commands"
      }

      require_shell

      # --- the credential, which expires part-way through a run -------------
      #
      # ADR 0006: the runner authenticates as a GitHub App, so what the secret
      # store holds is a private key and what the API wants is an installation
      # token minted from it. That token lives one hour, while `attemptTimeout`
      # alone is 3600 and `maxRuntime` covers three attempts plus their gates -
      # so a token expiring mid-run is the ordinary case here, not the
      # exceptional one. Reading it once at startup would work all the way
      # through the poll, the claim and the implement stage and then fail at
      # the push, with a claimed ticket already behind it.
      #
      # So `gh` below is a shell function that refreshes first, and every `gh`
      # in this script goes through it - which is why no call site has to think
      # about token lifetime. `command gh` rather than a bare one, so the
      # function does not call itself, and so the mock the check substitutes is
      # still what runs.
      #
      # The cache is a file rather than a shell variable because most of the
      # `gh` calls here are inside `$(...)`. A variable set by the refresh would
      # be set in the subshell and discarded with it, so the token would be
      # re-minted on every single call rather than once an hour. The file is 0600 under a 0700 StateDirectory, and
      # the trap removes it - a token that outlives the run that minted it is a
      # standing credential, which is the property this design is meant not to
      # have.
      #
      # Nothing here is echoed. The key reaches openssl on a path and the token
      # reaches `gh` through the environment; neither is ever a log line or a
      # command-line argument.
      app_id="${appId}"
      token_cache="$state_dir/installation-token"
      mkdir -p "$state_dir"
      trap 'rm -f "$token_cache"' EXIT

      b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

      refresh_gh_token() {
        local now expires header payload signing_input signature jwt installation token

        now="$(date +%s)"
        if [ -s "$token_cache" ]; then
          expires="$(head -n 1 "$token_cache")"
          if [ "$now" -lt "$expires" ]; then
            GH_TOKEN="$(tail -n 1 "$token_cache")"
            export GH_TOKEN
            return 0
          fi
        fi

        # `iat` is backdated a minute because GitHub rejects a JWT whose clock
        # runs ahead of its own, and ten minutes is the longest expiry it will
        # accept. This JWT authenticates as the App itself and can do nothing
        # to the repository; only the token it is exchanged for can.
        header='{"alg":"RS256","typ":"JWT"}'
        payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
          "$((now - 60))" "$((now + 540))" "$app_id")"
        signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
        signature="$(printf '%s' "$signing_input" \
          | openssl dgst -sha256 -sign "$creds/github-app-key" -binary | b64url)" \
          || die "the App private key would not sign a JWT; it is not a usable RSA key"
        jwt="$signing_input.$signature"

        installation="$(curl -sS \
          -H "Authorization: Bearer $jwt" \
          -H 'Accept: application/vnd.github+json' \
          https://api.github.com/app/installations | jq -r '.[0].id // empty')" \
          || die "could not ask GitHub where this App is installed"
        [ -n "$installation" ] \
          || die "this App has no installations; it has to be installed on $repo before the runner can act as it"

        token="$(curl -sS -X POST \
          -H "Authorization: Bearer $jwt" \
          -H 'Accept: application/vnd.github+json' \
          "https://api.github.com/app/installations/$installation/access_tokens" \
          | jq -r '.token // empty')" \
          || die "could not mint an installation token for installation $installation"
        [ -n "$token" ] \
          || die "GitHub returned no installation token; the App's permissions may have been withdrawn"

        # Fifty minutes against GitHub's sixty, so that no single `gh` call can
        # outlive the token it started with.
        printf '%s\n%s\n' "$((now + 3000))" "$token" > "$token_cache"
        GH_TOKEN="$token"
        export GH_TOKEN
      }

      gh() { refresh_gh_token; command gh "$@"; }

      # The one seam the check needs: it drives a mocked `gh` against a fixture
      # origin and has no App key to mint from. Everything else about the
      # credential path - that the key is required, that `gh` refreshes before
      # it runs, that the push refreshes too - is under test as written.
      if [ -n "''${AFK_GH_TOKEN:-}" ]; then
        export GH_TOKEN="$AFK_GH_TOKEN"
        refresh_gh_token() { :; }
      fi

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

      # Per-run scratch: prompts, gate logs, the pull request body, and the
      # stuck path's comment bodies. Created before the guard, because the
      # guard's hand-back writes into it. Everything here stays outside the
      # worktree, for the reason the implement stage below repeats: a file
      # written inside it would show up in the diff being gated, and then in
      # the pull request.
      run_dir="$state_dir/run"
      rm -rf "$run_dir"
      mkdir -p "$run_dir"

      # The ntfy token, as the header file `notify` reads. Written once per
      # run rather than read per notification - it is read from
      # $CREDENTIALS_DIRECTORY, which does not change under a running unit -
      # and through a file rather than curl's argv, for the reason `notify`
      # gives. Never echoed: the value reaches the file and stops there.
      printf 'Authorization: Bearer %s\n' "$(cat "$creds/ntfy-token")" \
        > "$run_dir/ntfy-auth"

      # --- one ticket at a time --------------------------------------------
      #
      # systemd already makes two live runs impossible (see the module header),
      # but it has nothing to say about a run that died: a unit killed by the
      # runtime ceiling, or by the kill switch, leaves its worktree behind, and
      # the next poll would otherwise claim a second ticket beside the wreckage
      # of the first. Refusing to start was only ever the conservative half of
      # that - it wedged the pipeline on its first casualty, and the wreckage
      # stayed until a hand removed it. The stuck path (item 8, #175) owns the
      # other half, and the decision it makes is tear-down, not resume: each
      # leftover worktree is handed back to its ticket - comment, relabel,
      # teardown - and the poll then carries on.
      #
      # Anything here that cannot be handed back cleanly stops the run: a
      # directory whose name is not a slug, a tracker that will not answer, a
      # relabel that will not land. A runner that quietly worked around a
      # wreck it could not identify would be the louder failure.
      mkdir -p "$worktrees"
      for leftover in "$worktrees"/*; do
        [ -e "$leftover" ] || continue
        if [ ! -d "$leftover" ]; then
          die "a worktree path from an earlier run is still here ($leftover) but is not a directory; remove it by hand"
        fi
        hand_back_dead_run "$leftover"
      done

      # --- poll -------------------------------------------------------------
      #
      # Two filters, and they now guard against different people. The label is
      # the runner's own claim (ADR 0006): it drops the label when it takes a
      # ticket, so a ticket it already holds is not in this list at all. The
      # assignee filter is what keeps it off a ticket a *human* has taken -
      # reading assignees works perfectly well as an App, it is only writing
      # one that GitHub refuses, so nothing about that half had to change.
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
      # relabelled: a rejection that stopped the poll would let one ineligible
      # ticket block every eligible one behind it, and the stuck path is not
      # the answer either - a ticket refused here was never claimed, so there
      # is nothing to hand back, and commenting on it every poll would be
      # noise about a ticket nobody is working. It is triage that relabels.
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

      # Everything past this point acts on a claimed ticket, and two things
      # can now happen to it. They have different exits, and the difference is
      # whether anything was tried:
      #
      # - It cannot be *started*. The clone, the fetch and the worktree are
      #   infrastructure the ticket did not choose, so nothing is handed back:
      #   the claim is undone and the next poll tries again. Leaving the
      #   ticket carrying `$working_label` instead would strand it - invisible
      #   to the frontier query, and with no worktree behind, invisible to
      #   the guard too.
      # - It was *tried* and cannot be carried to a hand-off. That is
      #   `hand_back` (item 8, #175): a comment saying what was tried and why
      #   it stopped, `$working_label` swapped for `$stuck_label`, and a
      #   teardown - never a pull request opened, nothing left in flight.
      unclaim_and_die() {
        if ! gh issue edit "$number" --repo "$repo" \
          --remove-label "$working_label" --add-label "$label"; then
          echo "afk-agent: #$number: could not undo the claim either; the ticket carries $working_label and is invisible to the frontier query" >&2
        fi
        die "$1"
      }

      # State the hand-back reads, initialised where the claim lands so that
      # every exit past this point knows what this run created. `attempt`
      # belongs to the implement loop and is read by nothing before it.
      attempt=1
      branch_created=0
      pushed=0
      pr_url=""

      log "claiming #$number: $title"
      gh issue edit "$number" --repo "$repo" \
        --remove-label "$label" --add-label "$working_label"

      # --- isolate ----------------------------------------------------------
      #
      # AGENTS.md's worktree-isolation pattern, with the worktrees gathered
      # under one directory rather than dropped beside the checkout as siblings:
      # that form exists for a human's interactive tree, and here it is what
      # both the in-flight guard above and the stuck path's teardown (#175)
      # need to be able to enumerate.
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
      branch="$branch_prefix$slug"
      worktree="$worktrees/$slug"

      # The slug becomes both a git ref and a directory name, and its input is
      # an issue title. Checked rather than trusted, and checked against what
      # is allowed rather than against a list of what is not.
      if ! [[ "$slug" =~ ^[0-9]+(-[a-z0-9]+)*$ ]]; then
        hand_back "refusing to build a branch name from the title: '$slug' is not a safe slug"
      fi

      if [ ! -d "$checkout/.git" ]; then
        log "cloning $repo_url into $checkout"
        git clone "$repo_url" "$checkout" \
          || unclaim_and_die "cloning $repo_url failed; the claim is undone and the next poll will try again"
      fi

      git -C "$checkout" fetch --prune origin \
        || unclaim_and_die "fetching $repo_url failed; the claim is undone and the next poll will try again"

      if git -C "$checkout" show-ref --verify --quiet "refs/heads/$branch"; then
        hand_back "branch $branch already exists in $checkout, and this run did not cut it, so the ticket looks half-worked; the branch is left exactly as it was found"
      fi

      # --no-track is not a detail. Without it git sets the new branch's
      # upstream to origin/master, and item 7 (#174)'s push - with git's default
      # push.default of `simple` - would then aim at master rather than at the
      # branch. Protection on master would refuse it, so the failure would be
      # loud rather than dangerous, but a runner whose push target depends on a
      # branch protection rule holding is the wrong shape.
      git -C "$checkout" worktree add --no-track -b "$branch" "$worktree" "origin/$base_branch" \
        || unclaim_and_die "cutting $branch at $worktree failed; the claim is undone and the next poll will try again"

      branch_created=1

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
      sed "s/ISSUE/$number/g" ${implementPrompt} > "$run_dir/prompt"


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
      # entries and does nothing else - is a different question, and it is
      # asked of the diff itself by `push_gate` below, before the push.
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

      # Four ways a session that was asked to write code fails, in the order
      # they can be told apart. The middle two are not defensive padding: the
      # pilot measured runs that exited 0 having explained what they would do
      # rather than doing it, and work left in the working tree is work the
      # push would silently drop.
      #
      # A function rather than a block inside the loop, because ADR 0007 adds a
      # second caller: a CI fix round runs an implement session too, and it has
      # to be judged by exactly these four things rather than by a second copy
      # of them that can drift. `$2` is what "committed something" is measured
      # against - `origin/master` for an attempt at the whole ticket, and the
      # commit already pushed for a round that is fixing it.
      #
      # `reason` and `committed` are set rather than returned: bash returns a
      # status, and both callers need the prose as well as the verdict.
      attempt_verdict() {
        local rc=$1 since=$2
        reason=""
        committed="$(git -C "$worktree" rev-list --count "$since..HEAD")"
        if [ "$rc" -eq 124 ]; then
          reason="it ran past its ${toString attemptTimeout}s ceiling and was stopped"
        elif [ "$rc" -ne 0 ]; then
          reason="opencode exited $rc"
        elif [ "$committed" -eq 0 ]; then
          reason="nothing was committed to $branch"
        elif [ -n "$(git -C "$worktree" status --porcelain)" ]; then
          reason="$(printf 'work was left uncommitted:\n%s' \
            "$(git -C "$worktree" status --porcelain)")"
        elif ! gate; then
          reason="$(printf 'the gate failed. Its last ${toString gateTailLines} lines:\n\n%s' \
            "$(tail -n ${toString gateTailLines} "$run_dir/gate.log")")"
        fi
      }

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
        #
        # `--dir` says the same thing a second way, and it is not redundant.
        # opencode resolves its project - and with it which `.agents/skills/`
        # it can see - from the directory it is launched in, so an ambient
        # working directory is load-bearing state that looks like none. Item
        # 1's review-stage run is what this is guarding against: launched one
        # level above its worktree, it lost the skill it was told to use and
        # gained a view of every sibling checkout, and all three of the
        # failures it recorded came from that. The review stage below pins the
        # same flag; both stages say it explicitly so that neither depends on
        # the `cd` above having done what it looks like it did.
        # Overlay scoped to the command, not exported for the rest of the run,
        # for the reason the review stage below gives: a deny-set that outlives
        # its own session is ambient state that looks like none, and the verbs
        # this one denies are ones a later stage needs.
        attempt_rc=0
        (
          cd "$worktree" || exit 1
          OPENCODE_CONFIG_CONTENT=${lib.escapeShellArg permissionOverlay} \
            timeout ${toString attemptTimeout} opencode run --auto \
              --dir "$worktree" "''${opencode_args[@]}" "$message"
        ) || attempt_rc=$?

        attempt_verdict "$attempt_rc" "origin/$base_branch"

        if [ -z "$reason" ]; then
          log "#$number: implemented on $branch, in $attempt attempt(s)"
          break
        fi

        log "#$number: attempt $attempt did not pass, because $reason"

        if [ "$attempt" -ge ${toString maxAttempts} ]; then
          hand_back "${toString maxAttempts} attempts and no passing implementation; the last one failed because $reason"
        fi

        # Read back once and then reused: the id does not change, and
        # `session list` is a question with a cost.
        if [ -z "$session" ]; then
          session="$(session_id_for "$worktree" "$slug")"
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
          hand_back "attempt $attempt ran, but no session titled '$slug' can be found to continue; refusing to retry in a fresh context (ADR 0004 §6)"
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

      # --- the last denylist check, asked of the diff ------------------------
      #
      # Rule 1 of docs/agents/afk-eligibility.md again, and this time against
      # the thing that will actually be pushed. Item 5's pre-claim check reads
      # a ticket's prose, which is all there is before a line of code exists;
      # whether a diff is additions-only to one list in one file is a question
      # about a diff that did not exist at claim time, and the harness pins
      # that limit with a ticket that plainly means to edit ci.yml and never
      # writes the path.
      #
      # THIS IS THE ONLY CONTROL, not an extra one. `AFK_AGENT_TOKEN` carries
      # the Workflows permission (plan item 3) precisely so the ci.yml matrix
      # exception can be exercised, so nothing at GitHub's end refuses a push
      # that edits a workflow file. And after the push there is nothing left to
      # gate: a pushed branch becomes a pull request, a `pull_request` event
      # runs the workflow file *from the head branch* with this repository's
      # secrets, and `deploy` - the only ref the fleet follows - is a
      # fast-forward away from any credential with write access. The pull
      # request could be read, rejected and closed with all three hosts already
      # moved (afk-eligibility.md, "Why these three").
      #
      # A FUNCTION CALLED FROM ONE PLACE, and that place is the line above the
      # push. ADR 0007 §6 makes that structural rather than incidental: this
      # run pushes more than once now - a CI fix round pushes to the same
      # branch - and every one of those pushes has to be gated, because it is
      # the push and not the pull request that makes a workflow file
      # executable. `push_branch` below is the only caller and it does these
      # two things and nothing else, so "immediately before, with nothing in
      # between" is a property of that function rather than of anybody's care.
      #
      # It used to also have to sit after the review, which was denied `edit`
      # by a pattern match on a command line rather than by a capability
      # boundary. That reason is gone: under ADR 0007 the review runs after the
      # push, against a branch nothing pushes again.
      #
      # Every refusal here is a stuck-path exit (item 8, #175): the hand-back
      # comments on the ticket with this gate's verdict, relabels it, and tears
      # down what nothing points at. On a first push that is everything the
      # run built; on a CI fix's push the pull request is already open, and the
      # hand-back reaches it too - the cost ADR 0007 accepted.
      push_gate() {
        local changed path base_ci added removed name

        # Three dots. `origin/$base_branch` has been moving underneath this run
        # for as long as the ticket took, and a two-dot diff would read every
        # commit master gained meanwhile as this branch's work, reversed - so a
        # merge into master that touched `secrets/` would look like this branch
        # deleting it.
        changed="$(git -C "$worktree" diff --name-only "origin/$base_branch...HEAD")"

        while IFS= read -r path; do
          [ -n "$path" ] || continue
          case "$path" in
            secrets/* | .sops.yaml)
              hand_back "refusing to push $branch - its diff changes '$path', which no AFK diff may touch and which has no exception (docs/agents/afk-eligibility.md rule 1)"
              ;;
            # The one file with an exception, checked below rather than here.
            .github/workflows/ci.yml) ;;
            .github/workflows/*)
              hand_back "refusing to push $branch - its diff changes '$path'. The only workflow file an AFK diff may touch is ci.yml, and only its checks matrix (docs/agents/afk-eligibility.md)"
              ;;
          esac
        done <<<"$changed"

        # Nothing under .github/workflows/ changed, so the exception below has
        # nothing to say and the diff is clean.
        grep -qxF ".github/workflows/ci.yml" <<<"$changed" || return 0

        log "#$number: the diff changes ci.yml, so the checks-matrix exception is what has to hold"

        # A diff that deletes ci.yml outright, which is neither an addition to
        # the matrix nor something the reads below could survive: every one of
        # them is a `yq` against a file that is no longer there, and an
        # unguarded `yq` here would abort the runner with none of this
        # explanation. Item 5's gate reads the same file and would already have
        # failed on it, which is why this is one line rather than a case in the
        # harness.
        [ -f "$worktree/.github/workflows/ci.yml" ] \
          || hand_back "refusing to push $branch - its diff deletes .github/workflows/ci.yml, and the only change the exception allows is an addition to one list in it"

        base_ci="$run_dir/ci-base.yml"
        git -C "$worktree" show "origin/$base_branch:.github/workflows/ci.yml" > "$base_ci" 2>/dev/null \
          || hand_back "refusing to push $branch - it adds .github/workflows/ci.yml rather than amending the one on $base_branch, and the exception is written against a file that already exists"

        # "Nothing else in ci.yml may differ", asked by normalising the one
        # list that may differ away and comparing what is left. `yq` on both
        # sides rather than a textual diff, because a re-indented or re-quoted
        # file is not a changed one - and the same tool ci.yml's own lint job
        # uses, so the two readings cannot disagree about what the file says.
        #
        # Its limit is written down in afk-eligibility.md and accepted there:
        # yq drops comments on both sides, so a comment-only edit passes.
        # Comments do not execute.
        yq "del(.jobs.checks.strategy.matrix.check)" "$base_ci" > "$run_dir/ci-base.normalised"
        yq "del(.jobs.checks.strategy.matrix.check)" "$worktree/.github/workflows/ci.yml" \
          > "$run_dir/ci-head.normalised"
        diff -u "$run_dir/ci-base.normalised" "$run_dir/ci-head.normalised" \
          > "$run_dir/ci-normalised.diff" \
          || hand_back "$(printf 'refusing to push %s - its ci.yml differs outside jobs.checks.strategy.matrix.check, which is the whole of what the exception allows:\n\n%s' \
            "$branch" "$(cat "$run_dir/ci-normalised.diff")")"

        yq -r ".jobs.checks.strategy.matrix.check[]" "$base_ci" \
          | LC_ALL=C sort > "$run_dir/matrix-was"
        yq -r ".jobs.checks.strategy.matrix.check[]" "$worktree/.github/workflows/ci.yml" \
          | LC_ALL=C sort > "$run_dir/matrix-now"

        # Additions only. An entry removed silently stops a check from running,
        # which is the "gate that quietly stops gating" failure ci.yml's own
        # lint job exists to catch; an entry altered is a removal and an
        # addition, so this catches that too.
        removed="$(comm -23 "$run_dir/matrix-was" "$run_dir/matrix-now")"
        [ -z "$removed" ] \
          || hand_back "refusing to push $branch - its ci.yml diff removes $(tr '\n' ' ' <<<"$removed")from the checks matrix, and a check that stops being listed stops running"

        added="$(comm -13 "$run_dir/matrix-was" "$run_dir/matrix-now")"

        # What the flake actually exposes, re-derived here rather than read
        # from the file the implement gate left behind. That gate already
        # demands the matrix and this list agree exactly, which makes the
        # second half of the loop below redundant today - and that is the
        # point. This check is the last one standing between a workflow edit
        # and a run holding the repository's secrets, so it must not be a
        # reading of another check's homework.
        ( cd "$worktree" \
            && nix eval --raw .#checks.x86_64-linux \
              --apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)' ) \
          | LC_ALL=C sort > "$run_dir/push-checks" \
          || hand_back "refusing to push $branch - the flake's own checks could not be listed, so an added matrix entry cannot be checked against them"

        while IFS= read -r name; do
          [ -n "$name" ] || continue

          # The character class, and it is not belt-and-braces: a matrix entry
          # is interpolated straight into a `run:` script by ci.yml, so it is
          # shell context rather than data, and Nix attribute names can carry
          # arbitrary characters when quoted.
          [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] \
            || hand_back "refusing to push $branch - its ci.yml diff adds the matrix entry '$name', which is not a safe name; entries are interpolated into a shell script by the workflow"

          grep -qxF "$name" "$run_dir/push-checks" \
            || hand_back "refusing to push $branch - its ci.yml diff adds the matrix entry '$name', which names no check this flake exposes"
        done <<<"$added"

        log "#$number: the ci.yml diff is additions-only to the checks matrix, adding $(tr '\n' ' ' <<<"$added")"
      }

      # --- push --------------------------------------------------------------
      #
      # Item 7 (#174), and the step `implement` never does: everything above
      # this line is reversible by deleting a directory.
      #
      # The gate is the first line of this function and the push is the last,
      # with nothing between them (ADR 0007 §6). Called once for the branch's
      # first push and once more for each CI fix round, so a fix that adds a
      # workflow file is refused exactly as the original diff would have been.
      #
      # An explicit refspec rather than a bare `git push`: what gets pushed
      # should not depend on push.default, nor on an upstream item 5 went out
      # of its way not to set. Never `--force`, and never a refspec that could
      # become one: a branch a human may already be reading is not rewritten
      # underneath them (ADR 0007 §4).
      #
      # The credential reaches git through `gh`, which already holds it in the
      # environment, rather than through a remote URL or a config file - so the
      # token never lands in .git/config, in a URL git will echo on failure, or
      # on a command line `ps` can read. The empty helper ahead of it is git's
      # own idiom for "use this one and nothing inherited".
      # `gh auth git-credential` runs in a shell of git's making and reads
      # GH_TOKEN out of the environment, so it never passes through the wrapper
      # above. This is the one call site that has to ask for itself - and a
      # second or third push is further still from the last refresh, which is
      # exactly where a one-hour token would have died.
      push_branch() {
        push_gate

        log "#$number: pushing $branch"
        refresh_gh_token

        git -C "$worktree" \
          -c credential.helper= \
          -c credential.helper='!gh auth git-credential' \
          push origin "HEAD:refs/heads/$branch" \
          || if [ -n "$pr_url" ]; then
            hand_back "$branch did not push, so the CI fix never reached $pr_url - which is open, red, and now a commit behind this worktree"
          else
            hand_back "$branch did not push, so nothing was opened for it"
          fi

        # What separates the hand-backs from here on from every one before it:
        # the branch is on origin now, so pushed work is kept rather than
        # torn down, and once the pull request is open the hand-back reaches
        # it too.
        pushed=1
      }

      push_branch

      # --- raise the pull request, before anything reviews it ----------------
      #
      # ADR 0007 §1. This used to come after the review, which was decided when
      # the review was a gate; item 6 measured that gate away, so what is left
      # of the old order was inheritance. Opening here buys two things: CI - the
      # only reading of this branch that is not the agent marking its own
      # homework - starts now rather than after a stage that decides nothing,
      # and the review that follows runs against a branch nothing will push
      # again, so it is structurally unable to change what is in the pull
      # request rather than merely denied the verbs to.
      # A squash merge takes the pull request's title as its commit subject, so
      # this is a line that ends up in `git log` on master. Where the branch is
      # one commit, that commit's subject is the better answer: the implement
      # stage wrote it in this repository's house style and the gate passed on
      # it. Where the ticket took several attempts, no single subject describes
      # the branch, and the ticket's own title is the honest one.
      commits="$(git -C "$worktree" rev-list --count "origin/$base_branch..HEAD")"
      if [ "$commits" -eq 1 ]; then
        pr_title="$(git -C "$worktree" log -1 --format=%s)"
      else
        pr_title="$title"
      fi

      pr_prose() {
        sed -e "s/ISSUE/$number/g" \
          -e "s|BRANCH|$branch|g" \
          -e "s|IMPLEMODEL|${model}|g" \
          -e "s|REVIEWMODEL|${reviewModel}|g" \
          -e "s/ATTEMPTS/$attempt/g" \
          -e "s/CIROUNDS/$ci_round/g" \
          -e "s|HANDOFF|${handoffLabel}|g" \
          "$1"
      }

      # The body, rendered from whatever is known at the moment it is called.
      # Called twice: once now, with the hand-off section absent because CI has
      # not run and the review has not happened, and once at the end of the run
      # with both. Re-rendered rather than appended to, so the second body is
      # built from the branch as it finally stands - a CI fix round's commits
      # are in the "what the branch says it does" section, and `ATTEMPTS`
      # counts every session that touched it.
      pr_body() {
        {
          pr_prose ${prIntro}

          # What the branch claims to do, in the implementer's own words.
          # Oldest first, subject as a heading and body under it, so a ticket
          # that took three attempts reads as three steps rather than as one
          # wall.
          git -C "$worktree" log --reverse --format='### %s%n%n%b' \
            "origin/$base_branch..HEAD"

          if [ "$1" = with-handoff ]; then
            pr_prose ${prHandoff}

            # The findings the review stage left, carried to the one place they
            # are worth anything: in front of the person deciding whether to
            # merge, next to the diff they are about. The prose above says what
            # they are not. #202 moves them to a comment, which is why they are
            # kept as their own file rather than assembled inline here.
            cat "$review_dir/findings.md"
          fi
        } > "$run_dir/pr-body.md"
      }

      # Zero until CI has been watched at all, which is what the body says at
      # creation time: the hand-off section is absent, so `CIROUNDS` is never
      # read out of this rendering.
      ci_round=0
      pr_body without-handoff

      # `--label` rather than a second call, so a pull request that exists is a
      # pull request that is already attributable at a glance - the other half
      # of what plan item 3 asks the label for, since no ruleset can enforce
      # ADR 0004 §9 here.
      #
      # Nothing arms auto-merge, here or anywhere: this opens the pull request
      # and stops. That is a property of this script rather than of a ruleset
      # (plan item 3), which is why the harness asserts it from both sides -
      # the merge verb appearing nowhere in this script at all, and no
      # auto-merge flag in what `gh` was actually called with. Both of its
      # greps are deliberately crude enough to match prose, so this comment
      # names neither command literally.
      log "#$number: opening the pull request"
      pr_url="$(
        cd "$worktree" \
          && gh pr create \
            --repo "$repo" \
            --base "$base_branch" \
            --head "$branch" \
            --title "$pr_title" \
            --body-file "$run_dir/pr-body.md" \
            --label "$pr_label"
      )" || hand_back "$branch is pushed but the pull request could not be opened"

      log "#$number: opened $pr_url"

      # --- watch the branch's own CI ----------------------------------------
      #
      # ADR 0007 §3: CI is the correctness gate on this path and the review is
      # a quality pass. The local gate above is not redundant - it is cheap,
      # immediate, and it is what decides whether the implement stage converged
      # at all - but it is this runner's reproduction of CI's steps, and the
      # gate's own comment already records that a reproduction can drift from
      # what it copies. CI runs what only CI runs: a cold runner, the sharded
      # check matrix, and every host built from an empty store.
      #
      # THE HARD PART IS TELLING A CHECK THAT NEVER ARRIVES FROM A SLOW ONE,
      # and there is no fact that distinguishes them - only a bound. So there
      # are two, counted in polls rather than seconds (see `ciPollInterval`
      # above): how long a run may go with no check reported for the commit
      # that was just pushed, and how long the whole watch may take. The first
      # is a workflow that was never triggered, which is a configuration
      # problem rather than a problem with the diff and so is never fed back to
      # a model that would have nothing to fix.
      #
      # READ FROM THE PULL REQUEST'S HEAD COMMIT RATHER THAN FROM `gh pr
      # checks`, and the difference is load-bearing. Immediately after a fix is
      # pushed, GitHub can still be reporting the *previous* commit's checks -
      # which for a round that got here are red. A watch that trusted them
      # would spend its second round refusing the fix it had just made, before
      # the fix had been looked at. `statusCheckRollup` comes back beside
      # `headRefOid` in one snapshot, so the commit the verdict belongs to
      # arrives with the verdict and can be compared to the one that was
      # pushed.
      ci_poll_interval="''${AFK_CI_POLL_INTERVAL:-${toString ciPollInterval}}"

      # One snapshot, reduced to a word and - for everything but green - the
      # names behind it. Both check kinds GitHub reports through this field are
      # handled: a `CheckRun` has a `status`/`conclusion` pair, a
      # `StatusContext` has a single `state`, and a rollup can hold both.
      #
      # `|| rollup=""` on the `gh` call rather than a bare one, for the reason
      # `session_id_for` carries a `|| true`: this whole function runs inside a
      # command substitution under `set -euo pipefail`, so a transient API
      # failure would abort the runner outright rather than counting as one
      # poll that saw nothing. The same goes for the `|| printf` after `jq`,
      # which catches an answer that parsed but was not a rollup.
      ci_snapshot() {
        local head=$1 rollup
        rollup="$(gh pr view "$pr_url" --json headRefOid,statusCheckRollup 2>/dev/null)" || rollup=""
        [ -n "$rollup" ] || { printf 'absent\n'; return 0; }

        printf '%s' "$rollup" | jq -r --arg head "$head" '
          def bucket:
            if has("conclusion") then
              if .status != "COMPLETED" then "pending"
              elif .conclusion == null or .conclusion == "" then "pending"
              elif (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then "pass"
              elif .conclusion == "CANCELLED" then "cancelled"
              else "fail"
              end
            else
              if .state == "SUCCESS" then "pass"
              elif .state == "PENDING" or .state == "EXPECTED" then "pending"
              else "fail"
              end
            end;
          def named($b): map(select(.bucket == $b) | .name) | join(", ");
          if (.headRefOid // "") != $head then "absent"
          else
            [ (.statusCheckRollup // [])[]
              | { name: (.name // .context // "an unnamed check"), bucket: bucket } ]
            | if length == 0 then "absent"
              elif (map(select(.bucket == "fail")) | length) > 0 then "red\n" + named("fail")
              elif (map(select(.bucket == "cancelled")) | length) > 0 then "cancelled\n" + named("cancelled")
              elif (map(select(.bucket == "pending")) | length) > 0 then "pending\n" + named("pending")
              else "green"
              end
          end' 2>/dev/null || printf 'absent\n'
      }

      # Poll until the checks on `$1` have settled, or until one of the two
      # bounds runs out. Sets `ci_state` to one of green, red, cancelled,
      # absent or unsettled, and `ci_failed` to whichever checks are behind it.
      ci_state=""
      ci_failed=""
      watch_ci() {
        local head=$1 tick=0 unseen=0 answer state
        while :; do
          answer="$(ci_snapshot "$head")"
          state="$(printf '%s\n' "$answer" | head -n 1)"
          ci_failed="$(printf '%s\n' "$answer" | tail -n +2)"

          case "$state" in
            green | red | cancelled)
              ci_state="$state"
              return 0
              ;;
            absent)
              unseen=$((unseen + 1))
              if [ "$unseen" -ge ${toString ciFirstCheckPolls} ]; then
                ci_state=absent
                return 0
              fi
              ;;
            *)
              # Pending, and the only state worth waiting through.
              ;;
          esac

          tick=$((tick + 1))
          if [ "$tick" -ge ${toString ciSettlePolls} ]; then
            ci_state=unsettled
            return 0
          fi

          sleep "$ci_poll_interval"
        done
      }

      ci_round=1
      while :; do
        pushed_head="$(git -C "$worktree" rev-parse HEAD)"
        log "#$number: watching CI on $pushed_head (round $ci_round of ${toString maxCiRounds})"
        watch_ci "$pushed_head"

        if [ "$ci_state" = green ]; then
          log "#$number: CI is green on $pushed_head after $ci_round round(s)"
          break
        fi

        # Three ways the watch ends without a verdict about the diff. None of
        # them is something a model can fix, so none is fed back to one; each
        # leaves $pr_url open, without the hand-off label, which is what says
        # from the outside that nobody has finished with it (ADR 0007 §2).
        case "$ci_state" in
          absent)
            hand_back "nothing has reported on $pushed_head after ${toString ciFirstCheckPolls} polls - either CI was never triggered for it, or GitHub could not be asked. Neither is something the diff can fix. $pr_url is open and unfinished"
            ;;
          unsettled)
            hand_back "CI on $pushed_head has not settled after ${toString ciSettlePolls} polls, and still has $ci_failed outstanding. $pr_url is open and unfinished"
            ;;
          cancelled)
            hand_back "CI on $pushed_head was cancelled ($ci_failed), so it reached no verdict. $pr_url is open and unfinished, and a re-run is a human's call"
            ;;
        esac

        # THE RECORD PLAN ITEM 13 ASKS FOR, and the reason this line names both
        # gates. The local gate passed on this exact commit; CI did not. If
        # that never happens, this whole stage is latency for its own sake and
        # should be cut. If it happens, the difference between the two readings
        # is what to go and fix - in the local gate, which is the reproduction,
        # rather than in ci.yml.
        log "#$number: CI is red on $pushed_head where the local gate passed. Not green: $ci_failed"

        if [ "$ci_round" -ge ${toString maxCiRounds} ]; then
          hand_back "${toString maxCiRounds} CI round(s) and $branch is still red ($ci_failed). $pr_url is open with the work on it and without the hand-off label; nothing merges it (ADR 0004 §9)"
        fi

        # ADR 0004 §6, applied to a failure it did not anticipate: the fix
        # happens inside the session that produced the failing commit, because
        # a fix that cannot see what it is fixing is close to useless. The
        # session id may never have been looked up - a ticket that converged on
        # its first attempt never needed it - so this is the same read-back the
        # retry path does, with the same refusal behind it.
        if [ -z "$session" ]; then
          session="$(session_id_for "$worktree" "$slug")"
        fi
        [ -n "$session" ] \
          || hand_back "CI is red on $pr_url, but no session titled '$slug' can be found to fix it in; refusing to fix in a fresh context (ADR 0004 §6)"

        # What crosses the boundary is what the model could not see for itself.
        # It is told which checks are not green and where to read them, and
        # told plainly that it is not the one who pushes - `gh pr*` is denied
        # to this session anyway, but a model that spends its round trying is a
        # round spent.
        #
        # `gh run view` is deliberately not denied. It is the only way to turn
        # a check's name into the log that explains it, and it can write
        # nothing.
        ci_message="$(printf '%s\n\n%s\n\n%s\n\n%s' \
          "The pull request for this branch is $pr_url, and CI on it is red on the commit at the head of this branch. This repository's local gate - the same one you have already passed - agreed with that commit, so this is something only CI sees: a cold runner, the sharded check matrix, and every host built from an empty store." \
          "$(printf 'These checks are not green:\n%s' "$ci_failed")" \
          "Read the failing job's log before changing anything: \`gh run view --log-failed --job <id>\`, where <id> is the last path segment of that check's link on the pull request. \`gh run list --branch $branch\` will find the run." \
          "Fix it here, in this worktree, and commit the fix. Do not push and do not touch the pull request - this runner pushes your commit to the same branch afterwards. The local gate has to pass on your fix as well, and there is no retry: this round is judged once.")"

        attempt=$((attempt + 1))
        log "#$number: feeding the red run back into session $session (implement session $attempt)"

        ci_fix_rc=0
        (
          cd "$worktree" || exit 1
          OPENCODE_CONFIG_CONTENT=${lib.escapeShellArg permissionOverlay} \
            timeout ${toString attemptTimeout} opencode run --auto \
              --dir "$worktree" \
              --agent build --model ${model} --variant ${variant} \
              --session "$session" "$ci_message"
        ) || ci_fix_rc=$?

        # Judged by the same four checks an implement attempt is, against the
        # commit that was pushed rather than against the base branch: what has
        # to be true here is that something NEW was committed on top of the red
        # commit.
        #
        # And judged once. A CI fix round gets one session and no retry, which
        # is a deliberate asymmetry with the implement stage rather than an
        # oversight: the local gate has already passed on this branch, so a fix
        # that fails it is the model going backwards rather than failing to
        # converge - and unlike the implement stage there is now a pull request
        # a human can pick up, which is most of what a retry budget was buying.
        attempt_verdict "$ci_fix_rc" "$pushed_head"
        [ -z "$reason" ] \
          || hand_back "the CI fix did not pass, because $reason. $pr_url is open with a red CI run on it; a CI fix gets one session and no retry (ADR 0007)"

        push_branch
        ci_round=$((ci_round + 1))
      done

      # Said once and appended to every hand-back below, because from here on
      # it is the same fact each time and it is the fact ADR 0007 changed: a
      # review that cannot be shown to have run no longer means no pull
      # request, it means a pull request nobody has handed over. The label's
      # absence is what says so from the outside, and the hand-back (item 8,
      # #175) carries the fact onto the ticket and the pull request both.
      unfinished="$pr_url is open and green, without the ${handoffLabel} label; nothing merges it (ADR 0004 §9)"

      # --- review, in a fresh context ---------------------------------------
      #
      # ADR 0004 §6, and item 6 (#173). A self-review in the context that just
      # wrote the code is the weakest form, so this is a new session against
      # the same worktree - never `--session` - however many attempts the
      # implementation took to converge.
      #
      # It runs LAST, after the push and after CI has gone green (ADR 0007
      # §1), which changes what it is rather than only when it happens. It can
      # no longer stop a pull request from existing - one is open - and it can
      # no longer change what is in it: this branch has been pushed and nothing
      # pushes it again, so a commit written here reaches a local ref and
      # stops. `reviewOverlay` and the prompt still deny it the verbs, but the
      # guarantee is now the shape of the run rather than a pattern match on a
      # command line.
      #
      # What it still is: the one stage whose output is prose, and the one
      # nothing downstream can check. So nothing here believes the session's
      # own account of what it did - every claim below is read out of the
      # transcript instead, and each of those checks is fatal, because a review
      # that cannot be shown to have happened is not a review that passed.
      #
      # `--dir` is the load-bearing flag, and it is worth saying why, because
      # the cost of not knowing was item 6's whole first attempt. Item 1's
      # review-stage run reported three separate failures - the `code-review`
      # skill missing, the two axes collapsing into one context, and a sibling
      # checkout reviewed instead of its own - and they were one failure.
      # opencode resolves its project, and with it skill discovery, from the
      # directory it is launched in; the pilot's harness launched it one level
      # above the worktree, where there is no `.agents/skills/` and no git
      # repository. From there `opencode debug skill` returns exactly one
      # skill, `customize-opencode`, which is the error string that run
      # recorded verbatim. The skill error is why no sub-agent ever spawned,
      # and being a directory above its target is why a sibling was in reach
      # to review. Naming the directory explicitly rather than inheriting it
      # from a `cd` is what makes that unrepeatable. The `cd` stays as well:
      # `session list` and `export` below are project-scoped the same way.
      # What the review is about to look at, kept only so that the log below can
      # say if the branch moved under it. Under #174 this was a pin and a
      # refusal, standing in for a guarantee the ordering did not provide; ADR
      # 0007 provides it, so what is left is a fact worth recording rather than
      # a gate.
      reviewed_head="$(git -C "$worktree" rev-parse HEAD)"

      review_dir="$run_dir/review"
      mkdir -p "$review_dir"
      review_title="$slug-review"

      sed -e "s/ISSUE/$number/g" -e "s|BASE|origin/$base_branch|g" \
        ${reviewPrompt} > "$review_dir/prompt"

      log "#$number: reviewing $branch in a fresh session"

      # The overlay is set on the one command it governs rather than exported
      # for the rest of the run. An `export` here would outlive the stage, and
      # what it would hand item 7 (#174) is a deny-set containing `gh pr*` and
      # `git commit*` - the two verbs that stage exists to use. Scoping it is
      # also the honest shape: it describes this session, not this process.
      review_rc=0
      (
        cd "$worktree" || exit 1
        OPENCODE_CONFIG_CONTENT=${lib.escapeShellArg reviewOverlay} \
          timeout ${toString reviewTimeout} opencode run --auto \
            --dir "$worktree" \
            --agent build --model ${reviewModel} --variant ${variant} \
            --title "$review_title" \
            "$(cat "$review_dir/prompt")"
      ) > "$review_dir/run.log" 2>&1 || review_rc=$?

      if [ "$review_rc" -eq 124 ]; then
        hand_back "the review ran past its ${toString reviewTimeout}s ceiling. Review does not retry (ADR 0004 §6). $unfinished"
      elif [ "$review_rc" -ne 0 ]; then
        hand_back "the review session exited $review_rc. Review does not retry (ADR 0004 §6). $unfinished"
      fi

      review_session="$(session_id_for "$worktree" "$review_title")"

      [ -n "$review_session" ] \
        || hand_back "the review exited 0 but no session titled '$review_title' can be found, so there is no transcript to verify it from. $unfinished"

      # Written to a file before jq is pointed at it, for the reason item 1
      # recorded: piping `opencode export` straight into jq truncates on large
      # sessions, and it fails as a parse error rather than as a wrong answer -
      # but only sometimes, which is the worse of the two.
      # `|| true` because a failing `export` has to reach the check below
      # rather than abort the runner here: this is the left side of a
      # redirection, not a condition, so `set -e` would take it.
      ( cd "$worktree" && opencode export "$review_session" ) \
        > "$review_dir/session.json" 2>/dev/null || true

      # And the transcript is checked for the shape the assertions below read,
      # not merely for being JSON. Valid JSON of the wrong shape is the trap
      # here: `jq -e .` is happy with anything parseable, and `.messages[]`
      # against a document without a `messages` array exits 5 - aborting the
      # runner with none of the diagnosis this stage exists to print. Item 1
      # recorded that `opencode export` truncates on large sessions and fails
      # as a parse error only sometimes, which is what makes checking here
      # worth more than a stack of unguarded reads below.
      jq -e 'has("messages") and (.messages | type == "array")' \
        "$review_dir/session.json" > /dev/null 2>&1 \
        || hand_back "the review transcript at $review_dir/session.json is not a readable session, so nothing can be verified from it; opencode export truncates on large sessions (plan item 1). $unfinished"

      # --- did a review actually happen -------------------------------------
      #
      # Asked of the transcript rather than of the session's own summary, and
      # this is the part of the stage with the most evidence behind it. Every
      # failure item 1 saw here was silent: the skill error was reported to the
      # model and not to anybody else, the missing sub-agents left `subagents=0`
      # in an export nobody was reading yet, and the substituted review read
      # exactly like a real one. A stage whose failures all look like passes
      # has to be checked from outside, so these two counts are read out of the
      # tool calls the session actually made.
      #
      # Both are fatal, and fatal in the fail-closed direction: a review that
      # cannot be shown to have happened is not a review that passed.
      skill_calls="$(
        jq '[ .messages[].parts[]?
              | select(.type == "tool" and .tool == "skill")
              | select(.state.status == "completed")
              | select(.state.input.name == "code-review")
            ] | length' "$review_dir/session.json"
      )"

      [ "$skill_calls" -gt 0 ] \
        || hand_back "the review never completed a \`skill\` call for code-review, so whatever it produced was not that skill's review. $unfinished"

      # The two axes are the point of the skill: standards and spec, in
      # genuinely separate contexts so that neither pollutes the other. They
      # arrive as `task` calls, and item 1 expected two. Fewer means they
      # collapsed into the parent context, which is the premise of this stage
      # failing rather than erroring - so it is checked rather than assumed.
      axes="$(
        jq '[ .messages[].parts[]? | select(.type == "tool" and .tool == "task") ] | length' \
          "$review_dir/session.json"
      )"

      [ "$axes" -ge ${toString reviewAxes} ] \
        || hand_back "the review spawned $axes sub-agent(s), not ${toString reviewAxes}; the standards and spec axes collapsed into one context (ADR 0004 §6). $unfinished"

      # And that they are the two axes rather than two sub-agents of any kind.
      # A count alone is satisfied by a session that fanned out twice for its
      # own reasons, which is not the same thing as standards and spec running
      # in separate contexts - and it is the separation, not the fan-out, that
      # ADR 0004 §6 is about.
      #
      # Matched over each call's description and prompt together and folded to
      # lower case, because that wording is the model's rather than this
      # repository's. What is asserted is only that both subjects are present
      # across the calls, which is as much as can be checked from outside
      # without pinning phrasing the skill never fixed. Deliberately loose in
      # the passing direction and strict in the one that matters: two sub-agents
      # sent to do something else entirely do not read as a two-axis review.
      named_axes="$(
        jq '[ .messages[].parts[]?
              | select(.type == "tool" and .tool == "task")
              | ((.state.input.description // "") + " " + (.state.input.prompt // ""))
              | ascii_downcase
            ]
            | [ (map(select(test("standard"))) | length > 0),
                (map(select(test("spec"))) | length > 0) ]
            | all' "$review_dir/session.json"
      )"

      [ "$named_axes" = true ] \
        || hand_back "the review spawned $axes sub-agent(s), but neither a standards nor a spec subject is identifiable across them, so this was not the code-review skill's two-axis pass. $unfinished"

      log "#$number: review ran the code-review skill across $axes axes"

      # --- the findings, which are the whole output of this stage -----------
      #
      # They are worth more on the pull request - where the human who has to
      # merge it reads them alongside the diff - than they ever were as a gate.
      # The body edit below appends this file verbatim to the pull request that
      # is already open; nothing here is the last reader of it, and nothing
      # here decides anything from it.
      #
      # Deliberately NOT fed back to the implement session to be fixed. Item 6
      # originally allowed one fix-and-recheck, and it was dropped on purpose:
      # a finding handed back to the model that just wrote the code becomes a
      # commit, and the gate cannot tell a correct change from a plausible
      # green one. A wrong finding would then cost a real edit and consume the
      # finding itself, where leaving it on the PR costs nothing and keeps it
      # legible. That reasoning outlived the verdict it was written for: with
      # the stage advisory, every finding now travels to the pull request, and
      # none of them is ever handed back to the model that wrote the code.
      jq -r '[ .messages[]
               | select(.info.role == "assistant")
               | .parts[]? | select(.type == "text") | .text
             ] | last // ""' "$review_dir/session.json" > "$review_dir/findings.md"

      # Tested for content rather than for size. `jq -r` on a `// ""` fallback
      # still emits its newline, so the file is one byte when the session
      # produced no text at all and `[ -s ]` would call that a report. Found by
      # removing this branch and watching every case still pass.
      #
      # Still fatal now that the stage is advisory, and for a reason that
      # survived the verdict: the findings are what this stage produces. A
      # review that verifiably ran and then said nothing has produced nothing
      # for the pull request to carry, and passing it on as though it had is
      # the same silent failure the checks above exist to refuse.
      grep -q '[^[:space:]]' "$review_dir/findings.md" \
        || hand_back "the review session produced no closing report, so this stage has nothing to hand to the pull request. $unfinished"

      # No verdict is read out of it, and that is the finding of plan item 6
      # rather than an omission - see the prompt above. The stage's outcome is
      # decided entirely by the provenance checks: a review that can be shown
      # to have run gets its findings carried, and one that cannot has already
      # died above.
      log "#$number: review ran and left $(wc -l < "$review_dir/findings.md") lines of findings in $review_dir/findings.md for the pull request; this stage is advisory and does not gate (plan item 6)"

      # --- did the review write anything anyway -----------------------------
      #
      # Report-only is asked for in the review prompt and denied in
      # `reviewOverlay`, and neither is a capability boundary: both are pattern
      # matches on a command line, and `git -C . commit` matches neither. Under
      # #174 this was a refusal, because the push came afterwards and a commit
      # written here would have gone out having never been gated. ADR 0007
      # removed the reason: the push is behind us, nothing pushes this branch
      # again, and the pull request cannot be reached from here.
      #
      # So it is a log line rather than a gate. Not deleted outright, because
      # a review session that committed has bypassed both controls that were
      # meant to stop it, and that is worth knowing about even when it can no
      # longer do any harm - it is otherwise entirely invisible, since a
      # session that commits leaves a clean tree behind it.
      review_head="$(git -C "$worktree" rev-parse HEAD)"
      if [ "$review_head" != "$reviewed_head" ]; then
        log "#$number: the review stage moved $branch from $reviewed_head to $review_head. It is report-only and was denied both file edits and commits, so it got past both; nothing pushes this branch again and $pr_url is unaffected, but the deny-set is not doing what it claims"
      fi

      # --- hand over --------------------------------------------------------
      #
      # The findings could not be in the body at creation time, because the
      # review had not run (ADR 0007). So the body is re-rendered with the
      # hand-off section in it and written over the one already there, which is
      # the interim `gh pr edit --body-file` this item accepted: it keeps the
      # body/comment separation item 12's author filter depends on, where a
      # comment would not until #202 lands.
      #
      # ONE `gh pr edit` RATHER THAN TWO, for the same reason the claim is one
      # `gh issue edit`. The label is the hand-off signal - it says CI is green
      # and a review has run - and a pull request that carried it while its
      # body still had no findings under it would be saying something untrue
      # for however long the second call took.
      #
      # The label is a signal and not a control (ADR 0007 §7). Nothing here or
      # at GitHub's end stops a merge before it is applied, and nothing should:
      # ADR 0004 §9 makes merging a human act, and a runner that could withhold
      # a merge would hold a veto over the person rather than the other way
      # round.
      pr_body with-handoff

      log "#$number: handing over - writing the findings onto $pr_url and labelling it ${handoffLabel}"

      gh pr edit "$pr_url" \
        --repo "$repo" \
        --body-file "$run_dir/pr-body.md" \
        --add-label "${handoffLabel}" \
        || hand_back "$pr_url is open and green, but the review's findings could not be written onto it, so it stays without the ${handoffLabel} label"

      # The notification (item 9, #176): the whole point of the hand-off
      # label, delivered to somebody who is not watching GitHub. Priority low
      # - informational, silent, the lane's warning level - because nothing
      # here is wrong and nothing is waiting on this beyond a person finding
      # a quiet moment to read the diff.
      notify low white_check_mark "AFK agent: PR ready for review (#$number)" \
        "$(printf '%s\n%s' "$pr_url" "$title")"

      # --- and nothing is left in flight ------------------------------------
      #
      # The worktree goes now that the branch is somewhere durable. The
      # in-flight guard at the top of this script refuses to poll past any
      # leftover worktree, so a ticket that finished and left one behind would
      # wedge every later poll: a pipeline that works exactly once. Item 8
      # (#175)'s guard is also what heals this if the removal ever does fail -
      # it finds the leftover, sees the open pull request for the branch, and
      # clears the worktree without touching the ticket.
      #
      # The local branch stays, deliberately. It costs nothing, `git worktree
      # remove` leaves it anyway, and it is what makes the "branch already
      # exists" check above refuse a ticket whose pull request is still open,
      # if one is ever unassigned and re-labelled while it is.
      #
      # No --force. The tree was asserted clean before the gate and the gate
      # writes nothing into it, so a removal that fails means an uncommitted
      # file appeared after the last thing that checked - which is the review
      # stage getting past `edit: deny`, logged above but not otherwise
      # stoppable. The next poll's guard clears it without touching the
      # ticket, since a pull request is open for its branch.
      git -C "$checkout" worktree remove "$worktree" \
        || die "#$number: $pr_url is open, but $worktree could not be removed; the next poll's guard clears it without touching the ticket"

      log "#$number: done - $pr_url is open on $branch. Merging it is a human act (ADR 0004 §9), and nothing here does it"
    '';
  };
in
{
  options.cg.service.afk-agent = {
    enable = lib.mkEnableOption ''
      the unattended AFK ticket runner.

      The pre-push denylist gate this switch used to wait on has landed (item
      7, #174), and so has the stuck path (item 8, #175): a ticket the runner
      cannot carry to a hand-off is commented on, relabelled `agent-stuck`,
      and torn down - so a failure neither wedges the next poll nor strands a
      claimed ticket. Past the push the hand-back reaches the pull request
      too: it is commented on and left open without the hand-off label, since
      it holds real work (ADR 0007 §2). Notifications through the self-hosted
      ntfy server (item 9, #176) - a handed-over pull request and a handed-back
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

        It grew from 7h with #201, which added the CI rounds - and 7h had
        already grown from the 4h item 4 guessed at before the implement stage
        existed and the 6h that stage left behind, where a 6h bound left fifteen
        minutes for a clone, a fetch, and everything else that is not one of
        those.

        This is the outer bound rather than an expected duration - every
        measured run of every stage is far inside it - but it is not free.
        Concurrency here is one (ADR 0004 §8), so a run that hangs blocks every
        later poll until this ceiling stops it, and a run that reaches it is
        killed mid-ticket; the next poll's guard finds the worktree it left
        and hands that ticket back (item 8, #175) - leaving an open pull
        request untouched too, past the push (ADR 0007).
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
