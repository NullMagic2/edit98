unit PC98Kbd;

{ PC-98 keyboard backend.  It polls the NEC BIOS through INT 18h, returns
  translated characters and native scan codes, and reports modifier state
  for selection, shortcuts, and GRPH/Alt-style menu activation. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}

interface

type
  TKeyEvent = record
    AsciiCode: Byte;
    ScanCode: Byte;
    ShiftState: Byte;
  end;

const
  ShiftPressed = $01;
  CapsLocked   = $02;
  KanaLocked   = $04;
  GraphPressed = $08;
  CtrlPressed  = $10;

  { PC-98 letter-key scan codes.  These remain stable even when GRPH/Alt
    changes the character returned in AL, so menu accelerators can be matched
    by physical key rather than by the translated JIS byte. }
  ScanQ         = $10;
  ScanW         = $11;
  ScanE         = $12;
  ScanR         = $13;
  ScanT         = $14;
  ScanY         = $15;
  ScanU         = $16;
  ScanI         = $17;
  ScanO         = $18;
  ScanP         = $19;
  ScanA         = $1D;
  ScanS         = $1E;
  ScanD         = $1F;
  ScanF         = $20;
  ScanG         = $21;
  ScanH         = $22;
  ScanJ         = $23;
  ScanK         = $24;
  ScanL         = $25;
  ScanZ         = $29;
  ScanX         = $2A;
  ScanC         = $2B;
  ScanV         = $2C;
  ScanB         = $2D;
  ScanN         = $2E;
  ScanM         = $2F;

  { XFER and NFER are mapped from the host Alt keys by common PC-98 emulators;
    GRPH is the native PC-98 modifier that most closely corresponds to Alt. }
  ScanXfer      = $35;
  ScanRollUp    = $36;
  ScanRollDown  = $37;
  ScanInsert    = $38;
  ScanDelete    = $39;
  ScanUp        = $3A;
  ScanLeft      = $3B;
  ScanRight     = $3C;
  ScanDown      = $3D;
  ScanHomeClear = $3E;
  ScanHelp      = $3F;
  ScanNfer      = $51;
  ScanF1        = $62;
  ScanF2        = $63;
  ScanF3        = $64;
  ScanF4        = $65;
  ScanF10       = $6B;
  ScanGraph     = $73;

{ Non-blockingly consumes one PC-98 BIOS key event when available. }
function PollKey(var Event: TKeyEvent): Boolean;
{ Reads PC-98 keyboard modifier and lock state from BIOS INT 18h. }
function ReadShiftState: Byte;

implementation

uses Dos;

{ Reads PC-98 keyboard modifier and lock state from BIOS INT 18h. }
function ReadShiftState: Byte;
var
  R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $02;
  Intr($18, R);
  ReadShiftState := R.AL;
end;

{ Non-blockingly consumes one PC-98 BIOS key event when available. }
function PollKey(var Event: TKeyEvent): Boolean;
var
  R: Registers;
begin
  { INT 18h function 01h checks the PC-98 BIOS keyboard buffer without
    blocking.  BH is zero when no complete key event is waiting. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $01;
  Intr($18, R);
  if R.BH = 0 then
  begin
    PollKey := False;
    Exit;
  end;

  { Function 00h consumes the key: AH is the PC-98 scan code and AL is the
    translated single-byte character. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $00;
  Intr($18, R);
  Event.ScanCode := R.AH;
  Event.AsciiCode := R.AL;

  { Modifier state is read separately so Shift-selection and Ctrl shortcuts
    use the physical PC-98 keyboard state rather than IBM-compatible codes. }
  Event.ShiftState := ReadShiftState;

  PollKey := True;
end;

end.
