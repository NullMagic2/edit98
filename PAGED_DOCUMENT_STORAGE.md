# EDIT98 0.7.13 paged document storage

## Layout

A logical document is split into 32-line `TDocumentPage` records. Three page
buffers are allocated independently on the far heap, so at most 96 document
lines are resident in the page cache. The logical limit is 65,535 lines.

Each line contains a `String[255]` and compact logical RTF-family metadata. The
metadata is retained for RTF round-trip saving but has no effect on display.

## Backing file

EDIT98 creates an 8.3 temporary file in the first writable location found:

1. `EDIT98TMP`
2. `TEMP`
3. `TMP`
4. the current directory

Each page has a fixed backing-file offset. Dirty pages are written before
cache eviction. New-document initialization truncates the backing file, and
normal shutdown removes it. A crash can leave an `E98P????.$$$` file.

## RTF behavior

RTF parsing is sequential because group and formatting state depend on earlier
input. A 1 KB reader feeds decoded text into the page cache, and completed pages
can be evicted immediately. Resident memory therefore does not increase with
source-file length.

Explicit RTF page breaks are represented as a dedicated logical line containing
form feed (`#12`). This record is paged like any other line. Hiding page-break
markers changes only display; it does not remove or reload the record.

## Editing behavior

The line-oriented editor API loads pages on demand. Viewport rendering normally
touches only pages intersecting the current 21-row screen. Search and save walk
pages sequentially. Inserting or deleting lines in a very large document may be
slow because subsequent lines must be shifted, but memory remains bounded.


## Printing behavior

Page counting and output use sequential `LinePtr` access, so only cache pages
encountered during the scan become resident. A range beginning late in a long
document skips earlier text without printing it, but the scan remains bounded
to three resident pages. Explicit `#12` records define the one-based print page
numbers and are emitted as printer form feeds only inside the selected range.


## 0.7.3 recovery behavior

Storage diagnostics include the exact `E98Pxxxx.$$$` path. Before an operation
that may evict a dirty cache page, EDIT98 estimates the required backing-file
extension and checks free space on that DOS drive. A previous error is cleared
and retried. If the drive still cannot accept the write, EDIT98 copies the
backing store to another configured temporary directory, overlays the dirty
resident pages, and deletes the old file only after the relocation succeeds.

At startup, abandoned page files from earlier dates are removed from the
configured temporary directories. Same-day files are never removed because
they may belong to another running EDIT98 instance.
