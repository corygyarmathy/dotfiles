# The garden builds a real vault, publishes only what is marked, and serves it.
#
# The build gate is weak evidence here, and used to be actively misleading.
# Under Quartz the failure mode was a build that *succeeded*: a plugin it could
# not instantiate left an undefined in the component list, and a plugin index
# regenerated without dist/ yielded a featureless site - green CI, clean
# activation, service exits 0, and the site is empty or unstyled.
#
# Hugo removes most of that class. A template that does not resolve is a build
# error, and there are no plugins to resolve at all. What remains is that a
# *missing* template is not an error: Hugo skips the pages it would have
# rendered and reports success. The first Hugo build of this site emitted the
# home page and nothing else, and said "Total in 40 ms" while doing it.
#
# Two properties are therefore still worth more than "it built".
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
      # Three notes: one published, one deliberately not, and one that fails to
      # parse at all - because publish-filter.py's stated rules are that
      # publish defaults to false AND that an unparseable note is skipped
      # rather than published, and only the second of those is a fail-closed
      # claim worth testing.
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

        - [[On Boundaries]]
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

      # The 4096/8192 this used to ask for was sized for a Quartz build: an
      # esbuild pass over a ~19MB Node tree. Hugo and Pagefind are two static
      # binaries rendering sixteen notes, so the headroom went with the reason
      # for it. Still above what the run needs, because a test that fails by
      # running out of memory does not say so clearly.
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
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
        # moment it succeeds, and the minutely timer makes "has it run yet"
        # a race. This also asserts a *second* run is clean, since the timer
        # has almost certainly fired once already.
        machine.succeed("systemctl start digital-garden-build.service")
        # index.html, not the stylesheet: Hugo fingerprints its CSS, so the
        # stylesheet has no fixed name to test for. It is checked by URL below,
        # read off the page that links it.
        machine.succeed(f"test -f {SITE}/index.html")

    with subtest("only published notes are in the staging tree"):
        # The boundary is publish-filter.py, and it works by never copying an
        # unpublished note - so the check that matches the design is on what
        # the staging tree Quartz is pointed at contains, not on what renders.
        #
        # The names are the slugs, not the vault's filenames: the filter owns
        # the URL, and a file staged under any other name would mean the
        # generator was deciding the address after all.
        staged = sorted(machine.succeed("ls /var/lib/digital-garden/content").split())
        assert staged == ["on-boundaries.md", "on-gates.md"], staged

    with subtest("no unpublished content reaches the served site"):
        # Deliberately the whole tree rather than the rendered page. A leak
        # would most plausibly surface in static/contentIndex.json (the search
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
        # Matched loosely on the form of the href, because whether it comes out
        # absolute or relative is the generator's business; that it is a link
        # to the right page is not.
        assert re.search(r'href="\.?/on-boundaries/?"', page), \
            "published link did not survive as a link"
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
        # The redirect target is matched loosely: Quartz wrote it relative and
        # Hugo writes it absolute against baseURL. Which one is not the point;
        # that the old address still leads to the new one is.
        redirect = served("/essays/on-gates")
        assert re.search(r"url=\S*/on-gates", redirect), redirect[:300]

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
        for selector in [".masthead", ".page", "--pagefind-ui-border"]:
            assert selector in css, f"{selector} missing from the stylesheet"

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

    with subtest("the feed and sitemap are generated"):
        assert "on-gates" in served("/index.xml")
        assert "on-gates" in served("/sitemap.xml")

    with subtest("caddy serves the generated 404 rather than its own"):
        # try_files plus handle_errors in the module's vhost. Hugo emits a
        # styled 404; without the handler Caddy answers with an empty one.
        machine.fail("curl -sf http://localhost:8086/no-such-note")
        assert len(machine.succeed("curl -s http://localhost:8086/no-such-note")) > 1000
  '';
}
