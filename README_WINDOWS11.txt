EDIT98 0.7.13 - WINDOWS 11 BUILD
================================

Install these matching Free Pascal 3.2.2 packages in this order:

1. fpc-3.2.2.i386-win32.exe
2. fpc-3.2.2.i386-win32.cross.i8086-msdos.exe

Install both under the same directory, normally:

C:\FPC\3.2.2

Open Command Prompt in this source directory and run:

BUILD-STORAGETEST-WIN11.BAT
BUILD-RTFTEST-WIN11.BAT
BUILD-PRINTTEST-WIN11.BAT
BUILD-WIN11.BAT

The expected editor output is EDIT98.EXE.

VERSION 0.7.11
-------------
- Print dialog now includes A4, Letter, Legal, Tabloid, Document Geometry, and four custom paper templates.
- Custom paper width/height, selected paper, and all four margins are remembered in EDIT98.CFG.
- Print dialog also includes Top, Bottom, Left, and Right margins.
- All four margins default to 0.5 cm and are remembered in EDIT98.CFG.
- Print Range shows From and To fields together with OK and Cancel.
- The two fields can be selected with Tab/Left/Right or clicked with the mouse.
- Printable pages are counted from the selected paper template, fixed-pitch wrapping,
  and automatic row-based pagination; explicit RTF page breaks still force a new page.
- Document Geometry uses imported page/line-spacing metadata when present; A4,
  Letter, Legal, Tabloid, and custom templates use their configured physical dimensions before margins.
- Counting and output share the same pagination rules.
- 0.7.3 temporary-storage recovery remains enabled.

TARGET TEST ORDER
-----------------
1. Run STORAGETEST.EXE. It should print:

   Paged storage check OK.

2. Run PRINTTEST.EXE. It should print:

   Printer automatic page-range check OK.

3. Run:

   RTFTEST RTF_SAMPLE.RTF /ALL

   Confirm that bullets appear as * and page boundaries appear as [PAGE BREAK].

4. Run:

   EDIT98 RTF_SAMPLE.RTF

   Confirm that document text has the same hardware glyph design as the menu,
   that Options > Show Page Breaks toggles the separator, and that relaunching
   EDIT98 restores the option from EDIT98.CFG.

5. Use File > Print. Confirm All Pages and Page Range both reach the emulator
   or printer capture attached to DOS PRN.

This package was prepared as source and was not target-compiled here.
