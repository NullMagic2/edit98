unit PC98Fonts;

{ Logical RTF-font metadata module.  EDIT98 preserves Serif, Sans Serif, and
  Monospace runs when importing, editing, copying, and saving RTF files, but
  document text is rendered exclusively by the native PC-98 text ROM—the same
  hardware font used by menus and dialogs.  No custom bitmap glyphs or graphics-
  plane font renderer remain in this unit. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}

interface

const
  FontStyleBytesPerLine = 64;  { 256 characters at two bits per character }
  FontFamilyCount = 3;

type
  TFontFamily = (ffSerif, ffSansSerif, ffMonospace);
  TFontStyleLine = array[0..FontStyleBytesPerLine - 1] of Byte;

{ Returns the user-facing name of one logical family. }
function FontFamilyName(Family: TFontFamily): String;
{ Sets every character position in one packed line to the same family. }
procedure ClearFontStyleLine(var Styles: TFontStyleLine; Family: TFontFamily);
{ Reads one two-bit family value from a packed style line. }
function GetFontFamily(const Styles: TFontStyleLine; Column: Word): TFontFamily;
{ Writes one two-bit family value into a packed style line. }
procedure SetFontFamily(var Styles: TFontStyleLine; Column: Word;
  Family: TFontFamily);
{ Copies a bounded run of family values between packed style lines. }
procedure CopyFontFamilies(const Source: TFontStyleLine; SourceColumn,
  Count: Word; var Destination: TFontStyleLine; DestinationColumn: Word);
{ Moves family values right by one position for a character insertion. }
procedure InsertFontFamily(var Styles: TFontStyleLine; Column, OldLength: Word;
  Family: TFontFamily);
{ Removes one family value and closes the resulting gap. }
procedure DeleteFontFamily(var Styles: TFontStyleLine; Column, OldLength: Word;
  FillFamily: TFontFamily);

implementation

{ Returns the user-facing name of one logical family. }
function FontFamilyName(Family: TFontFamily): String;
begin
  case Family of
    ffSerif: FontFamilyName := 'Serif';
    ffMonospace: FontFamilyName := 'Monospace';
    else FontFamilyName := 'Sans Serif';
  end;
end;

{ Converts one family into the repeated two-bit pattern for a packed byte. }
function PackedFamilyByte(Family: TFontFamily): Byte;
begin
  case Family of
    ffSerif: PackedFamilyByte := $00;
    ffMonospace: PackedFamilyByte := $AA;
    else PackedFamilyByte := $55;
  end;
end;

{ Sets every character position in one packed line to the same family. }
procedure ClearFontStyleLine(var Styles: TFontStyleLine; Family: TFontFamily);
begin
  FillChar(Styles, SizeOf(Styles), PackedFamilyByte(Family));
end;

{ Reads one two-bit family value from a packed style line. }
function GetFontFamily(const Styles: TFontStyleLine; Column: Word): TFontFamily;
var
  ByteIndex, ShiftCount: Word;
  FamilyValue: Byte;
begin
  if Column > 255 then
  begin
    GetFontFamily := ffSansSerif;
    Exit;
  end;

  ByteIndex := Column div 4;
  ShiftCount := (Column mod 4) * 2;
  FamilyValue := (Styles[ByteIndex] shr ShiftCount) and $03;
  case FamilyValue of
    0: GetFontFamily := ffSerif;
    2: GetFontFamily := ffMonospace;
    else GetFontFamily := ffSansSerif;
  end;
end;

{ Writes one two-bit family value into a packed style line. }
procedure SetFontFamily(var Styles: TFontStyleLine; Column: Word;
  Family: TFontFamily);
var
  ByteIndex, ShiftCount: Word;
  Mask, FamilyBits: Byte;
begin
  if Column > 255 then
    Exit;

  ByteIndex := Column div 4;
  ShiftCount := (Column mod 4) * 2;
  Mask := Byte($03 shl ShiftCount);
  FamilyBits := Byte(Ord(Family) shl ShiftCount);
  Styles[ByteIndex] := (Styles[ByteIndex] and ($FF xor Mask)) or FamilyBits;
end;

{ Copies a bounded run of family values between packed style lines. }
procedure CopyFontFamilies(const Source: TFontStyleLine; SourceColumn,
  Count: Word; var Destination: TFontStyleLine; DestinationColumn: Word);
var
  I: Word;
begin
  I := 0;
  while (I < Count) and (SourceColumn + I <= 255) and
        (DestinationColumn + I <= 255) do
  begin
    SetFontFamily(Destination, DestinationColumn + I,
      GetFontFamily(Source, SourceColumn + I));
    Inc(I);
  end;
end;

{ Moves family values right by one position for a character insertion. }
procedure InsertFontFamily(var Styles: TFontStyleLine; Column, OldLength: Word;
  Family: TFontFamily);
var
  I: Word;
begin
  if Column > OldLength then
    Column := OldLength;
  if OldLength > 255 then
    OldLength := 255;

  I := OldLength;
  while I > Column do
  begin
    SetFontFamily(Styles, I, GetFontFamily(Styles, I - 1));
    Dec(I);
  end;
  SetFontFamily(Styles, Column, Family);
end;

{ Removes one family value and closes the resulting gap. }
procedure DeleteFontFamily(var Styles: TFontStyleLine; Column, OldLength: Word;
  FillFamily: TFontFamily);
var
  I: Word;
begin
  if (OldLength = 0) or (Column >= OldLength) then
    Exit;

  I := Column;
  while I + 1 < OldLength do
  begin
    SetFontFamily(Styles, I, GetFontFamily(Styles, I + 1));
    Inc(I);
  end;
  SetFontFamily(Styles, OldLength - 1, FillFamily);
end;

end.
