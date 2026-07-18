unit EditorBuf;

{ Document-model module.  It stores fixed-size text, packed logical-font data,
  and clipboard buffers; performs validated and atomic editing operations; and
  loads or saves plain DOS text without depending on the user interface. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}

interface

uses
  PC98Fonts;

const
  { The document is stored in fixed 32-line pages.  Only three pages are kept
    in far memory; all other pages live in an EDIT98 temporary backing file.
    This keeps the resident document footprint bounded while allowing documents
    up to 65,535 lines. }
  DocumentLinesPerPage = 32;
  DocumentPageCacheCount = 3;
  MaxLines = 65535;
  InvalidDocumentPage = $FFFF;
  MaxClipboardLines = 96;
  MaxLineLength = 255;
  MaxClipboardFontRuns = 256;

  { Plain-text printer geometry. RTF import may reduce the row count from
    document page-height and line-spacing metadata, but output stays in a
    deterministic 80-column text layout so page ranges can be counted before
    a job is sent to PRN. }
  DefaultPrintColumns = 80;
  DefaultPrintRows = 60;

type
  TEditorLine = String[MaxLineLength];
  PEditorLine = ^TEditorLine;
  PFontStyleLine = ^TFontStyleLine;
  TDocumentPageLines = array[0..DocumentLinesPerPage - 1] of TEditorLine;
  TDocumentPageFonts = array[0..DocumentLinesPerPage - 1] of TFontStyleLine;
  TDocumentPage = record
    Lines: TDocumentPageLines;
    Fonts: TDocumentPageFonts;
  end;
  PDocumentPage = ^TDocumentPage;
  TDocumentPagePointerArray = array[0..DocumentPageCacheCount - 1] of
    PDocumentPage;
  TDocumentPageNumberArray = array[0..DocumentPageCacheCount - 1] of Word;
  TDocumentPageDirtyArray = array[0..DocumentPageCacheCount - 1] of Boolean;
  TDocumentPageAgeArray = array[0..DocumentPageCacheCount - 1] of Word;
  TBackingFileName = String[127];

  TClipboardLineArray = array[0..MaxClipboardLines - 1] of TEditorLine;
  TClipboardFontRun = packed record
    LineIndex, StartColumn, RunLength: Byte;
    Family: TFontFamily;
  end;
  TClipboardFontRunArray = array[0..MaxClipboardFontRuns - 1] of
    TClipboardFontRun;

  { The clipboard mirrors the fixed text shape and records formatting as a
    bounded run list instead of a second full style array.  This preserves
    ordinary mixed-family copies while keeping the 16-bit data segment small. }
  TTextClipboard = object
    Lines: TClipboardLineArray;
    FontRuns: TClipboardFontRunArray;
    FontRunCount: Word;
    FallbackFont: TFontFamily;
    FontsPreserved: Boolean;
    Count: Word;
    { Empties the clipboard and clears its fixed storage. }
    procedure Clear;
  end;

  { The public editor API still exposes line pointers, but those pointers refer
    to one of three cache pages.  A pointer is valid until enough accesses to
    other pages evict its page.  All EDIT98 operations consume it immediately. }
  TTextBuffer = object
    CachePages: TDocumentPagePointerArray;
    CachePageNumbers: TDocumentPageNumberArray;
    CacheDirty: TDocumentPageDirtyArray;
    CacheAge: TDocumentPageAgeArray;
    CacheClock: Word;
    LastPageNumber: Word;
    LastPageSlot: Byte;
    BackingFile: File;
    BackingOpen: Boolean;
    BackingName: TBackingFileName;
    BackingPageCount: Word;
    StorageError: Boolean;
    StorageErrorCode: Integer;
    Count: Word;
    Dirty: Boolean;
    TypingFont: TFontFamily;
    PrintColumns: Byte;
    PrintRows: Byte;
    { Allocates the three far-memory cache pages and creates a temporary file. }
    function AllocateStorage: Boolean;
    { Releases the cache and removes the temporary backing file. }
    procedure ReleaseStorage;
    { Returns read access to a checked text line. }
    function LinePtr(Index: Word): PEditorLine;
    { Returns read access to a checked packed-font line. }
    function FontPtr(Index: Word): PFontStyleLine;
    { Returns writable access and marks the containing page dirty. }
    function EditLinePtr(Index: Word): PEditorLine;
    { Returns writable font access and marks the containing page dirty. }
    function EditFontPtr(Index: Word): PFontStyleLine;
    { Explicitly marks one cached line page dirty after direct UI mutation. }
    procedure MarkLineDirty(Index: Word);
    { Writes every dirty cache page and reports temporary-file errors. }
    function FlushStorage(var ErrorText: String): Boolean;
    { Checks whether pending dirty pages can extend the backing file safely. }
    function CheckStorageSpace(var ErrorText: String): Boolean;
    { Clears a retained error and retries, relocating the page file if needed. }
    function RecoverStorage(var ErrorText: String): Boolean;
    { Returns the current temporary page-file path for diagnostics. }
    function StoragePath: String;
    { Initializes a new one-line, clean document buffer. }
    procedure Init;
    { Returns the logical font assigned to one document character. }
    function FontAt(LineIndex, Column: Word): TFontFamily;
    { Returns the font that newly typed text should inherit at a caret position. }
    function InsertionFontAt(LineIndex, Column: Word): TFontFamily;
    { Assigns one logical font without changing the character itself. }
    procedure SetFontAt(LineIndex, Column: Word; Family: TFontFamily);
    { Assigns one logical font to an end-exclusive document range. }
    procedure SetFontRange(StartLine, StartColumn, EndLine, EndColumn: Word;
      Family: TFontFamily);
    { Reports whether every character in an end-exclusive range has one font. }
    function FontRangeIsUniform(StartLine, StartColumn, EndLine, EndColumn: Word;
      var Family: TFontFamily): Boolean;
    { Assigns one logical font to every existing character on a line. }
    procedure SetLineFont(LineIndex: Word; Family: TFontFamily);
    { Loads a DOS text file through the page cache. }
    function LoadFromFile(const FileName: String; var ErrorText: String): Boolean;
    { Writes the buffer as DOS text and clears the dirty flag on success. }
    function SaveToFile(const FileName: String; var ErrorText: String): Boolean;
    { Inserts a character into a line when capacity permits. }
    function InsertChar(LineIndex, Column: Word; Ch: Char): Boolean;
    { Overwrites an existing character or appends at end of line. }
    function OverwriteChar(LineIndex, Column: Word; Ch: Char): Boolean;
    { Deletes at a position or joins with the next line at end-of-line. }
    procedure DeleteAt(LineIndex, Column: Word);
    { Deletes before a position or joins with the previous line. }
    procedure BackspaceAt(var LineIndex, Column: Word);
    { Splits one line at the caret when document capacity permits. }
    procedure SplitLine(var LineIndex, Column: Word);
    { Copies an end-exclusive range into the fixed clipboard. }
    function CopyRange(StartLine, StartColumn, EndLine, EndColumn: Word;
      var Clipboard: TTextClipboard; var ErrorText: String): Boolean;
    { Deletes an end-exclusive range and closes any removed lines. }
    function DeleteRange(StartLine, StartColumn, EndLine, EndColumn: Word;
      var ErrorText: String): Boolean;
    { Atomically replaces a range with fixed clipboard contents. }
    function ReplaceRangeWithClipboard(StartLine, StartColumn, EndLine,
      EndColumn: Word; var LineIndex, Column: Word;
      const Clipboard: TTextClipboard; var ErrorText: String): Boolean;
    { Replaces one in-line match and returns the new caret column. }
    function ReplaceTextAt(LineIndex, Column, MatchLength: Word;
      const Replacement: String; var NewColumn: Word;
      var ErrorText: String): Boolean;
  end;

implementation

uses
  Dos;

var
  { Accessors return this harmless line if temporary storage has already failed.
    That prevents a failed eviction from making callers overwrite an unrelated
    resident page while the original DOS error is retained for reporting. }
  StorageFallbackLine: TEditorLine;
  StorageFallbackFonts: TFontStyleLine;

{ Clears the deliberately smaller far-heap clipboard text array. }
procedure ClearClipboardLineArray(var LineArray: TClipboardLineArray);
var
  I: Word;
begin
  for I := 0 to MaxClipboardLines - 1 do
    LineArray[I] := '';
end;

{ Converts one nibble into an uppercase hexadecimal digit. }
function TempHexDigit(Value: Byte): Char;
begin
  Value := Value and $0F;
  if Value < 10 then
    TempHexDigit := Chr(Ord('0') + Value)
  else
    TempHexDigit := Chr(Ord('A') + Value - 10);
end;

{ Builds one DOS 8.3 temporary basename from a changing 16-bit value. }
function TempBaseName(Value: Word): String;
begin
  TempBaseName := 'E98P' +
    TempHexDigit(Byte(Value shr 12)) +
    TempHexDigit(Byte(Value shr 8)) +
    TempHexDigit(Byte(Value shr 4)) +
    TempHexDigit(Byte(Value)) + '.$$$';
end;

{ Joins a directory from the DOS environment to one 8.3 basename. }
function TempPath(const DirectoryName, BaseName: String): String;
var
  ResultPath: String;
begin
  ResultPath := DirectoryName;
  if ResultPath <> '' then
  begin
    if (ResultPath[Length(ResultPath)] <> '\') and
       (ResultPath[Length(ResultPath)] <> '/') then
      ResultPath := ResultPath + '\';
  end;
  TempPath := ResultPath + BaseName;
end;

{ Reports whether an exact DOS path already exists. }
function ExistingDosPath(const FileName: String): Boolean;
var
  SearchRecord: SearchRec;
begin
  FindFirst(FileName, AnyFile, SearchRecord);
  ExistingDosPath := DosError = 0;
end;

{ Clears all text and formatting in one resident page. }
procedure ClearDocumentPage(var Page: TDocumentPage;
  Family: TFontFamily);
var
  LineIndex: Word;
begin
  for LineIndex := 0 to DocumentLinesPerPage - 1 do
  begin
    Page.Lines[LineIndex] := '';
    ClearFontStyleLine(Page.Fonts[LineIndex], Family);
  end;
end;

{ Stores the first paging error so later operations do not hide its cause. }
procedure SetStorageError(var Buffer: TTextBuffer; ErrorCode: Integer);
begin
  if not Buffer.StorageError then
  begin
    Buffer.StorageError := True;
    Buffer.StorageErrorCode := ErrorCode;
    StorageFallbackLine := '';
    ClearFontStyleLine(StorageFallbackFonts, Buffer.TypingFont);
  end;
end;

{ Converts the retained paging error into a user-facing message. }
function StorageErrorMessage(const Buffer: TTextBuffer): String;
var
  CodeText: String;
begin
  Str(Buffer.StorageErrorCode, CodeText);
  StorageErrorMessage := 'Temporary document storage failed at ' +
    Buffer.BackingName + ' (DOS error ' + CodeText + ').';
end;

{ Resets cache metadata without writing pages from the previous document. }
procedure InvalidatePageCache(var Buffer: TTextBuffer);
var
  Slot: Byte;
begin
  for Slot := 0 to DocumentPageCacheCount - 1 do
  begin
    Buffer.CachePageNumbers[Slot] := InvalidDocumentPage;
    Buffer.CacheDirty[Slot] := False;
    Buffer.CacheAge[Slot] := 0;
  end;
  Buffer.CacheClock := 0;
  Buffer.LastPageNumber := InvalidDocumentPage;
  Buffer.LastPageSlot := 0;
end;

{ Attempts to create and reopen one temporary paging file in a directory. }
function TryCreateBackingStore(var Buffer: TTextBuffer;
  const DirectoryName: String; Seed: Word): Boolean;
var
  Attempt, CandidateValue: Word;
  Candidate: String;
  Code: Integer;
  OldFileMode: Integer;
begin
  TryCreateBackingStore := False;
  Attempt := 0;
  while Attempt < 256 do
  begin
    CandidateValue := Seed xor Attempt;
    Candidate := TempPath(DirectoryName, TempBaseName(CandidateValue));
    if (Length(Candidate) <= 127) and not ExistingDosPath(Candidate) then
    begin
      Assign(Buffer.BackingFile, Candidate);
      {$I-}
      Rewrite(Buffer.BackingFile, 1);
      Code := IOResult;
      {$I+}
      if Code = 0 then
      begin
        {$I-}
        System.Close(Buffer.BackingFile);
        Code := IOResult;
        {$I+}
        if Code = 0 then
        begin
          OldFileMode := FileMode;
          FileMode := 2;
          {$I-}
          Reset(Buffer.BackingFile, 1);
          Code := IOResult;
          {$I+}
          FileMode := OldFileMode;
          if Code = 0 then
          begin
            Buffer.BackingName := Candidate;
            Buffer.BackingOpen := True;
            Buffer.BackingPageCount := 0;
            TryCreateBackingStore := True;
            Exit;
          end;
        end;
        {$I-}
        Erase(Buffer.BackingFile);
        IOResult;
        {$I+}
      end;
    end;
    Inc(Attempt);
  end;
end;

{ Discards the previous logical document and truncates its backing file. }
function ResetBackingStore(var Buffer: TTextBuffer): Boolean;
var
  Code: Integer;
  OldFileMode: Integer;
begin
  ResetBackingStore := False;
  InvalidatePageCache(Buffer);
  Buffer.BackingPageCount := 0;
  if not Buffer.BackingOpen then
  begin
    SetStorageError(Buffer, 6);
    Exit;
  end;

  {$I-}
  System.Close(Buffer.BackingFile);
  Code := IOResult;
  {$I+}
  Buffer.BackingOpen := False;
  if Code <> 0 then
  begin
    SetStorageError(Buffer, Code);
    Exit;
  end;

  Assign(Buffer.BackingFile, Buffer.BackingName);
  {$I-}
  Rewrite(Buffer.BackingFile, 1);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    SetStorageError(Buffer, Code);
    Exit;
  end;
  {$I-}
  System.Close(Buffer.BackingFile);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    SetStorageError(Buffer, Code);
    Exit;
  end;

  OldFileMode := FileMode;
  FileMode := 2;
  {$I-}
  Reset(Buffer.BackingFile, 1);
  Code := IOResult;
  {$I+}
  FileMode := OldFileMode;
  if Code <> 0 then
  begin
    SetStorageError(Buffer, Code);
    Exit;
  end;

  Buffer.BackingOpen := True;
  ResetBackingStore := True;
end;


{ Compares DOS paths without depending on locale-specific routines. }
function SameDosPath(const LeftPath, RightPath: String): Boolean;
var
  I: Word;
begin
  SameDosPath := False;
  if Length(LeftPath) <> Length(RightPath) then
    Exit;
  for I := 1 to Length(LeftPath) do
    if UpCase(LeftPath[I]) <> UpCase(RightPath[I]) then
      Exit;
  SameDosPath := True;
end;

{ Returns the DOS drive number expected by DiskFree: 0=current, 1=A, etc. }
function PathDriveNumber(const FileName: String): Byte;
var
  DriveLetter: Char;
begin
  PathDriveNumber := 0;
  if (Length(FileName) >= 2) and (FileName[2] = ':') then
  begin
    DriveLetter := UpCase(FileName[1]);
    if (DriveLetter >= 'A') and (DriveLetter <= 'Z') then
      PathDriveNumber := Ord(DriveLetter) - Ord('A') + 1;
  end;
end;

{ Deletes only page files dated before today.  Same-day files are left alone so
  another running EDIT98 instance can never lose its active backing store. }
procedure CleanupOldPageFiles(const DirectoryName: String);
var
  SearchRecord: SearchRec;
  Stamp: DateTime;
  CurrentYear, CurrentMonth, CurrentDay, DayOfWeek: Word;
  Candidate: String;
  F: File;
begin
  GetDate(CurrentYear, CurrentMonth, CurrentDay, DayOfWeek);
  FindFirst(TempPath(DirectoryName, 'E98P????.$$$'), AnyFile, SearchRecord);
  while DosError = 0 do
  begin
    UnpackTime(SearchRecord.Time, Stamp);
    if (Stamp.Year < CurrentYear) or
       ((Stamp.Year = CurrentYear) and (Stamp.Month < CurrentMonth)) or
       ((Stamp.Year = CurrentYear) and (Stamp.Month = CurrentMonth) and
        (Stamp.Day < CurrentDay)) then
    begin
      Candidate := TempPath(DirectoryName, SearchRecord.Name);
      Assign(F, Candidate);
      {$I-}
      Erase(F);
      IOResult;
      {$I+}
    end;
    FindNext(SearchRecord);
  end;
end;

{ Performs conservative startup cleanup in every configured temporary folder. }
procedure CleanupAbandonedBackingStores;
var
  DirectoryName: String;
begin
  DirectoryName := GetEnv('EDIT98TMP');
  if DirectoryName <> '' then
    CleanupOldPageFiles(DirectoryName);
  DirectoryName := GetEnv('TEMP');
  if DirectoryName <> '' then
    CleanupOldPageFiles(DirectoryName);
  DirectoryName := GetEnv('TMP');
  if DirectoryName <> '' then
    CleanupOldPageFiles(DirectoryName);
  CleanupOldPageFiles('');
end;

{ Creates the page file using EDIT98TMP, TEMP, TMP, then the current directory. }
function CreateBackingStore(var Buffer: TTextBuffer): Boolean;
var
  HourValue, MinuteValue, SecondValue, HundredthValue: Word;
  Seed: Word;
  DirectoryName: String;
begin
  CleanupAbandonedBackingStores;
  GetTime(HourValue, MinuteValue, SecondValue, HundredthValue);
  Seed := Word((HourValue shl 11) xor (MinuteValue shl 5) xor
    (SecondValue shl 1) xor HundredthValue);

  DirectoryName := GetEnv('EDIT98TMP');
  if (DirectoryName <> '') and
     TryCreateBackingStore(Buffer, DirectoryName, Seed) then
  begin
    CreateBackingStore := True;
    Exit;
  end;

  DirectoryName := GetEnv('TEMP');
  if (DirectoryName <> '') and
     TryCreateBackingStore(Buffer, DirectoryName, Seed xor $0100) then
  begin
    CreateBackingStore := True;
    Exit;
  end;

  DirectoryName := GetEnv('TMP');
  if (DirectoryName <> '') and
     TryCreateBackingStore(Buffer, DirectoryName, Seed xor $0200) then
  begin
    CreateBackingStore := True;
    Exit;
  end;

  CreateBackingStore := TryCreateBackingStore(Buffer, '', Seed xor $0300);
end;

{ Writes one dirty resident page to its fixed position in the backing file. }
function FlushCacheSlot(var Buffer: TTextBuffer; Slot: Byte): Boolean;
var
  BytesWritten: Word;
  Code: Integer;
  FileOffset: LongInt;
  PageNumber: Word;
begin
  FlushCacheSlot := False;
  if not Buffer.CacheDirty[Slot] then
  begin
    FlushCacheSlot := True;
    Exit;
  end;
  if not Buffer.BackingOpen then
  begin
    SetStorageError(Buffer, 6);
    Exit;
  end;

  PageNumber := Buffer.CachePageNumbers[Slot];
  if PageNumber = InvalidDocumentPage then
  begin
    Buffer.CacheDirty[Slot] := False;
    FlushCacheSlot := True;
    Exit;
  end;

  FileOffset := LongInt(PageNumber) * LongInt(SizeOf(TDocumentPage));
  BytesWritten := 0;
  {$I-}
  Seek(Buffer.BackingFile, FileOffset);
  Code := IOResult;
  if Code = 0 then
  begin
    BlockWrite(Buffer.BackingFile, Buffer.CachePages[Slot]^,
      SizeOf(TDocumentPage), BytesWritten);
    Code := IOResult;
  end;
  {$I+}
  if (Code <> 0) or (BytesWritten <> SizeOf(TDocumentPage)) then
  begin
    if Code = 0 then
      Code := 112;
    SetStorageError(Buffer, Code);
    Exit;
  end;

  Buffer.CacheDirty[Slot] := False;
  if PageNumber >= Buffer.BackingPageCount then
    Buffer.BackingPageCount := PageNumber + 1;
  FlushCacheSlot := True;
end;

{ Loads one fixed page or creates a blank page beyond the written file. }
function LoadCacheSlot(var Buffer: TTextBuffer; Slot: Byte;
  PageNumber: Word): Boolean;
var
  BytesRead: Word;
  Code: Integer;
  FileOffset: LongInt;
begin
  LoadCacheSlot := False;
  if PageNumber < Buffer.BackingPageCount then
  begin
    FileOffset := LongInt(PageNumber) * LongInt(SizeOf(TDocumentPage));
    BytesRead := 0;
    {$I-}
    Seek(Buffer.BackingFile, FileOffset);
    Code := IOResult;
    if Code = 0 then
    begin
      BlockRead(Buffer.BackingFile, Buffer.CachePages[Slot]^,
        SizeOf(TDocumentPage), BytesRead);
      Code := IOResult;
    end;
    {$I+}
    if (Code <> 0) or (BytesRead <> SizeOf(TDocumentPage)) then
    begin
      if Code = 0 then
        Code := 5;
      SetStorageError(Buffer, Code);
      ClearDocumentPage(Buffer.CachePages[Slot]^, Buffer.TypingFont);
      Exit;
    end;
  end
  else
    ClearDocumentPage(Buffer.CachePages[Slot]^, Buffer.TypingFont);

  Buffer.CachePageNumbers[Slot] := PageNumber;
  Buffer.CacheDirty[Slot] := False;
  LoadCacheSlot := True;
end;

{ Normalizes cache ages before the 16-bit access counter wraps. }
procedure NormalizeCacheAges(var Buffer: TTextBuffer);
var
  Slot: Byte;
begin
  for Slot := 0 to DocumentPageCacheCount - 1 do
    Buffer.CacheAge[Slot] := Slot + 1;
  Buffer.CacheClock := DocumentPageCacheCount + 1;
end;

{ Ensures one document page is resident and returns its cache slot. }
function EnsureDocumentPage(var Buffer: TTextBuffer;
  PageNumber: Word): Integer;
var
  Slot, VictimSlot: Byte;
  LowestAge: Word;
begin
  if (Buffer.LastPageNumber = PageNumber) and
     (Buffer.CachePageNumbers[Buffer.LastPageSlot] = PageNumber) then
  begin
    EnsureDocumentPage := Buffer.LastPageSlot;
    Exit;
  end;

  for Slot := 0 to DocumentPageCacheCount - 1 do
    if Buffer.CachePageNumbers[Slot] = PageNumber then
    begin
      if Buffer.CacheClock = $FFFF then
        NormalizeCacheAges(Buffer)
      else
        Inc(Buffer.CacheClock);
      Buffer.CacheAge[Slot] := Buffer.CacheClock;
      Buffer.LastPageNumber := PageNumber;
      Buffer.LastPageSlot := Slot;
      EnsureDocumentPage := Slot;
      Exit;
    end;

  VictimSlot := 0;
  LowestAge := $FFFF;
  for Slot := 0 to DocumentPageCacheCount - 1 do
    if Buffer.CachePageNumbers[Slot] = InvalidDocumentPage then
    begin
      VictimSlot := Slot;
      LowestAge := 0;
      Break;
    end
    else if Buffer.CacheAge[Slot] < LowestAge then
    begin
      LowestAge := Buffer.CacheAge[Slot];
      VictimSlot := Slot;
    end;

  if not FlushCacheSlot(Buffer, VictimSlot) then
  begin
    EnsureDocumentPage := -1;
    Exit;
  end;
  if not LoadCacheSlot(Buffer, VictimSlot, PageNumber) then
  begin
    EnsureDocumentPage := -1;
    Exit;
  end;

  if Buffer.CacheClock = $FFFF then
    NormalizeCacheAges(Buffer)
  else
    Inc(Buffer.CacheClock);
  Buffer.CacheAge[VictimSlot] := Buffer.CacheClock;
  Buffer.LastPageNumber := PageNumber;
  Buffer.LastPageSlot := VictimSlot;
  EnsureDocumentPage := VictimSlot;
end;


{ Copies the current page file to one newly created candidate and makes that
  candidate active only after the copy and all pending writes succeed. }
function TryRelocateBackingStore(var Buffer: TTextBuffer;
  const DirectoryName: String; Seed: Word): Boolean;
type
  TCopyBuffer = array[0..1023] of Byte;
var
  Attempt, CandidateValue: Word;
  Candidate, OldName: String;
  DestinationFile, EraseFile: File;
  CopyBuffer: TCopyBuffer;
  BytesRead, BytesWritten: Word;
  Remaining, ChunkSize: LongInt;
  Code, OldFileMode: Integer;
  Slot: Byte;
begin
  TryRelocateBackingStore := False;
  if not Buffer.BackingOpen then
    Exit;

  Attempt := 0;
  while Attempt < 256 do
  begin
    CandidateValue := Seed xor Attempt;
    Candidate := TempPath(DirectoryName, TempBaseName(CandidateValue));
    if (Length(Candidate) <= 127) and
       not SameDosPath(Candidate, Buffer.BackingName) and
       not ExistingDosPath(Candidate) then
    begin
      Assign(DestinationFile, Candidate);
      {$I-}
      Rewrite(DestinationFile, 1);
      Code := IOResult;
      {$I+}
      if Code = 0 then
      begin
        {$I-}
        Seek(Buffer.BackingFile, 0);
        Code := IOResult;
        {$I+}
        if Code = 0 then
        begin
          Remaining := FileSize(Buffer.BackingFile);
          while (Remaining > 0) and (Code = 0) do
          begin
            if Remaining > SizeOf(CopyBuffer) then
              ChunkSize := SizeOf(CopyBuffer)
            else
              ChunkSize := Remaining;
            BytesRead := 0;
            BytesWritten := 0;
            {$I-}
            BlockRead(Buffer.BackingFile, CopyBuffer, Word(ChunkSize), BytesRead);
            Code := IOResult;
            if (Code = 0) and (BytesRead = Word(ChunkSize)) then
            begin
              BlockWrite(DestinationFile, CopyBuffer, BytesRead, BytesWritten);
              Code := IOResult;
              if (Code = 0) and (BytesWritten <> BytesRead) then
                Code := 112;
            end
            else if Code = 0 then
              Code := 5;
            {$I+}
            Dec(Remaining, BytesRead);
          end;
        end;
        {$I-}
        System.Close(DestinationFile);
        if Code = 0 then
          Code := IOResult
        else
          IOResult;
        {$I+}

        if Code = 0 then
        begin
          OldName := Buffer.BackingName;
          {$I-}
          System.Close(Buffer.BackingFile);
          Code := IOResult;
          {$I+}
          Buffer.BackingOpen := False;
          if Code = 0 then
          begin
            Assign(Buffer.BackingFile, Candidate);
            OldFileMode := FileMode;
            FileMode := 2;
            {$I-}
            Reset(Buffer.BackingFile, 1);
            Code := IOResult;
            {$I+}
            FileMode := OldFileMode;
            if Code = 0 then
            begin
              Buffer.BackingOpen := True;
              Buffer.BackingName := Candidate;
              Buffer.StorageError := False;
              Buffer.StorageErrorCode := 0;
              for Slot := 0 to DocumentPageCacheCount - 1 do
                if not FlushCacheSlot(Buffer, Slot) then
                  Break;
              if not Buffer.StorageError then
              begin
                Assign(EraseFile, OldName);
                {$I-}
                Erase(EraseFile);
                IOResult;
                {$I+}
                TryRelocateBackingStore := True;
                Exit;
              end;

              {$I-}
              System.Close(Buffer.BackingFile);
              IOResult;
              {$I+}
              Buffer.BackingOpen := False;
              Assign(EraseFile, Candidate);
              {$I-}
              Erase(EraseFile);
              IOResult;
              {$I+}
              Assign(Buffer.BackingFile, OldName);
              OldFileMode := FileMode;
              FileMode := 2;
              {$I-}
              Reset(Buffer.BackingFile, 1);
              Code := IOResult;
              {$I+}
              FileMode := OldFileMode;
              if Code = 0 then
              begin
                Buffer.BackingOpen := True;
                Buffer.BackingName := OldName;
              end;
            end;
          end;
        end;

        Assign(EraseFile, Candidate);
        {$I-}
        Erase(EraseFile);
        IOResult;
        {$I+}
      end;
    end;
    Inc(Attempt);
  end;
end;

{ Tries configured temporary directories in priority order, preferring a path
  different from the failed backing file. }
function RelocateBackingStore(var Buffer: TTextBuffer): Boolean;
var
  HourValue, MinuteValue, SecondValue, HundredthValue: Word;
  Seed: Word;
  DirectoryName: String;
begin
  GetTime(HourValue, MinuteValue, SecondValue, HundredthValue);
  Seed := Word((HourValue shl 11) xor (MinuteValue shl 5) xor
    (SecondValue shl 1) xor HundredthValue xor $7A31);

  DirectoryName := GetEnv('EDIT98TMP');
  if (DirectoryName <> '') and
     TryRelocateBackingStore(Buffer, DirectoryName, Seed) then
  begin
    RelocateBackingStore := True;
    Exit;
  end;
  DirectoryName := GetEnv('TEMP');
  if (DirectoryName <> '') and
     TryRelocateBackingStore(Buffer, DirectoryName, Seed xor $1100) then
  begin
    RelocateBackingStore := True;
    Exit;
  end;
  DirectoryName := GetEnv('TMP');
  if (DirectoryName <> '') and
     TryRelocateBackingStore(Buffer, DirectoryName, Seed xor $2200) then
  begin
    RelocateBackingStore := True;
    Exit;
  end;
  RelocateBackingStore := TryRelocateBackingStore(Buffer, '', Seed xor $3300);
end;

{ Allocates three 10 KB page buffers and one DOS temporary backing file. }
function TTextBuffer.AllocateStorage: Boolean;
var
  Slot: Byte;
begin
  AllocateStorage := False;
  BackingOpen := False;
  BackingName := '';
  BackingPageCount := 0;
  StorageError := False;
  StorageErrorCode := 0;
  for Slot := 0 to DocumentPageCacheCount - 1 do
    CachePages[Slot] := nil;
  InvalidatePageCache(Self);

  for Slot := 0 to DocumentPageCacheCount - 1 do
  begin
    New(CachePages[Slot]);
    if CachePages[Slot] = nil then
    begin
      ReleaseStorage;
      Exit;
    end;
    ClearDocumentPage(CachePages[Slot]^, ffSansSerif);
  end;

  if not CreateBackingStore(Self) then
  begin
    ReleaseStorage;
    Exit;
  end;
  AllocateStorage := True;
end;

{ Releases every cache page and removes EDIT98's temporary paging file. }
procedure TTextBuffer.ReleaseStorage;
var
  Slot: Byte;
begin
  if BackingOpen then
  begin
    {$I-}
    System.Close(BackingFile);
    IOResult;
    {$I+}
    BackingOpen := False;
  end;
  if BackingName <> '' then
  begin
    Assign(BackingFile, BackingName);
    {$I-}
    Erase(BackingFile);
    IOResult;
    {$I+}
    BackingName := '';
  end;

  for Slot := 0 to DocumentPageCacheCount - 1 do
    if CachePages[Slot] <> nil then
    begin
      Dispose(CachePages[Slot]);
      CachePages[Slot] := nil;
    end;
  InvalidatePageCache(Self);
end;

{ Returns immediate read access to one paged document line. }
function TTextBuffer.LinePtr(Index: Word): PEditorLine;
var
  PageNumber, PageLine: Word;
  Slot: Integer;
begin
  if Index >= MaxLines then
    Index := MaxLines - 1;
  PageNumber := Index div DocumentLinesPerPage;
  PageLine := Index mod DocumentLinesPerPage;
  Slot := EnsureDocumentPage(Self, PageNumber);
  if Slot < 0 then
    LinePtr := @StorageFallbackLine
  else
    LinePtr := @CachePages[Slot]^.Lines[PageLine];
end;

{ Returns immediate read access to one paged formatting line. }
function TTextBuffer.FontPtr(Index: Word): PFontStyleLine;
var
  PageNumber, PageLine: Word;
  Slot: Integer;
begin
  if Index >= MaxLines then
    Index := MaxLines - 1;
  PageNumber := Index div DocumentLinesPerPage;
  PageLine := Index mod DocumentLinesPerPage;
  Slot := EnsureDocumentPage(Self, PageNumber);
  if Slot < 0 then
    FontPtr := @StorageFallbackFonts
  else
    FontPtr := @CachePages[Slot]^.Fonts[PageLine];
end;

{ Returns writable text access and marks the page for later write-back. }
function TTextBuffer.EditLinePtr(Index: Word): PEditorLine;
var
  PageNumber, PageLine: Word;
  Slot: Integer;
begin
  if Index >= MaxLines then
    Index := MaxLines - 1;
  PageNumber := Index div DocumentLinesPerPage;
  PageLine := Index mod DocumentLinesPerPage;
  Slot := EnsureDocumentPage(Self, PageNumber);
  if Slot < 0 then
    EditLinePtr := @StorageFallbackLine
  else
  begin
    CacheDirty[Slot] := True;
    EditLinePtr := @CachePages[Slot]^.Lines[PageLine];
  end;
end;

{ Returns writable formatting access and marks the page for write-back. }
function TTextBuffer.EditFontPtr(Index: Word): PFontStyleLine;
var
  PageNumber, PageLine: Word;
  Slot: Integer;
begin
  if Index >= MaxLines then
    Index := MaxLines - 1;
  PageNumber := Index div DocumentLinesPerPage;
  PageLine := Index mod DocumentLinesPerPage;
  Slot := EnsureDocumentPage(Self, PageNumber);
  if Slot < 0 then
    EditFontPtr := @StorageFallbackFonts
  else
  begin
    CacheDirty[Slot] := True;
    EditFontPtr := @CachePages[Slot]^.Fonts[PageLine];
  end;
end;

{ Marks one line page dirty after direct text/font mutation by the UI. }
procedure TTextBuffer.MarkLineDirty(Index: Word);
var
  PageNumber: Word;
  Slot: Integer;
begin
  if Index >= MaxLines then
    Exit;
  PageNumber := Index div DocumentLinesPerPage;
  Slot := EnsureDocumentPage(Self, PageNumber);
  if Slot >= 0 then
    CacheDirty[Slot] := True;
end;

{ Writes the three resident pages and exposes any DOS paging error. }
function TTextBuffer.FlushStorage(var ErrorText: String): Boolean;
var
  Slot: Byte;
begin
  FlushStorage := False;
  if StorageError then
  begin
    if not RecoverStorage(ErrorText) then
      Exit;
  end;
  if not CheckStorageSpace(ErrorText) then
    Exit;
  for Slot := 0 to DocumentPageCacheCount - 1 do
    if not FlushCacheSlot(Self, Slot) then
      Break;

  if StorageError then
  begin
    ErrorText := StorageErrorMessage(Self);
    Exit;
  end;
  ErrorText := '';
  FlushStorage := True;
end;

{ Returns the diagnostic path of the active temporary page file. }
function TTextBuffer.StoragePath: String;
begin
  StoragePath := BackingName;
end;

{ Checks whether pending dirty pages would need to extend the page file beyond
  its current physical length.  Existing-page rewrites require no new space. }
function TTextBuffer.CheckStorageSpace(var ErrorText: String): Boolean;
var
  Slot: Byte;
  HighestPage: LongInt;
  CurrentBytes, RequiredBytes, AdditionalBytes, FreeBytes: LongInt;
  DriveNumber: Byte;
  RequiredText, FreeText: String;
begin
  CheckStorageSpace := False;
  ErrorText := '';
  if not BackingOpen then
  begin
    ErrorText := 'Temporary document storage is not open: ' + BackingName + '.';
    Exit;
  end;

  HighestPage := BackingPageCount;
  for Slot := 0 to DocumentPageCacheCount - 1 do
    if CacheDirty[Slot] and
       (CachePageNumbers[Slot] <> InvalidDocumentPage) and
       (LongInt(CachePageNumbers[Slot]) + 1 > HighestPage) then
      HighestPage := LongInt(CachePageNumbers[Slot]) + 1;

  CurrentBytes := FileSize(BackingFile);
  RequiredBytes := HighestPage * LongInt(SizeOf(TDocumentPage));
  AdditionalBytes := RequiredBytes - CurrentBytes;
  if AdditionalBytes < 0 then
    AdditionalBytes := 0;

  DriveNumber := PathDriveNumber(BackingName);
  FreeBytes := DiskFree(DriveNumber);
  if FreeBytes < 0 then
  begin
    ErrorText := 'Unable to determine free space for ' + BackingName + '.';
    Exit;
  end;

  { Keep one cluster-sized safety allowance because DOS may allocate space in
    units larger than the exact page-file extension. }
  if (AdditionalBytes > 0) and (FreeBytes < AdditionalBytes + 4096) then
  begin
    Str(AdditionalBytes + 4096, RequiredText);
    Str(FreeBytes, FreeText);
    ErrorText := 'Not enough free space for temporary document storage at ' +
      BackingName + '. Need about ' + RequiredText + ' bytes; ' + FreeText +
      ' bytes are free.';
    Exit;
  end;

  CheckStorageSpace := True;
end;

{ Retries a retained page-file error.  If the original drive still cannot
  accept the dirty pages, the complete backing file is moved to another
  configured temporary directory and the resident dirty pages are overlaid. }
function TTextBuffer.RecoverStorage(var ErrorText: String): Boolean;
var
  Slot: Byte;
  OriginalCode: Integer;
begin
  RecoverStorage := False;
  ErrorText := '';
  OriginalCode := StorageErrorCode;
  StorageError := False;
  StorageErrorCode := 0;

  if CheckStorageSpace(ErrorText) then
  begin
    for Slot := 0 to DocumentPageCacheCount - 1 do
      if not FlushCacheSlot(Self, Slot) then
        Break;
    if not StorageError then
    begin
      ErrorText := '';
      RecoverStorage := True;
      Exit;
    end;
  end;

  { Error 112 is specifically insufficient disk space.  Relocation is also
    attempted after other write errors because a failing drive may be the
    underlying cause even when DOS reports a less specific code. }
  StorageError := False;
  StorageErrorCode := 0;
  if RelocateBackingStore(Self) then
  begin
    ErrorText := '';
    RecoverStorage := True;
    Exit;
  end;

  if not StorageError then
  begin
    StorageError := True;
    if OriginalCode <> 0 then
      StorageErrorCode := OriginalCode
    else
      StorageErrorCode := 112;
  end;
  ErrorText := StorageErrorMessage(Self);
end;

{ Adds or merges one bounded logical-font run in clipboard coordinates. }
procedure AddClipboardFontRun(var Clipboard: TTextClipboard; LineIndex,
  StartColumn, RunLength: Word; Family: TFontFamily);
var
  PreviousIndex, CombinedLength: Word;
begin
  if (RunLength = 0) or not Clipboard.FontsPreserved then
    Exit;

  if Clipboard.FontRunCount > 0 then
  begin
    PreviousIndex := Clipboard.FontRunCount - 1;
    if (Clipboard.FontRuns[PreviousIndex].LineIndex = LineIndex) and
       (Clipboard.FontRuns[PreviousIndex].Family = Family) and
       (Word(Clipboard.FontRuns[PreviousIndex].StartColumn) +
        Clipboard.FontRuns[PreviousIndex].RunLength = StartColumn) then
    begin
      CombinedLength := Word(Clipboard.FontRuns[PreviousIndex].RunLength) +
        RunLength;
      if CombinedLength <= 255 then
      begin
        Clipboard.FontRuns[PreviousIndex].RunLength := Byte(CombinedLength);
        Exit;
      end;
    end;
  end;

  if Clipboard.FontRunCount >= MaxClipboardFontRuns then
  begin
    { Highly fragmented formatting is rare.  Preserve the text and use the
      first copied family rather than overflowing fixed real-mode storage. }
    Clipboard.FontRunCount := 0;
    Clipboard.FontsPreserved := False;
    Exit;
  end;

  Clipboard.FontRuns[Clipboard.FontRunCount].LineIndex := Byte(LineIndex);
  Clipboard.FontRuns[Clipboard.FontRunCount].StartColumn := Byte(StartColumn);
  Clipboard.FontRuns[Clipboard.FontRunCount].RunLength := Byte(RunLength);
  Clipboard.FontRuns[Clipboard.FontRunCount].Family := Family;
  Inc(Clipboard.FontRunCount);
end;

{ Captures one copied source-line segment as compact clipboard font runs. }
procedure CaptureClipboardLineFonts(const TextBuffer: TTextBuffer;
  SourceLine, SourceColumn, CopyLength, ClipboardLine: Word;
  var Clipboard: TTextClipboard);
var
  Column, RunStart: Word;
  Family, NextFamily: TFontFamily;
begin
  if (CopyLength = 0) or not Clipboard.FontsPreserved then
    Exit;

  RunStart := 0;
  Family := TextBuffer.FontAt(SourceLine, SourceColumn);
  Column := 1;
  while Column < CopyLength do
  begin
    NextFamily := TextBuffer.FontAt(SourceLine, SourceColumn + Column);
    if NextFamily <> Family then
    begin
      AddClipboardFontRun(Clipboard, ClipboardLine, RunStart,
        Column - RunStart, Family);
      if not Clipboard.FontsPreserved then
        Exit;
      RunStart := Column;
      Family := NextFamily;
    end;
    Inc(Column);
  end;
  AddClipboardFontRun(Clipboard, ClipboardLine, RunStart,
    CopyLength - RunStart, Family);
end;

{ Paints one clipboard line's stored font runs into a destination style line. }
procedure PaintClipboardLineFonts(const Clipboard: TTextClipboard;
  ClipboardLine, DestinationColumn, TextLength: Word;
  var Destination: TFontStyleLine);
var
  I, Column, RunStart, RunEnd: Word;
  Family: TFontFamily;
begin
  if TextLength = 0 then
    Exit;

  { The fallback also initializes gaps if a malformed or truncated run list is
    encountered. }
  Column := 0;
  while Column < TextLength do
  begin
    SetFontFamily(Destination, DestinationColumn + Column,
      Clipboard.FallbackFont);
    Inc(Column);
  end;

  if (not Clipboard.FontsPreserved) or (Clipboard.FontRunCount = 0) then
    Exit;
  for I := 0 to Clipboard.FontRunCount - 1 do
    if Clipboard.FontRuns[I].LineIndex = ClipboardLine then
    begin
      Family := Clipboard.FontRuns[I].Family;
      RunStart := Clipboard.FontRuns[I].StartColumn;
      RunEnd := RunStart + Clipboard.FontRuns[I].RunLength;
      if RunEnd > TextLength then
        RunEnd := TextLength;
      Column := RunStart;
      while Column < RunEnd do
      begin
        SetFontFamily(Destination, DestinationColumn + Column, Family);
        Inc(Column);
      end;
    end;
end;

{ Validates ordered, end-exclusive document range coordinates. }
function ValidateRange(const TextBuffer: TTextBuffer; StartLine, StartColumn,
  EndLine, EndColumn: Word; RequireText: Boolean;
  var ErrorText: String): Boolean;
begin
  { End positions are exclusive.  Empty ranges are valid insertion points only
    when RequireText is False. }
  ValidateRange := False;
  ErrorText := '';

  if (StartLine >= TextBuffer.Count) or (EndLine >= TextBuffer.Count) then
  begin
    ErrorText := 'The selection is outside the document.';
    Exit;
  end;

  if (StartLine > EndLine) or
     ((StartLine = EndLine) and (StartColumn > EndColumn)) then
  begin
    ErrorText := 'The selection is in an invalid order.';
    Exit;
  end;

  if RequireText and (StartLine = EndLine) and
     (StartColumn = EndColumn) then
  begin
    ErrorText := 'No text is selected.';
    Exit;
  end;

  if (StartColumn > Length(TextBuffer.LinePtr(StartLine)^)) or
     (EndColumn > Length(TextBuffer.LinePtr(EndLine)^)) then
  begin
    ErrorText := 'The selection is outside the current line.';
    Exit;
  end;

  ValidateRange := True;
end;

{ Joins two adjacent lines when the resulting line fits capacity. }
function JoinLines(var TextBuffer: TTextBuffer; FirstLine: Word): Boolean;
var
  I, FirstLength, SecondLength: Word;
begin
  { Join FirstLine with the following line and close the resulting text and
    font-style gaps together. }
  JoinLines := False;
  if FirstLine + 1 >= TextBuffer.Count then
    Exit;
  FirstLength := Length(TextBuffer.EditLinePtr(FirstLine)^);
  SecondLength := Length(TextBuffer.EditLinePtr(FirstLine + 1)^);
  if FirstLength + SecondLength > MaxLineLength then
    Exit;

  CopyFontFamilies(TextBuffer.EditFontPtr(FirstLine + 1)^, 0, SecondLength,
    TextBuffer.EditFontPtr(FirstLine)^, FirstLength);
  TextBuffer.EditLinePtr(FirstLine)^ := TextBuffer.EditLinePtr(FirstLine)^ +
    TextBuffer.EditLinePtr(FirstLine + 1)^;
  for I := FirstLine + 1 to TextBuffer.Count - 2 do
  begin
    TextBuffer.EditLinePtr(I)^ := TextBuffer.EditLinePtr(I + 1)^;
    TextBuffer.EditFontPtr(I)^ := TextBuffer.EditFontPtr(I + 1)^;
  end;
  TextBuffer.EditLinePtr(TextBuffer.Count - 1)^ := '';
  ClearFontStyleLine(TextBuffer.EditFontPtr(TextBuffer.Count - 1)^,
    TextBuffer.TypingFont);
  Dec(TextBuffer.Count);
  TextBuffer.Dirty := True;
  JoinLines := True;
end;

{ Atomically replaces a range with fixed clipboard contents. }
function TTextBuffer.ReplaceRangeWithClipboard(StartLine, StartColumn,
  EndLine, EndColumn: Word; var LineIndex, Column: Word;
  const Clipboard: TTextClipboard; var ErrorText: String): Boolean;
var
  I, OldCount, NewCount, SourceTailStart, DestinationTailStart: Word;
  DestinationIndex: Word;
  NewCountValue: LongInt;
  PrefixLength, SuffixLength, ClipboardLength: Word;
  PrefixText, SuffixText: TEditorLine;
  NewFirstFonts, NewLastFonts: TFontStyleLine;
begin
  { Replace a possibly empty range with clipboard text.  Every capacity and
    line-length check happens before the first byte or family value is moved,
    preserving the atomic paste-over-selection guarantee. }
  ReplaceRangeWithClipboard := False;
  ErrorText := '';

  if Clipboard.Count = 0 then
  begin
    ErrorText := 'The clipboard is empty.';
    Exit;
  end;
  if not ValidateRange(Self, StartLine, StartColumn, EndLine,
                       EndColumn, False, ErrorText) then
    Exit;

  OldCount := Count;
  NewCountValue := LongInt(OldCount) - LongInt(EndLine - StartLine) +
    LongInt(Clipboard.Count) - 1;
  if (NewCountValue < 1) or (NewCountValue > MaxLines) then
  begin
    ErrorText := 'There is not enough room for all clipboard lines.';
    Exit;
  end;
  NewCount := Word(NewCountValue);

  PrefixText := Copy(EditLinePtr(StartLine)^, 1, StartColumn);
  SuffixText := Copy(EditLinePtr(EndLine)^, EndColumn + 1, MaxLineLength);
  PrefixLength := Length(PrefixText);
  SuffixLength := Length(SuffixText);

  if Clipboard.Count = 1 then
  begin
    if PrefixLength + Length(Clipboard.Lines[0]) + SuffixLength >
       MaxLineLength then
    begin
      ErrorText := 'The pasted text would create an overlong line.';
      Exit;
    end;
  end
  else
  begin
    { Check component lengths before concatenating short strings.  Length() of a
      String[255] can never exceed 255, so checking the result after the
      concatenation was both ineffective and diagnosed as unreachable by FPC. }
    if (PrefixLength + Length(Clipboard.Lines[0]) > MaxLineLength) or
       (Length(Clipboard.Lines[Clipboard.Count - 1]) + SuffixLength >
        MaxLineLength) then
    begin
      ErrorText := 'The pasted text would create an overlong line.';
      Exit;
    end;
  end;

  ClearFontStyleLine(NewFirstFonts, TypingFont);
  ClearFontStyleLine(NewLastFonts, TypingFont);
  CopyFontFamilies(EditFontPtr(StartLine)^, 0, PrefixLength,
    NewFirstFonts, 0);

  ClipboardLength := Length(Clipboard.Lines[0]);
  PaintClipboardLineFonts(Clipboard, 0, PrefixLength, ClipboardLength,
    NewFirstFonts);

  if Clipboard.Count = 1 then
    CopyFontFamilies(EditFontPtr(EndLine)^, EndColumn, SuffixLength,
      NewFirstFonts, PrefixLength + ClipboardLength)
  else
  begin
    ClipboardLength := Length(Clipboard.Lines[Clipboard.Count - 1]);
    PaintClipboardLineFonts(Clipboard, Clipboard.Count - 1, 0,
      ClipboardLength, NewLastFonts);
    CopyFontFamilies(EditFontPtr(EndLine)^, EndColumn, SuffixLength,
      NewLastFonts, ClipboardLength);
  end;

  { Move the untouched tail in the direction that cannot overwrite source
    lines which have not yet been copied. }
  SourceTailStart := EndLine + 1;
  DestinationTailStart := StartLine + Clipboard.Count;
  if SourceTailStart < OldCount then
  begin
    if DestinationTailStart > SourceTailStart then
      for I := OldCount - 1 downto SourceTailStart do
      begin
        DestinationIndex := Word(LongInt(DestinationTailStart) +
          LongInt(I) - LongInt(SourceTailStart));
        EditLinePtr(DestinationIndex)^ := EditLinePtr(I)^;
        EditFontPtr(DestinationIndex)^ := EditFontPtr(I)^;
      end
    else if DestinationTailStart < SourceTailStart then
      for I := SourceTailStart to OldCount - 1 do
      begin
        DestinationIndex := Word(LongInt(DestinationTailStart) +
          LongInt(I) - LongInt(SourceTailStart));
        EditLinePtr(DestinationIndex)^ := EditLinePtr(I)^;
        EditFontPtr(DestinationIndex)^ := EditFontPtr(I)^;
      end;
  end;

  if Clipboard.Count = 1 then
  begin
    EditLinePtr(StartLine)^ := PrefixText + Clipboard.Lines[0] + SuffixText;
    EditFontPtr(StartLine)^ := NewFirstFonts;
    LineIndex := StartLine;
    Column := StartColumn + Length(Clipboard.Lines[0]);
  end
  else
  begin
    EditLinePtr(StartLine)^ := PrefixText + Clipboard.Lines[0];
    EditFontPtr(StartLine)^ := NewFirstFonts;
    if Clipboard.Count > 2 then
      for I := 1 to Clipboard.Count - 2 do
      begin
        EditLinePtr(StartLine + I)^ := Clipboard.Lines[I];
        ClearFontStyleLine(EditFontPtr(StartLine + I)^, Clipboard.FallbackFont);
        PaintClipboardLineFonts(Clipboard, I, 0,
          Length(Clipboard.Lines[I]), EditFontPtr(StartLine + I)^);
      end;
    EditLinePtr(StartLine + Clipboard.Count - 1)^ :=
      Clipboard.Lines[Clipboard.Count - 1] + SuffixText;
    EditFontPtr(StartLine + Clipboard.Count - 1)^ := NewLastFonts;
    LineIndex := StartLine + Clipboard.Count - 1;
    Column := Length(Clipboard.Lines[Clipboard.Count - 1]);
  end;

  Count := NewCount;
  if NewCount < OldCount then
    for I := NewCount to OldCount - 1 do
    begin
      EditLinePtr(I)^ := '';
      ClearFontStyleLine(EditFontPtr(I)^, TypingFont);
    end;
  Dirty := True;
  ReplaceRangeWithClipboard := True;
end;

{ Empties the clipboard and clears its fixed storage. }
procedure TTextClipboard.Clear;
begin
  ClearClipboardLineArray(Lines);
  FontRunCount := 0;
  FallbackFont := ffSansSerif;
  FontsPreserved := True;
  Count := 0;
end;

{ Initializes a new one-line document without touching off-screen pages.
  Old backing bytes are logically discarded by resetting BackingPageCount. }
procedure TTextBuffer.Init;
begin
  TypingFont := ffSansSerif;
  PrintColumns := DefaultPrintColumns;
  PrintRows := DefaultPrintRows;
  StorageError := False;
  StorageErrorCode := 0;
  ResetBackingStore(Self);
  Count := 1;
  EditLinePtr(0)^ := '';
  ClearFontStyleLine(EditFontPtr(0)^, TypingFont);
  Dirty := False;
end;

{ Returns the logical font assigned to one document character. }
function TTextBuffer.FontAt(LineIndex, Column: Word): TFontFamily;
begin
  if (LineIndex >= Count) or (Column > 255) then
    FontAt := TypingFont
  else
    FontAt := GetFontFamily(FontPtr(LineIndex)^, Column);
end;

{ Returns the local font inherited by text inserted at a caret position. }
function TTextBuffer.InsertionFontAt(LineIndex, Column: Word): TFontFamily;
var
  LineLength: Word;
begin
  if LineIndex >= Count then
  begin
    InsertionFontAt := TypingFont;
    Exit;
  end;

  LineLength := Length(LinePtr(LineIndex)^);
  if LineLength = 0 then
    InsertionFontAt := TypingFont
  else if Column < LineLength then
    InsertionFontAt := FontAt(LineIndex, Column)
  else
    InsertionFontAt := FontAt(LineIndex, LineLength - 1);
end;

{ Assigns one logical font without changing the character itself. }
procedure TTextBuffer.SetFontAt(LineIndex, Column: Word;
  Family: TFontFamily);
begin
  if (LineIndex < Count) and (Column < Length(LinePtr(LineIndex)^)) then
  begin
    SetFontFamily(EditFontPtr(LineIndex)^, Column, Family);
    Dirty := True;
  end;
end;

{ Assigns one logical font to every existing character in a document range. }
procedure TTextBuffer.SetFontRange(StartLine, StartColumn, EndLine,
  EndColumn: Word; Family: TFontFamily);
var
  LineIndex, FirstColumn, LastColumn, Column: Word;
  Changed: Boolean;
begin
  if (StartLine >= Count) or (EndLine >= Count) then
    Exit;
  if (StartLine > EndLine) or
     ((StartLine = EndLine) and (StartColumn > EndColumn)) then
    Exit;

  Changed := False;
  LineIndex := StartLine;
  while LineIndex <= EndLine do
  begin
    if LineIndex = StartLine then
      FirstColumn := StartColumn
    else
      FirstColumn := 0;
    if LineIndex = EndLine then
      LastColumn := EndColumn
    else
      LastColumn := Length(EditLinePtr(LineIndex)^);

    if FirstColumn > Length(EditLinePtr(LineIndex)^) then
      FirstColumn := Length(EditLinePtr(LineIndex)^);
    if LastColumn > Length(EditLinePtr(LineIndex)^) then
      LastColumn := Length(EditLinePtr(LineIndex)^);

    Column := FirstColumn;
    while Column < LastColumn do
    begin
      SetFontFamily(EditFontPtr(LineIndex)^, Column, Family);
      Changed := True;
      Inc(Column);
    end;
    if LineIndex = EndLine then
      Break;
    Inc(LineIndex);
  end;
  if Changed then
    Dirty := True;
end;

{ Reports whether all existing characters in a range use one font family. }
function TTextBuffer.FontRangeIsUniform(StartLine, StartColumn, EndLine,
  EndColumn: Word; var Family: TFontFamily): Boolean;
var
  LineIndex, FirstColumn, LastColumn, Column: Word;
  Candidate: TFontFamily;
  FoundCharacter: Boolean;
begin
  FontRangeIsUniform := True;
  FoundCharacter := False;
  if (StartLine >= Count) or (EndLine >= Count) then
  begin
    Family := TypingFont;
    Exit;
  end;
  if (StartLine > EndLine) or
     ((StartLine = EndLine) and (StartColumn > EndColumn)) then
  begin
    Family := TypingFont;
    Exit;
  end;

  LineIndex := StartLine;
  while LineIndex <= EndLine do
  begin
    if LineIndex = StartLine then
      FirstColumn := StartColumn
    else
      FirstColumn := 0;
    if LineIndex = EndLine then
      LastColumn := EndColumn
    else
      LastColumn := Length(LinePtr(LineIndex)^);

    if FirstColumn > Length(LinePtr(LineIndex)^) then
      FirstColumn := Length(LinePtr(LineIndex)^);
    if LastColumn > Length(LinePtr(LineIndex)^) then
      LastColumn := Length(LinePtr(LineIndex)^);

    Column := FirstColumn;
    while Column < LastColumn do
    begin
      Candidate := FontAt(LineIndex, Column);
      if not FoundCharacter then
      begin
        Family := Candidate;
        FoundCharacter := True;
      end
      else if Candidate <> Family then
      begin
        FontRangeIsUniform := False;
        Exit;
      end;
      Inc(Column);
    end;
    if LineIndex = EndLine then
      Break;
    Inc(LineIndex);
  end;

  if not FoundCharacter then
    Family := InsertionFontAt(StartLine, StartColumn);
end;

{ Assigns one logical font to every existing character on a line. }
procedure TTextBuffer.SetLineFont(LineIndex: Word; Family: TFontFamily);
var
  Column: Word;
begin
  if LineIndex >= Count then
    Exit;
  ClearFontStyleLine(EditFontPtr(LineIndex)^, Family);
  if Length(LinePtr(LineIndex)^) > 0 then
  begin
    for Column := 0 to Length(LinePtr(LineIndex)^) - 1 do
      SetFontFamily(EditFontPtr(LineIndex)^, Column, Family);
    Dirty := True;
  end;
end;

{ Loads a DOS text file while enforcing line and document limits. }
function TTextBuffer.LoadFromFile(const FileName: String;
  var ErrorText: String): Boolean;
var
  F: Text;
  Code: Integer;
  CodeText: String;
  Truncated: Boolean;
  DefaultFont: TFontFamily;
  CapacityText: String;
  LineIndex: Word;
begin
  DefaultFont := TypingFont;
  Init;
  TypingFont := DefaultFont;
  if StorageError then
  begin
    ErrorText := StorageErrorMessage(Self);
    LoadFromFile := False;
    Exit;
  end;
  Assign(F, FileName);
  {$I-}
  Reset(F);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    Str(Code, CodeText);
    ErrorText := 'Unable to open file (DOS error ' + CodeText + ').';
    LoadFromFile := False;
    Exit;
  end;

  Count := 0;
  Truncated := False;
  while (not Eof(F)) and (Count < MaxLines) do
  begin
    LineIndex := Count;
    EditLinePtr(LineIndex)^ := '';
    ClearFontStyleLine(EditFontPtr(LineIndex)^, TypingFont);
    {$I-}
    ReadLn(F, EditLinePtr(LineIndex)^);
    Code := IOResult;
    {$I+}
    if Code <> 0 then
    begin
      Close(F);
      Str(Code, CodeText);
      ErrorText := 'Unable to read file (DOS error ' + CodeText + ').';
      LoadFromFile := False;
      Exit;
    end;
    Inc(Count);
  end;
  if not Eof(F) then
    Truncated := True;
  {$I-}
  Close(F);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    Str(Code, CodeText);
    ErrorText := 'Unable to close file (DOS error ' + CodeText + ').';
    LoadFromFile := False;
    Exit;
  end;

  if Count = 0 then
  begin
    Count := 1;
    EditLinePtr(0)^ := '';
    ClearFontStyleLine(EditFontPtr(0)^, TypingFont);
  end;

  if not FlushStorage(ErrorText) then
  begin
    LoadFromFile := False;
    Exit;
  end;

  if Truncated then
  begin
    Str(MaxLines, CapacityText);
    ErrorText := 'Only the first ' + CapacityText + ' lines were loaded.';
  end
  else
    ErrorText := '';

  Dirty := False;
  LoadFromFile := True;
end;

{ Writes the buffer as DOS text and clears the dirty flag on success. }
function TTextBuffer.SaveToFile(const FileName: String;
  var ErrorText: String): Boolean;
var
  F: Text;
  I: Word;
  Code: Integer;
  CodeText: String;
begin
  if not FlushStorage(ErrorText) then
  begin
    SaveToFile := False;
    Exit;
  end;

  Assign(F, FileName);
  {$I-}
  Rewrite(F);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    Str(Code, CodeText);
    ErrorText := 'Unable to create file (DOS error ' + CodeText + ').';
    SaveToFile := False;
    Exit;
  end;

  I := 0;
  while I < Count do
  begin
    {$I-}
    WriteLn(F, LinePtr(I)^);
    Code := IOResult;
    {$I+}
    if Code <> 0 then
    begin
      {$I-}
      Close(F);
      IOResult;
      {$I+}
      Str(Code, CodeText);
      ErrorText := 'Unable to write file (DOS error ' + CodeText + ').';
      SaveToFile := False;
      Exit;
    end;
    Inc(I);
  end;

  {$I-}
  Close(F);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    Str(Code, CodeText);
    ErrorText := 'Unable to close file (DOS error ' + CodeText + ').';
    SaveToFile := False;
    Exit;
  end;

  Dirty := False;
  ErrorText := '';
  SaveToFile := True;
end;

{ Inserts a character into a line when capacity permits. }
function TTextBuffer.InsertChar(LineIndex, Column: Word; Ch: Char): Boolean;
var
  OneChar: String[1];
  OldLength: Word;
begin
  InsertChar := False;
  if (LineIndex >= Count) or (Length(EditLinePtr(LineIndex)^) >= MaxLineLength) then
    Exit;

  OldLength := Length(EditLinePtr(LineIndex)^);
  if Column > OldLength then
    Column := OldLength;

  InsertFontFamily(EditFontPtr(LineIndex)^, Column, OldLength, TypingFont);
  OneChar := Ch;
  EditLinePtr(LineIndex)^ := Copy(EditLinePtr(LineIndex)^, 1, Column) + OneChar +
    Copy(EditLinePtr(LineIndex)^, Column + 1, MaxLineLength);
  Dirty := True;
  InsertChar := True;
end;

{ Overwrites an existing character or appends at end of line. }
function TTextBuffer.OverwriteChar(LineIndex, Column: Word; Ch: Char): Boolean;
begin
  OverwriteChar := False;
  if LineIndex >= Count then
    Exit;

  if Column < Length(EditLinePtr(LineIndex)^) then
  begin
    EditLinePtr(LineIndex)^[Column + 1] := Ch;
    SetFontFamily(EditFontPtr(LineIndex)^, Column, TypingFont);
    Dirty := True;
    OverwriteChar := True;
  end
  else
    OverwriteChar := InsertChar(LineIndex, Column, Ch);
end;

{ Deletes at a position or joins with the next line at end-of-line. }
procedure TTextBuffer.DeleteAt(LineIndex, Column: Word);
var
  OldLength: Word;
begin
  if LineIndex >= Count then
    Exit;

  OldLength := Length(EditLinePtr(LineIndex)^);
  if Column < OldLength then
  begin
    DeleteFontFamily(EditFontPtr(LineIndex)^, Column, OldLength, TypingFont);
    Delete(EditLinePtr(LineIndex)^, Column + 1, 1);
    Dirty := True;
  end
  else
    JoinLines(Self, LineIndex);
end;

{ Deletes before a position or joins with the previous line. }
procedure TTextBuffer.BackspaceAt(var LineIndex, Column: Word);
var
  PreviousLength, OldLength: Word;
begin
  if LineIndex >= Count then
    Exit;

  if Column > 0 then
  begin
    OldLength := Length(EditLinePtr(LineIndex)^);
    DeleteFontFamily(EditFontPtr(LineIndex)^, Column - 1, OldLength, TypingFont);
    Delete(EditLinePtr(LineIndex)^, Column, 1);
    Dec(Column);
    Dirty := True;
  end
  else if LineIndex > 0 then
  begin
    PreviousLength := Length(EditLinePtr(LineIndex - 1)^);
    if JoinLines(Self, LineIndex - 1) then
    begin
      Dec(LineIndex);
      Column := PreviousLength;
    end;
  end;
end;

{ Splits one line at the caret when document capacity permits. }
procedure TTextBuffer.SplitLine(var LineIndex, Column: Word);
var
  I, OldLength, TailLength: Word;
  Tail: TEditorLine;
begin
  if (LineIndex >= Count) or (Count >= MaxLines) then
    Exit;

  OldLength := Length(EditLinePtr(LineIndex)^);
  if Column > OldLength then
    Column := OldLength;
  TailLength := OldLength - Column;

  Tail := Copy(EditLinePtr(LineIndex)^, Column + 1, MaxLineLength);
  Delete(EditLinePtr(LineIndex)^, Column + 1, MaxLineLength);

  I := Count;
  while I > LineIndex + 1 do
  begin
    EditLinePtr(I)^ := EditLinePtr(I - 1)^;
    EditFontPtr(I)^ := EditFontPtr(I - 1)^;
    Dec(I);
  end;

  EditLinePtr(LineIndex + 1)^ := Tail;
  ClearFontStyleLine(EditFontPtr(LineIndex + 1)^, TypingFont);
  CopyFontFamilies(EditFontPtr(LineIndex)^, Column, TailLength,
    EditFontPtr(LineIndex + 1)^, 0);
  I := Column;
  while I < OldLength do
  begin
    SetFontFamily(EditFontPtr(LineIndex)^, I, TypingFont);
    Inc(I);
  end;

  Inc(Count);
  Inc(LineIndex);
  Column := 0;
  Dirty := True;
end;

{ Copies an end-exclusive range into the fixed clipboard. }
function TTextBuffer.CopyRange(StartLine, StartColumn, EndLine, EndColumn: Word;
  var Clipboard: TTextClipboard; var ErrorText: String): Boolean;
var
  SourceLine, TargetLine, CopyLength: Word;
begin
  Clipboard.Clear;
  CopyRange := False;
  if not ValidateRange(Self, StartLine, StartColumn, EndLine, EndColumn,
                       True, ErrorText) then
    Exit;

  if (EndLine - StartLine + 1) > MaxClipboardLines then
  begin
    ErrorText := 'The selection exceeds the 96-line clipboard capacity.';
    Exit;
  end;

  if StartColumn < Length(LinePtr(StartLine)^) then
    Clipboard.FallbackFont := GetFontFamily(FontPtr(StartLine)^, StartColumn)
  else
    Clipboard.FallbackFont := TypingFont;

  if StartLine = EndLine then
  begin
    Clipboard.Count := 1;
    CopyLength := EndColumn - StartColumn;
    Clipboard.Lines[0] := Copy(LinePtr(StartLine)^, StartColumn + 1,
      CopyLength);
    CaptureClipboardLineFonts(Self, StartLine, StartColumn, CopyLength, 0,
      Clipboard);
  end
  else
  begin
    Clipboard.Count := EndLine - StartLine + 1;
    CopyLength := Length(LinePtr(StartLine)^) - StartColumn;
    Clipboard.Lines[0] := Copy(LinePtr(StartLine)^, StartColumn + 1,
      MaxLineLength);
    CaptureClipboardLineFonts(Self, StartLine, StartColumn, CopyLength, 0,
      Clipboard);
    TargetLine := 1;
    for SourceLine := StartLine + 1 to EndLine - 1 do
    begin
      Clipboard.Lines[TargetLine] := LinePtr(SourceLine)^;
      CaptureClipboardLineFonts(Self, SourceLine, 0,
        Length(LinePtr(SourceLine)^), TargetLine, Clipboard);
      Inc(TargetLine);
    end;
    Clipboard.Lines[Clipboard.Count - 1] :=
      Copy(LinePtr(EndLine)^, 1, EndColumn);
    CaptureClipboardLineFonts(Self, EndLine, 0, EndColumn,
      Clipboard.Count - 1, Clipboard);
  end;

  ErrorText := '';
  CopyRange := True;
end;

{ Deletes an end-exclusive range and closes any removed lines. }
function TTextBuffer.DeleteRange(StartLine, StartColumn, EndLine, EndColumn: Word;
  var ErrorText: String): Boolean;
var
  I, RemoveCount, OldCount, OldLength, SuffixLength: Word;
  PrefixText, SuffixText: TEditorLine;
  NewFonts: TFontStyleLine;
begin
  DeleteRange := False;
  if not ValidateRange(Self, StartLine, StartColumn, EndLine, EndColumn,
                       True, ErrorText) then
    Exit;

  if StartLine = EndLine then
  begin
    OldLength := Length(EditLinePtr(StartLine)^);
    I := StartColumn;
    while I + (EndColumn - StartColumn) < OldLength do
    begin
      SetFontFamily(EditFontPtr(StartLine)^, I,
        GetFontFamily(EditFontPtr(StartLine)^, I + EndColumn - StartColumn));
      Inc(I);
    end;
    while I < OldLength do
    begin
      SetFontFamily(EditFontPtr(StartLine)^, I, TypingFont);
      Inc(I);
    end;
    Delete(EditLinePtr(StartLine)^, StartColumn + 1, EndColumn - StartColumn);
  end
  else
  begin
    PrefixText := Copy(EditLinePtr(StartLine)^, 1, StartColumn);
    SuffixText := Copy(EditLinePtr(EndLine)^, EndColumn + 1, MaxLineLength);
    if Length(PrefixText) + Length(SuffixText) > MaxLineLength then
    begin
      ErrorText := 'Deleting this selection would create an overlong line.';
      Exit;
    end;

    ClearFontStyleLine(NewFonts, TypingFont);
    CopyFontFamilies(EditFontPtr(StartLine)^, 0, StartColumn, NewFonts, 0);
    SuffixLength := Length(SuffixText);
    CopyFontFamilies(EditFontPtr(EndLine)^, EndColumn, SuffixLength,
      NewFonts, StartColumn);
    EditLinePtr(StartLine)^ := PrefixText + SuffixText;
    EditFontPtr(StartLine)^ := NewFonts;

    RemoveCount := EndLine - StartLine;
    OldCount := Count;
    if EndLine + 1 < OldCount then
      for I := EndLine + 1 to OldCount - 1 do
      begin
        EditLinePtr(I - RemoveCount)^ := EditLinePtr(I)^;
        EditFontPtr(I - RemoveCount)^ := EditFontPtr(I)^;
      end;
    Count := OldCount - RemoveCount;
    if Count < OldCount then
      for I := Count to OldCount - 1 do
      begin
        EditLinePtr(I)^ := '';
        ClearFontStyleLine(EditFontPtr(I)^, TypingFont);
      end;
  end;

  Dirty := True;
  ErrorText := '';
  DeleteRange := True;
end;


{ Replaces one in-line match and returns the new caret column. }
function TTextBuffer.ReplaceTextAt(LineIndex, Column, MatchLength: Word;
  const Replacement: String; var NewColumn: Word;
  var ErrorText: String): Boolean;
var
  PrefixText, SuffixText: TEditorLine;
  NewFonts: TFontStyleLine;
  I, SuffixLength: Word;
  ReplacementFont: TFontFamily;
begin
  ErrorText := '';
  ReplaceTextAt := False;

  if LineIndex >= Count then
  begin
    ErrorText := 'The match is outside the document.';
    Exit;
  end;
  if (Column > Length(EditLinePtr(LineIndex)^)) or
     (Column + MatchLength > Length(EditLinePtr(LineIndex)^)) then
  begin
    ErrorText := 'The match is outside the current line.';
    Exit;
  end;

  PrefixText := Copy(EditLinePtr(LineIndex)^, 1, Column);
  SuffixText := Copy(EditLinePtr(LineIndex)^, Column + MatchLength + 1,
    MaxLineLength);
  if Length(PrefixText) + Length(Replacement) + Length(SuffixText) >
     MaxLineLength then
  begin
    ErrorText := 'The replacement would create an overlong line.';
    Exit;
  end;

  if (MatchLength > 0) and (Column < Length(EditLinePtr(LineIndex)^)) then
    ReplacementFont := GetFontFamily(EditFontPtr(LineIndex)^, Column)
  else
    ReplacementFont := TypingFont;

  ClearFontStyleLine(NewFonts, TypingFont);
  CopyFontFamilies(EditFontPtr(LineIndex)^, 0, Column, NewFonts, 0);
  if Length(Replacement) > 0 then
    for I := 0 to Length(Replacement) - 1 do
      SetFontFamily(NewFonts, Column + I, ReplacementFont);
  SuffixLength := Length(SuffixText);
  CopyFontFamilies(EditFontPtr(LineIndex)^, Column + MatchLength, SuffixLength,
    NewFonts, Column + Length(Replacement));

  EditLinePtr(LineIndex)^ := PrefixText + Replacement + SuffixText;
  EditFontPtr(LineIndex)^ := NewFonts;
  NewColumn := Column + Length(Replacement);
  Dirty := True;
  ReplaceTextAt := True;
end;

end.
