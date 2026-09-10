# shellcheck shell=bash
# ADR 0004 §6 (and #173). A self-review in the context that just
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
# `--dir` is the load-bearing flag: opencode resolves its project, and
# with it skill discovery, from the directory it is launched in, and a
# directory one level above the worktree has no `.agents/skills/`, no
# git repository, and a sibling checkout in reach to review. Naming the
# directory explicitly rather than inheriting it from a `cd` is what
# makes that unrepeatable. The `cd` stays as well: `session list` and
# `export` below are project-scoped the same way.
#
# The revision lane (150-revise.sh) never reaches here - the reviewer's
# own comments are the review that stage responds to - so the whole of
# this stage is behind the `flow` guard.
if [ "$flow" = issue ]; then
	# What the review is about to look at, kept only so that the log below
	# can say if the branch moved under it.
	reviewed_head="$(git -C "$worktree" rev-parse HEAD)"

	review_dir="$run_dir/review"
	mkdir -p "$review_dir"
	review_title="$slug-review"

	sed -e "s/ISSUE/$number/g" -e "s|BASE|origin/$base_branch|g" \
		@REVIEW_PROMPT@ >"$review_dir/prompt"

	log "#$number: reviewing $branch in a fresh session"

	# The overlay is set on the one command it governs rather than exported
	# for the rest of the run. An `export` here would outlive the stage, and
	# what it would hand the pre-push stage (#174) is a deny-set containing `gh pr*` and
	# `git commit*` - the two verbs that stage exists to use. Scoping it is
	# also the honest shape: it describes this session, not this process.
	review_rc=0
	(
		cd "$worktree" || exit 1
		OPENCODE_CONFIG_CONTENT=@REVIEW_OVERLAY@ \
			timeout @REVIEW_TIMEOUT@ opencode run --auto \
			--dir "$worktree" \
			--agent build --model @REVIEW_MODEL@ --variant @VARIANT@ \
			--title "$review_title" \
			"$(cat "$review_dir/prompt")"
	) >"$review_dir/run.log" 2>&1 || review_rc=$?

	if [ "$review_rc" -eq 124 ]; then
		hand_back "the review ran past its @REVIEW_TIMEOUT@s ceiling. Review does not retry (ADR 0004 §6). $unfinished"
	elif [ "$review_rc" -ne 0 ]; then
		hand_back "the review session exited $review_rc. Review does not retry (ADR 0004 §6). $unfinished"
	fi

	review_session="$(session_id_for "$worktree" "$review_title")"

	[ -n "$review_session" ] ||
		hand_back "the review exited 0 but no session titled '$review_title' can be found, so there is no transcript to verify it from. $unfinished"

	# Written to a file before jq is pointed at it: piping `opencode export`
	# straight into jq truncates on large sessions, and it fails as a parse
	# error rather than as a wrong answer - but only sometimes, which is the
	# worse of the two.
	# `|| true` because a failing `export` has to reach the check below
	# rather than abort the runner here: this is the left side of a
	# redirection, not a condition, so `set -e` would take it.
	(cd "$worktree" && opencode export "$review_session") \
		>"$review_dir/session.json" 2>/dev/null || true

	# And the transcript is checked for the shape the assertions below read,
	# not merely for being JSON. Valid JSON of the wrong shape is the trap
	# here: `jq -e .` is happy with anything parseable, and `.messages[]`
	# against a document without a `messages` array exits 5 - aborting the
	# runner with none of the diagnosis this stage exists to print.
	jq -e 'has("messages") and (.messages | type == "array")' \
		"$review_dir/session.json" >/dev/null 2>&1 ||
		hand_back "the review transcript at $review_dir/session.json is not a readable session, so nothing can be verified from it; opencode export truncates on large sessions (checked/run by checks/afk-agent-runner.nix). $unfinished"

# --- did a review actually happen -------------------------------------
#
fi
