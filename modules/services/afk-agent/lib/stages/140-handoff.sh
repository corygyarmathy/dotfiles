# shellcheck shell=bash
# The findings could not be in the body at creation time, because the
# review had not run (ADR 0007). So the body is re-rendered with the
# hand-off section in it and written over the one already there: it keeps
# the body/comment separation the author filter depends on, where a
# comment would not (#202).
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
#
# Ticket lane only: the revision lane hands back to the reviewer with a
# comment and the hand-off label, without re-running the review
# (150-revise.sh).
if [ "$flow" = issue ]; then
	pr_body with-handoff

	log "#$number: handing over - writing the findings onto $pr_url and labelling it @HANDOFF_LABEL@"

	gh pr edit "$pr_url" \
		--repo "$repo" \
		--body-file "$run_dir/pr-body.md" \
		--add-label "@HANDOFF_LABEL@" ||
		hand_back "$pr_url is open and green, but the review's findings could not be written onto it, so it stays without the @HANDOFF_LABEL@ label"

	# The notification (#176): the whole point of the hand-off
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
