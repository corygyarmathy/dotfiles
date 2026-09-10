# shellcheck shell=bash
# --- rebase onto the base branch before the pull request (#242) --------
#
# The branch was cut at the `$base_branch` tip of claim time, and the
# implement stage can run for an hour after that. A pull request opened
# from it is born stale - behind whatever merged while the ticket was
# being worked, with the conflicts already showing beside the diff a
# human is about to read. So, before anything is pushed: fetch, and
# where the tip has moved, replay this branch onto it.
#
# This is the one place a replay can happen. The branch has never been
# pushed here - `push_branch` is the only writer of the runner's branches
# on origin, and every one of its callers runs after this stage - so the
# replay rewrites a branch nobody can be reading, and ADR 0007 §4's
# never-a-force-push holds untouched. The revision lane (150-revise.sh)
# resumes a branch that is already pushed, which is why it gets no
# rebase at all: there, a replay would be exactly the rewrite §4 forbids.
#
# The gate runs again on anything the replay touched. A clean rebase is
# still a merge of the new base's content under this branch's work, and
# the verdict the implement loop earned was for the old tree - a gate
# that did not re-run would be blessing a commit it never saw.
#
# The conflict path is a fresh session, and neither of the two things it
# used to be confused with. Not the stuck path: a conflict is the
# ordinary cost of working a moving base, and handing every one to a
# human is the inefficiency #242 was filed about. Not the implement
# session continued (ADR 0004 §6): a retry needs a failure the session
# produced, and this conflict is between this branch's work and commits
# that did not exist when that session finished - its transcript has
# nothing to say about them. The session is pointed at the
# `resolving-merge-conflicts` skill by name, because naming the skill is
# the whole of what makes a model call it rather than improvise, and it
# runs under the implement overlay: the edit and `git` verbs it needs to
# resolve and continue, the tracker verbs denied.
#
# One session, no retry - the same asymmetry a CI fix round runs on (ADR
# 0007 §5). The work behind the conflict already passed the gate, so a
# session that cannot finish the replay is going backwards, and what is
# owed here is a human decision rather than a budget.
#
# The order inside the failure path is load-bearing. `git rebase
# --abort` runs before hand_back because mid-replay the branch ref still
# points at the gated pre-rebase tip while HEAD is detached on the
# half-replayed commit: the rescue inside hand_back would commit the
# conflicted tree onto that detached HEAD, and the work would dangle the
# moment the worktree is removed. Aborted, the tree is exactly what the
# gate passed on - a shape hand_back's teardown already describes.

if [ "$flow" = issue ]; then
	rebase_in_progress() {
		local state_path
		for state_path in rebase-merge rebase-apply; do
			if [ -e "$(git -C "$worktree" rev-parse --git-path "$state_path" 2>/dev/null)" ]; then
				return 0
			fi
		done
		return 1
	}

	# The stage's one question, asked twice: is this branch sitting on the
	# base branch's tip? Greasing the pipeline at line 67, and catching the
	# abort dressed up as a resolution at line 96. The negation there reads
	# naturally - a "no" is the failure shape - so one helper serves both.
	off_new_base_tip() {
		[ "$(git -C "$checkout" merge-base "refs/heads/$branch" "origin/$base_branch")" = "$(git -C "$checkout" rev-parse "origin/$base_branch")" ]
	}

	if ! git -C "$checkout" fetch --prune origin; then
		# A failed fetch leaves `origin/$base_branch` where the claim left
		# it, and the comparison below then answers with the base the
		# branch was cut from - the pre-#242 behaviour, which is better
		# than handing a passing branch back over a transient.
		log "#$number: the fetch before the rebase failed; $branch stays on the $base_branch it was cut from"
	elif off_new_base_tip; then
		log "#$number: $base_branch has not moved since $branch was cut; nothing to replay"
	elif git -C "$worktree" rebase "origin/$base_branch"; then
		log "#$number: replayed onto the new $base_branch tip; the gate runs again on the result"
		if ! gate; then
			hand_back "$(printf 'the replay of %s onto the new %s tip was clean, and the gate failed on the result. Its last @GATE_TAIL_LINES@ lines:\n\n%s' \
				"$branch" "$base_branch" \
				"$(tail -n @GATE_TAIL_LINES@ "$run_dir/gate.log")")"
		fi
	elif rebase_in_progress; then
		log "#$number: the replay stopped on a conflict; starting a conflict session"
		rebase_rc=0
		(
			cd "$worktree" || exit 1
			OPENCODE_CONFIG_CONTENT=@PERMISSION_OVERLAY@ \
				timeout @ATTEMPT_TIMEOUT@ opencode run --auto \
				--dir "$worktree" \
				--agent build --model @MODEL@ --variant @VARIANT@ \
				--title "$slug-rebase" \
				"$(cat @REBASE_PROMPT@)"
		) || rebase_rc=$?

		if [ "$rebase_rc" -ne 0 ]; then
			rebase_failure="the conflict session exited $rebase_rc"
		elif rebase_in_progress; then
			rebase_failure="the conflict session ended and the replay is still in progress"
		elif [ -n "$(git -C "$worktree" status --porcelain)" ]; then
			rebase_failure="$(printf 'the conflict session left work uncommitted:\n%s' \
				"$(git -C "$worktree" status --porcelain)")"
		elif {
			# The base can move a second time while the conflict session runs -
			# up to @ATTEMPT_TIMEOUT@ after the fetch at the stage top - and the
			# check below against that stale ref would bless a pull request
			# born stale again. It answers against a fetch made here instead.
			# A failed fetch leaves the ref where the stage top left it, and
			# the comparison is then no worse than this check ever was.
			git -C "$checkout" fetch --prune origin ||
				log "#$number: the fetch before the merge-base check failed; it answers with the fetch above"
			! off_new_base_tip
		}; then
			# The abort dressed up as a resolution: a clean tree, an exited
			# session, and a branch exactly as stale as the pull request
			# this stage exists to prevent. Nothing else can tell that
			# shape from success, so the merge base is checked, not assumed.
			rebase_failure="the conflict session finished without landing $branch on the new $base_branch tip"
		else
			rebase_failure=""
		fi

		if [ -n "$rebase_failure" ]; then
			if ! git -C "$worktree" rebase --abort 2>/dev/null; then
				log "#$number: the replay could not be aborted; the worktree keeps what the session left"
			fi
			hand_back "the replay of $branch onto the moved $base_branch stopped on a conflict, and it could not be finished: $rebase_failure. The replay was aborted and the run handed back."
		fi

		log "#$number: the conflicts are resolved and $branch sits on the new $base_branch tip"
		if ! gate; then
			hand_back "$(printf 'the rebase conflicts were resolved, and the gate failed on the result. Its last @GATE_TAIL_LINES@ lines:\n\n%s' \
				"$(tail -n @GATE_TAIL_LINES@ "$run_dir/gate.log")")"
		fi
	else
		hand_back "the replay of $branch onto $base_branch failed without stopping on a conflict; git's output is in this unit's journal"
	fi
fi

# --- push, gate first --------------------------------------------------
#
