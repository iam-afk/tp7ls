unit tpudump;

{$mode objfpc}{$H+}

interface

uses
  Contnrs, SysUtils;

type
  ETpuError = class(Exception);
  ETpuIndex = class(ETpuError);
  ETpuStruct = class(ETpuError);

  TTypeKind = (tdNamed, tdUnresolved, tdArray, tdRecord, tdObject, tdPointer, tdString, tdSubrange, tdSet, tdFile,
    tdProc, tdPrimitive, tdEnum, tdOther);

  TTypeDesc = class;
  TParam = class;
  TFieldInfo = class;
  TMethodInfo = class;
  TParams = array of TParam;
  TFieldInfos = array of TFieldInfo;
  TMethodInfos = array of TMethodInfo;

  TEnumMembers = class
  public
    Names: TStringArray;
  end;

  TTypeDesc = class
  public
    Kind: TTypeKind;
    Name: string;
    UnitOf: string;
    Ofs: Integer;
    Size: Integer;
    Elem, Index, Target, Base, Result, Ancestor: TTypeDesc;
    Fields: TFieldInfos;
    Methods: TMethodInfos;
    Params: TParams;
    MaxLen: Integer;
    Lo, Hi: LongInt;
    Chars: Boolean;
    CodeNum: Integer;
    Code: string;
    Members: TEnumMembers;
  end;

  TFieldInfo = class
  public
    Name: string;
    Offset: Integer;
    TypeDesc: TTypeDesc;
    IsMember: Boolean;
    Private_: Boolean;
    Seq: Integer;
  end;

  TMethodInfo = class
  public
    Name, Kind: string;
    Virtual_: Boolean;
    Vmt: Integer;
    Params: TParams;
    Result: TTypeDesc;
    Private_: Boolean;
    Seq: Integer;
  end;

  TParam = class
  public
    Kind: string;
    TypeName: string;
    Name: string;
    Open: Boolean;
    TypeDesc: TTypeDesc;
  end;

  TSymField = class
  public
    Name: string;
    Offset: Integer;
    TypeName: string;
    TypeDesc: TTypeDesc;
    IsMember: Boolean;
    Private_: Boolean;
    Seq: Integer;
  end;

  TSymFields = array of TSymField;

  TValueKind = (vkNone, vkInt, vkStr);

  TSym = class
  public
    Kind: string;
    Name: string;
    Tag: string;
    Offset: Integer;
    TypeName: string;
    Params: TParams;
    HasParams: Boolean;
    Fields: TSymFields;
    HasFields: Boolean;
    ValueKind: TValueKind;
    IntValue: Int64;
    StrValue: string;
    Size: Integer;
    Shape: string;
    Definition: string;
    Members: TStringArray;
    HasMembers: Boolean;
    Methods: TMethodInfos;
    HasMethods: Boolean;
    Ancestor: TTypeDesc;
    TypeDesc: TTypeDesc;
    Note: string;
    Display: string;
    TypedConst: Boolean;
    Init: string;
    HasAbsolute: Boolean;
    AbsSeg, AbsOfs: Integer;
    Directive: string;
    DataOfs, DataUid, DataPos: Integer;
    SetType: TTypeDesc;
    SetBits: TBytes;
    HasSet: Boolean;
  end;

  TSyms = array of TSym;

  TUnit = class
  public
    Name: string;
    Used: TStringArray;
    Symbols: TSyms;
  end;

  TRec = record
    Tag: string;
    TagByte: Byte;
    Name: string;
    Next, Body, Off: Integer;
  end;

  TRecs = array of TRec;

  TImage = class
  private
    FRecs: TRecs;
    FRecsDone: Boolean;
  public
    D: TBytes;
    constructor Create(const AData: TBytes);
    function B(O: Integer): Byte;
    function W(O: Integer): Integer;
    function I32(O: Integer): LongInt;
    function Bytes(O, N: Integer): TBytes;
    function Text(O, N: Integer): string;
    function Records: TRecs;
  end;

  TImages = array of TImage;

  TIntName = record
    Key: Integer;
    Name: string;
  end;

  TIntNames = array of TIntName;

  TUnitSlot = record
    Key: string;
    Img: TImage;
    Recs: TRecs;
    TMap: TIntNames;
    Ids: TIntNames;
    U: TUnit;
  end;

  TEnumList = record
    Key: string;
    Ofs: Integer;
    Members: TEnumMembers;
  end;

  TEnumNamed = record
    Key, Name: string;
    Members: TStringArray;
  end;

  TLoader = class
  private
    FArena: TObjectList;
    FSlots: array of TUnitSlot;
    FEnumLists: array of TEnumList;
    FEnumNamed: array of TEnumNamed;
    function Slot(const Key: string): Integer;
    function Keep(O: TObject): TObject;
    function NewDesc(Kind: TTypeKind): TTypeDesc;
    function EnumList(const Key: string; Ofs: Integer): TEnumMembers;
    function FindEnumNamed(const Key, Name: string; out Members: TStringArray): Boolean;
    function Fields(const Key: string; Im: TImage; Desc, Depth: Integer): TFieldInfos;
    procedure Members(const Key: string; Im: TImage; Desc, Depth: Integer; out AFields: TFieldInfos;
      out AMethods: TMethodInfos);
    function Param(const Key: string; Im: TImage; P: Integer): TParam;
    function Signature(const Key: string; Im: TImage; Rec, B: Integer; out Params: TParams): TTypeDesc;
    function ParamNames(Im: TImage; Rec, Ptr, N: Integer; out Names: TStringArray): Boolean;
    function StructOf(const Key: string; T: TTypeDesc; Ofs, Uid: Integer): TTypeDesc;
    function SizeOfType(const Key: string; T: TTypeDesc; Ofs, Uid: Integer): Integer;
    function ValueText(const Key: string; Im: TImage; T: TTypeDesc; Ofs, Uid, Pos: Integer; Depth: Integer;
      out Text: string): Boolean;
    function SetBaseNames(const Key: string; Base: TTypeDesc; out Names: TStringArray; out IsChar: Boolean): Boolean;
    function Ref(const AUnit: string; Im: TImage; O: Integer): TTypeDesc;
    function Decode(const Key: string): TUnit;
    function Sym(const Key: string; Im: TImage; const R: TRec): TSym;
  public
    Primary: TStringArray;
    constructor Create(const Images: TImages; NPrimary: Integer = -1);
    destructor Destroy; override;
    function TDesc(const AUnit: string; Ofs, Uid: Integer; Depth: Integer = 0; Named: Boolean = True): TTypeDesc;
    function UnitCount: Integer;
    function UnitKey(I: Integer): string;
    function UnitAt(I: Integer): TUnit;
    function FindUnit(const Key: string): TUnit;
  end;

function SplitImages(const Blob: TBytes): TImages;
function ReadImages(const Path: string): TImages;
procedure FreeImages(var Images: TImages);
function RealText(const Raw: TBytes; const Name: string): string;
function CharText(Code: Integer): string;
function PasLiteral(const Text: string): string;
function SetText(const Bits: TBytes; const Names: TStringArray; HasNames, IsChar: Boolean): string;
function FormatG15(V: Double): string;
function TStr(T: TTypeDesc): string;
function ParamText(const Params: TParams; const Prefix: string = 'P'): string;
function MethodText(M: TMethodInfo): string;
function RenderPas(U: TUnit): string;

implementation

uses
  Classes, Math, tp7enc;

const
  Sig = 'TPUQ';
  ScalarNames: array[0..10] of string = ('Byte', 'Shortint', 'Integer', 'Word', 'Longint', 'Char', 'Boolean',
    'Bytebool', 'Wordbool', 'Longbool', 'Comp');
  ScalarSizes: array[0..10] of Integer = (1, 1, 2, 2, 4, 1, 1, 1, 2, 4, 8);
  ScalarSigned: array[0..10] of Boolean = (False, True, True, False, True, False, False, False, False, False, True);
  RealNames: array[0..3] of string = ('Real', 'Single', 'Double', 'Extended');
  RealSizes: array[0..3] of Integer = (6, 4, 8, 10);

function ScalarIndex(const N: string): Integer;
begin
  for Result := 0 to High(ScalarNames) do
    if ScalarNames[Result] = N then
      Exit;
  Result := -1;
end;

function RealIndex(const N: string): Integer;
begin
  for Result := 0 to High(RealNames) do
    if RealNames[Result] = N then
      Exit;
  Result := -1;
end;

function IsBool(const N: string): Boolean;
begin
  Result := (N = 'Boolean') or (N = 'Bytebool') or (N = 'Wordbool') or (N = 'Longbool');
end;

function HexLower(V: Integer): string;
begin
  Result := '0x' + LowerCase(IntToHex(V, 1));
end;

function JoinStr(const Parts: array of string; const Sep: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Parts) do
    if I = 0 then
      Result := Parts[I]
    else
      Result := Result + Sep + Parts[I];
end;

procedure PushStr(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function BytesToInt(const B: TBytes; Signed: Boolean): Int64;
var
  I: Integer;
  U: QWord;
begin
  U := 0;
  for I := High(B) downto 0 do
    U := (U shl 8) or B[I];
  Result := Int64(U);
  if Signed and (Length(B) > 0) and (Length(B) < 8) and (B[High(B)] and $80 <> 0) then
    Result := Int64(U) - (Int64(1) shl (8 * Length(B)));
end;

{ exact %.15g }

type
  TBig = array of LongWord;

procedure BigNorm(var A: TBig);
var
  N: Integer;
begin
  N := Length(A);
  while (N > 0) and (A[N - 1] = 0) do
    Dec(N);
  SetLength(A, N);
end;

function BigFrom(V: QWord): TBig;
begin
  Result := nil;
  SetLength(Result, 2);
  Result[0] := LongWord(V);
  Result[1] := LongWord(V shr 32);
  BigNorm(Result);
end;

function BigMulSmall(const A: TBig; M: LongWord): TBig;
var
  I: Integer;
  Carry: QWord;
begin
  Result := nil;
  SetLength(Result, Length(A) + 1);
  Carry := 0;
  for I := 0 to High(A) do
  begin
    Carry := QWord(A[I]) * M + Carry;
    Result[I] := LongWord(Carry);
    Carry := Carry shr 32;
  end;
  Result[Length(A)] := LongWord(Carry);
  BigNorm(Result);
end;

function BigShl(const A: TBig; Bits: Integer): TBig;
var
  Words, Sh, I: Integer;
  V: QWord;
begin
  Result := nil;
  if Length(A) = 0 then
    Exit;
  Words := Bits div 32;
  Sh := Bits mod 32;
  SetLength(Result, Length(A) + Words + 1);
  for I := 0 to High(A) do
  begin
    V := QWord(A[I]) shl Sh;
    Result[I + Words] := Result[I + Words] or LongWord(V);
    Result[I + Words + 1] := Result[I + Words + 1] or LongWord(V shr 32);
  end;
  BigNorm(Result);
end;

function BigCmp(const A, B: TBig): Integer;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(Ord(Length(A) > Length(B)) * 2 - 1);
  for I := High(A) downto 0 do
    if A[I] <> B[I] then
      Exit(Ord(A[I] > B[I]) * 2 - 1);
  Result := 0;
end;

function BigSub(const A, B: TBig): TBig;
var
  I: Integer;
  Borrow, X: Int64;
begin
  Result := Copy(A);
  Borrow := 0;
  for I := 0 to High(Result) do
  begin
    X := Int64(Result[I]) - Borrow;
    if I <= High(B) then
      X := X - B[I];
    if X < 0 then
    begin
      X := X + (Int64(1) shl 32);
      Borrow := 1;
    end
    else
      Borrow := 0;
    Result[I] := LongWord(X);
  end;
  BigNorm(Result);
end;

function BigPow10(const A: TBig; N: Integer): TBig;
begin
  Result := A;
  while N >= 9 do
  begin
    Result := BigMulSmall(Result, 1000000000);
    Dec(N, 9);
  end;
  while N > 0 do
  begin
    Result := BigMulSmall(Result, 10);
    Dec(N);
  end;
end;

procedure BigDivSmallQ(A: TBig; const B: TBig; out Q: QWord; out R: TBig);
var
  I: Integer;
begin
  Q := 0;
  for I := 60 downto 0 do
    if BigCmp(A, BigShl(B, I)) >= 0 then
    begin
      A := BigSub(A, BigShl(B, I));
      Q := Q or (QWord(1) shl I);
    end;
  R := A;
end;

function FormatG15(V: Double): string;
const
  P = 15;
  Lo15: QWord = 100000000000000;
  Hi15: QWord = 1000000000000000;
var
  Bits, Mant, Q: QWord;
  E, K, S, X, I: Integer;
  Neg: Boolean;
  N, D, A, B, R: TBig;
  Digits, Mantissa, ExpPart: string;
begin
  Move(V, Bits, 8);
  Neg := Bits shr 63 <> 0;
  E := (Bits shr 52) and $7FF;
  Mant := Bits and ((QWord(1) shl 52) - 1);
  if E = $7FF then
  begin
    if Mant <> 0 then
      Exit('nan');
    if Neg then
      Exit('-inf');
    Exit('inf');
  end;
  if (E = 0) and (Mant = 0) then
  begin
    if Neg then
      Exit('-0');
    Exit('0');
  end;
  if E = 0 then
    E := -1074
  else
  begin
    Mant := Mant or (QWord(1) shl 52);
    E := E - 1075;
  end;
  N := BigFrom(Mant);
  D := BigFrom(1);
  if E >= 0 then
    N := BigShl(N, E)
  else
    D := BigShl(D, -E);
  K := Floor(Log10(Abs(V)));
  repeat
    S := P - 1 - K;
    if S >= 0 then
    begin
      A := BigPow10(N, S);
      B := D;
    end
    else
    begin
      A := N;
      B := BigPow10(D, -S);
    end;
    BigDivSmallQ(A, B, Q, R);
    if Q >= Hi15 then
      Inc(K)
    else if Q < Lo15 then
      Dec(K)
    else
      Break;
  until False;
  I := BigCmp(BigShl(R, 1), B);
  if (I > 0) or ((I = 0) and Odd(Q)) then
    Inc(Q);
  if Q = Hi15 then
  begin
    Q := Lo15;
    Inc(K);
  end;
  Digits := IntToStr(Q);
  X := K;
  if (X >= -4) and (X < P) then
  begin
    if X >= 0 then
      Result := Copy(Digits, 1, X + 1) + '.' + Copy(Digits, X + 2, MaxInt)
    else
      Result := '0.' + StringOfChar('0', -X - 1) + Digits;
    while Result[Length(Result)] = '0' do
      SetLength(Result, Length(Result) - 1);
    if Result[Length(Result)] = '.' then
      SetLength(Result, Length(Result) - 1);
  end
  else
  begin
    Mantissa := Digits[1] + '.' + Copy(Digits, 2, MaxInt);
    while Mantissa[Length(Mantissa)] = '0' do
      SetLength(Mantissa, Length(Mantissa) - 1);
    if Mantissa[Length(Mantissa)] = '.' then
      SetLength(Mantissa, Length(Mantissa) - 1);
    ExpPart := IntToStr(Abs(X));
    if Length(ExpPart) < 2 then
      ExpPart := '0' + ExpPart;
    if X < 0 then
      Result := Mantissa + 'e-' + ExpPart
    else
      Result := Mantissa + 'e+' + ExpPart;
  end;
  if Neg then
    Result := '-' + Result;
end;

{ texts }

function ScaledQWord(Mant: QWord; Exp: Integer): Double;
var
  Shift: Integer;
  Q, Rem, Half: QWord;
begin
  Shift := 0;
  while (Mant shr Shift) >= (QWord(1) shl 53) do
    Inc(Shift);
  Q := Mant shr Shift;
  if Shift > 0 then
  begin
    Rem := Mant and ((QWord(1) shl Shift) - 1);
    Half := QWord(1) shl (Shift - 1);
    if (Rem > Half) or ((Rem = Half) and Odd(Q)) then
      Inc(Q);
  end;
  Result := LdExp(Double(Q), Shift + Exp);
end;

function RealText(const Raw: TBytes; const Name: string): string;
var
  V: Double;
  Mant: QWord;
  SE, Ex: Integer;
  M: QWord;
  Sng: Single;
  P: SizeInt;
  Tmp: TBytes;
begin
  if Name = 'Extended' then
  begin
    Mant := QWord(BytesToInt(Copy(Raw, 0, 8), False));
    SE := Integer(BytesToInt(Copy(Raw, 8, 2), False));
    if Mant <> 0 then
      V := ScaledQWord(Mant, (SE and $7FFF) - 16383 - 63)
    else
      V := 0.0;
    if SE and $8000 <> 0 then
      V := -V;
  end
  else if Name = 'Double' then
  begin
    if Length(Raw) < 8 then
      raise ETpuStruct.Create('unpack requires a buffer of 8 bytes');
    Move(Raw[0], V, 8);
  end
  else if Name = 'Single' then
  begin
    if Length(Raw) < 4 then
      raise ETpuStruct.Create('unpack requires a buffer of 4 bytes');
    Move(Raw[0], Sng, 4);
    V := Sng;
  end
  else
  begin
    if Length(Raw) = 0 then
      raise ETpuIndex.Create('index out of range');
    Ex := Raw[0];
    Tmp := Copy(Raw, 1, 5);
    M := QWord(BytesToInt(Tmp, False));
    if Ex = 0 then
      V := 0.0
    else
      V := (1 + (M and ((QWord(1) shl 39) - 1)) / Power(2.0, 39)) * Power(2.0, Ex - 129);
    if (M shr 39) and 1 <> 0 then
      V := -V;
  end;
  Result := FormatG15(V);
  P := Pos('e', Result);
  if P > 0 then
    Exit(Copy(Result, 1, P - 1) + 'E' + IntToStr(StrToInt(Copy(Result, P + 1, MaxInt))));
  if Pos('.', Result) = 0 then
    Result := Result + '.0';
end;

function PasLiteral(const Text: string): string;
var
  Run: string;
  C: Char;
  HasOut: Boolean;
begin
  Result := '';
  Run := '';
  HasOut := False;
  for C in Text do
    if (Ord(C) < 32) or (Ord(C) = 127) then
    begin
      if Run <> '' then
      begin
        Result := Result + '''' + StringReplace(Run, '''', '''''', [rfReplaceAll]) + '''';
        Run := '';
      end;
      Result := Result + '#' + IntToStr(Ord(C));
      HasOut := True;
    end
    else
      Run := Run + C;
  if (Run <> '') or not HasOut then
    Result := Result + '''' + StringReplace(Run, '''', '''''', [rfReplaceAll]) + '''';
end;

function CharText(Code: Integer): string;
begin
  Result := PasLiteral(Cp866ToUtf8(Chr(Code and 255)));
end;

function SetText(const Bits: TBytes; const Names: TStringArray; HasNames, IsChar: Boolean): string;
var
  On_: array of Integer;
  Parts: TStringArray;
  I, J, K: Integer;

  function One(X: Integer): string;
  begin
    if HasNames then
    begin
      if X < Length(Names) then
        Exit(Names[X]);
      Exit(IntToStr(X));
    end;
    if IsChar then
      Exit(CharText(X));
    Result := IntToStr(X);
  end;

begin
  On_ := nil;
  for I := 0 to Length(Bits) * 8 - 1 do
    if (Bits[I div 8] shr (I mod 8)) and 1 <> 0 then
    begin
      SetLength(On_, Length(On_) + 1);
      On_[High(On_)] := I;
    end;
  Parts := nil;
  I := 0;
  while I < Length(On_) do
  begin
    J := I;
    while (J + 1 < Length(On_)) and (On_[J + 1] = On_[J] + 1) do
      Inc(J);
    if J - I >= 2 then
      PushStr(Parts, One(On_[I]) + '..' + One(On_[J]))
    else
      for K := I to J do
        PushStr(Parts, One(On_[K]));
    I := J + 1;
  end;
  Result := '[' + JoinStr(Parts, ', ') + ']';
end;

function ParamText(const Params: TParams; const Prefix: string): string;
var
  Parts: TStringArray;
  I: Integer;
  P: TParam;
  Kw, Name, ArrOf: string;
begin
  Parts := nil;
  for I := 0 to High(Params) do
  begin
    P := Params[I];
    if P.Kind = 'var' then
      Kw := 'var '
    else if P.Kind = 'const' then
      Kw := 'const '
    else
      Kw := '';
    Name := P.Name;
    if Name = '' then
      Name := Prefix + IntToStr(I + 1);
    if (P.Kind = 'var') and (P.TypeName = 'file') and not P.Open then
      PushStr(Parts, 'var ' + Name)
    else
    begin
      if P.Open then
        ArrOf := 'array of '
      else
        ArrOf := '';
      PushStr(Parts, Kw + Name + ': ' + ArrOf + P.TypeName);
    end;
  end;
  Result := JoinStr(Parts, '; ');
end;

function TStr(T: TTypeDesc): string;
var
  Idx: TStringArray;
  E: TTypeDesc;
  F: TFieldInfo;
  Parts: TStringArray;
  Ps, Res, Anc: string;
begin
  case T.Kind of
    tdNamed:
      Result := T.Name;
    tdUnresolved:
      Result := '?' + T.UnitOf + '@' + HexLower(T.Ofs);
    tdString:
      Result := 'string[' + IntToStr(T.MaxLen) + ']';
    tdArray:
      begin
        Idx := nil;
        PushStr(Idx, TStr(T.Index));
        E := T.Elem;
        while E.Kind = tdArray do
        begin
          PushStr(Idx, TStr(E.Index));
          E := E.Elem;
        end;
        Result := 'array[' + JoinStr(Idx, ', ') + '] of ' + TStr(E);
      end;
    tdSet:
      Result := 'set of ' + TStr(T.Base);
    tdFile:
      Result := 'file of ' + TStr(T.Elem);
    tdProc:
      begin
        Ps := ParamText(T.Params, 'A');
        if T.Result <> nil then
          Res := TStr(T.Result)
        else
          Res := '';
        if Res <> '' then
          Result := 'function'
        else
          Result := 'procedure';
        if Ps <> '' then
          Result := Result + '(' + Ps + ')';
        if Res <> '' then
          Result := Result + ': ' + Res;
      end;
    tdPointer:
      Result := '^' + TStr(T.Target);
    tdSubrange:
      if T.Chars then
        Result := CharText(T.Lo) + '..' + CharText(T.Hi)
      else
        Result := IntToStr(T.Lo) + '..' + IntToStr(T.Hi);
    tdPrimitive:
      Result := 'primitive' + HexLower(T.CodeNum);
    tdRecord, tdObject:
      begin
        Parts := nil;
        for F in T.Fields do
          PushStr(Parts, F.Name + ': ' + TStr(F.TypeDesc) + ';');
        if T.Kind = tdRecord then
          Result := 'record ' + JoinStr(Parts, ' ') + ' end'
        else
        begin
          Anc := '';
          if T.Ancestor <> nil then
            Anc := '(' + TStr(T.Ancestor) + ')';
          Result := 'object' + Anc + ' ' + JoinStr(Parts, ' ') + ' end';
        end;
      end;
    tdEnum:
      if (T.Members <> nil) and (T.Members.Names <> nil) then
        Result := '(' + JoinStr(T.Members.Names, ', ') + ')'
      else if (T.Size = -1) or (T.Size = 1) then
        Result := 'Byte'
      else
        Result := 'Word';
  else
    Result := '?other';
  end;
end;

function MethodText(M: TMethodInfo): string;
var
  Ps: string;
begin
  Ps := ParamText(M.Params);
  Result := M.Kind + ' ' + M.Name;
  if Ps <> '' then
    Result := Result + '(' + Ps + ')';
  if M.Result <> nil then
    Result := Result + ': ' + TStr(M.Result);
  Result := Result + ';';
  if M.Virtual_ then
    Result := Result + ' virtual;';
end;

function SizeText(V: Integer): string;
begin
  if V < 0 then
    Result := 'None'
  else
    Result := IntToStr(V);
end;

function ValueStr(S: TSym): string;
begin
  case S.ValueKind of
    vkInt:
      Result := IntToStr(S.IntValue);
    vkStr:
      Result := S.StrValue;
  else
    Result := 'None';
  end;
end;

function RenderPas(U: TUnit): string;
var
  L, EnumNames, Names: TStringArray;
  S: TSym;
  F: TSymField;
  M: TMethodInfo;
  Ps, Anc: string;
  Any: Boolean;

  procedure Add(const X: string);
  begin
    PushStr(L, X);
  end;

  function IsEnumName(const N: string): Boolean;
  var
    X: string;
  begin
    for X in EnumNames do
      if X = N then
        Exit(True);
    Result := False;
  end;

begin
  L := nil;
  Add('unit ' + U.Name + ';');
  Add('');
  Add('interface');
  Add('');
  if U.Used <> nil then
  begin
    Add('uses ' + JoinStr(U.Used, ', ') + ';');
    Add('');
  end;
  EnumNames := nil;
  for S in U.Symbols do
    if S.HasMembers then
      for Ps in S.Members do
        PushStr(EnumNames, Ps);
  Any := False;
  for S in U.Symbols do
    if (S.Kind = 'const') and not IsEnumName(S.Name) then
    begin
      if not Any then
        Add('const');
      Any := True;
      Add('  ' + S.Name + ' = ' + ValueStr(S) + ';  { ' + S.TypeName + ' }');
    end;
  if Any then
    Add('');
  Any := False;
  for S in U.Symbols do
    if S.Kind = 'type' then
    begin
      if not Any then
        Add('type');
      Any := True;
      if S.Shape = 'record' then
      begin
        Add('  ' + S.Name + ' = record  { size ' + SizeText(S.Size) + ' }');
        for F in S.Fields do
          Add('    ' + F.Name + ': ' + F.TypeName + ';  { @' + IntToStr(F.Offset) + ' }');
        Add('  end;');
      end
      else if S.Shape = 'object' then
      begin
        Anc := '';
        if S.Ancestor <> nil then
          Anc := '(' + TStr(S.Ancestor) + ')';
        Add('  ' + S.Name + ' = object' + Anc + '  { size ' + SizeText(S.Size) + ' }');
        for F in S.Fields do
          Add('    ' + F.Name + ': ' + F.TypeName + ';  { @' + IntToStr(F.Offset) + ' }');
        for M in S.Methods do
          Add('    ' + MethodText(M));
        Add('  end;');
      end
      else if S.Definition <> '' then
        Add('  ' + S.Name + ' = ' + S.Definition + ';  { size ' + SizeText(S.Size) + ' }')
      else
        Add('  ' + S.Name + ' = ...;  { ' + S.Shape + ', size ' + SizeText(S.Size) + ' }');
    end;
  if Any then
    Add('');
  Any := False;
  for S in U.Symbols do
    if S.Kind = 'var' then
    begin
      if not Any then
        Add('var');
      Any := True;
      Add('  ' + S.Name + ': ' + S.TypeName + ';');
    end;
  if Any then
    Add('');
  for S in U.Symbols do
    if S.Kind = 'routine' then
    begin
      Ps := ParamText(S.Params);
      if Ps <> '' then
        Ps := '(' + Ps + ')';
      if S.TypeName <> '' then
        Add('function ' + S.Name + Ps + ': ' + S.TypeName + ';')
      else
        Add('procedure ' + S.Name + Ps + ';');
    end;
  Names := nil;
  for S in U.Symbols do
    if S.Kind = 'builtin' then
      PushStr(Names, S.Name);
  if Names <> nil then
  begin
    Add('');
    Add('{ compiler built-ins: ' + JoinStr(Names, ', ') + ' }');
  end;
  Result := JoinStr(L, #10) + #10;
end;

{ TImage }

constructor TImage.Create(const AData: TBytes);
begin
  if (Length(AData) < 4) or (AData[0] <> Ord('T')) or (AData[1] <> Ord('P')) or (AData[2] <> Ord('U'))
    or (AData[3] <> Ord('Q')) then
    raise ETpuError.Create('not a TPU image');
  D := AData;
end;

function TImage.B(O: Integer): Byte;
begin
  if (O < 0) or (O >= Length(D)) then
    raise ETpuIndex.Create('index out of range');
  Result := D[O];
end;

function TImage.W(O: Integer): Integer;
begin
  if (O < 0) or (O + 2 > Length(D)) then
    raise ETpuStruct.Create('unpack_from requires a buffer of at least 2 bytes');
  Result := D[O] or (D[O + 1] shl 8);
end;

function TImage.I32(O: Integer): LongInt;
begin
  if (O < 0) or (O + 4 > Length(D)) then
    raise ETpuStruct.Create('unpack_from requires a buffer of at least 4 bytes');
  Result := LongInt(LongWord(D[O]) or (LongWord(D[O + 1]) shl 8) or (LongWord(D[O + 2]) shl 16)
    or (LongWord(D[O + 3]) shl 24));
end;

function TImage.Bytes(O, N: Integer): TBytes;
begin
  if O >= Length(D) then
    Exit(nil);
  if O + N > Length(D) then
    N := Length(D) - O;
  if N <= 0 then
    Exit(nil);
  Result := Copy(D, O, N);
end;

function TImage.Text(O, N: Integer): string;
var
  Raw: RawByteString;
  Src: TBytes;
begin
  Src := Bytes(O, N);
  Raw := '';
  SetLength(Raw, Length(Src));
  if Src <> nil then
    Move(Src[0], Raw[1], Length(Src));
  Result := Cp866ToUtf8(Raw);
end;

function TagText(B: Byte): string;
begin
  if B < $80 then
    Result := Chr(B)
  else
    Result := Chr($C0 or (B shr 6)) + Chr($80 or (B and $3F));
end;

function TImage.Records: TRecs;
var
  Size, I, O, Ln: Integer;
  Seen: array of Boolean;
  R: TRec;
begin
  if FRecsDone then
    Exit(FRecs);
  Size := W(96);
  if Odd(Size) or (Size > $400) then
    raise ETpuError.CreateFmt('unexpected hash table size %s', [HexLower(Size)]);
  Seen := nil;
  SetLength(Seen, Length(D));
  FRecs := nil;
  for I := 0 to Size div 2 do
  begin
    O := W(98 + 2 * I);
    while (O <> 0) and ((O >= Length(D)) or not Seen[O]) do
    begin
      Ln := B(O + 3);
      R.TagByte := B(O + 2);
      R.Tag := TagText(R.TagByte);
      R.Name := Text(O + 4, Ln);
      R.Next := W(O);
      R.Body := O + 4 + Ln;
      R.Off := O;
      if O < Length(D) then
        Seen[O] := True;
      SetLength(FRecs, Length(FRecs) + 1);
      FRecs[High(FRecs)] := R;
      O := W(O);
    end;
  end;
  FRecsDone := True;
  Result := FRecs;
end;

function SortedRecs(const Recs: TRecs): TRecs;
var
  I, J: Integer;
  T: TRec;
begin
  Result := Copy(Recs);
  for I := 1 to High(Result) do
  begin
    T := Result[I];
    J := I - 1;
    while (J >= 0) and (Result[J].Off > T.Off) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := T;
  end;
end;

function SplitImages(const Blob: TBytes): TImages;
var
  Offs: array of Integer;
  I, K: Integer;
  Im: TImage;
begin
  Result := nil;
  Offs := nil;
  I := 0;
  while I + 4 <= Length(Blob) do
  begin
    if (Blob[I] = Ord('T')) and (Blob[I + 1] = Ord('P')) and (Blob[I + 2] = Ord('U')) and (Blob[I + 3] = Ord('Q')) then
    begin
      SetLength(Offs, Length(Offs) + 1);
      Offs[High(Offs)] := I;
      Inc(I, 4);
    end
    else
      Inc(I);
  end;
  SetLength(Offs, Length(Offs) + 1);
  Offs[High(Offs)] := Length(Blob);
  for K := 0 to High(Offs) - 1 do
  begin
    Im := TImage.Create(Copy(Blob, Offs[K], Offs[K + 1] - Offs[K]));
    try
      Im.Records;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Im;
    except
      Im.Free;
    end;
  end;
end;

function ReadImages(const Path: string): TImages;
var
  Raw: RawByteString;
  Blob: TBytes;
begin
  Raw := ReadFileBytes(Path);
  Blob := nil;
  SetLength(Blob, Length(Raw));
  if Raw <> '' then
    Move(Raw[1], Blob[0], Length(Raw));
  Result := SplitImages(Blob);
end;

procedure FreeImages(var Images: TImages);
var
  Im: TImage;
begin
  for Im in Images do
    Im.Free;
  Images := nil;
end;

{ TLoader }

function FindName(const Map: TIntNames; Key: Integer; out Name: string): Boolean;
var
  X: TIntName;
begin
  for X in Map do
    if X.Key = Key then
    begin
      Name := X.Name;
      Exit(True);
    end;
  Result := False;
end;

procedure PutName(var Map: TIntNames; Key: Integer; const Name: string);
var
  I: Integer;
begin
  for I := 0 to High(Map) do
    if Map[I].Key = Key then
    begin
      Map[I].Name := Name;
      Exit;
    end;
  SetLength(Map, Length(Map) + 1);
  Map[High(Map)].Key := Key;
  Map[High(Map)].Name := Name;
end;

constructor TLoader.Create(const Images: TImages; NPrimary: Integer);
var
  N, I, K: Integer;
  Im: TImage;
  Recs, S: TRecs;
  R: TRec;
  Name, Key: string;
begin
  FArena := TObjectList.Create(True);
  Primary := nil;
  for N := 0 to High(Images) do
  begin
    Im := Images[N];
    Recs := Im.Records;
    S := nil;
    for R in SortedRecs(Recs) do
      if R.Tag = 'S' then
      begin
        SetLength(S, Length(S) + 1);
        S[High(S)] := R;
      end;
    if S <> nil then
      Name := S[0].Name
    else
      Name := 'System';
    Key := LowerText(Name);
    if (NPrimary < 0) or (N < NPrimary) then
      PushStr(Primary, Key);
    K := Slot(Key);
    if K < 0 then
    begin
      SetLength(FSlots, Length(FSlots) + 1);
      K := High(FSlots);
      FSlots[K].Key := Key;
    end;
    FSlots[K].Img := Im;
    FSlots[K].Recs := Recs;
    FSlots[K].TMap := nil;
    for R in Recs do
      if (R.Tag = 'P') or (R.Tag = '[') then
        PutName(FSlots[K].TMap, Im.W(R.Body), R.Name);
    FSlots[K].Ids := nil;
    for R in S do
      PutName(FSlots[K].Ids, R.Body, R.Name);
  end;
  for I := 0 to High(FSlots) do
    FSlots[I].U := Decode(FSlots[I].Key);
end;

destructor TLoader.Destroy;
begin
  FArena.Free;
  inherited Destroy;
end;

function TLoader.Slot(const Key: string): Integer;
begin
  for Result := 0 to High(FSlots) do
    if FSlots[Result].Key = Key then
      Exit;
  Result := -1;
end;

function TLoader.Keep(O: TObject): TObject;
begin
  FArena.Add(O);
  Result := O;
end;

function TLoader.NewDesc(Kind: TTypeKind): TTypeDesc;
begin
  Result := TTypeDesc(Keep(TTypeDesc.Create));
  Result.Kind := Kind;
  Result.Size := -1;
end;

function TLoader.UnitCount: Integer;
begin
  Result := Length(FSlots);
end;

function TLoader.UnitKey(I: Integer): string;
begin
  Result := FSlots[I].Key;
end;

function TLoader.UnitAt(I: Integer): TUnit;
begin
  Result := FSlots[I].U;
end;

function TLoader.FindUnit(const Key: string): TUnit;
var
  K: Integer;
begin
  K := Slot(Key);
  if K < 0 then
    Exit(nil);
  Result := FSlots[K].U;
end;

function TLoader.EnumList(const Key: string; Ofs: Integer): TEnumMembers;
var
  X: TEnumList;
begin
  for X in FEnumLists do
    if (X.Key = Key) and (X.Ofs = Ofs) then
      Exit(X.Members);
  Result := TEnumMembers(Keep(TEnumMembers.Create));
  SetLength(FEnumLists, Length(FEnumLists) + 1);
  FEnumLists[High(FEnumLists)].Key := Key;
  FEnumLists[High(FEnumLists)].Ofs := Ofs;
  FEnumLists[High(FEnumLists)].Members := Result;
end;

function TLoader.FindEnumNamed(const Key, Name: string; out Members: TStringArray): Boolean;
var
  X: TEnumNamed;
begin
  Members := nil;
  for X in FEnumNamed do
    if (X.Key = Key) and (X.Name = Name) then
    begin
      Members := X.Members;
      Exit(True);
    end;
  Result := False;
end;

function TLoader.TDesc(const AUnit: string; Ofs, Uid: Integer; Depth: Integer; Named: Boolean): TTypeDesc;
var
  UName, Key, TName: string;
  K, Size, N, I: Integer;
  Im: TImage;
  Code: Byte;
  Anc, RefOfs: Integer;

  function Sub(O: Integer): TTypeDesc;
  begin
    Result := TDesc(Key, Im.W(O), Im.W(O + 2), Depth + 1);
  end;

begin
  K := Slot(AUnit);
  if (K < 0) or not FindName(FSlots[K].Ids, Uid, UName) then
  begin
    Result := NewDesc(tdUnresolved);
    Result.UnitOf := '?';
    Result.Ofs := Ofs;
    Exit;
  end;
  Key := LowerText(UName);
  if Key = 'system' then
    case Ofs of
      $BA, $82, $8A:
        begin
          Result := NewDesc(tdNamed);
          if Ofs = $BA then
            Result.Name := 'string'
          else
            Result.Name := 'file';
          Result.UnitOf := 'System';
          Exit;
        end;
    end;
  K := Slot(Key);
  if K < 0 then
  begin
    Result := NewDesc(tdUnresolved);
    Result.UnitOf := UName;
    Result.Ofs := Ofs;
    Exit;
  end;
  if Named and FindName(FSlots[K].TMap, Ofs, TName) then
  begin
    Result := NewDesc(tdNamed);
    Result.Name := TName;
    Result.UnitOf := UName;
    Exit;
  end;
  if Depth > 8 then
  begin
    Result := NewDesc(tdOther);
    Result.Code := 'too deep';
    Exit;
  end;
  Im := FSlots[K].Img;
  Code := Im.B(Ofs);
  Size := Im.W(Ofs + 2);
  case Code of
    1:
      begin
        Result := NewDesc(tdArray);
        Result.Size := Size;
        Result.Elem := Sub(Ofs + 8);
        Result.Index := Sub(Ofs + 12);
      end;
    2:
      begin
        Result := NewDesc(tdRecord);
        Result.Size := Size;
        Result.Fields := Fields(Key, Im, Ofs, Depth);
      end;
    3:
      begin
        Result := NewDesc(tdObject);
        Result.Size := Size;
        Members(Key, Im, Ofs, Depth, Result.Fields, Result.Methods);
        Anc := Im.W(Ofs + 12);
        if Anc <> 0 then
          Result.Ancestor := TDesc(Key, Anc, Im.W(Ofs + 14), Depth + 1);
      end;
    8:
      begin
        Result := NewDesc(tdPointer);
        Result.Target := Sub(Ofs + 8);
      end;
    9:
      begin
        Result := NewDesc(tdString);
        Result.MaxLen := Size - 1;
      end;
    $0C:
      begin
        Result := NewDesc(tdSubrange);
        Result.Size := Size;
        Result.Lo := Im.I32(Ofs + 8);
        Result.Hi := Im.I32(Ofs + 12);
      end;
    7:
      begin
        Result := NewDesc(tdSet);
        Result.Size := Size;
        Result.Base := Sub(Ofs + 8);
      end;
    4:
      begin
        Result := NewDesc(tdFile);
        Result.Size := Size;
        Result.Elem := Sub(Ofs + 8);
      end;
    6:
      begin
        Result := NewDesc(tdProc);
        Result.Size := Size;
        N := Im.W(Ofs + 12);
        RefOfs := Im.W(Ofs + 8);
        if RefOfs <> 0 then
          Result.Result := Sub(Ofs + 8);
        for I := 0 to N - 1 do
        begin
          SetLength(Result.Params, Length(Result.Params) + 1);
          Result.Params[High(Result.Params)] := Param(Key, Im, Ofs + 14 + 5 * I);
        end;
      end;
    $0E:
      begin
        if (Im.I32(Ofs + 8) <> 0) or (Im.I32(Ofs + 12) <> 255) then
        begin
          Result := NewDesc(tdSubrange);
          Result.Size := Size;
          Result.Lo := Im.I32(Ofs + 8);
          Result.Hi := Im.I32(Ofs + 12);
          Result.Chars := True;
        end
        else
        begin
          Result := NewDesc(tdPrimitive);
          Result.CodeNum := Code;
          Result.Size := Size;
        end;
      end;
    $0F:
      begin
        Result := NewDesc(tdEnum);
        Result.Members := EnumList(Key, Ofs);
        Result.Size := Size;
        Result.UnitOf := Key;
        Result.Ofs := Ofs;
      end;
    $05, $0A, $0B, $0D:
      begin
        Result := NewDesc(tdPrimitive);
        Result.CodeNum := Code;
        Result.Size := Size;
      end;
  else
    Result := NewDesc(tdOther);
    Result.Code := HexLower(Im.W(Ofs));
    Result.Size := Size;
  end;
end;

function TLoader.Fields(const Key: string; Im: TImage; Desc, Depth: Integer): TFieldInfos;
var
  F, Ln, Q: Integer;
  Seen: array of Integer;
  Fi: TFieldInfo;

  function WasSeen(X: Integer): Boolean;
  var
    Y: Integer;
  begin
    for Y in Seen do
      if Y = X then
        Exit(True);
    Result := False;
  end;

begin
  Result := nil;
  Seen := nil;
  F := Im.W(Desc + 10);
  while (F <> 0) and not WasSeen(F) and (Im.B(F + 2) = $51) do
  begin
    SetLength(Seen, Length(Seen) + 1);
    Seen[High(Seen)] := F;
    Ln := Im.B(F + 3);
    Q := F + 4 + Ln;
    Fi := TFieldInfo(Keep(TFieldInfo.Create));
    Fi.Name := Im.Text(F + 4, Ln);
    Fi.Offset := Im.W(Q + 1);
    Fi.TypeDesc := TDesc(Key, Im.W(Q + 7), Im.W(Q + 9), Depth + 1);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Fi;
    F := Im.W(Q + 5);
  end;
end;

procedure TLoader.Members(const Key: string; Im: TImage; Desc, Depth: Integer; out AFields: TFieldInfos;
  out AMethods: TMethodInfos);
var
  F, Ln, B, Seq: Integer;
  Seen: array of Integer;
  Name: string;
  Priv: Boolean;
  Tag, Flags: Byte;
  Fi: TFieldInfo;
  M: TMethodInfo;
  Ret: TTypeDesc;
  Params: TParams;

  function WasSeen(X: Integer): Boolean;
  var
    Y: Integer;
  begin
    for Y in Seen do
      if Y = X then
        Exit(True);
    Result := False;
  end;

begin
  AFields := nil;
  AMethods := nil;
  Seen := nil;
  Seq := 0;
  F := Im.W(Desc + 10);
  while (F <> 0) and not WasSeen(F) and ((Im.B(F + 2) and $7F) in [$51, $52]) do
  begin
    SetLength(Seen, Length(Seen) + 1);
    Seen[High(Seen)] := F;
    Ln := Im.B(F + 3);
    B := F + 4 + Ln;
    Name := Im.Text(F + 4, Ln);
    Tag := Im.B(F + 2);
    Priv := Tag and $80 <> 0;
    if Tag and $7F = $51 then
    begin
      Inc(Seq);
      Fi := TFieldInfo(Keep(TFieldInfo.Create));
      Fi.Name := Name;
      Fi.Offset := Im.W(B + 1);
      Fi.IsMember := True;
      Fi.Private_ := Priv;
      Fi.Seq := Seq;
      Fi.TypeDesc := TDesc(Key, Im.W(B + 7), Im.W(B + 9), Depth + 1);
      SetLength(AFields, Length(AFields) + 1);
      AFields[High(AFields)] := Fi;
      F := Im.W(B + 5);
      Continue;
    end;
    Flags := Im.B(B);
    Ret := Signature(Key, Im, F, B, Params);
    M := TMethodInfo(Keep(TMethodInfo.Create));
    M.Name := Name;
    case Flags and $F0 of
      $30:
        M.Kind := 'constructor';
      $50:
        M.Kind := 'destructor';
    else
      if Ret <> nil then
        M.Kind := 'function'
      else
        M.Kind := 'procedure';
    end;
    Inc(Seq);
    M.Vmt := Im.W(B + 8);
    M.Virtual_ := M.Vmt <> 0;
    M.Params := Params;
    M.Result := Ret;
    M.Private_ := Priv;
    M.Seq := Seq;
    SetLength(AMethods, Length(AMethods) + 1);
    AMethods[High(AMethods)] := M;
    F := Im.W(B + 16);
  end;
end;

function TLoader.Param(const Key: string; Im: TImage; P: Integer): TParam;
var
  Kb: Byte;
begin
  Kb := Im.B(P + 4);
  Result := TParam(Keep(TParam.Create));
  case Kb and $47 of
    $02:
      Result.Kind := 'value';
    $06:
      Result.Kind := 'var';
    $42:
      Result.Kind := 'const';
  else
    Result.Kind := 'kind' + HexLower(Kb);
  end;
  Result.TypeDesc := Ref(Key, Im, P);
  Result.TypeName := TStr(Result.TypeDesc);
  Result.Open := Kb and $80 <> 0;
end;

function TLoader.Signature(const Key: string; Im: TImage; Rec, B: Integer; out Params: TParams): TTypeDesc;
var
  N, P, I: Integer;
  Names: TStringArray;
begin
  Result := Ref(Key, Im, B + 18);
  N := Im.W(B + 22);
  Params := nil;
  P := B + 24;
  for I := 0 to N - 1 do
  begin
    SetLength(Params, Length(Params) + 1);
    Params[High(Params)] := Param(Key, Im, P);
    Inc(P, 5);
  end;
  if ParamNames(Im, Rec, Im.W(B + 6), N, Names) and (Names <> nil) then
    for I := 0 to Min(High(Params), High(Names)) do
      Params[I].Name := Names[I];
  if Im.W(B + 18) = 0 then
    Result := nil;
end;

function TLoader.ParamNames(Im: TImage; Rec, Ptr, N: Integer; out Names: TStringArray): Boolean;
var
  Size, I, O, B: Integer;
  Found: array of Integer;
  Count, J, K, T: Integer;

  function Known(X: Integer): Boolean;
  var
    Y: Integer;
  begin
    for Y in Found do
      if Y = X then
        Exit(True);
    Result := False;
  end;

begin
  Names := nil;
  Result := False;
  try
    if (N = 0) or (Ptr = 0) or (Ptr + 4 > Length(Im.D)) then
      Exit;
    Size := Im.W(Ptr);
    if Odd(Size) or (Size > $400) then
      Exit;
    Found := nil;
    for I := 0 to Size div 2 do
    begin
      O := Im.W(Ptr + 2 + 2 * I);
      while (O <> 0) and not Known(O) and (O + 4 < Length(Im.D)) do
      begin
        SetLength(Found, Length(Found) + 1);
        Found[High(Found)] := O;
        O := Im.W(O);
      end;
    end;
    Count := Length(Found);
    for J := 1 to Count - 1 do
    begin
      T := Found[J];
      K := J - 1;
      while (K >= 0) and (Found[K] > T) do
      begin
        Found[K + 1] := Found[K];
        Dec(K);
      end;
      Found[K + 1] := T;
    end;
    for O in Found do
    begin
      if Im.B(O + 2) <> $51 then
        Continue;
      B := O + 4 + Im.B(O + 3);
      if (Im.B(B) and $20 <> 0) and (Im.W(B + 3) = Rec) then
        PushStr(Names, Im.Text(O + 4, B - O - 4));
    end;
    if Length(Names) = N then
      Result := True
    else
      Names := nil;
  except
    on ETpuIndex do
    begin
      Names := nil;
      Result := False;
    end;
  end;
end;

function TLoader.StructOf(const Key: string; T: TTypeDesc; Ofs, Uid: Integer): TTypeDesc;
var
  UK: string;
  K, I, Me: Integer;
  X: TIntName;
begin
  if T.Kind <> tdNamed then
    Exit(T);
  if Ofs <> 0 then
    Exit(TDesc(Key, Ofs, Uid, 0, False));
  UK := LowerText(T.UnitOf);
  K := Slot(UK);
  if K >= 0 then
    for X in FSlots[K].TMap do
      if X.Name = T.Name then
      begin
        Me := -1;
        for I := 0 to High(FSlots[K].Ids) do
          if LowerText(FSlots[K].Ids[I].Name) = UK then
          begin
            Me := FSlots[K].Ids[I].Key;
            Break;
          end;
        if Me >= 0 then
          Exit(TDesc(UK, X.Key, Me, 0, False));
      end;
  Result := T;
end;

function TLoader.SizeOfType(const Key: string; T: TTypeDesc; Ofs, Uid: Integer): Integer;
var
  St: TTypeDesc;
begin
  if T.Kind = tdNamed then
  begin
    if ScalarIndex(T.Name) >= 0 then
      Exit(ScalarSizes[ScalarIndex(T.Name)]);
    if RealIndex(T.Name) >= 0 then
      Exit(RealSizes[RealIndex(T.Name)]);
    if T.Name = 'Pointer' then
      Exit(4);
  end;
  St := StructOf(Key, T, Ofs, Uid);
  case St.Kind of
    tdString:
      Result := St.MaxLen + 1;
    tdPointer:
      Result := 4;
    tdArray, tdRecord, tdObject, tdSubrange, tdSet, tdFile, tdProc, tdPrimitive, tdEnum, tdOther:
      Result := St.Size;
  else
    Result := -1;
  end;
end;

function AllZero(const B: TBytes): Boolean;
var
  X: Byte;
begin
  for X in B do
    if X <> 0 then
      Exit(False);
  Result := True;
end;

function TLoader.ValueText(const Key: string; Im: TImage; T: TTypeDesc; Ofs, Uid, Pos: Integer; Depth: Integer;
  out Text: string): Boolean;
var
  N, V, Part: string;
  SI, Size, ESize, Count, I: Integer;
  Val: Int64;
  St: TTypeDesc;
  Names, Vals, Parts: TStringArray;
  IsChar, HasNames: Boolean;
  F: TFieldInfo;
begin
  Text := '';
  Result := False;
  if T.Kind = tdNamed then
    N := T.Name
  else
    N := #0;
  try
    SI := ScalarIndex(N);
    if SI >= 0 then
    begin
      Val := BytesToInt(Im.Bytes(Pos, ScalarSizes[SI]), ScalarSigned[SI]);
      if N = 'Char' then
        Text := CharText(Val)
      else if IsBool(N) then
      begin
        if Val <> 0 then
          Text := 'True'
        else
          Text := 'False';
      end
      else
        Text := IntToStr(Val);
      Exit(True);
    end;
    if RealIndex(N) >= 0 then
    begin
      Text := RealText(Im.Bytes(Pos, RealSizes[RealIndex(N)]), N);
      Exit(True);
    end;
    if N = 'string' then
    begin
      Text := PasLiteral(Im.Text(Pos + 1, Im.B(Pos)));
      Exit(True);
    end;
    if N = 'Pointer' then
    begin
      if AllZero(Im.Bytes(Pos, 4)) then
      begin
        Text := 'nil';
        Exit(True);
      end;
      Exit(False);
    end;
    if Depth > 6 then
      Exit(False);
    St := StructOf(Key, T, Ofs, Uid);
    case St.Kind of
      tdString:
        begin
          Text := PasLiteral(Im.Text(Pos + 1, Im.B(Pos)));
          Exit(True);
        end;
      tdPointer:
        begin
          if AllZero(Im.Bytes(Pos, 4)) then
          begin
            Text := 'nil';
            Exit(True);
          end;
          Exit(False);
        end;
      tdSubrange:
        begin
          Size := St.Size;
          if Size <= 0 then
            Size := 2;
          Val := BytesToInt(Im.Bytes(Pos, Size), St.Lo < 0);
          if St.Chars then
            Text := CharText(Val)
          else
            Text := IntToStr(Val);
          Exit(True);
        end;
      tdEnum:
        begin
          Size := St.Size;
          if Size <= 0 then
            Size := 1;
          Val := BytesToInt(Im.Bytes(Pos, Size), False);
          Names := nil;
          if (St.Members <> nil) and (St.Members.Names <> nil) then
            Names := St.Members.Names
          else if T.Kind = tdNamed then
            FindEnumNamed(LowerText(T.UnitOf), T.Name, Names);
          if (Names <> nil) and (Val < Length(Names)) then
            Text := Names[Val]
          else
            Text := IntToStr(Val);
          Exit(True);
        end;
      tdSet:
        begin
          HasNames := SetBaseNames(Key, St.Base, Names, IsChar);
          Text := SetText(Im.Bytes(Pos, St.Size), Names, HasNames, IsChar);
          Exit(True);
        end;
      tdArray:
        begin
          ESize := SizeOfType(Key, St.Elem, 0, 0);
          if ESize <= 0 then
            Exit(False);
          Count := St.Size div ESize;
          Vals := nil;
          for I := 0 to Min(Count, 64) - 1 do
          begin
            if not ValueText(Key, Im, St.Elem, 0, 0, Pos + I * ESize, Depth + 1, V) then
              Exit(False);
            PushStr(Vals, V);
          end;
          Text := '(' + JoinStr(Vals, ', ');
          if Count > 64 then
            Text := Text + ', ...';
          Text := Text + ')';
          Exit(True);
        end;
      tdRecord:
        begin
          Parts := nil;
          for F in St.Fields do
          begin
            if not ValueText(Key, Im, F.TypeDesc, 0, 0, Pos + F.Offset, Depth + 1, Part) then
              Exit(False);
            PushStr(Parts, F.Name + ': ' + Part);
          end;
          Text := '(' + JoinStr(Parts, '; ') + ')';
          Exit(True);
        end;
    end;
  except
    on ETpuError do
      Exit(False);
  end;
  Result := False;
end;

function TLoader.SetBaseNames(const Key: string; Base: TTypeDesc; out Names: TStringArray;
  out IsChar: Boolean): Boolean;
begin
  Names := nil;
  IsChar := False;
  if ((Base.Kind = tdNamed) and (Base.Name = 'Char')) or ((Base.Kind = tdSubrange) and Base.Chars) then
  begin
    IsChar := True;
    Exit(False);
  end;
  if Base.Kind = tdEnum then
  begin
    if (Base.Members <> nil) and (Base.Members.Names <> nil) then
    begin
      Names := Base.Members.Names;
      Exit(True);
    end;
    Exit(False);
  end;
  if Base.Kind = tdNamed then
    Result := FindEnumNamed(LowerText(Base.UnitOf), Base.Name, Names) and (Names <> nil)
  else
    Result := False;
end;

function TLoader.Ref(const AUnit: string; Im: TImage; O: Integer): TTypeDesc;
begin
  Result := TDesc(AUnit, Im.W(O), Im.W(O + 2));
end;

function TLoader.Decode(const Key: string): TUnit;
type
  TAnon = record
    Ofs: Integer;
    Consts: TSyms;
  end;
var
  K, Pass, I, J, Data, Run: Integer;
  Im: TImage;
  Ordered, S: TRecs;
  R: TRec;
  Sm, C, X: TSym;
  Anon: array of TAnon;
  Found: Boolean;
  Sorted, Consts, Enums: TSyms;
  Names: TStringArray;
  HasNames, IsChar: Boolean;
  Txt: string;
  Mem: TEnumMembers;

  procedure SortSyms(var A: TSyms; ByValue: Boolean);
  var
    P, Q: Integer;
    T: TSym;

    function Less(L, M: TSym): Boolean;
    begin
      if ByValue then
        Result := L.IntValue < M.IntValue
      else
        Result := L.Offset < M.Offset;
    end;

  begin
    for P := 1 to High(A) do
    begin
      T := A[P];
      Q := P - 1;
      while (Q >= 0) and Less(T, A[Q]) do
      begin
        A[Q + 1] := A[Q];
        Dec(Q);
      end;
      A[Q + 1] := T;
    end;
  end;

begin
  K := Slot(Key);
  Im := FSlots[K].Img;
  Ordered := SortedRecs(FSlots[K].Recs);
  S := nil;
  for R in Ordered do
    if R.Tag = 'S' then
    begin
      SetLength(S, Length(S) + 1);
      S[High(S)] := R;
    end;
  Result := TUnit(Keep(TUnit.Create));
  if S <> nil then
    Result.Name := S[0].Name
  else
    Result.Name := 'System';
  Result.Used := nil;
  for I := 1 to High(S) do
    PushStr(Result.Used, S[I].Name);
  for Pass := 1 to 2 do
  begin
    Result.Symbols := nil;
    for R in Ordered do
    begin
      Sm := Sym(Key, Im, R);
      if Sm <> nil then
      begin
        SetLength(Result.Symbols, Length(Result.Symbols) + 1);
        Result.Symbols[High(Result.Symbols)] := Sm;
      end;
    end;
    if Pass = 1 then
    begin
      Anon := nil;
      for C in Result.Symbols do
        if (C.Kind = 'const') and (C.TypeDesc <> nil) and (C.TypeDesc.Kind = tdEnum) and (C.TypeDesc.UnitOf = Key) then
        begin
          Found := False;
          for I := 0 to High(Anon) do
            if Anon[I].Ofs = C.TypeDesc.Ofs then
            begin
              SetLength(Anon[I].Consts, Length(Anon[I].Consts) + 1);
              Anon[I].Consts[High(Anon[I].Consts)] := C;
              Found := True;
              Break;
            end;
          if not Found then
          begin
            SetLength(Anon, Length(Anon) + 1);
            Anon[High(Anon)].Ofs := C.TypeDesc.Ofs;
            Anon[High(Anon)].Consts := [C];
          end;
        end;
      for I := 0 to High(Anon) do
      begin
        Sorted := Copy(Anon[I].Consts);
        SortSyms(Sorted, True);
        Mem := EnumList(Key, Anon[I].Ofs);
        Mem.Names := nil;
        for C in Sorted do
          PushStr(Mem.Names, C.Name);
      end;
      if Anon = nil then
        Break;
    end;
  end;
  Consts := nil;
  for C in Result.Symbols do
    if C.Kind = 'const' then
    begin
      SetLength(Consts, Length(Consts) + 1);
      Consts[High(Consts)] := C;
    end;
  Enums := nil;
  for X in Result.Symbols do
    if X.Shape = 'enum' then
    begin
      Found := False;
      for I := 0 to High(Enums) do
        if Enums[I].Name = X.Name then
        begin
          Enums[I] := X;
          Found := True;
        end;
      if not Found then
      begin
        SetLength(Enums, Length(Enums) + 1);
        Enums[High(Enums)] := X;
      end;
    end;
  for X in Enums do
  begin
    Sorted := nil;
    for C in Consts do
      if (C.TypeDesc.Kind = tdNamed) and (C.TypeDesc.Name = X.Name) and (C.TypeDesc.UnitOf = Result.Name) then
      begin
        SetLength(Sorted, Length(Sorted) + 1);
        Sorted[High(Sorted)] := C;
      end;
    SortSyms(Sorted, False);
    X.Members := nil;
    Run := 0;
    for C in Sorted do
    begin
      if (C.ValueKind <> vkInt) or (C.IntValue <> Run) then
        Break;
      PushStr(X.Members, C.Name);
      Inc(Run);
    end;
    X.HasMembers := True;
    X.Definition := '(' + JoinStr(X.Members, ', ') + ')';
    J := -1;
    for I := 0 to High(FEnumNamed) do
      if (FEnumNamed[I].Key = Key) and (FEnumNamed[I].Name = X.Name) then
        J := I;
    if J < 0 then
    begin
      SetLength(FEnumNamed, Length(FEnumNamed) + 1);
      J := High(FEnumNamed);
      FEnumNamed[J].Key := Key;
      FEnumNamed[J].Name := X.Name;
    end;
    FEnumNamed[J].Members := X.Members;
  end;
  for C in Consts do
    if C.Display = '' then
    begin
      Names := nil;
      HasNames := False;
      if (C.TypeDesc <> nil) and (C.TypeDesc.Kind = tdNamed) then
        HasNames := FindEnumNamed(LowerText(C.TypeDesc.UnitOf), C.TypeDesc.Name, Names) and (Names <> nil);
      if HasNames and (C.ValueKind = vkInt) and (C.IntValue >= 0) and (C.IntValue < Length(Names)) then
        C.Display := Names[C.IntValue]
      else if C.HasSet then
      begin
        HasNames := SetBaseNames(Key, C.SetType.Base, Names, IsChar);
        C.Display := SetText(C.SetBits, Names, HasNames, IsChar);
      end;
    end;
  Data := (Im.W(30) + Im.W(34) + 15) and not 15;
  if Data < Length(Im.D) then
    for C in Result.Symbols do
      if C.TypedConst then
        if ValueText(Key, Im, C.TypeDesc, C.DataOfs, C.DataUid, Data + C.DataPos, 0, Txt) then
          C.Init := Txt;
end;

function TLoader.Sym(const Key: string; Im: TImage; const R: TRec): TSym;
var
  B, N, RI: Integer;
  T, St: TTypeDesc;
  Params: TParams;
  NM: string;
  F: TFieldInfo;
  SF: TSymField;
begin
  B := R.Body;
  if R.Tag = 'S' then
    Exit(nil);
  Result := TSym(Keep(TSym.Create));
  Result.Name := R.Name;
  Result.Tag := R.Tag;
  Result.Offset := R.Off;
  Result.Size := -1;
  if R.Tag = 'R' then
  begin
    Result.Kind := 'routine';
    T := Signature(Key, Im, R.Off, B, Params);
    Result.TypeDesc := T;
    if T <> nil then
      Result.TypeName := TStr(T);
    Result.Params := Params;
    Result.HasParams := True;
    case Im.B(B) of
      $02:
        Result.Directive := 'inline';
      $04:
        Result.Directive := 'interrupt';
    end;
  end
  else if R.Tag = 'Q' then
  begin
    T := Ref(Key, Im, B + 7);
    Result.Kind := 'var';
    Result.TypeName := TStr(T);
    Result.TypeDesc := T;
    case Im.B(B) of
      1:
        begin
          Result.TypedConst := True;
          Result.DataOfs := Im.W(B + 7);
          Result.DataUid := Im.W(B + 9);
          Result.DataPos := Im.W(B + 1);
        end;
      3:
        begin
          Result.HasAbsolute := True;
          Result.AbsSeg := Im.W(B + 3);
          Result.AbsOfs := Im.W(B + 1);
        end;
    end;
  end
  else if R.Tag = 'O' then
  begin
    T := Ref(Key, Im, B);
    Result.Kind := 'const';
    Result.TypeDesc := T;
    if (T.Kind = tdNamed) and (T.Name = 'string') then
    begin
      N := Im.B(B + 4);
      Result.TypeName := 'string';
      Result.ValueKind := vkStr;
      Result.StrValue := PasLiteral(Im.Text(B + 5, N));
      Exit;
    end;
    Result.TypeName := TStr(T);
    Result.ValueKind := vkInt;
    Result.IntValue := Im.I32(B + 4);
    if T.Kind = tdNamed then
      NM := T.Name
    else
      NM := #0;
    RI := RealIndex(NM);
    if NM = 'Char' then
      Result.Display := CharText(Im.B(B + 4))
    else if IsBool(NM) then
    begin
      if Result.IntValue <> 0 then
        Result.Display := 'True'
      else
        Result.Display := 'False';
    end
    else if RI >= 0 then
      Result.Display := RealText(Im.Bytes(B + 4, RealSizes[RI]), NM)
    else
    begin
      St := StructOf(Key, T, Im.W(B), Im.W(B + 2));
      if St.Kind = tdSet then
      begin
        Result.HasSet := True;
        Result.SetType := St;
        Result.SetBits := Im.Bytes(B + 4, St.Size);
      end;
    end;
  end
  else if R.Tag = 'P' then
  begin
    T := TDesc(Key, Im.W(B), Im.W(B + 2), 0, False);
    Result.Kind := 'type';
    case T.Kind of
      tdNamed, tdUnresolved:
        Result.Shape := 'other';
      tdArray:
        Result.Shape := 'array';
      tdRecord:
        Result.Shape := 'record';
      tdObject:
        Result.Shape := 'object';
      tdPointer:
        Result.Shape := 'pointer';
      tdString:
        Result.Shape := 'string';
      tdSubrange:
        Result.Shape := 'subrange';
      tdSet:
        Result.Shape := 'set';
      tdFile:
        Result.Shape := 'file';
      tdProc:
        Result.Shape := 'proc';
      tdPrimitive:
        Result.Shape := 'primitive';
      tdEnum:
        Result.Shape := 'enum';
      tdOther:
        Result.Shape := 'other';
    end;
    Result.Size := Im.W(Im.W(B) + 2);
    Result.TypeDesc := T;
    if T.Kind in [tdRecord, tdObject] then
    begin
      Result.HasFields := True;
      for F in T.Fields do
      begin
        SF := TSymField(Keep(TSymField.Create));
        SF.Name := F.Name;
        SF.Offset := F.Offset;
        SF.TypeName := TStr(F.TypeDesc);
        SF.TypeDesc := F.TypeDesc;
        SF.IsMember := T.Kind = tdObject;
        SF.Private_ := F.Private_;
        SF.Seq := F.Seq;
        SetLength(Result.Fields, Length(Result.Fields) + 1);
        Result.Fields[High(Result.Fields)] := SF;
      end;
    end;
    if T.Kind = tdObject then
    begin
      Result.Methods := T.Methods;
      Result.HasMethods := True;
      Result.Ancestor := T.Ancestor;
    end;
    if not (T.Kind in [tdEnum, tdPrimitive]) then
      Result.Definition := TStr(T);
  end
  else if R.Tag = '[' then
  begin
    Result.Kind := 'type';
    Result.Shape := 'openstring';
  end
  else if (Length(R.Tag) = 1) and (R.Tag[1] in ['V', 'W', 'X', 'Y', 'Z']) then
  begin
    Result.Kind := 'builtin';
    case R.Tag[1] of
      'V':
        Result.Note := 'procedure';
      'W':
        Result.Note := 'function';
      'X':
        Result.Note := 'procedure (New)';
      'Y':
        Result.Note := 'port array';
      'Z':
        Result.Note := 'memory array';
    end;
  end
  else
  begin
    Result.Kind := 'other';
    Result.Note := 'tag ' + PyRepr(R.Tag) + ' not decoded';
  end;
end;

end.
