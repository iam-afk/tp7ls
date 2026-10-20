program good;
uses Crt, Dos;
type
  TColor = (Red, Green, Blue);
  TColors = set of TColor;
  TSmall = 1..10;
  PInt = ^Integer;
  TBuf = array[0..255] of Byte;
  PBuf = ^TBuf;
  TName = string[20];
  TProc = procedure;
  TFunc = function(a: Integer): Integer;
  TRec = record
    Name: TName;
    Age: Byte;
    case Kind: Byte of
      0: (I: Integer);
      1: (R: Real);
  end;
  PRec = ^TRec;
  TBase = object
    N: Integer;
    constructor Init(A: Integer);
    destructor Done; virtual;
    procedure Show; virtual;
    function Get: Integer;
  end;
  PBase = ^TBase;
  TKid = object(TBase)
    M: Longint;
    constructor Init(A: Integer; B: Longint);
    procedure Show; virtual;
  end;
  PKid = ^TKid;
const
  Max = 100;
  Names: array[TColor] of string[5] = ('red', 'green', 'blue');
  Origin: TRec = (Name: 'o'; Age: 0; Kind: 0; I: 0);
  Pi2 = 6.28;
  Esc = #27;
  Tab = ^I;
var
  i, j: Integer;
  b: Byte;
  w: Word;
  l: Longint;
  r: Real;
  e: Extended;
  cm: Comp;
  s: string;
  nm: TName;
  c: Char;
  f: Boolean;
  col: TColor;
  cols: TColors;
  sm: TSmall;
  p: PInt;
  pr: PRec;
  rec: TRec;
  base: TBase;
  kid: TKid;
  pb: PBase;
  pk: PKid;
  buf: TBuf;
  pbuf: PBuf;
  arr: array[1..10] of Integer;
  mat: array[1..3, 1..3] of Real;
  pc: PChar;
  asc: array[0..9] of Char;
  proc: TProc;
  fn: TFunc;
  txt: Text;
  fl: file of Integer;
  uf: file;
  reg: Registers;
  dt: DateTime;
  sr: SearchRec;
  ptr: Pointer;

function Sq(a: Integer): Integer; far;
begin
  Sq := a * a;
end;

procedure Nothing; far;
begin
end;

procedure Fill(var Buf; Size: Word);
begin
end;

procedure Sum(const A: array of Integer; var T: Longint);
var k: Integer;
begin
  T := 0;
  for k := 0 to High(A) do T := T + A[k];
end;

procedure Swap2(var A, B: Integer);
var t: Integer;
begin
  t := A; A := B; B := t;
end;

function IsOk(const S: string): Boolean;
begin
  IsOk := (S <> '') and (S[1] = 'x');
end;

constructor TBase.Init(A: Integer);
begin
  N := A;
end;

destructor TBase.Done;
begin
end;

procedure TBase.Show;
begin
  Writeln(N);
end;

function TBase.Get: Integer;
begin
  Get := N;
end;

constructor TKid.Init(A: Integer; B: Longint);
begin
  TBase.Init(A);
  M := B;
end;

procedure TKid.Show;
begin
  inherited Show;
  Writeln(M);
end;

begin
  i := 1; j := i + 2 * 3 - Max div 4;
  l := i; l := l * 1000 + w;
  i := Integer(l);
  b := Byte(i); b := b + 1; b := 255; b := i and $FF;
  w := $FFFF; w := w shr 4; w := Word(l);
  r := i; r := r * 2.5 + l; e := r; r := Sqrt(e) + Sin(r);
  cm := l; l := Round(r);
  i := Trunc(r / 2) + Ord(c) - Ord('a');
  s := 'abc' + c + Esc; s := s + 'x'; s := Copy(s, 1, 2) + Chr(65);
  nm := s; s := nm; c := s[1]; s[1] := 'z'; c := UpCase(c);
  c := #65; c := Chr(i); c := Esc; s := Tab;
  f := (i < 3) and (s = 'x') or not f; f := Odd(i) xor f;
  f := c in ['a'..'z', 'A'..'Z']; f := col in [Red, Blue];
  col := Green; col := Succ(col); col := TColor(i); i := Ord(col);
  cols := [Red, Green]; cols := cols + [Blue] - [Red]; f := Red in cols;
  cols := []; f := cols = [];
  sm := 5; i := sm; sm := i;
  new(p); p^ := 5; i := p^; dispose(p);
  GetMem(ptr, 10); FreeMem(ptr, 10);
  p := @i; p := nil; ptr := p; p := ptr; ptr := @buf;
  pr := @rec; pr^.Name := 'n'; pr^.Age := 3; rec := pr^; rec := Origin;
  rec.I := 3; rec.R := 1.5;
  base.Init(1); kid.Init(1, 2); base := kid; base.Show; i := base.Get;
  pb := New(PKid, Init(1, 2)); pb^.Show; Dispose(pb, Done);
  pb := @kid; pk := PKid(pb);
  buf[0] := 1; buf[i] := Byte(c); pbuf := @buf; pbuf^[1] := 2;
  arr[1] := arr[2] + 1; mat[1, 2] := 1; mat[1][2] := 2; r := mat[i, j];
  FillChar(buf, SizeOf(buf), 0); Fill(buf, 10); Fill(i, 2); Move(buf, buf, 4);
  Swap2(arr[1], arr[2]); Swap2(i, j); Swap2(i, j);
  Sum(arr, l);
  proc := Nothing; proc; fn := Sq; i := fn(3); i := Sq(2);
  if @proc <> nil then proc;
  GotoXY(1, 2); GotoXY(i, j); TextColor(LightGray); ClrScr;
  Writeln('x', i, r:6:2, s); Write(txt, 'a'); Readln(s); Readln(i);
  Assign(txt, 'f.txt'); Reset(txt); Close(txt); Assign(fl, 'f'); Rewrite(fl); Write(fl, i);
  Inc(i); Dec(i, 2); Inc(l); Inc(c); Inc(col);
  Str(i:3, s); Val(s, i, j);
  asc := 'hello'; pc := @asc; pc := 'lit'; s := StrPas(pc);
  reg.AX := $4C00; Intr($21, reg); reg.AH := 1; MsDos(reg);
  GetDate(w, w, w, w); GetTime(w, w, w, w); GetFTime(txt, l); 
  FindFirst('*.*', AnyFile, sr); while DosError = 0 do FindNext(sr);
  i := Mem[$40:$17]; Mem[$B800:0] := 65; w := MemW[$40:0]; Port[$60] := 1; b := Port[$61];
  with rec do begin Name := 'x'; Age := 1; end;
  with base do begin N := 3; Show; end;
  case c of 'a'..'z': i := 1; 'A': i := 2; else i := 0 end;
  case col of Red: i := 1; Green, Blue: i := 2 end;
  case i of 1, 2: j := 1; 3..5: j := 2 end;
  for i := 1 to 10 do ; for c := 'a' to 'z' do ; for col := Red to Blue do ;
  for b := 10 downto 1 do ; for l := 1 to 100000 do ;
  repeat i := i + 1 until i > 5 ; while (i > 0) and not f do Dec(i);
  i := Abs(i) + Sqr(i); r := Abs(r); l := Abs(l); r := Sqr(r);
  w := Swap(w); b := Hi(w); b := Lo(w); w := Seg(i); w := Ofs(i);
  ptr := Ptr($B800, 0); ptr := Addr(i);
  r := Random; i := Random(10); Randomize;
  r := Pi; r := Int(r) + Frac(r); e := Exp(Ln(r));
  l := MemAvail; l := MaxAvail; l := FileSize(fl); l := FilePos(fl);
  f := Eof(txt) or Eoln(txt) or KeyPressed;
  c := ReadKey; i := IOResult; i := ParamCount; s := ParamStr(1);
  s := Concat(s, 'x', c); i := Pos('a', s); Delete(s, 1, 1); Insert('x', s, 1);
  s := GetEnv('PATH'); s := FExpand('x'); s := UpperCase('x');
  halt(0);
end.
