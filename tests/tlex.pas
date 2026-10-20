unit tlex;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TLexerTest = class(TTestCase)
  published
    procedure TestRoundtripSamples;
    procedure TestRoundtripRandomGarbage;
    procedure TestCommentsDoNotNestAndDoNotMix;
    procedure TestNoSlashSlashComments;
    procedure TestDirectives;
    procedure TestNumbers;
    procedure TestStrings;
    procedure TestSymbols;
    procedure TestKeywordsCaseInsensitiveAndDirectivesAreIdents;
    procedure TestAsmLabels;
    procedure TestErrorsAreTokens;
    procedure TestNewlinesAndPositions;
    procedure TestCtrlZ;
  end;

implementation

uses
  SysUtils, tp7enc, tp7lex, tutil;

function Describe(const Src: string; SignificantOnly, WithText: Boolean): string;
var
  All: TTokens;
  T: TToken;
begin
  Result := '';
  All := Lex(Src);
  for T in All do
  begin
    if SignificantOnly and (T.Kind in Trivia + [tkEOF]) then
      Continue;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + TokenKindNames[T.Kind];
    if WithText then
      Result := Result + '(' + T.Text + ')';
  end;
  FreeTokens(All);
end;

function Kinds(const Src: string): string;
begin
  Result := Describe(Src, True, True);
end;

function KindsOnly(const Src: string): string;
begin
  Result := Describe(Src, False, False);
end;

function SignificantKinds(const Src: string): string;
begin
  Result := Describe(Src, True, False);
end;

procedure TLexerTest.TestRoundtripSamples;
var
  Dir, Path, Src: string;
  Tokens: TTokens;
  T: TToken;
  Count: Integer;
begin
  Count := 0;
  for Dir in SampleDirs do
    for Path in PasFiles(Dir) do
    begin
      Inc(Count);
      Src := ReadSource(Path);
      Tokens := Lex(Src);
      AssertEquals(Path, Src, JoinText(Tokens));
      for T in Tokens do
        AssertFalse(Path + ' ' + T.Text, T.Kind = tkError);
      FreeTokens(Tokens);
    end;
  AssertTrue(Count > 0);
end;

procedure TLexerTest.TestRoundtripRandomGarbage;
const
  Alphabet: array[0..40] of string = ('{', '}', '(', ')', '*', '''', '#', '$', '@', '.', ':', ';', ',', '^', '<',
    '>', '=', '+', '-', '/', ' ', #9, #13, #10, #26, 'a', 'Z', '0', '9', '_', '"', '!', '?', '\', '%', '&', '~',
    '`', '|', 'ё', 'Ж');
var
  K, J: Integer;
  S: string;
begin
  RandSeed := 7;
  for K := 1 to 3000 do
  begin
    S := '';
    for J := 1 to Random(41) do
      S := S + Alphabet[Random(Length(Alphabet))];
    AssertTrue(S, RoundtripOk(S));
  end;
end;

procedure TLexerTest.TestCommentsDoNotNestAndDoNotMix;
begin
  AssertEquals('COMMENT WS IDENT EOF', KindsOnly('{ { } x'));
  AssertEquals('IDENT(x)', Kinds('{ (* } x'));
  AssertEquals('IDENT(x)', Kinds('(* { *) x'));
  AssertEquals('IDENT(x)', Kinds('(* } *) x'));
end;

procedure TLexerTest.TestNoSlashSlashComments;
begin
  AssertEquals('IDENT(a) SYM(/) SYM(/) IDENT(b)', Kinds('a // b'));
end;

procedure TLexerTest.TestDirectives;
begin
  AssertEquals('DIRECTIVE DIRECTIVE COMMENT EOF', KindsOnly('{$IFDEF X}(*$I+*){ $notdirective}'));
  AssertEquals('DIRECTIVE EOF', KindsOnly('{$A+,B-,D+,E-}'));
end;

procedure TLexerTest.TestNumbers;
begin
  AssertEquals('INT(1) SYM(..) INT(10)', Kinds('1..10'));
  AssertEquals('REAL(1.5)', Kinds('1.5'));
  AssertEquals('REAL(1.5e-3) REAL(2E+4) REAL(3e2)', Kinds('1.5e-3 2E+4 3e2'));
  AssertEquals('HEX($FF) HEX($0d)', Kinds('$FF $0d'));
  AssertEquals('IDENT(a) SYM([) INT(1) SYM(]) SYM(.) IDENT(x)', Kinds('a[1].x'));
end;

procedure TLexerTest.TestStrings;
begin
  AssertEquals('STRING(''it''''s'')', Kinds('''it''''s'''));
  AssertEquals('STRING('''')', Kinds(''''''));
  AssertEquals('CHARCODE(#39)', Kinds('#39'));
  AssertEquals('STRING(''a'') CHARCODE(#13) CHARCODE(#10) STRING(''b'') CHARCODE(#$41)',
    Kinds('''a''#13#10''b''#$41'));
  AssertEquals('STRING(''ПРОГРАММА'')', Kinds('''ПРОГРАММА'''));
  AssertEquals('IDENT WS SYM WS ERROR', Copy(KindsOnly('x := ''abc'#10'z'), 1, 21));
end;

procedure TLexerTest.TestSymbols;
begin
  AssertEquals('SYM(:=) SYM(<=) SYM(>=) SYM(<>) SYM(..) SYM(^) SYM(@) SYM((.) SYM(.)) SYM(:) SYM(;)',
    Kinds(':= <= >= <> .. ^ @ (. .) : ;'));
  AssertEquals('IDENT(a) SYM(:=) IDENT(b)', Kinds('a:=b'));
  AssertEquals('SYM(() IDENT(a) SYM())', Kinds('(a)'));
  AssertEquals('ERROR((*))', Kinds('(*)'));
end;

procedure TLexerTest.TestKeywordsCaseInsensitiveAndDirectivesAreIdents;
begin
  AssertEquals('KW KW KW KW KW', SignificantKinds('BEGIN Begin end String STRING'));
  AssertEquals('IDENT IDENT IDENT IDENT IDENT IDENT IDENT',
    SignificantKinds('far near forward external absolute virtual interrupt'));
  AssertEquals('IDENT(Nextchar)', Kinds('Nextchar'));
end;

procedure TLexerTest.TestAsmLabels;
begin
  AssertEquals('ASMLABEL(@@loop) SYM(:) IDENT(jmp) ASMLABEL(@@loop)', Kinds('@@loop: jmp @@loop'));
  AssertEquals('SYM(@) IDENT(x)', Kinds('@x'));
end;

procedure TLexerTest.TestErrorsAreTokens;
begin
  AssertEquals('IDENT ERROR IDENT ERROR IDENT', SignificantKinds('a " b ! c'));
  AssertEquals('ERROR({never closed)', Kinds('{never closed'));
  AssertEquals('ERROR($)', Kinds('$'));
end;

procedure TLexerTest.TestNewlinesAndPositions;
const
  Src = 'a'#13#10'b'#13'c'#10'd {x'#10'y} e';
var
  Tokens: TTokens;
  T: TToken;
  Positions: string;
begin
  Tokens := Lex(Src);
  Positions := '';
  for T in Tokens do
    if T.Kind = tkIdent then
      Positions := Positions + Format('%s%d:%d ', [T.Text, T.Line, T.Col]);
  AssertEquals('a1:1 b2:1 c3:1 d4:1 e5:4 ', Positions);
  AssertEquals(5, Tokens[High(Tokens)].Line);
  FreeTokens(Tokens);
end;

procedure TLexerTest.TestCtrlZ;
begin
  AssertEquals('KW SYM NL CTRLZ EOF', KindsOnly('end.'#13#10#26));
  AssertEquals('IDENT ERROR IDENT EOF', KindsOnly('a'#26'b'));
end;

initialization
  RegisterTest(TLexerTest);
end.
