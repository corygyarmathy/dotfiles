# Plan: theme and navigation for the digital garden

Status: proposed 2026-08-27; decisions taken the same day, see _Decisions, 2026-08-27_ below. Extended 2026-08-31 with items 13-20, which came out of a design session held against live prototypes rather than against this document; see _Decisions, 2026-08-31_. Items 1, 2 and 4 were the agreed first pass; 5, 6 and 10 followed on the same day. Item 11 came out of a review on 2026-08-28 and is done. Item 3, the only item that fixed something broken today, was taken and is done on 2026-08-30. Item 16, the callout icons, was taken and is done on 2026-08-31 — the first of the 2026-08-31 set, per the sequencing that lets a small dependency-free item fill a short session. Item 18, the bonsai, followed on the same day, in the two sessions it was scoped as: the generator is done and on the landing page, and the taste pass is done after it — it also took item 15's filter half, because the tree's foliage needs the topic before it can be coloured. Item 15, the growth marks, topic hue and link marks, was taken next and is done: the sprite, the link marks and the /notes/ entries, reading the topic the bonsai's note_topic already writes. Two ideas asked for — a Kanagawa palette and a right-hand navigation column — plus seven more that came out of looking at what the site actually serves today. Everything below is scoped against `modules/services/digital-garden/lib/hugo/`, which is the whole design: four layouts, six partials, three render hooks and a 488-line stylesheet. There is no theme underneath to fight, so every item here is an edit to files this repository owns.

| #   | Item                                | Size   | Depends on | Status      |
| --- | ----------------------------------- | ------ | ---------- | ----------- |
| 1   | Rendering fixture + screenshot loop | small  | -          | **done** 2026-08-27 |
| 2   | Kanagawa palette                    | medium | 1          | **done** 2026-08-27 |
| 3   | An index of everything published    | small  | -          | **done** 2026-08-30 |
| 4   | Right-hand rail: contents, backlinks| medium | 1          | **done** 2026-08-27 |
| 5   | Link and image treatment            | small  | 2          | **done** 2026-08-27; the image mat reverted the same day |
| 6   | Typography                          | small  | 2          | built and **reverted** 2026-08-27 |
| 7   | Wikilink hover previews             | medium | -          | optional, and less urgent after 15 |
| 8   | Footnotes as sidenotes              | large  | 4          | **done** 2026-08-28 (#79) |
| 9   | Reading time in the dateline        | small  | -          | **absorbed into 17** |
| 10  | Polish: print, selection, motion    | small  | 2          | **done** 2026-08-27 |
| 11  | Rendering gaps found by review      | small  | 1          | **done** 2026-08-28 |
| 12  | The dateline in the empty margin    | small  | 4          | **superseded by 17** |
| 13  | Rename-stable ledger (defect)       | small  | -          | **done** 2026-08-31 (#118) |
| 14  | Maturity: model, counter, override  | medium | 13         | **done** 2026-08-31 (#121) |
| 15  | Growth marks, topic hue, link marks | small  | 14         | **done** 2026-08-31 |
| 16  | Callout icons on Obsidian's mapping | small  | -          | **done** 2026-08-31 |
| 17  | A margin on every note              | medium | 14         | not started |
| 18  | The bonsai                          | large  | 14         | **done** 2026-08-31; generator and taste pass |
| 19  | The home page, composed once        | small  | 18         | not started |
| 20  | Ambient Life on the 404             | small  | -          | **done** 2026-08-31 |
| -   | Graph view                          | -      | -          | **rejected**, see below; the bonsai is not a revisit |

## Decisions, 2026-08-31

Taken against a set of live prototypes rather than against swatches or this document — the same discipline item 1 exists to enforce, one level up. The prototypes are published at <https://claude.ai/code/artifact/fe8c2380-306f-4cc5-89c3-4ec2a7a7f60d> and are the reference for items 14 through 20: every number in them was computed from the real vault, so they show what the site would actually look like rather than what it might.

The 2026-08-27 decisions below all still stand. The three that were touched are named here.

- **Stock photography is out, and so is generative decoration.** The brief was "the site is a little boring", and the rejected answer is a stock image. The accepted answer is that everything added must _report something true about the note it sits beside_ — a maturity mark, a topic hue, a proportional section map, a tree whose every leaf is a note. Hash-derived abstract artwork was proposed and rejected on the same grounds as stock photography: it is decoration with no referent, and it ages into a gimmick faster than a photograph does.
- **Build-time diagram DSLs are rejected.** `d2` and `mermaid` were proposed for the Lighting notes and turned down: draw.io exports are already the working tool, and a DSL fights anything that is not its exact use case — network diagrams especially. The only improvement worth making is exporting with a transparent ground, which the stylesheet's own image comment already argues for.
- **Bookish set pieces are rejected.** Drop caps, letterspaced small-caps openings and fleuron section breaks were proposed and turned down: they look right in books and translate badly to a web page. Callout icons survived that cut, because an icon that names a callout's type is information rather than ornament — that is item 16.
- **Scale contrast is the one purely visual change accepted.** The stylesheet has nothing set above `1.75rem` and nothing below `0.8rem`, so the site has no scale contrast anywhere. Item 19 spends that on the home page only. This does **not** reopen item 6: the face is still the system stack, and a masthead at `4.25rem` is a size, not a change of voice.
- **Link kinds are distinguished by shape, not by hue.** Kanagawa gives about eight usable hues and the callouts have spent most of them, so a third axis was needed. Hue carries topic (two values today), and link kind is carried by mark instead — see item 15. The first attempt put a dot _before_ an internal link, which was wrong twice over: it was inconsistent with the external arrow that trails, and a leading dot reads as a bullet.
- **Maturity is computed, with a hand-written override that wins.** This follows the precedent `publish-filter.py` already sets for dates: the ledger is a default and not an authority, and frontmatter written by hand always wins. See item 14 for why the override is not optional.
- **Evergreen is set at 5.00, and exactly one note qualifies.** This was checked against the real scores and accepted as an accurate reflection of the vault rather than treated as a threshold to be tuned until it flattered.
- **The graph view stays rejected, and the bonsai is not a revisit of it.** See the rejection section at the foot of this document for why the two are different things.

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

Four notes: `Every Element` (every element the theme styles — headings h1-h4 including one that wraps, lists including the task lists the stylesheet does not style, blockquote, all eight callout hues plus an untitled and a folded one, two code blocks, a normal table and one wide enough to strain, a deliberately light-background SVG, inline and display maths, a footnote, a horizontal rule), `A Long Note` (twelve `##` sections, for the rail and for sticky behaviour), `Another Note` (so that a page has a backlink to render, and a heading fragment to resolve) and an index. Item 15 grew it to five: `A Seedling` (the lowest maturity the model records, sitting at the root so it carries the neutral mark too). The shelf assignment — `Every Element` to `_Slip_Box`, `A Long Note` to `_Reference/Lighting`, `Another Note` left at the root — came with the bonsai, which needed the folders before it could colour its foliage; item 15 inherited it, which is why the fixture's evergreens sit on different shelves and the marks read both hues.

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

## 8. Footnotes as sidenotes (done 2026-08-28, depends on 4)

Once the grid from item 4 exists, footnotes can be moved into the right margin beside the paragraph that cites them, Tufte-style, instead of collected at the bottom. The Lighting notes are heavily footnoted and this suits them. It is genuinely large: Hugo emits footnotes as a list at the end of the document, so they have to be relocated, and the vertical positioning of a sidenote against its reference is the part that never quite works. It also conflicts with item 4's rail — both want the right margin — so it would need a rule about which wins on a page that has both. Worth wanting, not worth doing before the rest of the list.

**Shipped 2026-08-28 in #79, and the table above said "optional" until 2026-08-31 — a bookkeeping error, corrected while adding items 13-20.** The margin conflict was resolved by not having one: the rail moved to the LEFT column and the sidenotes took the right, so neither needs the other to exist. The vertical positioning that "never quite works" took three follow-up commits to settle — overlap between notes cited from adjacent paragraphs, placement without waiting for a frame so a background tab does not open to a stack of unplaced notes, and capping the grid so the notes stay beside the prose on a wide monitor. All three are recorded in the comments in `baseof.html`, which is the right place for them. Item 17 inherits that geometry rather than changing it: it fills the left column, which is the one the rail already owns.

## 9. Reading time in the dateline (absorbed into 17, 2026-08-31)

`publish-filter.py` already counts words for `LONG_NOTE_WORDS`. Surfacing an estimate next to the date is a few lines. Given that half the notes are under 500 words, this may say more about the garden than is flattering, which is either a reason not to do it or the honest thing about a slip box.

Taken, and not on its own: the reading time belongs in the margin rather than in the dateline, so it ships as part of item 17. The "more than is flattering" worry stands and was accepted — the same argument settled item 14's evergreen threshold, and in both cases the honest number was preferred to the flattering one.

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

## 12. The dateline in the empty margin (superseded by 17, 2026-08-31)

### The problem

The rail renders on six of nineteen notes. On the other thirteen, a wide screen shows a 15rem left column of nothing while the dateline sits above the prose in the measure. The layout therefore reads as _"this site has a rail when it has one"_ rather than _"this site has margins"_, and the widest, emptiest version of the page is the one a reader on a large monitor gets.

### Approach

Move the dateline into the left column at the wide breakpoint, on the title's baseline where the rail's heading already sits, and leave it above the prose below it. The grid, the baseline alignment and the sticky behaviour all exist already; this is a second element placed in a column that is already built, and the narrow layout is the one the site has always served.

Item 9's reading time, if it is ever taken, belongs in the same place and is the reason to do these two together rather than separately.

The thing to check by looking, and the reason this is not obviously right: on a page that _does_ have a rail, the dateline and the rail's first heading are then both in the left column, and two small grey blocks stacked in a margin may read as a sidebar — which is the thing the single-column layout was chosen to avoid.

**Answered 2026-08-31, against a rendered margin carrying four blocks rather than two.** The worry does not materialise, and the reason is instructive: what makes a stack of grey blocks read as a sidebar is that the blocks are unlabelled and unordered. Given a small uppercase label each and an order that runs cheapest-fact-first — date, reading time, maturity, then the shape of the note, then who cites it — the same column reads as apparatus belonging to the essay. This item is therefore superseded by item 17, which does what it proposed and more; the diagnosis in _The problem_ above is unchanged and is still the reason to do it.

### Cost and risk

An hour, and it is entirely reversible. The risk is the one above, and it is a judgement that can only be made against the rendered pages.

## 13. Rename-stable ledger

### The problem

A live defect, found while looking for somewhere to keep a revision count. `update_ledger` is keyed on `path.stem.lower()` — the note's filename. Moving a note between folders is therefore safe, which is the property the docstring claims and it holds. **Renaming one is not**: the key changes, no entry is found, and the note is treated as seen for the first time. Its `published` date silently resets to today.

That is already happening to dates. It matters more from item 14 onward, because a revision counter kept in the same ledger would reset with it, and a count of rewrites that resets whenever a title is improved is worse than no count at all.

### Approach

Rename detection, the way git does it, using the hash the ledger already stores. After the publish set is decided: collect the ledger keys that have disappeared and the keys that are new. Where exactly one disappeared key and exactly one new key share a content hash, they are the same note — carry the entry across to the new key.

The 1:1 restriction is the whole of the safety argument. Two notes with identical content are rare but possible (a stub duplicated as a starting point), and a wrong carry is worse than a reset date: it would silently attribute one note's history to another. Anything that is not an unambiguous pair is treated as a new note, which is exactly today's behaviour.

### What to verify

The VM check grows one assertion: render a fixture, rename a note, render again, and assert `published` survived. Cheap to write and it pins the property rather than the implementation.

### Cost and risk

An hour. About ten lines in `publish-filter.py`, and it makes every later item's history durable.

## 14. Maturity: the model, the counter, and the override

### The problem

Nothing on the site says how developed a note is, and four separate items downstream want to know: the index (15), the link marks (15), the margin (17) and the tree (18). It has to be computed rather than hand-maintained — a maturity stage that must be edited by hand on every note is a stage that will be wrong on most of them.

### Approach

A score in `publish-filter.py`, emitted into frontmatter as `maturity` (the stage) and `maturity_score` (the number, for debugging and for the margin). Components, with the weights the prototypes were tuned to:

| Signal | Weight | Note |
| --- | --- | --- |
| Length | `min(words / 800, 1) * 2` | Saturating, not linear |
| Backlinks | `1.2` each | The only signal that comes from outside the note |
| Forward links | `0.5` each | Resolved against the published set |
| Sections | `+1` if `##` count >= 3 | Structured rather than dumped |
| Rewrites | `min(n, 4) * 0.35` | Commits whose diff exceeded 15 lines |

Stages: sapling at `1.5`, evergreen at `5.0`. On the vault as it stands that gives six seedlings, eleven saplings and one evergreen.

**Length saturates at 800 words on purpose.** A linear length term is what made two long unrevised notes outrank a short careful one, which is the failure that started this item. Past the saturation point, "longer" stops being evidence of anything.

**The override is not optional, and here is the evidence.** Take the three notes with no sections, no backlinks and no forward links: _Frustrations in Pursuing a Goal_ (399 words), _Managing Your Manager_ (1,078) and _Relationship with Work_ (1,594). On every signal the vault can compute, other than length, they are identical. The author's judgement is that the first is the most refined of the three; git says it has four commits and not one of them changed more than fifteen lines, while _Relationship with Work_ has ten commits and four substantial rewrites. Both facts are true. _Refined_ and _revised_ are different properties and only the second one is recorded anywhere. So the computed stage is a default, and a hand-written `maturity:` in the note wins — exactly as a hand-written `published:` already beats the ledger.

### The revision counter, and where history actually lives

The ledger gains a `revisions` integer, bumped whenever the stored hash changes. That works for both values of `source`, survives forever, and after item 13 survives renames.

It starts at zero for every existing note, which makes the signal worthless for about a year unless it is seeded. Git can seed it — the vault is a repository, `git log --follow` survives renames and moves, and counting commits whose diff exceeded fifteen lines gives the numbers used above. Two constraints decide how:

- The builder fetches with `git clone --depth 1` and `git fetch --depth 1` (`digital-garden.nix`, the "get the vault" block). On the server there is exactly one commit, so there is no history to count.
- `source` can be `obsidian-sync`, where there is no repository at all.

**Recommended: deepen the clone, and treat git as a seed rather than a store.** Drop `--depth 1` (or use `--filter=blob:none`, which keeps the history and skips the file contents the counting does not need); seed `revisions` from `git log --follow` the first time a note is seen; bump it from the hash thereafter. Under `obsidian-sync` the seed is simply skipped and the counter accrues from first deploy, which is a worse signal but not a broken one. The alternative — never seeding — is defensible only if the counter is understood to mean "rewrites since the ledger began", and it should then be labelled that way rather than called a revision count.

### What to verify

The VM check asserts the mechanism, not the aesthetics: that `maturity` is emitted for every published note, that a hand-written `maturity:` in frontmatter survives the filter unchanged, and that a note whose text changes between two runs has its `revisions` incremented while its neighbours do not.

### Cost and risk

Half a day, and it is the session everything else waits on. The risk is over-tuning the weights against nineteen notes: they are a starting point, they are all in one table in one file, and 800 is the number most worth revisiting once the vault has grown.

## 15. Growth marks, topic hue, and link marks

### The problem

Three separate wants, one sprite and one hue decision between them: an index that shows at a glance what is finished, a link that says whether it leads somewhere finished, and a page that shows which shelf a note came from.

### Approach

**The mark** is the site's own favicon, grown: seedling is the stem and one leaf, sapling adds the second, evergreen adds a crown. One SVG sprite of three symbols, a few hundred bytes, used in the index, in the margin (17) and on internal links.

**The hue** carries topic and nothing else. `_Slip_Box` takes lotusGreen/springGreen, `_Reference/Lighting` takes lotusOrange/roninYellow. This needs the filter to carry the source directory into frontmatter, which item 3 already identified as a small change to `publish-filter.py` and is the only place these two items touch.

**Done 2026-08-31, with item 18**, because the bonsai's foliage is coloured by topic and there was no topic to read. `note_topic` in `publish-filter.py` writes the note's own folder — the deepest one, so `_Reference/Lighting` is `lighting` and not `reference` — into `topic:` on every note, and the two hues above are declared once each in the stylesheet as `--topic`, which the foliage and the bonsai's caption both read. A new shelf in the vault is one line of CSS. What is left of this item is the sprite, the margin and the link marks; none of it is blocked any more.

**Link kinds are shape, not hue**, and all three marks trail so they are consistent with each other:

- a link to another note takes the target's maturity sprout, in the target's topic hue;
- a link to a section of the current note takes a dotted underline and no glyph, because there is no destination note to describe;
- an external link keeps the `↗` the stylesheet already emits.

This spends nothing from the hue budget, which was the objection that shaped it.

### Cost and risk

Two hours. The sprite and the CSS are small; the filter change is the same one item 3 deferred. Low risk, and every part of it is reversible in one file.

### Shipped, 2026-08-31

The three wants, and the shape rule that joins them, all landed as the item describes them.

**The mark** is a sprite of three symbols in `_partials/mark-icons.html`, and each is the tab icon grown one stage — seedling is the stem and one leaf, sapling adds the second, evergreen adds a crown — drawn as filled shapes in `currentColor`. The shape is the maturity and the hue is the topic, decided in different places on purpose: `_partials/mark-icon.html` knows only the shape, and the stylesheet's `.topic-*` rules — the same ones the bonsai's foliage reads — supply the hue. The sprite is gated exactly as the callout sprite is — a `hasMark` store flag set by the new `_markup/render-link.html` hook and by the index template, read in `baseof.html` — so a page with no internal links ships no sprite at all.

**The link kinds** are carried by shape, not hue, and all trail. `render-link.html` resolves the destination back to a page with `.Page.GetPage`, reads the target's `maturity` and `topic`, and trails a sprout on links to other notes; a link to a section of the same note (`[[#Heading]]`, an empty path and a fragment) takes `a.link-section`, a dotted underline with no glyph; an external link is left to the arrow the stylesheet already emits. A link to `/` is not a section link — it has a fragmentless empty path, so it resolves to the home page and takes the home page's own sprout. The hook does not touch footnote references — Goldmark builds those itself — which was the failure to look for, and the VM check's footnote assertions pass unchanged. A link to a page with no known maturity (the home page, a section) renders as it always did.

**The hue** reads the `topic` frontmatter the bonsai's `note_topic` already writes — this item's filter half arrived with item 18, which needed the topic before the tree could be coloured. A note's `topic` is its folder, slugified, and the marks carry it as the same `.topic-*` class the foliage uses, so `--topic` — `slip-box` green, `lighting` orange — is declared once in the stylesheet and serves the tree, the caption and the marks together; a new shelf in the vault is one line of CSS for all three. A note with no shelf (the empty topic) gets no class and falls back to `--muted`. On the /notes/ index each entry trails its note's mark, which is how the page now shows at a glance what is finished.

Two facts worth recording. **Forward links and backlinks count wikilinks only**, not the plain Markdown links the filter leaves alone — the check's fixture uses hyphenated filenames, so `[[On Money]]` does not resolve (`on-money` is the stem) and the link must be written `[[on-money|On Money]]`; the maturity model's signals are not affected by the fixture's phrasing otherwise. And **the marks print black**: the print stylesheet overrides `.mark` to `#000`, because a topic hue under toner is just a shade of grey and the sheet stays in one voice.

The VM check pins the mechanism rather than the aesthetics, which is the line this plan drew at the top: `topic` in the staging tree (the empty string at the vault root), the four index entries' sprout-and-topic pairs, the link hook reading the target's stage (on-money's hand-written evergreen included), the same-page link dotted, the external link untouched, the sprite present exactly where a mark rendered, and the stylesheet's two topic rules plus the absence of a rule for the unnamed `essays` shelf — the neutral case, which is an absence and so the thing a future edit reintroduces without noticing.

## 16. Callout icons on Obsidian's mapping

### The problem

The callouts are distinguished by hue alone. Obsidian distinguishes them by icon as well, and the vault is written in Obsidian — so the site currently renders less information than the editor it came from.

### Approach

One SVG sprite, stroked with `currentColor` so each icon takes its callout's existing hue, referenced from `_markup/render-blockquote.html` where the type is already parsed. Roughly 1KB for the full set.

**One mapping conflict to settle before building.** The stylesheet groups `important` with `example` on lotusViolet4/oniViolet. Obsidian does not: it gives `important` the flame — the same icon as `tip` — and `example` a list. So "match Obsidian" and "keep the current hue grouping" disagree on exactly one type. Matching Obsidian means `important` moves into the tip group and `example` keeps the violet on its own.

The icons drawn for the prototype match Obsidian's _choices_ rather than Lucide's geometry. Exact parity would mean vendoring Lucide's SVGs at build time, the way KaTeX already is; whether nixpkgs carries them has not been checked, and it should be before that is promised.

### Cost and risk

Two hours. No new failure mode: a type the sprite does not know renders exactly as it does today.

### Shipped, 2026-08-31

One sprite partial and one mapping partial, both in `layouts/_partials/`, and the render hook now drops a `<use>` into the callout title. The sprite is gated exactly as the KaTeX stylesheet is — a `hasCallout` store flag set in `render-blockquote.html` and read in `baseof.html` — so an iconless page ships no sprite at all, and a type the sprite does not know renders no icon, which is the fallback the plan priced in.

The mapping conflict was settled as the plan said: `important` moved into the tip group's green (the flame) and `example` keeps the violet alone. The fixture grows an `example` callout and the five types the old one-per-hue set never showed (`info`, `todo`, `success`, `danger`, `bug`), so every distinct icon is on screen. The VM check pins the settlement in the stylesheet (the green and violet pairs, and the old `important, example` grouping by its absence) and pins the icons on the served page: the sprite present only where a callout rendered, and each `<use>` naming a symbol the sprite actually defines — the "link to an uncopied asset looks right and 404s" failure from item 11, met from the same-document side.

Two facts worth recording. `pkgs.lucide` **does** exist in nixpkgs (0.563.0, riding flake.lock), so exact Lucide parity would have been a build-time copy exactly like KaTeX — it was not taken, because the prototype's own icons already matched Obsidian's choices and vendoring buys only geometry. And the type is now lowercased before it is used for the class, the icon and the default title, because Obsidian's callout types are case-insensitive and a `> [!NOTE]` should render exactly as `> [!note]` does; before this item the class silently depended on the marker's spelling.

## 17. A margin on every note (supersedes 12, absorbs 9)

### The problem

Item 12's problem, restated with the numbers that make it worse: the rail renders on six of nineteen notes, so thirteen notes show an empty 15rem column on a wide screen, and the layout reads as _"this site has a rail when it has one"_.

### Approach

The margin becomes unconditional and its _contents_ conditional. Always present: the dateline, the reading time (item 9), and the maturity mark from item 15. Present when the note has them: the section map, and the backlinks the rail already carries.

**The section map is item 4's contents list drawn to scale.** One block per `##` section, its height proportional to that section's word count, so the strip is a scale map of the document. The block for the section being read is picked out, and — this is what makes it better than a list — it _fills from the top as the reader moves through that section_, so the mark advances continuously instead of jumping a whole block at each boundary. The observer in `baseof.html` already tracks the current heading and can be reused; the within-section fraction is arithmetic on offsets.

**The part this plan cannot price from the outside**: Hugo's `.Fragments.Headings` gives the heading tree but not the word count of each section. The cheap answer is to compute them in `publish-filter.py`, which already parses the body, and emit them as frontmatter alongside the headings. That should be confirmed before the session starts, because if it is wrong the item is larger than it looks.

### Cost and risk

Half a day. The risk that item 12 recorded — two grey blocks reading as a sidebar — was checked against a rendered margin and did not materialise; see the note under item 12 for why labels and ordering are what prevent it.

## 18. The bonsai

### The problem

The site's one moment of visual interest, and the answer to the brief that started all this. Not decoration: a picture of the vault's actual state, in which the trunk is the site, each branch carries several notes, and every published note is one foliage pad whose glyph is its maturity and whose colour is its topic. Add a note and the tree grows; rewrite one and its pad changes.

### Approach

Generated at build time by a small module beside `publish-filter.py`, emitted as static markup — a few kilobytes of `<span>`-wrapped characters — so the page ships no generator and no library. The growth animation is one small script that reveals the characters in the order they were drawn; `prefers-reduced-motion` gets the finished tree.

The growth model is `cbonsai`'s, with one rule changed. **Branch count grows as the square root of the note count and each branch carries several notes**, dropping each note's pad at its own point along its length. One shoot per note — the obvious rule — makes wood grow as fast as the canopy, and the tree becomes a thicket somewhere past sixty notes. Under the square-root rule eighteen notes get seven branches, sixty get thirteen, two hundred get eighteen: the canopy fills in while the wood barely changes, and every note keeps its own pad.

**The foliage is navigation.** Each pad carries the index of the note it grew from, so pointing at one lights every character of that note's pad and names it, and a click opens the note. The tree stays `aria-hidden` and this stays an _enhancement_: eighteen tab stops made of single characters would be a worse route to a note than the `/notes/` index, which is already the complete accessible path. On a touch screen there is no hover, so a tap opens the note rather than revealing a caption first.

### Four bugs already found, recorded so they are not rebuilt

Each of these was met in the prototype and each is invisible in a screenshot of a single tree, which is why they are written down rather than left to be rediscovered.

- **Foliage below the soil.** A branch leaving the trunk low down drifts downward until its pad lies on the ground beside the tree. Branches may sag by one row but never descend below where they left the trunk, nothing may be drawn at or below the soil line, and branches leave the upper half of the trunk only.
- **The dropped branch.** The last branch's fork point, computed as a fraction of the trunk's length, landed one step past the end of it — so it never grew and the notes riding on it were silently absent. Clamp the fork points to the last trunk step.
- **The invisible note.** A pad whose every cell landed on already-occupied cells places nothing, and that note is then neither visible nor hoverable. Search outward for a free cell, and **assert that the number of distinct notes on the tree equals the number published** — this is the assertion that caught both of the above.
- **The vertical trunk.** A trunk whose sideways step is a fresh random number each step averages to vertical however wide the range. The lean has to persist across steps and reverse occasionally.

### What shipped, 2026-08-31

The generator, wired end to end: `modules/services/digital-garden/bonsai.py`, called by `publish-filter.py`, rendered on the landing page. The growth model is the prototype's, ported rather than reinterpreted — the branch-count rule reproduces all three numbers quoted above exactly (18 notes → 7 branches, 60 → 13, 200 → 18), and all four recorded bugs are prevented by construction, with the note-count assertion live in the build rather than left as a development aid.

Four things the plan did not price, all of them decisions rather than surprises:

- **The tree has to be the same tree every build.** The builder skips a rebuild when the staging tree hashes the same as last time, so a generator that reseeded itself would defeat that gate and rewrite the site on every tick. So the seed is fixed, and the PRNG is written out in the file rather than taken from `random`: CPython's Mersenne Twister is stable in practice, and "in practice" is not the right guarantee for something whose output is hashed. Mulberry32 is nine lines and makes the tree a function of this file alone.
- **The markup travels through the staging tree, and is not a note.** The filter is the only thing that knows the published set, and the renderer is the only thing that knows Hugo — so the filter leaves `bonsai.html` in the staging tree and `lib/hugo.nix` moves it into `assets/` before Hugo looks at the content directory, which is the same division that already renames `index.md` to `_index.md`. Into assets rather than `layouts/_partials/` deliberately: a partial is _executed_ as a template, and generated markup has no business going through a template engine. `resources.Get` also returns nothing when there is no tree, which is the whole of the "render a content tree that did not come from the filter" case.
- **`publish-filter.py` and `bonsai.py` are one program in two files, which Nix does not hand you for free.** `${./publish-filter.py}` puts each file in a store path of its own, so the import does not resolve; the two are assembled into one directory, and that directory is now exposed from the module the way the renderer already was, so `garden-preview` cannot drift from the server.
- **Item 15's filter change came with this one**, because the pad's colour is the note's topic and there was no topic to read. `note_topic` writes the note's folder, slugified, into frontmatter for every note. That is the piece the plan said these two items share; the sprite and the link marks are untouched.

The **fifth bug**, found here and not in the prototype: the soil was never drawn. It went through the same bounds check as the foliage — the one that rejects everything at or below the soil line — so the colour was declared, the loop ran, and every cell of it was refused. Invisible in a screenshot for the same reason the other four were: you cannot see what is not there. The ground is now drawn on the row the trunk starts on, below the ceiling every other rule respects, because it is not something that grew.

Two things were settled by rendering rather than by reasoning, which is item 1 doing its job: the soil's first colour pair (lotusWhite0 over winterYellow — the border tint and the diff ground, both picked by name) was a line you had to hunt for in light and absent in dark, and is now each theme's grey; and the fixture's three notes were re-filed into the vault's own folders, because a fixture whose notes all sat at the root drew its whole canopy in the no-topic fallback and proved nothing about the two hues the stylesheet declares.

### The taste pass, which is a second session

The generator is one session; making the tree _look_ right is another, and it should not be rushed into the first. The known open problem is that at high note counts the canopy reads as fairy floss — a single ball on a stick. The levers are branch count against pad size against trunk length, and the judgement can only be made by generating many and looking. `garden-preview --fixture` plus a seed control is the loop.

**Done 2026-08-31**, and both of the observations recorded above turned out to name the same fault. Three numbers moved, a fourth was added, one of them was in the stylesheet, and none of them was the one the generator predicted.

**The lever was the trunk, not the canopy.** `SPREAD` was documented as "the one knob the taste pass is expected to move" and it is the one knob the taste pass did not move: at 1.4 the canopy closes into a single blob and at 2.1 it breaks into scattered small pads, so 1.7 survived being tried. Ball-on-a-stick was never a canopy problem. The trunk ran thirteen steps plus a step per branch and climbs a row on about seven steps in ten, so it stood most of the canvas high on its own, and every branch forked from the top 45% of it — the canopy had nowhere to sit but on top. `TRUNK_BASE` 13 → 8 and `FORK_LO` 0.55 → 0.35 (with `FORK_SPAN` 0.44 → 0.55) are the whole of the fix, and they are worth stating in the same breath because either alone only moves the problem: a shorter trunk with high forks is a shorter stick, and low forks on a tall trunk still leave the top half bare.

Measured over 48 trees at eighteen and sixty notes, the bare trunk under the lowest foliage went from a third of the tree's height to a sixth, worst case from a half to a quarter. 0.35 is also where a trained bonsai's first branch goes, which is not why it was chosen but is a good sign about where looking landed.

**Nothing sprouts from the soil at 0.35, and the "upper half only" rule was never what guaranteed that.** `ceiling` and the no-descent clamp in `branch` are what hold foliage off the ground; the fork fraction was belt-and-braces, and it was the braces that caused the fault. Checked rather than assumed: no leaf lands on or below the soil row across 39 seeds at every note count from 1 to 500, and the equal-count assertion never fires.

**A fifth thing found by looking, and a trap next to it.** The trunk sweeps, and a sweep that only reverses at random walks the base out from under its own canopy until the tree reads as falling over — 6.6 columns of base-to-canopy offset on average. The tempting fix is to reverse the lean more often, and that is exactly the fourth recorded bug coming back in: a lean that reverses half the time _is_ a fresh random sign each step, which averages to a vertical trunk. So the lean is as persistent as it ever was and is reined instead — past `LEAN_REIN` columns from the base, a lean still heading away turns back. Offset 6.6 → 2.8, and the sweep survives.

**The `font-size` ceiling was sized for a vault ten times this one.** 1rem is the size at which a two-hundred-note tree still fits the measure without scrolling, and paying for that today made the picture under half the width of the measure — a sketch of the tree rather than the page's one picture. At 1.25rem every vault up to about a hundred notes fits and `.bonsai-plate` already scrolls past that. Item 19 will compose this page around the tree and may want the scale again; this is the size it should start from.

**What was checked by looking, since that is the whole point of this session.** Trees at 12, 18, 30, 45, 60, 100 and 200 notes; six seeds at eighteen; before and after on the real nineteen-note vault through `garden-preview`, rendered in both themes at 1280px. One thing the terminal loop cannot show and the browser did: the growth animation means a screenshot taken too early catches a half-drawn tree, so every comparison here was taken with the animation allowed to finish.

The terminal loop is what made this affordable, and it is worth keeping: `python3 modules/services/digital-garden/bonsai.py --notes 60 --seed 3 --spread 2.1` draws a tree with no vault, no build and no browser in it. But the numbers that decided it came from measuring many trees at once, not from reading them one at a time — bare trunk as a fraction of tree height, and base-to-canopy offset in columns. Neither is a judgement; both are filters, and looking is still what chose.

### Cost and risk

A day for the generator, and a second session of unknown length for the taste pass. The risk is the second one: this is the only item on the list where "correct" and "good" are different questions, and the plan should not pretend the second is estimable.

The second session came in at about half a day, and refusing to estimate it was right for a reason that is not the obvious one. It was cheap not because the judgement was easy but because the generator session had left a command that draws a tree in a terminal — the estimate would have been wrong in either direction depending on a decision taken in the session before it.

## 19. The home page, composed once

### The problem

The landing page is an `h1` and a list. It is also the page that carries the tree, and a large tree next to a small heading is two unrelated things sharing a screen.

### Approach

One composition: the site title at roughly `4.25rem`, a colophon line counting the garden from item 14's model — _"18 notes, 1 evergreen, 11 growing, 6 seedlings"_ — and the tree beside it, growing once on arrival. Home page only; interior pages keep the masthead they have.

A grey SVG seedling set behind the title was prototyped and dropped: the fix for a weak mark is not a better mark but not having two plants on one page. The tree is the mark.

This is the item that spends the scale contrast the decision above allows, and it does not reopen item 6 — the face is the system stack at a larger size.

### Cost and risk

Two hours, and it is the largest change in how the site feels for the least code on this list.

## 20. Ambient Life on the 404

Conway's Game of Life, seeded from an R-pentomino, running quietly in `--border` on the 404 page. About a kilobyte, paused when scrolled out of view and when `prefers-reduced-motion` is set.

It is the one thing on this list that reports nothing — the cells are cells, not notes — which is why it is confined to the page where the reader has nothing to read. It is deliberately **not** on the home page: two growing things on one screen is one too many, the same argument that removed the seedling from item 19.

### Shipped, 2026-08-31

One `<canvas>` and one inline script in `layouts/404.html`. The plan guessed "about a kilobyte"; the script is about 2.5KB of code, and Caddy's gzip makes it about 1.3KB on the wire — the number that matters for a page this rare, and the estimate was optimistic about how much the two pauses and the reseed cost.

The first pass put it in the empty left margin the way the rail does, and the preview showed two things wrong with that: the page felt off balance with a lone thing in the side column, and 240px was too small for a patch that is supposed to look cool. It now sits centred in the body, directly beneath the message — the centre of the 404 is its one piece of empty body, and a thing that lives only to look cool belongs where the eye lands. The canvas doubled to 480×312 (80×52 cells), which also gives the R-pentomino room to develop before its gliders leave.

The same preview showed that the plan's "quietly in `--border`" was quieter than it should be: in the site's quietest colour on the bare page, the cells read as invisible. They are now `--accent` on a `--code-bg` well with a `--border` frame — the code well's own recess, so the panel needs no new colour, and the accent is the site's alive colour. The cells still read `--accent` from the computed style each frame, so a theme change repaints with nothing to observe it.

One thing the build made obvious that the plan did not say: on a bounded grid the R-pentomino's gliders fly off the edges and the rest settles, so the page goes still within a minute. The reseed when the population stops changing is what keeps it alive — the plan named the seed and not the cycle, and the cycle is the difference between life and a screenshot.

Both pauses are behaviour, so the VM check runs the page in headless Chromium rather than grepping for it: the script writes its running state and population back to the canvas as data-attributes, and the check reads those to assert it runs, that it pauses under `prefers-reduced-motion`, and that it pauses out of view — plus the plan's own "not on the home page" pinned as a negative, and the centred-beneath-the-message placement pinned as a positive. No cost over the estimate; the Chromium machinery was already in the test.

## Rejected: a graph view

The canonical Quartz feature, and it should not be built here. Nineteen nodes with six edges is not a graph, it is a list with extra steps — the rendered picture would be five connected Lighting notes and thirteen dots. It needs a rendering library, which means either a build-time network fetch or vendoring a canvas library into a site that currently ships zero bytes of framework, and it works badly on the phones that most of this site's readers will use. Items 3 and 4 deliver what a reader actually wants from a graph view, which is "what else is near this", at a fraction of the cost. Revisit at a hundred notes if the link density has gone up with them.

**Still rejected, 2026-08-31, and item 18 is not a revisit of it.** The two get confused because both put a picture of the garden on the home page, so the distinction is worth stating. A graph view draws the _edges_ — it is a picture of the link structure, and this vault's link structure is six edges across nineteen notes, which is the thing that is not worth drawing. The bonsai draws no edges at all: it is a picture of the _set_ of notes and of each note's own properties, which is information the vault genuinely has and has a lot of. Both of the practical objections above also fall away — it needs no rendering library, because it is characters, and it works on a phone, because it is text that scrolls in its own box. If the link density ever does go up, the graph view becomes worth reconsidering on its own merits and the bonsai has no bearing on that decision either way.

## Sequencing

Item 1 first, because everything after it is judged by looking. Then item 2, the largest visible change, which wants the fixture page to land against. Then item 4. Then 5 and 6 as taste passes over a palette that has settled.

Items 5, 6 and 10 were taken together on 2026-08-27, in that order, which is the order the plan gives them: the link treatment and the face are both judged against the palette, and the polish is judged against both.

Item 3 is out of the first pass by choice, not by dependency; it can be taken at any point, including between the others, since it touches no file the rest of them touch. Items 7 through 9 are likewise independent of each other and of the rest.

Each item is its own PR, per the usual gate. Item 2 will not change the VM test's assertions — the test looks for a stylesheet, not for its contents — which is worth stating explicitly, because it means the gate is not evidence for any of this and the screenshots are.

That held for items 2, 4 and 5, and stopped holding at item 6, which added two assertions: a webfont is not a colour — the file either is served from this site or it is not, and if it is not, nothing fails, every reader silently gets their own serif. When the face was reverted one of the two went with it and one stayed, which is the useful line between them. The file being served was a fact about a decision that got reversed; **the stylesheet naming no font CDN** is a fact about the property this whole toolchain exists to hold, and it holds whether or not there is ever a webfont again. The rest of the judgement is still the screenshots'.

Item 11 was not sequenced at all — it came out of a review on 2026-08-28 and every part of it was a defect or a gap rather than a design decision, so it was taken immediately and in four commits rather than one PR per item. It moved the line above again, in the same direction item 6 moved it: two more assertions now guard properties the screenshots cannot, because _"the build was clean, the CSS was present, the table rendered, and the page was wrong"_ is the failure this project keeps meeting and the only one the gate can be taught to catch.

Item 12 depends on item 4 and on nothing else, and is worth doing at the same time as item 9 if item 9 is ever taken, since both put a small grey line in the same place. Item 3, taken 2026-08-30, made "reachable only by search or by a backlink" a sentence in the past tense: fourteen of nineteen notes used to be reachable that way, and none is now.

## Sequencing, 2026-08-31: one item per session

Items 13 to 20 are scoped to be taken **one per session**, deliberately, because the context needed to do any one of them well is much smaller than the context needed to hold all eight. Each names its own files, its own verification and its own open questions, so a session can start from this document and the prototype sheet without replaying the design conversation.

The order is fixed by dependencies for the first two and by taste after that.

1. **Item 13, the rename-stable ledger.** First, and on its own, because it is a live defect rather than a feature: every day it is not fixed is a day a renamed note can lose its publication date. It touches one function and it makes everything after it durable.
2. **Item 14, maturity.** The hinge. Items 15, 17, 18 and 19 all read what this session computes, and none of them can be built honestly before it exists. It is also the session that decides the clone depth question, which is the only decision here that reaches outside `publish-filter.py`.
3. **Item 16, callout icons.** Out of dependency order on purpose: it depends on nothing, it is small, and it is a good session to take when there is not room for a large one. Settle the `important` mapping conflict first.
4. **Item 15, growth marks and link marks.** Small, and the first session where item 14's work becomes visible on the site.
5. **Item 17, the margin.** Medium. Confirm the per-section word count question before starting; if the answer is not "compute it in the filter", re-price the item.
6. **Item 18a, the bonsai generator.** Large. Build to the four recorded bugs and the equal-count assertion, and stop when the tree is correct rather than when it is beautiful.
7. **Item 18b, the bonsai taste pass.** Unestimated by design. Generate many, look at them, tune the three levers. Done 2026-08-31; the three levers were the wrong three, and the trunk was the one that mattered.
8. **Item 19, the home page.** Last, because it wants the tree finished. It is finished, so this is the next one.
9. **Item 20, the 404.** Any time; it depends on nothing and blocks nothing.

Item 7 is the only optional item still outstanding — item 8 shipped on 2026-08-28 and the table has been corrected. It is less urgent after item 15 — the maturity sprout on an internal link already answers most of "is this worth following", which was the value the hover preview was reaching for — so if it is ever taken it should be taken as the `title` version first, and judged against a site that already has the marks.

The rule from the top of this document still governs all of it: **each item is its own PR, per the usual gate, and the gate is not evidence for any of this.** The VM check can assert that maturity is emitted, that a rename preserves a date, that every published note appears on the tree — properties, all of them. Whether the tree looks like a bonsai and whether the margin looks like apparatus rather than a sidebar are questions only the screenshots can answer, and item 1 exists so that they can be asked cheaply.
