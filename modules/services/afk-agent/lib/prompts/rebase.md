Finish the rebase the runner started in this worktree: it stopped on a
conflict while replaying this branch's commits onto the base branch that
moved while the ticket was being worked. `git status` shows where it
stopped.

Use the `resolving-merge-conflicts` skill, by name - call it rather than
improvising something equivalent.

Scope:

- Work only inside this directory. Do not read, write or reason about any
  checkout above or beside it.
- Do not touch `secrets/`, `.sops.yaml`, or anything under
  `.github/workflows/`. If a conflict sits in one of those, do not
  resolve it: leave the rebase where it stopped. That is a human's call,
  and the runner hands the ticket back to one.
- Resolve every other conflict and continue the rebase until every
  commit has been replayed. Never `git rebase --abort`; a resolution
  that resets to the stale base is the exact outcome this stage exists
  to prevent.
- Do not push, and do not comment on, edit or close anything on the
  tracker. The runner pushes, after its gate.
- Before you finish, run `nix fmt` (write mode) from the repo root, so
  the resolution carries no formatting drift the gate would refuse.

Do not run the repository's full gate; the runner runs it on the finished
rebase and pushes only when it passes. If you need to see what the merge
broke, run the checks one `nix build .#checks.x86_64-linux.<name>` at a
time, and never `nix flake check` - it evaluates every output of this
flake in one process and peaks around 8 GB on this host, which is enough
to invoke the kernel's OOM killer and lose your work with it.

The commits being replayed are this branch's own work; the commits they
land on are the ones that merged while it was being written. Read both
sides before deciding, and preserve both intents where they can coexist.
