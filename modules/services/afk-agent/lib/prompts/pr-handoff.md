## The advisory review's findings

CI on this branch went green, over CIROUNDS watch(es) of its checks. That
is the correctness gate on this path (ADR 0007) - the runner's own local
gate is a reproduction of CI's steps and can drift from them, and CI runs
what only CI runs: a cold runner, the sharded check matrix, and every host
built from an empty store.

`code-review` then ran against this branch on `REVIEWMODEL`, in a fresh
context, across its standards and spec axes. The runner verified that from
the session transcript rather than from the session's own account of
itself, and would not have applied `HANDOFF` otherwise. It decided nothing,
and nothing downstream read it as a decision
(`docs/research/afk-agent-pilot-findings.md`).

It also could not have changed what is in this pull request. It ran after
the push, against a branch nothing pushes again, so its report is the
entirety of what it was able to affect (ADR 0007).

Two measured things are worth holding while reading it. Its findings are
accurate - nine recurring themes across 25 runs were checked against
source and all nine were true - but across 15 runs on a diff with an
independently graded defect it never once refused that diff for the defect
in it, and it has repeatedly written that a criterion holds without
running anything that shows it. A finding below is worth reading. A
silence below is worth nothing. It was asked, among other things, to
report any claim in the commit messages quoted in this pull request's
description that is not true of the diff.

---
