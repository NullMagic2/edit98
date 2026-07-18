unit PC98Mouse;

{ Mouse backend.  It detects and polls a resident INT 33h driver, configures
  movement speed, and draws an editor-owned text-VRAM arrow while preserving
  the character and attribute beneath the pointer. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}

interface

type
  TMouseState = record
    X: Word;
    Y: Word;
    Buttons: Word;
  end;

{ Detects and initializes an INT 33h mouse driver without showing its cursor. }
function InitMouse: Boolean;
{ Enables and paints the editor-owned mouse arrow. }
procedure ShowMouse;
{ Removes the editor-owned mouse arrow and restores its background. }
procedure HideMouse;
{ Returns current mouse state and keeps the visible arrow synchronized. }
procedure PollMouse(var State: TMouseState);
{ Sets the resident driver mickey-to-pixel movement ratio. }
procedure SetMouseSpeed(HorizontalMickeys, VerticalMickeys: Word);
{ Changes the text glyph and attribute used for the mouse arrow. }
procedure SetMouseCursorAppearance(Glyph: Char; Attr: Byte);

implementation

uses
  Dos, PC98Screen;

var
  Present: Boolean;
  CursorVisible: Boolean;
  SavedCellValid: Boolean;
  CursorCellX, CursorCellY: Byte;
  SavedCharacter, CursorGlyph: Char;
  SavedAttribute, CursorAttribute: Byte;

{ Reads coordinates and buttons from the resident INT 33h driver. }
procedure ReadDriverState(var State: TMouseState);
var
  R: Registers;
begin
  if not Present then
  begin
    State.X := 0;
    State.Y := 0;
    State.Buttons := 0;
    Exit;
  end;

  FillChar(R, SizeOf(R), 0);
  R.AX := $0003;
  Intr($33, R);
  State.Buttons := R.BX;
  State.X := R.CX;
  State.Y := R.DX;
end;

{ Restores the text cell previously covered by the mouse arrow. }
procedure RestoreSavedCell;
begin
  if not SavedCellValid then
    Exit;

  PutCell(CursorCellX, CursorCellY, SavedCharacter, SavedAttribute);
  SavedCellValid := False;
end;

{ Saves a text cell and paints the editor-owned mouse arrow over it. }
procedure PaintCursorAt(CellX, CellY: Byte);
begin
  { The resident PC-98 mouse driver often paints into a graphics plane below
    reverse-video text.  EDIT98 therefore leaves the driver's visual cursor
    hidden and draws this one-cell cursor directly in text VRAM.  Saving the
    original cell makes the overlay independent of menus, dialogs and themes. }
  GetCell(CellX, CellY, SavedCharacter, SavedAttribute);
  CursorCellX := CellX;
  CursorCellY := CellY;
  SavedCellValid := True;
  PutCell(CellX, CellY, CursorGlyph, CursorAttribute);
end;

{ Moves the text-VRAM arrow only when its cell position changes. }
procedure MoveVisibleCursor(const State: TMouseState);
var
  NewX, NewY: Word;
begin
  if not CursorVisible then
    Exit;

  NewX := State.X div 8;
  NewY := State.Y div 16;
  if NewX >= ScreenWidth then
    NewX := ScreenWidth - 1;
  if NewY >= ScreenHeight then
    NewY := ScreenHeight - 1;

  if SavedCellValid and
     (CursorCellX = Byte(NewX)) and (CursorCellY = Byte(NewY)) then
    Exit;

  RestoreSavedCell;
  PaintCursorAt(Byte(NewX), Byte(NewY));
end;

{ Detects and initializes an INT 33h mouse driver without showing its cursor. }
function InitMouse: Boolean;
var
  R: Registers;
begin
  Present := False;
  CursorVisible := False;
  SavedCellValid := False;

  { Check the INT 33h vector before invoking it.  This avoids jumping through
    a null vector on systems where MOUSE.COM has not been loaded yet. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $35;
  R.AL := $33;
  MsDos(R);
  if (R.ES = 0) and (R.BX = 0) then
  begin
    InitMouse := False;
    Exit;
  end;

  FillChar(R, SizeOf(R), 0);
  R.AX := $0000;
  Intr($33, R);
  Present := R.AX <> 0;

  if Present then
  begin
    { The reset operation hides the driver's own pointer.  Keep it hidden: its
      graphics-plane cursor can sit behind PC-98 reverse-video text. }
    FillChar(R, SizeOf(R), 0);
    R.AX := $0007;
    R.CX := 0;
    R.DX := 639;
    Intr($33, R);

    FillChar(R, SizeOf(R), 0);
    R.AX := $0008;
    R.CX := 0;
    R.DX := 399;
    Intr($33, R);
  end;

  InitMouse := Present;
end;

{ Enables and paints the editor-owned mouse arrow. }
procedure ShowMouse;
var
  State: TMouseState;
begin
  if (not Present) or CursorVisible then
    Exit;

  CursorVisible := True;
  ReadDriverState(State);
  MoveVisibleCursor(State);
end;

{ Removes the editor-owned mouse arrow and restores its background. }
procedure HideMouse;
begin
  if not CursorVisible then
    Exit;

  RestoreSavedCell;
  CursorVisible := False;
end;

{ Returns current mouse state and keeps the visible arrow synchronized. }
procedure PollMouse(var State: TMouseState);
begin
  ReadDriverState(State);
  MoveVisibleCursor(State);
end;

{ Sets the resident driver mickey-to-pixel movement ratio. }
procedure SetMouseSpeed(HorizontalMickeys, VerticalMickeys: Word);
var
  R: Registers;
begin
  if not Present then
    Exit;

  { INT 33h function 0Fh: mickeys required for eight pixels of motion.
    Lower values produce faster pointer movement. }
  if HorizontalMickeys = 0 then
    HorizontalMickeys := 1;
  if VerticalMickeys = 0 then
    VerticalMickeys := 1;

  FillChar(R, SizeOf(R), 0);
  R.AX := $000F;
  R.CX := HorizontalMickeys;
  R.DX := VerticalMickeys;
  Intr($33, R);
end;

{ Changes the text glyph and attribute used for the mouse arrow. }
procedure SetMouseCursorAppearance(Glyph: Char; Attr: Byte);
var
  WasVisible: Boolean;
  State: TMouseState;
begin
  { Theme changes can happen while the Options menu is open.  Remove the old
    overlay before changing its attribute, then repaint it over the updated UI. }
  WasVisible := CursorVisible;
  if WasVisible then
    RestoreSavedCell;

  CursorGlyph := Glyph;
  CursorAttribute := Attr;

  if WasVisible then
  begin
    ReadDriverState(State);
    MoveVisibleCursor(State);
  end;
end;

begin
  Present := False;
  CursorVisible := False;
  SavedCellValid := False;
  { Normal (non-reverse) video draws only the arrow glyph's own pixels, so
    the pointer looks like an arrow instead of a filled reverse-video cell.
    ApplyColorScheme in the editor refreshes this for each theme. }
  CursorGlyph := MouseArrow;
  CursorAttribute := AttrWhite;
end.
