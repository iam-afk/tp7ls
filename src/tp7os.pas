unit tp7os;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TStamp = record
    Exists: Boolean;
    Size: Int64;
    MTimeNs: Int64;
  end;

function Stamp(const Path: string): TStamp;
function SameStamp(const A, B: TStamp): Boolean;
function ListDir(const Dir: string; out Names: TStringArray): Boolean;
function IsFile(const Path: string): Boolean;
function IsDir(const Path: string): Boolean;
function IsLink(const Path: string): Boolean;
function AbsPath(const Path: string): string;
function DirName(const Path: string): string;
function BaseName(const Path: string): string;
function JoinPath(const A, B: string): string;
procedure SplitExt(const Path: string; out Root, Ext: string);
function ExtOf(const Path: string): string;
function NormCase(const Path: string): string;
function MonotonicSeconds: Double;
procedure SortStrings(var A: TStringArray);

implementation

uses
{$IFDEF UNIX}
  BaseUnix,
{$ENDIF}
  Classes;

function IsSep(C: Char): Boolean;
begin
  Result := (C = '/') or (C = DirectorySeparator);
end;

function Stamp(const Path: string): TStamp;
{$IFDEF UNIX}
var
  St: Stat;
begin
  Result.Exists := FpStat(Path, St) = 0;
  if Result.Exists then
  begin
    Result.Size := St.st_size;
    Result.MTimeNs := Int64(St.st_mtime) * 1000000000 + St.st_mtime_nsec;
  end
  else
  begin
    Result.Size := 0;
    Result.MTimeNs := 0;
  end;
end;
{$ELSE}
var
  Info: TSearchRec;
begin
  Result.Exists := FindFirst(Path, faAnyFile or faDirectory, Info) = 0;
  Result.Size := 0;
  Result.MTimeNs := 0;
  if Result.Exists then
  begin
    Result.Size := Info.Size;
    Result.MTimeNs := Int64(Info.Time) * 1000000000;
    FindClose(Info);
  end;
end;
{$ENDIF}

function SameStamp(const A, B: TStamp): Boolean;
begin
  Result := (A.Exists = B.Exists) and (A.Size = B.Size) and (A.MTimeNs = B.MTimeNs);
end;

function ListDir(const Dir: string; out Names: TStringArray): Boolean;
var
  Info: TSearchRec;
begin
  Names := nil;
  if not IsDir(Dir) then
    Exit(False);
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile or faDirectory, Info) = 0 then
  begin
    repeat
      if (Info.Name <> '.') and (Info.Name <> '..') then
      begin
        SetLength(Names, Length(Names) + 1);
        Names[High(Names)] := Info.Name;
      end;
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  Result := True;
end;

function IsFile(const Path: string): Boolean;
begin
  Result := FileExists(Path) and not DirectoryExists(Path);
end;

function IsDir(const Path: string): Boolean;
begin
  Result := DirectoryExists(Path);
end;

function IsLink(const Path: string): Boolean;
{$IFDEF UNIX}
var
  St: Stat;
begin
  Result := (FpLstat(Path, St) = 0) and fpS_ISLNK(St.st_mode);
end;
{$ELSE}
begin
  Result := False;
end;
{$ENDIF}

function AbsPath(const Path: string): string;
begin
  if Path = '' then
    Result := ExcludeTrailingPathDelimiter(GetCurrentDir)
  else
    Result := ExpandFileName(Path);
  while (Length(Result) > 1) and (Result[Length(Result)] = DirectorySeparator) do
    SetLength(Result, Length(Result) - 1);
end;

function DirName(const Path: string): string;
var
  I: SizeInt;
  Head: string;
begin
  I := Length(Path);
  while (I > 0) and not IsSep(Path[I]) do
    Dec(I);
  Head := Copy(Path, 1, I);
  if (Head <> '') and (Head <> StringOfChar('/', Length(Head))) then
    while (Head <> '') and (IsSep(Head[Length(Head)])) do
      SetLength(Head, Length(Head) - 1);
  Result := Head;
end;

function BaseName(const Path: string): string;
var
  I: SizeInt;
begin
  I := Length(Path);
  while (I > 0) and not IsSep(Path[I]) do
    Dec(I);
  Result := Copy(Path, I + 1, MaxInt);
end;

function JoinPath(const A, B: string): string;
begin
  if (B <> '') and IsSep(B[1]) then
    Exit(B);
  if (A = '') or IsSep(A[Length(A)]) then
    Result := A + B
  else
    Result := A + DirectorySeparator + B;
end;

procedure SplitExt(const Path: string; out Root, Ext: string);
var
  Sep, Dot, I: SizeInt;
begin
  Sep := 0;
  for I := Length(Path) downto 1 do
    if IsSep(Path[I]) then
    begin
      Sep := I;
      Break;
    end;
  Dot := 0;
  for I := Length(Path) downto Sep + 1 do
    if Path[I] = '.' then
    begin
      Dot := I;
      Break;
    end;
  Root := Path;
  Ext := '';
  if Dot = 0 then
    Exit;
  for I := Sep + 1 to Dot - 1 do
    if Path[I] <> '.' then
    begin
      Root := Copy(Path, 1, Dot - 1);
      Ext := Copy(Path, Dot, MaxInt);
      Exit;
    end;
end;

function ExtOf(const Path: string): string;
var
  Root: string;
begin
  SplitExt(Path, Root, Result);
end;

function NormCase(const Path: string): string;
begin
{$IFDEF WINDOWS}
  Result := LowerCase(StringReplace(Path, '/', '\', [rfReplaceAll]));
{$ELSE}
  Result := Path;
{$ENDIF}
end;

function MonotonicSeconds: Double;
begin
  Result := GetTickCount64 / 1000.0;
end;

procedure SortStrings(var A: TStringArray);
var
  I, J: Integer;
  T: string;
begin
  for I := 1 to High(A) do
  begin
    T := A[I];
    J := I - 1;
    while (J >= 0) and (CompareStr(A[J], T) > 0) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := T;
  end;
end;

end.
