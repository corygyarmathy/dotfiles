# Plan: theme and navigation for the digital garden

Status: proposed 2026-08-27; decisions taken the same day, see _Decisions_ below. Items 1, 2 and 4 are the agreed first pass. Two ideas asked for — a Kanagawa palette and a right-hand navigation column — plus seven more that came out of looking at what the site actually serves today. Everything below is scoped against `modules/services/digital-garden/lib/hugo/`, which is the whole design: four layouts, six partials, three render hooks and a 488-line stylesheet. There is no theme underneath to fight, so every item here is an edit to files this repository owns.

| #   | Item                                | Size   | Depends on | Status      |
| --- | ----------------------------------- | ------ | ---------- | ----------- |
| 1   | Rendering fixture + screenshot loop | small  | -          | **done** 2026-08-27 |
| 2   | Kanagawa palette                    | medium | 1          | **first pass** |
| 3   | An index of everything published    | small  | -          | not started |
| 4   | Right-hand rail: contents, backlinks| medium | 1          | **first pass** |
| 5   | Link and image treatment            | small  | 2          | not started |
| 6   | Typography                          | small  | 2          | **agreed, not scheduled** |
| 7   | Wikilink hover previews             | medium | -          | optional    |
| 8   | Footnotes as sidenotes              | large  | 4          | optional    |
| 9   | Reading time in the dateline        | small  | -          | optional    |
| 10  | Polish: print, selection, motion    | small  | 2          | optional    |
| -   | Graph view                          | -      | -          | **rejected**, see below |

## Decisions, 2026-08-27

Taken against the rendered comparisons rather than the swatches, which is the point of item 1 existing before item 2.

- **The light theme is Lotus, lightened.** `#f2ecbc` mixed 45% toward white, `#f9f6e1`, with the surface, border and code-well tokens lightened to match. Option 1 of the three below. Lotus as specified is out: rendered at full width it is a buttery yellow that the Lighting notes' white-background diagrams have to fight.
- **Headings stay neutral.** `fujiWhite` in dark, `lotusInk2` in light. No `carpYellow`.
- **The first pass is items 1, 2 and 4.** The fixture, the palette, the rail. Item 3 is not dropped — it is still the only item that fixes something broken today — but it is not in this pass.
- **Typography goes serif for headings and stays on the system sans for body.** One vendored face, and the body text keeps matching the editor. Item 6 is agreed in direction; it is sequenced after item 2 rather than scheduled now, because a face chosen against the old palette would be chosen twice.

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

### Cost and risk

Half a day including the screenshot pass. The risk is that colour choices read differently at page scale than at swatch scale, which is what item 1 exists to catch, and it already caught this one.

## 3. An index of everything published

### The problem

Fourteen of nineteen published notes are unreachable from the home page. The landing page is a hand-written index — deliberately, and it should stay one, because `publish-filter.py` annotates its bare links with each target's thesis and what is authored is what should be shown. But "the index is curated" and "there is no way to see everything" are different decisions, and only the first one was made on purpose.

### Approach

A generated `/notes/` listing every published page: title, thesis, date, newest first. Hugo can do this from `site.RegularPages` in one template; the thesis is already in `.Params.description`, and the date logic already exists in `dateline.html`. A link from the footer, next to RSS.

Optionally group by the vault folder the note came from — the Lighting set is already a coherent group and reads as one — which needs `publish-filter.py` to carry the source directory into the frontmatter. That is a small change to the filter, and it is the only item here that touches it.

### Cost and risk

Two hours without grouping. No risk: it is one new template and one footer link, and the publish boundary is untouched because it lists what has already been published.

## 4. Right-hand rail

### The problem

The prose column is capped at 40rem and centred, so at 1440px there are 400px of empty space on each side. The table of contents does not exist anywhere, and backlinks sit at the very bottom of the page, which is the one place a reader who wants to know what else cites this note will not look until they have finished reading.

### Approach

Prototyped and screenshotted; it works, and the important property is that **the prose does not move**. A three-track grid — `1fr minmax(0, var(--measure)) 1fr` — puts the article in the centre track at exactly the position it occupies today, at every viewport width, and puts the rail in the right track, which is empty space now. The rail is `position: sticky` so it follows the reader down a long page.

Below about 1200px the grid becomes a single column, the contents list is hidden, and the rail falls back into the flow after the article — which is precisely the current bottom-of-page backlinks block. One piece of markup, both layouts, no duplicated partial.

Contents comes from Hugo's `.Fragments`. **`##` only**: the writeup's twenty-nine entries do not fit a viewport, its thirteen `##`s do. Render the nav only when there are three or more, so the thirteen pages that would show a one-item or empty list show nothing at all.

An optional twenty lines of `IntersectionObserver` highlights the section currently on screen. It is the difference between a list of links and a sense of where you are, and it is the only JavaScript this item needs.

The finicky part is alignment: the masthead and footer must line up with the prose column and not with the full page width, or the rule under the masthead extends past the text it belongs to. The prototype got this subtly wrong and it was visible immediately.

### Cost and risk

Half a day, most of it in the alignment and the narrow-width fallback. The risk is the one in the findings section: on thirteen of nineteen pages this ships nothing. The mitigation is the render-when-non-empty rule, and the reason to build it anyway is that the pages where it does appear — the Lighting set — are the ones people are actually sent to.

## 5. Link and image treatment

### The problem

Two things the screenshots made obvious. Every inline link carries a `--surface` tint box, including footnote references, which at footnote density looks like the page has been highlighted by someone else. And the diagrams in the Lighting notes are white-background PNGs, which on a `#1F1F28` page glare like a torch.

### Approach

For links: drop the tint and use an underline with `text-underline-offset: 0.15em` and a `--muted` underline colour that goes `--accent` on hover. Keeps the affordance, loses the boxes. This is a taste call and worth a screenshot both ways.

For images: a paper-coloured mat behind them in dark mode — a few pixels of padding in a colour near the light theme's background — rather than a `filter: brightness()`, which would also dim the photographs, and there are photographs.

### Cost and risk

An hour. Reversible in one commit.

## 6. Typography

### The problem

The stylesheet uses the system stack, with a comment explaining that asking for a webfont without shipping it is the worst of both. That reasoning holds. But the system stack on this machine resolves to something different from the system stack on a reader's phone, so the site has no typography — it has whatever the reader has.

### Approach

Vendor a face from nixpkgs exactly as `lib/hugo.nix` already vendors KaTeX: copy the woff2 out of the store at build time, serve it as a static file, no network, no CDN, `font-display: swap`. `modules/nixos/stylix.nix` already pulls `noto-fonts`, so Noto Serif and Noto Sans are in the closure.

Whether to use a serif was the real question, and it is decided: **a serif for headings, the system sans for body**. A serif body suits an essay site and is what most gardens reach for, but it breaks the what-you-see-is-what-you-get property with Obsidian that the current layout was built around. Headings alone give the page a voice and leave the reading experience matching the editor.

### Cost and risk

Two hours. The risk is page weight — one weight of one face is 20-40KB, which is on the same order as everything else the page loads, and it is worth being deliberate about rather than adding four weights.

## 7. Wikilink hover previews (optional)

Quartz's most-copied feature: hovering an internal link shows the target's opening. There is a cheap version here that nothing else has, because `publish-filter.py` already resolves the whole link graph and already knows every note's thesis. It can emit `data-thesis` on internal links at build time, and roughly thirty lines of CSS plus a small script turn that into a popover. No fetch, no second copy of the content, nothing at runtime that is not already in the HTML. A `title` attribute is the version with no JavaScript at all, if it turns out that is enough.

## 8. Footnotes as sidenotes (optional, depends on 4)

Once the grid from item 4 exists, footnotes can be moved into the right margin beside the paragraph that cites them, Tufte-style, instead of collected at the bottom. The Lighting notes are heavily footnoted and this suits them. It is genuinely large: Hugo emits footnotes as a list at the end of the document, so they have to be relocated, and the vertical positioning of a sidenote against its reference is the part that never quite works. It also conflicts with item 4's rail — both want the right margin — so it would need a rule about which wins on a page that has both. Worth wanting, not worth doing before the rest of the list.

## 9. Reading time in the dateline (optional)

`publish-filter.py` already counts words for `LONG_NOTE_WORDS`. Surfacing an estimate next to the date is a few lines. Given that half the notes are under 500 words, this may say more about the garden than is flattering, which is either a reason not to do it or the honest thing about a slip box.

## 10. Polish (optional)

A print stylesheet — these are essays, and people print essays; hide the masthead controls, unstick the rail, print link targets after external links. `prefers-reduced-motion` around the two transitions. A "follow system" third state on the theme toggle, which currently has no way back to the OS preference once a reader has chosen. Each is minutes; none is interesting; together they are the difference between finished and nearly finished.

## Rejected: a graph view

The canonical Quartz feature, and it should not be built here. Nineteen nodes with six edges is not a graph, it is a list with extra steps — the rendered picture would be five connected Lighting notes and thirteen dots. It needs a rendering library, which means either a build-time network fetch or vendoring a canvas library into a site that currently ships zero bytes of framework, and it works badly on the phones that most of this site's readers will use. Items 3 and 4 deliver what a reader actually wants from a graph view, which is "what else is near this", at a fraction of the cost. Revisit at a hundred notes if the link density has gone up with them.

## Sequencing

Item 1 first, because everything after it is judged by looking. Then item 2, the largest visible change, which wants the fixture page to land against. Then item 4. Then 5 and 6 as taste passes over a palette that has settled.

Item 3 is out of the first pass by choice, not by dependency; it can be taken at any point, including between the others, since it touches no file the rest of them touch. Items 7 through 10 are likewise independent of each other and of the rest.

Each item is its own PR, per the usual gate. Item 2 will not change the VM test's assertions — the test looks for a stylesheet, not for its contents — which is worth stating explicitly, because it means the gate is not evidence for any of this and the screenshots are.
