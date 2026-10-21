unit tp7stub;

{$mode objfpc}{$H+}

interface

uses
  Classes, Contnrs, SysUtils, tp7maps, tp7sema, tpudump;

const
  StubVersion = 2;
  StubWidth = 100;
  StubEol = #13#10;

type
  TStubEntry = class
  public
    Kind, Owner, Name: string;
    Line, Col, Len: Integer;
  end;

  TStub = class
  private
    FEntries: TObjectList;
    FMap: TStrMap;
  public
    UnitName_: string;
    Lines: TStringArray;
    Text: string;
    constructor Create;
    destructor Destroy; override;
    procedure Mark(const AKind, AOwner, AName: string; ALine, ACol, ALen: Integer);
    function Count: Integer;
    function Entry(I: Integer): TStubEntry;
    function Lookup(const AKind, AOwner, AName: string): TStubEntry;
    function Find(const Kind, Name: string; const Owner: string = ''): TStubEntry;
    function Block(const Kind, Name: string; const Owner: string = ''): TStringArray;
    function Declaration(const Kind, Name: string; const Owner: string = ''): string;
  end;

  TStubStore = class
  private
    FArena: TObjectList;
    FKeys: TStringList;
    FPaths: TStringArray;
    FStubs: array of TStub;
  public
    Root: string;
    constructor Create(const ARoot: string);
    destructor Destroy; override;
    function IsStub(const Path: string): Boolean;
    function Get(Info: TUnitInfo; out Path: string; out Stub: TStub): Boolean;
  end;

function BuiltinSig(const Name: string; out Sig: string): Boolean;
function Render(U: TUnit; const Origin: string = ''): TStub;
function DefaultStubDir: string;

implementation

uses
{$IFDEF UNIX}
  BaseUnix,
{$ENDIF}
  sha1, tp7enc, tp7os;

type
  TSigPair = record
    Name, Sig: string;
  end;

const
  BuiltinSigs: array[0..99] of TSigPair = (
    (Name: 'Abs'; Sig: 'function Abs(X: integer or real type): same type'),
    (Name: 'Addr'; Sig: 'function Addr(var X): Pointer'),
    (Name: 'Append'; Sig: 'procedure Append(var F: Text)'),
    (Name: 'ArcTan'; Sig: 'function ArcTan(X: Real): Real'),
    (Name: 'Assign'; Sig: 'procedure Assign(var F; Name: string)'),
    (Name: 'Assigned'; Sig: 'function Assigned(P: Pointer): Boolean'),
    (Name: 'BlockRead'; Sig: 'procedure BlockRead(var F: file; var Buf; Count: Word [; var Result: Word])'),
    (Name: 'BlockWrite'; Sig: 'procedure BlockWrite(var F: file; var Buf; Count: Word [; var Result: Word])'),
    (Name: 'Break'; Sig: 'procedure Break'),
    (Name: 'ChDir'; Sig: 'procedure ChDir(S: string)'),
    (Name: 'Chr'; Sig: 'function Chr(X: Byte): Char'),
    (Name: 'Close'; Sig: 'procedure Close(var F)'),
    (Name: 'Concat'; Sig: 'function Concat(S1, S2 [, ..., Sn]: string): string'),
    (Name: 'Continue'; Sig: 'procedure Continue'),
    (Name: 'Copy'; Sig: 'function Copy(S: string; Index, Count: Integer): string'),
    (Name: 'Cos'; Sig: 'function Cos(X: Real): Real'),
    (Name: 'CSeg'; Sig: 'function CSeg: Word'),
    (Name: 'Dec'; Sig: 'procedure Dec(var X: ordinal type [; N: Longint])'),
    (Name: 'Delete'; Sig: 'procedure Delete(var S: string; Index, Count: Integer)'),
    (Name: 'Dispose'; Sig: 'procedure Dispose(var P: pointer [, Destructor(...)])'),
    (Name: 'DSeg'; Sig: 'function DSeg: Word'),
    (Name: 'Eof'; Sig: 'function Eof([var F]): Boolean'),
    (Name: 'Eoln'; Sig: 'function Eoln([var F: Text]): Boolean'),
    (Name: 'Erase'; Sig: 'procedure Erase(var F)'),
    (Name: 'Exclude'; Sig: 'procedure Exclude(var S: set; E: element)'),
    (Name: 'Exit'; Sig: 'procedure Exit'),
    (Name: 'Exp'; Sig: 'function Exp(X: Real): Real'),
    (Name: 'Fail'; Sig: 'procedure Fail'),
    (Name: 'FilePos'; Sig: 'function FilePos(var F): Longint'),
    (Name: 'FileSize'; Sig: 'function FileSize(var F): Longint'),
    (Name: 'FillChar'; Sig: 'procedure FillChar(var X; Count: Word; Value: Byte or Char)'),
    (Name: 'Flush'; Sig: 'procedure Flush(var F: Text)'),
    (Name: 'Frac'; Sig: 'function Frac(X: Real): Real'),
    (Name: 'FreeMem'; Sig: 'procedure FreeMem(var P: Pointer; Size: Word)'),
    (Name: 'GetDir'; Sig: 'procedure GetDir(D: Byte; var S: string)'),
    (Name: 'GetMem'; Sig: 'procedure GetMem(var P: Pointer; Size: Word)'),
    (Name: 'Halt'; Sig: 'procedure Halt([Code: Word])'),
    (Name: 'Hi'; Sig: 'function Hi(X: Integer or Word): Byte'),
    (Name: 'High'; Sig: 'function High(X: ordinal type or array): ordinal value'),
    (Name: 'Inc'; Sig: 'procedure Inc(var X: ordinal type [; N: Longint])'),
    (Name: 'Include'; Sig: 'procedure Include(var S: set; E: element)'),
    (Name: 'Insert'; Sig: 'procedure Insert(Source: string; var S: string; Index: Integer)'),
    (Name: 'Int'; Sig: 'function Int(X: Real): Real'),
    (Name: 'IOResult'; Sig: 'function IOResult: Word'),
    (Name: 'Length'; Sig: 'function Length(S: string): Integer'),
    (Name: 'Ln'; Sig: 'function Ln(X: Real): Real'),
    (Name: 'Lo'; Sig: 'function Lo(X: Integer or Word): Byte'),
    (Name: 'Low'; Sig: 'function Low(X: ordinal type or array): ordinal value'),
    (Name: 'Mark'; Sig: 'procedure Mark(var P: Pointer)'),
    (Name: 'MaxAvail'; Sig: 'function MaxAvail: Longint'),
    (Name: 'Mem'; Sig: 'Mem: array of Byte           { Mem[Segment:Offset] }'),
    (Name: 'MemAvail'; Sig: 'function MemAvail: Longint'),
    (Name: 'MemL'; Sig: 'MemL: array of Longint        { MemL[Segment:Offset] }'),
    (Name: 'MemW'; Sig: 'MemW: array of Word           { MemW[Segment:Offset] }'),
    (Name: 'MkDir'; Sig: 'procedure MkDir(S: string)'),
    (Name: 'Move'; Sig: 'procedure Move(var Source, Dest; Count: Word)'),
    (Name: 'New'; Sig: 'procedure New(var P: pointer [, Constructor(...)])'),
    (Name: 'Odd'; Sig: 'function Odd(X: Longint): Boolean'),
    (Name: 'Ofs'; Sig: 'function Ofs(var X): Word'),
    (Name: 'Ord'; Sig: 'function Ord(X: ordinal type): Longint'),
    (Name: 'ParamCount'; Sig: 'function ParamCount: Word'),
    (Name: 'ParamStr'; Sig: 'function ParamStr(Index: Word): string'),
    (Name: 'Pi'; Sig: 'function Pi: Real'),
    (Name: 'Port'; Sig: 'Port: array of Byte           { Port[Number] }'),
    (Name: 'PortW'; Sig: 'PortW: array of Word          { PortW[Number] }'),
    (Name: 'Pos'; Sig: 'function Pos(Substr, S: string): Byte'),
    (Name: 'Pred'; Sig: 'function Pred(X: ordinal type): same type'),
    (Name: 'Ptr'; Sig: 'function Ptr(Seg, Ofs: Word): Pointer'),
    (Name: 'Random'; Sig: 'function Random[(Range: Word)]: Word or Real'),
    (Name: 'Randomize'; Sig: 'procedure Randomize'),
    (Name: 'Read'; Sig: 'procedure Read([var F: Text;] V1 [, V2, ..., Vn])'),
    (Name: 'ReadLn'; Sig: 'procedure ReadLn([var F: Text;] [V1 [, V2, ..., Vn]])'),
    (Name: 'Release'; Sig: 'procedure Release(var P: Pointer)'),
    (Name: 'Rename'; Sig: 'procedure Rename(var F; NewName: string)'),
    (Name: 'Reset'; Sig: 'procedure Reset(var F [; RecSize: Word])'),
    (Name: 'Rewrite'; Sig: 'procedure Rewrite(var F [; RecSize: Word])'),
    (Name: 'RmDir'; Sig: 'procedure RmDir(S: string)'),
    (Name: 'Round'; Sig: 'function Round(X: Real): Longint'),
    (Name: 'RunError'; Sig: 'procedure RunError([Code: Word])'),
    (Name: 'Seek'; Sig: 'procedure Seek(var F; N: Longint)'),
    (Name: 'SeekEof'; Sig: 'function SeekEof([var F: Text]): Boolean'),
    (Name: 'SeekEoln'; Sig: 'function SeekEoln([var F: Text]): Boolean'),
    (Name: 'Seg'; Sig: 'function Seg(var X): Word'),
    (Name: 'SetTextBuf'; Sig: 'procedure SetTextBuf(var F: Text; var Buf [; Size: Word])'),
    (Name: 'Sin'; Sig: 'function Sin(X: Real): Real'),
    (Name: 'SizeOf'; Sig: 'function SizeOf(X): Word'),
    (Name: 'SPtr'; Sig: 'function SPtr: Word'),
    (Name: 'Sqr'; Sig: 'function Sqr(X: integer or real type): same type'),
    (Name: 'Sqrt'; Sig: 'function Sqrt(X: Real): Real'),
    (Name: 'SSeg'; Sig: 'function SSeg: Word'),
    (Name: 'Str'; Sig: 'procedure Str(X [: Width [: Decimals]]; var S: string)'),
    (Name: 'Succ'; Sig: 'function Succ(X: ordinal type): same type'),
    (Name: 'Swap'; Sig: 'function Swap(X: Integer or Word): same type'),
    (Name: 'Trunc'; Sig: 'function Trunc(X: Real): Longint'),
    (Name: 'Truncate'; Sig: 'procedure Truncate(var F)'),
    (Name: 'TypeOf'; Sig: 'function TypeOf(X: object type): Pointer'),
    (Name: 'UpCase'; Sig: 'function UpCase(Ch: Char): Char'),
    (Name: 'Val'; Sig: 'procedure Val(S: string; var V; var Code: Integer)'),
    (Name: 'Write'; Sig: 'procedure Write([var F: Text;] P1 [, P2, ..., Pn])'),
    (Name: 'WriteLn'; Sig: 'procedure WriteLn([var F: Text;] [P1 [, P2, ..., Pn]])'));

function BuiltinSig(const Name: string; out Sig: string): Boolean;
var
  P: TSigPair;
  Key: string;
begin
  Key := LowerText(Name);
  for P in BuiltinSigs do
    if LowerText(P.Name) = Key then
    begin
      Sig := P.Sig;
      Exit(True);
    end;
  Sig := '';
  Result := False;
end;

function IsWordChar(C: Char): Boolean;
begin
  Result := C in ['0'..'9', 'A'..'Z', 'a'..'z', '_'];
end;

function IsSpaceChar(C: Char): Boolean;
begin
  Result := C in [#9..#13, #28..#32];
end;

function DecodeAt(const S: string; I: Integer; out Len: Integer): LongWord;
var
  B: Byte;
  K: Integer;
begin
  B := Ord(S[I]);
  if B < $80 then
  begin
    Len := 1;
    Exit(B);
  end;
  if B and $E0 = $C0 then
  begin
    Len := 2;
    Result := B and $1F;
  end
  else if B and $F0 = $E0 then
  begin
    Len := 3;
    Result := B and $0F;
  end
  else
  begin
    Len := 4;
    Result := B and $07;
  end;
  for K := 1 to Len - 1 do
    if (I + K <= Length(S)) and (Ord(S[I + K]) and $C0 = $80) then
      Result := (Result shl 6) or (Ord(S[I + K]) and $3F)
    else
    begin
      Len := K;
      Exit($FFFD);
    end;
end;

function IsWordCP(C: LongWord): Boolean;
begin
  if C < $80 then
    Result := IsWordChar(Chr(C))
  else
    Result := (C >= $0400) and (C <= $04FF);
end;

function WordStartsAt(const S: string; I: Integer): Integer;
var
  Len: Integer;
begin
  if (I <= Length(S)) and IsWordCP(DecodeAt(S, I, Len)) then
    Result := Len
  else
    Result := 0;
end;

function StartBefore(const S: string; I: Integer): Integer;
begin
  Result := I - 1;
  while (Result > 1) and (Ord(S[Result]) and $C0 = $80) do
    Dec(Result);
end;

function WordEndsBefore(const S: string; I: Integer): Integer;
var
  J, Len: Integer;
begin
  if I <= 1 then
    Exit(0);
  J := StartBefore(S, I);
  if IsWordCP(DecodeAt(S, J, Len)) then
    Result := J
  else
    Result := 0;
end;

function CharLen(const S: string): Integer;
begin
  Result := Utf8Length(S, 1, Length(S));
end;

procedure Push(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function Join(const A: TStringArray; const Sep: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then
      Result := Result + Sep;
    Result := Result + A[I];
  end;
end;

function RStrip(const S: string): string;
var
  N: Integer;
begin
  N := Length(S);
  while (N > 0) and IsSpaceChar(S[N]) do
    Dec(N);
  Result := Copy(S, 1, N);
end;

function SizeText(Size: Integer): string;
begin
  if Size < 0 then
    Result := 'None'
  else
    Result := IntToStr(Size);
end;

function EntryKey(const Kind, Owner, Name: string): string;
begin
  Result := Kind + #0 + Owner + #0 + Name;
end;

{ TStub }

constructor TStub.Create;
begin
  FEntries := TObjectList.Create(True);
  FMap := TStrMap.Create;
end;

destructor TStub.Destroy;
begin
  FMap.Free;
  FEntries.Free;
  inherited;
end;

procedure TStub.Mark(const AKind, AOwner, AName: string; ALine, ACol, ALen: Integer);
var
  E: TStubEntry;
  Key: string;
begin
  Key := EntryKey(AKind, AOwner, AName);
  if FMap.Has(Key) then
    Exit;
  E := TStubEntry.Create;
  E.Kind := AKind;
  E.Owner := AOwner;
  E.Name := AName;
  E.Line := ALine;
  E.Col := ACol;
  E.Len := ALen;
  FEntries.Add(E);
  FMap.Put(Key, E);
end;

function TStub.Count: Integer;
begin
  Result := FEntries.Count;
end;

function TStub.Entry(I: Integer): TStubEntry;
begin
  Result := TStubEntry(FEntries[I]);
end;

function TStub.Lookup(const AKind, AOwner, AName: string): TStubEntry;
begin
  Result := TStubEntry(FMap.Get(EntryKey(AKind, AOwner, AName)));
end;

function TStub.Find(const Kind, Name: string; const Owner: string): TStubEntry;
begin
  if Kind = 'unit' then
    Result := Lookup('unit', '', '')
  else if Kind = 'field' then
    Result := Lookup('field', LowerText(Owner), LowerText(Name))
  else if (Kind = 'routine') and (Owner <> '') then
    Result := Lookup('method', LowerText(Owner), LowerText(Name))
  else
    Result := Lookup(Kind, '', LowerText(Name));
end;

function EndsWith(const S, Tail: string): Boolean;
begin
  Result := (Length(S) >= Length(Tail)) and (Copy(S, Length(S) - Length(Tail) + 1, Length(Tail)) = Tail);
end;

function OpensRecord(const Line: string): Boolean;
var
  S: string;
  I, J: Integer;
begin
  S := RStrip(Line);
  if EndsWith(S, '= record') or EndsWith(S, '= object') then
    Exit(True);
  if not EndsWith(S, ')') then
    Exit(False);
  I := Length(S);
  J := WordEndsBefore(S, I);
  while J > 0 do
  begin
    I := J;
    J := WordEndsBefore(S, I);
  end;
  Result := (I < Length(S)) and (I > 1) and (S[I - 1] = '(') and EndsWith(Copy(S, 1, I - 2), '= object');
end;

function TStub.Block(const Kind, Name: string; const Owner: string): TStringArray;
var
  E: TStubEntry;
  I: Integer;
begin
  Result := nil;
  E := Find(Kind, Name, Owner);
  if E = nil then
    Exit;
  Push(Result, Lines[E.Line]);
  if (Kind = 'type') and OpensRecord(Result[0]) then
    for I := E.Line + 1 to High(Lines) do
    begin
      Push(Result, Lines[I]);
      if StripSpace(Lines[I]) = 'end;' then
        Break;
    end;
end;

function TStub.Declaration(const Kind, Name: string; const Owner: string): string;
var
  E: TStubEntry;
  J, K: Integer;
begin
  E := Find(Kind, Name, Owner);
  if E = nil then
    Exit('');
  Result := StripSpace(Lines[E.Line]);
  K := Length(Result);
  while (K > 0) and IsSpaceChar(Result[K]) do
    Dec(K);
  if (K = 0) or (Result[K] <> '}') then
    Exit;
  J := K - 1;
  while (J > 0) and not (Result[J] in ['{', '}']) do
    Dec(J);
  if (J = 0) or (Result[J] <> '{') then
    Exit;
  while (J > 1) and IsSpaceChar(Result[J - 1]) do
    Dec(J);
  Result := Copy(Result, 1, J - 1);
end;

type
  TMarkRec = record
    Kind, Owner, Name: string;
    Col, Len: Integer;
  end;

  TMarks = array of TMarkRec;

  TWriter = class
  public
    Stub: TStub;
    procedure Line(const Text: string = '');
    procedure LineM(const Text: string; const Marks: TMarks);
    procedure Line1(const Text, Kind, Owner, Name: string; Col, Len: Integer);
    procedure Wrapped(const Head: string; const Texts, Names: TStringArray; const Tail: string;
      const Indent: string = '    ');
  end;

function MarkOf(const Kind, Owner, Name: string; Col, Len: Integer): TMarkRec;
begin
  Result.Kind := Kind;
  Result.Owner := Owner;
  Result.Name := Name;
  Result.Col := Col;
  Result.Len := Len;
end;

procedure TWriter.LineM(const Text: string; const Marks: TMarks);
var
  N: Integer;
  M: TMarkRec;
begin
  N := Length(Stub.Lines);
  Push(Stub.Lines, Text);
  for M in Marks do
    Stub.Mark(M.Kind, M.Owner, M.Name, N, M.Col, M.Len);
end;

procedure TWriter.Line(const Text: string);
begin
  LineM(Text, nil);
end;

procedure TWriter.Line1(const Text, Kind, Owner, Name: string; Col, Len: Integer);
var
  Marks: TMarks;
begin
  SetLength(Marks, 1);
  Marks[0] := MarkOf(Kind, Owner, Name, Col, Len);
  LineM(Text, Marks);
end;

procedure TWriter.Wrapped(const Head: string; const Texts, Names: TStringArray; const Tail: string;
  const Indent: string);
var
  Cur, Piece: string;
  Marks: TMarks;
  I: Integer;
begin
  Cur := Head;
  Marks := nil;
  for I := 0 to High(Texts) do
  begin
    Piece := Texts[I];
    if I < High(Texts) then
      Piece := Piece + ', ';
    if (CharLen(Cur) + CharLen(RStrip(Piece)) > StubWidth) and (StripSpace(Cur) <> '') and (Cur <> Head) then
    begin
      LineM(RStrip(Cur), Marks);
      Cur := Indent;
      Marks := nil;
    end;
    if Names[I] <> '' then
    begin
      SetLength(Marks, Length(Marks) + 1);
      Marks[High(Marks)] := MarkOf('const', '', Names[I], Length(Cur), Length(Texts[I]));
    end;
    Cur := Cur + Piece;
  end;
  LineM(Cur + Tail, Marks);
end;

function IsHexLower(C: Char): Boolean;
begin
  Result := C in ['0'..'9', 'a'..'f'];
end;

function TypeText(const T: string): string;
var
  S: string;
  I, J, K: Integer;
begin
  S := '';
  I := 1;
  while I <= Length(T) do
    if (Copy(T, I, 6) = 'array[') and (WordEndsBefore(T, I) = 0) then
    begin
      S := S + 'array [';
      Inc(I, 6);
    end
    else
    begin
      S := S + T[I];
      Inc(I);
    end;
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '?' then
    begin
      J := I + 1;
      while WordStartsAt(S, J) > 0 do
        Inc(J, WordStartsAt(S, J));
      K := J + 3;
      if (J > I + 1) and (Copy(S, J, 3) = '@0x') and (K <= Length(S)) and IsHexLower(S[K]) then
      begin
        while (K <= Length(S)) and IsHexLower(S[K]) do
          Inc(K);
        Result := Result + Copy(S, I + 1, J - I - 1) + '.?';
        I := K;
        Continue;
      end;
    end;
    Result := Result + S[I];
    Inc(I);
  end;
  Result := StringReplace(Result, '?other', 'procedure', [rfReplaceAll]);
end;

function ParamGroups(const Params: TParams): TStringArray;
type
  TRun = record
    Kind, Typ: string;
    Open, Untyped: Boolean;
    Names: TStringArray;
  end;
var
  Runs: array of TRun;
  P: TParam;
  I: Integer;
  Untyped: Boolean;
  Typ, Name, Text: string;
begin
  Runs := nil;
  for I := 0 to High(Params) do
  begin
    P := Params[I];
    Untyped := (P.Kind = 'var') and (P.TypeName = 'file') and not P.Open;
    if Untyped then
      Typ := ''
    else
      Typ := TypeText(P.TypeName);
    Name := P.Name;
    if Name = '' then
      Name := 'P' + IntToStr(I + 1);
    if (Runs <> nil) and (Runs[High(Runs)].Kind = P.Kind) and (Runs[High(Runs)].Open = P.Open) and
      (Runs[High(Runs)].Untyped = Untyped) and (Runs[High(Runs)].Typ = Typ) then
      Push(Runs[High(Runs)].Names, Name)
    else
    begin
      SetLength(Runs, Length(Runs) + 1);
      Runs[High(Runs)].Kind := P.Kind;
      Runs[High(Runs)].Typ := Typ;
      Runs[High(Runs)].Open := P.Open;
      Runs[High(Runs)].Untyped := Untyped;
      Runs[High(Runs)].Names := nil;
      Push(Runs[High(Runs)].Names, Name);
    end;
  end;
  Result := nil;
  for I := 0 to High(Runs) do
  begin
    Text := Join(Runs[I].Names, ', ');
    if not Runs[I].Untyped then
    begin
      Text := Text + ': ';
      if Runs[I].Open then
        Text := Text + 'array of ';
      Text := Text + Runs[I].Typ;
    end;
    if Runs[I].Kind = 'var' then
      Text := 'var ' + Text
    else if Runs[I].Kind = 'const' then
      Text := 'const ' + Text;
    Push(Result, Text);
  end;
end;

function GroupsText(const Groups: TStringArray): string;
begin
  if Groups = nil then
    Result := ''
  else
    Result := '(' + Join(Groups, '; ') + ')';
end;

procedure Partition(const S: string; out Before, After: string);
var
  I: Integer;
begin
  I := Pos('{', S);
  if I = 0 then
  begin
    Before := S;
    After := '';
  end
  else
  begin
    Before := Copy(S, 1, I - 1);
    After := Copy(S, I + 1, MaxInt);
  end;
end;

function NoteText(const Note: string): string;
begin
  if Note = '' then
    Result := ''
  else
    Result := '  {' + Note;
end;

function WordAt(const S, W: string): Integer;
var
  I, L: Integer;
  First, Last: Boolean;
begin
  if W = '' then
    Exit(0);
  First := WordStartsAt(W, 1) > 0;
  Last := WordEndsBefore(W, Length(W) + 1) > 0;
  L := Length(W);
  for I := 1 to Length(S) - L + 1 do
    if (Copy(S, I, L) = W) and ((WordEndsBefore(S, I) > 0) <> First) and ((WordStartsAt(S, I + L) > 0) <> Last) then
      Exit(I);
  Result := 0;
end;

function NamedOf(T: TTypeDesc; out Name: string): Boolean;
begin
  Result := (T <> nil) and (T.Kind = tdNamed);
  if Result then
    Name := T.Name
  else
    Name := '';
end;

function ValueOf(C: TSym): string;
begin
  case C.ValueKind of
    vkInt:
      Result := IntToStr(C.IntValue);
    vkStr:
      Result := C.StrValue;
  else
    Result := 'None';
  end;
end;

procedure MethodLine(W: TWriter; T: TSym; M: TMethodInfo);
var
  Head, Text: string;
begin
  Text := '';
  if M.Result <> nil then
    Text := ': ' + TypeText(TStr(M.Result));
  Head := '    ' + M.Kind + ' ';
  Text := Head + M.Name + GroupsText(ParamGroups(M.Params)) + Text + ';';
  if M.Virtual_ then
    Text := Text + ' virtual;';
  W.Line1(Text, 'method', LowerText(T.Name), LowerText(M.Name), Length(Head), Length(M.Name));
end;

procedure RoutineLines(W: TWriter; R: TSym);
var
  Head, Res, Tail, One: string;
  Groups: TStringArray;
  I: Integer;
begin
  if R.TypeName <> '' then
    Head := 'function '
  else
    Head := 'procedure ';
  Groups := ParamGroups(R.Params);
  Res := '';
  if R.TypeName <> '' then
    Res := ': ' + TypeText(R.TypeName);
  if R.Directive = 'interrupt' then
    Tail := ' interrupt;'
  else if R.Directive = 'inline' then
    Tail := '  { inline }'
  else
    Tail := '';
  One := Head + R.Name + GroupsText(Groups) + Res + ';' + Tail;
  if (CharLen(One) <= StubWidth) or (Length(Groups) < 2) then
  begin
    W.Line1(One, 'routine', '', LowerText(R.Name), Length(Head), Length(R.Name));
    Exit;
  end;
  W.Line1(Head + R.Name + '(', 'routine', '', LowerText(R.Name), Length(Head), Length(R.Name));
  for I := 0 to High(Groups) do
    if I < High(Groups) then
      W.Line('    ' + Groups[I] + ';')
    else
      W.Line('    ' + Groups[I] + ')' + Res + ';' + Tail);
end;

type
  TMember = record
    IsField: Boolean;
    F: TSymField;
    M: TMethodInfo;
    Seq: Integer;
    Private_: Boolean;
  end;

procedure TypeLines(W: TWriter; T: TSym; const Members: TSyms);
var
  Key, Head, Anc, Tail: string;
  Items: array of TMember;
  X: TMember;
  F: TSymField;
  M: TMethodInfo;
  I, J, First: Integer;
  Private_: Boolean;
  Texts, Names: TStringArray;
  C: TSym;
begin
  Key := LowerText(T.Name);
  Head := '  ' + T.Name + ' = ';
  if (T.Shape = 'record') or (T.Shape = 'object') then
  begin
    Anc := '';
    if (T.Shape = 'object') and NamedOf(T.Ancestor, Anc) and (Anc <> '') then
      Anc := '(' + Anc + ')';
    W.Line1(Head + T.Shape + Anc, 'type', '', Key, 2, Length(T.Name));
    Items := nil;
    for F in T.Fields do
    begin
      SetLength(Items, Length(Items) + 1);
      Items[High(Items)].IsField := True;
      Items[High(Items)].F := F;
      Items[High(Items)].M := nil;
      if F.IsMember then
        Items[High(Items)].Seq := F.Seq
      else
        Items[High(Items)].Seq := 0;
      Items[High(Items)].Private_ := F.IsMember and F.Private_;
    end;
    for M in T.Methods do
    begin
      SetLength(Items, Length(Items) + 1);
      Items[High(Items)].IsField := False;
      Items[High(Items)].F := nil;
      Items[High(Items)].M := M;
      Items[High(Items)].Seq := M.Seq;
      Items[High(Items)].Private_ := M.Private_;
    end;
    for I := 1 to High(Items) do
    begin
      X := Items[I];
      J := I - 1;
      while (J >= 0) and (Items[J].Seq > X.Seq) do
      begin
        Items[J + 1] := Items[J];
        Dec(J);
      end;
      Items[J + 1] := X;
    end;
    Private_ := False;
    for X in Items do
    begin
      if (T.Shape = 'object') and (X.Private_ <> Private_) then
      begin
        Private_ := X.Private_;
        if Private_ then
          W.Line('  private')
        else
          W.Line('  public');
      end;
      if X.IsField then
        W.Line1('    ' + X.F.Name + ': ' + TypeText(X.F.TypeName) + ';  { @' + IntToStr(X.F.Offset) + ' }',
          'field', Key, LowerText(X.F.Name), 4, Length(X.F.Name))
      else
        MethodLine(W, T, X.M);
    end;
    W.Line('  end;');
    Exit;
  end;
  if Members <> nil then
  begin
    Texts := nil;
    Names := nil;
    for C in Members do
    begin
      Push(Texts, C.Name);
      Push(Names, LowerText(C.Name));
    end;
    First := Length(W.Stub.Lines);
    Tail := ');';
    if T.Shape <> 'enum' then
      Tail := Tail + '  { built-in, size ' + SizeText(T.Size) + ' }';
    W.Wrapped(Head + '(', Texts, Names, Tail);
    W.Stub.Mark('type', '', Key, First, 2, Length(T.Name));
    Exit;
  end;
  if T.Shape = 'openstring' then
    W.Line1(Head + 'string;  { open string parameter type }', 'type', '', Key, 2, Length(T.Name))
  else if T.Shape = 'primitive' then
    W.Line1(Head + T.Name + ';  { built-in, size ' + SizeText(T.Size) + ' }', 'type', '', Key, 2, Length(T.Name))
  else if T.Definition <> '' then
  begin
    if TypeText(T.Definition) = '^file' then
      W.Line1(Head + 'Pointer;  { built-in untyped pointer, size ' + SizeText(T.Size) + ' }', 'type', '', Key, 2,
        Length(T.Name))
    else
      W.Line1(Head + TypeText(T.Definition) + ';', 'type', '', Key, 2, Length(T.Name));
  end
  else if T.Size = 4 then
    W.Line1(Head + 'procedure;  { procedural type: its signature is not decoded }', 'type', '', Key, 2,
      Length(T.Name))
  else
    W.Line1(Head + '...;  { size ' + SizeText(T.Size) + ': the kind of this type is not decoded }', 'type', '', Key,
      2, Length(T.Name));
end;

function HasName(const A: TStringArray; const S: string): Boolean;
var
  X: string;
begin
  for X in A do
    if X = S then
      Exit(True);
  Result := False;
end;

procedure PushSym(var A: TSyms; S: TSym);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

type
  TMemberList = class
  public
    Items: TSyms;
  end;

function SortedMembers(const A: TSyms): TSyms;
var
  I, J: Integer;
  X: TSym;

  function Before(P, Q: TSym): Boolean;
  var
    PN, QN: Boolean;
    PV, QV: Int64;
  begin
    PN := P.ValueKind = vkNone;
    QN := Q.ValueKind = vkNone;
    if PN <> QN then
      Exit(QN);
    if P.ValueKind = vkInt then
      PV := P.IntValue
    else
      PV := 0;
    if Q.ValueKind = vkInt then
      QV := Q.IntValue
    else
      QV := 0;
    Result := PV < QV;
  end;

begin
  Result := Copy(A);
  for I := 1 to High(Result) do
  begin
    X := Result[I];
    J := I - 1;
    while (J >= 0) and Before(X, Result[J]) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := X;
  end;
end;

function Render(U: TUnit; const Origin: string): TStub;
var
  W: TWriter;
  S, T, C, V, B, Owner: TSym;
  Types, Consts, Typed, Vars, Routines, Builtins, Arrays: TSyms;
  MembersOf: TStrMap;
  L: TMemberList;
  Uses_, MemberNames: TStringArray;
  X, Named, Shown, Extra, Ab, Full, Sig, Note: string;
  I, At: Integer;
begin
  Result := TStub.Create;
  Result.UnitName_ := U.Name;
  W := TWriter.Create;
  MembersOf := TStrMap.Create;
  try
    W.Stub := Result;
    W.Line('{ tp7ls stub (version ' + IntToStr(StubVersion) + '): the interface of unit ' + U.Name + '.');
    if Origin <> '' then
      W.Line('  Generated from ' + Origin + '.')
    else
      W.Line('  Generated from a TPU file.');
    W.Line('  There is no source for this unit. Generated files are read only: changes are lost.');
    W.Line('  A TPU stores no bodies, comments or constant expressions; parameter names only with debug info');
    W.Line('  (otherwise P1, P2, ... stand in), so only declarations and their types are shown. }');
    W.Line1('unit ' + U.Name + ';', 'unit', '', '', Length('unit '), Length(U.Name));
    W.Line;
    W.Line('interface');
    W.Line;
    Uses_ := nil;
    for X in U.Used do
      if (LowerText(X) <> LowerText(U.Name)) and (LowerText(X) <> 'system') then
        Push(Uses_, X);
    if Uses_ <> nil then
    begin
      W.Line('uses');
      W.Line('  ' + Join(Uses_, ', ') + ';');
      W.Line;
    end;

    Types := nil;
    for S in U.Symbols do
      if S.Kind = 'type' then
        PushSym(Types, S);
    for T in Types do
      if (T.Shape = 'enum') and T.HasMembers and (T.Members <> nil) then
      begin
        L := TMemberList(MembersOf.Get(T.Name));
        if L = nil then
        begin
          L := TMemberList.Create;
          MembersOf.Put(T.Name, L);
        end;
        L.Items := nil;
        for C in U.Symbols do
          if (C.Kind = 'const') and HasName(T.Members, C.Name) then
            PushSym(L.Items, C);
      end;
    for C in U.Symbols do
    begin
      if C.Kind <> 'const' then
        Continue;
      Owner := nil;
      if NamedOf(C.TypeDesc, Named) then
        for T in Types do
          if (T.Name = Named) and (C.TypeDesc.UnitOf = U.Name) and (T.Shape = 'primitive') then
          begin
            Owner := T;
            Break;
          end;
      if Owner <> nil then
      begin
        L := TMemberList(MembersOf.SetDefault(Owner.Name, nil));
        if L = nil then
        begin
          L := TMemberList.Create;
          MembersOf.Put(Owner.Name, L);
        end;
        PushSym(L.Items, C);
      end;
    end;
    MemberNames := nil;
    for I := 0 to MembersOf.Count - 1 do
      for C in TMemberList(MembersOf.At(I)).Items do
        Push(MemberNames, C.Name);
    Consts := nil;
    Typed := nil;
    Vars := nil;
    Routines := nil;
    Builtins := nil;
    Arrays := nil;
    for S in U.Symbols do
      if (S.Kind = 'const') and not HasName(MemberNames, S.Name) then
        PushSym(Consts, S)
      else if (S.Kind = 'var') and S.TypedConst then
        PushSym(Typed, S)
      else if S.Kind = 'var' then
        PushSym(Vars, S)
      else if S.Kind = 'routine' then
        PushSym(Routines, S)
      else if S.Kind = 'builtin' then
        if (S.Tag <> '') and (Pos(S.Tag, 'YZ') = 0) then
          PushSym(Builtins, S)
        else
          PushSym(Arrays, S);

    if (Consts <> nil) or (Typed <> nil) then
    begin
      W.Line('const');
      for C in Consts do
      begin
        NamedOf(C.TypeDesc, Named);
        if C.Display <> '' then
          Shown := C.Display
        else
          Shown := ValueOf(C);
        if (Named = '') or (Named = 'Longint') or (Named = 'string') or (C.Display <> '') then
          Extra := ''
        else
          Extra := '  { ' + Named + ' }';
        W.Line1('  ' + C.Name + ' = ' + Shown + ';' + Extra, 'const', '', LowerText(C.Name), 2, Length(C.Name));
      end;
      for V in Typed do
      begin
        X := V.TypeName;
        if X = '' then
          X := '?';
        if V.Init <> '' then
          W.Line1('  ' + V.Name + ': ' + TypeText(X) + ' = ' + V.Init + ';', 'var', '', LowerText(V.Name), 2,
            Length(V.Name))
        else
          W.Line1('  ' + V.Name + ': ' + TypeText(X) + ';  { typed constant: the value is not decoded }', 'var', '',
            LowerText(V.Name), 2, Length(V.Name));
      end;
      W.Line;
    end;
    if Types <> nil then
    begin
      W.Line('type');
      for T in Types do
      begin
        L := TMemberList(MembersOf.Get(T.Name));
        if L <> nil then
          TypeLines(W, T, SortedMembers(L.Items))
        else
          TypeLines(W, T, nil);
      end;
      W.Line;
    end;
    if (Vars <> nil) or (Arrays <> nil) then
    begin
      W.Line('var');
      for V in Vars do
      begin
        Ab := '';
        if V.HasAbsolute then
          Ab := ' absolute $' + IntToHex(V.AbsSeg, 4) + ':$' + IntToHex(V.AbsOfs, 4);
        X := V.TypeName;
        if X = '' then
          X := '?';
        W.Line1('  ' + V.Name + ': ' + TypeText(X) + Ab + ';', 'var', '', LowerText(V.Name), 2, Length(V.Name));
      end;
      for B in Arrays do
      begin
        if not BuiltinSig(B.Name, Full) then
          Full := B.Name + ': array';
        Partition(Full, Sig, Note);
        W.Line1('  ' + RStrip(Sig) + ';' + NoteText(Note), 'builtin', '', LowerText(B.Name), 2, Length(B.Name));
      end;
      W.Line;
    end;
    for S in Routines do
      RoutineLines(W, S);
    if Routines <> nil then
      W.Line;
    if Builtins <> nil then
    begin
      W.Line('{ Built-in procedures and functions: the compiler knows them, they have no declaration.');
      W.Line('  The signatures below are informal (taken from the Turbo Pascal 7 manual). }');
      for B in Builtins do
      begin
        if not BuiltinSig(B.Name, Full) then
          if B.Tag = 'W' then
            Full := 'function ' + B.Name
          else
            Full := 'procedure ' + B.Name;
        Partition(Full, Sig, Note);
        Sig := RStrip(Sig);
        At := WordAt(Sig, B.Name);
        if At > 0 then
          Dec(At);
        W.Line1(Sig + ';' + NoteText(Note), 'builtin', '', LowerText(B.Name), At, Length(B.Name));
      end;
      W.Line;
    end;
    W.Line('implementation');
    W.Line;
    W.Line('end.');
    Result.Text := Join(Result.Lines, StubEol) + StubEol;
  finally
    for I := 0 to MembersOf.Count - 1 do
      MembersOf.At(I).Free;
    MembersOf.Free;
    W.Free;
  end;
end;

function TempDir: string;
var
  V: string;
begin
  for V in [string('TMPDIR'), 'TEMP', 'TMP'] do
    if (GetEnvironmentVariable(V) <> '') and IsDir(GetEnvironmentVariable(V)) then
      Exit(AbsPath(GetEnvironmentVariable(V)));
{$IFDEF WINDOWS}
  Result := AbsPath(GetTempDir(False));
{$ELSE}
  Result := '/tmp';
{$ENDIF}
end;

function HomeDir: string;
begin
  Result := GetEnvironmentVariable('HOME');
  if Result = '' then
    Result := ExcludeTrailingPathDelimiter(GetUserDir);
end;

function DefaultStubDir: string;
var
  Base, Path: string;
begin
{$IFDEF WINDOWS}
  Base := GetEnvironmentVariable('LOCALAPPDATA');
  if Base = '' then
    Base := HomeDir;
{$ELSE}
  Base := GetEnvironmentVariable('XDG_CACHE_HOME');
  if Base = '' then
    Base := JoinPath(HomeDir, '.cache');
{$ENDIF}
  Path := JoinPath(JoinPath(Base, 'tp7ls'), 'stubs');
  try
    if ForceDirectories(Path) then
      Exit(Path);
  except
    on EInOutError do;
  end;
  Result := JoinPath(TempDir, 'tp7ls-stubs');
end;

{ TStubStore }

constructor TStubStore.Create(const ARoot: string);
begin
  Root := AbsPath(ARoot);
  FArena := TObjectList.Create(True);
  FKeys := TStringList.Create;
end;

destructor TStubStore.Destroy;
begin
  FKeys.Free;
  FArena.Free;
  inherited;
end;

function TStubStore.IsStub(const Path: string): Boolean;
var
  A, R: string;
begin
  if Path = '' then
    Exit(False);
  A := NormCase(AbsPath(Path));
  R := NormCase(Root);
  Result := (A = R) or (Copy(A, 1, Length(R) + 1) = R + DirectorySeparator);
end;

procedure SetMode(const Path: string; Mode: Integer);
begin
{$IFDEF UNIX}
  if FpChmod(Path, Mode) <> 0 then
    raise EInOutError.Create('chmod failed: ' + Path);
{$ELSE}
  if Mode and &200 = 0 then
    FileSetAttr(Path, faReadOnly)
  else
    FileSetAttr(Path, 0);
{$ENDIF}
end;

function SameFile(const Path: string; const Data: RawByteString): Boolean;
begin
  try
    Result := ReadFileBytes(Path) = Data;
  except
    on EStreamError do
      Result := False;
    on EInOutError do
      Result := False;
  end;
end;

procedure WriteData(const Path: string; const Data: RawByteString);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    if Data <> '' then
      F.WriteBuffer(Data[1], Length(Data));
  finally
    F.Free;
  end;
end;

function TStubStore.Get(Info: TUnitInfo; out Path: string; out Stub: TStub): Boolean;
var
  U: TUnit;
  Key0, Key, Folder, Abs: string;
  Data: RawByteString;
  I: Integer;
begin
  Path := '';
  Stub := nil;
  if (Info = nil) or (Info.Tpu = nil) then
    Exit(False);
  U := Info.Tpu;
  if Info.Origin <> '' then
  begin
    Abs := AbsPath(Info.Origin);
    Key0 := NormCase(Abs);
  end
  else
  begin
    Abs := '';
    Key0 := '';
  end;
  Key := Key0 + #0 + LowerText(U.Name);
  I := FKeys.IndexOf(Key);
  if I >= 0 then
  begin
    Path := FPaths[I];
    Stub := FStubs[I];
    Exit(Stub <> nil);
  end;
  Stub := Render(U, Abs);
  FArena.Add(Stub);
  Folder := JoinPath(Root, Copy(SHA1Print(SHA1String(Key0)), 1, 8));
  Path := JoinPath(Folder, U.Name + '.pas');
  Data := Utf8ToCp866(Stub.Text);
  try
    if not SameFile(Path, Data) then
    begin
      if not ForceDirectories(Folder) then
        raise EInOutError.Create('cannot create ' + Folder);
      if FileExists(Path) or DirectoryExists(Path) then
        SetMode(Path, &666);
      WriteData(Path, Data);
      SetMode(Path, &444);
    end;
  except
    on EStreamError do
      Stub := nil;
    on EInOutError do
      Stub := nil;
    on EOSError do
      Stub := nil;
  end;
  if Stub = nil then
    Path := '';
  FKeys.Add(Key);
  SetLength(FPaths, Length(FPaths) + 1);
  FPaths[High(FPaths)] := Path;
  SetLength(FStubs, Length(FStubs) + 1);
  FStubs[High(FStubs)] := Stub;
  Result := Stub <> nil;
end;

end.
