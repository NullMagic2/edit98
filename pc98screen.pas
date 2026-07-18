unit PC98Screen;

{ PC-98 display backend.  It provides bounded text-VRAM primitives, native
  frames and shadows, BIOS text-cursor control, and graphics-plane backdrop
  operations used to reproduce the MS-DOS Edit color treatment. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}

interface

const
  ScreenWidth  = 80;
  ScreenHeight = 25;

  { PC-98 text attributes: bit 0 enables the cell, bits 5..7 select B/R/G,
    and bit 2 reverses the selected color into the cell background. }
  AttrBlack      = $01;
  AttrBlue       = $21;
  AttrRed        = $41;
  AttrMagenta    = $61;
  AttrGreen      = $81;
  AttrCyan       = $A1;
  AttrYellow     = $C1;
  AttrWhite      = $E1;

  AttrBlueRev    = $25;
  AttrRedRev     = $45;
  AttrMagentaRev = $65;
  AttrGreenRev   = $85;
  AttrCyanRev    = $A5;
  AttrYellowRev  = $C5;
  AttrWhiteRev   = $E5;

  { PC-98 attribute bit 3 underlines the glyph without changing its color.
    EDIT98 uses it for classic Alt/GRPH menu access-key highlighting. }
  AttrUnderline  = $08;

  { Native PC-98 one-byte line-drawing glyphs.  Unlike ASCII '-' and '|',
    these meet at cell boundaries and form an uninterrupted frame. }
  FrameHorizontal  = #$95;
  FrameVertical    = #$96;
  FrameTopLeft     = #$98;
  FrameTopRight    = #$99;
  FrameBottomLeft  = #$9A;
  FrameBottomRight = #$9B;

  { These character codes are used by the Edit-style scroll bar and shadows.
    The arrows are the PC-98 text-ROM arrow glyphs.  SolidBlock is also useful
    for an opaque shadow because a space has a transparent background on PC-98. }
  ScrollArrowUp   = #$1E;
  ScrollArrowDown = #$1F;
  SolidBlock      = #$87;

  { The PC-98 text ROM keeps four arrow glyphs in the control-code region:
    $1C right, $1D left, $1E up, $1F down.  The up arrow is used as the mouse
    pointer because, drawn in normal (non-reverse) video, only the arrow
    pixels appear and the pointer reads as an arrow instead of a solid cell. }
  MouseArrow = #$1E;

  { Graphics-plane color indices used beneath reverse-video text.  A reverse
    text glyph is transparent on PC-98, so the graphics color underneath it
    becomes the visible glyph color. }
  GraphicsBlack    = $00;
  GraphicsBlue     = $01;
  GraphicsDarkGray = $08;

{ Reads one character and attribute from bounded PC-98 text VRAM. }
procedure GetCell(X, Y: Byte; var Ch: Char; var Attr: Byte);
{ Writes one character and attribute to bounded PC-98 text VRAM. }
procedure PutCell(X, Y: Byte; Ch: Char; Attr: Byte);
{ Writes a string horizontally without crossing the screen edge. }
procedure PutText(X, Y: Byte; const S: String; Attr: Byte);
{ Clears and writes a fixed-width text field. }
procedure WriteField(X, Y, Width: Byte; const S: String; Attr: Byte);
{ Fills a bounded rectangular region of text VRAM. }
procedure FillRect(X1, Y1, X2, Y2: Byte; Ch: Char; Attr: Byte);
{ Draws a native PC-98 single-line frame around a rectangle. }
procedure DrawFrame(X1, Y1, X2, Y2: Byte; Attr: Byte);
{ Draws an opaque right-and-bottom shadow for a floating window. }
procedure DrawDropShadow(X1, Y1, X2, Y2: Byte; Attr: Byte);
{ Fills graphics pixels corresponding to a bounded text-cell rectangle. }
procedure FillGraphicsCellRect(X1, Y1, X2, Y2, ColorIndex: Byte);
{ Paints dark-gray upper/left and black lower/right frame backdrops. }
procedure ShadeGraphicsFrame(X1, Y1, X2, Y2: Byte);
{ Disables the PC-98 BIOS hardware text cursor. }
procedure HideTextCursor;
{ Re-enables the PC-98 BIOS hardware text cursor. }
procedure ShowTextCursor;
{ Initializes and displays the graphics backdrop in blue or black. }
procedure SetGraphicsBackdrop(Blue: Boolean);
{ Clears graphics VRAM and switches off the backdrop display. }
procedure ShutdownGraphicsBackdrop;

implementation

uses
  Dos;

const
  { 640x400 8-color bitmap planes, one bit per pixel, 32000 bytes each. }
  GraphPlaneB     = $A800;
  GraphPlaneR     = $B000;
  GraphPlaneG     = $B800;
  GraphPlaneE     = $E000;
  GraphPlaneBytes = 32000;

{ Fills one complete PC-98 graphics plane with a byte pattern. }
procedure FillGraphicsPlane(PlaneSegment: Word; Value: Byte);
var
  Offset: Word;
begin
  { Do not construct a repeated $FFFF word with a checked 16-bit shift here.
    With overflow checking enabled, the former `(Word(Value) shl 8) or Value` expression could be
    evaluated through a signed 16-bit intermediate when Value was $FF, raising
    runtime error 215 before the first EDIT98 frame appeared.  Writing bytes
    directly is slightly less clever but unambiguous on every i8086 FPC build. }
  Offset := 0;
  while Offset < GraphPlaneBytes do
  begin
    Mem[PlaneSegment:Offset] := Value;
    Inc(Offset);
  end;
end;

{ Fills graphics pixels corresponding to a bounded text-cell rectangle. }
procedure FillGraphicsCellRect(X1, Y1, X2, Y2, ColorIndex: Byte);
var
  CellX: Byte;
  PixelY, Offset: Word;
  BlueValue, RedValue, GreenValue, IntensityValue: Byte;
begin
  if (X1 > X2) or (Y1 > Y2) or
     (X1 >= ScreenWidth) or (Y1 >= ScreenHeight) then
    Exit;
  if X2 >= ScreenWidth then
    X2 := ScreenWidth - 1;
  if Y2 >= ScreenHeight then
    Y2 := ScreenHeight - 1;

  if (ColorIndex and $01) <> 0 then BlueValue := $FF else BlueValue := $00;
  if (ColorIndex and $02) <> 0 then RedValue := $FF else RedValue := $00;
  if (ColorIndex and $04) <> 0 then GreenValue := $FF else GreenValue := $00;
  if (ColorIndex and $08) <> 0 then IntensityValue := $FF else IntensityValue := $00;

  { Every 8x16 text cell maps to one byte on each of sixteen consecutive
    graphics scan lines.  Updating the underlying planes lets reverse-video
    text retain an opaque pale surface while its glyph cut-outs become black
    or dark gray instead of revealing the document's blue backdrop. }
  for PixelY := Word(Y1) * 16 to Word(Y2) * 16 + 15 do
  begin
    Offset := PixelY * 80 + X1;
    for CellX := X1 to X2 do
    begin
      Mem[$A800:Offset] := BlueValue;
      Mem[$B000:Offset] := RedValue;
      Mem[$B800:Offset] := GreenValue;
      Mem[$E000:Offset] := IntensityValue;
      Inc(Offset);
    end;
  end;
end;

{ Paints dark-gray upper/left and black lower/right frame backdrops. }
procedure ShadeGraphicsFrame(X1, Y1, X2, Y2: Byte);
begin
  if (X2 <= X1) or (Y2 <= Y1) then
    Exit;

  { Dark gray on the upper/left edges and black on the lower/right edges gives
    pale reverse-video frames a restrained two-tone bevel.  Eight-color PC-98
    hardware ignores the intensity plane, gracefully falling back to black. }
  FillGraphicsCellRect(X1, Y1, X2, Y1, GraphicsDarkGray);
  FillGraphicsCellRect(X1, Y1, X1, Y2, GraphicsDarkGray);
  FillGraphicsCellRect(X1, Y2, X2, Y2, GraphicsBlack);
  FillGraphicsCellRect(X2, Y1, X2, Y2, GraphicsBlack);
end;

{ Disables the PC-98 BIOS hardware text cursor. }
procedure HideTextCursor; assembler; nostackframe;
asm
  { Call the PC-98 CRT BIOS directly.  This avoids routing a no-argument BIOS
    service through FPC's generic Registers/Intr wrapper during startup. }
  mov ah,$12
  int $18
end;

{ Re-enables the PC-98 BIOS hardware text cursor. }
procedure ShowTextCursor; assembler; nostackframe;
asm
  mov ah,$11
  int $18
end;

{ Initializes and displays the graphics backdrop in blue or black. }
procedure SetGraphicsBackdrop(Blue: Boolean);
var
  R: Registers;
  BlueFill: Byte;
begin
  { A PC-98 text cell carries a single color: normal video draws the glyph in
    that color over a transparent background, and reverse video draws a black
    glyph on a cell of that color.  White text on a blue field is therefore
    impossible in the text plane alone.  The classic PC-98 answer is used
    here: the graphics screen is filled with solid blue and left underneath
    the text plane, so every normal-video cell picks up a blue background
    while reverse-video cells (menus, status line, dialogs) stay opaque. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $42;
  R.CH := $C0;               { CH bits 7..6 = 11: 640x400 color display area }
  Intr($18, R);

  if Blue then
    BlueFill := $FF
  else
    BlueFill := $00;
  FillGraphicsPlane(GraphPlaneB, BlueFill);
  FillGraphicsPlane(GraphPlaneR, $00);
  FillGraphicsPlane(GraphPlaneG, $00);
  { The fourth (intensity) plane exists on 16-color hardware.  Clearing it
    keeps the backdrop color index correct there; 8-color machines simply
    ignore writes to this segment. }
  FillGraphicsPlane(GraphPlaneE, $00);

  FillChar(R, SizeOf(R), 0);
  R.AH := $40;               { graphics display on }
  Intr($18, R);
end;

{ Clears graphics VRAM and switches off the backdrop display. }
procedure ShutdownGraphicsBackdrop;
var
  R: Registers;
begin
  { Clear the planes and stop the graphics display so the DOS prompt returns
    to its ordinary text-only appearance after EDIT98 exits. }
  FillGraphicsPlane(GraphPlaneB, $00);
  FillGraphicsPlane(GraphPlaneR, $00);
  FillGraphicsPlane(GraphPlaneG, $00);
  FillGraphicsPlane(GraphPlaneE, $00);
  FillChar(R, SizeOf(R), 0);
  R.AH := $41;               { graphics display off }
  Intr($18, R);
end;

{ Reads one character and attribute from bounded PC-98 text VRAM. }
procedure GetCell(X, Y: Byte; var Ch: Char; var Attr: Byte);
var
  Ofs: Word;
begin
  if (X >= ScreenWidth) or (Y >= ScreenHeight) then
  begin
    Ch := ' ';
    Attr := AttrWhite;
    Exit;
  end;

  { The mouse overlay must restore the exact character and attribute which
    occupied its cell.  Reading both planes here keeps raw VRAM access inside
    the screen unit, just like PutCell does for writes. }
  Ofs := Word(Y) * 160 + Word(X) * 2;
  Ch := Chr(MemW[$A000:Ofs] and $00FF);
  Attr := Mem[$A200:Ofs];
end;

{ Writes one character and attribute to bounded PC-98 text VRAM. }
procedure PutCell(X, Y: Byte; Ch: Char; Attr: Byte);
var
  Ofs: Word;
begin
  if (X >= ScreenWidth) or (Y >= ScreenHeight) then
    Exit;

  { Character and attribute planes use matching even offsets.  Keeping the
    calculation here leaves all raw VRAM access inside this unit. }
  Ofs := Word(Y) * 160 + Word(X) * 2;
  MemW[$A000:Ofs] := Ord(Ch);
  Mem[$A200:Ofs] := Attr;
end;

{ Writes a string horizontally without crossing the screen edge. }
procedure PutText(X, Y: Byte; const S: String; Attr: Byte);
var
  I: Byte;
begin
  I := 1;
  while (I <= Length(S)) and (X < ScreenWidth) do
  begin
    PutCell(X, Y, S[I], Attr);
    Inc(I);
    Inc(X);
  end;
end;

{ Clears and writes a fixed-width text field. }
procedure WriteField(X, Y, Width: Byte; const S: String; Attr: Byte);
var
  I: Byte;
begin
  { Every cell in a field is overwritten so stale menu labels and filenames
    disappear without clearing or flashing the whole dialog. }
  for I := 0 to Width - 1 do
  begin
    if I + 1 <= Length(S) then
      PutCell(X + I, Y, S[I + 1], Attr)
    else
      PutCell(X + I, Y, ' ', Attr);
  end;
end;

{ Fills a bounded rectangular region of text VRAM. }
procedure FillRect(X1, Y1, X2, Y2: Byte; Ch: Char; Attr: Byte);
var
  X, Y: Byte;
begin
  if (X1 > X2) or (Y1 > Y2) then
    Exit;

  for Y := Y1 to Y2 do
    for X := X1 to X2 do
      PutCell(X, Y, Ch, Attr);
end;

{ Draws a native PC-98 single-line frame around a rectangle. }
procedure DrawFrame(X1, Y1, X2, Y2: Byte; Attr: Byte);
var
  X, Y: Byte;
begin
  if (X2 <= X1) or (Y2 <= Y1) then
    Exit;

  PutCell(X1, Y1, FrameTopLeft, Attr);
  PutCell(X2, Y1, FrameTopRight, Attr);
  PutCell(X1, Y2, FrameBottomLeft, Attr);
  PutCell(X2, Y2, FrameBottomRight, Attr);

  for X := X1 + 1 to X2 - 1 do
  begin
    PutCell(X, Y1, FrameHorizontal, Attr);
    PutCell(X, Y2, FrameHorizontal, Attr);
  end;

  for Y := Y1 + 1 to Y2 - 1 do
  begin
    PutCell(X1, Y, FrameVertical, Attr);
    PutCell(X2, Y, FrameVertical, Attr);
  end;
end;

{ Draws an opaque right-and-bottom shadow for a floating window. }
procedure DrawDropShadow(X1, Y1, X2, Y2: Byte; Attr: Byte);
var
  X, Y, ShadowRight, ShadowBottom: Byte;
begin
  { Microsoft-style text interfaces offset shadows by two columns and one row.
    SolidBlock is used instead of a blank cell so the shadow remains opaque over
    both ordinary text and a reverse-video colored editing field. }
  if X2 < ScreenWidth - 1 then
  begin
    ShadowRight := X2 + 2;
    if ShadowRight >= ScreenWidth then
      ShadowRight := ScreenWidth - 1;
    for Y := Y1 + 1 to Y2 do
      for X := X2 + 1 to ShadowRight do
        PutCell(X, Y, SolidBlock, Attr);
  end;

  if Y2 < ScreenHeight - 1 then
  begin
    ShadowBottom := Y2 + 1;
    ShadowRight := X2 + 2;
    if ShadowRight >= ScreenWidth then
      ShadowRight := ScreenWidth - 1;
    for X := X1 + 2 to ShadowRight do
      PutCell(X, ShadowBottom, SolidBlock, Attr);
  end;
end;

end.
