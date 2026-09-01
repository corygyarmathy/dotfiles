#!/usr/bin/env python3
"""Copy ONLY notes marked `publish: true` out of the vault into a staging tree.

This is the security boundary for the digital garden, and it is deliberately
placed *before* the site generator rather than inside it. A generator that can
filter on `publish` itself puts the safety property at the mercy of a config
option, which can ship disabled, be mistyped, or be dropped by an upgrade
without anything failing. Here, an unmarked note is never copied, so it cannot
be rendered, indexed, linked, or served no matter what the generator is told to
do — or which generator it is.

The builder re-checks the marker on the staging tree before rendering, and
refuses to build if one is missing; see digital-garden.nix. That is the second
layer, and it is deliberately not in this file: a check inside the thing being
checked is worth less.

Fail-closed rules, in order of importance:
  * publish defaults to false. Only a real YAML boolean true publishes.
  * Any note that fails to parse is skipped, never published.
  * The rewritten frontmatter is re-checked against the same strict pattern
    before it is written, so a note can only leave here still marked.
  * Wikilinks that point at unpublished notes are flattened to plain text, so
    the garden contains no links to pages that do not exist.
  * Only attachments actually embedded by a published note are copied.
  * The staging tree is built fresh and swapped in, so a removed `publish: true`
    always disappears from the next build.

Nothing Obsidian-specific reaches the generator except two things Hugo's own
parser understands, chosen so any CommonMark renderer degrades them
gracefully: callouts (> [!type], a blockquote either way) and $...$ maths
(captured by the passthrough extension). Everything else is rewritten here.
Wikilinks become ordinary Markdown links and embeds become ordinary images,
so the staging tree's links already carry the finished URL. That is what
keeps the generator replaceable: it is handed files already named what they
will be served as, pointing at each other by those names, so swapping one
generator for another cannot silently move a page. See `slugify`.

Obsidian's internal-only syntax is stripped rather than rendered: %% comments
and ^block identifiers never leave the vault. A link to a block
([[Note#^id]]) drops its fragment, because the id it names does not survive;
a link to a heading in the same note ([[#Heading]]) is rewritten to an
ordinary fragment link. See OBSIDIAN_INTERNAL and `rewrite`.

Published notes are FLATTENED to the root of the staging tree, so the site's
URLs are `/some-essay/` rather than `/whatever-folder/some-essay/`. The vault's
folder names are private working vocabulary, and reorganising the vault must
not break a published URL. A note that moves keeps its address; a note's old
address keeps working via an injected `aliases:` entry, which the generator
turns into a redirect page. That entry is slugified segment by segment, because
the address being kept alive is the one that was *served*, not the vault path
it was derived from — `essays/On Boundaries.md` was reachable at
`/essays/on-boundaries/`, and an alias naming the raw path publishes a URL with
a space in it while leaving the real old address a 404.

Links carry a trailing slash, which is the form the generator itself publishes
in `rel=canonical`, the sitemap, the feed and the search index. Both forms are
served directly, so this is not about reachability: it is so that one page is
one string everywhere it is written down.

Flattening makes filenames the global namespace, which the link rewriter below
already assumed (it resolves wikilinks by stem). Two published notes sharing a
URL is therefore a hard error rather than a silent drop — and the check is on
the URL, not the filename, because "Some Note" and "some-note" are two files
and one page.

Dates are derived, not written by hand. `<ledger>` records the first time each
note appeared in the published set and the last time its text changed, and
those are injected as `published:`/`modified:` frontmatter for the
generator to render. Frontmatter written by hand always wins, so the ledger is a default and
not an authority — which also means losing the ledger costs you nothing that
matters.

Maturity is derived the same way. The ledger also counts substantial rewrites
(`revisions`), seeded from the vault's git history the first time a note is
seen (`git log --follow`, counting commits whose diff to the note exceeded
fifteen lines) and bumped whenever the note's hash changes; where there is no
repository, the counter simply starts at zero. Each note is then given a
`maturity_score` — a weighted sum of length, backlinks, forward links, `##`
sections and revisions, in one table in one file so the weights can be tuned —
and a `maturity:` stage cut from it (seedling below 1.5, sapling to 5.0,
evergreen from there). A hand-written `maturity:` in the note wins over the
computed stage, exactly as a hand-written `published:` already beats the
ledger; `maturity_score` is always the computed number, for debugging and for
the margin that will show it.

The margin (item 17 of the design plan) is fed here too, because it is the
same parsing the maturity model already does. Every note is given a
`word_count`, a `reading_time` (both from the body the filter actually emits),
and a `sections` list — one entry per `##`, carrying the heading's `id` (the
`anchorize` rule, which agrees with Hugo's ids for the headings Obsidian
produces), its title, and the words under it down to the next `##`. Hugo's
`.Fragments.Headings` knows the heading tree but not how much text sits under
each heading, and this is the only place that knows the word counts.

`thesis:` is the note's claim in one sentence. It becomes the page description
and the RSS item's summary, and it is appended to any list item elsewhere that
is nothing but a link to the note — so an index or hub page reads as claims,
while each claim lives in exactly one place: the essay making it. It is
optional; a note without one is reported, not withheld. Notes past
LONG_NOTE_WORDS are reported on the same terms.

A leading H1 is lifted out of the body and becomes the title. The page template
renders a title of its own, so a note written the ordinary way would otherwise
show it twice.

Backlinks are derived here rather than in the generator, for the same reason
the URLs are: this is the only place that knows the link graph. By the time the
generator sees a page, a link is an opaque href; here it is still a wikilink
resolved against the published set. That also makes the safety property free
rather than argued - a backlink source can only be a note already in
`published`, so an unpublished note cannot appear as one, and the publish
boundary needs no second look.

The home page is excluded as a SOURCE. It is a table of contents that links to
everything, so counting it would give every note the same backlink and tell a
reader nothing they did not get by arriving from it.

Usage: publish-filter.py <vault> <staging> <ledger>
"""

import hashlib
import json
import re
import shutil
import subprocess
import sys
import unicodedata
from datetime import date
from pathlib import Path

import yaml

# The bonsai (docs/plans/digital-garden-design.md, item 18): the tree on the
# landing page, whose every foliage pad is one published note. It lives beside
# this file rather than inside it because it is a page of arithmetic that has
# nothing to do with filtering, and because it can then be run on its own to
# look at trees - which is the only way the plan's taste pass can work. This
# filter is what calls it, because this is the only thing that knows the
# published set. See bonsai.py.
import bonsai

# The libyaml-backed loader when it is available, the pure-Python one otherwise.
# Both implement the SafeLoader schema, so this is a speed choice with no
# semantic difference - the filter must not get faster at the cost of reading a
# different YAML than before.
try:
    from yaml import CSafeLoader as SafeLoader
except ImportError:  # pragma: no cover
    from yaml import SafeLoader

FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
# (?!\() rejects [[1]](url) — pasted Wikipedia prose is full of these.
# The target may be empty, which is Obsidian's same-note link: [[#Heading]].
LINK = re.compile(r"(!?)\[\[([^\]|#]*)(#[^\]|]*)?(?:\|([^\]]*))?\]\](?!\()")
# deliberately not a YAML parser: we accept exactly one literal spelling
PUBLISH_TRUE = re.compile(r"^publish:\s*true\s*(?:#.*)?$", re.M | re.I)
# Obsidian's internal annotations, matched in one alternation so that code
# wins over everything: a fenced block or an inline span is kept whole, while
# a %% comment or a trailing ^block-id is dropped. The comment pattern needs
# its closing %% — an unclosed marker is left alone, because Obsidian's
# comment-to-end-of-file rule would let one stray keystroke delete half a
# published note. Fences are backtick-only; tilde fences are rare enough that
# treating their contents as prose is the acceptable failure.
OBSIDIAN_INTERNAL = re.compile(
    r"(^`{3,}[^\n]*\n.*?^`{3,}[ \t]*$)"  # fenced code block — kept
    r"|(`+[^`\n]*`+)"  # inline code span — kept
    r"|%%.*?%%"  # comment — dropped
    r"| ?\^[A-Za-z0-9-]+[ \t]*$",  # block identifier — dropped
    re.M | re.S,
)
# The first thing in the body, if it is an ATX H1. Setext underlining is not
# matched: Obsidian does not produce it and guessing costs more than it saves.
LEADING_H1 = re.compile(r"\A\s*#[ \t]+(.+?)[ \t]*\n+")
# A list item that is nothing but a link to another published note — the shape
# an index or hub entry takes before its thesis is filled in. Matched after the
# wikilinks have already become Markdown links, so there is one link syntax to
# recognise here rather than two. The trailing slash is captured OUTSIDE the
# slug so that the lookup key matches the one `theses` is built with.
BARE_LINK_ITEM = re.compile(
    r"^([ \t]*[-*+][ \t]+)\[([^\]]*)\]\(/([^)#/]*)/?[^)]*\)[ \t]*$", re.M
)
# Unreserved URL characters (RFC 3986). Anything else is dropped rather than
# percent-escaped: an escape in a path is not something anyone wants to read,
# type, or see in a browser's address bar.
SLUG_DROP = re.compile(r"[^a-z0-9._~-]")
# Anything that is not a letter or a digit, for the topic label. A separate
# rule from SLUG_DROP on purpose - see `note_topic` for why an address and a
# label are not the same string.
TOPIC_DROP = re.compile(r"[^a-z0-9]+")
# How many hues the stylesheet's `.hue-*` ring has. Kanagawa offers about this
# many that hold up as text on both grounds, which is why the ring is this long
# and not longer - see `assign_topic_hues`, and the `--hue-*` block in main.css
# where the eight are declared. The two have to agree about this number.
TOPIC_HUES = 8
# Runs of two or more hyphens, which Goldmark's typographer turns into dashes
# before a heading id is computed. See `anchorize`.
DASH_RUN = re.compile(r"-{2,}")
# `_emphasis_`, but not the underscore inside `under_score`. CommonMark refuses
# to open or close emphasis on an underscore flanked by alphanumerics, which is
# exactly the distinction here: [^\W_] is "alphanumeric", spelt so that the
# underscore itself does not count as one.
UNDERSCORE_EMPHASIS = re.compile(r"(?<![^\W_])_([^_]+)_(?![^\W_])")
# Not a limit, just the point past which a note is worth another look.
LONG_NOTE_WORDS = 500
# Where embedded files are staged, and the first segment of their URL.
ATTACHMENTS = "attachments"
# The one file in the staging tree that is not a note and not an attachment:
# the bonsai's markup. lib/hugo.nix moves it out of the content tree by this
# name before Hugo runs, so the two files agree on it and nothing else does.
BONSAI = "bonsai.html"
ATTACHMENT_SUFFIXES = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".svg",
    ".avif",
    ".pdf",
    ".mp4",
    ".webm",
    ".mp3",
    ".ogg",
    ".wav",
}
# A level-2 ATX heading: `##` NOT followed by a third `#`, so `###` does not
# count. The maturity model and the rail both care about `##` only - a `###`
# is a subsection, not a section.
H2_HEADING = re.compile(r"^##(?!#)[ \t]+", re.M)
# The maturity model, in one place so the weights are one edit. These are the
# numbers the 2026-08-31 prototypes were tuned to; they are a starting point,
# not a finding (see docs/plans/digital-garden-design.md, item 14). The stage
# cuts: seedling below MATURITY_SAPLING, sapling up to MATURITY_EVERGREEN.
MATURITY_SAPLING = 1.5
MATURITY_EVERGREEN = 5.0
# The length term saturates at this many words. A linear length term let two
# long unrevised notes outrank a short careful one, which is the failure that
# started the model: past the saturation point, longer stops being evidence of
# anything.
MATURITY_LENGTH_SATURATION = 800
# A commit counts as a substantial rewrite only when its diff to the note
# exceeds this many lines (added + deleted).
REWRITE_LINES = 15


def slugify(name):
    """The URL path a note or attachment is published at.

    Lowercase, spaces to hyphens, nothing else touched. That is not an
    aesthetic choice: it reproduces character for character what the site's
    original generator did to filenames, because those URLs were already live
    when this moved here and must not move again. Runs of hyphens are NOT
    collapsed, so "A - B" stays "a---b" exactly as it is served today.

    Owning this here rather than leaving it to the generator is the point: it
    makes the URL a property of the staging tree instead of a behaviour of
    whatever renders it.
    """
    return SLUG_DROP.sub("", name.lower().replace(" ", "-"))


def note_topic(rel):
    """Which shelf a note came from: the folder it sits in, slugified.

    The published tree is flat, so the vault's folders are the one fact about a
    note that publishing otherwise throws away - and they are exactly the fact
    a reader would call its topic. `_Slip_Box/Getting Good.md` is `slip-box`;
    `_Reference/Lighting/Effective Lighting.md` is `lighting`, because the
    shelf is Lighting and not Reference. A note at the vault root has no shelf
    and gets no topic, which is the honest answer rather than a made-up one.

    Emitted as frontmatter as well as handed to the bonsai, so that the value
    the tree colours a pad with is inspectable in the staging tree next to
    everything else the filter decided. Item 15 of the design plan is the other
    consumer, and this is the only place the two items touch.

    Deliberately NOT `slugify`. That function reproduces the URLs this site
    was already serving and must keep serving, so it preserves `_` and `~` and
    never collapses a run of hyphens; a topic is a label and a CSS class rather
    than an address, and `_Slip_Box` should read as `slip-box` and not as
    `_slip_box`. Two rules because there are two jobs, not because one of them
    is wrong.
    """
    if rel.parent == Path("."):
        return ""
    return TOPIC_DROP.sub("-", rel.parent.name.lower()).strip("-")


def assign_topic_hues(topics):
    """Which slot in the stylesheet's hue ring each shelf takes.

    The two shelves this vault publishes from used to be two hand-written
    rules in main.css, and every other folder fell through to `--muted`. That
    made "publish from a new folder" a code change, which is the wrong shape
    for a fact the filter already knows: the shelves are whatever the vault
    happens to contain this morning.

    The slot comes from a HASH OF THE SHELF'S OWN NAME rather than from its
    position in a sorted list, and that is the whole design. Handing hues out
    in name order is simpler and has no collisions, but it makes every shelf's
    colour a function of every OTHER shelf: publishing a folder called
    `essays` would renumber everything after it, and a reader who has learned
    that orange means lighting would find it means something else. Hashed, a
    shelf's hue is fixed by its name and by nothing else, so it survives every
    future folder.

    Collisions are the price. Two names can want the same slot, and then the
    second one to be reached takes the next free slot going up the ring - so
    the one case where publishing a new shelf can recolour an existing one is
    when the new name both collides with it and sorts before it. With eight
    slots that is uncommon and it is bounded; the alternative, two shelves
    drawn in one hue forever, is worse and is not bounded. Past eight shelves
    every slot is taken and hues are shared, which is the honest thing for a
    ring of eight to do.
    """
    used = {}
    for topic in sorted(topics):
        want = hashlib.sha256(topic.encode("utf-8")).digest()[0] % TOPIC_HUES
        for step in range(TOPIC_HUES):
            slot = (want + step) % TOPIC_HUES
            if slot not in used.values():
                break
        else:
            slot = want
        used[topic] = slot
    return used


def resolve_title(front, body, rel):
    """The title a note is published under.

    Frontmatter wins, then a leading H1, then the filename. Computed before
    anything is written because backlinks need every note's title while the
    first note is still being rendered - and having one definition of this is
    worth more than the pass it saves.

    Wikilinks in a title are flattened to their own text. A title is prose, not
    a place to put a link, and the alternative is a Markdown link embedded in a
    <title> tag and an og:title.
    """
    if front.get("title"):
        return str(front["title"])
    heading = LEADING_H1.match(body)
    if heading:
        return LINK.sub(lambda m: m.group(4) or m.group(2), heading.group(1)).strip()
    return rel.stem


def anchorize(text):
    """The id the generator gives a heading, for `[[Note#Some Heading]]`.

    Deliberately NOT `slugify`. The two rules genuinely differ, and the reason
    is that they answer to different authorities: a note's URL is ours to
    define, and a heading's id is Hugo's, because Hugo is what writes it into
    the page. A fragment we compute by our own rule points at nothing.

    They agree on the headings people usually write and diverge on punctuation,
    which is what made this worth fixing rather than documenting: `slugify`
    keeps `.` `_` `~` and preserves runs of hyphens, so "A Section, With
    Punctuation" came out `a-section--with-punctuation` against Hugo's
    `a-section-with-punctuation`, and the link landed nowhere.

    Reproduces Hugo's `github` autoHeadingIDType, derived by rendering a corpus
    of adversarial headings through the pinned Hugo and reading back the ids
    rather than from anyone's memory of the algorithm:

      * a Unicode letter or decimal digit is kept, lowercased - so `Über
        Straße` keeps its accents and `日本語` survives intact;
      * a space or a hyphen becomes a hyphen, and runs are NOT collapsed:
        "a  b" is `a--b`;
      * an underscore is kept, which is why `under_score` is not `underscore`;
      * everything else is dropped.

    Duplicate headings get `-1`, `-2` from Hugo. Not reproduced, and not a gap:
    a wikilink naming a heading by text means the first one, which is the id
    with no suffix.

    Inline markup in the heading is handled where it can occur. Asterisks and
    backticks need no special case - they are dropped as punctuation, which
    leaves `**bold**` and `` `code` `` reading correctly by themselves. Only the
    underscore needs a rule, because it is the one marker this function would
    otherwise KEEP. A Markdown link needs none either: `[[Note#a [b](c)]]` does
    not parse as a wikilink at all, because the syntax forbids `]` inside, so
    that heading is unreachable from a fragment by construction.

    Verified against Hugo itself rather than against this description: a corpus
    of adversarial headings is rendered by the pinned Hugo and the ids read
    back, and every case that a fragment can express agrees.
    """
    # Goldmark's typographer runs before ids are computed, and it is the one
    # thing that changes a character this rule would otherwise KEEP. `---` is
    # an em dash and `--` an en dash, both punctuation and both dropped, while
    # a lone hyphen stays a hyphen - so `co-operative` keeps its hyphen and
    # `a --- b` does not. Longest first, which is why four hyphens leave one
    # behind (em + hyphen) and five leave none (em + en).
    text = DASH_RUN.sub(lambda m: "-" if len(m.group(0)) % 3 == 1 else "", text.strip())
    text = UNDERSCORE_EMPHASIS.sub(r"\1", text)
    out = []
    for ch in text:
        category = unicodedata.category(ch)
        if category[0] == "L" or category == "Nd":
            out.append(ch.lower())
        elif ch in "- ":
            out.append("-")
        elif ch == "_":
            out.append("_")
    return "".join(out)


def is_published(text):
    m = FRONTMATTER.match(text)
    return bool(m) and bool(PUBLISH_TRUE.search(m.group(1)))


def split_frontmatter(text):
    """(mapping, body) for a note, or None if the frontmatter is not usable.

    Returning None is a decision not to publish: a note whose frontmatter does
    not round-trip is one whose `publish:` marker we cannot reason about.
    """
    m = FRONTMATTER.match(text)
    if not m:
        return None
    try:
        front = yaml.load(m.group(1), Loader=SafeLoader)
    except yaml.YAMLError:
        return None
    if not isinstance(front, dict):
        return None
    return front, text[m.end() :]


def coalesce_aliases(front):
    """Obsidian accepts `alias` and `aliases`, scalar or list. Normalise both."""
    out = []
    for key in ("aliases", "alias"):
        value = front.get(key)
        if isinstance(value, str):
            value = [value]
        if isinstance(value, list):
            out += [str(v) for v in value]
    return out


def git_revisions(vault, rel):
    """Count substantial rewrites of a note from its git history, or 0.

    The seed for the ledger's revision counter. A commit counts when the note's
    own diff in it exceeds REWRITE_LINES lines (added + deleted), which is the
    line that separates a rewrite from a touch-up. `--follow` survives renames,
    the same property `carry_renames` gets from the content hash, so the count
    is stable under the renames that would otherwise reset it.

    Returns 0 rather than raising when there is no history to count in: the
    vault may be an obsidian-sync mirror with no `.git` directory, or git may
    not be on PATH (the preview without this package in its runtime inputs).
    The counter then accrues from first deploy, which is a worse signal but
    not a broken one.
    """
    if shutil.which("git") is None or not (vault / ".git").exists():
        return 0
    try:
        out = subprocess.run(
            [
                "git",
                "-C",
                str(vault),
                "log",
                "--follow",
                "--numstat",
                "--format=",
                "--",
                rel.as_posix(),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 0
    if out.returncode != 0:
        return 0
    rewrites = 0
    for line in out.stdout.splitlines():
        added, sep, rest = line.partition("\t")
        deleted, _, _ = rest.partition("\t")
        # `--numstat` writes `-\t-` for a binary file; skipping those is the
        # same decision as not counting them.
        if sep and added.isdigit() and deleted.isdigit():
            if int(added) + int(deleted) > REWRITE_LINES:
                rewrites += 1
    return rewrites


def maturity_score(words, backlinks, forward, sections, revisions):
    """The number behind the maturity stage, as the plan lists its parts.

    Components, with the weights the prototypes were tuned to:

      length:    min(words / 800, 1) * 2  - saturating, not linear
      backlinks: 1.2 each                 - the only signal from outside
      forward:   0.5 each                 - resolved against the published set
      sections:  +1 if the note has >= 3 `##`s - structured, not dumped
      rewrites:  min(n, 4) * 0.35         - substantial commits

    Rounded to three decimals so a computed score is stable in the emitted
    frontmatter - a raw float sum can carry binary noise out to a sixteenth
    decimal, which is a debugging number nobody asked to read.

    The weights are all here, in one table in one file, so tuning them is one
    edit and one commit. 800 is the number most worth revisiting once the vault
    has grown.
    """
    score = min(words / MATURITY_LENGTH_SATURATION, 1.0) * 2
    score += 1.2 * backlinks
    score += 0.5 * forward
    if sections >= 3:
        score += 1
    score += min(revisions, 4) * 0.35
    return round(score, 3)


def maturity_stage(score):
    """seedling below 1.5, sapling from 1.5, evergreen at 5.0."""
    if score >= MATURITY_EVERGREEN:
        return "evergreen"
    if score >= MATURITY_SAPLING:
        return "sapling"
    return "seedling"


def section_weights(body):
    """One (id, title, words) per `##` section, for the margin's scale map.

    A section runs from its `##` heading to the next one (or the end of the
    note), `###` subsections and their text included — a subsection belongs to
    the section it sits under. The id is `anchorize`'d, the same rule the
    wikilink rewriter already uses for heading fragments, so the margin's
    href="#id" lands on the id Hugo actually emits. Duplicate headings get no
    suffix here, the same caveat `anchorize` records for wikilinks: a section
    title used twice in one note makes both blocks point at the first, which
    is a writing problem rather than a rendering one. This is the part of the
    margin that cannot be priced from the templates: Hugo's
    `.Fragments.Headings` gives the tree without the words, and only the
    filter has the body.
    """
    matches = list(H2_HEADING.finditer(body))
    out = []
    for i, match in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(body)
        line_end = body.find("\n", match.end())
        if line_end == -1:
            line_end = len(body)
        title = body[match.end() : line_end].strip()
        out.append(
            {
                "id": anchorize(title),
                "title": title,
                "words": len(body[match.end() : end].split()),
            }
        )
    return out


def carry_renames(ledger, published):
    """Move a ledger entry across a rename, keyed by content hash.

    The ledger is keyed by the note's filename (see `update_ledger`), so a
    renamed note looks like a new one: its entry is never found, and
    `published` silently resets to today. Detect the rename the way git
    does, from the hash the ledger already stores: where exactly one ledger
    key has disappeared and exactly one published key is new, and the two
    share a content hash, they are the same note and the entry moves.

    The 1:1 restriction is the whole of the safety argument. Two notes with
    identical content are rare but possible — a stub duplicated as a
    starting point — and a wrong carry is worse than a reset date, because
    it would silently attribute one note's history to another. Anything that
    is not an unambiguous pair stays a new note, which is exactly what
    happens without this function.
    """
    new_by_hash = {}
    for key in set(published) - set(ledger):
        digest = hashlib.sha256(published[key][1].encode("utf-8")).hexdigest()
        new_by_hash.setdefault(digest, []).append(key)
    gone_by_hash = {}
    for key, entry in ledger.items():
        if key in published:
            continue
        if isinstance(entry, dict) and "hash" in entry:
            gone_by_hash.setdefault(entry["hash"], []).append(key)
    for digest, keys in new_by_hash.items():
        if len(keys) != 1:
            continue
        gone = gone_by_hash.get(digest, [])
        if len(gone) == 1:
            ledger[keys[0]] = ledger.pop(gone[0])


def update_ledger(ledger, key, text, today, seed_revisions=0):
    """First sighting sets `published`; a changed note bumps `modified`.

    The hash covers the note as it was READ, not as it is written below, so a
    note's date does not move because some *other* note was published and its
    links here turned back into links.

    The ledger also carries `revisions`, a count of substantial rewrites, which
    is the signal `maturity_score` reads. It is seeded the first time a note is
    seen and bumped once per hash change after that. The seed comes from git
    (see `git_revisions`); where there is no repository the seed is 0 and the
    counter accrues from first deploy.

    The bump applies only to entries that already carried a counter. An entry
    written by an older version of the filter has no `revisions`, and seeding
    it from git is exactly right rather than approximate: git already counts
    every commit in its history, including the one that produced the current
    hash, so the seed is not followed by the bump. This is what makes the
    counter land on the real number for notes published before it existed,
    instead of treating a year of history as rewrites-since-yesterday.

    Keyed by the note's filename, deliberately not by its URL. The two are
    nearly the same string, and conflating them would mean that any future
    change to how a URL is derived silently re-dates every note on the site.
    A rename moves the entry before this runs (see `carry_renames`), so the
    changed key does not re-date the note.
    """
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    entry = ledger.get(key)
    if not isinstance(entry, dict) or "published" not in entry:
        ledger[key] = {
            "published": today,
            "modified": today,
            "hash": digest,
            "revisions": seed_revisions,
        }
        return ledger[key]
    revisions = entry.get("revisions")
    if revisions is None:
        revisions = seed_revisions
    elif entry.get("hash") != digest:
        revisions = revisions + 1
    if entry.get("hash") != digest:
        entry = {**entry, "modified": today, "hash": digest}
    entry["revisions"] = revisions
    ledger[key] = entry
    return entry


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    vault, staging = Path(argv[1]).resolve(), Path(argv[2]).resolve()
    ledger_path = Path(argv[3]).resolve()
    if not vault.is_dir():
        print(f"vault not a directory: {vault}", file=sys.stderr)
        return 2
    if staging == vault or vault in staging.parents:
        print("staging must be outside the vault", file=sys.stderr)
        return 2

    # ---- pass 1: decide what is published -----------------------------------
    published = {}  # stem(lower) -> (relative path, text)
    attachments = {}  # stem(lower) -> path
    taken = {}  # slug -> stem(lower), for collision detection
    collisions = []
    skipped = 0
    for path in sorted(vault.rglob("*")):
        if not path.is_file() or any(
            p.startswith(".") for p in path.relative_to(vault).parts
        ):
            continue
        if path.suffix.lower() in ATTACHMENT_SUFFIXES:
            attachments.setdefault(path.name.lower(), path)
            attachments.setdefault(path.stem.lower(), path)
            continue
        if path.suffix.lower() != ".md":
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            skipped += 1
            continue
        if is_published(text):
            rel = path.relative_to(vault)
            key = path.stem.lower()
            # Collide on the URL rather than on the filename: "Some Note" and
            # "some-note" are different files and one page, and only the slug
            # sees that.
            slug = slugify(path.stem)
            if slug in taken:
                collisions.append((published[taken[slug]][0], rel))
            taken[slug] = key
            published[key] = (rel, text)

    # Flattening puts every published note in one namespace, so a duplicate
    # filename would silently publish whichever sorted last — under the URL of
    # the other one. Refuse to build rather than guess which was meant.
    if collisions:
        print("published notes share a URL; rename one of each pair:", file=sys.stderr)
        for first, second in collisions:
            print(f"  {first}\n  {second}", file=sys.stderr)
        return 1

    # ---- pass 2: read frontmatter, so a thesis is known before anything is
    #              written and an unusable note is dropped before it is linked -
    fronts = {}  # stem(lower) -> (frontmatter mapping, body)
    theses = {}  # slug -> one-line claim, since a rewritten link carries a slug
    titles = {}  # slug -> display title, for backlinks and for the write loop
    for key, (rel, text) in sorted(published.items()):
        split = split_frontmatter(text)
        if split is None:
            print(f"unparseable frontmatter, not publishing: {rel}", file=sys.stderr)
            skipped += 1
            continue
        fronts[key] = split
        titles[slugify(rel.stem)] = resolve_title(split[0], split[1], rel)
        thesis = split[0].get("thesis")
        if thesis:
            theses[slugify(rel.stem)] = " ".join(str(thesis).split())
    # Drop the unusable ones BEFORE the link rewriter runs, or a note that is
    # about to be discarded still reads as published and every wikilink to it
    # survives as a link to a page that will not exist.
    published = {key: v for key, v in published.items() if key in fronts}

    # Every shelf the published set came from, and the hue ring slot each one
    # takes. Computed here because it needs the WHOLE set - a collision is
    # resolved against the other shelves, so no per-note pass can decide it -
    # and because everything downstream of this line wants the answer: the
    # frontmatter, the link marks, and the tree.
    hues = assign_topic_hues(
        {note_topic(rel) for rel, _ in published.values()} - {""}
    )

    # ---- pass 3: rewrite links, gather the attachments actually used --------
    used_attachments = {}

    def rewrite(m):
        """A wikilink becomes a Markdown link, an image, or plain text."""
        embed, target, heading, alias = m.groups()
        key = target.strip().lower()
        if embed:
            hit = attachments.get(key)
            if hit is None:
                return alias or target  # embed of something not shipping
            used_attachments[hit] = True
            return f"![{alias or ''}](/{ATTACHMENTS}/{slugify(hit.name)})"
        # A fragment naming a block rather than a heading points at an id
        # that is stripped below, so the link drops it rather than landing
        # nowhere.
        anchor = ""
        if heading and not heading[1:].startswith("^"):
            # A heading fragment follows the generator's rule, not ours - see
            # `anchorize` for why those are two different things.
            anchor = f"#{anchorize(heading[1:])}"
        if not key:
            # [[#Heading]] - Obsidian resolves an empty target against the
            # note holding the link, and a bare fragment does the same here.
            # A block reference in the same note has nothing left to point
            # at, so it becomes plain text like any other unshippable target.
            if not heading:
                return m.group(0)  # [[]] - not a link at all
            if anchor:
                return f"[{alias or heading[1:]}]({anchor})"
            return alias or heading[1:].lstrip("^")
        if key in published:
            return f"[{alias or target}](/{slugify(published[key][0].stem)}/{anchor})"
        return alias or target  # link to an unpublished note

    # ---- pass 4: the backlink graph ----------------------------------------
    # Whole-graph, and therefore its own pass: a note's backlinks depend on the
    # bodies of notes that have not been written yet, so this cannot be folded
    # into the loop below.
    #
    # Resolution deliberately mirrors `rewrite` above - same key, same lookup
    # in `published` - because a backlink that does not agree with the forward
    # link it came from is worse than no backlink at all.
    backlinks = {}  # target slug -> {source slug}
    for key, (rel, text) in sorted(published.items()):
        if rel.name.lower() == "index.md":
            continue  # see the module docstring
        source = slugify(rel.stem)
        for m in LINK.finditer(text):
            embed, target, _heading, _alias = m.groups()
            if embed:
                continue  # an image is not a citation
            hit = published.get(target.strip().lower())
            if hit is None:
                continue  # unpublished, or not a note
            dest = slugify(hit[0].stem)
            if dest == source:
                continue  # a note does not cite itself
            # A set, so a note that links to another five times is one entry.
            backlinks.setdefault(dest, set()).add(source)

    # Maturity reads the graph in both directions. Backlinks are who cites this
    # note; forward links are who this note cites, which is the transpose of
    # `backlinks` - every (target, source) edge above is a link from source to
    # target. The index is absent from both directions: it was skipped as a
    # source in the loop above, so it has no edges for the transpose to count
    # either, and a table of contents carries no maturity signal of its own.
    forward_links = {}  # source slug -> how many published notes it links to
    for dest, sources in backlinks.items():
        for source in sources:
            forward_links[source] = forward_links.get(source, 0) + 1

    # ---- pass 5: derive dates, then write a flat tree and swap it in --------
    try:
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
        if not isinstance(ledger, dict):
            ledger = {}
    except (OSError, ValueError):
        ledger = {}

    # A note that was renamed has a new key and no entry, which would re-date
    # it. Carry the entry across before the write loop looks anything up, so
    # a rename preserves `published` (and, from item 14 on, the revision
    # counter). Runs against the filtered `published` set, so a note that was
    # dropped as unparseable is not mistaken for a rename.
    carry_renames(ledger, published)

    today = date.today().isoformat()
    tmp = staging.with_name(staging.name + ".new")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)

    written = 0
    no_thesis = []
    overlong = []
    # What the bonsai is grown from, in the order this loop writes notes -
    # which is `sorted(published)`, so the tree is a function of the published
    # set and of nothing else. Appended only after a note has actually been
    # written, so a note dropped below is not a pad on a tree that claims to be
    # a picture of what is published.
    grown = []
    for key, (rel, text) in sorted(published.items()):
        slug = slugify(rel.stem)
        # Rewritten as one string, frontmatter included: a wikilink to a private
        # note is just as much of a leak in an `aliases:` list as it is in prose.
        # That rewriting can itself invalidate the YAML, which is why this is
        # re-checked here having already parsed in pass 2.
        split = split_frontmatter(LINK.sub(rewrite, text))
        if split is None:
            print(
                f"link rewriting broke the frontmatter, dropping: {rel}",
                file=sys.stderr,
            )
            skipped += 1
            continue
        front, body = split

        # Markdown convention says the first H1 is the title, and the page
        # template renders a title of its own, so a note written the usual way
        # shows it twice. Take the H1 out and let it BE the title, which also
        # means a note can be titled differently from its filename without
        # anyone having to remember a frontmatter key.
        heading = LEADING_H1.match(body)
        if heading:
            body = body[heading.end() :]

        # Obsidian's internal annotations - %% comments and ^block ids -
        # never leave the vault. One pass, so that code (fenced or inline) is
        # never touched by it.
        body = OBSIDIAN_INTERNAL.sub(lambda m: m.group(1) or m.group(2) or "", body)

        # Always explicit, because the file is about to be renamed to its slug
        # and a generator falling back to the filename for a title would then
        # show "building-capability" where it used to show "Building
        # Capability". The value comes from resolve_title, which pass 2 already
        # ran - the H1 is stripped here, but it is not decided here.
        front["title"] = titles[slug]

        entry = ledger.get(key)
        # Seed the revision counter from git only when the ledger has nothing
        # to bump: a brand-new note, or an entry written before the counter
        # existed. Every other run passes 0 and `update_ledger` either keeps
        # the count or advances it by one, so the seed (a git log walk) is paid
        # once per note, not once per build.
        needs_seed = not (
            isinstance(entry, dict) and isinstance(entry.get("revisions"), int)
        )
        seed = git_revisions(vault, rel) if needs_seed else 0
        entry = update_ledger(ledger, key, text, today, seed)

        # The word count is a signal for maturity, so it is computed for every
        # note, index included - the overlong report below is what stays
        # essay-only.
        words = len(body.split())
        # The landing page is a table of contents, not an essay: it has no
        # publication date worth showing and owes nobody a thesis.
        if rel.name.lower() != "index.md":
            if words > LONG_NOTE_WORDS:
                overlong.append((rel, words))
            # As real YAML dates, so they match a hand-written `published:` and
            # reach the generator as dates rather than as strings that look
            # like them.
            front.setdefault("published", date.fromisoformat(entry["published"]))
            if entry["modified"] != entry["published"]:
                front.setdefault("modified", date.fromisoformat(entry["modified"]))

            # The one-sentence claim, when there is one, is the page's
            # description: a better summary than the first 150 characters of
            # prose will ever be.
            thesis = front.get("thesis")
            if thesis and not front.get("description"):
                front["description"] = str(thesis).strip()
            if not thesis:
                no_thesis.append(rel)

        # Maturity is computed here because it needs the whole graph (from
        # pass 4) and the ledger (the revision counter just updated above),
        # neither of which exists earlier. A hand-written `maturity:` in the
        # note wins over the computed stage, exactly as a hand-written
        # `published:` beats the ledger; `maturity_score` is always the computed
        # number, so the override can sit next to what the model thinks.
        score = maturity_score(
            words=words,
            backlinks=len(backlinks.get(slug, ())),
            forward=forward_links.get(slug, 0),
            sections=len(H2_HEADING.findall(body)),
            revisions=entry["revisions"],
        )
        front["maturity_score"] = score
        if "maturity" not in front:
            front["maturity"] = maturity_stage(score)

        # Which shelf the note came from, and which hue that shelf draws in.
        # Emitted for every note, index included: it is a fact about the file
        # either way, and a key that is present on some notes and absent on
        # others is a key every consumer has to special-case.
        #
        # TWO keys, because they are two different facts and only one of them
        # is stable. `topic` is the shelf's name and is what the markup can be
        # read and asserted against; `hue` is which slot of the palette it
        # happens to occupy, which depends on the other shelves. A template
        # that wanted to colour by name would have to know every name.
        #
        # `hue` is a STRING and not a number, and the empty string is "no
        # shelf". Go templates treat the integer zero as false, so `{{ with
        # .Params.hue }}` on a number would silently drop the class for every
        # note in whichever shelf landed on slot 0 - a bug that shows up as
        # one shelf being grey and only if that slot is occupied.
        front["topic"] = note_topic(rel)
        front["hue"] = str(hues[front["topic"]]) if front["topic"] else ""

        # A list item that is only a link gets the target's thesis appended, so
        # an index or hub page reads as claims rather than as bare titles, and
        # the claim itself lives in exactly one place: the essay making it. An
        # item the author has already written prose after is left alone.
        def annotate(m):
            thesis = theses.get(m.group(3))
            if not thesis:
                return m.group(0)
            # Appended to the matched line rather than rebuilt from its parts,
            # so anything the pattern did not capture survives untouched.
            return f"{m.group(0).rstrip()} — {thesis}"

        body = BARE_LINK_ITEM.sub(annotate, body)

        # The margin, item 17. Computed from the body as it is about to be
        # written (the theses just appended included), so the map is a map of
        # what the reader will see. `word_count` and `reading_time` come from
        # the same `words` the maturity model read, one number used twice
        # rather than two numbers that drift apart. Emitted for every note,
        # index included, exactly as maturity is.
        front["sections"] = section_weights(body)
        front["word_count"] = words
        front["reading_time"] = max(1, (words + 199) // 200)

        # Sorted by title rather than by date. Which note happened to be
        # written first is not a fact about the note being read, and ordering
        # by it would quietly make an edit look like a change in relevance.
        if slug in backlinks:
            front["backlinks"] = [
                dict(
                    [("title", titles[src]), ("url", f"/{src}/")]
                    + ([("thesis", theses[src])] if src in theses else [])
                )
                for src in sorted(backlinks[slug], key=lambda s: titles[s].casefold())
            ]

        # Everything published lives at the root, so anything that used to live
        # in a folder needs its old address kept alive. Slugified segment by
        # segment: the address to keep alive is the one that was served, and
        # the vault path it came from is not that string — "essays/On
        # Boundaries" was served at /essays/on-boundaries/.
        old_url = "/".join(slugify(part) for part in rel.with_suffix("").parts)
        if rel.parent != Path("."):
            aliases = coalesce_aliases(front)
            if old_url not in aliases:
                aliases.append(old_url)
            front["aliases"] = aliases
            front.pop("alias", None)

        head = yaml.safe_dump(front, sort_keys=False, allow_unicode=True)
        # Defence in depth against this function itself: whatever we just built
        # has to still satisfy the check that let the note through in the first
        # place, or it does not get written.
        if not PUBLISH_TRUE.search(head):
            print(
                f"lost publish marker while rewriting, dropping: {rel}", file=sys.stderr
            )
            skipped += 1
            continue

        (tmp / f"{slug}.md").write_text(f"---\n{head}---\n{body}", encoding="utf-8")
        written += 1

        # The landing page is not foliage on its own tree: it is a table of
        # contents, the same reason it is excluded from the backlink graph and
        # from the dateline.
        if rel.name.lower() != "index.md":
            # The stage the PAGE claims, so the glyph and the page agree - a
            # hand-written `maturity:` wins here exactly as it wins in the
            # frontmatter. Anything that is not one of the three stages is not
            # a stage the tree can draw, so the computed one stands and the
            # note is still on the tree.
            stage = front["maturity"]
            if stage not in bonsai.LEAF_CHARS:
                stage = maturity_stage(score)
            grown.append(
                bonsai.Note(
                    title=titles[slug],
                    url=f"/{slug}/",
                    words=words,
                    stage=stage,
                    topic=front["topic"],
                    hue=front["hue"],
                )
            )

    # The bonsai, grown from the notes that were actually written above. It
    # goes into the staging tree because that is the one place downstream of
    # this filter and upstream of the generator, and it is NOT a note: the
    # renderer lifts it out of the content tree before Hugo ever sees it (see
    # lib/hugo.nix), so the published set is still exactly the .md files here.
    #
    # Written unconditionally, so an empty garden produces an empty plate
    # rather than last build's tree.
    (tmp / BONSAI).write_text(bonsai.render(grown), encoding="utf-8")

    for src in used_attachments:
        dest = tmp / ATTACHMENTS / slugify(src.name)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)

    old = staging.with_name(staging.name + ".old")
    if old.exists():
        shutil.rmtree(old)
    if staging.exists():
        staging.rename(old)
    tmp.rename(staging)
    if old.exists():
        shutil.rmtree(old)

    # Only after the tree is in place: a run that died above should not record
    # dates for notes that were never published.
    ledger_path.write_text(
        json.dumps(ledger, indent=2, sort_keys=True), encoding="utf-8"
    )

    print(
        f"published {written} notes, {len(used_attachments)} attachments"
        + (f", skipped {skipped}" if skipped else "")
    )
    # Reported, never enforced. These are the author's own standards and the
    # build has no business deciding when a note has met them.
    for rel in no_thesis:
        print(f"  no thesis: {rel}", file=sys.stderr)
    for rel, words in overlong:
        print(f"  {words} words: {rel}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
