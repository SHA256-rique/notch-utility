# 0025 — Scan one level at a time, and never delete

**Status:** Accepted · **Date:** 2026-09-16

## Context

The Disk Map tab answers "where did my space go" and offers to reclaim some of
it. Two decisions dominate everything else about it: how much of the filesystem
to hold in memory, and what "clean it up" is allowed to mean.

## Decision 1 — size one directory at a time

The obvious design is to scan everything into a tree and then browse the tree.
DaisyDisk and GrandPerspective both do this and it gives instant navigation once
the scan finishes.

It is the wrong trade here. A home directory is two million files. A node per
file — URL, size, item count, children array — is hundreds of megabytes of
resident memory, held for as long as the tab is open, to answer a question about
the ten biggest folders. In an app whose entire argument is that it costs
nothing when you are not looking at it, that is not a defensible amount of RAM.

So `DiskScanner` sizes the **immediate children** of one directory, recursing
only far enough to total each child. Drilling in scans the next level.

**The cost**: each step re-walks a subtree, so navigating down five levels walks
the deepest one five times.

**What that buys**: memory bounded by the number of entries in one folder;
results that stream in progressively instead of arriving after a ten-second
freeze; and cancellation that actually works, so drilling in while the previous
scan is running abandons it rather than leaving four walks of `~/Library`
competing for the same device.

Allocated size, not logical size. `totalFileAllocatedSize` is what the file
occupies on disk including block slack; `fileSize` is the logical length, which
for a folder of a thousand small files understates the real cost substantially.
"How much will I get back" is the only question anyone opens this to answer.

## Decision 2 — nothing deletes

Every destructive action goes through `FileManager.trashItem`. Nothing calls
`removeItem`, anywhere in the tab.

The reasoning is asymmetric risk. An app that walks someone's home directory and
offers a Delete button has to be right *every single time*, because the failure
mode is unrecoverable and the blast radius is someone's work. Offering Move to
Bin instead means it only has to be **useful** — a wrong suggestion costs the
user a trip to the Finder, not a file.

`trashItem` also does things `removeItem` does not: it updates the Bin, it
refuses on things it should refuse on, and it returns the resulting URL so the
item can be found again.

## Decision 3 — a fixed cleanup list, not a heuristic

"Find me junk" is unbounded, and getting it wrong deletes someone's work.

Every quick-win category is a named directory whose *purpose* is to hold
regenerable data, with a sentence saying what happens if it goes — including the
uncomfortable ones. Downloads says "nothing regenerates these". Containers says
"this is real app state". DerivedData says the next build will be slow.

Nothing is ever removed without the user selecting it and confirming.

## Squarified treemap

Worth its own note because the naive version is a trap. Slice-and-dice
alternates horizontal and vertical cuts: areas are correct and the rectangles
are terrible — one enormous folder beside forty slivers a pixel wide. Slivers
are unreadable and, worse, unclickable.

Squarified (Bruls, Huizing & van Wijk, 2000) grows a row while doing so improves
its worst aspect ratio. About forty lines, and the entire reason a treemap earns
its place rather than being a prettier bar chart. There is a test asserting no
tile exceeds 12:1, which naive layout blows past by an order of magnitude.

Only the largest forty entries are drawn. Below that the rectangles are smaller
than their own labels, and a treemap of 400 slivers is a texture, not a chart.

## Costs we accepted

- Re-walking subtrees makes deep navigation slower than a cached tree would be.
- No global "scan the whole Mac" view, because that is precisely the thing whose
  memory cost was rejected. The quick-win categories cover the same ground for
  the directories that actually matter.
- Bundles are opaque: a 4GB `.app` cannot be drilled into. That is correct —
  it is one thing to the person looking at it — but it does mean the tab cannot
  tell you which resource inside an app is large.

## Revisit if

Someone genuinely needs whole-disk analysis. The right shape would be an
on-disk index built once and memory-mapped, not an in-memory tree — at which
point this is a different feature with a different budget.
