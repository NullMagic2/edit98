program RTFTest;

{ DOS-side diagnostic for the streaming RTF decoder and disk-backed page cache.
  It avoids the PC-98 editor UI so import time is separated from rendering. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}
{$M 8192, 32768, 131072}

uses
  EditorBuf, RTFCodec, PC98Fonts, PrintDoc;

type
  PTextBuffer = ^TTextBuffer;

var
  Buffer: PTextBuffer;
  ErrorText, PrintErrorText, FileName: String;
  LineIndex, FirstTailLine: Word;
  PageCount: LongInt;
  PrintAll: Boolean;
  Margins: TPrintMargins;
  Paper: TPrintPaper;
  ContentColumns, ContentRows, LeftColumns, TopRows: Byte;

procedure PrintDocumentLine(Index: Word);
begin
  if (Length(Buffer^.LinePtr(Index)^) = 1) and
     (Buffer^.LinePtr(Index)^[1] = #12) then
    WriteLn(Index + 1, ': [PAGE BREAK]')
  else
    WriteLn(Index + 1, ': ', Buffer^.LinePtr(Index)^);
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn('Usage: RTFTEST file.rtf [/ALL]');
    Halt(2);
  end;

  FileName := ParamStr(1);
  PrintAll := (ParamCount > 1) and
    ((ParamStr(2) = '/ALL') or (ParamStr(2) = '/all'));
  New(Buffer);
  if Buffer = nil then
  begin
    WriteLn('Not enough memory for the document controller.');
    Halt(1);
  end;
  if not Buffer^.AllocateStorage then
  begin
    Dispose(Buffer);
    WriteLn('Unable to allocate the page cache or create a temporary file.');
    Halt(1);
  end;
  Buffer^.Init;
  Margins.Top := DefaultPrintMarginTenthsCm;
  Margins.Bottom := DefaultPrintMarginTenthsCm;
  Margins.Left := DefaultPrintMarginTenthsCm;
  Margins.Right := DefaultPrintMarginTenthsCm;
  Paper.WidthTenthsCm := A4PaperWidthTenthsCm;
  Paper.HeightTenthsCm := A4PaperHeightTenthsCm;
  Paper.UseDocumentGeometry := False;
  WriteLn('Opening: ', FileName);
  if not LoadRtfFile(FileName, Buffer^, ErrorText) then
  begin
    WriteLn('Import failed: ', ErrorText);
    Buffer^.ReleaseStorage;
    Dispose(Buffer);
    Halt(1);
  end;

  WriteLn('Import OK. Lines: ', Buffer^.Count);
  if CountDocumentPages(Buffer^, Paper, Margins, PageCount, PrintErrorText) then
  begin
    if ResolvePrintGeometry(Buffer^, Paper, Margins, ContentColumns, ContentRows,
      LeftColumns, TopRows, PrintErrorText) then
      WriteLn('Printable pages: ', PageCount, ' (', ContentColumns,
        ' content columns x ', ContentRows, ' content rows; A4, 0.5 cm margins)')
    else
      WriteLn('Geometry failed: ', PrintErrorText);
  end
  else
    WriteLn('Page count failed: ', PrintErrorText);
  if ErrorText <> '' then
    WriteLn(ErrorText);

  if PrintAll or (Buffer^.Count <= 10) then
  begin
    LineIndex := 0;
    while LineIndex < Buffer^.Count do
    begin
      PrintDocumentLine(LineIndex);
      Inc(LineIndex);
    end;
  end
  else
  begin
    LineIndex := 0;
    while LineIndex < 5 do
    begin
      PrintDocumentLine(LineIndex);
      Inc(LineIndex);
    end;
    WriteLn('... ', Buffer^.Count - 10, ' lines omitted ...');
    FirstTailLine := Buffer^.Count - 5;
    LineIndex := FirstTailLine;
    while LineIndex < Buffer^.Count do
    begin
      PrintDocumentLine(LineIndex);
      Inc(LineIndex);
    end;
  end;

  Buffer^.ReleaseStorage;
  Dispose(Buffer);
end.
