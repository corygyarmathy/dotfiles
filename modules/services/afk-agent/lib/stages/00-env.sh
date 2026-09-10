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
