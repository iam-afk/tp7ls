program tp7parsecli;

{$mode objfpc}{$H+}

uses
  SysUtils, tp7enc, tp7lex, tp7parse;

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

function Position(const Src: string; T: TToken): string;
begin
  Result := IntToStr(T.Line) + ':' + IntToStr(Utf8Length(Src, T.Pos - T.Col + 1, T.Pos - 1) + 1);
end;

procedure DumpNode(const Src: string; N: TNode; Depth: Integer);
var
  K: TObject;
  T: TToken;
begin
  WriteLn(StringOfChar(' ', 2 * Depth), NodeKindNames[N.Kind]);
  for K in N.Kids do
    if K is TNode then
      DumpNode(Src, TNode(K), Depth + 1)
    else
    begin
      T := TToken(K);
      WriteLn(StringOfChar(' ', 2 * Depth + 2), TokenKindNames[T.Kind], ' ', Position(Src, T), ' ',
        Escape(Utf8ToCp866(T.Text)));
    end;
end;

procedure Dump(R: TParseResult);
var
  D: TDiag;
  T: TToken;
  Incl: TInclude;
begin
  DumpNode(R.Source, R.Tree, 0);
  for D in R.Diags do
    WriteLn('DIAG ', Position(R.Source, D.Token), ' ', Escape(Utf8ToCp866(D.Message)));
  for T in R.Tokens do
    if not T.Active then
      WriteLn('INACTIVE ', Position(R.Source, T));
  for Incl in R.Includes do
    WriteLn('INCLUDE ', Position(R.Source, Incl.Token), ' ', Escape(Utf8ToCp866(Incl.Name)));
  if Reconstruct(R) = R.Source then
    WriteLn('ROUNDTRIP OK')
  else
    WriteLn('ROUNDTRIP BROKEN');
end;

procedure Check(R: TParseResult);
var
  D: TDiag;
  N: Integer;
begin
  Write(Length(R.Sig) - 1, ' significant tokens, ', Length(R.Diags), ' diagnostics, roundtrip ');
  if Reconstruct(R) = R.Source then
    WriteLn('OK')
  else
    WriteLn('BROKEN');
  N := 0;
  for D in R.Diags do
  begin
    Inc(N);
    if N > 30 then
      Break;
    WriteLn('  ', Position(R.Source, D.Token), ' ', D.Message);
  end;
end;

var
  Defines: array of string;
  Mode, Path: string;
  I: Integer;
  R: TParseResult;
begin
  Defines := nil;
  for Path in DefaultDefines do
    Defines := Concat(Defines, [Path]);
  Mode := '--check';
  Path := '';
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '--dump') or (ParamStr(I) = '--check') then
      Mode := ParamStr(I)
    else if (ParamStr(I) = '-D') and (I < ParamCount) then
    begin
      Inc(I);
      Defines := Concat(Defines, [ParamStr(I)]);
    end
    else
      Path := ParamStr(I);
    Inc(I);
  end;
  if Path = '' then
  begin
    WriteLn('usage: tp7parse [--dump|--check] [-D SYMBOL ...] FILE.PAS');
    Halt(1);
  end;
  try
    R := Parse(ReadSource(Path), Defines);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'error: ', E.Message);
      Halt(1);
    end;
  end;
  if Mode = '--dump' then
    Dump(R)
  else
    Check(R);
  R.Free;
end.
