unit tinc;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TSpliceTest = class(TTestCase)
  private
    function Resolve(const Name, FromPath: string; out Path, Text: string): Boolean;
  published
    procedure TestTokensAreSplicedAndMarked;
    procedure TestLoopIsLeftUnresolved;
    procedure TestWithoutAResolverNothingChanges;
  end;

implementation

uses
  SysUtils, tp7enc, tp7lex, tp7parse;

function TSpliceTest.Resolve(const Name, FromPath: string; out Path, Text: string): Boolean;
var
  N: string;
begin
  N := StripSpace(Name);
  Path := ExpandFileName(N);
  Result := True;
  if N = 'a.inc' then
    Text := 'const A = 1;'#10'{$I b.inc}'#10
  else if N = 'b.inc' then
    Text := 'type T = integer;'#10'{$I a.inc}'#10
  else
    Result := False;
end;

procedure TSpliceTest.TestTokensAreSplicedAndMarked;
var
  R: TParseResult;
  T: TToken;
  Words: string;
begin
  R := Parse('program p;'#10'{$I a.inc}'#10'var x: T;'#10'begin end.'#10, DefaultDefines, @Resolve, 'main.pas');
  try
    AssertEquals(0, Length(R.Diags));
    Words := ' ';
    for T in R.Sig do
    begin
      Words := Words + T.Text + '/' + ExtractFileName(T.FileName) + ' ';
      if T.FileName <> '' then
        AssertNotNull(T.Via);
    end;
    AssertTrue(Words, Pos(' A/a.inc ', Words) > 0);
    AssertTrue(Words, Pos(' T/b.inc ', Words) > 0);
    AssertTrue(Words, Pos(' x/ ', Words) > 0);
  finally
    R.Free;
  end;
end;

procedure TSpliceTest.TestLoopIsLeftUnresolved;
var
  R: TParseResult;
begin
  R := Parse('program p;'#10'{$I a.inc}'#10'begin end.'#10, DefaultDefines, @Resolve, 'main.pas');
  try
    AssertEquals(3, Length(R.Includes));
    AssertTrue(R.Includes[0].Resolved);
    AssertTrue(R.Includes[1].Resolved);
    AssertFalse(R.Includes[2].Resolved);
  finally
    R.Free;
  end;
end;

procedure TSpliceTest.TestWithoutAResolverNothingChanges;
var
  R: TParseResult;
  T: TToken;
begin
  R := Parse('program p;'#10'{$I a.inc}'#10'begin end.'#10);
  try
    AssertEquals(1, Length(R.Includes));
    AssertFalse(R.Includes[0].Resolved);
    for T in R.Sig do
      AssertEquals('', T.FileName);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TSpliceTest);
end.
