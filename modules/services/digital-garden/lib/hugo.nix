# How the digital garden is generated:
#
#   digital-garden-render-hugo <content-dir> <output-dir> [stylesheet]
#
# The property to preserve here is that the whole toolchain is two static
# binaries from nixpkgs — Hugo in Go, Pagefind in Rust — both riding
# flake.lock, neither fetching anything at build time or in the reader's
# browser. A generator that resolves plugins over the network at build time
# fails in the one way a CI gate cannot see: the build succeeds and the site is
# quietly missing features. Anything added below should be weighed against
# that, not against convenience. See docs/adr/ for how this was arrived at.
#
# What keeps this file short is that publish-filter.py already owns the hard
# parts. The staging tree's links carry finished URLs and its files are named
# what they will be served as, so this renderer does not have to resolve a
# wikilink or decide what a page is called. It supplies a layout and a
# stylesheet and gets out of the way. Everything Hugo-specific is in this
# file and lib/hugo/.
#
# Two Obsidian-isms DO reach the renderer, both deliberately, because Hugo's
# parser understands them natively and any CommonMark renderer degrades them
# gracefully: callouts (> [!type], rendered by _markup/render-blockquote.html)
# and $...$ maths (captured by the passthrough extension and rendered to HTML
# at build time by _markup/render-passthrough.html). KaTeX's stylesheet and
# fonts are vendored from nixpkgs below, so a page with equations still needs
# no JavaScript and nothing fetched from anyone else's server.
{
  pkgs,
  lib,
}:
let
  theme = ./hugo;

  # The heading face, vendored on exactly the terms KaTeX is: taken from a
  # package that rides flake.lock, reduced here, and served as an ordinary
  # static file. Nothing is fetched at build time and nothing is fetched by the
  # reader's browser — which is the property this whole file exists to hold, and
  # the reason a webfont is affordable at all. A CDN link would have been one
  # line and would have made every reader's page load depend on Google.
  #
  # Noto Serif ships as a 1.9MB variable TTF: every weight from 100 to 900, and
  # a glyph for very nearly every language Noto covers. Two reductions get that
  # to ~29KB, which is the budget the plan set.
  #
  #   1. Instance the variable axes at the ONE weight the headings use. This is
  #      the big one: `gvar`, the table describing how every glyph deforms
  #      across the weight axis, is two thirds of the file and it goes entirely.
  #   2. Subset the glyphs to Latin plus the punctuation these notes contain.
  #      The range is Google Fonts' own `latin` subset, which is what a heading
  #      in English with an em dash and a curly quote in it needs.
  #
  # If a note ever takes a heading outside this range, the browser falls back to
  # the body stack for that heading rather than showing tofu — the same
  # degradation the site had before the face existed.
  headingFont =
    pkgs.runCommand "noto-serif-latin-600.woff2"
      {
        nativeBuildInputs = [
          pkgs.python3Packages.fonttools
          pkgs.woff2
        ];
      }
      ''
        fonttools varLib.instancer -o instance.ttf \
          ${pkgs.noto-fonts}/share/fonts/noto/NotoSerif.ttf wght=600
        pyftsubset instance.ttf --output-file=subset.ttf --no-hinting \
          --unicodes='U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+2074,U+20AC,U+2122,U+2190-2193,U+2212,U+2215,U+FEFF,U+FFFD'
        woff2_compress subset.ttf
        cp subset.woff2 $out
      '';
in
{
  mkRenderer =
    {
      baseUrl,
      siteTitle,
      siteDescription ? "",
      styleSheet,
      footerLinks ? { },
      locale ? "en-au",
    }:
    let
      config = pkgs.writeText "hugo.toml" ''
        baseURL = 'https://${baseUrl}/'
        locale = '${locale}'
        title = ${builtins.toJSON siteTitle}
        enableRobotsTXT = true

        # publish-filter.py derives dates from its ledger as bare local dates,
        # and Hugo reads a bare date as midnight UTC. Anywhere behind UTC that
        # puts a note published "today" up to a day in the future, and Hugo
        # omits future content by default — which silently cost 15 of 16 pages
        # the first time this was built. There is no scheduled publishing here:
        # a date is metadata about a note, not an embargo on it.
        buildFuture = true

        # Nothing here is organised by tag, and an empty taxonomy listing is
        # just another URL that has to be explained.
        disableKinds = ['taxonomy', 'term']

        [frontmatter]
        date = ['published', 'date']
        # `date` last, so a note that was never edited reports its publication
        # date as its last change rather than no date at all. Without it the
        # feed's lastBuildDate and the sitemap's <lastmod> were empty, because
        # publish-filter.py only writes `modified` when it differs from
        # `published`. The dateline and the social card both compare the two
        # and stay quiet when they are equal, so nothing starts claiming a note
        # was updated on the day it was published.
        lastmod = ['modified', 'lastmod', 'date']

        # Chroma writes its colours inline by default, which hard-codes one
        # theme into the markup: every fenced block shipped Monokai's #272822
        # ground and #f8f8f2 text regardless of what the reader had chosen.
        # That was invisible while the site's dark theme was near-black, and
        # became a black box in the middle of a warm page the moment the light
        # theme stopped being white. Classes instead, so the stylesheet colours
        # code the same way it colours everything else - and so the theme
        # toggle reaches it, which inline styles never allowed.
        [markup.highlight]
        noClasses = false

        [markup.goldmark.renderer]
        # The vault contains no raw HTML, only autolinks — which are CommonMark
        # and unaffected by this. Left off so a note cannot put markup, or a
        # script, onto a public page.
        unsafe = false

        [markup.goldmark.extensions.extras.mark]
        # Obsidian's ==highlights==. Off by default; without this the markers
        # render as literal text.
        enable = true

        [markup.goldmark.extensions.passthrough]
        # Captures $...$ and $$...$$ verbatim so _markup/render-passthrough.html
        # can hand them to Hugo's embedded KaTeX instance. The delimiters are
        # Obsidian's, which is the point: a note reads the same in both places.
        # The cost of the inline one is Obsidian's too — a literal $ in prose
        # between two $s is maths to both — so this changes nothing about how
        # notes are written.
        enable = true
        [markup.goldmark.extensions.passthrough.delimiters]
        block = [['$$', '$$']]
        inline = [['$', '$']]

        [params]
        description = ${builtins.toJSON siteDescription}
        footerLinks = [
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: url: "  { name = ${builtins.toJSON name}, url = ${builtins.toJSON url} },"
          ) footerLinks
        )}
        ]
      '';
    in
    pkgs.writeShellApplication {
      name = "digital-garden-render-hugo";
      runtimeInputs = [
        pkgs.hugo
        pkgs.pagefind
        pkgs.coreutils
      ];
      text = ''
        if [ $# -lt 2 ] || [ $# -gt 3 ]; then
          echo "usage: digital-garden-render-hugo <content-dir> <output-dir> [stylesheet]" >&2
          exit 2
        fi
        content=$(realpath "$1")
        outdir=$2
        css=$(realpath "''${3:-${styleSheet}}")

        if [ ! -d "$content" ]; then
          echo "no such content directory: $content" >&2
          exit 1
        fi
        rm -rf "$outdir"
        mkdir -p "$outdir"
        outdir=$(realpath "$outdir")

        # Hugo wants a site directory. Assembled per run rather than kept,
        # because every input is either in the store or handed in as an
        # argument, so there is nothing here worth preserving between builds.
        work=$(mktemp -d --tmpdir digital-garden-hugo.XXXXXX)
        trap 'rm -rf "$work"' EXIT

        cp -r ${theme}/layouts "$work/layouts"
        mkdir -p "$work/assets"
        cp "$css" "$work/assets/main.css"
        cp ${config} "$work/hugo.toml"
        chmod -R u+w "$work"

        # KaTeX's stylesheet and fonts, vendored from nixpkgs and served as
        # ordinary static files. Pages with equations render maths to HTML at
        # build time (see _markup/render-passthrough.html), so this is ALL the
        # reader's browser ever sees of KaTeX - no script. baseof.html links
        # the stylesheet only on pages that used maths, so a reading page
        # never pays for it.
        mkdir -p "$work/static/katex"
        cp ${pkgs.katex}/lib/node_modules/katex/dist/katex.min.css "$work/static/katex/"
        cp -r ${pkgs.katex}/lib/node_modules/katex/dist/fonts "$work/static/katex/fonts"

        # The heading face, subset above. One file, one weight, on every page:
        # unlike KaTeX there is no test for "did this page use it", because
        # every page has a title.
        mkdir -p "$work/static/fonts"
        cp ${headingFont} "$work/static/fonts/noto-serif-latin.woff2"

        # Store paths copy out read-only, and the exit trap's rm -rf cannot
        # remove a read-only directory's contents.
        chmod -R u+w "$work/static"

        mkdir -p "$work/content"
        cp -r "$content/." "$work/content/"
        chmod -R u+w "$work/content"
        # Hugo's home page comes from `_index.md`; a plain `index.md` at the
        # content root would make the whole site one leaf bundle instead. The
        # filter has no business knowing that, so the rename happens here.
        if [ -f "$work/content/index.md" ]; then
          mv "$work/content/index.md" "$work/content/_index.md"
        fi

        # Not --quiet: this runs inside a oneshot service whose journal is the
        # only place a failure surfaces. A quiet hugo turned "KaTeX could not
        # render this expression" into two silent seconds and exit 1.
        hugo --source "$work" --destination "$outdir"

        # Search index, built from the rendered HTML rather than from the
        # markdown, so what is searchable is exactly what is readable. Runs
        # here rather than as a separate step because a site whose index does
        # not match its pages is worse than one with no search at all.
        pagefind --site "$outdir"
      '';
    };
}
