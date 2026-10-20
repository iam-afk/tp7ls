program bad;
uses Crt, Dos;
type
  TColor = (Red, Green, Blue);
  TPoint = record X, Y: Integer; end;
  PPoint = ^TPoint;
  TBase = object
    N: Integer;
    constructor Init(A: Integer);
    procedure Show; virtual;
  end;
  TKid = object(TBase)
    procedure Show; virtual;
  end;
const
  Max = 100;
  Name = 'abc';
var
  i, j: Integer;
  b: Byte;
  w: Word;
  r: Real;
  s: string;
  c: Char;
  f: Boolean;
  col: TColor;
  p: TPoint;
  pp: PPoint;
  base: TBase;
  kid: TKid;
  arr: array[1..10] of Integer;
  m: array[TColor] of Byte;

procedure Take(var x: Integer; y: Word; const z: string);
begin
end;

function Half(x: Integer): Real;
begin
  Half := x / 2;
end;

constructor TBase.Init(A: Integer);
begin
  N := A;
end;

procedure TBase.Show;
begin
end;

procedure TKid.Show;
begin
end;

begin
  i := 'text';            { 1 string to integer }
  s := 5;                 { 2 integer to string }
  f := 1;                 { 3 integer to boolean }
  i := r;                 { 4 real to integer }
  r := i;                 { ok }
  b := 300;               { 5 out of range }
  b := -1;                { 6 out of range }
  w := 65535;             { ok }
  c := 65;                { 7 integer to char }
  col := 1;               { 8 integer to enum }
  col := Green;           { ok }
  i := Max;               { ok }
  Max := 5;               { 9 assign to const }
  p := i;                 { 10 integer to record }
  if i then i := 1;       { 11 non-boolean }
  while s do ;            { 12 }
  repeat until r;         { 13 }
  for r := 1 to 3 do ;    { 14 real loop var }
  for c := 'a' to 'z' do ;{ ok }
  for i := 'a' to 3 do ;  { 15 }
  case r of 1: ; end;     { 16 real selector }
  i := i + 'x';           { 17 }
  i := f + 1;             { 18 }
  i := 7 / 2;             { 19 real to int }
  i := 7 div 2;           { ok }
  f := i and f;           { 20 }
  f := (i = s);           { 21 compare }
  f := (col = 1);         { 22 compare enum int }
  f := i in [1, 2];       { 23? in needs set: ok here actually }
  i := col + 1;           { 24 }
  Take(i, w, s);          { ok }
  Take(w, w, s);          { 25 var param type }
  Take(5, w, s);          { 26 var needs variable }
  Take(i, w);             { 27 not enough }
  Take(i, w, s, s);       { 28 too many }
  Take(i, s, s);          { 29 string to word }
  Take(i, w, 5);          { 30 int to string }
  Take(Max, w, s);        { 31 const to var }
  r := Half(3);           { ok }
  i := Half(3);           { 32 real to int }
  r := Half;              { 33 not enough }
  pp := @p;               { ok }
  pp := nil;              { ok }
  pp^ := p;               { ok }
  pp^ := i;               { 34 }
  p.X := 'a';             { 35 }
  p.Q := 1;               { unknown field: binder }
  arr[1] := 'a';          { 36 }
  arr['a'] := 1;          { 37 index }
  m[Red] := 1;            { ok }
  m[1] := 1;              { 38 index type }
  s[1] := 'a';            { ok }
  s[1] := 5;              { 39 }
  i[1] := 1;              { 40 not indexable }
  i^ := 1;                { 41 not pointer }
  base := kid;            { ok? object to ancestor - ok in TP }
  kid := base;            { 42 }
  base.Init('a');         { 43 }
  base.Init(1, 2);        { 44 }
  s := s + c;             { ok }
  s := s + 1;             { 45 }
  i := Length(s);         { ok }
  s := Copy(s, 1, 2);     { ok }
  c := UpCase(c);         { ok }
  i := Ord(c);            { ok }
  c := Chr(i);            { ok }
  i := Round(r);          { ok }
  i := Trunc(r);          { ok }
  w := i;                 { ok }
  i := w;                 { ok }
  b := Length(s);         { ok }
  GotoXY(1, 2);           { ok }
  GotoXY('a', 2);         { 46 }
  GotoXY(1);              { 47 }
  ClrScr;                 { ok }
  ClrScr(1);              { 48 }
  writeln(i:3, r:5:2, s);{ ok }
end.
