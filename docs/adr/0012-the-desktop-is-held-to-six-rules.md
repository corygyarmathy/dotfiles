# ADR 0012: the desktop is held to six rules

- **Status:** Proposed
- **Date:** 2026-11-27
- **Related Artefacts:**
    - Constrains: [modules/home/desktop/](../../modules/home/desktop), [configs/](../../configs), [lib/kanagawa-wave.nix](../../lib/kanagawa-wave.nix), [lib/geometry.nix](../../lib/geometry.nix)

## Context

The desktop on `xps15` was designed against six principles and two rules derived from them. They lived in a plan document, and dozens of code comments cited them from there. That plan has been deleted, because plans here are written once and deleted when their work lands. The principles are not plan content, though. They are the standard that every desktop change is reviewed against, they outlive any one tool choice, and the code relies on them.

## Decision

Every desktop surface, whichever tool provides it, is held to these rules. A change that breaks one is wrong even if it works.

1. **Fast.** Anything the user starts is complete within 150 ms. Anything the system starts on its own may take longer but never blocks input. No poller runs faster than the thing it watches changes. There is no motion: user-initiated changes are instant, and only a change the system makes on its own schedule may be gradual.
2. **Keyboard first, with pointer backups.** Every action has a keybind, and every action that can be a pointer target is one. The keybinds are discoverable, so the list of bindings is itself a surface.
3. **The user is the driver.** Nothing takes focus the user didn't ask for. Notifications are for things the user didn't know; information the user asked for goes somewhere else. Muting is one keystroke.
4. **System state is visible.** Anything the user would otherwise open a terminal for daily (network, audio, bluetooth, power, mounts, what is running, what has failed) is at most two interactions away.
5. **Consistent.** One palette, one geometry scale and one input grammar. A colour or a length is named in exactly one file. A surface that cannot be themed from that file gets replaced, or is listed as an exception with its reason.
6. **Maintainable.** Prefer a declarative option over a script, and a script over a daemon. A tool stays only while nothing simpler can do its job. Anything that breaks does so loudly, and a check catches it when the failure would otherwise be silent.

Two rules follow from combining them:

- **The escalation ladder** (1, 3 and 4). Information about the system lives at four depths: _glance_ (always visible, no interaction), _hover_ (a tooltip), _pick_ (a panel or menu, one click or keystroke away, dismissed with Escape) and _full_ (the application itself). Each fact lives at exactly one depth and is reachable from the depth above. Anything only interesting when abnormal shows nothing at glance depth while it is normal.
- **One owner per responsibility** (5 and 6). Colour, window geometry, surfaces, idle timing: each has exactly one owner. A change that gives a responsibility a second owner is wrong even if it works. Which tool owns what is a parameter of the current implementation, and is recorded in the modules, not here.

The numbers (150 ms, two interactions, four depths) are part of the rules, because they are what a change can be checked against.

## Consequences

**Positive**

- Code comments and reviews can cite one stable document for _why_ a surface is shaped the way it is, instead of a plan item that disappears.
- The rules survive changing tools. The move from waybar, rofi and dunst to a single shell changes the owners, not the standard.

**Negative**

- The rules are strict enough to reject reasonable additions, such as a permanently displayed CPU percentage. That is the intent, but it means a rule sometimes has to be argued with rather than followed.
- Rule 5's "one file" makes every surface that can't be themed from the source an exception to defend, which grows into a list if tools are chosen carelessly.

## Alternatives considered

- **Keep the original rule 6 wording, "a daemon over a framework".** It was written to rule out a shell framework, and it would now rule out moving to a single Quickshell shell. That move is wanted because one programmable surface does rules 4 and 5 better than six separately themed tools. The rule was restated as "a tool stays only while nothing simpler can do its job", which still refuses frameworks adopted for their own sake.
- **Keep the principles in a README under `modules/home/desktop/`.** READMEs here are for orientation only, and a README is easy to edit quietly. A review standard should change only through a new decision.
- **Drop them and let each plan restate what it needs.** That is how they ended up living in a plan in the first place, with the code citing something that was always going to be deleted.
