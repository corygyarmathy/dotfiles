#!/usr/bin/env python3
"""Grow the garden's bonsai: a picture of the vault, drawn from the vault.

Item 18 of docs/plans/digital-garden-design.md, and the answer to the brief
that started that plan ("the site is a little boring"). The rejected answer was
a stock photograph; the accepted rule is that anything added has to *report
something true about the note it sits beside*. So this is not a decorative
tree. The trunk is the site, each branch carries several notes, and every
published note is one foliage pad whose glyph is its maturity stage and whose
colour is its topic. Add a note and the tree grows; rewrite one and its pad
changes.

The growth model is `cbonsai`'s, with one rule changed. **Branch count grows as
the square root of the note count, and each branch carries several notes**,
dropping each one's pad at its own point along its length. One shoot per note -
the obvious rule, and the one the prototype started with - makes wood grow as
fast as the canopy does, and past about sixty notes the tree is a thicket. Under
the square-root rule eighteen notes get seven branches, sixty get thirteen, two
hundred get eighteen: the canopy fills in and deepens while the wood barely
changes, and every note still keeps a pad of its own.

Called by publish-filter.py, which is the only thing that knows the published
set, and emitted as static markup - a few kilobytes of `<span>`-wrapped
characters - so the page ships no generator and no library. The reader's
browser only ever reveals characters that are already in the HTML.

Run it directly to look at trees rather than at the site, which is the loop the
plan's "taste pass" needs:

    python3 bonsai.py                  # the vault's eighteen, as text
    python3 bonsai.py --notes 60       # what sixty would look like
    python3 bonsai.py --seed 3 --html  # the markup, for a given seed

Determinism is a requirement rather than a nicety. The builder skips a rebuild
when the staging tree hashes the same as last time (see digital-garden.nix), so
a tree that reseeded itself on every run would defeat that gate and rewrite the
site hourly for no reason. Hence a fixed default seed and a PRNG written out
here in full: `random` is deterministic for a given CPython but is not promised
to be stable across versions, and this has to draw the same tree in five years'
time.
"""

import argparse
import collections
import html
import math
import sys

# One published note, as the tree needs to know it. `stage` is one of the three
# keys of LEAF below and `topic` is a CSS-class-safe label or the empty string;
# publish-filter.py, which builds these, is what guarantees both, so nothing
# here has to defend against a hand-written `maturity: mature`.
Note = collections.namedtuple("Note", "title url words stage topic")

# The default seed. Any value draws a tree; this one is the seed the prototype
# the design session was held against happened to use, so the shipped tree is
# the tree that was looked at and agreed to.
DEFAULT_SEED = 7

# Branch count is `round(sqrt(notes) * SPREAD)`, clamped. SPREAD is the one
# knob the taste pass is expected to move: lower packs the same notes onto
# fewer, heavier limbs, higher opens the canopy into more, lighter ones. At
# 1.7, eighteen notes get 7 branches, sixty get 13, two hundred get 18.
SPREAD = 1.7
MIN_BRANCHES = 3
# Not a limit on notes - a limit on WOOD. Past this the canopy keeps filling in
# and the trunk stops sprouting new limbs, which is the whole mechanism for
# staying a tree rather than becoming a thicket.
MAX_BRANCHES = 18

# The canvas. Wide enough for the widest branch reach (the trunk wanders, and a
# branch is clamped to 30 columns either side of it, with a pad another 7 wide
# on top of that), and cropped to what actually grew before it is emitted.
WIDTH = 100

# The maturity stages, as glyphs. Three characters that read as increasing
# density at a glance and need no legend to be understood in order.
LEAF = {"seedling": ".", "sapling": "*", "evergreen": "&"}

# How many cells of the pad each stage fills. A more mature note is a bigger
# mass of foliage, which is the whole of the "glyph is its maturity" rule -
# stage is carried by size as well as by character, so it survives being looked
# at from across the room.
PAD_CELLS = {"seedling": 6, "sapling": 12, "evergreen": 20}

# Which way a shoot leaves the trunk.
SHOOT_LEFT, SHOOT_RIGHT = -1, 1


def _round(x):
    """Round half away from zero, the way JavaScript's Math.round does.

    Python rounds halves to even, so `round(0.5)` is 0 and `round(1.5)` is 2.
    Every number in this file was tuned against a JavaScript prototype, and a
    branch count or a fork point that lands on exactly .5 would otherwise draw
    a different tree here than the one that was agreed to.
    """
    return math.floor(x + 0.5)


def mulberry32(seed):
    """A 32-bit PRNG, written out so the tree is stable forever.

    `random.Random` would do, and its Mersenne Twister is stable in practice -
    but "in practice" is the wrong guarantee for something whose output is
    hashed by the build's skip-if-unchanged gate. Mulberry32 is nine lines of
    arithmetic with no library behind it, so the tree a seed draws is fixed by
    this file and by nothing else.
    """
    state = seed & 0xFFFFFFFF

    def next_float():
        nonlocal state
        state = (state + 0x6D2B79F5) & 0xFFFFFFFF
        t = ((state ^ (state >> 15)) * (state | 1)) & 0xFFFFFFFF
        t = ((t + (((t ^ (t >> 7)) * (t | 61)) & 0xFFFFFFFF)) & 0xFFFFFFFF) ^ t
        return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296

    return next_float


def _pad_offsets():
    """Cell offsets of one foliage pad, nearest the centre first.

    A pad, not a sprinkle. The offsets are ordered by distance from the centre
    with x scaled by half, because a character cell is about twice as tall as
    it is wide - so a pad that is round in cells comes out as a tall column on
    screen, and one that is round on screen has to be twice as wide in cells.
    Filling nearest-first means adjacent pads overlap into continuous masses,
    which is what a bonsai canopy actually is.
    """
    out = []
    for dy in range(-3, 4):
        for dx in range(-7, 8):
            out.append((dx, dy, math.hypot(dx * 0.5, dy * 1.05)))
    out.sort(key=lambda o: o[2])
    return [(dx, dy) for dx, dy, _ in out]


PAD = _pad_offsets()


def canvas_height(count):
    """Tall enough that the canopy has sky to grow into.

    The tree has to have somewhere to put a pad that lands on occupied cells,
    because a note with no visible pad is a note the tree is lying about (see
    `grow`). These are the prototype's three sizes, plus a fourth rule so that
    a vault which keeps growing keeps getting canvas rather than eventually
    running out of free cells.
    """
    if count <= 45:
        return 26
    if count <= 100:
        return 30
    if count <= 200:
        return 34
    return 34 + 4 * ((count - 101) // 100)


class Cell:
    """One drawn character: what it is, what it is made of, and when it grew."""

    __slots__ = ("char", "kind", "note", "grew")

    def __init__(self, char, kind, note, grew):
        self.char = char
        # "wood", "soil", or "leaf".
        self.kind = kind
        # The index of the note this cell grew from, or None for wood and soil.
        self.note = note
        # Position in the order the tree was drawn, which is the order the
        # growth animation reveals it in.
        self.grew = grew


class Tree:
    """A grown tree: the grid it was drawn on, cropped to what is on it."""

    def __init__(self, rows, branches):
        self.rows = rows
        self.branches = branches


def grow(notes, seed=DEFAULT_SEED, spread=SPREAD):
    """Draw the tree, and prove every note is on it.

    `notes` is a sequence of note records - anything with `.words`, `.stage`
    and `.topic` - and a note's index in that sequence is the identity its
    foliage carries. The sequence has to be in a stable order, because the
    branch buckets are dealt from it.
    """
    rng = mulberry32(seed)

    def ri(n):
        return int(rng() * n)

    height = canvas_height(len(notes))
    grid = [[None] * WIDTH for _ in range(height)]
    drawn = 0

    centre = _round(WIDTH / 2)
    # Where the trunk starts, which is the soil line: the trunk's first step
    # moves it up to `ceiling`, so the lowest wood sits directly on the ground
    # rather than a row above it with a gap in between.
    soil_y = height - 3
    # Nothing may grow at or below the soil line. Without this a branch leaving
    # the trunk low down drifts downward until its foliage is lying on the
    # ground beside the tree, which looks exactly like what it is: a bug.
    ceiling = soil_y - 1

    def place(x, y, char, kind, note=None, floor=ceiling):
        nonlocal drawn
        xi, yi = _round(x), _round(y)
        if xi < 0 or xi >= WIDTH or yi < 0 or yi > floor:
            return False
        if grid[yi][xi] is not None:
            return False
        grid[yi][xi] = Cell(char, kind, note, drawn)
        drawn += 1
        return True

    def draw_str(x, y, s, kind):
        for k, char in enumerate(s):
            place(x + k, y, char, kind)

    def foliage(x, y, index, note):
        """One note's pad, and the guarantee that it is visible.

        Every note must be on the tree - that is the premise of the whole
        feature - and a note whose pad landed entirely on already-occupied
        cells would be one you can neither see nor point at. In a dense canopy
        that happens often, so when the pad places nothing the search widens
        outward, and upward first, where there is open sky.
        """
        char = LEAF[note.stage]
        placed = 0
        for dx, dy in PAD[: PAD_CELLS[note.stage]]:
            if place(x + dx, y + dy, char, "leaf", index):
                placed += 1
        if placed:
            return
        for r in range(1, max(WIDTH, height)):
            for dy in range(-r, r + 1):
                for dx in range(-r * 2, r * 2 + 1):
                    if place(x + dx, y + dy, char, "leaf", index):
                        return

    # How many branches, and who rides on each.
    branches = max(
        MIN_BRANCHES, min(MAX_BRANCHES, _round(math.sqrt(len(notes)) * spread))
    )
    buckets = [[] for _ in range(branches)]
    # Longest first, dealt round-robin, so that no branch carries only the long
    # notes and none carries only stubs - the canopy's weight is spread over
    # the tree instead of hanging off one limb.
    order = sorted(range(len(notes)), key=lambda i: -notes[i].words)
    for k, index in enumerate(order):
        buckets[k % branches].append(index)

    lean = 1 if ri(2) else -1

    def trunk_glyph(age, dx, dy):
        # Tapered: three characters at the base, two through the middle, one at
        # the top. A full-width trunk string at every step is what made the
        # prototype's first tree read as a bundle of sticks.
        if age < 3:
            if dy == 0:
                return "/~"
            return "/|\\" if dx == 0 else ("\\|" if dx < 0 else "|/")
        if age < 7:
            if dy == 0:
                return "/~"
            return "\\|" if dx < 0 else ("|/" if dx > 0 else "|")
        if dy == 0:
            return "~"
        return "\\" if dx < 0 else ("/" if dx > 0 else "|")

    def shoot_glyph(side, dx, dy):
        if side == SHOOT_LEFT:
            if dy > 0:
                return "\\"
            if dy == 0:
                return "\\_"
            return "\\" if dx < 0 else "/"
        if dy > 0:
            return "/"
        if dy == 0:
            return "_/"
        return "\\" if dx < 0 else "/"

    def branch(x, y, side, bucket):
        # Long enough to carry what rides on it: the notes themselves set the
        # length, so a limb holding five long notes reaches further than one
        # holding two stubs, and the tree's proportions are the vault's.
        life = max(
            3,
            _round(
                2
                + len(bucket) * 1.5
                + math.sqrt(sum(notes[i].words for i in bucket)) / 22
            ),
        )
        # Where along the branch each note drops its pad - spaced out, with the
        # last at the tip.
        at = {}
        for k, index in enumerate(bucket):
            at.setdefault(_round(((k + 1) / len(bucket)) * (life - 1)), []).append(
                index
            )
        start_y = y
        for step in range(life):
            r = ri(10)
            dy = -1 if r > 5 else (0 if r > 1 else 1)
            dx = -1 if side == SHOOT_LEFT else 1
            x += dx
            y += dy
            # A branch may sag by a row, but never descend. This and the
            # ceiling above are the two halves of one fix: foliage on the
            # ground was a branch that left the trunk low and kept going down.
            y = min(y, start_y + 1, ceiling)
            y = max(y, 1)
            x = min(max(x, centre - 30), centre + 30)
            draw_str(x, y, shoot_glyph(side, dx, dy), "wood")
            for index in at.get(step, ()):
                foliage(x, y, index, notes[index])

    trunk_life = 13 + _round(branches * 0.8)
    # Branches leave the upper half of the trunk only, so that nothing sprouts
    # out of the soil. Clamped to the last trunk step, because unclamped the
    # final fork point landed one step PAST the end of the trunk: that branch
    # never grew, and the notes riding on it were silently missing from the
    # tree. The assertion at the foot of this function is what caught it.
    fork_at = {}
    for i in range(branches):
        step = min(
            trunk_life - 1,
            _round(trunk_life * 0.55 + (i / max(1, branches - 1)) * trunk_life * 0.44),
        )
        fork_at.setdefault(step, []).append(i)

    tx, ty = centre, soil_y
    for step in range(trunk_life):
        # A trunk whose sideways step is a fresh random number every step
        # averages to vertical however wide the range is. The lean persists and
        # reverses occasionally instead, so the trunk sweeps out and doubles
        # back the way a trained bonsai does.
        if ri(10) > 7:
            lean = -lean
        dy = -1 if ri(10) > 2 else 0
        dx = lean * (2 if ri(10) > 7 else 1)
        tx += dx
        ty = max(2, min(ty + dy, ceiling))
        draw_str(tx, ty, trunk_glyph(step, dx, dy), "wood")
        for i in fork_at.get(step, ()):
            # Alternating sides, so consecutive fork points do not pile every
            # limb onto one flank of the trunk.
            branch(tx, ty, SHOOT_RIGHT if i % 2 else SHOOT_LEFT, buckets[i])

    # The ground, drawn last and below the ceiling every other rule respects -
    # it is not something that grew, it is what the tree is standing in. The
    # prototype declared a colour for it and never drew a cell: its soil went
    # through the same bounds check as the foliage, which rejects everything at
    # or below this row by definition.
    for i in range(-14, 15):
        place(centre + i, soil_y, "." if i % 3 == 0 else "_", "soil", floor=soil_y)

    # The assertion the plan asks for, and the one that found both of the bugs
    # recorded above. A tree that quietly drops a note is worse than no tree:
    # the whole claim of this feature is that it is a picture of the garden.
    on_tree = {
        c.note for row in grid for c in row if c is not None and c.note is not None
    }
    assert len(on_tree) == len(notes), (
        f"bonsai lost {len(notes) - len(on_tree)} of {len(notes)} notes: "
        f"{sorted(set(range(len(notes))) - on_tree)}"
    )

    return Tree(_crop(grid), branches)


def _crop(grid):
    """Trim the canvas to what actually grew.

    The tree is drawn on a canvas wide enough for the worst case and is never
    that wide, so cropping is what lets the composition be centred on the tree
    rather than on the grid it happens to have been drawn on.
    """
    filled = [(y, x) for y, row in enumerate(grid) for x, c in enumerate(row) if c]
    if not filled:
        return []
    top = min(y for y, _ in filled)
    bottom = max(y for y, _ in filled)
    left = min(x for _, x in filled)
    right = max(x for _, x in filled)
    return [row[left : right + 1] for row in grid[top : bottom + 1]]


def to_text(tree):
    """The tree as plain characters, for looking at one in a terminal."""
    return "\n".join(
        "".join(c.char if c else " " for c in row).rstrip() for row in tree.rows
    )


def to_html(tree, notes):
    """The tree as the markup the page ships.

    One `<span>` per drawn character, carrying three things: what it is made of
    (so the stylesheet can colour wood, soil and each topic), which note it
    grew from (so pointing at any cell of a pad can light the whole pad and
    name the note), and when it was drawn (so the growth animation can reveal
    the characters in the order the tree grew rather than wiping down the page).

    Rows are right-stripped: trailing spaces inside a `<pre>` are invisible and
    are pure weight, and there is one row of them for every row of the tree.

    `aria-hidden`, and deliberately so. This is an ENHANCEMENT and not a route
    to a note: a tab order made of single characters would be a far worse way
    to reach one than /notes/, which is the complete accessible path and is
    already there. The caption store below it is hidden from everyone - it is
    where the caption's words live, not something to read in document order.
    """
    lines = []
    for row in tree.rows:
        out = []
        blanks = 0
        for cell in row:
            if cell is None:
                blanks += 1
                continue
            out.append(" " * blanks)
            blanks = 0
            classes = cell.kind
            if cell.note is not None:
                topic = notes[cell.note].topic
                if topic:
                    classes += f" topic-{topic}"
            note_attr = "" if cell.note is None else f' data-note="{cell.note}"'
            out.append(
                f'<span class="{classes}"{note_attr} data-grow="{cell.grew}">'
                f"{html.escape(cell.char)}</span>"
            )
        lines.append("".join(out))

    captions = []
    for index, note in enumerate(notes):
        topic = f" topic-{note.topic}" if note.topic else ""
        captions.append(
            f'<span data-note="{index}" data-url="{html.escape(note.url, quote=True)}">'
            f"<b>{html.escape(note.title)}</b> &middot; "
            f"{note.words:,} words &middot; "
            f'<span class="stage{topic}">{note.stage}</span></span>'
        )

    return (
        '<div class="bonsai-plate">\n'
        '<pre class="bonsai" aria-hidden="true">'
        + "\n".join(lines)
        + "</pre>\n"
        + '<p class="bonsai-caption" aria-hidden="true"></p>\n'
        + '<div class="bonsai-notes" hidden>'
        + "".join(captions)
        + "</div>\n</div>\n"
    )


def render(notes, seed=DEFAULT_SEED, spread=SPREAD):
    """Grow a tree from `notes` and return the markup for it."""
    return to_html(grow(notes, seed, spread), notes)


# ---- running this file directly -----------------------------------------
#
# The plan calls the taste pass a second session of its own, and says the only
# way to judge a tree is to generate many and look at them. That needs a loop
# that does not involve a vault, a build or a browser, which is all this is.


def _synthetic(count, seed):
    """A plausible garden of `count` notes.

    Word counts follow a long tail - most notes short, a few very long - which
    is the shape of the real vault and the shape that decides how the branches
    are dealt. These claim nothing about anyone's notes; they exist to answer
    "what does this look like at sixty".
    """
    rng = mulberry32(seed + 9973)
    notes = []
    for i in range(count):
        words = _round(60 + rng() ** 2.2 * 3000)
        stage = (
            "evergreen" if words > 1200 else "sapling" if words > 380 else "seedling"
        )
        notes.append(
            Note(
                f"Note {i + 1}",
                f"/note-{i + 1}/",
                words,
                stage,
                "slip-box" if rng() > 0.28 else "lighting",
            )
        )
    return notes


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--notes", type=int, default=18, help="how many notes to grow")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument(
        "--spread",
        type=float,
        default=SPREAD,
        help="branch-count multiplier on sqrt(notes)",
    )
    parser.add_argument(
        "--html", action="store_true", help="print the markup instead of the tree"
    )
    args = parser.parse_args(argv[1:])

    notes = _synthetic(args.notes, args.seed)
    tree = grow(notes, args.seed, args.spread)
    if args.html:
        print(to_html(tree, notes), end="")
    else:
        print(to_text(tree))
        print(
            f"\n{len(notes)} notes, {tree.branches} branches, "
            f"seed {args.seed}, spread {args.spread}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
