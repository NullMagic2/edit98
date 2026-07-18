# EDIT98 0.7.13

EDIT98 is a from-scratch native 16-bit text editor for NEC PC-98 MS-DOS. Its
interface is inspired by the classic Microsoft MS-DOS Editor, but it uses no
Microsoft source code or assets.

## Version 0.7.13

- Fixes the Custom Paper Template width/height fields so the opening `[` bracket remains visible.
- Corrects the paper-template expansion: predefined **paper formats** are added
  instead of adding extra custom slots.
- Includes **A4** (21.0 x 29.7 cm), **Letter** (21.6 x 27.9 cm),
  **Legal** (21.6 x 35.6 cm), **Tabloid** (27.9 x 43.2 cm), and
  **Document Geometry**.
- Keeps four persistent custom paper slots (`Custom 1` through `Custom 4`) whose
  width and height can be edited in centimetres.
- The selected paper template, portrait/landscape orientation, custom paper dimensions, and all four custom print margins are stored in `EDIT98.CFG`.
- A4 is the default paper template for a new configuration; margins still
  default to 0.5 cm on every side.
- Portrait is the default print orientation; Landscape swaps physical paper width and height before pagination.
- Pagination uses the chosen paper dimensions at the NP21/W target's effective 13.3 CPI / 6 LPI and then
  subtracts the configured margins.
- Keeps raw `PRN` printing, page-range printing, and sparse disk-backed document
  paging from the 0.7.x series.

## Document paging

EDIT98 does not keep an entire long document in conventional memory. Text and
logical RTF metadata are divided into 32-line pages. Three pages (96 lines) are
resident at once; clean pages may be discarded and dirty pages are written to a
temporary backing file before eviction.

The backing-file location is selected in this order:

1. `EDIT98TMP`
2. `TEMP`
3. `TMP`
4. the current directory

The file is removed during normal shutdown. A crash can leave an
`E98P????.$$$` file behind; it is safe to delete after confirming EDIT98 is not
running.

RTF still has to be parsed sequentially because later text depends on earlier
formatting state, but decoded pages are written out as the cache advances. Thus,
opening time remains proportional to source-file size while resident memory
stays bounded.

## Menus

### File

- New
- Open
- Save
- Save As
- Print
- Exit

### Edit

- Cut
- Copy
- Paste
- Delete
- Select All

### Search

- Find
- Find Next
- Replace
- Replace All
- Match Case

### Options

- Tab Width: 2, 4, or 8
- Typing Mode: Insert or Overwrite
- Auto Indent
- Mouse Speed: Slow, Normal, or Fast
- Colors: PC-98 Cyan, MS-DOS Edit, Amber, Green, or Monochrome
- Show Page Breaks

Options remain open after a setting changes. Settings are written immediately
to `EDIT98.CFG` and once more during normal shutdown.

## Printing

Choose **File > Print** or press `Ctrl+P`. The Print dialog offers:

- all pages or an inclusive page range;
- paper template selection;
- Portrait or Landscape orientation;
- a `Custom...` editor for four custom paper slots;
- Top, Bottom, Left, and Right margins in centimetres;
- OK and Cancel.

Built-in paper templates are **A4** (21.0 x 29.7 cm), **Letter** (21.6 x
27.9 cm), **Legal** (21.6 x 35.6 cm), **Tabloid** (27.9 x 43.2 cm), and
**Document Geometry**, which uses the print geometry imported from the source document. A4 is the default for a new `EDIT98.CFG`. The four
custom slots accept width and height from 5.0 through 64.0 cm.

The selected paper template, portrait/landscape orientation, all four custom paper dimensions, and the four margin values are persisted in `EDIT98.CFG`. Margins default to `0.5` cm on
every side. Decimal comma input (such as `0,5`) is accepted as well as a
decimal point.

Press `Tab` to move through every control. When the paper field is focused, Left/Right, Space, or Enter cycles through Document Geometry, A4, Letter, Legal, Tabloid, and Custom 1-4. When Orientation is focused, Left selects Portrait, Right selects Landscape, and Space or Enter toggles the choice. `P` and `L` select the orientations directly. Press `C` or activate `Custom...` to define or edit a custom slot.
The custom-paper dialog lets you choose a slot, enter width/height, Save, Delete,
or Cancel.

If page-range mode is selected, a second `From [ ] to [ ]` dialog appears with
mouse-clickable fields plus **OK** and **Cancel**.

Printing uses the NP21/W target's effective fixed-pitch model of 13.3 characters per inch horizontally and 6 lines per inch vertically. The selected paper dimensions are converted into a text grid, then left/right margins reduce wrapping width and top/bottom margins reduce usable page height. Landscape swaps the physical template width and height before this conversion. `Document Geometry` instead uses the imported RTF/plain-text geometry before margins are applied and is not rotated by the orientation setting. Explicit `\page` / internal
`#12` breaks still force a new page.

Output is sent to the DOS `PRN` device so DOS or emulator printer redirection
continues to work. The paper template and orientation control EDIT98's pagination. PC-PR201/80A text output has a fixed print direction, so Landscape is modeled as a rotated sheet (swapped page dimensions) rather than a separate escape sequence. The host printer/PDF driver should be configured to the matching physical paper size and orientation when exact output dimensions matter.

Printing walks the disk-backed document cache sequentially, so selecting a
large page range does not load the full document into conventional memory.

## RTF support

The importer supports a practical text-oriented subset: font tables and font
switches, paragraphs, explicit line breaks, tabs, common escaped characters,
common ANSI/Unicode punctuation, bullets, and page breaks. Unsupported rich
layout destinations are skipped.

Page breaks are stored internally as a dedicated line containing form feed
(`#12`). They are exported as `\page`. Common bullets are approximated as `*`.
Logical font families are preserved on save, although every family displays in
the native PC-98 ROM font inside EDIT98.

This is not a full RTF page-layout engine. It does not reproduce proportional
spacing, images, tables, colors, or bold/italic styling. Printing uses EDIT98's own fixed-pitch paper-template pagination rather than desktop-style RTF layout.

## Building on Windows 11

Install matching Free Pascal 3.2.2 packages into the same directory, normally
`C:\FPC\3.2.2`:

1. `fpc-3.2.2.i386-win32.exe`
2. `fpc-3.2.2.i386-win32.cross.i8086-msdos.exe`

Then run:

```bat
BUILD-STORAGETEST-WIN11.BAT
BUILD-RTFTEST-WIN11.BAT
BUILD-PRINTTEST-WIN11.BAT
BUILD-WIN11.BAT
```

The expected editor output is `EDIT98.EXE`.

## Running

Load a compatible PC-98 DOS mouse driver first, or allow EDIT98 to find and
execute `MOUSE.COM`/`MOUSE.EXE` from the current directory or DOS `PATH`:

```dos
EDIT98
EDIT98 README.TXT
EDIT98 RTF_SAMPLE.RTF
```

## Main shortcuts

- Arrow keys: move the caret
- Shift + movement: extend selection
- Home/CLR: beginning of line
- RollUp / RollDown: move by one screen
- Del / Backspace: delete
- Enter: split line
- F2: Save
- F3: Open
- Ctrl+F: Find
- Ctrl+P: Print
- F4: Find Next
- F10 or GRPH/Alt mapping: menu bar
- HELP: tutorial
- Esc: exit or close a dialog/menu

## Limits

- Lines are limited to 255 bytes.
- Logical documents are limited to 65,535 lines.
- The internal clipboard remains deliberately bounded.
- Text is single-byte; Shift-JIS-aware cursor movement is not implemented.
- Very large insertions/deletions can be slow because later logical lines must
  be shifted through the page cache.

This archive is source-only and has not been compiled in the preparation
environment. Build it with the supplied Windows scripts and your installed
Free Pascal i8086 cross-compiler.


### Print-range keyboard focus

In the simultaneous page-range dialog, `Tab` cycles `From -> To -> OK -> Cancel`
and `Shift+Tab` reverses. `Enter` activates the focused button. Host-side printer
dialogs may release emulator mouse capture; that capture belongs to the emulator,
not the DOS guest, so EDIT98 cannot force it back on.


0.7.13 printing note: the first margin correction used `FS B`, but that changes only the two-byte Kanji pitch and therefore did not alter the ANK/ASCII width visible in NP21/W PDF output. Horizontal paper and margin geometry now use the effective 13.3-CPI grid produced by the Windows 11 NP21/W conversion path, while vertical layout remains 6 LPI. The setup prologue now uses `FS A` so the Kanji grid matches the corrected half-width layout.
