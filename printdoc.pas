unit PrintDoc;

{ Deterministic line-oriented DOS printer output for EDIT98. Version 0.7.13
  deliberately uses untyped binary File + BlockWrite rather than Pascal Text
  output for PRN.  The i8086 Text runtime's buffered character-device path was
  observed to corrupt the PC-98 display state under some DOS/emulator setups.
  Raw DOS handle writes avoid TextRec buffering and send only the exact bytes
  required by the printer stream. Page ranges use EDIT98's print geometry. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}

interface

uses
  EditorBuf;

const
  { Margins are stored in tenths of a centimetre so the 16-bit DOS build does
    not require floating-point code. 5 means 0.5 cm. }
  DefaultPrintMarginTenthsCm = 5;
  MaximumPrintMarginTenthsCm = 99;

  { Paper dimensions are stored in tenths of a centimetre. A zero-sized paper
    with UseDocumentGeometry=True keeps the imported RTF/plain-text geometry. }
  A4PaperWidthTenthsCm = 210;
  A4PaperHeightTenthsCm = 297;
  LetterPaperWidthTenthsCm = 216;
  LetterPaperHeightTenthsCm = 279;
  LegalPaperWidthTenthsCm = 216;
  LegalPaperHeightTenthsCm = 356;
  TabloidPaperWidthTenthsCm = 279;
  TabloidPaperHeightTenthsCm = 432;
  MinimumPaperDimensionTenthsCm = 50;
  MaximumPaperDimensionTenthsCm = 640;

type
  TPrintMargins = record
    Top, Bottom, Left, Right: Byte;
  end;

  TPrintPaper = record
    WidthTenthsCm, HeightTenthsCm: Word;
    UseDocumentGeometry: Boolean;
  end;

{ Applies portrait/landscape page orientation to a physical paper template.
  Document Geometry is already an abstract imported row/column grid and is not
  rotated by this helper. }
procedure ApplyPrintOrientation(var Paper: TPrintPaper; Landscape: Boolean);

{ Resolves the actual fixed-pitch text area after user margins. The NP21/W
  PC-PR201-to-GDI path used by the Windows 11 target renders the ANK text grid
  at an effective 13.3 CPI horizontally and 6 LPI vertically. Geometry must use
  that same grid or A4 content wraps at about 79 columns and leaves a large false
  right margin. }
function ResolvePrintGeometry(var Buffer: TTextBuffer; const Paper: TPrintPaper;
  const Margins: TPrintMargins; var ContentColumns, ContentRows, LeftColumns,
  TopRows: Byte; var ErrorText: String): Boolean;

{ Counts printable pages after fixed-column wrapping, user margins, and
  automatic row-based pagination. Explicit #12 marker lines force boundaries. }
function CountDocumentPages(var Buffer: TTextBuffer; const Paper: TPrintPaper;
  const Margins: TPrintMargins; var PageCount: LongInt;
  var ErrorText: String): Boolean;

{ Sends an inclusive printable page range to DestinationName. PRN selects the
  default DOS printer. A normal filename may be supplied by test programs.
  Output is wrapped explicitly so counting and printing use identical pages. }
function PrintDocumentPages(var Buffer: TTextBuffer; FirstPage, LastPage: LongInt;
  const Paper: TPrintPaper; const Margins: TPrintMargins;
  const DestinationName: String; var ErrorText: String): Boolean;

implementation

{ Prepares paged storage without forcing a write of every resident page.
  Read-only printing may consume the cache as-is; only enough free space for a
  later dirty-page eviction is required. }
function PreparePagedRead(var Buffer: TTextBuffer;
  var ErrorText: String): Boolean;
begin
  PreparePagedRead := False;
  if Buffer.StorageError and not Buffer.RecoverStorage(ErrorText) then
    Exit;
  if not Buffer.CheckStorageSpace(ErrorText) then
    Exit;
  PreparePagedRead := True;
end;

{ Reports whether one logical line is the internal explicit page-break record. }
function IsPageBreakLine(Line: PEditorLine): Boolean;
begin
  IsPageBreakLine := (Length(Line^) = 1) and (Line^[1] = #12);
end;

{ Uses conservative defaults if an older or damaged buffer has zero geometry. }
function EffectivePrintColumns(var Buffer: TTextBuffer): Byte;
begin
  if Buffer.PrintColumns < 20 then
    EffectivePrintColumns := DefaultPrintColumns
  else
    EffectivePrintColumns := Buffer.PrintColumns;
end;

function EffectivePrintRows(var Buffer: TTextBuffer): Byte;
begin
  if Buffer.PrintRows < 10 then
    EffectivePrintRows := DefaultPrintRows
  else
    EffectivePrintRows := Buffer.PrintRows;
end;

{ PC-PR201/80A text printing uses a fixed print direction; portrait versus
  landscape is obtained by using the sheet in the corresponding orientation.
  EDIT98 models that behavior by swapping the physical paper dimensions before
  resolving the fixed-pitch text grid. Document Geometry already describes an
  abstract imported row/column grid, so it is intentionally left unchanged. }
procedure ApplyPrintOrientation(var Paper: TPrintPaper; Landscape: Boolean);
var
  TemporaryDimension: Word;
begin
  if Landscape and (not Paper.UseDocumentGeometry) then
  begin
    TemporaryDimension := Paper.WidthTenthsCm;
    Paper.WidthTenthsCm := Paper.HeightTenthsCm;
    Paper.HeightTenthsCm := TemporaryDimension;
  end;
end;


{ Converts tenths of a centimetre to fixed-pitch character columns at the
  effective 13.3 CPI ANK grid produced by the NP21/W PC-PR201-to-GDI path.
  Integer rounding keeps the conversion deterministic on an 8086 target. }
function TenthsCmToColumns(Value: Word): Word;
var
  WholeCm, FractionTenths, RemainderPart, Converted: Word;
begin
  { 13.3 CPI gives 133/254 columns per tenth of a centimetre:
      round(Value * 133 / 254)

    Avoid a checked 16-bit intermediate overflow on the i8086 target by
    splitting Value into whole centimetres and the remaining tenth:
      Value = WholeCm * 10 + FractionTenths
      Value*133 = WholeCm*1330 + FractionTenths*133
                = WholeCm*(5*254 + 60) + FractionTenths*133.

    Therefore the rounded result is:
      WholeCm*5 + (WholeCm*60 + FractionTenths*133 + 127) div 254

    Every intermediate remains safely below 65535 for the supported paper
    range, while A4 resolves to 110 base columns instead of the incorrect 83. }
  WholeCm := Value div 10;
  FractionTenths := Value mod 10;
  RemainderPart := WholeCm * 60 + FractionTenths * 133 + 127;
  Converted := WholeCm * 5 + RemainderPart div 254;
  if Converted > 255 then
    Converted := 255;
  TenthsCmToColumns := Converted;
end;

{ Converts tenths of a centimetre to printer rows at 6 LPI. }
function TenthsCmToRows(Value: Word): Word;
var
  WholeCm, FractionTenths, RemainderPart, Converted: Word;
begin
  { Same overflow-safe decomposition for
      (Value * 236 + 500) div 1000.
    Value*236 = WholeCm*2000 + WholeCm*360 + FractionTenths*236. }
  WholeCm := Value div 10;
  FractionTenths := Value mod 10;
  RemainderPart := WholeCm * 360 + FractionTenths * 236 + 500;
  Converted := WholeCm * 2 + RemainderPart div 1000;
  if Converted > 255 then
    Converted := 255;
  TenthsCmToRows := Converted;
end;

function MarginToColumns(Value: Byte): Byte;
begin
  MarginToColumns := Byte(TenthsCmToColumns(Value));
end;

function MarginToRows(Value: Byte): Byte;
begin
  MarginToRows := Byte(TenthsCmToRows(Value));
end;

function ResolvePrintGeometry(var Buffer: TTextBuffer; const Paper: TPrintPaper;
  const Margins: TPrintMargins; var ContentColumns, ContentRows, LeftColumns,
  TopRows: Byte; var ErrorText: String): Boolean;
var
  BaseColumns, BaseRows, RightColumns, BottomRows: Word;
  HorizontalMargins, VerticalMargins: Word;
begin
  ResolvePrintGeometry := False;

  if Paper.UseDocumentGeometry then
  begin
    BaseColumns := EffectivePrintColumns(Buffer);
    BaseRows := EffectivePrintRows(Buffer);
  end
  else
  begin
    if (Paper.WidthTenthsCm < MinimumPaperDimensionTenthsCm) or
       (Paper.WidthTenthsCm > MaximumPaperDimensionTenthsCm) or
       (Paper.HeightTenthsCm < MinimumPaperDimensionTenthsCm) or
       (Paper.HeightTenthsCm > MaximumPaperDimensionTenthsCm) then
    begin
      ErrorText := 'Paper dimensions must be from 5.0 through 64.0 cm.';
      Exit;
    end;
    BaseColumns := TenthsCmToColumns(Paper.WidthTenthsCm);
    BaseRows := TenthsCmToRows(Paper.HeightTenthsCm);
  end;

  LeftColumns := MarginToColumns(Margins.Left);
  RightColumns := MarginToColumns(Margins.Right);
  TopRows := MarginToRows(Margins.Top);
  BottomRows := MarginToRows(Margins.Bottom);
  HorizontalMargins := Word(LeftColumns) + RightColumns;
  VerticalMargins := Word(TopRows) + BottomRows;

  if (BaseColumns < 20) or (HorizontalMargins + 10 >= BaseColumns) then
  begin
    ErrorText := 'Paper width and margins leave too little printable width.';
    Exit;
  end;
  if (BaseRows < 10) or (VerticalMargins + 5 >= BaseRows) then
  begin
    ErrorText := 'Paper height and margins leave too little printable height.';
    Exit;
  end;

  ContentColumns := Byte(BaseColumns - HorizontalMargins);
  ContentRows := Byte(BaseRows - VerticalMargins);
  ErrorText := '';
  ResolvePrintGeometry := True;
end;

{ Returns the number of physical printer rows occupied after fixed-width wrap.
  Empty logical lines still consume one row. }
function WrappedRowCount(Line: PEditorLine; Columns: Byte): Word;
var
  LineLength: Word;
begin
  LineLength := Length(Line^);
  if LineLength = 0 then
    WrappedRowCount := 1
  else
    WrappedRowCount := (LineLength + Columns - 1) div Columns;
end;

{ Converts a DOS I/O result into the compact message style used by EDIT98. }
procedure SetDosPrintError(const Operation: String; Code: Integer;
  var ErrorText: String);
var
  CodeText: String;
begin
  Str(Code, CodeText);
  ErrorText := Operation + ' (DOS error ' + CodeText + ').';
end;

{ Closes an output stream while intentionally discarding any additional error.
  This is used only after an earlier write error has already been preserved. }
procedure CloseAfterPrintError(var OutputFile: File);
begin
  {$I-}
  System.Close(OutputFile);
  IOResult;
  {$I+}
end;

{ Writes one raw byte block and reports the first DOS output error.  BlockWrite
  is used with record size 1, so the DOS character device receives exactly the
  requested bytes and no Pascal TextRec buffering is involved. }
function WritePrinterBytes(var OutputFile: File; var Data; ByteCount: Word;
  var ErrorText: String): Boolean;
var
  Code: Integer;
  BytesWritten: Word;
begin
  WritePrinterBytes := False;
  if ByteCount = 0 then
  begin
    WritePrinterBytes := True;
    Exit;
  end;

  BytesWritten := 0;
  {$I-}
  BlockWrite(OutputFile, Data, ByteCount, BytesWritten);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    SetDosPrintError('Unable to write to printer', Code, ErrorText);
    Exit;
  end;
  if BytesWritten <> ByteCount then
  begin
    ErrorText := 'Unable to write complete printer data.';
    Exit;
  end;
  WritePrinterBytes := True;
end;

{ Establishes the printer state used by the target NP21/W PC-PR201 conversion
  path before any page data is emitted.

  The earlier FS B correction did not affect the problem shown in PDF output:
  FS B changes the two-byte Kanji grid, not the one-byte ANK/ASCII pitch. The
  converted ANK text remained on the effective 13.3-CPI grid, so pagination
  still wrapped A4 at the old 10-CPI width and produced a large blank area on
  the right.

  Geometry is now calculated on the observed 13.3-CPI ANK grid. FS A explicitly
  restores the matching 3/20-inch full-width Kanji pitch so mixed single-byte
  and double-byte text keeps the expected 1:2 cell relationship.

  The sequence is deliberately PC-PR201 compatible:
    ESC c 1     reset printer parameters
    ESC H       high-density pica / ANK text mode
    FS  A       3/20-inch Kanji grid matching the 13.3-CPI ANK grid
    ESC A       1/6-inch line spacing (6 LPI)
    ESC f       forward line-feed direction

  PRINTTEST writes to a normal file, so keeping the setup in the raw output
  stream also makes the selected geometry deterministic and testable. }
function WritePrinterSetup(var OutputFile: File;
  var ErrorText: String): Boolean;
var
  SetupBytes: array[0..10] of Char;
begin
  SetupBytes[0] := #27;
  SetupBytes[1] := 'c';
  SetupBytes[2] := '1';

  SetupBytes[3] := #27;
  SetupBytes[4] := 'H';

  SetupBytes[5] := #28;  { FS }
  SetupBytes[6] := 'A';

  SetupBytes[7] := #27;
  SetupBytes[8] := 'A';

  SetupBytes[9] := #27;
  SetupBytes[10] := 'f';

  WritePrinterSetup := WritePrinterBytes(OutputFile, SetupBytes[0],
    SizeOf(SetupBytes), ErrorText);
end;

{ Writes one printer row as raw bytes followed by DOS CR/LF. }
function WritePrinterLine(var OutputFile: File; const TextValue: String;
  var ErrorText: String): Boolean;
var
  LineBytes: String;
  NewLineBytes: array[0..1] of Char;
begin
  WritePrinterLine := False;
  LineBytes := TextValue;
  if Length(LineBytes) > 0 then
    if not WritePrinterBytes(OutputFile, LineBytes[1], Length(LineBytes),
      ErrorText) then
      Exit;

  NewLineBytes[0] := #13;
  NewLineBytes[1] := #10;
  if not WritePrinterBytes(OutputFile, NewLineBytes[0], 2, ErrorText) then
    Exit;
  WritePrinterLine := True;
end;

{ Emits one raw form-feed byte between or after selected printer pages. }
function WritePrinterFormFeed(var OutputFile: File;
  var ErrorText: String): Boolean;
var
  FormFeedByte: Char;
begin
  FormFeedByte := #12;
  WritePrinterFormFeed := WritePrinterBytes(OutputFile, FormFeedByte, 1,
    ErrorText);
end;

function CountDocumentPages(var Buffer: TTextBuffer; const Paper: TPrintPaper;
  const Margins: TPrintMargins; var PageCount: LongInt;
  var ErrorText: String): Boolean;
var
  LineIndex: Word;
  Line: PEditorLine;
  Columns, RowsPerPage, LeftColumns, TopRows: Byte;
  RowsUsed, WrappedRows, RemainingRows: Word;
begin
  CountDocumentPages := False;
  PageCount := 0;
  if not PreparePagedRead(Buffer, ErrorText) then
    Exit;

  if not ResolvePrintGeometry(Buffer, Paper, Margins, Columns, RowsPerPage,
    LeftColumns, TopRows, ErrorText) then
    Exit;
  PageCount := 1;
  RowsUsed := 0;
  LineIndex := 0;

  while LineIndex < Buffer.Count do
  begin
    Line := Buffer.LinePtr(LineIndex);
    if Buffer.StorageError then
    begin
      if not Buffer.RecoverStorage(ErrorText) then
        Exit;
      Line := Buffer.LinePtr(LineIndex);
      if Buffer.StorageError then
      begin
        ErrorText := 'Unable to read temporary document storage at ' +
          Buffer.StoragePath + '.';
        Exit;
      end;
    end;

    if IsPageBreakLine(Line) then
    begin
      Inc(PageCount);
      RowsUsed := 0;
    end
    else
    begin
      WrappedRows := WrappedRowCount(Line, Columns);
      while WrappedRows > 0 do
      begin
        if RowsUsed >= RowsPerPage then
        begin
          Inc(PageCount);
          RowsUsed := 0;
        end;

        RemainingRows := RowsPerPage - RowsUsed;
        if WrappedRows <= RemainingRows then
        begin
          Inc(RowsUsed, WrappedRows);
          WrappedRows := 0;
        end
        else
        begin
          Dec(WrappedRows, RemainingRows);
          RowsUsed := RowsPerPage;
        end;
      end;
    end;
    Inc(LineIndex);
  end;

  ErrorText := '';
  CountDocumentPages := True;
end;

function PrintDocumentPages(var Buffer: TTextBuffer; FirstPage, LastPage: LongInt;
  const Paper: TPrintPaper; const Margins: TPrintMargins;
  const DestinationName: String; var ErrorText: String): Boolean;
var
  OutputFile: File;
  LineIndex: Word;
  CurrentPage: LongInt;
  Line: PEditorLine;
  Code: Integer;
  Columns, RowsPerPage, LeftColumns, TopRows: Byte;
  RowsUsed, WrappedRows: Word;
  SegmentStart, SegmentLength, LineLength: Word;
  SegmentText, LeftPadding: String;
  StopPrinting, PageStarted: Boolean;
begin
  PrintDocumentPages := False;
  ErrorText := '';

  if (FirstPage < 1) or (LastPage < FirstPage) then
  begin
    ErrorText := 'Invalid print page range.';
    Exit;
  end;
  if DestinationName = '' then
  begin
    ErrorText := 'No printer device was specified.';
    Exit;
  end;
  if not PreparePagedRead(Buffer, ErrorText) then
    Exit;

  if not ResolvePrintGeometry(Buffer, Paper, Margins, Columns, RowsPerPage,
    LeftColumns, TopRows, ErrorText) then
    Exit;
  LeftPadding := '';
  while Length(LeftPadding) < LeftColumns do
    LeftPadding := LeftPadding + ' ';

  Assign(OutputFile, DestinationName);
  {$I-}
  Rewrite(OutputFile, 1);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    SetDosPrintError('Unable to open printer', Code, ErrorText);
    Exit;
  end;

  { The layout engine measures paper and horizontal margins on the same
    effective 13.3-CPI grid produced by NP21/W's PC-PR201-to-GDI path, with
    vertical spacing at 6 LPI. Keep the printer in deterministic high-density
    pica / forward-feed state so the measured grid and emitted stream agree. }
  if not WritePrinterSetup(OutputFile, ErrorText) then
  begin
    CloseAfterPrintError(OutputFile);
    Exit;
  end;

  CurrentPage := 1;
  RowsUsed := 0;
  LineIndex := 0;
  StopPrinting := False;
  PageStarted := False;

  while (LineIndex < Buffer.Count) and (not StopPrinting) do
  begin
    Line := Buffer.LinePtr(LineIndex);
    if Buffer.StorageError then
    begin
      if not Buffer.RecoverStorage(ErrorText) then
      begin
        CloseAfterPrintError(OutputFile);
        Exit;
      end;
      Line := Buffer.LinePtr(LineIndex);
      if Buffer.StorageError then
      begin
        CloseAfterPrintError(OutputFile);
        ErrorText := 'Unable to read temporary document storage at ' +
          Buffer.StoragePath + '.';
        Exit;
      end;
    end;

    if IsPageBreakLine(Line) then
    begin
      { Explicit page breaks override the remaining automatic page space. }
      if (CurrentPage >= FirstPage) and (CurrentPage < LastPage) then
        if not WritePrinterFormFeed(OutputFile, ErrorText) then
        begin
          CloseAfterPrintError(OutputFile);
          Exit;
        end;
      Inc(CurrentPage);
      RowsUsed := 0;
      PageStarted := False;
      if CurrentPage > LastPage then
        StopPrinting := True;
    end
    else
    begin
      LineLength := Length(Line^);
      WrappedRows := WrappedRowCount(Line, Columns);
      SegmentStart := 1;

      while (WrappedRows > 0) and (not StopPrinting) do
      begin
        { Start a new automatic page only when another output row is needed.
          This avoids inventing an empty trailing page when the document ends
          exactly at the bottom margin. }
        if RowsUsed >= RowsPerPage then
        begin
          if (CurrentPage >= FirstPage) and (CurrentPage < LastPage) then
            if not WritePrinterFormFeed(OutputFile, ErrorText) then
            begin
              CloseAfterPrintError(OutputFile);
              Exit;
            end;
          Inc(CurrentPage);
          RowsUsed := 0;
          PageStarted := False;
          if CurrentPage > LastPage then
          begin
            StopPrinting := True;
            Break;
          end;
        end;

        if LineLength = 0 then
          SegmentText := ''
        else
        begin
          SegmentLength := Columns;
          if SegmentStart + SegmentLength - 1 > LineLength then
            SegmentLength := LineLength - SegmentStart + 1;
          SegmentText := Copy(Line^, SegmentStart, SegmentLength);
        end;

        if CurrentPage >= FirstPage then
        begin
          if not PageStarted then
          begin
            while TopRows > 0 do
            begin
              if not WritePrinterLine(OutputFile, '', ErrorText) then
              begin
                CloseAfterPrintError(OutputFile);
                Exit;
              end;
              Dec(TopRows);
            end;
            { Resolve the top margin again for subsequent automatic pages. }
            TopRows := MarginToRows(Margins.Top);
            PageStarted := True;
          end;
          if not WritePrinterLine(OutputFile, LeftPadding + SegmentText,
            ErrorText) then
          begin
            CloseAfterPrintError(OutputFile);
            Exit;
          end;
        end;

        Inc(RowsUsed);
        if LineLength > 0 then
          Inc(SegmentStart, SegmentLength);
        Dec(WrappedRows);
      end;
    end;
    Inc(LineIndex);
  end;

  { Eject the final requested page, including a deliberately blank page. }
  if not WritePrinterFormFeed(OutputFile, ErrorText) then
  begin
    CloseAfterPrintError(OutputFile);
    Exit;
  end;

  {$I-}
  System.Close(OutputFile);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    SetDosPrintError('Unable to close printer', Code, ErrorText);
    Exit;
  end;

  ErrorText := '';
  PrintDocumentPages := True;
end;

end.
