#!/usr/bin/env python3
"""Grow the garden's bonsai: a picture of the vault, drawn from the vault.

Item 18 of docs/plans/digital-garden-design.md, and the answer to the brief
that started that plan ("the site is a little boring"). The rejected answer was
a stock photograph; the accepted rule is that anything added has to *report
something true about the note it sits beside*. So this is not a decorative
tree. The trunk is the site, and every published note is a clump of foliage
whose glyphs are its maturity and whose hue is its topic. Add a note and the
tree grows; rewrite one and its clump changes.

**The crown's outline is computed first, and everything else only decides where
the sky inside it is.** That is the one structural idea in this file, and it
replaced a growth model taken from `cbonsai`: walk each branch at random, drop
foliage wherever it stops, and let the union of those pads be the tree's
silhouette. Under that model every pad placement was a chance to spoil the
shape, and with seven pads there were seven chances - which is exactly what
"it only looks like a bonsai on some seeds" was. Here the silhouette is a
designed dome that nothing downstream is allowed to change, the trunk is a
designed S-curve rather than a random walk, and what is seeded is the variation
within those shapes rather than the shapes themselves.

Two consequences worth stating, because both were bugs before:

**The canopy's AREA is budgeted, and grows as `notes ** 0.6`.** Every note used
to take six to twenty cells whatever the vault held, so the canopy's area grew
linearly with the garden: nineteen notes drew about 215 cells, a hundred and
twenty about 1,430, and two hundred about 2,400, by which point the tree was a
solid blob that only got bigger. A canopy is a silhouette, not a sum. Nineteen
notes now draw about 245 cells and two hundred about 920 - four times the notes
for less than four times the foliage, and still a tree.

**The number of foliage pads is capped.** A trained bonsai carries a handful of
pads however old it is - an older tree grows more foliage per pad, it does not
sprout more pads - and the cap is what stops the crown fragmenting into islands
as the garden grows.

The organic quality is PyBonsai's (https://github.com/Ben-Edwards44/PyBonsai),
and it comes from two things that file does and this one now does too: each
cell's glyph is picked at random from a SET rather than fixed, and each cell
carries a lightness. Here the set is the note's maturity - so the glyph still
says what it always said - and the lightness comes from one light source over
the whole crown, which is what makes the mass read as a form rather than as a
flat colour.

Called by publish-filter.py, which is the only thing that knows the published
set, and emitted as static markup - a few kilobytes of `<span>`-wrapped
characters - so the page ships no generator and no library. The reader's
browser only ever reveals characters that are already in the HTML.

Run it directly to look at trees rather than at the site, which is the loop the
plan's "taste pass" needs:

    python3 bonsai.py                  # the vault's nineteen, as text
    python3 bonsai.py --notes 120      # what a hundred and twenty would look like
    python3 bonsai.py --seeds 6        # six seeds, to judge consistency
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
# keys of LEAF_CHARS below and `topic` is a CSS-class-safe label or the empty
# string; publish-filter.py, which builds these, is what guarantees both, so
# nothing here has to defend against a hand-written `maturity: mature`.
Note = collections.namedtuple("Note", "title url words stage topic")

# The default seed. Any value draws a tree - that is the point of the rewrite -
# so this is no longer load-bearing the way it was when only some seeds worked.
DEFAULT_SEED = 7

# A character cell is about this many times taller than it is wide, once the
# stylesheet's `line-height: 1.05` is applied. Anything meant to look round on
# screen has to be this much wider than it is tall in cells, and the number
# appears wherever a distance is compared across the two axes.
ASPECT = 1.9

# How much wider than tall the crown looks ON SCREEN. A bonsai's crown is a
# broad, shallow dome; a tall narrow one reads as a conifer.
CANOPY_ASPECT = 1.6

# The crown's underside, as a fraction of its top half. Foliage grows up into
# the light and is cut off below by the branches carrying it, so the shape is
# flat-bottomed rather than elliptical.
CROWN_UNDER = 0.62

# How much of the crown's area is the sky BETWEEN the foliage plates. Below
# about 0.25 the plates merge into one mass and the tree stops reading as
# layered; above about 0.4 they come apart into separate bushes.
GAP = 0.24

# The canopy's area in cells is `CANOPY_A * notes ** CANOPY_B`. This is the
# whole of the fix for the blob, and CANOPY_B is the number that matters: at
# 0.6, tripling the garden roughly doubles the crown. CANOPY_A is then just the
# size of the picture, chosen so that today's vault draws a tree about as big
# as the one it replaces.
CANOPY_A = 38.0
CANOPY_B = 0.60

# Foliage pads: how many masses the crown is divided into. Not one per note and
# not one per branch - a trained bonsai has a handful, and MAX_PADS is what
# keeps a large garden reading as an old tree rather than as a shrub. At eleven
# the channels between the pads outnumbered the pads.
PAD_A = 1.20
MIN_PADS, MAX_PADS = 3, 7

# The maturity stages, as glyph SETS. Three fixed characters was legible and
# completely flat; picking each cell out of a set is where PyBonsai's organic
# quality comes from. The sets are as far apart in density as `.` `*` `&` were,
# so maturity still reads at a glance and still needs no legend - what varies
# inside a set is texture, and it carries no meaning.
LEAF_CHARS = {
    "seedling": ".,'`",
    "sapling": "*^v+",
    "evergreen": "&%#@",
}

# Relative canopy weight per stage. These are RATIOS, not cell counts: what a
# note actually gets is its share of the budget above, so a bigger garden makes
# every note's clump smaller rather than making the tree bigger.
STAGE_WEIGHT = {"seedling": 6, "sapling": 12, "evergreen": 20}

# Texture for the wood. Same idea as the leaf sets: most cells take the glyph
# their direction calls for and some take one of these instead, which is what
# stops a trunk reading as a drawn line.
TRUNK_CHARS = "|:;"
BRANCH_CHARS = "~-="


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


class Cell:
    """One drawn character: what it is, what it is made of, and when it grew."""

    __slots__ = ("char", "kind", "note", "shade", "grew")

    def __init__(self, char, kind, note, shade, grew):
        self.char = char
        # "wood", "leaf", "soil" or "pot".
        self.kind = kind
        # The index of the note this cell grew from, or None for everything
        # that is not foliage.
        self.note = note
        # "lit", "mid" or "shade" - where this cell sits relative to the one
        # light source over the tree. The stylesheet turns it into a lightness.
        self.shade = shade
        # Position in the order the tree was drawn, which is the order the
        # growth animation reveals it in.
        self.grew = grew


class Tree:
    """A grown tree: the grid it was drawn on, cropped to what is on it."""

    def __init__(self, rows, pads, leaves):
        self.rows = rows
        self.pads = pads
        self.leaves = leaves


def grow(notes, seed=DEFAULT_SEED):
    """Draw the tree, and prove every note is on it.

    `notes` is a sequence of note records - anything with `.words`, `.stage`
    and `.topic` - and a note's index in that sequence is the identity its
    foliage carries. The sequence has to be in a stable order, because the pad
    buckets are dealt from it.
    """
    rng = mulberry32(seed)

    def jit(spread):
        return (rng() * 2 - 1) * spread

    def pick(chars):
        return chars[int(rng() * len(chars))]

    count = len(notes)
    pads = max(MIN_PADS, min(MAX_PADS, round(math.sqrt(count) * PAD_A)))

    # ---- how big the crown is ---------------------------------------------
    # `max(count, ...)` because every note must end up with at least one cell,
    # and for a very small garden the budget is smaller than the note count.
    budget = max(count, CANOPY_A * count**CANOPY_B)
    area = budget / (1 - GAP)

    # The crown's two radii, solved from that area and from the aspect it
    # should have ON SCREEN - which is not the aspect it has in cells, because
    # a cell is not square. Getting this wrong is how the first cut drew a
    # crown that was correct in the grid and a tall narrow bush to look at.
    stretch = CANOPY_ASPECT * ASPECT * (1 + CROWN_UNDER) / 2
    crown_h = math.sqrt(area / (math.pi * stretch * (1 + CROWN_UNDER) / 2))
    crown_w = stretch * crown_h

    # ---- the trunk --------------------------------------------------------
    # A designed S-curve: only its amplitude, phase and direction are seeded.
    # The old trunk was a random walk with a persistent lean and a rein on how
    # far it could wander, which is three rules fighting each other to
    # approximate the shape this one just has.
    #
    # `clear` is the bare trunk under the crown, and it is what separates a
    # trained tree from a shrub. It stops growing with the garden on purpose:
    # proportional to the crown, a two-hundred-note tree stood on stilts.
    clear = 1.6 + min(crown_h, 9.0) * 0.26
    crown_y = clear + crown_h * CROWN_UNDER
    trunk_h = crown_y + crown_h * 0.55

    amp = min(3.2, 1.6 + crown_w * 0.09) + jit(0.8)
    swing = 1.45 + jit(0.35)
    phase = jit(0.8)
    lean = 1 if rng() > 0.5 else -1

    def trunk_x(t):
        """The trunk's centre line, `t` running 0 at the soil to 1 at the top.

        The amplitude decays with height, so the base leans one way and the
        apex comes back over it - which is the movement a trained trunk has and
        the reason the tree does not read as falling over.
        """
        t = max(0.0, min(1.0, t))
        return lean * amp * math.sin(t * swing * math.pi + phase) * (1 - 0.45 * t)

    crown_x = trunk_x(crown_y / trunk_h) * 0.5

    # ---- the crown's outline ----------------------------------------------
    # Lobed rather than elliptical. The perturbation is a smooth function of
    # the ANGLE, so the edge bulges and hollows over several cells at a time;
    # an independent draw per cell gives a salt-and-pepper fringe, which reads
    # as a rendering fault rather than as foliage. Two harmonics: one slow one
    # for the overall lopsidedness, one faster for the lobes.
    lobe_a, lobe_b = 2 + int(rng() * 2), 4 + int(rng() * 3)
    turn_a, turn_b = rng() * 2 * math.pi, rng() * 2 * math.pi
    deep_a, deep_b = 0.10 + rng() * 0.09, 0.04 + rng() * 0.05

    def inside(dx, dy):
        span = crown_h if dy >= 0 else crown_h * CROWN_UNDER
        u, v = dx / crown_w, dy / span
        radius = math.hypot(u, v)
        if radius == 0:
            return True
        angle = math.atan2(v, u)
        edge = (
            1.0
            + deep_a * math.sin(lobe_a * angle + turn_a)
            + deep_b * math.sin(lobe_b * angle + turn_b)
        )
        return radius <= edge

    # Held as INTEGER offsets from the crown's centre, not as absolute
    # positions. Two cells being neighbours has to be an exact test - the
    # pruning below counts neighbours - and `(crown_x + dx) + 1` is not
    # reliably the same float as `crown_x + (dx + 1)`.
    crown = [
        (dx, dy)
        for dy in range(-int(crown_h * CROWN_UNDER) - 2, int(crown_h) + 3)
        for dx in range(-int(crown_w) - 2, int(crown_w) + 3)
        if inside(dx, dy)
    ]

    # ---- where the sky inside the crown is --------------------------------
    # Pad centres, in tiers: a left and a right pad at about the same height,
    # and one apex pad over the trunk's top. Tiers rather than one pad per
    # height stepping up the trunk, because alternating single pads puts every
    # left pad low and every right pad high whatever the mass balance says.
    #
    # Their exact positions no longer decide the tree's outline - only where
    # the channels between the plates fall - which is the whole point of
    # computing the outline first.
    tiers = max(1, pads // 2)
    centres = []
    for i in range(pads):
        if i == pads - 1:
            centres.append((crown_x + jit(0.6), crown_y + crown_h * 0.62))
            continue
        height = (i // 2 + 0.5) / tiers
        y = crown_y - crown_h * CROWN_UNDER * 0.7 + height * crown_h * 1.35
        side = -1 if i % 2 == 0 else 1
        # The two pads of a tier are not level. Level, the channel between one
        # tier and the next runs clean across the crown as a horizontal band of
        # sky, which cuts the tree in half; offset, the channels break up and
        # read as gaps between plates.
        y += side * crown_h * 0.16
        half = crown_w * math.sqrt(max(0.04, 1 - ((y - crown_y) / crown_h) ** 2))
        centres.append((crown_x + side * half * (0.42 + 0.22 * rng()), y + jit(0.5)))

    def nearest_two(dx, dy):
        """The nearest pad centre, and how far the second nearest is."""
        x, y = crown_x + dx, crown_y + dy
        best, best_at, second = 1e9, -1, 1e9
        for i, (px, py) in enumerate(centres):
            d = math.hypot((x - px) / ASPECT, y - py)
            if d < best:
                best, best_at, second = d, i, best
            elif d < second:
                second = d
        return best, best_at, second

    kept = {}
    for dx, dy in crown:
        near, which, far = nearest_two(dx, dy)
        # A cell roughly equidistant from two pads is sky. Those channels are
        # what separate one plate of foliage from the next, and they are the
        # difference between a layered tree and a single green mass.
        if far > 0 and near / far > 0.84 - 0.05 * rng():
            continue
        kept[(dx, dy)] = (which, near)

    # Prune the fringe. The lobed outline and the channels between them both
    # leave cells with almost nothing beside them, and a scatter of single
    # characters around a crown reads as dust rather than as foliage - most
    # visibly where a seedling's glyphs, which are the lightest set, land on
    # the edge. Two passes, because removing a cell can orphan its neighbour.
    for _ in range(2):
        lonely = [
            at
            for at in kept
            if sum(
                ((at[0] + ddx, at[1] + ddy) in kept)
                for ddx, ddy in ((1, 0), (-1, 0), (0, 1), (0, -1))
            )
            < 2
        ]
        for at in lonely:
            del kept[at]

    foliage = [(dx, dy, which, near) for (dx, dy), (which, near) in kept.items()]

    # ---- who owns which cell ----------------------------------------------
    # The pads' sizes come out of the geometry, so the notes are dealt to MATCH
    # them: longest note first, each to whichever pad is furthest below its
    # share, so no pad ends up carrying only the long notes or only the stubs.
    #
    # Deliberately NOT grouped by shelf. Putting each topic on a pad of its own
    # was tried and drew hard-edged blocks of colour: the tree read as a chart
    # of itself rather than as foliage. Spread, the hues interleave at the
    # scale of a note's clump, which is the scale foliage varies at.
    by_pad = collections.defaultdict(list)
    for cell in foliage:
        by_pad[cell[2]].append(cell)
    sizes = {i: len(v) for i, v in by_pad.items()}
    live = [i for i in sizes if sizes[i]]
    total_cells = sum(sizes.values())
    total_weight = sum(STAGE_WEIGHT[note.stage] for note in notes)

    buckets = collections.defaultdict(list)
    load = collections.defaultdict(float)
    for index in sorted(range(count), key=lambda i: -notes[i].words):
        at = max(live, key=lambda k: sizes[k] - load[k])
        buckets[at].append(index)
        load[at] += total_cells * STAGE_WEIGHT[notes[index].stage] / total_weight

    # Inside a pad, each note grows from a seed point of its own and takes the
    # cells nearest it. A note's cells have to be a CLUMP and not a sprinkle:
    # pointing at foliage lights the whole note and names it, and a note
    # scattered through a pad would be impossible to point at.
    owner = {}
    for i in live:
        bucket = buckets.get(i)
        if not bucket:
            continue
        cells = sorted(by_pad[i], key=lambda c: c[3])
        px, py = centres[i]
        weights = [STAGE_WEIGHT[notes[b].stage] for b in bucket]
        share = sum(weights)
        room = {
            b: max(1, round(len(cells) * w / share)) for b, w in zip(bucket, weights)
        }
        seeds = []
        for k, b in enumerate(bucket):
            angle = (k / len(bucket)) * 2 * math.pi + rng() * 0.8
            radius = 0.35 + 0.45 * ((k % 3) / 2.0)
            seeds.append(
                (
                    px + math.cos(angle) * ASPECT * 3.0 * radius,
                    py + math.sin(angle) * 2.0 * radius,
                    b,
                )
            )
        for dx, dy, _, _ in cells:
            x, y = crown_x + dx, crown_y + dy
            best, best_d = None, None
            for sx, sy, b in seeds:
                if room[b] <= 0:
                    continue
                d = math.hypot((x - sx) / ASPECT, y - sy)
                if best_d is None or d < best_d:
                    best, best_d = b, d
            if best is None:
                # Every seed is full and there are cells over: they go to
                # whichever note is nearest, because a hole in the crown would
                # be a hole in the outline this whole file exists to protect.
                best = min(
                    seeds, key=lambda s: math.hypot((x - s[0]) / ASPECT, y - s[1])
                )[2]
            else:
                room[best] -= 1
            owner[(dx, dy)] = best

    # ---- the canvas -------------------------------------------------------
    pot_half = max(6, int(crown_w * 0.54))
    # The pot goes under the tree as a whole and not under the trunk's base. A
    # bonsai's trunk enters its pot off-centre, but the tree stands over it; a
    # pot centred on the base alone slid out from under a leaning crown.
    pot_x = (trunk_x(0) + crown_x) / 2
    xs = [crown_x + dx for dx, _, _, _ in foliage] or [crown_x]
    ys = [crown_y + dy for _, dy, _, _ in foliage] or [crown_y]
    left = min(min(xs), pot_x - pot_half - 1)
    right = max(max(xs), pot_x + pot_half + 1)

    width = int(right - left) + 6
    height = int(max(ys)) + 6
    # The column of x = 0, and the row of y = 0, which is the soil line. The
    # pot hangs below it, which is why the origin is not the last row.
    ox = int(-left) + 3
    oy = height - 4

    grid = [[None] * width for _ in range(height)]
    drawn = 0

    def place(x, y, char, kind, note=None, shade="mid"):
        nonlocal drawn
        col, row = round(x) + ox, oy - round(y)
        # Only the pot may be drawn below the soil line; nothing that grew may.
        floor = height - 1 if kind in ("pot", "soil") else oy
        if col < 0 or col >= width or row < 0 or row > floor:
            return False
        held = grid[row][col]
        # Foliage covers wood, the way a canopy covers the branch holding it
        # up. Refusing every overwrite - which is what the previous version did
        # - left a bare trunk running up through the middle of the crown with a
        # channel of sky either side of it. Nothing covers foliage, so no note
        # can ever hide another.
        if held is not None and not (kind == "leaf" and held.kind == "wood"):
            return False
        grid[row][col] = Cell(char, kind, note, shade, drawn)
        drawn += 1
        return True

    # ---- the wood ---------------------------------------------------------
    # Drawn before the foliage, so the structure is never buried by it. The
    # trunk tapers from three cells to one and carries a lit edge and a
    # shadowed edge, which is what reads as a cylinder rather than as a stroke.
    steps = max(10, int(trunk_h * 2.4))
    previous = None
    for step in range(steps + 1):
        t = step / steps
        y, x = t * trunk_h, trunk_x(t)
        dx = 0.0 if previous is None else x - previous
        previous = x
        thick = 3 if t < 0.16 else (2 if t < 0.55 else 1)
        for k in range(thick):
            off = k - (thick - 1) / 2
            if off < 0:
                char, shade = ("\\" if dx < -0.12 else "|"), "lit"
            elif off > 0:
                char, shade = ("/" if dx > 0.12 else "|"), "shade"
            else:
                if dx < -0.18:
                    char = "\\"
                elif dx > 0.18:
                    char = "/"
                else:
                    char = "|" if rng() > 0.3 else pick(TRUNK_CHARS)
                shade = "mid"
            place(x + off, y, char, "wood", shade=shade)

    # A branch out to each pad, so the wood visibly holds the foliage up
    # instead of the crown floating over a bare trunk. Most of each branch ends
    # up under the pad it carries; what shows is the length between the trunk
    # and the plate, which is the part that matters.
    for i, (px, py) in enumerate(centres):
        if i == pads - 1:
            continue
        side = 1 if px > crown_x else -1
        from_y = min(py, trunk_h * 0.92)
        from_x = trunk_x(from_y / trunk_h)
        to_x = px - side * 1.5
        run = max(2, int(abs(to_x - from_x)))
        for step in range(1, run + 1):
            u = step / run
            # A trained branch leaves the trunk level, dips, and lifts into its
            # pad. A straight line from trunk to pad reads as a spoke.
            x = from_x + (to_x - from_x) * u
            y = from_y + (py - 0.5 - from_y) * (u**1.3) - 0.6 * math.sin(u * math.pi)
            place(
                x,
                y,
                "_" if rng() > 0.5 else pick(BRANCH_CHARS),
                "wood",
                shade="lit" if side < 0 else "shade",
            )

    # ---- the foliage ------------------------------------------------------
    # One light source, from the upper left, read off the cell's place in the
    # CROWN rather than in its own pad. Per-pad shading was tried and gives
    # seven separately lit blobs; one source over the whole tree is what makes
    # the shading read as the form of a single mass.
    light_x, light_y = -0.5, 0.87
    on_tree = set()
    for dx, dy, _, _ in foliage:
        note = owner.get((dx, dy))
        if note is None:
            continue
        light = (dx / crown_w) * light_x + (dy / crown_h) * light_y + jit(0.30)
        shade = "lit" if light > 0.22 else ("shade" if light < -0.22 else "mid")
        char = pick(LEAF_CHARS[notes[note].stage])
        if place(crown_x + dx, crown_y + dy, char, "leaf", note, shade):
            on_tree.add(note)

    # Every note must be on the tree - that is the premise of the whole
    # feature, and a note whose cells all landed on occupied ground would be
    # one you can neither see nor point at. The search widens outward until it
    # finds room.
    for index in sorted(set(range(count)) - on_tree):
        char = pick(LEAF_CHARS[notes[index].stage])
        found = False
        px, py = centres[index % pads]
        for radius in range(1, max(width, height)):
            for dy in range(-radius, radius + 1):
                for dx in range(-radius * 2, radius * 2 + 1):
                    if place(px + dx, py + dy, char, "leaf", index):
                        found = True
                        break
                if found:
                    break
            if found:
                break

    # ---- the pot ----------------------------------------------------------
    # Nothing in it reports anything about a note - and neither did the row of
    # soil it replaces, which was already here on exactly that footing. It
    # earns its place for the same reason: this is a picture of a BONSAI, and a
    # tree without a pot is just a tree. It is the cheapest thing on the page
    # that makes the object read as the thing it is meant to be.
    #
    # Proportioned the way a bonsai pot is - about two thirds of the crown's
    # spread, and shallow. A pot as wide as the tree reads as a tub.
    for i in range(-pot_half, pot_half + 1):
        place(pot_x + i, 0, "." if i % 4 == 0 else "_", "soil")
    place(pot_x - pot_half - 1, 0, "\\", "pot")
    place(pot_x + pot_half + 1, 0, "/", "pot")
    inner = pot_half - 1
    for i in range(-inner, inner + 1):
        place(pot_x + i, -1, "_", "pot")
    place(pot_x - inner - 1, -1, "\\", "pot")
    place(pot_x + inner + 1, -1, "/", "pot")
    for sign in (-1, 1):
        place(pot_x + sign * (inner - 2), -2, "‾", "pot")

    # The assertion the plan asks for. A tree that quietly drops a note is
    # worse than no tree: the whole claim of this feature is that it is a
    # picture of the garden.
    carried = {c.note for row in grid for c in row if c is not None and c.note is not None}
    assert len(carried) == count, (
        f"bonsai lost {count - len(carried)} of {count} notes: "
        f"{sorted(set(range(count)) - carried)}"
    )

    return Tree(_crop(grid), pads, len(foliage))


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

    One `<span>` per drawn character, carrying four things: what it is made of
    and how the light falls on it (so the stylesheet can colour wood, soil, the
    pot and each topic, at three lightnesses), which note it grew from (so
    pointing at any cell of a clump can light the whole clump and name the
    note), and when it was drawn (so the growth animation can reveal the
    characters in the order the tree grew rather than wiping down the page).

    `leaf` is FIRST in the class list on purpose: checks/digital-garden.nix
    matches `<span class="leaf[^"]*" data-note=` to count the notes on the
    served tree, which is the gate on this feature's one real claim.

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
            classes = f"{cell.kind} sh-{cell.shade}"
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

    # The note's name on one line and its facts on the next, always - not one
    # run of text left to wrap where it fits. The caption is about as wide as
    # the tree, which is narrow enough that a run like "... Optimum - 623 /
    # words - sapling" breaks between a number and its unit, and a line that
    # breaks somewhere different for every note reads as a mistake each time.
    # Two lines is also exactly the room the stylesheet holds open for it.
    captions = []
    for index, note in enumerate(notes):
        topic = f" topic-{note.topic}" if note.topic else ""
        captions.append(
            f'<span data-note="{index}" data-url="{html.escape(note.url, quote=True)}">'
            f"<b>{html.escape(note.title)}</b>"
            f'<span class="bonsai-meta">{note.words:,} words &middot; '
            f'<span class="stage{topic}">{note.stage}</span></span></span>'
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


def render(notes, seed=DEFAULT_SEED):
    """Grow a tree from `notes` and return the markup for it."""
    return to_html(grow(notes, seed), notes)


# ---- running this file directly -----------------------------------------
#
# The plan calls the taste pass a session of its own, and says the only way to
# judge a tree is to generate many and look at them. That needs a loop that
# does not involve a vault, a build or a browser, which is all this is.


def _synthetic(count, seed):
    """A plausible garden of `count` notes.

    Word counts follow a long tail - most notes short, a few very long - which
    is the shape of the real vault and the shape that decides how the pads are
    dealt. These claim nothing about anyone's notes; they exist to answer "what
    does this look like at a hundred and twenty".
    """
    rng = mulberry32(seed + 9973)
    notes = []
    for i in range(count):
        words = math.floor(60 + rng() ** 2.2 * 3000 + 0.5)
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
    parser.add_argument("--notes", type=int, default=19, help="how many notes to grow")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument(
        "--seeds",
        type=int,
        default=0,
        help="draw this many seeds in a row, to judge consistency",
    )
    parser.add_argument(
        "--html", action="store_true", help="print the markup instead of the tree"
    )
    args = parser.parse_args(argv[1:])

    for seed in range(1, args.seeds + 1) if args.seeds else [args.seed]:
        notes = _synthetic(args.notes, seed)
        tree = grow(notes, seed)
        if args.html:
            print(to_html(tree, notes), end="")
            continue
        print(to_text(tree))
        print(
            f"\n{len(notes)} notes, {tree.pads} pads, {tree.leaves} leaf cells, "
            f"seed {seed}\n",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
