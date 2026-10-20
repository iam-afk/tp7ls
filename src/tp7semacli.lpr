program tp7semacli;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, tp7enc, tp7lex, tp7parse, tp7sema, tp7os;

var
  Path, Tpl, Mode, Src: string;
  Dirs: TStringArray;
  I: Integer;
  Prov: TProvider;
  Res: TParseResult;
  B: TBinder;
  Rep: TReport;
  Lines: TStringList;

function Escape(const S: string): string;
var
  Bytes: RawByteString;
  C: Char;
begin
  Bytes := Utf8ToCp866(S);
  Result := '';
  for C in Bytes do
    if (C >= ' ') and (C <= '~') and (C <> '\') then
      Result := Result + C
    else
      Result := Result + '\x' + IntToHex(Ord(C), 2);
end;

function Pos_(T: TToken): string;
begin
  if T.FileName <> '' then
    Result := BaseName(T.FileName) + ' L' + IntToStr(T.Line)
  else
    Result := IntToStr(T.Line) + ':' + IntToStr(Utf8Length(Res.Source, T.Pos - T.Col + 1, T.Pos - 1) + 1);
end;

function Where(S: TSym): string;
begin
  if S.Tok <> nil then
  begin
    Result := 'L' + IntToStr(S.Tok.Line);
    if (S.FileName <> '') and (AbsPath(S.FileName) <> AbsPath(Path)) then
      Result := Result + ' ' + BaseName(S.FileName);
  end
  else if S.Kind = skUnit then
  begin
    if S.FileName <> '' then
      Result := 'unit:' + BaseName(S.FileName)
    else
      Result := 'unit:lib';
  end
  else if S.Lib then
  begin
    if S.Home <> '' then
      Result := '@' + S.Home
    else
      Result := '@?';
  end
  else if S.Implicit then
    Result := 'self'
  else
    Result := '-';
  Result := SymKindNames[S.Kind] + ' ' + Escape(S.Name) + ' ' + Result;
end;

procedure Dump;
var
  T: TToken;
  S: TObject;
  D: TDup;
begin
  for T in Res.Sig do
  begin
    S := B.Refs.Get(T);
    if S <> nil then
      Lines.Add('REF ' + Pos_(T) + ' ' + Escape(T.Text) + ' -> ' + Where(TSym(S)));
  end;
  for T in Res.Sig do
  begin
    S := B.Decls.Get(T);
    if S <> nil then
      Lines.Add('DECL ' + Pos_(T) + ' ' + Escape(T.Text) + ' -> ' + Where(TSym(S)));
  end;
  for T in B.Unresolved do
    Lines.Add('UNRESOLVED ' + Pos_(T) + ' ' + Escape(T.Text));
  for T in B.Uncertain do
    Lines.Add('UNCERTAIN ' + Pos_(T) + ' ' + Escape(T.Text));
  for T in B.MissingUnits do
    Lines.Add('MISSING ' + Pos_(T) + ' ' + Escape(T.Text));
  for D in B.Dups do
    Lines.Add('DUP ' + Pos_(D.Tok) + ' ' + Escape(D.Tok.Text) + ' -> ' + Where(D.Old));
  Lines.Add('RENAMED ' + IntToStr(B.Renamed));
  Lines.Add('ERRORS ' + IntToStr(Prov.Errors.Count));
  Lines.Add('TEXT ' + Escape(Reconstruct(Res)));
end;

procedure Summary;
var
  Missing, Names: TStringList;
  T: TToken;
  S: string;
begin
  Missing := TStringList.Create;
  Names := TStringList.Create;
  try
    Missing.Sorted := True;
    Missing.Duplicates := dupIgnore;
    Missing.CaseSensitive := True;
    for T in Rep.MissingUnits do
      Missing.Add(T.Text);
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;
    Names.CaseSensitive := True;
    for T in Rep.Unresolved do
      Names.Add(LowerText(T.Text));
    S := '';
    for I := 0 to Missing.Count - 1 do
    begin
      if S <> '' then
        S := S + ', ';
      S := S + Missing[I];
    end;
    if S = '' then
      S := '-';
    Lines.Add(Format('renamed %d identifiers; unresolved %d; uncertain %d; units not found: %s',
      [Rep.Renamed, Length(Rep.Unresolved), Length(Rep.Uncertain), S]));
    S := '';
    for I := 0 to Names.Count - 1 do
      if I < 80 then
        S := S + ' ' + Names[I];
    Lines.Add('unresolved names:' + S);
  finally
    Missing.Free;
    Names.Free;
  end;
end;

begin
  Path := '';
  Tpl := '';
  Mode := '';
  Dirs := nil;
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '--path') and (I < ParamCount) then
    begin
      Inc(I);
      Dirs := Concat(Dirs, [ParamStr(I)]);
    end
    else if (ParamStr(I) = '--tpl') and (I < ParamCount) then
    begin
      Inc(I);
      Tpl := ParamStr(I);
    end
    else if ParamStr(I) = '--dump' then
      Mode := '--dump'
    else
      Path := ParamStr(I);
    Inc(I);
  end;
  if Path = '' then
  begin
    WriteLn('usage: tp7sema FILE.PAS [--path DIR]... [--tpl TURBO.TPL] [--dump]');
    Halt(1);
  end;
  if Dirs = nil then
    Dirs := [DirName(AbsPath(Path))];
  Lines := TStringList.Create;
  Prov := TProvider.Create(Dirs, Tpl);
  try
    Src := ReadSource(Path);
    if Mode = '--dump' then
      Res := Parse(Src, DefaultDefines, Prov.IncludeResolver(Path), Path)
    else
      Res := Parse(Src);
    Rep := NormalizeCaseKeep(Res, Prov, B);
    if Mode = '--dump' then
      Dump
    else
      Summary;
    Write(Lines.Text);
    B.Free;
    Res.Free;
  finally
    Prov.Free;
    Lines.Free;
  end;
end.
