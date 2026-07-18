program Edit98;

{ Main EDIT98 application module.  It owns editor state, paints the user
  interface, runs menus and dialogs, translates keyboard and mouse events,
  coordinates file commands, delegates checked text mutations to EditorBuf,
  and delegates RTF interchange to RTFCodec.  Document text, menus, dialogs,
  page-break markers, selections, and the caret all use the native PC-98 text
  ROM. }

{$mode objfpc}
{$H-}
{$R+}
{$Q+}
{$S+}
{ Stack, minimum heap, MAXIMUM heap.  The third value is the critical one:
  Free Pascal's i8086-msdos large-model default for the maximum heap is 640 KB,
  which the internal linker converts into an MZ header "max paragraphs" value
  of $FFFF.  DOS then hands EDIT98 every free paragraph of conventional memory
  at load time, so the later EXEC of MOUSE.COM fails with DOS error 8 (not
  enough memory) and automatic driver startup silently does nothing.
  Version 0.7.13 keeps the minimum heap below one 16-bit data element while
  capping the maximum heap at 128 KB: enough for the three-page document cache,
  viewport state, and clipboard, but still far below the 640 KB default so the
  resident mouse driver and DOS retain ample conventional memory. }
{$M 16384, 32768, 131072}

uses
  Dos, PC98Screen, PC98Kbd, PC98Mouse, PC98Fonts, EditorBuf, RTFCodec,
  PrintDoc;

const
  EditLeft   = 1;
  EditTop    = 2;
  EditWidth  = 77;
  EditHeight = 21;

  MaxPopupItems = 8;

  MouseSpeedSlow   = 0;
  MouseSpeedNormal = 1;
  MouseSpeedFast   = 2;

  SchemePC98       = 0;
  SchemeDOSEdit    = 1;
  SchemeAmber      = 2;
  SchemeGreen      = 3;
  SchemeMonochrome = 4;
  ColorSchemeCount = 5;

  MaxBrowserEntries = 96;
  BrowserVisibleRows = 12;

  BrowserFocusDrives = 0;
  BrowserFocusList   = 1;
  BrowserFocusName   = 2;

  HelpPageCount       = 10;
  HelpVisibleLines    = 14;

  HundredthsPerMinute       = 6000;
  BrowserDoubleClickInterval = 50;  { half a second }

  PageBreakMarker =
    '------------------------------- Page Break -------------------------------';
  DefaultPrinterDevice = 'PRN';
  MaximumLogicalPages = 65536;

  PaperTemplateDocument = 0;
  PaperTemplateA4 = 1;
  PaperTemplateLetter = 2;
  PaperTemplateFirstCustom = 3;
  CustomPaperTemplateCount = 4;
  PaperTemplateLastCustom = PaperTemplateFirstCustom + CustomPaperTemplateCount - 1;
  { Keep Custom 1-4 at their historical numeric IDs (3-6) so existing
    EDIT98.CFG files remain compatible. The predefined formats added in
    0.7.10 therefore use IDs after the custom block. }
  PaperTemplateLegal = 7;
  PaperTemplateTabloid = 8;
  PaperTemplateCount = 9;
  DefaultPaperTemplate = PaperTemplateA4;

  PrintOrientationPortrait = 0;
  PrintOrientationLandscape = 1;
  PrintOrientationCount = 2;
  DefaultPrintOrientation = PrintOrientationPortrait;

type
  TPopupLabels = array[0..MaxPopupItems - 1] of String[32];
  { One-based character positions identify the underlined access key in each
    menu label.  Zero means that an item has no accelerator. }
  TPopupAccelerators = array[0..MaxPopupItems - 1] of Byte;

  TBrowserEntry = record
    Name: String[12];
    IsDirectory: Boolean;
  end;

  TBrowserEntries = array[0..MaxBrowserEntries - 1] of TBrowserEntry;

  { Stores the zero-based DOS drive numbers that actually accept selection. }
  TDriveList = array[0..25] of Byte;

  THelpLine = String[72];
  THelpLines = array[0..HelpVisibleLines - 1] of THelpLine;

  { The viewport cache stores only the native text-ROM cells currently
    visible.  Logical RTF font families remain in EditorBuf for round-trip
    saving, but they never affect on-screen glyph selection. }
  TViewportCell = packed record
    Ch: Char;
    Attr: Byte;
    BackdropColor: Byte;
  end;
  TViewportCache = array[0..EditHeight - 1, 0..EditWidth - 1] of
    TViewportCell;

  { Keeps the genuinely large fixed objects outside DGROUP. Each allocation remains below
    one 64 KB real-mode segment, while their combined storage is supplied by
    the bounded far heap. }
  PTextBuffer = ^TTextBuffer;
  PTextClipboard = ^TTextClipboard;

var
  Buffer: PTextBuffer;
  Clipboard: PTextClipboard;
  ViewportCache: TViewportCache;
  ViewportCacheValid: Boolean;
  CachedTopLine, CachedLeftColumn: Word;

  { Scratch context for resolving one viewport row.  These values are global on
    purpose: FPC 3.2.2's i8086 register allocator can exhaust its spill passes
    when the resolver is a nested procedure capturing many outer locals.  The
    editor is single-threaded, so a shared row context is safe and keeps each
    generated procedure small enough for the 8086 backend. }
  ViewportRowLineIndex, ViewportRowLineLength: Word;
  ViewportRowCurrentLine: PEditorLine;
  ViewportHasSelection: Boolean;
  ViewportSelectionStartLine, ViewportSelectionStartColumn: Word;
  ViewportSelectionEndLine, ViewportSelectionEndColumn: Word;

  CurrentFile: String[127];
  SettingsPath: String[127];
  CursorLine, CursorColumn: Word;
  TopLine, LeftColumn: Word;
  SelectionActive: Boolean;
  SelectionAnchorLine, SelectionAnchorColumn: Word;
  Running, NeedsRedraw: Boolean;
  MenuAcceleratorsVisible: Boolean;
  MouseReady, MouseSelecting: Boolean;
  PreviousButtons: Word;
  PreviousShiftState: Byte;
  CaretVisible: Boolean;
  LastCaretClock: Word;
  GraphicsBackdropDirty: Boolean;

  LastFind: String[127];
  LastReplace: String[127];
  MatchCase: Boolean;

  TabWidth: Byte;
  InsertMode: Boolean;
  AutoIndent: Boolean;
  MouseSpeedSetting: Byte;
  ColorScheme: Byte;
  ShowPageBreaks: Boolean;
  PrintMarginTopTenthsCm, PrintMarginBottomTenthsCm: Byte;
  PrintMarginLeftTenthsCm, PrintMarginRightTenthsCm: Byte;
  PrintPaperTemplate: Byte;
  PrintOrientation: Byte;
  CustomPaperWidthTenthsCm: array[0..CustomPaperTemplateCount - 1] of Word;
  CustomPaperHeightTenthsCm: array[0..CustomPaperTemplateCount - 1] of Word;

  { Small shared state for the print-options dialog. Margin strings are kept
    global to avoid register pressure in FPC 3.2.2's i8086 backend. }
  PrintOptionsTopText, PrintOptionsBottomText: String[4];
  PrintOptionsLeftText, PrintOptionsRightText: String[4];
  PrintOptionsErrorLine: String[54];
  PrintOptionsActiveField: Byte;
  PrintOptionsReplaceOnType: Boolean;
  PrintOptionsRangeMode: Boolean;
  PrintOptionsPaperTemplate: Byte;
  PrintOptionsOrientation: Byte;

  { Shared state for the custom-paper editor. Custom slots use fixed labels
    Custom 1 through Custom 4 and persist their width/height in EDIT98.CFG. }
  CustomPaperWidthText, CustomPaperHeightText: String[5];
  CustomPaperErrorLine: String[52];
  CustomPaperActiveField, CustomPaperEditSlot: Byte;
  CustomPaperReplaceOnType: Boolean;

  { Small shared state for the simultaneous print-range dialog. Keeping these
    strings outside the event-loop procedure reduces register pressure on FPC
    3.2.2's i8086 backend, which is sensitive to large modal procedures. }
  PrintRangeFromText, PrintRangeToText: String[5];
  PrintRangeErrorLine: String[46];
  PrintRangeActiveField: Byte;
  PrintRangeReplaceOnType: Boolean;

  { Resolved attributes for the active scheme.  Drawing code reads these
    values instead of embedding colors, so dialogs and menus change together. }
  UiMenuAttr, UiTextAttr, UiFrameAttr, UiTitleAttr: Byte;
  UiStatusAttr, UiPopupAttr, UiPopupSelectedAttr: Byte;
  UiShadowAttr: Byte;
  UiScrollTrackAttr, UiScrollThumbAttr, UiScrollButtonAttr: Byte;

  { Native text attributes and the graphics color beneath their transparent
    glyph pixels.  This preserves the MS-DOS Edit blue field while using the
    exact same PC-98 ROM font as the menu bar. }
  DocTextAttr, DocSelectionAttr, DocCaretAttr: Byte;
  DocTextBackdrop, DocSelectionBackdrop, DocCaretBackdrop: Byte;

{ Returns the final filename component of a DOS path. }
function BaseName(const Path: String): String;
var
  I, StartAt: Byte;
begin
  StartAt := 1;
  for I := 1 to Length(Path) do
    if (Path[I] = '\') or (Path[I] = '/') or (Path[I] = ':') then
      StartAt := I + 1;
  BaseName := Copy(Path, StartAt, 255);
end;

{ Cancels selection state and moves the selection anchor to the caret. }
procedure ClearSelection;
begin
  SelectionActive := False;
  SelectionAnchorLine := CursorLine;
  SelectionAnchorColumn := CursorColumn;
end;

{ Normalizes the anchor and caret into ordered, end-exclusive selection bounds. }
procedure GetSelectionBounds(var StartLine, StartColumn,
  EndLine, EndColumn: Word);
begin
  if (SelectionAnchorLine < CursorLine) or
     ((SelectionAnchorLine = CursorLine) and
      (SelectionAnchorColumn < CursorColumn)) then
  begin
    StartLine := SelectionAnchorLine;
    StartColumn := SelectionAnchorColumn;
    EndLine := CursorLine;
    EndColumn := CursorColumn;
  end
  else
  begin
    StartLine := CursorLine;
    StartColumn := CursorColumn;
    EndLine := SelectionAnchorLine;
    EndColumn := SelectionAnchorColumn;
  end;
end;

{ Synchronizes future typing with the font run at the current caret. }
procedure SyncTypingFontToCaret;
begin
  if not SelectionActive then
    Buffer^.TypingFont := Buffer^.InsertionFontAt(CursorLine, CursorColumn);
end;


{ Reports whether a document cell lies inside the active selection. }
function CellIsSelected(LineIndex, Column: Word): Boolean;
var
  StartLine, StartColumn, EndLine, EndColumn: Word;
begin
  CellIsSelected := False;
  if not SelectionActive then
    Exit;

  GetSelectionBounds(StartLine, StartColumn, EndLine, EndColumn);
  if (LineIndex < StartLine) or (LineIndex > EndLine) then
    Exit;

  if StartLine = EndLine then
    CellIsSelected := (Column >= StartColumn) and (Column < EndColumn)
  else if LineIndex = StartLine then
    CellIsSelected := (Column >= StartColumn) and
      (Column <= Length(Buffer^.LinePtr(LineIndex)^))
  else if LineIndex = EndLine then
    CellIsSelected := Column < EndColumn
  else
    CellIsSelected := Column <= Length(Buffer^.LinePtr(LineIndex)^);
end;


{ Discards only the rendered viewport description.  The document remains in
  EditorBuf's three-page disk-backed cache; off-screen pages are not loaded
  merely because the display cache is invalidated. }
procedure InvalidateViewportCache;
begin
  ViewportCacheValid := False;
end;

{ Finds and directly executes a DOS mouse TSR when no driver is resident. }
function StartMouseDriver: Boolean;
var
  MouseProgram: PathStr;
  SearchPath: String;
  LaunchError: Integer;
begin
  { Launch the TSR itself rather than starting a secondary COMMAND.COM.  Some
    PC-98 DOS configurations unload a resident program together with that
    temporary shell, while direct EXEC leaves MOUSE.COM resident as intended. }
  SearchPath := '.;' + GetEnv('PATH');
  MouseProgram := FSearch('MOUSE.COM', SearchPath);
  if MouseProgram = '' then
    MouseProgram := FSearch('MOUSE.EXE', SearchPath);
  if MouseProgram = '' then
  begin
    StartMouseDriver := False;
    Exit;
  end;

  { The three-value program-level $M directive caps EDIT98's maximum heap, so
    the MZ header only requests the memory the editor actually uses and DOS
    keeps the rest of conventional memory free for the child TSR.  SwapVectors
    protects Pascal's interrupt handlers while the TSR owns the machine during
    installation. }
  SwapVectors;
  Exec(MouseProgram, '');
  LaunchError := DosError;
  SwapVectors;
  StartMouseDriver := LaunchError = 0;
end;

{ Applies the selected mouse movement ratio to the resident driver. }
procedure ApplyMouseSpeed;
begin
  if not MouseReady then
    Exit;

  { INT 33h function 0Fh uses mickeys per eight pixels.  Smaller values make
    the pointer travel farther for the same physical movement. }
  case MouseSpeedSetting of
    MouseSpeedSlow: SetMouseSpeed(12, 24);
    MouseSpeedNormal: SetMouseSpeed(8, 16);
    MouseSpeedFast: SetMouseSpeed(4, 8);
  end;
end;

{ Resolves the selected theme into semantic UI and document attributes. }
procedure ApplyColorScheme;
begin
  { PC-98 text cells select one color and can reverse it into the background.
    The MS-DOS Edit theme keeps a solid blue graphics backdrop beneath normal
    white text-ROM glyphs.  Reverse-video selections and the caret use a black
    graphics cell underneath so their transparent glyph pixels remain dark. }
  case ColorScheme of
    SchemeDOSEdit:
      begin
        UiMenuAttr := AttrWhiteRev;
        UiTextAttr := AttrWhite;
        UiFrameAttr := AttrWhiteRev;
        UiTitleAttr := AttrWhiteRev;
        UiStatusAttr := AttrCyanRev;
        UiPopupAttr := AttrWhiteRev;
        UiPopupSelectedAttr := AttrCyanRev;
        UiShadowAttr := AttrBlack;
        UiScrollTrackAttr := AttrBlueRev;
        UiScrollThumbAttr := AttrWhiteRev;
        UiScrollButtonAttr := AttrWhiteRev;
        DocTextAttr := AttrWhite;
        DocSelectionAttr := AttrYellowRev;
        DocCaretAttr := AttrCyanRev;
        DocTextBackdrop := GraphicsBlue;
        DocSelectionBackdrop := GraphicsBlack;
        DocCaretBackdrop := GraphicsBlack;
      end;
    SchemeAmber:
      begin
        UiMenuAttr := AttrYellowRev;
        UiTextAttr := AttrYellow;
        UiFrameAttr := AttrYellow;
        UiTitleAttr := AttrYellow;
        UiStatusAttr := AttrYellowRev;
        UiPopupAttr := AttrYellow;
        UiPopupSelectedAttr := AttrYellowRev;
        UiShadowAttr := AttrBlack;
        UiScrollTrackAttr := AttrYellow;
        UiScrollThumbAttr := AttrYellowRev;
        UiScrollButtonAttr := AttrYellowRev;
        DocTextAttr := AttrYellow;
        DocSelectionAttr := AttrYellowRev;
        DocCaretAttr := AttrWhiteRev;
        DocTextBackdrop := GraphicsBlack;
        DocSelectionBackdrop := GraphicsBlack;
        DocCaretBackdrop := GraphicsBlack;
      end;
    SchemeGreen:
      begin
        UiMenuAttr := AttrGreenRev;
        UiTextAttr := AttrGreen;
        UiFrameAttr := AttrGreen;
        UiTitleAttr := AttrGreen;
        UiStatusAttr := AttrGreenRev;
        UiPopupAttr := AttrGreen;
        UiPopupSelectedAttr := AttrGreenRev;
        UiShadowAttr := AttrBlack;
        UiScrollTrackAttr := AttrGreen;
        UiScrollThumbAttr := AttrGreenRev;
        UiScrollButtonAttr := AttrGreenRev;
        DocTextAttr := AttrGreen;
        DocSelectionAttr := AttrGreenRev;
        DocCaretAttr := AttrWhiteRev;
        DocTextBackdrop := GraphicsBlack;
        DocSelectionBackdrop := GraphicsBlack;
        DocCaretBackdrop := GraphicsBlack;
      end;
    SchemeMonochrome:
      begin
        UiMenuAttr := AttrWhiteRev;
        UiTextAttr := AttrWhite;
        UiFrameAttr := AttrWhite;
        UiTitleAttr := AttrWhite;
        UiStatusAttr := AttrWhiteRev;
        UiPopupAttr := AttrWhite;
        UiPopupSelectedAttr := AttrWhiteRev;
        UiShadowAttr := AttrBlack;
        UiScrollTrackAttr := AttrWhite;
        UiScrollThumbAttr := AttrWhiteRev;
        UiScrollButtonAttr := AttrWhiteRev;
        DocTextAttr := AttrWhite;
        DocSelectionAttr := AttrWhiteRev;
        DocCaretAttr := AttrWhiteRev;
        DocTextBackdrop := GraphicsBlack;
        DocSelectionBackdrop := GraphicsBlack;
        DocCaretBackdrop := GraphicsBlack;
      end;
    else
      begin
        UiMenuAttr := AttrWhiteRev;
        UiTextAttr := AttrWhite;
        UiFrameAttr := AttrCyan;
        UiTitleAttr := AttrCyan;
        UiStatusAttr := AttrWhiteRev;
        UiPopupAttr := AttrWhite;
        UiPopupSelectedAttr := AttrWhiteRev;
        UiShadowAttr := AttrBlack;
        UiScrollTrackAttr := AttrCyan;
        UiScrollThumbAttr := AttrWhiteRev;
        UiScrollButtonAttr := AttrWhiteRev;
        DocTextAttr := AttrWhite;
        DocSelectionAttr := AttrWhiteRev;
        DocCaretAttr := AttrCyanRev;
        DocTextBackdrop := GraphicsBlack;
        DocSelectionBackdrop := GraphicsBlack;
        DocCaretBackdrop := GraphicsBlack;
      end;
  end;

  SetGraphicsBackdrop(ColorScheme = SchemeDOSEdit);
  GraphicsBackdropDirty := False;
  SetMouseCursorAppearance(MouseArrow, AttrWhite);
  InvalidateViewportCache;
end;

{ Clears graphics pixels beneath a rectangular opaque text surface. }
procedure PrepareOpaqueBackdrop(X1, Y1, X2, Y2: Byte);
begin
  { Document backdrops must never show through a popup.  Clear the covered
    pixels for every color scheme, not only the blue DOS theme. }
  FillGraphicsCellRect(X1, Y1, X2, Y2, GraphicsBlack);
end;

{ Prepares dark-gray and black graphics pixels beneath a beveled frame. }
procedure PrepareShadedFrameBackdrop(X1, Y1, X2, Y2: Byte);
begin
  if ColorScheme = SchemeDOSEdit then
    ShadeGraphicsFrame(X1, Y1, X2, Y2);
end;

{ Draws a filled, shaded, framed window with its drop shadow. }
procedure DrawWindowSurface(X1, Y1, X2, Y2: Byte);
begin
  { Reverse-video glyphs expose the graphics plane.  Clear the window area so
    labels are genuinely black, then give the pale frame a gray/black bevel. }
  PrepareOpaqueBackdrop(X1, Y1, X2, Y2);
  PrepareShadedFrameBackdrop(X1, Y1, X2, Y2);
  GraphicsBackdropDirty := True;

  { Shadows are painted first so the window itself remains crisp and the shadow
    never overwrites its lower or right border. }
  DrawDropShadow(X1, Y1, X2, Y2, UiShadowAttr);
  FillRect(X1, Y1, X2, Y2, ' ', UiPopupAttr);
  DrawFrame(X1, Y1, X2, Y2, UiFrameAttr);
end;

{ Draws the document scroll arrows, track, and proportional thumb. }
procedure DrawVerticalScrollBar;
const
  ScrollColumn = 78;
  TrackTop = 3;
  TrackBottom = 21;
  TrackHeight = TrackBottom - TrackTop + 1;
var
  Row, ThumbTop, ThumbSize, MaximumTopLine, AvailableTravel: Word;
begin
  { The original DOS Editor uses separate arrow buttons and a proportional
    thumb.  TopLine, rather than CursorLine, determines the thumb position so
    the bar represents the visible document window. }
  PutCell(ScrollColumn, 2, ScrollArrowUp, UiScrollButtonAttr);
  PutCell(ScrollColumn, 22, ScrollArrowDown, UiScrollButtonAttr);
  for Row := TrackTop to TrackBottom do
    PutCell(ScrollColumn, Row, ' ', UiScrollTrackAttr);

  if Buffer^.Count <= EditHeight then
  begin
    ThumbSize := TrackHeight;
    ThumbTop := TrackTop;
  end
  else
  begin
    ThumbSize := Word((LongInt(EditHeight) * TrackHeight) div Buffer^.Count);
    if ThumbSize = 0 then
      ThumbSize := 1;

    MaximumTopLine := Buffer^.Count - EditHeight;
    AvailableTravel := TrackHeight - ThumbSize;
    if TopLine > MaximumTopLine then
      ThumbTop := TrackTop + AvailableTravel
    else
      ThumbTop := TrackTop +
        Word((LongInt(TopLine) * AvailableTravel) div MaximumTopLine);
  end;

  for Row := ThumbTop to ThumbTop + ThumbSize - 1 do
    PutCell(ScrollColumn, Row, ' ', UiScrollThumbAttr);
end;

{ Converts an ASCII lowercase letter to uppercase without locale services. }
function UpperAscii(C: Char): Char;
begin
  if (C >= 'a') and (C <= 'z') then
    UpperAscii := Chr(Ord(C) - Ord('a') + Ord('A'))
  else
    UpperAscii := C;
end;


{ Returns an uppercase copy suitable for configuration keys. }
function UpperAsciiText(const TextValue: String): String;
var
  I: Byte;
begin
  UpperAsciiText := TextValue;
  for I := 1 to Length(UpperAsciiText) do
    UpperAsciiText[I] := UpperAscii(UpperAsciiText[I]);
end;

{ Locates EDIT98.CFG beside the executable when DOS supplies a path. }
function SettingsFileName: String;
var
  ProgramPath: String;
  I, LastSeparator: Integer;
begin
  ProgramPath := ParamStr(0);
  LastSeparator := 0;
  for I := 1 to Length(ProgramPath) do
    if (ProgramPath[I] = '\') or (ProgramPath[I] = '/') or
       (ProgramPath[I] = ':') then
      LastSeparator := I;
  if LastSeparator > 0 then
    SettingsFileName := Copy(ProgramPath, 1, LastSeparator) + 'EDIT98.CFG'
  else
    SettingsFileName := 'EDIT98.CFG';
end;

{ Parses one nonnegative decimal value without SysUtils or exceptions. }
function ParseSettingNumber(const TextValue: String;
  var NumberValue: Word): Boolean;
var
  I: Byte;
  Value: LongInt;
begin
  ParseSettingNumber := False;
  if TextValue = '' then
    Exit;
  Value := 0;
  for I := 1 to Length(TextValue) do
  begin
    if (TextValue[I] < '0') or (TextValue[I] > '9') then
      Exit;
    Value := Value * 10 + Ord(TextValue[I]) - Ord('0');
    if Value > 65535 then
      Exit;
  end;
  NumberValue := Word(Value);
  ParseSettingNumber := True;
end;

{ Loads persistent options from EDIT98.CFG, ignoring unknown or invalid lines. }
procedure LoadSettings;
var
  F: Text;
  LineText, KeyText, ValueText: String;
  EqualAt, Code: Integer;
  NumberValue: Word;
begin
  Assign(F, SettingsPath);
  {$I-}
  Reset(F);
  Code := IOResult;
  {$I+}
  if Code <> 0 then
    Exit;

  {$I-}
  while not EOF(F) do
  begin
    ReadLn(F, LineText);
    EqualAt := Pos('=', LineText);
    if EqualAt > 1 then
    begin
      KeyText := UpperAsciiText(Copy(LineText, 1, EqualAt - 1));
      ValueText := Copy(LineText, EqualAt + 1, 255);
      if ParseSettingNumber(ValueText, NumberValue) then
      begin
        if (KeyText = 'TABWIDTH') and
           ((NumberValue = 2) or (NumberValue = 4) or
            (NumberValue = 8)) then
          TabWidth := Byte(NumberValue)
        else if KeyText = 'INSERTMODE' then
          InsertMode := NumberValue <> 0
        else if KeyText = 'AUTOINDENT' then
          AutoIndent := NumberValue <> 0
        else if (KeyText = 'MOUSESPEED') and
                (NumberValue <= MouseSpeedFast) then
          MouseSpeedSetting := Byte(NumberValue)
        else if (KeyText = 'COLORSCHEME') and
                (NumberValue < ColorSchemeCount) then
          ColorScheme := Byte(NumberValue)
        else if KeyText = 'SHOWPAGEBREAKS' then
          ShowPageBreaks := NumberValue <> 0
        else if KeyText = 'MATCHCASE' then
          MatchCase := NumberValue <> 0
        else if (KeyText = 'PRINTMARGINTOP') and
                (NumberValue <= MaximumPrintMarginTenthsCm) then
          PrintMarginTopTenthsCm := Byte(NumberValue)
        else if (KeyText = 'PRINTMARGINBOTTOM') and
                (NumberValue <= MaximumPrintMarginTenthsCm) then
          PrintMarginBottomTenthsCm := Byte(NumberValue)
        else if (KeyText = 'PRINTMARGINLEFT') and
                (NumberValue <= MaximumPrintMarginTenthsCm) then
          PrintMarginLeftTenthsCm := Byte(NumberValue)
        else if (KeyText = 'PRINTMARGINRIGHT') and
                (NumberValue <= MaximumPrintMarginTenthsCm) then
          PrintMarginRightTenthsCm := Byte(NumberValue)
        else if (KeyText = 'PRINTPAPER') and
                (NumberValue < PaperTemplateCount) then
          PrintPaperTemplate := Byte(NumberValue)
        else if (KeyText = 'PRINTORIENTATION') and
                (NumberValue < PrintOrientationCount) then
          PrintOrientation := Byte(NumberValue)
        else if (KeyText = 'CUSTOMPAPER1WIDTH') and
                (NumberValue <= MaximumPaperDimensionTenthsCm) then
          CustomPaperWidthTenthsCm[0] := NumberValue
        else if (KeyText = 'CUSTOMPAPER1HEIGHT') and
                (NumberValue <= MaximumPaperDimensionTenthsCm) then
          CustomPaperHeightTenthsCm[0] := NumberValue
        else if (KeyText = 'CUSTOMPAPER2WIDTH') and
                (NumberValue <= MaximumPaperDimensionTenthsCm) then
          CustomPaperWidthTenthsCm[1] := NumberValue
        else if (KeyText = 'CUSTOMPAPER2HEIGHT') and
                (NumberValue <= MaximumPaperDimensionTenthsCm) then
          CustomPaperHeightTenthsCm[1] := NumberValue
        else if (KeyText = 'CUSTOMPAPER3WIDTH') and
                (NumberValue <= MaximumPaperDimensionTenthsCm) then
          CustomPaperWidthTenthsCm[2] := NumberValue
        else if (KeyText = 'CUSTOMPAPER3HEIGHT') and
                (NumberValue <= MaximumPaperDimensionTenthsCm) then
          CustomPaperHeightTenthsCm[2] := NumberValue
        else if (KeyText = 'CUSTOMPAPER4WIDTH') and
                (NumberValue <= MaximumPaperDimensionTenthsCm) then
          CustomPaperWidthTenthsCm[3] := NumberValue
        else if (KeyText = 'CUSTOMPAPER4HEIGHT') and
                (NumberValue <= MaximumPaperDimensionTenthsCm) then
          CustomPaperHeightTenthsCm[3] := NumberValue;
      end;
    end;
  end;
  System.Close(F);
  IOResult;
  {$I+}
end;

{ Writes all user-facing persistent options to EDIT98.CFG. }
procedure SaveSettings;
var
  F: Text;
  Code: Integer;
begin
  Assign(F, SettingsPath);
  {$I-}
  Rewrite(F);
  Code := IOResult;
  if Code = 0 then
  begin
    WriteLn(F, 'EDIT98CFG=2');
    WriteLn(F, 'TABWIDTH=', TabWidth);
    WriteLn(F, 'INSERTMODE=', Ord(InsertMode));
    WriteLn(F, 'AUTOINDENT=', Ord(AutoIndent));
    WriteLn(F, 'MOUSESPEED=', MouseSpeedSetting);
    WriteLn(F, 'COLORSCHEME=', ColorScheme);
    WriteLn(F, 'SHOWPAGEBREAKS=', Ord(ShowPageBreaks));
    WriteLn(F, 'MATCHCASE=', Ord(MatchCase));
    WriteLn(F, 'PRINTMARGINTOP=', PrintMarginTopTenthsCm);
    WriteLn(F, 'PRINTMARGINBOTTOM=', PrintMarginBottomTenthsCm);
    WriteLn(F, 'PRINTMARGINLEFT=', PrintMarginLeftTenthsCm);
    WriteLn(F, 'PRINTMARGINRIGHT=', PrintMarginRightTenthsCm);
    WriteLn(F, 'PRINTPAPER=', PrintPaperTemplate);
    WriteLn(F, 'PRINTORIENTATION=', PrintOrientation);
    WriteLn(F, 'CUSTOMPAPER1WIDTH=', CustomPaperWidthTenthsCm[0]);
    WriteLn(F, 'CUSTOMPAPER1HEIGHT=', CustomPaperHeightTenthsCm[0]);
    WriteLn(F, 'CUSTOMPAPER2WIDTH=', CustomPaperWidthTenthsCm[1]);
    WriteLn(F, 'CUSTOMPAPER2HEIGHT=', CustomPaperHeightTenthsCm[1]);
    WriteLn(F, 'CUSTOMPAPER3WIDTH=', CustomPaperWidthTenthsCm[2]);
    WriteLn(F, 'CUSTOMPAPER3HEIGHT=', CustomPaperHeightTenthsCm[2]);
    WriteLn(F, 'CUSTOMPAPER4WIDTH=', CustomPaperWidthTenthsCm[3]);
    WriteLn(F, 'CUSTOMPAPER4HEIGHT=', CustomPaperHeightTenthsCm[3]);
    System.Close(F);
    IOResult;
  end;
  {$I+}
end;

{ Derives a stable uppercase letter from a PC-98 key event and scan code. }
function KeyLetter(const K: TKeyEvent): Char;
begin
  { The physical scan code is authoritative.  GRPH, XFER and NFER can alter
    the translated JIS byte, but the scan code still identifies the letter. }
  case K.ScanCode of
    ScanQ: KeyLetter := 'Q';
    ScanW: KeyLetter := 'W';
    ScanE: KeyLetter := 'E';
    ScanR: KeyLetter := 'R';
    ScanT: KeyLetter := 'T';
    ScanY: KeyLetter := 'Y';
    ScanU: KeyLetter := 'U';
    ScanI: KeyLetter := 'I';
    ScanO: KeyLetter := 'O';
    ScanP: KeyLetter := 'P';
    ScanA: KeyLetter := 'A';
    ScanS: KeyLetter := 'S';
    ScanD: KeyLetter := 'D';
    ScanF: KeyLetter := 'F';
    ScanG: KeyLetter := 'G';
    ScanH: KeyLetter := 'H';
    ScanJ: KeyLetter := 'J';
    ScanK: KeyLetter := 'K';
    ScanL: KeyLetter := 'L';
    ScanZ: KeyLetter := 'Z';
    ScanX: KeyLetter := 'X';
    ScanC: KeyLetter := 'C';
    ScanV: KeyLetter := 'V';
    ScanB: KeyLetter := 'B';
    ScanN: KeyLetter := 'N';
    ScanM: KeyLetter := 'M';
    else
      if (K.AsciiCode >= Ord('a')) and (K.AsciiCode <= Ord('z')) then
        KeyLetter := Chr(K.AsciiCode - Ord('a') + Ord('A'))
      else if (K.AsciiCode >= Ord('A')) and (K.AsciiCode <= Ord('Z')) then
        KeyLetter := Chr(K.AsciiCode)
      else
        KeyLetter := #0;
  end;
end;

{ Paints the top menu bar, conditional access-key marks, and optional
  whole-label selection used only while a popup is open. }
procedure DrawTopMenuBar(SelectedMenu: Integer; ShowAccelerators,
  HighlightSelectedWord: Boolean);
var
  AcceleratorAttr: Byte;
begin
  { Reverse-video text is transparent at the glyph pixels.  A black graphics
    strip beneath the bar therefore produces actual black labels instead of
    letting the blue document backdrop show through them. }
  PrepareOpaqueBackdrop(0, 0, 79, 0);
  WriteField(0, 0, 80, ' File  Edit  Search  Options  Help', UiMenuAttr);

  { Merely pressing Alt/GRPH or F10 must not reverse an entire menu word.  A
    complete label is highlighted only after that menu is actually opened. }
  if HighlightSelectedWord then
    case SelectedMenu of
      0: WriteField(1, 0, 5, 'File ', UiPopupSelectedAttr);
      1: WriteField(7, 0, 5, 'Edit ', UiPopupSelectedAttr);
      2: WriteField(13, 0, 7, 'Search ', UiPopupSelectedAttr);
      3: WriteField(21, 0, 8, 'Options ', UiPopupSelectedAttr);
      4: WriteField(30, 0, 5, 'Help ', UiPopupSelectedAttr);
    end;

  { Match MS-DOS Edit: access letters are ordinary menu text until Alt/GRPH
    or F10 activates the bar.  In the active state, only each first letter is
    underlined and reverse-highlighted. }
  if ShowAccelerators then
  begin
    AcceleratorAttr := UiPopupSelectedAttr or AttrUnderline;
    PutCell(1, 0, 'F', AcceleratorAttr);
    PutCell(7, 0, 'E', AcceleratorAttr);
    PutCell(13, 0, 'S', AcceleratorAttr);
    PutCell(21, 0, 'O', AcceleratorAttr);
    PutCell(30, 0, 'H', AcceleratorAttr);
  end;
end;

{ Compares one cached native text cell with the newly resolved cell. }
function ViewportCellsEqual(const A, B: TViewportCell): Boolean;
begin
  ViewportCellsEqual := (A.Ch = B.Ch) and (A.Attr = B.Attr) and
    (A.BackdropColor = B.BackdropColor);
end;

{ Reports whether the current logical row is an imported page-break marker. }
function ViewportRowIsPageBreak: Boolean;
begin
  ViewportRowIsPageBreak := False;
  if ViewportRowLineIndex >= Buffer^.Count then
    Exit;
  if ViewportRowCurrentLine = nil then
    Exit;
  if ViewportRowLineLength <> 1 then
    Exit;
  ViewportRowIsPageBreak := ViewportRowCurrentLine^[1] = #12;
end;

{ Resolves one visible cell from the current row context. }
procedure ResolveViewportCell(ViewColumn: Word; var Cell: TViewportCell);
var
  DocumentColumn: Word;
  IsSelected: Boolean;
begin
  DocumentColumn := LeftColumn + ViewColumn;
  if ViewportRowIsPageBreak then
  begin
    if ShowPageBreaks and (ViewColumn < Length(PageBreakMarker)) then
      Cell.Ch := PageBreakMarker[ViewColumn + 1]
    else
      Cell.Ch := ' ';
  end
  else if (ViewportRowLineIndex < Buffer^.Count) and
          (DocumentColumn < ViewportRowLineLength) then
    Cell.Ch := ViewportRowCurrentLine^[DocumentColumn + 1]
  else
    Cell.Ch := ' ';

  IsSelected := False;
  if ViewportHasSelection and
     (ViewportRowLineIndex >= ViewportSelectionStartLine) and
     (ViewportRowLineIndex <= ViewportSelectionEndLine) then
  begin
    if ViewportSelectionStartLine = ViewportSelectionEndLine then
      IsSelected := (DocumentColumn >= ViewportSelectionStartColumn) and
        (DocumentColumn < ViewportSelectionEndColumn)
    else if ViewportRowLineIndex = ViewportSelectionStartLine then
      IsSelected := (DocumentColumn >= ViewportSelectionStartColumn) and
        (DocumentColumn <= ViewportRowLineLength)
    else if ViewportRowLineIndex = ViewportSelectionEndLine then
      IsSelected := DocumentColumn < ViewportSelectionEndColumn
    else
      IsSelected := DocumentColumn <= ViewportRowLineLength;
  end;

  if CaretVisible and (ViewportRowLineIndex = CursorLine) and
     (DocumentColumn = CursorColumn) then
  begin
    Cell.Attr := DocCaretAttr;
    Cell.BackdropColor := DocCaretBackdrop;
  end
  else if IsSelected then
  begin
    Cell.Attr := DocSelectionAttr;
    Cell.BackdropColor := DocSelectionBackdrop;
  end
  else
  begin
    Cell.Attr := DocTextAttr;
    Cell.BackdropColor := DocTextBackdrop;
  end;
end;

{ Marks every cached cell as different from any valid enabled text cell. }
procedure ResetViewportCacheBaseline;
begin
  { The screen backdrop has already been filled uniformly.  Repeating that
    backdrop byte through the packed cache gives every cell the correct known
    background while leaving an impossible control character as the redraw
    sentinel.  Native text can then be written without 16x4 graphics-plane
    writes for every ordinary character. }
  FillChar(ViewportCache, SizeOf(ViewportCache), DocTextBackdrop);
end;

{ Paints one resolved native cell and changes graphics only when required. }
procedure PaintViewportCell(CellX, CellY: Word; const Cell: TViewportCell;
  PreviousBackdrop: Byte);
begin
  if PreviousBackdrop <> Cell.BackdropColor then
    FillGraphicsCellRect(CellX, CellY, CellX, CellY, Cell.BackdropColor);
  PutCell(CellX, CellY, Cell.Ch, Cell.Attr);
end;

{ Clears a consecutive run of changed blank native text cells. }
procedure RenderViewportBlankRun(Row: Word; var Column: Word;
  var DesiredCell: TViewportCell);
var
  RunStart: Word;
  RunAttr, RunBackdrop: Byte;
  CellChanged, BackdropChanged: Boolean;
begin
  RunStart := Column;
  RunAttr := DesiredCell.Attr;
  RunBackdrop := DesiredCell.BackdropColor;
  BackdropChanged := False;
  repeat
    if ViewportCache[Row, Column].BackdropColor <> RunBackdrop then
      BackdropChanged := True;
    ViewportCache[Row, Column] := DesiredCell;
    Inc(Column);
    if Column < EditWidth then
    begin
      ResolveViewportCell(Column, DesiredCell);
      CellChanged := not ViewportCellsEqual(
        ViewportCache[Row, Column], DesiredCell);
    end
    else
      CellChanged := False;
  until (Column >= EditWidth) or (not CellChanged) or
    (DesiredCell.Ch <> ' ') or (DesiredCell.Attr <> RunAttr) or
    (DesiredCell.BackdropColor <> RunBackdrop);

  if BackdropChanged then
    FillGraphicsCellRect(EditLeft + RunStart, EditTop + Row,
      EditLeft + Column - 1, EditTop + Row, RunBackdrop);
  FillRect(EditLeft + RunStart, EditTop + Row,
    EditLeft + Column - 1, EditTop + Row, ' ', RunAttr);
end;

{ Lazily renders one row of the current viewport. }
procedure RenderViewportRow(Row: Word);
var
  Column: Word;
  DesiredCell: TViewportCell;
begin
  ViewportRowLineIndex := TopLine + Row;
  if ViewportRowLineIndex < Buffer^.Count then
  begin
    ViewportRowCurrentLine := Buffer^.LinePtr(ViewportRowLineIndex);
    ViewportRowLineLength := Length(ViewportRowCurrentLine^);
  end
  else
  begin
    ViewportRowCurrentLine := nil;
    ViewportRowLineLength := 0;
  end;

  Column := 0;
  while Column < EditWidth do
  begin
    ResolveViewportCell(Column, DesiredCell);
    if ViewportCellsEqual(ViewportCache[Row, Column], DesiredCell) then
      Inc(Column)
    else if DesiredCell.Ch = ' ' then
      RenderViewportBlankRun(Row, Column, DesiredCell)
    else
    begin
      PaintViewportCell(EditLeft + Column, EditTop + Row, DesiredCell,
        ViewportCache[Row, Column].BackdropColor);
      ViewportCache[Row, Column] := DesiredCell;
      Inc(Column);
    end;
  end;
end;

{ Lazily renders only the native text cells in the current viewport. }
procedure RenderDocumentViewport;
var
  Row: Word;
begin
  ViewportHasSelection := SelectionActive;
  if ViewportHasSelection then
    GetSelectionBounds(ViewportSelectionStartLine,
      ViewportSelectionStartColumn, ViewportSelectionEndLine,
      ViewportSelectionEndColumn)
  else
  begin
    ViewportSelectionStartLine := 0;
    ViewportSelectionStartColumn := 0;
    ViewportSelectionEndLine := 0;
    ViewportSelectionEndColumn := 0;
  end;

  if not ViewportCacheValid then
    ResetViewportCacheBaseline;

  for Row := 0 to EditHeight - 1 do
    RenderViewportRow(Row);

  CachedTopLine := TopLine;
  CachedLeftColumn := LeftColumn;
  ViewportCacheValid := True;
end;

{ Repaints the editor chrome and lazily updates the visible native text cells. }
procedure DrawDocument;
var
  TitleText, StatusText, ModeText: String;
  LineText, ColumnText, TabText, FormatText: String;
  BackdropWasDirty, ViewportWasInvalid: Boolean;
begin
  { Restore the graphics field after popups or dialogs, then reserve black and
    gray strips beneath opaque reverse-video interface cells. }
  BackdropWasDirty := GraphicsBackdropDirty;
  ViewportWasInvalid := not ViewportCacheValid;
  if BackdropWasDirty then
  begin
    if ColorScheme = SchemeDOSEdit then
      FillGraphicsCellRect(0, 0, 79, 24, GraphicsBlue)
    else
      FillGraphicsCellRect(0, 0, 79, 24, GraphicsBlack);
    GraphicsBackdropDirty := False;
  end;
  if ColorScheme = SchemeDOSEdit then
  begin
    PrepareOpaqueBackdrop(0, 24, 79, 24);
    PrepareOpaqueBackdrop(78, 2, 78, 22);
    PrepareShadedFrameBackdrop(0, 1, 79, 23);
  end;

  DrawTopMenuBar(-1, MenuAcceleratorsVisible, False);
  DrawFrame(0, 1, 79, 23, UiFrameAttr);

  if CurrentFile = '' then
    TitleText := ' Untitled '
  else
    TitleText := ' ' + BaseName(CurrentFile) + ' ';
  if Buffer^.Dirty then
    TitleText := TitleText + '*';
  PrepareOpaqueBackdrop(3, 1, 3 + Length(TitleText) - 1, 1);
  PutText(3, 1, TitleText, UiTitleAttr);

  { On a cache reset, clear stale text once.  Ordinary edits and caret blinks
    update only cells whose character, attribute, or backdrop changed. }
  if BackdropWasDirty or ViewportWasInvalid then
    FillRect(EditLeft, EditTop, EditLeft + EditWidth - 1,
             EditTop + EditHeight - 1, ' ', UiTextAttr);

  if BackdropWasDirty then
    InvalidateViewportCache;
  RenderDocumentViewport;

  DrawVerticalScrollBar;

  if InsertMode then
    ModeText := 'INS'
  else
    ModeText := 'OVR';
  Str(CursorLine + 1, LineText);
  Str(CursorColumn + 1, ColumnText);
  Str(TabWidth, TabText);
  if IsRtfFileName(CurrentFile) then
    FormatText := 'RTF'
  else
    FormatText := 'TXT';
  StatusText := ' Ln ' + LineText + ' Col ' + ColumnText + '  ' + ModeText +
                '  ' + FormatText + '  F2 Save  F3 Open  Ctrl+P Print  F10 Menu';
  WriteField(0, 24, 80, StatusText, UiStatusAttr);
end;

{ Returns a bounded hundredths-within-the-current-minute caret clock. }
function ClockHundredths: Word;
var
  HourValue, MinuteValue, SecondValue, HundredthValue: Word;
begin
  { Only a sub-minute clock is needed for a half-second caret interval.  Keeping
    the value in 0..5999 avoids the checked 32-bit multiplication chain used by
    the previous version and makes arithmetic overflow impossible here. }
  GetTime(HourValue, MinuteValue, SecondValue, HundredthValue);
  {$Q-}
  ClockHundredths := (SecondValue mod 60) * 100 + (HundredthValue mod 100);
  {$Q+}
end;

{ Returns elapsed hundredths between two bounded sub-minute clock values. }
function ElapsedHundredths(StartClock, EndClock: Word): Word;
begin
  if EndClock >= StartClock then
    ElapsedHundredths := EndClock - StartClock
  else
    ElapsedHundredths := HundredthsPerMinute - StartClock + EndClock;
end;

{ Restarts the caret blink interval and makes the caret visible immediately. }
procedure ResetCaretBlink;
begin
  CaretVisible := True;
  LastCaretClock := ClockHundredths;
end;

{ Repaints only the native text cell occupied by the editor caret. }
procedure RedrawCaretCell;
var
  CaretX, CaretY: Word;
  DesiredCell: TViewportCell;
begin
  if not ((CursorLine >= TopLine) and
          (CursorLine < TopLine + EditHeight) and
          (CursorColumn >= LeftColumn) and
          (CursorColumn < LeftColumn + EditWidth)) then
    Exit;

  CaretX := EditLeft + CursorColumn - LeftColumn;
  CaretY := EditTop + CursorLine - TopLine;
  ViewportRowLineIndex := CursorLine;
  ViewportRowCurrentLine := Buffer^.LinePtr(CursorLine);
  ViewportRowLineLength := Length(ViewportRowCurrentLine^);
  ViewportHasSelection := SelectionActive;
  if ViewportHasSelection then
    GetSelectionBounds(ViewportSelectionStartLine,
      ViewportSelectionStartColumn, ViewportSelectionEndLine,
      ViewportSelectionEndColumn);
  ResolveViewportCell(CursorColumn - LeftColumn, DesiredCell);

  if MouseReady then
    HideMouse;
  if ViewportCacheValid and (CachedTopLine = TopLine) and
     (CachedLeftColumn = LeftColumn) then
    PaintViewportCell(CaretX, CaretY, DesiredCell,
      ViewportCache[CaretY - EditTop, CaretX - EditLeft].BackdropColor)
  else
    PaintViewportCell(CaretX, CaretY, DesiredCell, DocTextBackdrop);

  if ViewportCacheValid and (CachedTopLine = TopLine) and
     (CachedLeftColumn = LeftColumn) then
    ViewportCache[CaretY - EditTop, CaretX - EditLeft] := DesiredCell;

  if MouseReady then
    ShowMouse;
end;

{ Toggles and redraws the caret when the half-second interval expires. }
procedure UpdateCaretBlink;
const
  CaretBlinkInterval = 50;  { half a second, in DOS hundredths }
var
  CurrentClock, Elapsed: Word;
begin
  CurrentClock := ClockHundredths;
  Elapsed := ElapsedHundredths(LastCaretClock, CurrentClock);
  if Elapsed < CaretBlinkInterval then
    Exit;

  CaretVisible := not CaretVisible;
  LastCaretClock := CurrentClock;
  RedrawCaretCell;
end;

{ Adjusts vertical and horizontal viewport offsets to include the caret. }
procedure EnsureCursorVisible;
begin
  if CursorLine < TopLine then
    TopLine := CursorLine
  else if CursorLine >= TopLine + EditHeight then
    TopLine := CursorLine - EditHeight + 1;

  if CursorColumn < LeftColumn then
    LeftColumn := CursorColumn
  else if CursorColumn >= LeftColumn + EditWidth then
    LeftColumn := CursorColumn - EditWidth + 1;
end;

{ Hides the mouse and draws a titled modal dialog surface. }
procedure BeginDialog(X1, Y1, X2, Y2: Byte; const Title: String);
begin
  { Dialogs remove the text-VRAM mouse overlay before repainting so its saved
    background cell cannot overwrite part of the freshly drawn window. }
  HideMouse;
  DrawWindowSurface(X1, Y1, X2, Y2);
  PrepareOpaqueBackdrop(X1 + 3, Y1, X1 + Length(Title) + 4, Y1);
  PutText(X1 + 3, Y1, ' ' + Title + ' ', UiTitleAttr);
end;

{ Marks the editor for repaint and restores the mouse after a modal dialog. }
procedure EndDialog;
begin
  NeedsRedraw := True;
  if MouseReady then
    ShowMouse;
end;

{ Extracts one word-wrapped display line and advances a one-based position. }
function TakeMessageLine(const MessageText: String; var Position: Word;
  Width: Byte): String;
var
  TextLength, EndPosition, BreakPosition, I: Word;
  ResultText: String;
begin
  TextLength := Length(MessageText);
  while (Position <= TextLength) and (MessageText[Position] = ' ') do
    Inc(Position);
  if Position > TextLength then
  begin
    TakeMessageLine := '';
    Exit;
  end;

  EndPosition := Position + Width - 1;
  if EndPosition > TextLength then
    EndPosition := TextLength;
  BreakPosition := EndPosition;
  if EndPosition < TextLength then
  begin
    I := EndPosition;
    while (I > Position) and (MessageText[I] <> ' ') do
      Dec(I);
    if MessageText[I] = ' ' then
      BreakPosition := I - 1;
  end;

  ResultText := Copy(MessageText, Position, BreakPosition - Position + 1);
  while (Length(ResultText) > 0) and
        (ResultText[Length(ResultText)] = ' ') do
    Delete(ResultText, Length(ResultText), 1);
  Position := BreakPosition + 1;
  while (Position <= TextLength) and (MessageText[Position] = ' ') do
    Inc(Position);
  TakeMessageLine := ResultText;
end;

{ Displays a wrapped modal message until Enter or Esc is pressed. }
procedure ShowMessage(const Title, MessageText: String);
var
  K: TKeyEvent;
  Done: Boolean;
  Position: Word;
  LineIndex: Byte;
  MessageLine: String;
begin
  BeginDialog(9, 7, 70, 15, Title);
  Position := 1;
  for LineIndex := 0 to 2 do
  begin
    MessageLine := TakeMessageLine(MessageText, Position, 56);
    if (LineIndex = 2) and (Position <= Length(MessageText)) then
    begin
      if Length(MessageLine) > 53 then
        SetLength(MessageLine, 53);
      MessageLine := MessageLine + '...';
    end;
    WriteField(12, 9 + LineIndex, 56, MessageLine, UiPopupAttr);
  end;
  WriteField(12, 13, 56, 'Press Enter or Esc.', UiPopupAttr);
  Done := False;
  repeat
    if PollKey(K) then
      Done := (K.AsciiCode = 13) or (K.AsciiCode = 27);
  until Done;
  EndDialog;
end;



{ Initializes every visible tutorial line to an empty string. }
procedure ClearHelpLines(var Lines: THelpLines);
var
  I: Byte;
begin
  for I := 0 to HelpVisibleLines - 1 do
    Lines[I] := '';
end;

{ Builds the title and instructional lines for one tutorial page. }
procedure BuildHelpPage(Page: Byte; var PageTitle: String;
  var Lines: THelpLines);
begin
  ClearHelpLines(Lines);
  case Page of
    0:
      begin
        PageTitle := '1. Getting started';
        Lines[0] := 'EDIT98 edits plain DOS text and a bounded RTF subset.';
        Lines[1] := 'The blinking yellow caret marks where the next character goes.';
        Lines[2] := 'Type ordinary characters to insert text at the caret.';
        Lines[3] := 'Arrow keys move one character or one line at a time.';
        Lines[4] := 'ROLL UP and ROLL DOWN move by approximately one screen.';
        Lines[5] := 'HOME/CLEAR moves to the start of the current line.';
        Lines[6] := 'The status bar shows line, column, insert mode, and file state.';
        Lines[7] := 'An asterisk in the title/status means the document was changed.';
        Lines[8] := 'Press F2 frequently to save your work.';
        Lines[9] := 'Press HELP at any time to reopen this tutorial.';
        Lines[11] := 'Tutorial navigation:';
        Lines[12] := 'LEFT/RIGHT or ROLL UP/ROLL DOWN changes pages.';
        Lines[13] := 'ENTER or ESC closes Help and returns to the document.';
      end;
    1:
      begin
        PageTitle := '2. Menus and access keys';
        Lines[0] := 'Press GRPH, host Alt (NFER/XFER), or F10 to activate menus.';
        Lines[1] := 'Activation reverses and underlines each menu access letter.';
        Lines[2] := 'While the bar is active, F/E/S/O/H chooses a top menu.';
        Lines[3] := 'LEFT and RIGHT move across File, Edit, Search, Options, Help.';
        Lines[4] := 'DOWN, UP, or ENTER opens the highlighted menu.';
        Lines[5] := 'Inside a menu, UP/DOWN moves and ENTER runs the command.';
        Lines[6] := 'You may also press an underlined command letter directly.';
        Lines[7] := 'ESC closes the current menu without performing a command.';
        Lines[8] := 'A mouse click on a menu title or item performs the same action.';
        Lines[10] := 'Direct menu access:';
        Lines[11] := 'Hold GRPH and press F, E, S, O, or H.';
        Lines[12] := 'On many emulators the host Alt keys map to NFER and XFER.';
      end;
    2:
      begin
        PageTitle := '3. Creating, opening, and saving files';
        Lines[0] := 'File > New clears the editor after confirming unsaved changes.';
        Lines[1] := 'File > Open or F3 displays the DOS file browser.';
        Lines[2] := 'File > Save or F2 writes to the current filename.';
        Lines[3] := 'File > Save As chooses a new drive, directory, and filename.';
        Lines[4] := 'File > Print or Ctrl+P sets paper, orientation, margins, and pages.';
        Lines[5] := 'Portrait/landscape orientation and margins are saved automatically.';
        Lines[6] := 'TXT files store text only; .RTF files preserve logical fonts.';
        Lines[7] := 'A file named on the DOS command line opens at startup:';
        Lines[8] := '  EDIT98 README.RTF';
        Lines[10] := 'Print supports A4, Letter, Legal, Tabloid, document, and custom papers.';
        Lines[11] := 'File > Exit or ESC asks before discarding changed text.';
        Lines[12] := 'Save and print errors leave the document in memory.';
      end;
    3:
      begin
        PageTitle := '4. Using the file browser';
        Lines[0] := 'TAB cycles focus through Drives, File List, and File Name.';
        Lines[1] := 'Only DOS-detected drives appear; arrows choose among them.';
        Lines[2] := 'In File List, UP/DOWN selects an entry.';
        Lines[3] := 'ROLL UP/DOWN moves through one list page at a time.';
        Lines[4] := 'ENTER or a double-click opens a directory or accepts a file.';
        Lines[5] := 'BACKSPACE moves to the parent directory.';
        Lines[6] := 'Typing while the list is focused switches to File Name.';
        Lines[7] := 'In File Name, type or edit the DOS filename and press ENTER.';
        Lines[8] := 'ESC cancels and restores the original drive and directory.';
        Lines[10] := 'The browser is DOS 8.3 oriented and lists up to 96 entries.';
        Lines[11] := 'Double-click entries; single clicks choose other controls.';
      end;
    4:
      begin
        PageTitle := '5. Editing and movement';
        Lines[0] := 'INSERT toggles between Insert and Overwrite typing.';
        Lines[1] := 'BACKSPACE removes the character before the caret.';
        Lines[2] := 'DELETE removes the character at the caret.';
        Lines[3] := 'At a line boundary, these keys join adjacent lines when safe.';
        Lines[4] := 'ENTER splits a line and creates a new line.';
        Lines[5] := 'With Auto Indent enabled, ENTER copies leading spaces.';
        Lines[6] := 'TAB inserts spaces to the next configured tab stop.';
        Lines[7] := 'The Options menu changes tab width between 2, 4, and 8.';
        Lines[9] := 'Long lines scroll horizontally as the caret moves.';
        Lines[10] := 'The right-hand scroll bar represents the visible line range.';
        Lines[11] := 'Click the document to reposition the caret.';
      end;
    5:
      begin
        PageTitle := '6. Selecting and using the clipboard';
        Lines[0] := 'Hold SHIFT while pressing movement keys to select text.';
        Lines[1] := 'You may also drag with the left mouse button.';
        Lines[2] := 'Selected text is drawn with the selection attribute.';
        Lines[3] := 'Ctrl+Ins copies the selection to EDIT98 internal memory.';
        Lines[4] := 'Shift+Del cuts: copy first, then remove the selected range.';
        Lines[5] := 'Shift+Ins pastes at the caret or replaces a selection.';
        Lines[6] := 'Ctrl+A selects the entire document.';
        Lines[7] := 'DELETE or BACKSPACE removes the current selection.';
        Lines[9] := 'Clipboard operations are checked before changing the document.';
        Lines[10] := 'If the result exceeds capacity, the original text is retained.';
      end;
    6:
      begin
        PageTitle := '7. Finding and replacing text';
        Lines[0] := 'Ctrl+F or Search > Find enters text to search for.';
        Lines[1] := 'F4 or Search > Find Next repeats the most recent search.';
        Lines[2] := 'Search wraps from the end of the document to the beginning.';
        Lines[3] := 'Match Case controls whether uppercase and lowercase differ.';
        Lines[4] := 'Replace finds the next match and substitutes the new text.';
        Lines[5] := 'Replace All changes every match and reports the total.';
        Lines[6] := 'An empty replacement deletes matching text.';
        Lines[8] := 'A found match becomes the current selection.';
        Lines[9] := 'Typing or pasting over it replaces the match.';
        Lines[10] := 'Oversized replacements are rejected without partial edits.';
      end;
    7:
      begin
        PageTitle := '8. Options, colors, and mouse';
        Lines[0] := 'Options remains open while settings are changed.';
        Lines[1] := 'Tab Width cycles through 2, 4, and 8 spaces.';
        Lines[2] := 'Typing Mode switches between Insert and Overwrite.';
        Lines[3] := 'Auto Indent controls leading spaces on a new line.';
        Lines[4] := 'Mouse Speed cycles through Slow, Normal, and Fast.';
        Lines[5] := 'Colors cycles through five complete interface schemes.';
        Lines[6] := 'Show Page Breaks toggles visible RTF page separators.';
        Lines[7] := 'The mouse arrow is drawn by EDIT98 in text VRAM.';
        Lines[8] := 'The resident driver supplies only position and button state.';
        Lines[9] := 'If no driver is resident, EDIT98 searches for MOUSE.COM.';
        Lines[10] := 'Options are saved automatically in EDIT98.CFG.';
        Lines[11] := 'The file is kept beside EDIT98.EXE when a path is known.';
        Lines[12] := 'Unknown or invalid configuration entries are ignored safely.';
      end;
    8:
      begin
        PageTitle := '9. Limits and quick reference';
        Lines[0] := 'F2 Save        F3 Open         F4 Find Next';
        Lines[1] := 'F10 Menus      HELP Tutorial   ESC Exit/cancel';
        Lines[2] := 'Ctrl+F Find    Ctrl+P Print    Ctrl+A Select All';
        Lines[3] := 'Ctrl+Ins Copy  Shift+Ins Paste  Shift+Del Cut';
        Lines[5] := 'Documents may contain up to 65,535 paged lines.';
        Lines[6] := 'Only three 32-line pages stay resident in memory.';
        Lines[7] := 'RTF paragraphs wrap at 255 single-byte characters.';
        Lines[8] := 'RTF saves preserve fonts; TXT saves flatten them.';
        Lines[9] := 'DOC and DOCX remain unsupported binary/package formats.';
        Lines[10] := 'RTF tables flatten; images, colors, and objects are skipped.';
        Lines[11] := 'Keep an original copy of complex documents before editing.';
      end;
    9:
      begin
        PageTitle := '10. RTF and logical fonts';
        Lines[0] := 'Open or save a filename ending in .RTF to use Rich Text Format.';
        Lines[1] := 'RTF font-table entries map to three EDIT98 logical families.';
        Lines[2] := 'Roman fonts map to Serif; Swiss fonts map to Sans Serif.';
        Lines[3] := 'Modern or fixed fonts map to Monospace.';
        Lines[5] := 'Document text uses the native PC-98 ROM font.';
        Lines[6] := 'Logical families are preserved but are not drawn differently.';
        Lines[7] := 'Common RTF bullets are converted to ASCII asterisks.';
        Lines[8] := 'All document text uses the same native ROM font as the menus.';
        Lines[9] := 'Imported font runs remain stored only for RTF round-trip saving.';
        Lines[10] := 'Bold, italic, size, color, tables, and pictures are ignored.';
        Lines[11] := 'Unicode outside printable ASCII is approximated when possible.';
        Lines[12] := 'RTF page breaks are preserved as form-feed marker lines.';
      end;
  end;
end;

{ Paints one page of the in-program tutorial and its navigation footer. }
procedure DrawHelpPage(Page: Byte);
var
  Lines: THelpLines;
  PageTitle, PageText, CountText: String;
  I: Byte;
begin
  BuildHelpPage(Page, PageTitle, Lines);
  if MouseReady then
    HideMouse;
  WriteField(3, 3, 74, PageTitle, UiPopupSelectedAttr);
  for I := 0 to HelpVisibleLines - 1 do
    WriteField(3, 5 + I, 74, Lines[I], UiPopupAttr);
  Str(Page + 1, PageText);
  Str(HelpPageCount, CountText);
  WriteField(3, 20, 74, 'Page ' + PageText + ' of ' + CountText +
    '   LEFT/RIGHT or ROLL UP/DOWN changes page.', UiPopupAttr);
  WriteField(3, 21, 74,
    'HOME/CLEAR: first page   ENTER/ESC/HELP: close', UiPopupAttr);
  if MouseReady then
    ShowMouse;
end;

{ Runs the multi-page keyboard-and-mouse tutorial dialog. }
procedure ShowHelpTutorial;
var
  Page: Byte;
  K: TKeyEvent;
  M: TMouseState;
  LocalPreviousButtons: Word;
  CellX, CellY: Word;
  Done, PageChanged: Boolean;
begin
  Page := 0;
  Done := False;
  LocalPreviousButtons := 0;
  BeginDialog(1, 1, 78, 23, 'EDIT98 Tutorial');
  if MouseReady then
  begin
    PollMouse(M);
    LocalPreviousButtons := M.Buttons;
  end;
  DrawHelpPage(Page);

  repeat
    PageChanged := False;
    if PollKey(K) then
    begin
      if (K.AsciiCode = 13) or (K.AsciiCode = 27) or
         (K.ScanCode = ScanHelp) then
        Done := True
      else if (K.ScanCode = ScanLeft) or (K.ScanCode = ScanUp) or
              (K.ScanCode = ScanRollUp) then
      begin
        if Page = 0 then
          Page := HelpPageCount - 1
        else
          Dec(Page);
        PageChanged := True;
      end
      else if (K.ScanCode = ScanRight) or (K.ScanCode = ScanDown) or
              (K.ScanCode = ScanRollDown) then
      begin
        Page := (Page + 1) mod HelpPageCount;
        PageChanged := True;
      end
      else if K.ScanCode = ScanHomeClear then
      begin
        PageChanged := Page <> 0;
        Page := 0;
      end;
    end;

    if MouseReady then
    begin
      PollMouse(M);
      if ((M.Buttons and 1) <> 0) and
         ((LocalPreviousButtons and 1) = 0) then
      begin
        CellX := M.X div 8;
        CellY := M.Y div 16;
        if (CellY >= 20) and (CellY <= 21) then
        begin
          if CellX < 40 then
          begin
            if Page = 0 then
              Page := HelpPageCount - 1
            else
              Dec(Page);
          end
          else
            Page := (Page + 1) mod HelpPageCount;
          PageChanged := True;
        end;
      end;
      LocalPreviousButtons := M.Buttons;
    end;

    if PageChanged and (not Done) then
      DrawHelpPage(Page);
  until Done;

  EndDialog;
end;

{ Edits a short string in a modal prompt with optional empty input. }
function PromptStringEx(const Title, Prompt: String; var Value: String;
  AllowEmpty: Boolean): Boolean;
var
  K: TKeyEvent;
  Done, ValueChanged: Boolean;
begin
  Done := False;
  PromptStringEx := False;
  BeginDialog(6, 7, 73, 13, Title);
  WriteField(9, 9, 62, Prompt, UiPopupAttr);
  WriteField(9, 11, 62, Value, UiPopupSelectedAttr);
  WriteField(9, 12, 62, 'Enter accepts; Esc cancels.', UiPopupAttr);

  repeat
    if PollKey(K) then
    begin
      ValueChanged := False;
      if K.AsciiCode = 13 then
      begin
        if AllowEmpty or (Value <> '') then
        begin
          PromptStringEx := True;
          Done := True;
        end;
      end
      else if K.AsciiCode = 27 then
        Done := True
      else if K.AsciiCode = 8 then
      begin
        if Length(Value) > 0 then
        begin
          Delete(Value, Length(Value), 1);
          ValueChanged := True;
        end;
      end
      else if (K.AsciiCode >= 32) and (K.AsciiCode <= 126) and
              (Length(Value) < 127) then
      begin
        Value := Value + Chr(K.AsciiCode);
        ValueChanged := True;
      end;

      if ValueChanged then
        WriteField(9, 11, 62, Value, UiPopupSelectedAttr);
    end;
  until Done;

  EndDialog;
end;

{ Formats tenths of a centimetre as a compact one-decimal value. }
function FormatPrintMargin(Value: Byte): String;
var
  WholeText: String;
begin
  Str(Value div 10, WholeText);
  FormatPrintMargin := WholeText + '.' + Chr(Ord('0') + (Value mod 10));
end;

{ Parses centimetres with either a period or comma decimal separator. Values
  are retained as tenths of a centimetre to avoid floating-point code. }
function ParsePrintMargin(const TextValue: String; var TenthsCm: Byte): Boolean;
var
  I: Byte;
  WholePart, FractionPart, Value: Word;
  SawSeparator, SawFractionDigit: Boolean;
  Ch: Char;
begin
  ParsePrintMargin := False;
  if TextValue = '' then
    Exit;
  WholePart := 0;
  FractionPart := 0;
  SawSeparator := False;
  SawFractionDigit := False;

  for I := 1 to Length(TextValue) do
  begin
    Ch := TextValue[I];
    if (Ch = '.') or (Ch = ',') then
    begin
      if SawSeparator then
        Exit;
      SawSeparator := True;
    end
    else if (Ch >= '0') and (Ch <= '9') then
    begin
      if not SawSeparator then
      begin
        WholePart := WholePart * 10 + Ord(Ch) - Ord('0');
        if WholePart > 9 then
          Exit;
      end
      else
      begin
        if SawFractionDigit then
          Exit;
        FractionPart := Ord(Ch) - Ord('0');
        SawFractionDigit := True;
      end;
    end
    else
      Exit;
  end;

  Value := WholePart * 10 + FractionPart;
  if Value > MaximumPrintMarginTenthsCm then
    Exit;
  TenthsCm := Byte(Value);
  ParsePrintMargin := True;
end;

{ Copies the persistent margin settings into the PrintDoc record. }
procedure CurrentPrintMargins(var Margins: TPrintMargins);
begin
  Margins.Top := PrintMarginTopTenthsCm;
  Margins.Bottom := PrintMarginBottomTenthsCm;
  Margins.Left := PrintMarginLeftTenthsCm;
  Margins.Right := PrintMarginRightTenthsCm;
end;

{ Formats a paper dimension stored in tenths of a centimetre. }
function FormatPaperDimension(Value: Word): String;
var
  WholeText: String;
begin
  Str(Value div 10, WholeText);
  FormatPaperDimension := WholeText + '.' + Chr(Ord('0') + (Value mod 10));
end;

{ Parses a custom paper width/height. The range is deliberately bounded so
  fixed-pitch geometry always fits in the one-byte column/row counters. }
function ParsePaperDimension(const TextValue: String;
  var TenthsCm: Word): Boolean;
var
  I: Byte;
  WholePart, FractionPart, Value: Word;
  SawSeparator, SawFractionDigit: Boolean;
  Ch: Char;
begin
  ParsePaperDimension := False;
  if TextValue = '' then
    Exit;
  WholePart := 0;
  FractionPart := 0;
  SawSeparator := False;
  SawFractionDigit := False;
  for I := 1 to Length(TextValue) do
  begin
    Ch := TextValue[I];
    if (Ch = '.') or (Ch = ',') then
    begin
      if SawSeparator then Exit;
      SawSeparator := True;
    end
    else if (Ch >= '0') and (Ch <= '9') then
    begin
      if not SawSeparator then
      begin
        WholePart := WholePart * 10 + Ord(Ch) - Ord('0');
        if WholePart > 99 then Exit;
      end
      else
      begin
        if SawFractionDigit then Exit;
        FractionPart := Ord(Ch) - Ord('0');
        SawFractionDigit := True;
      end;
    end
    else
      Exit;
  end;
  Value := WholePart * 10 + FractionPart;
  if (Value < MinimumPaperDimensionTenthsCm) or
     (Value > MaximumPaperDimensionTenthsCm) then
    Exit;
  TenthsCm := Value;
  ParsePaperDimension := True;
end;

function IsCustomPaperTemplate(TemplateIndex: Byte): Boolean;
begin
  IsCustomPaperTemplate := (TemplateIndex >= PaperTemplateFirstCustom) and
    (TemplateIndex <= PaperTemplateLastCustom);
end;

function IsValidPaperTemplate(TemplateIndex: Byte): Boolean;
begin
  IsValidPaperTemplate := (TemplateIndex = PaperTemplateDocument) or
    (TemplateIndex = PaperTemplateA4) or
    (TemplateIndex = PaperTemplateLetter) or
    (TemplateIndex = PaperTemplateLegal) or
    (TemplateIndex = PaperTemplateTabloid) or
    IsCustomPaperTemplate(TemplateIndex);
end;

function PaperTemplateLabel(TemplateIndex: Byte): String;
var
  Slot: Byte;
  SlotText: String;
begin
  case TemplateIndex of
    PaperTemplateDocument:
      PaperTemplateLabel := 'Document geometry';
    PaperTemplateA4:
      PaperTemplateLabel := 'A4 21.0 x 29.7 cm';
    PaperTemplateLetter:
      PaperTemplateLabel := 'Letter 21.6 x 27.9 cm';
    PaperTemplateLegal:
      PaperTemplateLabel := 'Legal 21.6 x 35.6 cm';
    PaperTemplateTabloid:
      PaperTemplateLabel := 'Tabloid 27.9 x 43.2 cm';
    else
      begin
        if not IsCustomPaperTemplate(TemplateIndex) then
        begin
          PaperTemplateLabel := 'A4 21.0 x 29.7 cm';
          Exit;
        end;
        Slot := TemplateIndex - PaperTemplateFirstCustom;
        Str(Slot + 1, SlotText);
        if (CustomPaperWidthTenthsCm[Slot] >= MinimumPaperDimensionTenthsCm) and
           (CustomPaperHeightTenthsCm[Slot] >= MinimumPaperDimensionTenthsCm) then
          PaperTemplateLabel := 'Custom ' + SlotText + ' ' +
            FormatPaperDimension(CustomPaperWidthTenthsCm[Slot]) + ' x ' +
            FormatPaperDimension(CustomPaperHeightTenthsCm[Slot]) + ' cm'
        else
          PaperTemplateLabel := 'Custom ' + SlotText + ' (unset)';
      end;
  end;
end;

function ResolvePrintPaper(TemplateIndex: Byte; var Paper: TPrintPaper;
  var ErrorText: String): Boolean;
var
  Slot: Byte;
begin
  ResolvePrintPaper := False;
  Paper.WidthTenthsCm := 0;
  Paper.HeightTenthsCm := 0;
  Paper.UseDocumentGeometry := False;
  case TemplateIndex of
    PaperTemplateDocument:
      Paper.UseDocumentGeometry := True;
    PaperTemplateA4:
      begin
        Paper.WidthTenthsCm := A4PaperWidthTenthsCm;
        Paper.HeightTenthsCm := A4PaperHeightTenthsCm;
      end;
    PaperTemplateLetter:
      begin
        Paper.WidthTenthsCm := LetterPaperWidthTenthsCm;
        Paper.HeightTenthsCm := LetterPaperHeightTenthsCm;
      end;
    PaperTemplateLegal:
      begin
        Paper.WidthTenthsCm := LegalPaperWidthTenthsCm;
        Paper.HeightTenthsCm := LegalPaperHeightTenthsCm;
      end;
    PaperTemplateTabloid:
      begin
        Paper.WidthTenthsCm := TabloidPaperWidthTenthsCm;
        Paper.HeightTenthsCm := TabloidPaperHeightTenthsCm;
      end;
    else
      begin
        if not IsCustomPaperTemplate(TemplateIndex) then
        begin
          ErrorText := 'Invalid paper template.';
          Exit;
        end;
        Slot := TemplateIndex - PaperTemplateFirstCustom;
        if (CustomPaperWidthTenthsCm[Slot] < MinimumPaperDimensionTenthsCm) or
           (CustomPaperHeightTenthsCm[Slot] < MinimumPaperDimensionTenthsCm) then
        begin
          ErrorText := 'Selected custom paper is not defined. Use Custom...';
          Exit;
        end;
        Paper.WidthTenthsCm := CustomPaperWidthTenthsCm[Slot];
        Paper.HeightTenthsCm := CustomPaperHeightTenthsCm[Slot];
      end;
  end;
  ErrorText := '';
  ResolvePrintPaper := True;
end;

procedure CyclePrintPaperTemplate(MoveBackward: Boolean);
begin
  { Present built-in formats together even though Custom 1-4 retain their
    legacy numeric IDs for EDIT98.CFG compatibility. }
  if MoveBackward then
  begin
    case PrintOptionsPaperTemplate of
      PaperTemplateDocument: PrintOptionsPaperTemplate := PaperTemplateLastCustom;
      PaperTemplateA4: PrintOptionsPaperTemplate := PaperTemplateDocument;
      PaperTemplateLetter: PrintOptionsPaperTemplate := PaperTemplateA4;
      PaperTemplateLegal: PrintOptionsPaperTemplate := PaperTemplateLetter;
      PaperTemplateTabloid: PrintOptionsPaperTemplate := PaperTemplateLegal;
      PaperTemplateFirstCustom: PrintOptionsPaperTemplate := PaperTemplateTabloid;
      else
        if IsCustomPaperTemplate(PrintOptionsPaperTemplate) then
          Dec(PrintOptionsPaperTemplate)
        else
          PrintOptionsPaperTemplate := PaperTemplateA4;
    end;
  end
  else
  begin
    case PrintOptionsPaperTemplate of
      PaperTemplateDocument: PrintOptionsPaperTemplate := PaperTemplateA4;
      PaperTemplateA4: PrintOptionsPaperTemplate := PaperTemplateLetter;
      PaperTemplateLetter: PrintOptionsPaperTemplate := PaperTemplateLegal;
      PaperTemplateLegal: PrintOptionsPaperTemplate := PaperTemplateTabloid;
      PaperTemplateTabloid: PrintOptionsPaperTemplate := PaperTemplateFirstCustom;
      PaperTemplateLastCustom: PrintOptionsPaperTemplate := PaperTemplateDocument;
      else
        if IsCustomPaperTemplate(PrintOptionsPaperTemplate) then
          Inc(PrintOptionsPaperTemplate)
        else
          PrintOptionsPaperTemplate := PaperTemplateA4;
    end;
  end;
  PrintOptionsErrorLine := '';
end;

procedure LoadCustomPaperEditSlot;
var
  Slot: Byte;
begin
  Slot := CustomPaperEditSlot;
  if (CustomPaperWidthTenthsCm[Slot] >= MinimumPaperDimensionTenthsCm) and
     (CustomPaperHeightTenthsCm[Slot] >= MinimumPaperDimensionTenthsCm) then
  begin
    CustomPaperWidthText := FormatPaperDimension(CustomPaperWidthTenthsCm[Slot]);
    CustomPaperHeightText := FormatPaperDimension(CustomPaperHeightTenthsCm[Slot]);
  end
  else
  begin
    CustomPaperWidthText := FormatPaperDimension(A4PaperWidthTenthsCm);
    CustomPaperHeightText := FormatPaperDimension(A4PaperHeightTenthsCm);
  end;
  CustomPaperReplaceOnType := False;
  CustomPaperErrorLine := '';
end;

procedure SelectCustomPaperField(NewField: Byte);
begin
  if NewField > 5 then NewField := 0;
  CustomPaperActiveField := NewField;
  CustomPaperReplaceOnType := (NewField = 1) or (NewField = 2);
  CustomPaperErrorLine := '';
end;

procedure CycleCustomPaperFocus(MoveBackward: Boolean);
begin
  if MoveBackward then
  begin
    if CustomPaperActiveField = 0 then SelectCustomPaperField(5)
    else SelectCustomPaperField(CustomPaperActiveField - 1);
  end
  else
  begin
    if CustomPaperActiveField >= 5 then SelectCustomPaperField(0)
    else SelectCustomPaperField(CustomPaperActiveField + 1);
  end;
end;

procedure CycleCustomPaperSlot(MoveBackward: Boolean);
begin
  if MoveBackward then
  begin
    if CustomPaperEditSlot = 0 then
      CustomPaperEditSlot := CustomPaperTemplateCount - 1
    else
      Dec(CustomPaperEditSlot);
  end
  else
  begin
    Inc(CustomPaperEditSlot);
    if CustomPaperEditSlot >= CustomPaperTemplateCount then
      CustomPaperEditSlot := 0;
  end;
  LoadCustomPaperEditSlot;
end;

procedure DrawCustomPaperFields;
var
  SlotText, SlotLabel: String;
begin
  Str(CustomPaperEditSlot + 1, SlotText);
  SlotLabel := '[ Custom ' + SlotText + ' ]';
  if CustomPaperActiveField = 0 then
    WriteField(25, 9, 14, SlotLabel, UiPopupSelectedAttr)
  else
    WriteField(25, 9, 14, SlotLabel, UiPopupAttr);

  if CustomPaperActiveField = 1 then
    WriteField(30, 11, 5, CustomPaperWidthText, UiPopupSelectedAttr)
  else
    WriteField(30, 11, 5, CustomPaperWidthText, UiPopupAttr);
  if CustomPaperActiveField = 2 then
    WriteField(30, 13, 5, CustomPaperHeightText, UiPopupSelectedAttr)
  else
    WriteField(30, 13, 5, CustomPaperHeightText, UiPopupAttr);

  if CustomPaperActiveField = 3 then
    PutText(20, 16, '[ Save ]', UiPopupSelectedAttr)
  else
    PutText(20, 16, '[ Save ]', UiPopupAttr);
  if CustomPaperActiveField = 4 then
    PutText(34, 16, '[ Delete ]', UiPopupSelectedAttr)
  else
    PutText(34, 16, '[ Delete ]', UiPopupAttr);
  if CustomPaperActiveField = 5 then
    PutText(50, 16, '[ Cancel ]', UiPopupSelectedAttr)
  else
    PutText(50, 16, '[ Cancel ]', UiPopupAttr);
  WriteField(14, 18, 50, CustomPaperErrorLine, UiPopupAttr);
end;

procedure AppendCustomPaperChar(Ch: Char);
var
  Normalized: Char;
begin
  if (CustomPaperActiveField <> 1) and (CustomPaperActiveField <> 2) then Exit;
  Normalized := Ch;
  if Normalized = ',' then Normalized := '.';
  if CustomPaperActiveField = 1 then
  begin
    if CustomPaperReplaceOnType then CustomPaperWidthText := '';
    if Length(CustomPaperWidthText) < 5 then
      CustomPaperWidthText := CustomPaperWidthText + Normalized;
  end
  else
  begin
    if CustomPaperReplaceOnType then CustomPaperHeightText := '';
    if Length(CustomPaperHeightText) < 5 then
      CustomPaperHeightText := CustomPaperHeightText + Normalized;
  end;
  CustomPaperReplaceOnType := False;
  CustomPaperErrorLine := '';
end;

procedure BackspaceCustomPaperField;
begin
  if CustomPaperActiveField = 1 then
  begin
    if Length(CustomPaperWidthText) > 0 then
      Delete(CustomPaperWidthText, Length(CustomPaperWidthText), 1);
  end
  else if CustomPaperActiveField = 2 then
  begin
    if Length(CustomPaperHeightText) > 0 then
      Delete(CustomPaperHeightText, Length(CustomPaperHeightText), 1);
  end;
  CustomPaperReplaceOnType := False;
  CustomPaperErrorLine := '';
end;

function SaveCustomPaperSlot: Boolean;
var
  WidthValue, HeightValue: Word;
begin
  SaveCustomPaperSlot := False;
  if not ParsePaperDimension(CustomPaperWidthText, WidthValue) or
     not ParsePaperDimension(CustomPaperHeightText, HeightValue) then
  begin
    CustomPaperErrorLine := 'Width/height must be from 5.0 through 64.0 cm.';
    Exit;
  end;
  CustomPaperWidthTenthsCm[CustomPaperEditSlot] := WidthValue;
  CustomPaperHeightTenthsCm[CustomPaperEditSlot] := HeightValue;
  PrintOptionsPaperTemplate := PaperTemplateFirstCustom + CustomPaperEditSlot;
  SaveSettings;
  SaveCustomPaperSlot := True;
end;

function PromptCustomPaperTemplate: Boolean;
var
  K: TKeyEvent;
  M: TMouseState;
  LocalPreviousButtons: Word;
  CellX, CellY: Word;
  Done, Accepted, RedrawFields: Boolean;
begin
  PromptCustomPaperTemplate := False;
  if IsCustomPaperTemplate(PrintOptionsPaperTemplate) then
    CustomPaperEditSlot := PrintOptionsPaperTemplate - PaperTemplateFirstCustom
  else
    CustomPaperEditSlot := 0;
  LoadCustomPaperEditSlot;
  SelectCustomPaperField(0);
  Done := False;
  Accepted := False;
  LocalPreviousButtons := 0;

  BeginDialog(10, 6, 69, 20, 'Custom Paper Template');
  PutText(15, 9, 'Template:', UiPopupAttr);
  PutText(17, 11, 'Width (cm): [', UiPopupAttr);
  PutText(35, 11, ']', UiPopupAttr);
  PutText(16, 13, 'Height (cm): [', UiPopupAttr);
  PutText(35, 13, ']', UiPopupAttr);
  WriteField(14, 19, 50, 'Tab moves focus; Left/Right changes template slot.', UiPopupAttr);
  DrawCustomPaperFields;

  if MouseReady then
  begin
    PollMouse(M);
    LocalPreviousButtons := M.Buttons;
    ShowMouse;
  end;

  repeat
    RedrawFields := False;
    if PollKey(K) then
    begin
      if K.AsciiCode = 27 then
        Done := True
      else if K.AsciiCode = 9 then
      begin
        CycleCustomPaperFocus((K.ShiftState and ShiftPressed) <> 0);
        RedrawFields := True;
      end
      else if K.AsciiCode = 13 then
      begin
        case CustomPaperActiveField of
          0: begin CycleCustomPaperSlot(False); RedrawFields := True; end;
          3, 1, 2:
            if SaveCustomPaperSlot then
            begin Accepted := True; Done := True; end
            else RedrawFields := True;
          4:
            begin
              CustomPaperWidthTenthsCm[CustomPaperEditSlot] := 0;
              CustomPaperHeightTenthsCm[CustomPaperEditSlot] := 0;
              if PrintPaperTemplate = PaperTemplateFirstCustom + CustomPaperEditSlot then
                PrintPaperTemplate := PaperTemplateA4;
              if PrintOptionsPaperTemplate = PaperTemplateFirstCustom + CustomPaperEditSlot then
                PrintOptionsPaperTemplate := PaperTemplateA4;
              SaveSettings;
              Accepted := True;
              Done := True;
            end;
          5: Done := True;
        end;
      end
      else if K.AsciiCode = 8 then
      begin BackspaceCustomPaperField; RedrawFields := True; end
      else if ((K.AsciiCode >= Ord('0')) and (K.AsciiCode <= Ord('9'))) or
              (K.AsciiCode = Ord('.')) or (K.AsciiCode = Ord(',')) then
      begin AppendCustomPaperChar(Chr(K.AsciiCode)); RedrawFields := True; end
      else if K.ScanCode = ScanLeft then
      begin
        if CustomPaperActiveField = 0 then CycleCustomPaperSlot(True)
        else CycleCustomPaperFocus(True);
        RedrawFields := True;
      end
      else if K.ScanCode = ScanRight then
      begin
        if CustomPaperActiveField = 0 then CycleCustomPaperSlot(False)
        else CycleCustomPaperFocus(False);
        RedrawFields := True;
      end;
    end;

    if MouseReady then
    begin
      PollMouse(M);
      if ((M.Buttons and 1) <> 0) and ((LocalPreviousButtons and 1) = 0) then
      begin
        CellX := M.X div 8;
        CellY := M.Y div 16;
        if (CellY = 9) and (CellX >= 25) and (CellX <= 38) then
        begin CycleCustomPaperSlot(False); SelectCustomPaperField(0); RedrawFields := True; end
        else if (CellY = 11) and (CellX >= 28) and (CellX <= 32) then
        begin SelectCustomPaperField(1); RedrawFields := True; end
        else if (CellY = 13) and (CellX >= 28) and (CellX <= 32) then
        begin SelectCustomPaperField(2); RedrawFields := True; end
        else if (CellY = 16) and (CellX >= 20) and (CellX <= 27) then
        begin
          SelectCustomPaperField(3);
          if SaveCustomPaperSlot then begin Accepted := True; Done := True; end
          else RedrawFields := True;
        end
        else if (CellY = 16) and (CellX >= 34) and (CellX <= 43) then
        begin
          CustomPaperWidthTenthsCm[CustomPaperEditSlot] := 0;
          CustomPaperHeightTenthsCm[CustomPaperEditSlot] := 0;
          if PrintPaperTemplate = PaperTemplateFirstCustom + CustomPaperEditSlot then
            PrintPaperTemplate := PaperTemplateA4;
          if PrintOptionsPaperTemplate = PaperTemplateFirstCustom + CustomPaperEditSlot then
            PrintOptionsPaperTemplate := PaperTemplateA4;
          SaveSettings;
          Accepted := True;
          Done := True;
        end
        else if (CellY = 16) and (CellX >= 50) and (CellX <= 59) then
          Done := True;
      end;
      LocalPreviousButtons := M.Buttons;
    end;

    if RedrawFields and (not Done) then
    begin
      if MouseReady then HideMouse;
      DrawCustomPaperFields;
      if MouseReady then ShowMouse;
    end;
  until Done;

  EndDialog;
  PromptCustomPaperTemplate := Accepted;
end;

{ Repaints the print-options controls. Focus values are 0=All, 1=Range,
  2=Paper, 3=Custom..., 4=Orientation, 5=Top, 6=Bottom, 7=Left, 8=Right,
  9=OK, 10=Cancel. }
procedure DrawPrintOptionsFields;
var
  AllText, RangeText, PaperText, PortraitText, LandscapeText: String;
begin
  if PrintOptionsRangeMode then
  begin
    AllText := '[ ] All pages';
    RangeText := '[X] Page range';
  end
  else
  begin
    AllText := '[X] All pages';
    RangeText := '[ ] Page range';
  end;

  if PrintOptionsActiveField = 0 then
    WriteField(18, 7, 13, AllText, UiPopupSelectedAttr)
  else
    WriteField(18, 7, 13, AllText, UiPopupAttr);
  if PrintOptionsActiveField = 1 then
    WriteField(36, 7, 14, RangeText, UiPopupSelectedAttr)
  else
    WriteField(36, 7, 14, RangeText, UiPopupAttr);

  PaperText := PaperTemplateLabel(PrintOptionsPaperTemplate);
  if PrintOptionsActiveField = 2 then
    WriteField(18, 9, 32, PaperText, UiPopupSelectedAttr)
  else
    WriteField(18, 9, 32, PaperText, UiPopupAttr);
  if PrintOptionsActiveField = 3 then
    PutText(53, 9, '[ Custom... ]', UiPopupSelectedAttr)
  else
    PutText(53, 9, '[ Custom... ]', UiPopupAttr);

  if PrintOptionsOrientation = PrintOrientationLandscape then
  begin
    PortraitText := '[ ] Portrait';
    LandscapeText := '[X] Landscape';
  end
  else
  begin
    PortraitText := '[X] Portrait';
    LandscapeText := '[ ] Landscape';
  end;
  if PrintOptionsActiveField = 4 then
  begin
    WriteField(22, 11, 12, PortraitText, UiPopupSelectedAttr);
    WriteField(39, 11, 13, LandscapeText, UiPopupSelectedAttr);
  end
  else
  begin
    WriteField(22, 11, 12, PortraitText, UiPopupAttr);
    WriteField(39, 11, 13, LandscapeText, UiPopupAttr);
  end;

  if PrintOptionsActiveField = 5 then
    WriteField(18, 14, 4, PrintOptionsTopText, UiPopupSelectedAttr)
  else
    WriteField(18, 14, 4, PrintOptionsTopText, UiPopupAttr);
  if PrintOptionsActiveField = 6 then
    WriteField(39, 14, 4, PrintOptionsBottomText, UiPopupSelectedAttr)
  else
    WriteField(39, 14, 4, PrintOptionsBottomText, UiPopupAttr);
  if PrintOptionsActiveField = 7 then
    WriteField(19, 16, 4, PrintOptionsLeftText, UiPopupSelectedAttr)
  else
    WriteField(19, 16, 4, PrintOptionsLeftText, UiPopupAttr);
  if PrintOptionsActiveField = 8 then
    WriteField(38, 16, 4, PrintOptionsRightText, UiPopupSelectedAttr)
  else
    WriteField(38, 16, 4, PrintOptionsRightText, UiPopupAttr);

  if PrintOptionsActiveField = 9 then
    PutText(24, 20, '[ OK ]', UiPopupSelectedAttr)
  else
    PutText(24, 20, '[ OK ]', UiPopupAttr);
  if PrintOptionsActiveField = 10 then
    PutText(42, 20, '[ Cancel ]', UiPopupSelectedAttr)
  else
    PutText(42, 20, '[ Cancel ]', UiPopupAttr);

  WriteField(10, 18, 58, PrintOptionsErrorLine, UiPopupAttr);
end;

{ Rebuilds the complete Print dialog. This is required after the nested Custom
  Paper dialog because EDIT98 dialogs repaint directly and do not save a window
  stack beneath them. }
procedure DrawPrintOptionsDialogSurface;
begin
  BeginDialog(6, 3, 73, 23, 'Print');
  WriteField(9, 5, 60, 'Printer device: ' + DefaultPrinterDevice, UiPopupAttr);
  PutText(9, 7, 'Pages:', UiPopupAttr);
  PutText(9, 9, 'Paper:', UiPopupAttr);
  PutText(9, 11, 'Orientation:', UiPopupAttr);
  PutText(9, 13, 'Margins (cm):', UiPopupAttr);
  PutText(13, 14, 'Top [', UiPopupAttr);
  PutText(22, 14, ']', UiPopupAttr);
  PutText(31, 14, 'Bottom [', UiPopupAttr);
  PutText(43, 14, ']', UiPopupAttr);
  PutText(13, 16, 'Left [', UiPopupAttr);
  PutText(23, 16, ']', UiPopupAttr);
  PutText(31, 16, 'Right [', UiPopupAttr);
  PutText(42, 16, ']', UiPopupAttr);
  WriteField(9, 22, 60,
    'Tab focus. Left/Right changes paper/orientation. C=Custom.', UiPopupAttr);
  DrawPrintOptionsFields;
end;

procedure SelectPrintOptionsField(NewField: Byte);
begin
  if NewField > 10 then NewField := 0;
  PrintOptionsActiveField := NewField;
  PrintOptionsReplaceOnType := (NewField >= 5) and (NewField <= 8);
  PrintOptionsErrorLine := '';
end;

procedure CyclePrintOptionsFocus(MoveBackward: Boolean);
begin
  if MoveBackward then
  begin
    if PrintOptionsActiveField = 0 then SelectPrintOptionsField(10)
    else SelectPrintOptionsField(PrintOptionsActiveField - 1);
  end
  else
  begin
    if PrintOptionsActiveField >= 10 then SelectPrintOptionsField(0)
    else SelectPrintOptionsField(PrintOptionsActiveField + 1);
  end;
end;

{ Adds one numeric/decimal character to the active margin field. }
procedure AppendPrintOptionChar(Ch: Char);
var
  Normalized: Char;
begin
  if (PrintOptionsActiveField < 5) or (PrintOptionsActiveField > 8) then Exit;
  Normalized := Ch;
  if Normalized = ',' then Normalized := '.';
  case PrintOptionsActiveField of
    5:
      begin
        if PrintOptionsReplaceOnType then PrintOptionsTopText := '';
        if Length(PrintOptionsTopText) < 4 then PrintOptionsTopText := PrintOptionsTopText + Normalized;
      end;
    6:
      begin
        if PrintOptionsReplaceOnType then PrintOptionsBottomText := '';
        if Length(PrintOptionsBottomText) < 4 then PrintOptionsBottomText := PrintOptionsBottomText + Normalized;
      end;
    7:
      begin
        if PrintOptionsReplaceOnType then PrintOptionsLeftText := '';
        if Length(PrintOptionsLeftText) < 4 then PrintOptionsLeftText := PrintOptionsLeftText + Normalized;
      end;
    8:
      begin
        if PrintOptionsReplaceOnType then PrintOptionsRightText := '';
        if Length(PrintOptionsRightText) < 4 then PrintOptionsRightText := PrintOptionsRightText + Normalized;
      end;
  end;
  PrintOptionsReplaceOnType := False;
  PrintOptionsErrorLine := '';
end;

procedure BackspacePrintOptionField;
begin
  case PrintOptionsActiveField of
    5: if Length(PrintOptionsTopText) > 0 then Delete(PrintOptionsTopText, Length(PrintOptionsTopText), 1);
    6: if Length(PrintOptionsBottomText) > 0 then Delete(PrintOptionsBottomText, Length(PrintOptionsBottomText), 1);
    7: if Length(PrintOptionsLeftText) > 0 then Delete(PrintOptionsLeftText, Length(PrintOptionsLeftText), 1);
    8: if Length(PrintOptionsRightText) > 0 then Delete(PrintOptionsRightText, Length(PrintOptionsRightText), 1);
  end;
  PrintOptionsReplaceOnType := False;
  PrintOptionsErrorLine := '';
end;

{ Validates paper and margins and verifies that they leave a usable fixed-pitch
  print area for the current document. }
function AcceptPrintOptions(var Paper: TPrintPaper;
  var Margins: TPrintMargins): Boolean;
var
  ContentColumns, ContentRows, LeftColumns, TopRows: Byte;
begin
  AcceptPrintOptions := False;
  if not ParsePrintMargin(PrintOptionsTopText, Margins.Top) or
     not ParsePrintMargin(PrintOptionsBottomText, Margins.Bottom) or
     not ParsePrintMargin(PrintOptionsLeftText, Margins.Left) or
     not ParsePrintMargin(PrintOptionsRightText, Margins.Right) then
  begin
    PrintOptionsErrorLine := 'Margins must be values from 0.0 through 9.9 cm.';
    Exit;
  end;
  if not ResolvePrintPaper(PrintOptionsPaperTemplate, Paper,
    PrintOptionsErrorLine) then Exit;
  ApplyPrintOrientation(Paper,
    PrintOptionsOrientation = PrintOrientationLandscape);
  if not ResolvePrintGeometry(Buffer^, Paper, Margins, ContentColumns,
    ContentRows, LeftColumns, TopRows, PrintOptionsErrorLine) then Exit;
  AcceptPrintOptions := True;
end;

{ Configures page selection mode, paper template, and margins before pagination
  is calculated. Margins, selected paper, and custom paper slots are persistent. }
function PromptPrintOptions(var RangeMode: Boolean; var Paper: TPrintPaper;
  var Margins: TPrintMargins): Boolean;
var
  K: TKeyEvent;
  M: TMouseState;
  LocalPreviousButtons: Word;
  CellX, CellY: Word;
  Done, Accepted, RedrawFields: Boolean;
begin
  PromptPrintOptions := False;
  CurrentPrintMargins(Margins);
  PrintOptionsTopText := FormatPrintMargin(Margins.Top);
  PrintOptionsBottomText := FormatPrintMargin(Margins.Bottom);
  PrintOptionsLeftText := FormatPrintMargin(Margins.Left);
  PrintOptionsRightText := FormatPrintMargin(Margins.Right);
  PrintOptionsRangeMode := False;
  PrintOptionsPaperTemplate := PrintPaperTemplate;
  PrintOptionsOrientation := PrintOrientation;
  PrintOptionsErrorLine := '';
  PrintOptionsActiveField := 0;
  PrintOptionsReplaceOnType := False;
  Done := False;
  Accepted := False;
  LocalPreviousButtons := 0;

  DrawPrintOptionsDialogSurface;

  if MouseReady then
  begin
    PollMouse(M);
    LocalPreviousButtons := M.Buttons;
    ShowMouse;
  end;

  repeat
    RedrawFields := False;
    if PollKey(K) then
    begin
      if K.AsciiCode = 27 then
        Done := True
      else if K.AsciiCode = 9 then
      begin
        CyclePrintOptionsFocus((K.ShiftState and ShiftPressed) <> 0);
        RedrawFields := True;
      end
      else if K.AsciiCode = 13 then
      begin
        if PrintOptionsActiveField = 10 then
          Done := True
        else if PrintOptionsActiveField = 0 then
        begin
          PrintOptionsRangeMode := False;
          SelectPrintOptionsField(2);
          RedrawFields := True;
        end
        else if PrintOptionsActiveField = 1 then
        begin
          PrintOptionsRangeMode := True;
          SelectPrintOptionsField(2);
          RedrawFields := True;
        end
        else if PrintOptionsActiveField = 2 then
        begin
          CyclePrintPaperTemplate(False);
          RedrawFields := True;
        end
        else if PrintOptionsActiveField = 3 then
        begin
          PromptCustomPaperTemplate;
          DrawPrintOptionsDialogSurface;
          if MouseReady then ShowMouse;
          RedrawFields := False;
        end
        else if PrintOptionsActiveField = 4 then
        begin
          PrintOptionsOrientation := (PrintOptionsOrientation + 1) mod
            PrintOrientationCount;
          RedrawFields := True;
        end
        else if AcceptPrintOptions(Paper, Margins) then
        begin
          Accepted := True;
          Done := True;
        end
        else
          RedrawFields := True;
      end
      else if K.AsciiCode = 8 then
      begin BackspacePrintOptionField; RedrawFields := True; end
      else if ((K.AsciiCode >= Ord('0')) and (K.AsciiCode <= Ord('9'))) or
              (K.AsciiCode = Ord('.')) or (K.AsciiCode = Ord(',')) then
      begin AppendPrintOptionChar(Chr(K.AsciiCode)); RedrawFields := True; end
      else if (K.AsciiCode = Ord('a')) or (K.AsciiCode = Ord('A')) then
      begin
        PrintOptionsRangeMode := False;
        SelectPrintOptionsField(0);
        RedrawFields := True;
      end
      else if (K.AsciiCode = Ord('r')) or (K.AsciiCode = Ord('R')) then
      begin
        PrintOptionsRangeMode := True;
        SelectPrintOptionsField(1);
        RedrawFields := True;
      end
      else if (K.AsciiCode = Ord('c')) or (K.AsciiCode = Ord('C')) then
      begin
        PromptCustomPaperTemplate;
        DrawPrintOptionsDialogSurface;
        if MouseReady then ShowMouse;
        RedrawFields := False;
      end
      else if (K.AsciiCode = Ord('p')) or (K.AsciiCode = Ord('P')) then
      begin
        PrintOptionsOrientation := PrintOrientationPortrait;
        SelectPrintOptionsField(4);
        RedrawFields := True;
      end
      else if (K.AsciiCode = Ord('l')) or (K.AsciiCode = Ord('L')) then
      begin
        PrintOptionsOrientation := PrintOrientationLandscape;
        SelectPrintOptionsField(4);
        RedrawFields := True;
      end
      else if (K.AsciiCode = 32) and
              ((PrintOptionsActiveField = 2) or
               (PrintOptionsActiveField = 4)) then
      begin
        if PrintOptionsActiveField = 2 then
          CyclePrintPaperTemplate(False)
        else
          PrintOptionsOrientation := (PrintOptionsOrientation + 1) mod
            PrintOrientationCount;
        RedrawFields := True;
      end
      else if K.ScanCode = ScanLeft then
      begin
        if PrintOptionsActiveField = 2 then CyclePrintPaperTemplate(True)
        else if PrintOptionsActiveField = 4 then
          PrintOptionsOrientation := PrintOrientationPortrait
        else CyclePrintOptionsFocus(True);
        RedrawFields := True;
      end
      else if K.ScanCode = ScanRight then
      begin
        if PrintOptionsActiveField = 2 then CyclePrintPaperTemplate(False)
        else if PrintOptionsActiveField = 4 then
          PrintOptionsOrientation := PrintOrientationLandscape
        else CyclePrintOptionsFocus(False);
        RedrawFields := True;
      end;
    end;

    if MouseReady then
    begin
      PollMouse(M);
      if ((M.Buttons and 1) <> 0) and ((LocalPreviousButtons and 1) = 0) then
      begin
        CellX := M.X div 8;
        CellY := M.Y div 16;
        if (CellY = 7) and (CellX >= 18) and (CellX <= 30) then
        begin PrintOptionsRangeMode := False; SelectPrintOptionsField(0); RedrawFields := True; end
        else if (CellY = 7) and (CellX >= 36) and (CellX <= 49) then
        begin PrintOptionsRangeMode := True; SelectPrintOptionsField(1); RedrawFields := True; end
        else if (CellY = 9) and (CellX >= 18) and (CellX <= 49) then
        begin CyclePrintPaperTemplate(False); SelectPrintOptionsField(2); RedrawFields := True; end
        else if (CellY = 9) and (CellX >= 53) and (CellX <= 65) then
        begin
          SelectPrintOptionsField(3);
          PromptCustomPaperTemplate;
          DrawPrintOptionsDialogSurface;
          if MouseReady then ShowMouse;
          RedrawFields := False;
        end
        else if (CellY = 11) and (CellX >= 22) and (CellX <= 33) then
        begin
          PrintOptionsOrientation := PrintOrientationPortrait;
          SelectPrintOptionsField(4);
          RedrawFields := True;
        end
        else if (CellY = 11) and (CellX >= 39) and (CellX <= 51) then
        begin
          PrintOptionsOrientation := PrintOrientationLandscape;
          SelectPrintOptionsField(4);
          RedrawFields := True;
        end
        else if (CellY = 14) and (CellX >= 18) and (CellX <= 21) then
        begin SelectPrintOptionsField(5); RedrawFields := True; end
        else if (CellY = 14) and (CellX >= 39) and (CellX <= 42) then
        begin SelectPrintOptionsField(6); RedrawFields := True; end
        else if (CellY = 16) and (CellX >= 19) and (CellX <= 22) then
        begin SelectPrintOptionsField(7); RedrawFields := True; end
        else if (CellY = 16) and (CellX >= 38) and (CellX <= 41) then
        begin SelectPrintOptionsField(8); RedrawFields := True; end
        else if (CellY = 20) and (CellX >= 24) and (CellX <= 29) then
        begin
          SelectPrintOptionsField(9);
          if AcceptPrintOptions(Paper, Margins) then begin Accepted := True; Done := True; end
          else RedrawFields := True;
        end
        else if (CellY = 20) and (CellX >= 42) and (CellX <= 51) then
          Done := True;
      end;
      LocalPreviousButtons := M.Buttons;
    end;

    if RedrawFields and (not Done) then
    begin
      if MouseReady then HideMouse;
      DrawPrintOptionsFields;
      if MouseReady then ShowMouse;
    end;
  until Done;

  EndDialog;
  if Accepted then
  begin
    RangeMode := PrintOptionsRangeMode;
    PrintMarginTopTenthsCm := Margins.Top;
    PrintMarginBottomTenthsCm := Margins.Bottom;
    PrintMarginLeftTenthsCm := Margins.Left;
    PrintMarginRightTenthsCm := Margins.Right;
    PrintPaperTemplate := PrintOptionsPaperTemplate;
    PrintOrientation := PrintOptionsOrientation;
    SaveSettings;
    PromptPrintOptions := True;
  end;
end;

{ Parses one logical page number without overflowing checked LongInt math. }
function ParsePrintPageNumber(const TextValue: String;
  var NumberValue: LongInt): Boolean;
var
  I: Byte;
  Digit: Byte;
  Value: LongInt;
begin
  ParsePrintPageNumber := False;
  if TextValue = '' then
    Exit;
  Value := 0;
  for I := 1 to Length(TextValue) do
  begin
    if (TextValue[I] < '0') or (TextValue[I] > '9') then
      Exit;
    Digit := Ord(TextValue[I]) - Ord('0');
    if Value > (MaximumLogicalPages - Digit) div 10 then
      Exit;
    Value := Value * 10 + Digit;
  end;
  NumberValue := Value;
  ParsePrintPageNumber := True;
end;

{ Validates the two fields used by the simultaneous page-range dialog. }
function ValidatePrintRangeText(const FromText, ToText: String;
  TotalPages: LongInt; var FirstPage, LastPage: LongInt;
  var ErrorText: String): Boolean;
var
  ParsedFirst, ParsedLast: LongInt;
  TotalText: String;
begin
  ValidatePrintRangeText := False;
  if not ParsePrintPageNumber(FromText, ParsedFirst) or
     not ParsePrintPageNumber(ToText, ParsedLast) then
  begin
    ErrorText := 'Enter numeric page values.';
    Exit;
  end;

  Str(TotalPages, TotalText);
  if (ParsedFirst < 1) or (ParsedFirst > TotalPages) or
     (ParsedLast < 1) or (ParsedLast > TotalPages) then
  begin
    ErrorText := 'Range must stay between 1 and ' + TotalText + '.';
    Exit;
  end;
  if ParsedFirst > ParsedLast then
  begin
    ErrorText := 'From page must not be after To page.';
    Exit;
  end;

  FirstPage := ParsedFirst;
  LastPage := ParsedLast;
  ErrorText := '';
  ValidatePrintRangeText := True;
end;

{ Repaints the two numeric fields, the OK/Cancel buttons, and validation line.
  Focus values are 0=From, 1=To, 2=OK, and 3=Cancel. }
procedure DrawPrintRangeFields;
begin
  if PrintRangeActiveField = 0 then
    WriteField(26, 11, 5, PrintRangeFromText, UiPopupSelectedAttr)
  else
    WriteField(26, 11, 5, PrintRangeFromText, UiPopupAttr);

  if PrintRangeActiveField = 1 then
    WriteField(37, 11, 5, PrintRangeToText, UiPopupSelectedAttr)
  else
    WriteField(37, 11, 5, PrintRangeToText, UiPopupAttr);

  if PrintRangeActiveField = 2 then
    PutText(25, 14, '[ OK ]', UiPopupSelectedAttr)
  else
    PutText(25, 14, '[ OK ]', UiPopupAttr);

  if PrintRangeActiveField = 3 then
    PutText(41, 14, '[ Cancel ]', UiPopupSelectedAttr)
  else
    PutText(41, 14, '[ Cancel ]', UiPopupAttr);

  WriteField(17, 13, 46, PrintRangeErrorLine, UiPopupAttr);
end;

{ Selects one of the four controls in the page-range dialog. Selecting either
  numeric field makes the next typed digit replace its prefilled value. }
procedure SelectPrintRangeField(NewField: Byte);
begin
  if NewField > 3 then
    NewField := 0;
  PrintRangeActiveField := NewField;
  PrintRangeReplaceOnType := NewField < 2;
  PrintRangeErrorLine := '';
end;

{ Moves focus through From, To, OK, and Cancel. Shift+Tab calls this with
  MoveBackward=True. }
procedure CyclePrintRangeFocus(MoveBackward: Boolean);
begin
  if MoveBackward then
  begin
    if PrintRangeActiveField = 0 then
      SelectPrintRangeField(3)
    else
      SelectPrintRangeField(PrintRangeActiveField - 1);
  end
  else
  begin
    if PrintRangeActiveField >= 3 then
      SelectPrintRangeField(0)
    else
      SelectPrintRangeField(PrintRangeActiveField + 1);
  end;
end;

{ Applies one digit to the active print-range field. }
procedure AppendPrintRangeDigit(DigitChar: Char);
begin
  if PrintRangeActiveField = 0 then
  begin
    if PrintRangeReplaceOnType then
      PrintRangeFromText := '';
    if Length(PrintRangeFromText) < 5 then
      PrintRangeFromText := PrintRangeFromText + DigitChar;
  end
  else if PrintRangeActiveField = 1 then
  begin
    if PrintRangeReplaceOnType then
      PrintRangeToText := '';
    if Length(PrintRangeToText) < 5 then
      PrintRangeToText := PrintRangeToText + DigitChar;
  end
  else
    Exit;
  PrintRangeReplaceOnType := False;
  PrintRangeErrorLine := '';
end;

{ Removes one digit from the active print-range field. }
procedure BackspacePrintRangeField;
begin
  if PrintRangeActiveField = 0 then
  begin
    if Length(PrintRangeFromText) > 0 then
      Delete(PrintRangeFromText, Length(PrintRangeFromText), 1);
  end
  else if PrintRangeActiveField = 1 then
  begin
    if Length(PrintRangeToText) > 0 then
      Delete(PrintRangeToText, Length(PrintRangeToText), 1);
  end
  else
    Exit;
  PrintRangeReplaceOnType := False;
  PrintRangeErrorLine := '';
end;

{ Validates the current shared fields and commits them to the caller. }
function AcceptPrintRange(TotalPages: LongInt; var FirstPage,
  LastPage: LongInt): Boolean;
begin
  AcceptPrintRange := ValidatePrintRangeText(PrintRangeFromText,
    PrintRangeToText, TotalPages, FirstPage, LastPage, PrintRangeErrorLine);
end;

{ Allows both ends of a print range to be edited at once. Tab cycles through
  From, To, OK, and Cancel; Shift+Tab reverses. Mouse clicks select fields or
  activate buttons. Enter activates the focused button (or OK from a field). }
function PromptPrintRangeDialog(TotalPages: LongInt; var FirstPage,
  LastPage: LongInt): Boolean;
var
  K: TKeyEvent;
  M: TMouseState;
  LocalPreviousButtons: Word;
  CellX, CellY: Word;
  TotalText: String;
  Done, Accepted, RedrawFields: Boolean;
begin
  PromptPrintRangeDialog := False;
  Str(TotalPages, TotalText);
  PrintRangeFromText := '1';
  PrintRangeToText := TotalText;
  PrintRangeErrorLine := '';
  PrintRangeActiveField := 0;
  PrintRangeReplaceOnType := True;
  Done := False;
  Accepted := False;
  LocalPreviousButtons := 0;

  BeginDialog(14, 7, 66, 17, 'Print Range');
  WriteField(17, 9, 46, 'Pages available: 1 through ' + TotalText + '.',
    UiPopupAttr);
  PutText(20, 11, 'From [', UiPopupAttr);
  PutText(31, 11, '] to [', UiPopupAttr);
  PutText(42, 11, ']', UiPopupAttr);
  PutText(25, 14, '[ OK ]', UiPopupAttr);
  PutText(41, 14, '[ Cancel ]', UiPopupAttr);
  WriteField(17, 15, 46,
    'Tab: From > To > OK > Cancel. Shift+Tab back.', UiPopupAttr);
  DrawPrintRangeFields;

  if MouseReady then
  begin
    PollMouse(M);
    LocalPreviousButtons := M.Buttons;
    ShowMouse;
  end;

  repeat
    RedrawFields := False;
    if PollKey(K) then
    begin
      if K.AsciiCode = 27 then
        Done := True
      else if K.AsciiCode = 13 then
      begin
        if PrintRangeActiveField = 3 then
          Done := True
        else if AcceptPrintRange(TotalPages, FirstPage, LastPage) then
        begin
          Accepted := True;
          Done := True;
        end
        else
          RedrawFields := True;
      end
      else if K.AsciiCode = 9 then
      begin
        CyclePrintRangeFocus((K.ShiftState and ShiftPressed) <> 0);
        RedrawFields := True;
      end
      else if K.AsciiCode = 8 then
      begin
        BackspacePrintRangeField;
        RedrawFields := True;
      end
      else if (K.AsciiCode >= Ord('0')) and
              (K.AsciiCode <= Ord('9')) then
      begin
        AppendPrintRangeDigit(Chr(K.AsciiCode));
        RedrawFields := True;
      end
      else if K.ScanCode = ScanLeft then
      begin
        CyclePrintRangeFocus(True);
        RedrawFields := True;
      end
      else if K.ScanCode = ScanRight then
      begin
        CyclePrintRangeFocus(False);
        RedrawFields := True;
      end;
    end;

    if MouseReady then
    begin
      PollMouse(M);
      if ((M.Buttons and 1) <> 0) and
         ((LocalPreviousButtons and 1) = 0) then
      begin
        CellX := M.X div 8;
        CellY := M.Y div 16;
        if (CellY = 11) and (CellX >= 26) and (CellX <= 30) then
        begin
          SelectPrintRangeField(0);
          RedrawFields := True;
        end
        else if (CellY = 11) and (CellX >= 37) and (CellX <= 41) then
        begin
          SelectPrintRangeField(1);
          RedrawFields := True;
        end
        else if (CellY = 14) and (CellX >= 25) and (CellX <= 30) then
        begin
          if AcceptPrintRange(TotalPages, FirstPage, LastPage) then
          begin
            Accepted := True;
            Done := True;
          end
          else
            RedrawFields := True;
        end
        else if (CellY = 14) and (CellX >= 41) and (CellX <= 50) then
          Done := True;
      end;
      LocalPreviousButtons := M.Buttons;
    end;

    if RedrawFields and (not Done) then
    begin
      if MouseReady then
        HideMouse;
      DrawPrintRangeFields;
      if MouseReady then
        ShowMouse;
    end;
  until Done;

  EndDialog;
  PromptPrintRangeDialog := Accepted;
end;

{ Probes DOS drive selection and builds a compact list of usable letters. }
procedure ReadDriveInformation(var CurrentDrive: Byte;
  var AvailableDrives: TDriveList; var DriveCount: Byte);
var
  R: Registers;
  ProbeDrive, OriginalDrive: Byte;
  OriginalFound: Boolean;
begin
  { DOS function 0Eh changes the default drive without reading its media, and
    function 19h reports which drive DOS actually accepted.  Testing every
    letter this way avoids treating the highest reported drive number as proof
    that every preceding letter exists; gaps caused by emulator configuration,
    ASSIGN/SUBST, or absent devices therefore stay out of the browser row. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $19;
  Intr($21, R);
  OriginalDrive := R.AL;
  CurrentDrive := OriginalDrive;
  DriveCount := 0;
  OriginalFound := False;

  for ProbeDrive := 0 to 25 do
  begin
    FillChar(R, SizeOf(R), 0);
    R.AH := $0E;
    R.DL := ProbeDrive;
    Intr($21, R);

    FillChar(R, SizeOf(R), 0);
    R.AH := $19;
    Intr($21, R);
    if R.AL = ProbeDrive then
    begin
      AvailableDrives[DriveCount] := ProbeDrive;
      if ProbeDrive = OriginalDrive then
        OriginalFound := True;
      Inc(DriveCount);
    end;
  end;

  { Restore the user's original default drive after the non-destructive probe. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $0E;
  R.DL := OriginalDrive;
  Intr($21, R);
  CurrentDrive := OriginalDrive;

  { A running DOS process must have a current drive.  Keep that drive visible
    even if an unusual redirector did not respond normally to the probe. }
  if not OriginalFound then
  begin
    if DriveCount < 26 then
    begin
      AvailableDrives[DriveCount] := CurrentDrive;
      Inc(DriveCount);
    end
    else
      AvailableDrives[0] := CurrentDrive;
  end;
end;

{ Finds the visual slot occupied by a zero-based DOS drive number. }
function DriveListPosition(const AvailableDrives: TDriveList;
  DriveCount, DriveIndex: Byte): Byte;
var
  I: Byte;
begin
  DriveListPosition := 0;
  if DriveCount = 0 then
    Exit;
  for I := 0 to DriveCount - 1 do
    if AvailableDrives[I] = DriveIndex then
    begin
      DriveListPosition := I;
      Exit;
    end;
end;

{ Selects a DOS drive and returns a readable error on failure. }
function SelectDosDrive(DriveIndex: Byte; var ErrorText: String): Boolean;
var
  R: Registers;
  Code: Integer;
begin
  { Selecting a drive is separate from changing its directory in DOS.  Move to
    the root after selecting it so an old per-drive working directory does not
    make the browser appear to jump unpredictably. }
  SelectDosDrive := False;
  ErrorText := '';
  FillChar(R, SizeOf(R), 0);
  R.AH := $0E;
  R.DL := DriveIndex;
  Intr($21, R);

  FillChar(R, SizeOf(R), 0);
  R.AH := $19;
  Intr($21, R);
  if R.AL <> DriveIndex then
  begin
    ErrorText := 'That drive is not available.';
    Exit;
  end;

  {$I-}
  ChDir('\');
  Code := IOResult;
  {$I+}
  if Code <> 0 then
  begin
    ErrorText := 'The drive cannot be read.';
    Exit;
  end;
  SelectDosDrive := True;
end;

{ Sorts browser entries with directories before files and names alphabetically. }
procedure SortBrowserEntries(var Entries: TBrowserEntries;
  FirstIndex, EntryCount: Word);
var
  I, J: Word;
  Temp: TBrowserEntry;
  MustSwap: Boolean;
begin
  { DOS usually returns directory order.  A small insertion sort keeps folders
    before files and gives the dialog a predictable alphabetical presentation. }
  if EntryCount < 2 then
    Exit;
  for I := FirstIndex + 1 to EntryCount - 1 do
  begin
    J := I;
    while J > FirstIndex do
    begin
      MustSwap :=
        ((not Entries[J - 1].IsDirectory) and Entries[J].IsDirectory) or
        ((Entries[J - 1].IsDirectory = Entries[J].IsDirectory) and
         (Entries[J].Name < Entries[J - 1].Name));
      if not MustSwap then
        Break;
      Temp := Entries[J - 1];
      Entries[J - 1] := Entries[J];
      Entries[J] := Temp;
      Dec(J);
    end;
  end;
end;

{ Enumerates the current directory into the fixed browser entry array. }
procedure LoadBrowserEntries(var Entries: TBrowserEntries;
  var EntryCount: Word; var CurrentDirectory: String);
var
  Search: SearchRec;
  SortStart: Word;
begin
  GetDir(0, CurrentDirectory);
  EntryCount := 0;

  { The parent item remains first and is not included in alphabetical sorting. }
  SortStart := 0;
  if not ((Length(CurrentDirectory) = 3) and
          (CurrentDirectory[2] = ':') and
          (CurrentDirectory[3] = '\')) then
  begin
    Entries[0].Name := '..';
    Entries[0].IsDirectory := True;
    EntryCount := 1;
    SortStart := 1;
  end;

  FindFirst('*.*', AnyFile, Search);
  while (DosError = 0) and (EntryCount < MaxBrowserEntries) do
  begin
    if (Search.Name <> '.') and (Search.Name <> '..') and
       ((Search.Attr and VolumeID) = 0) then
    begin
      Entries[EntryCount].Name := Search.Name;
      Entries[EntryCount].IsDirectory :=
        (Search.Attr and Directory) <> 0;
      Inc(EntryCount);
    end;
    FindNext(Search);
  end;

  SortBrowserEntries(Entries, SortStart, EntryCount);
end;

{ Switches drives and reloads browser state for the new current directory. }
procedure ChangeBrowserDrive(NewDrive: Byte; var CurrentDrive: Byte;
  var Entries: TBrowserEntries; var EntryCount, Selected,
  FirstVisible: Word; var CurrentDirectory: String);
var
  ErrorText: String;
begin
  { Commit the UI's drive number only after DOS confirms that the requested
    device exists.  A failed floppy or absent drive therefore leaves the
    browser on the previous usable device. }
  if SelectDosDrive(NewDrive, ErrorText) then
  begin
    CurrentDrive := NewDrive;
    LoadBrowserEntries(Entries, EntryCount, CurrentDirectory);
    Selected := 0;
    FirstVisible := 0;
  end
  else
    ShowMessage('Drive', ErrorText);
end;

{ Scrolls the browser list so the selected entry remains visible. }
procedure KeepBrowserSelectionVisible(Selected: Word; var FirstVisible: Word);
begin
  if Selected < FirstVisible then
    FirstVisible := Selected
  else if Selected >= FirstVisible + BrowserVisibleRows then
    FirstVisible := Selected - BrowserVisibleRows + 1;
end;

{ Paints only DOS-detected drives and marks the active drive. }
procedure DrawBrowserDrives(CurrentDrive: Byte;
  const AvailableDrives: TDriveList; DriveCount, Focus: Byte);
var
  I, DriveIndex: Byte;
  DriveText: String;
  DriveName: String[4];
  RowAttr: Byte;
begin
  DriveText := 'Drives: ';
  if DriveCount > 0 then
    for I := 0 to DriveCount - 1 do
    begin
      DriveIndex := AvailableDrives[I];
      if DriveIndex = CurrentDrive then
        DriveName := '[' + Chr(Ord('A') + DriveIndex) + ':] '
      else
        DriveName := ' ' + Chr(Ord('A') + DriveIndex) + ':  ';
      if Length(DriveText) + Length(DriveName) <= 68 then
        DriveText := DriveText + DriveName;
    end;

  if Focus = BrowserFocusDrives then
    RowAttr := UiPopupSelectedAttr
  else
    RowAttr := UiPopupAttr;
  WriteField(6, 5, 68, DriveText, RowAttr);
end;

{ Paints the visible directory/file entries and current selection. }
procedure DrawBrowserList(const Entries: TBrowserEntries; EntryCount,
  Selected, FirstVisible: Word; Focus: Byte);
var
  Row, EntryIndex: Word;
  LabelText: String;
  RowAttr: Byte;
begin
  for Row := 0 to BrowserVisibleRows - 1 do
  begin
    EntryIndex := FirstVisible + Row;
    LabelText := '';
    if EntryIndex < EntryCount then
    begin
      if Entries[EntryIndex].IsDirectory then
        LabelText := '[DIR] ' + Entries[EntryIndex].Name
      else
        LabelText := '      ' + Entries[EntryIndex].Name;
    end;

    if (Focus = BrowserFocusList) and (EntryIndex = Selected) and
       (EntryIndex < EntryCount) then
      RowAttr := UiPopupSelectedAttr
    else
      RowAttr := UiPopupAttr;
    WriteField(7, 7 + Row, 64, LabelText, RowAttr);
  end;
end;

{ Paints the editable filename field and its current focus state. }
procedure DrawBrowserName(const FileName: String; Focus: Byte);
var
  FieldAttr: Byte;
begin
  if Focus = BrowserFocusName then
    FieldAttr := UiPopupSelectedAttr
  else
    FieldAttr := UiPopupAttr;
  WriteField(16, 19, 43, FileName, FieldAttr);
end;

{ Paints the complete Open or Save As browser dialog. }
procedure DrawFileBrowser(const Title, CurrentDirectory, FileName: String;
  SaveMode: Boolean; const Entries: TBrowserEntries; EntryCount, Selected,
  FirstVisible: Word; CurrentDrive: Byte; const AvailableDrives: TDriveList;
  DriveCount, Focus: Byte);
var
  ActionText: String;
begin
  { Mouse visibility is managed by FileDialog because this routine is also used
    for in-place repaints while the browser remains open. }
  DrawWindowSurface(3, 2, 76, 22);
  PrepareOpaqueBackdrop(6, 2, 7 + Length(Title), 2);
  PutText(6, 2, ' ' + Title + ' ', UiTitleAttr);
  WriteField(6, 4, 68, 'Path: ' + CurrentDirectory, UiPopupAttr);
  DrawBrowserDrives(CurrentDrive, AvailableDrives, DriveCount, Focus);
  WriteField(6, 6, 68, 'Name / directory', UiFrameAttr);
  DrawBrowserList(Entries, EntryCount, Selected, FirstVisible, Focus);
  WriteField(6, 19, 10, 'File name:', UiPopupAttr);
  DrawBrowserName(FileName, Focus);

  if SaveMode then
    ActionText := '[ Save ]'
  else
    ActionText := '[ Open ]';
  PutText(50, 21, ActionText, UiPopupSelectedAttr);
  PutText(61, 21, '[ Cancel ]', UiPopupAttr);
  WriteField(6, 20, 41, 'Enter/dbl-click; Tab changes area.', UiPopupAttr);
end;

{ Combines the current directory and filename into an absolute DOS path. }
procedure BuildBrowserPath(const CurrentDirectory, FileName: String;
  var FullPath: String);
begin
  FullPath := CurrentDirectory;
  if (Length(FullPath) > 0) and
     (FullPath[Length(FullPath)] <> '\') then
    FullPath := FullPath + '\';
  FullPath := FullPath + FileName;
end;

{ Enters a selected directory or accepts a selected file. }
function ActivateBrowserEntry(const Entries: TBrowserEntries; EntryCount,
  Selected: Word; var FileName: String): Boolean;
var
  Code: Integer;
begin
  { A directory activation reloads the list; a file activation supplies the
    filename and closes the dialog in either Open or Save mode. }
  ActivateBrowserEntry := False;
  if Selected >= EntryCount then
    Exit;

  if Entries[Selected].IsDirectory then
  begin
    {$I-}
    ChDir(Entries[Selected].Name);
    Code := IOResult;
    {$I+}
    if Code <> 0 then
      ShowMessage('Directory', 'Unable to enter that directory.');
  end
  else
  begin
    FileName := Entries[Selected].Name;
    ActivateBrowserEntry := True;
  end;
end;

{ Runs the modal DOS drive, directory, and filename browser. }
function FileDialog(const Title: String; SaveMode: Boolean;
  var SelectedPath: String): Boolean;
var
  Entries: TBrowserEntries;
  EntryCount, Selected, FirstVisible: Word;
  CurrentDirectory, OriginalDirectory, FileName, ErrorText: String;
  AvailableDrives: TDriveList;
  CurrentDrive, OriginalDrive, DriveCount, Focus, RequestedDrive,
  DrivePosition: Byte;
  K: TKeyEvent;
  M: TMouseState;
  LocalPreviousButtons: Word;
  CellX, CellY, ClickedEntry: Word;
  LastClickedEntry, LastClickClock, ClickClock: Word;
  Done, Accepted, RepaintAll, RepaintList, RepaintName: Boolean;
  LastClickValid, DoubleClick: Boolean;
  Code: Integer;
begin
  { Navigation is performed with ordinary DOS current-directory services.
    Cancelling restores both the original drive and its original directory. }
  FileDialog := False;
  Accepted := False;
  Done := False;
  Focus := BrowserFocusList;
  Selected := 0;
  FirstVisible := 0;
  FileName := BaseName(SelectedPath);
  LastClickedEntry := 0;
  LastClickClock := 0;
  LastClickValid := False;

  ReadDriveInformation(OriginalDrive, AvailableDrives, DriveCount);
  CurrentDrive := OriginalDrive;
  GetDir(0, OriginalDirectory);
  LoadBrowserEntries(Entries, EntryCount, CurrentDirectory);
  if EntryCount = 0 then
    Selected := 0;

  LocalPreviousButtons := 0;
  if MouseReady then
  begin
    PollMouse(M);
    LocalPreviousButtons := M.Buttons;
  end;
  if MouseReady then
    HideMouse;
  DrawFileBrowser(Title, CurrentDirectory, FileName, SaveMode, Entries,
    EntryCount, Selected, FirstVisible, CurrentDrive, AvailableDrives,
    DriveCount, Focus);
  if MouseReady then
    ShowMouse;

  repeat
    RepaintAll := False;
    RepaintList := False;
    RepaintName := False;

    { Expire the first-click latch even when the user does nothing else.  This
      also prevents the bounded sub-minute clock from matching a stale click
      after it wraps at the next minute. }
    if LastClickValid then
    begin
      ClickClock := ClockHundredths;
      if ElapsedHundredths(LastClickClock, ClickClock) >
         BrowserDoubleClickInterval then
        LastClickValid := False;
    end;

    if PollKey(K) then
    begin
      { A keyboard action interrupts any pending mouse double-click sequence. }
      LastClickValid := False;
      if K.AsciiCode = 27 then
        Done := True
      else if K.AsciiCode = 9 then
      begin
        Focus := (Focus + 1) mod 3;
        RepaintAll := True;
      end
      else if Focus = BrowserFocusDrives then
      begin
        if (K.ScanCode = ScanLeft) or (K.ScanCode = ScanUp) then
        begin
          DrivePosition := DriveListPosition(AvailableDrives, DriveCount,
                                             CurrentDrive);
          if DrivePosition = 0 then
            DrivePosition := DriveCount - 1
          else
            Dec(DrivePosition);
          RequestedDrive := AvailableDrives[DrivePosition];
          ChangeBrowserDrive(RequestedDrive, CurrentDrive, Entries,
            EntryCount, Selected, FirstVisible, CurrentDirectory);
          RepaintAll := True;
        end
        else if (K.ScanCode = ScanRight) or (K.ScanCode = ScanDown) then
        begin
          DrivePosition := DriveListPosition(AvailableDrives, DriveCount,
                                             CurrentDrive);
          DrivePosition := (DrivePosition + 1) mod DriveCount;
          RequestedDrive := AvailableDrives[DrivePosition];
          ChangeBrowserDrive(RequestedDrive, CurrentDrive, Entries,
            EntryCount, Selected, FirstVisible, CurrentDirectory);
          RepaintAll := True;
        end
        else if K.AsciiCode = 13 then
        begin
          Focus := BrowserFocusList;
          RepaintAll := True;
        end;
      end
      else if Focus = BrowserFocusList then
      begin
        if (K.ScanCode = ScanUp) and (Selected > 0) then
        begin
          Dec(Selected);
          KeepBrowserSelectionVisible(Selected, FirstVisible);
          RepaintList := True;
        end
        else if (K.ScanCode = ScanDown) and (Selected + 1 < EntryCount) then
        begin
          Inc(Selected);
          KeepBrowserSelectionVisible(Selected, FirstVisible);
          RepaintList := True;
        end
        else if K.ScanCode = ScanRollUp then
        begin
          if Selected > BrowserVisibleRows then
            Dec(Selected, BrowserVisibleRows)
          else
            Selected := 0;
          KeepBrowserSelectionVisible(Selected, FirstVisible);
          RepaintList := True;
        end
        else if K.ScanCode = ScanRollDown then
        begin
          if Selected + BrowserVisibleRows < EntryCount then
            Inc(Selected, BrowserVisibleRows)
          else if EntryCount > 0 then
            Selected := EntryCount - 1;
          KeepBrowserSelectionVisible(Selected, FirstVisible);
          RepaintList := True;
        end
        else if K.AsciiCode = 8 then
        begin
          {$I-}
          ChDir('..');
          Code := IOResult;
          {$I+}
          if Code = 0 then
          begin
            LoadBrowserEntries(Entries, EntryCount, CurrentDirectory);
            Selected := 0;
            FirstVisible := 0;
            RepaintAll := True;
          end;
        end
        else if K.AsciiCode = 13 then
        begin
          if ActivateBrowserEntry(Entries, EntryCount, Selected, FileName) then
          begin
            Accepted := True;
            Done := True;
          end
          else
          begin
            LoadBrowserEntries(Entries, EntryCount, CurrentDirectory);
            Selected := 0;
            FirstVisible := 0;
            RepaintAll := True;
          end;
        end
        else if (K.AsciiCode >= 32) and (K.AsciiCode <= 126) then
        begin
          Focus := BrowserFocusName;
          if Length(FileName) < 127 then
            FileName := FileName + Chr(K.AsciiCode);
          RepaintAll := True;
        end;
      end
      else
      begin
        if K.AsciiCode = 13 then
        begin
          Accepted := FileName <> '';
          Done := Accepted;
        end
        else if K.AsciiCode = 8 then
        begin
          if Length(FileName) > 0 then
          begin
            Delete(FileName, Length(FileName), 1);
            RepaintName := True;
          end;
        end
        else if (K.AsciiCode >= 32) and (K.AsciiCode <= 126) and
                (Length(FileName) < 127) then
        begin
          FileName := FileName + Chr(K.AsciiCode);
          RepaintName := True;
        end
        else if K.ScanCode = ScanUp then
        begin
          Focus := BrowserFocusList;
          RepaintAll := True;
        end;
      end;
    end;

    if MouseReady then
    begin
      PollMouse(M);
      if ((M.Buttons and 1) <> 0) and
         ((LocalPreviousButtons and 1) = 0) then
      begin
        CellX := M.X div 8;
        CellY := M.Y div 16;
        if CellY = 5 then
        begin
          LastClickValid := False;
          Focus := BrowserFocusDrives;
          if (CellX >= 14) and (((CellX - 14) div 5) < DriveCount) then
          begin
            DrivePosition := (CellX - 14) div 5;
            RequestedDrive := AvailableDrives[DrivePosition];
            ChangeBrowserDrive(RequestedDrive, CurrentDrive, Entries,
              EntryCount, Selected, FirstVisible, CurrentDirectory);
          end;
          RepaintAll := True;
        end
        else if (CellY >= 7) and
                (CellY < 7 + BrowserVisibleRows) then
        begin
          ClickedEntry := FirstVisible + CellY - 7;
          if ClickedEntry < EntryCount then
          begin
            ClickClock := ClockHundredths;
            DoubleClick := LastClickValid and
              (ClickedEntry = LastClickedEntry) and
              (ElapsedHundredths(LastClickClock, ClickClock) <=
               BrowserDoubleClickInterval);

            Selected := ClickedEntry;
            Focus := BrowserFocusList;
            if DoubleClick then
            begin
              { A double-click is deliberately identical to pressing Enter:
                directories (including '..') are entered and files are
                accepted.  Clearing the latch prevents a third click from
                being mistaken for a second activation. }
              LastClickValid := False;
              if ActivateBrowserEntry(Entries, EntryCount, Selected,
                                      FileName) then
              begin
                Accepted := True;
                Done := True;
              end
              else
              begin
                LoadBrowserEntries(Entries, EntryCount, CurrentDirectory);
                Selected := 0;
                FirstVisible := 0;
                RepaintAll := True;
              end;
            end
            else
            begin
              LastClickedEntry := ClickedEntry;
              LastClickClock := ClickClock;
              LastClickValid := True;
              if not Entries[Selected].IsDirectory then
              begin
                FileName := Entries[Selected].Name;
                RepaintName := True;
              end;
              RepaintAll := True;
            end;
          end
          else
            LastClickValid := False;
        end
        else if CellY = 19 then
        begin
          LastClickValid := False;
          Focus := BrowserFocusName;
          RepaintAll := True;
        end
        else if (CellY = 21) and (CellX >= 50) and (CellX <= 57) then
        begin
          LastClickValid := False;
          if Focus = BrowserFocusList then
          begin
            if ActivateBrowserEntry(Entries, EntryCount, Selected,
                                    FileName) then
            begin
              Accepted := True;
              Done := True;
            end
            else
            begin
              { A directory was entered.  Keep the browser open and refresh
                its contents instead of treating an old filename as accepted. }
              LoadBrowserEntries(Entries, EntryCount, CurrentDirectory);
              Selected := 0;
              FirstVisible := 0;
              RepaintAll := True;
            end;
          end
          else
          begin
            Accepted := FileName <> '';
            Done := Accepted;
          end;
        end
        else if (CellY = 21) and (CellX >= 61) and (CellX <= 70) then
        begin
          LastClickValid := False;
          Done := True;
        end
        else
          LastClickValid := False;
      end;
      LocalPreviousButtons := M.Buttons;
    end;

    if not Done and (RepaintAll or RepaintList or RepaintName) then
    begin
      if MouseReady then
        HideMouse;
      if RepaintAll then
        DrawFileBrowser(Title, CurrentDirectory, FileName, SaveMode, Entries,
          EntryCount, Selected, FirstVisible, CurrentDrive, AvailableDrives,
          DriveCount, Focus)
      else
      begin
        if RepaintList then
          DrawBrowserList(Entries, EntryCount, Selected, FirstVisible, Focus);
        if RepaintName then
          DrawBrowserName(FileName, Focus);
      end;
      if MouseReady then
        ShowMouse;
    end;
  until Done;

  if Accepted then
  begin
    GetDir(0, CurrentDirectory);
    BuildBrowserPath(CurrentDirectory, FileName, SelectedPath);
    FileDialog := True;
  end
  else
  begin
    { Restore the state which was active before browsing. }
    SelectDosDrive(OriginalDrive, ErrorText);
    {$I-}
    ChDir(OriginalDirectory);
    Code := IOResult;
    {$I+}
  end;
  NeedsRedraw := True;
end;

{ Loads either plain DOS text or Rich Text Format by filename extension. }
function LoadDocumentFile(const FileName: String;
  var ErrorText: String): Boolean;
begin
  if IsRtfFileName(FileName) then
    LoadDocumentFile := LoadRtfFile(FileName, Buffer^, ErrorText)
  else
    LoadDocumentFile := Buffer^.LoadFromFile(FileName, ErrorText);
end;

{ Saves either plain DOS text or Rich Text Format by filename extension. }
function SaveDocumentFile(const FileName: String;
  var ErrorText: String): Boolean;
begin
  if IsRtfFileName(FileName) then
    SaveDocumentFile := SaveRtfFile(FileName, Buffer^, ErrorText)
  else
    SaveDocumentFile := Buffer^.SaveToFile(FileName, ErrorText);
end;

{ Tests whether a named DOS file can be found. }
function DosFileExists(const FileName: String): Boolean;
var
  Search: SearchRec;
begin
  FindFirst(FileName, AnyFile, Search);
  DosFileExists := (DosError = 0) and ((Search.Attr and Directory) = 0);
end;

{ Displays a yes/no confirmation dialog and returns the chosen answer. }
function ConfirmQuestion(const Title, MessageText: String): Boolean;
var
  K: TKeyEvent;
  Done: Boolean;
begin
  ConfirmQuestion := False;
  Done := False;
  BeginDialog(10, 8, 69, 13, Title);
  WriteField(13, 10, 54, MessageText, UiPopupAttr);
  WriteField(13, 12, 54, 'Y = yes; N or Esc = no', UiPopupAttr);
  repeat
    if PollKey(K) then
    begin
      if (K.AsciiCode = Ord('y')) or (K.AsciiCode = Ord('Y')) then
      begin
        ConfirmQuestion := True;
        Done := True;
      end
      else if (K.AsciiCode = Ord('n')) or (K.AsciiCode = Ord('N')) or
              (K.AsciiCode = 27) then
        Done := True;
    end;
  until Done;
  EndDialog;
end;


{ Saves to the current path or obtains a path through Save As. }
function SaveDocument(ForceDialog: Boolean): Boolean;
var
  Name, ErrorText: String;
  ConfirmOverwrite: Boolean;
begin
  { Save and Save As share one implementation.  Save As merely forces the
    browser to run; ordinary Save reuses CurrentFile when it is available. }
  SaveDocument := False;
  Name := CurrentFile;
  if ForceDialog or (Name = '') then
    if not FileDialog('Save As', True, Name) then
      Exit;

  ConfirmOverwrite := DosFileExists(Name) and (Name <> CurrentFile);
  if ConfirmOverwrite and
     (not ConfirmQuestion('Save As', 'Replace the existing file?')) then
    Exit;

  if SaveDocumentFile(Name, ErrorText) then
  begin
    CurrentFile := Name;
    NeedsRedraw := True;
    SaveDocument := True;
  end
  else
    ShowMessage('Save Error', ErrorText);
end;

{ Confirms whether unsaved document changes may be discarded. }
function ConfirmDiscard: Boolean;
var
  K: TKeyEvent;
  Choice: Char;
  Done: Boolean;
begin
  if not Buffer^.Dirty then
  begin
    ConfirmDiscard := True;
    Exit;
  end;

  { Finish the three-way dialog before opening the file browser.  This avoids
    nesting mouse show/hide operations when the user chooses Save. }
  Choice := #0;
  Done := False;
  BeginDialog(10, 8, 69, 13, 'Unsaved changes');
  WriteField(13, 10, 54, 'S = save, D = discard, Esc = cancel', UiPopupAttr);
  repeat
    if PollKey(K) then
    begin
      if (K.AsciiCode = Ord('s')) or (K.AsciiCode = Ord('S')) then
      begin
        Choice := 'S';
        Done := True;
      end
      else if (K.AsciiCode = Ord('d')) or (K.AsciiCode = Ord('D')) then
      begin
        Choice := 'D';
        Done := True;
      end
      else if K.AsciiCode = 27 then
        Done := True;
    end;
  until Done;
  EndDialog;

  if Choice = 'S' then
    ConfirmDiscard := SaveDocument(False)
  else
    ConfirmDiscard := Choice = 'D';
end;

{ Returns caret, viewport, and selection state to the document origin. }
procedure ResetViewAndSelection;
begin
  CursorLine := 0;
  CursorColumn := 0;
  TopLine := 0;
  LeftColumn := 0;
  ClearSelection;
  SyncTypingFontToCaret;
end;

{ Creates an empty document after protecting unsaved work. }
procedure NewDocument;
begin
  if not ConfirmDiscard then
    Exit;
  Buffer^.Init;
  CurrentFile := '';
  ResetViewAndSelection;
  NeedsRedraw := True;
end;

{ Selects and loads a text file after protecting unsaved work. }
procedure OpenDocument;
var
  Name, ErrorText: String;
begin
  if not ConfirmDiscard then
    Exit;

  Name := CurrentFile;
  if not FileDialog('Open', False, Name) then
    Exit;

  if LoadDocumentFile(Name, ErrorText) then
  begin
    CurrentFile := Name;
    ResetViewAndSelection;
    NeedsRedraw := True;
    if ErrorText <> '' then
      ShowMessage('Open', ErrorText);
  end
  else
    ShowMessage('Open Error', ErrorText);
end;

{ Sends the current in-memory document, including unsaved changes, to PRN. }
procedure PrintCommand;
var
  TotalPages, FirstPage, LastPage: LongInt;
  ErrorText, FirstText, LastText: String;
  Printed, RangeMode: Boolean;
  Margins: TPrintMargins;
  Paper: TPrintPaper;
begin
  if not PromptPrintOptions(RangeMode, Paper, Margins) then
    Exit;

  if not CountDocumentPages(Buffer^, Paper, Margins, TotalPages, ErrorText) then
  begin
    ShowMessage('Print Error', ErrorText);
    Exit;
  end;

  FirstPage := 1;
  LastPage := TotalPages;
  if RangeMode then
    if not PromptPrintRangeDialog(TotalPages, FirstPage, LastPage) then
      Exit;

  Str(FirstPage, FirstText);
  Str(LastPage, LastText);
  BeginDialog(12, 8, 67, 13, 'Print');
  WriteField(15, 10, 50, 'Sending pages ' + FirstText + ' through ' +
    LastText + ' to ' + DefaultPrinterDevice + '...', UiPopupAttr);
  WriteField(15, 11, 50, 'Please wait for the DOS printer device.',
    UiPopupAttr);
  Printed := PrintDocumentPages(Buffer^, FirstPage, LastPage, Paper, Margins,
    DefaultPrinterDevice, ErrorText);
  EndDialog;

  { Printer device calls can disturb the PC-98 display/controller state on some
    DOS/emulator combinations.  Rebuild both the graphics backdrop and native
    text viewport immediately after returning from PRN, before opening the
    result message.  This also guarantees that any temporary screen damage is
    not left visible until the next event-loop redraw. }
  HideMouse;
  GraphicsBackdropDirty := True;
  InvalidateViewportCache;
  DrawDocument;
  NeedsRedraw := False;
  if MouseReady then
    ShowMouse;

  if Printed then
    ShowMessage('Print', 'Pages ' + FirstText + ' through ' + LastText +
      ' were sent to ' + DefaultPrinterDevice + '.')
  else
    ShowMessage('Print Error', ErrorText);
end;

{ Clears the fixed popup-menu label array. }
procedure ClearPopupLabels(var Labels: TPopupLabels);
var
  I: Byte;
begin
  for I := 0 to MaxPopupItems - 1 do
    Labels[I] := '';
end;

{ Clears the popup access-key position array. }
procedure ClearPopupAccelerators(var Accelerators: TPopupAccelerators);
var
  I: Byte;
begin
  for I := 0 to MaxPopupItems - 1 do
    Accelerators[I] := 0;
end;

{ Paints one popup item with selection and accelerator underline. }
procedure DrawPopupItem(MenuX, MenuWidth, ItemIndex: Byte;
  Selected: Boolean; const Labels: TPopupLabels;
  const Accelerators: TPopupAccelerators);
var
  Attr, AcceleratorPosition: Byte;
begin
  if Selected then
    Attr := UiPopupSelectedAttr
  else
    Attr := UiPopupAttr;

  WriteField(MenuX + 2, 2 + ItemIndex, MenuWidth - 3,
    Labels[ItemIndex], Attr);

  AcceleratorPosition := Accelerators[ItemIndex];
  if (AcceleratorPosition > 0) and
     (AcceleratorPosition <= Length(Labels[ItemIndex])) and
     (AcceleratorPosition <= MenuWidth - 3) then
    PutCell(MenuX + 1 + AcceleratorPosition, 2 + ItemIndex,
      Labels[ItemIndex][AcceleratorPosition], Attr or AttrUnderline);
end;

{ Paints a complete popup menu surface and all of its items. }
procedure DrawPopupWindow(MenuX, MenuWidth, ItemCount, Selected: Byte;
  const Labels: TPopupLabels; const Accelerators: TPopupAccelerators);
var
  I: Byte;
begin
  DrawWindowSurface(MenuX, 1, MenuX + MenuWidth, ItemCount + 2);
  for I := 0 to ItemCount - 1 do
    DrawPopupItem(MenuX, MenuWidth, I, I = Selected, Labels, Accelerators);
end;

{ Repaints only the old and new highlighted popup rows. }
procedure DrawPopupSelection(MenuX, MenuWidth: Byte;
  OldSelected, NewSelected: Byte; const Labels: TPopupLabels;
  const Accelerators: TPopupAccelerators);
begin
  if OldSelected = NewSelected then
    Exit;
  DrawPopupItem(MenuX, MenuWidth, OldSelected, False, Labels, Accelerators);
  DrawPopupItem(MenuX, MenuWidth, NewSelected, True, Labels, Accelerators);
end;

{ Matches a key event against popup access letters. }
function PopupAcceleratorChoice(const K: TKeyEvent; ItemCount: Byte;
  const Labels: TPopupLabels; const Accelerators: TPopupAccelerators): Integer;
var
  I, Position: Byte;
  Letter: Char;
begin
  PopupAcceleratorChoice := -1;
  Letter := KeyLetter(K);
  if Letter = #0 then
    Exit;

  for I := 0 to ItemCount - 1 do
  begin
    Position := Accelerators[I];
    if (Position > 0) and (Position <= Length(Labels[I])) and
       (UpperAscii(Labels[I][Position]) = Letter) then
    begin
      PopupAcceleratorChoice := I;
      Exit;
    end;
  end;
end;

{ Runs a reusable keyboard-and-mouse popup menu and returns its choice. }
function PopupMenu(MenuX, MenuWidth, ItemCount: Byte;
  const Labels: TPopupLabels; const Accelerators: TPopupAccelerators;
  InitialSelection: Byte): Integer;
var
  Selected, OldSelected: Byte;
  AcceleratorChoice: Integer;
  K: TKeyEvent;
  M: TMouseState;
  LocalPreviousButtons: Word;
  CellX, CellY: Word;
  Done, Cancelled: Boolean;
begin
  Selected := InitialSelection mod ItemCount;
  Done := False;
  Cancelled := False;
  LocalPreviousButtons := 0;
  if MouseReady then
  begin
    PollMouse(M);
    LocalPreviousButtons := M.Buttons;
    HideMouse;
  end;

  DrawPopupWindow(MenuX, MenuWidth, ItemCount, Selected, Labels, Accelerators);
  if MouseReady then
    ShowMouse;

  repeat
    if PollKey(K) then
    begin
      OldSelected := Selected;
      AcceleratorChoice := -1;
      if K.ScanCode = ScanUp then
      begin
        if Selected = 0 then
          Selected := ItemCount - 1
        else
          Dec(Selected);
      end
      else if K.ScanCode = ScanDown then
        Selected := (Selected + 1) mod ItemCount
      else if K.AsciiCode = 13 then
        Done := True
      else if K.AsciiCode = 27 then
      begin
        Cancelled := True;
        Done := True;
      end
      else
      begin
        AcceleratorChoice := PopupAcceleratorChoice(K, ItemCount,
          Labels, Accelerators);
        if AcceleratorChoice >= 0 then
        begin
          Selected := AcceleratorChoice;
          Done := True;
        end;
      end;

      if OldSelected <> Selected then
      begin
        if MouseReady then
          HideMouse;
        DrawPopupSelection(MenuX, MenuWidth, OldSelected, Selected,
          Labels, Accelerators);
        if MouseReady then
          ShowMouse;
      end;
    end;

    if MouseReady then
    begin
      PollMouse(M);
      if ((M.Buttons and 1) <> 0) and ((LocalPreviousButtons and 1) = 0) then
      begin
        CellX := M.X div 8;
        CellY := M.Y div 16;
        if (CellX >= MenuX + 2) and
           (CellX <= MenuX + MenuWidth - 2) and
           (CellY >= 2) and (CellY < 2 + ItemCount) then
        begin
          Selected := CellY - 2;
          Done := True;
        end
        else if not ((CellX >= MenuX) and
                     (CellX <= MenuX + MenuWidth) and
                     (CellY >= 1) and (CellY <= ItemCount + 2)) then
        begin
          Cancelled := True;
          Done := True;
        end;
      end;
      LocalPreviousButtons := M.Buttons;
    end;
  until Done;

  if Cancelled then
    PopupMenu := -1
  else
    PopupMenu := Selected;
  NeedsRedraw := True;
end;

{ Copies the active range into the fixed internal clipboard. }
function CopySelection(const DialogTitle: String): Boolean;
var
  StartLine, StartColumn, EndLine, EndColumn: Word;
  ErrorText: String;
begin
  { Cut calls this same routine before deleting, so clipboard validation and
    user-facing errors cannot drift away from the Copy command. }
  CopySelection := False;
  if not SelectionActive then
  begin
    ShowMessage(DialogTitle,
      'Select text first with Shift+arrows or the mouse.');
    Exit;
  end;

  GetSelectionBounds(StartLine, StartColumn, EndLine, EndColumn);
  if Buffer^.CopyRange(StartLine, StartColumn, EndLine, EndColumn,
                      Clipboard^, ErrorText) then
    CopySelection := True
  else
    ShowMessage(DialogTitle, ErrorText);
end;

{ Deletes the active range after validating it. }
function RemoveSelection(const DialogTitle: String): Boolean;
var
  StartLine, StartColumn, EndLine, EndColumn: Word;
  ErrorText: String;
begin
  RemoveSelection := True;
  if not SelectionActive then
    Exit;

  GetSelectionBounds(StartLine, StartColumn, EndLine, EndColumn);
  if Buffer^.DeleteRange(StartLine, StartColumn, EndLine, EndColumn,
                        ErrorText) then
  begin
    CursorLine := StartLine;
    CursorColumn := StartColumn;
    ClearSelection;
    EnsureCursorVisible;
    NeedsRedraw := True;
  end
  else
  begin
    ShowMessage(DialogTitle, ErrorText);
    RemoveSelection := False;
  end;
end;

{ Copies and then removes the active selection atomically. }
procedure CutSelection;
begin
  { Copy first and only delete after a successful clipboard operation. }
  if CopySelection('Cut') then
    if RemoveSelection('Cut') then
      NeedsRedraw := True;
end;

{ Deletes a selection or the character at the caret. }
procedure DeleteForward;
begin
  { Both the Edit menu and the Delete key use exactly the same decision. }
  if SelectionActive then
  begin
    if RemoveSelection('Delete') then
      NeedsRedraw := True;
  end
  else
    Buffer^.DeleteAt(CursorLine, CursorColumn);
end;

{ Pastes clipboard text at the caret or over the selection. }
procedure PasteClipboard;
var
  StartLine, StartColumn, EndLine, EndColumn: Word;
  ErrorText: String;
begin
  if Clipboard^.Count = 0 then
  begin
    ShowMessage('Paste', 'The clipboard is empty.');
    Exit;
  end;

  if SelectionActive then
  begin
    GetSelectionBounds(StartLine, StartColumn, EndLine, EndColumn);
    if not Buffer^.ReplaceRangeWithClipboard(StartLine, StartColumn,
      EndLine, EndColumn, CursorLine, CursorColumn, Clipboard^,
      ErrorText) then
    begin
      ShowMessage('Paste', ErrorText);
      Exit;
    end;
  end
  else if not Buffer^.ReplaceRangeWithClipboard(CursorLine, CursorColumn,
    CursorLine, CursorColumn, CursorLine, CursorColumn, Clipboard^,
    ErrorText) then
  begin
    ShowMessage('Paste', ErrorText);
    Exit;
  end;

  ClearSelection;
  SyncTypingFontToCaret;
  EnsureCursorVisible;
  NeedsRedraw := True;
end;

{ Selects the entire document from its first to final position. }
procedure SelectAll;
begin
  SelectionAnchorLine := 0;
  SelectionAnchorColumn := 0;
  CursorLine := Buffer^.Count - 1;
  CursorColumn := Length(Buffer^.LinePtr(CursorLine)^);
  Buffer^.TypingFont := Buffer^.InsertionFontAt(0, 0);
  SelectionActive := (SelectionAnchorLine <> CursorLine) or
    (SelectionAnchorColumn <> CursorColumn);
  EnsureCursorVisible;
  NeedsRedraw := True;
end;

{ Compares two characters according to the Match Case option. }
function CharactersEqual(A, B: Char): Boolean;
begin
  if MatchCase then
    CharactersEqual := A = B
  else
    CharactersEqual := UpCase(A) = UpCase(B);
end;

{ Searches one line for a needle beginning at a specified column. }
function FindInLine(const LineText, Needle: String;
  StartColumn: Word): Integer;
var
  I, J, LastStart: Word;
  Matches: Boolean;
begin
  FindInLine := -1;
  if (Needle = '') or (Length(Needle) > Length(LineText)) then
    Exit;
  if StartColumn > Length(LineText) then
    Exit;

  LastStart := Length(LineText) - Length(Needle);
  if StartColumn > LastStart then
    Exit;

  for I := StartColumn to LastStart do
  begin
    Matches := True;
    for J := 1 to Length(Needle) do
      if not CharactersEqual(LineText[I + J], Needle[J]) then
      begin
        Matches := False;
        Break;
      end;
    if Matches then
    begin
      FindInLine := I;
      Exit;
    end;
  end;
end;

{ Searches forward from a document position and wraps once. }
function FindFrom(StartLine, StartColumn: Word;
  var FoundLine, FoundColumn: Word): Boolean;
var
  LineIndex: Word;
  FoundAt: Integer;
begin
  FindFrom := False;
  if LastFind = '' then
    Exit;
  if StartLine >= Buffer^.Count then
    StartLine := 0;

  for LineIndex := StartLine to Buffer^.Count - 1 do
  begin
    if LineIndex = StartLine then
      FoundAt := FindInLine(Buffer^.LinePtr(LineIndex)^, LastFind, StartColumn)
    else
      FoundAt := FindInLine(Buffer^.LinePtr(LineIndex)^, LastFind, 0);
    if FoundAt >= 0 then
    begin
      FoundLine := LineIndex;
      FoundColumn := FoundAt;
      FindFrom := True;
      Exit;
    end;
  end;

  if StartLine > 0 then
    for LineIndex := 0 to StartLine - 1 do
    begin
      FoundAt := FindInLine(Buffer^.LinePtr(LineIndex)^, LastFind, 0);
      if FoundAt >= 0 then
      begin
        FoundLine := LineIndex;
        FoundColumn := FoundAt;
        FindFrom := True;
        Exit;
      end;
    end;

  FoundAt := FindInLine(Buffer^.LinePtr(StartLine)^, LastFind, 0);
  if (FoundAt >= 0) and (FoundAt < StartColumn) then
  begin
    FoundLine := StartLine;
    FoundColumn := FoundAt;
    FindFrom := True;
  end;
end;

{ Moves the caret to a match and selects exactly its text. }
procedure SelectFoundMatch(FoundLine, FoundColumn: Word);
begin
  SelectionAnchorLine := FoundLine;
  SelectionAnchorColumn := FoundColumn;
  CursorLine := FoundLine;
  CursorColumn := FoundColumn + Length(LastFind);
  Buffer^.TypingFont := Buffer^.InsertionFontAt(FoundLine, FoundColumn);
  SelectionActive := (SelectionAnchorLine <> CursorLine) or
    (SelectionAnchorColumn <> CursorColumn);
  EnsureCursorVisible;
  NeedsRedraw := True;
end;

{ Finds and selects the next occurrence of the stored search text. }
function FindNextMatch: Boolean;
var
  StartLine, StartColumn, EndLine, EndColumn: Word;
  FoundLine, FoundColumn: Word;
begin
  FindNextMatch := False;
  if LastFind = '' then
    Exit;

  if SelectionActive then
  begin
    GetSelectionBounds(StartLine, StartColumn, EndLine, EndColumn);
    StartLine := EndLine;
    StartColumn := EndColumn;
  end
  else
  begin
    StartLine := CursorLine;
    StartColumn := CursorColumn;
  end;

  if FindFrom(StartLine, StartColumn, FoundLine, FoundColumn) then
  begin
    SelectFoundMatch(FoundLine, FoundColumn);
    FindNextMatch := True;
  end;
end;

{ Prompts for search text when needed and starts a search. }
procedure FindCommand(PromptForNewText: Boolean);
var
  SearchText: String;
begin
  if PromptForNewText or (LastFind = '') then
  begin
    SearchText := LastFind;
    if not PromptStringEx('Find', 'Find what:', SearchText, False) then
      Exit;
    LastFind := SearchText;
    ClearSelection;
  end;

  if not FindNextMatch then
    ShowMessage('Find', 'Text not found: ' + LastFind);
end;

{ Finds the next match and replaces it with the requested text. }
procedure ReplaceNextCommand;
var
  SearchText, ReplacementText, ErrorText: String;
  StartLine, StartColumn, EndLine, EndColumn, NewColumn: Word;
begin
  SearchText := LastFind;
  if not PromptStringEx('Replace', 'Find what:', SearchText, False) then
    Exit;
  ReplacementText := LastReplace;
  if not PromptStringEx('Replace', 'Replace with:', ReplacementText, True) then
    Exit;
  LastFind := SearchText;
  LastReplace := ReplacementText;
  ClearSelection;

  if not FindNextMatch then
  begin
    ShowMessage('Replace', 'Text not found: ' + LastFind);
    Exit;
  end;

  GetSelectionBounds(StartLine, StartColumn, EndLine, EndColumn);
  if Buffer^.ReplaceTextAt(StartLine, StartColumn, Length(LastFind),
    LastReplace, NewColumn, ErrorText) then
  begin
    CursorLine := StartLine;
    CursorColumn := NewColumn;
    ClearSelection;
    SyncTypingFontToCaret;
    EnsureCursorVisible;
    NeedsRedraw := True;
  end
  else
    ShowMessage('Replace', ErrorText);
end;

{ Replaces every matching occurrence and reports the total. }
procedure ReplaceAllCommand;
var
  SearchText, ReplacementText, ErrorText: String;
  LineIndex, Column, NewColumn, ReplacedCount: Word;
  FoundAt: Integer;
begin
  SearchText := LastFind;
  if not PromptStringEx('Replace All', 'Find what:', SearchText, False) then
    Exit;
  ReplacementText := LastReplace;
  if not PromptStringEx('Replace All', 'Replace with:', ReplacementText,
                        True) then
    Exit;
  LastFind := SearchText;
  LastReplace := ReplacementText;
  ClearSelection;

  ReplacedCount := 0;
  LineIndex := 0;
  Column := 0;
  while LineIndex < Buffer^.Count do
  begin
    FoundAt := FindInLine(Buffer^.LinePtr(LineIndex)^, LastFind, Column);
    if FoundAt >= 0 then
    begin
      if not Buffer^.ReplaceTextAt(LineIndex, FoundAt, Length(LastFind),
        LastReplace, NewColumn, ErrorText) then
      begin
        ShowMessage('Replace All', ErrorText);
        Exit;
      end;
      Inc(ReplacedCount);
      Column := NewColumn;
    end
    else
    begin
      Inc(LineIndex);
      Column := 0;
    end;
  end;

  CursorLine := 0;
  CursorColumn := 0;
  ClearSelection;
  SyncTypingFontToCaret;
  EnsureCursorVisible;
  Str(ReplacedCount, ReplacementText);
  ShowMessage('Replace All', ReplacementText + ' occurrence(s) replaced.');
end;

{ Builds and runs the File command menu. }
procedure FileMenu;
var
  Labels: TPopupLabels;
  Accelerators: TPopupAccelerators;
  Choice: Integer;
begin
  ClearPopupLabels(Labels);
  ClearPopupAccelerators(Accelerators);
  Labels[0] := 'New';
  Labels[1] := 'Open...          F3';
  Labels[2] := 'Save             F2';
  Labels[3] := 'Save As...';
  Labels[4] := 'Print...      Ctrl+P';
  Labels[5] := 'Exit              Esc';
  Accelerators[0] := 1;  { New }
  Accelerators[1] := 1;  { Open }
  Accelerators[2] := 1;  { Save }
  Accelerators[3] := 6;  { Save As }
  Accelerators[4] := 1;  { Print }
  Accelerators[5] := 2;  { Exit }
  Choice := PopupMenu(0, 27, 6, Labels, Accelerators, 0);
  case Choice of
    0: NewDocument;
    1: OpenDocument;
    2: if SaveDocument(False) then NeedsRedraw := True;
    3: if SaveDocument(True) then NeedsRedraw := True;
    4: PrintCommand;
    5: if ConfirmDiscard then Running := False;
  end;
end;

{ Builds and runs the Edit command menu. }
procedure EditMenu;
var
  Labels: TPopupLabels;
  Accelerators: TPopupAccelerators;
  Choice: Integer;
begin
  ClearPopupLabels(Labels);
  ClearPopupAccelerators(Accelerators);
  Labels[0] := 'Cut          Shift+Del';
  Labels[1] := 'Copy          Ctrl+Ins';
  Labels[2] := 'Paste        Shift+Ins';
  Labels[3] := 'Delete             Del';
  Labels[4] := 'Select All       Ctrl+A';
  Accelerators[0] := 3;  { Cut }
  Accelerators[1] := 1;  { Copy }
  Accelerators[2] := 1;  { Paste }
  Accelerators[3] := 1;  { Delete }
  Accelerators[4] := 8;  { Select All }
  Choice := PopupMenu(6, 28, 5, Labels, Accelerators, 0);
  case Choice of
    0: CutSelection;
    1: if CopySelection('Copy') then NeedsRedraw := True;
    2: PasteClipboard;
    3: DeleteForward;
    4: SelectAll;
  end;
end;

{ Builds and runs the Search command menu. }
procedure SearchMenu;
var
  Labels: TPopupLabels;
  Accelerators: TPopupAccelerators;
  Choice: Integer;
begin
  ClearPopupLabels(Labels);
  ClearPopupAccelerators(Accelerators);
  Labels[0] := 'Find...          Ctrl+F';
  Labels[1] := 'Find Next           F4';
  Labels[2] := 'Replace...';
  Labels[3] := 'Replace All...';
  if MatchCase then
    Labels[4] := '[X] Match Case'
  else
    Labels[4] := '[ ] Match Case';
  Accelerators[0] := 1;  { Find }
  Accelerators[1] := 6;  { Find Next }
  Accelerators[2] := 1;  { Replace }
  Accelerators[3] := 9;  { Replace All }
  Accelerators[4] := 5;  { Match Case }
  Choice := PopupMenu(12, 27, 5, Labels, Accelerators, 0);
  case Choice of
    0: FindCommand(True);
    1: FindCommand(False);
    2: ReplaceNextCommand;
    3: ReplaceAllCommand;
    4:
      begin
        MatchCase := not MatchCase;
        SaveSettings;
        NeedsRedraw := True;
      end;
  end;
end;



{ Builds and runs the Help menu for the tutorial and About dialog. }
procedure HelpMenu;
var
  Labels: TPopupLabels;
  Accelerators: TPopupAccelerators;
  Choice: Integer;
begin
  ClearPopupLabels(Labels);
  ClearPopupAccelerators(Accelerators);
  Labels[0] := 'Tutorial...       HELP';
  Labels[1] := 'About EDIT98...';
  Accelerators[0] := 1;  { Tutorial }
  Accelerators[1] := 1;  { About }
  Choice := PopupMenu(30, 25, 2, Labels, Accelerators, 0);
  case Choice of
    0: ShowHelpTutorial;
    1: ShowMessage('About EDIT98',
      'EDIT98 0.7.13 - paged PC-98 editor with paper templates and print margins.');
  end;
end;

{ Builds live labels reflecting every current option value. }
procedure BuildOptionsLabels(var Labels: TPopupLabels);
var
  NumberText, SpeedText, SchemeText: String;
begin
  ClearPopupLabels(Labels);
  Str(TabWidth, NumberText);
  Labels[0] := 'Tab Width: ' + NumberText;

  if InsertMode then
    Labels[1] := 'Typing Mode: Insert'
  else
    Labels[1] := 'Typing Mode: Overwrite';

  if AutoIndent then
    Labels[2] := '[X] Auto Indent'
  else
    Labels[2] := '[ ] Auto Indent';

  case MouseSpeedSetting of
    MouseSpeedSlow: SpeedText := 'Slow';
    MouseSpeedNormal: SpeedText := 'Normal';
    else SpeedText := 'Fast';
  end;
  Labels[3] := 'Mouse Speed: ' + SpeedText;

  case ColorScheme of
    SchemeDOSEdit: SchemeText := 'MS-DOS Edit';
    SchemeAmber: SchemeText := 'Amber';
    SchemeGreen: SchemeText := 'Green';
    SchemeMonochrome: SchemeText := 'Monochrome';
    else SchemeText := 'PC-98 Cyan';
  end;
  Labels[4] := 'Colors: ' + SchemeText;

  if ShowPageBreaks then
    Labels[5] := '[X] Show Page Breaks'
  else
    Labels[5] := '[ ] Show Page Breaks';
end;


{ Changes or toggles the selected option and applies immediate effects. }
procedure ChangeOption(Choice: Byte);
begin
  { Changing an item does not dismiss the Options menu.  The caller rebuilds
    the labels and repaints either the changed row or the complete themed UI. }
  case Choice of
    0:
      case TabWidth of
        2: TabWidth := 4;
        4: TabWidth := 8;
        else TabWidth := 2;
      end;
    1: InsertMode := not InsertMode;
    2: AutoIndent := not AutoIndent;
    3:
      begin
        MouseSpeedSetting := (MouseSpeedSetting + 1) mod 3;
        ApplyMouseSpeed;
      end;
    4:
      begin
        ColorScheme := (ColorScheme + 1) mod ColorSchemeCount;
        ApplyColorScheme;
      end;
    5:
      begin
        ShowPageBreaks := not ShowPageBreaks;
        InvalidateViewportCache;
      end;
  end;
  SaveSettings;
end;

{ Runs the persistent options popup and repaints changed settings. }
procedure OptionsMenu;
const
  MenuX = 20;
  MenuWidth = 34;
  ItemCount = 6;
var
  Labels: TPopupLabels;
  Accelerators: TPopupAccelerators;
  Selected, OldSelected: Byte;
  AcceleratorChoice: Integer;
  K: TKeyEvent;
  M: TMouseState;
  LocalPreviousButtons: Word;
  CellX, CellY: Word;
  Done, ApplyChoice: Boolean;
begin
  { This menu owns its event loop instead of using PopupMenu because options
    are immediate settings.  Enter or a click applies the highlighted item and
    leaves the menu open; Esc or an outside click closes it. }
  Selected := 0;
  Done := False;
  LocalPreviousButtons := 0;
  BuildOptionsLabels(Labels);
  ClearPopupAccelerators(Accelerators);
  Accelerators[0] := 1;  { Tab Width }
  Accelerators[1] := 2;  { Typing Mode }
  Accelerators[2] := 5;  { Auto Indent }
  Accelerators[3] := 1;  { Mouse Speed }
  Accelerators[4] := 1;  { Colors }
  Accelerators[5] := 10;  { Show Page Breaks: P }

  if MouseReady then
  begin
    PollMouse(M);
    LocalPreviousButtons := M.Buttons;
    HideMouse;
  end;
  DrawPopupWindow(MenuX, MenuWidth, ItemCount, Selected, Labels, Accelerators);
  if MouseReady then
    ShowMouse;

  repeat
    ApplyChoice := False;
    if PollKey(K) then
    begin
      OldSelected := Selected;
      if K.ScanCode = ScanUp then
      begin
        if Selected = 0 then
          Selected := ItemCount - 1
        else
          Dec(Selected);
      end
      else if K.ScanCode = ScanDown then
        Selected := (Selected + 1) mod ItemCount
      else if K.AsciiCode = 13 then
        ApplyChoice := True
      else if K.AsciiCode = 27 then
        Done := True
      else
      begin
        AcceleratorChoice := PopupAcceleratorChoice(K, ItemCount,
          Labels, Accelerators);
        if AcceleratorChoice >= 0 then
        begin
          Selected := AcceleratorChoice;
          ApplyChoice := True;
        end;
      end;

      if OldSelected <> Selected then
      begin
        if MouseReady then
          HideMouse;
        DrawPopupSelection(MenuX, MenuWidth, OldSelected, Selected, Labels, Accelerators);
        if MouseReady then
          ShowMouse;
      end;
    end;

    if MouseReady then
    begin
      PollMouse(M);
      if ((M.Buttons and 1) <> 0) and
         ((LocalPreviousButtons and 1) = 0) then
      begin
        CellX := M.X div 8;
        CellY := M.Y div 16;
        if (CellX >= MenuX + 2) and
           (CellX <= MenuX + MenuWidth - 2) and
           (CellY >= 2) and (CellY < 2 + ItemCount) then
        begin
          OldSelected := Selected;
          Selected := CellY - 2;
          if OldSelected <> Selected then
          begin
            HideMouse;
            DrawPopupSelection(MenuX, MenuWidth, OldSelected, Selected, Labels, Accelerators);
            ShowMouse;
          end;
          ApplyChoice := True;
        end
        else if not ((CellX >= MenuX) and
                     (CellX <= MenuX + MenuWidth) and
                     (CellY >= 1) and (CellY <= ItemCount + 2)) then
          Done := True;
      end;
      LocalPreviousButtons := M.Buttons;
    end;

    if ApplyChoice and (not Done) then
    begin
      ChangeOption(Selected);
      BuildOptionsLabels(Labels);
      if MouseReady then
        HideMouse;
      if (Selected = 4) or (Selected = 5) then
      begin
        { A theme or page-break visibility change repaints the document once
          and then restores the still-open Options window on top. }
        DrawDocument;
        DrawPopupWindow(MenuX, MenuWidth, ItemCount, Selected, Labels, Accelerators);
      end
      else
        DrawPopupItem(MenuX, MenuWidth, Selected, True, Labels, Accelerators);
      if MouseReady then
        ShowMouse;
    end;
  until Done;

  NeedsRedraw := True;
end;

{ Synchronizes edge-detection state with the current mouse buttons. }
procedure SyncMouseButtons;
var
  M: TMouseState;
begin
  if MouseReady then
  begin
    PollMouse(M);
    PreviousButtons := M.Buttons;
  end;
end;

{ Dispatches one top-level menu index to its command menu. }
procedure OpenTopMenu(MenuIndex: Byte);
begin
  case MenuIndex of
    0: FileMenu;
    1: EditMenu;
    2: SearchMenu;
    3: OptionsMenu;
    4: HelpMenu;
  end;
  SyncMouseButtons;
end;

{ Maps a top-menu access letter to its menu index. }
function TopMenuAccelerator(const K: TKeyEvent): Integer;
begin
  case KeyLetter(K) of
    'F': TopMenuAccelerator := 0;
    'E': TopMenuAccelerator := 1;
    'S': TopMenuAccelerator := 2;
    'O': TopMenuAccelerator := 3;
    'H': TopMenuAccelerator := 4;
    else TopMenuAccelerator := -1;
  end;
end;

{ Maps a menu-bar screen column to its top-level menu index. }
function TopMenuAtColumn(CellX: Word): Integer;
begin
  if (CellX >= 1) and (CellX <= 5) then
    TopMenuAtColumn := 0
  else if (CellX >= 7) and (CellX <= 11) then
    TopMenuAtColumn := 1
  else if (CellX >= 13) and (CellX <= 19) then
    TopMenuAtColumn := 2
  else if (CellX >= 21) and (CellX <= 28) then
    TopMenuAtColumn := 3
  else if (CellX >= 30) and (CellX <= 34) then
    TopMenuAtColumn := 4
  else
    TopMenuAtColumn := -1;
end;

{ Runs menu-bar keyboard and mouse navigation before opening a menu. }
procedure ActivateMenuBar(InitialMenu: Byte);
var
  Selected, OldSelected: Byte;
  MenuChoice: Integer;
  K: TKeyEvent;
  M: TMouseState;
  CellX, CellY: Word;
  LocalPreviousButtons: Word;
  CurrentModifiers, LastModifiers: Byte;
  Done, OpenSelected: Boolean;
begin
  Selected := InitialMenu mod 5;
  Done := False;
  OpenSelected := False;
  MenuAcceleratorsVisible := True;
  LocalPreviousButtons := 0;
  LastModifiers := ReadShiftState;

  if MouseReady then
  begin
    PollMouse(M);
    LocalPreviousButtons := M.Buttons;
    HideMouse;
  end;
  DrawTopMenuBar(Selected, True, False);
  if MouseReady then
    ShowMouse;

  repeat
    OldSelected := Selected;
    if PollKey(K) then
    begin
      { A buffered GRPH make event can still be pending when activation was
        detected through the modifier state.  Ignore that event here; the
        second GRPH press is detected by the rising-edge check below. }
      if (K.ScanCode = ScanNfer) or (K.ScanCode = ScanXfer) then
        Done := True
      else if K.ScanCode = ScanLeft then
      begin
        if Selected = 0 then Selected := 4 else Dec(Selected);
      end
      else if K.ScanCode = ScanRight then
        Selected := (Selected + 1) mod 5
      else if (K.ScanCode = ScanDown) or (K.ScanCode = ScanUp) or
              (K.AsciiCode = 13) then
      begin
        OpenSelected := True;
        Done := True;
      end
      else if K.AsciiCode = 27 then
        Done := True
      else
      begin
        MenuChoice := TopMenuAccelerator(K);
        if MenuChoice >= 0 then
        begin
          Selected := MenuChoice;
          OpenSelected := True;
          Done := True;
        end;
      end;
    end;

    CurrentModifiers := ReadShiftState;
    if ((CurrentModifiers and GraphPressed) <> 0) and
       ((LastModifiers and GraphPressed) = 0) then
      Done := True;
    LastModifiers := CurrentModifiers;

    if MouseReady then
    begin
      PollMouse(M);
      if ((M.Buttons and 1) <> 0) and ((LocalPreviousButtons and 1) = 0) then
      begin
        CellX := M.X div 8;
        CellY := M.Y div 16;
        if CellY = 0 then
        begin
          MenuChoice := TopMenuAtColumn(CellX);
          if MenuChoice >= 0 then
          begin
            Selected := MenuChoice;
            OpenSelected := True;
          end;
        end;
        Done := True;
      end;
      LocalPreviousButtons := M.Buttons;
    end;

    if OldSelected <> Selected then
    begin
      if MouseReady then HideMouse;
      DrawTopMenuBar(Selected, True, False);
      if MouseReady then ShowMouse;
    end;
  until Done;

  if OpenSelected then
  begin
    if MouseReady then
      HideMouse;
    DrawTopMenuBar(Selected, True, True);
    if MouseReady then
      ShowMouse;
  end;
  MenuAcceleratorsVisible := False;
  NeedsRedraw := True;
  if OpenSelected then
    OpenTopMenu(Selected)
  else
    SyncMouseButtons;
end;

{ Converts an on-screen editor cell to a bounded document position. }
function CellToDocumentPosition(CellX, CellY: Word;
  var LineIndex, Column: Word): Boolean;
begin
  CellToDocumentPosition := False;
  if not ((CellX >= EditLeft) and (CellX < EditLeft + EditWidth) and
          (CellY >= EditTop) and (CellY < EditTop + EditHeight)) then
    Exit;

  LineIndex := TopLine + CellY - EditTop;
  if LineIndex >= Buffer^.Count then
    LineIndex := Buffer^.Count - 1;
  Column := LeftColumn + CellX - EditLeft;
  if Column > Length(Buffer^.LinePtr(LineIndex)^) then
    Column := Length(Buffer^.LinePtr(LineIndex)^);
  CellToDocumentPosition := True;
end;

{ Handles menu, scroll-bar, and document actions for a new click. }
procedure HandleMouseDown(CellX, CellY: Word);
var
  TargetLine, TargetColumn: Word;
  MenuIndex: Byte;
begin
  ResetCaretBlink;
  MouseSelecting := False;
  if CellY = 0 then
  begin
    if (CellX >= 1) and (CellX <= 5) then
      MenuIndex := 0
    else if (CellX >= 7) and (CellX <= 11) then
      MenuIndex := 1
    else if (CellX >= 13) and (CellX <= 19) then
      MenuIndex := 2
    else if (CellX >= 21) and (CellX <= 28) then
      MenuIndex := 3
    else if (CellX >= 30) and (CellX <= 34) then
      MenuIndex := 4
    else
      MenuIndex := 5;

    if MenuIndex < 5 then
    begin
      if MouseReady then
        HideMouse;
      DrawTopMenuBar(MenuIndex, False, True);
      if MouseReady then
        ShowMouse;
      OpenTopMenu(MenuIndex);
    end;
    Exit;
  end;

  { The scroll bar occupies the column immediately inside the right frame.
    Arrow buttons move one line; clicking the track positions the viewport
    proportionally, matching the behavior expected from classic DOS editors. }
  if CellX = 78 then
  begin
    if CellY = 2 then
    begin
      if TopLine > 0 then
        Dec(TopLine);
    end
    else if CellY = 22 then
    begin
      if LongInt(TopLine) + EditHeight < Buffer^.Count then
        Inc(TopLine);
    end
    else if (CellY >= 3) and (CellY <= 21) and
            (Buffer^.Count > EditHeight) then
      TopLine := Word((LongInt(CellY - 3) *
        LongInt(Buffer^.Count - EditHeight)) div 18);
    NeedsRedraw := True;
    Exit;
  end;

  if CellToDocumentPosition(CellX, CellY, TargetLine, TargetColumn) then
  begin
    CursorLine := TargetLine;
    CursorColumn := TargetColumn;
    ClearSelection;
    SyncTypingFontToCaret;
    MouseSelecting := True;
    EnsureCursorVisible;
    NeedsRedraw := True;
  end;
end;

{ Extends the active selection while the mouse button is dragged. }
procedure HandleMouseDrag(CellX, CellY: Word);
var
  TargetLine, TargetColumn: Word;
begin
  if not MouseSelecting then
    Exit;
  if CellToDocumentPosition(CellX, CellY, TargetLine, TargetColumn) then
    if (TargetLine <> CursorLine) or (TargetColumn <> CursorColumn) then
    begin
      ResetCaretBlink;
      CursorLine := TargetLine;
      CursorColumn := TargetColumn;
      SelectionActive := (SelectionAnchorLine <> CursorLine) or
        (SelectionAnchorColumn <> CursorColumn);
      if not SelectionActive then
        SyncTypingFontToCaret;
      EnsureCursorVisible;
      NeedsRedraw := True;
    end;
end;

{ Starts or cancels keyboard selection before caret movement. }
procedure PrepareMovementSelection(const K: TKeyEvent);
begin
  if (K.ShiftState and ShiftPressed) <> 0 then
  begin
    if not SelectionActive then
    begin
      SelectionAnchorLine := CursorLine;
      SelectionAnchorColumn := CursorColumn;
    end;
  end
  else
    ClearSelection;
end;

{ Clamps the caret, completes selection state, and ensures visibility. }
procedure FinalizeMovement(const K: TKeyEvent; ClampColumn: Boolean);
begin
  { Vertical and page movement retain the preferred column where possible but
    must clamp it when the destination line is shorter. }
  if ClampColumn and
     (CursorColumn > Length(Buffer^.LinePtr(CursorLine)^)) then
    CursorColumn := Length(Buffer^.LinePtr(CursorLine)^);
  if (K.ShiftState and ShiftPressed) <> 0 then
    SelectionActive := (SelectionAnchorLine <> CursorLine) or
    (SelectionAnchorColumn <> CursorColumn);
  if not SelectionActive then
    SyncTypingFontToCaret;
end;

{ Inserts or overwrites one printable character at the caret. }
procedure TypeCharacter(Ch: Char);
var
  Inserted: Boolean;
begin
  if SelectionActive then
    if not RemoveSelection('Delete') then
      Exit;

  if InsertMode then
    Inserted := Buffer^.InsertChar(CursorLine, CursorColumn, Ch)
  else
    Inserted := Buffer^.OverwriteChar(CursorLine, CursorColumn, Ch);
  if Inserted and (CursorColumn < MaxLineLength) then
    Inc(CursorColumn);
end;

{ Inserts spaces up to the next configured tab stop. }
procedure InsertTab;
var
  Spaces, I: Byte;
begin
  Spaces := TabWidth - (CursorColumn mod TabWidth);
  for I := 1 to Spaces do
    TypeCharacter(' ');
end;

{ Splits the current line and optionally copies its indentation. }
procedure InsertNewLine;
var
  IndentText: String;
  IndentFonts: TFontStyleLine;
  I, IndentLength, NewLineLength: Word;
  OldCount, OldLine: Word;
begin
  if SelectionActive then
    if not RemoveSelection('Delete') then
      Exit;

  IndentText := '';
  ClearFontStyleLine(IndentFonts, Buffer^.TypingFont);
  if AutoIndent then
  begin
    I := 1;
    while (I <= Length(Buffer^.LinePtr(CursorLine)^)) and
          ((Buffer^.LinePtr(CursorLine)^[I] = ' ') or
           (Buffer^.LinePtr(CursorLine)^[I] = Chr(9))) do
    begin
      IndentText := IndentText + Buffer^.LinePtr(CursorLine)^[I];
      SetFontFamily(IndentFonts, I - 1,
        Buffer^.FontAt(CursorLine, I - 1));
      Inc(I);
    end;
  end;

  OldCount := Buffer^.Count;
  OldLine := CursorLine;
  Buffer^.SplitLine(CursorLine, CursorColumn);
  IndentLength := Length(IndentText);
  if (Buffer^.Count > OldCount) and AutoIndent and
     (IndentLength + Length(Buffer^.LinePtr(CursorLine)^) <= MaxLineLength) then
  begin
    NewLineLength := Length(Buffer^.LinePtr(CursorLine)^);
    I := NewLineLength;
    while I > 0 do
    begin
      Dec(I);
      SetFontFamily(Buffer^.EditFontPtr(CursorLine)^, I + IndentLength,
        GetFontFamily(Buffer^.FontPtr(CursorLine)^, I));
    end;
    CopyFontFamilies(IndentFonts, 0, IndentLength,
      Buffer^.EditFontPtr(CursorLine)^, 0);
    Buffer^.EditLinePtr(CursorLine)^ := IndentText +
      Buffer^.LinePtr(CursorLine)^;
    CursorColumn := IndentLength;
  end
  else if CursorLine = OldLine then
    CursorColumn := Length(Buffer^.LinePtr(CursorLine)^);
end;

{ Dispatches one PC-98 key event to editor commands and movement. }
procedure HandleKey(const K: TKeyEvent);
var
  MenuChoice: Integer;
begin
  ResetCaretBlink;
  MenuChoice := TopMenuAccelerator(K);
  if (K.ScanCode = ScanGraph) or (K.ScanCode = ScanNfer) or
     (K.ScanCode = ScanXfer) then
    ActivateMenuBar(0)
  else if ((K.ShiftState and GraphPressed) <> 0) and
          (MenuChoice >= 0) then
    OpenTopMenu(MenuChoice)
  else if (K.ScanCode = ScanDelete) and
     ((K.ShiftState and ShiftPressed) <> 0) then
    CutSelection
  else if (K.ScanCode = ScanInsert) and
          ((K.ShiftState and CtrlPressed) <> 0) then
  begin
    if CopySelection('Copy') then
      NeedsRedraw := True;
  end
  else if (K.ScanCode = ScanInsert) and
          ((K.ShiftState and ShiftPressed) <> 0) then
    PasteClipboard
  else if K.AsciiCode = 1 then
    SelectAll
  else if K.AsciiCode = 6 then
    FindCommand(True)
  else if K.AsciiCode = 16 then
    PrintCommand
  else if K.ScanCode = ScanF4 then
    FindCommand(False)
  else if K.ScanCode = ScanUp then
  begin
    PrepareMovementSelection(K);
    if CursorLine > 0 then
      Dec(CursorLine);
    FinalizeMovement(K, True);
  end
  else if K.ScanCode = ScanDown then
  begin
    PrepareMovementSelection(K);
    if CursorLine + 1 < Buffer^.Count then
      Inc(CursorLine);
    FinalizeMovement(K, True);
  end
  else if K.ScanCode = ScanLeft then
  begin
    PrepareMovementSelection(K);
    if CursorColumn > 0 then
      Dec(CursorColumn)
    else if CursorLine > 0 then
    begin
      Dec(CursorLine);
      CursorColumn := Length(Buffer^.LinePtr(CursorLine)^);
    end;
    FinalizeMovement(K, False);
  end
  else if K.ScanCode = ScanRight then
  begin
    PrepareMovementSelection(K);
    if CursorColumn < Length(Buffer^.LinePtr(CursorLine)^) then
      Inc(CursorColumn)
    else if CursorLine + 1 < Buffer^.Count then
    begin
      Inc(CursorLine);
      CursorColumn := 0;
    end;
    FinalizeMovement(K, False);
  end
  else if K.ScanCode = ScanDelete then
    DeleteForward
  else if K.ScanCode = ScanInsert then
    InsertMode := not InsertMode
  else if K.ScanCode = ScanHomeClear then
  begin
    PrepareMovementSelection(K);
    CursorColumn := 0;
    FinalizeMovement(K, False);
  end
  else if K.ScanCode = ScanRollUp then
  begin
    PrepareMovementSelection(K);
    if CursorLine > EditHeight then
      Dec(CursorLine, EditHeight)
    else
      CursorLine := 0;
    FinalizeMovement(K, True);
  end
  else if K.ScanCode = ScanRollDown then
  begin
    PrepareMovementSelection(K);
    if LongInt(CursorLine) + EditHeight < Buffer^.Count then
      Inc(CursorLine, EditHeight)
    else
      CursorLine := Buffer^.Count - 1;
    FinalizeMovement(K, True);
  end
  else if K.ScanCode = ScanF2 then
  begin
    if SaveDocument(False) then
      NeedsRedraw := True;
  end
  else if K.ScanCode = ScanF3 then
    OpenDocument
  else if K.ScanCode = ScanF10 then
    ActivateMenuBar(0)
  else if K.ScanCode = ScanHelp then
    ShowHelpTutorial
  else if K.AsciiCode = 8 then
  begin
    if SelectionActive then
    begin
      if RemoveSelection('Delete') then
        NeedsRedraw := True;
    end
    else
      Buffer^.BackspaceAt(CursorLine, CursorColumn);
  end
  else if K.AsciiCode = 9 then
    InsertTab
  else if K.AsciiCode = 13 then
    InsertNewLine
  else if K.AsciiCode = 27 then
  begin
    if ConfirmDiscard then
      Running := False;
  end
  else if (K.AsciiCode >= 32) and (K.AsciiCode <= 126) and
          ((K.ShiftState and CtrlPressed) = 0) then
    TypeCharacter(Chr(K.AsciiCode));

  EnsureCursorVisible;
  NeedsRedraw := True;
end;

{ Loads an optional startup filename captured from the DOS command line. }
procedure LoadCommandLineFile(const StartupFile: String; HasStartupFile: Boolean);
var
  ErrorText: String;
begin
  if not HasStartupFile then
    Exit;

  CurrentFile := StartupFile;
  if not LoadDocumentFile(CurrentFile, ErrorText) then
  begin
    Buffer^.Init;
    ShowMessage('Open Error', ErrorText);
    CurrentFile := '';
  end;
  ResetViewAndSelection;
end;

var
  K: TKeyEvent;
  M: TMouseState;
  CellX, CellY: Word;
  CurrentShiftState: Byte;
  StartupFile: String;
  HasStartupFile: Boolean;
begin
  { Capture the program command line before executing a resident mouse driver.
    FPC initializes ParamStr lazily on this target.  A child TSR can alter DOS
    process state on some PC-98 DOS versions, so parsing it only after EXEC is
    unsafe and can send startup into the Open Error dialog with corrupted data. }
  HasStartupFile := ParamCount > 0;
  if HasStartupFile then
    StartupFile := ParamStr(1)
  else
    StartupFile := '';
  { Capture ParamStr(0) before executing MOUSE.COM for the same reason. }
  SettingsPath := FExpand(SettingsFileName);

  { The mouse driver is handled before anything else the program does.  If no
    INT 33h driver is resident, MOUSE.COM/MOUSE.EXE is executed while the
    screen still belongs to DOS, so its installation banner scrolls by like a
    normal command and the TSR is in place before the first frame is drawn. }
  MouseReady := InitMouse;
  if not MouseReady then
  begin
    { MOUSE.COM is executed directly and remains resident after returning.
      Re-test INT 33h immediately so the text-VRAM pointer can be enabled. }
    if StartMouseDriver then
      MouseReady := InitMouse;
  end;

  { Allocate the document controller, three bounded 32-line cache pages, and
    a DOS temporary backing file after the mouse TSR has become resident.  The
    decoded document can contain up to 65,535 lines while only 96 lines remain
    resident in the page cache. }
  New(Buffer);
  if Buffer = nil then
  begin
    WriteLn('EDIT98: not enough memory for the document controller.');
    Halt(1);
  end;
  if not Buffer^.AllocateStorage then
  begin
    Dispose(Buffer);
    Buffer := nil;
    WriteLn('EDIT98: unable to create document page storage.');
    WriteLn('Check free memory, disk space, and EDIT98TMP/TEMP/TMP.');
    Halt(1);
  end;

  New(Clipboard);
  if Clipboard = nil then
  begin
    Buffer^.ReleaseStorage;
    Dispose(Buffer);
    Buffer := nil;
    WriteLn('EDIT98: not enough memory for the internal clipboard.');
    Halt(1);
  end;

  { The cache holds only one 77x21 visible native-text screen.  It is a
    static near-data object so the i8086 compiler never has to synthesize
    two-dimensional far-pointer addressing for viewport cells. }
  ResetViewportCacheBaseline;

  { DOS leaves its own blinking text cursor enabled.  EDIT98 paints and blinks
    one caret itself, so the BIOS cursor must stay hidden to avoid duplicates. }
  HideTextCursor;

  Buffer^.Init;
  Clipboard^.Clear;
  CurrentFile := '';
  CursorLine := 0;
  CursorColumn := 0;
  TopLine := 0;
  LeftColumn := 0;
  SelectionActive := False;
  SelectionAnchorLine := 0;
  SelectionAnchorColumn := 0;
  PreviousButtons := 0;
  MouseSelecting := False;
  Running := True;
  NeedsRedraw := True;
  MenuAcceleratorsVisible := False;
  PreviousShiftState := ReadShiftState;
  CaretVisible := True;
  LastCaretClock := 0;
  GraphicsBackdropDirty := False;
  ViewportCacheValid := False;
  CachedTopLine := 0;
  CachedLeftColumn := 0;

  LastFind := '';
  LastReplace := '';
  MatchCase := False;
  TabWidth := 4;
  InsertMode := True;
  AutoIndent := True;
  MouseSpeedSetting := MouseSpeedFast;
  ColorScheme := SchemeDOSEdit;
  ShowPageBreaks := True;
  PrintMarginTopTenthsCm := DefaultPrintMarginTenthsCm;
  PrintMarginBottomTenthsCm := DefaultPrintMarginTenthsCm;
  PrintMarginLeftTenthsCm := DefaultPrintMarginTenthsCm;
  PrintMarginRightTenthsCm := DefaultPrintMarginTenthsCm;
  PrintPaperTemplate := DefaultPaperTemplate;
  PrintOrientation := DefaultPrintOrientation;
  CustomPaperWidthTenthsCm[0] := 0;
  CustomPaperHeightTenthsCm[0] := 0;
  CustomPaperWidthTenthsCm[1] := 0;
  CustomPaperHeightTenthsCm[1] := 0;
  CustomPaperWidthTenthsCm[2] := 0;
  CustomPaperHeightTenthsCm[2] := 0;
  CustomPaperWidthTenthsCm[3] := 0;
  CustomPaperHeightTenthsCm[3] := 0;
  LoadSettings;
  if not IsValidPaperTemplate(PrintPaperTemplate) then
    PrintPaperTemplate := PaperTemplateA4
  else if IsCustomPaperTemplate(PrintPaperTemplate) and
     ((CustomPaperWidthTenthsCm[PrintPaperTemplate - PaperTemplateFirstCustom] <
       MinimumPaperDimensionTenthsCm) or
      (CustomPaperHeightTenthsCm[PrintPaperTemplate - PaperTemplateFirstCustom] <
       MinimumPaperDimensionTenthsCm)) then
    PrintPaperTemplate := PaperTemplateA4;
  ApplyColorScheme;
  ResetCaretBlink;

  if MouseReady then
  begin
    ApplyMouseSpeed;
    ShowMouse;
  end;

  LoadCommandLineFile(StartupFile, HasStartupFile);

  while Running do
  begin
    if NeedsRedraw then
    begin
      HideMouse;
      DrawDocument;
      NeedsRedraw := False;
      if MouseReady then
        ShowMouse;
    end;

    CurrentShiftState := ReadShiftState;
    if ((CurrentShiftState and GraphPressed) <> 0) and
       ((PreviousShiftState and GraphPressed) = 0) then
    begin
      ActivateMenuBar(0);
      PreviousShiftState := ReadShiftState;
    end
    else if PollKey(K) then
      HandleKey(K);
    PreviousShiftState := ReadShiftState;

    if MouseReady then
    begin
      PollMouse(M);
      CellX := M.X div 8;
      CellY := M.Y div 16;

      if ((M.Buttons and 1) <> 0) and ((PreviousButtons and 1) = 0) then
        HandleMouseDown(CellX, CellY)
      else if ((M.Buttons and 1) <> 0) and MouseSelecting then
        HandleMouseDrag(CellX, CellY)
      else if ((M.Buttons and 1) = 0) and ((PreviousButtons and 1) <> 0) then
        MouseSelecting := False;

      PreviousButtons := M.Buttons;
    end;

    if not NeedsRedraw then
      UpdateCaretBlink;
  end;

  HideMouse;
  SaveSettings;
  Dispose(Clipboard);
  Clipboard := nil;
  Buffer^.ReleaseStorage;
  Dispose(Buffer);
  Buffer := nil;
  ShutdownGraphicsBackdrop;
  FillRect(0, 0, ScreenWidth - 1, ScreenHeight - 1, ' ', AttrWhite);
  PutText(0, 0, 'EDIT98 ended.', AttrWhite);
  ShowTextCursor;
end.
