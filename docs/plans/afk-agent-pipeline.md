# Plan: the AFK agent pipeline

Status: in progress — item 1 has two of its three questions answered (see its findings note) and a protocol written for the third; nothing else has started. Follows [ADR 0004](../adr/0004-afk-agent-runs-self-hosted-with-a-harness-split.md), which covers the architectural decisions (platform, harness split, identity, trigger, retries, kill switch) and the alternatives rejected along the way; this plan is the work items that implement it.

The engineering skills (`.agents/skills/`) already carry a ticket from idea through `to-tickets`, which publishes a GitHub issue labelled `ready-for-agent` per `docs/agents/triage-labels.md`. `implement` already runs `/tdd`, tests, and a self-review, then commits. Everything below starts at the gap right after that: nothing currently claims a `ready-for-agent` ticket unattended, pushes it, opens a PR, or tells anyone.

Item 1 gates everything else: the model this pipeline runs on is deliberately undecided (ADR 0004), and building the rest around a guess would be the wrong order.

| #  | Item                                 | Size   | Status      |
| -- | ------------------------------------ | ------ | ----------- |
| 1  | Measured pilot                       | medium | in progress |
| 2  | Triage: path denylist                | small  | not started |
| 3  | AFK identity (`AFK_AGENT_TOKEN`)     | small  | not started |
| 4  | `modules/services/afk-agent.nix`     | medium | not started |
| 5  | Runner: claim → worktree → implement | large  | not started |
| 6  | Review stage                         | small  | not started |
| 7  | Raise the PR                         | small  | not started |
| 8  | Stuck path                           | small  | not started |
| 9  | Notifications                        | small  | not started |
| 10 | Peak-hour scheduling                 | small  | not started |
| 11 | Secrets                              | small  | not started |

---

## 1. Measured pilot

### The problem

Three real unknowns sit underneath ADR 0004's harness split: whether DeepSeek V4 (Pro or Flash) produces PR-quality output on this codebase's kind of tickets, whether OpenCode reads `.agents/skills/` well enough to run something equivalent to `/implement` and `/code-review`, and whether OpenCode Go's usage accounting reflects DeepSeek's off-peak discount. Guessing at any of them and building the rest of the pipeline on top is exactly backwards.

### Settled without spending a token, 2026-09-07

Two of the three questions fell out of the local install before any run happened. Recorded here so the runs below only have to answer what is actually still open.

**OpenCode reads `.agents/skills/` directly. Item 5 does not need to inline anything.** `opencode debug skill`, run from this repo, returns all 25 skills resolved off disk by absolute path — `implement` and `code-review` among them — alongside OpenCode's own built-in `customize-opencode`. Discovery searches `.opencode/skills/`, then `.claude/skills/`, then `.agents/skills/`, walking up from the working directory to the git worktree root, so a `git worktree add` checkout resolves them the same way the main checkout does.

Three caveats travel with that finding, all of them places the pipeline could misbehave without erroring:

- **Discovery is not invocation.** OpenCode exposes skills through a native `skill` tool the model _chooses_ to call. A weaker model may never call it and improvise instead — and this is not hypothetical: an existing DeepSeek V4 Flash session on this repo (`ses_f8abae513ffe…`, the Cloudflare Tunnel alert-silencing work) made 41 tool calls across `bash`, `edit`, `read`, `grep`, `glob` and `todowrite`, and never once called `skill`. The runner's prompt must name the skill explicitly rather than hope, and each pilot run records whether the `skill` tool actually fired.
- **`disable-model-invocation: true` is silently ignored.** OpenCode's frontmatter schema is `name`/`description`/`license`/`compatibility`/`metadata`, and unknown fields are dropped. So `implement`, `to-tickets`, `triage` and `handoff` — everything Claude Code deliberately hides from auto-invocation — are all auto-invocable under OpenCode. Not harmful, but it is a real behavioural divergence between the two harnesses, and it means the AFK executor has a wider skill surface than the interactive one.
- **`code-review` spawns parallel sub-agents.** OpenCode has a `task` tool, so the shape can work, but sub-agent model selection is separate configuration. Item 6 asserts the two axes run in genuinely separate contexts; if they collapse into one, that premise fails silently. Confirm it during the pilot's review stage rather than assuming it.

**The Go catalogue is far wider than ADR 0004 assumed, and the rates are flat.** Go carries 27 models, not the two the ADR names. The relevant slice, refreshed from models.dev via `opencode models opencode-go --verbose --refresh` (US$ per million tokens):

| Model               | In    | Out  | Context | Image | Variants                    |
| ------------------- | ----- | ---- | ------- | ----- | --------------------------- |
| `glm-5.3-flash`     | 0.075 | 0.25 | 1M      | yes   | low / high / max            |
| `qwen3.8-flash`     | 0.15  | 0.47 | 1M      | yes   | low / medium / xhigh        |
| `gpt-5.6-luna`      | 0.20  | 1.20 | 1.05M   | yes   | none…max (capped $15/mo)    |
| `deepseek-v4-flash` | 0.22  | 0.66 | 1M      | no    | low / high / max            |
| `longcat-2.0`       | 0.30  | 1.20 | 1M      | no    | low / medium / high         |
| `deepseek-v4-pro`   | 0.66  | 1.98 | 1M      | no    | high / max                  |
| `glm-5.3`           | 1.40  | 4.40 | 1M      | no    | low / high / max            |
| `qwen3.8-max`       | 2.00  | 6.00 | 1M      | yes   | low / medium / xhigh        |
| `grok-4.6`          | 2.00  | 6.00 | 500K    | yes   | low / medium / high / xhigh |
| `kimi-k3`           | 3.00  | 15.0 | 1M      | yes   | max only                    |

Go is dollar-metered at these published rates: $10/month buys roughly $60 of usage, capped at $12 per 5 hours, $30 per week and $60 per month, with optional fallback to the Zen balance once a cap is hit. The practical consequence for a serial runner is that `kimi-k3` burns the meter about fourteen times faster than `deepseek-v4-flash` for the same token count, and that the binding constraint is the **$12/5h rolling cap**, not the monthly one — a single ticket that costs a dollar is irrelevant monthly and material within a five-hour window.

There is no peak/off-peak field anywhere in the Go metadata; the rates are flat. That is strong evidence Go does _not_ pass DeepSeek's off-peak discount through, which is item 10's open question. It stays cheap to settle empirically — see the procedure — but **item 10 stands either way**, now justified by the 5-hour cap rather than by the discount.

**The measurement instrument already exists.** `opencode export <session-id>` emits, per session, the aggregate dollar cost, input/output/**reasoning** token counts, wall-clock span, the model _and variant_ actually used, and every tool call. Verified end to end on this host. Reasoning tokens being counted separately is what makes the effort-variant arm measurable rather than a matter of opinion.

It also gives a first cost scale to plan against, from real sessions rather than arithmetic: the DeepSeek V4 Flash session above cost **$0.067** for one small module change (90.7K input, 34.1K output, 3.5M cache reads). If that is representative, a ticket costs cents on the cheap arms and the $12/5h cap is nowhere near binding — but it is one session, on one ticket, which is exactly the reason the runs below exist rather than an argument for skipping them.

### What is still open

Only the first question: whether any Go model produces mergeable output on this codebase's tickets, at what cost, and at what reasoning effort. The rest of this item is the protocol for answering it.

### Approach

**Five arms.** The ADR names two; two is not enough to find the floor, and the leaderboard evidence says the top of the Go range is undifferentiated. Terminal-Bench 2.1 currently places GLM-5.3 at 88.2, Grok 4.6 at 88.4, DeepSeek V4 Pro at 87.9, Kimi K3 at 88.3 and Qwen3.8 Max at 86.6 — five models inside a 1.8-point band, which is smaller than the benchmark's own noise. The useful reading of that is not "they are all equally good", it is "public benchmarks cannot pick the winner here". What separates them on this repo will be harness fit — tool-call reliability across a thirty-turn run, whether the `skill` tool gets called, whether the model stops early — none of which any leaderboard measures.

| Arm | Model                           | Variant | Why it is in                                                                  |
| --- | ------------------------------- | ------- | ----------------------------------------------------------------------------- |
| A   | `opencode-go/deepseek-v4-flash` | `high`  | The cheap default ADR 0004 presumed                                           |
| B   | `opencode-go/deepseek-v4-pro`   | `high`  | The ADR's other named arm                                                     |
| C   | `opencode-go/glm-5.3`           | `high`  | The strong arm; tops the open-weights band and sets a realistic ceiling in Go |
| D   | `opencode-go/glm-5.3-flash`     | `high`  | Three times cheaper than A. If it passes, the budget question stops existing  |
| E   | winner of A–D                   | `max`   | The effort arm — run only after A–D are graded                                |

`high` is the floor because it is the only effort level all four models share (`deepseek-v4-pro` offers no `low`). Arm E is deliberately sequenced last: it is one extra run that retires a question otherwise guessed at permanently.

Plus one arm that is **not a candidate**: the same ticket run through Claude Code on Opus 5, as the calibration line. ADR 0004 §2 rules Claude Code out of the unattended path, so this never becomes the answer — but without a known-good ceiling there is no way to distinguish "this model is weak" from "this ticket is badly specified", and that ambiguity would waste the whole exercise.

**Two tickets and a smoke test, chosen for gradeability rather than for being representative.**

- **Smoke test: #167** (document the path denylist). Docs-only, costs cents, **not scored**. Run it on all four arms first, purely to shake out authentication, skills discovery, the permission overlay, commit formatting and worktree isolation — so the real runs are not debugging the harness and the model simultaneously.
- **Primary: #178** ("The lock screen is off-palette"). Desktop config, palette sourcing, geometry scale, write-the-check-first — the same _kind_ of work as the rofi and waybar tickets, but with mechanically checkable criteria. "A build-time check fails if `hyprlock.nix` contains any raw hex or `rgb()` literal not sourced from the shared palette" is gate-able; "radius and border match 12/2" is a literal comparison. The five offending literals are still at `modules/home/desktop/hyprlock.nix:42-51`, so a correctly-written check fails red on the baseline. It is single-file and small but still exercises the hard parts: locating `lib/kanagawa-wave.nix`, following item 5's check pattern, writing the check _before_ the change, and producing an explicit recorded decision about the `screenshot` background — that last criterion is the probe for silently-skipped judgement calls, which is a failure mode that only matters once nobody is watching.
- **Holdout: #159** ("The filter refuses a shelf-name collision"). A different axis entirely: real logic, a new test seam, and a ticket body that _argues_ for why the test must be structured a particular way. It is the best available measure of whether a model follows reasoning it has been given rather than pattern-matching nearby code, and it is fully headless and fully objective. **Held back and run once per surviving arm with the prompt frozen**, because iterating prompt wording against #178 fits the prompt to #178; #159 is the honest estimate.

**Why not #180, the ticket originally proposed.** Not because the models cannot see — the human grades the windows, not the model. Because its decisive criteria are manual and visual, and that breaks the experiment three ways. "Opening each of the seven surfaces shows a window sized to its content… no empty trailing rows… does not truncate without a scroll affordance" needs a live Hyprland session and human eyes across seven surfaces per run; at the sample size below that is over a hundred GUI inspections, and the measurement cost swamps the thing being measured. `nix flake check` passes whether or not the windows are sized correctly, so the primary objective metric goes dead exactly where the ticket is hardest. And it is large — seven call sites, a new build check, plus a resolve-or-defer judgement on `sidebar-mode` — which produces too many partial-credit states to discriminate between arms. #180 remains a good ticket; it is a bad instrument.

Also excluded: this pipeline's own tickets (#170–#176). Having the unproven agent build its own runner makes every failure ambiguous between "weak model" and "unclear spec".

**Sample size, and the one thing not to economise on.** Agent runs are stochastic — the same model on the same ticket can pass and fail. The design is **four arms × two repeats on the primary ticket (8 scored runs)**, then the effort arm and a single confirming run per surviving arm on the holdout — 13 scored runs in total, against roughly 20 executions once the unscored smoke and calibration runs are counted. The full breakdown is in the procedure's vocabulary section. If it proves too expensive, **cut arms before cutting repeats.** Run one arm's two repeats first: if they disagree with each other, the effect size is smaller than the noise, and no amount of single-run comparison will settle anything.

### What counts as evidence

Three sources, with three different jobs, and they are not interchangeable.

**Public leaderboards pick the shortlist and never the winner.** They are a prior, not evidence, for four reasons. The top of the band is inside the noise, as above. The task distribution is Python and JavaScript repositories with unit tests; Nix is close to absent from every public coding benchmark, so a SWE-bench score transfers roughly not at all to "knows that `nix fmt -- --ci` is the gate and that `checks/` are VM tests". Every published number is model _plus_ scaffold — Kimi K3's 88.3 is measured with KimiCode at max reasoning, not with OpenCode. And the headline figures are increasingly vendor-reported. Their legitimate job was getting 27 Go models down to four arms in an afternoon of reading. That job is done.

**Objective data decides elimination, and the metrics are fixed before the first run.** The trap is measuring what is easy — tokens, seconds — rather than what decides. Recorded per run:

- **Gate-pass (binary, primary).** Did `nix fmt -- --ci` and the host build pass on the agent's branch, unassisted? This gate already exists and CI already enforces it. One bit, no judgement.
- **Spec-pass (binary, primary).** Every acceptance checkbox satisfied, graded against the checklists below, which are written _before_ any run.
- **Human-fix distance.** The most informative number. Not "needed fixes: yes/no", which flattens a typo and a redesign into one value — the diff between the agent's commit and the state that would actually be merged, in lines _and_ in minutes to fix.
- **Cost per _successful_ run.** From the session export. A three-cent run that fails is infinitely expensive; cost per run is the wrong denominator.
- **Wall-clock: recorded, not weighted.** AFK work runs overnight, so twelve minutes and forty minutes are the same outcome. What matters is whether a run exceeds the timeout item 5 will need.
- **Unattended-failure behaviours**, which are what make this different from measuring a supervised agent: was the `skill` tool called at all; was a denylisted path touched; was a command hallucinated; did the run stop early and hand back. A model that scores well but stops early is useless here, and no benchmark measures it.

**Subjective judgement is the ground truth, not the weak evidence.** These PRs get merged by a human, so "would I merge this unedited?" _is_ the target variable and every objective metric above is a proxy for it. It is structured rather than free-floating: grade the diffs with the arm identities stripped, and **rank pairwise rather than scoring out of ten**, because a single rater's absolute scores drift across a session while rankings do not. Grade against the pre-written checklist, so the verdict is not rationalised after seeing the output. And record the _reasons_, not just the verdict — "invented an abstraction the repo does not use", "wrote the check after the change instead of before", "ignored the formatting gate". Those reasons are worth more than the scores; they are what goes into `AGENTS.md` and into item 5's prompt.

The synthesis: leaderboards shortlist, gates eliminate, blind ranking selects among survivors, cost breaks ties. Nothing is chosen on a benchmark number, and nothing is eliminated on a feeling.

### Procedure

Kept in this document rather than as a script under `packages/`, because it is a one-off measurement whose reasoning matters more than its reusability — and because item 5 lifts its `opencode run` invocation from here directly.

#### Vocabulary

Four words that are used precisely below, because the arithmetic depends on them:

| Term       | Means                                                                                                                                             | How many                                  |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| **Pilot**  | This whole exercise — every command in this section, start to finish                                                                              | 1                                         |
| **Arm**    | One _configuration_ under comparison: a model plus a reasoning variant. A condition, not an execution                                             | 5 (A–E)                                   |
| **Repeat** | The same arm on the same ticket, executed again, to separate signal from noise                                                                    | 2 on the primary ticket, 1 on the holdout |
| **Run**    | One _execution_ — one call to `pilot-run`. A run is an arm × a ticket × a repeat, and produces one worktree, one branch, one row in `results.tsv` | 22 at most (see below)                    |

So an arm is what you are comparing; a run is what you execute; the pilot is all of it. "Arm C failed" means the model configuration lost; "run `i178-glm-5.3-high-r2` failed" means one specific execution did, which may or may not be the arm's fault — that is exactly what the repeats are for.

The full count, since the run order below is easy to misread as symmetric:

| Stage | What                                | Runs      | Scored         |
| ----- | ----------------------------------- | --------- | -------------- |
| 3a    | Smoke test, #167, arms A–D          | 4         | no             |
| 3b    | Noise calibration, #178, arm A × 2  | 2         | yes            |
| 3c    | #178, arms B–D × 2 repeats          | 6         | yes            |
| 3d    | Calibration ceiling, #178, Opus 5   | 1         | no (reference) |
| 3e    | Effort arm E, #178, winner at `max` | 1         | yes            |
| 3f    | Holdout, #159, surviving arms × 1   | up to 4   | yes            |
| —     | Off-peak probe, #167                | 2         | no             |
|       | **Total**                           | **20–22** | **13 scored**  |

The holdout runs **once** per surviving arm, not twice, and that asymmetry is deliberate: #159 is a confirmation with the prompt frozen, not a second comparison. Repeats buy noise estimates, and the noise estimate has already been bought on #178.

#### Where to run these commands

`pilot-run` and `pilot-review` are written to be independent of the working directory — they use `git -C "$REPO"` and `cd` into the run's own worktree in a subshell, because OpenCode scopes both skill discovery and session listing to the project it was launched in. **The one exception is the `gh issue view` snapshot in Step 1**, because `gh` resolves the repository from the current directory's git remote: run that line from `~/git/dotfiles`. Nothing else cares, so the simplest habit is to run the whole pilot from `~/git/dotfiles` and never think about it again.

#### Step 0 — prerequisites, from `~/git/dotfiles`

1. Commit or stash everything. The pilot's baseline must be a real commit, and every arm starts from the same one.
2. Confirm authentication: `opencode providers list` lists **OpenCode Go**.
3. Read the grading checklists below **now**, before seeing any output.

#### Step 1 — set up the pilot directory, once per pilot

The baseline is pinned into a **file**, not an environment variable. A variable assigned with `$(git rev-parse HEAD)` re-derives itself in every new shell, so a commit landing on `master` midway through would silently give later runs a different baseline — and the comparison would be broken in a way nothing in the results would reveal.

```bash
mkdir -p ~/pilot
git -C ~/git/dotfiles rev-parse HEAD > ~/pilot/baseline     # pin once, never again
for n in 167 178 159; do gh issue view $n > ~/pilot/issue-$n.txt; done   # from ~/git/dotfiles
printf 'run_id\tissue\tmodel\tvariant\trepeat\tsession\tcost\ttok_in\ttok_out\ttok_reasoning\ttool_calls\tused_skill\tsecs\texit\tfmt\tbuild\tcommits\tinsertions\tdeletions\n' > ~/pilot/results.tsv
```

Snapshotting the issue bodies matters because they are the spec being graded against: if one gets edited mid-pilot, the later arms are answering a different question, and the snapshot is what makes that visible.

The prompt is written once and never varied between arms — that is the whole point of a controlled comparison, and it is also the draft of item 5's real prompt:

```bash
cat > ~/pilot/prompt.tmpl <<'EOF'
Implement GitHub issue #ISSUE in this repository.

Use the `implement` skill. Fetch the issue with `gh issue view ISSUE`.

Constraints:
- Do not modify `.github/workflows/`, `secrets/`, or `.sops.yaml`.
- Do not push, do not open a pull request, and do not edit or close the issue.
- Do not run `/code-review`; review is a separate stage run after you finish.
- Commit your work to the current branch when done.
EOF
```

The `implement` skill ends by telling the agent to run `/code-review` itself. That instruction is overridden above deliberately: item 6 makes review a separate fresh-context pass, and folding it in here would make an implement failure and a review failure indistinguishable.

#### Step 2 — the pilot library

`pilot-run` and `pilot-review` are shell functions, so they exist only in the shell that defined them. Rather than pasting them repeatedly, write them to a file once and **`source ~/pilot/pilot.sh` in each terminal you use for the pilot** — including after a reboot, a new tab, or a `tmux` pane. Re-sourcing is always safe: it reads the pinned baseline from `~/pilot/baseline` rather than re-deriving it.

Write the file (`cat > ~/pilot/pilot.sh <<'PILOT_EOF' … PILOT_EOF`) with this content:

```bash
REPO=~/git/dotfiles
PILOT=~/pilot
BASE=$(cat "$PILOT/baseline")   # read the pin; never re-derive it

pilot-run() {  # pilot-run <issue> <model> <variant> <repeat> <host>
  local issue=$1 model=$2 variant=$3 rep=$4 host=$5
  local id="i${issue}-${model}-${variant}-r${rep}"
  local wt="$PILOT/$id"

  git -C "$REPO" worktree add -b "pilot/$id" "$wt" "$BASE" >/dev/null 2>&1 || return 1
  sed "s/ISSUE/$issue/g" "$PILOT/prompt.tmpl" > "$PILOT/$id.prompt"

  # Pilot-only guardrails. Verified with `opencode debug config`: inline config
  # merges after the repo's own rules, and last match wins, so these take effect.
  local guard='{"permission":{"bash":{"git push*":"deny","gh issue edit*":"deny","gh issue close*":"deny","gh issue comment*":"deny","gh pr*":"deny"}}}'

  local t0 t1 rc
  t0=$(date +%s)
  ( cd "$wt" && OPENCODE_CONFIG_CONTENT="$guard" timeout 3600 \
      opencode run --model "opencode-go/$model" --variant "$variant" \
                   --agent build --title "$id" --auto \
                   "$(cat "$PILOT/$id.prompt")" ) > "$PILOT/$id.log" 2>&1
  rc=$?
  t1=$(date +%s)

  # Redirect the export to a file before touching it with jq: piping
  # `opencode export` straight into jq truncates on large sessions.
  local sid
  sid=$(cd "$wt" && opencode session list -n 20 --format json 2>/dev/null \
          | jq -r --arg t "$id" '.[] | select(.title==$t) | .id' | head -1)
  ( cd "$wt" && opencode export "$sid" ) > "$PILOT/$id.json" 2>/dev/null

  local metrics
  metrics=$(jq -r '
    [ .info.cost,
      .info.tokens.input, .info.tokens.output, .info.tokens.reasoning,
      ([.messages[].parts[]? | select(.type=="tool") | .tool] | length),
      ([.messages[].parts[]? | select(.type=="tool") | .tool] | index("skill") != null)
    ] | @tsv' "$PILOT/$id.json")

  ( cd "$wt" && nix fmt -- --ci ) >/dev/null 2>&1; local fmt=$?
  local build=0
  if [ -n "$host" ]; then
    ( cd "$wt" && nix build --no-link \
        ".#nixosConfigurations.$host.config.system.build.toplevel" ) >/dev/null 2>&1
    build=$?
  fi

  local commits ins del row
  commits=$(git -C "$wt" rev-list --count "$BASE"..HEAD)
  read -r ins del <<<"$(git -C "$wt" diff --numstat "$BASE" \
                          | awk '{i+=$1; d+=$2} END {print i+0, d+0}')"

  row=$(printf '%s\t' "$id" "$issue" "$model" "$variant" "$rep" "$sid")
  row+="$metrics"$'\t'
  row+=$(printf '%s\t' "$((t1-t0))" "$rc" "$fmt" "$build" "$commits" "$ins" "$del")
  printf '%s\n' "${row%$'\t'}" >> "$PILOT/results.tsv"

  echo "$id: exit=$rc fmt=$fmt build=$build commits=$commits $((t1-t0))s"
}

pilot-review() {  # pilot-review <run-id> <issue> <model>
  local id=$1 issue=$2 model=$3 wt="$PILOT/$id"
  # `edit: deny` makes "report only" enforced rather than merely requested,
  # so a review pass cannot quietly fix what it was supposed to report.
  local guard='{"permission":{"edit":"deny","bash":{"git push*":"deny","git commit*":"deny","gh pr*":"deny","gh issue edit*":"deny"}}}'

  ( cd "$wt" && OPENCODE_CONFIG_CONTENT="$guard" timeout 1800 \
      opencode run --model "opencode-go/$model" --variant high \
                   --agent build --title "$id-review" --auto \
                   "Use the \`code-review\` skill. The fixed point is $BASE. The spec is GitHub issue #$issue; fetch it with \`gh issue view $issue\`. Report findings only — do not change any files." \
  ) > "$PILOT/$id-review.log" 2>&1

  local sid
  sid=$(cd "$wt" && opencode session list -n 20 --format json 2>/dev/null \
          | jq -r --arg t "$id-review" '.[] | select(.title==$t) | .id' | head -1)
  ( cd "$wt" && opencode export "$sid" ) > "$PILOT/$id-review.json" 2>/dev/null

  jq -r '"cost=\(.info.cost) subagents=\([.messages[].parts[]? | select(.type=="tool") | .tool] | map(select(. == "task")) | length)"' \
    "$PILOT/$id-review.json"
}
```

A run is named by its arm, its ticket and its repeat — `i178-glm-5.3-high-r2` is arm C's second repeat on the primary ticket. That id is the worktree directory under `~/pilot/`, the branch name under `pilot/`, the OpenCode session title, and the first column of `results.tsv`, so any one of them leads back to the other three.

Notes on the choices, since each of them is load-bearing:

- **`--auto` is required, not a shortcut.** It approves everything the permission config does not deny, which is exactly the posture the real runner has. Sitting there approving prompts would measure the supervised path, not the unattended one.
- **`OPENCODE_CONFIG_CONTENT` rather than a file in the worktree.** A config file committed into the worktree would show up in the diff being measured. The inline variable merges above both the repo config and any `.opencode/` directory, and the pilot denies are appended after the repo's own rules, so last-match-wins gives them effect. Confirmed with `opencode debug config`.
- **A worktree per run, never reused.** Each arm starts from the pinned baseline; nothing carries over. Clean up with `git worktree remove` once graded, not before, because the diff is the evidence.
- **Per-run gate is `nix fmt -- --ci` plus the host build, not full `nix flake check`.** Sixteen full flake checks build every VM test in `checks/`, and almost none of them are reachable from these two tickets. The host build catches evaluation and build failures, which is where a bad change lands. **Run the full `nix flake check` on the finalists only** — the honest gate is what CI runs, and it is what the winning diff must pass before anything merges.
- **Hosts:** `xps15` for #178 (it owns hyprlock), `homelab01` for #159 (it is the gateway, so it owns the digital garden). Pass an empty host for the docs-only smoke test on #167.
- **The session export is written to a file before jq touches it.** Piping `opencode export` straight into `jq` truncates on large sessions — verified, and it fails as a parse error rather than as a wrong number, but only sometimes, which is worse. The `.json` file per run is also the raw evidence for grading, so it is worth keeping regardless.
- **`used_skill` is read from the export, not grepped out of the log.** Tool calls live at `.messages[].parts[] | select(.type=="tool") | .tool`; the default run log is human-formatted and cannot be parsed reliably. `tool_calls` comes from the same place and is worth watching: a run with very few tool calls that still claims success usually did not read enough of the repo.
- **`exit` and `commits` are separate columns for a reason.** A run can exit 0 having decided to explain what it would do rather than do it. `commits = 0` with `insertions > 0` means it worked but never committed; `commits = 0` with `insertions = 0` means it did nothing at all. Both are failure modes specific to unattended operation and both are invisible in a pass/fail column.

#### Step 3 — run order

Order matters: the smoke test shakes out mechanics, the repeat pair calibrates noise before any comparison is attempted, and the holdout runs last with nothing changed.

```bash
# 3a. Smoke test — not scored. Confirms auth, skills, permissions, commit shape.
for m in deepseek-v4-flash deepseek-v4-pro glm-5.3 glm-5.3-flash; do
  pilot-run 167 "$m" high 1 ""
done

# 3b. Noise calibration FIRST. If these two disagree, the design is under-powered
#     and everything downstream is a coin flip — stop and add repeats.
pilot-run 178 deepseek-v4-flash high 1 xps15
pilot-run 178 deepseek-v4-flash high 2 xps15

# 3c. The rest of the primary ticket.
for m in deepseek-v4-pro glm-5.3 glm-5.3-flash; do
  for r in 1 2; do pilot-run 178 "$m" high "$r" xps15; done
done

# 3d. Calibration ceiling: same ticket, same baseline, Claude Code on Opus 5,
#     from a worktree created by hand. Not a candidate — the reference line.

# 3e. Effort arm, once the winner of 3b–3c is known.
pilot-run 178 <winner> max 1 xps15

# 3f. Holdout, prompt frozen, one run per surviving arm.
for m in <survivors>; do pilot-run 159 "$m" high 1 homelab01; done
```

Two cheap experiments to fold in while the caps are being watched anyway:

- **Off-peak pass-through (item 10).** Run `pilot-run 167 deepseek-v4-flash high 9 ""` once inside a peak window (01:00–04:00 or 06:00–10:00 UTC, weekday) and once outside it, then compare the `cost` column for the same token counts. Costs a few cents and settles the ADR's open question outright.
- **Cap headroom.** After 3c, read the cost column: total spend across eight runs of one ticket is the number that says whether serial AFK operation fits inside $12 per five hours.

#### Step 4 — review stage

Run `pilot-review <run-id> <issue> <model>` only against runs that passed step 3's gate. It starts a **fresh session** against the same worktree — that separation is the whole point of item 6, and reusing the implement session would defeat it.

The function prints the `task`-tool count, which is the number that matters beyond the findings themselves: **`subagents=0` means the two axes collapsed into a single context**, and item 6's premise — that review is a genuinely separate pass — fails silently rather than erroring. Expect 2. Record alongside it whether the review caught the defects already found by hand during grading: a review pass that misses what a human found in five minutes is not a review stage.

#### Step 5 — grading

1. **Objective pass first**, from `results.tsv`. Any run with `fmt != 0` or `build != 0` is eliminated. No discussion, no partial credit — CI would reject it.
2. **Spec-pass**, against the checklists below, one column per run.
3. **Blind pairwise ranking** of the survivors' diffs. Strip the identities first:

   ```bash
   git -C "$REPO" branch --list 'pilot/i178-*' | shuf | nl -w1 -s$'\t' > "$PILOT/blind-key.tsv"
   # review `git diff $BASE..<branch>` by row number; unseal the key only afterwards
   ```

   Rank rows against each other rather than scoring each in isolation, and write the _reason_ beside each placement.
4. **Cost breaks ties**, from cost per _successful_ run, not per run.
5. Record the outcome in the results table below, then append a `### Built` note naming the chosen model and variant, the numbers behind it, and — most valuable for item 5 — the recurring failure reasons from step 3.

### Grading checklists

Written before any run, taken from the tickets' own acceptance criteria. Each is scored pass/fail with a one-line reason; partial credit is recorded as a fail with the gap named.

**#178 — the lock screen is off-palette**

One discrepancy in the ticket, found while writing this and left in place deliberately: it says "six colour literals" but `modules/home/desktop/hyprlock.nix` holds five (`outer_color`, `inner_color`, `font_color`, `check_color`, `fail_color` at lines 42-51; the `capslock_color = -1` family are "don't change" sentinels, not colours). Grade against five. It is worth watching whether any arm notices the mismatch and says so, versus inventing a sixth to satisfy the count — that distinction is more informative than the checklist itself.

- [ ] A build-time check exists that fails on any raw hex or `rgb()` literal in `hyprlock.nix` not sourced from the shared palette
- [ ] The check was written so it fails against the baseline's literals, not retrofitted to pass afterwards (verifiable: run the new check against `$BASE`)
- [ ] After the change, every colour in `hyprlock.nix` traces to `lib/kanagawa-wave.nix` via `config.lib.stylix.colors`
- [ ] Input field radius is 12 and border is 2, per item 6's geometry scale
- [ ] The `path = "screenshot"` background has an explicit recorded decision — kept, changed or dropped — with the privacy/aesthetic tradeoff named, rather than being left untouched and unmentioned
- [ ] Follows the item 5 pattern (the deployed file is the check's output) rather than adding a test under `checks/`
- [ ] No files outside the ticket's scope modified; nothing under `.github/workflows/`, `secrets/`, `.sops.yaml` touched
- [ ] Work is committed to the branch, with a message matching the repo's convention

**#159 — the filter refuses a shelf-name collision**

- [ ] The filter detects two distinct folders whose leaf names slugify to the same shelf
- [ ] On collision the render fails, and the message names both colliding paths _and_ the shared slug
- [ ] A vault with no collision renders exactly as before
- [ ] The failure is reachable by the existing sync-health alerting
- [ ] A test invokes the filter **directly** against a colliding vault — not through the served site
- [ ] That test's fixture is separate from the VM check's vault fixture and leaves it undisturbed
- [ ] The ticket's stated reasoning for _why_ the test must be structured this way is followed, not merely the surface requirement
- [ ] No files outside scope modified; work committed

### Results

Filled in as runs complete. Cost in US$, time in seconds, fix-distance in minutes.

| Run | Ticket | Model | Variant | Rep | Gate | Spec | Skill tool | Cost | Time | Fix-distance | Blind rank | Notes |
| --- | ------ | ----- | ------- | --- | ---- | ---- | ---------- | ---- | ---- | ------------ | ---------- | ----- |
| --- | ------ | ----- | ------- | --- | ---- | ---- | ---------- | ---- | ---- | ------------ | ---------- | ----- |

### Testing

No automated test — this is a manual spike. The result (model choice, cost/time/quality numbers, the skills-compatibility finding, and the off-peak pass-through answer) gets recorded directly in this file once it is run.

### Done when

A model _and_ reasoning-effort default is chosen with real numbers behind it, the noise-calibration pair either supports or undermines that choice explicitly, the skills-compatibility findings above are confirmed under load rather than only at discovery time, and the recurring failure reasons are written down in a form item 5's prompt can consume.

---

## 2. Triage: path denylist

### The problem

ADR 0004 restricts AFK-eligible tickets from touching `.github/workflows/`, `secrets/`, or `.sops.yaml`, regardless of how well-specified the ticket is.

### Approach

Wherever `ready-for-agent` gets applied today (manually, or by a future triage automation), add a check: if the ticket's described scope would require touching a denied path, apply `ready-for-human` instead. Document the denylist in `docs/agents/triage-labels.md` so it travels with the rest of the triage vocabulary.

### Testing

No automated test while triage stays manual. Once the denylist is enforced in code — the runner's own re-check in item 5 — that's where it becomes a real assertion; see item 5's testing note.

### Done when

The denylist is written down in one place that both a human triaging by hand and the runner's own check (item 5) can reference.

---

## 3. AFK identity (`AFK_AGENT_TOKEN`)

### The problem

A PR needs to be opened and pushed by something other than `GITHUB_TOKEN`, or the required `nixos ci` check never fires and the PR hangs unmergeable - the same trap `flake-update.yml` already routes around with `FLAKE_UPDATE_TOKEN`.

### Approach

A second fine-grained PAT scoped to this repo, under the existing account (ADR 0004 §4 - not a separate GitHub account). Branches it pushes use an `afk/*` prefix; PRs it opens carry an `afk-agent` label, giving the same at-a-glance distinction `deps/*` already provides.

### Testing

No automated test. Verified once, by hand: open a PR with `AFK_AGENT_TOKEN` and confirm `nixos ci` actually runs against it — the same kind of live, manual verification `deploy-rs` used (deployment-hardening.md item 6), since what's being proven is GitHub's own behaviour, not something a VM test can see.

### Done when

`AFK_AGENT_TOKEN` exists, is scoped to this repo only, and a manual `gh pr create` using it opens a PR that `nixos ci` actually runs against.

---

## 4. `modules/services/afk-agent.nix`

### The problem

Following `AGENTS.md`'s own convention (`cg.service.<name>.enable`), the whole pipeline should be a real, toggleable NixOS service - not a script someone remembers to run.

### Approach

A module on `homelab01` wrapping the poller (item 5) as a systemd service + timer, with `cg.service.afk-agent.enable` as the kill switch. Secrets (item 11) flow in the same way every other service's secrets do.

### Testing

A `pkgs.testers.runNixOSTest` under `checks/`, following the `monitoring`/`reverse-proxy` pattern (deployment-hardening.md item 4): instantiate the module with `cg.service.afk-agent.enable = true` and assert the poller's service and timer units exist and are enabled; instantiate again with `enable = false` and assert they're absent. This is the test that actually proves the kill switch — the module's whole reason for being a real service rather than a script.

Also covers item 10: assert the generated timer's schedule excludes all four weekday peak windows (01:00-04:00, 06:00-10:00 UTC), rather than as a separate test.

If the test needs secrets present to start the service, it follows the existing `checks/stub-secrets.nix` convention — plaintext fixtures swapped in for `sops.secrets.<name>.path`, real values never entering the test.

### Done when

`cg.service.afk-agent.enable = false` in host config fully stops the pipeline, and flipping it back on resumes polling with no other change needed.

---

## 5. Runner: claim → worktree → implement

### The problem

This is the actual unattended loop: find an eligible ticket, claim it, do the work, without colliding with a human working the same tracker.

### Approach

On each poll (skipping the peak windows from item 10):

1. `gh issue list --label ready-for-agent --state open`, filtered to unassigned issues.
2. Re-check the path denylist (item 2) against the ticket's described scope - defense in depth, not trusting the label alone (ADR 0004 §5).
3. Claim it: `gh issue edit <n> --add-assignee @me`, reusing the exact convention `docs/agents/issue-tracker.md` already documents.
4. `git worktree add ../repo-<ticket-slug> -b afk/<ticket-slug>`, per the isolation pattern `AGENTS.md` already establishes for concurrent agent work.
5. Run OpenCode against the ticket body, equivalent to `/implement` (adapted per item 1's finding on skills compatibility) - tests, typecheck, up to 2 retries in the same session against a failing result (ADR 0004 §6).
6. On success, hand off to item 6. On exhausting retries, or any other reason it can't proceed, hand off to item 8.

One ticket at a time (ADR 0004 §8) - no parallel worktrees for now.

### Testing

Not a NixOS VM test — this is script logic driving `gh` and `opencode`, neither of which can run inside the Nix build sandbox. A script-level test harness instead, with `gh` and `opencode` mocked: assert the poller only picks up unassigned `ready-for-agent` issues, claims via assignee before touching anything, re-checks the path denylist from item 2 and bails correctly on a ticket that would violate it, and stops after 2 retries rather than looping indefinitely. There's no prior art for this in the repo yet - script-level tests outside `checks/` are new here, so this sets the pattern rather than following one. Items 8 and 10 reuse this same harness rather than inventing their own.

### Done when

A real `ready-for-agent` ticket, run through this loop by hand once, ends with a commit on an `afk/*` branch in an isolated worktree, with the source issue correctly claimed and never double-processed on a second poll.

---

## 6. Review stage

### The problem

`implement`'s own bolted-on self-review runs in the same context that just wrote the code - the weakest form of review. ADR 0004 §6 calls for a genuinely separate pass.

### Approach

After item 5 succeeds, invoke `/code-review` in a fresh context - the existing skill's parallel standards + spec sub-agents, unchanged. A failure here does not consume another retry from item 5's budget; it's a new stage with its own outcome (fix-and-recheck once, or hand off to item 8).

### Testing

Manual, at least initially: run the stage against a deliberately flawed implementation (a clear spec violation, or a subtle bug) and confirm the fresh-context `/code-review` pass catches it before the PR reaches item 7. Same shape as how every `checks/` test in deployment-hardening.md item 4 was proven against a deliberate break — just not automatable the same way here, since this stage drives an LLM call rather than a VM.

### Done when

A deliberately flawed implementation, run through this stage, gets caught by the fresh-context review rather than sailing through on the strength of its own self-check.

---

## 7. Raise the PR

### The problem

This is the step `implement` never does today - nothing currently pushes or opens a PR.

### Approach

Push the `afk/*` branch and open the PR with `AFK_AGENT_TOKEN` (item 3), `afk-agent` labelled, body linking back to the source issue. No auto-merge (ADR 0004 §9) - it lands exactly like any other PR, waiting on human review.

### Testing

Manual, alongside item 3's verification: the resulting PR should show `nixos ci` running and the `afk-agent` label applied. Nothing to test for auto-merge, since ADR 0004 rules it out entirely for this path.

### Done when

A PR opened this way shows `nixos ci` actually running (proving the token choice from item 3 works end to end, not just in isolation).

---

## 8. Stuck path

### The problem

Ambiguous ticket, unfixable failure, missing credential, denylisted scope discovered mid-run - none of these should produce a PR, and none should fail silently.

### Approach

Comment on the issue with what was tried and why it stopped, relabel (`ready-for-agent` → something like `agent-stuck`, added to `docs/agents/triage-labels.md`), and notify (item 9). No draft PR, no WIP branch left dangling - `git worktree remove` cleans up.

### Testing

Same script-level harness as item 5: feed the runner a ticket engineered to fail (an impossible acceptance criterion), and assert it produces the issue comment and relabel, sends a notification (item 9), and leaves no branch or worktree behind afterward.

### Done when

A ticket engineered to fail (an impossible acceptance criterion) ends with a clear comment, the relabel, a notification, and no open PR.

---

## 9. Notifications

### The problem

Two things need to reach a human without them polling GitHub themselves: a PR is ready, or the agent got stuck. A third, added during design: OpenCode Go's usage is approaching a cap.

### Approach

Reuse the existing self-hosted ntfy setup and its severity conventions. PR-ready is low-priority/informational; stuck is a step up, since it needs a decision; a usage-cap threshold alert (e.g. 80% of the weekly or monthly Go cap) sits alongside it now that Zen billing is funded.

### Testing

If the AFK alerts route through the existing Alertmanager/ntfy stack, add them as cases to the existing `checks/monitoring.nix` VM test, which already asserts alert routing and severity through `amtool` (deployment-hardening.md item 4) - reuse rather than a new test file. If they're instead sent directly from the runner, it's a script-level assertion in item 5's harness that the right ntfy call fires for each of the three conditions.

### Done when

All three conditions produce a distinguishable ntfy notification, tested by hand once each.

---

## 10. Peak-hour scheduling

### The problem

DeepSeek V4 has real peak pricing (01:00-04:00 and 06:00-10:00 UTC, weekdays) at 2x the off-peak rate. Whether OpenCode Go's usage caps reflect this discount is unconfirmed either way (ADR 0004).

### Approach

The poller's systemd timer simply excludes those windows. Free to build regardless of the answer to item 1's Go-pass-through question - if it turns out Go doesn't reflect the discount, this becomes a no-op, not a mistake.

### Testing

Covered by item 4's VM test, not a separate one - see item 4's testing note.

### Done when

The timer's schedule visibly excludes the four weekday peak windows.

---

## 11. Secrets

### The problem

`AFK_AGENT_TOKEN` and the OpenCode Go API key need to reach the systemd service on `homelab01` without touching plaintext.

### Approach

SOPS entries alongside the rest of `secrets/`, following the existing convention exactly - no new secrets-handling design needed here.

### Testing

No test of secret content, by design - see item 4's note on `checks/stub-secrets.nix` for how the module test avoids needing real values.

### Done when

The service starts and authenticates using both, with neither value ever appearing in a build log or committed file.
