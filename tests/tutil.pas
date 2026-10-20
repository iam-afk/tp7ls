unit tutil;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

function DataDir: string;
function SampleDirs: TStringArray;
function PasFiles(const Dir: string): TStringArray;
function Strs(const A: array of string): TStringArray;
function DataFile(const Name: string): string;
function MakeTempDir: string;
procedure RemoveTree(const Dir: string);
procedure WriteText(const Path, Text: string);
procedure CopyFile(const Src, Dst: string);

implementation

uses
  Classes, tp7enc;

function DataDir: string;
begin
  Result := GetEnvironmentVariable('TP7LS_DATA');
end;

function SampleDirs: TStringArray;
begin
  Result := [ExpandFileName(ExtractFilePath(ParamStr(0)) + '../python/samples')];
  if DataDir <> '' then
    Result := Concat(Result, [DataDir]);
end;

function PasFiles(const Dir: string): TStringArray;
var
  Info: TSearchRec;
begin
  Result := nil;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, Info) = 0 then
  begin
    repeat
      if UpperCase(ExtractFileExt(Info.Name)) = '.PAS' then
        Result := Concat(Result, [IncludeTrailingPathDelimiter(Dir) + Info.Name]);
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
end;

function Strs(const A: array of string): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function DataFile(const Name: string): string;
var
  Info: TSearchRec;
begin
  Result := '';
  if DataDir = '' then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(DataDir) + '*', faAnyFile, Info) = 0 then
  begin
    repeat
      if SameText(Info.Name, Name) then
        Result := IncludeTrailingPathDelimiter(DataDir) + Info.Name;
    until (Result <> '') or (FindNext(Info) <> 0);
    FindClose(Info);
  end;
end;

var
  TempCounter: Integer;

function MakeTempDir: string;
begin
  repeat
    Inc(TempCounter);
    Result := IncludeTrailingPathDelimiter(GetTempDir) + Format('tp7ls-test-%d-%d', [GetProcessID, TempCounter]);
  until not DirectoryExists(Result);
  ForceDirectories(Result);
end;

procedure RemoveTree(const Dir: string);
var
  Info: TSearchRec;
  P: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile or faDirectory, Info) = 0 then
  begin
    repeat
      if (Info.Name = '.') or (Info.Name = '..') then
        Continue;
      P := IncludeTrailingPathDelimiter(Dir) + Info.Name;
      if (Info.Attr and faDirectory) <> 0 then
        RemoveTree(P)
      else
        DeleteFile(P);
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  RemoveDir(Dir);
end;

procedure WriteText(const Path, Text: string);
var
  F: TFileStream;
  Bytes: RawByteString;
begin
  ForceDirectories(ExtractFileDir(Path));
  Bytes := Utf8ToCp866(Text);
  F := TFileStream.Create(Path, fmCreate);
  try
    if Bytes <> '' then
      F.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    F.Free;
  end;
end;

procedure CopyFile(const Src, Dst: string);
var
  Bytes: RawByteString;
  F: TFileStream;
begin
  Bytes := ReadFileBytes(Src);
  F := TFileStream.Create(Dst, fmCreate);
  try
    if Bytes <> '' then
      F.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    F.Free;
  end;
end;

end.
