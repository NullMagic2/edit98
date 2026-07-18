# EDIT98 0.7.13 design notes

## Layers

- `edit98.pas`: UI state, menus, dialogs, native viewport rendering, settings.
- `editorbuf.pas`: checked line editing and three-page disk-backed document cache.
- `rtfcodec.pas`: streaming RTF import/export, bullet approximation, page breaks.
- `printdoc.pas`: logical page counting and streamed DOS PRN output.
- `pc98fonts.pas`: logical RTF-family metadata only; no rendering.
- `pc98screen.pas`: PC-98 text VRAM, attributes, frames, and graphics backdrops.
- `pc98kbd.pas`: PC-98 BIOS keyboard events.
- `pc98mouse.pas`: INT 33h polling and text-cell mouse pointer.

## Native document display

The document and interface use the same PC-98 text-ROM glyph source. The
viewport stores characters, text attributes, and backdrop colors. It no longer
stores a font-family visual state or invokes any custom glyph rasterizer.

The blue MS-DOS Edit field is a graphics-plane background. Native text cells are
placed above it. Popups clear the graphics beneath their reverse-video cells so
their labels remain opaque and readable.

## Long documents

The logical buffer contains up to 65,535 lines, divided into 32-line pages. Only
three pages reside in memory. Dirty pages are flushed before eviction. The
77 x 21 viewport cache is independent and contains only visible native cells.

## Page breaks

RTF page breaks are represented by a line whose sole character is `#12`. This
makes the boundary durable under paging and easy to stream during save. The
Show Page Breaks setting changes only how that line is resolved for display.

## Printing

`PrintDoc` scans document lines through the same three-slot cache used by
rendering and saving. It wraps plain output at 80 columns and advances pages
after the buffer's printer-row count; RTF import can derive that row count from
page-height and line-spacing metadata; user margins are applied afterward. A line containing only `#12`
still forces a hard page boundary. The print dialog validates one-based
inclusive ranges, then the output pass skips unselected pages without emitting
leading form feeds. Selected automatic or explicit boundaries become form
feeds, and a final form feed ejects the last requested page.

User print margins are stored as tenths of a centimetre and resolved into
fixed-pitch geometry at an effective 13.3 CPI horizontally for the NP21/W
PC-PR201-to-GDI target and 6 LPI vertically. The left/right values reduce the
content width; top/bottom reduce content height. The left margin is emitted as
spaces and the top margin as blank CR/LF rows. Right and bottom margins remain
blank because wrapping/page breaks stop before those areas.

The destination is DOS `PRN`, not direct printer hardware. This keeps printer
routing under DOS/emulator control and avoids adding a resident spooler or a
large printer driver to EDIT98. Output is deliberately plain single-byte text;
RTF logical font metadata has no effect on printer rendering.

## Persistent settings

`EDIT98.CFG` is a simple numeric key/value text file. Print margins are stored as `PRINTMARGINTOP`, `PRINTMARGINBOTTOM`, `PRINTMARGINLEFT`, and `PRINTMARGINRIGHT` in tenths of a centimetre. Unknown or invalid keys are
ignored. The editor stores tab width, typing mode, auto-indent, mouse speed,
color scheme, page-break visibility, and Match Case. The path is captured from
`ParamStr(0)` before a mouse TSR is executed.

## Safety constraints

The editing core uses fixed short strings, checked indices, bounded page records,
and no unbounded document allocation. Large objects are separated so no single
16-bit data element approaches 64 KB. The preparation package is source-only;
the installed FPC 3.2.2 i8086 compiler is the definitive compatibility check.


0.7.13 printing note: the first margin correction incorrectly tried to force the PDF width with `FS B`. That sequence changes only the Kanji pitch, so the ANK/ASCII output width was unchanged. The Windows 11 NP21/W target now calculates horizontal paper and margin geometry on the effective 13.3-CPI grid actually produced by the conversion path, keeps 6 LPI vertically, and explicitly selects `FS A` so double-byte Kanji cells remain aligned 1:2 with the half-width grid.
