unit RTFCodec;

{ Rich Text Format interchange module.  It imports a deliberately bounded RTF
  subset into EDIT98's paged text-and-font model and exports that model as
  standards-oriented RTF containing Serif, Sans Serif, Monospace runs, and
  explicit page breaks. Unsupported destinations and formatting are skipped
  without exposing their control words as document text. }

{$mode objfpc}
{$H-}
{$R+}
{ The RTF reader validates every numeric conversion and document index itself.
  FPC 3.2.2's 16-bit i8086 backend can nevertheless emit false arithmetic-
  overflow traps for mixed signed/unsigned expressions when Q+ is enabled.
  That made valid RTF input terminate with runtime error 215.  Keep range
  checking enabled for arrays and strings, but disable generated arithmetic
  traps in this bounded codec. }
{$Q-}

interface

uses
  EditorBuf, PC98Fonts;

{ Reports whether a DOS path has an RTF extension. }
function IsRtfFileName(const FileName: String): Boolean;
{ Loads RTF text and logical font runs into a document buffer. }
function LoadRtfFile(const FileName: String; var Buffer: TTextBuffer;
  var ErrorText: String): Boolean;
{ Saves document text and logical font runs as an RTF document. }
function SaveRtfFile(const FileName: String; var Buffer: TTextBuffer;
  var ErrorText: String): Boolean;

implementation

const
  MaxRtfDepth = 32;
  MaxRtfFonts = 64;
  RtfReadBufferSize = 1024;

  DestinationDocument = 0;
  DestinationFontTable = 1;
  DestinationSkipped   = 2;

type
  TRtfReader = object
    Stream: File;
    IsOpen: Boolean;
    HasPushback: Boolean;
    PushbackChar: Char;
    ReadBuffer: array[0..RtfReadBufferSize - 1] of Char;
    ReadPosition, ReadCount: Word;
    { Opens a byte-oriented RTF stream. }
    function Open(const FileName: String; var ErrorCode: Integer): Boolean;
    { Returns the next byte, including an optional pushed-back delimiter. }
    function ReadChar(var Ch: Char): Boolean;
    { Makes one delimiter available to the next read operation. }
    procedure UnreadChar(Ch: Char);
    { Closes the stream when it is open. }
    procedure Close;
  end;

  TRtfState = record
    Destination: Byte;
    Family: TFontFamily;
    UnicodeSkipCount: Byte;
    FontDefinitionNumber: Integer;
    FontDefinitionFamily: TFontFamily;
    FontDefinitionName: String[48];
  end;

  TRtfStateStack = array[0..MaxRtfDepth - 1] of TRtfState;
  TRtfFontMap = array[0..MaxRtfFonts - 1] of TFontFamily;
  TRtfFontFlags = array[0..MaxRtfFonts - 1] of Boolean;

var
  { Printer pagination metadata collected from the document-level RTF
    controls. These are intentionally module-local: LoadRtfFile initializes
    them for each import and the codec is single-threaded under DOS. }
  LayoutPaperHeightTwips: LongInt;
  LayoutMarginTopTwips: LongInt;
  LayoutMarginBottomTwips: LongInt;
  LayoutLineSpacingTwips: LongInt;

{ Converts one ASCII letter to uppercase without locale tables. }
function UpperAscii(C: Char): Char;
begin
  if (C >= 'a') and (C <= 'z') then
    UpperAscii := Chr(Ord(C) - Ord('a') + Ord('A'))
  else
    UpperAscii := C;
end;

{ Converts one ASCII letter to lowercase without locale tables. }
function LowerAscii(C: Char): Char;
begin
  if (C >= 'A') and (C <= 'Z') then
    LowerAscii := Chr(Ord(C) - Ord('A') + Ord('a'))
  else
    LowerAscii := C;
end;

{ Returns an uppercase copy suitable for simple font-name matching. }
function UpperAsciiString(const S: String): String;
var
  I: Byte;
begin
  UpperAsciiString := S;
  for I := 1 to Length(UpperAsciiString) do
    UpperAsciiString[I] := UpperAscii(UpperAsciiString[I]);
end;

{ Reports whether one ASCII character can belong to an RTF control word. }
function IsAsciiLetter(C: Char): Boolean;
begin
  IsAsciiLetter := ((C >= 'A') and (C <= 'Z')) or
                   ((C >= 'a') and (C <= 'z'));
end;

{ Reports whether one ASCII character is a decimal digit. }
function IsAsciiDigit(C: Char): Boolean;
begin
  IsAsciiDigit := (C >= '0') and (C <= '9');
end;

{ Opens a byte-oriented RTF stream. }
function TRtfReader.Open(const FileName: String;
  var ErrorCode: Integer): Boolean;
begin
  IsOpen := False;
  HasPushback := False;
  ReadPosition := 0;
  ReadCount := 0;
  Assign(Stream, FileName);
  {$I-}
  Reset(Stream, 1);
  ErrorCode := IOResult;
  {$I+}
  IsOpen := ErrorCode = 0;
  Open := IsOpen;
end;

{ Returns the next byte, including an optional pushed-back delimiter. }
function TRtfReader.ReadChar(var Ch: Char): Boolean;
var
  BytesRead: Word;
begin
  if HasPushback then
  begin
    Ch := PushbackChar;
    HasPushback := False;
    ReadChar := True;
    Exit;
  end;
  if not IsOpen then
  begin
    ReadChar := False;
    Exit;
  end;

  if ReadPosition >= ReadCount then
  begin
    BytesRead := 0;
    {$I-}
    BlockRead(Stream, ReadBuffer, RtfReadBufferSize, BytesRead);
    {$I+}
    ReadCount := BytesRead;
    ReadPosition := 0;
    if ReadCount = 0 then
    begin
      ReadChar := False;
      Exit;
    end;
  end;

  Ch := ReadBuffer[ReadPosition];
  Inc(ReadPosition);
  ReadChar := True;
end;

{ Makes one delimiter available to the next read operation. }
procedure TRtfReader.UnreadChar(Ch: Char);
begin
  PushbackChar := Ch;
  HasPushback := True;
end;

{ Closes the stream when it is open. }
procedure TRtfReader.Close;
begin
  if IsOpen then
  begin
    {$I-}
    System.Close(Stream);
    IOResult;
    {$I+}
  end;
  IsOpen := False;
  HasPushback := False;
  ReadPosition := 0;
  ReadCount := 0;
end;

{ Returns the final four filename characters in uppercase when available. }
function FileExtensionUpper(const FileName: String): String;
var
  I, DotPosition: Integer;
  ResultText: String;
begin
  DotPosition := 0;
  for I := 1 to Length(FileName) do
    if FileName[I] = '.' then
      DotPosition := I
    else if (FileName[I] = '\') or (FileName[I] = '/') or
            (FileName[I] = ':') then
      DotPosition := 0;

  if DotPosition = 0 then
    ResultText := ''
  else
    ResultText := Copy(FileName, DotPosition, 16);
  FileExtensionUpper := UpperAsciiString(ResultText);
end;

{ Reports whether a DOS path has an RTF extension. }
function IsRtfFileName(const FileName: String): Boolean;
begin
  IsRtfFileName := FileExtensionUpper(FileName) = '.RTF';
end;

{ Converts a hexadecimal digit into its numeric value. }
function HexValue(C: Char; var Valid: Boolean): Byte;
begin
  Valid := True;
  if (C >= '0') and (C <= '9') then
    HexValue := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'f') then
    HexValue := Ord(C) - Ord('a') + 10
  else if (C >= 'A') and (C <= 'F') then
    HexValue := Ord(C) - Ord('A') + 10
  else
  begin
    Valid := False;
    HexValue := 0;
  end;
end;

{ Reads an RTF control word, optional signed parameter, and delimiter. }
procedure ReadControlWord(var Reader: TRtfReader; FirstChar: Char;
  var ControlWord: String; var HasParameter: Boolean;
  var Parameter: LongInt);
var
  Ch: Char;
  Negative: Boolean;
  HaveDelimiter: Boolean;
  Value: LongInt;
begin
  ControlWord := '';
  Ch := FirstChar;
  while IsAsciiLetter(Ch) do
  begin
    if Length(ControlWord) < 31 then
      ControlWord := ControlWord + LowerAscii(Ch);
    if not Reader.ReadChar(Ch) then
    begin
      Ch := #0;
      Break;
    end;
  end;

  HasParameter := False;
  Negative := False;
  if Ch = '-' then
  begin
    Negative := True;
    if not Reader.ReadChar(Ch) then
      Ch := #0;
  end;

  Value := 0;
  while IsAsciiDigit(Ch) do
  begin
    HasParameter := True;
    { Clamp hostile or irrelevant giant parameters before multiplication. }
    if Value < 1000000 then
      Value := (Value * LongInt(10)) + LongInt(Ord(Ch) - Ord('0'));
    if not Reader.ReadChar(Ch) then
    begin
      Ch := #0;
      Break;
    end;
  end;
  if Negative then
    Value := -Value;
  Parameter := Value;

  HaveDelimiter := Ch <> #0;
  if HaveDelimiter and (Ch <> ' ') then
    Reader.UnreadChar(Ch);
end;

{ Tests whether a control word introduces content EDIT98 deliberately skips. }
function IsSkippedDestination(const ControlWord: String): Boolean;
begin
  IsSkippedDestination :=
    (ControlWord = 'colortbl') or (ControlWord = 'stylesheet') or
    (ControlWord = 'info') or (ControlWord = 'pict') or
    (ControlWord = 'object') or (ControlWord = 'header') or
    (ControlWord = 'headerl') or (ControlWord = 'headerr') or
    (ControlWord = 'footer') or (ControlWord = 'footerl') or
    (ControlWord = 'footerr') or (ControlWord = 'footnote') or
    (ControlWord = 'annotation') or
    (ControlWord = 'fldinst') or (ControlWord = 'generator') or
    (ControlWord = 'datastore') or (ControlWord = 'xmlnstbl') or
    (ControlWord = 'listtable') or
    (ControlWord = 'listoverridetable') or
    (ControlWord = 'themedata');
end;

{ Chooses a logical family from an RTF family tag and font name. }
function ResolveFontDefinition(TaggedFamily: TFontFamily;
  const FontName: String): TFontFamily;
var
  UpperName: String;
begin
  UpperName := UpperAsciiString(FontName);
  if (Pos('COURIER', UpperName) > 0) or
     (Pos('MONO', UpperName) > 0) or
     (Pos('CONSOLAS', UpperName) > 0) or
     (Pos('TERMINAL', UpperName) > 0) or
     (Pos('FIXED', UpperName) > 0) then
    ResolveFontDefinition := ffMonospace
  else if (Pos('ARIAL', UpperName) > 0) or
          (Pos('HELVETICA', UpperName) > 0) or
          (Pos('TAHOMA', UpperName) > 0) or
          (Pos('VERDANA', UpperName) > 0) or
          (Pos('SANS', UpperName) > 0) then
    ResolveFontDefinition := ffSansSerif
  else if (Pos('TIMES', UpperName) > 0) or
          (Pos('ROMAN', UpperName) > 0) or
          (Pos('GEORGIA', UpperName) > 0) or
          (Pos('GARAMOND', UpperName) > 0) then
    ResolveFontDefinition := ffSerif
  else
    ResolveFontDefinition := TaggedFamily;
end;

{ Commits one parsed font-table definition into the bounded font map. }
procedure CommitFontDefinition(const State: TRtfState;
  var FontMap: TRtfFontMap; var FontDefined: TRtfFontFlags);
var
  FontNumber: Integer;
begin
  FontNumber := State.FontDefinitionNumber;
  if (FontNumber >= 0) and (FontNumber < MaxRtfFonts) then
  begin
    FontMap[FontNumber] := ResolveFontDefinition(
      State.FontDefinitionFamily, State.FontDefinitionName);
    FontDefined[FontNumber] := True;
  end;
end;

{ Returns a mapped family or the current default when a number is unknown. }
function MappedFontFamily(FontNumber: LongInt; const FontMap: TRtfFontMap;
  const FontDefined: TRtfFontFlags; DefaultFamily: TFontFamily): TFontFamily;
begin
  if (FontNumber >= 0) and (FontNumber < MaxRtfFonts) and
     FontDefined[FontNumber] then
    MappedFontFamily := FontMap[FontNumber]
  else
    MappedFontFamily := DefaultFamily;
end;

{ Appends one decoded character, wrapping a full 255-byte editor line instead
  of discarding the rest of the RTF paragraph. }
procedure AppendDecodedChar(var Buffer: TTextBuffer; var LineIndex: Word;
  Ch: Char; Family: TFontFamily; var Truncated: Boolean);
var
  Column: Word;
  Line: PEditorLine;
  Styles: PFontStyleLine;
begin
  if LineIndex >= MaxLines then
  begin
    Truncated := True;
    Exit;
  end;

  Line := Buffer.EditLinePtr(LineIndex);
  Styles := Buffer.EditFontPtr(LineIndex);
  Column := Length(Line^);
  if Column >= MaxLineLength then
  begin
    if LineIndex >= MaxLines - 1 then
    begin
      Truncated := True;
      Exit;
    end;
    Inc(LineIndex);
    if Buffer.Count <= LineIndex then
      Buffer.Count := Word(LineIndex + 1);
    Line := Buffer.EditLinePtr(LineIndex);
    Styles := Buffer.EditFontPtr(LineIndex);
    Line^ := '';
    ClearFontStyleLine(Styles^, Family);
    Column := 0;
  end;

  { SetLength only changes the length byte of a fixed short string.  The former
    `Line := Line + Ch` expression copied the entire line for every character. }
  SetLength(Line^, Column + 1);
  Line^[Column + 1] := Ch;
  SetFontFamily(Styles^, Column, Family);
end;

{ Starts a new decoded line while enforcing the fixed line-count limit. }
procedure AppendDecodedLineBreak(var Buffer: TTextBuffer;
  var LineIndex: Word; Family: TFontFamily; var Truncated: Boolean);
begin
  if LineIndex >= MaxLines - 1 then
  begin
    Truncated := True;
    Exit;
  end;
  Inc(LineIndex);
  if Buffer.Count <= LineIndex then
    Buffer.Count := Word(LineIndex + 1);
  Buffer.EditLinePtr(LineIndex)^ := '';
  ClearFontStyleLine(Buffer.EditFontPtr(LineIndex)^, Family);
end;


{ Stores an RTF page break as a dedicated form-feed line.  The UI can show the
  line as a full-width separator or hide it as an empty row without losing the
  page boundary during paging, editing, or RTF round-trip saving. }
procedure AppendDecodedPageBreak(var Buffer: TTextBuffer;
  var LineIndex: Word; Family: TFontFamily; var Truncated: Boolean);
begin
  if Truncated then
    Exit;

  if Length(Buffer.LinePtr(LineIndex)^) > 0 then
    AppendDecodedLineBreak(Buffer, LineIndex, Family, Truncated);
  if Truncated then
    Exit;

  Buffer.EditLinePtr(LineIndex)^ := #12;
  ClearFontStyleLine(Buffer.EditFontPtr(LineIndex)^, Family);
  SetFontFamily(Buffer.EditFontPtr(LineIndex)^, 0, Family);

  AppendDecodedLineBreak(Buffer, LineIndex, Family, Truncated);
end;

{ Appends spaces through the next four-column tab stop. }
procedure AppendDecodedTab(var Buffer: TTextBuffer; var LineIndex: Word;
  Family: TFontFamily; var Truncated: Boolean);
var
  SpaceCount, I: Byte;
begin
  SpaceCount := 4 - (Length(Buffer.LinePtr(LineIndex)^) mod 4);
  for I := 1 to SpaceCount do
    AppendDecodedChar(Buffer, LineIndex, ' ', Family, Truncated);
end;

{ Approximates common ANSI punctuation and Latin letters as ASCII. }
function ApproximateAnsiByte(Value: Byte): Char;
begin
  case Value of
    128: ApproximateAnsiByte := 'E';
    130, 145, 146: ApproximateAnsiByte := '''';
    132, 147, 148: ApproximateAnsiByte := '"';
    133: ApproximateAnsiByte := '.';
    149, 183: ApproximateAnsiByte := '*';
    150, 151: ApproximateAnsiByte := '-';
    160: ApproximateAnsiByte := ' ';
    192..197, 224..229: ApproximateAnsiByte := 'A';
    198, 230: ApproximateAnsiByte := 'A';
    199, 231: ApproximateAnsiByte := 'C';
    200..203, 232..235: ApproximateAnsiByte := 'E';
    204..207, 236..239: ApproximateAnsiByte := 'I';
    208, 240: ApproximateAnsiByte := 'D';
    209, 241: ApproximateAnsiByte := 'N';
    210..214, 216, 242..246, 248: ApproximateAnsiByte := 'O';
    217..220, 249..252: ApproximateAnsiByte := 'U';
    221, 253, 255: ApproximateAnsiByte := 'Y';
    222, 254: ApproximateAnsiByte := 'P';
    223: ApproximateAnsiByte := 's';
    else
      if (Value >= 32) and (Value <= 126) then
        ApproximateAnsiByte := Chr(Value)
      else
        ApproximateAnsiByte := '?';
  end;
end;

{ Approximates one Unicode code point with EDIT98's single-byte character set. }
function ApproximateUnicode(Value: LongInt): Char;
begin
  if Value < 0 then
    Value := Value + LongInt(65536);
  if (Value >= 32) and (Value <= 126) then
    ApproximateUnicode := Chr(Value)
  else
    case Value of
      160: ApproximateUnicode := ' ';
      169: ApproximateUnicode := 'C';
      174: ApproximateUnicode := 'R';
      8211, 8212: ApproximateUnicode := '-';
      8216, 8217: ApproximateUnicode := '''';
      8220, 8221: ApproximateUnicode := '"';
      183, 8226, 8729, 9679, 9642, 9643, 9670, 9675,
      61607, 61623, 61692: ApproximateUnicode := '*';
      8230: ApproximateUnicode := '.';
      else ApproximateUnicode := '?';
    end;
end;

{ Applies captured RTF paper height and line spacing to EDIT98's base plain-text
  print geometry. User-configurable margins are applied later by PrintDoc, so
  imported RTF margin controls do not get counted a second time. Horizontal
  printing remains the standard 80-column fixed-pitch page. }
procedure ApplyRtfPrintGeometry(var Buffer: TTextBuffer);
var
  Spacing, Rows: LongInt;
begin
  Buffer.PrintColumns := DefaultPrintColumns;
  Buffer.PrintRows := DefaultPrintRows;

  if LayoutPaperHeightTwips <= 0 then
    Exit;

  Spacing := LayoutLineSpacingTwips;
  if Spacing <= 0 then
    Spacing := 288; { 12-point text with conventional 1.2 leading. }

  Rows := LayoutPaperHeightTwips div Spacing;
  if Rows < 20 then
    Rows := 20
  else if Rows > 80 then
    Rows := 80;
  Buffer.PrintRows := Byte(Rows);
end;

{ Applies one recognized control word to parser state or document output. }
procedure ProcessControlWord(const ControlWord: String;
  HasParameter: Boolean; Parameter: LongInt; var State: TRtfState;
  var FontMap: TRtfFontMap; var FontDefined: TRtfFontFlags;
  var DefaultFontNumber: LongInt; var DefaultFamily: TFontFamily;
  var Buffer: TTextBuffer; var LineIndex: Word; var Truncated: Boolean;
  var SawRtfHeader: Boolean; var FallbackBytesToSkip: Byte;
  var BinaryBytesToSkip: LongInt);
begin
  if ControlWord = 'rtf' then
    SawRtfHeader := True
  else if ControlWord = 'fonttbl' then
    State.Destination := DestinationFontTable
  else if IsSkippedDestination(ControlWord) then
    State.Destination := DestinationSkipped
  else if ControlWord = 'bin' then
  begin
    if HasParameter and (Parameter > 0) then
      BinaryBytesToSkip := Parameter;
  end
  else if State.Destination = DestinationFontTable then
  begin
    if ControlWord = 'f' then
    begin
      if HasParameter and (Parameter >= -32768) and
         (Parameter <= 32767) then
      begin
        { A new font number begins a new definition even in flat font tables
          that do not wrap every entry in its own group. }
        State.FontDefinitionNumber := Parameter;
        State.FontDefinitionFamily := ffSansSerif;
        State.FontDefinitionName := '';
      end;
    end
    else if ControlWord = 'froman' then
      State.FontDefinitionFamily := ffSerif
    else if ControlWord = 'fswiss' then
      State.FontDefinitionFamily := ffSansSerif
    else if ControlWord = 'fmodern' then
      State.FontDefinitionFamily := ffMonospace
    else if (ControlWord = 'fnil') or (ControlWord = 'fscript') or
            (ControlWord = 'fdecor') or (ControlWord = 'ftech') or
            (ControlWord = 'fbidi') then
      State.FontDefinitionFamily := ffSansSerif;
  end
  else if State.Destination = DestinationDocument then
  begin
    if ControlWord = 'paperh' then
    begin
      if HasParameter and (Parameter >= 1440) and (Parameter <= 100000) then
        LayoutPaperHeightTwips := Parameter;
    end
    else if ControlWord = 'margt' then
    begin
      if HasParameter and (Parameter >= 0) and (Parameter <= 50000) then
        LayoutMarginTopTwips := Parameter;
    end
    else if ControlWord = 'margb' then
    begin
      if HasParameter and (Parameter >= 0) and (Parameter <= 50000) then
        LayoutMarginBottomTwips := Parameter;
    end
    else if ControlWord = 'sl' then
    begin
      { Keep the first useful body line spacing. Later paragraphs may override
        it locally; the first value is a better document-wide print estimate. }
      if HasParameter and (LayoutLineSpacingTwips = 0) then
      begin
        if Parameter < 0 then
          Parameter := -Parameter;
        if (Parameter >= 120) and (Parameter <= 1440) then
          LayoutLineSpacingTwips := Parameter;
      end;
    end
    else if ControlWord = 'deff' then
    begin
      if HasParameter then
      begin
        DefaultFontNumber := Parameter;
        DefaultFamily := MappedFontFamily(DefaultFontNumber, FontMap,
          FontDefined, DefaultFamily);
      end;
    end
    else if ControlWord = 'f' then
    begin
      if HasParameter then
        State.Family := MappedFontFamily(Parameter, FontMap, FontDefined,
          DefaultFamily);
    end
    else if ControlWord = 'plain' then
      State.Family := MappedFontFamily(DefaultFontNumber, FontMap,
        FontDefined, DefaultFamily)
    else if ControlWord = 'uc' then
    begin
      if HasParameter and (Parameter >= 0) and (Parameter <= 8) then
        State.UnicodeSkipCount := Parameter;
    end
    else if ControlWord = 'u' then
    begin
      if HasParameter then
      begin
        AppendDecodedChar(Buffer, LineIndex, ApproximateUnicode(Parameter),
          State.Family, Truncated);
        FallbackBytesToSkip := State.UnicodeSkipCount;
      end;
    end
    else if (ControlWord = 'par') or (ControlWord = 'line') then
      AppendDecodedLineBreak(Buffer, LineIndex, State.Family, Truncated)
    else if ControlWord = 'page' then
      AppendDecodedPageBreak(Buffer, LineIndex, State.Family, Truncated)
    else if (ControlWord = 'pagebb') and
            ((not HasParameter) or (Parameter <> 0)) then
      AppendDecodedPageBreak(Buffer, LineIndex, State.Family, Truncated)
    else if (ControlWord = 'tab') or (ControlWord = 'cell') then
      AppendDecodedTab(Buffer, LineIndex, State.Family, Truncated)
    else if ControlWord = 'row' then
      AppendDecodedLineBreak(Buffer, LineIndex, State.Family, Truncated)
    else if (ControlWord = 'emdash') or (ControlWord = 'endash') then
      AppendDecodedChar(Buffer, LineIndex, '-', State.Family, Truncated)
    else if ControlWord = 'bullet' then
      AppendDecodedChar(Buffer, LineIndex, '*', State.Family, Truncated)
    else if (ControlWord = 'lquote') or (ControlWord = 'rquote') then
      AppendDecodedChar(Buffer, LineIndex, '''', State.Family, Truncated)
    else if (ControlWord = 'ldblquote') or
            (ControlWord = 'rdblquote') then
      AppendDecodedChar(Buffer, LineIndex, '"', State.Family, Truncated);
  end;
end;

{ Quickly verifies the required opening RTF signature before clearing a buffer. }
function LooksLikeRtfFile(const FileName: String; var ErrorCode: Integer): Boolean;
var
  Reader: TRtfReader;
  Ch: Char;
  Signature: String[5];
begin
  LooksLikeRtfFile := False;
  Signature := '';
  if not Reader.Open(FileName, ErrorCode) then
    Exit;
  while (Length(Signature) < 5) and Reader.ReadChar(Ch) do
    if not (Ch in [#9, #10, #13, ' ']) then
      Signature := Signature + LowerAscii(Ch);
  Reader.Close;
  LooksLikeRtfFile := Signature = '{\rtf';
end;

{ Loads RTF text and logical font runs into a document buffer. }
function LoadRtfFile(const FileName: String; var Buffer: TTextBuffer;
  var ErrorText: String): Boolean;
var
  Reader: TRtfReader;
  State: TRtfState;
  Stack: TRtfStateStack;
  FontMap: TRtfFontMap;
  FontDefined: TRtfFontFlags;
  Depth, I: Integer;
  ErrorCode: Integer;
  Ch, EscapedChar, Hex1, Hex2: Char;
  OldDestination: Byte;
  ControlWord: String;
  HasParameter, HexValid1, HexValid2: Boolean;
  Parameter, DefaultFontNumber, BinaryBytesToSkip: LongInt;
  DefaultFamily: TFontFamily;
  LineIndex: Word;
  Truncated, SawRtfHeader: Boolean;
  FallbackBytesToSkip: Byte;
  CodeText, CapacityText: String;
begin
  LoadRtfFile := False;
  ErrorText := '';
  if not LooksLikeRtfFile(FileName, ErrorCode) then
  begin
    if ErrorCode <> 0 then
    begin
      Str(ErrorCode, CodeText);
      ErrorText := 'Unable to open RTF file (DOS error ' + CodeText + ').';
    end
    else
      ErrorText := 'The selected file does not contain an RTF header.';
    Exit;
  end;

  if not Reader.Open(FileName, ErrorCode) then
  begin
    Str(ErrorCode, CodeText);
    ErrorText := 'Unable to open RTF file (DOS error ' + CodeText + ').';
    Exit;
  end;

  Buffer.Init;
  if not Buffer.FlushStorage(ErrorText) then
  begin
    Reader.Close;
    Exit;
  end;
  Buffer.Count := 1;
  Buffer.TypingFont := ffSansSerif;
  for I := 0 to MaxRtfFonts - 1 do
  begin
    FontMap[I] := ffSansSerif;
    FontDefined[I] := False;
  end;

  DefaultFontNumber := 0;
  DefaultFamily := ffSansSerif;
  State.Destination := DestinationDocument;
  State.Family := DefaultFamily;
  State.UnicodeSkipCount := 1;
  State.FontDefinitionNumber := -1;
  State.FontDefinitionFamily := ffSansSerif;
  State.FontDefinitionName := '';
  Depth := 0;
  LineIndex := 0;
  Truncated := False;
  SawRtfHeader := False;
  FallbackBytesToSkip := 0;
  BinaryBytesToSkip := 0;
  LayoutPaperHeightTwips := 0;
  LayoutMarginTopTwips := 0;
  LayoutMarginBottomTwips := 0;
  LayoutLineSpacingTwips := 0;

  while Reader.ReadChar(Ch) do
  begin
    if BinaryBytesToSkip > 0 then
    begin
      Dec(BinaryBytesToSkip);
      Continue;
    end;

    case Ch of
      '{':
        begin
          if Depth >= MaxRtfDepth then
          begin
            ErrorText := 'The RTF nesting depth exceeds EDIT98 capacity.';
            Reader.Close;
            Exit;
          end;
          Stack[Depth] := State;
          Inc(Depth);
        end;
      '}':
        begin
          if Depth > 0 then
          begin
            OldDestination := State.Destination;
            Dec(Depth);
            State := Stack[Depth];
            if (OldDestination = DestinationFontTable) and
               (State.Destination = DestinationDocument) then
              State.Family := DefaultFamily;
          end;
        end;
      '\':
        begin
          if not Reader.ReadChar(EscapedChar) then
            Break;
          if IsAsciiLetter(EscapedChar) then
          begin
            ReadControlWord(Reader, EscapedChar, ControlWord,
              HasParameter, Parameter);
            ProcessControlWord(ControlWord, HasParameter, Parameter, State,
              FontMap, FontDefined, DefaultFontNumber, DefaultFamily,
              Buffer, LineIndex, Truncated, SawRtfHeader,
              FallbackBytesToSkip, BinaryBytesToSkip);
          end
          else
            case EscapedChar of
              '\', '{', '}':
                begin
                  if FallbackBytesToSkip > 0 then
                    Dec(FallbackBytesToSkip)
                  else if State.Destination = DestinationFontTable then
                  begin
                    if Length(State.FontDefinitionName) < 48 then
                      State.FontDefinitionName := State.FontDefinitionName +
                        EscapedChar;
                  end
                  else if State.Destination = DestinationDocument then
                    AppendDecodedChar(Buffer, LineIndex, EscapedChar,
                      State.Family, Truncated);
                end;
              '''':
                begin
                  if Reader.ReadChar(Hex1) and Reader.ReadChar(Hex2) then
                  begin
                    I := Integer(HexValue(Hex1, HexValid1)) * 16 +
                         Integer(HexValue(Hex2, HexValid2));
                    if HexValid1 and HexValid2 then
                    begin
                      if FallbackBytesToSkip > 0 then
                        Dec(FallbackBytesToSkip)
                      else if State.Destination = DestinationDocument then
                        AppendDecodedChar(Buffer, LineIndex,
                          ApproximateAnsiByte(I), State.Family, Truncated);
                    end;
                  end;
                end;
              '*': State.Destination := DestinationSkipped;
              '~', '_', '-':
                begin
                  { RTF Unicode escapes are followed by a configurable number
                    of fallback bytes.  Control symbols count as one fallback
                    byte just like literal and hex-escaped characters. }
                  if FallbackBytesToSkip > 0 then
                    Dec(FallbackBytesToSkip)
                  else if State.Destination = DestinationDocument then
                    case EscapedChar of
                      '~': AppendDecodedChar(Buffer, LineIndex, ' ',
                        State.Family, Truncated);
                      '_': AppendDecodedChar(Buffer, LineIndex, '-',
                        State.Family, Truncated);
                      '-': ; { optional hyphen remains invisible }
                    end;
                end;
            end;
        end;
      ';':
        if State.Destination = DestinationFontTable then
        begin
          CommitFontDefinition(State, FontMap, FontDefined);
          if State.FontDefinitionNumber = DefaultFontNumber then
            DefaultFamily := ResolveFontDefinition(
              State.FontDefinitionFamily, State.FontDefinitionName);
        end
        else if (State.Destination = DestinationDocument) and
                (FallbackBytesToSkip = 0) then
          AppendDecodedChar(Buffer, LineIndex, ';', State.Family, Truncated);
      #9, #10, #13: ; { formatting whitespace outside control words }
      else
        begin
          if FallbackBytesToSkip > 0 then
            Dec(FallbackBytesToSkip)
          else if State.Destination = DestinationFontTable then
          begin
            if Length(State.FontDefinitionName) < 48 then
              State.FontDefinitionName := State.FontDefinitionName + Ch;
          end
          else if State.Destination = DestinationDocument then
            AppendDecodedChar(Buffer, LineIndex, Ch, State.Family, Truncated);
        end;
    end;

    { The page cache streams decoded output to disk.  Only the explicit
      65,535-line logical limit can stop the sequential import early. }
    if Truncated then
      Break;
  end;
  Reader.Close;

  if not SawRtfHeader then
  begin
    ErrorText := 'The selected file does not contain a valid RTF header.';
    Exit;
  end;

  Buffer.Count := Word(LineIndex + 1);
  if Buffer.Count = 0 then
    Buffer.Count := 1;
  if Length(Buffer.LinePtr(LineIndex)^) > 0 then
    Buffer.TypingFont := Buffer.FontAt(LineIndex,
      Length(Buffer.LinePtr(LineIndex)^) - 1)
  else
    Buffer.TypingFont := DefaultFamily;
  ApplyRtfPrintGeometry(Buffer);
  if not Buffer.FlushStorage(ErrorText) then
    Exit;

  Buffer.Dirty := False;
  if Truncated then
  begin
    Str(MaxLines, CapacityText);
    ErrorText := 'RTF exceeds the ' + CapacityText + '-line document capacity.';
  end
  else
    ErrorText := '';
  LoadRtfFile := True;
end;

{ Converts one nibble into an uppercase hexadecimal digit. }
function HexDigit(Value: Byte): Char;
begin
  Value := Value and $0F;
  if Value < 10 then
    HexDigit := Chr(Ord('0') + Value)
  else
    HexDigit := Chr(Ord('A') + Value - 10);
end;

{ Writes one character with RTF escaping and single-byte hex fallback. }
procedure WriteRtfCharacter(var F: Text; Ch: Char);
var
  Code: Byte;
begin
  case Ch of
    '\': Write(F, '\\');
    '{': Write(F, '\{');
    '}': Write(F, '\}');
    #9: Write(F, '\tab ');
    else
      begin
        Code := Ord(Ch);
        if (Code >= 32) and (Code <= 126) then
          Write(F, Ch)
        else
          Write(F, '\''', HexDigit(Code shr 4), HexDigit(Code));
      end;
  end;
end;

{ Maps one logical family to the font number emitted by EDIT98. }
function RtfFontNumber(Family: TFontFamily): Byte;
begin
  case Family of
    ffSerif: RtfFontNumber := 0;
    ffMonospace: RtfFontNumber := 2;
    else RtfFontNumber := 1;
  end;
end;

{ Saves document text and logical font runs as an RTF document. }
function SaveRtfFile(const FileName: String; var Buffer: TTextBuffer;
  var ErrorText: String): Boolean;
var
  F: Text;
  LineIndex, Column: Word;
  Code: Integer;
  CodeText: String;
  Family: TFontFamily;
  CurrentFont, NextFont: Byte;
begin
  SaveRtfFile := False;
  ErrorText := '';
  if not Buffer.FlushStorage(ErrorText) then
    Exit;
  Assign(F, FileName);
  {$I-}
  Rewrite(F);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    Str(Code, CodeText);
    ErrorText := 'Unable to create RTF file (DOS error ' + CodeText + ').';
    Exit;
  end;

  {$I-}
  Write(F, '{\rtf1\ansi\ansicpg437\deff1');
  Write(F, '{\fonttbl');
  Write(F, '{\f0\froman Times New Roman;}');
  Write(F, '{\f1\fswiss Arial;}');
  Write(F, '{\f2\fmodern Courier New;}}');
  Write(F, '\viewkind4\uc1\pard\f1 ');
  CurrentFont := 1;

  for LineIndex := 0 to Buffer.Count - 1 do
  begin
    if (Length(Buffer.LinePtr(LineIndex)^) = 1) and
       (Buffer.LinePtr(LineIndex)^[1] = #12) then
      Write(F, '\page', #13, #10)
    else
    begin
      if Length(Buffer.LinePtr(LineIndex)^) > 0 then
        for Column := 0 to Length(Buffer.LinePtr(LineIndex)^) - 1 do
        begin
          Family := Buffer.FontAt(LineIndex, Column);
          NextFont := RtfFontNumber(Family);
          if NextFont <> CurrentFont then
          begin
            Write(F, '\f', NextFont, ' ');
            CurrentFont := NextFont;
          end;
          WriteRtfCharacter(F, Buffer.LinePtr(LineIndex)^[Column + 1]);
        end;
      if LineIndex + 1 < Buffer.Count then
      begin
        if not ((Length(Buffer.LinePtr(LineIndex + 1)^) = 1) and
                (Buffer.LinePtr(LineIndex + 1)^[1] = #12)) then
          Write(F, '\par', #13, #10);
      end;
    end;
  end;
  Write(F, '}');
  Code := IOResult;
  System.Close(F);
  if Code = 0 then
    Code := IOResult;
  {$I+}

  if Code <> 0 then
  begin
    Str(Code, CodeText);
    ErrorText := 'Unable to write RTF file (DOS error ' + CodeText + ').';
    Exit;
  end;

  Buffer.Dirty := False;
  SaveRtfFile := True;
end;

end.
