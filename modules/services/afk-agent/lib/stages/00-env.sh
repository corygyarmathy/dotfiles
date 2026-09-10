# shellcheck shell=bash
# Everything the runner keeps outside its own process is relocatable, so
# that the check can point it at a scratch directory and a fixture origin
# repository. Nothing else is overridable: the label, the branch prefix
# and the denylist are the behaviour under test, not the fixture around
# it.
state_dir="${AFK_STATE_DIR:-@STATE_DIR@}"
repo="@REPOSITORY@"
repo_url="${AFK_REPO_URL:-https://github.com/@REPOSITORY@.git}"

label="@LABEL@"
base_branch="@BASE_BRANCH@"
branch_prefix="@BRANCH_PREFIX@"
pr_label="@PR_LABEL@"
# The claim (ADR 0006). It replaces the assignee the tracker used to
# carry here, because GitHub will not assign an issue to a GitHub App.
working_label="@WORKING_LABEL@"
# What a handed-back ticket carries instead. The stuck path (#175) swaps `$working_label` for this in one edit, next to the comment
# that says why the run stopped. Deliberately not `$label`: re-applying
# the claim marker would send a ticket the runner cannot finish straight
# round the frontier query again, to burn its retry budget on the same
# failure every poll. A human decides what happens to an
# `$stuck_label` ticket (docs/agents/triage-labels.md).
stuck_label="@STUCK_LABEL@"
# The hand-off signal (ADR 0007 §7). The ticket lane applies it beside the
# review findings in one edit; the revision lane re-applies it in one edit
# once a revised commit's CI is green. A variable here rather than the
# inline token the ticket lane uses, because the revision lane and the
# hand-off both read it.
handoff_label="@HANDOFF_LABEL@"

# The revision loop's trigger (#196, as re-triggered by #247): a pull
# request this runner opened, carrying `$handoff_label`, with a `/revise`
# comment on it from an account other than the agent's own, has that
# request - or, when the comment carries no text, the review comments
# behind it - read back into a revision session. The comment is the whole
# of the trigger, not the presence of unresolved threads, because a
# half-written review must not start a run.
revising_label="@REVISING_LABEL@"
# Revision rounds per pull request before the stuck path. Three, then a
# human: a disagreement between a reviewer and the model is otherwise
# unbounded spend.
max_revision_rounds="@MAX_REVISION_ROUNDS@"
# The runner's own login (ADR 0006). The revision loop's author filter
# reads it, so that the agent's own words on a pull request - the round
# comments, and the advisory findings quoted in the body - never become
# instructions to the model that wrote them.
bot_login="@BOT_LOGIN@"

# Which lane this run is on. The revision frontier sets `revise` before
# the ticket poll runs, when an unacknowledged `/revise` comment is
# waiting: a human waiting on a revision is ahead of a backlog ticket.
# Every issue-stage between here and the hand-off reads this and steps
# aside, and the revision flow at the end of the script runs only when it
# is set.
flow="issue"
# Which tracker surface the stuck path writes to: the issue for the
# ticket lane, the pull request itself for the revision lane.
tracker_kind="issue"

checkout="$state_dir/checkout"
worktrees="$state_dir/worktrees"

# The ntfy server and topic the two notifications publish to. Deliberately not an environment seam: the URL and topic are the
# behaviour under test, and the check asserts the exact POST the runner
# would make against the values the module evaluated.
ntfy_url="@NTFY_URL@"
ntfy_topic="@NTFY_TOPIC@"

denied=(
	@DENIED_LINES@
)
