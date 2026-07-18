program StorageTest;

{ Minimal compiler/runtime check for EDIT98's disk-backed paged document
  storage. It is intentionally independent of the PC-98 screen and RTF UI. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}
{$M 8192, 32768, 131072}

uses
  EditorBuf, PC98Fonts;

type
  PTextBuffer = ^TTextBuffer;

const
  TestLineCount = 512;
  PageBreakTestIndex = 160;

type
  TTestIndexArray = array[0..9] of Word;
  TTestTextArray = array[0..9] of String[32];

const
  TestIndices: TTestIndexArray =
    (0, 31, 32, 63, 64, 95, 96, 127, 128, 511);
  TestTexts: TTestTextArray =
    ('line zero', 'page zero end', 'page one start', 'page one end',
     'page two start', 'page two end', 'page three start', 'page three end',
     'page four start', 'last test line');

var
  Buffer: PTextBuffer;
  I: Word;
  ErrorText: String;

procedure Fail(const MessageText: String);
begin
  if Buffer <> nil then
  begin
    Buffer^.ReleaseStorage;
    Dispose(Buffer);
    Buffer := nil;
  end;
  WriteLn('Storage check failed: ', MessageText);
  Halt(1);
end;

begin
  Buffer := nil;
  WriteLn('Document page bytes: ', SizeOf(TDocumentPage));
  WriteLn('Document controller bytes: ', SizeOf(TTextBuffer));
  WriteLn('Resident pages: ', DocumentPageCacheCount);
  WriteLn('Lines per page: ', DocumentLinesPerPage);
  WriteLn('Logical line limit: ', MaxLines);

  New(Buffer);
  if Buffer = nil then
    Fail('document controller allocation.');
  if not Buffer^.AllocateStorage then
    Fail('page cache or temporary file allocation.');

  Buffer^.Init;
  Buffer^.Count := TestLineCount;
  I := 0;
  while I <= High(TestIndices) do
  begin
    Buffer^.EditLinePtr(TestIndices[I])^ := TestTexts[I];
    Buffer^.SetLineFont(TestIndices[I], TFontFamily(I mod FontFamilyCount));
    Inc(I);
  end;

  { A page break is a durable form-feed record and must survive eviction. }
  Buffer^.EditLinePtr(PageBreakTestIndex)^ := #12;
  Buffer^.SetLineFont(PageBreakTestIndex, ffSansSerif);

  if not Buffer^.FlushStorage(ErrorText) then
    Fail(ErrorText);

  { Read in reverse page order so every original page has to be reloaded from
    the temporary file after the three-slot cache has evicted it. }
  I := High(TestIndices);
  repeat
    if Buffer^.LinePtr(TestIndices[I])^ <> TestTexts[I] then
      Fail('text mismatch after page eviction.');
    if Buffer^.FontAt(TestIndices[I], 0) <>
       TFontFamily(I mod FontFamilyCount) then
      Fail('font mismatch after page eviction.');
    if I = 0 then
      Break;
    Dec(I);
  until False;

  if (Length(Buffer^.LinePtr(PageBreakTestIndex)^) <> 1) or
     (Buffer^.LinePtr(PageBreakTestIndex)^[1] <> #12) then
    Fail('page-break record mismatch after page eviction.');

  Buffer^.ReleaseStorage;
  Dispose(Buffer);
  Buffer := nil;
  WriteLn('Paged storage check OK.');
end.
