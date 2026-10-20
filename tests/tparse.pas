unit tparse;

{$mode objfpc}{$H+}

interface

uses
  Contnrs, fpcunit, testregistry, tp7lex, tp7parse;

type
  TParserTestBase = class(TTestCase)
  private
    FResults: TObjectList;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
    function Keep(R: TParseResult): TParseResult;
    function P(const Src: string): TParseResult;
    function PD(const Src: string; const Defines: array of string): TParseResult;
    function Check(const Src: string): TParseResult;
    function CheckD(const Src: string; const Defines: array of string): TParseResult;
    function CheckInvariants(R: TParseResult): TParseResult;
    function Stmt(const Body: string): TNode;
  end;

  TSamplesTest = class(TParserTestBase)
  published
    procedure TestSamplesParseCleanlyAndLosslessly;
    procedure TestUnitStructureOfTestPas;
  end;

  TDeclarationsTest = class(TParserTestBase)
  published
    procedure TestTypes;
    procedure TestSubrangeCountIsExact;
    procedure TestConstsAndTypedConsts;
    procedure TestAggregatesExact;
    procedure TestVarWithAbsoluteAndLabels;
    procedure TestRoutinesAndDirectives;
    procedure TestNestedRoutines;
    procedure TestObjectTypeIsParsed;
  end;

  TStatementsTest = class(TParserTestBase)
  published
    procedure TestDanglingElseBindsToNearestIf;
    procedure TestControlFlow;
    procedure TestEmptyStatementsAndSemicolons;
    procedure TestCallsAndDesignators;
    procedure TestExpressionPrecedence;
    procedure TestInlineAsmStatementIsRaw;
    procedure TestStringsSeparatedBySpaceAreNotJoined;
  end;

  TConditionalTest = class(TParserTestBase)
  published
    procedure TestBranchSelectionByDefine;
    procedure TestInactiveTextIsKeptAsTrivia;
    procedure TestUnbalancedBeginEndAcrossBranchesIsFine;
    procedure TestNestedAndDefineUndef;
    procedure TestDefinesAreCaseInsensitiveAndPredefined;
    procedure TestIfoptFollowsSwitches;
    procedure TestIncludeIsRecordedNotExpanded;
    procedure TestDiagnosticsForBrokenConditionals;
    procedure TestSecondElseIsInactive;
  end;

  TRecoveryTest = class(TParserTestBase)
  published
    procedure TestErrorsDoNotDestroyTheRest;
    procedure TestMissingEndStopsAtNextRoutine;
    procedure TestGarbageAfterEnd;
    procedure TestEmptyAndWhitespaceOnly;
    procedure TestFuzzNeverRaisesAndStaysLossless;
    procedure TestDeepNestingDoesNotCrash;
  end;

  TObjectsTest = class(TParserTestBase)
  published
    procedure TestAncestorFieldsSectionsAndMethods;
    procedure TestEmptyObjectAndObjectWithoutAncestor;
    procedure TestAFieldMayBeCalledPrivate;
    procedure TestRecordWithMethods;
    procedure TestVariantPartDoesNotTakeMethods;
    procedure TestMethodImplementationNames;
    procedure TestInheritedAsStatementAndInAnExpression;
    procedure TestNewWithAConstructorCallIsAnOrdinaryCall;
    procedure TestBrokenObjectStillGivesATree;
  end;

  TPointerToStringTest = class(TParserTestBase)
  published
    procedure TestPointerToTheReservedWordString;
  end;

  TStrayElseTest = class(TParserTestBase)
  published
    procedure TestSemicolonBeforeElseIsOneErrorWithAHint;
    procedure TestElseWithoutSemicolonIsFine;
  end;

function Prog(const Body: string; const Decls: string = ''): string;
function Diags(R: TParseResult): string;
function Count(R: TParseResult; Kind: TNodeKind): Integer;
function DeclNames(R: TParseResult): string;
function NodeKinds(N: TNode): string;

implementation

uses
  SysUtils, tp7enc, tutil;

function Prog(const Body: string; const Decls: string): string;
begin
  Result := 'program t;'#10 + Decls + #10'begin'#10 + Body + #10'end.'#10;
end;

function Diags(R: TParseResult): string;
var
  D: TDiag;
begin
  Result := '';
  for D in R.Diags do
    Result := Result + Format('%d: %s; ', [D.Token.Line, D.Message]);
end;

function Count(R: TParseResult; Kind: TNodeKind): Integer;
begin
  Result := Length(R.Tree.Nodes(Kind));
end;

function DeclNames(R: TParseResult): string;
var
  N: TNode;
begin
  Result := '';
  for N in R.Tree.Nodes(nkDeclName) do
    Result := Result + TToken(N.Kids[0]).Text + ' ';
  Result := Trim(Result);
end;

function NodeKinds(N: TNode): string;
var
  K: TObject;
begin
  Result := '';
  for K in N.Kids do
    if K is TNode then
      Result := Result + NodeKindNames[TNode(K).Kind] + ' ';
  Result := Trim(Result);
end;

function HasKind(R: TParseResult; Kind: TNodeKind): Boolean;
begin
  Result := Count(R, Kind) > 0;
end;

function HasTokenText(N: TNode; const Text: string): Boolean;
var
  K: TObject;
begin
  for K in N.Kids do
    if (K is TToken) and (TToken(K).Text = Text) then
      Exit(True);
  Result := False;
end;

{ TParserTestBase }

procedure TParserTestBase.SetUp;
begin
  FResults := TObjectList.Create(True);
end;

procedure TParserTestBase.TearDown;
begin
  FResults.Free;
end;

function TParserTestBase.Keep(R: TParseResult): TParseResult;
begin
  FResults.Add(R);
  Result := R;
end;

function TParserTestBase.P(const Src: string): TParseResult;
begin
  Result := Keep(Parse(Src));
end;

function TParserTestBase.PD(const Src: string; const Defines: array of string): TParseResult;
begin
  Result := Keep(Parse(Src, Defines));
end;

function TParserTestBase.CheckInvariants(R: TParseResult): TParseResult;
var
  TreeTokens: TTokens;
  J: Integer;
begin
  AssertEquals(R.Source, Reconstruct(R));
  TreeTokens := R.Tree.Tokens;
  AssertEquals(Length(R.Sig) - 1, Length(TreeTokens));
  for J := 0 to High(TreeTokens) do
    AssertSame(R.Sig[J], TreeTokens[J]);
  Result := R;
end;

function TParserTestBase.Check(const Src: string): TParseResult;
begin
  Result := CheckInvariants(P(Src));
end;

function TParserTestBase.CheckD(const Src: string; const Defines: array of string): TParseResult;
begin
  Result := CheckInvariants(PD(Src, Defines));
end;

function TParserTestBase.Stmt(const Body: string): TNode;
var
  R: TParseResult;
begin
  R := P(Prog(Body));
  AssertEquals('', Diags(R));
  Result := R.Tree.First(nkCompound).First(nkStmtList);
end;

{ TSamplesTest }

procedure TSamplesTest.TestSamplesParseCleanlyAndLosslessly;
var
  Path: string;
  R: TParseResult;
begin
  if DataDir = '' then
    Ignore('TP7LS_DATA is not set');
  AssertTrue(Length(PasFiles(DataDir)) > 0);
  for Path in PasFiles(DataDir) do
  begin
    R := Check(ReadSource(Path));
    AssertEquals(Path, '', Diags(R));
  end;
end;

procedure TSamplesTest.TestUnitStructureOfTestPas;
var
  R: TParseResult;
  U, N: TNode;
  Uses_: string;
begin
  if not FileExists(IncludeTrailingPathDelimiter(DataDir) + 'TEST.PAS') then
    Ignore('TEST.PAS is not in TP7LS_DATA');
  R := P(ReadSource(IncludeTrailingPathDelimiter(DataDir) + 'TEST.PAS'));
  U := R.Tree.First(nkUnit);
  AssertEquals('DeclName Interface Implementation InitSection', NodeKinds(U));
  for Uses_ in Strs(['Ident', 'str_15', 'pZnach', 'tZnach', 'tNode', 'tMainVar', 'MainLex', 'cmProg']) do
    AssertTrue(Uses_, Pos(' ' + Uses_ + ' ', ' ' + DeclNames(R) + ' ') > 0);
  Uses_ := '';
  for N in U.First(nkUsesClause).Nodes(nkName) do
    Uses_ := Uses_ + N.Text + ' ';
  AssertEquals('vesa dos objects crt polsk option ', Uses_);
end;

{ TDeclarationsTest }

procedure TDeclarationsTest.TestTypes;
var
  R: TParseResult;
  K: TNodeKind;
begin
  R := Check(Prog('', 'type'#10 +
    '  Color = (Red, Green, Blue);'#10 +
    '  Small = 1..10;  Neg = -5..5;  Ch = ''a''..''z'';  Rng = Low..High;'#10 +
    '  P = ^Rec;'#10 +
    '  Rec = record'#10 +
    '    a, b: integer;'#10 +
    '    case tag: byte of'#10 +
    '      0: (x: word);'#10 +
    '      1: (y: array[0..3] of char; z: record q: longint end);'#10 +
    '      2: ();'#10 +
    '  end;'#10 +
    '  Arr = array [1..3, Color] of packed record f: boolean end;'#10 +
    '  S = set of Color;  F = file of Rec;  U = file;  Str = string[20];  Str2 = string;'#10 +
    '  Fn = function(a: integer; var b: real): boolean;'#10 +
    '  Pr = procedure;'#10 +
    '  Alt = array(. 1 .. 3 .) of byte;'#10 +
    '  Q = Crt.Foo;'));
  AssertEquals('', Diags(R));
  for K in [nkEnumType, nkSubrangeType, nkPointerType, nkRecordType, nkVariantPart, nkVariant, nkArrayType,
    nkPackedType, nkSetType, nkFileType, nkStringType, nkProcType] do
    AssertTrue(NodeKindNames[K], HasKind(R, K));
  AssertEquals(3, Count(R, nkVariant));
end;

procedure TDeclarationsTest.TestSubrangeCountIsExact;
begin
  AssertEquals(5, Count(P(Prog('', 'type A = 1..10; B = -5..5; C = ''a''..''z''; D = Low..High; ' +
    'E = array[0..3] of byte;')), nkSubrangeType));
end;

procedure TDeclarationsTest.TestConstsAndTypedConsts;
var
  R: TParseResult;
begin
  R := Check(Prog('', 'const'#10 +
    '  N = 10;  M = N * 2 + 1;  S = ''it''''s'' + #13#10;  H = $FF;  R = 1.5e3;'#10 +
    '  T: integer = 5;'#10 +
    '  A: array[0..2] of byte = (1, 2, 3);'#10 +
    '  Rc: record x, y: integer end = (x: 1; y: 2);'#10 +
    '  Mx: array[0..1, 0..1] of byte = ((1, 2), (3, 4));'#10 +
    '  P: (boolean) = (true);'#10 +
    '  E = (3 + 4) * 2;'#10 +
    '  Names: array[1..2] of string[3] = (''abc'', ''def'');'));
  AssertEquals('', Diags(R));
  AssertEquals(6, Count(R, nkAggregate));
  AssertEquals(12, Count(R, nkConstDecl));
end;

procedure TDeclarationsTest.TestAggregatesExact;
var
  R: TParseResult;
begin
  R := P(Prog('', 'const A: array[0..1,0..1] of byte = ((1,2),(3,4)); B = (1+2)*3; ' +
    'C: record x:integer end = (x: 1);'));
  AssertEquals(4, Count(R, nkAggregate));
  AssertEquals('', Diags(R));
end;

procedure TDeclarationsTest.TestVarWithAbsoluteAndLabels;
var
  R: TParseResult;
begin
  R := Check(Prog('1: x := 1; goto 1;', 'label 1, Done;'#10 +
    'var x, y: integer; Scr: array[0..1999] of word absolute $B800:0;'));
  AssertEquals('', Diags(R));
  AssertEquals(1, Count(R, nkAbsolute));
  AssertEquals(1, Count(R, nkLabeled));
end;

procedure TDeclarationsTest.TestRoutinesAndDirectives;
var
  R: TParseResult;
begin
  R := Check('unit u;'#10 +
    'interface'#10 +
    'procedure A(x: integer; var y, z: real; const s: string); far;'#10 +
    'function B: integer;'#10 +
    'function C(n: word): longint; external;'#10 +
    'procedure D; interrupt;'#10 +
    'procedure Beep; inline($B0/$07/$CD/$29);'#10 +
    'implementation'#10 +
    'procedure A; begin end;'#10 +
    'function B; var q: integer; begin B := q end;'#10 +
    'function C; external ''foo'' name ''bar'';'#10 +
    'procedure D; assembler; asm mov ax, 1; @@l: dec ax; jnz @@l end;'#10 +
    'procedure Fwd; forward;'#10 +
    'procedure Fwd; begin end;'#10 +
    'end.');
  AssertEquals('', Diags(R));
  AssertEquals(11, Count(R, nkRoutine));
  AssertEquals(1, Count(R, nkAsm));
  AssertEquals('asm mov ax , 1 ; @@l : dec ax ; jnz @@l end', R.Tree.First(nkAsm).Text);
end;

procedure TDeclarationsTest.TestNestedRoutines;
var
  R: TParseResult;
begin
  R := Check(Prog('Outer(1)', 'procedure Outer(n: integer);'#10'  procedure Inner; begin end;'#10'begin Inner end;'));
  AssertEquals('', Diags(R));
  AssertEquals(2, Count(R, nkRoutine));
end;

procedure TDeclarationsTest.TestObjectTypeIsParsed;
var
  R: TParseResult;
begin
  R := Check(Prog('x := 1', 'type T = object'#10' x: integer;'#10' procedure P; virtual;'#10' end;'#10'var x: integer;'));
  AssertEquals('', Diags(R));
  AssertEquals(1, Count(R, nkObjectType));
  AssertEquals(1, Count(R, nkAssign));
  AssertEquals('FieldDecl Routine', NodeKinds(FieldListOf(R.Tree.First(nkObjectType))));
end;

{ TStatementsTest }

procedure TStatementsTest.TestDanglingElseBindsToNearestIf;
var
  Outer, Inner: TNode;
  K: TObject;
  Ifs: Integer;
begin
  Outer := Stmt('if a then if b then x := 1 else x := 2').First(nkIf);
  Ifs := 0;
  Inner := nil;
  for K in Outer.Kids do
    if (K is TNode) and (TNode(K).Kind = nkIf) then
    begin
      Inc(Ifs);
      Inner := TNode(K);
    end;
  AssertEquals(1, Ifs);
  AssertTrue(HasTokenText(Inner, 'else'));
  AssertFalse(HasTokenText(Outer, 'else'));
end;

procedure TStatementsTest.TestControlFlow;
var
  S, C: TNode;
begin
  S := Stmt('for i := 1 to 10 do s := s + i;'#10 +
    'for i := 10 downto 1 do begin end;'#10 +
    'while x < 3 do inc(x);'#10 +
    'repeat dec(x); inc(y) until x = 0;'#10 +
    'with p^, q do begin a := b end;'#10 +
    'case c of'#10 +
    '  1, 2: x := 1;'#10 +
    '  3..5: begin x := 2 end;'#10 +
    '  7: ;'#10 +
    '  else x := 0; y := 0'#10 +
    'end;'#10 +
    'case c of 1: x := 1 end;'#10 +
    'goto 5;');
  AssertEquals('For For While Repeat With Case Case Goto', NodeKinds(S));
  C := S.Nodes(nkCase)[0];
  AssertEquals(3, Length(C.Nodes(nkCaseBranch)));
  AssertEquals(2, Length(C.First(nkCaseElse).First(nkStmtList).Nodes(nkAssign)));
end;

procedure TStatementsTest.TestEmptyStatementsAndSemicolons;
begin
  AssertEquals(1, Length(Stmt(';;x := 1;;').Nodes(nkAssign)));
  AssertEquals(0, Length(Stmt('').Kids));
end;

procedure TStatementsTest.TestCallsAndDesignators;
var
  S, D: TNode;
begin
  S := Stmt('Writeln(''x = '', x:8:2, y:3); p^.next^[3].f := q(1)[2]; Crt.Delay(10);');
  AssertEquals(3 + 1 + 1, Length(S.Nodes(nkArg)));
  D := TNode(S.Nodes(nkAssign)[0].Kids[0]);
  AssertEquals('Name Deref Field Deref Index Field', NodeKinds(D));
  AssertEquals(2, Length(S.Nodes(nkProcCall)));
end;

procedure TStatementsTest.TestExpressionPrecedence;
var
  S, Top: TNode;
begin
  S := Stmt('x := a + b * c - d');
  AssertEquals('(Binary (Binary (Designator (Name a)) + (Binary (Designator (Name b)) * (Designator (Name c)))) - ' +
    '(Designator (Name d)))', TNode(S.First(nkAssign).Kids[2]).Sexp);
  S := Stmt('x := not a and b or c = d');
  Top := TNode(S.First(nkAssign).Kids[2]);
  AssertEquals('Binary', NodeKindNames[Top.Kind]);
  AssertEquals('=', TToken(Top.Kids[1]).Text);
  S := Stmt('x := -a * 2; y := @z; b := i in [1, 3..5, c]; s := ''a'' + #13#10''b''');
  AssertEquals(1, Length(S.Nodes(nkSetCtor)));
  AssertEquals(2, Length(S.Nodes(nkStringLit)));
  AssertEquals('#13 #10 ''b''', S.Nodes(nkStringLit)[1].Text);
end;

procedure TStatementsTest.TestInlineAsmStatementIsRaw;
var
  S: TNode;
begin
  S := Stmt('asm mov ax, 3; int $10 end; x := 1');
  AssertEquals(1, Length(S.Nodes(nkAsm)));
  AssertEquals(1, Length(S.Nodes(nkAssign)));
end;

procedure TStatementsTest.TestStringsSeparatedBySpaceAreNotJoined;
var
  N: TNode;
begin
  N := P(Prog('s := ''a'' ''b''#13')).Tree.First(nkStringLit);
  AssertEquals('''a''', N.Text);
end;

{ TConditionalTest }

const
  CondSrc = 'program t;'#10 +
    '{$IFDEF DEBUG}'#10 +
    'var dbg: integer;'#10 +
    '{$ELSE}'#10 +
    'var rel: integer;'#10 +
    '{$ENDIF}'#10 +
    'begin'#10 +
    '{$IFNDEF DEBUG}'#10 +
    '  rel := 1;'#10 +
    '{$ENDIF}'#10 +
    'end.'#10;

procedure TConditionalTest.TestBranchSelectionByDefine;
var
  R: TParseResult;
begin
  AssertEquals('t rel', DeclNames(Check(CondSrc)));
  R := CheckD(CondSrc, ['DEBUG']);
  AssertEquals('t dbg', DeclNames(R));
  AssertEquals(0, Count(R, nkAssign));
end;

procedure TConditionalTest.TestInactiveTextIsKeptAsTrivia;
var
  R: TParseResult;
  T: TToken;
  Inactive: string;
  Directives: Integer;
begin
  R := P(CondSrc);
  Inactive := ' ';
  Directives := 0;
  for T in R.Tokens do
  begin
    if not T.Active then
      Inactive := Inactive + T.Text + ' ';
    if T.Kind = tkDirective then
      Inc(Directives);
  end;
  AssertTrue(Pos(' dbg ', Inactive) > 0);
  AssertFalse(Pos(' rel ', Inactive) > 0);
  AssertEquals(5, Directives);
end;

procedure TConditionalTest.TestUnbalancedBeginEndAcrossBranchesIsFine;
const
  Src = 'program t;'#10 +
    'procedure P;'#10 +
    'begin'#10 +
    '{$IFDEF A}'#10 +
    '  if x then begin'#10 +
    '{$ELSE}'#10 +
    '  if y then begin'#10 +
    '{$ENDIF}'#10 +
    '    z := 1;'#10 +
    '  end;'#10 +
    'end;'#10 +
    'begin end.'#10;
begin
  AssertEquals('', Diags(Check(Src)));
  AssertEquals('', Diags(CheckD(Src, ['A'])));
end;

procedure TConditionalTest.TestNestedAndDefineUndef;
begin
  AssertEquals('t b', DeclNames(Check('{$DEFINE X}'#10 +
    'program t;'#10 +
    '{$IFDEF X}{$IFDEF Y}var a: integer;{$ELSE}var b: integer;{$ENDIF}{$ENDIF}'#10 +
    '{$UNDEF X}'#10 +
    '{$IFDEF X}var c: integer;{$ENDIF}'#10 +
    'begin end.')));
end;

procedure TConditionalTest.TestDefinesAreCaseInsensitiveAndPredefined;
begin
  AssertEquals('a b', DeclNames(P('{$ifdef msdos}var a: integer;{$endif}{$IFDEF VER70}var b: integer;{$ENDIF}' +
    '{$IFDEF CPU87}var c: integer;{$ENDIF}'#10'begin end.')));
end;

procedure TConditionalTest.TestIfoptFollowsSwitches;
begin
  AssertEquals('b c', DeclNames(P('{$IFOPT R+}var a: integer;{$ELSE}var b: integer;{$ENDIF}{$R+}' +
    '{$IFOPT R+}var c: integer;{$ENDIF}'#10'begin end.')));
end;

procedure TConditionalTest.TestIncludeIsRecordedNotExpanded;
var
  R: TParseResult;
begin
  R := P('program t;'#10'{$I defs.inc}'#10'{$I+}'#10'begin end.');
  AssertEquals(1, Length(R.Includes));
  AssertEquals('defs.inc', R.Includes[0].Name);
end;

procedure TConditionalTest.TestDiagnosticsForBrokenConditionals;
var
  R: TParseResult;
  Msgs: string;
begin
  R := P('{$ENDIF}'#10'{$ELSE}'#10'{$IFDEF A}'#10'begin end.');
  Msgs := Diags(R);
  AssertTrue(Pos('ENDIF', Msgs) > 0);
  AssertTrue(Pos('ELSE', Msgs) > 0);
  AssertTrue(Pos('never closed', Msgs) > 0);
  AssertEquals('{$ENDIF}'#10'{$ELSE}'#10'{$IFDEF A}'#10'begin end.', Reconstruct(R));
end;

procedure TConditionalTest.TestSecondElseIsInactive;
begin
  AssertEquals('t b', DeclNames(P('program t; {$IFDEF A}var a: byte;{$ELSE}var b: byte;{$ELSE}var c: byte;{$ENDIF}' +
    ' begin end.')));
end;

{ TRecoveryTest }

procedure TRecoveryTest.TestErrorsDoNotDestroyTheRest;
var
  R: TParseResult;
begin
  R := Check(Prog('x := ;'#10'y := 2;'#10'if then z := 3;'#10'w := 4', 'var x, y, z, w: integer;'));
  AssertTrue(R.Diags <> nil);
  AssertEquals(4, Count(R, nkAssign));
end;

procedure TRecoveryTest.TestMissingEndStopsAtNextRoutine;
var
  R: TParseResult;
  Msgs: string;
begin
  R := Check('program t;'#10'procedure A;'#10'begin'#10' x := 1;'#10'procedure B;'#10'begin end;'#10'begin end.'#10);
  Msgs := Diags(R);
  AssertTrue((Pos('missing', Msgs) > 0) or (Pos('''end''', Msgs) > 0));
  AssertEquals(2, Count(R, nkRoutine));
end;

procedure TRecoveryTest.TestGarbageAfterEnd;
begin
  AssertTrue(Check('program t;'#10'begin end.'#10'this is junk "!"'#10).Diags <> nil);
end;

procedure TRecoveryTest.TestEmptyAndWhitespaceOnly;
var
  S: string;
begin
  for S in Strs(['', '   '#10, '{just a comment}', #26]) do
    Check(S);
end;

procedure TRecoveryTest.TestFuzzNeverRaisesAndStaysLossless;
const
  Pieces: array[0..75] of string = ('begin', 'end', 'if', 'then', 'else', 'while', 'do', 'repeat', 'until', 'for',
    'to', 'case', 'of', 'with', 'goto', 'asm', 'record', 'array', 'set', 'file', 'string', 'procedure', 'function',
    'var', 'const', 'type', 'label', 'unit', 'interface', 'implementation', 'uses', 'program', 'object', 'forward',
    'external', 'inline', 'inherited', 'private', 'public', 'constructor', 'destructor', 'virtual', 'x', 'y', 'Foo',
    '1', '$F', '1.5', '''s''', '#13', ':=', ':', ';', ',', '.', '..', '(', ')', '[', ']', '^', '@', '+', '-', '*', '/',
    '=', '<>', '{$IFDEF A}', '{$ELSE}', '{$ENDIF}', '{c}', '(*c*)', '"', #10, ' ');
var
  K, J: Integer;
  Src: string;
begin
  RandSeed := 11;
  for K := 1 to 4000 do
  begin
    Src := '';
    for J := 1 to Random(41) do
    begin
      if J > 1 then
        Src := Src + ' ';
      Src := Src + Pieces[Random(Length(Pieces))];
    end;
    Check(Src);
    CheckD(Src, ['A']);
    FResults.Clear;
  end;
end;

procedure TRecoveryTest.TestDeepNestingDoesNotCrash;
begin
  Check(Prog('x := ' + StringOfChar('(', 3000) + '1' + StringOfChar(')', 3000)));
end;

{ TObjectsTest }

const
  Obj = 'type'#10'  TShape = object(TBase)'#10'    x, y: Integer;'#10'  private'#10'    z: Byte;'#10'  public'#10 +
    '    constructor Init(AX: Integer);'#10'    destructor Done; virtual;'#10'    function Area: Integer; far;'#10 +
    '  end;'#10;

procedure TObjectsTest.TestAncestorFieldsSectionsAndMethods;
var
  R: TParseResult;
  O, FL: TNode;
  K: TObject;
  Keywords: string;
begin
  R := Check(Prog('x := 1', Obj));
  AssertEquals('', Diags(R));
  O := R.Tree.First(nkObjectType);
  AssertEquals('( TBase )', O.First(nkHeritage).Text);
  FL := FieldListOf(O);
  AssertEquals('FieldDecl Section FieldDecl Section Routine Routine Routine', NodeKinds(FL));
  Keywords := '';
  for K in FL.Kids do
    if (K is TNode) and (TNode(K).Kind = nkRoutine) then
      Keywords := Keywords + TToken(TNode(K).Kids[0]).Text + ' ';
  AssertEquals('constructor destructor function ', Keywords);
  AssertEquals('virtual ;', O.Nodes(nkDirectives)[0].Text);
end;

procedure TObjectsTest.TestEmptyObjectAndObjectWithoutAncestor;
var
  R: TParseResult;
begin
  R := Check(Prog('x := 1', 'type A = object end; B = object (A) end;'));
  AssertEquals('', Diags(R));
  AssertEquals(2, Count(R, nkObjectType));
end;

procedure TObjectsTest.TestAFieldMayBeCalledPrivate;
var
  R: TParseResult;
begin
  R := Check(Prog('x := 1', 'type A = object'#10' private: Integer;'#10' public, c: Byte;'#10' end;'));
  AssertEquals('', Diags(R));
  AssertEquals(0, Count(R, nkSection));
  AssertEquals(2, Count(R, nkFieldDecl));
end;

procedure TObjectsTest.TestRecordWithMethods;
var
  R: TParseResult;
begin
  R := Check(Prog('x := 1', 'type R = record'#10' a: Integer;'#10' procedure Move(d: Integer);'#10' end;'));
  AssertEquals('', Diags(R));
  AssertEquals(1, Length(R.Tree.First(nkRecordType).Nodes(nkRoutine)));
end;

procedure TObjectsTest.TestVariantPartDoesNotTakeMethods;
begin
  AssertTrue(Check(Prog('x := 1', 'type R = record'#10' case Byte of 0: (a: Integer; procedure P);'#10' end;')).Diags
    <> nil);
end;

procedure TObjectsTest.TestMethodImplementationNames;
var
  R: TParseResult;
  Routines: TNodes;
  Owner, Decl: TNode;
begin
  R := Check(Prog('x := 1', 'procedure T.Draw(n: Integer); begin end;'#10'procedure Plain; begin end;'));
  AssertEquals('', Diags(R));
  Routines := R.Tree.Nodes(nkRoutine);
  AssertEquals(2, Length(Routines));
  RoutineNames(Routines[0], Owner, Decl);
  AssertEquals('Name T DeclName Draw', NodeKindNames[Owner.Kind] + ' ' + TToken(Owner.Kids[0]).Text + ' ' +
    NodeKindNames[Decl.Kind] + ' ' + TToken(Decl.Kids[0]).Text);
  RoutineNames(Routines[1], Owner, Decl);
  AssertNull(Owner);
  AssertEquals('Plain', TToken(Decl.Kids[0]).Text);
end;

procedure TObjectsTest.TestInheritedAsStatementAndInAnExpression;
var
  R: TParseResult;
  N: TNode;
  Lengths: string;
begin
  R := Check(Prog('', 'procedure T.P; begin'#10' inherited P(1);'#10' inherited;'#10' x := inherited F + 1;'#10'end;'));
  AssertEquals('', Diags(R));
  Lengths := '';
  for N in R.Tree.Nodes(nkInherited) do
    Lengths := Lengths + IntToStr(Length(N.Kids)) + ' ';
  AssertEquals('2 1 2 ', Lengths);
  AssertEquals('Inherited', NodeKindNames[TNode(R.Tree.Nodes(nkBinary)[0].Kids[0]).Kind]);
end;

procedure TObjectsTest.TestNewWithAConstructorCallIsAnOrdinaryCall;
begin
  AssertEquals('', Diags(Check(Prog('New(P, Init(1, 2)); Dispose(P, Done);'))));
end;

procedure TObjectsTest.TestBrokenObjectStillGivesATree;
var
  R: TParseResult;
begin
  R := Check(Prog('x := 1', 'type T = object'#10' x: ;'#10' procedure ;'#10' end;'#10'var y: Integer;'));
  AssertTrue(R.Diags <> nil);
  AssertEquals(1, Count(R, nkAssign));
end;

{ TPointerToStringTest }

procedure TPointerToStringTest.TestPointerToTheReservedWordString;
var
  Src: string;
begin
  for Src in Strs(['unit u; interface type T = object S: ^String; N: Byte; end; var P: ^string; implementation end.',
    'program p; type PS = ^String; var Q: ^String; begin end.']) do
    AssertEquals(Src, '', Diags(P(Src)));
end;

{ TStrayElseTest }

procedure TStrayElseTest.TestSemicolonBeforeElseIsOneErrorWithAHint;
begin
  AssertEquals('5: unexpected ''else'' (the '';'' before ''else'' ended the if statement: remove it); ',
    Diags(P('program a;'#10'begin'#10'  if x then'#10'    y := 1;'#10'  else'#10'    y := 2;'#10'  z := 3;'#10'end.'#10)));
end;

procedure TStrayElseTest.TestElseWithoutSemicolonIsFine;
begin
  AssertEquals('', Diags(P('program a;'#10'begin'#10'  if x then'#10'    y := 1'#10'  else'#10'    y := 2;'#10'end.'#10)));
end;

initialization
  RegisterTests([TSamplesTest, TDeclarationsTest, TStatementsTest, TConditionalTest, TRecoveryTest, TObjectsTest,
    TPointerToStringTest, TStrayElseTest]);
end.
