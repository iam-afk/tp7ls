program tp7typescli;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, tp7enc, tp7lex, tp7parse, tp7sema, tp7types, tp7os;

type
  TCollect = class
  public
    Src: string;
    Lines: TStringList;
    procedure Report(Tok: TToken; const Msg: string);
  end;

var
  C: TCollect;

function Escape(const S: string): string;
var
  Bytes: RawByteString;
  Ch: Char;
begin
  Bytes := Utf8ToCp866(S);
  Result := '';
  for Ch in Bytes do
    if (Ch >= ' ') and (Ch <= '~') and (Ch <> '\') then
      Result := Result + Ch
    else
      Result := Result + '\x' + IntToHex(Ord(Ch), 2);
end;

function Pos_(T: TToken): string;
begin
  if T.FileName <> '' then
    Result := BaseName(T.FileName) + ' L' + IntToStr(T.Line)
  else
    Result := IntToStr(T.Line) + ':' + IntToStr(Utf8Length(C.Src, T.Pos - T.Col + 1, T.Pos - 1) + 1);
end;

procedure TCollect.Report(Tok: TToken; const Msg: string);
begin
  Lines.Add('PROBLEM ' + Pos_(Tok) + ' ' + Escape(Msg));
end;

var
  Path, Tpl, Text: string;
  Dirs: TStringArray;
  I: Integer;
  Prov: TProvider;
  Res: TParseResult;
  B: TBinder;
  Inl: TInlayData;
  Types: TTypes;
  Refs: TBinderRefs;
  T: TToken;
  Sym: TSym;
  Ty: TTy;
  At: TExprAt;
begin
  Path := '';
  Tpl := '';
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
    else if ParamStr(I) <> '--dump' then
      Path := ParamStr(I);
    Inc(I);
  end;
  if Path = '' then
  begin
    WriteLn('usage: tp7types --dump FILE.PAS [--path DIR]... [--tpl TURBO.TPL]');
    Halt(1);
  end;
  C := TCollect.Create;
  C.Lines := TStringList.Create;
  Prov := TProvider.Create(Concat([DirName(Path)], Dirs), Tpl);
  C.Src := ReadSource(Path);
  Res := Parse(C.Src, DefaultDefines, Prov.IncludeResolver(Path), Path);
  B := TBinder.Create(Res, Prov);
  try
    B.Run;
  except
    on EBroken do
    begin
      C.Lines.Add('BIND EXCEPTION');
      Write(C.Lines.Text);
      Halt(0);
    end;
  end;
  try
    CheckTypes(Res, B, Prov, @C.Report);
  except
    on EBroken do
      C.Lines.Add('EXCEPTION');
  end;
  try
    Inl := InlayData(Res, B, Prov);
    for I := 0 to High(Inl.Params) do
      C.Lines.Add('PARAM ' + Pos_(Inl.Params[I].Tok) + ' ' + Escape(Inl.Params[I].Text));
    for I := 0 to High(Inl.Consts) do
      C.Lines.Add('CONST ' + Pos_(Inl.Consts[I].Tok) + ' ' + Escape(Inl.Consts[I].Text));
    for I := 0 to High(Inl.Ends) do
      C.Lines.Add('END ' + Pos_(Inl.Ends[I].Tok) + ' ' + Escape(Inl.Ends[I].Name) + ' ' + IntToStr(Inl.Ends[I].Lines));
  except
    on EBroken do
      C.Lines.Add('INLAY EXCEPTION');
  end;
  Types := TTypes.Create(Prov);
  for T in Res.Sig do
  begin
    Sym := TSym(B.Refs.Get(T));
    if Sym = nil then
      Continue;
    try
      if Sym.Kind = skType then
        Ty := Types.OfTypeSym(Sym)
      else
        Ty := Types.OfSym(Sym);
      Text := TypeText(Ty);
    except
      on EBroken do
        Text := '<exception>';
    end;
    C.Lines.Add('TYPE ' + Pos_(T) + ' ' + Escape(T.Text) + ': ' + Escape(Text));
  end;
  Types.Free;
  Refs := TBinderRefs.Create(B);
  for T in Res.DocSig do
  begin
    if not (T.Kind in [tkSym, tkKW]) then
      Continue;
    try
      At := ExprAt(Res.Tree, Refs, Prov, T);
    except
      on EBroken do
      begin
        C.Lines.Add('EXPR ' + Pos_(T) + ' <exception>');
        Continue;
      end;
    end;
    if At = nil then
      Continue;
    Text := TypeText(At.Ty);
    if (At.Ty.Kind = tyInt) and At.Ty.HasValue then
      Text := ConstTypeName(At.Ty) + ' = ' + IntToStr(At.Ty.Value);
    C.Lines.Add('EXPR ' + Pos_(T) + ' ' + Escape(T.Text) + ' ' + Pos_(At.Tokens[0]) + '-' +
      Pos_(At.Tokens[High(At.Tokens)]) + ': ' + Escape(Text) + BoolToStr(At.Ty = FloatTy, ' float', ''));
    At.Free;
  end;
  Refs.Free;
  Write(C.Lines.Text);
  B.Free;
  Res.Free;
  Prov.Free;
  C.Lines.Free;
  C.Free;
end.
