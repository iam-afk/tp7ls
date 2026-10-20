unit tfmt;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TGoldenTest = class(TTestCase)
  published
    procedure TestReferencePairsAreReproducedExactly;
    procedure TestIdempotentOnReferencesAndOnTestPas;
    procedure TestSemicolonBeforeUntilIsTheOnlyAddedToken;
    procedure TestFormattedOutputReparsesCleanlyWithTheSameTree;
    procedure TestWhitespaceMutationsDoNotChangeTheResult;
  end;

  TLayoutTest = class(TTestCase)
  published
    procedure TestIfElseChainAndDangling;
    procedure TestCompoundBodies;
    procedure TestRepeatAndCase;
    procedure TestCaseBranchWithStructuredStatementAndMultiElse;
    procedure TestExpressions;
    procedure TestMissingLastSemicolonAndStraySemicolons;
    procedure TestLabelsAndGoto;
    procedure TestLabelOnItsOwnLineTwoColumnsLeft;
    procedure TestLabelInNestedBlocksAndWithComments;
    procedure TestLabelBeforeEndOrSemicolon;
    procedure TestDeclarations;
    procedure TestRoutinesAndDirectives;
    procedure TestUnitWithInitSection;
  end;

  TTriviaTest = class(TTestCase)
  published
    procedure TestTrailingAndOwnLineComments;
    procedure TestBlankLinesBetweenStatementsAreKeptOnce;
    procedure TestBlankLineBeforeAnOwnLineCommentIsKept;
    procedure TestInlineCommentsSurvive;
    procedure TestMultilineCommentIsKeptVerbatim;
    procedure TestEveryCommentInEverySampleSurvives;
    procedure TestDirectiveHugsPreviousItem;
  end;

  TEmptyStatementsTest = class(TTestCase)
  published
    procedure TestEmptyBodyKeepsItsSemicolon;
    procedure TestCommentAfterTheEmptyStatement;
    procedure TestEmptyThenBeforeElseIsLegal;
    procedure TestInactiveTextHasNoTrailingBlanks;
  end;

  TFmtConditionalTest = class(TTestCase)
  published
    procedure TestInactiveBranchIsVerbatim;
    procedure TestIdempotentForBothConfigurations;
    procedure TestUnbalancedBeginEndInBranches;
  end;

  TWrappingTest = class(TTestCase)
  published
    procedure TestCallArgumentsWrapAtCommas;
    procedure TestIfConditionBreaksBeforeAndOrAtTheShallowestLevel;
    procedure TestDeclarationListsAndUses;
    procedure TestCaseLabelLine;
    procedure TestAssignmentPrefersOperatorsOverTheAssign;
    procedure TestTokensAndCommentsSurviveAndItIsIdempotent;
    procedure TestUnbreakableLineIsLeftAloneAndReported;
    procedure TestStringsWithCommasAndBracesAreNotCut;
    procedure TestCommentsAndShortLinesAreUntouched;
    procedure TestWrapLineDirectly;
    procedure TestTheReferenceFilesAreNotTouched;
    procedure TestRealSampleWithANarrowWidth;
    procedure TestNoStubLineAfterAnEarlyCut;
  end;

  TElseIfAndVariantsTest = class(TTestCase)
  published
    procedure TestElseIfChainIsFlat;
    procedure TestElseIfWithoutFinalElseAndIfInsideCompoundElse;
    procedure TestElseIfInACaseBranch;
    procedure TestCommentsAroundElseIfSurvive;
    procedure TestEveryVariantDeclarationHasItsOwnLine;
    procedure TestVariantsAreStableAndKeepTheSameTokens;
    procedure TestSemicolonInsideAVariantOneFieldNoneSeveralAll;
    procedure TestCommentOnADroppedSemicolonIsKept;
    procedure TestCommentsBetweenVariantFieldsSurvive;
    procedure TestPlainRecordsStillOneFieldGroupPerLine;
  end;

  TFmtObjectsTest = class(TTestCase)
  published
    procedure TestLayout;
    procedure TestIdempotent;
    procedure TestSectionMarkersBecomeLowerCaseWhenNormalising;
    procedure TestCommentsAndTokensSurvive;
    procedure TestObjectInsideAnInactiveBranchIsCopied;
    procedure TestLinesStayInTheLimit;
  end;

  TRefusalsTest = class(TTestCase)
  published
    procedure TestSyntaxErrorsAreNotFormatted;
    procedure TestConditionalDirectiveInsideAStatementIsRefused;
  end;

implementation

uses
  Classes, SysUtils, tp7enc, tp7lex, tp7parse, tp7fmt, tutil;

function Rd(Test: TTestCase; const Name: string): string;
var
  Path: string;
begin
  Path := IncludeTrailingPathDelimiter(DataDir) + Name;
  if (DataDir = '') or not FileExists(Path) then
    Test.Ignore(Name + ' is not in TP7LS_DATA');
  Result := ReadSource(Path);
end;

function Fmt(const Src: string): string;
begin
  Result := FormatSource(Src);
end;

function FmtD(const Src: string; const Defines: array of string): string;
begin
  Result := FormatSource(Src, Defines);
end;

function FmtW(const Src: string; Width: Integer; Warnings: TStrings = nil): string;
begin
  Result := FormatSource(Src, DefaultDefines, Width, Warnings);
end;

function SplitNl(const S: string): TStringArray;
var
  I, Start: SizeInt;
begin
  Result := nil;
  Start := 1;
  for I := 1 to Length(S) do
    if S[I] = #10 then
    begin
      Result := Concat(Result, [Copy(S, Start, I - Start)]);
      Start := I + 1;
    end;
  Result := Concat(Result, [Copy(S, Start, MaxInt)]);
end;

function JoinNl(const A: TStringArray; First, Stop: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := First to Stop - 1 do
    if I = First then
      Result := A[I]
    else
      Result := Result + #10 + A[I];
end;

function IndexOfLine(const A: TStringArray; const S: string): Integer;
begin
  for Result := 0 to High(A) do
    if A[Result] = S then
      Exit;
  Result := -1;
end;

function HasLine(const S, Line: string): Boolean;
begin
  Result := IndexOfLine(SplitNl(S), Line) >= 0;
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

function FmtBody(const Body: string; const Decls: string = ''): string;
var
  Lines: TStringArray;
  I: Integer;
begin
  Lines := SplitNl(Fmt('program t;'#10 + Decls + #10'begin'#10 + Body + #10'end.'#10));
  I := IndexOfLine(Lines, 'begin');
  if Lines[High(Lines)] = '' then
    Result := JoinNl(Lines, I + 1, Length(Lines) - 2)
  else
    Result := JoinNl(Lines, I + 1, Length(Lines) - 1);
end;

function SigTexts(const Src: string): TStringArray;
var
  Tokens: TTokens;
  T: TToken;
begin
  Result := nil;
  Tokens := Lex(Src);
  for T in Tokens do
    if not (T.Kind in Trivia + [tkEOF]) then
      Result := Concat(Result, [T.Text]);
  FreeTokens(Tokens);
end;

function SameStrings(const A, B: TStringArray): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Exit(False);
  Result := True;
end;

function JoinedSig(const Src: string; DropSemicolons: Boolean = False; Lower: Boolean = False): string;
var
  S: string;
begin
  Result := '';
  for S in SigTexts(Src) do
    if not (DropSemicolons and (S = ';')) then
      if Lower then
        Result := Result + LowerCase(S) + ' '
      else
        Result := Result + S + ' ';
end;

function Comments(const Src: string): string;
var
  Tokens: TTokens;
  T: TToken;
  L: TStringList;
begin
  L := TStringList.Create;
  try
    Tokens := Lex(Src);
    for T in Tokens do
      if T.Kind in [tkComment, tkDirective] then
        L.Add(T.Text);
    FreeTokens(Tokens);
    L.Sort;
    L.LineBreak := #0;
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function TreeKinds(const Src: string; out Diags: Integer): string;
var
  R: TParseResult;
  N: TNode;
begin
  R := Parse(Src);
  try
    Diags := Length(R.Diags);
    Result := '';
    for N in R.Tree.Walk do
      if N.Kind <> nkEmpty then
        Result := Result + NodeKindNames[N.Kind] + ' ';
  finally
    R.Free;
  end;
end;

function NoSpace(const S: string): string;
var
  C: Char;
begin
  Result := '';
  for C in S do
    if not (C in [#9..#13, ' ']) then
      Result := Result + C;
end;

function CrlfToLf(const S: string): string;
begin
  Result := StringReplace(S, #13#10, #10, [rfReplaceAll]);
  while (Result <> '') and (Result[Length(Result)] = #10) do
    SetLength(Result, Length(Result) - 1);
end;

function MaxLineLen(const S: string): Integer;
var
  L: string;
begin
  Result := 0;
  for L in SplitNl(S) do
    if Utf8Length(L, 1, Length(L)) > Result then
      Result := Utf8Length(L, 1, Length(L));
end;

function StartsWith(const S, Prefix: string): Boolean;
begin
  Result := Copy(S, 1, Length(Prefix)) = Prefix;
end;

function EndsWith(const S, Suffix: string): Boolean;
begin
  Result := (Length(S) >= Length(Suffix)) and (Copy(S, Length(S) - Length(Suffix) + 1, MaxInt) = Suffix);
end;

{ TGoldenTest }

procedure TGoldenTest.TestReferencePairsAreReproducedExactly;
begin
  AssertEquals('polsk.pas', Rd(Self, 'polsk_formatted.pas'), Fmt(Rd(Self, 'polsk.pas')));
  AssertEquals('option.pas', Rd(Self, 'option_formatted.pas'), Fmt(Rd(Self, 'option.pas')));
end;

procedure TGoldenTest.TestIdempotentOnReferencesAndOnTestPas;
var
  Name, Once: string;
begin
  for Name in Strs(['polsk.pas', 'option.pas', 'TEST.PAS']) do
  begin
    Once := Fmt(Rd(Self, Name));
    AssertEquals(Name, Once, Fmt(Once));
  end;
end;

procedure TGoldenTest.TestSemicolonBeforeUntilIsTheOnlyAddedToken;
var
  A, B, Added: TStringArray;
  Src, Y: string;
  J: Integer;
begin
  Src := Rd(Self, 'option.pas');
  A := SigTexts(Src);
  B := SigTexts(Fmt(Src));
  AssertEquals(1, Length(B) - Length(A));
  J := 0;
  Added := nil;
  for Y in B do
    if (J < Length(A)) and (A[J] = Y) then
      Inc(J)
    else
      Added := Concat(Added, [Y]);
  AssertEquals(Length(A), J);
  AssertEquals(1, Length(Added));
  AssertEquals(';', Added[0]);
end;

procedure TGoldenTest.TestFormattedOutputReparsesCleanlyWithTheSameTree;
var
  Name, Src, K1, K2: string;
  D1, D2: Integer;
begin
  for Name in Strs(['polsk.pas', 'option.pas', 'TEST.PAS']) do
  begin
    Src := Rd(Self, Name);
    K1 := TreeKinds(Src, D1);
    K2 := TreeKinds(Fmt(Src), D2);
    AssertEquals(Name, 0, D2);
    AssertEquals(Name, K1, K2);
  end;
end;

procedure TGoldenTest.TestWhitespaceMutationsDoNotChangeTheResult;
const
  Ws: array[0..3] of string = (' ', '  ', #9, ' ');
  Nl: array[0..3] of string = (#10, #13#10, ' ', #10);
var
  Name, Src, Want, Mutated: string;
  K: Integer;
  Tokens: TTokens;
  T: TToken;
begin
  RandSeed := 5;
  for Name in Strs(['polsk.pas', 'TEST.PAS']) do
  begin
    Src := Rd(Self, Name);
    Want := Fmt(Src);
    for K := 1 to 15 do
    begin
      Mutated := '';
      Tokens := Lex(Src);
      for T in Tokens do
        if T.Kind = tkWS then
          Mutated := Mutated + Ws[Random(4)]
        else if T.Kind = tkNL then
          Mutated := Mutated + Nl[Random(4)]
        else
          Mutated := Mutated + T.Text;
      FreeTokens(Tokens);
      if not SameStrings(SigTexts(Mutated), SigTexts(Src)) then
        Continue;
      AssertEquals(Name, CrlfToLf(Want), CrlfToLf(Fmt(Mutated)));
    end;
  end;
end;

{ TLayoutTest }

procedure TLayoutTest.TestIfElseChainAndDangling;
begin
  AssertEquals('  if a then'#10'    x := 1'#10'  else if b then'#10'    x := 2'#10'  else'#10 +
    '    x := 3;',
    FmtBody('if a then x:=1 else if b then x:=2 else x:=3'));
end;

procedure TLayoutTest.TestCompoundBodies;
begin
  AssertEquals('  while a do'#10'  begin'#10'    x := 1;'#10'    y := 2;'#10'  end;', FmtBody('while a do begin x:=1; y:=2 end'));
  AssertEquals('  for i := 1 to 3 do'#10'    x := x + i;', FmtBody('for i:=1 to 3 do x:=x+i'));
  AssertEquals('  with p^ do'#10'  begin'#10'    a := 1;'#10'  end;', FmtBody('with p^ do begin a:=1 end'));
end;

procedure TLayoutTest.TestRepeatAndCase;
begin
  AssertEquals('  repeat'#10'    x := x + 1;'#10'  until x > 3;', FmtBody('repeat x:=x+1 until x>3'));
  AssertEquals('  case c of'#10'    1, 2: x := 1;'#10'    3..5: begin'#10'      x := 2;'#10'    end;'#10 +
    '    7: ;'#10'    else x := 0;'#10'  end;',
    FmtBody('case c of 1,2:x:=1; 3..5:begin x:=2 end; 7:; else x:=0 end'));
end;

procedure TLayoutTest.TestCaseBranchWithStructuredStatementAndMultiElse;
begin
  AssertEquals('  case c of'#10'    1:'#10'      if a then'#10'        x := 1'#10'      else'#10 +
    '        x := 2;'#10'    else'#10'      x := 0;'#10'      y := 0;'#10'  end;',
    FmtBody('case c of 1: if a then x:=1 else x:=2; else x:=0; y:=0 end'));
end;

procedure TLayoutTest.TestExpressions;
begin
  AssertEquals('  x := -a * 2 + b div 3;'#10'  y := not (a) or b;'#10'  s := ''a'' + #13#10''b'';'#10 +
    '  w := @p;'#10'  z := [1, 3..5, c];'#10'  q := a[i, j].f^.n;',
    FmtBody('x:=-a*2+b div 3; y:=not(a)or b; s:=''a''+#13#10''b''; w:=@p; z:=[1,3..5,c]; q:=a[i,j].f^.n'));
  AssertEquals('  Writeln(x:8:2, y);', FmtBody('Writeln(x:8:2,y)'));
end;

procedure TLayoutTest.TestMissingLastSemicolonAndStraySemicolons;
begin
  AssertEquals('  x := 1;'#10'  y := 2;', FmtBody(';;x:=1;;;y:=2'));
end;

procedure TLayoutTest.TestLabelsAndGoto;
var
  Out_: string;
begin
  Out_ := Fmt('program t;'#10'label 1,Done;'#10'begin'#10'1: x:=1; goto Done; Done: end.');
  AssertTrue(Contains(Out_, 'label'#10'  1, Done;'));
  AssertTrue(Contains(Out_, #10'1:'#10'  x := 1;'#10));
end;

procedure TLayoutTest.TestLabelOnItsOwnLineTwoColumnsLeft;
var
  Out_: string;
begin
  Out_ := Fmt('label'#13#10'  m;'#13#10'begin'#13#10'  goto m;'#13#10'm:'#13#10'  exit;'#13#10'end.'#13 +
    #10);
  AssertEquals('label'#13#10'  m;'#13#10#13#10'begin'#13#10'  goto m;'#13#10'm:'#13#10'  exit;'#13#10 +
    'end.'#13#10, Out_);
  AssertEquals(Out_, Fmt(Out_));
end;

procedure TLayoutTest.TestLabelInNestedBlocksAndWithComments;
var
  Out_: string;
begin
  Out_ := Fmt('begin'#10'  if a then begin'#10'  q: x := 1;'#10'  m: while b do y := 2;'#10'  end;'#10 +
    '  { c } 2: { d } z := 3;'#10'end.'#10);
  AssertEquals('begin'#10'  if a then'#10'  begin'#10'  q:'#10'    x := 1;'#10'  m:'#10'    while b do' +
    #10'      y := 2;'#10'  end;'#10'  { c }'#10'2: { d }'#10'  z := 3;'#10'end.'#10,
    Out_);
  AssertEquals(Out_, Fmt(Out_));
end;

procedure TLayoutTest.TestLabelBeforeEndOrSemicolon;
begin
  AssertEquals('begin'#10'  repeat'#10'  L:'#10'    Inc(i);'#10'  until i > 3;'#10'M:;'#10'end.'#10,
    Fmt('begin'#10'  repeat'#10'  L: Inc(i);'#10'  until i > 3;'#10'  M: ;'#10'end.'#10));
end;

procedure TLayoutTest.TestDeclarations;
var
  Out_, Want: string;
begin
  Out_ := Fmt('program t;'#10 +
    'type A=1..10;B=(Red,Green);C=array[1..3,B]of ^A;D=record x,y:integer;case tag:byte of 0:(p:word);1:(q:char;r:string[3]) end;' +
    #10 +
    'E=array[1..2]of record f:integer end;F=set of B;G=file of A;H=function(a:integer;var b:real):boolean;' +
    #10 +
    'const N=10;S=''it''''s'';T:array[0..2]of byte=(1,2,3);R:record x,y:integer end=(x:1;y:2);' +
    #10'var a,b:integer;Scr:array[0..1999]of word absolute $B800:0;'#10'begin end.');
  for Want in Strs(['  A = 1..10;', '  B = (Red, Green);', '  C = array [1..3, B] of ^A;', '  D = record',
    '    x, y: integer;', '    case tag: byte of', '      0: (p: word);', '      1: (', '        q: char;',
    '        r: string[3];', '      );', '  end;', '  E = array [1..2] of record', '    f: integer;', '  F = set of B;',
    '  G = file of A;', '  H = function(a: integer; var b: real): boolean;', '  N = 10;', '  S = ''it''''s'';',
    '  T: array [0..2] of byte = (1, 2, 3);', '  R: record', '  end = (x: 1; y: 2);', '  a, b: integer;',
    '  Scr: array [0..1999] of word absolute $B800:0;']) do
    AssertTrue(Want, HasLine(Out_, Want));
end;

procedure TLayoutTest.TestRoutinesAndDirectives;
var
  Out_: string;
begin
  Out_ := Fmt('unit u;'#10'interface'#10'procedure A(x:integer;var y,z:real;const s:string);far;'#10 +
    'function C(n:word):longint;external;'#10'implementation'#10'procedure A;'#10 +
    ' procedure Inner;begin end;'#10'begin Inner end;'#10'procedure D;assembler;'#10'asm'#10 +
    '   mov ax,1   ;  keep   me'#10'@@l: dec ax'#10'     jnz @@l'#10'end;'#10 +
    'function C;external ''foo'' name ''bar'';'#10'end.');
  AssertTrue(Contains(Out_, 'procedure A(x: integer; var y, z: real; const s: string); far;'));
  AssertTrue(Contains(Out_, 'function C(n: word): longint; external;'));
  AssertTrue(Contains(Out_, 'procedure D; assembler;'#10'asm'#10'   mov ax,1   ;  keep   me'#10'@@l: dec ax'#10 +
    '     jnz @@l'#10'end;'));
  AssertEquals(Out_, Fmt(Out_));
end;

procedure TLayoutTest.TestUnitWithInitSection;
begin
  AssertEquals('unit u;'#10#10'interface'#10#10'implementation'#10#10'var'#10'  x: integer;'#10#10'begin' +
    #10'  x := 1;'#10'end.',
    Fmt('unit u;interface implementation var x:integer;begin x:=1 end.'));
end;

{ TTriviaTest }

procedure TTriviaTest.TestTrailingAndOwnLineComments;
begin
  AssertEquals('  x := 1; { note }'#10'  { own line }'#10'  y := 2;'#10'{ before end }',
    FmtBody('x := 1; { note }'#10'{ own line }'#10'y := 2;'#10'{ before end }'));
end;

procedure TTriviaTest.TestBlankLinesBetweenStatementsAreKeptOnce;
begin
  AssertEquals('  x := 1;'#10#10'  y := 2;', FmtBody('x:=1;'#10#10#10#10'y:=2;'));
  AssertEquals('  x := 1;', FmtBody(#10#10'x:=1;'#10#10));
end;

procedure TTriviaTest.TestBlankLineBeforeAnOwnLineCommentIsKept;
const
  Src = 'program t;'#10#10'begin'#10'  x := 1;'#10#10'  { c }'#10'  y := 2;'#10'end.'#10;
begin
  AssertEquals(Src, Fmt(Src));
end;

procedure TTriviaTest.TestInlineCommentsSurvive;
var
  Out_, C: string;
begin
  Out_ := FmtBody('x := {c1} 1 + {c2} 2 ; if a {c3} then y := 1');
  for C in Strs(['{c1}', '{c2}', '{c3}']) do
    AssertTrue(C, Contains(Out_, C));
end;

procedure TTriviaTest.TestMultilineCommentIsKeptVerbatim;
begin
  AssertTrue(Contains(FmtBody('{ one'#10'   two'#10' three }'#10'x := 1'), '  { one'#10'   two'#10' three }'#10'  x := 1;'));
end;

procedure TTriviaTest.TestEveryCommentInEverySampleSurvives;
var
  Name, Src: string;
begin
  for Name in Strs(['polsk.pas', 'option.pas', 'TEST.PAS']) do
  begin
    Src := Rd(Self, Name);
    AssertEquals(Name, Comments(Src), Comments(Fmt(Src)));
  end;
end;

procedure TTriviaTest.TestDirectiveHugsPreviousItem;
begin
  AssertTrue(Contains(Fmt('unit u;'#10'interface'#10'implementation'#10'function F(n:word):word;external;'#10 +
    '{$L f.obj}'#10'procedure P;begin end;'#10'end.'),
    'function F(n: word): word; external;'#10'{$L f.obj}'#10#10'procedure P;'));
end;

{ TEmptyStatementsTest }

procedure TEmptyStatementsTest.TestEmptyBodyKeepsItsSemicolon;
var
  Out_: string;
begin
  Out_ := Fmt('program a;'#10'begin'#10'  if x then;'#10'  while y do;'#10'  for i := 1 to 2 do;'#10 +
    '  with q do;'#10'  if x then else;'#10'end.'#10);
  AssertTrue(Contains(Out_, '  if x then;'#10'  while y do;'#10'  for i := 1 to 2 do;'#10'  with q do;'#10 +
    '  if x then'#10'  else;'#10));
  AssertEquals(Out_, Fmt(Out_));
end;

procedure TEmptyStatementsTest.TestCommentAfterTheEmptyStatement;
begin
  AssertTrue(Contains(Fmt('program a;'#10'begin'#10'  if z then ; { c }'#10'end.'#10), '  if z then; { c }'#10));
end;

procedure TEmptyStatementsTest.TestEmptyThenBeforeElseIsLegal;
var
  Out_: string;
begin
  Out_ := Fmt('program a;'#10'begin'#10'  if x then else y;'#10'end.'#10);
  AssertTrue(Contains(Out_, '  if x then'#10'  else'#10'    y;'#10));
  AssertEquals(Out_, Fmt(Out_));
end;

procedure TEmptyStatementsTest.TestInactiveTextHasNoTrailingBlanks;
var
  Out_, L: string;
begin
  Out_ := Fmt('program a;'#10'var x: integer;'#10'  {$IFDEF DEBUG}'#10'  y: integer;   '#10'  {$ENDIF}' +
    #10'begin'#10'end.'#10);
  for L in SplitNl(Out_) do
    AssertEquals(TrimRight(L), L);
  AssertTrue(Contains(Out_, '  y: integer;'#10'{$ENDIF}'#10));
  AssertEquals(Out_, Fmt(Out_));
end;

{ TFmtConditionalTest }

const
  CondSrc = 'program t;'#10'var a: integer;'#10'{$IFDEF DEBUG}'#10 +
    'var   dbg  :  integer;   { not formatted }'#10'{$ELSE}'#10'var rel:integer;'#10'{$ENDIF}' +
    #10'begin'#10'a:=1;'#10'end.'#10;

procedure TFmtConditionalTest.TestInactiveBranchIsVerbatim;
begin
  AssertTrue(Contains(Fmt(CondSrc), '  a: integer;'#10#10'{$IFDEF DEBUG}'#10'var   dbg  :  integer;   { not formatted }'#10 +
    '{$ELSE}'#10'var'#10'  rel: integer;'#10'{$ENDIF}'#10#10'begin'));
  AssertTrue(Contains(FmtD(CondSrc, ['DEBUG']), '{$IFDEF DEBUG}'#10'var'#10'  dbg: integer; { not formatted }'#10'{$ELSE}'#10 +
    'var rel:integer;'#10'{$ENDIF}'#10#10'begin'));
end;

procedure TFmtConditionalTest.TestIdempotentForBothConfigurations;
var
  Once: string;
begin
  Once := Fmt(CondSrc);
  AssertEquals(Once, Fmt(Once));
  Once := FmtD(CondSrc, ['DEBUG']);
  AssertEquals(Once, FmtD(Once, ['DEBUG']));
end;

procedure TFmtConditionalTest.TestUnbalancedBeginEndInBranches;
begin
  AssertTrue(Contains(Fmt('program t;'#10'begin'#10'{$IFDEF A}'#10'if x then begin'#10'{$ELSE}'#10'if y then begin' +
    #10'{$ENDIF}'#10'z:=1;'#10'end;'#10'end.'#10),
    '{$IFDEF A}'#10'if x then begin'#10'{$ELSE}'#10'  if y then'#10'  begin'#10'{$ENDIF}'#10 +
    '    z := 1;'));
end;

{ TWrappingTest }

const
  WA = 'FirstVariable';
  WB = 'SecondVariable';
  WC = 'ThirdVariable';

function WProg(const Body: string; const Decls: string = ''): string;
begin
  Result := 'program p;'#10 + Decls + 'begin'#10 + Body + #10'end.'#10;
end;

procedure TWrappingTest.TestCallArgumentsWrapAtCommas;
var
  W: TStringList;
  Lines: TStringArray;
  B: Integer;
begin
  W := TStringList.Create;
  try
    Lines := SplitNl(FmtW(WProg('WriteLn(''first argument '', ' + WA + ', '' second argument '', ' + WB +
      ', '' third argument '', ' + WC + ', '' fourth '', ' + WA + ');'), MaxWidth, W));
    AssertEquals(0, W.Count);
  finally
    W.Free;
  end;
  AssertTrue(MaxLineLen(JoinNl(Lines, 0, Length(Lines))) <= MaxWidth);
  B := IndexOfLine(Lines, 'begin');
  AssertTrue(EndsWith(Lines[B + 1], ','));
  AssertTrue(StartsWith(Lines[B + 2], '      '));
  AssertFalse(StartsWith(Lines[B + 2], '       '));
end;

procedure TWrappingTest.TestIfConditionBreaksBeforeAndOrAtTheShallowestLevel;
var
  Cond, Out_, L: string;
  Lines: TStringArray;
  I, B, Halts: Integer;
  AnyThen: Boolean;
begin
  Cond := '';
  for I := 1 to 7 do
  begin
    if I > 1 then
      Cond := Cond + ' and ';
    Cond := Cond + Format('(%s > %d)', [WA, I]);
  end;
  Cond := Cond + ' or (' + WB + ' = 0)';
  Out_ := Fmt(WProg('if ' + Cond + ' then Halt;'));
  Lines := SplitNl(Out_);
  AssertTrue(MaxLineLen(Out_) <= MaxWidth);
  B := IndexOfLine(Lines, 'begin');
  AssertTrue(Lines[B + 2], StartsWith(TrimLeft(Lines[B + 2]), 'and ') or StartsWith(TrimLeft(Lines[B + 2]), 'or '));
  Halts := 0;
  AnyThen := False;
  for L in Lines do
  begin
    if Trim(L) = 'Halt;' then
      Inc(Halts);
    if EndsWith(L, ' then') then
      AnyThen := True;
  end;
  AssertEquals(1, Halts);
  AssertTrue(AnyThen);
end;

procedure TWrappingTest.TestDeclarationListsAndUses;
var
  Names, Out_, L: string;
  I: Integer;
  EndsInteger, Indented: Boolean;
begin
  Names := '';
  for I := 1 to 15 do
  begin
    if I > 1 then
      Names := Names + ', ';
    Names := Names + 'Variable' + IntToStr(I);
  end;
  Out_ := Fmt('program p;'#10'uses Crt, Dos;'#10'var ' + Names + ': Integer;'#10'begin'#10'end.'#10);
  AssertTrue(MaxLineLen(Out_) <= MaxWidth);
  EndsInteger := False;
  Indented := False;
  for L in SplitNl(Out_) do
  begin
    EndsInteger := EndsInteger or EndsWith(L, 'Integer;');
    Indented := Indented or StartsWith(L, '      Variable');
  end;
  AssertTrue(EndsInteger);
  AssertTrue(Indented);
end;

procedure TWrappingTest.TestCaseLabelLine;
var
  Out_, L: string;
  Found: Boolean;
begin
  Out_ := Fmt(WProg(Format('case %s of'#10'1, 2, 3: PutImage(11 + (%s - 1) * 32, 11 + (%s - 1) * 32, pic[pole[%s, %s]], ' +
    'NormalPut, 1, 2, 3);'#10'end;', [WA, WB, WC, WA, WB])));
  AssertTrue(MaxLineLen(Out_) <= MaxWidth);
  Found := False;
  for L in SplitNl(Out_) do
    Found := Found or (StartsWith(L, '        ') and not StartsWith(L, '         '));
  AssertTrue(Found);
end;

procedure TWrappingTest.TestAssignmentPrefersOperatorsOverTheAssign;
var
  Expr: string;
  Lines: TStringArray;
  I, B: Integer;
begin
  Expr := '';
  for I := 1 to 6 do
  begin
    if I > 1 then
      Expr := Expr + ' + ';
    Expr := Expr + WA + ' * ' + WB;
  end;
  Lines := SplitNl(Fmt(WProg('Result := ' + Expr + ';')));
  B := IndexOfLine(Lines, 'begin');
  AssertTrue(StartsWith(Lines[B + 1], '  Result := '));
  AssertTrue(StartsWith(TrimLeft(Lines[B + 2]), '+ '));
end;

procedure TWrappingTest.TestTokensAndCommentsSurviveAndItIsIdempotent;
var
  Body, Out_, Flat: string;
begin
  Body := 'WriteLn(''first argument '', ' + WA + ', '' second argument '', ' + WB + ', { keep me } '' third argument '', ' +
    WC + ', '' x '', ' + WA + '); { trailing }';
  Out_ := Fmt(WProg(Body));
  Flat := FmtW(WProg(Body), 0);
  AssertEquals(NoSpace(Flat), NoSpace(Out_));
  AssertEquals(Out_, Fmt(Out_));
  AssertTrue(Contains(Out_, '{ keep me }'));
  AssertTrue(Contains(Out_, '{ trailing }'));
end;

procedure TWrappingTest.TestUnbreakableLineIsLeftAloneAndReported;
var
  W: TStringList;
  Out_: string;
begin
  W := TStringList.Create;
  try
    Out_ := FmtW(WProg('Msg := ''' + StringOfChar('x', 150) + ''';'), MaxWidth, W);
    AssertTrue(Contains(Out_, '''' + StringOfChar('x', 150) + ''''));
    AssertEquals(5, Occurrences(Out_, #10));
    AssertEquals(1, W.Count);
    AssertTrue(Contains(W[0], 'line 4'));
  finally
    W.Free;
  end;
end;

procedure TWrappingTest.TestStringsWithCommasAndBracesAreNotCut;
var
  S: string;
begin
  S := '''a, b, {c}, (d, e), ''''q, r'''' '' + ''' + StringOfChar('y', 60) + '''';
  AssertEquals(2, Occurrences(Fmt(WProg('Msg := ' + S + ' + ' + S + ';')), '''a, b, {c}, (d, e), ''''q, r'''' '''));
end;

procedure TWrappingTest.TestCommentsAndShortLinesAreUntouched;
var
  LongComment, Words: string;
  I: Integer;
begin
  Words := '';
  for I := 1 to 40 do
    Words := Words + 'word ';
  LongComment := '{ ' + Words + '}';
  AssertTrue(HasLine(Fmt(WProg(LongComment + #10'WriteLn;')), '  ' + LongComment));
  AssertEquals('program p;'#10#10'begin'#10'  WriteLn(1, 2);'#10'end.'#10, Fmt(WProg('WriteLn(1, 2);')));
end;

procedure TWrappingTest.TestWrapLineDirectly;
var
  Line, Joined, P: string;
  Parts: TStringArray;
  I: Integer;
begin
  Line := '  alpha';
  for I := 2 to 40 do
    Line := Line + ', alpha';
  Line := Line + ';';
  Parts := WrapLine(Line, 60);
  Joined := '';
  for P in Parts do
  begin
    AssertTrue(Length(P) <= 60);
    if Joined <> '' then
      Joined := Joined + ' ';
    Joined := Joined + Trim(P);
  end;
  AssertEquals(Trim(Line), Joined);
  Parts := WrapLine('  short;', 60);
  AssertEquals(1, Length(Parts));
  AssertEquals('  short;', Parts[0]);
  Parts := WrapLine(StringOfChar('x', 100), 60);
  AssertEquals(1, Length(Parts));
  AssertEquals(StringOfChar('x', 100), Parts[0]);
end;

procedure TWrappingTest.TestTheReferenceFilesAreNotTouched;
var
  Name: string;
begin
  for Name in Strs(['option_formatted.pas', 'polsk_formatted.pas']) do
    AssertTrue(Name, MaxLineLen(Rd(Self, Name)) <= MaxWidth);
end;

procedure TWrappingTest.TestRealSampleWithANarrowWidth;
var
  Src, Wide, Narrow: string;
begin
  Src := Rd(Self, 'option.pas');
  Wide := FmtW(Src, 0);
  Narrow := FmtW(Src, 70);
  AssertEquals(NoSpace(Wide), NoSpace(Narrow));
  AssertEquals(Narrow, FmtW(Narrow, 70));
end;

procedure TWrappingTest.TestNoStubLineAfterAnEarlyCut;
begin
  AssertEquals('program p;'#10#10'begin'#10'  if Ab(x) and (Second(FirstVariable, SecondVariable, ThirdVariable)'#10 +
    '      + Third(FirstVariable, SecondVariable, ThirdVariable, FourthVariable) > 0) then'#10'    Halt;'#10'end.'#10,
    Fmt(WProg('  if Ab(x) and (Second(FirstVariable, SecondVariable, ThirdVariable) + Third(FirstVariable, ' +
    'SecondVariable, ThirdVariable, FourthVariable) > 0) then Halt;')));
end;

{ TElseIfAndVariantsTest }

const
  Rec = 'program p;'#10 +
    'type R = record a, b: Integer; case Tag: Byte of 0: (p: Word); 1: (q: Char; r: string[3]); 2: (x: Integer; y: Integer;); 3: (n: record u, v: Integer end); 4: (case Sub: Boolean of True: (m: Byte; k: Byte); False: ()); 5: (); end;' +
    #10'begin'#10'end.'#10;

procedure TElseIfAndVariantsTest.TestElseIfChainIsFlat;
begin
  AssertEquals('  if a then'#10'    x := 1'#10'  else if b then'#10'    x := 2'#10'  else if c then'#10 +
    '  begin'#10'    x := 3;'#10'  end'#10'  else'#10'    x := 4;',
    FmtBody('if a then x:=1 else if b then x:=2 else if c then begin x:=3 end else x:=4'));
end;

procedure TElseIfAndVariantsTest.TestElseIfWithoutFinalElseAndIfInsideCompoundElse;
begin
  AssertEquals('  if a then'#10'    x := 1'#10'  else if b then'#10'    x := 2;', FmtBody('if a then x:=1 else if b then x:=2'));
  AssertEquals('  if a then'#10'    x := 1'#10'  else'#10'  begin'#10'    if b then'#10'      x := 2;'#10 +
    '  end;',
    FmtBody('if a then x:=1 else begin if b then x:=2 end'));
end;

procedure TElseIfAndVariantsTest.TestElseIfInACaseBranch;
begin
  AssertEquals('  case c of'#10'    1:'#10'      if a then'#10'        x := 1'#10'      else if b then' +
    #10'        x := 2'#10'      else'#10'        x := 3;'#10'  end;',
    FmtBody('case c of 1: if a then x:=1 else if b then x:=2 else x:=3 end'));
end;

procedure TElseIfAndVariantsTest.TestCommentsAroundElseIfSurvive;
var
  Out_, C: string;
begin
  Out_ := FmtBody('if a then x:=1 { one }'#10'{ two }'#10'else { three }'#10'{ four }'#10'if b then x:=2');
  for C in Strs(['{ one }', '{ two }', '{ three }', '{ four }']) do
    AssertTrue(C, Contains(Out_, C));
  AssertEquals('program p;'#10#10'begin'#10 + Out_ + #10'end.'#10, Fmt('program p;'#10'begin'#10 + Out_ + #10'end.'#10));
end;

procedure TElseIfAndVariantsTest.TestEveryVariantDeclarationHasItsOwnLine;
var
  Lines: TStringArray;
begin
  Lines := SplitNl(Fmt(Rec));
  AssertEquals('type'#10'  R = record'#10'    a, b: Integer;'#10'    case Tag: Byte of'#10 +
    '      0: (p: Word);'#10'      1: ('#10'        q: Char;'#10'        r: string[3];'#10 +
    '      );'#10'      2: ('#10'        x: Integer;'#10'        y: Integer;'#10'      );'#10 +
    '      3: ('#10'        n: record'#10'          u, v: Integer;'#10'        end'#10 +
    '      );'#10'      4: ('#10'        case Sub: Boolean of'#10'          True: ('#10 +
    '            m: Byte;'#10'            k: Byte;'#10'          );'#10'          False: ();' +
    #10'      );'#10'      5: ();'#10'  end;',
    JoinNl(Lines, 2, 30));
end;

procedure TElseIfAndVariantsTest.TestVariantsAreStableAndKeepTheSameTokens;
var
  Out_: string;
  D: Integer;
begin
  Out_ := Fmt(Rec);
  AssertEquals(Out_, Fmt(Out_));
  TreeKinds(Out_, D);
  AssertEquals(0, D);
  AssertEquals(JoinedSig(Rec, True), JoinedSig(Out_, True));
end;

procedure TElseIfAndVariantsTest.TestSemicolonInsideAVariantOneFieldNoneSeveralAll;

  function F(const V: string): string;
  begin
    Result := Fmt('program p;'#10'type R = record case Byte of ' + V + ' end;'#10'begin end.'#10);
  end;

var
  V: string;
begin
  for V in Strs(['0: (a: Byte; b: Byte);', '0: (a: Byte; b: Byte;);']) do
    AssertTrue(V, Contains(F(V), '      0: ('#10'        a: Byte;'#10'        b: Byte;'#10'      );'#10));
  for V in Strs(['0: (a: Byte);', '0: (a: Byte;);']) do
    AssertTrue(V, Contains(F(V), '      0: (a: Byte);'#10));
  AssertTrue(Contains(F('0: (n: record u: Byte end;);'), '      0: ('#10'        n: record'#10'          u: Byte;'#10'        end'#10'      );'#10));
  AssertTrue(Contains(F('0: ();'), '      0: ();'#10));
end;

procedure TElseIfAndVariantsTest.TestCommentOnADroppedSemicolonIsKept;
var
  Out_: string;
begin
  Out_ := Fmt('program p;'#10 +
    'type R = record case Byte of 0: (z: Word; { c } ); 1: ({ d } w: Word); end;'#10 +
    'begin end.'#10);
  AssertTrue(Contains(Out_, '      0: (z: Word { c });'));
  AssertTrue(Contains(Out_, '      1: ({ d } w: Word);'));
  AssertEquals(Out_, Fmt(Out_));
end;

procedure TElseIfAndVariantsTest.TestCommentsBetweenVariantFieldsSurvive;
var
  Src, Out_, C: string;
begin
  Src := 'program p;'#10'type R = record case Byte of'#10'0: ( { first }'#10'a: Byte; { after a }' +
    #10'{ before b }'#10'b: Byte'#10'{ last } ); end;'#10'begin end.'#10;
  Out_ := Fmt(Src);
  for C in Strs(['{ first }', '{ after a }', '{ before b }', '{ last }']) do
    AssertTrue(C, Contains(Out_, C));
  AssertEquals(Out_, Fmt(Out_));
  AssertEquals(Comments(Src), Comments(Out_));
end;

procedure TElseIfAndVariantsTest.TestPlainRecordsStillOneFieldGroupPerLine;
begin
  AssertTrue(Contains(Fmt('program p;'#10'type R = record a, b: Integer; c: Byte; end;'#10'begin end.'#10),
    '    a, b: Integer;'#10'    c: Byte;'#10'  end;'));
end;

{ TFmtObjectsTest }

const
  ObjSrc = 'unit u;interface'#10'type'#10'  PShape=^TShape;'#10'  TShape  =  object (TBase)'#10 +
    '    x,y:Integer;   { pos }'#10'  private'#10'   z:Byte;'#10'  public'#10#10 +
    '    constructor Init(AX,AY:Integer);'#10'    destructor Done;virtual;   { bye }'#10 +
    '    procedure Draw ;virtual;'#10'    function Area:Integer;far;'#10'  end;'#10 +
    '  TPt=record a,b:Integer;procedure Move(d:Integer);end;'#10'  TE=object end;'#10 +
    'implementation'#10'constructor TShape.Init(AX,AY:Integer);'#10'begin'#10 +
    'inherited Init(AX,AY);'#10'  inherited;'#10'  x:=inherited Area+1;'#10 +
    '  if x>0 then inherited Draw else inherited Done;'#10'end;'#10'end.'#10;
  ObjWant = 'unit u;'#10#10'interface'#10#10'type'#10'  PShape = ^TShape;'#10 +
    '  TShape = object(TBase)'#10'    x, y: Integer; { pos }'#10'  private'#10'    z: Byte;' +
    #10'  public'#10'    constructor Init(AX, AY: Integer);'#10 +
    '    destructor Done; virtual; { bye }'#10'    procedure Draw; virtual;'#10 +
    '    function Area: Integer; far;'#10'  end;'#10'  TPt = record'#10'    a, b: Integer;'#10 +
    '    procedure Move(d: Integer);'#10'  end;'#10'  TE = object'#10'  end;'#10#10 +
    'implementation'#10#10'constructor TShape.Init(AX, AY: Integer);'#10'begin'#10 +
    '  inherited Init(AX, AY);'#10'  inherited;'#10'  x := inherited Area + 1;'#10 +
    '  if x > 0 then'#10'    inherited Draw'#10'  else'#10'    inherited Done;'#10'end;'#10#10 +
    'end.'#10;

procedure TFmtObjectsTest.TestLayout;
begin
  AssertEquals(ObjWant, Fmt(ObjSrc));
end;

procedure TFmtObjectsTest.TestIdempotent;
begin
  AssertEquals(ObjWant, Fmt(ObjWant));
end;

procedure TFmtObjectsTest.TestSectionMarkersBecomeLowerCaseWhenNormalising;
begin
  Ignore('needs tp7sema (identifier normalisation), not ported yet');
end;

procedure TFmtObjectsTest.TestCommentsAndTokensSurvive;
var
  Out_: string;
begin
  Out_ := Fmt(ObjSrc);
  AssertEquals(Comments(ObjSrc), Comments(Out_));
  AssertEquals(JoinedSig(ObjSrc, False, True), JoinedSig(Out_, False, True));
end;

procedure TFmtObjectsTest.TestObjectInsideAnInactiveBranchIsCopied;
var
  Out_: string;
begin
  Out_ := Fmt('program t;'#10'type'#10'  T = object'#10'    x: Integer;'#10'{$IFDEF NOPE}'#10 +
    '    y:integer;'#10'{$ENDIF}'#10'  end;'#10'begin'#10'end.'#10);
  AssertTrue(Contains(Out_, '{$IFDEF NOPE}'#10'    y:integer;'#10'{$ENDIF}'));
  AssertTrue(Contains(Out_, '  T = object'#10'    x: Integer;'));
end;

procedure TFmtObjectsTest.TestLinesStayInTheLimit;
var
  Params: string;
  I: Integer;
begin
  Params := '';
  for I := 1 to 19 do
  begin
    if I > 1 then
      Params := Params + '; ';
    Params := Params + 'a' + IntToStr(I) + ': Integer';
  end;
  AssertTrue(MaxLineLen(Fmt('program t;'#10'type T = object'#10' procedure P(' + Params + ');'#10' end;'#10'begin end.'#10))
    <= TpLineLimit);
end;

{ TRefusalsTest }

procedure TRefusalsTest.TestSyntaxErrorsAreNotFormatted;
var
  Bad: string;
  Raised: Boolean;
begin
  for Bad in Strs(['program t; begin x := ; end.', 'program t; begin if then x := 1; end.', 'program t; begin x := 1 end']) do
  begin
    Raised := False;
    try
      Fmt(Bad);
    except
      on EFormatError do
        Raised := True;
    end;
    AssertTrue(Bad, Raised);
  end;
end;

procedure TRefusalsTest.TestConditionalDirectiveInsideAStatementIsRefused;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    Fmt('program t; begin x := {$IFDEF A}1{$ELSE}2{$ENDIF}; end.');
  except
    on EFormatError do
      Raised := True;
  end;
  AssertTrue(Raised);
end;

initialization
  RegisterTests([TGoldenTest, TLayoutTest, TTriviaTest, TEmptyStatementsTest, TFmtConditionalTest, TWrappingTest,
    TElseIfAndVariantsTest, TFmtObjectsTest, TRefusalsTest]);
end.
