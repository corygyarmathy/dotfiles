# shellcheck shell=bash
# ADR 0007 §1. Opening here buys two things: CI - the
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
#
# All of it is the ticket lane's: the revision lane (150-revise.sh) does
# not open a pull request, it revises the one that exists.
if [ "$flow" = issue ]; then
	commits="$(git -C "$worktree" rev-list --count "origin/$base_branch..HEAD")"
	if [ "$commits" -eq 1 ]; then
		pr_title="$(git -C "$worktree" log -1 --format=%s)"
	else
		pr_title="$title"
	fi

pr_prose() {
	sed -e "s/ISSUE/$number/g" \
		-e "s|BRANCH|$branch|g" \
		-e "s|IMPLEMODEL|@MODEL@|g" \
		-e "s|REVIEWMODEL|@REVIEW_MODEL@|g" \
		-e "s/ATTEMPTS/$attempt/g" \
		-e "s/CIROUNDS/$ci_round/g" \
		-e "s|HANDOFF|@HANDOFF_LABEL@|g" \
		"$1"
}

# The body, rendered from whatever is known at the moment it is called.
# Called twice: once now, and once at the end of the run. Re-rendered
# rather than appended to, so the second body is built from the branch as
# it finally stands - a CI fix round's commits are in the "what the branch
# says it does" section, and `ATTEMPTS` counts every session that touched
# it. The review's findings are not part of it at either call (#202): they
# arrive as a comment on the pull request, headed by @PR_HANDOFF@ at
# hand-off, which is why they are kept as their own file rather than
# assembled inline here.
pr_body() {
	{
		pr_prose @PR_INTRO@

		# What the branch claims to do, in the implementer's own words.
		# Oldest first, subject as a heading and body under it, so a ticket
		# that took three attempts reads as three steps rather than as one
		# wall.
		git -C "$worktree" log --reverse --format='### %s%n%n%b' \
			"origin/$base_branch..HEAD"
	} >"$run_dir/pr-body.md"
}

ci_round=0
pr_body

# `--label` rather than a second call, so a pull request that exists is a
# pull request that is already attributable at a glance - no ruleset can
# enforce ADR 0004 §9 here.
#
# Nothing arms auto-merge, here or anywhere: this opens the pull request
# and stops. That is a property of this script rather than of a ruleset,
# which is why the harness asserts it from both sides -
# the merge verb appearing nowhere in this script at all, and no
# auto-merge flag in what `gh` was actually called with. Both of its
# greps are deliberately crude enough to match prose, so this comment
# names neither command literally.
log "#$number: opening the pull request"
pr_url="$(
	cd "$worktree" &&
		gh pr create \
			--repo "$repo" \
			--base "$base_branch" \
			--head "$branch" \
			--title "$pr_title" \
			--body-file "$run_dir/pr-body.md" \
			--label "$pr_label"
)" || hand_back "$branch is pushed but the pull request could not be opened"

log "#$number: opened $pr_url"
fi

# --- watch the branch's own CI ----------------------------------------
#
