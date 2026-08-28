# The garden builds a real vault, publishes only what is marked, and serves it.
#
# The build gate is weak evidence here. A template that does not resolve is a
# build error and there are no plugins to resolve, so most of what could go
# wrong does go loudly - but one thing does not: a *missing* template is not an
# error. Hugo skips the pages it would have rendered and reports success. The
# first Hugo build of this site emitted the home page and nothing else, and
# said "Total in 40 ms" while doing it.
#
# Two properties are therefore worth more than "it built".
#
# The publish boundary is the important one, and the only property in this
# repository whose failure has consequences outside it. A test that only
# checked the published note was present would pass just as happily if the
# filter had copied the entire vault, so the assertions below are written the
# other way round: the private markers must appear nowhere in the served tree,
# including the search index and the feed, which are the two places a leak
# would actually surface.
#
# The second is that the site has pages, styling and search - the things whose
# absence Hugo will not report. Asserting on the *count* of pages matters as
# much as asserting any one of them exists, because the silent-skip mode above
# produces a site that is real, styled, and missing everything.
#
# `source = "obsidian-sync"` rather than "git", because it reads the vault from
# disk instead of cloning it - the only path through this module that does not
# want the network. The sync service that would normally fill that directory is
# switched off and the vault is staged from a fixture instead: this covers the
# builder and the boundary, not Obsidian's client.
{
  name = "digital-garden";

  nodes.machine =
    { pkgs, ... }:
    let
      # Three published essays and a landing page; one note deliberately not
      # published, and one that fails to parse at all - because
      # publish-filter.py's stated rules are that publish defaults to false AND
      # that an unparseable note is skipped rather than published, and only the
      # second of those is a fail-closed claim worth testing.
      #
      # The published note links to the unpublished one, so the wikilink
      # rewriter is exercised rather than assumed.
      vault = pkgs.runCommand "garden-vault-fixture" { } ''
        mkdir -p $out/essays $out/private

        cat > $out/essays/on-gates.md <<'NOTE'
        ---
        publish: true
        thesis: A gate that only builds proves the wrong thing.
        ---

        # On Gates

        MARKER-PUBLISHED-BODY

        A gate that only proves the Nix evaluates is a gate against typos.

        This links to [[Rates And Figures]], which is not published, and to
        [[On Boundaries|the boundary essay]], which is.

        And to a heading inside it:
        [[On Boundaries#A Heading, With Punctuation -- and More]].

        - [[On Boundaries]]

        > [!warning] Watch the gate
        > MARKER-CALLOUT-BODY

        > [!note]- Folded away
        > MARKER-CALLOUT-FOLDED

        > [!tip]+
        > MARKER-CALLOUT-OPEN

        > [!question] A type with no GitHub equivalent
        > MARKER-CALLOUT-QUESTION

        Some ==MARKER-HIGHLIGHT== prose.

        %% MARKER-COMMENT-SECRET %%

        A paragraph carrying a block id. ^markerblockid

        A same-note link to [[#Some Section]], and a block-ref to
        [[On Boundaries#^someblock|the boundary block]].

        ## Some Section

        Euler's identity: $e^{i\pi} + 1 = 0$.

        ```python
        # %% MARKER-IN-CODE %% - inside a fence, %% is code, not a comment
        x = 1
        ```
        NOTE

        # Named as Obsidian names things - spaces and capitals - because a
        # wikilink resolves by filename, and because the staging tree should
        # then show it renamed to the slug it is served under.
        cat > "$out/essays/On Boundaries.md" <<'NOTE'
        ---
        publish: true
        thesis: MARKER-THESIS-BOUNDARIES
        ---

        # On Boundaries

        MARKER-BOUNDARIES-BODY

        ## A Heading, With Punctuation -- and More
        NOTE

        # Prose about money, which is the shape that took publishing down on
        # 2026-08-25: two unrelated dollar amounts in one paragraph read as an
        # inline maths span as far as the $...$ passthrough delimiters are
        # concerned, and KaTeX strict mode treated the en-dash inside it -
        # "Unrecognized Unicode character" - as a build-breaking error. It is
        # in the initial fixture rather than added later so that the very first
        # build has to survive it.
        cat > $out/essays/on-money.md <<'NOTE'
        ---
        publish: true
        thesis: Prose about money is not maths.
        ---

        # On Money

        MARKER-MONEY-BODY

        Roughly $80k on fixtures that last 5–7 years is a better position than ~$400k on fixtures that last 10+ years, because the second option locks you into decade-old technology you can no longer afford to replace.
        NOTE

        # A note that exercises the sidenote (_right-margin footnote_)
        # positioning, built to pin BOTH ways it has been got wrong.
        #
        # The first two footnotes live in DIFFERENT paragraphs that sit right
        # on top of each other, and the first note is deliberately long so its
        # margin note is tall enough to reach past the second citation. They
        # share one margin column, so the second note MUST be pushed down to
        # clear the first: scoping the overlap bookkeeping per block let it
        # land on top of the first instead, because two citations a few lines
        # apart have notes that are not.
        #
        # The third footnote is cited far below both, with nothing above it to
        # clear, so it MUST sit exactly beside its own citation. That is the
        # other failure: keying the bookkeeping by a DOM node as an object key
        # stringified every element to the same value, coupled every paragraph
        # on the page into one bucket, and dragged notes like this one far from
        # the text that cites them.
        cat > $out/essays/on-sidenotes.md <<'NOTE'
        ---
        publish: true
        ---

        # On Sidenotes

        MARKER-SIDENOTES-BODY

        The first paragraph cites a note that is deliberately long, so that its
        margin note wraps across several lines and grows tall: the exact
        condition under which a wrongly shared block would drag the following
        note down out of place.[^1]

        [^1]: This is a deliberately long sidenote. It continues to assert its
              length across multiple lines so that the rendered note in the
              margin is tall, wrapping well past the single line of its own
              citation, and tall enough to reach the position of the next
              note's citation below it. That reach is what exposes a shared
              block: the note that follows must still sit beside its own
              citation and not be pushed below this one.

        The second paragraph follows the first immediately, and cites its own
        note.[^2]

        [^2]: A second note in its own, separate paragraph.

        ## Far below

        This paragraph exists to put distance between the crowded pair above
        and the free note below, so that the last citation has nothing above it
        to clear and must therefore land exactly beside its own line.

        Another paragraph of filler, for the same reason: the margin column has
        to be empty here for the assertion below it to mean anything.

        More filler still. The point of the distance is that a note placed here
        is constrained by nothing except the position of its own citation.

        The distance has to be real rather than nominal: the second note's
        bottom, plus the gap a pushed note must clear it by, has to fall well
        above the third citation, or the third note is still being pushed and
        the assertion below it proves nothing.

        So there are several paragraphs here rather than one. They say nothing
        in particular; their only job is to be tall enough that the margin
        beside the last citation is genuinely empty.

        A fourth paragraph of the same, for the same reason.

        A fifth, and that is enough: the margin above the next citation is now
        clear by a wide margin at any window this test runs at.

        The final paragraph cites a note with clear margin above it.[^3]

        [^3]: A third note, far enough down the page that nothing crowds it.
        NOTE

        # A real landing page, because it is the one note whose handling is
        # special: it is excluded as a backlink SOURCE. Without it here, the
        # rule that keeps a table of contents from becoming every note's
        # backlink would be asserted by its absence, which is no assertion.
        cat > $out/index.md <<'NOTE'
        ---
        publish: true
        ---

        # Test Garden

        MARKER-INDEX-BODY

        - [[On Gates]]
        - [[On Boundaries]]
        NOTE

        cat > $out/private/rates-and-figures.md <<'NOTE'
        ---
        publish: false
        ---

        # Rates And Figures

        MARKER-PRIVATE-BODY
        NOTE

        cat > $out/private/no-frontmatter-at-all.md <<'NOTE'
        Just a stray note with no frontmatter.

        MARKER-UNPARSEABLE-BODY
        NOTE
      '';
    in
    {
      imports = [
        ../modules/services/digital-garden/digital-garden.nix
        (import ./stub-secrets.nix {
          secrets."digital-garden/obsidian-token" = "not-a-real-obsidian-token";
          templates."digital-garden-obsidian-env" = "OBSIDIAN_AUTH_TOKEN=not-a-real-obsidian-token\n";
        })
      ];

      cg.service.digital-garden = {
        enable = true;
        source = "obsidian-sync";
        siteTitle = "Test Garden";
        siteDescription = "A test garden.";
        baseUrl = "garden.test.invalid";
      };

      # The module adds a virtual host but never enables Caddy - on a real host
      # that comes from cg.service.reverse-proxy. Enabling it directly keeps
      # this test to the one module under examination.
      services.caddy.enable = true;

      # The half of the module that wants the network. It would restart every
      # 30 seconds against an Obsidian API the sandbox cannot reach, and the
      # vault it exists to populate is staged from the fixture below instead.
      systemd.services.digital-garden-sync.enable = false;

      systemd.tmpfiles.rules = [
        "C+ /var/lib/digital-garden/vault 0755 digital-garden digital-garden - ${vault}"
      ];

      # Hugo and Pagefind are two static binaries rendering a handful of
      # notes, so this needs very little - except that the sidenote check at
      # the bottom runs the page's own Javascript in a headless Chromium and
      # asks it where the notes landed. That is the only client-side behaviour
      # on the site, and no amount of grep can assert it, so chromium is here
      # and the memory allowance is sized for a browser rather than two
      # static generators.
      environment.systemPackages = [
        pkgs.chromium
        # For splicing the measurement probe into a copy of the served page;
        # coreutils alone cannot insert a multi-line script before </body>.
        pkgs.python3
      ];

      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    import datetime as dt
    import json
    import re

    SITE = "/var/lib/digital-garden/public"

    def served(path):
        return machine.succeed(f"curl -sf http://localhost:8086{path}")

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("caddy.service")

    with subtest("the builder runs to completion offline"):
        # Started explicitly rather than waited for: the unit is a
        # Type=oneshot without RemainAfterExit, so it reads inactive the
        # moment it succeeds. The fallback timer is 15 minutes, and the watcher
        # only fires on a change, so neither is a dependable first trigger here.
        # This also asserts a *second* run is clean, since the watcher may have
        # fired once already.
        machine.succeed("systemctl start digital-garden-build.service")
        # index.html, not the stylesheet: Hugo fingerprints its CSS, so the
        # stylesheet has no fixed name to test for. It is checked by URL below,
        # read off the page that links it.
        machine.succeed(f"test -f {SITE}/index.html")

    with subtest("only published notes are in the staging tree"):
        # The boundary is publish-filter.py, and it works by never copying an
        # unpublished note - so the check that matches the design is on what
        # the staging tree contains, not on what renders.
        #
        # The names are the slugs, not the vault's filenames: the filter owns
        # the URL, and a file staged under any other name would mean the
        # generator was deciding the address after all.
        staged = sorted(machine.succeed("ls /var/lib/digital-garden/content").split())
        assert staged == [
            "index.md",
            "on-boundaries.md",
            "on-gates.md",
            "on-money.md",
            "on-sidenotes.md",
          ], staged

    with subtest("no unpublished content reaches the served site"):
        # Deliberately the whole tree rather than the rendered page. A leak
        # would most plausibly surface in the Pagefind fragments (the search
        # index) or index.xml (the feed), neither of which anyone looks at.
        for marker in ["MARKER-PRIVATE-BODY", "MARKER-UNPARSEABLE-BODY"]:
            machine.fail(f"grep -r --quiet {marker} {SITE}")

        # And the note that fails to parse is skipped rather than published,
        # which is the fail-closed half of the filter's contract.
        machine.fail("curl -sf http://localhost:8086/no-frontmatter-at-all")

    with subtest("the staging tree is plain CommonMark"):
        # The filter converts wikilinks so that the generator never has to
        # understand Obsidian, which is what makes the generator replaceable.
        # Asserted on the staging tree AND on the served site: a surviving
        # wikilink renders as the literal text "[[Some Note]]" on the page,
        # which is a build that succeeds and a site that is wrong.
        machine.fail("grep -rq -e '[[' /var/lib/digital-garden/content")
        machine.fail(f"grep -rq -e '[[' {SITE}")

    with subtest("a link to a published note is a real link"):
        page = served("/on-gates")
        # The trailing slash is asserted, not tolerated. Both forms are served
        # directly, so this is not about reachability - it is that the filter
        # writes links in the same string Hugo publishes in rel=canonical, the
        # sitemap and the feed, and a page addressed two ways is a page that
        # gets counted, cached and linked two ways.
        assert re.search(r'href="\.?/on-boundaries/"', page), \
            "published link did not survive as a link, with its trailing slash"
        # The alias is what the reader sees, not the filename.
        assert "the boundary essay" in page

        # A list item that is nothing but a link gets the target's thesis
        # appended, so a hub page reads as claims. This is matched against the
        # rewritten Markdown link rather than the wikilink it started as, and
        # if that pattern stopped matching, every index would quietly lose its
        # annotations while the build stayed green.
        assert "MARKER-THESIS-BOUNDARIES" in page, "thesis was not appended to the bare link"

    with subtest("a link to an unpublished note is not a link"):
        page = served("/on-gates")
        assert "MARKER-PUBLISHED-BODY" in page
        # The title survives as plain text - digital-garden.nix names this as
        # a known residual leak, so it is pinned here rather than treated as a
        # bug. What must not survive is the href.
        assert "Rates And Figures" in page, "expected the title as plain text"
        assert "rates-and-figures" not in page, "wikilink was left as a link"

    with subtest("the site is served, flattened, at a stable URL"):
        assert "MARKER-PUBLISHED-BODY" in served("/on-gates")

        # publish-filter.py flattens published notes to the root so that
        # reorganising the vault cannot break a URL, and injects an alias for
        # the old path. Both halves matter: the flat URL is the address, and
        # the vault-shaped one still resolves.
        # The redirect target is matched loosely - absolute or relative is the
        # generator's business. That the old address still leads to the new one
        # is not.
        redirect = served("/essays/on-gates")
        assert re.search(r"url=\S*/on-gates/", redirect), redirect[:300]

        # The alias has to be the URL that was SERVED, not the vault path it
        # was derived from. "essays/On Boundaries.md" was reachable at
        # /essays/on-boundaries; an alias built from the raw path instead
        # publishes /essays/On%20Boundaries and leaves the real old address a
        # 404 - which is the whole promise of flattening, broken silently.
        # This fixture is named with a space and a capital for exactly this.
        redirect = served("/essays/on-boundaries")
        assert re.search(r"url=\S*/on-boundaries/", redirect), redirect[:300]
        machine.fail("curl -sf 'http://localhost:8086/essays/On%20Boundaries'")

    with subtest("every published note became a page"):
        # The silent-failure mode this test now exists for. A missing template
        # is not an error to Hugo: it skips the pages it would have rendered
        # and reports success. Counting is what catches that - the first Hugo
        # build of this site emitted the home page and nothing else, and any
        # assertion that only looked at the home page would have passed.
        home = served("/")
        assert "MARKER-PUBLISHED-BODY" not in home, "home page rendered an essay's body"
        for slug, marker in [
            ("on-gates", "MARKER-PUBLISHED-BODY"),
            ("on-boundaries", "MARKER-BOUNDARIES-BODY"),
            ("on-money", "MARKER-MONEY-BODY"),
            ("on-sidenotes", "MARKER-SIDENOTES-BODY"),
        ]:
            assert marker in served(f"/{slug}"), f"{slug} was not rendered"

        # And it is served on the FIRST request. Hugo emits `<slug>/index.html`,
        # which file_server answers with a 308 to the trailing-slash form unless
        # try_files names index.html ahead of the directory - so this asserts on
        # the status code, not merely on the body arriving after a redirect.
        code = machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' http://localhost:8086/on-gates"
        )
        assert code == "200", f"expected a direct 200, got {code}"

    with subtest("the site is styled"):
        # The stylesheet is fingerprinted, so its URL is read off the page
        # rather than guessed. Asserted on rules that carry the layout: a
        # stylesheet that built but resolved none of its content would still be
        # served, and would still be a 200.
        href = re.search(r'href="([^"]*main\.[^"]*\.css)"', served("/"))
        assert href, "no fingerprinted stylesheet linked from the home page"
        css = served(href.group(1))
        for selector in [".masthead", ".page", "--pf-border"]:
            assert selector in css, f"{selector} missing from the stylesheet"
        # And it asks nobody else for anything. The whole toolchain is offline
        # by construction; an @import or a font CDN named here undoes that in
        # one line, and it would still render perfectly on a machine with a
        # network, so nothing else would notice.
        assert "fonts.googleapis.com" not in css and "fonts.gstatic.com" not in css, \
            "the stylesheet fetches a font from a CDN"

    with subtest("search costs a reading page nothing until it is asked for"):
        # The bundle is ~46KB gzipped that a reader who never searches never
        # needs, so the page carries its URLs and fetches it on first use. The
        # failure this guards is a template edit that quietly puts either file
        # back into <head>, which nothing else would notice.
        page = served("/on-gates")
        assert not re.search(r'<script[^>]*\bsrc="[^"]*pagefind', page), \
            "the pagefind bundle is loaded on every page again"
        assert not re.search(r'<link[^>]*\bhref="[^"]*pagefind', page), \
            "the pagefind stylesheet is loaded on every page again"
        # And the other half: the URLs the page defers to have to be real, or
        # the search button is a button that does nothing.
        assert 'data-js="/pagefind/pagefind-component-ui.js"' in page, page[:400]
        for asset in ["pagefind-component-ui.js", "pagefind-component-ui.css"]:
            machine.succeed(
                f"curl -sf -o /dev/null http://localhost:8086/pagefind/{asset}"
            )

    with subtest("search is built and covers the published set"):
        # Pagefind indexes the rendered HTML, so an index that exists but is
        # empty means the pages were not there when it ran. Both halves matter:
        # the bundle being served, and the content being in it.
        entry = json.loads(served("/pagefind/pagefind-entry.json"))
        indexed = sum(lang["page_count"] for lang in entry["languages"].values())
        # Home, plus the two published essays. An index that exists but covers
        # nothing is what a build that skipped its pages leaves behind.
        assert indexed >= 3, f"only {indexed} pages indexed: {entry}"

        # Fragments are gzipped JSON, but that is an implementation detail of
        # Pagefind's storage rather than a promise - read them either way.
        fragments = machine.succeed(
            f"for f in {SITE}/pagefind/fragment/*; do gunzip -c $f 2>/dev/null || cat $f; done"
        )
        assert "MARKER-PUBLISHED-BODY" in fragments, "the published note is not searchable"

    with subtest("a note shows what cites it, and the index is not a citation"):
        # on-gates links to on-boundaries, so the backlink runs the other way.
        page = served("/on-boundaries")
        assert 'class="backlinks"' in page, "no backlinks section"
        assert re.search(r'<a href="/on-gates/">On Gates</a>', page), page[-800:]
        # With the source's thesis, so the list reads as claims.
        assert "A gate that only builds proves the wrong thing." in page

        # And the rule that needs a fixture to test at all: BOTH notes are
        # linked from the landing page, and neither may count it. on-gates is
        # cited by nothing else, so it must have no backlinks section - if the
        # index were counted, every note on the site would carry the same
        # entry and the feature would be noise.
        assert 'class="backlinks"' not in served("/on-gates"), \
            "the landing page was counted as a backlink source"

        # Backlinks sit outside data-pagefind-body: they are another note's
        # words, and indexing them here would make a search for a phrase
        # return the essay that was cited rather than the one that said it.
        fragments = machine.succeed(
            f"for f in {SITE}/pagefind/fragment/*; do gunzip -c $f 2>/dev/null || cat $f; done"
        )
        assert "Linked from" not in fragments, "backlinks were indexed for search"

    with subtest("headings are addressable"):
        page = served("/on-boundaries")
        # The id and the link have to agree; a heading with an id and no anchor
        # is not reachable, and an anchor pointing at a missing id is worse.
        m = re.search(r'<h2 id="([^"]+)">.*?<a class="heading-anchor" href="#([^"]+)"', page)
        assert m, page[-800:]
        assert m.group(1) == m.group(2), m.groups()
        # Named, not decorative - the visible text is a single "#".
        assert 'aria-label="Link to this section"' in page

    with subtest("a wikilink to a heading lands on that heading"):
        # Two different programs compute this string: publish-filter.py writes
        # the fragment when it rewrites the wikilink, and Hugo writes the id
        # when it renders the heading. They used to disagree the moment a
        # heading contained punctuation - `a-section--with-punctuation` against
        # `a-section-with-punctuation` - and the link silently landed nowhere.
        #
        # Asserted by comparing the two sides rather than by naming the
        # expected string, so this stays true if Hugo ever changes its rule:
        # what matters is that they agree, not what they agree on. The fixture
        # heading carries a comma and a `--`, which Goldmark's typographer
        # turns into an en dash before the id is computed.
        source = served("/on-gates")
        m = re.search(r'href="/on-boundaries/#([^"]+)"', source)
        assert m, "the heading wikilink did not survive as a fragment link"
        fragment = m.group(1)
        assert f'id="{fragment}"' in served("/on-boundaries"), \
            f"fragment #{fragment} matches no id on the target page"

    with subtest("callouts render as callouts, folds and all"):
        page = served("/on-gates")

        # Title and body survive, and the [!type] marker is gone rather than
        # left as visible text inside a plain blockquote - which is the way
        # this was broken, with a build that stayed green throughout.
        assert 'class="callout callout-warning"' in page, page[:2000]
        assert "Watch the gate" in page
        assert "MARKER-CALLOUT-BODY" in page
        assert "[!" not in page, "a callout marker was left as visible text"

        # Folding follows the sign: '-' starts closed, '+' starts open, and
        # both are <details> - collapsed in the HTML itself, not by a script.
        # An untitled callout takes its type as the title, as in Obsidian.
        assert re.search(r'<details class="callout callout-note">', page), \
            "the folded callout did not start closed"
        assert re.search(r'<details class="callout callout-tip" open>', page), \
            "the open callout lost its open state"
        assert ">Tip</summary>" in page

        # Obsidian lets a vault define its own types; one Hugo has never heard
        # of still renders as a callout, under its own name.
        assert 'class="callout callout-question"' in page
        assert "A type with no GitHub equivalent" in page

    with subtest("obsidian's internal-only syntax never leaves the vault"):
        page = served("/on-gates")
        # %% comments are stripped before staging. Checked on the staging tree
        # as well as the served site: this is the publish boundary, not
        # styling, and the place to discover an aside survived is here.
        machine.fail("grep -rq MARKER-COMMENT-SECRET /var/lib/digital-garden/content")
        machine.fail(f"grep -rq MARKER-COMMENT-SECRET {SITE}")
        # But %% inside a code fence is code, not a comment, and survives.
        assert "MARKER-IN-CODE" in page, "the comment stripper reached into a code fence"
        # Block ids are stripped with them; a survivor would be a stray
        # caret on the page.
        assert "markerblockid" not in page

        # ==highlights== and $...$ maths render as what they mean.
        assert "<mark>MARKER-HIGHLIGHT</mark>" in page
        assert 'class="katex"' in page, "inline maths was not rendered"

        # A same-note heading link keeps working, and a block reference drops
        # the fragment that cannot exist rather than linking nowhere.
        assert 'href="#some-section"' in page, "same-note heading link was not rewritten"
        assert "the boundary block" in page
        assert "#someblock" not in page

    with subtest("maths costs a reading page nothing"):
        # KaTeX renders at build time, so the only per-page asset is the
        # stylesheet, and it is linked only where an equation was rendered.
        assert "katex.min.css" in served("/on-gates"), \
            "a page with maths did not get the KaTeX stylesheet"
        assert "katex.min.css" not in served("/"), \
            "the home page links KaTeX with no maths on it"
        machine.succeed("curl -sf -o /dev/null http://localhost:8086/katex/katex.min.css")

    with subtest("a dollar-sign pair in prose does not fail the build"):
        # The 2026-08-25 outage: two unrelated amounts of money in one
        # paragraph are an inline maths span to the $...$ passthrough
        # delimiters, and KaTeX strict mode escalated the en-dash inside it to
        # a build error - so an ordinary sentence about cost took publishing
        # down. strict=warn keeps genuine parse errors fatal while letting this
        # render best-effort, which is what Obsidian shows for it too.
        #
        # Asserted on the note being served rather than merely the build
        # exiting zero, because a build that skipped its pages also exits zero.
        page = served("/on-money")
        assert "MARKER-MONEY-BODY" in page
        assert 'class="katex"' in page, \
            "the accidental maths span was not rendered as maths"
        assert "decade-old technology" in page

    with subtest("pages carry a social card built from the note's own claim"):
        page = served("/on-gates")
        assert '<meta property="og:type" content="article"' in page, page[:400]
        assert '<meta property="og:url" content="https://garden.test.invalid/on-gates/"' in page

        # The description is the note's own claim, not an extract of its prose.
        assert 'content="A gate that only builds proves the wrong thing."' in page, \
            "og:description is not the note's thesis"

        # This next one is the assertion that actually guards something, and it
        # is on the HOME page for a reason worth stating.
        #
        # Hugo ships an EMBEDDED opengraph partial. If _partials/social.html
        # fails to reach the build - it once did, being untracked, and a flake
        # only sees what git tracks - Hugo's version takes over silently. On an
        # essay that substitution is nearly invisible, because Hugo reads the
        # same `.Description` the filter wrote, so every assertion above still
        # passes. The home page is where the two diverge: it has no thesis of
        # its own, so it takes the site description, where Hugo's would
        # summarise the body - which on a table of contents means scraping the
        # link list. That is exactly what appeared the day this went wrong.
        home = served("/")
        assert '<meta property="og:type" content="website"' in home, home[:400]
        assert 'og:description" content="A test garden."' in home, \
            "the home page did not take the site description"
        assert "MARKER-INDEX-BODY" not in home.split("</head>")[0], \
            "the home page description was scraped from its body"

    with subtest("the feed carries whole essays, not teasers"):
        import xml.etree.ElementTree as ET

        feed = served("/index.xml")
        assert "on-gates" in feed
        # Parsed rather than grepped: Hugo's built-in feed emitted a stray
        # newline before the XML declaration once, which greps do not see and
        # a reader's parser does.
        channel = ET.fromstring(feed).find("channel")
        assert channel is not None, "the feed has no channel"
        assert channel.findtext("description") == "A test garden.", \
            "the channel kept Hugo's 'Recent content on ...' boilerplate"
        # Hugo printed "Mon, 01 Jan 0001" here until the frontmatter map fell
        # through to the publication date.
        built = channel.findtext("lastBuildDate") or ""
        assert "0001" not in built, built

        ns = {"content": "http://purl.org/rss/1.0/modules/content/"}
        items = {i.findtext("title"): i for i in channel.findall("item")}
        gates = items["On Gates"]
        # Both fields, and they are not the same text: the summary is the
        # thesis, the content is the essay.
        assert gates.findtext("description") == "A gate that only builds proves the wrong thing."
        body = gates.findtext("content:encoded", namespaces=ns) or ""
        assert "MARKER-PUBLISHED-BODY" in body, "the feed does not carry the essay"

        assert "on-gates" in served("/sitemap.xml")

    with subtest("caddy serves the generated 404 rather than its own"):
        # try_files plus handle_errors in the module's vhost. Hugo emits a
        # styled 404; without the handler Caddy answers with an empty one.
        machine.fail("curl -sf http://localhost:8086/no-such-note")
        assert len(machine.succeed("curl -s http://localhost:8086/no-such-note")) > 1000

    with subtest("a change to the vault triggers a rebuild without the timer"):
        # The inotify watcher, not a timer, is what publishes a change. A new
        # published note must reach the served site with nobody starting the
        # builder by hand: the watcher notices the write, the path unit fires
        # the build, and the 5s debounce collapses the burst.
        machine.wait_for_unit("digital-garden-watch.service")
        # Give inotifywait a moment to have its recursive watches established
        # before writing, so the event is not missed on a cold start.
        machine.sleep(duration=dt.timedelta(seconds=2))

        machine.succeed(
            "cat > /var/lib/digital-garden/vault/essays/on-triggers.md <<'NOTE'\n"
            "---\n"
            "publish: true\n"
            "thesis: A note that appears without a timer.\n"
            "---\n\n"
            "# On Triggers\n\n"
            "MARKER-TRIGGERED-BODY\n"
            "NOTE"
        )

        # 5s debounce + a couple of seconds to build; 60s is generous for a VM.
        machine.wait_until_succeeds(
            "curl -sf http://localhost:8086/on-triggers | grep -q MARKER-TRIGGERED-BODY",
            timeout=dt.timedelta(seconds=60),
        )

    with subtest("each sidenote sits beside its citation, not a shared block top"):
        # The sidenotes are the site's one piece of client-side behaviour: a
        # <script> in baseof.html turns each rendered footnote into an
        # absolutely-positioned note in the right-hand margin and writes its
        # `top` inline. No amount of grep can assert where a note lands, so the
        # only faithful check is to run that script and read the layout.
        #
        # The page is copied off the served tree onto the filesystem, the
        # measurement probe is appended, and the fingerprinted stylesheet link
        # is rewritten from an absolute root path to a same-directory one (the
        # @media (min-width: 80rem) rule that makes the notes position:absolute
        # and the .layout relative must actually apply, and on file:// an
        # absolute /main..css link would not resolve). Chromium is given a wide
        # viewport so that rule matches: at a phone-width viewport there is no
        # margin column and no sidenotes at all. The probe waits until the
        # script has written every note's top, then records each citation's and
        # each note's position.
        #
        # This is the regression test for on-sidenotes.md: two footnotes in two
        # separate paragraphs that sit right on top of each other, one of them
        # deliberately tall. When the placement loop keyed its overlap
        # bookkeeping by the DOM node as an object key, both paragraphs
        # stringified to the same value and the second note was pushed below
        # the tall first one instead of beside its own citation. The fix keys
        # by node identity, so each note must land exactly on its citation.
        machine.succeed(
            "mkdir -p /tmp/sn && "
            "cp /var/lib/digital-garden/public/on-sidenotes/index.html /tmp/sn/page.html && "
            "cp /var/lib/digital-garden/public/main.*.css /tmp/sn/"
        )

        # The probe sits between the notes' first placement and any later
        # re-placement, waiting in a requestAnimationFrame loop until every
        # .sidenote has an inline top, then measuring once.
        machine.succeed(
            "cat > /tmp/sn/probe.js <<'PROBE'\n"
            'var marker = document.createElement("div");\n'
            'marker.id = "SN-MEAS";\n'
            "function measure() {\n"
            "  var parts = [];\n"
            '  document.querySelectorAll("a.footnote-ref").forEach(function (a) {\n'
            '    parts.push("c" + a.getAttribute("href").replace("#", "") + "=" + Math.round(a.getBoundingClientRect().top));\n'
            "  });\n"
            '  document.querySelectorAll(".sidenote").forEach(function (s) {\n'
            "    var r = s.getBoundingClientRect();\n"
            '    parts.push("n" + s.id + "=" + Math.round(r.top) + "," + Math.round(r.height));\n'
            "  });\n"
            '  marker.textContent = "@@" + parts.join("|") + "@@";\n'
            "  document.body.appendChild(marker);\n"
            "}\n"
            "function maybeMeasure() {\n"
            '  var notes = document.querySelectorAll(".sidenote");\n'
            '  var placed = notes.length > 0 && Array.prototype.every.call(notes, function (n) { return n.style.top !== ""; });\n'
            "  if (placed) measure(); else requestAnimationFrame(maybeMeasure);\n"
            "}\n"
            'window.addEventListener("load", function () { requestAnimationFrame(maybeMeasure); });\n'
            "PROBE"
        )

        machine.succeed(
            "python3 - <<'PY'\n"
            "import re\n"
            'p = "/tmp/sn/page.html"\n'
            "s = open(p).read()\n"
            'probe = open("/tmp/sn/probe.js").read()\n'
            'css = re.search(r"main\\.[0-9a-f]+\\.css", s)\n'
            'assert css, "no fingerprinted stylesheet on the sidenote page"\n'
            's = re.sub(r\'href="/main\\.[0-9a-f]+\\.css"\', \'href="\' + css.group(0) + \'"\', s)\n'
            's = s.replace("</body>", "<script>" + probe + "</" + "script>" + "</body>", 1)\n'
            'open(p, "w").write(s)\n'
            "PY"
        )

        dom = machine.succeed(
            "chromium --headless=new --no-sandbox --disable-gpu "
            "--disable-dev-shm-usage --allow-file-access-from-files "
            "--virtual-time-budget=8000 --window-size=1600,1200 "
            "--dump-dom file:///tmp/sn/page.html 2>/dev/null"
        )

        m = re.search(r'id="SN-MEAS">@@(.*?)@@', dom, re.S)
        assert m, "the sidenote probe never ran"
        parts = m.group(1).split("|")
        cites = {}
        notes = {}
        for part in parts:
            key, _, value = part.rpartition("=")
            # Strip only the c/n tag, so the keys stay the footnote ids Hugo
            # gave them ("fn:2") and the assertions below name what they mean.
            if key.startswith("cfn:"):
                cites[key[1:]] = int(value)
            elif key.startswith("nfn:"):
                top, _, height = value.partition(",")
                notes[key[1:]] = (int(top), int(height))
        assert cites, f"no sidenote citations measured: {parts}"
        missing = sorted(set(cites) - set(notes))
        assert not missing, f"some citations got no sidenote: {missing}"

        # Down the page in citation order, which is the order the notes were
        # built in and the order the placement pass walks them.
        order = sorted(cites, key=lambda fid: cites[fid])

        # Nothing may sit above its own citation: a note is either beside the
        # line that cites it or below that line, never floating up the page.
        above = [
            (fid, cites[fid], notes[fid][0])
            for fid in order
            if notes[fid][0] < cites[fid] - 3
        ]
        assert not above, f"sidenotes above their citations (fid, cite, note): {above}"

        # Nothing may overlap the note before it: they share one margin column.
        overlaps = []
        previous = None
        for fid in order:
            top, height = notes[fid]
            if previous is not None and top < previous[1]:
                overlaps.append((previous[0], fid, previous[1] - top))
            previous = (fid, top + height)
        assert not overlaps, (
            f"sidenotes overlapping in the margin (above, below, px): {overlaps}"
        )

        # And a note is moved only as far as clearing the one above it needs.
        # Without this, "push everything to the bottom" would satisfy the two
        # assertions above, and so would the object-key bug that coupled every
        # paragraph on the page into a single bucket.
        slack = []
        previous_bottom = None
        for fid in order:
            top, height = notes[fid]
            floor = cites[fid] if previous_bottom is None else max(cites[fid], previous_bottom)
            if top > floor + 16:
                slack.append((fid, top, floor))
            previous_bottom = top + height
        assert not slack, (
            f"sidenotes pushed further than clearing required (fid, top, floor): {slack}"
        )

        # Finally, the specific geometry on-sidenotes.md was built for: the
        # tall first note reaches past the second citation, so fn:2 must have
        # been pushed clear of it, while fn:3 -- far below, with an empty
        # margin above it -- must be exactly beside its own line. One of these
        # fails under each of the two bugs this has had.
        assert notes["fn:2"][0] > cites["fn:2"] + 3, (
            "fn:2 was not pushed clear of the tall note above it: "
            f"note={notes['fn:2']} cite={cites['fn:2']}"
        )
        assert abs(notes["fn:3"][0] - cites["fn:3"]) <= 3, (
            "fn:3 has an empty margin above it and must sit on its citation: "
            f"note={notes['fn:3']} cite={cites['fn:3']}"
        )
  '';
}
