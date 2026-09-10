# AFK agent: pilot findings

Measured evidence behind two decisions baked into `modules/services/afk-agent.nix`: the implement model (`glm-5.3-flash`) and the review model (`deepseek-v4-pro`), plus the recurring failure reasons the runner's prompts were written against. This is a historical record of what was run and what it showed - not a spec, not a decision record, and not expected to change. The decisions themselves, and why the split between decision and parameter matters, are in [ADR 0004](../adr/0004-afk-agent-runs-self-hosted-with-a-harness-split.md); the numbers behind them are here.

Raw evidence (session logs, exports, grading rubrics) lived under `~/pilot/` on the machine that ran it and is not part of this repository.

## Implement model: the measured pilot

Three unknowns sat under ADR 0004's harness split: whether a Go-hosted model produces mergeable output on this codebase's tickets, whether OpenCode reads `.agents/skills/` well enough to run something equivalent to `implement`/`code-review`, and what a ticket actually costs.

**Skills discovery works; invocation is not guaranteed.** `opencode debug skill` resolves all 25 skills in `.agents/skills/` off disk, including through a `git worktree add` checkout. But discovery is not invocation - a weaker model may never call the `skill` tool and improvise instead (observed: a real session made 41 tool calls and never called `skill`). The runner's prompts name skills explicitly rather than hoping, and sessions are checked for the call rather than trusted.

**Five arms compared**, on OpenCode Go: `deepseek-v4-flash`, `deepseek-v4-pro`, `glm-5.3`, `glm-5.3-flash` (all at `high` effort), plus the winner of those four re-run at `low` and `max`. A non-candidate Claude Code/Opus 5 run served as a calibration ceiling. Two tickets: #178 (a small, mechanically-checkable desktop-config fix) for repeated comparison, #159 (real logic, a stated invariant) as a frozen-prompt holdout run once per surviving arm.

**Isolation matters for repeated runs.** An early repeat read a prior repeat's committed solution via a shared object store (`git worktree add` shares refs with the origin checkout) and built on it instead of solving independently - disqualified as a data point. Fix: an isolated clone (`--no-local --single-branch`) per run, not a worktree of the source repo.

**Results, `deepseek-v4-flash` (arm A):** 2/3 clean convergence (one clean timeout). Dropped after ranking last in blind pairwise comparison on both repeats.

**Results, `deepseek-v4-pro` (arm B):** 6/6 convergence, $0.76-$0.99/run. Fixed a colour-format bug on one repeat but not the other (within-arm inconsistency). On the holdout ticket, shipped a genuine false positive - the ticket's stated invariant was explained correctly in prose but enforced in the wrong place - and its own completion report claimed the untested case was covered when it was not.

**Results, `glm-5.3` (arm C):** 6/6 convergence, but $1.72-$3.11/run - over a quarter of the Go plan's 5-hour spend cap for one run. Dropped on cost.

**Results, `glm-5.3-flash` (arm D, winner):** 6/6 convergence, $0.036-$0.086/run (15-25x cheaper than `deepseek-v4-pro`). Ranked 1st and 3rd of six real candidates in blind pairwise grading (`deepseek-v4-pro` placed 2nd and 4th). Passed the holdout cleanly, including the edge case `deepseek-v4-pro` got wrong.

**Effort variant (`low`/`high`/`max`) moved scope, not correctness.** All three converged and fixed the same bugs; `low` produced the smallest diff and skipped incidental bookkeeping, `max` produced the largest and closest to the Opus reference's rigor. Reasoning-token counts backed this reading. Treat the effort knob as a thoroughness dial on this model, not an accuracy dial.

**Recurring failure reasons**, folded into the runner's prompts:

- Sourcing a value from the right file is not the same as sourcing a value the consuming format can parse - render the actual output and check it against the consuming tool's grammar.
- An invariant explained correctly in prose is not the same as an invariant enforced in the right place.
- A model's own "I verified this" is a claim to check, not a fact.
- A discrepancy noticed mid-run is routinely lost by the time a closing summary is written; derive the summary from what was done, not from what the ticket said before starting.
- Narrow scope, with no separate script or package, consistently outranked wider-but-equally-correct alternatives in blind grading.

**Cost, projected:** ~4-6 cents per implement attempt at `glm-5.3-flash`/`high`. A typical ticket (one implement pass, one review pass): ~$0.08-0.10. A worst case burning the full retry budget: ~$0.25-0.30. Against the Go plan's $12/5-hour cap and concurrency of one, the pipeline cannot process enough tickets in any window to approach the cap regardless of cost - which is why peak-hour scheduling (considered, to dodge a per-run cost pressure that never materialized at this model's price point) was dropped.

## Review model and rubric: measured

Item 6's original design asked the review stage to gate - refuse a diff it judged incorrect. This was measured directly, across 25 runs on the #159 holdout pair (one implementation with an independently graded defect, one clean), two models, and three prompt rubrics.

**The review stage never once refused the flawed diff for the defect in it**, across every arm:

| Arm | Model | Detected the defect | Gated on it |
| --- | --- | --- | --- |
| Base prompt | `glm-5.3-flash` | 0/3 | 0/3 |
| Base prompt | `deepseek-v4-pro` | 2/3 | 0/3 |
| "Precedent is not permission" rubric | `deepseek-v4-pro` | 2/3 | 0/3 |
| "Verdict from the skill's own categories" rubric | `deepseek-v4-pro` | 0/3 | 0/3 (but 2/2 false positives on the *clean* subject) |
| Same rubric, control | `glm-5.3-flash` | 1/3 | 0/3 |

The rubric that gated most aggressively gated the correct implementation too - false positives, not catches. A rubric could not manufacture a catch from a model that was not looking, and could not make a model that saw the defect refuse on it either: both `deepseek-v4-pro` runs that spotted the bug reasoned their way to a `pass` anyway, citing something true (an existing precedent in the codebase, the ticket's own stated preference) to justify it.

**Conclusion: this stage cannot be trusted to gate**, on any model or rubric tested. It was made advisory rather than a merge gate - a decision recorded in [ADR 0004 §6](../adr/0004-afk-agent-runs-self-hosted-with-a-harness-split.md) and [ADR 0007](../adr/0007-the-pull-request-opens-before-the-review.md), which made CI the correctness gate instead.

**Re-graded on findings quality, since the stage's whole value is now the notes it leaves.** Accuracy itself was never the problem: nine recurring finding-themes were checked against source across both subjects, all nine true, on both models. What the re-grade found instead: on the flawed subject, 9 of 15 runs affirmatively certified that the very criterion the diff breaks was satisfied - and 4 of the 5 runs that *did* detect the defect also certified, elsewhere in the same report, that the criterion it breaks holds. A reader gets the bug and its own refutation with nothing to separate them, which is worse than a report that missed it entirely. This is what the runner's review prompt now explicitly forbids: writing that something is "met", "verified" or "unchanged" without having run something that shows it.

**Model choice for review, settled separately from implement.** Counting tool calls: `deepseek-v4-pro` ran `nix build`/`nix eval` to check its own claims in 8 of 15 runs; `glm-5.3-flash` did in 2 of 10, and 4 of those 10 wrote a full report having read, run, and searched nothing - relaying sub-agent output wholesale. One `deepseek-v4-pro` run also found a real bug nobody else caught, including the human grading the holdout: an empty-string slug producing a false collision on unrelated folders. Review is a single pass with no retry budget, so the 15-25x cost difference is affordable there in a way it isn't for implement - roughly 10 cents against implement's 4-9, still a rounding error against the spend cap. `deepseek-v4-pro` was chosen for review on this basis; `glm-5.3-flash` stays the implement model. This is not evidence that `deepseek-v4-pro` reviews better in general - the defect-detection numbers above point in both directions depending on rubric and are noise at this sample size (n=3 per cell). The verification-behavior counts are the only part of this comparison that isn't.
