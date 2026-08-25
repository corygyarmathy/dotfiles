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
      # notes, so this needs very little. Still well above what the run uses,
      # because a test that fails by running out of memory does not say so
      # clearly.
      virtualisation.memorySize = 2048;
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
        assert staged == ["index.md", "on-boundaries.md", "on-gates.md", "on-money.md"], staged

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
  '';
}
