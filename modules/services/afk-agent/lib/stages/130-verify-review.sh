# shellcheck shell=bash
# Asked of the transcript rather than of the session's own summary. A
# stage whose failures all look like passes has to be checked from
# outside, so these two counts are read out of the tool calls the session
# actually made.
#
# Both are fatal, and fatal in the fail-closed direction: a review that
# cannot be shown to have happened is not a review that passed.
#
# Ticket lane only (see 120-review.sh): the whole of this stage sits
# behind the `flow` guard.
if [ "$flow" = issue ]; then
	skill_calls="$(
	jq '[ .messages[].parts[]?
        | select(.type == "tool" and .tool == "skill")
        | select(.state.status == "completed")
        | select(.state.input.name == "code-review")
      ] | length' "$review_dir/session.json"
)"

[ "$skill_calls" -gt 0 ] ||
	hand_back "the review never completed a \`skill\` call for code-review, so whatever it produced was not that skill's review. $unfinished"

# The two axes are the point of the skill: standards and spec, in
# genuinely separate contexts so that neither pollutes the other. They
# arrive as `task` calls. Fewer means they collapsed into the parent
# context, which is the premise of this stage failing rather than
# erroring - so it is checked rather than assumed.
axes="$(
	jq '[ .messages[].parts[]? | select(.type == "tool" and .tool == "task") ] | length' \
		"$review_dir/session.json"
)"

[ "$axes" -ge @REVIEW_AXES@ ] ||
	hand_back "the review spawned $axes sub-agent(s), not @REVIEW_AXES@; the standards and spec axes collapsed into one context (ADR 0004 §6). $unfinished"

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

[ "$named_axes" = true ] ||
	hand_back "the review spawned $axes sub-agent(s), but neither a standards nor a spec subject is identifiable across them, so this was not the code-review skill's two-axis pass. $unfinished"

log "#$number: review ran the code-review skill across $axes axes"

# --- the findings, which are the whole output of this stage -----------
#
# They are worth more on the pull request, next to the diff, than they
# ever were as a gate. The body edit below appends this file verbatim to
# the pull request that is already open; nothing here is the last reader
# of it, and nothing here decides anything from it.
#
# Deliberately NOT fed back to the implement session to be fixed: a
# finding handed back to the model that just wrote the code becomes a
# commit, and the gate cannot tell a correct change from a plausible
# green one. A wrong finding would then cost a real edit and consume the
# finding itself, where leaving it on the PR costs nothing and keeps it
# legible. With the stage advisory, every finding travels to the pull
# request, and none of them is ever handed back to the model that wrote
# the code.
jq -r '[ .messages[]
         | select(.info.role == "assistant")
         | .parts[]? | select(.type == "text") | .text
       ] | last // ""' "$review_dir/session.json" >"$review_dir/findings.md"

# Tested for content rather than for size. `jq -r` on a `// ""` fallback
# still emits its newline, so the file is one byte when the session
# produced no text at all and `[ -s ]` would call that a report.
#
# Still fatal now that the stage is advisory: the findings are what this
# stage produces. A review that verifiably ran and then said nothing has
# produced nothing for the pull request to carry, and passing it on as
# though it had is the same silent failure the checks above exist to
# refuse.
grep -q '[^[:space:]]' "$review_dir/findings.md" ||
	hand_back "the review session produced no closing report, so this stage has nothing to hand to the pull request. $unfinished"

# No verdict is read out of it - see the prompt above. The stage's
# outcome is decided entirely by the provenance checks: a review that can
# be shown to have run gets its findings carried, and one that cannot has
# already died above.
log "#$number: review ran and left $(wc -l <"$review_dir/findings.md") lines of findings in $review_dir/findings.md for the pull request; this stage is advisory and does not gate (ADR 0007 §3)"

# --- did the review write anything anyway -----------------------------
#
# Report-only is asked for in the review prompt and denied in
# `reviewOverlay`, and neither is a capability boundary: both are pattern
# matches on a command line, and `git -C . commit` matches neither. ADR
# 0007 is why a commit here can do no harm: the push is behind us,
# nothing pushes this branch again, and the pull request cannot be
# reached from here.
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
fi

# --- hand over --------------------------------------------------------
#
