# ADR 0007: The pull request opens before the review, and CI is the gate

- **Status:** Proposed
- **Date:** 2026-09-09
- **Related Artefacts:**
    - Amends: [ADR 0004](0004-afk-agent-runs-self-hosted-with-a-harness-split.md) §6, whose closing "never a PR" was written when the review was a gate. Its retry-in-the-same-session rule is upheld here and extended to a new kind of failure; §9 is untouched
    - Answers: #201, #271, and (the amendment block at §3) #269
    - Depends on: [ADR 0006](0006-the-runner-is-a-github-app.md), which gives the runner an identity that can edit a pull request body without being mistaken for the operator
    - Constrains: `docs/plans/afk-agent-pipeline.md` (items 12 and 15, since shipped), `modules/services/afk-agent.nix` (items 8 and 13's shipped implementation), `docs/agents/triage-labels.md` (the hand-off label), `docs/agents/afk-eligibility.md` (the pre-push gate's placement)

## Context

ADR 0004 §6 fixed an order: implement, then review in a fresh context, then - if the review agreed - a pull request. The review was the last thing standing between generated code and a human's attention, so it went last and it decided.

Plan item 6 measured that gate and removed it. Across 25 runs on the one diff in this repository with an independently graded defect, over two models, three prompts and five arms, the review stage never once refused that diff _for the defect in it_; the rubric that refused most reliably refused the correct implementation too. The stage now reports findings and decides nothing, and its accuracy - nine recurring finding-themes checked against source, nine true - is what makes it worth its ten cents. Nothing downstream reads it.

So the order that remains is inherited rather than chosen, and it costs two things.

**CI runs last.** The runner's local gate is a reproduction of CI's steps, written out in `modules/services/afk-agent.nix` and already recorded there as able to drift from the thing it copies. CI additionally runs what only CI runs: a cold runner, the sharded check matrix, every host built from a clean store. It is the only reading of the branch that is not the agent marking its own homework, and today it starts after a stage whose output decides nothing.

**The review sits between the gate and the push.** `edit: deny` and `git commit*: deny` on the review session are pattern matches on a command line, not capability boundaries - `git -C . commit` matches neither. A review session that committed would have that commit pushed, having never been through the gate. #174 pinned `HEAD` across the stage against exactly that, which is a check standing in for a structure.

There is a sentence in the way. ADR 0004 §6 ends: "A ticket that exhausts its retries, or otherwise can't proceed, gets a comment, a relabel, and a notification - never a PR." Opening the pull request before the review means a run that then fails leaves one open. That is a decision, not a detail, so it is settled here rather than amended quietly into a plan (`docs/agents/domain.md`).

## Decision

**1. The pull request opens before the review.** The order is: implement to convergence against the local gate, check the diff against the path denylist, push, open the pull request, watch its checks, then review and post the findings on that pull request as a comment - one comment, headed by the measured caveat, posted by the agent's own account so the author filter below keeps it out of the revision loop's inputs (#202). The body keeps the issue link, the provenance and what the branch says it does, and says there where the findings arrive instead of carrying them. This amends the last sentence of ADR 0004 §6, and only that sentence.

**2. "Never a PR" is narrowed rather than dropped.** It still holds everywhere it was aimed: a ticket that cannot be implemented, that fails the denylist, or that cannot be pushed produces no pull request, because the push is what creates one and nothing before it has happened. What changes is what "can't proceed" means _after_ the push. Past that point the pull request exists, and the honest thing is to leave it open and withhold the signal that says it is finished - not to close or delete work a human may want. The comment, relabel and notification §6 asks for are unchanged; the stuck path now has to reach a pull request as well as an issue.

> **Amended 2026-09-11 (the hand-back's destination, #271).** "Reach a pull request as well as an issue" is tightened: past the push, the hand-back lives on the pull request and nowhere else - the comment, the `agent-stuck` label and the notification's link are the pull request's, and the issue is touched only to lose its claim marker. The reason is the same as the reason the pull request opens early: past the push the work and the failure are both the pull request's, so a story told in both places is two threads for one fact, and the thread the reviewer is already reading is where the decision also has to be made. Before the push there is no pull request, and the hand-back stays on the issue, where the triage reads; the dead-run guard's writes stay there too, because by the time it fires no pull request exists. A pull request carrying `agent-stuck` means the same as an issue carrying it: the runner stopped without finishing, and its comments say why. What a human does next is unchanged, except that past the push the pull request is where it happens.

**3. CI is the correctness gate; the review is a quality pass.** The runner's local gate keeps its job - it is what decides whether the implement stage converged, and it is cheap and immediate - but the branch's own CI run is what has to be green before the work is handed over. The review is asked for findings a person reads next to the diff, which is what item 6 measured it to be good at.

> **Amended 2026-09-11 (the degraded review, after #269's investigation of #267's stuck exit).** §3's findings-comment verification was written fail-closed while the fail-closed stance of ADR 0004 §6 still made sense: a review whose transcript could not show the two-axis fan-out (the `code-review` skill's standards and spec sub-agent contexts) handed the whole ticket back. That made sense as a gate stance, and this ADR removed the gate. What the mismatch cost in practice: on #267 the review session invoked the skill and then performed both axes itself in the parent context - model behavior, non-deterministic as agent behavior always is - and the runner answered a spend problem by stranding a green pull request without the hand-off label. The only reader of the findings is the person at the pull request, so the fix for findings of the wrong shape is on their face, not in their absence. The rule now: two things hand back, and both are about the output possibly not being the review it claims to be or not being there at all - no completed `skill` call for `code-review`, and no closing findings. The fan-out's shape is provenance: what the transcript cannot certify is stated on the findings' face instead of the two-axis sentence it cannot support, logged and carried on the hand-off notification so a degradation rate worth acting on stays observable. The hand-off label's meaning is unchanged - CI is green and a review has run, whatever shape that review took - because the caveat, not the label, is what carries the shape.

**4. A red CI run is fed back into the implement session**, in the session that produced the failing commit, and the fix is pushed to the same branch. This is ADR 0004 §6's retry rule applied to a failure it did not anticipate, and it is upheld rather than reinterpreted: a retry that cannot see what it is retrying against is close to useless. Never a force-push - a branch a human may already be reading is not rewritten underneath them.

> **Amended 2026-09-11 (the leased revision push, after #263's revise failure).** The revision lane rewrites the branch it resumes, because the session there responds to review comments on work this runner itself pushed, and amend-or-replay is sometimes the cleaner edit than a stack of "address review" fixup commits. Its push carries `--force-with-lease` pinned to the origin head the round resumed at, so a rewrite lands only where nobody has pushed since the round started. The rule this narrows into is: the runner never rewrites over a push it did not observe itself making. The ticket lane keeps the plain push, and §4 holds unchanged everywhere the branch carries anything but agent-authored work.

**5. The number of CI rounds, and what a failed fix does, are bounded.** Both are parameters, owned by `modules/services/afk-agent.nix`. What is decided here is that they are bounded at all, and that exhausting them stops the run rather than merging, retrying forever, or handing over anyway.

**6. The pre-push denylist gate moves with the push.** It runs immediately before every push, with nothing between the two - including the push a CI fix round makes. It remains the only enforcement of `docs/agents/afk-eligibility.md` on the push path, and the reason is unchanged: a pushed branch runs its own workflow file with this repository's secrets before anybody reads it.

**7. The hand-off is a label, and a label is a signal rather than a control.** It says "CI is green and a review has run", not "you may merge". Nothing prevents a merge before it is applied, and nothing should: ADR 0004 §9 makes merging a human act, and a mechanism that could withhold a merge would be the runner acquiring a veto over the human instead of the other way round. Which label, and its wording, are parameters recorded in `docs/agents/triage-labels.md`.

**8. What CI catches that the local gate did not is recorded.** The runner logs it when it happens. If the answer turns out to be "nothing, ever", this stage is latency for its own sake and should be cut; if it is drift between the local gate and `ci.yml`, that drift is worth fixing where it starts. Neither is knowable today, and the stage is built so that the question can be answered rather than argued about.

## Consequences

**Positive**

- The review becomes structurally unable to change what is in the pull request. A commit it writes after the push is a local commit on a branch nothing will push again, so #174's `HEAD` pin stops standing in for a guarantee and can be deleted.
- The check that decides correctness is the one that runs the real workflow on a cold runner, rather than the agent's own reproduction of it.
- A red branch is fixed by the session that wrote it, before a human ever sees it, instead of arriving as a red pull request somebody has to hand back.
- The drift the local gate was always able to have becomes observable, because something now compares the two readings on every ticket.

**Negative**

- A failed run can now leave a pull request open. That is the point, and it is still a mess somebody has to clear - a larger mess than the claimed ticket and stray worktree it already leaves.
- The runner's wall-clock ceiling grows substantially. CI on this repository is minutes-to-tens-of-minutes, and watching it twice with a fix in between has to fit under one `TimeoutStartSec`. Concurrency is one (ADR 0004 §8), so a run that reaches its ceiling blocks every later poll for that whole time.
- The pull request body is re-rendered after the fact - at hand-off, so a CI fix round's commits and the final attempt count are in it - and a reader who arrives between the two sees an older body. It is a body that always says where the findings arrive, so the window shows no lies, only staleness. The findings are not in the body at either call: since #202 they travel as a comment posted by the agent's own account, which is also what lets ADR 0006's author filter keep them out of the agent's own instructions. A comment that fails to post hands the run back rather than applying the label that says the review ran.
- The runner now depends on GitHub's check-run reporting being truthful and prompt. A required check that never arrives looks exactly like a slow one, and telling them apart is a timeout rather than a fact.

## Alternatives considered

- **Keep the order and simply delete the review's gate role**, which is what item 6 did and where this started. Rejected: it leaves CI running last, after the stage that no longer decides anything, and it leaves the `HEAD` pin standing in for a structural guarantee. The ordering was a consequence of the gate, and removing the gate without the ordering keeps the cost and drops the benefit.
- **Open the pull request as a draft and mark it ready** once CI is green and the review has run. Genuinely attractive: GitHub refuses to merge a draft, so the hand-off would be a control rather than a signal, with nothing for the runner to enforce in its own code. Rejected because that is the wrong direction of authority. ADR 0004 §9 makes merging a human act; a draft would let the runner _withhold_ a merge a human wants - including when the runner has simply died mid-run - which is a veto it should not have. §9 constrains the runner, not the person.
- **Run the review before the push and keep it advisory**, moving only CI. Rejected: it keeps the review inside the window where a commit it wrote can still be pushed, which is the half of this that is a safety property rather than a preference.
- **Let CI rounds spend the implement stage's retry budget** rather than having their own. Rejected: the two budgets bound different failures. The implement budget bounds "the model cannot converge against the local gate"; a CI round bounds "the local gate and CI disagree". A ticket that needed all three attempts is if anything _more_ likely to need a CI round, so a shared budget would deny rounds exactly where they are most likely to be earned.
- **Wait for CI without a ceiling**, since a required check does eventually arrive or the platform is broken. Rejected: concurrency is one, so an unbounded wait is an unbounded outage of the whole pipeline, and "the platform is broken" is precisely the case a timer-driven runner has to survive without a person.
