unit Polsk;

interface

function NextChar(var str: string): string;

function pr(n: string): integer;

function rang(t: string): integer;

function PushStrInPol(str: string): string;

function PopStrInPol(str: string): string;

implementation

type
  ts = array [1..30] of string;

var
  s: ts;
  r: integer;
  n: string;
  top: integer;
  p: string;
  i: integer;
  t: string;
  correct: boolean;

function NextChar;
var
  k: integer;
begin
  if str[1] in ['А'..'Я'] then
  begin
    k := 1;
    while str[k] in ['А'..'Я'] do
      inc(k);
    NextChar := copy(str, 1, k - 1);
    delete(str, 1, k - 1);
  end
  else
  begin
    NextChar := str[1];
    delete(str, 1, 1);
  end;
end;

function pr;
begin
  case n[1] of
    '+', '-': pr := 1;
    '*', '/': pr := 2;
    '#': pr := 0;
    else pr := 3;
  end;
end;

function rang;
begin
  case t[1] of
    '+', '-', '*', '/': rang := -1;
    else rang := 1;
  end;
end;

function PushStrInPol;
label
  1;
begin
  str := str + '#';
  correct := true;
  top := 1;
  s[top] := '#';
  r := 0;
  i := 0;
  n := NextChar(str);
  while n <> '#' do
  begin
    while pr(n) <= pr(s[top]) do
    begin
      inc(i);
      t := s[top];
      dec(top);
      p := p + t + ',';
      r := r + rang(t);
      if r < 1 then
      begin
        correct := false;
        exit;
      end;
    end;
    inc(top);
    s[top] := n;
    n := Nextchar(str);
  end;
  while s[top] <> '#' do
  begin
    inc(i);
    t := s[top];
    dec(top);
    p := p + t + ',';
    r := r + rang(t);
    if r < 1 then
    begin
      correct := false;
      exit;
    end;
  end;
  if r = 1 then
    PushStrInPol := p
  else
    correct := false;
end;

function PopStrInPol;
begin
end;

end.