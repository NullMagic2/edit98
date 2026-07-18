# EDIT98 0.7.13 RTF support

## Import

`rtfcodec.pas` reads RTF sequentially through a 1 KB buffer and writes decoded
text into the disk-backed document page cache. It recognizes a practical,
text-oriented subset including:

- font tables and Serif/Sans/Monospace switches;
- paragraphs, explicit line breaks, tabs, cells, and rows;
- escaped braces, backslashes, hexadecimal bytes, and Unicode escapes;
- common punctuation approximations;
- common ANSI, Unicode, and Symbol-font bullets;
- explicit `\page` and enabled `\pagebb` page breaks;
- page height and line-spacing metadata used for base text-printer pagination; user print margins are applied separately.

Unsupported destinations such as pictures and objects are skipped.

## Native display

All imported text displays in the PC-98 text-ROM font. Logical RTF family runs
are retained only so they can be written back on save. Bullets are normalized to
the ASCII asterisk (`*`).

Page breaks are stored as a dedicated form-feed (`#12`) line. The UI can render
that record as a dashed native-font separator or hide it. The record remains in
the document in either mode.

## Export

RTF save emits a small three-family font table, switches `\fN` at retained run
boundaries, writes escaped text, and emits `\page` for page-break records.

## Deliberate limits

EDIT98 does not reproduce proportional desktop word-processor layout, bold,
italics, colors, images, tables, headers, or footers. For printing, it converts
RTF page-height/margin/line-spacing metadata into a bounded text-printer row
count, wraps output at 80 columns, and honors explicit hard page breaks. Lines
longer than 255 bytes continue on another editor line.
