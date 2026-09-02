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
        mkdir -p $out/essays $out/private $out/_Reference/Lighting $out/_Slip_Box

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

        The marks are exercised by linking to notes that carry them: [[on-money|On Money]]
        is the hand-written evergreen on the lighting shelf, [[on-sidenotes|On Sidenotes]] is
        the sapling on the slip box, and [[On Boundaries]] is the neutral
        seedling. And an [external site](https://example.invalid) exercises the
        third link kind, while a [dead link](/no-such-page/) points at nothing
        and must render as the plain anchor it always has.

        - [[On Boundaries]]

        > [!warning] Watch the gate
        > MARKER-CALLOUT-BODY

        > [!note]- Folded away
        > MARKER-CALLOUT-FOLDED

        > [!tip]+
        > MARKER-CALLOUT-OPEN

        > [!question] A type with no GitHub equivalent
        > MARKER-CALLOUT-QUESTION

        > [!important] The important flame
        > MARKER-CALLOUT-IMPORTANT

        > [!example] The example list
        > MARKER-CALLOUT-EXAMPLE

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

        | Column | MARKER-TABLE-CELL |
        | ------ | ----------------- |
        | a      | b                 |
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
        cat > "$out/_Reference/Lighting/on-money.md" <<'NOTE'
        ---
        publish: true
        thesis: Prose about money is not maths.
        published: 2001-02-03
        maturity: evergreen
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
        cat > "$out/_Slip_Box/on-sidenotes.md" <<'NOTE'
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

        # A note with enough `##` sections for the margin's scale map to
        # render (the threshold is three), with sections of DELIBERATELY
        # different lengths. A map drawn to scale is a map of the shape of a
        # note, and a fixture whose sections are all one size could never
        # show the proportionality being wrong.
        cat > $out/essays/on-sections.md <<'NOTE'
        ---
        publish: true
        thesis: MARKER-THESIS-SECTIONS
        ---

        # On Sections

        MARKER-SECTIONS-BODY

        ## The longest section

        This section is deliberately the longest on the page, so its block in
        the scale map has to be the tallest. That means several sentences of
        prose that exist for no reason other than to make the word count
        grow, and to make sure the difference between this section and the
        others is large enough to be measured rather than assumed.

        A second paragraph in the same section, for the same reason: the map
        is drawn to scale, and a scale that cannot be measured is a scale
        that cannot be wrong. More words here mean a taller block there.

        And a third, because two paragraphs of padding might still be too
        close to the next section for the assertion to mean anything. The
        shortest section below exists so this one has something obvious to be
        taller than.

        ## A middle one

        A section of middling length, so the map has three different block
        heights rather than two. It needs a little more prose to sit between
        the longest and the shortest.

        ## The shortest

        One line.

        ## A second middle one

        Back up toward the longer end, so the map is not monotonic: a scale
        map that just grew downward would be a list drawn as bars, and a
        fixture exists to catch the shape being wrong, not merely the heights.
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
        # The module asserts cg.service.reverse-proxy.enable is on - its Caddy
        # vhost depends on Caddy, which the reverse proxy enables on a real
        # host. Declare just that toggle here (rather than importing the whole
        # reverse-proxy module with its Cloudflare plugin build) so this test
        # keeps exercising only the digital garden.
        (
          { lib, ... }:
          {
            options.cg.service.reverse-proxy.enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          }
        )
      ];

      cg.service.digital-garden = {
        enable = true;
        source = "obsidian-sync";
        siteTitle = "Test Garden";
        siteDescription = "A test garden.";
        baseUrl = "garden.test.invalid";
        # One of each kind, because the option now has two: an entry with a
        # URL is a link, and an entry without one renders as muted text so a
        # destination that does not exist yet can still hold its place. Both
        # halves are asserted, in the header and in the footer.
        footerLinks = {
          GitHub = "https://github.com/example/test";
          Resume = "";
        };
      };

      # The module asserts cg.service.reverse-proxy.enable is on (declared by
      # the module added to imports above); satisfy it, then enable Caddy
      # directly rather than through the reverse proxy so this test keeps
      # exercising only the one module under examination.
      cg.service.reverse-proxy.enable = true;
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
    import html
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
            # Not a note. The bonsai's markup, which the filter grows from the
            # published set and lib/hugo.nix lifts out of the content tree
            # before Hugo sees it. It is asserted in this list rather than
            # excused from it, so that the list stays the exact contents of the
            # staging tree and anything new here has to be named.
            "bonsai.html",
            "index.md",
            "on-boundaries.md",
            "on-gates.md",
            "on-money.md",
            "on-sections.md",
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
            ("on-sections", "MARKER-SECTIONS-BODY"),
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

    with subtest("everything published is reachable from /notes, newest first"):
        # The landing page is a curated table of contents and is deliberately
        # not the guarantee that nothing is lost - fourteen of nineteen notes
        # used to be reachable only by search or by a backlink. /notes/ is the
        # page that makes that false, generated by layouts/_default/list.html
        # from site.RegularPages, and it must list every published note by the
        # title, thesis and date the note itself already carries.
        page = served("/notes")
        for href, title in [
            ("/on-gates/", "On Gates"),
            ("/on-boundaries/", "On Boundaries"),
            ("/on-money/", "On Money"),
            ("/on-sections/", "On Sections"),
            ("/on-sidenotes/", "On Sidenotes"),
        ]:
            assert re.search(f'<a href="{href}"[^>]*>{title}<svg class="mark"', page), \
                f"{title} is not listed on /notes"

        # ... and served on the FIRST request, the same direct-200 pin the
        # essays get: /notes is linked from every footer, so a redirect that
        # sneaks back in is a defect, not merely an old-address courtesy.
        code = machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' http://localhost:8086/notes"
        )
        assert code == "200", f"expected a direct 200 for /notes, got {code}"

        # The thesis rides along as the entry's description, the same field the
        # feed and the social card read.
        assert "A gate that only builds proves the wrong thing." in page, \
            "the /notes/ entry lost its thesis"
        assert "MARKER-THESIS-BOUNDARIES" in page

        # Newest first. on-money is pinned to 2001 in the fixture; the other
        # notes are dated by the ledger on the day of the build, so the oldest
        # must sort below every one of them.
        oldest = page.index('<a href="/on-money/"')
        for href in ["/on-gates/", "/on-boundaries/", "/on-sidenotes/"]:
            assert page.index(f'<a href="{href}"') < oldest, \
                f"{href} sorted below a note published in 2001"

        # The notes index is not in the feed: it is a section page, and the
        # feed carries the essays themselves.
        assert "All notes" not in served("/index.xml")

        # And the way here lives in the footer, next to RSS.
        assert 'href="/notes/"' in served("/"), "the footer does not link /notes/"

    with subtest("the site is styled"):
        # The stylesheet is fingerprinted, so its URL is read off the page
        # rather than guessed. Asserted on rules that carry the layout: a
        # stylesheet that built but resolved none of its content would still be
        # served, and would still be a 200.
        href = re.search(r'href="([^"]*main\.[^"]*\.css)"', served("/"))
        assert href, "no fingerprinted stylesheet linked from the home page"
        css = served(href.group(1))
        for selector in [".masthead", ".page", "--pf-border", ".note-index", ".section-map-list", ".margin-facts"]:
            assert selector in css, f"{selector} missing from the stylesheet"
        # The rail's "you are here" marker gets its own hue in Wave (carpYellow)
        # so it stays distinct from the purple --muted links around it; pin it so
        # that value cannot drift back toward crystalBlue, which the muted
        # change made indistinguishable (1.18:1). Since item 17 the hue has two
        # call sites - the current section's NAME and the fill of its bar - so
        # it is a role variable rather than a literal, and what is pinned is the
        # variable's value in each theme plus the fact that both sites read it.
        assert re.search(r"--reading:\s*#4d699b", css), \
            "the light theme's --reading is no longer lotusBlue4"
        assert re.search(r"--reading:\s*#e6c384", css), \
            "the dark theme's --reading is no longer carpYellow"
        assert re.search(r"\.rail a\.current\s*{[^}]*var\(--reading\)", css), \
            ".rail a.current no longer takes the reading hue"
        assert re.search(
            r"\.section-map-list a\.current \.section-map-fill\s*{[^}]*var\(--reading\)", css
        ), "the current section's bar fill no longer takes the reading hue"
        # And it asks nobody else for anything. The whole toolchain is offline
        # by construction; an @import or a font CDN named here undoes that in
        # one line, and it would still render perfectly on a machine with a
        # network, so nothing else would notice.
        assert "fonts.googleapis.com" not in css and "fonts.gstatic.com" not in css, \
            "the stylesheet fetches a font from a CDN"

        # Item 16's one mapping conflict, settled in the stylesheet. Obsidian
        # gives `important` the flame it gives `tip`, so important moved into
        # the tip group's green, and `example` keeps the violet on its own -
        # the two used to share a single violet rule. These pin the
        # settlement rather than the colours: a drift back toward the old
        # grouping, or a new grouping that splits the families differently,
        # fails here.
        assert re.search(r'\.callout-important[^}]*light-dark\(#6f894e,\s?#98bb6c\)', css), \
            "important no longer shares the tip group's green"
        assert re.search(r'\.callout-example\s*{[^}]*light-dark\(#624c83,\s?#957fb8\)', css), \
            "example no longer holds the violet alone"
        assert not re.search(r'\.callout-important,\s*\.callout-example', css), \
            "important is grouped with example again"
        # And the icon is sized to its label; its colour is inherited, never
        # set here.
        assert re.search(r'\.callout-icon\s*{[^}]*width', css), \
            "the callout icon is not sized"

    with subtest("a table wraps to the page, and scrolls only when it cannot"):
        # Three independent failures are guarded here, each of which alone is a
        # bug, and two of which have actually shipped.
        #
        # The first is the wrapper: `.table-container { overflow-x: auto }` sat
        # in the stylesheet for weeks with no hook to emit the div, so it
        # matched nothing, and a table wider than the measure scrolled the PAGE
        # - at 390px the document went to about twice the width of the phone,
        # and every paragraph on it could be dragged sideways. Nothing failed:
        # the build was clean, the CSS was there, the table rendered. So both
        # halves are asserted: the selector exists in the stylesheet, AND the
        # markup an actual table produces contains it.
        #
        # The second and third are the two ways of sizing a column by hand,
        # both of which were tried and both of which were worse than letting
        # the browser measure it:
        #
        #   - `width: max-content` sized the table to its content, so nothing
        #     wrapped and every table wider than the measure became one long
        #     line inside a scroll box;
        #   - `table-layout: fixed` over a <colgroup> of percentages estimated
        #     from codepoint counts made those estimates binding, so on a phone
        #     a 10% column was about two characters and "Backlinks" was set as
        #     nine stacked letters.
        #
        # Automatic layout has neither failure because it measures glyphs at the
        # width the page is being read at. It is the absence of the two overrides
        # that makes it work, and an absence is exactly what a future edit
        # reintroduces without noticing - so both are pinned negative.
        page = served("/on-gates")
        assert "MARKER-TABLE-CELL" in page, "the fixture table did not render"
        assert re.search(r'<div class="table-container"[^>]*>\s*<table', page), \
            "a table is not wrapped in .table-container"
        assert ".table-container" in css, \
            ".table-container missing from the stylesheet"
        assert "<colgroup" not in page, \
            "the hook is estimating column widths again; the browser measures better"
        assert not re.search(r'table\s*{[^}]*table-layout:\s*fixed', css), \
            "fixed layout is back, which makes an estimated width binding"
        assert not re.search(r'table\s*{[^}]*width:\s*max-content', css), \
            "the table rule sizes the table to its content again, so nothing wraps"
        assert re.search(r'table\s*{[^}]*width:\s*100%', css), \
            "tables do not fill the measure"
        # `anywhere` lets a break count towards the minimum width a cell reports,
        # so a column can be squeezed to one character and still claim to fit -
        # which is how the fixed layout produced its stacked letters, and it
        # would do the same under auto layout. `break-word` reports the honest
        # minimum. The two differ by one word and by exactly this bug.
        assert re.search(r'\bth,\s*\n\s*td\s*{[^}]*overflow-wrap:\s*break-word', css), \
            "cells do not wrap with break-word"
        assert not re.search(r'\bth,\s*\n\s*td\s*{[^}]*overflow-wrap:\s*anywhere', css), \
            "cells wrap with `anywhere`, which lets a column be sized below a word"
        # A table that scrolls has to say so. On a phone there is no scrollbar
        # until you touch the box, so a clipped table with no shadow on its edge
        # reads as a broken table rather than a scrollable one. The shadow pair
        # is `local` covers over `scroll` shadows; the `local` keyword is the
        # whole trick, so that is what is pinned.
        assert re.search(r'\.table-container\s*{[^}]*\blocal\b', css), \
            "the scroll shadow on a table container is gone"
        # And room around it. The container had no margin at all, so a table
        # took whatever the block after it happened to have above it - and a
        # callout's is 1rem, the same 1rem that separates two paragraphs of one
        # argument. A table and the callout under it therefore sat at the
        # spacing of two sentences and read as ONE object with a tinted foot.
        # The vault makes that adjacency common rather than rare: the markdown
        # formatter these notes are written with closes the blank line around
        # a table, so the two arrive with no authored separation to inherit.
        assert re.search(r'\.table-container\s*{[^}]*\bmargin:', css), \
            "a table has no room around it, so it merges with whatever follows"
        # And paper, which cannot scroll: the box must stop clipping there, or a
        # wide table prints with its right-hand columns cut off.
        assert re.search(r'@media print\s*{.*\.table-container\s*{[^}]*overflow-x:\s*visible',
                         css, re.S), \
            "a wide table is still clipped when printed"

    with subtest("the page declares a tab icon"):
        # Without one the browser asks for /favicon.ico on every visit and gets
        # a 404 for it. Fingerprinted like the stylesheet, so it is read off the
        # page and then fetched rather than guessed - a <link> pointing at an
        # asset the renderer did not copy would look right in the HTML and 404
        # for every reader, which is exactly how it first failed.
        icon = re.search(r'<link rel="icon"[^>]*href="([^"]+)"', served("/"))
        assert icon, "no icon linked from the home page"
        machine.succeed(f"curl -sf -o /dev/null http://localhost:8086{icon.group(1)}")

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

        # Item 16: each callout type carries the icon Obsidian gives it,
        # stroked in the callout's own hue. The sprite ships only on pages
        # that rendered a callout (the hasCallout store flag, the same gating
        # the KaTeX stylesheet gets from hasMath), and every <use> names a
        # symbol the sprite actually defines - an icon that references a
        # missing symbol draws nothing, which is the same silent failure as a
        # link to an uncopied asset.
        assert 'class="callout-sprite"' in page, \
            "no callout icon sprite on a page with callouts"
        assert 'class="callout-sprite"' not in served("/"), \
            "the icon sprite ships on pages with no callouts"
        for icon in ["pencil", "flame", "alert-triangle", "help-circle", "list"]:
            assert f'href="#callout-icon-{icon}"' in page, \
                f"no {icon} callout icon on the page"
            assert f'id="callout-icon-{icon}"' in page, \
                f"a callout references #callout-icon-{icon}, which the sprite does not define"
        # The conflict item 16 settled: important takes the flame, example the
        # list - the two types that used to share a hue on violet.
        assert 'class="callout callout-important"' in page
        assert "MARKER-CALLOUT-IMPORTANT" in page
        assert 'class="callout callout-example"' in page
        assert "MARKER-CALLOUT-EXAMPLE" in page
        # The icons are stroked in currentColor, so they inherit the callout's
        # own hue from the title rule; a colour hard-coded in the sprite would
        # undo the whole design.
        assert 'stroke="currentColor"' in page

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

    with subtest("ambient life runs on the 404, and only there"):
        # Item 20 of the design plan: a Game of Life seeded from an
        # R-pentomino, painted in --border, on the one page that has nothing
        # to read. The cells are cells, not notes, so it reports nothing and
        # is confined to the 404 - in particular NOT on the home page, where
        # two growing things would be one too many.
        #
        # The markup is pinned by grep; whether it RUNS, and pauses when it
        # should, is behaviour, so the rest is asserted by running the page's
        # own script in headless Chromium. The script writes its running state
        # and its population back to the canvas as data-attributes for exactly
        # this reason (see 404.html).
        # The 404 body is read without curl's -f: the page IS a 404, and -f
        # turns that status into a curl failure before the body is returned.
        page = machine.succeed("curl -s http://localhost:8086/no-such-note")
        assert '<aside class="life" aria-hidden="true">' in page, page[-800:]
        assert 'id="garden-life"' in page
        # Centred beneath the message, in the body - not in a margin. The
        # placement is the design, so it is pinned rather than assumed.
        assert re.search(r'</p>\s*<aside class="life" aria-hidden="true">', page), \
            "the life no longer sits directly beneath the message"
        assert "garden-life" not in served("/"), \
            "the life leaked onto the home page (two growing things is one too many)"
        assert "garden-life" not in served("/on-gates"), \
            "the life leaked onto a reading page"

        def life_dom(window, extra=""):
            return machine.succeed(
                "chromium --headless=new --no-sandbox --disable-gpu "
                "--disable-dev-shm-usage --virtual-time-budget=10000 "
                f"--window-size={window} {extra} --dump-dom "
                "http://localhost:8086/no-such-note 2>/dev/null"
            )

        # Runs: in view, the interval is live and the population has grown
        # from the five-cell seed - it evolved, rather than merely started.
        dom = life_dom("1600,1200")
        assert 'data-running="true"' in dom, "the life is not running while in view"
        m = re.search(r'data-population="(\d+)"', dom)
        assert m and int(m.group(1)) > 5, \
            f"the life never left the R-pentomino seed: {m and m.group(1)}"

        # Reduced motion: an ambient animation is exactly what the preference
        # is for. The seed frame may be painted; the interval must not run.
        quiet = life_dom("1600,1200", "--force-prefers-reduced-motion")
        assert 'data-running="true"' not in quiet, \
            "the life animates under prefers-reduced-motion"

        # Scrolled out of view: on the narrow layout the canvas sits below the
        # fold of a short window, so the IntersectionObserver stops it.
        hidden = life_dom("400,50")
        assert 'data-running="true"' not in hidden, \
            "the life animates while scrolled out of view"

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

        # The probe waits in a requestAnimationFrame loop until the document
        # is complete AND every .sidenote carries an inline top, then measures
        # once -- so it reads the notes after the re-placement that images,
        # fonts and window load trigger, not the first pass.
        #
        # Neither the probe nor the page it measures may depend on a frame
        # being produced. Under --virtual-time-budget chromium advances the
        # clock for pending timers, but rAF callbacks need frames, and in this
        # VM they sometimes never arrive: the same tree passed on a branch and
        # failed on master with "the probe never ran", because the poll loop
        # stalled before its first tick and the DOM was dumped with no marker
        # in it. The loop below polls on setTimeout for that reason, and the
        # placement it measures now runs straight away rather than from a rAF.
        #
        # The budget still has to cover the slowest runner rather than the
        # fastest -- 8000 passed here in 9s of wall clock and expired on a CI
        # runner that took 17.
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
            "var tries = 0;\n"
            "function maybeMeasure() {\n"
            "  tries++;\n"
            '  var notes = document.querySelectorAll(".sidenote");\n'
            '  var placed = notes.length > 0 && Array.prototype.every.call(notes, function (n) { return n.style.top !== ""; });\n'
            '  var settled = document.readyState === "complete";\n'
            "  // One more beat after both are true, so the measurement is the\n"
            "  // one that survives the re-placement fonts and window load\n"
            "  // trigger, not an earlier pass that is about to be rewritten.\n"
            "  if (placed && settled) { setTimeout(measure, 500); return; }\n"
            "  // Give up loudly rather than by producing nothing: a probe that\n"
            "  // never appends its marker is indistinguishable from one that\n"
            "  // never parsed, and says nothing about which.\n"
            "  if (tries > 200) {\n"
            '    marker.textContent = "@@GAVEUP placed=" + placed + " settled=" + settled + " notes=" + notes.length + "@@";\n'
            "    document.body.appendChild(marker);\n"
            "    return;\n"
            "  }\n"
            "  setTimeout(maybeMeasure, 50);\n"
            "}\n"
            "// setTimeout, not requestAnimationFrame. Under --virtual-time-budget\n"
            "// the clock is advanced for pending timers, but frames are only\n"
            "// produced if something drives them, and in this VM rAF sometimes\n"
            "// never fires at all -- which stalled this loop before its first\n"
            "// tick and dumped a DOM with no marker in it. That is also why the\n"
            "// page itself no longer waits on a frame to place its notes.\n"
            "//\n"
            "// Polling starts here rather than from the load event: the page can\n"
            "// already be complete by the time this script parses, and a load\n"
            "// listener added after the event has fired never runs at all.\n"
            "maybeMeasure();\n"
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
            "--virtual-time-budget=30000 --window-size=1600,1200 "
            "--dump-dom file:///tmp/sn/page.html 2>/dev/null"
        )

        m = re.search(r'id="SN-MEAS">@@(.*?)@@', dom, re.S)
        assert m, "the sidenote probe never ran"
        assert not m.group(1).startswith("GAVEUP"), (
            f"the sidenote probe timed out waiting for placement: {m.group(1)}"
        )
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

    with subtest("every published note carries a computed maturity"):
        # Item 14: the maturity model lives in publish-filter.py, which emits a
        # stage and a score into every staged note's frontmatter. Nothing
        # renders them yet - the margin that will is item 17 - so the contract
        # to pin is the staging tree, where the filter wrote them.
        staged = sorted(machine.succeed("ls /var/lib/digital-garden/content/*.md").split())
        assert staged, "no staged notes to check maturity on"
        for note in staged:
            head = machine.succeed(f"sed -n '1,25p' {note}")
            assert re.search(r"^maturity: (seedling|sapling|evergreen)$", head, re.M), (
                f"{note} has no maturity stage:\n{head}"
            )
            assert re.search(r"^maturity_score: \d+(\.\d+)?$", head, re.M), (
                f"{note} has no maturity score:\n{head}"
            )
            # Item 15's half of the same frontmatter pass, and the value the
            # bonsai colours a note's foliage with: the folder the note came
            # from, slugified. The landing page is at the vault root and has
            # no folder, so an empty value is the correct one there.
            # \x27\x27 is YAML's empty string, which is what a note at the
            # vault root gets. Spelt in escapes because this Python lives
            # inside a Nix indented string, where a pair of apostrophes is
            # the terminator rather than two characters.
            assert re.search(r"^topic: (\x27\x27|[a-z0-9-]+)$", head, re.M), (
                f"{note} has no topic:\n{head}"
            )
        essay = machine.succeed(
            "sed -n '1,25p' /var/lib/digital-garden/content/on-gates.md"
        )
        assert re.search(r"^topic: essays$", essay, re.M), essay

    with subtest("every staged note carries what the margin needs to draw"):
        # Item 17's filter side: the margin is unconditional, so the data it
        # always shows - the reading time and the scale map's per-section word
        # counts - has to be on every note, not only the ones that happen to
        # have a table of contents. The sections list carries the id the filter
        # computed for each `##` heading, which is the string the margin's
        # href="#id" has to land on, so it is pinned against Hugo's rendering
        # in the margin subtest below rather than assumed here.
        for note in ["index.md", "on-gates.md", "on-money.md", "on-sections.md"]:
            head = machine.succeed(f"sed -n '1,40p' /var/lib/digital-garden/content/{note}")
            assert re.search(r"^word_count: \d+$", head, re.M), f"{note} has no word_count:\n{head}"
            assert re.search(r"^reading_time: \d+$", head, re.M), f"{note} has no reading_time:\n{head}"
            assert re.search(r"^sections:", head, re.M), f"{note} has no sections:\n{head}"

        # The one sectioned note carries the map's raw material, each entry the
        # heading's id, title and the words under it.
        head = machine.succeed("sed -n '1,60p' /var/lib/digital-garden/content/on-sections.md")
        entries = re.findall(r"^  (id|title|words): (.+)$", head, re.M)
        assert entries, f"on-sections has no section entries:\n{head}"
        words = [int(w) for k, w in entries if k == "words"]
        assert len(words) >= 3, f"on-sections has fewer than three sections: {words}"
        assert len(set(words)) == len(words), (
            f"the fixture's section lengths are not distinct, so the scale map "
            f"cannot prove proportionality: {words}"
        )

    with subtest("the margin is on every note, whatever it has to say"):
        # Item 17's point: the left margin used to render only on the six of
        # nineteen notes that had a table of contents or a backlink, and the
        # other thirteen showed an empty 15rem column on a wide screen. Now the
        # column is unconditional and its CONTENTS are conditional, so even a
        # note with neither sections nor backlinks - on-money is exactly that -
        # renders the margin and its facts.
        page = served("/on-money")
        assert '<aside class="rail">' in page, "no margin on a bare note"
        assert "Reading time" in page
        assert "Maturity" in page
        # The reading time is the margin's own estimate, computed by the
        # filter from the same word count the maturity model reads.
        assert "<dd>1 min</dd>" in page, page[-600:]
        # on-money carries a hand-written `maturity: evergreen`, so the margin
        # must show the evergreen mark - the same override the maturity
        # subtest above pins in the staging tree, here on the page. The mark is
        # item 15's, from item 15's sprite: one sprite for the margin, the
        # /notes/ index and every internal link, so a maturity is drawn the
        # same way wherever it appears.
        assert 'href="#mark-evergreen"' in page, page[-600:]
        # And it takes the note's own topic hue. on-money sits on the Lighting
        # shelf, so the mark's <dd> carries that shelf's name and its slot in
        # the stylesheet's hue ring - the same pair the bonsai's foliage and
        # every internal link carry, all of them from _partials/topic-class.
        assert re.search(r'<dd class="topic-lighting hue-2">', page), (
            "the margin's maturity mark does not carry the note's topic hue"
        )
        assert '<nav class="rail-nav section-map"' not in page, \
            "on-money has no `##` sections, so the section map must not render"
        # The conditional half proved in the other direction on the same page:
        # on-gates cites on-money (item 15 added that link to exercise the
        # marks), so its margin carries backlinks even though it carries no map.
        assert 'class="backlinks"' in page, \
            "on-money is cited by on-gates, so its margin must carry backlinks"

        # And the case the item exists for: a note with NEITHER a map nor a
        # backlink still renders the margin and its facts, rather than an empty
        # column. on-gates has one `##` and is cited by nothing - index is
        # excluded as a backlink source - so it is the barest page the fixture
        # has. Before item 17 this note showed a 15rem hole on a wide screen.
        bare = served("/on-gates")
        # `rail-wide-only` because nothing cites on-gates: the aside is here in
        # the markup and hidden at the narrow width, where it would otherwise
        # be an empty box with a rule on top. See the swap subtest below.
        assert re.search(r'<aside class="rail(?: rail-wide-only)?">', bare), \
            "no margin on the barest note"
        assert "<dt>Published</dt>" in bare
        assert "<dt>Reading time</dt>" in bare
        assert "<dt>Maturity</dt>" in bare
        assert 'class="backlinks"' not in bare, \
            "on-gates is cited by nothing, so the backlinks must not render"

        # The mark's sprite is the one asset the margin needs, gated exactly as
        # the callout sprite is: present where a mark rendered, absent on a
        # page that draws none - a page that names a symbol the sprite does not
        # define, or a sprite that is never shipped, draws a mark that is
        # invisible to a screenshot and wrong to a reader.
        assert 'class="mark-sprite"' in page
        assert 'id="mark-seedling"' in page

        # The dates are two facts with two labels, not one label over both.
        # A note whose ledger entry has moved on carries an Updated row; the
        # label naming half its own value was the shape this replaced.
        assert "<dt>Published</dt>" in page, page[-600:]

    with subtest("the scale map is drawn to scale, and every block lands"):
        # The section map is the contents list drawn to scale: one block per
        # `##` section, its height proportional to that section's word count,
        # the current section picked out and filling as the reader moves. Two
        # properties are asserted: the map renders only when there are enough
        # sections for it to mean anything (on-sections has four, on-gates has
        # one and must have no map), and every block's href lands on the id the
        # filter computed - the "link to nowhere" failure that the wikilink
        # test guards, met from the margin's side.
        page = served("/on-sections")
        m = re.search(r'class="section-map-list" style="--widest: (\d+)"', page)
        assert m, "no section map on a note with four sections"
        # Every bar is drawn as a fraction of the page's longest section, so
        # the normalising number has to be exactly that and not, say, the
        # site's longest - which would draw every short note as a row of stubs.
        rows = re.findall(
            r'<a href="#([^"]+)" style="--w: (\d+)">\s*'
            r'<span class="section-map-name">([^<]+)</span>',
            page,
        )
        assert len(rows) == 4, f"expected four entries, got {rows}"
        assert int(m.group(1)) == max(int(w) for _f, w, _t in rows), (
            f"--widest {m.group(1)} is not the largest section: {rows}"
        )
        for frag, _w, title in rows:
            assert f'id="{frag}"' in page, \
                f"section map href #{frag} ({title}) lands on no heading id"
        # THE NAME IS IN THE MARKUP, not behind a hover. The first cut of the
        # map hid the names and revealed them on pointer, because the blocks
        # were sized by word count and the small ones had four pixels to draw
        # a name in; a contents list you have to hover to read is not a
        # contents list, and this is the assertion that keeps it one.
        for _f, _w, title in rows:
            assert title.strip(), f"a section map entry has no name: {rows}"
        # And the entries carry distinct weights - a map whose sections all
        # weigh the same would be a list. The fixture's sections are
        # deliberately different lengths; see on-sections.md.
        weights = {int(w) for _f, w, _t in rows}
        assert len(weights) == 4, f"the four entries are not distinct: {weights}"
        assert 'class="section-map-bar"' in page
        assert 'class="section-map-fill"' in page

        # A note with a single `##` must render no map: the column stays, the
        # contents are conditional.
        assert '<nav class="rail-nav section-map"' not in served("/on-gates")

    with subtest("the facts swap whole between the two layouts"):
        # A note's facts exist twice in the HTML, once per layout, and exactly
        # one copy is visible at a time. The swap is ALL of them: the first cut
        # moved only the dates onto the dateline and left the reading time and
        # the maturity in the margin, which at the narrow width sits BELOW the
        # essay - so the facts arrived split in half, and the half that came
        # after the prose was reached only by a reader who had finished it.
        #
        # The visibility is CSS rather than markup, so it is pinned in the
        # stylesheet like the rail's current-section hue is; the CONTENTS are
        # markup and are pinned on the page.
        page = served("/on-sections")
        line = re.search(r'<p class="dateline">(.*?)</p>', page, re.S)
        assert line, "a note has no dateline to carry its facts at the narrow width"
        line = line.group(1)
        assert "min read" in line, f"the note's dateline has no reading time:\n{line}"
        assert re.search(r'href="#mark-', line), \
            f"the note's dateline has no maturity mark:\n{line}"

        # And the /notes/ index gets the dates only. Its rows already carry a
        # maturity mark on each title, and a reading time on every one of them
        # is noise - the same partial, told to say less.
        index = served("/notes/")
        for entry in re.findall(r'<p class="dateline">(.*?)</p>', index, re.S):
            assert "min read" not in entry, f"an index row grew a reading time:\n{entry}"
            assert "#mark-" not in entry, f"an index row grew a second mark:\n{entry}"

        css_link = re.search(r'href="([^"]*main\.[^"]*\.css)"', served("/"))
        assert css_link, "no fingerprinted stylesheet to assert the swap on"
        css_served = served(css_link.group(1))
        assert re.search(r'\.layout\s*>\s*article\s*>\s*\.dateline\s*{[^}]*display:\s*none', css_served), \
            "the article's dateline is not hidden at the wide width"
        assert re.search(r'\.margin-facts\s*{[^}]*display:\s*none', css_served), \
            "the margin's facts are not hidden at the narrow width"

        # At the narrow width the facts and the map are both hidden, so a note
        # nothing cites has an empty <aside> - and the border that separates it
        # from the essay becomes a rule across the page with nothing after it.
        # on-gates is cited by nothing; on-money is cited by on-gates.
        assert 'class="rail rail-wide-only"' in served("/on-gates"), \
            "an uncited note's margin is not hidden at the narrow width"
        assert 'class="rail"' in served("/on-money"), \
            "a cited note's margin is hidden at the narrow width, losing its backlinks"

    with subtest("the section map is drawn to scale, and its names are readable"):
        # Two properties that grep cannot see, and both of them are the point
        # of the redesign. The bar widths are computed by the browser from the
        # --w weights against --widest, so only a rendered layout can say
        # whether the map is drawn to scale. And the NAMES have to be
        # measurably on screen: the first cut of this item sized the blocks by
        # word count on the vertical axis, which left the smallest section four
        # pixels tall and forced its name behind a hover, and a contents list
        # you have to hover to read is not a contents list. Reading selectors
        # would not have caught either failure; a screenshot caught the first
        # one, and this is that screenshot turned into a gate.
        #
        # The page is copied off the served tree and the probe appended,
        # exactly as the sidenote probe is; the fingerprinted stylesheet link
        # is rewritten from an absolute root path to a same-directory one so
        # the @media (min-width: 80rem) rules that reveal the map actually
        # apply on file://, and chromium is given a wide viewport.
        machine.succeed(
            "mkdir -p /tmp/sm && "
            "cp /var/lib/digital-garden/public/on-sections/index.html /tmp/sm/page.html && "
            "cp /var/lib/digital-garden/public/main.*.css /tmp/sm/"
        )
        machine.succeed(
            "cat > /tmp/sm/probe.js <<'PROBE'\n"
            'var parts = [];\n'
            'document.querySelectorAll(".section-map-list a").forEach(function (a) {\n'
            '  var w = a.style.getPropertyValue("--w").trim();\n'
            '  var bar = a.querySelector(".section-map-bar").getBoundingClientRect();\n'
            '  var name = a.querySelector(".section-map-name");\n'
            '  var box = name.getBoundingClientRect();\n'
            '  var vis = window.getComputedStyle(name);\n'
            '  parts.push([w, bar.width, box.height, vis.opacity, vis.visibility].join(":"));\n'
            "});\n"
            'var list = document.querySelector(".section-map-list");\n'
            'var marker = document.createElement("div");\n'
            'marker.id = "SM-MEAS";\n'
            'marker.textContent = "@@" + parts.join("|") + "|TRACK:" + list.getBoundingClientRect().width + "@@";\n'
            'document.body.appendChild(marker);\n'
            "PROBE"
        )
        machine.succeed(
            "python3 - <<'PY'\n"
            "import re\n"
            'p = "/tmp/sm/page.html"\n'
            "s = open(p).read()\n"
            'probe = open("/tmp/sm/probe.js").read()\n'
            'css = re.search(r"main\\.[0-9a-f]+\\.css", s)\n'
            'assert css, "no fingerprinted stylesheet on the section-map page"\n'
            's = re.sub(r\'href="/main\\.[0-9a-f]+\\.css"\', \'href="\' + css.group(0) + \'"\', s)\n'
            's = s.replace("</body>", "<script>" + probe + "</" + "script>" + "</body>", 1)\n'
            'open(p, "w").write(s)\n'
            "PY"
        )

        dom = machine.succeed(
            "chromium --headless=new --no-sandbox --disable-gpu "
            "--disable-dev-shm-usage --allow-file-access-from-files "
            "--virtual-time-budget=30000 --window-size=1600,1200 "
            "--dump-dom file:///tmp/sm/page.html 2>/dev/null"
        )
        m = re.search(r'id="SM-MEAS">@@(.*?)@@', dom, re.S)
        assert m, "the section-map probe never ran"
        items = m.group(1).split("|")
        track_tail = items.pop()
        assert track_tail.startswith("TRACK:"), f"probe lost its track width: {track_tail}"
        track = float(track_tail.split("TRACK:")[1])
        assert track > 100, f"the map is not laid out in the margin column: {track}"

        rows = []
        for item in items:
            w, bar, height, opacity, visibility = item.split(":")
            rows.append((int(w), float(bar), float(height), float(opacity), visibility))
        assert len(rows) == 4, f"expected four entries, measured {rows}"

        # EVERY NAME IS ON SCREEN. Not transparent, not collapsed, not
        # visibility:hidden - the three ways a label disappears while its
        # markup stays in the page and passes a grep.
        for w, _bar, height, opacity, visibility in rows:
            assert height >= 10, f"a section name has no height: {rows}"
            assert opacity == 1.0, f"a section name is transparent: {rows}"
            assert visibility == "visible", f"a section name is hidden: {rows}"

        # Nothing falls below the visible floor, and the longest section fills
        # the column: the map is normalised against this page's own longest
        # section, so its bar is the full track.
        assert all(bar >= 8 for _w, bar, _h, _o, _v in rows), \
            f"a bar fell below min-width: {rows}"
        widest = max(rows, key=lambda r: r[0])
        assert abs(widest[1] - track) < 2, \
            f"the longest section's bar does not fill the track: {widest} of {track}"

        # And it is drawn to scale: every bar's width is proportional to its
        # section's word count. A bar pinned to the min-width floor is excluded,
        # since the floor is a shape the map makes on purpose; the rest must
        # agree within a fifth.
        ratios = [bar / w for w, bar, _h, _o, _v in rows if bar > 10]
        assert len(ratios) >= 3, f"too few measurable bars: {rows}"
        assert (max(ratios) - min(ratios)) / min(ratios) < 0.2, (
            f"bar widths are not proportional to word counts: {rows}"
        )

    with subtest("the reading line reaches every section and the foot of the note"):
        # The scroll-spy is arithmetic on offsets, and arithmetic on offsets is
        # exactly the thing that looks right in the source and is wrong on the
        # page. Three faults were reported against the first version of it and
        # all three are gated here, by sweeping the whole scrollable range and
        # asserting properties of the sequence rather than of one position.
        #
        # THE LAST SECTION HAS TO BE REACHABLE. The reading line sits below the
        # viewport's top, so a line at a fixed offset stops a whole screenful
        # short of the document's end and every heading in that screenful never
        # becomes current at all. Two of the three sectioned notes in the real
        # vault were in exactly that state - the last section never highlighted
        # and its bar never filled - and nothing in the markup or the stylesheet
        # showed it.
        #
        # THE HANDOVER HAS TO BE CONTINUOUS. Deciding the current section by one
        # rule and the fill by another leaves a gap between them, and the bar
        # crosses that gap in one jump when the next section takes over. With a
        # single reading line the bar reaches full at the instant of handover,
        # so the remainder at each handover should be zero - it is asserted
        # against the sweep's own step size, which is the resolution this can
        # be measured at.
        #
        # AND IT HAS TO BE MONOTONIC. The current section going backwards while
        # the page scrolls forwards is what a reader sees as flicker: the old
        # version chose the topmost heading inside an observation band, and
        # scrolling up puts several headings in that band at once.
        machine.succeed(
            "mkdir -p /tmp/sc && "
            "cp /var/lib/digital-garden/public/on-sections/index.html /tmp/sc/page.html && "
            "cp /var/lib/digital-garden/public/main.*.css /tmp/sc/"
        )
        # The sweep dispatches synthetic scroll events. Headless chromium moves
        # the scroll position but does not run the rendering steps that deliver
        # a real scroll event, so driving the page's own handler is the only way
        # to exercise it here - and it is the same handler a reader's scroll
        # calls, not a reimplementation of it.
        machine.succeed(
            "cat > /tmp/sc/probe.js <<'PROBE'\n"
            'window.addEventListener("load", function () {\n'
            "  var limit = document.documentElement.scrollHeight - window.innerHeight;\n"
            '  var links = [].slice.call(document.querySelectorAll(".section-map-list a"));\n'
            "  var tops = [];\n"
            "  for (var t = 0; t < links.length; t++) {\n"
            "    var id = decodeURIComponent(links[t].hash.slice(1));\n"
            "    tops.push(document.getElementById(id).getBoundingClientRect().top);\n"
            "  }\n"
            '  var artEnd = document.querySelector("article").getBoundingClientRect().bottom;\n'
            "  var out = [];\n"
            "  for (var s = 0; s <= 200; s++) {\n"
            "    var y = Math.round((limit * s) / 200);\n"
            "    window.scrollTo(0, y);\n"
            '    window.dispatchEvent(new Event("scroll"));\n'
            "    var cur = -1;\n"
            "    var fills = [];\n"
            "    for (var i = 0; i < links.length; i++) {\n"
            '      if (links[i].classList.contains("current")) cur = i;\n'
            '      fills.push(parseFloat(links[i].style.getPropertyValue("--fill") || "0"));\n'
            "    }\n"
            "    out.push([y, cur, fills]);\n"
            "  }\n"
            '  var d = document.createElement("div");\n'
            '  d.id = "SWEEP";\n'
            '  d.textContent = "@@" + JSON.stringify({\n'
            "    limit: limit, tops: tops, artEnd: artEnd, samples: out\n"
            '  }) + "@@";\n'
            "  document.body.appendChild(d);\n"
            "});\n"
            "PROBE"
        )
        machine.succeed(
            "python3 - <<'PY'\n"
            "import re\n"
            'p = "/tmp/sc/page.html"\n'
            "s = open(p).read()\n"
            'probe = open("/tmp/sc/probe.js").read()\n'
            'css = re.search(r"main\\.[0-9a-f]+\\.css", s)\n'
            'assert css, "no fingerprinted stylesheet on the section-map page"\n'
            's = re.sub(r\'href="/main\\.[0-9a-f]+\\.css"\', \'href="\' + css.group(0) + \'"\', s)\n'
            's = s.replace("</body>", "<script>" + probe + "</" + "script>" + "</body>", 1)\n'
            'open(p, "w").write(s)\n'
            "PY"
        )

        # A short viewport, so that a four-section fixture note actually has a
        # scrollable range to sweep. The width still has to clear the 80rem
        # breakpoint, or the map is display:none and there is nothing to read.
        dom = machine.succeed(
            "chromium --headless=new --no-sandbox --disable-gpu "
            "--disable-dev-shm-usage --allow-file-access-from-files "
            "--virtual-time-budget=60000 --window-size=1600,480 "
            "--dump-dom file:///tmp/sc/page.html 2>/dev/null"
        )
        m = re.search(r'id="SWEEP">@@(.*?)@@', dom, re.S)
        assert m, "the scroll sweep never ran"
        sweep = json.loads(m.group(1))
        samples = sweep["samples"]
        tops = sweep["tops"]
        count = len(tops)
        assert count == 4, f"expected four sections to sweep, got {count}"
        # The sweep proves nothing on a page that cannot scroll.
        assert sweep["limit"] > 200, (
            f"on-sections does not scroll at this viewport ({sweep['limit']}px), "
            "so the reading line is never exercised"
        )
        step = samples[1][0] - samples[0][0]

        # Every section gets a turn. This is the reported fault, and the one
        # that only shows on notes whose last heading lies in the final
        # screenful - which is most short notes.
        seen = {c for _y, c, _f in samples if c >= 0}
        missing = [i for i in range(count) if i not in seen]
        assert not missing, f"sections that never become current: {missing}"

        # At the foot of the page the note is finished: the last section is
        # current and every bar is full. This is the progress bar completing.
        last_y, last_cur, last_fills = samples[-1]
        assert last_cur == count - 1, (
            f"at the bottom the current section is {last_cur}, not the last"
        )
        assert all(f >= 0.999 for f in last_fills), (
            f"at the bottom the bars are not all full: {last_fills}"
        )

        # Monotonic: the mark never travels back up the list while the reader
        # travels down the page.
        previous = -2
        for y, cur, _f in samples:
            assert cur >= previous, f"the current section went backwards at y={y}"
            previous = cur

        # Continuous: a bar is already full when the next section takes over,
        # so nothing jumps. Measured in document pixels against the sweep's own
        # step, because a coarser sweep can only ever resolve the remainder to
        # within one step of scrolling.
        for i in range(1, len(samples)):
            _py, prev_cur, prev_fills = samples[i - 1]
            _y, cur, _fills = samples[i]
            if cur > prev_cur >= 0:
                end = tops[prev_cur + 1] if prev_cur + 1 < count else sweep["artEnd"]
                span = end - tops[prev_cur]
                remainder = (1.0 - prev_fills[prev_cur]) * span
                assert remainder <= 2 * step, (
                    f"section {prev_cur} jumped {remainder:.0f}px to full when "
                    f"section {cur} took over (one sweep step is {step}px)"
                )

    with subtest("a hand-written maturity wins over the computed score"):
        # on-money is a short note with no links, sections or rewrites: its
        # computed score is well below the sapling threshold. Its frontmatter
        # says `maturity: evergreen`, and that hand-written stage must survive
        # the filter unchanged - exactly as a hand-written `published:` beats
        # the ledger. The score stays computed, so the override can be read
        # next to what the model thinks.
        head = machine.succeed("sed -n '1,25p' /var/lib/digital-garden/content/on-money.md")
        assert re.search(r"^maturity: evergreen$", head, re.M), head
        m = re.search(r"^maturity_score: ([0-9.]+)$", head, re.M)
        assert m, "on-money lost its computed score"
        assert float(m.group(1)) < 1.5, (
            "on-money's score is not below the sapling threshold, so the "
            f"evergreen override proves nothing: {m.group(1)}"
        )

    with subtest("the filter carries each note's topic and hue into frontmatter"):
        # Item 15: the topic hue is derived from the shelf a note lives on,
        # and the filter writes that folder, slugified, into frontmatter as
        # `topic` - the same value the bonsai's foliage reads. The landing
        # page is at the root and gets the empty string, which is the honest
        # no-topic answer rather than a made-up one.
        #
        # `hue` beside it is the shelf's slot in the stylesheet's ring, from a
        # hash of the shelf's OWN name - so `essays`, which used to fall
        # through to grey because nothing had written it a rule, now has a
        # colour like every other shelf without this file or the stylesheet
        # knowing it exists. That is the whole point of the ring.
        #
        # The numbers are the hashes, and they are written out rather than
        # recomputed here on purpose: recomputing them would assert that the
        # filter agrees with itself, which it cannot fail to do. These say the
        # mapping has not silently moved under a reader who has learned it.
        for note, topic, hue in [
            ("on-money", "lighting", "2"),
            ("on-sidenotes", "slip-box", "4"),
            ("on-gates", "essays", "6"),
        ]:
            head = machine.succeed(
                f"sed -n '1,30p' /var/lib/digital-garden/content/{note}.md"
            )
            assert re.search(rf"^topic: {topic}$", head, re.M), head
            assert re.search(rf"^hue: \x27{hue}\x27$", head, re.M), head
        head = machine.succeed("sed -n '1,30p' /var/lib/digital-garden/content/index.md")
        assert re.search(r"^topic: \x27\x27$", head, re.M), head
        # No shelf, no slot. A note at the root gets neither, rather than
        # borrowing slot 0 - which a numeric default would have handed it.
        assert re.search(r"^hue: \x27\x27$", head, re.M), head

    with subtest("growth marks report maturity and topic on the /notes/ index"):
        # Item 15's first use of the mark: the generated index shows at a
        # glance what is finished. Each entry trails a mark whose SHAPE is the
        # note's maturity stage and whose HUE is its topic - green for the slip
        # box, orange for the lighting shelf, and now a hue for every other
        # shelf too rather than grey. The shape is asserted by the symbol each
        # <use> names, and the hue by the pair of classes _partials/topic-class
        # wrote from the filter's frontmatter: the shelf's NAME, which is what
        # this file can read, and its RING SLOT, which is what carries colour.
        page = served("/notes")
        assert re.search(r'<a href="/on-money/" class="topic-lighting hue-2">On Money<svg class="mark"[^>]*><use href="#mark-evergreen"', page), \
            "the on-money entry lost its orange evergreen mark"
        assert re.search(r'<a href="/on-sidenotes/" class="topic-slip-box hue-4">On Sidenotes<svg class="mark"[^>]*><use href="#mark-sapling"', page), \
            "the on-sidenotes entry lost its green sapling mark"
        assert re.search(r'<a href="/on-gates/" class="topic-essays hue-6">On Gates<svg class="mark"[^>]*><use href="#mark-sapling"', page), \
            "the on-gates entry lost its sapling mark"
        assert re.search(r'<a href="/on-boundaries/" class="topic-essays hue-6">On Boundaries<svg class="mark"[^>]*><use href="#mark-seedling"', page), \
            "the on-boundaries entry lost its seedling mark"
        # `ZgotmplZ` is what Go's html/template writes when it will not let a
        # value into the context it was placed in, and an attribute NAME is one
        # of those contexts: the class attribute here comes out of a partial,
        # and a partial that returned a plain string would land every mark on
        # this page as `ZgotmplZ` with no build error at all. It is asserted
        # across the whole site, not just here, because that failure is silent
        # and total.
        assert "ZgotmplZ" not in page, "a template value was rejected by the escaper"
        # Every symbol the entries reference is defined by the sprite on the
        # same page - a mark that references a missing symbol draws nothing,
        # which is the same silent failure as a link to an uncopied asset.
        assert 'class="mark-sprite"' in page, "no mark sprite on the index"
        for symbol in ["seedling", "sapling", "evergreen"]:
            assert f'id="mark-{symbol}"' in page, \
                f"a mark references #mark-{symbol}, which the sprite does not define"

    with subtest("internal links carry the target's maturity and topic"):
        # Item 15's second use of the mark: a link says whether it leads
        # somewhere finished. The hook resolves the link back to the target
        # page and reads its frontmatter, so the sprout is the TARGET's stage
        # - on-money's hand-written evergreen included - and its hue is the
        # target's shelf. on-boundaries is on the `essays` shelf, which under
        # the hue ring has a colour of its own like every other shelf; it used
        # to be the case that this link had to be grey, because the stylesheet
        # named two shelves and no more.
        page = served("/on-gates")
        assert re.search(r'<a href="/on-money/" data-maturity="evergreen" class="topic-lighting hue-2">', page), page[:1000]
        assert 'href="#mark-evergreen"' in page
        assert re.search(r'<a href="/on-sidenotes/" data-maturity="sapling" class="topic-slip-box hue-4">', page), page[:1000]
        assert 'href="#mark-sapling"' in page
        assert re.search(r'<a href="/on-boundaries/" data-maturity="seedling" class="topic-essays hue-6">', page), page[:1000]
        assert "ZgotmplZ" not in page, "a template value was rejected by the escaper"
        # The same-page section link takes a dotted underline and no glyph,
        # because there is no destination note to describe.
        assert re.search(r'<a href="#some-section" class="link-section">', page), page[:1000]
        # The external link keeps the arrow the stylesheet already emits; the
        # hook must render it as a plain anchor with no sprout inside it.
        assert re.search(r'<a href="https://example.invalid">[^<]*</a>', page), page[:1000]
        # A link to a page that does not exist resolves to nothing, and the
        # hook must render it exactly as the bare renderer did - a sprout for
        # a page with no maturity would be a link that reports nothing.
        dead = re.search(r'<a href="/no-such-page/">[^<]*</a>', page)
        assert dead, page[:1000]
        assert 'data-maturity' not in dead.group(0)
        # And the sprite ships only where a mark rendered. Since item 17 that
        # is every NOTE, because the margin draws the note's own maturity even
        # when its prose links to nothing - on-boundaries used to be the "no
        # outgoing links, no sprite" case and now legitimately carries one. The
        # gate still has to hold somewhere, or a page could name a symbol the
        # sprite never defines and draw a mark invisible to a screenshot; the
        # 404 is the page that draws no mark at all, having neither a margin
        # nor links.
        assert 'class="mark-sprite"' in page
        assert 'class="mark-sprite"' in served("/on-boundaries"), \
            "a note's own maturity mark ships without its sprite"
        assert 'class="mark-sprite"' not in served("/404.html"), \
            "the mark sprite ships on a page that draws no mark"
        assert 'class="mark-sprite"' in served("/"), \
            "the home page's table-of-contents links should carry marks"

    with subtest("the stylesheet draws the marks and their topic hues"):
        # The marks are a visual element whose absence a build cannot report,
        # so the stylesheet half is pinned like the callout icons: the glyph
        # is sized and reads its hue from the --topic variable, the two named
        # shelves carry their hues, and the same-page link is dotted - none
        # of which a green gate would catch.
        assert re.search(r'\.mark\s*{[^}]*width', css), "the mark glyph is not sized"
        assert re.search(r'\.mark\s*{[^}]*color:\s*var\(--topic,\s*var\(--muted\)\)', css), \
            "the mark no longer reads its hue from the topic variable"
        assert re.search(r'a\.link-section\s*{[^}]*text-decoration-style:\s*dotted', css), \
            "the same-page link is no longer dotted"

        # The hue RING. The stylesheet used to name two shelves - green for
        # `slip-box`, orange for `lighting` - and every other folder fell
        # through to --muted, so publishing from a new folder was a code
        # change. It is now eight numbered slots, and publish-filter.py hands
        # one to each shelf from a hash of the shelf's name.
        #
        # The whole ring is pinned, because a missing slot is invisible until
        # a shelf happens to hash to it: the failure is one shelf silently
        # grey, months after the edit that caused it, on a vault the author of
        # the edit did not have.
        for slot in range(8):
            assert re.search(rf'\.hue-{slot}\s*{{[^}}]*--topic:\s*light-dark\(', css), \
                f"the hue ring has no slot {slot}"
        # The two the vault publishes from today keep the colours they have
        # always had. The ring's ORDER is arbitrary - slots go out by hash -
        # so it was chosen to land these two where they already were, and
        # this is the assertion that says so on purpose.
        assert re.search(r'\.hue-4\s*{[^}]*--topic:\s*light-dark\(#6f894e,\s?#98bb6c\)', css), \
            "slip-box hashes to slot 4, which is no longer green"
        assert re.search(r'\.hue-2\s*{[^}]*--topic:\s*light-dark\(#cc6d00,\s?#ff9e3b\)', css), \
            "lighting hashes to slot 2, which is no longer orange"
        # And no slot may be one of Kanagawa's yellows. They are within a few
        # percent of the trunk's own boatYellow1, so a shelf drawn in one puts
        # foliage and wood in a single colour and the tree loses its
        # structure. That is why the ring is eight hues and not nine.
        assert not re.search(r'--topic:\s*light-dark\(#77713f|--topic:[^;]*#e6c384', css), \
            "a hue slot has been given a yellow, which is the trunk's own colour"
        # The old named rules are gone, not merely unused: leaving one behind
        # would beat the ring for any shelf it named, and only for that shelf.
        # Matched as a RULE - the selector with its brace - because the
        # stylesheet ships its comments, and the block above names both of the
        # rules it replaced in prose.
        assert not re.search(r'\.topic-[a-z-]+\s*{', css), \
            "a shelf is still coloured by name rather than by its ring slot"

    with subtest("a changed note's revision counter advances, its neighbours' do not"):
        # The ledger counts substantial rewrites per note: editing a note's
        # text changes its stored hash, which advances that note's `revisions`
        # by one and nobody else's. The fixture vault has no git history, so
        # every counter was seeded at zero on the first build.
        ledger = json.loads(machine.succeed("cat /var/lib/digital-garden/dates.json"))
        assert ledger["on-money"]["revisions"] == 0, ledger["on-money"]

        machine.succeed(
            "printf '\\nMARKER-REVISED-BODY\\n' >> /var/lib/digital-garden/vault/_Reference/Lighting/on-money.md"
        )
        machine.succeed("systemctl start digital-garden-build.service")

        # The watcher may also fire a build a few seconds later; it runs the
        # same filter over the same state, so the counter settles at 1 either
        # way - the second run sees the hash it recorded and bumps nothing.
        ledger = json.loads(machine.succeed("cat /var/lib/digital-garden/dates.json"))
        assert ledger["on-money"]["revisions"] == 1, (
            f"on-money revisions did not advance: {ledger['on-money']}"
        )
        for neighbour in ["on-gates", "on boundaries", "on-sidenotes"]:
            assert ledger[neighbour]["revisions"] == 0, (
                f"{neighbour} revisions moved while its text did not: "
                f"{ledger[neighbour]}"
            )

    with subtest("the bonsai carries every published note and nothing else"):
        # Item 18. The tree's whole claim is that it is a picture of the
        # garden, so the property worth testing is not that it renders - it is
        # that every published note is on it, exactly once as an identity and
        # at least once as something a reader can point at.
        #
        # bonsai.py asserts the same thing at build time, which is what caught
        # the two bugs recorded in the plan (a branch whose fork point landed
        # past the end of the trunk, and a pad every cell of which fell on
        # occupied ground). This is that assertion from the outside: on the
        # served page, where a mistake in the markup or in the template would
        # also show up.
        # Counted from the staging tree rather than written down, because the
        # subtests above have already published a note the fixture did not
        # start with - and "every published note" is the claim, so the number
        # has to come from what is published at this moment.
        staged = machine.succeed("ls /var/lib/digital-garden/content/*.md").split()
        # Less the landing page: a table of contents is not foliage on its own
        # tree, the same rule that keeps it out of the backlink graph.
        expected = len([p for p in staged if not p.endswith("/index.md")])

        home = served("/")
        on_tree = set(re.findall(r'<span class="leaf[^"]*" data-note="(\d+)"', home))
        assert len(on_tree) == expected, (
            f"{len(on_tree)} notes on the tree, {expected} published"
        )

        # One caption per note, and every pad's index resolves to one - the
        # caption is what the hover names, and a pad pointing at a caption that
        # is not there would be a dead cell on the tree.
        captions = set(re.findall(r'<span data-note="(\d+)" data-url="([^"]+)"', home))
        assert len(captions) == expected, captions
        assert {index for index, _ in captions} == on_tree, (captions, on_tree)
        # And each caption points at a page that exists, since a click on the
        # foliage goes there.
        for _, url in captions:
            served(url)

        # An enhancement, not a route. The tree carries no headings, no links
        # and no tab stops; /notes/ is the accessible path and it is complete.
        #
        # Matched on the tag's attributes rather than on the whole opening tag
        # written out: the `--cols` below is the second attribute to live here
        # and an exact string is a check that breaks every time one is added,
        # which is a check that tests the spelling rather than the claim.
        opening = re.search(r'<pre class="bonsai"[^>]*>', home)
        assert opening, home[:400]
        assert 'aria-hidden="true"' in opening.group(0), opening.group(0)

        # And the tree says how wide it is, because the stylesheet sizes the
        # type from it - `font-size: 100cqi / (--cols * advance)` - and only
        # the generator can count the columns. This is asserted rather than
        # trusted because losing it fails SILENTLY: the rule has a default, so
        # a tree with no `--cols` still renders, at the wrong size, filling
        # neither its column nor the header's width. Nothing errors and the
        # only symptom is a picture that stops short of its own rule, which is
        # the fault this whole pass exists to fix.
        cols = re.search(r"--cols:\s*(\d+)", opening.group(0))
        assert cols, opening.group(0)

        # The number is the tree's real width, not just some number. Rows are
        # right-stripped in `to_html`, and `_crop` guarantees the rightmost
        # column has ink in at least one row, so the longest row is exactly
        # the grid's width.
        drawn = home[opening.end() : home.index("</pre>", opening.end())]
        widest = max(
            len(html.unescape(re.sub(r"<[^>]+>", "", line)))
            for line in drawn.split("\n")
        )
        assert int(cols.group(1)) == widest, (
            f"the tree says it is {cols.group(1)} columns wide and draws {widest}"
        )

        # The markup is a fragment of the home page, not a page. Hugo must
        # never have seen it as content.
        machine.fail(f"test -e {SITE}/bonsai.html")
        machine.fail(f"test -e {SITE}/bonsai/index.html")

        # And the caption store is outside <article>, so Pagefind - which
        # indexes the element marked data-pagefind-body - does not put every
        # note's title into the home page's search entry. Asserted on the
        # index rather than on the page, because that is where it would show.
        assert home.index('class="bonsai-notes"') < home.index("data-pagefind-body"), (
            "the bonsai's caption store is inside the indexed article"
        )

    with subtest("the colophon counts the garden the tree grew from"):
        # Item 19. The line under the name is item 14's model read back off the
        # frontmatter the filter wrote, so the property worth pinning is not
        # that it renders - it is that it agrees with what is published. A
        # colophon claiming eighteen notes where nineteen are published is
        # wrong in exactly the way a screenshot cannot show, and the way it
        # would go wrong is the page set: site.RegularPages must be the notes,
        # with the landing page and the generated /notes/ index outside it.
        #
        # Counted from the staging tree for the same reason the tree above is:
        # earlier subtests have already published a note the fixture did not
        # start with.
        stages = []
        staged = machine.succeed("ls /var/lib/digital-garden/content/*.md").split()
        for note in staged:
            # Not a note it counts, the same rule that keeps the landing page
            # off the tree and out of the backlink graph.
            if note.endswith("/index.md"):
                continue
            head = machine.succeed(f"sed -n '1,25p' {note}")
            stage = re.search(r"^maturity: (\w+)$", head, re.M)
            assert stage, f"{note} has no maturity to count:\n{head}"
            stages.append(stage.group(1))

        home = served("/")
        line = re.search(r'<p class="colophon">(.*?)</p>', home, re.S)
        assert line, "no colophon on the home page"
        counted = re.search(
            r"(\d+) notes? &middot;\s*(\d+) evergreen &middot;\s*"
            r"(\d+) growing &middot;\s*(\d+) seedlings?",
            line.group(1),
        )
        assert counted, f"the colophon does not read as a count: {line.group(1)!r}"
        assert [int(n) for n in counted.groups()] == [
            len(stages),
            stages.count("evergreen"),
            stages.count("sapling"),
            stages.count("seedling"),
        ], (counted.groups(), stages)
        # Not vacuous: on-money's hand-written `maturity: evergreen` is the
        # only thing that puts a note in that column, so a colophon counting
        # computed stages instead of published ones would read zero here.
        assert int(counted.group(2)) >= 1, "the hand-written evergreen is not counted"

    with subtest("one masthead, on every page, and the tree on the home page alone"):
        # Item 21. The site had two headers - this bar on the interior pages
        # and a composition of its own on the landing page, carrying the same
        # name at twice the size - so the row at the top of the window changed
        # height on the commonest journey the site has. There is now one bar,
        # rendered by baseof.html for every page, and what is left on the home
        # page is the picture.
        #
        # Still one site title per page. On the home page the name is that
        # page's <h1>: the landing page's own title was removed with the
        # composition, and the site's name is what the page is about, so it
        # takes the heading rather than the page having none.
        home = served("/")
        assert '<h1 class="masthead-title">' in home, home[:400]
        assert home.count("masthead-title") == 1, (
            "the home page carries the site title twice"
        )
        assert not re.search(r'<article[^>]*>\s*<h1', home), (
            "the landing page still opens with a title of its own"
        )
        # And the tree is outside the indexed article, for the reason the
        # bonsai's caption store is: a search for the site would otherwise
        # return the home page for the words "notes evergreen growing".
        assert home.index('class="garden"') < home.index("data-pagefind-body"), (
            "the tree is inside the indexed article"
        )

        # The masthead's link list, and the placeholder rule. An entry with no
        # URL renders as muted text and not as a link, so a section can show
        # its shape before every destination exists - the alternative being a
        # 404 shipped on purpose. GitHub has a URL; Projects and Resume do not
        # yet.
        links = re.search(r'<ul class="masthead-links">(.*?)</ul>', home, re.S)
        assert links, "the header has no link list"
        # THE LINKS DROP, THEY DO NOT WRAP. On the old landing page the list
        # was allowed to fold onto a second line, which turned the bar into a
        # block on a phone - at the one width where the header should cost
        # least. The row is now fixed at one line and the links leave it one at
        # a time, from the left, as the bar narrows. The question is asked of
        # the BAR rather than of the viewport, because the bar is capped at the
        # measure and it is the bar that runs out of room.
        assert re.search(r'\.masthead\s*{[^}]*container-type:\s*inline-size', css), \
            "the masthead is not a container, so the link steps cannot be measured on it"
        assert re.search(r'@container[^{]*{\s*\.masthead-links', css), \
            "nothing drops a link when the bar runs out of room"
        assert not re.search(r'\.masthead-links\s*{[^}]*flex-wrap:\s*wrap', css), \
            "the masthead's links can wrap onto a second line again"
        assert re.search(
            r'<a href="https://github\.com/[^"]+">GitHub</a>', links.group(1)
        ), links.group(1)
        assert '<span class="link-placeholder">Resume</span>' in links.group(1), (
            "an entry with no URL is not rendered as a placeholder"
        )
        assert 'href=""' not in links.group(1), (
            "an entry with no URL is rendered as a link to nowhere"
        )
        # The same rule in the footer, which renders the same list: a
        # placeholder that was a link in one of the two places would be the
        # exact drift the shared list exists to prevent.
        footer = re.search(r"<footer.*?</footer>", home, re.S)
        assert footer, "the home page has no footer"
        assert '<span class="link-placeholder">Resume</span>' in footer.group(0), (
            footer.group(0)
        )

        essay = served("/on-gates/")
        # The same bar, with the name as a link rather than as a heading - an
        # interior page's <h1> is the note's own title - and with the same
        # links beside it, which is the half of item 21's blend that the
        # interior pages gained.
        assert '<a class="masthead-title"' in essay, essay[:400]
        assert '<h1 class="masthead-title">' not in essay, (
            "an interior page took the site's name as its heading"
        )
        assert re.search(r'<ul class="masthead-links">.*?GitHub', essay, re.S), (
            "an interior page's masthead carries no links"
        )
        # The bonsai is matched on its element rather than on the word: the
        # script that grows it is inlined on every page and names the plate it
        # looks for, and finding nothing is how it stays off an essay.
        for stray in ['class="garden"', 'class="colophon"', 'class="bonsai-plate"']:
            assert stray not in essay, f"an interior page rendered {stray}"

    with subtest("the home page's header and tree are anchored to the page's own grid"):
        # The home page's header used to share a CENTRE with the page and not a
        # single EDGE: at 1440px every interior masthead's rule ran from 400px
        # to 1040px, exactly the article column, and the landing page's ran
        # from 305px to 1135px. Nothing on the page lined up with either of its
        # ends, and a band that lines up with nothing reads as floating over
        # the page rather than as part of it. That is a geometry fault,
        # invisible to a grep and obvious in a screenshot, so it is measured
        # here.
        #
        # It is now the same masthead every page carries (item 21), which no
        # longer needs a rule of its own to reach those edges: `max-width:
        # var(--measure); margin-inline: auto` reduces to the article column's
        # own offset out here. That is arithmetic rather than a coincidence,
        # and this is what pins it - along with the tree beneath, which is held
        # to the same two lines by the same declaration.
        machine.succeed(
            "mkdir -p /tmp/np && "
            "cp /var/lib/digital-garden/public/index.html /tmp/np/page.html && "
            "cp /var/lib/digital-garden/public/main.*.css /tmp/np/"
        )
        machine.succeed(
            "cat > /tmp/np/probe.js <<'PROBE'\n"
            'function box(sel) {\n'
            '  var el = document.querySelector(sel);\n'
            '  if (!el) return "MISSING";\n'
            '  var r = el.getBoundingClientRect();\n'
            '  return Math.round(r.left) + "," + Math.round(r.right);\n'
            "}\n"
            'var marker = document.createElement("div");\n'
            'marker.id = "NP-MEAS";\n'
            'marker.textContent = "@@" + [box(".masthead"), box(".layout > article"),\n'
            '  box(".layout"), box(".garden")].join("|") + "@@";\n'
            'document.body.appendChild(marker);\n'
            "PROBE"
        )
        machine.succeed(
            "python3 - <<'PY'\n"
            "import re\n"
            'p = "/tmp/np/page.html"\n'
            "s = open(p).read()\n"
            'probe = open("/tmp/np/probe.js").read()\n'
            'css = re.search(r"main\\.[0-9a-f]+\\.css", s)\n'
            'assert css, "no fingerprinted stylesheet on the home page"\n'
            's = re.sub(r\'href="/main\\.[0-9a-f]+\\.css"\', \'href="\' + css.group(0) + \'"\', s)\n'
            's = s.replace("</body>", "<script>" + probe + "</" + "script>" + "</body>", 1)\n'
            'open(p, "w").write(s)\n'
            "PY"
        )
        dom = machine.succeed(
            "chromium --headless=new --no-sandbox --disable-gpu "
            "--disable-dev-shm-usage --allow-file-access-from-files "
            "--virtual-time-budget=30000 --window-size=1600,1200 "
            "--dump-dom file:///tmp/np/page.html 2>/dev/null"
        )
        m = re.search(r'id="NP-MEAS">@@(.*?)@@', dom, re.S)
        assert m, "the masthead probe never ran"
        parts = m.group(1).split("|")
        assert "MISSING" not in parts, f"the probe could not find a box: {parts}"
        header, article, grid, tree = [
            tuple(int(n) for n in part.split(",")) for part in parts
        ]
        # A pixel of slack, because a fractional layout rounds.
        assert abs(header[0] - article[0]) <= 1, (
            f"the header does not begin on the prose's left edge: {header} vs {article}"
        )
        assert abs(header[1] - article[1]) <= 1, (
            f"the header does not end on the prose's right edge: {header} vs {article}"
        )
        # The tree under it spans the same column, so the picture begins and
        # ends where every line of prose begins and ends.
        assert abs(tree[0] - article[0]) <= 1 and abs(tree[1] - article[1]) <= 1, (
            f"the tree does not span the prose column: {tree} vs {article}"
        )
        # And the page is genuinely in its wide layout, so that the three
        # assertions above are about the anchored header and not about a
        # narrow page where everything is one centred column anyway.
        assert grid[1] - article[1] > 100, (
            f"the page is not in its wide layout: article {article}, grid {grid}"
        )

    with subtest("the masthead drops a link before it cuts the site's name"):
        # The name is the one item in the bar that can be squeezed, so the
        # order the bar gives way in is a property with a wrong answer: a
        # reader at 430px saw "Cory Gyarma..." with three links beside it,
        # which is the site's identity cut to keep its chrome. That shipped,
        # from container steps measured off a screenshot rather than off the
        # bar - the row needs 396.5px to hold two links and the second step
        # was set at 384.
        #
        # A screenshot cannot hold this still: it is true or false at every
        # width, and the failure lives in a forty-pixel window between two
        # steps. So the bar is swept in a real browser instead. One page load
        # measures a clone of the masthead inside a box of each width from
        # 280 to 720px - the clone carries `.masthead`, so it is its own
        # container and the @container steps resolve against the box - and
        # reports, for each width, whether the name's text is wider than the
        # box the name was given and whether the row overflows the bar.
        #
        # Both must be no, everywhere. Never cut says the links go first;
        # never overflow says the answer to "no room" is not a bar hanging off
        # the page, which is what a name that could not shrink at all would
        # do. The step widths are reported so a failure says which one moved.
        machine.succeed(
            "mkdir -p /tmp/bar && "
            "cp /var/lib/digital-garden/public/index.html /tmp/bar/page.html && "
            "cp /var/lib/digital-garden/public/main.*.css /tmp/bar/"
        )
        machine.succeed(
            "cat > /tmp/bar/sweep.js <<'SWEEP'\n"
            'var bar = document.querySelector(".masthead");\n'
            'var host = document.createElement("div");\n'
            'host.style.cssText = "position:absolute;left:-9999px;top:0";\n'
            "document.body.appendChild(host);\n"
            "var rows = [];\n"
            "for (var w = 280; w <= 720; w += 2) {\n"
            '  var box = document.createElement("div");\n'
            '  box.style.cssText = "width:" + w + "px";\n'
            "  var clone = bar.cloneNode(true);\n"
            "  clone.querySelectorAll('[id]').forEach(function (el) {\n"
            '    el.removeAttribute("id");\n'
            "  });\n"
            "  box.appendChild(clone);\n"
            "  host.appendChild(box);\n"
            '  var t = clone.querySelector(".masthead-title");\n'
            "  var links = Array.prototype.filter.call(\n"
            "    clone.querySelectorAll('.masthead-links > li'),\n"
            "    function (li) { return li.offsetParent !== null; }\n"
            "  );\n"
            "  rows.push([w, links.length, t.scrollWidth - t.clientWidth,\n"
            '    clone.scrollWidth - clone.clientWidth].join(","));\n'
            "  host.removeChild(box);\n"
            "}\n"
            'var marker = document.createElement("div");\n'
            'marker.id = "BAR-SWEEP";\n'
            'marker.textContent = "@@" + rows.join(";") + "@@";\n'
            "document.body.appendChild(marker);\n"
            "SWEEP"
        )
        machine.succeed(
            "python3 - <<'PY'\n"
            "import re\n"
            'p = "/tmp/bar/page.html"\n'
            "s = open(p).read()\n"
            'sweep = open("/tmp/bar/sweep.js").read()\n'
            'css = re.search(r"main\\.[0-9a-f]+\\.css", s)\n'
            'assert css, "no fingerprinted stylesheet on the home page"\n'
            's = re.sub(r\'href="/main\\.[0-9a-f]+\\.css"\', \'href="\' + css.group(0) + \'"\', s)\n'
            's = s.replace("</body>", "<script>" + sweep + "</" + "script>" + "</body>", 1)\n'
            'open(p, "w").write(s)\n'
            "PY"
        )
        dom = machine.succeed(
            "chromium --headless=new --no-sandbox --disable-gpu "
            "--disable-dev-shm-usage --allow-file-access-from-files "
            "--virtual-time-budget=30000 --window-size=1600,1200 "
            "--dump-dom file:///tmp/bar/page.html 2>/dev/null"
        )
        m = re.search(r'id="BAR-SWEEP">@@(.*?)@@', dom, re.S)
        assert m, "the masthead sweep never ran"
        cut, overflow, steps, previous = [], [], [], None
        for row in m.group(1).split(";"):
            width, shown, clipped, over = (int(n) for n in row.split(","))
            if clipped > 0:
                cut.append((width, shown, clipped))
            if over > 0:
                overflow.append((width, shown, over))
            if previous is not None and shown != previous:
                steps.append((width, previous, shown))
            previous = shown
        assert steps, "no width in the sweep changes how many links are shown"
        assert not cut, (
            f"the name is cut while links are still shown: {cut[:5]}; steps {steps}"
        )
        assert not overflow, (
            f"the bar overflows rather than dropping a link: {overflow[:5]}; steps {steps}"
        )

    with subtest("a renamed note keeps its publication date"):
        # The ledger is keyed by the note's filename, so a rename used to
        # look like a brand-new note: the old key disappears, the new key
        # has no entry, and `published` silently reset to today. That is the
        # defect this pins, and it is pinned by giving the note a date that
        # is NOT today first.
        #
        # The first build dated every note today, so a naive "rename and
        # assert the date is unchanged" would pass with or without the fix -
        # a reset lands on today and today is what the note already had. The
        # ledger is therefore seeded with a past date before the rename, and
        # the assertion is that the renamed note still carries it.
        machine.succeed(
            "python3 - <<'PY'\n"
            "import json\n"
            'ledger = json.load(open("/var/lib/digital-garden/dates.json"))\n'
            'assert "on-gates" in ledger, ledger\n'
            'ledger["on-gates"]["published"] = "2001-01-01"\n'
            'json.dump(ledger, open("/var/lib/digital-garden/dates.json", "w"))\n'
            "PY"
        )

        # Rename the note in the vault. The rename changes both gates (the
        # file list and the content tree), so the builder runs the filter
        # rather than skipping. The watcher may also fire a build a few
        # seconds later; it runs the same filter over the same state, so the
        # result is the same either way.
        machine.succeed(
            "mv /var/lib/digital-garden/vault/essays/on-gates.md "
            "/var/lib/digital-garden/vault/essays/on-gates-renamed.md"
        )
        machine.succeed("systemctl start digital-garden-build.service")

        # The renamed note keeps the seeded date, in the ledger and on the
        # page a reader sees.
        ledger = json.loads(machine.succeed("cat /var/lib/digital-garden/dates.json"))
        assert "on-gates-renamed" in ledger, ledger.keys()
        assert ledger["on-gates-renamed"]["published"] == "2001-01-01", (
            f"renamed note was re-dated: {ledger['on-gates-renamed']}"
        )
        assert "on-gates" not in ledger, "the old key lingered after the rename"
        page = served("/on-gates-renamed")
        assert 'datetime="2001-01-01"' in page, page[-400:]

        # ONE DATE ON A NOTE, at the narrow width (item 21). The seeding above
        # makes this the fixture's only note whose edit date differs from its
        # publication date, so it is the only place the rule can be seen: the
        # line under the title carries the EDIT and drops the publication,
        # because four facts and two dates are wider than a phone and the
        # wrapped second line pushed the essay down by a whole row at exactly
        # the width where vertical space is scarcest. The margin has a column
        # to spend and still carries both.
        line = re.search(r'<p class="dateline">(.*?)</p>', page, re.S)
        assert line, "the renamed note has no dateline"
        line = line.group(1)
        assert "updated" in line, (
            f"the note's dateline dropped the edit rather than the publication:\n{line}"
        )
        assert 'datetime="2001-01-01"' not in line, (
            f"the note's dateline carries both dates and so can wrap:\n{line}"
        )
        facts = re.search(r'<dl class="margin-facts">(.*?)</dl>', page, re.S)
        assert facts and 'datetime="2001-01-01"' in facts.group(1), (
            "the margin lost the publication date"
        )
  '';
}
