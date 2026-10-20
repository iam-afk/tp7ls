unit tp7lex;

{$mode objfpc}{$H+}

interface

type
  TTokenKind = (tkWS, tkNL, tkComment, tkDirective, tkCtrlZ, tkIdent, tkKW, tkInt, tkHex, tkReal, tkString,
    tkCharCode, tkSym, tkAsmLabel, tkError, tkEOF);

  TToken = record
    Kind: TTokenKind;
    Text: string;
    Pos: SizeInt;
    Line: Integer;
    Col: SizeInt;
  end;

  TTokens = array of TToken;

const
  TokenKindNames: array[TTokenKind] of string = ('WS', 'NL', 'COMMENT', 'DIRECTIVE', 'CTRLZ', 'IDENT', 'KW', 'INT',
    'HEX', 'REAL', 'STRING', 'CHARCODE', 'SYM', 'ASMLABEL', 'ERROR', 'EOF');
  Trivia = [tkWS, tkNL, tkComment, tkDirective, tkCtrlZ];

function IsReserved(const Name: string): Boolean;
function Lex(const Src: string): TTokens;
function Significant(const Tokens: TTokens): TTokens;
function JoinText(const Tokens: TTokens): string;
function RoundtripOk(const Src: string): Boolean;

implementation

uses
  SysUtils, StrUtils;

const
  Reserved: array[0..48] of string = (
    'and', 'array', 'asm', 'begin', 'case', 'const', 'constructor', 'destructor', 'div', 'do', 'downto', 'else',
    'end', 'file', 'for', 'function', 'goto', 'if', 'implementation', 'in', 'inherited', 'inline', 'interface',
    'label', 'mod', 'nil', 'not', 'object', 'of', 'or', 'packed', 'procedure', 'program', 'record', 'repeat', 'set',
    'shl', 'shr', 'string', 'then', 'to', 'type', 'unit', 'until', 'uses', 'var', 'while', 'with', 'xor');

  Blanks = [' ', #9, #11, #12];
  Digits = ['0'..'9'];
  HexDigits = ['0'..'9', 'A'..'F', 'a'..'f'];
  IdentStart = ['A'..'Z', 'a'..'z', '_'];
  IdentChars = IdentStart + Digits;
  CtrlZTail = [#26, #13, #10, ' ', #9];

function IsReserved(const Name: string): Boolean;
var
  Lo, Hi, Mid, Cmp: Integer;
  Key: string;
begin
  Key := LowerCase(Name);
  Lo := Low(Reserved);
  Hi := High(Reserved);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    Cmp := CompareStr(Reserved[Mid], Key);
    if Cmp = 0 then
      Exit(True);
    if Cmp < 0 then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
  Result := False;
end;

function Lex(const Src: string): TTokens;
var
  N, I, LineStart, Count: SizeInt;
  Line: Integer;

  function IsAt(K: SizeInt; const Chars: TSysCharSet): Boolean;
  begin
    Result := (K <= N) and (Src[K] in Chars);
  end;

  function Skip(K: SizeInt; const Chars: TSysCharSet): SizeInt;
  begin
    while IsAt(K, Chars) do
      Inc(K);
    Result := K;
  end;

  procedure Add(Kind: TTokenKind; Stop: SizeInt);
  begin
    if Count = Length(Result) then
      SetLength(Result, 2 * Count + 64);
    Result[Count].Kind := Kind;
    Result[Count].Text := Copy(Src, I, Stop - I);
    Result[Count].Pos := I;
    Result[Count].Line := Line;
    Result[Count].Col := I - LineStart + 1;
    Inc(Count);
    I := Stop;
  end;

  procedure AddMultiline(Kind: TTokenKind; Stop: SizeInt; LoneCR: Boolean);
  var
    First, K: SizeInt;
  begin
    First := I;
    Add(Kind, Stop);
    for K := First to Stop - 1 do
      if (Src[K] = #10) or (LoneCR and (Src[K] = #13) and not ((K + 1 < Stop) and (Src[K + 1] = #10))) then
      begin
        Inc(Line);
        LineStart := K + 1;
      end;
  end;

  procedure AddNewline;
  begin
    if (Src[I] = #13) and IsAt(I + 1, [#10]) then
      Add(tkNL, I + 2)
    else
      Add(tkNL, I + 1);
    Inc(Line);
    LineStart := I;
  end;

  procedure AddComment(const Close: string; OpenLen: SizeInt);
  var
    E: SizeInt;
  begin
    E := PosEx(Close, Src, I + OpenLen);
    if E = 0 then
      AddMultiline(tkError, N + 1, True)
    else if IsAt(I + OpenLen, ['$']) then
      AddMultiline(tkDirective, E + Length(Close), True)
    else
      AddMultiline(tkComment, E + Length(Close), True);
  end;

  procedure AddString;
  var
    J, LastPair: SizeInt;
  begin
    J := I + 1;
    LastPair := 0;
    while (J <= N) and not (Src[J] in [#13, #10]) do
    begin
      if Src[J] <> '''' then
        Inc(J)
      else if IsAt(J + 1, ['''']) then
      begin
        LastPair := J;
        Inc(J, 2);
      end
      else
      begin
        Add(tkString, J + 1);
        Exit;
      end;
    end;
    if LastPair > 0 then
      Add(tkString, LastPair + 1)
    else
    begin
      J := I;
      while (J <= N) and not (Src[J] in [#13, #10]) do
        Inc(J);
      Add(tkError, J);
    end;
  end;

  function SkipExponent(J: SizeInt): SizeInt;
  var
    K: SizeInt;
  begin
    Result := J;
    if not IsAt(J, ['e', 'E']) then
      Exit;
    K := J + 1;
    if IsAt(K, ['+', '-']) then
      Inc(K);
    if IsAt(K, Digits) then
      Result := Skip(K, Digits);
  end;

  procedure AddNumber;
  var
    J, K: SizeInt;
  begin
    J := Skip(I, Digits);
    if IsAt(J, ['.']) and IsAt(J + 1, Digits) then
      Add(tkReal, SkipExponent(Skip(J + 1, Digits)))
    else
    begin
      K := SkipExponent(J);
      if K > J then
        Add(tkReal, K)
      else
        Add(tkInt, J);
    end;
  end;

  procedure AddCharCode;
  begin
    if IsAt(I + 1, ['$']) and IsAt(I + 2, HexDigits) then
      Add(tkCharCode, Skip(I + 2, HexDigits))
    else if IsAt(I + 1, Digits) then
      Add(tkCharCode, Skip(I + 1, Digits))
    else
      Add(tkError, I + 1);
  end;

  procedure AddIdent;
  var
    J: SizeInt;
  begin
    J := Skip(I, IdentChars);
    if IsReserved(Copy(Src, I, J - I)) then
      Add(tkKW, J)
    else
      Add(tkIdent, J);
  end;

  procedure AddSym(const Pairs: string);
  begin
    if (I < N) and (System.Pos(Src[I + 1], Pairs) > 0) then
      Add(tkSym, I + 2)
    else
      Add(tkSym, I + 1);
  end;

  procedure AddCtrlZ;
  begin
    if Skip(I + 1, CtrlZTail) > N then
      AddMultiline(tkCtrlZ, N + 1, False)
    else
      Add(tkError, I + 1);
  end;

  procedure AddOther;
  var
    J: SizeInt;
  begin
    J := I + 1;
    if Ord(Src[I]) >= $80 then
      while (J <= N) and (Ord(Src[J]) and $C0 = $80) do
        Inc(J);
    Add(tkError, J);
  end;

begin
  Result := nil;
  N := Length(Src);
  I := 1;
  Line := 1;
  LineStart := 1;
  Count := 0;
  while I <= N do
    case Src[I] of
      ' ', #9, #11, #12:
        Add(tkWS, Skip(I, Blanks));
      #13, #10:
        AddNewline;
      '{':
        AddComment('}', 1);
      '(':
        if IsAt(I + 1, ['*']) then
          AddComment('*)', 2)
        else
          AddSym('.');
      '''':
        AddString;
      '#':
        AddCharCode;
      '0'..'9':
        AddNumber;
      '$':
        if IsAt(I + 1, HexDigits) then
          Add(tkHex, Skip(I + 1, HexDigits))
        else
          Add(tkError, I + 1);
      '@':
        if IsAt(I + 1, ['@']) and IsAt(I + 2, IdentChars) then
          Add(tkAsmLabel, Skip(I + 2, IdentChars))
        else
          Add(tkSym, I + 1);
      'A'..'Z', 'a'..'z', '_':
        AddIdent;
      ':', '>':
        AddSym('=');
      '<':
        AddSym('=>');
      '.':
        AddSym('.)');
      '+', '-', '*', '/', '=', '[', ']', ',', ')', ';', '^':
        Add(tkSym, I + 1);
      #26:
        AddCtrlZ;
    else
      AddOther;
    end;
  Add(tkEOF, I);
  SetLength(Result, Count);
end;

function Significant(const Tokens: TTokens): TTokens;
var
  T: TToken;
  Count: SizeInt;
begin
  Result := nil;
  SetLength(Result, Length(Tokens));
  Count := 0;
  for T in Tokens do
    if not (T.Kind in Trivia + [tkEOF]) then
    begin
      Result[Count] := T;
      Inc(Count);
    end;
  SetLength(Result, Count);
end;

function JoinText(const Tokens: TTokens): string;
var
  T: TToken;
  Len: SizeInt;
begin
  Len := 0;
  for T in Tokens do
    Inc(Len, Length(T.Text));
  Result := '';
  SetLength(Result, Len);
  Len := 0;
  for T in Tokens do
    if T.Text <> '' then
    begin
      Move(T.Text[1], Result[Len + 1], Length(T.Text));
      Inc(Len, Length(T.Text));
    end;
end;

function RoundtripOk(const Src: string): Boolean;
begin
  Result := JoinText(Lex(Src)) = Src;
end;

end.
