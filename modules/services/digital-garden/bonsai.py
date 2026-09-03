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
site hourly for no reason. That is a requirement to be a FUNCTION OF THE VAULT,
though, and it was met for a while by the weaker thing of being a constant - so
every build drew the same tree, and the garden could only widen it. The seed is
now a hash of the published set (`seed_from`), which satisfies the gate exactly
as a constant did and also makes the tree what it claims to be: write a note
and you get a different tree, not the old one with one more clump on it. Change
nothing and it is the same tree it was this morning, forever.

Hence also a PRNG written out here in full: `random` is deterministic for a
given CPython but is not promised to be stable across versions, and this has to
draw the same tree from the same vault in five years' time.
"""

import argparse
import collections
import hashlib
import html
import math
import sys

# One published note, as the tree needs to know it. `stage` is one of the three
# keys of LEAF_CHARS below, `topic` is a CSS-class-safe label or the empty
# string, and `hue` is the shelf's slot in the stylesheet's ring, as a string,
# or the empty string; publish-filter.py, which builds these, is what
# guarantees all three, so nothing here has to defend against a hand-written
# `maturity: mature`.
#
# `topic` and `hue` are both carried because they are two facts: the shelf's
# NAME, which is what the markup can be read against and is fixed by the vault,
# and its slot in the palette, which depends on what other shelves exist. Only
# the second one carries the colour.
#
# `revisions` and `published` come from the ledger and decide how far OUT on
# the tree a note sits - the most-worked notes low and close to the trunk, the
# least-worked out at the tips. See "who owns which cell" in `grow` for why
# revisions leads and the date only breaks its ties. Both default, because they
# are the only two fields a caller can sensibly not have: a tree grown from a
# hand-written list in a test is still a tree, it just has no inside.
Note = collections.namedtuple(
    "Note",
    "title url words stage topic hue revisions published",
    defaults=(0, ""),
)

# What `grow` falls back to when it is called without a seed. Nothing on the
# site takes it: `render` seeds every tree from the notes themselves, which is
# what makes the tree a picture of THIS vault rather than a fixed drawing (see
# `seed_from`). It is here so that `grow` can be called on its own - from a
# test, or from a session spent looking at trees - without inventing a number.
# Any value draws a tree, which is the point of the outline-first rewrite, so
# this is not load-bearing the way it was when only some seeds worked.
DEFAULT_SEED = 7

# A character cell is about this many times taller than it is wide, once the
# stylesheet's `line-height: 1.05` is applied. Anything meant to look round on
# screen has to be this much wider than it is tall in cells, and the number
# appears wherever a distance is compared across the two axes.
ASPECT = 1.9

# How much wider than tall the crown looks ON SCREEN. A bonsai's crown is a
# broad, shallow dome; a tall narrow one reads as a conifer.
#
# Raised from 1.6 by item 19's second pass, and the reason is the composition
# rather than the tree. At 1.6 the whole picture - crown, bare trunk and pot -
# came out 35x18 cells, which on screen is 1.11:1: a SQUARE. A square is the
# one shape that cannot be a masthead, and it was what forced the home page's
# header to put the name beside the tree rather than above it. The width has
# to come from somewhere, and taking it from the crown's proportion is free:
# a broader, shallower dome is what the line above already asks for. At 2.4
# today's vault draws 43x15 - 1.64:1, and three rows shorter - so the picture
# can fill the measure without pushing the prose off the screen.
#
# It also improves as the garden grows. The crown widens faster than it rises,
# so a two-hundred-note vault draws 78x27 rather than a taller and taller
# mass: the tree keeps roughly the height it has today and spends the extra
# foliage sideways, which is the axis the page has room on.
CANOPY_ASPECT = 2.4

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
# Pruning the crown's fringe: one pass per entry, removing every cell with
# fewer than that many orthogonal neighbours. Two passes at two, because
# removing a cell can orphan the one beside it.
#
# THE THIRD IDEA LEFT OPEN ON 2026-09-03 WAS TO RAISE ONE PASS TO THREE, and it
# is declined here on measurements rather than on taste, because the premise
# turned out not to hold. Counted over forty-eight trees at four vault sizes:
#
#   * 0.3% of crown cells have fewer than two orthogonal neighbours. There is
#     no dust to prune - these two passes already removed it.
#   * The crown's EDGE cells carry more ink than its interior, not less (2.41
#     against 2.33 on a three-point scale over the glyph sets), and fewer of
#     them come from the faint seedling set (14.5% against 18.7%). The fringe
#     is not fainter than the mass behind it.
#   * (2, 3) costs 14.5% of the canopy and takes specks from 0.3% UP to 2.1%,
#     because a pass at three removes cells with two neighbours and orphans
#     what was leaning on them, with no low pass left to clean up after it.
#   * (3, 2) - erode hard, then tidy - is the only ordering that improves on
#     today at all, and it buys 0.3% to 0.1% for 15.6% of the canopy. Rendered
#     at three seeds and three vault sizes, what that 15.6% costs is holes in
#     the crown's BODY and channels between the pads wide enough to come apart:
#     the silhouette this file exists to protect, eaten from the inside.
#
# On the real vault the numbers are the same shape: 0.4% specks on the tree
# this replaces, and 0.0% on the one it draws.
#
# AND THE FRINGE NOW MEANS SOMETHING, which is the argument that closes it.
# Dealing the notes inward-to-outward by revision count sorts the glyph sets
# along with them, because a note nobody has gone back to is usually a seedling
# and a seedling's set is the faintest. Measured on the vault: the crown used
# to carry the same weight of ink in its outer half as in its inner half (1.97
# against 1.97 on a three-point scale over the sets), and now carries 1.48
# outside against 2.18 inside. That gradient IS the wispy edge somebody looked
# at - and it is now the picture reporting that the tips are this year's
# growth, which is the whole of the idea above. Pruning it away would delete
# the signal the pass before it was added to carry.
#
# Left as a named constant because the idea is a natural one to have twice, and
# this is the cheapest possible way to try it again.
PRUNE = (2, 2)
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

# ---- the growth timeline ---------------------------------------------------
#
# Every cell carries WHEN it grew, as a number between 0 and 1, and the page
# reveals the tree in that order. This is the one thing on the tree that is not
# geometry, and it is worth stating why it is computed rather than counted.
#
# It used to be a counter bumped once per character placed, so the order the
# reader saw was the order this file happens to draw in - the whole trunk, then
# the crown scanned bottom-to-top like a raster, then the pot. Three of those
# four facts are wrong about a tree. The trunk arrived as one object because it
# is 50 cells out of 300 and the reveal was paced by COUNT; the foliage swept in
# rows because that is the order the crown's cells are enumerated in, not the
# order foliage opens in; and the pot came last, when a pot is the one thing on
# the picture that was there before the tree.
#
# So the times below are a botanical timeline instead. The pot is set down, the
# trunk rises out of it, each branch leaves the trunk AT THE MOMENT the trunk
# passes its height, and each pad opens outward from the branch that carries
# it. The lower pads are therefore in leaf while the apex is still rising,
# which is the thing that makes it read as growth rather than as a wipe.
#
# The numbers are a proportion of the whole animation and not seconds - how
# long the whole thing takes is the page's business, and baseof.html sets it -
# so what these fix is the SHAPE of the growth, which is the part this file
# knows about.
# The first cut of this timeline was right about the ORDER and wrong about the
# RATE, and the fade the page used to reveal it with was wide enough to hide
# the difference. Counted per twentieth of the animation, the tree arrived as a
# lump (fifty cells of pot and trunk base in the first tenth), then a stall of
# about a quarter of the whole run in which a one-cell-wide trunk was the only
# thing being drawn, then an avalanche - every pad opening at once, a third of
# the tree in a fifth of the time. That is not a rate a thing can be GENERATED
# at; it is a rate you can only get away with behind a wipe.
#
# The stall and the avalanche have one cause. A bonsai's trunk is bare low down
# - that is what `clear` is for - so every branch leaves the trunk in its upper
# half, and "a branch leaves at the moment the trunk passes its height" put all
# of them within a fifth of the run of each other. There is genuinely nothing to
# draw while the bare trunk rises, and then there is everything to draw at once.
#
# So the trunk is given a share of the clock in proportion to the wood it
# actually draws, and the crown is given a span of its own that the pads divide
# BY CELL COUNT - see `grow`. The causality survives as an ORDER rather than as
# an arrival time: a pad still cannot leaf before the branch carrying it has
# reached out, and the pads still leaf in the order the trunk reached them, so
# the lower crown is still in leaf while the apex is still rising. What changes
# is that the picture now arrives at a roughly even rate whatever the geometry
# happens to be, which is the property the page needs and the one thing the
# old constants could not promise from one vault size to the next.
# The pot is about fifty of three hundred cells, and at 0.09 it was set down at
# three times the rate the rest of the tree grows at - the front half of the
# lump the note above describes. It is still QUICKER than the tree, because it
# is placed rather than grown, but not by a factor you can see.
POT_SET = 0.18  # the pot and its soil, sweeping out from under the trunk
TRUNK_FROM, TRUNK_TO = 0.10, 0.34  # the trunk, rising base to apex
BRANCH_SPAN = 0.06  # a branch reaching out, once the trunk has passed it

# The crown's own span, which the pads divide between them in proportion to how
# many cells each carries - so a big pad gets more of the clock than a small one
# and both fill at the same rate. It opens BEFORE the trunk has topped out
# (TRUNK_TO above), because the lowest branch is reached long before the apex is
# and a crown that waits for the leader is a stage list rather than a tree.
CROWN_FROM, CROWN_TO = 0.24, 1.0

# How far a pad's opening runs past its own slot, as a multiple of it. At 1.0
# each pad finishes exactly as the next begins, and a hard handoff from one
# plate to the next is the stage list this file keeps trying not to be; the
# overlap is what keeps two or three pads always in motion.
PAD_OVERLAP = 2.2


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
        # When this cell grew, 0 at the start of the animation and 1 at the
        # end - see the growth timeline above. NOT the order it was drawn in:
        # the order this file draws in is chosen so that foliage can cover the
        # wood it hangs from, which is a fact about painting and not about
        # growing. `to_html` rescales these onto 0..1000 for the markup.
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
    # An empty garden, and not a hypothetical one: publish-filter.py writes the
    # tree unconditionally so that unpublishing everything leaves an empty
    # plate rather than last build's tree, which is exactly the path that
    # reaches this. Everything below divides by the crown's radius, and the
    # crown of a garden with nothing in it has a radius of zero - so this used
    # to take the whole build down with a ZeroDivisionError.
    if not count:
        return Tree([], 0, 0)

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
    for need in PRUNE:
        lonely = [
            at
            for at in kept
            if sum(
                ((at[0] + ddx, at[1] + ddy) in kept)
                for ddx, ddy in ((1, 0), (-1, 0), (0, 1), (0, -1))
            )
            < need
        ]
        for at in lonely:
            del kept[at]

    foliage = [(dx, dy, which, near) for (dx, dy), (which, near) in kept.items()]

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

    def place(x, y, char, kind, note=None, shade="mid", at=0.0):
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
        grid[row][col] = Cell(char, kind, note, shade, at)
        return True

    def trunk_time(y):
        """When the trunk's growing tip passes height `y`."""
        reached = max(0.0, min(1.0, y / trunk_h))
        return TRUNK_FROM + (TRUNK_TO - TRUNK_FROM) * reached

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
        # The soil row takes the FIRST step and no other. Steps are about
        # four tenths of a row apart, so two of them land on the ground, and
        # the second one carries the lean: on a trunk with any movement in it
        # the base came out four cells wide with a `\` or a `/` hanging off one
        # side, and the root flare below then met that slash point-to-point and
        # read as a notch cut into the trunk rather than as a foot. A trunk
        # does not lean where it enters the ground.
        if step and round(y) == 0:
            continue
        # THE TAPER IS ANCHORED TO THE CROWN, not to the trunk's total height.
        # At fixed fractions of `trunk_h` how much of the VISIBLE trunk was at
        # full width depended on how tall the tree happened to be, which is a
        # fact about the vault's size and not about the tree's proportions.
        # Three cells for the whole bare trunk, two through the crown's lower
        # half, one above: `clear` and `crown_y` are where those things
        # actually are.
        thick = 3 if y < clear else (2 if y < crown_y else 1)
        for k in range(thick):
            off = k - (thick - 1) / 2
            if off < 0:
                char, shade = ("\\" if dx < -0.12 else "|"), "lit"
            elif off > 0:
                char, shade = ("/" if dx > 0.12 else "|"), "shade"
            else:
                # THE MIDDLE COLUMN IS NEVER A SLASH, and this is the line that
                # fixed "the trunk is thin for a bonsai". It used to take the
                # lean's own diagonal, so a leaning trunk drew `\\\\|` - every
                # column the same stroke - and three cells of wood read as one
                # hatched line rather than as a column that has shifted. The
                # lean is already carried by the x position the whole group is
                # drawn at; the edges show it, and the core stays upright.
                #
                # Measured over twenty-four seeds at nineteen notes, because
                # the two halves of this fix look interchangeable and are not.
                # Anchoring the taper ALONE takes the bare trunk from 2.75
                # cells wide to 3.41 and from 43% upright DOWN to 36% - wider,
                # and more obviously a hatch, which is why the 2026-09-03
                # session found it "barely moved". The solid core alone leaves
                # it 2.75 wide at 53% upright. Together: 3.41 wide and 62%
                # upright, for no change to the picture's proportions at any
                # vault size.
                char = "|" if rng() > 0.3 else pick(TRUNK_CHARS)
                shade = "mid"
            place(x + off, y, char, "wood", shade=shade, at=trunk_time(y))

    # The nebari - the root flare where the trunk meets the soil. A bonsai is
    # judged on it before it is judged on anything else, and the reason is
    # visible at this resolution: a trunk that meets the soil as a straight
    # column of three cells reads as a pole stuck in a pot, and two cells of
    # spread either side is the whole difference between that and a tree that
    # is standing on something. `__/|||\__`, in wood rather than in the soil's
    # grey, so the roots and the ground they enter are two different things.
    #
    # First in time as well as lowest on the picture: a tree roots before it
    # rises, and starting the trunk's climb from a base that is already spread
    # is what stops the first frames looking like a line being drawn.
    #
    # Measured off the trunk that was actually drawn rather than off
    # `trunk_x(0)`, and that is not fussiness. A trunk with a lean puts two of
    # its steps on the soil row, so its base is three cells wide on one side
    # and four on the other, and a flare starting a fixed distance from the
    # centre line began INSIDE the wood on the leaning side - where `place`
    # refused it, leaving one shoulder flared and the other cut square. The
    # only reliable answer to "where does the wood end" is to look.
    # `or [ox]` so a trunk whose base fell off the canvas flares from the
    # origin instead of taking the build down on `min(())`. The canvas is sized
    # to hold the pot and the pot is always wider than the trunk's lean, so
    # this cannot happen today - but the empty-garden guard above was also a
    # thing that could not happen, and it was a ZeroDivisionError in the build.
    roots = [col for col, cell in enumerate(grid[oy]) if cell is not None] or [ox]
    for side, edge in ((-1, min(roots)), (1, max(roots))):
        # Not symmetric, and not seeded to be: a flare that matches itself
        # across the trunk reads as a drawn bracket. Each side gets its own
        # draw, the way each side of a real nebari got its own roots.
        for k in range(1, 2 + int(rng() * 3)):
            place(
                edge + side * k - ox,
                0,
                ("/" if side < 0 else "\\") if k == 1 else "_",
                "wood",
                shade="lit" if side < 0 else "shade",
                at=TRUNK_FROM * k / 4,
            )

    # A branch out to each pad, so the wood visibly holds the foliage up
    # instead of the crown floating over a bare trunk. Most of each branch ends
    # up under the pad it carries; what shows is the length between the trunk
    # and the plate, which is the part that matters.
    #
    # Each branch also records WHEN it finished and WHERE it ended, because
    # those two are what the foliage's timing hangs off: a pad opens from the
    # end of the branch carrying it, and it opens outward from that end.
    #
    # `reached_at` is when the branch is done and the pad COULD open; when it
    # actually opens is settled below, out of the crown's own span, because
    # every branch leaves this trunk within a fifth of the run of every other
    # one and a crown that opens on those times opens all at once.
    reached_at, pad_anchor = {}, {}
    for i, (px, py) in enumerate(centres):
        if i == pads - 1:
            # The apex pad sits on the trunk's own top, so it has no branch and
            # is ready the moment the trunk tops out. It is the last thing on
            # the tree to leaf, which is what a leader is.
            reached_at[i] = trunk_time(trunk_h)
            pad_anchor[i] = (trunk_x(1.0), trunk_h)
            continue
        side = 1 if px > crown_x else -1
        from_y = min(py, trunk_h * 0.92)
        from_x = trunk_x(from_y / trunk_h)
        to_x = px - side * 1.5
        run = max(2, int(abs(to_x - from_x)))
        leaves_at = trunk_time(from_y)
        # A long branch takes longer to reach out than a short one. Constant,
        # it was one more reason every pad on this tree became ready within a
        # fifth of the run of every other.
        reaching = BRANCH_SPAN * min(1.0, abs(to_x - from_x) / (crown_w or 1))
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
                at=leaves_at + reaching * u,
            )
        reached_at[i] = leaves_at + reaching
        pad_anchor[i] = (to_x, py - 0.5)

    # ---- when each pad leafs ----------------------------------------------
    # The pads leaf in the order the trunk reached them, and they divide the
    # crown's span BY CELL COUNT: a pad carrying eighty cells gets four times
    # the clock of one carrying twenty, so both fill at the same rate and the
    # whole crown fills at one rate. Sizing the slots by count rather than
    # handing every pad an equal share is the difference between an even rate
    # and a picture that stalls on the small plates and floods on the big ones.
    #
    # `max` against the branch's own arrival keeps the causality that matters:
    # a pad may be scheduled early, but it can never leaf before the wood
    # holding it up is there.
    pad_cells = collections.Counter(which for _, _, which, _ in foliage)
    crown_cells = sum(pad_cells.values()) or 1
    pad_ready, pad_span = {}, {}
    filled = 0
    for i in sorted(reached_at, key=lambda k: (reached_at[k], k)):
        share = pad_cells.get(i, 0) / crown_cells
        pad_ready[i] = max(
            reached_at[i], CROWN_FROM + (CROWN_TO - CROWN_FROM) * filled
        )
        # The overlap is what stops the crown reading as one plate at a time.
        pad_span[i] = (CROWN_TO - CROWN_FROM) * share * PAD_OVERLAP
        filled += share

    # ---- the foliage ------------------------------------------------------
    # One light source, from the upper left, read off the cell's place in the
    # CROWN rather than in its own pad. Per-pad shading was tried and gives
    # seven separately lit blobs; one source over the whole tree is what makes
    # the shading read as the form of a single mass.
    light_x, light_y = -0.5, 0.87

    # A pad opens OUTWARD from the branch that carries it, over the same span
    # whatever size it is - so a big pad opens faster per cell than a small
    # one, which is what makes the crown fill rather than creep. The distance
    # is normalised per pad for exactly that reason.
    def reach(which, dx, dy):
        ax, ay = pad_anchor[which]
        return math.hypot((crown_x + dx - ax) / ASPECT, crown_y + dy - ay)

    deepest = collections.defaultdict(float)
    for dx, dy, which, _ in foliage:
        deepest[which] = max(deepest[which], reach(which, dx, dy))

    # ---- who owns which cell ----------------------------------------------
    #
    # NEW GROWTH BELONGS AT THE TIPS. A note's place in the crown used to be
    # arbitrary: the pads were dealt by word count so the long notes did not
    # all land on one plate, and inside a pad each note took a seed point at an
    # angle off the centre, which is a spiral and means nothing. So the picture
    # reported the garden's size and its spread and nothing about its DEPTH -
    # you could not tell the note that has been rewritten nine times from the
    # one written once and left, and the vault records the difference.
    #
    # It does now, on the axis a tree already has. The most-worked notes sit
    # low and close to the trunk where the oldest wood is; the least-worked sit
    # out at the extremities where this year's growth is. Both halves of the
    # placement carry it - which pad a note lands on, and where in that pad -
    # because either alone is too coarse to read at three notes per plate.
    #
    # REVISIONS, not age, is the fact that decides it, and that is a choice
    # about this vault rather than about trees. The ledger's `published` is the
    # first day a note appeared in the published set, and for a vault whose
    # ledger was seeded in one afternoon that is one date for almost every
    # note - an axis with no spread to give. `revisions` is seeded from the
    # vault's own git history and spreads from nought to eight today. Age
    # breaks the ties, so the axis sharpens by itself as the garden ages and
    # notes stop sharing a birthday.
    #
    # Ranked rather than scaled. A rank uses the whole axis whatever the
    # distribution behind it looks like, so a garden where every note has been
    # revised twice still reads as a tree rather than as a ring, and the
    # picture says "this note is more worked over than that one", which is the
    # only claim the numbers can actually support.
    established = sorted(
        range(count),
        key=lambda i: (-notes[i].revisions, notes[i].published, i),
    )
    rank = {index: k for k, index in enumerate(established)}

    by_pad = collections.defaultdict(list)
    for cell in foliage:
        by_pad[cell[2]].append(cell)
    sizes = {i: len(v) for i, v in by_pad.items()}
    live = [i for i in sizes if sizes[i]]
    total_cells = sum(sizes.values())
    total_weight = sum(STAGE_WEIGHT[note.stage] for note in notes)

    # The pads in order of how far their own foliage sits from the FOOT OF THE
    # TRUNK, in screen proportions - which is the axis the sentence this item
    # comes from describes, measured on the picture the reader will actually
    # see rather than inferred from something upstream of it.
    #
    # Two other orderings were built and measured against that same distance,
    # because "close to the trunk" is easy to say and has three plausible
    # readings. Over forty-eight gardens - eight vault sizes, six gardens each,
    # ranked against where the foliage actually landed on the drawn grid:
    #
    #   by the branch's HEIGHT on the trunk          rho +0.57
    #   by path distance along the wood              rho +0.33
    #   by where the pad's own foliage ended up      rho +0.74
    #
    # Height loses because a low branch that reaches right across the crown
    # ends further out than a high one that barely leaves it. Path distance
    # loses by more, and for a subtler reason: it orders the plates by their
    # ANCHORS, and a pad is not where its branch stops - it is a mass of cells
    # spread around that point, which can sit mostly inboard of it.
    #
    # Ordering the plates by the thing being measured is not circular here. The
    # measurement is of the DRAWN grid, and this is a decision taken before
    # anything is drawn; it just turns out that the honest axis is the visible
    # one.
    from_root = collections.defaultdict(float)
    for dx, dy, which, _ in foliage:
        from_root[which] += math.hypot(
            (crown_x + dx - trunk_x(0)) / ASPECT, crown_y + dy
        )
    inward = sorted(live, key=lambda i: (from_root[i] / sizes[i], i))

    # Poured rather than packed. Each pad is filled to its share of the canopy
    # before the next one is started, so the notes come out in rank order along
    # `inward` and every pad still ends up carrying about as much foliage as it
    # has room for - the balance the old word-count deal existed to get, kept,
    # but now as a side effect of an order that means something.
    #
    # The old deal put the LONGEST note first and gave it the emptiest pad,
    # which balanced the plates perfectly and scattered the notes at random.
    # Balance was never the thing worth optimising: no reader can see that a
    # pad is carrying its fair share, and every reader can see that the tree
    # has an inside and an outside.
    buckets = collections.defaultdict(list)
    load = collections.defaultdict(float)
    at_pad = 0
    for dealt, index in enumerate(established):
        pad = inward[at_pad]
        buckets[pad].append(index)
        load[pad] += total_cells * STAGE_WEIGHT[notes[index].stage] / total_weight
        left = len(established) - dealt - 1
        ahead = len(inward) - at_pad - 1
        # Hand on once this pad has taken its share - and hand on early if the
        # notes still to deal have only just enough left to reach every pad
        # after it. A pad with no note is a pad whose cells nothing owns, and
        # an unowned cell is never drawn: a hole in the outline this whole file
        # exists to protect.
        if ahead and left and (load[pad] >= sizes[pad] or left <= ahead):
            at_pad += 1

    # A garden with fewer notes than pads leaves the outer pads with nothing to
    # carry. Their cells still have to belong to somebody, so they go to the
    # nearest pad that does have a note - a hole in the crown is a worse answer
    # than a slightly larger clump.
    for i in inward:
        if not buckets[i]:
            near = min(
                (j for j in inward if buckets[j]),
                key=lambda j: math.hypot(
                    (centres[i][0] - centres[j][0]) / ASPECT,
                    centres[i][1] - centres[j][1],
                ),
                default=None,
            )
            if near is not None:
                by_pad[near].extend(by_pad[i])
                by_pad[i] = []

    # Inside a pad, each note grows from a seed point of its own and takes the
    # cells nearest it. A note's cells have to be a CLUMP and not a sprinkle:
    # pointing at foliage lights the whole note and names it, and a note
    # scattered through a pad would be impossible to point at.
    #
    # The seed points are strung along the pad's OWN outward axis - from the
    # end of the branch carrying it, out to the pad's far edge - in rank order,
    # so the inner-to-outer reading survives at the scale of a single plate as
    # well as across the crown. That axis is `reach`, which the timeline above
    # already measures the pad's opening against, so a note's place in the pad
    # and the moment it leafs are the same fact told twice.
    #
    # The lateral offset is seeded and is not decoration: seeds strung along a
    # line with no spread give clumps that are bands across the pad, and a pad
    # striped in three colours reads as a chart of itself - the same fault that
    # ruled out grouping the pads by shelf.
    owner = {}
    for i in live:
        bucket = buckets.get(i)
        cells = by_pad[i]
        if not bucket or not cells:
            continue
        cells = sorted(cells, key=lambda c: c[3])
        px, py = centres[i]
        ax, ay = pad_anchor[i]
        span = deepest[i] or 1.0
        # The pad's outward direction, in screen proportions, so that "out" is
        # out to look at and not merely out in the grid.
        ox_, oy_ = (px - ax) / ASPECT, py - ay
        length = math.hypot(ox_, oy_) or 1.0
        ox_, oy_ = ox_ / length, oy_ / length
        bucket = sorted(bucket, key=lambda b: rank[b])
        weights = [STAGE_WEIGHT[notes[b].stage] for b in bucket]
        share = sum(weights)
        room = {
            b: max(1, round(len(cells) * w / share)) for b, w in zip(bucket, weights)
        }
        seeds = []
        for k, b in enumerate(bucket):
            out = span * (k + 0.5) / len(bucket)
            # Enough lateral spread that the clumps are not bands across the
            # pad, not so much that it swamps the outward order it is jittering.
            side = jit(0.22) * span
            seeds.append(
                (
                    ax + (ox_ * out - oy_ * side) * ASPECT,
                    ay + oy_ * out + ox_ * side,
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

    on_tree = set()
    for dx, dy, which, _ in foliage:
        note = owner.get((dx, dy))
        if note is None:
            continue
        light = (dx / crown_w) * light_x + (dy / crown_h) * light_y + jit(0.30)
        shade = "lit" if light > 0.22 else ("shade" if light < -0.22 else "mid")
        char = pick(LEAF_CHARS[notes[note].stage])
        # The jitter is what stops the opening edge being a clean arc sweeping
        # across the pad - the same reason the crown's outline is perturbed by
        # angle rather than left as an ellipse.
        opened = pad_ready[which] + pad_span[which] * (
            reach(which, dx, dy) / (deepest[which] or 1) + jit(0.07)
        )
        if place(crown_x + dx, crown_y + dy, char, "leaf", note, shade, at=opened):
            on_tree.add(note)

    # Every note must be on the tree - that is the premise of the whole
    # feature, and a note whose cells all landed on occupied ground would be
    # one you can neither see nor point at. The search widens outward until it
    # finds room.
    for index in sorted(set(range(count)) - on_tree):
        char = pick(LEAF_CHARS[notes[index].stage])
        found = False
        px, py = centres[index % pads]
        last = pad_ready[index % pads] + pad_span[index % pads]
        for radius in range(1, max(width, height)):
            for dy in range(-radius, radius + 1):
                for dx in range(-radius * 2, radius * 2 + 1):
                    if place(px + dx, py + dy, char, "leaf", index, at=last):
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
    #
    # FIRST in the growth timeline, and it is the correction that matters most
    # to how the picture reads: the pot used to be revealed last, so the tree
    # grew in mid-air and the thing it stands in arrived afterwards. A pot is
    # the one object here that was not grown. It is set down, from under the
    # trunk outward, and everything else happens in it.
    def set_down(i):
        return POT_SET * abs(i) / (pot_half + 1)

    for i in range(-pot_half, pot_half + 1):
        place(pot_x + i, 0, "." if i % 4 == 0 else "_", "soil", at=set_down(i))
    place(pot_x - pot_half - 1, 0, "\\", "pot", at=POT_SET)
    place(pot_x + pot_half + 1, 0, "/", "pot", at=POT_SET)
    inner = pot_half - 1
    for i in range(-inner, inner + 1):
        place(pot_x + i, -1, "_", "pot", at=set_down(i))
    place(pot_x - inner - 1, -1, "\\", "pot", at=POT_SET)
    place(pot_x + inner + 1, -1, "/", "pot", at=POT_SET)
    for sign in (-1, 1):
        place(pot_x + sign * (inner - 2), -2, "‾", "pot", at=POT_SET)

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


def to_rate(tree, buckets=20):
    """How many characters arrive per slice of the animation, as a bar chart.

    The taste-pass loop for the GROWTH, and it exists for the same reason
    `--seeds` does: the only way to judge a tree is to look at one, and the
    only way to judge how it grows is to look at its rate. A screenshot cannot
    show this and neither can reading the constants - the timeline's shape is
    an emergent property of the crown's geometry, and it changes whenever the
    geometry does.

    What it is FOR is catching the fault that produced it. The reveal used to
    arrive as a lump, then a stall of about a quarter of the whole run in which
    a one-cell-wide trunk was the only thing being drawn, then an avalanche as
    every pad opened at once. Behind a 0.35s fade that read as "smooth"; behind
    the snap the page uses now it would read as a stutter, a wait and a flash.
    An even bar chart here is what lets the page get away with hard-edged
    arrival, so this is the number to look at before changing anything in the
    growth timeline or in the crown's proportions.
    """
    times = sorted(c.grew for row in tree.rows for c in row if c is not None)
    if not times:
        return "an empty plate"
    lo, hi = times[0], times[-1]
    span = (hi - lo) or 1.0
    counts = collections.Counter(
        min(buckets - 1, int(buckets * (t - lo) / span)) for t in times
    )
    flat = len(times) / buckets
    lines = [f"{len(times)} cells; an even rate would be {flat:.1f} per slice"]
    for i in range(buckets):
        n = counts.get(i, 0)
        lines.append(f"{i * 100 // buckets:3d}% {n:5d} {'#' * n}")
    worst = min(counts.get(i, 0) for i in range(buckets))
    lines.append(f"thinnest slice {worst}, fullest {max(counts.values())}")
    return "\n".join(lines)


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
    # The growth times are rescaled onto whole numbers from 0 to 1000 here
    # rather than written out as the floats they are. Two reasons, and the
    # second is the real one: an integer is a third of the bytes, and there is
    # one of these per drawn character - but more importantly the page divides
    # by 1000 and gets a fraction of the animation, so how long the tree takes
    # to grow is a decision baseof.html makes and this file cannot accidentally
    # take. Rescaled from the tree's OWN first and last cell, so every tree
    # starts at 0 and finishes at 1000 whatever the timeline's constants add up
    # to for its particular geometry.
    times = [c.grew for row in tree.rows for c in row if c is not None]
    first, last = (min(times), max(times)) if times else (0.0, 1.0)
    span = (last - first) or 1.0

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
                note = notes[cell.note]
                if note.topic:
                    classes += f" topic-{note.topic}"
                if note.hue:
                    classes += f" hue-{note.hue}"
            note_attr = "" if cell.note is None else f' data-note="{cell.note}"'
            grew = round(1000 * (cell.grew - first) / span)
            out.append(
                f'<span class="{classes}"{note_attr} data-grow="{grew}">'
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
        topic += f" hue-{note.hue}" if note.hue else ""
        captions.append(
            f'<span data-note="{index}" data-url="{html.escape(note.url, quote=True)}">'
            f"<b>{html.escape(note.title)}</b>"
            f'<span class="bonsai-meta">{note.words:,} words &middot; '
            f'<span class="stage{topic}">{note.stage}</span></span></span>'
        )

    # The stylesheet sizes the tree from the width of the column it is in -
    # `font-size: 100cqi / (cols * advance)` - so that the picture's right
    # edge and the header's right edge are the same line at every viewport
    # and for every vault. It cannot count the columns itself: `pre` is
    # `max-content` wide precisely so the type decides the box, and asking the
    # box how wide the type is would be the circle that sizing is there to
    # break. Only the generator knows, so the generator says.
    #
    # The grid is rectangular after `_crop`, so any row's length is the
    # width; `lines` are right-stripped and are not.
    cols = len(tree.rows[0]) if tree.rows else 0

    return (
        '<div class="bonsai-plate">\n'
        f'<pre class="bonsai" aria-hidden="true" style="--cols: {cols}">'
        + "\n".join(lines)
        + "</pre>\n"
        + '<p class="bonsai-caption" aria-hidden="true"></p>\n'
        + '<div class="bonsai-notes" hidden>'
        + "".join(captions)
        + "</div>\n</div>\n"
    )


def seed_from(notes):
    """The seed a given set of notes draws itself with.

    The tree used to be drawn from a fixed constant, so it was the same tree on
    every build: the garden's SIZE moved it - a new note widened the crown and
    took a share of the canopy - but its silhouette, its trunk's curve and its
    pads were nailed down. That was the wrong reading of a real constraint. The
    constraint is that the same vault must draw the same tree, because the
    builder skips a rebuild when the staging tree hashes the same as last time
    (see digital-garden.nix) and a tree that reseeded itself every hour would
    rewrite the site for nothing. A constant satisfies that. So does a hash of
    the garden, and a hash also does the thing the constant could not: it makes
    the tree a FINGERPRINT of the vault rather than a fixed picture that a
    counter happens to be pointed at.

    So: write a note, and the tree you get is a different tree - a new trunk,
    new lobes on the crown, new pads - not the old one with one more clump on
    it. Change nothing, and it is the same tree it was this morning, forever.

    Every field the tree can draw is in the hash, WORD COUNTS INCLUDED, which
    is the one debatable line here: it means fixing a typo redraws the whole
    tree. That is the intended reading of "a picture of the garden as it is" -
    the picture is of this vault at this moment, and this vault is not the one
    that had the typo. Dropping `words` from the fields below is the whole
    change if that ever grates.

    blake2b rather than `hash()`, which is salted per process for strings and
    would draw a different tree on every build of the same vault - the exact
    failure this function exists to avoid.
    """
    fields = "\n".join(
        f"{n.title}\x1f{n.url}\x1f{n.words}\x1f{n.stage}\x1f{n.topic}\x1f{n.hue}"
        f"\x1f{n.revisions}\x1f{n.published}"
        for n in notes
    )
    digest = hashlib.blake2b(fields.encode("utf-8"), digest_size=4).digest()
    return int.from_bytes(digest, "big")


def render(notes, seed=None):
    """Grow a tree from `notes` and return the markup for it.

    With no seed, the notes seed themselves - see `seed_from`. A seed is still
    accepted so that a particular tree can be pinned or replayed, which is what
    `--seed` on the command line is for.
    """
    if seed is None:
        seed = seed_from(notes)
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
        shelf, hue = ("slip-box", "2") if rng() > 0.28 else ("lighting", "5")
        # A long tail again, and for the same reason: most notes are written
        # once and left, a few are worked over repeatedly, and the shape of
        # that tail is what the inner-to-outer axis has to read against. The
        # dates spread over a year so that the tie-break has something to do,
        # which the real vault's ledger cannot offer it yet.
        revisions = math.floor(rng() ** 2.6 * 10)
        published = f"2026-{1 + math.floor(rng() * 12):02d}-{1 + math.floor(rng() * 28):02d}"
        notes.append(
            Note(
                f"Note {i + 1}",
                f"/note-{i + 1}/",
                words,
                stage,
                shelf,
                hue,
                revisions,
                published,
            )
        )
    return notes


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--notes", type=int, default=19, help="how many notes to grow")
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="pin the tree to one seed. Without it the notes seed themselves, "
        "which is what the site does",
    )
    parser.add_argument(
        "--seeds",
        type=int,
        default=0,
        help="draw this many seeds in a row, to judge consistency",
    )
    parser.add_argument(
        "--html", action="store_true", help="print the markup instead of the tree"
    )
    parser.add_argument(
        "--rate",
        action="store_true",
        help="print how many characters arrive per twentieth of the animation, "
        "which is the shape the page reveals the tree at",
    )
    args = parser.parse_args(argv[1:])

    # `--seeds` varies the GARDEN and lets each one seed itself, which is the
    # loop the taste pass wants: what varies on the site is the vault, and a
    # run that held the notes still and turned the seed would be judging trees
    # the site can never draw.
    for vault in range(1, args.seeds + 1) if args.seeds else [args.seed or 0]:
        notes = _synthetic(args.notes, vault)
        seed = args.seed if args.seed is not None else seed_from(notes)
        tree = grow(notes, seed)
        if args.rate:
            print(to_rate(tree))
            continue
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
