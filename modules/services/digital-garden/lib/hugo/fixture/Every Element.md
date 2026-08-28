---
publish: true
thesis: Every element the theme styles, on one page, so a stylesheet change can be judged by looking.
---

# Every Element

The opening paragraph, which exists to be read at the measure the stylesheet caps prose to. It carries _emphasis_, **strong emphasis**, `inline code`, an ==Obsidian highlight==, a [link to another note](/another-note/), a [wikilink](/a-long-note/), and an [external link](https://gohugo.io) that should be marked as leaving the site. It also carries a footnote.[^1]

A second paragraph, so that the spacing between two paragraphs is visible and not inferred from the spacing between a paragraph and something else, and so that a footnote here is far enough from a footnote above it for the margin placement to be judged rather than assumed.[^2]

## Sidenotes

Footnotes move into the right margin beside the paragraph that cites them, and this whole section exists so that there are enough of them in enough places to see whether that placement holds together — one at the top of the page, one mid-page, and one at the foot of a long section.[^3] A note with more than one footnote in a single paragraph is the stress case, because the margin then has to separate the notes without overlapping.[^4] And a second note in the same paragraph confirms it.[^5] A single note can be cited more than once, and it must still appear once — not once for every citation.[^3]

## A heading, and under it the shortest possible section

One line.

### A third-level heading

Sections nest three deep in the real vault and no deeper, so this is where the heading scale stops mattering.

#### A fourth-level heading, which is as deep as the stylesheet styles

Below this, headings fall back to the browser's own sizes — which is worth seeing rather than assuming.

## A heading long enough to wrap onto a second line at the measure this page is capped to

Headings wrap. The line-height they wrap at is set separately from the body's, and the only way to check it is to have one that wraps.

## Lists

- An unordered item
- An item with a nested list under it
  - The nested item
  - A second nested item, long enough to wrap onto a second line so that the hanging indent is visible rather than assumed
- A third item

1. An ordered item
2. A second ordered item
3. A third, so the widest marker is two characters wide

- [ ] An unfinished task, which Obsidian writes as a checkbox and the stylesheet gives the marker column to
- [x] A finished one

## Quotation

> A blockquote, set apart from the prose around it by a rule and a colour rather than by an indent alone.
>
> Its second paragraph, because a one-paragraph quote hides how the margins inside it behave.

## Callouts

Obsidian's callout syntax, rendered by `_markup/render-blockquote.html`. Every type the stylesheet names a hue for appears here, because the point of the set is that it reads as one family and only the hue changes.

> [!note] A note
> The default type, and the one every unknown type falls back to.

> [!abstract] An abstract
> Also reachable as `summary` and `tldr`.

> [!tip] A tip
> Also `hint`, `success`, `check` and `done`.

> [!important] Something important
> Shares its hue with `example`.

> [!question] A question
> Also `help` and `faq`.

> [!warning] A warning
> Also `caution` and `attention`.

> [!failure] A failure
> Also `fail`, `missing`, `danger`, `error` and `bug`.

> [!quote] A quotation
> Also `cite`. Rendered in the muted role rather than a hue of its own.

> [!note]
> A callout with no title, which takes the type's name as its heading.

> [!tip]- A folded callout
> Foldable callouts are `<details>`, and the title row is the disclosure control. This body is hidden until it is opened.

## Code

A fenced block, with one line long enough to need a horizontal scrollbar inside its own box rather than making the page scroll sideways:

```nix
{
  # A comment at a comfortable width.
  services.digital-garden.baseUrl = "garden.example.com";
  services.digital-garden.footerLinks = { GitHub = "https://github.com/example/dotfiles"; RSS = "https://garden.example.com/index.xml"; Contact = "mailto:someone@example.com"; };
}
```

And a block with no language, which gets no highlighting and should still get the well:

```
$ garden-preview --fixture
rendered in 84ms
```

## Tables

| Token       | Role                        | Light     | Dark      |
| ----------- | --------------------------- | --------- | --------- |
| `--bg`      | The page behind the text    | `#f9f6e1` | `#1F1F28` |
| `--text`    | The text on it              | `#545464` | `#DCD7BA` |
| `--muted`   | Datelines, theses, captions | `#716e61` | `#727169` |
| `--accent`  | Links and the masthead      | `#4d699b` | `#7E9CD8` |

A table wide enough to scroll inside its own container:

| Note                        | Words | Headings | Backlinks | Published  | Modified   | Thesis                                                       |
| --------------------------- | ----- | -------- | --------- | ---------- | ---------- | ------------------------------------------------------------ |
| Riverview Lighting Upgrade  | 5871  | 29       | 0         | 2026-08-23 | 2026-08-27 | A year of volunteer work, written down while it is still true |
| Relationship with Work      | 1604  | 0        | 0         | 2026-08-23 | 2026-08-23 | Work is a trade, and a trade has two sides                    |

## An image

Diagrams in the vault are frequently light-background scans and exports, which is the case worth looking at on a dark page:

![[fixture-diagram.svg]]

## Mathematics

Inline maths, $E = mc^2$, captured by the passthrough extension and rendered at build time. And a display equation, which scrolls inside its own box when it is wider than the measure:

$$
\int_{0}^{\infty} \frac{x^{s-1}}{e^{x} - 1} \, dx = \Gamma(s) \zeta(s), \qquad \Re(s) > 1
$$

A paragraph mentioning two amounts, $80 and $400, because that shape once read as an inline equation and took a build down.

---

A horizontal rule sits above this line.

[^1]: The footnote itself, which renders in a list at the foot of the page with a link back to the reference.

[^2]: A second footnote, near the top of the page but below the first, so the vertical gap between two sidenotes is a thing that is looked at.

[^3]: A footnote in the middle of the note, on its own section, so sidenotes are seen against headings rather than only against a wall of prose.

[^4]: The first of two footnotes in one paragraph. Multiple notes in the same paragraph are the hardest case for a sidenote margin, because they must stack without overlapping.

[^5]: The second footnote in the same paragraph as the fourth, which is how a column of sidenotes has to separate its entries.
