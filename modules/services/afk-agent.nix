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
# (#173, item 6), and the push and pull request that end a run (#174, item 7).
# A successful ticket now ends with a pull request open, the worktree gone, and
# nothing in flight. The stuck path that hands back a ticket that failed
# instead (#175) is the one stage still missing, and it is why every refusal
# below still ends in a red unit and a worktree somebody has to clear by hand.
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
# below now forbids. Item 7 attaches these findings to the pull request; it
# does not read them as a decision, there is no longer a verdict for it to
# mistake for one, and `prBody` spends a paragraph telling the person who does
# read them what they are not.
#
# THE MODEL NEVER PUSHES; THE RUNNER DOES. Both sessions are denied `git push`,
# `gh pr` and every tracker verb through OpenCode's own permission layer
# (`permissionOverlay`, `reviewOverlay`) rather than merely asked not to use
# them, and the script pushes afterwards, from outside the session, only past
# the pre-push gate that reads the diff. Nothing anywhere here merges or arms
# auto-merge: ADR 0004 §9 cannot be a ruleset in this repository (plan item 3),
# so it is a property of this script, asserted from outside by the harness.
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

  # Ceiling on the review pass (item 6, #173), for the same reason
  # `attemptTimeout` exists: a stage that hangs should fail the runner's own
  # way, countable, rather than by systemd killing the unit mid-ticket and
  # leaving a worktree the in-flight guard then refuses to poll past.
  #
  # Measured runs of this stage finished in 2-10 minutes across both models and
  # all 25 arm runs, so this is generous by an order of magnitude rather than
  # tight. It matches the ceiling item 1's pilot used for the same call, which
  # is the only number with real runs behind it. Left unchanged when review
  # moved to `deepseek-v4-pro`: that model's slowest measured run was 10
  # minutes, still a third of this.
  reviewTimeout = 1800;

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

  # The pull request's body, in two halves with the branch's own commit
  # messages between them and the review's findings after them. Files in the
  # store with substituted tokens, for the same reason the two prompts above
  # are: this is prose, and prose does not survive being a shell literal in a
  # script this one's shape.
  #
  # `ISSUE`, `BRANCH`, `IMPLEMODEL`, `REVIEWMODEL` and `ATTEMPTS` are
  # substituted at run time; nothing else in them varies. No token is a
  # substring of another, which is what keeps one `sed` expression from eating
  # the next.
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
    claimed from `ready-for-agent`, implemented by `IMPLEMODEL` in ATTEMPTS
    attempt(s), and pushed only once this repository's own gate passed on the
    commit at the head of the branch: `nix fmt -- --ci`, `nix flake check`, a
    build of every host, and agreement between the checks the flake exposes and
    the matrix in `ci.yml`. The diff was checked against the path denylist in
    `docs/agents/afk-eligibility.md` before the push as well as before the
    claim.

    **No person has read this diff.** Nothing in this pipeline merges and no
    auto-merge is armed on this path: merging is a human act (ADR 0004 §9).

    ## What the branch says it does

    Quoted from its own commit messages, unedited. The review below was asked
    to report any claim in them that is not true of the diff.

  '';

  prReviewIntro = pkgs.writeText "afk-agent-pr-review-intro" ''
    ## The review below is advisory, and is not an approval

    `code-review` ran against this branch on `REVIEWMODEL`, in a fresh context,
    across its standards and spec axes. The runner verified that from the
    session transcript rather than from the session's own account of itself,
    and would not have opened this pull request otherwise. It decided nothing,
    and nothing downstream read it as a decision
    (`docs/plans/afk-agent-pipeline.md`, item 6).

    Two measured things are worth holding while reading it. Its findings are
    accurate - nine recurring themes across 25 runs were checked against
    source and all nine were true - but across 15 runs on a diff with an
    independently graded defect it never once refused that diff for the defect
    in it, and it has repeatedly written that a criterion holds without
    running anything that shows it. A finding here is worth reading. A silence
    here is worth nothing.

    ---

  '';

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
      pr_label="afk-agent"

      checkout="$state_dir/checkout"
      worktrees="$state_dir/worktrees"

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

      # --- review, in a fresh context ---------------------------------------
      #
      # ADR 0004 §6, and item 6 (#173). A self-review in the context that just
      # wrote the code is the weakest form, so this is a new session against
      # the same worktree - never `--session` - however many attempts the
      # implementation took to converge.
      #
      # It is also the last stage that can stop a ticket before a human sees
      # it, and the one whose output is prose. Both facts shape what follows:
      # nothing here believes the session's own account of what it did, and
      # the one bit this stage needs out of a page of English is asked for in
      # a fixed shape rather than parsed out of it.
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
      # What the review is about to look at, kept so that what gets pushed can
      # be checked against it below. Interim: #201 opens the pull request
      # before this stage runs, which makes the same guarantee structural and
      # this pin dead code to delete.
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
        die "#$number: the review ran past its ${toString reviewTimeout}s ceiling. Review does not retry (ADR 0004 §6); handing the ticket back is the stuck path, item 8 (#175)"
      elif [ "$review_rc" -ne 0 ]; then
        die "#$number: the review session exited $review_rc. Review does not retry (ADR 0004 §6); handing the ticket back is the stuck path, item 8 (#175)"
      fi

      review_session="$(session_id_for "$worktree" "$review_title")"

      [ -n "$review_session" ] \
        || die "#$number: the review exited 0 but no session titled '$review_title' can be found, so there is no transcript to verify it from"

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
        || die "#$number: the review transcript at $review_dir/session.json is not a readable session, so nothing can be verified from it; opencode export truncates on large sessions (plan item 1)"

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
        || die "#$number: the review never completed a \`skill\` call for code-review, so whatever it produced was not that skill's review"

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
        || die "#$number: the review spawned $axes sub-agent(s), not ${toString reviewAxes}; the standards and spec axes collapsed into one context (ADR 0004 §6)"

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
        || die "#$number: the review spawned $axes sub-agent(s), but neither a standards nor a spec subject is identifiable across them, so this was not the code-review skill's two-axis pass"

      log "#$number: review ran the code-review skill across $axes axes"

      # --- the findings, which are the whole output of this stage -----------
      #
      # They are worth more on the pull request - where the human who has to
      # merge it reads them alongside the diff - than they ever were as a gate.
      # The pull request body below appends this file verbatim; nothing here is
      # the last reader of it, and nothing here decides anything from it.
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
        || die "#$number: the review session produced no closing report, so this stage has nothing to hand to the pull request"

      # No verdict is read out of it, and that is the finding of plan item 6
      # rather than an omission - see the prompt above. The stage's outcome is
      # decided entirely by the provenance checks: a review that can be shown
      # to have run gets its findings carried, and one that cannot has already
      # died above.
      log "#$number: review ran and left $(wc -l < "$review_dir/findings.md") lines of findings in $review_dir/findings.md for the pull request; this stage is advisory and does not gate (plan item 6)"

      # --- the review changed nothing --------------------------------------
      #
      # Report-only is asked for in the review prompt and denied in
      # `reviewOverlay`, and neither is a capability boundary: both are pattern
      # matches on a command line, and `git -C . commit` matches neither. The
      # implement stage's own checks do not cover this either - they run before
      # the review, not after it - so without this a commit the review wrote
      # would be pushed having never been through the gate.
      #
      # The tree being clean is not the same question and is not enough: a
      # session that committed leaves a clean tree, and the teardown at the end
      # of this run would happily remove it.
      #
      # Interim, and #201 is what removes it: with the pull request opened
      # before the review, a commit written afterwards cannot reach it at all,
      # and a check becomes an impossibility.
      [ "$(git -C "$worktree" rev-parse HEAD)" = "$reviewed_head" ] \
        || die "#$number: the review stage moved $branch from $reviewed_head to $(git -C "$worktree" rev-parse HEAD). Review is report-only, and a commit it wrote has not been through the gate"

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
      # Run here rather than the moment the implement stage converged, which
      # would be cheaper by one review on a ticket that ends up refused. The
      # review session is denied `edit` through a pattern match on a command
      # line rather than by a capability boundary, so a gate placed before it
      # is a gate something after it can still get past. Ten cents against the
      # fleet is not a trade worth taking.
      #
      # Every refusal here leaves a claimed ticket, a local branch and a
      # worktree, exactly as an exhausted retry budget does; handing those back
      # is the stuck path, item 8 (#175).
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
              die "#$number: refusing to push $branch - its diff changes '$path', which no AFK diff may touch and which has no exception (docs/agents/afk-eligibility.md rule 1). Handing the ticket back is the stuck path, item 8 (#175)"
              ;;
            # The one file with an exception, checked below rather than here.
            .github/workflows/ci.yml) ;;
            .github/workflows/*)
              die "#$number: refusing to push $branch - its diff changes '$path'. The only workflow file an AFK diff may touch is ci.yml, and only its checks matrix (docs/agents/afk-eligibility.md)"
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
          || die "#$number: refusing to push $branch - its diff deletes .github/workflows/ci.yml, and the only change the exception allows is an addition to one list in it"

        base_ci="$run_dir/ci-base.yml"
        git -C "$worktree" show "origin/$base_branch:.github/workflows/ci.yml" > "$base_ci" 2>/dev/null \
          || die "#$number: refusing to push $branch - it adds .github/workflows/ci.yml rather than amending the one on $base_branch, and the exception is written against a file that already exists"

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
          || die "$(printf '#%s: refusing to push %s - its ci.yml differs outside jobs.checks.strategy.matrix.check, which is the whole of what the exception allows:\n\n%s' \
            "$number" "$branch" "$(cat "$run_dir/ci-normalised.diff")")"

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
          || die "#$number: refusing to push $branch - its ci.yml diff removes $(tr '\n' ' ' <<<"$removed")from the checks matrix, and a check that stops being listed stops running"

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
          || die "#$number: refusing to push $branch - the flake's own checks could not be listed, so an added matrix entry cannot be checked against them"

        while IFS= read -r name; do
          [ -n "$name" ] || continue

          # The character class, and it is not belt-and-braces: a matrix entry
          # is interpolated straight into a `run:` script by ci.yml, so it is
          # shell context rather than data, and Nix attribute names can carry
          # arbitrary characters when quoted.
          [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] \
            || die "#$number: refusing to push $branch - its ci.yml diff adds the matrix entry '$name', which is not a safe name; entries are interpolated into a shell script by the workflow"

          grep -qxF "$name" "$run_dir/push-checks" \
            || die "#$number: refusing to push $branch - its ci.yml diff adds the matrix entry '$name', which names no check this flake exposes"
        done <<<"$added"

        log "#$number: the ci.yml diff is additions-only to the checks matrix, adding $(tr '\n' ' ' <<<"$added")"
      }

      push_gate

      # --- push, and raise the pull request ---------------------------------
      #
      # Item 7 (#174), and the step `implement` never does: everything above
      # this line is reversible by deleting a directory.
      log "#$number: pushing $branch"

      # An explicit refspec rather than a bare `git push`: what gets pushed
      # should not depend on push.default, nor on an upstream item 5 went out
      # of its way not to set.
      #
      # The credential reaches git through `gh`, which already holds it in the
      # environment, rather than through a remote URL or a config file - so the
      # PAT never lands in .git/config, in a URL git will echo on failure, or
      # on a command line `ps` can read. The empty helper ahead of it is git's
      # own idiom for "use this one and nothing inherited".
      git -C "$worktree" \
        -c credential.helper= \
        -c credential.helper='!gh auth git-credential' \
        push origin "HEAD:refs/heads/$branch" \
        || die "#$number: $branch did not push, so no pull request was opened. Handing the ticket back is the stuck path, item 8 (#175)"

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
          "$1"
      }

      {
        pr_prose ${prIntro}

        # What the branch claims to do, in the implementer's own words. Oldest
        # first, subject as a heading and body under it, so a ticket that took
        # three attempts reads as three steps rather than as one wall.
        git -C "$worktree" log --reverse --format='### %s%n%n%b' \
          "origin/$base_branch..HEAD"

        pr_prose ${prReviewIntro}

        # The findings the review stage left, carried to the one place they
        # are worth anything: in front of the person deciding whether to
        # merge, next to the diff they are about. The prose above says what
        # they are not. #202 moves them to a comment, once there is an account
        # that makes them distinguishable from the human's own.
        cat "$review_dir/findings.md"
      } > "$run_dir/pr-body.md"

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
      )" || die "#$number: $branch is pushed but the pull request could not be opened. Handing the ticket back is the stuck path, item 8 (#175)"

      log "#$number: opened $pr_url"

      # --- and nothing is left in flight ------------------------------------
      #
      # The worktree goes now that the branch is somewhere durable. The
      # in-flight guard at the top of this script refuses to poll past any
      # leftover worktree, so a ticket that finished and left one behind would
      # wedge every later poll: a pipeline that works exactly once. Item 8
      # (#175) owns the same clean-up for a run that failed, where the question
      # is harder because there is a claimed ticket to hand back; the
      # successful half is one line and belongs where the run ends.
      #
      # The local branch stays, deliberately. It costs nothing, `git worktree
      # remove` leaves it anyway, and it is what makes the "branch already
      # exists" check above refuse a ticket whose pull request is still open,
      # if one is ever unassigned and re-labelled while it is.
      #
      # No --force. The tree was asserted clean before the gate, the gate
      # writes nothing into it, and the review stage cannot edit - so a removal
      # that fails means something happened that none of those allow for, and
      # the next poll refusing to start is the correct amount of noise.
      git -C "$checkout" worktree remove "$worktree" \
        || die "#$number: $pr_url is open, but $worktree could not be removed; every later poll refuses to start until it is gone"

      log "#$number: done - $pr_url is open on $branch. Merging it is a human act (ADR 0004 §9), and nothing here does it"
    '';
  };
in
{
  options.cg.service.afk-agent = {
    enable = lib.mkEnableOption ''
      the unattended AFK ticket runner.

      The pre-push denylist gate this switch used to wait on has landed (item
      7, #174). The diff is now read against docs/agents/afk-eligibility.md
      immediately before the push, which is the last moment anything can:
      `AFK_AGENT_TOKEN` carries the Workflows permission (item 3), so nothing
      at GitHub's end stops this service pushing a branch that edits
      `.github/workflows/`, and a pushed branch runs its own workflow with the
      repository's secrets before anyone reads the pull request.

      Two things still argue for leaving it off. #190 asks whether `deploy`
      should restrict who may push, and `deploy` is a shorter route to the
      fleet than any workflow edit - worth answering before an unattended
      process holds a credential that can take it. And the stuck path (item 8,
      #175) does not exist yet, so a ticket that fails leaves itself claimed
      and its worktree on disk, and every later poll refuses to start until a
      person clears it
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
      default = "7h";
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
        with a gate after each, and then the review pass at its own, which is
        why it is neither the 4h item 4 guessed at before the implement stage
        existed nor the 6h that stage left behind: three attempts, three gates
        and one review come to 5h45m of ceilings, and a 6h bound left fifteen
        minutes for a clone, a fetch, and everything else that is not one of
        those. It is the outer bound rather than an expected duration - every
        measured run of either stage is far inside it - and a run that reaches
        it is killed mid-ticket and leaves a worktree behind, which the
        in-flight guard then refuses to poll past until item 8 (#175) can
        clear it.
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
