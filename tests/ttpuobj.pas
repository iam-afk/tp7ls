unit ttpuobj;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TTpuObjTestBase = class(TTestCase)
  protected
    function Tpl: string;
    function StubText(const Dirs: array of string; const AUnit: string): string;
    procedure AssertHas(const Text: string; const Parts: array of string);
  end;

  TLocalShadowTest = class(TTpuObjTestBase)
  published
    procedure TestDependenciesComeFromTheDirOfTheUnitThatUsesThem;
  end;

  TAnonymousEnumTest = class(TTpuObjTestBase)
  published
    procedure TestInlineEnumerationKeepsItsMembers;
  end;

  TStringConstantsTest = class(TTpuObjTestBase)
  published
    procedure TestStringConstantsArePascalLiterals;
  end;

  TSamplesUnitTest = class(TTpuObjTestBase)
  private
    Tmp: string;
    Text: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestConstants;
    procedure TestTypedConstantsKeepTheirValues;
    procedure TestTypes;
    procedure TestAbsoluteVariablesAndDirectives;
    procedure TestParameters;
    procedure TestPrivateSectionsAreShownInTheStubButHiddenFromUsers;
  end;

implementation

uses
  tp7enc, tp7os, tp7sema, tp7stub, tpudump, tutil;

function SamplesDir: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '../python/samples');
end;

function TTpuObjTestBase.Tpl: string;
begin
  Result := DataFile('TURBO.TPL');
  if Result = '' then
    Ignore('TURBO.TPL is not in TP7LS_DATA');
end;

function TTpuObjTestBase.StubText(const Dirs: array of string; const AUnit: string): string;
var
  Prov: TProvider;
  Info: TUnitInfo;
  St: TStub;
begin
  Prov := TProvider.Create(Dirs, Tpl);
  try
    Info := Prov.Get(AUnit);
    AssertNotNull(AUnit, Info);
    St := Render(Info.Tpu, 'x');
    Result := St.Text;
    St.Free;
  finally
    Prov.Free;
  end;
end;

procedure TTpuObjTestBase.AssertHas(const Text: string; const Parts: array of string);
var
  P: string;
begin
  for P in Parts do
    AssertTrue(P, Pos(P, Text) > 0);
end;

procedure TLocalShadowTest.TestDependenciesComeFromTheDirOfTheUnitThatUsesThem;
var
  Tmp, Lib, Ws: string;
  Data: RawByteString;
  F: TFileStream;
begin
  Tmp := MakeTempDir;
  try
    Lib := JoinPath(Tmp, 'UNITS');
    Ws := JoinPath(Tmp, 'ws');
    ForceDirectories(Lib);
    ForceDirectories(Ws);
    CopyFile(JoinPath(SamplesDir, 'VIEWS.TPU'), JoinPath(Lib, 'VIEWS.TPU'));
    CopyFile(JoinPath(SamplesDir, 'OBJECTS.TPU'), JoinPath(Lib, 'OBJECTS.TPU'));
    Data := Copy(ReadFileBytes(JoinPath(SamplesDir, 'OBJECTS.TPU')), 1, 3000);
    F := TFileStream.Create(JoinPath(Ws, 'OBJECTS.TPU'), fmCreate);
    try
      F.WriteBuffer(Data[1], Length(Data));
    finally
      F.Free;
    end;
    AssertHas(StubText([Ws, Lib], 'views'), ['Origin: TPoint;']);
  finally
    RemoveTree(Tmp);
  end;
end;

procedure TAnonymousEnumTest.TestInlineEnumerationKeepsItsMembers;
begin
  AssertHas(StubText([SamplesDir], 'views'), ['Phase: (phFocused, phPreProcess, phPostProcess);']);
end;

procedure TStringConstantsTest.TestStringConstantsArePascalLiterals;
var
  Text: string;
begin
  Text := StubText([SamplesDir], 'views');
  AssertHas(StringReplace(Text, #13#10, #10, [rfReplaceAll]), ['  CFrame = #1#1#2#2#3;'#10]);
  AssertHas(Text, ['  CGrayWindow = #24#25#26#27#28#29#30#31;']);
  AssertEquals('''it''''s''#13#10''ok''', PasLiteral('it''s'#13#10'ok'));
  AssertEquals('''''', PasLiteral(''));
end;

procedure TSamplesUnitTest.SetUp;
begin
  Tmp := MakeTempDir;
  CopyFile(JoinPath(SamplesDir, 'SAMPLES.TPU'), JoinPath(Tmp, 'SAMPLES.TPU'));
  Text := StringReplace(StubText([Tmp], 'samples'), #13#10, #10, [rfReplaceAll]);
end;

procedure TSamplesUnitTest.TearDown;
begin
  RemoveTree(Tmp);
end;

procedure TSamplesUnitTest.TestConstants;
begin
  AssertHas(Text, ['  cChar = ''A'';', '  cCtl = #13;', '  cBoolT = True;', '  cReal = 3.14159;',
    '  cSetDigit = [''0''..''9''];', '  cSetSmall = [1, 3, 5..7];', '  cColor = clGreen;', '  cDay = dFri;']);
end;

procedure TSamplesUnitTest.TestTypedConstantsKeepTheirValues;
begin
  AssertHas(Text, ['  kInt: Integer = 5;', '  kStr: string[10] = ''abc'';',
    '  kTable2: array [0..1, 0..2] of Integer = ((1, 2, 3), (4, 5, 6));']);
end;

procedure TSamplesUnitTest.TestTypes;
begin
  AssertHas(Text, ['TColors = set of TColor;', 'TLetter = ''A''..''Z'';', 'TFileU = file;', 'TFileB = file of Byte;',
    'TProcVar = procedure(var A1: Integer; A2: Word);', 'TMatrix = array [1..3, 1..3] of Real;']);
end;

procedure TSamplesUnitTest.TestAbsoluteVariablesAndDirectives;
begin
  AssertHas(Text, ['absolute $B800:$0000;', 'gMonoSeg: Word absolute $0040:$0063;', '); interrupt;']);
end;

procedure TSamplesUnitTest.TestParameters;
begin
  AssertHas(Text, ['procedure POpen(const A: array of Integer; var B: array of Char);',
    'procedure PUntyped(var Buf; Size: Word);']);
end;

procedure TSamplesUnitTest.TestPrivateSectionsAreShownInTheStubButHiddenFromUsers;
var
  Prov: TProvider;
  Fields: TSymTable;
begin
  AssertHas(Text, ['  private'#10'    Hidden: Integer;', '  public'#10'    Open2: Integer;']);
  Prov := TProvider.Create([Tmp], Tpl);
  try
    Fields := TiOfSym(tp7sema.TSym(Prov.Get('samples').Exports_.Get('tsecret'))).GetFields;
    AssertTrue(Fields.Has('open1'));
    AssertFalse(Fields.Has('hidden'));
    AssertFalse(Fields.Has('internal'));
  finally
    Prov.Free;
  end;
end;

initialization
  RegisterTest(TLocalShadowTest);
  RegisterTest(TAnonymousEnumTest);
  RegisterTest(TStringConstantsTest);
  RegisterTest(TSamplesUnitTest);
end.
