# EDIT98 0.7.13 native viewport rendering

## Separate caches

Document paging and screen rendering are separate:

- `EditorBuf` keeps three 32-line document pages resident.
- The UI keeps one 77 x 21 cache of currently displayed native text cells.

Scrolling asks `EditorBuf` for only the logical pages needed by the viewport.
Search and save may walk other pages, but off-screen text is not rendered.

## Cell contents

Each viewport-cache cell records:

- character;
- native PC-98 text attribute;
- graphics backdrop color.

There is no font-family or bitmap-glyph field. A changed cell is painted by
clearing/filling its backdrop and calling `PutCell`; the hardware text ROM draws
the same glyph design used by the menus.

## Incremental updates

A redraw compares the desired viewport with the cache and writes only changed
cells. Adjacent changed spaces are cleared as a run. Caret blinking updates one
cell and synchronizes that cell in the cache.

An imported page-break record is resolved either as a native-font dashed
`Page Break` separator or as spaces, according to the persistent Show Page
Breaks option. Hiding it does not collapse line numbering.
