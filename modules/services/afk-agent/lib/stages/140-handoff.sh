# shellcheck shell=bash
# The findings could not be in the body at creation time, because the
# review had not run (ADR 0007). Since #202 they are not in the body at
# all: they are a comment on the pull request, posted by the agent's own
# account (ADR 0006), and the body keeps the issue link, the provenance
# and what the branch says it does. The comment is the agent's by its
# author, which is the filter the revision lane (#196) reads - the
# body/comment distinction it used to depend on is gone, and nothing else
# depended on it.
#
# THE COMMENT BEFORE THE LABEL, and the reason is the one the single edit
# used to carry: the label says a review has run, and a pull request
# carrying it while the findings were still in flight would be saying
# something untrue for however long the second call took. A comment that
# cannot be posted is a handed-back run rather than a silent one, for the
# same reason the edit below is: the findings are the review stage's
# entire output, and a pull request labelled ready without them would be
# saying something untrue.
#
# The label is a signal and not a control (ADR 0007 §7). Nothing here or
# at GitHub's end stops a merge before it is applied, and nothing should:
# ADR 0004 §9 makes merging a human act, and a runner that could withhold
# a merge would hold a veto over the person rather than the other way
# round.
#
# Ticket lane only: the revision lane hands back to the reviewer with a
# comment and the hand-off label, without re-running the review
# (150-revise.sh).
if [ "$flow" = issue ]; then
	# The body is re-rendered first, for the reason 100-pr.sh gives: the
	# hand-off edit rewrites it with the CI fix round's commits and the
	# final attempt count in the sections that are already there.
	pr_body

	# The comment: the caveat prose first, the findings appended under it
	# verbatim. One comment, not one per finding - the review's output is
	# prose and carries no line anchors, so inline comments would be
	# invented positions.
	findings_comment="$run_dir/findings-comment.md"
	{
		pr_prose @PR_HANDOFF@
		cat "$review_dir/findings.md"
	} >"$findings_comment"

	log "#$number: handing over - posting the review's findings on $pr_url and labelling it @HANDOFF_LABEL@"

	gh pr comment "$pr_url" --repo "$repo" --body-file "$findings_comment" ||
		hand_back "$pr_url is open and green, but the review's findings could not be posted on it, so it stays without the @HANDOFF_LABEL@ label"

	gh pr edit "$pr_url" \
		--repo "$repo" \
		--body-file "$run_dir/pr-body.md" \
		--add-label "@HANDOFF_LABEL@" ||
		hand_back "$pr_url is open and green with the review's findings posted on it, but the hand-off label could not be applied"

	# The notification (#176): the whole point of the hand-off
	# label, delivered to somebody who is not watching GitHub. Priority low
	# - informational, silent, the lane's warning level - because nothing
	# here is wrong and nothing is waiting on this beyond a person finding
	# a quiet moment to read the diff. A degraded review (#269) is exactly
	# the same kind of news, plus one sentence: the finding's provenance
	# caveat repeats here, so the rate this happens at is observable
	# without opening the pull request.
	notify_title="AFK agent: PR ready for review (#$number)"
	notify_body="$(printf '%s\n%s' "$pr_url" "$title")"
	if [ -n "$degraded_what" ]; then
		notify_title="AFK agent: PR ready for review, degraded (#$number)"
		notify_body="$(printf '%s\n%s\n\n%s' "$pr_url" "$title" "$review_axes_note")"
	fi
	notify low white_check_mark "$notify_title" "$notify_body"

	# --- and nothing is left in flight ------------------------------------
	#
	# The worktree goes now that the branch is somewhere durable. The
	# in-flight guard at the top of this script refuses to poll past any
	# leftover worktree, so a ticket that finished and left one behind would
	# wedge every later poll: a pipeline that works exactly once. The guard
	# (#175) is also what heals this if the removal ever does fail -
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
	# stoppable.
	git -C "$checkout" worktree remove "$worktree" ||
		die "#$number: $pr_url is open, but $worktree could not be removed; the next poll's guard clears it without touching the ticket"

	log "#$number: done - $pr_url is open on $branch. Merging it is a human act (ADR 0004 §9), and nothing here does it"
fi
