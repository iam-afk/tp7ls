unit tsema;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TSemaTestBase = class(TTestCase)
  protected
    Unresolved, Uncertain, Missing: string;
    function Tpl: string;
    function Norm(const Src: string; const Dirs: array of string; UseTpl: Boolean = True): string;
    function NormD(const Src: string; const Dir: string): string;
  end;

  TBasicsTest = class(TSemaTestBase)
  published
    procedure TestKeywordsAreLowerCaseAndSystemNamesTakeTheirDeclaredSpelling;
    procedure TestDeclaredSpellingWinsOverUseSpelling;
    procedure TestLocalScopeShadowsAndParams;
    procedure TestUnresolvedNamesAreUntouchedAndReported;
    procedure TestFunctionResultAssignment;
    procedure TestForwardPointerTypeAndRecordChain;
    procedure TestArraysOfRecordsAndMultiIndex;
    procedure TestWithStatement;
    procedure TestWithOfUnknownTypeMakesNamesUncertain;
    procedure TestEnumMembersCaseLabelsAndTypedConstants;
    procedure TestLabels;
    procedure TestInactiveBranchIsNotTouched;
    procedure TestIdempotent;
    procedure TestOnlyCaseChanges;
  end;

  TUnitsTest = class(TSemaTestBase)
  published
    procedure TestStandardUnitsAndQualifiedNames;
    procedure TestDosRecordChainThroughPointerAndFunctionResult;
    procedure TestTpuFileAndSourceUnitInSearchPath;
    procedure TestMissingUnitIsReportedAndItsNamesStay;
    procedure TestLastUnitInUsesWins;
  end;

  TUnitFilesTest = class(TSemaTestBase)
  published
    procedure TestImplementationHeaderTakesInterfaceSpellingAndParameters;
    procedure TestHeaderRepeatedWithOwnParameters;
    procedure TestImplementationSeesInterfaceAndOwnDeclarations;
    procedure TestOwnUnitNameQualification;
    procedure TestSamples;
  end;

  TObjectNamesTest = class(TSemaTestBase)
  published
    procedure TestMembersSelfInheritedAndConstructorArgumentsAreNormalised;
    procedure TestNothingIsUnresolved;
    procedure TestHeadersTakeTheSpellingOfTheDeclaration;
    procedure TestAMethodWithoutADeclarationIsReportedAndDeclaresNothing;
    procedure TestAHeaderWithoutParametersSeesTheDeclaredOnes;
    procedure TestParametersAndLocalsHideMembers;
    procedure TestAncestorFromAnotherUnit;
    procedure TestFieldsOfAncestorsThroughWith;
    procedure TestInheritedWithoutAnAncestorDoesNotCrash;
    procedure TestAncestorCycleTerminates;
    procedure TestOwnMembersHideTheAncestors;
  end;

  TWithFormatterTest = class(TSemaTestBase)
  published
    procedure TestFormatWithNormalizeMatchesReferenceLayoutPlusCase;
    procedure TestOptionLayoutUnchangedByNormalization;
  end;

  TBrokenCodeTest = class(TSemaTestBase)
  published
    procedure TestDesignatorWithoutAName;
  end;

implementation

uses
  Classes, SysUtils, tp7enc, tp7lex, tp7parse, tp7fmt, tp7sema, tutil;

function Sorted(const Tokens: TTokens): string;
var
  L: TStringList;
  T: TToken;
begin
  L := TStringList.Create;
  try
    for T in Tokens do
      L.Add(T.Text);
    L.Sort;
    L.Delimiter := ' ';
    Result := Trim(L.DelimitedText);
  finally
    L.Free;
  end;
end;

function Joined(const Tokens: TTokens): string;
var
  T: TToken;
begin
  Result := '';
  for T in Tokens do
    Result := Result + T.Text + ' ';
  Result := Trim(Result);
end;

function Contains(const S, Part: string): Boolean;
begin
  Result := Pos(Part, S) > 0;
end;

function Occurrences(const S, Part: string): Integer;
var
  P: SizeInt;
begin
  Result := 0;
  P := Pos(Part, S);
  while P > 0 do
  begin
    Inc(Result);
    P := Pos(Part, S, P + Length(Part));
  end;
end;

function Prog(const Body: string; const Decls: string = ''; const Uses_: string = ''): string;
var
  U: string;
begin
  U := '';
  if Uses_ <> '' then
    U := 'uses ' + Uses_ + ';';
  Result := 'program t;'#10 + U + #10 + Decls + #10'begin'#10 + Body + #10'end.'#10;
end;

function SigLower(const Src: string): string;
var
  Tokens: TTokens;
  T: TToken;
begin
  Result := '';
  Tokens := Lex(Src);
  for T in Tokens do
    if not (T.Kind in Trivia + [tkEOF]) then
      Result := Result + LowerCase(T.Text) + #1;
  FreeTokens(Tokens);
end;

function TSemaTestBase.Tpl: string;
begin
  Result := DataFile('TURBO.TPL');
  if Result = '' then
    Ignore('TURBO.TPL is not in TP7LS_DATA');
end;

function TSemaTestBase.Norm(const Src: string; const Dirs: array of string; UseTpl: Boolean): string;
var
  R: TParseResult;
  Prov: TProvider;
  Rep: TReport;
  TplPath: string;
begin
  TplPath := '';
  if UseTpl then
    TplPath := Tpl;
  R := Parse(Src);
  Prov := nil;
  try
    AssertEquals('syntax problems', 0, Length(R.Diags));
    Prov := TProvider.Create(Dirs, TplPath);
    Rep := NormalizeCase(R, Prov);
    Unresolved := Sorted(Rep.Unresolved);
    Uncertain := Joined(Rep.Uncertain);
    Missing := Joined(Rep.MissingUnits);
    Result := Reconstruct(R);
  finally
    R.Free;
    Prov.Free;
  end;
end;

function TSemaTestBase.NormD(const Src: string; const Dir: string): string;
begin
  Result := Norm(Src, [Dir]);
end;

{ TBasicsTest }

procedure TBasicsTest.TestKeywordsAreLowerCaseAndSystemNamesTakeTheirDeclaredSpelling;
begin
  AssertEquals('program T; var X: Integer; B: Boolean; begin WriteLn(X); X := Ord(True); Inc(X); Exit end.',
    Norm('PROGRAM T; VAR X: INTEGER; B: BOOLEAN; BEGIN WRITELN(X); X := ORD(TRUE); Inc(X); EXIT END.', []));
end;

procedure TBasicsTest.TestDeclaredSpellingWinsOverUseSpelling;
begin
  AssertTrue(Contains(Norm(Prog('count := COUNT + 1; Total := total', 'var Count, TOTAL: integer;'), []),
    'Count := Count + 1; TOTAL := TOTAL'));
end;

procedure TBasicsTest.TestLocalScopeShadowsAndParams;
var
  Out_: string;
begin
  Out_ := Norm(Prog('i := 1; P(2)', 'var I: integer;'#10'procedure P(Index: integer);'#10'var i: integer;'#10 +
    'begin INDEX := 3; I := 4 end;'), []);
  AssertTrue(Contains(Out_, 'begin Index := 3; i := 4 end;'));
  AssertTrue(Contains(Out_, 'begin'#10'I := 1; P(2)'#10'end.'));
end;

procedure TBasicsTest.TestUnresolvedNamesAreUntouchedAndReported;
begin
  AssertTrue(Contains(Norm(Prog('FooBar(1); x := UNKNOWN', 'var X: integer;'), []), 'FooBar(1); X := UNKNOWN'));
  AssertEquals('FooBar UNKNOWN', Unresolved);
end;

procedure TBasicsTest.TestFunctionResultAssignment;
begin
  AssertTrue(Contains(Norm(Prog('x := Fn(1)', 'var x: integer;'#10'function Fn(a: integer): integer;'#10'begin FN := A + 1 end;'), []),
    'begin Fn := a + 1 end;'));
end;

procedure TBasicsTest.TestForwardPointerTypeAndRecordChain;
var
  Out_: string;
begin
  Out_ := Norm(Prog('p := new_node; p^.NEXT^.value := 1; q := p^.next^.Value',
    'type PNode = ^TNode; TNode = record Next: PNode; Value: integer end;'#10 +
    'var P, Q: PNode; function new_node: pnode; begin end;'), []);
  AssertTrue(Contains(Out_, 'P := new_node'));
  AssertTrue(Contains(Out_, 'P^.Next^.Value := 1; Q := P^.Next^.Value'));
end;

procedure TBasicsTest.TestArraysOfRecordsAndMultiIndex;
begin
  AssertEquals(3, Occurrences(Norm(Prog('a[1].NAME := 1; m[1, 2].Name := 2; m[1][2].NAME := 3',
    'type R = record Name: integer end;'#10 +
    'var a: array[1..3] of R; m: array[1..3, 1..3] of R;'), []), '.Name'));
end;

procedure TBasicsTest.TestWithStatement;
var
  Out_: string;
begin
  Out_ := Norm(Prog('with r do begin NAME := 1; outer := 2 end; with r, s do begin Other := Name end',
    'type RR = record Name: integer end; SS = record Other: integer end;'#10 +
    'var r: RR; s: SS; Outer: integer;'), []);
  AssertTrue(Contains(Out_, 'Name := 1; Outer := 2'));
  AssertTrue(Contains(Out_, 'Other := Name'));
end;

procedure TBasicsTest.TestWithOfUnknownTypeMakesNamesUncertain;
begin
  AssertTrue(Contains(Norm(Prog('with Unknown^ do begin value := 1 end; value := 2', 'var Value: integer;'), []),
    'begin value := 1 end; Value := 2'));
  AssertEquals('value', Uncertain);
end;

procedure TBasicsTest.TestEnumMembersCaseLabelsAndTypedConstants;
var
  Out_: string;
begin
  Out_ := Norm(Prog('case c of cmaa: x := 1; CMBB: x := 2 end',
    'type Cmd = (cmAa, cmBb);'#10'var c: Cmd; x: integer;'#10 +
    'const Names: array[Cmd] of string = (''a'', ''b'');'#10 +
    'type Rec = record Lo, Hi: integer end;'#10'const Lim: Rec = (LO: 1; hi: 2);'#10 +
    '      Grid: array[0..1] of Rec = ((lo: 1; hi: 2), (LO: 3; Hi: 4));'#10 +
    '      G2: array[0..1, 0..1] of Rec = (((lo: 1; hi: 2), (LO: 3; hi: 4)), ((lo: 5; HI: 6), (lo: 7; hi: 8)));'), []);
  AssertTrue(Contains(Out_, 'cmAa: x := 1; cmBb: x := 2'));
  AssertTrue(Contains(Out_, '(Lo: 1; Hi: 2)'));
  AssertTrue(Contains(Out_, '((Lo: 1; Hi: 2), (Lo: 3; Hi: 4))'));
  AssertTrue(Contains(Out_, '(((Lo: 1; Hi: 2), (Lo: 3; Hi: 4)), ((Lo: 5; Hi: 6), (Lo: 7; Hi: 8)))'));
end;

procedure TBasicsTest.TestLabels;
begin
  AssertTrue(Contains(Norm(Prog('GOTO done; DONE: x := 1', 'label Done;'#10'var x: integer;'), []),
    'goto Done; Done: x := 1'));
end;

procedure TBasicsTest.TestInactiveBranchIsNotTouched;
var
  Out_: string;
begin
  Out_ := Norm(Prog('{$IFDEF NOPE}'#10'INTEGER_x := 1;'#10'{$ELSE}'#10'X := 1;'#10'{$ENDIF}', 'var x: integer;'), []);
  AssertTrue(Contains(Out_, 'INTEGER_x := 1;'));
  AssertTrue(Contains(Out_, 'x := 1;'));
end;

procedure TBasicsTest.TestIdempotent;
var
  Name, Once: string;
begin
  for Name in Strs(['polsk.pas', 'option.pas', 'TEST.PAS']) do
  begin
    if DataFile(Name) = '' then
      Ignore(Name + ' is not in TP7LS_DATA');
    Once := NormD(ReadSource(DataFile(Name)), DataDir);
    AssertEquals(Name, Once, NormD(Once, DataDir));
  end;
end;

procedure TBasicsTest.TestOnlyCaseChanges;
var
  Name, Src: string;
begin
  for Name in Strs(['polsk.pas', 'option.pas', 'TEST.PAS']) do
  begin
    if DataFile(Name) = '' then
      Ignore(Name + ' is not in TP7LS_DATA');
    Src := ReadSource(DataFile(Name));
    AssertEquals(Name, SigLower(Src), SigLower(NormD(Src, DataDir)));
  end;
end;

{ TUnitsTest }

procedure TUnitsTest.TestStandardUnitsAndQualifiedNames;
var
  Out_: string;
begin
  Out_ := Norm(Prog('clrscr; Crt.DELAY(10); r.ax := 1; r.AL := 2; intr($10, r); x := dosversion',
    'var r: registers; x: word;', 'crt, DOS'), []);
  AssertTrue(Contains(Out_, 'uses Crt, Dos;'));
  AssertTrue(Contains(Out_, 'ClrScr; Crt.Delay(10); r.AX := 1; r.AL := 2; Intr($10, r); x := DosVersion'));
  AssertTrue(Contains(Out_, 'var r: Registers; x: Word;'));
end;

procedure TUnitsTest.TestDosRecordChainThroughPointerAndFunctionResult;
begin
  AssertTrue(Contains(Norm(Prog('f.name := ''x''; findfirst(''*.*'', anyfile, f); if f.ATTR = directory then;',
    'var f: searchrec;', 'dos'), []), 'f.Name := ''x''; FindFirst(''*.*'', AnyFile, f); if f.Attr = Directory then;'));
end;

procedure TUnitsTest.TestTpuFileAndSourceUnitInSearchPath;
var
  Tmp, Out_: string;
begin
  if DataFile('GRAPH.TPU') = '' then
    Ignore('GRAPH.TPU is not in TP7LS_DATA');
  Tmp := MakeTempDir;
  try
    CopyFile(DataFile('GRAPH.TPU'), IncludeTrailingPathDelimiter(Tmp) + 'GRAPH.TPU');
    WriteText(IncludeTrailingPathDelimiter(Tmp) + 'mylib.pas', 'unit MyLib;'#10'interface'#10'type Pt = record X, Y: integer end;'#10'var Origin: Pt;'#10 +
    'procedure Move(var P: Pt);'#10'implementation'#10'procedure Move; begin end;'#10'end.'#10);
    Out_ := Norm(Prog('initgraph(gd, gm, ''''); origin.x := 1; MYLIB.move(ORIGIN); graphresult', 'var gd, gm: integer;',
      'graph, mylib'), [Tmp]);
    AssertTrue(Contains(Out_, 'uses Graph, MyLib;'));
    AssertTrue(Contains(Out_, 'InitGraph(gd, gm, ''''); Origin.X := 1; MyLib.Move(Origin); GraphResult'));
    AssertEquals('', Missing);
  finally
    RemoveTree(Tmp);
  end;
end;

procedure TUnitsTest.TestMissingUnitIsReportedAndItsNamesStay;
begin
  AssertTrue(Contains(Norm(Prog('SetColor(1); delay(1)', '', 'vesa, crt'), []), 'SetColor(1); Delay(1)'));
  AssertEquals('vesa', Missing);
end;

procedure TUnitsTest.TestLastUnitInUsesWins;
var
  Tmp: string;
begin
  Tmp := MakeTempDir;
  try
    WriteText(IncludeTrailingPathDelimiter(Tmp) + 'ua.pas', 'unit ua;'#10'interface'#10'procedure Common;'#10'implementation'#10 +
    'procedure Common; begin end;'#10'end.'#10);
    WriteText(IncludeTrailingPathDelimiter(Tmp) + 'ub.pas', 'unit ub;'#10'interface'#10'procedure COMMON;'#10'implementation'#10 +
    'procedure COMMON; begin end;'#10'end.'#10);
    AssertTrue(Contains(Norm(Prog('common', '', 'ua, ub'), [Tmp]), 'begin'#10'COMMON'#10'end.'));
    AssertTrue(Contains(Norm(Prog('common', '', 'ub, ua'), [Tmp]), 'begin'#10'Common'#10'end.'));
  finally
    RemoveTree(Tmp);
  end;
end;

{ TUnitFilesTest }

procedure TUnitFilesTest.TestImplementationHeaderTakesInterfaceSpellingAndParameters;
var
  Out_: string;
begin
  Out_ := Norm('unit u;'#10'interface'#10'function GetIt(Index: integer; var Buf: string): boolean;'#10 +
    'implementation'#10'function getit;'#10'begin'#10 +
    '  GETIT := (INDEX > 0) and (buf <> '''');'#10'end;'#10'end.'#10, []);
  AssertTrue(Contains(Out_, 'function GetIt;'));
  AssertTrue(Contains(Out_, 'GetIt := (Index > 0) and (Buf <> '''');'));
end;

procedure TUnitFilesTest.TestHeaderRepeatedWithOwnParameters;
var
  Out_: string;
begin
  Out_ := Norm('unit u;'#10'interface'#10'procedure Run(A: integer);'#10'implementation'#10 +
    'procedure RUN(b: integer);'#10'begin B := 1 end;'#10'end.'#10, []);
  AssertTrue(Contains(Out_, 'procedure Run(b: Integer);'));
  AssertTrue(Contains(Out_, 'begin b := 1 end;'));
end;

procedure TUnitFilesTest.TestImplementationSeesInterfaceAndOwnDeclarations;
begin
  AssertTrue(Contains(Norm('unit u;'#10'interface'#10'var Pub: integer;'#10'implementation'#10'var Priv: integer;'#10 +
    'procedure P; begin pub := 1; PRIV := 2 end;'#10'end.'#10, []),
    'begin Pub := 1; Priv := 2 end;'));
end;

procedure TUnitFilesTest.TestOwnUnitNameQualification;
begin
  AssertTrue(Contains(Norm('unit MyU;'#10'interface'#10'var V: integer;'#10'implementation'#10 +
    'procedure P; begin myu.v := 1 end;'#10'end.'#10, []),
    'begin MyU.V := 1 end;'));
end;

procedure TUnitFilesTest.TestSamples;
var
  Out_: string;
begin
  if DataFile('polsk.pas') = '' then
    Ignore('polsk.pas is not in TP7LS_DATA');
  Out_ := NormD(ReadSource(DataFile('polsk.pas')), DataDir);
  AssertTrue(Contains(Out_, 'n:=NextChar(str);'));
  AssertFalse(Contains(Out_, 'Nextchar'));
  if DataFile('TEST.PAS') = '' then
    Ignore('TEST.PAS is not in TP7LS_DATA');
  Out_ := NormD(ReadSource(DataFile('TEST.PAS')), DataDir);
  AssertTrue(Contains(Out_, 'uses vesa,Dos,objects,Crt,Polsk,option;'));
  AssertTrue(Contains(Out_, 'str_15=string[15];'));
end;

{ TObjectNamesTest }

const
  ObjSrc = 'program p;'#10'type'#10'  PShape = ^TShape;'#10'  TShape = object'#10'    x, y: Integer;' +
    #10'    constructor Init(AX, AY: Integer);'#10'    destructor Done; virtual;'#10 +
    '    procedure Draw; virtual;'#10'    function Area: Integer;'#10'  end;'#10 +
    '  PCircle = ^TCircle;'#10'  TCircle = object(TShape)'#10'    r: Integer;'#10 +
    '    constructor Init(AX, AY, AR: Integer);'#10'    procedure Draw; virtual;'#10'  end;' +
    #10'  TPt = record'#10'    a, b: Integer;'#10'    procedure Move(d: Integer);'#10'  end;' +
    #10'var'#10'  c: TCircle;'#10'  pc: PCircle;'#10'  pt: TPt;'#10#10 +
    'constructor TShape.Init(AX, AY: Integer);'#10'begin'#10'  X := ax;'#10'  Y := AY;'#10 +
    'end;'#10#10'destructor TShape.Done;'#10'begin'#10'end;'#10#10'procedure TShape.Draw;'#10 +
    'begin'#10'  writeln(x);'#10'end;'#10#10'function TShape.Area: Integer;'#10'begin'#10 +
    '  area := 0;'#10'end;'#10#10'constructor TCircle.Init;'#10'begin'#10 +
    '  inherited init(ax, ay);'#10'  R := ar;'#10'  self.r := 1;'#10'end;'#10#10 +
    'procedure TCircle.Draw;'#10'begin'#10'  inherited DRAW;'#10 +
    '  X := y + r + SELF.x + area;'#10'  draw;'#10'end;'#10#10 +
    'procedure TPt.Move(d: Integer);'#10'begin'#10'  A := a + D;'#10'end;'#10#10'begin'#10 +
    '  c.init(1, 2, 3);'#10'  c.DRAW;'#10'  new(pc, init(1, 2, 3));'#10'  dispose(pc, DONE);' +
    #10'  pc^.draw;'#10'  pt.move(3);'#10'  writeln(c.AREA, pc^.R);'#10'end.'#10;

procedure TObjectNamesTest.TestMembersSelfInheritedAndConstructorArgumentsAreNormalised;
var
  Out_, Want: string;
begin
  Out_ := Norm(ObjSrc, []);
  for Want in Strs(['  x := AX;'#10, '  Area := 0;'#10, '  inherited Init(AX, AY);'#10,
    '  r := AR;'#10, '  Self.r := 1;'#10, '  inherited Draw;'#10, '  x := y + r + Self.x + Area;'#10, '  Draw;'#10,
    '  a := a + d;'#10, '  c.Init(1, 2, 3);'#10, '  c.Draw;'#10, '  New(pc, Init(1, 2, 3));'#10,
    '  Dispose(pc, Done);'#10, '  pc^.Draw;'#10, '  pt.Move(3);'#10, '  WriteLn(c.Area, pc^.r);'#10]) do
    AssertTrue(Want, Contains(Out_, Want));
end;

procedure TObjectNamesTest.TestNothingIsUnresolved;
begin
  Norm(ObjSrc, []);
  AssertEquals('', Unresolved);
end;

procedure TObjectNamesTest.TestHeadersTakeTheSpellingOfTheDeclaration;
begin
  AssertTrue(Contains(Norm('program p;'#10'type T = object'#10'  procedure DoIt(Count: Integer);'#10'end;'#10 +
    'procedure t.DOIT(count: Integer);'#10'begin'#10'  count := 1'#10'end;'#10'begin end.'#10, []),
    'procedure T.DoIt(count: Integer);'));
end;

procedure TObjectNamesTest.TestAMethodWithoutADeclarationIsReportedAndDeclaresNothing;
begin
  Norm('program p;'#10'type T = object x: Integer; end;'#10'procedure T.Nope; begin end;'#10 +
    'begin Nope end.'#10, []);
  AssertEquals('Nope Nope', Unresolved);
end;

procedure TObjectNamesTest.TestAHeaderWithoutParametersSeesTheDeclaredOnes;
begin
  AssertTrue(Contains(Norm('program p;'#10'type T = object x: Integer;'#10'  procedure Put(Value: Integer);'#10'end;' +
    #10'procedure T.Put;'#10'begin'#10'  x := value'#10'end;'#10'begin end.'#10, []),
    'x := Value'));
end;

procedure TObjectNamesTest.TestParametersAndLocalsHideMembers;
begin
  AssertTrue(Contains(Norm('program p;'#10'type T = object X: Integer;'#10'  procedure Put(Value: Integer);'#10'end;' +
    #10'procedure T.Put(Value: Integer);'#10'var x: Real;'#10'begin'#10'  X := value'#10'end;' +
    #10'begin end.'#10, []),
    '  x := Value'));
end;

procedure TObjectNamesTest.TestAncestorFromAnotherUnit;
var
  D, Out_: string;
begin
  D := MakeTempDir;
  try
    WriteText(IncludeTrailingPathDelimiter(D) + 'BASE.PAS', 'unit Base;'#13#10'interface'#13#10'type'#13#10'  TBase = object'#13#10 +
    '    Count: Integer;'#13#10'    procedure Bump;'#13#10'  end;'#13#10'implementation'#13#10 +
    'procedure TBase.Bump; begin Inc(Count) end;'#13#10'end.'#13#10);
    Out_ := Norm('program p;'#10'uses Base;'#10'type TKid = object(tbase)'#10'  procedure Twice;'#10'end;' +
    #10'procedure TKid.Twice;'#10'begin'#10'  bump; BUMP; count := 0'#10'end;'#10 +
    'var k: TKid;'#10'begin'#10'  k.BUMP'#10'end.'#10, [D]);
    AssertTrue(Contains(Out_, 'object(TBase)'));
    AssertTrue(Contains(Out_, '  Bump; Bump; Count := 0'));
    AssertTrue(Contains(Out_, '  k.Bump'));
  finally
    RemoveTree(D);
  end;
end;

procedure TObjectNamesTest.TestFieldsOfAncestorsThroughWith;
begin
  AssertTrue(Contains(Norm('program p;'#10'type A = object x: Integer; end; B = object(A) y: Integer; end;'#10 +
    'var v: B;'#10'begin'#10'  with v do begin X := 1; Y := 2 end'#10'end.'#10, []),
    'begin x := 1; y := 2 end'));
end;

procedure TObjectNamesTest.TestInheritedWithoutAnAncestorDoesNotCrash;
begin
  Norm('program p;'#10'type A = object procedure P; end;'#10 +
    'procedure A.P; begin inherited P end;'#10'begin end.'#10, []);
  AssertEquals('P', Unresolved);
end;

procedure TObjectNamesTest.TestAncestorCycleTerminates;
begin
  Norm('program p;'#10'type A = object(B) x: Integer; end; B = object(A) y: Integer; end;'#10 +
    'var v: A;'#10'begin v.X := 1 end.'#10, []);
end;

procedure TObjectNamesTest.TestOwnMembersHideTheAncestors;
begin
  AssertTrue(Contains(Norm('program p;'#10'type A = object x: Integer; procedure Run; end; B = object(A) X: Byte; ' +
    'procedure RUN; end;'#10'procedure A.Run; begin end;'#10'procedure B.RUN; begin end;'#10'var v: B;'#10'begin'#10 +
    '  v.x := 1; v.run'#10'end.'#10, []), '  v.X := 1; v.RUN'));
end;

{ TWithFormatterTest }

procedure TWithFormatterTest.TestFormatWithNormalizeMatchesReferenceLayoutPlusCase;
var
  Prov: TProvider;
  Out_, Ref: string;
begin
  if (DataFile('polsk.pas') = '') or (DataFile('polsk_formatted.pas') = '') then
    Ignore('polsk.pas / polsk_formatted.pas are not in TP7LS_DATA');
  Prov := TProvider.Create([DataDir], Tpl);
  try
    Out_ := FormatSource(ReadSource(DataFile('polsk.pas')), DefaultDefines, MaxWidth, nil, True, Prov);
    Ref := ReadSource(DataFile('polsk_formatted.pas'));
    AssertEquals(SigLower(Ref), SigLower(Out_));
    AssertEquals(LowerText(Ref), LowerText(Out_));
    AssertFalse(Out_ = Ref);
    AssertEquals(Out_, FormatSource(Out_, DefaultDefines, MaxWidth, nil, True, Prov));
  finally
    Prov.Free;
  end;
end;

procedure TWithFormatterTest.TestOptionLayoutUnchangedByNormalization;
var
  Prov: TProvider;
begin
  if (DataFile('option.pas') = '') or (DataFile('option_formatted.pas') = '') then
    Ignore('option.pas / option_formatted.pas are not in TP7LS_DATA');
  Prov := TProvider.Create([DataDir], Tpl);
  try
    AssertEquals(LowerText(ReadSource(DataFile('option_formatted.pas'))),
      LowerText(FormatSource(ReadSource(DataFile('option.pas')), DefaultDefines, MaxWidth, nil, True, Prov)));
  finally
    Prov.Free;
  end;
end;

{ TBrokenCodeTest }

procedure TBrokenCodeTest.TestDesignatorWithoutAName;
var
  Src: string;
  R: TParseResult;
  Prov: TProvider;
begin
  for Src in Strs(['program t;'#10'type O = object procedure P; end;'#10'procedure O.P;'#10'begin'#10 +
    '  with inherited do P;'#10'end;'#10'begin end.'#10,
    'program t;'#10'var a: integer;'#10'begin'#10'  with ^ do a := 1;'#10'  with . do;'#10 +
    'end.'#10,
    'program t;'#10'type O = object('#10'begin end.'#10,
    'program t;'#10'type O = object X: Integer; procedure P; virtual;'#10'procedure O.P;'#10 +
    'begin'#10'  inherited;'#10'  Self.'#10'end;'#10]) do
  begin
    R := Parse(Src);
    Prov := TProvider.Create([], Tpl);
    try
      NormalizeCase(R, Prov);
    finally
      R.Free;
      Prov.Free;
    end;
  end;
end;

initialization
  RegisterTests([TBasicsTest, TUnitsTest, TUnitFilesTest, TObjectNamesTest, TWithFormatterTest, TBrokenCodeTest]);
end.
