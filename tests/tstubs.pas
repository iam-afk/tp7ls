unit tstubs;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, tp7sema, tp7stub;

type
  TStubTestBase = class(TTestCase)
  protected
    Provs: TList;
    Stubs: TList;
    procedure SetUp; override;
    procedure TearDown; override;
    function Tpl: string;
    function StubOf(const AUnit: string; Tpu: Boolean; out Info: TUnitInfo): TStub;
    function Stub(const AUnit: string; Tpu: Boolean = False): TStub;
    procedure AssertHasLine(St: TStub; const Line: string);
  end;

  TRenderingTest = class(TStubTestBase)
  published
    procedure TestEveryIndexedNameIsWhereTheIndexSays;
    procedure TestStubIsAUnitWithAnInterface;
    procedure TestRoutinesConstantsVariables;
    procedure TestRecordsShowTheirFields;
    procedure TestSystemPrimitivesBooleansAndBuiltins;
    procedure TestUntypedVarParametersAndWrapping;
    procedure TestEnumerationMembersAreIndexed;
    procedure TestLongEnumerationsWrapAndUsesSkipSystemAndItself;
  end;

  TStoreTest = class(TStubTestBase)
  private
    Dir: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFileIsWrittenReadOnlyAndReused;
    procedure TestAStaleFileIsReplaced;
    procedure TestUnitsWithASourceHaveNoStub;
    procedure TestSameUnitNameFromDifferentFilesDoesNotCollide;
  end;

implementation

uses
{$IFDEF UNIX}
  BaseUnix,
{$ENDIF}
  Contnrs, tp7enc, tp7os, tp7parse, tpudump, tutil;

procedure TStubTestBase.SetUp;
begin
  Provs := TList.Create;
  Stubs := TList.Create;
end;

procedure TStubTestBase.TearDown;
var
  I: Integer;
begin
  for I := 0 to Stubs.Count - 1 do
    TObject(Stubs[I]).Free;
  for I := 0 to Provs.Count - 1 do
    TObject(Provs[I]).Free;
  Stubs.Free;
  Provs.Free;
end;

function TStubTestBase.Tpl: string;
begin
  Result := DataFile('TURBO.TPL');
  if Result = '' then
    Ignore('TURBO.TPL is not in TP7LS_DATA');
end;

function TStubTestBase.StubOf(const AUnit: string; Tpu: Boolean; out Info: TUnitInfo): TStub;
var
  Prov: TProvider;
  Graph: string;
begin
  if Tpu then
  begin
    Graph := DataFile('GRAPH.TPU');
    if Graph = '' then
      Ignore('GRAPH.TPU is not in TP7LS_DATA');
    Prov := TProvider.Create([DirName(Graph)], Tpl);
  end
  else
    Prov := TProvider.Create([], Tpl);
  Provs.Add(Prov);
  Info := Prov.Get(AUnit);
  AssertNotNull(AUnit, Info);
  Result := Render(Info.Tpu, Info.Origin);
  Stubs.Add(Result);
end;

function TStubTestBase.Stub(const AUnit: string; Tpu: Boolean): TStub;
var
  Info: TUnitInfo;
begin
  Result := StubOf(AUnit, Tpu, Info);
end;

function IndexOfLine(St: TStub; const Line: string): Integer;
begin
  for Result := 0 to High(St.Lines) do
    if St.Lines[Result] = Line then
      Exit;
  Result := -1;
end;

procedure TStubTestBase.AssertHasLine(St: TStub; const Line: string);
begin
  AssertTrue(Line, IndexOfLine(St, Line) >= 0);
end;

procedure TRenderingTest.TestEveryIndexedNameIsWhereTheIndexSays;
var
  U: string;
  St: TStub;
  I: Integer;
  E: TStubEntry;
begin
  for U in Strs(['System', 'Crt', 'Dos', 'Overlay', 'Printer', 'Graph']) do
  begin
    St := Stub(U, True);
    AssertTrue(U, St.Count > 1);
    for I := 0 to St.Count - 1 do
    begin
      E := St.Entry(I);
      if E.Kind <> 'unit' then
        AssertEquals(U + ' ' + E.Kind + ' ' + E.Name, E.Name, LowerText(Copy(St.Lines[E.Line], E.Col + 1, E.Len)));
    end;
  end;
end;

procedure TRenderingTest.TestStubIsAUnitWithAnInterface;
var
  St: TStub;
  Res: TParseResult;
begin
  St := Stub('Crt');
  Res := Parse(St.Text);
  try
    AssertEquals(0, Length(Res.Diags));
  finally
    Res.Free;
  end;
  AssertHasLine(St, 'unit Crt;');
  AssertHasLine(St, 'interface');
  AssertEquals('end.', St.Lines[High(St.Lines)]);
end;

procedure TRenderingTest.TestRoutinesConstantsVariables;
var
  St: TStub;
begin
  St := Stub('Crt');
  AssertHasLine(St, 'procedure GotoXY(P1, P2: Byte);');
  AssertHasLine(St, 'function ReadKey: Char;');
  AssertHasLine(St, '  Blue = 1;');
  AssertHasLine(St, '  TextAttr: Byte;');
  AssertHasLine(St, 'procedure AssignCrt(var P1: Text);');
end;

procedure TRenderingTest.TestRecordsShowTheirFields;
var
  St: TStub;
  E: TStubEntry;
  B: TStringArray;
begin
  St := Stub('Dos');
  AssertHasLine(St, '  Registers = record');
  AssertHasLine(St, '    AX: Word;  { @0 }');
  E := St.Find('field', 'ah', 'Registers');
  AssertNotNull(E);
  AssertEquals('AH: Byte;  { @1 }', StripSpace(St.Lines[E.Line]));
  B := St.Block('type', 'DateTime');
  AssertEquals('end;', StripSpace(B[High(B)]));
  AssertHasLine(St, '  PathStr = string[79];');
end;

procedure TRenderingTest.TestSystemPrimitivesBooleansAndBuiltins;
var
  St: TStub;
  I, J: Integer;
  N, X: string;
begin
  St := Stub('System');
  AssertHasLine(St, '  Boolean = (False, True);  { built-in, size 1 }');
  AssertNotNull(St.Find('const', 'True'));
  AssertHasLine(St, '  Byte = 0..255;');
  AssertHasLine(St, '  Pointer = Pointer;  { built-in untyped pointer, size 4 }');
  AssertHasLine(St, 'function Copy(S: string; Index, Count: Integer): string;');
  AssertHasLine(St, '  Mem: array of Byte;  { Mem[Segment:Offset] }');
  I := IndexOfLine(St, '  Mem: array of Byte;  { Mem[Segment:Offset] }');
  for J := IndexOfLine(St, 'var') to I - 1 do
    AssertTrue(St.Lines[J] <> '');
  for X in St.Lines do
    AssertFalse(X, (Copy(X, 1, 3) = 'Mem') or (Copy(X, 1, 4) = 'Port'));
  for N in Strs(['WriteLn', 'Inc', 'Dispose', 'Str', 'Val']) do
    AssertNotNull(N, St.Find('builtin', N));
end;

procedure TRenderingTest.TestUntypedVarParametersAndWrapping;
var
  St: TStub;
  I: Integer;
begin
  St := Stub('Graph', True);
  AssertHasLine(St, 'procedure GetImage(P1, P2, P3, P4: Integer; var P5);');
  for I := 3 to High(St.Lines) do
    AssertTrue(St.Lines[I], Utf8Length(St.Lines[I], 1, Length(St.Lines[I])) <= 100);
end;

procedure TRenderingTest.TestEnumerationMembersAreIndexed;
begin
  AssertNotNull(Stub('Graph', True).Find('const', 'VGA'));
end;

procedure TRenderingTest.TestLongEnumerationsWrapAndUsesSkipSystemAndItself;
const
  Want: array[0..6] of string = (
    'uses',
    '  Crt, Dos;',
    '',
    'type',
    '  TBig = (mMember00, mMember01, mMember02, mMember03, mMember04, mMember05, mMember06, mMember07,',
    '    mMember08, mMember09, mMember10, mMember11, mMember12, mMember13, mMember14, mMember15,',
    '    mMember16, mMember17, mMember18, mMember19);');
var
  Arena: TObjectList;
  U: TUnit;
  T, C: tpudump.TSym;
  D: TTypeDesc;
  St: TStub;
  I: Integer;
  E: TStubEntry;
begin
  Arena := TObjectList.Create(True);
  try
    U := TUnit.Create;
    Arena.Add(U);
    U.Name := 'Big';
    U.Used := Strs(['System', 'Big', 'Crt', 'Dos']);
    T := tpudump.TSym.Create;
    Arena.Add(T);
    T.Kind := 'type';
    T.Name := 'TBig';
    T.Tag := 'P';
    T.Shape := 'enum';
    T.Size := 1;
    T.HasMembers := True;
    U.Symbols := [T];
    D := TTypeDesc.Create;
    Arena.Add(D);
    D.Kind := tdNamed;
    D.Name := 'TBig';
    D.UnitOf := 'Big';
    for I := 0 to 19 do
    begin
      C := tpudump.TSym.Create;
      Arena.Add(C);
      C.Kind := 'const';
      C.Name := Format('mMember%.2d', [I]);
      C.Tag := 'Q';
      C.TypeName := 'TBig';
      C.TypeDesc := D;
      C.ValueKind := vkInt;
      C.IntValue := I;
      T.Members := Concat(T.Members, [C.Name]);
      U.Symbols := Concat(U.Symbols, [C]);
    end;
    St := Render(U, 'x');
    Stubs.Add(St);
    for I := 0 to High(Want) do
      AssertEquals(Want[I], St.Lines[9 + I]);
    E := St.Find('const', 'mMember19');
    AssertEquals(15, E.Line);
    AssertEquals(37, E.Col);
    E := St.Find('const', 'mMember08');
    AssertEquals(14, E.Line);
    AssertEquals(4, E.Col);
    E := St.Find('type', 'TBig');
    AssertEquals(13, E.Line);
    AssertEquals(2, E.Col);
  finally
    Arena.Free;
  end;
end;

procedure TStoreTest.SetUp;
begin
  inherited;
  Dir := MakeTempDir;
end;

procedure TStoreTest.TearDown;
begin
  RemoveTree(Dir);
  inherited;
end;

function Writable(const Path: string): Boolean;
{$IFDEF UNIX}
var
  St: Stat;
begin
  Result := (FpStat(Path, St) = 0) and (St.st_mode and S_IWUSR <> 0);
end;
{$ELSE}
begin
  Result := FileGetAttr(Path) and faReadOnly = 0;
end;
{$ENDIF}

procedure TStoreTest.TestFileIsWrittenReadOnlyAndReused;
var
  Info: TUnitInfo;
  Store: TStubStore;
  Path, Path2: string;
  St, St2: TStub;
begin
  StubOf('Crt', False, Info);
  Store := TStubStore.Create(Dir);
  try
    AssertTrue(Store.Get(Info, Path, St));
    AssertTrue(Store.IsStub(Path));
    AssertFalse(Store.IsStub(JoinPath(JoinPath(Dir, '..'), 'x.pas')));
    AssertEquals('Crt.pas', BaseName(Path));
    AssertTrue(ReadFileBytes(Path) = Utf8ToCp866(St.Text));
    AssertFalse(Writable(Path));
    AssertTrue(Store.Get(Info, Path2, St2));
    AssertSame(St, St2);
  finally
    Store.Free;
  end;
end;

procedure TStoreTest.TestAStaleFileIsReplaced;
var
  Info: TUnitInfo;
  Store, Store2: TStubStore;
  Path, Path2: string;
  St, St2: TStub;
begin
  StubOf('Crt', False, Info);
  Store := TStubStore.Create(Dir);
  Store2 := TStubStore.Create(Dir);
  try
    AssertTrue(Store.Get(Info, Path, St));
{$IFDEF UNIX}
    FpChmod(Path, &666);
{$ELSE}
    FileSetAttr(Path, 0);
{$ENDIF}
    WriteText(Path, 'old');
    AssertTrue(Store2.Get(Info, Path2, St2));
    AssertTrue(ReadFileBytes(Path2) = Utf8ToCp866(St2.Text));
  finally
    Store2.Free;
    Store.Free;
  end;
end;

procedure TStoreTest.TestUnitsWithASourceHaveNoStub;
var
  Info: TUnitInfo;
  Store: TStubStore;
  Path: string;
  St: TStub;
begin
  Info := TUnitInfo.Create;
  Store := TStubStore.Create(Dir);
  try
    AssertFalse(Store.Get(Info, Path, St));
    AssertNull(St);
  finally
    Store.Free;
    Info.Free;
  end;
end;

procedure TStoreTest.TestSameUnitNameFromDifferentFilesDoesNotCollide;
var
  A, B: TUnitInfo;
  Store: TStubStore;
  PA, PB: string;
  SA, SB: TStub;
begin
  StubOf('Crt', False, A);
  StubOf('Crt', False, B);
  B.Origin := JoinPath(Dir, 'OTHER.TPL');
  Store := TStubStore.Create(Dir);
  try
    AssertTrue(Store.Get(A, PA, SA));
    AssertTrue(Store.Get(B, PB, SB));
    AssertTrue(PA <> PB);
  finally
    Store.Free;
  end;
end;

initialization
  RegisterTest(TRenderingTest);
  RegisterTest(TStoreTest);
end.
