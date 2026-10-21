unit tp7diff;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TOpTag = (opEqual, opReplace, opDelete, opInsert);

  TOpcode = record
    Tag: TOpTag;
    I1, I2, J1, J2: Integer;
  end;

  TOpcodes = array of TOpcode;

  TMatch = record
    A, B, Size: Integer;
  end;

  TMatches = array of TMatch;

  TIntSeq = array of Integer;

  TSequenceMatcher = class
  private
    FA, FB: TIntSeq;
    FB2J: array of TIntSeq;
    FHas: array of Boolean;
    FPrevLen, FCurLen: array of Integer;
    FPrevStamp, FCurStamp: array of Integer;
    FStamp: Integer;
    FFullBCount: array of Integer;
    FFullBCountDone: Boolean;
    FMatches: TMatches;
    FMatchesDone: Boolean;
    procedure ChainB;
  public
    AutoJunk: Boolean;
    constructor Create(AAutoJunk: Boolean = True);
    procedure SetSeqs(const A, B: TIntSeq);
    procedure SetSeq1(const A: TIntSeq);
    procedure SetSeq2(const B: TIntSeq);
    function FindLongestMatch(ALo, AHi, BLo, BHi: Integer): TMatch;
    function MatchingBlocks: TMatches;
    function Opcodes: TOpcodes;
    function Ratio: Double;
    function QuickRatio: Double;
    function RealQuickRatio: Double;
  end;

  TInterner = class
  private
    FKeys: array of string;
    FSlots: array of Integer;
    FCount: Integer;
    procedure Grow;
    function Slot(const S: string): Integer;
  public
    function Id(const S: string): Integer;
    function Count: Integer;
  end;

function LineOpcodes(const A, B: TStringArray; AutoJunk: Boolean = False): TOpcodes;
function GetCloseMatches(const Word: string; const Possibilities: TStringArray; N: Integer = 3;
  Cutoff: Double = 0.6): TStringArray;

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
{$POP}

function TInterner.Slot(const S: string): Integer;
var
  Mask: Integer;
begin
  Mask := Length(FSlots) - 1;
  Result := Integer(StrHash(S) and LongWord(Mask));
  while (FSlots[Result] >= 0) and (FKeys[FSlots[Result]] <> S) do
    Result := (Result + 1) and Mask;
end;

procedure TInterner.Grow;
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

function TInterner.Id(const S: string): Integer;
var
  K: Integer;
begin
  if 2 * (FCount + 1) > Length(FSlots) then
    Grow;
  K := Slot(S);
  if FSlots[K] >= 0 then
    Exit(FSlots[K]);
  if FCount = Length(FKeys) then
    SetLength(FKeys, 2 * FCount + 8);
  FKeys[FCount] := S;
  FSlots[K] := FCount;
  Result := FCount;
  Inc(FCount);
end;

function TInterner.Count: Integer;
begin
  Result := FCount;
end;

constructor TSequenceMatcher.Create(AAutoJunk: Boolean);
begin
  AutoJunk := AAutoJunk;
end;

procedure TSequenceMatcher.SetSeqs(const A, B: TIntSeq);
begin
  SetSeq1(A);
  SetSeq2(B);
end;

procedure TSequenceMatcher.SetSeq1(const A: TIntSeq);
begin
  FA := Copy(A);
  FMatchesDone := False;
end;

procedure TSequenceMatcher.SetSeq2(const B: TIntSeq);
begin
  FB := Copy(B);
  FMatchesDone := False;
  FFullBCountDone := False;
  ChainB;
end;

procedure TSequenceMatcher.ChainB;
var
  I, MaxId, NTest, X: Integer;
begin
  MaxId := -1;
  for X in FB do
    if X > MaxId then
      MaxId := X;
  for I := 0 to High(FB2J) do
    FB2J[I] := nil;
  SetLength(FB2J, MaxId + 1);
  SetLength(FHas, MaxId + 1);
  for I := 0 to MaxId do
    FHas[I] := False;
  for I := 0 to High(FB) do
  begin
    SetLength(FB2J[FB[I]], Length(FB2J[FB[I]]) + 1);
    FB2J[FB[I]][High(FB2J[FB[I]])] := I;
    FHas[FB[I]] := True;
  end;
  if AutoJunk and (Length(FB) >= 200) then
  begin
    NTest := Length(FB) div 100 + 1;
    for I := 0 to MaxId do
      if Length(FB2J[I]) > NTest then
        FB2J[I] := nil;
  end;
  SetLength(FPrevLen, Length(FB) + 1);
  SetLength(FCurLen, Length(FB) + 1);
  SetLength(FPrevStamp, Length(FB) + 1);
  SetLength(FCurStamp, Length(FB) + 1);
  for I := 0 to Length(FB) do
  begin
    FPrevStamp[I] := -1;
    FCurStamp[I] := -1;
  end;
  FStamp := 0;
end;

function TSequenceMatcher.FindLongestMatch(ALo, AHi, BLo, BHi: Integer): TMatch;
var
  BestI, BestJ, BestSize, I, J, K, X: Integer;
  Js: TIntSeq;
  TL: array of Integer;
begin
  BestI := ALo;
  BestJ := BLo;
  BestSize := 0;
  Inc(FStamp);
  for I := ALo to AHi - 1 do
  begin
    Inc(FStamp);
    X := FA[I];
    if (X >= 0) and (X <= High(FB2J)) then
      Js := FB2J[X]
    else
      Js := nil;
    for J in Js do
    begin
      if J < BLo then
        Continue;
      if J >= BHi then
        Break;
      if (J > 0) and (FPrevStamp[J - 1] = FStamp - 1) then
        K := FPrevLen[J - 1] + 1
      else
        K := 1;
      FCurLen[J] := K;
      FCurStamp[J] := FStamp;
      if K > BestSize then
      begin
        BestI := I - K + 1;
        BestJ := J - K + 1;
        BestSize := K;
      end;
    end;
    TL := FPrevLen;
    FPrevLen := FCurLen;
    FCurLen := TL;
    TL := FPrevStamp;
    FPrevStamp := FCurStamp;
    FCurStamp := TL;
  end;
  Inc(FStamp);
  while (BestI > ALo) and (BestJ > BLo) and (FA[BestI - 1] = FB[BestJ - 1]) do
  begin
    Dec(BestI);
    Dec(BestJ);
    Inc(BestSize);
  end;
  while (BestI + BestSize < AHi) and (BestJ + BestSize < BHi) and (FA[BestI + BestSize] = FB[BestJ + BestSize]) do
    Inc(BestSize);
  Result.A := BestI;
  Result.B := BestJ;
  Result.Size := BestSize;
end;

function TSequenceMatcher.MatchingBlocks: TMatches;
type
  TQ = record
    ALo, AHi, BLo, BHi: Integer;
  end;
var
  Queue: array of TQ;
  Q: TQ;
  M, X: TMatch;
  Blocks: TMatches;
  I, J, I1, J1, K1: Integer;
begin
  if FMatchesDone then
    Exit(FMatches);
  SetLength(Queue, 1);
  Queue[0].ALo := 0;
  Queue[0].AHi := Length(FA);
  Queue[0].BLo := 0;
  Queue[0].BHi := Length(FB);
  Blocks := nil;
  while Queue <> nil do
  begin
    Q := Queue[High(Queue)];
    SetLength(Queue, Length(Queue) - 1);
    M := FindLongestMatch(Q.ALo, Q.AHi, Q.BLo, Q.BHi);
    if M.Size > 0 then
    begin
      SetLength(Blocks, Length(Blocks) + 1);
      Blocks[High(Blocks)] := M;
      if (Q.ALo < M.A) and (Q.BLo < M.B) then
      begin
        SetLength(Queue, Length(Queue) + 1);
        Queue[High(Queue)].ALo := Q.ALo;
        Queue[High(Queue)].AHi := M.A;
        Queue[High(Queue)].BLo := Q.BLo;
        Queue[High(Queue)].BHi := M.B;
      end;
      if (M.A + M.Size < Q.AHi) and (M.B + M.Size < Q.BHi) then
      begin
        SetLength(Queue, Length(Queue) + 1);
        Queue[High(Queue)].ALo := M.A + M.Size;
        Queue[High(Queue)].AHi := Q.AHi;
        Queue[High(Queue)].BLo := M.B + M.Size;
        Queue[High(Queue)].BHi := Q.BHi;
      end;
    end;
  end;
  for I := 1 to High(Blocks) do
  begin
    X := Blocks[I];
    J := I - 1;
    while (J >= 0) and ((Blocks[J].A > X.A) or ((Blocks[J].A = X.A) and ((Blocks[J].B > X.B) or
      ((Blocks[J].B = X.B) and (Blocks[J].Size > X.Size))))) do
    begin
      Blocks[J + 1] := Blocks[J];
      Dec(J);
    end;
    Blocks[J + 1] := X;
  end;
  FMatches := nil;
  I1 := 0;
  J1 := 0;
  K1 := 0;
  for M in Blocks do
    if (I1 + K1 = M.A) and (J1 + K1 = M.B) then
      Inc(K1, M.Size)
    else
    begin
      if K1 > 0 then
      begin
        SetLength(FMatches, Length(FMatches) + 1);
        FMatches[High(FMatches)].A := I1;
        FMatches[High(FMatches)].B := J1;
        FMatches[High(FMatches)].Size := K1;
      end;
      I1 := M.A;
      J1 := M.B;
      K1 := M.Size;
    end;
  if K1 > 0 then
  begin
    SetLength(FMatches, Length(FMatches) + 1);
    FMatches[High(FMatches)].A := I1;
    FMatches[High(FMatches)].B := J1;
    FMatches[High(FMatches)].Size := K1;
  end;
  SetLength(FMatches, Length(FMatches) + 1);
  FMatches[High(FMatches)].A := Length(FA);
  FMatches[High(FMatches)].B := Length(FB);
  FMatches[High(FMatches)].Size := 0;
  FMatchesDone := True;
  Result := FMatches;
end;

function TSequenceMatcher.Opcodes: TOpcodes;
var
  I, J: Integer;
  M: TMatch;
  Tag: TOpTag;
  HasTag: Boolean;

  procedure Add(T: TOpTag; I1, I2, J1, J2: Integer);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Tag := T;
    Result[High(Result)].I1 := I1;
    Result[High(Result)].I2 := I2;
    Result[High(Result)].J1 := J1;
    Result[High(Result)].J2 := J2;
  end;

begin
  Result := nil;
  I := 0;
  J := 0;
  for M in MatchingBlocks do
  begin
    HasTag := True;
    if (I < M.A) and (J < M.B) then
      Tag := opReplace
    else if I < M.A then
      Tag := opDelete
    else if J < M.B then
      Tag := opInsert
    else
      HasTag := False;
    if HasTag then
      Add(Tag, I, M.A, J, M.B);
    I := M.A + M.Size;
    J := M.B + M.Size;
    if M.Size > 0 then
      Add(opEqual, M.A, I, M.B, J);
  end;
end;

function CalcRatio(Matches, Len: Integer): Double;
begin
  if Len > 0 then
    Result := 2.0 * Matches / Len
  else
    Result := 1.0;
end;

function TSequenceMatcher.Ratio: Double;
var
  M: TMatch;
  N: Integer;
begin
  N := 0;
  for M in MatchingBlocks do
    Inc(N, M.Size);
  Result := CalcRatio(N, Length(FA) + Length(FB));
end;

function TSequenceMatcher.QuickRatio: Double;
var
  Avail: array of Integer;
  I, X, MaxId, Matches: Integer;
begin
  if not FFullBCountDone then
  begin
    MaxId := -1;
    for X in FB do
      if X > MaxId then
        MaxId := X;
    SetLength(FFullBCount, MaxId + 1);
    for I := 0 to MaxId do
      FFullBCount[I] := 0;
    for X in FB do
      Inc(FFullBCount[X]);
    FFullBCountDone := True;
  end;
  Avail := Copy(FFullBCount);
  Matches := 0;
  for X in FA do
    if (X <= High(Avail)) and (Avail[X] > 0) then
    begin
      Dec(Avail[X]);
      Inc(Matches);
    end;
  Result := CalcRatio(Matches, Length(FA) + Length(FB));
end;

function TSequenceMatcher.RealQuickRatio: Double;
var
  LA, LB: Integer;
begin
  LA := Length(FA);
  LB := Length(FB);
  if LA < LB then
    Result := CalcRatio(LA, LA + LB)
  else
    Result := CalcRatio(LB, LA + LB);
end;

function LineOpcodes(const A, B: TStringArray; AutoJunk: Boolean): TOpcodes;
var
  Ids: TInterner;
  SA, SB: TIntSeq;
  I: Integer;
  M: TSequenceMatcher;
begin
  Ids := TInterner.Create;
  M := TSequenceMatcher.Create(AutoJunk);
  try
    SetLength(SA, Length(A));
    for I := 0 to High(A) do
      SA[I] := Ids.Id(A[I]);
    SetLength(SB, Length(B));
    for I := 0 to High(B) do
      SB[I] := Ids.Id(B[I]);
    M.SetSeqs(SA, SB);
    Result := M.Opcodes;
  finally
    M.Free;
    Ids.Free;
  end;
end;

function CharIds(const S: string; Ids: TInterner): TIntSeq;
var
  I, N, Len, Want: Integer;
  B: Byte;
begin
  Result := nil;
  SetLength(Result, Length(S));
  N := 0;
  I := 1;
  while I <= Length(S) do
  begin
    B := Ord(S[I]);
    if B < $C0 then
      Want := 1
    else if B < $E0 then
      Want := 2
    else if B < $F0 then
      Want := 3
    else
      Want := 4;
    Len := 1;
    while (Len < Want) and (I + Len <= Length(S)) and (Ord(S[I + Len]) and $C0 = $80) do
      Inc(Len);
    Result[N] := Ids.Id(Copy(S, I, Len));
    Inc(N);
    Inc(I, Len);
  end;
  SetLength(Result, N);
end;

function GetCloseMatches(const Word: string; const Possibilities: TStringArray; N: Integer;
  Cutoff: Double): TStringArray;
type
  TScored = record
    Score: Double;
    Text: string;
  end;
var
  M: TSequenceMatcher;
  Ids: TInterner;
  Found: array of TScored;
  X: TScored;
  P: string;
  I, J: Integer;
  R: Double;
begin
  Result := nil;
  Found := nil;
  M := TSequenceMatcher.Create(True);
  Ids := TInterner.Create;
  try
    M.SetSeq2(CharIds(Word, Ids));
    for P in Possibilities do
    begin
      M.SetSeq1(CharIds(P, Ids));
      if (M.RealQuickRatio >= Cutoff) and (M.QuickRatio >= Cutoff) then
      begin
        R := M.Ratio;
        if R >= Cutoff then
        begin
          SetLength(Found, Length(Found) + 1);
          Found[High(Found)].Score := R;
          Found[High(Found)].Text := P;
        end;
      end;
    end;
  finally
    Ids.Free;
    M.Free;
  end;
  for I := 1 to High(Found) do
  begin
    X := Found[I];
    J := I - 1;
    while (J >= 0) and ((Found[J].Score < X.Score) or ((Found[J].Score = X.Score) and (Found[J].Text < X.Text))) do
    begin
      Found[J + 1] := Found[J];
      Dec(J);
    end;
    Found[J + 1] := X;
  end;
  for I := 0 to High(Found) do
    if I < N then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Found[I].Text;
    end;
end;

end.
