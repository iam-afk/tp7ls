program good2;
uses Crt, Dos, Graph;
type
  TPt = record X, Y: Integer; end;
  TArr = array[1..5] of TPt;
  PStr = ^string;
  TObj = object
    F: Integer;
    procedure Run(P: Pointer; Cb: Pointer);
  end;
const
  Letters = ['a'..'z'];
  Neg = -32768;
  Mask = $FFFF;
  Big = 70000;
var
  i: Integer; l: Longint; w: Word; b: Byte; s, t: string; c: Char;
  pts: TArr; ps: PStr; o: TObj; gd, gm: Integer; f: Text;
  ok: Boolean; r: Real; sh: ShortInt; code: Integer;
procedure TObj.Run(P: Pointer; Cb: Pointer);
begin
end;
begin
  l := $FFFFFFFF; i := $FFFF; w := $8000; b := $FF; i := Neg; l := Big;
  i := Mask; s := ''; s := s + ''; t := 'a' + 'b'; c := 'a'; s := c; s := 'x' + c + #13#10;
  ok := (s = c) or (c = 'a') or (s <> '') or ('a' < s);
  ok := c in Letters; ok := (i and 1) = 0; ok := Odd(i) and (i > 0);
  pts[1].X := 1; pts[i].Y := pts[i - 1].X + 2; pts[1] := pts[2];
  New(ps); ps^ := 'abc'; ps^[1] := 'x'; s := ps^; Dispose(ps);
  o.Run(@i, nil); o.Run(ps, @o);
  gd := Detect; InitGraph(gd, gm, ''); SetColor(15); Line(0, 0, 10, 10); Circle(i, i, 5);
  OutTextXY(1, 2, s); SetFillStyle(SolidFill, 4); Bar(0, 0, 5, 5); CloseGraph;
  i := GetMaxX + GetMaxY; w := GetColor; r := i / 2; r := r + i; r := Round(r) * 1.5;
  Val(s, i, code); if code <> 0 then Halt(1); Str(r:0:2, s);
  sh := -5; i := sh; sh := i; b := w; w := b; l := w * w; l := Longint(w) * w;
  Assign(f, 'x'); {$I-} Reset(f); {$I+} if IOResult <> 0 then Exit;
  while not Eof(f) do begin Readln(f, s); Writeln(s); end;
  Close(f);
  i := Ord(s[1]) - 48; c := Chr(i + 48); s[0] := Chr(3); b := Ord(s[0]);
  i := Length(s); b := Length(s); i := Pos(' ', s);
  if (i >= 1) and (i <= Length(s)) then s := Copy(s, i, 1);
  repeat Inc(i) until (i > 10) or KeyPressed;
  l := MemL[0:0]; b := Mem[0:0]; Port[$3C8] := 0; b := Port[$3C9];
  i := Trunc(Frac(r) * 10); l := Trunc(Int(r)); w := Round(r) mod 7; i := i mod 3 + i div 3;
end.
