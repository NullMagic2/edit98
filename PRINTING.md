# EDIT98 0.7.13 printing

## Paper formats, margins, and raw printer transport

The Print dialog now selects a paper template and portrait/landscape orientation before page counting. Built-in
templates are:

- `A4` — 21.0 x 29.7 cm (default)
- `Letter` — 21.6 x 27.9 cm
- `Legal` — 21.6 x 35.6 cm
- `Tabloid` — 27.9 x 43.2 cm
- `Document geometry` — preserves the imported RTF/plain-text print geometry
- `Custom 1` through `Custom 4` — user-defined width and height

`Custom...` opens a small editor for the four custom slots. Each slot accepts
width and height from 5.0 through 64.0 cm. Saving a slot immediately writes its
dimensions to `EDIT98.CFG`. Deleting a slot clears it. The selected template and orientation are also persisted when the Print dialog is accepted.

Portrait and Landscape are selectable in the same Print dialog. For physical paper templates, Landscape swaps the paper width and height before the fixed-pitch grid is resolved. `Document geometry` remains the imported row/column geometry and is intentionally unaffected by orientation.

Top, Bottom, Left, and Right margins remain editable in the same Print dialog,
default to 0.5 cm, and are persisted independently. Thus a user can combine any
paper template with any saved margin set.

EDIT98 outputs fixed-pitch PC-PR201 text. On the NP21/W PC-PR201-to-GDI path
used by the Windows 11 target, the emitted ANK/ASCII grid is effectively 13.3 CPI
horizontally while line spacing is 6 LPI. Paper width and horizontal margins are
therefore converted on the same 13.3-CPI grid; paper height and vertical margins
remain 6 LPI. Before the first page, 0.7.13 emits a deterministic PC-PR201 setup
prologue that resets printer state, selects high-density pica, selects the
3/20-inch Kanji grid (`FS A`) that matches the 13.3-CPI half-width grid, selects
1/6-inch line spacing, and restores forward line feed.

The previous corrective build used `FS B`, but that command changes only the
two-byte Kanji pitch. It does not change the one-byte ANK/ASCII pitch, so PDF
output continued to wrap A4 at 79 columns and left a large artificial blank area
on the right. With the corrected geometry, A4 plus 0.5 cm left/right margins
resolves to 104 printable columns. The host printer or PDF driver should still
be configured to the matching paper size when exact physical dimensions are
required.

The printer transport continues to use an untyped binary file and `BlockWrite`
for the DOS `PRN` stream.

## User interface

`File > Print` and `Ctrl+P` open one dialog containing page mode, paper template, portrait/landscape orientation, `Custom...`, and Top/Bottom/Left/Right margins. `Tab` visits every control. When the paper field has focus, Left/Right, Space, or Enter cycles templates. When Orientation has focus, Left chooses Portrait, Right chooses Landscape, and Space or Enter toggles the orientation. `P` and `L` are direct shortcuts. Press `C` or activate `Custom...` to edit custom paper slots.

The persisted print-related configuration keys are `PRINTPAPER`, `PRINTORIENTATION`,
`PRINTMARGINTOP`, `PRINTMARGINBOTTOM`, `PRINTMARGINLEFT`, `PRINTMARGINRIGHT`,
and `CUSTOMPAPER1WIDTH/HEIGHT` through `CUSTOMPAPER4WIDTH/HEIGHT`. Values are
stored as tenths of a centimetre, so `5` represents 0.5 cm and `210` represents 21.0 cm. `PRINTORIENTATION=0` is Portrait and `PRINTORIENTATION=1` is Landscape.

## Margin model

EDIT98 prints fixed-pitch text rather than a printer-specific page-description
language. For the NP21/W converted-printer target, horizontal margin values are
converted using the effective 13.3-CPI ANK grid and vertical margins at 6 LPI,
rounded to the nearest whole character column or printer row. The left margin is
emitted as leading spaces; the right margin reduces wrapping width. The top
margin is emitted as blank rows at 6 LPI; the bottom margin reduces the content
rows available before the form feed. Page counting uses exactly the same
resolved geometry as printer output.

## Automatic page numbering

0.7.3 counted only explicit RTF `\\page` / form-feed markers. Many normal RTF
files contain no such marker because their pages are created by layout flow;
those documents were therefore incorrectly reported as one printable page.

0.7.10 uses deterministic text-printer pagination from the selected paper
template:

- A4, Letter, Legal, and Tabloid are converted to fixed-pitch columns at the NP21/W target's effective 13.3 CPI and rows at 6 LPI;
- Document Geometry uses the imported document base columns and rows;
- custom templates use their saved width and height in centimetres;
- Print-dialog margins are subtracted after the base paper grid is resolved;
- explicit page-break records still force an immediate new page.

Counting and output use the same wrapping algorithm, so the page numbers shown
in the range dialog match the pages actually separated by form feeds in the
printer stream.

This is intentionally a text-printer layout, not a full proportional-font RTF
layout engine. It gives stable DOS printing and useful page ranges without
loading or rendering the whole document as a desktop word processor would.

## Output stream

The destination is the DOS `PRN` device. A short PC-PR201 setup sequence is
written first so the printer mode remains deterministic while EDIT98 uses the same effective horizontal grid as the NP21/W conversion path and 6 LPI vertically.
Long logical lines are split into the same template-dependent rows used by page counting. Automatic page boundaries and
explicit page breaks are written as form feeds. One final form feed ejects the
last requested page.

The current in-memory document is printed, including unsaved edits. Logical RTF
font-family metadata is not translated into printer escape sequences.

## Memory behavior

`PrintDoc` counts and prints through `EditorBuf.LinePtr`. The existing
three-slot, 32-line disk-backed cache therefore remains the only resident
document storage even for very long print jobs.

## Test program

Build and run:

```bat
BUILD-PRINTTEST-WIN11.BAT
PRINTTEST
```

The test verifies both explicit page-break counting and automatic pagination, including A4 portrait and landscape geometry.
It then prints automatic pages 2 through 3 to `PRINTTEST.OUT`, verifies that
page 1 is absent, checks page order and form-feed count, and removes the file.

Expected result:

```text
Printer automatic page-range check OK.
```

## Storage handling

Counting and printing are read-only operations and do not force a complete
cache flush first. EDIT98 checks whether dirty resident pages would extend the
temporary file, retries retained storage errors, and may relocate the paging
file automatically when the original temporary drive is full.

## Emulator mouse capture

Printing through a host-side Windows printer dialog can make NP21/W lose mouse
capture because the emulator window loses host focus. EDIT98 can restore its own
INT 33h mouse state and text-VRAM pointer, but a DOS guest has no interface for
forcing the emulator to recapture the Windows mouse. To avoid capture loss, turn
off NP21/W's `Show print settings before printing` option when possible, or use a
noninteractive `FILE` destination. Microsoft Print to PDF may still display its
own host save dialog, which likewise releases capture.
