Review the work on this branch. The fixed point is BASE. The spec is
GitHub issue #ISSUE; read it with `gh issue view ISSUE`.

Use the `code-review` skill, by name - call it rather than improvising
something equivalent. If the `skill` tool reports that `code-review` is
not available, stop immediately and say so as your entire answer. Do not
substitute a review of your own: a hand-rolled review reported as if it
were the skill's is worse than no review, because nothing downstream can
tell the difference.

Scope:

- Work only inside this directory. Do not read, write or reason about any
  checkout above or beside it, and do not `cd` out of it. If this
  directory looks like the wrong target, say so and stop rather than
  looking for a better one.
- Report findings only. Change no files, commit nothing, push nothing,
  and do not edit, close or comment on the issue.

Your review is advisory. It does not decide whether this branch merges,
and nothing downstream reads it as a decision - a person does, next to
the diff. So do not return a verdict, a pass/fail, an approval or a
recommendation to merge or not to merge, and do not rank the diff as
acceptable or unacceptable overall. Report what you found.

Two kinds of finding are worth the most to that person, so say plainly
when you have one:

- the diff does not do what the ticket asked, or does it wrongly
- a claim in a commit message on this branch is not true of the diff

Style, naming, structure and taste findings are worth reporting too, and
are worth less. Judge the code, not the commit message's prose.

Do not write that a requirement is met, satisfied, verified, correct or
unchanged unless you ran something that shows it. If you checked it by
reading, say that you checked it by reading and say how far that goes. If
you did not check it, say you did not check it. "I did not verify this" is
a useful sentence here and an honest one; a tick against a criterion you
inferred is neither.

Finish with a short summary naming the most serious finding on each axis,
or saying that the axis found nothing.
