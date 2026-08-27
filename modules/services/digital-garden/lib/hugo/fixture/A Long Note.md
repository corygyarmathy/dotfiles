---
publish: true
thesis: A note long enough to scroll, sectioned enough to have a table of contents.
---

# A Long Note

Most notes in the real vault are short and have no headings at all. This one is the outlier, and the outlier is the case the navigation chrome has to be designed against: a page long enough that a reader loses their place, and sectioned enough that a list of its sections is worth the margin it takes.

## The first section

Every heading below is a `##`, because that is the level a table of contents lists. The rail shows nothing when a page has fewer than three of them, so this page has twelve and the other fixture notes have one or none — which is the ratio the real vault has, and the reason the rule exists.

## The second section

Linked to by name from another note, so that a fragment link is exercised rather than assumed. The anchor it resolves to is Hugo's, not one computed by the filter; the two agree for the headings Obsidian actually produces and can diverge on punctuation.

## The third section, whose heading is long enough to wrap in a narrow rail

A contents list is much narrower than the prose it describes, so its longest entry wraps where the heading itself does not. What that wrap looks like — whether the second line hangs, and how far — is a decision, and this is the heading that forces it to be made.

## Sticky positioning

The rail is sticky, so it stays in view while this text moves past it. The thing to watch is what happens at the very top and the very bottom of the page: at the top it should not overlap the masthead, and at the bottom it should not run past the footer.

## Where the current section is

Highlighting the section currently on screen turns a list of links into a sense of place. It costs an IntersectionObserver and about twenty lines, and it is the only JavaScript the rail needs. Without it the list is still useful; with it the page tells you where you are.

## What happens when the rail is taller than the window

Twelve sections fit. Twenty-nine, which the longest note in the real vault has, do not — which is why the list stops at `##` rather than descending to `###`. If it still overflows, it scrolls inside itself, and a nested scrollbar is a compromise rather than a design.

## Backlinks, in the rail rather than at the foot

A reader who wants to know what else cites a note wants that while they are reading it, not four screens below where they stopped. Moving the list into the margin is most of the argument for having a margin at all.

## Below twelve hundred pixels

The grid becomes one column, the contents list is hidden, and the rail falls back into the flow beneath this article — which is exactly the layout served today. One piece of markup produces both, so nothing has to be kept in step.

## The masthead and the footer

Both align to the prose column and not to the full page width. Getting this wrong puts the rule under the masthead a few pixels wide of the text it belongs to, which is invisible in a diff and obvious in a screenshot.

## Reading on a phone

Most of the space this design spends is space a phone does not have. Nothing above changes what a narrow screen gets, which is the point: the rail is an enhancement of the empty margin, not a redesign of the page.

## Printing

An essay is a thing people print. The rail should not print, the masthead controls should not print, and external links should print their targets — none of which the page currently does.

## The end of the note

The last section, so that scrolling to the bottom is a thing that can be done and the footer's spacing beneath a long article can be seen.
