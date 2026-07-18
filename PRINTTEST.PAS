program PrintTest;

{ Exercises explicit page breaks, automatic wrapped pagination, and inclusive
  page-range output without requiring a physical printer. PrintDoc accepts an
  ordinary filename as its destination, so this verifies the same stream that
  EDIT98 sends to PRN. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}
{$S+}
{$M 8192, 32768, 131072}

uses
  EditorBuf, PrintDoc;

const
  PrinterSetupLength = 11;

var
  Buffer: TTextBuffer;
  ErrorText: String;
  PageCount: LongInt;
  OutputFile: File of Char;
  Ch: Char;
  OutputText: String[255];
  FormFeedCount: Byte;
  Code: Integer;
  I: Word;
  Margins: TPrintMargins;
  Paper: TPrintPaper;
  Columns, Rows, LeftColumns, TopRows: Byte;

procedure Fail(const MessageText: String);
begin
  WriteLn('PRINTTEST FAILED: ', MessageText);
  Buffer.ReleaseStorage;
  Halt(1);
end;

begin
  Margins.Top := DefaultPrintMarginTenthsCm;
  Margins.Bottom := DefaultPrintMarginTenthsCm;
  Margins.Left := DefaultPrintMarginTenthsCm;
  Margins.Right := DefaultPrintMarginTenthsCm;
  Paper.WidthTenthsCm := 0;
  Paper.HeightTenthsCm := 0;
  Paper.UseDocumentGeometry := True;

  if not Buffer.AllocateStorage then
  begin
    WriteLn('PRINTTEST FAILED: unable to allocate paged storage.');
    Halt(1);
  end;

  { Explicit form-feed records must still define hard page boundaries. }
  Buffer.Init;
  Buffer.Count := 5;
  Buffer.EditLinePtr(0)^ := 'PAGE1';
  Buffer.EditLinePtr(1)^ := #12;
  Buffer.EditLinePtr(2)^ := 'PAGE2';
  Buffer.EditLinePtr(3)^ := #12;
  Buffer.EditLinePtr(4)^ := 'PAGE3';
  if not CountDocumentPages(Buffer, Paper, Margins, PageCount, ErrorText) then
    Fail(ErrorText);
  if PageCount <> 3 then
    Fail('expected 3 explicit pages.');

  { Twenty-one one-row lines at ten rows per page must produce three automatic
    printer pages even without any explicit page-break record. }
  Buffer.Init;
  Buffer.PrintColumns := 20;
  Buffer.PrintRows := 10;
  Buffer.Count := 21;
  for I := 0 to 20 do
    Buffer.EditLinePtr(I)^ := 'filler';
  Buffer.EditLinePtr(0)^ := 'FIRSTPAGE';
  Buffer.EditLinePtr(10)^ := 'SECONDPAGE';
  Buffer.EditLinePtr(20)^ := 'THIRDPAGE';

  if not CountDocumentPages(Buffer, Paper, Margins, PageCount, ErrorText) then
    Fail(ErrorText);
  if PageCount <> 3 then
    Fail('expected 3 automatically paginated pages.');

  if not PrintDocumentPages(Buffer, 2, 3, Paper, Margins, 'PRINTTEST.OUT', ErrorText) then
    Fail(ErrorText);

  OutputText := '';
  Assign(OutputFile, 'PRINTTEST.OUT');
  {$I-}
  Reset(OutputFile);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
    Fail('unable to reopen PRINTTEST.OUT.');

  while (not EOF(OutputFile)) and (Length(OutputText) < 255) do
  begin
    Read(OutputFile, Ch);
    OutputText := OutputText + Ch;
  end;
  {$I-}
  System.Close(OutputFile);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
    Fail('unable to close PRINTTEST.OUT.');

  if Pos('FIRSTPAGE', OutputText) <> 0 then
    Fail('automatic page 1 leaked into the requested range.');
  if Pos('SECONDPAGE', OutputText) = 0 then
    Fail('automatic page 2 was not printed.');
  if Pos('  SECONDPAGE', OutputText) = 0 then
    Fail('default 0.5 cm left margin was not emitted as two columns.');
  if Length(OutputText) < PrinterSetupLength + 2 then
    Fail('printer setup/header is missing or truncated.');
  if (OutputText[1] <> #27) or (OutputText[2] <> 'c') or
     (OutputText[3] <> '1') or
     (OutputText[4] <> #27) or (OutputText[5] <> 'H') or
     (OutputText[6] <> #28) or (OutputText[7] <> 'A') or
     (OutputText[8] <> #27) or (OutputText[9] <> 'A') or
     (OutputText[10] <> #27) or (OutputText[11] <> 'f') then
    Fail('PC-PR201 13.3 CPI / 6 LPI setup sequence is incorrect.');
  if (OutputText[PrinterSetupLength + 1] <> #13) or
     (OutputText[PrinterSetupLength + 2] <> #10) then
    Fail('default 0.5 cm top margin was not emitted after printer setup.');
  if Pos('THIRDPAGE', OutputText) = 0 then
    Fail('automatic page 3 was not printed.');
  if Pos('SECONDPAGE', OutputText) >= Pos('THIRDPAGE', OutputText) then
    Fail('printed page order is incorrect.');

  FormFeedCount := 0;
  for Code := 1 to Length(OutputText) do
    if OutputText[Code] = #12 then
      Inc(FormFeedCount);
  if FormFeedCount <> 2 then
    Fail('expected one automatic separator and one final page eject.');

  { Built-in paper templates must resolve to different fixed-pitch geometries. }
  Paper.UseDocumentGeometry := False;
  Paper.WidthTenthsCm := A4PaperWidthTenthsCm;
  Paper.HeightTenthsCm := A4PaperHeightTenthsCm;
  if not ResolvePrintGeometry(Buffer, Paper, Margins, Columns, Rows,
    LeftColumns, TopRows, ErrorText) then
    Fail(ErrorText);
  if (Columns <> 104) or (Rows <> 68) then
    Fail('A4 template geometry is incorrect or overflowed.');

  { Landscape swaps the physical A4 axes before the same margins are applied. }
  Paper.WidthTenthsCm := A4PaperWidthTenthsCm;
  Paper.HeightTenthsCm := A4PaperHeightTenthsCm;
  ApplyPrintOrientation(Paper, True);
  if not ResolvePrintGeometry(Buffer, Paper, Margins, Columns, Rows,
    LeftColumns, TopRows, ErrorText) then
    Fail(ErrorText);
  if (Columns <> 150) or (Rows <> 48) then
    Fail('A4 landscape orientation geometry is incorrect.');

  Paper.WidthTenthsCm := LetterPaperWidthTenthsCm;
  Paper.HeightTenthsCm := LetterPaperHeightTenthsCm;
  if not ResolvePrintGeometry(Buffer, Paper, Margins, Columns, Rows,
    LeftColumns, TopRows, ErrorText) then
    Fail(ErrorText);
  if (Columns <> 107) or (Rows <> 64) then
    Fail('Letter template geometry is incorrect or overflowed.');

  Paper.WidthTenthsCm := LegalPaperWidthTenthsCm;
  Paper.HeightTenthsCm := LegalPaperHeightTenthsCm;
  if not ResolvePrintGeometry(Buffer, Paper, Margins, Columns, Rows,
    LeftColumns, TopRows, ErrorText) then
    Fail(ErrorText);
  if (Columns <> 107) or (Rows <> 82) then
    Fail('Legal template geometry is incorrect or overflowed.');

  Paper.WidthTenthsCm := TabloidPaperWidthTenthsCm;
  Paper.HeightTenthsCm := TabloidPaperHeightTenthsCm;
  if not ResolvePrintGeometry(Buffer, Paper, Margins, Columns, Rows,
    LeftColumns, TopRows, ErrorText) then
    Fail(ErrorText);
  if (Columns <> 140) or (Rows <> 100) then
    Fail('Tabloid template geometry is incorrect or overflowed.');

  Paper.WidthTenthsCm := 180;
  Paper.HeightTenthsCm := 250;
  if not ResolvePrintGeometry(Buffer, Paper, Margins, Columns, Rows,
    LeftColumns, TopRows, ErrorText) then
    Fail(ErrorText);
  if (Columns <> 88) or (Rows <> 57) then
    Fail('custom 18.0 x 25.0 cm template geometry is incorrect.');

  {$I-}
  Erase(OutputFile);
  IOResult;
  {$I+}
  Buffer.ReleaseStorage;
  WriteLn('Printer automatic page-range check OK.');
end.
