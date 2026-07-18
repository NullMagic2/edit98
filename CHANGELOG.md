# EDIT98 0.7.13


## 0.7.13

- Added persistent Portrait/Landscape selection to the Print dialog.
- Landscape swaps the physical width and height of A4, Letter, Legal, Tabloid, and custom paper templates before fixed-pitch pagination is calculated; Document Geometry remains unchanged.
- Added `PRINTORIENTATION` to `EDIT98.CFG` (`0` = Portrait, `1` = Landscape), with Portrait as the backward-compatible default.
- Added keyboard and mouse controls for orientation and extended PRINTTEST with A4 landscape geometry validation.
- Corrected the first 0.7.13 margin fix after real PDF output showed that adding `FS B` had no effect on single-byte text width.
- The NP21/W PC-PR201-to-GDI target path renders the ANK/ASCII grid at an effective 13.3 CPI while vertical output remains 6 LPI. EDIT98 now converts paper widths and horizontal margins on that same 13.3-CPI grid instead of incorrectly calculating them at 10 CPI.
- A4 with the default 0.5 cm left/right margins now resolves to 104 printable columns instead of 79, eliminating the artificial large blank area on the right.
- The deterministic printer prologue remains, but now uses `FS A` (3/20-inch Kanji pitch) rather than `FS B`. `FS B` only changes the two-byte Kanji grid and cannot change the ANK/ASCII pitch that caused the PDF mismatch.
- Updated PRINTTEST to verify the corrected raw setup bytes and the new A4, Letter, Legal, Tabloid, and custom-paper horizontal geometries.


## 0.7.12

- Fixed runtime error 215 when accepting built-in paper formats such as A4.
- Reworked centimetre-to-fixed-pitch column/row conversion so the i8086 build never evaluates the large `Value * 394` or `Value * 236` products as checked 16-bit intermediates.
- The new decomposition is mathematically equivalent to the previous rounded conversion but keeps all intermediate `Word` multiplications below 65535 for the supported 5.0-64.0 cm paper range.
- Strengthened `PRINTTEST.PAS` with exact A4, Letter, Legal, and Tabloid geometry checks.


## 0.7.11

- Fixed a cosmetic overlap in the Custom Paper Template dialog: the width and height edit fields no longer overwrite their opening `[` brackets.
- Width and height are now rendered as `Width (cm): [value]` and `Height (cm): [value]`.


## 0.7.10

- Corrected the 0.7.9 interpretation of "more templates": restored the custom-paper editor to four persistent custom slots rather than seven.
- Added predefined `Legal` paper at 21.6 x 35.6 cm.
- Added predefined `Tabloid` paper at 27.9 x 43.2 cm.
- Kept the existing predefined `A4` (21.0 x 29.7 cm) and `Letter` (21.6 x 27.9 cm) formats.
- Kept Custom 1-4 at their existing configuration IDs so older `EDIT98.CFG` files remain compatible.
- Updated PRINTTEST with Legal and Tabloid geometry checks.



## 0.7.9

- Expanded persistent custom paper templates from four to seven slots (`Custom 1` through `Custom 7`).
- Added `CUSTOMPAPER5*`, `CUSTOMPAPER6*`, and `CUSTOMPAPER7*` settings keys while preserving compatibility with existing `EDIT98.CFG` files.

- Added selectable paper templates to the Print dialog.
- Added built-in A4 (21.0 x 29.7 cm), Letter (21.6 x 27.9 cm), and
  Document Geometry templates.
- Added four editable custom paper-template slots with width and height from
  5.0 through 64.0 cm.
- Custom paper slots are edited from the Print dialog and stored in
  `EDIT98.CFG` together with the selected paper template.
- Existing custom Top, Bottom, Left, and Right margins remain persistent.
- Pagination and wrapping now resolve from the selected paper template before
  applying the saved margins.
- The A4 template is the default for a new configuration.


## 0.7.7

- Added Top, Bottom, Left, and Right margin fields to the Print dialog.
- Set the default print margins to 0.5 cm on all four sides.
- Added decimal-point and decimal-comma margin input.
- Persisted all four margin values in `EDIT98.CFG`.
- Applied left margins as leading fixed-pitch spaces, right margins as reduced
  wrap width, top margins as leading blank rows, and bottom margins as reduced
  printable content height.
- Page counting and page-range printing now use exactly the same margin-adjusted
  geometry.

## 0.7.6

- Page-range dialog focus now cycles through `From`, `To`, `OK`, and `Cancel`.
- `Tab` moves forward through all four controls; `Shift+Tab` moves backward.
- Left/Right also move backward/forward through the same focus order.
- The focused OK or Cancel button is highlighted, and Enter activates it.
- Documents that invoke a host-side printer dialog may cause an emulator such as
  NP21/W to release host mouse capture. A DOS guest cannot re-enable host capture;
  disable the emulator's "Show print settings before printing" option or use a
  noninteractive printer destination when uninterrupted capture is required.

## 0.7.5

- Replaces Pascal `Text` output to `PRN` with raw untyped-file `BlockWrite` output.
  This avoids the buffered `TextRec` character-device path that could corrupt the
  PC-98 display under some DOS/emulator combinations.
- Printer rows are emitted as exact bytes followed by CR/LF; form feeds are sent
  as a single raw `0Ch` byte.
- Forces a full native-text and graphics-backdrop redraw immediately after a
  printer-device call returns, before the success/error message is displayed.
- Keeps automatic pagination and simultaneous From/To page-range selection.




## 0.7.4

- Replaced the two sequential page-number prompts with one simultaneous `From` / `To` range dialog.
- Added mouse-clickable From/To fields plus OK and Cancel buttons; Tab or Left/Right changes the active field.
- Fixed print-range counting for ordinary flowing RTF files that contain no explicit `\page` control.
- Added deterministic automatic printer pagination: 80-column wrapping plus a bounded rows-per-page value.
- RTF import now derives printer rows per page from `\paperh`, top/bottom margins, and the first useful `\sl` line spacing when available.
- Explicit RTF/document page breaks still force hard printer page boundaries.
- Page counting and printer output now share exactly the same wrapping/pagination algorithm.
- Expanded PRINTTEST to cover both explicit and automatic pagination.

## 0.7.3

- Printing no longer flushes every cache page before counting or sending pages.
- Temporary-storage errors now include the exact active page-file path.
- Pending page-file growth is checked against DOS free space before printing.
- A retained storage error is retried on the next operation instead of remaining permanent.
- When the original temporary drive cannot accept pending pages, EDIT98 attempts to relocate the complete page file through `EDIT98TMP`, `TEMP`, `TMP`, and the current directory.
- Temporary page files dated before the current day are removed at startup; same-day files are preserved so another running instance is never disturbed.
- Error 112 recovery preserves dirty resident pages and overlays them after relocation.

## 0.7.2

- Added File > Print and the Ctrl+P shortcut.
- Added a print-scope dialog for all pages or an inclusive page range.
- Sent plain text through the DOS PRN device, preserving explicit document page
  breaks as printer form feeds and ejecting the final selected page.
- Made page counting and printing stream through the disk-backed page cache.
- Added PrintDoc as a small printer-output unit and PRINTTEST as a device-free
  page-range verification program.
- Updated the tutorial, README, Windows build notes, and design documentation.

## 0.7.1

- Removed all custom document bitmap tables and graphics-plane glyph rendering.
  Document text now uses the native PC-98 text ROM used by menus and dialogs.
- Retained logical Serif/Sans/Monospace metadata only for RTF round-trip output.
- Normalized common ANSI, Unicode, and Symbol-font bullets to ASCII `*`.
- Added durable RTF page-break records, native-font page-break separators, and
  an Options toggle to show or hide them.
- Added persistent `EDIT98.CFG` settings for tab width, typing mode, auto-indent,
  mouse speed, color scheme, page-break visibility, and Match Case.
- Preserved the 32-line, three-page disk-backed document cache and 65,535-line
  logical limit introduced in 0.7.0.

## 0.7.0

- Added a three-slot, 32-line disk-backed document page cache.
- Raised the logical document limit to 65,535 lines with bounded resident RAM.
- Made TXT and RTF loading/saving stream through the page cache.
- Replaced generated 5x7-derived glyphs with three static 8x16 bitmap fonts.
- Added DOS temporary-directory fallback through EDIT98TMP, TEMP, TMP, and the
  current directory.
- Added page-eviction verification to STORAGETEST and summarized RTFTEST output.
- Added common Unicode/Symbol bullet approximations.

## 0.6.10

- Replaces the far-heap viewport-cache pointer with a small static near-data
  cache.
- Replaces the nested baseline initialization loops with a single zero-fill
  sentinel reset.
- Avoids FPC 3.2.2 i8086 internal error 200309041 at the end of the old cache
  reset procedure.
- Keeps the 77 x 21 lazy renderer and all 0.6.9 rendering behavior.

## 0.6.9

- Refactors the lazy viewport renderer into small top-level procedures so the
  FPC 3.2.2 i8086 register allocator no longer reaches internal error
  `200309041` at the end of `RenderDocumentViewport`.
- Preserves viewport-only drawing, dirty-cell comparison, blank-run clearing,
  and cached custom glyphs.
- Avoids the unconditional 77 x 21 text-plane clear on ordinary redraws.
- Replaces impossible post-concatenation `String[255]` length comparisons with
  pre-concatenation component-length validation in clipboard paste handling.


- Replaced unconditional 77 x 21 custom-font rasterization with a lazy viewport
  cache that stores only the cells currently visible on screen.
- Redraws only changed characters, font families, selection cells, and caret
  cells; off-screen document lines are never rasterized.
- Uses the already-cleared graphics backdrop as the blank baseline after
  startup, theme changes, and dialogs instead of repainting every space.
- Merges adjacent changed blank cells into one graphics rectangle clear.
- Added lazy per-character/per-family glyph bitmap caching in `pc98fonts.pas`.
- Kept the caret blink path synchronized with the viewport cache.
- Preserved the 192-line segmented document, 96-line clipboard, buffered RTF
  parser, and existing file formats.

# EDIT98 0.6.7
- Fixed the remaining i8086 `Data element too large` build failure. The cause
  was the 98,304-byte **minimum heap** in the three-argument `$M` directive,
  not the already segmented 20 KB document blocks.
- Changed the main editor from `$M 16384,98304,131072` to
  `$M 16384,32768,131072`; test programs now use the same 32 KB minimum and
  128 KB maximum.
- Preserved the 192-line, three-block far-heap document and the 96-line
  clipboard. The heap is allowed to grow from its 32 KB minimum at runtime.
- Added automatic removal of stale compiler units and objects before every
  Windows build.
- Removed the nested compiler-directive text from a comment that generated a
  harmless `Comment level 2 found` warning.

# EDIT98 0.6.6

- Fixed the i8086 compiler error `Data element too large` reported at the end
  of `edit98.pas` after the 0.6.5 capacity increase.
- Split the 192-line document into three approximately 20 KB far-heap blocks
  instead of declaring one approximately 60 KB structured data element.
- Preserved 192 document lines, 255-byte lines, packed logical fonts, buffered
  RTF import, and the separate 96-line clipboard.
- Added pointer accessors that map logical line numbers across the three blocks
  and updated all text/font mutation, rendering, search, TXT, and RTF paths.
- Added `STORAGETEST.PAS` and `BUILD-STORAGETEST-WIN11.BAT` for an isolated
  compile/runtime check of both block boundaries.
- Source-only revision; target compilation remains required.

# EDIT98 0.6.5

- Replaced byte-at-a-time RTF file I/O with a 1 KB buffered reader.
- Appends decoded text in place and stops parsing immediately when storage is
  exhausted, eliminating the major sources of slow imports under emulation.
- Moved the document object to the far heap and doubled capacity from 96 to 192
  lines without enlarging the 64 KB `DGROUP` segment.
- Kept the internal clipboard at 96 lines and added an explicit capacity check
  for larger selections.
- Wraps RTF paragraphs at the 255-byte editor-line boundary instead of dropping
  the remaining characters.
- Expanded message dialogs to three wrapped lines so warnings are fully visible.
- Updated the standalone RTF test to allocate its enlarged document on the far
  heap.
- Source-only revision; target compilation remains required.

# EDIT98 0.6.4

- Addresses runtime error 215 reported while importing RTF files with the Free
  Pascal 3.2.2 i8086 compiler; target testing is still required.
- Kept array/string range checking enabled, but disabled generated arithmetic
  overflow traps inside the manually bounded RTF codec. FPC 3.2.2 can otherwise
  report false overflows for mixed signed/unsigned arithmetic on narrow targets.
- Rewrote the RTF parser's decimal, hexadecimal, Unicode, line-count, and
  paragraph-count arithmetic with explicit widths and pre-addition bounds.
- Added `RTFTEST.PAS` and `BUILD-RTFTEST-WIN11.BAT` to test RTF import without
  entering the graphical editor.
- Added `BUILD-DEBUG-WIN11.BAT` for an unstripped line-information build and
  `DOWNLOAD-FPC-WIN11.ps1` for obtaining the two official compiler installers.

# EDIT98 0.6.3

- Made logical fonts explicitly range based: formatting a selection changes
  only those characters and leaves all neighboring imported or user-applied
  font runs intact.
- Added uniform/mixed selection detection. The Options menu and status bar show
  `Font: Mixed` when a selection crosses family boundaries.
- Made caret movement and mouse placement inherit the local run's family for
  subsequent typing, while a font chosen without a selection remains an
  insertion-only style until the caret is repositioned.
- Kept RTF serialization per character run; mixed family changes continue to
  round-trip through `\f0`, `\f1`, and `\f2` switches.
- Added document-model range APIs for assigning and inspecting family runs.
- Updated Help and design documentation. No compiler was downloaded or invoked.

# EDIT98 0.6.2

- Corrected Alt/GRPH/F10 menu activation so only each mnemonic letter is
  reverse-highlighted and underlined; merely activating the bar no longer
  highlights the complete `File` label.
- Kept whole-word highlighting only for the top-level menu whose popup is
  actually open, including menus opened directly with the mouse.
- Replaced repeated Font cycling with a dropdown-style three-choice font menu.
- The chooser preselects the current family and supports keyboard access keys
  and mouse selection.
- Selected text receives the chosen family; without a selection the chosen
  family becomes the typing font. RTF output preserves it and TXT output
  remains deliberately plain text.
- Updated Help, README, rendering notes, UI mockup, design notes, and Windows
  build notes. No compiler was downloaded or invoked for this revision.

# EDIT98 0.6.1

- Fixed the i8086 linker failure `Data segment "DGROUP" too large` introduced
  by the RTF/font milestone.
- Moved the approximately 25 KB fixed clipboard object from global DGROUP
  storage to one far-heap allocation made after mouse-driver startup.
- Kept the document buffer fixed and range checked; editing and RTF behavior are
  otherwise unchanged from 0.6.0.
- Added an explicit out-of-memory message and release of the clipboard block on
  normal shutdown.

# EDIT98 0.6.0

- Added bounded RTF import and export for `.RTF` files in the new, separate
  `rtfcodec.pas` module.
- Added Serif, Sans Serif, and Monospace logical families and a separate
  graphics-plane glyph renderer in `pc98fonts.pas`.
- Added packed two-bit per-character family storage to the document model and a
  bounded run-based clipboard representation.
- Updated insertion, overwrite, line split/join, deletion, paste, replacement,
  auto-indent, selection formatting, redraw, status, and file routing so logical
  fonts move with their text.
- Added Options > Font for selection formatting and typing-family choice.
- RTF import handles font tables/switches, paragraphs, tabs, escaped characters,
  common Unicode/ANSI punctuation, and flattened table cells/rows; unsupported
  binary or layout destinations are skipped.
- RTF export emits a clean three-font table and changes `\fN` only at family
  run boundaries. TXT output remains plain text.
- Added `RTF_SAMPLE.RTF`, `RTF_SUPPORT.md`, and `FONT_RENDERING.md`.
- Source was lexer-, structure-, documentation-, RTF-sample-, packed-font-,
  and archive-audited in this environment. No compiler was downloaded or
  invoked for this revision, so target compilation remains required.

# EDIT98 0.5.10

- Replaced the contiguous A-through-highest-letter browser assumption with a
  DOS drive-selection probe. Only logical drives that DOS actually accepts are
  shown in Open and Save As.
- Updated keyboard and mouse drive selection to index the compact detected-drive
  list, automatically skipping absent letters.
- Restores the original default drive after probing and does not access drive
  media merely to determine whether a logical drive exists.
- Updated the tutorial, README, design notes, and Windows build notes.
- Source and documentation only; no executable is included.

# EDIT98 0.5.9

- Changed the top menu bar so access letters are ordinary text while editing
  and become reverse-highlighted plus underlined when Alt/GRPH or F10 activates
  the bar, matching MS-DOS Edit more closely.
- Added half-second double-click recognition to the Open/Save As browser.
  Double-click now performs the same action as Enter: it enters directories
  (including `..`) and accepts files.
- Updated the tutorial and browser footer to describe the new behavior.
- Source and documentation only; no executable is included.

# EDIT98 0.5.8

- Replaced the short Help message with a navigable nine-page tutorial.
- Added Tutorial and About entries to the Help menu; the PC-98 HELP key opens
  the tutorial directly.
- Documented every Pascal module with a responsibility summary.
- Added a concise responsibility comment for every procedure, function, and
  object method in the source.
- Kept all file handling as plain text; no RTF or Word parser was added.
- Source and documentation only; no executable was compiled for this release.

# EDIT98 0.5.7

- Rebuilt and inspected with Free Pascal 3.2.2 for i8086/MS-DOS.
- Captures the original command-line filename before executing MOUSE.COM,
  avoiding lazy ParamStr initialization after a resident child process.
- Replaces the startup cursor BIOS wrapper with a direct INT 18h call.
- Reworks caret timing to a bounded 0..5999 hundredths-of-a-minute counter,
  eliminating the checked 32-bit multiplication path that could raise error 215.
- Keeps direct EDIT98.EXE output; no E98CORE executable or batch launcher.

# EDIT98 0.5.6

- Attempted to address runtime error 215 by replacing the graphics-plane fill
  expression with direct byte writes. Subsequent testing showed that diagnosis
  was incorrect; v0.5.7 supersedes this attempt.
- Kept direct `EDIT98.EXE` output; no `E98CORE.EXE` or `EDIT98.BAT` launcher.

# EDIT98 0.5.5

- Reverted the temporary `E98CORE.EXE` / `EDIT98.BAT` packaging split.
- `BUILD.BAT` and `BUILD-WIN11.BAT` once again produce `EDIT98.EXE` directly.
- Removed the separate batch launcher; EDIT98 retains its existing internal
  mouse-driver startup fallback.
- No runtime UI behavior from 0.5.4 was otherwise changed.
- Source and documentation only; no executable was compiled for this release.

# EDIT98 0.5.4

- Fixed blue-looking menu and popup glyphs in the MS-DOS Edit scheme by
  clearing graphics VRAM beneath reverse-video labels to black.
- Made all top-level and popup access-key underlines permanently visible.
- Hid the PC-98 BIOS hardware text cursor while the editor is active and added
  a single editor-owned half-second blinking caret; the BIOS cursor is restored
  at the DOS prompt.
- Added dark-gray upper/left and black lower/right bevel shading to pale frame
  borders while preserving the existing larger popup/dialog drop shadows.
- Added graphics-backdrop invalidation so closing a popup restores the blue
  document field before the main screen is redrawn.
- Updated build helpers to output `E98CORE.EXE` and added `EDIT98.BAT`, which
  starts a local mouse driver and forwards `%1` through `%9`.
- Source and documentation only; no executable was compiled for this release.

# EDIT98 0.5.3

- Made the default MS-DOS Edit menu bar and popup labels explicitly black on
  their pale surfaces. Highlighted menu items use black glyphs on cyan.
- Added underlined access keys to the top menu bar and every popup-menu item.
- Added an Alt-style menu activation mode: PC-98 `GRPH`, emulator `NFER`/`XFER`,
  and `F10` activate the menu bar; letters choose File, Edit, Search, Options,
  or Help; arrow keys move across the bar; Enter/Up/Down opens the selection.
- Added letter accelerators inside File, Edit, Search, and Options menus.
- Kept all floating-window borders on the shared two-column/right and
  one-row/bottom opaque drop-shadow renderer.
- Source and documentation only; no executable was compiled for this release.

# EDIT98 0.5.2

- Fixed automatic MOUSE.COM startup for real this time. The two-value `{$M}`
  directive left Free Pascal's large-model default maximum heap (640 KB) in
  effect, so the MZ header asked DOS for up to 723 KB and DOS granted EDIT98
  every free paragraph of conventional memory at load. The later `EXEC` of
  MOUSE.COM then failed with DOS error 8 (not enough memory) and the automatic
  startup silently did nothing. The directive now supplies a third value that
  caps the maximum heap at 32 KB, leaving conventional memory free for the TSR.
- The mouse driver check and MOUSE.COM/MOUSE.EXE execution now happen as the
  very first statements of the program, before any buffer, theme, or screen
  initialization.
- The mouse pointer is now a normal-video white arrow glyph (text-ROM up
  arrow) instead of a reverse-video cell that appeared as a solid block.
- MS-DOS Edit scheme: the document field is now white text on blue. Because a
  PC-98 text cell carries only one color, the blue comes from a solid blue
  graphics-plane backdrop kept underneath the text plane; normal-video white
  cells show it through their transparent background.
- MS-DOS Edit scheme: the black border ring and dialog frames are now black
  lines on the same pale surface as the menu bar, instead of white lines on
  black.
- `pc98screen.pas` gained `SetGraphicsBackdrop`/`ShutdownGraphicsBackdrop`
  (INT 18h functions 40h/41h/42h plus plane fills); the backdrop is cleared
  and the graphics display switched off again when the editor exits.

# EDIT98 0.5.1

- Replaced the driver-rendered graphics cursor with a text-VRAM overlay cursor.
- Fixed pointer layering over the blue document field, menus and dialogs.
- Execute MOUSE.COM or MOUSE.EXE directly after searching the current directory and PATH.

# Changelog

## 0.5

- Reworked the built-in Microsoft-style scheme to match the classic MS-DOS
  Editor more closely: pale menu/dialog surfaces, a blue editing field, a cyan
  status line, light frames, and dark shadows.
- Made the MS-DOS Edit scheme the startup default and renamed it from
  `MS-DOS Blue/Red` to `MS-DOS Edit`.
- Added two-column, one-row drop shadows to popup menus, message boxes, prompts,
  and the Open/Save As browser.
- Replaced the one-cell cursor marker with an Edit-style proportional vertical
  scroll bar containing separate arrow buttons, a colored track, and a viewport
  thumb. The mouse can click its arrows or track.
- Made mouse show/hide calls idempotent so the INT 33h visibility counter cannot
  drift and leave the pointer underneath a newly repainted menu.
- Fixed automatic mouse-driver startup by reserving conventional memory for the
  child TSR and asking `COMMAND.COM` to resolve `MOUSE` through the current
  directory and `PATH`.

## 0.4.1

- Fixed a compile-blocking orphaned `begin`/`end` block in `pc98screen.pas` left behind when the one-line `ClearScreen` helper was removed.
- Removed the remaining one-line `ReplaceRangeWithClipboard` forwarding helper by moving the atomic splice implementation directly into the buffer method.
- No runtime behavior or file format changed from 0.4.

## 0.4

- Added a DOS-native Open/Save As file browser.
  - Lists files and directories.
  - Supports `..` and Backspace parent navigation.
  - Supports keyboard and mouse operation.
  - Allows switching among DOS drive letters/devices.
  - Provides a filename field and overwrite confirmation for Save As.
- Added five color schemes, including an MS-DOS-inspired Blue/Red scheme.
- Changed the Options menu to remain open after applying an option.
- Repaints only the updated option row, except when a complete theme repaint is
  required.
- Replaced ASCII frame characters with native continuous PC-98 box glyphs.
- Refactored duplicated code:
  - Cut now reuses Copy plus checked selection removal.
  - Save and Save As share one function.
  - Copy/Delete/Replace share range validation.
  - Paste and paste-over-selection share one atomic splice implementation.
  - Delete and Backspace share line joining.
  - Menu and keyboard Delete share a forward-delete command.
  - Vertical cursor movement shares column clamping.
  - Dialogs share setup and teardown.
  - Buffer and clipboard initialization share array clearing.
- Removed trivial wrappers and unused one-line accessors.
- Added explanatory comments throughout the UI, buffer, keyboard, mouse, and
  screen units.

## 0.3

- Implemented Cut, Copy, Paste, Delete, and Select All.
- Added multiline clipboard and keyboard/mouse selection.
- Implemented Find, Find Next, Replace, Replace All, and Match Case.
- Added tab width, typing mode, auto-indent, and mouse-speed options.
- Added non-blinking popup-row repainting.

## 0.2

- Automatically starts `MOUSE.COM` when no mouse driver is detected.
- Added configurable faster mouse movement.
- Reduced menu and dialog flashing.
