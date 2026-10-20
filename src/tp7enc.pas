unit tp7enc;

{$mode objfpc}{$H+}

interface

function Cp866ToUtf8(const S: RawByteString): string;
function Utf8ToCp866(const S: string): RawByteString;
function ReadFileBytes(const Path: string): RawByteString;
function ReadSource(const Path: string): string;
function Utf8Length(const S: string; First, Last: SizeInt): SizeInt;

implementation

uses
  Classes, SysUtils;

const
  Cp866High: array[$80..$FF] of Word = (
    $0410, $0411, $0412, $0413, $0414, $0415, $0416, $0417,
    $0418, $0419, $041A, $041B, $041C, $041D, $041E, $041F,
    $0420, $0421, $0422, $0423, $0424, $0425, $0426, $0427,
    $0428, $0429, $042A, $042B, $042C, $042D, $042E, $042F,
    $0430, $0431, $0432, $0433, $0434, $0435, $0436, $0437,
    $0438, $0439, $043A, $043B, $043C, $043D, $043E, $043F,
    $2591, $2592, $2593, $2502, $2524, $2561, $2562, $2556,
    $2555, $2563, $2551, $2557, $255D, $255C, $255B, $2510,
    $2514, $2534, $252C, $251C, $2500, $253C, $255E, $255F,
    $255A, $2554, $2569, $2566, $2560, $2550, $256C, $2567,
    $2568, $2564, $2565, $2559, $2558, $2552, $2553, $256B,
    $256A, $2518, $250C, $2588, $2584, $258C, $2590, $2580,
    $0440, $0441, $0442, $0443, $0444, $0445, $0446, $0447,
    $0448, $0449, $044A, $044B, $044C, $044D, $044E, $044F,
    $0401, $0451, $0404, $0454, $0407, $0457, $040E, $045E,
    $00B0, $2219, $00B7, $221A, $2116, $00A4, $25A0, $00A0);

function Cp866ToUtf8(const S: RawByteString): string;
var
  I, N: SizeInt;
  C: Word;
begin
  SetLength(Result, Length(S) * 3);
  N := 0;
  for I := 1 to Length(S) do
  begin
    if Ord(S[I]) < $80 then
    begin
      Inc(N);
      Result[N] := S[I];
      Continue;
    end;
    C := Cp866High[Ord(S[I])];
    if C < $800 then
    begin
      Result[N + 1] := Chr($C0 or (C shr 6));
      Result[N + 2] := Chr($80 or (C and $3F));
      Inc(N, 2);
    end
    else
    begin
      Result[N + 1] := Chr($E0 or (C shr 12));
      Result[N + 2] := Chr($80 or ((C shr 6) and $3F));
      Result[N + 3] := Chr($80 or (C and $3F));
      Inc(N, 3);
    end;
  end;
  SetLength(Result, N);
end;

function Cp866Byte(CodePoint: LongWord): Char;
var
  B: Integer;
begin
  for B := Low(Cp866High) to High(Cp866High) do
    if Cp866High[B] = CodePoint then
      Exit(Chr(B));
  Result := '?';
end;

function Utf8ToCp866(const S: string): RawByteString;
var
  I, N, Len, K: SizeInt;
  B: Byte;
  C: LongWord;
begin
  SetLength(Result, Length(S));
  N := 0;
  I := 1;
  while I <= Length(S) do
  begin
    B := Ord(S[I]);
    if B < $80 then
    begin
      Len := 1;
      C := B;
    end
    else if B and $E0 = $C0 then
    begin
      Len := 2;
      C := B and $1F;
    end
    else if B and $F0 = $E0 then
    begin
      Len := 3;
      C := B and $0F;
    end
    else if B and $F8 = $F0 then
    begin
      Len := 4;
      C := B and $07;
    end
    else
    begin
      Len := 1;
      C := $FFFD;
    end;
    for K := 1 to Len - 1 do
      if (I + K <= Length(S)) and (Ord(S[I + K]) and $C0 = $80) then
        C := (C shl 6) or (Ord(S[I + K]) and $3F)
      else
      begin
        Len := K;
        C := $FFFD;
        Break;
      end;
    Inc(N);
    if C < $80 then
      Result[N] := Chr(C)
    else
      Result[N] := Cp866Byte(C);
    Inc(I, Len);
  end;
  SetLength(Result, N);
end;

function ReadFileBytes(const Path: string): RawByteString;
var
  F: TFileStream;
begin
  Result := '';
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if Length(Result) > 0 then
      F.ReadBuffer(Result[1], Length(Result));
  finally
    F.Free;
  end;
end;

function ReadSource(const Path: string): string;
begin
  Result := Cp866ToUtf8(ReadFileBytes(Path));
end;

function Utf8Length(const S: string; First, Last: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  Result := 0;
  for I := First to Last do
    if Ord(S[I]) and $C0 <> $80 then
      Inc(Result);
end;

end.
