# Plan: theme and navigation for the digital garden

Status: proposed 2026-08-27; decisions taken the same day, see _Decisions_ below. Items 1, 2 and 4 were the agreed first pass; 5, 6 and 10 followed on the same day. Item 11 came out of a review on 2026-08-28 and is done. Item 3, the only item that fixed something broken today, was taken and is done on 2026-08-30. Two ideas asked for — a Kanagawa palette and a right-hand navigation column — plus seven more that came out of looking at what the site actually serves today. Everything below is scoped against `modules/services/digital-garden/lib/hugo/`, which is the whole design: four layouts, six partials, three render hooks and a 488-line stylesheet. There is no theme underneath to fight, so every item here is an edit to files this repository owns.

| #   | Item                                | Size   | Depends on | Status      |
| --- | ----------------------------------- | ------ | ---------- | ----------- |
| 1   | Rendering fixture + screenshot loop | small  | -          | **done** 2026-08-27 |
| 2   | Kanagawa palette                    | medium | 1          | **done** 2026-08-27 |
| 3   | An index of everything published    | small  | -          | **done** 2026-08-30 |
| 4   | Right-hand rail: contents, backlinks| medium | 1          | **done** 2026-08-27 |
| 5   | Link and image treatment            | small  | 2          | **done** 2026-08-27; the image mat reverted the same day |
| 6   | Typography                          | small  | 2          | built and **reverted** 2026-08-27 |
| 7   | Wikilink hover previews             | medium | -          | optional    |
| 8   | Footnotes as sidenotes              | large  | 4          | optional    |
| 9   | Reading time in the dateline        | small  | -          | optional    |
| 10  | Polish: print, selection, motion    | small  | 2          | **done** 2026-08-27 |
| 11  | Rendering gaps found by review      | small  | 1          | **done** 2026-08-28 |
| 12  | The dateline in the empty margin    | small  | 4          | not started |
| -   | Graph view                          | -      | -          | **rejected**, see below |

## Decisions, 2026-08-27

Taken against the rendered comparisons rather than the swatches, which is the point of item 1 existing before item 2.

- **The light theme is Lotus, lightened.** `#f2ecbc` mixed 45% toward white, `#f9f6e1`, with the surface, border and code-well tokens lightened to match. Option 1 of the three below. Lotus as specified is out: rendered at full width it is a buttery yellow that the Lighting notes' white-background diagrams have to fight.
- **Headings stay neutral.** `fujiWhite` in dark, `lotusInk2` in light. No `carpYellow`.
- **One hue per role, per the official scheme.** The first pass spent `--accent` (`crystalBlue`/`lotusBlue4`) everywhere that wanted emphasis, which read as a wall of blue across the masthead, every link, the default callout and the rail's "you are here". The official `themes.lua` never collapses roles like that — `fun`, `statement`, `diag.info` and visual selection each have their own hue, consistently in Wave and Lotus. So `--accent` was withdrawn to the roles the scheme gives it and the others were reassigned, keeping one hue per role in both themes (details below). This is the opposite of "fruit salad": fruit salad is arbitrary colouring, and this is systematic.**

  - **Links stay `--accent` (crystalBlue / lotusBlue4).** Links are the site's `fun` — the official scheme's function colour — and the affordance must be consistent. Unchanged.
  - **The masthead title becomes `--brand` (oniViolet / lotusViolet4).** The `statement`/`keyword` role, and this repository's own established secondary accent (rofi's `accent2`, waybar's `secondary`). A single site title reading as brand is not the "headings stay neutral" case — that decision was made for notes with twenty-nine headings, not a masthead, and the title is chrome rather than prose.
  - **Note/info/todo callouts become `--callout-accent` teal (dragonBlue / lotusTeal3).** This is the official `diag.info` hue; the first pass had mapped note to crystalBlue, which was _less_ faithful than the scheme itself. The commonest callout now reads as its own colour rather than as "another link".
  - **The rail's current section is text, not a tint, and has its own hue in Wave.** The first attempt made "you are here" a selection ground (`bg_visual` waveBlue2 / lotusViolet3) with `--strong` text, but the site's hover already turns the rail link to the text colour, so a tinted but colourless active row lost the active state on hover. Text is the better carrier than a ground here, with the two states ordered deliberately: `.rail a.current` is `light-dark(#4d699b, #e6c384)` (lotusBlue4 / carpYellow), and `.rail a:hover` is declared **after** it (equal specificity, so it wins the tie) — a section under the pointer goes to the text colour whether it is active or not, so hover is a momentary cue and never claims to be the section being read. The active section originally shared `--accent` (`crystalBlue` in Wave); when Wave's `--muted` moved to `springViolet1` it became only 1.18:1 from crystalBlue, which are the same family of pale cool pastel, so the active link stopped reading. carpYellow is the warm side of the wheel from both the purple rail text and the blue prose links (1.94:1 from muted, 9.73:1 on the dark ground, 1.64:1 from crystalBlue), giving the section-being-read its own role-group hue in Wave while Lotus keeps lotusBlue4. carpYellow is already the dark side of the question/help callout on pages that carry one — a role-group reuse in Kanagawa's own spirit, where one hue can name several meanings; it reads as emphasis in both places, never as a link.

  The violet/teal choices sat next to each other fine on the rendered pages, and the `info` teal reads distinctly from the `abstract` aqua once both are on screen, so the collision flagged below did not materialise.
- **The first pass is items 1, 2 and 4.** The fixture, the palette, the rail. Item 3 is not dropped — it is still the only item that fixes something broken today — but it is not in this pass.
- **Typography goes serif for headings and stays on the system sans for body.** One vendored face, and the body text keeps matching the editor. Item 6 is agreed in direction; it is sequenced after item 2 rather than scheduled now, because a face chosen against the old palette would be chosen twice. **Reversed the same day, on the rendered pages** — see item 6. The direction was agreed in the abstract and did not survive being looked at; the site is back on the system stack throughout.

## What the site actually contains, 2026-08-27

This changes the shape of item 4 and is the one thing that is not visible from inside Obsidian, so it goes first.

Nineteen notes are published. Ten of them have **no `##` or `###` at all**; four have exactly one. Five have three or more, and all five are the Lighting reference set — one of which, the Riverview upgrade writeup, has twenty-nine and is by itself four times the length of the next-longest note.

Backlinks are thinner still. Five pages have a backlink; every one of them has exactly one. The union of "has a table of contents worth printing" and "has a backlink" is six pages out of nineteen.

So a right-hand rail built today would be empty on thirteen of nineteen pages. That is an argument about _how_ to build it, not against building it: the rail has to render nothing when it has nothing, rather than render an empty box, and its value grows as the vault does. It is also an argument for doing item 3 first, because it is cheap and it fixes a gap that exists right now.

The other thing worth recording: fourteen of the nineteen published notes are not linked from the home page. They are reachable only by search or by a backlink from one of the five that are. That is item 3.

## 1. Rendering fixture and a screenshot loop

### The problem

Every item below is a visual change, and the only way to know a visual change worked is to look at it. `nix run .#garden-preview` already removed the deploy round-trip; what is still missing is a page that exercises every element at once, so that one screenshot covers callouts, tables, code, maths, footnotes, images, blockquotes, long headings and the dateline instead of nine.

### Approach

A fixture vault in the repository — not in the Obsidian vault, since it is a development artefact and not a published thought — rendered by `garden-preview --fixture`.

**Where it went, and why not where this plan said.** The plan proposed sharing the VM test's fixture in `checks/digital-garden.nix`, on the argument that the thing being looked at should be the thing being asserted on. Reading that file changes the answer: its vault is deliberately minimal and its own comments say why — every note in it exists to make an assertion about the publish boundary or the page count. Adding callouts, maths, tables and footnotes there would put six pages of content into a test that asserts nothing about any of it, which is the "test that asserts nothing" shape the rest of this repository argues against. So the rendering fixture lives at `modules/services/digital-garden/lib/hugo/fixture/`, beside the layouts and stylesheet it exists to exercise, and the check is untouched.

Four notes: `Every Element` (every element the theme styles — headings h1-h4 including one that wraps, lists including the task lists the stylesheet does not style, blockquote, all eight callout hues plus an untitled and a folded one, two code blocks, a normal table and one wide enough to strain, a deliberately light-background SVG, inline and display maths, a footnote, a horizontal rule), `A Long Note` (twelve `##` sections, for the rail and for sticky behaviour), `Another Note` (so that a page has a backlink to render, and a heading fragment to resolve) and an index.

It has its own dates ledger, `fixture-dates.json`, so rendering it never touches the vault's. `--fixture` wins over `--vault` and `$GARDEN_VAULT`: it is not a vault you might have meant, it is a request for a specific one.

Screenshots come from headless Chrome against the preview, which works today:

    google-chrome-stable --headless --hide-scrollbars --window-size=1440,1400 \
      --screenshot=out.png http://localhost:8087/some-note/

`--blink-settings=preferredColorScheme=1` forces the light theme, which is otherwise only reachable by clicking the toggle. For a page taller than any sensible window, screenshot into a very tall one and slice the result with ImageMagick; `google-chrome-stable` and `magick` are both already on this machine.

### Cost and risk

An hour, and it took about that. The risk was scope: this is a development aid, and it should not grow into a visual-regression harness with golden images in git. Screenshots to look at, not to diff — that still holds, and is the reason the fixture asserts nothing.

## 2. Kanagawa palette

### The problem

The current palette is a set of neutral greys with one blue accent (`#284b63` / `#7b97aa`). It is inoffensive and it is nobody's. Kanagawa Wave is what this machine runs, and matching it makes the site read as part of the same system as the editor the notes are written in.

### Approach

The stylesheet is already the right shape for this. Every colour is a role token — `--bg`, `--surface`, `--border`, `--muted`, `--text`, `--strong`, `--accent` — declared once on `:root` and once on `:root[data-theme="dark"]`, and the eight callout hues are `light-dark()` pairs. The change is the values, not the structure, plus one new token for the code well.

Kanagawa is two palettes: Wave for dark, Lotus for light. The values are available offline from `pkgs.vimPlugins.kanagawa-nvim` (`lua/kanagawa/colors.lua`) and, for the sixteen base16 slots only, `pkgs.base16-schemes`, both of which ride `flake.lock`. That matters: no build-time network fetch, which is the property `lib/hugo.nix` is written to protect. `configs/waybar/kanagawa-wave.css` already maps this palette onto role names in this repository, and the naming should agree with it.

Proposed mapping:

| Role        | Wave (dark)             | Lotus (light)                 |
| ----------- | ----------------------- | ----------------------------- |
| `--bg`      | `#1F1F28` sumiInk3      | `#f9f6e1` lotusWhite3, lightened |
| `--surface` | `#2A2A37` sumiInk4      | lotusWhite2, lightened        |
| `--border`  | `#363646` sumiInk5      | lotusWhite0, lightened        |
| `--muted`   | `#727169` fujiGray      | `#716e61` lotusGray2          |
| `--text`    | `#DCD7BA` fujiWhite     | `#545464` lotusInk1           |
| `--strong`  | `#DCD7BA` fujiWhite     | `#43436c` lotusInk2           |
| `--accent`  | `#7E9CD8` crystalBlue   | `#4d699b` lotusBlue4          |
| `--code-bg` | `#16161D` sumiInk0      | lotusWhite1, lightened        |

Callouts map one-for-one onto Kanagawa's semantic hues — crystalBlue for note, waveAqua2 for abstract, springGreen for tip, oniViolet for important, carpYellow for question, roninYellow for warning, waveRed for failure, fujiGray for quote — with the Lotus counterpart in each `light-dark()` pair. `==highlight==` becomes winterYellow / lotusYellow4, and `::selection` becomes waveBlue2 / lotusBlue1, which the site does not currently style at all.

This measurably improves the dimmest text on the site. `--muted` carries the dateline and the backlink theses, and today it is `#b8b8b8` on `#faf8f8` — a contrast ratio of **1.87**, which is not a legibility judgement, it is illegible. Lotus's lotusGray2 gives 4.70 on the lightened cream. In dark it goes from 3.05 to 3.33. Body text stays comfortably AAA in both.

### The open question, decided 2026-08-27 — option 1

Lotus's own background is `#f2ecbc`. Inside a Neovim window that is a warm cream. Across a full browser page at 1440px it is a **buttery yellow**, and it competes with the white-background diagrams the Lighting notes are full of. Rendered, it is a much bigger change than the dark side is.

Three ways out, in order of preference. **Option 1 was taken**; the other two are kept because the reasoning against them is the useful part.

1. **Lotus, lightened.** `#f2ecbc` mixed 45% toward white gives `#f9f6e1` — warm paper, unmistakably in the Kanagawa family, calm at full width. Contrast improves across the board. Rendered, this is the one that looks right.
2. **Lotus as specified.** Authentic, and a strong aesthetic commitment.
3. **Dark only.** Kanagawa Wave for dark, keep the near-white light theme. Defensible — Wave is what is actually used — but it leaves two unrelated palettes in one stylesheet, and it leaves `--muted` at 1.87.

A second, smaller decision, also taken: headings stay neutral (`fujiWhite` / `lotusInk2`) rather than taking a hue. The writeup has twenty-nine headings and a yellow one every screen is a lot.

### What the fixture caught, which this plan did not know about

Fenced code blocks were never themed at all. Chroma writes its colours **inline** by default — `style="color:#f8f8f2;background-color:#272822"` on the `<code>` element and a `style` on every span — so every code block on the site shipped Monokai regardless of the reader's theme, and no stylesheet could override it and no toggle could reach it. Against a near-black page that passed for deliberate. Against warm paper it is a black box in the middle of the page.

The fix is `noClasses = false` in `lib/hugo.nix` plus a Chroma section in the stylesheet, grouped by what a token means rather than one rule per class, in Kanagawa's syntax hues with the same `light-dark()` pairs as everything else. Anything unlisted inherits the block's colour, which is the right default: an unstyled token should look like code, not like an error.

This is the argument for item 1 in one finding. The bug was two years old, visible on every page with a code block, and invisible until something rendered one next to a page that had changed colour.

### Cost and risk

Half a day including the screenshot pass and the Chroma work. The risk was that colour choices read differently at page scale than at swatch scale — which is what item 1 exists to catch, and it caught both this and the Lotus background.

## 3. An index of everything published

### The problem

Fourteen of nineteen published notes are unreachable from the home page. The landing page is a hand-written index — deliberately, and it should stay one, because `publish-filter.py` annotates its bare links with each target's thesis and what is authored is what should be shown. But "the index is curated" and "there is no way to see everything" are different decisions, and only the first one was made on purpose.

### Approach

A generated `/notes/` listing every published page: title, thesis, date, newest first. Hugo can do this from `site.RegularPages` in one template; the thesis is already in `.Params.description`, and the date logic already exists in `dateline.html`. A link from the footer, next to RSS.

Optionally group by the vault folder the note came from — the Lighting set is already a coherent group and reads as one — which needs `publish-filter.py` to carry the source directory into the frontmatter. That is a small change to the filter, and it is the only item here that touches it.

### Cost and risk

Two hours without grouping. No risk: it is one new template and one footer link, and the publish boundary is untouched because it lists what has already been published.

### Shipped, 2026-08-30

One new template, `layouts/_default/list.html`, renders the page from `site.RegularPages` — title, thesis and the dateline partial, newest first — and the page itself is born in `lib/hugo.nix` at render time rather than in the vault or the staging tree, so the staging tree stays exactly the published set. The footer link sits next to RSS. The plan priced this at "no risk"; the actual price was one fact about Hugo 0.165 (a section listing is `_default/list.html`), plus the familiar trap dressed the other way: a new file under `layouts/` is invisible to the flake until it is `git add`-ed, so the first render emitted the section's feed and no HTML — the silent skip the VM check exists for, met from the subversion side.

Two residues worth recording. A vault note titled `Notes` would publish at `/notes/` and collide with this page; nothing guards that URL, and it is recorded here rather than fixed, because the URL is item 3's own. And the dateline, whose spacing is tuned for a page top, needed its own margin inside an index entry.

The VM check pins the behaviour rather than the appearance: every published note is listed with its thesis (the on-money fixture is pinned to 2001 so "newest first" is asserted, not assumed), the page is absent from the feed, and the footer links it.

## 4. Right-hand rail

### The problem

The prose column is capped at 40rem and centred, so at 1440px there are 400px of empty space on each side. The table of contents does not exist anywhere, and backlinks sit at the very bottom of the page, which is the one place a reader who wants to know what else cites this note will not look until they have finished reading.

### Approach

Prototyped and screenshotted; it works, and the important property is that **the prose does not move**. A three-track grid — `1fr minmax(0, var(--measure)) 1fr` — puts the article in the centre track at exactly the position it occupies today, at every viewport width, and puts the rail in the right track, which is empty space now. The rail is `position: sticky` so it follows the reader down a long page.

Below about 1200px the grid becomes a single column, the contents list is hidden, and the rail falls back into the flow after the article — which is precisely the current bottom-of-page backlinks block. One piece of markup, both layouts, no duplicated partial.

Contents comes from Hugo's `.Fragments`. **`##` only**: the writeup's twenty-nine entries do not fit a viewport, its thirteen `##`s do. Render the nav only when there are three or more, so the thirteen pages that would show a one-item or empty list show nothing at all.

An optional twenty lines of `IntersectionObserver` highlights the section currently on screen. It is the difference between a list of links and a sense of where you are, and it is the only JavaScript this item needs.

The finicky part is alignment: the masthead and footer must line up with the prose column and not with the full page width, or the rule under the masthead extends past the text it belongs to. The prototype got this subtly wrong and it was visible immediately.

### What it cost that the plan did not price in

**Hugo wraps the heading tree in a synthetic root.** `.Fragments.Headings` returns one entry — `Level` 0, empty `Title` — whenever a page's headings do not start at H1, which here is _always_, because `publish-filter.py` lifts a note's leading H1 out of the body to become the title. So the count is one on every page, the threshold of three is never met, and the contents list silently renders nowhere. Nothing errors. It was found by a page with twelve visible sections reporting one, and it is now a comment in `rail.html` rather than a fact to rediscover.

**A nil frontmatter key is not a zero-length one.** `len .Params.backlinks` errors on a note with no backlinks — `reflect: call of reflect.Value.Type on zero Value` — which is a build failure and not a missing rail. The truthiness of the value is the right test.

### What it actually ships, on the real vault

Six of nineteen pages get a rail: the five Lighting notes and Work-Life Balance. Three of those get a contents list. The other thirteen render no `<aside>` at all, which is what the plan asked for and what the numbers predicted.

### Cost and risk

Half a day, most of it in the two findings above rather than in the alignment. The risk is the one in the findings section: on thirteen of nineteen pages this ships nothing. The mitigation is the render-when-non-empty rule, and the reason to build it anyway is that the pages where it does appear — the Lighting set — are the ones people are actually sent to.

## 5. Link and image treatment

### The problem

Two things the screenshots made obvious. Every inline link carries a `--surface` tint box, including footnote references, which at footnote density looks like the page has been highlighted by someone else. And the diagrams in the Lighting notes are white-background PNGs, which on a `#1F1F28` page glare like a torch.

### Approach

For links: drop the tint and use an underline with `text-underline-offset: 0.15em` and a `--muted` underline colour that goes `--accent` on hover. Keeps the affordance, loses the boxes. This is a taste call and worth a screenshot both ways.

For images: a paper-coloured mat behind them in dark mode — a few pixels of padding in a colour near the light theme's background — rather than a `filter: brightness()`, which would also dim the photographs, and there are photographs.

### What shipped, and the two things worth recording

**The chrome exclusion list was the whole of the work.** Dropping the tint is one declaration; deciding which links are prose and which are machinery is the rest. Footnote references are the case the problem statement named, and they turn out to be the case an underline is worst for as well: the line under a superscript numeral lands in the gap above the next line of text rather than under anything. So the reference and the backref both keep `text-decoration: none`, alongside the site title, the footer links and the heading anchors. The footer's hover underline is restored explicitly, because `a:hover` no longer sets a line for it to inherit.

That list also had a redundant pair in it — `a.footnote-backref` and `[role="doc-backlink"]` are the same element, Hugo emits both — which was invisible while the rule only removed a background. It is one selector now.

**The mat frames the glare rather than removing it,** and that is the trade the plan chose when it ruled out a filter. A white diagram on paper is still white; what changes is that it reads as a page rather than as a hole cut in a dark one. The fixture's SVG is white to its own edges, so what the mat shows is a cream ring — which is the honest picture of what this does to a real Lighting diagram. Photographs get the same ring, which reads as a mount.

### The mat is reverted, 2026-08-27

**It was judged on the fixture's SVG and the fixture's SVG is not the vault.** Two things showed up against real images, and each of them is a case the paragraph above assumed away.

On a photograph the ring does not read as a mount. It reads as a white rectangle drawn around the picture — the plan called it "a decision" and accepted it as the price of the diagrams, and looked at, it is not a decision, it is an artefact.

The diagrams are worse, and they are the reverse of the problem the mat was built for. Not every diagram in the vault is a light-background scan: some were drawn **for** a dark background, and the mat puts cream behind a figure whose own strokes are pale, so it takes parts of the drawing from readable to invisible. A treatment that damages the case it was meant to help is not a trade, and there is nothing to tune here — the mat cannot know which kind of image it is behind.

So images render as their author exported them, in both themes, which is where this started. The glare is real and it remains unsolved; the honest position is that it is the image's problem and belongs upstream in the vault — a diagram exported with a transparent or dark ground fixes it for every reader and every theme, and no stylesheet rule can. The link half of this item stands unchanged.

### Cost and risk

An hour, and it took about that. Reversible in one commit, which is what happened.

## 6. Typography

**Built and reverted on 2026-08-27.** The sections below are the reasoning as it stood, kept because the build is worth reading and the finding in it is worth keeping; _Reverted_ near the end is what happened when it was looked at. The site is on the system stack, headings included.

### The problem

The stylesheet uses the system stack, with a comment explaining that asking for a webfont without shipping it is the worst of both. That reasoning holds. But the system stack on this machine resolves to something different from the system stack on a reader's phone, so the site has no typography — it has whatever the reader has.

### Approach

Vendor a face from nixpkgs exactly as `lib/hugo.nix` already vendors KaTeX: copy the woff2 out of the store at build time, serve it as a static file, no network, no CDN, `font-display: swap`. `modules/nixos/stylix.nix` already pulls `noto-fonts`, so Noto Serif and Noto Sans are in the closure.

Whether to use a serif was the real question, and it is decided: **a serif for headings, the system sans for body**. A serif body suits an essay site and is what most gardens reach for, but it breaks the what-you-see-is-what-you-get property with Obsidian that the current layout was built around. Headings alone give the page a voice and leave the reading experience matching the editor.

### What it took to hit the weight budget

nixpkgs does not ship a woff2. `noto-fonts` carries `NotoSerif.ttf`, a **1.9MB variable font**: every weight from 100 to 900, and very nearly every glyph Noto covers. Shipping that, or a naive woff2 of it, would have been forty times the budget.

Two reductions, both at build time in `lib/hugo.nix`, both from packages already on `flake.lock`:

1. `fonttools varLib.instancer` pins the weight axis at 600 — the weight the headings already used. This is the big one. `gvar`, the table describing how each glyph deforms across the axis, is two thirds of the file, and instancing removes it outright.
2. `pyftsubset` cuts the glyphs to Google's own `latin` range plus the punctuation these notes use.

`woff2_compress` does the rest. The result is **28,952 bytes**, inside the 20-40KB the plan asked for. A heading that ever needs a glyph outside the range falls back to the body stack for that heading, which is the degradation the site already had.

### The finding: you cannot check this by looking at it

A browser keeps the faces **installed** under a family name in that family, alongside the ones `@font-face` adds. This machine has Noto Serif in fontconfig, and so does every Android phone. So a `src` pointing at a URL that 404s still renders a serif heading here, taken from the system, and the screenshot is indistinguishable from the working one — verified, twice, at zero differing pixels.

The check that does work is to rename the family to something nobody has and screenshot that: the heading is still a serif, so the woff2 was fetched, parsed and used. That is now a comment in the stylesheet, and the VM test asserts the file is served at all — which is the same class of silent failure as item 2's inline Chroma colours, and the same reason for testing it.

The same fact settles a question the plan did not ask. Adding `local("Noto Serif")` to the `src` would let those readers skip the download, but the installed face at that name is Regular, and claiming it as the 600 weight would render headings light on exactly the machines that have it. One URL, one weight, the same face for everyone.

### Reverted, 2026-08-27: the headings look better in the sans

The face was correct on every measure the plan set for it — vendored, 29KB, preloaded, no CDN, no DNS lookup to anyone else — and the page reads better without it. A serif heading over sans body text gives the page a voice the page did not need; the type scale was already doing the work, and one face throughout is quieter and closer to what the notes look like in Obsidian, which is the property this item's own reasoning kept coming back to.

That is a taste call and it was made the way item 1 exists to have it made: by looking at the rendered pages, at both themes, rather than at the argument. The argument was good, which is why it was built at all.

What came out: the `@font-face` and `--heading-font` from the stylesheet, the `varLib.instancer`/`pyftsubset`/`woff2_compress` derivation from `lib/hugo.nix`, the static copy, the preload from `baseof.html`, and the VM subtest that asserted the file was served. One assertion outlives the face and stays, moved into the "the site is styled" subtest: **the stylesheet names no font CDN**. That guard is about the offline property, not about this face, and it is the line that would be cheapest to undo by accident.

What is kept in this document rather than in the code is the finding, because it will be true for whoever tries this next: **you cannot check a webfont by looking at it** on a machine that has the family installed. That section stands above.

### Cost and risk

Two hours to build and ten minutes to remove. The risk taken was page weight and it was not the one that bit — the plan had no way to sequence "does this look right" before "does this work", because the answer to the first needs the second in front of it.

## 7. Wikilink hover previews (optional)

Quartz's most-copied feature: hovering an internal link shows the target's opening. There is a cheap version here that nothing else has, because `publish-filter.py` already resolves the whole link graph and already knows every note's thesis. It can emit `data-thesis` on internal links at build time, and roughly thirty lines of CSS plus a small script turn that into a popover. No fetch, no second copy of the content, nothing at runtime that is not already in the HTML. A `title` attribute is the version with no JavaScript at all, if it turns out that is enough.

Revised 2026-08-28: do the `title` version _first_ and treat the popover as a separate decision taken against it. The filter already resolves the graph and already knows every thesis, so the attribute is a few lines in `publish-filter.py` and nothing else — no CSS, no script, no new failure mode, and it works on a phone where a hover does not exist. If it turns out to be enough, the medium-sized half of this item never gets built; if it is not, the popover is built against something real rather than against a guess about what a reader wants from a link.

## 8. Footnotes as sidenotes (optional, depends on 4)

Once the grid from item 4 exists, footnotes can be moved into the right margin beside the paragraph that cites them, Tufte-style, instead of collected at the bottom. The Lighting notes are heavily footnoted and this suits them. It is genuinely large: Hugo emits footnotes as a list at the end of the document, so they have to be relocated, and the vertical positioning of a sidenote against its reference is the part that never quite works. It also conflicts with item 4's rail — both want the right margin — so it would need a rule about which wins on a page that has both. Worth wanting, not worth doing before the rest of the list.

## 9. Reading time in the dateline (optional)

`publish-filter.py` already counts words for `LONG_NOTE_WORDS`. Surfacing an estimate next to the date is a few lines. Given that half the notes are under 500 words, this may say more about the garden than is flattering, which is either a reason not to do it or the honest thing about a slip box.

## 10. Polish

A print stylesheet — these are essays, and people print essays; hide the masthead controls, unstick the rail, print link targets after external links. `prefers-reduced-motion` around the two transitions. A "follow system" third state on the theme toggle, which currently has no way back to the OS preference once a reader has chosen. Each is minutes; none is interesting; together they are the difference between finished and nearly finished.

Selection was the fourth item in the title and it was taken in item 2, where the palette had the Kanagawa values to hand.

### The print stylesheet was not a nicety

Printing from the dark theme produced **a blank sheet**. Browsers do not print background colours by default, so the ground goes and the text stays: fujiWhite on white paper. The fix is to override both token blocks inside `@media print` — paper is white and the ink is black, whichever theme the reader was in — and it is the reason this item stopped being optional.

One smaller consequence of the same fact: `==highlight==` is a background and so does not print; it takes an underline instead, which is the same mark made with ink. (A second rule rode along here — the dark theme's image mat from item 5, which keyed off `data-theme` and so was still on for someone printing from the dark theme — and it went when the mat did.)

The rest went as described. External destinations print after the link, scoped to the article so the footer's chrome does not; `break-after: avoid` on headings and `break-inside: avoid` on the blocks that cannot be scrolled past; the rail needs no unsticking in practice, because print media is about 794px wide and the grid needs 1280, but it is unstuck explicitly since `sticky` in a paged medium is browser-dependent and none of the answers are a table of contents.

### The toggle: three states, and no dead click

A literal three-way cycle — system, light, dark — has a click in it that does nothing. Leaving "system" for the theme the system was already showing changes no pixel, and a control that appears not to work is worse than one that cannot reach a state.

So the button flips the theme every time, and "follow the system" is where the flip lands when the result agrees with the system preference. Two clicks back to it from anywhere, and every click changes the page. `data-theme` stays what the page is painted in; a second attribute, `data-theme-source`, carries whether that was chosen, which is what the third glyph and the button's label read.

The state that this buys, beyond a way back: a reader who has not chosen now follows the system **while the page is open**, not merely as it was at load.

Verified by driving headless Chrome over the DevTools protocol — click the button four times at each system preference and read back the attribute, the stored value, which glyph is displayed and the computed background — because this is behaviour, and a screenshot cannot press a button. `Emulation.setEmulatedMedia` is what sets the system preference for that: `--blink-settings=preferredColorScheme` works for a plain screenshot but does not reach `matchMedia` once devtools is attached.

### Cost and risk

Two hours, most of it in the printing. No risk taken: every rule here is inside a media query or behind an attribute the page already sets.

## 11. Rendering gaps found by review, 2026-08-28

### The problem

Four things found by rendering the fixture and measuring it, none of which is visible from reading the stylesheet, and none of which the gate could fail on. They are grouped as one item because they share that property, not because they share a cause.

**A wide table scrolled the page.** `.table-container { overflow-x: auto }` had been in the stylesheet since the single-column layout landed, and there was no render hook to emit the div, so the rule matched nothing. The container was never there. A table therefore had no box to scroll inside and did the only other thing available to it: at 390px the reference tables took the document to about twice the width of the phone, so every paragraph on the note could be dragged sideways and had to be dragged back. `width: 100%` on the table was the same bug seen from the other end — it guaranteed the table could never exceed the container, so `overflow-x` never had anything to scroll, and it guaranteed a table too wide for the measure was squeezed into it anyway. That is how a column of one-sentence theses came to be set one word per line at 1600px. The fixture has said _"a table wide enough to scroll inside its own container"_ since it was written, and it never did.

**Wave's `--muted` was below the contrast floor for body text.** fujiGray `#727169` against sumiInk3 is 3.33:1, under the 4.5:1 that body text needs, and 2.88:1 where it lands on `--surface`. That would be defensible if `--muted` were decoration. It is not: it carries blockquote text, every sidenote at 0.8rem, the dateline, the backlink theses, the footer and every rail link that is not the current section. fujiGray is Kanagawa's _comment_ colour, and it was doing duty as reading text. Lotus needed nothing — lotusGray2 is 4.70:1.

**No tab icon and no `theme-color`.** The site declared neither, so every visit asked for `/favicon.ico` and got a 404, the tab showed the browser's blank-page glyph, and on a phone a sumiInk3 page sat under a white address bar.

**Task lists carried two markers.** An Obsidian `- [ ]` item rendered with a bullet _and_ a checkbox, a few pixels apart and aligned to neither the text nor each other. The fixture had said the stylesheet did not style these since the day it was written.

### Approach

Four commits, each independently revertible.

A `_markup/render-table.html` hook, which is the missing half of a rule that was already written, plus `width: max-content; min-width: 100%` on the table so a wide one can be as wide as it needs and a narrow one still fills the measure. The container is a tab stop: Firefox makes an overflow box focusable on its own and Chrome does not, so without it a keyboard reader could reach every other part of the page and not the right-hand columns — a worse regression than the page-scrolling it replaces, since the page at least scrolled. Hugo already emits `tabindex="0"` on a `<pre>` for exactly this reason, which is the best evidence the decision is right. `role="region"` with a name is the usual companion and is not taken: the name would have to be invented, since these tables have no captions, and _"region: table"_ announced before every one of them is noise bought with nothing.

`--muted` in Wave becomes springViolet1 `#938AA9`, 5.02:1. It is Wave's own, so the property this palette was built on holds: every hex is still traceable to the `colors.lua` that rides flake.lock, and none of it was picked off a screenshot.

An `assets/icon.svg` seedling, drawn as three filled shapes rather than as strokes, because at the 16px a tab actually renders a hairline disappears and a filled leaf does not. It carries its own `prefers-color-scheme` rule, so it is lotusPink against a light tab strip and sakuraPink against a dark one. `theme-color` is a single tag driven by the theme script rather than the obvious pair of tags with media attributes: a media pair follows the operating system, and this site's theme is a toggle a reader can move off the system, so the only thing that knows the answer is the script that already decides `data-theme`.

`li:has(> input[type="checkbox"])` for the task lists, which selects the item by what it contains and avoids a render hook whose only job would be to add a class. Scoped to the item rather than the list, so a list mixing tasks with plain items keeps its bullets on the plain ones.

### What it cost that the plan did not price in

One renderer change, and it is worth more than the icon that forced it. `lib/hugo.nix` copied only the stylesheet into the site's assets directory and not the theme's own assets, so any _second_ asset was invisible to `resources.Get`. Here that failed loudly, as a nil fingerprint at build time. The same shape in a template that guarded the lookup would have been a `<link>` to a file the renderer never copied: right in the HTML, 404 for every reader, and nothing to notice it. It now copies the directory and overlays the argument, which keeps `garden-preview`'s working-tree stylesheet working and needs no further change for the next asset.

Two traps worth recording for the next person, both of which cost a rebuild to find. A new file under `layouts/` is invisible to the flake until it is `git add`-ed — the same trap `_partials/social.html` documents, met again from the other direction, and the symptom is a hook that silently does not run rather than an error. And XML forbids a double hyphen inside a comment, which is awkward in a repository whose colours are all named after CSS custom properties; the icon's comment says so, because writing `--brand` in it produces a file the browser renders as a broken image.

### The regression guard

Both of the new assertions are in `checks/digital-garden.nix`, and they are there because this is exactly the failure the check exists for: the build was clean, the CSS was present, the table rendered, and the page was wrong. The check's fixture grows a table, and the assertion has two halves because either one alone is the bug — the selector is in the stylesheet, _and_ a real table's markup contains it. Confirmed live by renaming the class in the hook and watching the check fail with `a table is not wrapped in .table-container`. The icon assertion reads the fingerprinted URL off the page and then fetches it, for the reason above: a link to an uncopied asset looks right and 404s.

This is the same line item 6 drew between its two assertions. A rule that is written and never reached is the same class of failure as a stylesheet naming a font CDN, and neither is visible in a screenshot or a green gate.

**Updated, 2026-08-29:** the `width: max-content; min-width: 100%` fix above was itself the next instance of the same shape. It left a wide table scrolling inside its container — no longer the page, but the right-hand prose columns sat off-screen and ~500px of sideways scroll was still the interface. It is replaced by a `<colgroup>` cap emitted by the hook plus `table-layout: fixed; width: 100%` on the table, so every column stays on the measure and prose wraps at a capped width. Two numbers tune it: the prose cap (120 codepoints) sits high enough that a longer column still earns proportionally more of the table, and a 10% share floor keeps a short data column ("Role", a price) from being crushed by a long prose neighbour. Fixed layout is what makes the hook's widths stick — under auto layout a `<col>` width is only a hint the content can outgrow, which is the original bug returning. See `_markup/render-table.html` and `checks/digital-garden.nix`.

### The open question, not decided

Lotus's `--brand` is 4.12:1 on the masthead. At 1.1rem and weight 600 that is 17.6px semibold, just under the 18.66px where the large-text allowance of 3:1 starts, so the 4.5:1 floor applies and it misses.

Three ways out, and the choice is a taste decision rather than a measurement:

- **Take the title to 1.2rem.** 19.2px semibold qualifies as large text, where 4.12:1 passes comfortably. Keeps sakuraPink and lotusPink, which were chosen deliberately on 2026-08-28, and costs a slightly heavier masthead.
- **Change the hue.** lotusRed `#c84053` is 4.47:1 and still misses; lotusViolet3 `#5d57a3` is 5.75:1 and lotusViolet4 `#624c83` is 6.70:1, both of which reverse the pink decision back toward the violet it came from.
- **Leave it.** One word of chrome at 4.12:1, on a masthead, is the mildest instance of this problem on the site, and it is now the only one.

The first is the recommendation. Nothing is blocked on it.

### Deliberately not changed

The Chroma comment rule keeps fujiGray at 3.67:1 against sumiInk0. That one is genuinely a comment, on code the stylesheet already sets at lower contrast on purpose — the syntax block says so in as many words — and changing it would cost more editor parity than it buys.

The light-ground SVG diagram still glares on the dark page. Item 5 settled that on 2026-08-27 and the answer has not changed: the fix for a glaring diagram is to export it with a transparent ground, which fixes it for every reader and every theme, and nothing in CSS can tell a diagram from a photograph.

There is still no skip link, and there should not be one. The masthead is one link and two buttons; a skip link saves nobody a keystroke.

### Cost and risk

Half a day, most of it in finding the table bug rather than fixing it. No risk: every rule is a stylesheet edit or a render hook, the publish boundary is untouched, and the two new assertions fail loudly if any of it is undone.

## 12. The dateline in the empty margin (optional)

### The problem

The rail renders on six of nineteen notes. On the other thirteen, a wide screen shows a 15rem left column of nothing while the dateline sits above the prose in the measure. The layout therefore reads as _"this site has a rail when it has one"_ rather than _"this site has margins"_, and the widest, emptiest version of the page is the one a reader on a large monitor gets.

### Approach

Move the dateline into the left column at the wide breakpoint, on the title's baseline where the rail's heading already sits, and leave it above the prose below it. The grid, the baseline alignment and the sticky behaviour all exist already; this is a second element placed in a column that is already built, and the narrow layout is the one the site has always served.

Item 9's reading time, if it is ever taken, belongs in the same place and is the reason to do these two together rather than separately.

The thing to check by looking, and the reason this is not obviously right: on a page that _does_ have a rail, the dateline and the rail's first heading are then both in the left column, and two small grey blocks stacked in a margin may read as a sidebar — which is the thing the single-column layout was chosen to avoid.

### Cost and risk

An hour, and it is entirely reversible. The risk is the one above, and it is a judgement that can only be made against the rendered pages.

## Rejected: a graph view

The canonical Quartz feature, and it should not be built here. Nineteen nodes with six edges is not a graph, it is a list with extra steps — the rendered picture would be five connected Lighting notes and thirteen dots. It needs a rendering library, which means either a build-time network fetch or vendoring a canvas library into a site that currently ships zero bytes of framework, and it works badly on the phones that most of this site's readers will use. Items 3 and 4 deliver what a reader actually wants from a graph view, which is "what else is near this", at a fraction of the cost. Revisit at a hundred notes if the link density has gone up with them.

## Sequencing

Item 1 first, because everything after it is judged by looking. Then item 2, the largest visible change, which wants the fixture page to land against. Then item 4. Then 5 and 6 as taste passes over a palette that has settled.

Items 5, 6 and 10 were taken together on 2026-08-27, in that order, which is the order the plan gives them: the link treatment and the face are both judged against the palette, and the polish is judged against both.

Item 3 is out of the first pass by choice, not by dependency; it can be taken at any point, including between the others, since it touches no file the rest of them touch. Items 7 through 9 are likewise independent of each other and of the rest.

Each item is its own PR, per the usual gate. Item 2 will not change the VM test's assertions — the test looks for a stylesheet, not for its contents — which is worth stating explicitly, because it means the gate is not evidence for any of this and the screenshots are.

That held for items 2, 4 and 5, and stopped holding at item 6, which added two assertions: a webfont is not a colour — the file either is served from this site or it is not, and if it is not, nothing fails, every reader silently gets their own serif. When the face was reverted one of the two went with it and one stayed, which is the useful line between them. The file being served was a fact about a decision that got reversed; **the stylesheet naming no font CDN** is a fact about the property this whole toolchain exists to hold, and it holds whether or not there is ever a webfont again. The rest of the judgement is still the screenshots'.

Item 11 was not sequenced at all — it came out of a review on 2026-08-28 and every part of it was a defect or a gap rather than a design decision, so it was taken immediately and in four commits rather than one PR per item. It moved the line above again, in the same direction item 6 moved it: two more assertions now guard properties the screenshots cannot, because _"the build was clean, the CSS was present, the table rendered, and the page was wrong"_ is the failure this project keeps meeting and the only one the gate can be taught to catch.

Item 12 depends on item 4 and on nothing else, and is worth doing at the same time as item 9 if item 9 is ever taken, since both put a small grey line in the same place. Item 3, taken 2026-08-30, made "reachable only by search or by a backlink" a sentence in the past tense: fourteen of nineteen notes used to be reachable that way, and none is now.
