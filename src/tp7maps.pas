unit tp7maps;

{$mode objfpc}{$H+}

interface

type
  TStrMap = class
  private
    FKeys: array of string;
    FVals: array of TObject;
    FSlots: array of Integer;
    FCount: Integer;
    function Slot(const Key: string): Integer;
    procedure Grow;
  public
    function Count: Integer;
    function KeyAt(I: Integer): string;
    function At(I: Integer): TObject;
    function IndexOf(const Key: string): Integer;
    function Get(const Key: string): TObject;
    function Has(const Key: string): Boolean;
    procedure Put(const Key: string; V: TObject);
    function SetDefault(const Key: string; V: TObject): TObject;
    procedure Assign(Src: TStrMap);
  end;

  TPtrMap = class
  private
    FKeys: array of Pointer;
    FVals: array of TObject;
    FSlots: array of Integer;
    FCount: Integer;
    function Slot(Key: Pointer): Integer;
    procedure Grow;
  public
    function Count: Integer;
    function KeyAt(I: Integer): Pointer;
    function At(I: Integer): TObject;
    function IndexOf(Key: Pointer): Integer;
    function Get(Key: Pointer): TObject;
    function Has(Key: Pointer): Boolean;
    procedure Put(Key: Pointer; V: TObject);
    procedure Assign(Src: TPtrMap);
  end;

implementation

{$PUSH}{$Q-}{$R-}
function StrHash(const S: string): LongWord;
var
  C: Char;
begin
  Result := 2166136261;
  for C in S do
    Result := (Result xor Ord(C)) * 16777619;
end;

function PtrHash(P: Pointer): LongWord;
var
  X: QWord;
begin
  X := QWord(PtrUInt(P));
  X := X xor (X shr 33);
  X := X * QWord($FF51AFD7ED558CCD);
  X := X xor (X shr 33);
  Result := LongWord(X);
end;
{$POP}

{ TStrMap }

function TStrMap.Count: Integer;
begin
  Result := FCount;
end;

function TStrMap.KeyAt(I: Integer): string;
begin
  Result := FKeys[I];
end;

function TStrMap.At(I: Integer): TObject;
begin
  Result := FVals[I];
end;

function TStrMap.Slot(const Key: string): Integer;
var
  Mask: Integer;
begin
  Mask := Length(FSlots) - 1;
  Result := StrHash(Key) and Mask;
  while (FSlots[Result] >= 0) and (FKeys[FSlots[Result]] <> Key) do
    Result := (Result + 1) and Mask;
end;

procedure TStrMap.Grow;
var
  I, N: Integer;
begin
  N := 16;
  while N < 4 * (FCount + 1) do
    N := N * 2;
  SetLength(FSlots, N);
  for I := 0 to N - 1 do
    FSlots[I] := -1;
  for I := 0 to FCount - 1 do
    FSlots[Slot(FKeys[I])] := I;
end;

function TStrMap.IndexOf(const Key: string): Integer;
begin
  if FSlots = nil then
    Exit(-1);
  Result := FSlots[Slot(Key)];
end;

function TStrMap.Get(const Key: string): TObject;
var
  I: Integer;
begin
  I := IndexOf(Key);
  if I < 0 then
    Result := nil
  else
    Result := FVals[I];
end;

function TStrMap.Has(const Key: string): Boolean;
begin
  Result := IndexOf(Key) >= 0;
end;

procedure TStrMap.Put(const Key: string; V: TObject);
var
  I: Integer;
begin
  I := IndexOf(Key);
  if I >= 0 then
  begin
    FVals[I] := V;
    Exit;
  end;
  if 2 * (FCount + 1) > Length(FSlots) then
    Grow;
  if FCount = Length(FKeys) then
  begin
    SetLength(FKeys, 2 * FCount + 8);
    SetLength(FVals, 2 * FCount + 8);
  end;
  FKeys[FCount] := Key;
  FVals[FCount] := V;
  FSlots[Slot(Key)] := FCount;
  Inc(FCount);
end;

function TStrMap.SetDefault(const Key: string; V: TObject): TObject;
var
  I: Integer;
begin
  I := IndexOf(Key);
  if I >= 0 then
    Exit(FVals[I]);
  Put(Key, V);
  Result := V;
end;

procedure TStrMap.Assign(Src: TStrMap);
var
  I: Integer;
begin
  FKeys := nil;
  FVals := nil;
  FSlots := nil;
  FCount := 0;
  for I := 0 to Src.Count - 1 do
    Put(Src.KeyAt(I), Src.At(I));
end;

{ TPtrMap }

function TPtrMap.Count: Integer;
begin
  Result := FCount;
end;

function TPtrMap.KeyAt(I: Integer): Pointer;
begin
  Result := FKeys[I];
end;

function TPtrMap.At(I: Integer): TObject;
begin
  Result := FVals[I];
end;

function TPtrMap.Slot(Key: Pointer): Integer;
var
  Mask: Integer;
begin
  Mask := Length(FSlots) - 1;
  Result := PtrHash(Key) and Mask;
  while (FSlots[Result] >= 0) and (FKeys[FSlots[Result]] <> Key) do
    Result := (Result + 1) and Mask;
end;

procedure TPtrMap.Grow;
var
  I, N: Integer;
begin
  N := 16;
  while N < 4 * (FCount + 1) do
    N := N * 2;
  SetLength(FSlots, N);
  for I := 0 to N - 1 do
    FSlots[I] := -1;
  for I := 0 to FCount - 1 do
    FSlots[Slot(FKeys[I])] := I;
end;

function TPtrMap.IndexOf(Key: Pointer): Integer;
begin
  if FSlots = nil then
    Exit(-1);
  Result := FSlots[Slot(Key)];
end;

function TPtrMap.Get(Key: Pointer): TObject;
var
  I: Integer;
begin
  I := IndexOf(Key);
  if I < 0 then
    Result := nil
  else
    Result := FVals[I];
end;

function TPtrMap.Has(Key: Pointer): Boolean;
begin
  Result := IndexOf(Key) >= 0;
end;

procedure TPtrMap.Put(Key: Pointer; V: TObject);
var
  I: Integer;
begin
  I := IndexOf(Key);
  if I >= 0 then
  begin
    FVals[I] := V;
    Exit;
  end;
  if 2 * (FCount + 1) > Length(FSlots) then
    Grow;
  if FCount = Length(FKeys) then
  begin
    SetLength(FKeys, 2 * FCount + 8);
    SetLength(FVals, 2 * FCount + 8);
  end;
  FKeys[FCount] := Key;
  FVals[FCount] := V;
  FSlots[Slot(Key)] := FCount;
  Inc(FCount);
end;

procedure TPtrMap.Assign(Src: TPtrMap);
var
  I: Integer;
begin
  FKeys := nil;
  FVals := nil;
  FSlots := nil;
  FCount := 0;
  for I := 0 to Src.Count - 1 do
    Put(Src.KeyAt(I), Src.At(I));
end;

end.
