# WeRead annotation overlay (reflowable documents)

Plugin-owned annotation layer that projects WeRead underlines and thoughts onto
reflowable CREngine documents without modifying the source book or KOReader's
own notes.

## Why an overlay instead of native annotations

- Projections never enter `ui.annotation.annotations` and are never written to
  the book's `.sdr` list, so clearing or re-syncing WeRead data cannot touch the
  reader's own highlights.
- Each local book gets an isolated SQLite database under
  `<KOReader data>/weread/external-annotations/`, keyed by file path. Moving or
  replacing a book requires matching it again.
- Coordinates are stored as XPointer ranges. `Store.documentKey` mixes path,
  file size, mtime and the CREngine revision, so a replaced file or an engine
  upgrade invalidates stored coordinates instead of silently reusing them.
- Underlines are painted through KOReader's supported
  `ReaderView:registerViewModule()` extension point, inside the same paint pass
  as the page, so projecting a mark never requests a second e-ink refresh.
- Tap hit boxes stay separate from KOReader annotations and open the existing
  native WeRead thought popup.

## Invalidation

Page-mode projections are cached. `Overlay:invalidate()` drops the rectangle
cache and bumps the generation counter; `Overlay:setRecords()` additionally
clears the ordered-lookup prefix cache. The controller invalidates on typography
reflows (`UpdatePos`) and on `DocumentRerendered`, because the current page
number can stay the same while the text reflows underneath it.

## Manual test

1. Open a local EPUB (or any reflowable CREngine document).
2. `Tools -> WeRead -> Underlines and thoughts management`, bind the book to its
   WeRead title and synchronize.
3. Close the menu: synchronized ranges should be underlined.
4. Tap an underline outside the configured page-turn edge; the normal WeRead
   thought popup opens.
5. Change font size, line spacing, margins and orientation: underlines must
   follow the same text after the rerender.
6. Toggle `Show underlines and thoughts` in the WeRead menu: it controls both
   downloaded WeRead books and local-book overlays.
7. Clear the local-book annotation data: the source book and the KOReader note
   list stay unchanged.

## Limits

- Reflowable CREngine documents only; fixed-layout PDF/DjVu coordinates are out
  of scope.
- Records are keyed by file path, so moving or replacing a book requires
  matching it again.
- Quote matching can miss ranges when the local edition differs from the WeRead
  edition.
