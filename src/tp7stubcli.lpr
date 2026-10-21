program tp7stubcli;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, tp7os, tp7sema, tp7stub, tpudump;

var
  Output: string;

procedure Put(const S: string);
begin
  Output := Output + S;
end;

procedure DumpStub(St: TStub);
var
  I: Integer;
  E: TStubEntry;
  Kind: string;
begin
  for I := 0 to St.Count - 1 do
  begin
    E := St.Entry(I);
    Put(Format('ENTRY %s|%s|%s %d %d %d'#10, [E.Kind, E.Owner, E.Name, E.Line, E.Col, E.Len]));
    Kind := E.Kind;
    if Kind = 'method' then
      Kind := 'routine';
    Put('DECL ' + St.Declaration(Kind, E.Name, E.Owner) + #10);
    Put('BLOCK ' + IntToStr(Length(St.Block(Kind, E.Name, E.Owner))) + #10);
  end;
end;

var
  Path, Lib, Cand, Only, Home, K: string;
  I, N: Integer;
  Dump: Boolean;
  Images, LibCopy, Deps: TImages;
  Prov: TProvider;
  Loader: TLoader;
  St: TStub;
  Std: THandleStream;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: tp7stub FILE.TPU|FILE.TPL [UNIT] [--lib LIB.TPL] [--dump]');
    Halt(1);
  end;
  Path := ParamStr(1);
  Lib := '';
  Dump := False;
  for I := 2 to ParamCount do
    if (ParamStr(I) = '--lib') and (I < ParamCount) then
      Lib := ParamStr(I + 1)
    else if ParamStr(I) = '--dump' then
      Dump := True;
  if Lib = '' then
  begin
    Cand := JoinPath(DirName(AbsPath(Path)), 'TURBO.TPL');
    if (FileExists(Cand) or DirectoryExists(Cand)) and (AbsPath(Cand) <> AbsPath(Path)) then
      Lib := Cand;
  end;
  Home := DirName(AbsPath(Path));
  Images := ReadImages(Path);
  N := Length(Images);
  LibCopy := nil;
  if Lib <> '' then
  begin
    Images := Concat(Images, ReadImages(Lib));
    LibCopy := ReadImages(Lib);
  end;
  Prov := TProvider.Create([Home]);
  Prov.LibImages := LibCopy;
  Deps := Prov.TpuDependencies(Images, Home);
  Loader := TLoader.Create(Concat(Images, Deps), N);
  Only := '';
  for I := 2 to ParamCount do
    if (Copy(ParamStr(I), 1, 2) <> '--') and (ParamStr(I) <> Lib) then
    begin
      Only := LowerCase(ParamStr(I));
      Break;
    end;
  Output := '';
  for K in Loader.Primary do
    if (Only = '') or (Only = K) then
    begin
      St := Render(Loader.FindUnit(K), AbsPath(Path));
      Put(St.Text);
      if Dump then
        DumpStub(St);
      St.Free;
    end;
  Std := THandleStream.Create(StdOutputHandle);
  try
    if Output <> '' then
      Std.WriteBuffer(Output[1], Length(Output));
  finally
    Std.Free;
  end;
  Loader.Free;
  Prov.Free;
  FreeImages(Images);
  FreeImages(LibCopy);
end.
