unit tlsp;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, tp7lsp;

type
  TEditComputationTest = class(TTestCase)
  published
    procedure TestCasesRoundTrip;
    procedure TestEqualTextsGiveNoEdits;
    procedure TestExactRanges;
    procedure TestEndColumnCountsUtf16Units;
    procedure TestFuzz;
  end;

  TFakeTransport = class(TTransport)
  public
    Sent: TJSONArray;
    constructor Create;
    destructor Destroy; override;
    function Read: TJSONData; override;
    procedure Send(Msg: TJSONObject); override;
  end;

  TServerTestBase = class(TTestCase)
  protected
    Tmp: string;
    T: TFakeTransport;
    S: TServer;
    procedure SetUp; override;
    procedure TearDown; override;
    procedure Dispatch_(const Json: string);
    procedure Open(const Uri, Text: string);
    procedure Change(const Uri: string; Version: Integer; const Text: string);
    function Published: TJSONArray;
    function LastFor(const Uri: string): TJSONObject;
    function UriOf(const Name: string): string;
    function IsPending(const Uri: string): Boolean;
  end;

  TQueueingTest = class(TServerTestBase)
  private
    Uri: string;
  protected
    procedure SetUp; override;
  published
    procedure TestChangesAreDiagnosedOnceWhenTheTypingPauses;
    procedure TestQuietTimeAndLongestWait;
    procedure TestCloseForgetsThePendingDiagnostics;
    procedure TestARequestAboutTextThatAlreadyMovedOnIsRefused;
    procedure TestACancelledRequestIsNotAnsweredWithWork;
  end;

  TDependentsTest = class(TServerTestBase)
  private
    GeomUri, MainUri: string;
  protected
    procedure SetUp; override;
  published
    procedure TestAUnitChangeRefreshesTheProgramThatUsesIt;
    procedure TestAProgramChangeDoesNotRefreshOthers;
    procedure TestSaveAndFileWatcherRefresh;
  end;

  TCachesTest = class(TServerTestBase)
  private
    Doc: TDoc;
    Geom: string;
  protected
    procedure SetUp; override;
  published
    procedure TestProviderIsReusedUntilAUnitChanges;
    procedure TestANewUnitFileIsFound;
    procedure TestAnOpenBufferOfAnotherUnitWinsAndIsCached;
    procedure TestBindingIsSharedUntilTheTextChanges;
    procedure TestDiagnosingTwiceGivesTheSameAnswer;
  end;

  TPositionEncodingTest = class(TServerTestBase)
  protected
    procedure TearDown; override;
    function Init(const Encodings: string): string;
    function LongLineEnd: Integer;
  published
    procedure TestUtf16ByDefault;
    procedure TestUtf8WhenTheClientOffersIt;
  end;

  TGapsTest = class(TServerTestBase)
  protected
    function Request(const Method, Params: string): TJSONObject;
  published
    procedure TestRenameIsRefusedWhenTheNewNameIsInAnIncludeFile;
    procedure TestNamesAreNotCheckedWhenAUnitCouldNotBeRead;
    procedure TestLongDetailsAreCut;
    procedure TestOpenStubsAreNotRediagnosed;
    procedure TestGotoOffersEachLabelOnce;
    procedure TestTheLastParameterOfWriteLnRepeats;
  end;

implementation

uses
  jsonparser, tp7enc, tp7os, tp7sema, tp7stub, tutil;

function JsonOf(const S: string): TJSONData;
begin
  Result := GetJSON(S);
end;

function OffsetOf(const Lines: TStringArray; const Text: string; Line, Ch: Integer): Integer;
var
  I, Off, Units_: Integer;
  S: string;
  B: Byte;
begin
  if Line >= Length(Lines) then
    Exit(Length(Text));
  Off := 0;
  for I := 0 to Line - 1 do
    Inc(Off, Length(Lines[I]));
  S := Lines[Line];
  I := 1;
  Units_ := 0;
  while (I <= Length(S)) and (Units_ < Ch) do
  begin
    B := Ord(S[I]);
    if B >= $F0 then
      Inc(Units_, 2)
    else
      Inc(Units_);
    Inc(I);
    while (I <= Length(S)) and (Ord(S[I]) and $C0 = $80) do
      Inc(I);
  end;
  Result := Off + I - 1;
end;

function ApplyEdits(const Text: string; Edits: TJSONArray): string;
type
  TSpan = record
    S, E: Integer;
    New: string;
  end;
var
  Lines: TStringArray;
  Spans: array of TSpan;
  X: TSpan;
  I, J: Integer;
  R: TJSONObject;
begin
  Lines := SplitLines(Text);
  Spans := nil;
  for I := 0 to Edits.Count - 1 do
  begin
    R := TJSONObject(Edits[I]).Objects['range'];
    SetLength(Spans, Length(Spans) + 1);
    Spans[High(Spans)].S := OffsetOf(Lines, Text, R.Objects['start'].Integers['line'],
      R.Objects['start'].Integers['character']);
    Spans[High(Spans)].E := OffsetOf(Lines, Text, R.Objects['end'].Integers['line'],
      R.Objects['end'].Integers['character']);
    Spans[High(Spans)].New := TJSONObject(Edits[I]).Strings['newText'];
  end;
  for I := 1 to High(Spans) do
  begin
    X := Spans[I];
    J := I - 1;
    while (J >= 0) and (Spans[J].S < X.S) do
    begin
      Spans[J + 1] := Spans[J];
      Dec(J);
    end;
    Spans[J + 1] := X;
  end;
  Result := Text;
  for X in Spans do
    Result := Copy(Result, 1, X.S) + X.New + Copy(Result, X.E + 1, MaxInt);
end;

const
  Emoji = #$F0#$9F#$98#$80;
  EAcute = #$C3#$A9;
  Cases: array[0..12, 0..1] of string = (('', ''), ('', 'a'#10), ('a'#10, ''), ('a', 'b'), ('a'#10'b', 'a'#10'c'),
    ('a'#13#10'b'#13#10, 'a'#13#10'B'#13#10), ('x'#10'y', 'x'#10'y'#10), ('x'#10'y'#10, 'x'#10'y'),
    (#10#10, #10), ('a'#10'b'#10'c'#10, 'a'#10'c'#10), ('a'#10, 'a'#10'b'#10'c'#10),
    (EAcute + Emoji + #10'z', EAcute + Emoji + #10'Z'), ('a'#13'b'#13, 'a'#13'c'#13));

procedure TEditComputationTest.TestCasesRoundTrip;
var
  I: Integer;
  E: TJSONArray;
begin
  for I := 0 to High(Cases) do
  begin
    E := ComputeEdits(Cases[I, 0], Cases[I, 1]);
    try
      AssertTrue(E.Count <= 1);
      AssertEquals(PyRepr(Cases[I, 0]), Cases[I, 1], ApplyEdits(Cases[I, 0], E));
    finally
      E.Free;
    end;
  end;
end;

procedure TEditComputationTest.TestEqualTextsGiveNoEdits;
var
  E: TJSONArray;
begin
  E := ComputeEdits('a'#10'b'#10, 'a'#10'b'#10);
  try
    AssertEquals(0, E.Count);
  finally
    E.Free;
  end;
end;

procedure AssertSameJSON(const Want: string; Got: TJSONData);
var
  W: TJSONData;
begin
  W := JsonOf(Want);
  try
    TAssert.AssertEquals(W.AsJSON, Got.AsJSON);
  finally
    W.Free;
  end;
end;

procedure TEditComputationTest.TestExactRanges;
var
  E: TJSONArray;
begin
  E := ComputeEdits('a'#10'b'#10'c'#10, 'a'#10'c'#10);
  try
    AssertSameJSON('[{"range": {"start": {"line": 1, "character": 0}, "end": {"line": 2, "character": 0}}, ' +
      '"newText": ""}]', E);
  finally
    E.Free;
  end;
  E := ComputeEdits('a', 'b');
  try
    AssertSameJSON('[{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}, ' +
      '"newText": "b"}]', E);
  finally
    E.Free;
  end;
  E := ComputeEdits('x'#10'y', 'x'#10'y'#10);
  try
    AssertSameJSON('{"line": 1, "character": 1}', TJSONObject(E[0]).Objects['range'].Objects['end']);
  finally
    E.Free;
  end;
end;

procedure TEditComputationTest.TestEndColumnCountsUtf16Units;
var
  E: TJSONArray;
begin
  E := ComputeEdits(Emoji, 'x');
  try
    AssertSameJSON('{"line": 0, "character": 2}', TJSONObject(E[0]).Objects['range'].Objects['end']);
  finally
    E.Free;
  end;
  AssertEquals(3, Units(EAcute + Emoji));
end;

procedure TEditComputationTest.TestFuzz;
const
  Parts: array[0..9] of string = ('a'#10, 'b'#10, 'c', #13#10, EAcute + #10, Emoji + 'x'#10, '', #10, 'a'#13#10, 'zz');
var
  N, K: Integer;
  Old, New: string;
  E: TJSONArray;
begin
  RandSeed := 3;
  for N := 1 to 3000 do
  begin
    Old := '';
    for K := 1 to Random(7) do
      Old := Old + Parts[Random(10)];
    New := '';
    for K := 1 to Random(7) do
      New := New + Parts[Random(10)];
    E := ComputeEdits(Old, New);
    try
      AssertEquals(PyRepr(Old) + ' -> ' + PyRepr(New), New, ApplyEdits(Old, E));
    finally
      E.Free;
    end;
  end;
end;

{ TFakeTransport }

constructor TFakeTransport.Create;
begin
  Sent := TJSONArray.Create;
end;

destructor TFakeTransport.Destroy;
begin
  Sent.Free;
  inherited;
end;

function TFakeTransport.Read: TJSONData;
begin
  Result := nil;
end;

procedure TFakeTransport.Send(Msg: TJSONObject);
begin
  Sent.Add(Msg.Clone);
end;

{ TServerTestBase }

procedure TServerTestBase.SetUp;
var
  TplPath: string;
begin
  TplPath := DataFile('TURBO.TPL');
  if TplPath = '' then
    Ignore('TURBO.TPL is not in TP7LS_DATA');
  Tmp := MakeTempDir;
  T := TFakeTransport.Create;
  S := TServer.Create(T);
  S.Initialized := True;
  S.Tpl := TplPath;
  S.Stubs := TStubStore.Create(JoinPath(Tmp, 'stubs'));
end;

procedure TServerTestBase.TearDown;
begin
  S.Free;
  T.Free;
  RemoveTree(Tmp);
end;

procedure TServerTestBase.Dispatch_(const Json: string);
var
  M: TJSONData;
begin
  M := JsonOf(Json);
  try
    S.DispatchMsg(TJSONObject(M));
  finally
    M.Free;
  end;
end;

function Quote(const S: string): string;
var
  Q: TJSONString;
begin
  Q := TJSONString.Create(S);
  try
    Result := Q.AsJSON;
  finally
    Q.Free;
  end;
end;

procedure TServerTestBase.Open(const Uri, Text: string);
begin
  Dispatch_('{"method": "textDocument/didOpen", "params": {"textDocument": {"uri": ' + Quote(Uri) +
    ', "version": 1, "text": ' + Quote(Text) + '}}}');
end;

procedure TServerTestBase.Change(const Uri: string; Version: Integer; const Text: string);
begin
  Dispatch_('{"method": "textDocument/didChange", "params": {"textDocument": {"uri": ' + Quote(Uri) +
    ', "version": ' + IntToStr(Version) + '}, "contentChanges": [{"text": ' + Quote(Text) + '}]}}');
end;

function TServerTestBase.Published: TJSONArray;
var
  I: Integer;
  M: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to T.Sent.Count - 1 do
  begin
    M := TJSONObject(T.Sent[I]);
    if M.Get('method', '') = 'textDocument/publishDiagnostics' then
      Result.Add(M.Objects['params'].Clone);
  end;
end;

function TServerTestBase.LastFor(const Uri: string): TJSONObject;
var
  I: Integer;
  M: TJSONObject;
begin
  Result := nil;
  for I := 0 to T.Sent.Count - 1 do
  begin
    M := TJSONObject(T.Sent[I]);
    if (M.Get('method', '') = 'textDocument/publishDiagnostics') and (M.Objects['params'].Strings['uri'] = Uri) then
      Result := M.Objects['params'];
  end;
end;

function TServerTestBase.UriOf(const Name: string): string;
begin
  Result := 'file://' + JoinPath(Tmp, Name);
end;

function TServerTestBase.IsPending(const Uri: string): Boolean;
begin
  Result := S.PendingIndex(Uri) >= 0;
end;

{ TQueueingTest }

procedure TQueueingTest.SetUp;
begin
  inherited;
  Uri := UriOf('a.pas');
  Open(Uri, 'program a;'#10'begin'#10'end.'#10);
  T.Sent.Clear;
end;

procedure TQueueingTest.TestChangesAreDiagnosedOnceWhenTheTypingPauses;
var
  V: Integer;
  P: TJSONArray;
begin
  for V := 2 to 11 do
    Change(Uri, V, 'program a;'#10'begin'#10'  x := ' + IntToStr(V) + ';'#10'end.'#10);
  P := Published;
  try
    AssertEquals(0, P.Count);
  finally
    P.Free;
  end;
  S.FlushDiagnostics;
  P := Published;
  try
    AssertEquals(0, P.Count);
  finally
    P.Free;
  end;
  S.FlushDiagnostics(True);
  P := Published;
  try
    AssertEquals(1, P.Count);
    AssertEquals(11, TJSONObject(P[0]).Integers['version']);
    AssertTrue(Pos('unknown identifier ''x''', TJSONObject(TJSONObject(P[0]).Arrays['diagnostics'][0]).Strings['message']) > 0);
  finally
    P.Free;
  end;
end;

procedure TQueueingTest.TestQuietTimeAndLongestWait;
var
  I: Integer;
  P: TJSONArray;
  Now_: Double;
begin
  Change(Uri, 2, 'program a;'#10'begin'#10'  y := 1;'#10'end.'#10);
  I := S.PendingIndex(Uri);
  S.Pending[I].First := S.Pending[I].First - 10;
  S.Pending[I].Last := S.Pending[I].Last - DiagDelay - 0.01;
  S.FlushDiagnostics;
  P := Published;
  try
    AssertEquals(1, P.Count);
    AssertEquals(2, TJSONObject(P[0]).Integers['version']);
  finally
    P.Free;
  end;
  T.Sent.Clear;
  Change(Uri, 3, 'program a;'#10'begin'#10'  z := 1;'#10'end.'#10);
  Now_ := MonotonicSeconds;
  I := S.PendingIndex(Uri);
  S.Pending[I].First := Now_ - DiagMaxDelay - 0.01;
  S.Pending[I].Last := Now_;
  S.FlushDiagnostics;
  P := Published;
  try
    AssertEquals(1, P.Count);
    AssertEquals(3, TJSONObject(P[0]).Integers['version']);
  finally
    P.Free;
  end;
end;

procedure TQueueingTest.TestCloseForgetsThePendingDiagnostics;
var
  P: TJSONArray;
begin
  Change(Uri, 2, 'program a;'#10'begin'#10'  y := 1;'#10'end.'#10);
  Dispatch_('{"method": "textDocument/didClose", "params": {"textDocument": {"uri": ' + Quote(Uri) + '}}}');
  S.FlushDiagnostics(True);
  P := Published;
  try
    AssertEquals(1, P.Count);
    AssertEquals(0, TJSONObject(P[0]).Arrays['diagnostics'].Count);
  finally
    P.Free;
  end;
end;

procedure TQueueingTest.TestARequestAboutTextThatAlreadyMovedOnIsRefused;
var
  Last: TJSONObject;
begin
  Change(Uri, 2, 'program a;'#10'begin'#10'end.'#10);
  S.Inbox.Put(JsonOf('{"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {"textDocument": {"uri": ' +
    Quote(Uri) + ', "version": 3}, "contentChanges": [{"text": "program a;\nbegin end.\n"}]}}'));
  Dispatch_('{"jsonrpc": "2.0", "id": 7, "method": "textDocument/semanticTokens/full", "params": {"textDocument": ' +
    '{"uri": ' + Quote(Uri) + '}}}');
  Last := TJSONObject(T.Sent[T.Sent.Count - 1]);
  AssertEquals(ContentModified, Last.Objects['error'].Integers['code']);
  Dispatch_('{"jsonrpc": "2.0", "id": 8, "method": "textDocument/hover", "params": {"textDocument": {"uri": ' +
    Quote(Uri) + '}, "position": {"line": 0, "character": 0}}}');
  Last := TJSONObject(T.Sent[T.Sent.Count - 1]);
  AssertNull(Last.Find('error'));
end;

procedure TQueueingTest.TestACancelledRequestIsNotAnsweredWithWork;
var
  Id: TJSONData;
  Last: TJSONObject;
begin
  Id := JsonOf('9');
  try
    S.Cancel(Id);
  finally
    Id.Free;
  end;
  Dispatch_('{"jsonrpc": "2.0", "id": 9, "method": "textDocument/documentSymbol", "params": {"textDocument": ' +
    '{"uri": ' + Quote(Uri) + '}}}');
  Last := TJSONObject(T.Sent[T.Sent.Count - 1]);
  AssertEquals(RequestCancelled, Last.Objects['error'].Integers['code']);
end;

{ TDependentsTest }

const
  GeomText = 'unit Geom;'#10'interface'#10'var Origin: Integer;'#10'implementation'#10'end.'#10;

procedure TDependentsTest.SetUp;
begin
  inherited;
  GeomUri := UriOf('geom.pas');
  MainUri := UriOf('main.pas');
  WriteText(JoinPath(Tmp, 'geom.pas'), GeomText);
  Open(GeomUri, GeomText);
  Open(MainUri, 'program main;'#10'uses Geom;'#10'begin'#10'  Origin := 1;'#10'  Other := 2;'#10'end.'#10);
  T.Sent.Clear;
end;

procedure TDependentsTest.TestAUnitChangeRefreshesTheProgramThatUsesIt;
var
  D: TJSONObject;
  Diags: TJSONArray;
  I, N: Integer;
begin
  Change(GeomUri, 2, 'unit Geom;'#10'interface'#10'var Origin: Integer; Other: Integer;'#10'implementation'#10'end.'#10);
  AssertTrue(IsPending(MainUri));
  S.FlushDiagnostics(True);
  D := LastFor(MainUri);
  AssertNotNull(D);
  Diags := D.Arrays['diagnostics'];
  N := 0;
  for I := 0 to Diags.Count - 1 do
    if TJSONObject(Diags[I]).Integers['severity'] < 4 then
      Inc(N);
  AssertEquals(0, N);
end;

procedure TDependentsTest.TestAProgramChangeDoesNotRefreshOthers;
begin
  Change(MainUri, 2, 'program main;'#10'uses Geom;'#10'begin'#10'  Origin := 1;'#10'end.'#10);
  AssertFalse(IsPending(GeomUri));
end;

procedure TDependentsTest.TestSaveAndFileWatcherRefresh;
begin
  Dispatch_('{"method": "textDocument/didSave", "params": {"textDocument": {"uri": ' + Quote(GeomUri) + '}}}');
  AssertTrue(IsPending(MainUri));
  S.Pending := nil;
  Dispatch_('{"method": "workspace/didChangeWatchedFiles", "params": {"changes": []}}');
  AssertEquals(2, Length(S.Pending));
  AssertTrue(IsPending(GeomUri));
  AssertTrue(IsPending(MainUri));
end;

{ TCachesTest }

procedure TCachesTest.SetUp;
begin
  inherited;
  Doc := TDoc.Create(UriOf('a.pas'), nil, 'program a;'#10'uses Geom;'#10'begin'#10'  Origin := 1;'#10'end.'#10);
  S.Docs.Put(Doc.Uri, Doc);
  Geom := JoinPath(Tmp, 'geom.pas');
  WriteText(Geom, GeomText);
end;

procedure TCachesTest.TestProviderIsReusedUntilAUnitChanges;
var
  P1, P2: TProvider;
begin
  P1 := S.ProviderFor(Doc);
  P1.Get('Geom');
  AssertSame(P1, S.ProviderFor(Doc));
  WriteText(Geom, 'unit Geom;'#10'interface'#10'var Origin: Integer; Extra: Char;'#10'implementation'#10'end.'#10);
  P2 := S.ProviderFor(Doc);
  AssertTrue(P2 <> P1);
  AssertTrue(P2.Get('Geom').Exports_.Has('extra'));
end;

procedure TCachesTest.TestANewUnitFileIsFound;
var
  P1: TProvider;
begin
  P1 := S.ProviderFor(Doc);
  AssertNull(P1.Get('Later'));
  Sleep(10);
  WriteText(JoinPath(Tmp, 'later.pas'), 'unit Later;'#10'interface'#10'implementation'#10'end.'#10);
  AssertNotNull(S.ProviderFor(Doc).Get('Later'));
end;

procedure TCachesTest.TestAnOpenBufferOfAnotherUnitWinsAndIsCached;
var
  Other: TDoc;
  P1: TProvider;
begin
  Other := TDoc.Create('file://' + Geom, nil, 'unit Geom;'#10'interface'#10'var Mine: Integer;'#10'implementation'#10 +
    'end.'#10);
  S.Docs.Put(Other.Uri, Other);
  P1 := S.ProviderFor(Doc);
  AssertTrue(P1.Get('Geom').Exports_.Has('mine'));
  AssertSame(P1, S.ProviderFor(Doc));
  Other.Text := 'unit Geom;'#10'interface'#10'var Yours: Integer;'#10'implementation'#10'end.'#10;
  AssertTrue(S.ProviderFor(Doc).Get('Geom').Exports_.Has('yours'));
end;

procedure TCachesTest.TestBindingIsSharedUntilTheTextChanges;
var
  B1: TBound;
begin
  B1 := S.BindDoc(Doc, S.ProviderFor(Doc));
  AssertSame(B1, S.BindDoc(Doc, S.ProviderFor(Doc)));
  Doc.Text := Doc.Text + ' ';
  AssertTrue(S.BindDoc(Doc, S.ProviderFor(Doc)) <> B1);
end;

procedure TCachesTest.TestDiagnosingTwiceGivesTheSameAnswer;
var
  D1, D2: TJSONArray;
  I, N: Integer;
begin
  D1 := S.Diagnose(Doc);
  D2 := S.Diagnose(Doc);
  try
    AssertEquals(D1.AsJSON, D2.AsJSON);
    N := 0;
    for I := 0 to D1.Count - 1 do
      if TJSONObject(D1[I]).Integers['severity'] < 4 then
        Inc(N);
    AssertEquals(0, N);
  finally
    D2.Free;
    D1.Free;
  end;
end;

{ TPositionEncodingTest }

procedure TPositionEncodingTest.TearDown;
begin
  PositionsInBytes := False;
  inherited;
end;

function TPositionEncodingTest.Init(const Encodings: string): string;
var
  Last: TJSONObject;
begin
  S.Initialized := False;
  Dispatch_('{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {"general": ' +
    '{"positionEncodings": ' + Encodings + '}}, "initializationOptions": {"stubDir": ' + Quote(JoinPath(Tmp, 'stubs')) +
    '}}}');
  Last := TJSONObject(T.Sent[T.Sent.Count - 1]);
  Result := Last.Objects['result'].Objects['capabilities'].Strings['positionEncoding'];
end;

function TPositionEncodingTest.LongLineEnd: Integer;
var
  D: TJSONObject;
begin
  Open(UriOf('long.pas'), 'program a;'#10'{' + StringOfChar('x', 124) + #$D0#$96#$D0#$96' }'#10'begin'#10'end.'#10);
  D := LastFor(UriOf('long.pas'));
  AssertEquals(1, D.Arrays['diagnostics'].Count);
  Result := TJSONObject(D.Arrays['diagnostics'][0]).Objects['range'].Objects['end'].Integers['character'];
end;

procedure TPositionEncodingTest.TestUtf16ByDefault;
begin
  AssertEquals('utf-16', Init('["utf-16", "utf-32"]'));
  AssertEquals(129, LongLineEnd);
end;

procedure TPositionEncodingTest.TestUtf8WhenTheClientOffersIt;
begin
  AssertEquals('utf-8', Init('["utf-32", "utf-8", "utf-16"]'));
  AssertEquals(131, LongLineEnd);
end;

{ TGapsTest }

function TGapsTest.Request(const Method, Params: string): TJSONObject;
begin
  Dispatch_('{"jsonrpc": "2.0", "id": 5, "method": "' + Method + '", "params": ' + Params + '}');
  Result := TJSONObject(T.Sent[T.Sent.Count - 1]);
end;

procedure TGapsTest.TestRenameIsRefusedWhenTheNewNameIsInAnIncludeFile;
var
  R: TJSONObject;
begin
  WriteText(JoinPath(Tmp, 'defs.inc'), '{ Foo is mentioned here }'#13#10'const Lim = 3;'#13#10);
  Open(UriOf('m.pas'), 'program m;'#13#10'{$I defs.inc}'#13#10'var Bar: Integer;'#13#10'begin'#13#10'  Bar := Lim;'#13#10 +
    'end.'#13#10);
  R := Request('textDocument/rename', '{"textDocument": {"uri": ' + Quote(UriOf('m.pas')) + '}, "position": ' +
    '{"line": 2, "character": 5}, "newName": "Foo"}');
  AssertEquals(RequestFailed, R.Objects['error'].Integers['code']);
  AssertEquals('cannot rename: Foo also appears in the include file defs.inc, and edits inside include files are not ' +
    'made', R.Objects['error'].Strings['message']);
end;

procedure TGapsTest.TestNamesAreNotCheckedWhenAUnitCouldNotBeRead;
const
  Damage: array[0..5, 0..1] of Integer = ((6933, 164), (2664, 208), (4896, 194), (9755, 64), (22441, 58),
    (24875, 39));
var
  Data: RawByteString;
  I: Integer;
  F: TFileStream;
  D: TJSONObject;
  Prog: string;
begin
  if DataFile('GRAPH.TPU') = '' then
    Ignore('GRAPH.TPU is not in TP7LS_DATA');
  WriteText(JoinPath(Tmp, 'a.pas'), 'unit A;'#13#10'interface'#13#10'uses Graph;'#13#10'var X: Integer;'#13#10 +
    'implementation'#13#10'end.'#13#10);
  Prog := 'program q;'#13#10'uses A;'#13#10'begin'#13#10'  X := 1;'#13#10'  Zzz := 1;'#13#10'end.'#13#10;
  CopyFile(DataFile('GRAPH.TPU'), JoinPath(Tmp, 'GRAPH.TPU'));
  Open(UriOf('q.pas'), Prog);
  D := LastFor(UriOf('q.pas'));
  AssertEquals(1, D.Arrays['diagnostics'].Count);
  AssertEquals('unknown identifier ''Zzz''', TJSONObject(D.Arrays['diagnostics'][0]).Strings['message']);
  Data := ReadFileBytes(DataFile('GRAPH.TPU'));
  for I := 0 to High(Damage) do
    Data[Damage[I, 0] + 1] := Chr(Damage[I, 1]);
  F := TFileStream.Create(JoinPath(Tmp, 'GRAPH.TPU'), fmCreate);
  try
    F.WriteBuffer(Data[1], Length(Data));
  finally
    F.Free;
  end;
  Open(UriOf('q2.pas'), Prog);
  D := LastFor(UriOf('q2.pas'));
  AssertEquals(0, D.Arrays['diagnostics'].Count);
end;

procedure TGapsTest.TestLongDetailsAreCut;
var
  Symbols: TJSONArray;
begin
  Symbols := DocumentSymbols('program m;'#13#10'var Long: array [1..10] of record Alpha, Beta, Gamma, Delta, Epsilon, ' +
    'Zeta: Integer; Eta, Theta: Char end;'#13#10'begin'#13#10'end.'#13#10);
  try
    AssertEquals('array [1..10] of record Alpha, Beta, Gamma, Delta, Epsilon, Zeta: Integer; Eta,'#$E2#$80#$A6,
      TJSONObject(TJSONObject(Symbols[0]).Arrays['children'][0]).Strings['detail']);
  finally
    Symbols.Free;
  end;
end;

procedure TGapsTest.TestOpenStubsAreNotRediagnosed;
var
  Stub: string;
begin
  Stub := 'file://' + JoinPath(JoinPath(JoinPath(Tmp, 'stubs'), 'abcd1234'), 'Crt.pas');
  Open(UriOf('geom.pas'), GeomText);
  Open(Stub, 'unit Crt;'#13#10'interface'#13#10'uses Geom;'#13#10'implementation'#13#10'end.'#13#10);
  Open(UriOf('main.pas'), 'program main;'#13#10'uses Geom;'#13#10'begin'#13#10'end.'#13#10);
  Change(UriOf('geom.pas'), 2, GeomText + ' ');
  AssertTrue(IsPending(UriOf('main.pas')));
  AssertFalse(IsPending(Stub));
end;

procedure TGapsTest.TestGotoOffersEachLabelOnce;
var
  R: TJSONObject;
begin
  Open(UriOf('m.pas'), 'program m;'#13#10'label 1, 2;'#13#10'procedure P;'#13#10'label 1, 3;'#13#10'begin'#13#10 +
    '  goto '#13#10'1: 3: end;'#13#10'begin'#13#10'1: 2: P;'#13#10'end.'#13#10);
  R := Request('textDocument/completion', '{"textDocument": {"uri": ' + Quote(UriOf('m.pas')) + '}, "position": ' +
    '{"line": 5, "character": 7}}');
  AssertSameJSON('{"isIncomplete": false, "items": [{"label": "1", "kind": 18, "detail": "label", "sortText": "11"}, ' +
    '{"label": "3", "kind": 18, "detail": "label", "sortText": "23"}, {"label": "2", "kind": 18, "detail": "label", ' +
    '"sortText": "32"}]}', R.Objects['result']);
end;

procedure TGapsTest.TestTheLastParameterOfWriteLnRepeats;
var
  R: TJSONObject;
begin
  Open(UriOf('q.pas'), 'program q;'#13#10'begin'#13#10'  WriteLn(1, 2, 3, 4, 5);'#13#10'end.'#13#10);
  R := Request('textDocument/signatureHelp', '{"textDocument": {"uri": ' + Quote(UriOf('q.pas')) + '}, "position": ' +
    '{"line": 2, "character": 22}}');
  AssertSameJSON('{"signatures": [{"label": "procedure WriteLn([var F: Text;] [P1 [, P2, ..., Pn]])", "parameters": ' +
    '[{"label": [19, 30]}, {"label": [34, 36]}, {"label": [40, 42]}, {"label": [49, 51]}], "documentation": {"kind": ' +
    '"markdown", "value": "*unit System* \u00b7 *built-in: the signature is informal*"}, "activeParameter": 3}], ' +
    '"activeSignature": 0, "activeParameter": 3}', R.Objects['result']);
end;

initialization
  RegisterTest(TEditComputationTest);
  RegisterTest(TGapsTest);
  RegisterTest(TPositionEncodingTest);
  RegisterTest(TQueueingTest);
  RegisterTest(TDependentsTest);
  RegisterTest(TCachesTest);
end.
