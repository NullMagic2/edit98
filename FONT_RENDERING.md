# Native PC-98 text rendering in EDIT98 0.7.13

EDIT98 no longer contains or draws custom document fonts.

Menus, dialogs, status text, page-break separators, selections, the caret, and
document characters are all written through `PutCell`/`PutText` into PC-98 text
VRAM. The machine's text ROM therefore supplies the glyphs everywhere in the
interface.

`pc98fonts.pas` remains only as a compact logical-formatting helper. It stores
two-bit Serif, Sans Serif, or Monospace values imported from RTF so those font
runs can be written back during RTF save. It contains no bitmap tables, glyph
expansion, graphics-plane composition, or rendering routine. The logical family
does not change what the user sees in EDIT98.

The MS-DOS Edit color scheme still uses a blue graphics-plane backdrop under
native white text cells. That backdrop provides the color field; it does not
provide the glyphs.
