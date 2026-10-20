unit tp7index;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

const
  MaxIndexFiles = 5000;

type
  TDirEntry = record
    Name, Full: string;
  end;

  TDirEntries = array of TDirEntry;

  TDirInfo = record
    Key: string;
    MTimeNs: Int64;
    Entries: TDirEntries;
  end;

  TPathList = record
    Key: string;
    Paths: TStringArray;
  end;

  TPathLists = array of TPathList;

  TProjectIndex = class
  private
    FDirs: array of TDirInfo;
    FUnits: TPathLists;
    FFiles: TPathLists;
    FSources: TStringArray;
    FChecked: Double;
    FLock: TCriticalSection;
    function DirIndex(const Key: string): Integer;
    procedure Rebuild(const Live: TStringArray);
    function Ranked(const Paths: TStringArray; const Near: string): TStringArray;
  public
    Roots: TStringArray;
    MaxFiles: Integer;
    Throttle: Double;
    Generation: Integer;
    Truncated: Boolean;
    constructor Create(const ARoots: array of string; AMaxFiles: Integer = MaxIndexFiles; AThrottle: Double = 1.0);
    destructor Destroy; override;
    procedure Invalidate;
    procedure Refresh(Force: Boolean = False);
    function FindUnit(const Name, Ext: string; const Near: string = ''): string;
    function FindUnitAll(const Name, Ext: string; const Near: string = ''): TStringArray;
    function FindFile(const Rel: string; const Near: string = ''): string;
    function UnitNames: TStringArray;
    function Sources: TStringArray;
    function Duplicates: TPathLists;
  end;

function Distance(const Path, Near: string): Integer;

implementation

uses
  tp7enc, tp7os;

function NormPath(const P: string): string;
begin
  Result := NormCase(AbsPath(P));
end;

function FindList(const L: TPathLists; const Key: string): Integer;
begin
  for Result := 0 to High(L) do
    if L[Result].Key = Key then
      Exit;
  Result := -1;
end;

procedure AddToList(var L: TPathLists; const Key, Path: string);
var
  I: Integer;
begin
  I := FindList(L, Key);
  if I < 0 then
  begin
    SetLength(L, Length(L) + 1);
    I := High(L);
    L[I].Key := Key;
  end;
  SetLength(L[I].Paths, Length(L[I].Paths) + 1);
  L[I].Paths[High(L[I].Paths)] := Path;
end;

function SplitSep(const S: string): TStringArray;
begin
  Result := S.Split([DirectorySeparator]);
end;

function Distance(const Path, Near: string): Integer;
var
  A, B: TStringArray;
  I: Integer;
begin
  if Near = '' then
    Exit(0);
  A := SplitSep(NormPath(DirName(Path)));
  B := SplitSep(NormPath(DirName(AbsPath(Near))));
  I := 0;
  while (I < Length(A)) and (I < Length(B)) and (A[I] = B[I]) do
    Inc(I);
  Result := (Length(A) - I) + (Length(B) - I);
end;

constructor TProjectIndex.Create(const ARoots: array of string; AMaxFiles: Integer; AThrottle: Double);
var
  R: string;
begin
  Roots := nil;
  for R in ARoots do
  begin
    SetLength(Roots, Length(Roots) + 1);
    Roots[High(Roots)] := AbsPath(R);
  end;
  MaxFiles := AMaxFiles;
  Throttle := AThrottle;
  FLock := TCriticalSection.Create;
end;

destructor TProjectIndex.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TProjectIndex.Invalidate;
begin
  FChecked := 0;
end;

function TProjectIndex.DirIndex(const Key: string): Integer;
begin
  for Result := 0 to High(FDirs) do
    if FDirs[Result].Key = Key then
      Exit;
  Result := -1;
end;

procedure TProjectIndex.Refresh(Force: Boolean);
var
  Now: Double;
  Changed, Stop: Boolean;
  Seen, Stack, Names: TStringArray;
  Count, K, I: Integer;
  D, Key, N, Full: string;
  St: TStamp;
  Kept: array of TDirInfo;

  function WasSeen(const X: string): Boolean;
  var
    Y: string;
  begin
    for Y in Seen do
      if Y = X then
        Exit(True);
    Result := False;
  end;

begin
  Now := MonotonicSeconds;
  FLock.Acquire;
  try
    if not Force and (FChecked <> 0) and (Now - FChecked < Throttle) then
      Exit;
    FChecked := Now;
    if FChecked = 0 then
      FChecked := 1e-9;
    Changed := False;
    Seen := nil;
    Count := 0;
    Stack := Copy(Roots);
    Truncated := False;
    while Stack <> nil do
    begin
      D := Stack[High(Stack)];
      SetLength(Stack, Length(Stack) - 1);
      St := Stamp(D);
      if not St.Exists then
        Continue;
      Key := NormPath(D);
      if WasSeen(Key) then
        Continue;
      SetLength(Seen, Length(Seen) + 1);
      Seen[High(Seen)] := Key;
      K := DirIndex(Key);
      if (K < 0) or (FDirs[K].MTimeNs <> St.MTimeNs) then
      begin
        if not ListDir(D, Names) then
          Names := nil;
        SortStrings(Names);
        if K < 0 then
        begin
          SetLength(FDirs, Length(FDirs) + 1);
          K := High(FDirs);
          FDirs[K].Key := Key;
        end;
        FDirs[K].MTimeNs := St.MTimeNs;
        FDirs[K].Entries := nil;
        SetLength(FDirs[K].Entries, Length(Names));
        for I := 0 to High(Names) do
        begin
          FDirs[K].Entries[I].Name := Names[I];
          FDirs[K].Entries[I].Full := JoinPath(D, Names[I]);
        end;
        Changed := True;
      end;
      Stop := False;
      for I := 0 to High(FDirs[K].Entries) do
      begin
        N := FDirs[K].Entries[I].Name;
        Full := FDirs[K].Entries[I].Full;
        if (Copy(N, 1, 1) = '.') or (N = 'node_modules') or (N = '__pycache__') then
          Continue;
        if IsDir(Full) then
        begin
          if not IsLink(Full) then
          begin
            SetLength(Stack, Length(Stack) + 1);
            Stack[High(Stack)] := Full;
          end;
          Continue;
        end;
        Inc(Count);
        if Count > MaxFiles then
        begin
          Truncated := True;
          Stack := nil;
          Stop := True;
          Break;
        end;
      end;
      if Stop then
        Break;
    end;
    Kept := nil;
    for I := 0 to High(FDirs) do
      if WasSeen(FDirs[I].Key) then
      begin
        SetLength(Kept, Length(Kept) + 1);
        Kept[High(Kept)] := FDirs[I];
      end
      else
        Changed := True;
    FDirs := Kept;
    if Changed or ((FUnits = nil) and (FFiles = nil)) then
    begin
      Rebuild(Seen);
      Inc(Generation);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TProjectIndex.Rebuild(const Live: TStringArray);
var
  Keys: TStringArray;
  Key, Root, Ext, T: string;
  K, I, J: Integer;
  E: TDirEntry;

  function Before(const A, B: string): Boolean;
  var
    XA, XB: Boolean;
  begin
    XA := LowerText(ExtOf(A)) <> '.pas';
    XB := LowerText(ExtOf(B)) <> '.pas';
    if XA <> XB then
      Exit(not XA);
    Result := CompareStr(LowerText(A), LowerText(B)) < 0;
  end;

begin
  FUnits := nil;
  FFiles := nil;
  FSources := nil;
  Keys := Copy(Live);
  SortStrings(Keys);
  for Key in Keys do
  begin
    K := DirIndex(Key);
    if K < 0 then
      Continue;
    for E in FDirs[K].Entries do
    begin
      if Copy(E.Name, 1, 1) = '.' then
        Continue;
      SplitExt(E.Name, Root, Ext);
      Ext := LowerText(Ext);
      if ((Ext = '.pas') or (Ext = '.tpu')) and IsFile(E.Full) then
        AddToList(FUnits, LowerText(Root), E.Full);
      if (Ext = '.pas') and IsFile(E.Full) then
      begin
        SetLength(FSources, Length(FSources) + 1);
        FSources[High(FSources)] := E.Full;
      end;
      if (Ext = '.inc') or (Ext = '.pas') then
        AddToList(FFiles, LowerText(E.Name), E.Full);
    end;
  end;
  for K := 0 to High(FUnits) do
    for I := 1 to High(FUnits[K].Paths) do
    begin
      T := FUnits[K].Paths[I];
      J := I - 1;
      while (J >= 0) and Before(T, FUnits[K].Paths[J]) do
      begin
        FUnits[K].Paths[J + 1] := FUnits[K].Paths[J];
        Dec(J);
      end;
      FUnits[K].Paths[J + 1] := T;
    end;
end;

function TProjectIndex.Ranked(const Paths: TStringArray; const Near: string): TStringArray;
var
  Dist: array of Integer;
  I, J, TD: Integer;
  T: string;

  function Before(DA: Integer; const A: string; DB: Integer; const B: string): Boolean;
  var
    XA, XB: Boolean;
  begin
    if DA <> DB then
      Exit(DA < DB);
    XA := LowerText(ExtOf(A)) <> '.pas';
    XB := LowerText(ExtOf(B)) <> '.pas';
    if XA <> XB then
      Exit(not XA);
    Result := CompareStr(LowerText(A), LowerText(B)) < 0;
  end;

begin
  Result := Copy(Paths);
  Dist := nil;
  SetLength(Dist, Length(Result));
  for I := 0 to High(Result) do
    Dist[I] := Distance(Result[I], Near);
  for I := 1 to High(Result) do
  begin
    T := Result[I];
    TD := Dist[I];
    J := I - 1;
    while (J >= 0) and Before(TD, T, Dist[J], Result[J]) do
    begin
      Result[J + 1] := Result[J];
      Dist[J + 1] := Dist[J];
      Dec(J);
    end;
    Result[J + 1] := T;
    Dist[J + 1] := TD;
  end;
end;

function EndsWithText(const S, Suffix: string): Boolean;
begin
  Result := (Length(S) >= Length(Suffix)) and (Copy(S, Length(S) - Length(Suffix) + 1, MaxInt) = Suffix);
end;

function TProjectIndex.FindUnit(const Name, Ext: string; const Near: string): string;
var
  All: TStringArray;
begin
  All := FindUnitAll(Name, Ext, Near);
  if All = nil then
    Result := ''
  else
    Result := All[0];
end;

function TProjectIndex.FindUnitAll(const Name, Ext: string; const Near: string): TStringArray;
var
  K: Integer;
  P: string;
  Hits: TStringArray;
begin
  Refresh;
  Hits := nil;
  K := FindList(FUnits, LowerText(Name));
  if K >= 0 then
    for P in FUnits[K].Paths do
      if EndsWithText(LowerText(P), Ext) then
      begin
        SetLength(Hits, Length(Hits) + 1);
        Hits[High(Hits)] := P;
      end;
  Result := Ranked(Hits, Near);
end;

function TProjectIndex.FindFile(const Rel: string; const Near: string): string;
var
  Slashed, Base, Tail, P: string;
  Parts: TStringArray;
  K: Integer;
begin
  Refresh;
  Slashed := StringReplace(Rel, '\', '/', [rfReplaceAll]);
  Parts := Slashed.Split(['/']);
  Base := LowerText(Parts[High(Parts)]);
  Tail := LowerText(Slashed);
  K := FindList(FFiles, Base);
  if K >= 0 then
    for P in Ranked(FFiles[K].Paths, Near) do
      if EndsWithText(LowerText(StringReplace(P, '\', '/', [rfReplaceAll])), Tail) then
        Exit(P);
  Result := '';
end;

function TProjectIndex.UnitNames: TStringArray;
var
  L: TPathList;
  Root, Ext: string;
  I, J: Integer;
  T: string;
begin
  Refresh;
  Result := nil;
  for L in FUnits do
  begin
    SplitExt(BaseName(L.Paths[0]), Root, Ext);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Root;
  end;
  for I := 1 to High(Result) do
  begin
    T := Result[I];
    J := I - 1;
    while (J >= 0) and (CompareStr(LowerText(Result[J]), LowerText(T)) > 0) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := T;
  end;
end;

function TProjectIndex.Sources: TStringArray;
begin
  Refresh;
  Result := Copy(FSources);
end;

function TProjectIndex.Duplicates: TPathLists;
const
  Exts: array[0..1] of string = ('.pas', '.tpu');
var
  L: TPathList;
  P, Ext: string;
  Same: TStringArray;
begin
  Refresh;
  Result := nil;
  for L in FUnits do
    for Ext in Exts do
    begin
      Same := nil;
      for P in L.Paths do
        if EndsWithText(LowerText(P), Ext) then
        begin
          SetLength(Same, Length(Same) + 1);
          Same[High(Same)] := P;
        end;
      if Length(Same) > 1 then
        for P in Same do
          AddToList(Result, L.Key, P);
    end;
end;

end.
