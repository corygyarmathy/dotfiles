# The garden builds a real vault, publishes only what is marked, and serves it.
#
# This is the one place where the build gate is not merely silent but actively
# misleading. Everywhere else a runtime failure at least fails: a bad Caddyfile
# stops Caddy, a bad Prometheus config stops Prometheus. Here the failure mode
# is a build that *succeeds*. Quartz responds to a plugin it cannot instantiate
# by leaving an undefined in the component list, and a plugin index regenerated
# without dist/ yields a featureless site - so the build is green, activation
# is clean, the timer runs, the service exits 0, and the site is empty or
# unstyled. Green CI becomes positive evidence for something false.
#
# Two properties are worth more than "it built".
#
# The publish boundary is the important one, and the only property in this
# repository whose failure has consequences outside it. digital-garden.nix
# calls publish-filter.py the boundary and Quartz's explicit-publish plugin
# defence in depth. A test that only checked the published note was present
# would pass just as happily if the filter had copied the entire vault, so the
# assertions below are written the other way round: the private markers must
# appear nowhere in the served tree, including the search index and the feed,
# which are the two places a leak would actually surface.
#
# The second is that the site has features. `index.css` being substantial and
# the plugin-generated artefacts existing are what separate a real build from
# the silent-failure mode above - the module's own comment warns that
# overwriting custom.scss instead of appending to it drops every base rule and
# still builds, deploys and serves, as nearly unstyled prose.
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

      # A Quartz build is an esbuild pass over a Node tree, not a service
      # waiting on a port. It is the one test here that needs real headroom.
      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 8192;
    };

  testScript = ''
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
        machine.succeed(f"test -f {SITE}/index.css")

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
        machine.fail(f"test -e {SITE}/no-frontmatter-at-all.html")

    with subtest("the staging tree is plain CommonMark"):
        # The filter converts wikilinks so that the generator never has to
        # understand Obsidian, which is what makes the generator replaceable.
        # Asserted on the staging tree AND on the served site: a surviving
        # wikilink renders as the literal text "[[Some Note]]" on the page,
        # which is a build that succeeds and a site that is wrong.
        machine.fail("grep -rq -e '[[' /var/lib/digital-garden/content")
        machine.fail(f"grep -rq -e '[[' {SITE}")

    with subtest("a link to a published note is a real link"):
        page = machine.succeed(f"cat {SITE}/on-gates.html")
        assert 'href="./on-boundaries"' in page, "published link did not survive as a link"
        # The alias is what the reader sees, not the filename.
        assert "the boundary essay" in page

        # A list item that is nothing but a link gets the target's thesis
        # appended, so a hub page reads as claims. This is matched against the
        # rewritten Markdown link rather than the wikilink it started as, and
        # if that pattern stopped matching, every index would quietly lose its
        # annotations while the build stayed green.
        assert "MARKER-THESIS-BOUNDARIES" in page, "thesis was not appended to the bare link"

    with subtest("a link to an unpublished note is not a link"):
        page = machine.succeed(f"cat {SITE}/on-gates.html")
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
        assert "url=../on-gates" in served("/essays/on-gates")

    with subtest("the build has features, not just output"):
        # The silent-failure mode this test exists for. digital-garden.nix
        # appends to quartz/styles/custom.scss precisely because that file
        # carries the `@use "./base.scss"` that pulls in the entire base
        # stylesheet; overwrite it instead and the site still builds, still
        # deploys, and serves as nearly unstyled prose.
        #
        # Asserted on specific selectors rather than on size, which was the
        # first attempt and does not work: overwriting custom.scss takes
        # index.css from 59KB to 40KB, because every other component
        # stylesheet still compiles. A threshold loose enough not to be
        # brittle sits well below 40KB and therefore catches nothing.
        # These three come from base.scss and nowhere else - the flex helpers
        # the module's own comment names as load-bearing for the layout.
        css = served("/index.css")
        for selector in [".flex-component", ".desktop-only", ".table-container"]:
            assert selector in css, f"{selector} missing - base.scss was not pulled in"

        # Plugin-generated artefacts. If the plugin index regenerated empty -
        # the exact failure the module guards against with its grep for
        # CustomOgImagesEmitterName - the build still succeeds and these
        # quietly stop being emitted.
        assert "MARKER-PUBLISHED-BODY" in served("/static/contentIndex.json")
        assert "on-gates" in served("/index.xml")
        assert "on-gates" in served("/sitemap.xml")
        assert "MARKER-BOUNDARIES-BODY" in served("/on-boundaries")

    with subtest("caddy serves the generated 404 rather than its own"):
        # try_files plus handle_errors in the module's vhost. Quartz emits a
        # styled 404; without the handler Caddy answers with an empty one.
        machine.fail("curl -sf http://localhost:8086/no-such-note")
        assert len(machine.succeed("curl -s http://localhost:8086/no-such-note")) > 1000
  '';
}
