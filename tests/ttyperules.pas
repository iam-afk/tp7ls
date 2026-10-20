unit ttyperules;

{$mode objfpc}{$H+}

interface

uses
  Classes, fpcunit, testregistry, tp7types;

type
  TTypesTestBase = class(TTestCase)
  protected
    Ts: TTypes;
    Lines, Problems: TStringList;
    procedure SetUp; override;
    procedure TearDown; override;
    procedure Collect(const Path: string; const ExtraDirs: array of string);
    procedure CollectSrc(const Src: string);
    function ProblemLines: TStringList;
    function NamedInt(Lo, Hi: Int64): TTy;
  end;

  TRulesTest = class(TTypesTestBase)
  published
    procedure TestAssignmentCompatibility;
    procedure TestVarParametersNeedTheSameType;
    procedure TestMessagesNameTheTypes;
    procedure TestSetsAreNotOrderedByLessThan;
    procedure TestPointersToDifferentKindsDoNotMix;
  end;

  TResultsTest = class(TTypesTestBase)
  published
    procedure TestIntegerOperationsGiveTheCommonType;
    procedure TestTypeText;
  end;

  TFilesTest = class(TTypesTestBase)
  published
    procedure TestValidCodeIsNotReported;
    procedure TestEachErrorOfTheBadFileIsFound;
    procedure TestWording;
    procedure TestMoreValidCodeWithUnitsFromTpu;
    procedure TestCallsOfRoutinesThatComeFromATpu;
    procedure TestRealProgramsAreNotReported;
  end;

implementation

uses
  SysUtils, tp7enc, tp7lex, tp7parse, tp7sema, tp7os, tutil;

type
  TProblemSink = class
  public
    Out_: TStringList;
    procedure Report(Tok: TToken; const Msg: string);
  end;

procedure TProblemSink.Report(Tok: TToken; const Msg: string);
begin
  Out_.Add(IntToStr(Tok.Line) + #9 + Msg);
end;

function SamplesDir: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '../python/samples');
end;

procedure TTypesTestBase.SetUp;
begin
  Ts := TTypes.Create(nil);
  Lines := TStringList.Create;
  Problems := TStringList.Create;
end;

procedure TTypesTestBase.TearDown;
begin
  Problems.Free;
  Lines.Free;
  Ts.Free;
end;

function TTypesTestBase.NamedInt(Lo, Hi: Int64): TTy;
begin
  Result := Ts.NewTy(tyInt);
  Result.HasLo := True;
  Result.HasHi := True;
  Result.Lo := Lo;
  Result.Hi := Hi;
end;

procedure TTypesTestBase.Collect(const Path: string; const ExtraDirs: array of string);
var
  Tpl, Src: string;
  Prov: TProvider;
  Res: TParseResult;
  B: TBinder;
  Sink: TProblemSink;
  Dirs: TStringArray;
  D: string;
begin
  Tpl := DataFile('TURBO.TPL');
  if Tpl = '' then
    Ignore('TURBO.TPL is not in TP7LS_DATA');
  Src := ReadSource(Path);
  Lines.Text := StringReplace(Src, #13#10, #10, [rfReplaceAll]);
  Dirs := [DirName(Path)];
  for D in ExtraDirs do
    Dirs := Concat(Dirs, [D]);
  Prov := TProvider.Create(Dirs, Tpl);
  Res := Parse(Src, DefaultDefines, Prov.IncludeResolver(Path), Path);
  B := TBinder.Create(Res, Prov);
  Sink := TProblemSink.Create;
  try
    Sink.Out_ := Problems;
    B.Run;
    CheckTypes(Res, B, Prov, @Sink.Report);
  finally
    Sink.Free;
    B.Free;
    Res.Free;
    Prov.Free;
  end;
end;

procedure TTypesTestBase.CollectSrc(const Src: string);
var
  Tpl: string;
  Prov: TProvider;
  Res: TParseResult;
  B: TBinder;
  Sink: TProblemSink;
begin
  Tpl := DataFile('TURBO.TPL');
  if Tpl = '' then
    Ignore('TURBO.TPL is not in TP7LS_DATA');
  Prov := TProvider.Create([], Tpl);
  Res := Parse(Src);
  B := TBinder.Create(Res, Prov);
  Sink := TProblemSink.Create;
  try
    Sink.Out_ := Problems;
    B.Run;
    CheckTypes(Res, B, Prov, @Sink.Report);
  finally
    Sink.Free;
    B.Free;
    Res.Free;
    Prov.Free;
  end;
end;

function TTypesTestBase.ProblemLines: TStringList;
begin
  Result := Problems;
end;

{ TRulesTest }

procedure TRulesTest.TestAssignmentCompatibility;
var
  C65: TTy;

  procedure Ok(D, S: TTy);
  begin
    AssertEquals(Show(D) + ' := ' + Show(S), '', AssignError(D, S));
  end;

  procedure Bad(D, S: TTy);
  begin
    AssertTrue(Show(D) + ' := ' + Show(S), AssignError(D, S) <> '');
  end;

begin
  C65 := Ts.NewTy(tyChar);
  C65.HasValue := True;
  C65.Value := 65;
  C65.HasLo := True;
  C65.HasHi := True;
  C65.Lo := 65;
  C65.Hi := 65;
  Ok(IntegerTy, WordTy);
  Ok(IntegerTy, Ts.IntConst(5));
  Ok(RealTy, IntegerTy);
  Ok(StringTy, CharTy);
  Ok(CharTy, C65);
  Ok(PointerTy, NilTy);
  Ok(UnknownTy, StringTy);
  Ok(IntegerTy, UnknownTy);
  Ok(BooleanTy, BooleanTy);
  Bad(IntegerTy, RealTy);
  Bad(IntegerTy, StringTy);
  Bad(StringTy, IntegerTy);
  Bad(BooleanTy, IntegerTy);
  Bad(CharTy, IntegerTy);
  Bad(ByteTy, Ts.IntConst(300));
  Bad(WordTy, Ts.IntConst(-1));
  Bad(ByteTy, Ts.IntConst(-1));
  AssertTrue(Pos('out of range', AssignError(ByteTy, Ts.IntConst(256))) > 0);
end;

procedure TRulesTest.TestVarParametersNeedTheSameType;
begin
  AssertEquals('', VarParamError(IntegerTy, IntegerTy));
  AssertTrue(VarParamError(IntegerTy, WordTy) <> '');
  AssertTrue(VarParamError(RealTy, IntegerTy) <> '');
  AssertEquals('', VarParamError(UnknownTy, WordTy));
end;

procedure TRulesTest.TestMessagesNameTheTypes;
var
  P: TTy;
begin
  AssertEquals('Integer', Show(IntegerTy));
  AssertEquals('integer constant', Show(Ts.IntConst(3)));
  P := Ts.NewTy(tyPointer);
  P.SetTarget(IntegerTy);
  AssertEquals('^Integer', Show(P));
end;

procedure TRulesTest.TestSetsAreNotOrderedByLessThan;
begin
  CollectSrc('program t; var a, b: set of Byte; f: Boolean; begin f := a < b; f := a <= b end.');
  AssertEquals('1'#9'cannot compare set of Byte with set of Byte', Trim(Problems.Text));
end;

procedure TRulesTest.TestPointersToDifferentKindsDoNotMix;
begin
  CollectSrc('program t; var p: ^Integer; q: ^Char; r: ^Integer; begin p := q; p := r end.');
  AssertEquals('1'#9'type mismatch: cannot assign ^Char to ^Integer', Trim(Problems.Text));
end;

{ TResultsTest }

procedure TResultsTest.TestIntegerOperationsGiveTheCommonType;
var
  T: TTy;
  I: Integer;
  A, B: array[0..3] of TTy;
begin
  AssertSame(IntegerTy, Ts.CommonInt(IntegerTy, ByteTy));
  AssertSame(LongintTy, Ts.CommonInt(IntegerTy, WordTy));
  AssertSame(WordTy, Ts.CommonInt(WordTy, Ts.IntConst(1)));
  AssertSame(IntegerTy, Ts.CommonInt(IntegerTy, Ts.IntConst(1)));
  AssertSame(LongintTy, Ts.CommonInt(WordTy, Ts.IntConst(-1)));
  AssertSame(IntegerTy, Ts.CommonInt(ByteTy, Ts.IntConst(300)));
  A[0] := ByteTy;
  B[0] := ByteTy;
  A[1] := ShortIntTy;
  B[1] := Ts.IntConst(1);
  A[2] := IntegerTy;
  B[2] := NamedInt(1, 10);
  A[3] := IntegerTy;
  B[3] := Ts.NewTy(tyInt);
  for I := 0 to 3 do
  begin
    T := Ts.CommonInt(A[I], B[I]);
    AssertTrue(IntToStr(I), (T.Kind = tyInt) and (T.Name = '') and not T.HasValue);
  end;
end;

procedure TResultsTest.TestTypeText;
var
  T, S: TTy;
begin
  T := Ts.NewTy(tyArray);
  T.Elem := CharTy;
  T.Index := [NamedInt(0, 9)];
  AssertEquals('array [0..9] of Char', TypeText(T));
  T := Ts.NewTy(tyArray);
  T.Elem := IntegerTy;
  T.Open := True;
  AssertEquals('array of Integer', TypeText(T));
  T := Ts.NewTy(tyString);
  T.HasMaxLen := True;
  T.MaxLen := 10;
  AssertEquals('string[10]', TypeText(T));
  S := Ts.NewTy(tyString);
  S.HasMaxLen := True;
  S.MaxLen := 5;
  T := Ts.NewTy(tyPointer);
  T.SetTarget(S);
  AssertEquals('^string[5]', TypeText(T));
  T := Ts.NewTy(tySet);
  T.Elem := CharTy;
  AssertEquals('set of Char', TypeText(T));
  AssertEquals('integer', TypeText(Ts.NewTy(tyInt)));
end;

{ TFilesTest }

procedure TFilesTest.TestValidCodeIsNotReported;
begin
  Collect(JoinPath(SamplesDir, 'TYPES_GOOD.PAS'), []);
  AssertEquals('', Problems.Text);
end;

function LineOf(const P: string): Integer;
begin
  Result := StrToInt(Copy(P, 1, Pos(#9, P) - 1));
end;

procedure TFilesTest.TestEachErrorOfTheBadFileIsFound;
var
  I, J: Integer;
  L, After, Missing, Extra: string;
  Want, Got: TStringList;
begin
  Collect(JoinPath(SamplesDir, 'TYPES_BAD.PAS'), []);
  Want := TStringList.Create;
  Got := TStringList.Create;
  try
    for I := 0 to Lines.Count - 1 do
    begin
      L := Lines[I];
      if Pos('{', L) = 0 then
        Continue;
      After := TrimLeft(Copy(L, Pos('{', L) + 1, MaxInt));
      if (After <> '') and (After[1] in ['0'..'9']) and (Pos('ok', L) = 0) then
        Want.AddObject(IntToStr(I + 1), TObject(PtrInt(Ord(Pos('?', L) > 0))));
    end;
    for J := 0 to Problems.Count - 1 do
      Got.Add(IntToStr(LineOf(Problems[J])));
    Missing := '';
    for I := 0 to Want.Count - 1 do
      if (Got.IndexOf(Want[I]) < 0) and (PtrInt(Want.Objects[I]) = 0) then
        Missing := Missing + Want[I] + ' ';
    AssertEquals('missing', '', Missing);
    Extra := '';
    for J := 0 to Got.Count - 1 do
      if Want.IndexOf(Got[J]) < 0 then
        Extra := Extra + Problems[J] + '; ';
    AssertEquals('extra', '', Extra);
  finally
    Want.Free;
    Got.Free;
  end;
end;

procedure TFilesTest.TestWording;
var
  Frag: string;
begin
  Collect(JoinPath(SamplesDir, 'TYPES_BAD.PAS'), []);
  for Frag in Strs(['cannot assign string constant to Integer', 'constant 300 is out of range for Byte (0..255)',
    'cannot assign to the constant ''Max''', 'Boolean expression expected, found Integer',
    'too many arguments in the call of ''Take''', 'not enough arguments in the call of',
    'a variable is required for a var parameter', 'must be ordinal', 'operator ''+'' cannot be applied']) do
    AssertTrue(Frag, Pos(Frag, Problems.Text) > 0);
end;

procedure TFilesTest.TestMoreValidCodeWithUnitsFromTpu;
begin
  Collect(JoinPath(SamplesDir, 'TYPES_GOOD2.PAS'), [DataDir]);
  AssertEquals('', Problems.Text);
end;

procedure TFilesTest.TestCallsOfRoutinesThatComeFromATpu;

  function At(Line: Integer): string;
  var
    P: string;
  begin
    Result := '';
    for P in Problems do
      if LineOf(P) = Line then
        Result := Result + Copy(P, Pos(#9, P) + 1, MaxInt) + '|';
  end;

var
  P: string;
  N: Integer;
begin
  Collect(JoinPath(SamplesDir, 'TYPES_NEG.PAS'), [DataDir]);
  AssertTrue(At(5), Pos('argument 3 of ''Line'': cannot pass Char to Integer', At(5)) > 0);
  AssertTrue(At(6), Pos('not enough arguments in the call of ''Circle''', At(6)) > 0);
  AssertTrue(At(7), Pos('argument 1 of ''SetColor''', At(7)) > 0);
  N := 0;
  for P in Problems do
    if LineOf(P) = 10 then
      Inc(N);
  AssertEquals(4, N);
  AssertTrue(At(11), Pos('SearchRec is required, not DateTime', At(11)) > 0);
end;

procedure TFilesTest.TestRealProgramsAreNotReported;
var
  Name, P: string;
begin
  for Name in Strs(['WINXP.PAS', 'POLSK.PAS', 'TEST.PAS', 'option.pas']) do
  begin
    P := DataFile(Name);
    if P = '' then
      Continue;
    Problems.Clear;
    Collect(P, []);
    AssertEquals(Name, '', Problems.Text);
  end;
end;

initialization
  RegisterTests([TRulesTest, TResultsTest, TFilesTest]);
end.
