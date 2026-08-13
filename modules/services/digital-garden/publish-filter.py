#!/usr/bin/env python3
"""Copy ONLY notes marked `publish: true` out of the vault into a staging tree.

This is the security boundary for the digital garden, and it is deliberately
placed *before* the site generator rather than inside it. Quartz can filter on
`publish` itself (the explicit-publish plugin), but that puts the safety
property at the mercy of a config option that ships disabled by default and
could be silently dropped by an upgrade. Here, an unmarked note is never copied,
so it cannot be rendered, indexed, linked, or served no matter what the
generator is told to do.

Fail-closed rules, in order of importance:
  * publish defaults to false. Only a real YAML boolean true publishes.
  * Any note that fails to parse is skipped, never published.
  * Wikilinks that point at unpublished notes are flattened to plain text, so
    the garden contains no links to pages that do not exist.
  * Only attachments actually embedded by a published note are copied.
  * The staging tree is built fresh and swapped in, so a removed `publish: true`
    always disappears from the next build.

Usage: publish-filter.py <vault> <staging>
"""

import re
import shutil
import sys
from pathlib import Path

FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
# (?!\() rejects [[1]](url) — pasted Wikipedia prose is full of these
LINK = re.compile(r"(!?)\[\[([^\]|#]+)(#[^\]|]*)?(?:\|([^\]]*))?\]\](?!\()")
# deliberately not a YAML parser: we accept exactly one literal spelling
PUBLISH_TRUE = re.compile(r"^publish:\s*true\s*(?:#.*)?$", re.M | re.I)
ATTACHMENT_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif",
    ".pdf", ".mp4", ".webm", ".mp3", ".ogg", ".wav",
}


def is_published(text):
    m = FRONTMATTER.match(text)
    return bool(m) and bool(PUBLISH_TRUE.search(m.group(1)))


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    vault, staging = Path(argv[1]).resolve(), Path(argv[2]).resolve()
    if not vault.is_dir():
        print(f"vault not a directory: {vault}", file=sys.stderr)
        return 2
    if staging == vault or vault in staging.parents:
        print("staging must be outside the vault", file=sys.stderr)
        return 2

    # ---- pass 1: decide what is published -----------------------------------
    published = {}     # stem(lower) -> (relative path, text)
    attachments = {}   # stem(lower) -> path
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
            published[path.stem.lower()] = (path.relative_to(vault), text)

    # ---- pass 2: rewrite links, gather the attachments actually used --------
    used_attachments = {}

    def rewrite(m, _rel):
        embed, target, _heading, alias = m.groups()
        key = target.strip().lower()
        if embed:
            hit = attachments.get(key)
            if hit is None:
                return alias or target          # embed of something not shipping
            used_attachments[hit] = True
            return f"![[{hit.name}]]"
        if key in published:
            return m.group(0)
        return alias or target                  # link to an unpublished note

    out = {}
    for key, (rel, text) in published.items():
        out[key] = (rel, LINK.sub(lambda m: rewrite(m, rel), text))

    # ---- pass 3: build a fresh tree and swap it in --------------------------
    tmp = staging.with_name(staging.name + ".new")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    for _key, (rel, text) in out.items():
        dest = tmp / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8")
    for src in used_attachments:
        dest = tmp / "attachments" / src.name
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

    print(
        f"published {len(out)} notes, {len(used_attachments)} attachments"
        + (f", skipped {skipped} unreadable" if skipped else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
