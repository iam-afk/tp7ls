unit tutil;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

function DataDir: string;
function SampleDirs: TStringArray;
function PasFiles(const Dir: string): TStringArray;

implementation

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

end.
