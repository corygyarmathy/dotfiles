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

Nothing Obsidian-specific reaches the generator. Wikilinks become ordinary
Markdown links and embeds become ordinary images, so the staging tree is plain
CommonMark whose links already carry the finished URL. That is what keeps the
generator replaceable: it is handed files already named what they will be
served as, pointing at each other by those names, so swapping one generator for
another cannot silently move a page. See `slugify`.

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

`thesis:` is the note's claim in one sentence. It becomes the page description
and the RSS item's summary, and it is appended to any list item elsewhere that
is nothing but a link to the note — so an index or hub page reads as claims,
while each claim lives in exactly one place: the essay making it. It is
optional; a note without one is reported, not withheld. Notes past
LONG_NOTE_WORDS are reported on the same terms.

A leading H1 is lifted out of the body and becomes the title. The page template
renders a title of its own, so a note written the ordinary way would otherwise
show it twice.

Usage: publish-filter.py <vault> <staging> <ledger>
"""

import hashlib
import json
import re
import shutil
import sys
from datetime import date
from pathlib import Path

import yaml

FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
# (?!\() rejects [[1]](url) — pasted Wikipedia prose is full of these
LINK = re.compile(r"(!?)\[\[([^\]|#]+)(#[^\]|]*)?(?:\|([^\]]*))?\]\](?!\()")
# deliberately not a YAML parser: we accept exactly one literal spelling
PUBLISH_TRUE = re.compile(r"^publish:\s*true\s*(?:#.*)?$", re.M | re.I)
# The first thing in the body, if it is an ATX H1. Setext underlining is not
# matched: Obsidian does not produce it and guessing costs more than it saves.
LEADING_H1 = re.compile(r"\A\s*#[ \t]+(.+?)[ \t]*\n+")
# A list item that is nothing but a link to another published note — the shape
# an index or hub entry takes before its thesis is filled in. Matched after the
# wikilinks have already become Markdown links, so there is one link syntax to
# recognise here rather than two. The trailing slash is captured OUTSIDE the
# slug so that the lookup key matches the one `theses` is built with.
BARE_LINK_ITEM = re.compile(r"^([ \t]*[-*+][ \t]+)\[([^\]]*)\]\(/([^)#/]*)/?[^)]*\)[ \t]*$", re.M)
# Unreserved URL characters (RFC 3986). Anything else is dropped rather than
# percent-escaped: an escape in a path is not something anyone wants to read,
# type, or see in a browser's address bar.
SLUG_DROP = re.compile(r"[^a-z0-9._~-]")
# Not a limit, just the point past which a note is worth another look.
LONG_NOTE_WORDS = 500
# Where embedded files are staged, and the first segment of their URL.
ATTACHMENTS = "attachments"
ATTACHMENT_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif",
    ".pdf", ".mp4", ".webm", ".mp3", ".ogg", ".wav",
}


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
        front = yaml.safe_load(m.group(1))
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


def update_ledger(ledger, key, text, today):
    """First sighting sets `published`; a changed note bumps `modified`.

    The hash covers the note as it was READ, not as it is written below, so a
    note's date does not move because some *other* note was published and its
    links here turned back into links.

    Keyed by the note's filename, deliberately not by its URL. The two are
    nearly the same string, and conflating them would mean that any future
    change to how a URL is derived silently re-dates every note on the site.
    """
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    entry = ledger.get(key)
    if not isinstance(entry, dict) or "published" not in entry:
        entry = {"published": today, "modified": today, "hash": digest}
    elif entry.get("hash") != digest:
        entry = {**entry, "modified": today, "hash": digest}
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
    published = {}     # stem(lower) -> (relative path, text)
    attachments = {}   # stem(lower) -> path
    taken = {}         # slug -> stem(lower), for collision detection
    collisions = []
    skipped = 0
    for path in sorted(vault.rglob("*")):
        if not path.is_file() or any(p.startswith(".") for p in path.relative_to(vault).parts):
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
    fronts = {}   # stem(lower) -> (frontmatter mapping, body)
    theses = {}   # slug -> one-line claim, since a rewritten link carries a slug
    for key, (rel, text) in sorted(published.items()):
        split = split_frontmatter(text)
        if split is None:
            print(f"unparseable frontmatter, not publishing: {rel}", file=sys.stderr)
            skipped += 1
            continue
        fronts[key] = split
        thesis = split[0].get("thesis")
        if thesis:
            theses[slugify(rel.stem)] = " ".join(str(thesis).split())
    # Drop the unusable ones BEFORE the link rewriter runs, or a note that is
    # about to be discarded still reads as published and every wikilink to it
    # survives as a link to a page that will not exist.
    published = {key: v for key, v in published.items() if key in fronts}

    # ---- pass 3: rewrite links, gather the attachments actually used --------
    used_attachments = {}

    def rewrite(m):
        """A wikilink becomes a Markdown link, an image, or plain text."""
        embed, target, heading, alias = m.groups()
        key = target.strip().lower()
        if embed:
            hit = attachments.get(key)
            if hit is None:
                return alias or target          # embed of something not shipping
            used_attachments[hit] = True
            return f"![{alias or ''}](/{ATTACHMENTS}/{slugify(hit.name)})"
        if key in published:
            # The heading fragment is slugified the same way a filename is,
            # which is right for the headings Obsidian produces and would need
            # revisiting for one containing punctuation a generator strips.
            anchor = f"#{slugify(heading[1:])}" if heading else ""
            return f"[{alias or target}](/{slugify(published[key][0].stem)}/{anchor})"
        return alias or target                  # link to an unpublished note

    # ---- pass 4: derive dates, then write a flat tree and swap it in --------
    try:
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
        if not isinstance(ledger, dict):
            ledger = {}
    except (OSError, ValueError):
        ledger = {}

    today = date.today().isoformat()
    tmp = staging.with_name(staging.name + ".new")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)

    written = 0
    no_thesis = []
    overlong = []
    for key, (rel, text) in sorted(published.items()):
        slug = slugify(rel.stem)
        # Rewritten as one string, frontmatter included: a wikilink to a private
        # note is just as much of a leak in an `aliases:` list as it is in prose.
        # That rewriting can itself invalidate the YAML, which is why this is
        # re-checked here having already parsed in pass 2.
        split = split_frontmatter(LINK.sub(rewrite, text))
        if split is None:
            print(f"link rewriting broke the frontmatter, dropping: {rel}", file=sys.stderr)
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
            front.setdefault("title", heading.group(1).strip())
            body = body[heading.end() :]
        # Always explicit, because the file is about to be renamed to its slug
        # and a generator falling back to the filename for a title would then
        # show "building-capability" where it used to show "Building
        # Capability".
        front.setdefault("title", rel.stem)

        entry = update_ledger(ledger, key, text, today)
        # The landing page is a table of contents, not an essay: it has no
        # publication date worth showing and owes nobody a thesis.
        if rel.name.lower() != "index.md":
            words = len(body.split())
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
            print(f"lost publish marker while rewriting, dropping: {rel}", file=sys.stderr)
            skipped += 1
            continue

        (tmp / f"{slug}.md").write_text(f"---\n{head}---\n{body}", encoding="utf-8")
        written += 1

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
    ledger_path.write_text(json.dumps(ledger, indent=2, sort_keys=True), encoding="utf-8")

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
