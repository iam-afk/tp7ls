program tp7lexcli;

{$mode objfpc}{$H+}

uses
  SysUtils, tp7enc, tp7lex;

function Escape(const Bytes: RawByteString): string;
var
  C: Char;
begin
  Result := '';
  for C in Bytes do
    if (C >= ' ') and (C <= '~') and (C <> '\') then
      Result := Result + C
    else
      Result := Result + '\x' + IntToHex(Ord(C), 2);
end;

procedure Dump(const Src: string; const Tokens: TTokens);
var
  T: TToken;
  Col: SizeInt;
begin
  for T in Tokens do
  begin
    Col := Utf8Length(Src, T.Pos - T.Col + 1, T.Pos - 1) + 1;
    WriteLn(TokenKindNames[T.Kind], ' ', T.Line, ':', Col, ' ', Escape(Utf8ToCp866(T.Text)));
  end;
end;

procedure Check(const Src: string; const Tokens: TTokens);
var
  T: TToken;
  Errors: Integer;
begin
  Errors := 0;
  for T in Tokens do
    if T.Kind = tkError then
      Inc(Errors);
  Write(Length(Tokens), ' tokens, ', Length(Significant(Tokens)), ' significant, ', Errors, ' errors, roundtrip ');
  if JoinText(Tokens) = Src then
    WriteLn('OK')
  else
    WriteLn('BROKEN');
  for T in Tokens do
    if T.Kind = tkError then
      WriteLn('   ERROR ', T.Line, ':', T.Col, ' ', Escape(Utf8ToCp866(T.Text)));
end;

var
  Src: string;
  Mode: string;
begin
  if (ParamCount < 1) or (ParamCount > 2) then
  begin
    WriteLn('usage: tp7lex [--dump|--check] FILE.PAS');
    Halt(1);
  end;
  Mode := '--check';
  if ParamCount = 2 then
    Mode := ParamStr(1);
  try
    Src := ReadSource(ParamStr(ParamCount));
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'error: ', E.Message);
      Halt(1);
    end;
  end;
  if Mode = '--dump' then
    Dump(Src, Lex(Src))
  else if Mode = '--check' then
    Check(Src, Lex(Src))
  else
  begin
    WriteLn(StdErr, 'error: unknown option ', Mode);
    Halt(1);
  end;
end.
