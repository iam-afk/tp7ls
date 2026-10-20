unit tp7fmt;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, tp7lex, tp7parse, tp7sema;

const
  IndentStep = 2;
  MaxWidth = 120;
  TpLineLimit = 126;
  WrapIndent = 4;

type
  EFormatError = class(Exception);
  EFormatBug = class(Exception);

function SplitLines(const Text: string): TStringArray;
function WrapLine(const Line: string; Width: Integer = MaxWidth; Step: Integer = WrapIndent): TStringArray;
function FormatParsed(R: TParseResult; Width: Integer = MaxWidth; Warnings: TStrings = nil): string;
function FormatSource(const Src: string): string;
function FormatSource(const Src: string; const Defines: array of string; Width: Integer = MaxWidth;
  Warnings: TStrings = nil; Normalize: Boolean = False; Provider: TProvider = nil): string;

implementation

uses
  tp7enc;

type
  TCondKind = (ckNone, ckOpen, ckElse, ckEnd);
  TOwnKind = (okComment, okBlank, okVerbatim);

  TOwnItem = record
    Kind: TOwnKind;
    Text: string;
    IsDirective: Boolean;
    Cond: TCondKind;
  end;

  TOwnItems = array of TOwnItem;

  TTrivia = record
    Trailing: TStringArray;
    Own: TOwnItems;
    BlankBeforeToken: Boolean;
  end;

  TCut = record
    Pos: SizeInt;
    CharPos: SizeInt;
    Depth: Integer;
    Rank: Integer;
  end;

  TCuts = array of TCut;

{ text helpers }

function JoinStr(const Parts: array of string; const Sep: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Parts) do
    if I = 0 then
      Result := Parts[I]
    else
      Result := Result + Sep + Parts[I];
end;

procedure PushStr(var A: TStringArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function SplitLines(const Text: string): TStringArray;
var
  I, Start: SizeInt;
begin
  Result := nil;
  Start := 1;
  I := 1;
  while I <= Length(Text) do
    if Text[I] in [#13, #10] then
    begin
      PushStr(Result, Copy(Text, Start, I - Start));
      if (Text[I] = #13) and (I < Length(Text)) and (Text[I + 1] = #10) then
        Inc(I);
      Inc(I);
      Start := I;
    end
    else
      Inc(I);
  PushStr(Result, Copy(Text, Start, MaxInt));
end;

function HasNewline(const Text: string): Boolean;
begin
  Result := (Pos(#10, Text) > 0) or (Pos(#13, Text) > 0);
end;

function LastChars(const S: string; N: Integer): string;
var
  I: SizeInt;
begin
  I := Length(S) + 1;
  while (N > 0) and (I > 1) do
  begin
    Dec(I);
    while (I > 1) and (Ord(S[I]) and $C0 = $80) do
      Dec(I);
    Dec(N);
  end;
  Result := Copy(S, I, MaxInt);
end;

function CharLen(const S: string): SizeInt;
begin
  Result := Utf8Length(S, 1, Length(S));
end;

function LeadingSpaces(const S: string): SizeInt;
begin
  Result := 0;
  while (Result < Length(S)) and (S[Result + 1] = ' ') do
    Inc(Result);
end;

function TrimSpacesRight(const S: string): string;
var
  N: SizeInt;
begin
  N := Length(S);
  while (N > 0) and (S[N] = ' ') do
    Dec(N);
  Result := Copy(S, 1, N);
end;

function RStripSpace(const S: string): string;
var
  I, Stop, L: SizeInt;
begin
  I := 1;
  Stop := 0;
  while I <= Length(S) do
  begin
    L := SpaceLen(S, I);
    if L > 0 then
      Inc(I, L)
    else
    begin
      Inc(I);
      while (I <= Length(S)) and (Ord(S[I]) and $C0 = $80) do
        Inc(I);
      Stop := I - 1;
    end;
  end;
  Result := Copy(S, 1, Stop);
end;

function DropLeadingNewline(const S: string): string;
begin
  if Copy(S, 1, 2) = #13#10 then
    Result := Copy(S, 3, MaxInt)
  else if (S <> '') and (S[1] in [#13, #10]) then
    Result := Copy(S, 2, MaxInt)
  else
    Result := S;
end;

function DropTrailingBlankLine(const S: string): string;
var
  L, P, E: SizeInt;

  function AtEnd(X: SizeInt): Boolean;
  begin
    Result := (X = Length(S)) or ((X = Length(S) - 1) and (S[Length(S)] = #10));
  end;

  function MatchAt(At: SizeInt): SizeInt;
  var
    Starts: array[0..3] of SizeInt;
    NStarts, K: Integer;
    Q, R, X: SizeInt;
  begin
    NStarts := 0;
    if (At + 2 <= Length(S)) and (S[At + 1] = #13) and (S[At + 2] = #10) then
    begin
      Starts[NStarts] := At + 2;
      Inc(NStarts);
    end;
    if (At + 1 <= Length(S)) and (S[At + 1] in [#13, #10]) then
    begin
      Starts[NStarts] := At + 1;
      Inc(NStarts);
    end;
    Starts[NStarts] := At;
    Inc(NStarts);
    for K := 0 to NStarts - 1 do
    begin
      Q := Starts[K];
      R := Q;
      while (R < Length(S)) and (S[R + 1] in [' ', #9]) do
        Inc(R);
      for X := R downto Q do
        if AtEnd(X) then
          Exit(X);
    end;
    Result := -1;
  end;

begin
  L := Length(S);
  while (L > 0) and (S[L] in [' ', #9, #13, #10]) do
    Dec(L);
  Result := Copy(S, 1, L);
  P := L;
  while P <= Length(S) do
  begin
    E := MatchAt(P);
    if E > P then
      P := E
    else
    begin
      if P < Length(S) then
        Result := Result + S[P + 1];
      Inc(P);
    end;
  end;
end;

{ line wrapping }

function OperatorFollows(const S: string; I: SizeInt): Boolean;
const
  Words: array[0..7] of string = ('and', 'or', 'xor', 'div', 'mod', 'shl', 'shr', 'in');
var
  W: string;
begin
  for W in Words do
    if SameText(Copy(S, I, Length(W)), W) and (Copy(S, I + Length(W), 1) = ' ') then
      Exit(True);
  Result := (I < Length(S)) and (S[I] in ['-', '+', '*', '/']) and (S[I + 1] = ' ');
end;

function Cuts(const S: string; Depth: Integer): TCuts;
var
  I, N, J: SizeInt;
  C: Char;

  procedure Add(At: SizeInt; Rank: Integer);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Pos := At;
    Result[High(Result)].CharPos := Utf8Length(S, 1, At);
    Result[High(Result)].Depth := Depth;
    Result[High(Result)].Rank := Rank;
  end;

begin
  Result := nil;
  N := Length(S);
  I := 0;
  while I < N do
  begin
    C := S[I + 1];
    if C = '''' then
    begin
      Inc(I);
      while I < N do
      begin
        if S[I + 1] = '''' then
        begin
          if (I + 1 < N) and (S[I + 2] = '''') then
          begin
            Inc(I, 2);
            Continue;
          end;
          Break;
        end;
        Inc(I);
      end;
      Inc(I);
      Continue;
    end;
    if C = '{' then
    begin
      J := Pos('}', S, I + 1);
      if J = 0 then
        I := N
      else
        I := J;
      Continue;
    end;
    if (C = '(') and (Copy(S, I + 1, 2) = '(*') then
    begin
      J := Pos('*)', S, I + 3);
      if J = 0 then
        I := N
      else
        I := J + 1;
      Continue;
    end;
    if C in ['(', '['] then
      Inc(Depth)
    else if C in [')', ']'] then
      Dec(Depth)
    else if (C = ',') and (I + 1 < N) and (S[I + 2] = ' ') then
      Add(I + 1, 0)
    else if (C = ';') and (Depth > 0) and (I + 1 < N) and (S[I + 2] = ' ') then
      Add(I + 1, 0)
    else if (C = ':') and (Copy(S, I + 1, 3) = ':= ') then
    begin
      Add(I + 2, 1);
      Inc(I, 2);
      Continue;
    end
    else if (C = ' ') and (I > 0) and (S[I] <> ' ') and OperatorFollows(S, I + 2) then
      Add(I, 0);
    Inc(I);
  end;
end;

function WrapLine(const Line: string; Width: Integer; Step: Integer): TStringArray;
var
  Cur, Next, Rest: string;
  D0, Base, Ind: SizeInt;
  All, Fit, Good: TCuts;
  C, Pick: TCut;
  Found: Boolean;

  function Better(const A, B: TCut): Boolean;
  begin
    if A.Depth <> B.Depth then
      Exit(A.Depth < B.Depth);
    if A.Rank <> B.Rank then
      Exit(A.Rank < B.Rank);
    Result := A.Pos > B.Pos;
  end;

  procedure Push(var A: TCuts; const X: TCut);
  begin
    SetLength(A, Length(A) + 1);
    A[High(A)] := X;
  end;

begin
  Result := nil;
  Cur := Line;
  D0 := 0;
  Base := LeadingSpaces(Line);
  while CharLen(Cur) > Width do
  begin
    Ind := LeadingSpaces(Cur);
    All := nil;
    for C in Cuts(Cur, D0) do
      if C.CharPos > Ind then
        Push(All, C);
    Fit := nil;
    Good := nil;
    for C in All do
    begin
      Rest := Copy(Cur, C.Pos + 1, MaxInt);
      if (C.CharPos <= Width) and ((C.Rank = 0) or (Base + Step + CharLen(Rest) - LeadingSpaces(Rest) <= Width)) then
      begin
        Push(Fit, C);
        if C.CharPos >= Ind + 24 then
          Push(Good, C);
      end;
    end;
    Found := False;
    if Good <> nil then
    begin
      Pick := Good[0];
      for C in Good do
        if Better(C, Pick) then
          Pick := C;
      Found := True;
    end
    else if Fit <> nil then
    begin
      Pick := Fit[0];
      for C in Fit do
        if Better(C, Pick) then
          Pick := C;
      Found := True;
    end
    else
      for C in All do
        if (C.Rank = 0) and (not Found or (C.Pos < Pick.Pos)) then
        begin
          Pick := C;
          Found := True;
        end;
    if not Found then
      Break;
    Rest := Copy(Cur, Pick.Pos + 1, MaxInt);
    Next := StringOfChar(' ', Base + Step) + Copy(Rest, LeadingSpaces(Rest) + 1, MaxInt);
    if CharLen(Next) >= CharLen(Cur) then
      Break;
    PushStr(Result, TrimSpacesRight(Copy(Cur, 1, Pick.Pos)));
    Cur := Next;
    D0 := Pick.Depth;
  end;
  PushStr(Result, Cur);
end;

{ trivia }

function CondKind(T: TToken): TCondKind;
var
  Kind: TDirectiveKind;
  Arg: string;
begin
  if T.Kind <> tkDirective then
    Exit(ckNone);
  ParseDirective(T.Text, Kind, Arg);
  case Kind of
    dkIfdef, dkIfndef, dkIfopt:
      Result := ckOpen;
    dkElse:
      Result := ckElse;
    dkEndif:
      Result := ckEnd;
  else
    Result := ckNone;
  end;
end;

procedure PushOwn(var A: TOwnItems; Kind: TOwnKind; const Text: string; IsDirective: Boolean; Cond: TCondKind);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)].Kind := Kind;
  A[High(A)].Text := Text;
  A[High(A)].IsDirective := IsDirective;
  A[High(A)].Cond := Cond;
end;

function SplitTrivia(const Leading: TTokens): TTrivia;
var
  SeenNl: Boolean;
  Run: Integer;
  I, J, N: SizeInt;
  T: TToken;
  Buf, Text: string;
begin
  Result.Trailing := nil;
  Result.Own := nil;
  SeenNl := False;
  Run := 0;
  I := 0;
  N := Length(Leading);
  while I < N do
  begin
    T := Leading[I];
    if not T.Active then
    begin
      J := I;
      Buf := '';
      while (J < N) and not Leading[J].Active do
      begin
        Buf := Buf + Leading[J].Text;
        Inc(J);
      end;
      Text := DropTrailingBlankLine(DropLeadingNewline(Buf));
      if Text <> '' then
        PushOwn(Result.Own, okVerbatim, Text, False, ckNone);
      SeenNl := True;
      Run := 1;
      I := J;
      Continue;
    end;
    case T.Kind of
      tkWS, tkCtrlZ:
        Inc(I);
      tkNL:
        begin
          SeenNl := True;
          Inc(Run);
          Inc(I);
        end;
      tkComment, tkDirective:
        begin
          if not SeenNl then
            PushStr(Result.Trailing, T.Text)
          else
          begin
            if Run >= 2 then
              PushOwn(Result.Own, okBlank, '', False, ckNone);
            PushOwn(Result.Own, okComment, T.Text, T.Kind = tkDirective, CondKind(T));
            Run := 0;
          end;
          Inc(I);
        end;
    else
      raise EFormatError.CreateFmt('unexpected trivia %s at line %d', [TokenKindNames[T.Kind], T.Line]);
    end;
  end;
  Result.BlankBeforeToken := SeenNl and (Run >= 2);
end;

function FirstTok(X: TObject): TToken;
var
  K: TObject;
begin
  if X is TToken then
    Exit(TToken(X));
  for K in TNode(X).Kids do
  begin
    Result := FirstTok(K);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function IsTok(X: TObject; const Texts: array of string): Boolean;
var
  S: string;
begin
  if not (X is TToken) then
    Exit(False);
  for S in Texts do
    if (TToken(X).Text = S) or (TToken(X).Lower = S) then
      Exit(True);
  Result := False;
end;

function IsNode(X: TObject; Kind: TNodeKind): Boolean;
begin
  Result := (X is TNode) and (TNode(X).Kind = Kind);
end;

function Tok(X: TObject): TToken;
begin
  Result := X as TToken;
end;

function Nd(X: TObject): TNode;
begin
  Result := X as TNode;
end;

function Slice(const Kids: TKids; First, Stop: SizeInt): TKids;
begin
  if Stop > Length(Kids) then
    Stop := Length(Kids);
  if Stop <= First then
    Exit(nil);
  Result := Copy(Kids, First, Stop - First);
end;

function TokenRepr(T: TToken): string;
begin
  Result := Format('%s(%s)@%d:%d', [TokenKindNames[T.Kind], PyRepr(T.Text), T.Line, T.Col]);
end;

const
  SimpleKinds = [nkAssign, nkProcCall, nkGoto, nkInline, nkInherited];
  SectionKinds = [nkConstSection, nkTypeSection, nkVarSection, nkLabelSection];

{ the formatter }

type
  TFormatter = class
  private
    Res: TParseResult;
    Width: Integer;
    Warnings: TStrings;
    Lines: array of string;
    Code: array of Boolean;
    Count: SizeInt;
    Eol: string;
    Used: array of Boolean;
    function IsUsed(T: TToken): Boolean;
    procedure MarkUsed(T: TToken);
    procedure AddLine(const Text: string; IsCode: Boolean);
    procedure Line(Indent: Integer; const Text: string);
    procedure Raw(const Text: string);
    procedure AppendLast(const Text: string);
    function LastLine: string;
    procedure Blank;
    procedure Trailing(const Texts: TStringArray);
    procedure Comment(Indent: Integer; const Text: string);
    procedure Verbatim(const Text: string);
    procedure Lead(X: TObject; Indent: Integer; Keep: Boolean; Sep: Boolean = False; OwnTrailing: Boolean = False);
    function InlineTrivia(T: TToken): TStringArray;
    function Tx(X: TObject; First: Boolean = False): string;
    function R(X: TObject; First: Boolean = False): string;
    function Seq(const Kids: TKids; First: Boolean = False): string;
    function Bracketed(N: TNode; First: Boolean): string;
    function JoinTokens(N: TNode; First: Boolean): string;
    function JoinKids(N: TNode; First: Boolean): string;
    procedure ArrayParts(Ty: TNode; First: Boolean; out Head: string; out Elem: TObject);
    function HasRecord(Ty: TObject): Boolean;
    procedure EmitType(const Prefix: string; Ty: TObject; Indent: Integer; const Suffix: string);
    procedure EmitFields(FL: TNode; Indent: Integer; LastSemi: Boolean = True);
    procedure EmitVariant(VP: TNode; Indent: Integer);
    procedure EmitVariantEntry(V: TNode; Indent: Integer);
    procedure EmitSection(Sec: TNode; Indent: Integer; Sep: Boolean);
    procedure EmitDecl(Kind: TNodeKind; D: TNode; Indent: Integer);
    function AfterSemicolon(Semi: TToken): TStringArray;
    procedure EmitUses(U: TNode; Sep: Boolean);
    function RoutineHeader(Rt: TNode; out Next: SizeInt): string;
    procedure EmitRoutine(Rt: TNode; Indent: Integer; Sep: Boolean);
    procedure EmitBlock(B: TNode; Indent: Integer; const Term: string = '');
    procedure EmitCompound(C: TNode; Indent: Integer; const Term: string);
    procedure EmitAsm(A: TNode; Indent: Integer; const Term: string);
    procedure EmitStmtList(Lst: TNode; Indent: Integer);
    procedure EmitBranch(Stmt: TNode; Indent: Integer; const Term: string);
    function Simple(S: TNode; First: Boolean): string;
    procedure EmitIf(S: TNode; Indent: Integer; const Term, Prefix: string);
    procedure EmitStmt(S: TNode; Indent: Integer; const Term: string);
    procedure EmitCase(S: TNode; Indent: Integer; const Term: string);
    procedure CaseBody(const Head: string; Stmt: TNode; Indent: Integer);
    function Wrapped: TStringArray;
    procedure CheckConservation;
    procedure EmitUnit(U: TNode);
    procedure EmitPart(Part: TNode);
    procedure EmitInit(Init: TNode);
    procedure EmitProgram(P: TNode);
  public
    constructor Create(ARes: TParseResult; AWidth: Integer; AWarnings: TStrings);
    function Run: string;
  end;

constructor TFormatter.Create(ARes: TParseResult; AWidth: Integer; AWarnings: TStrings);
begin
  Res := ARes;
  Width := AWidth;
  Warnings := AWarnings;
  if Pos(#13#10, Res.Source) > 0 then
    Eol := #13#10
  else
    Eol := #10;
  SetLength(Used, Length(Res.Tokens));
end;

function TFormatter.IsUsed(T: TToken): Boolean;
begin
  Result := Used[T.Idx];
end;

procedure TFormatter.MarkUsed(T: TToken);
begin
  Used[T.Idx] := True;
end;

procedure TFormatter.AddLine(const Text: string; IsCode: Boolean);
begin
  if Count = Length(Lines) then
  begin
    SetLength(Lines, 2 * Count + 64);
    SetLength(Code, 2 * Count + 64);
  end;
  Lines[Count] := Text;
  Code[Count] := IsCode;
  Inc(Count);
end;

procedure TFormatter.Line(Indent: Integer; const Text: string);
begin
  AddLine(StringOfChar(' ', Indent) + Text, True);
end;

procedure TFormatter.Raw(const Text: string);
begin
  AddLine(Text, False);
end;

procedure TFormatter.AppendLast(const Text: string);
begin
  Lines[Count - 1] := Lines[Count - 1] + Text;
end;

function TFormatter.LastLine: string;
begin
  Result := Lines[Count - 1];
end;

procedure TFormatter.Blank;
begin
  if (Count > 0) and (LastLine <> '') then
    Raw('');
end;

procedure TFormatter.Trailing(const Texts: TStringArray);
var
  Add: string;
begin
  if Texts = nil then
    Exit;
  Add := JoinStr(Texts, ' ');
  if (Count > 0) and (LastLine <> '') then
    AppendLast(' ' + Add)
  else
    Raw(Add);
end;

procedure TFormatter.Comment(Indent: Integer; const Text: string);
var
  Parts: TStringArray;
  I: Integer;
begin
  Parts := SplitLines(Text);
  Raw(StringOfChar(' ', Indent) + Parts[0]);
  for I := 1 to High(Parts) do
    Raw(Parts[I]);
end;

procedure TFormatter.Verbatim(const Text: string);
var
  S: string;
begin
  for S in SplitLines(Text) do
    Raw(RStripSpace(S));
end;

procedure TFormatter.Lead(X: TObject; Indent: Integer; Keep: Boolean; Sep: Boolean; OwnTrailing: Boolean);
var
  T: TToken;
  Tv: TTrivia;
  Own, Rest: TOwnItems;
  Item: TOwnItem;
  S: string;
  K: SizeInt;

  procedure EmitItem(const It: TOwnItem);
  begin
    case It.Kind of
      okBlank:
        if Keep and not Sep then
          Blank;
      okVerbatim:
        Verbatim(It.Text);
      okComment:
        if It.Cond <> ckNone then
          Comment(0, It.Text)
        else
          Comment(Indent, It.Text);
    end;
  end;

begin
  T := FirstTok(X);
  if (T = nil) or IsUsed(T) then
    Exit;
  MarkUsed(T);
  Tv := SplitTrivia(T.Leading);
  Own := Tv.Own;
  if OwnTrailing then
  begin
    Own := nil;
    for S in Tv.Trailing do
      PushOwn(Own, okComment, S, False, ckNone);
    for Item in Tv.Own do
      PushOwn(Own, Item.Kind, Item.Text, Item.IsDirective, Item.Cond);
  end
  else
    Trailing(Tv.Trailing);
  if Sep then
  begin
    Rest := nil;
    for Item in Own do
      if Item.Kind <> okBlank then
        PushOwn(Rest, Item.Kind, Item.Text, Item.IsDirective, Item.Cond);
    K := 0;
    while (K < Length(Rest)) and ((Rest[K].Kind = okVerbatim)
      or ((Rest[K].Kind = okComment) and Rest[K].IsDirective and (Rest[K].Cond <> ckOpen))) do
    begin
      EmitItem(Rest[K]);
      Inc(K);
    end;
    Own := Copy(Rest, K, MaxInt);
    Blank;
  end;
  for Item in Own do
    EmitItem(Item);
  if Tv.BlankBeforeToken and Keep and not Sep then
    Blank;
end;

function TFormatter.InlineTrivia(T: TToken): TStringArray;
var
  L: TToken;
begin
  Result := nil;
  for L in T.Leading do
  begin
    if not L.Active then
      raise EFormatError.CreateFmt('inactive conditional code inside a statement or declaration (line %d)', [L.Line]);
    if L.Kind = tkDirective then
    begin
      if CondKind(L) <> ckNone then
        raise EFormatError.CreateFmt('conditional directive inside a statement or expression (line %d)', [L.Line]);
      PushStr(Result, L.Text);
    end
    else if L.Kind = tkComment then
      PushStr(Result, L.Text);
  end;
end;

function TFormatter.Tx(X: TObject; First: Boolean): string;
var
  T: TToken;
  C: TStringArray;
begin
  T := Tok(X);
  if First then
    Exit(T.Text);
  if IsUsed(T) then
    raise EFormatBug.Create('token emitted twice: ' + TokenRepr(T));
  MarkUsed(T);
  C := InlineTrivia(T);
  if (T.Text = ';') or (T.Text = ',') or (T.Text = ')') or (T.Text = ']') or (T.Text = '.') or (T.Text = '.)') then
  begin
    Result := T.Text;
    if C <> nil then
      Result := Result + ' ' + JoinStr(C, ' ');
  end
  else
  begin
    PushStr(C, T.Text);
    Result := JoinStr(C, ' ');
  end;
end;

function TFormatter.Seq(const Kids: TKids; First: Boolean): string;
var
  Parts: TStringArray;
  Glue, F: Boolean;
  K: TObject;
  S: string;
begin
  Parts := nil;
  Glue := False;
  for K in Kids do
    if IsTok(K, [',', ';', ':']) then
    begin
      S := Tx(K);
      if Parts <> nil then
        Parts[High(Parts)] := Parts[High(Parts)] + S
      else
        PushStr(Parts, S);
    end
    else if IsTok(K, ['..']) then
    begin
      S := Tx(K);
      if Parts <> nil then
        Parts[High(Parts)] := Parts[High(Parts)] + S
      else
        PushStr(Parts, S);
      Glue := True;
    end
    else
    begin
      F := First and (Parts = nil) and not Glue;
      S := R(K, F);
      if Glue and (Parts <> nil) then
      begin
        Parts[High(Parts)] := Parts[High(Parts)] + S;
        Glue := False;
      end
      else
        PushStr(Parts, S);
    end;
  Result := JoinStr(Parts, ' ');
end;

function TFormatter.Bracketed(N: TNode; First: Boolean): string;
var
  Kids: TKids;
  Close: Boolean;
begin
  Kids := N.Kids;
  Close := IsTok(Kids[High(Kids)], [')', ']', '.)']);
  Result := Tx(Kids[0], First);
  if Close then
  begin
    Result := Result + Seq(Slice(Kids, 1, High(Kids)));
    Result := Result + Tx(Kids[High(Kids)]);
  end
  else
    Result := Result + Seq(Slice(Kids, 1, Length(Kids)));
end;

function TFormatter.JoinTokens(N: TNode; First: Boolean): string;
var
  T: TToken;
  I: Integer;
begin
  Result := '';
  I := 0;
  for T in N.Tokens do
  begin
    Result := Result + Tx(T, First and (I = 0));
    Inc(I);
  end;
end;

function TFormatter.JoinKids(N: TNode; First: Boolean): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(N.Kids) do
    Result := Result + R(N.Kids[I], First and (I = 0));
end;

procedure TFormatter.ArrayParts(Ty: TNode; First: Boolean; out Head: string; out Elem: TObject);
var
  K: TKids;
  IOf, I: SizeInt;
begin
  K := Ty.Kids;
  IOf := -1;
  for I := High(K) downto 1 do
    if IsTok(K[I], ['of']) then
    begin
      IOf := I;
      Break;
    end;
  if IOf < 0 then
    raise EFormatError.Create('array without of');
  if IOf = 1 then
  begin
    Head := Tx(K[0], First);
    Head := Head + ' ' + Tx(K[1]) + ' ';
    Elem := K[2];
    Exit;
  end;
  Head := Tx(K[0], First);
  Head := Head + ' ' + Tx(K[1]);
  Head := Head + Seq(Slice(K, 2, IOf - 1));
  Head := Head + Tx(K[IOf - 1]);
  Head := Head + ' ' + Tx(K[IOf]) + ' ';
  Elem := K[IOf + 1];
end;

function TFormatter.R(X: TObject; First: Boolean): string;
var
  N: TNode;
  K: TKids;
  I: SizeInt;
  Head, Body: string;
  Elem: TObject;
begin
  if X is TToken then
    Exit(Tx(X, First));
  N := Nd(X);
  K := N.Kids;
  case N.Kind of
    nkName, nkDeclName, nkLiteral, nkStringLit:
      Result := JoinKids(N, First);
    nkParen, nkIndex, nkArgs, nkSetCtor, nkAggregate, nkParams, nkEnumType, nkHeritage:
      Result := Bracketed(N, First);
    nkUnary:
      begin
        Result := Tx(K[0], First);
        if Tok(K[0]).Kind = tkKW then
          Result := Result + ' ';
        Result := Result + R(K[1]);
      end;
    nkBinary:
      begin
        Result := R(K[0], First);
        Result := Result + ' ' + Tx(K[1]);
        Result := Result + ' ' + R(K[2]);
      end;
    nkDesignator, nkArg:
      Result := JoinKids(N, First);
    nkField:
      begin
        Result := '';
        for I := 0 to High(K) do
          Result := Result + Tx(K[I]);
      end;
    nkDeref:
      Result := Tx(K[0]);
    nkLabels, nkSubrangeType, nkParamGroup, nkFieldDecl, nkFieldList, nkVariantPart:
      Result := Seq(K, First);
    nkInline:
      Result := JoinTokens(N, First);
    nkNamedType:
      Result := R(K[0], First);
    nkPointerType:
      begin
        Result := Tx(K[0], First);
        Result := Result + R(K[1]);
      end;
    nkStringType:
      begin
        Result := Tx(K[0], First);
        if Length(K) > 1 then
        begin
          Result := Result + Tx(K[1]);
          Result := Result + R(K[2]);
          if Length(K) > 3 then
            Result := Result + Tx(K[3]);
        end;
      end;
    nkSetType:
      begin
        Result := Tx(K[0], First);
        Result := Result + ' ' + Tx(K[1]);
        Result := Result + ' ' + R(K[2]);
      end;
    nkFileType:
      begin
        Result := Tx(K[0], First);
        if Length(K) > 1 then
        begin
          Result := Result + ' ' + Tx(K[1]);
          Result := Result + ' ' + R(K[2]);
        end;
      end;
    nkPackedType:
      begin
        Result := Tx(K[0], First);
        Result := Result + ' ' + R(K[1]);
      end;
    nkArrayType:
      begin
        ArrayParts(N, First, Head, Elem);
        Result := Head + R(Elem);
      end;
    nkProcType:
      begin
        Result := Tx(K[0], First);
        I := 1;
        if (I < Length(K)) and IsNode(K[I], nkParams) then
        begin
          Result := Result + R(K[I]);
          Inc(I);
        end;
        if (I < Length(K)) and IsTok(K[I], [':']) then
        begin
          Result := Result + Tx(K[I]);
          Result := Result + ' ' + R(K[I + 1]);
        end;
      end;
    nkRecordType:
      begin
        Body := Seq(Nd(K[1]).Kids);
        Result := Tx(K[0], First);
        if Body <> '' then
          Result := Result + ' ' + Body;
        if Length(K) > 2 then
          Result := Result + ' ' + Tx(K[2])
        else
          Result := Result + ' end';
      end;
    nkInherited:
      begin
        Result := Tx(K[0], First);
        for I := 1 to High(K) do
          Result := Result + ' ' + R(K[I]);
      end;
    nkVariant:
      begin
        Result := R(K[0], First);
        Result := Result + Tx(K[1]);
        Result := Result + ' ' + Tx(K[2]);
        Result := Result + R(K[3]);
        if Length(K) > 4 then
          Result := Result + Tx(K[4]);
      end;
    nkAbsolute:
      begin
        Result := Tx(K[0], First);
        Result := Result + ' ' + R(K[1]);
        if Length(K) > 3 then
        begin
          Result := Result + Tx(K[2]);
          Result := Result + R(K[3]);
        end;
      end;
  else
    raise EFormatError.Create('no layout rule for ' + NodeKindNames[N.Kind]);
  end;
end;

function TFormatter.HasRecord(Ty: TObject): Boolean;
var
  N: TNode;
begin
  if not (Ty is TNode) then
    Exit(False);
  for N in TNode(Ty).Walk do
    if N.Kind in [nkRecordType, nkObjectType] then
      Exit(True);
  Result := False;
end;

procedure TFormatter.EmitType(const Prefix: string; Ty: TObject; Indent: Integer; const Suffix: string);
var
  N: TNode;
  Head: string;
  Elem, K: TObject;
begin
  if IsNode(Ty, nkPackedType) and HasRecord(Ty) then
  begin
    N := Nd(Ty);
    Head := Prefix + Tx(N.Kids[0]) + ' ';
    EmitType(Head, N.Kids[1], Indent, Suffix);
    Exit;
  end;
  if IsNode(Ty, nkArrayType) and HasRecord(Ty) then
  begin
    ArrayParts(Nd(Ty), False, Head, Elem);
    EmitType(Prefix + Head, Elem, Indent, Suffix);
    Exit;
  end;
  if IsNode(Ty, nkRecordType) or IsNode(Ty, nkObjectType) then
  begin
    N := Nd(Ty);
    Head := Prefix + Tx(N.Kids[0]);
    for K in N.Kids do
      if IsNode(K, nkHeritage) then
      begin
        Head := Head + R(K);
        Break;
      end;
    Line(Indent, Head);
    EmitFields(FieldListOf(N), Indent + IndentStep);
    if IsTok(N.Kids[High(N.Kids)], ['end']) then
    begin
      Lead(N.Kids[High(N.Kids)], Indent, False);
      Line(Indent, Tok(N.Kids[High(N.Kids)]).Text + Suffix);
    end;
    Exit;
  end;
  Line(Indent, Prefix + R(Ty) + Suffix);
end;

procedure TFormatter.EmitFields(FL: TNode; Indent: Integer; LastSemi: Boolean);
var
  I, Last, Colon, J: SizeInt;
  K: TObject;
  Kids: TKids;
  Names, Suffix, Text: string;
  Next: SizeInt;
begin
  Last := -1;
  for I := 0 to High(FL.Kids) do
    if FL.Kids[I] is TNode then
      Last := I;
  for I := 0 to High(FL.Kids) do
  begin
    K := FL.Kids[I];
    if K is TToken then
      Lead(K, Indent, False)
    else
      case Nd(K).Kind of
        nkFieldDecl:
          begin
            Lead(K, Indent, False);
            Kids := Nd(K).Kids;
            Colon := -1;
            for J := 0 to High(Kids) do
              if IsTok(Kids[J], [':']) then
                Colon := J;
            if Colon < 0 then
              raise EFormatError.Create('field without a type');
            Names := Seq(Slice(Kids, 0, Colon + 1), True);
            if not LastSemi and (I = Last) then
              Suffix := ''
            else
              Suffix := ';';
            EmitType(Names + ' ', Kids[Colon + 1], Indent, Suffix);
          end;
        nkVariantPart:
          EmitVariant(Nd(K), Indent);
        nkRoutine:
          begin
            Lead(K, Indent, False);
            Text := RoutineHeader(Nd(K), Next);
            Line(Indent, Text);
          end;
        nkSection:
          begin
            Lead(K, Indent - IndentStep, False);
            Line(Indent - IndentStep, Tx(Nd(K).Kids[0], True));
          end;
      else
        raise EFormatError.Create('unexpected ' + NodeKindNames[Nd(K).Kind] + ' in a field list');
      end;
  end;
end;

procedure TFormatter.EmitVariant(VP: TNode; Indent: Integer);
var
  Kids: TKids;
  IOf, I: SizeInt;
  K: TObject;
begin
  Kids := VP.Kids;
  IOf := -1;
  for I := 0 to High(Kids) do
    if IsTok(Kids[I], ['of']) then
    begin
      IOf := I;
      Break;
    end;
  if IOf < 0 then
    raise EFormatError.Create('case without of');
  Lead(Kids[0], Indent, False);
  Line(Indent, Seq(Slice(Kids, 0, IOf + 1), True));
  for I := IOf + 1 to High(Kids) do
  begin
    K := Kids[I];
    if K is TToken then
      Lead(K, Indent + IndentStep, False)
    else if IsNode(K, nkVariant) then
    begin
      Lead(K, Indent + IndentStep, False);
      EmitVariantEntry(Nd(K), Indent + IndentStep);
    end
    else
      raise EFormatError.Create('unexpected ' + NodeKindNames[Nd(K).Kind] + ' in a variant part');
  end;
end;

procedure TFormatter.EmitVariantEntry(V: TNode; Indent: Integer);
var
  Kids: TKids;
  FL: TNode;
  Decls: TNodes;
  X: TObject;
  Multi: Boolean;
  Head, C: string;
  Parts: TStringArray;
begin
  Kids := V.Kids;
  FL := Nd(Kids[3]);
  Decls := nil;
  for X in FL.Kids do
    if X is TNode then
    begin
      SetLength(Decls, Length(Decls) + 1);
      Decls[High(Decls)] := TNode(X);
    end;
  Multi := (Length(Decls) > 1) or ((Length(Decls) = 1) and ((Decls[0].Kind <> nkFieldDecl) or HasRecord(Decls[0])));
  Head := R(Kids[0], True);
  Head := Head + Tx(Kids[1]);
  Head := Head + ' ' + Tx(Kids[2]);
  if not Multi then
  begin
    Parts := nil;
    for X in FL.Kids do
      if X is TNode then
        PushStr(Parts, R(X))
      else
      begin
        C := StripSpace(Copy(Tx(X), 2, MaxInt));
        if C <> '' then
          PushStr(Parts, C);
      end;
    if Length(Kids) > 4 then
    begin
      C := StripSpace(Copy(Tx(Kids[4]), 2, MaxInt));
      if C <> '' then
        PushStr(Parts, C);
    end;
    Line(Indent, Head + JoinStr(Parts, ' ') + ')' + ';');
    Exit;
  end;
  Line(Indent, Head);
  EmitFields(FL, Indent + IndentStep, Length(Decls) > 1);
  if Length(Kids) > 4 then
  begin
    Lead(Kids[4], Indent, False);
    Line(Indent, Tok(Kids[4]).Text + ';');
  end
  else
    AppendLast(';');
end;

procedure TFormatter.EmitSection(Sec: TNode; Indent: Integer; Sep: Boolean);
var
  Kw: TToken;
  DI: Integer;
  Body: TKids;
  I: SizeInt;
begin
  Kw := Tok(Sec.Kids[0]);
  Lead(Kw, Indent, False, Sep);
  Line(Indent, Kw.Text);
  DI := Indent + IndentStep;
  if Sec.Kind = nkLabelSection then
  begin
    Body := Slice(Sec.Kids, 1, Length(Sec.Kids));
    Lead(Body[0], DI, False);
    Line(DI, Seq(Body, True));
    Exit;
  end;
  for I := 1 to High(Sec.Kids) do
  begin
    Lead(Sec.Kids[I], DI, False);
    EmitDecl(Sec.Kind, Nd(Sec.Kids[I]), DI);
  end;
end;

procedure TFormatter.EmitDecl(Kind: TNodeKind; D: TNode; Indent: Integer);
var
  Kids, Body: TKids;
  Semi: TToken;
  Name, Head, Tail, S: string;
  Eq, Colon, I: SizeInt;
begin
  Kids := D.Kids;
  Semi := nil;
  if IsTok(Kids[High(Kids)], [';']) then
  begin
    Semi := Tok(Kids[High(Kids)]);
    Body := Slice(Kids, 0, High(Kids));
  end
  else
    Body := Kids;
  if Kind = nkConstSection then
  begin
    Name := R(Body[0], True);
    if IsTok(Body[1], ['=']) then
    begin
      S := Name + ' ' + Tx(Body[1]);
      S := S + ' ' + R(Body[2]);
      Line(Indent, S + ';');
    end
    else
    begin
      Eq := -1;
      for I := 0 to High(Body) do
        if IsTok(Body[I], ['=']) then
        begin
          Eq := I;
          Break;
        end;
      if Eq < 0 then
        raise EFormatError.Create('typed constant without =');
      Head := Name + Tx(Body[1]) + ' ';
      Tail := ' ' + Tx(Body[Eq]);
      Tail := Tail + ' ' + R(Body[Eq + 1]) + ';';
      EmitType(Head, Body[2], Indent, Tail);
    end;
  end
  else if Kind = nkTypeSection then
  begin
    Head := R(Body[0], True);
    Head := Head + ' ' + Tx(Body[1]) + ' ';
    EmitType(Head, Body[2], Indent, ';');
  end
  else
  begin
    Colon := -1;
    for I := 0 to High(Body) do
      if IsTok(Body[I], [':']) then
      begin
        Colon := I;
        Break;
      end;
    if Colon < 0 then
      raise EFormatError.Create('variable without a type');
    Head := Seq(Slice(Body, 0, Colon + 1), True);
    Tail := '';
    for I := Colon + 2 to High(Body) do
      Tail := Tail + ' ' + R(Body[I]);
    EmitType(Head + ' ', Body[Colon + 1], Indent, Tail + ';');
  end;
  if Semi <> nil then
    Trailing(AfterSemicolon(Semi));
end;

function TFormatter.AfterSemicolon(Semi: TToken): TStringArray;
begin
  MarkUsed(Semi);
  Result := InlineTrivia(Semi);
end;

procedure TFormatter.EmitUses(U: TNode; Sep: Boolean);
begin
  Lead(U.Kids[0], 0, False, Sep);
  Line(0, 'uses');
  Line(IndentStep, Seq(Slice(U.Kids, 1, Length(U.Kids))));
end;

function TFormatter.RoutineHeader(Rt: TNode; out Next: SizeInt): string;
var
  K: TKids;
  I: SizeInt;
  Owner, Decl: TNode;
  D: TObject;
begin
  K := Rt.Kids;
  Result := Tx(K[0], True);
  Result := Result + ' ' + R(K[1]);
  I := 2;
  RoutineNames(Rt, Owner, Decl);
  if Owner <> nil then
  begin
    Result := Result + Tx(K[2]);
    Result := Result + R(K[3]);
    I := 4;
  end;
  if (I < Length(K)) and IsNode(K[I], nkParams) then
  begin
    Result := Result + R(K[I]);
    Inc(I);
  end;
  if (I < Length(K)) and IsTok(K[I], [':']) then
  begin
    Result := Result + Tx(K[I]);
    Result := Result + ' ' + R(K[I + 1]);
    Inc(I, 2);
  end;
  if (I < Length(K)) and IsTok(K[I], [';']) then
  begin
    Result := Result + Tx(K[I]);
    Inc(I);
  end;
  if (I < Length(K)) and IsNode(K[I], nkDirectives) then
  begin
    for D in Nd(K[I]).Kids do
      if IsTok(D, [';']) then
        Result := Result + Tx(D)
      else
        Result := Result + ' ' + R(D);
    Inc(I);
  end;
  Next := I;
end;

procedure TFormatter.EmitRoutine(Rt: TNode; Indent: Integer; Sep: Boolean);
var
  Text: string;
  I: SizeInt;
begin
  Lead(Rt.Kids[0], Indent, False, Sep);
  Text := RoutineHeader(Rt, I);
  Line(Indent, Text);
  if (I < Length(Rt.Kids)) and IsNode(Rt.Kids[I], nkBlock) then
  begin
    EmitBlock(Nd(Rt.Kids[I]), Indent);
    Inc(I);
    if (I < Length(Rt.Kids)) and IsTok(Rt.Kids[I], [';']) then
    begin
      AppendLast(';');
      Trailing(AfterSemicolon(Tok(Rt.Kids[I])));
    end;
  end;
end;

procedure TFormatter.EmitBlock(B: TNode; Indent: Integer; const Term: string);
var
  K: TObject;
begin
  for K in B.Kids do
    case Nd(K).Kind of
      nkConstSection, nkTypeSection, nkVarSection, nkLabelSection:
        EmitSection(Nd(K), Indent, False);
      nkRoutine:
        EmitRoutine(Nd(K), Indent, True);
      nkCompound:
        begin
          Lead(K, Indent, False);
          EmitCompound(Nd(K), Indent, Term);
        end;
      nkAsm:
        begin
          Lead(K, Indent, False);
          EmitAsm(Nd(K), Indent, Term);
        end;
    else
      raise EFormatError.Create('unexpected ' + NodeKindNames[Nd(K).Kind] + ' in a block');
    end;
end;

procedure TFormatter.EmitCompound(C: TNode; Indent: Integer; const Term: string);
begin
  Line(Indent, Tok(C.Kids[0]).Text);
  EmitStmtList(Nd(C.Kids[1]), Indent + IndentStep);
  if Length(C.Kids) > 2 then
  begin
    Lead(C.Kids[2], Indent, False);
    Line(Indent, Tok(C.Kids[2]).Text + Term);
  end;
end;

procedure TFormatter.EmitAsm(A: TNode; Indent: Integer; const Term: string);
var
  Toks: TTokens;
  AsmTok, EndTok: TToken;
  Start, I: SizeInt;
  RawText, First: string;
  Parts: TStringArray;
  HasEnd: Boolean;
begin
  Toks := A.Tokens;
  AsmTok := Toks[0];
  EndTok := Toks[High(Toks)];
  HasEnd := EndTok.Lower = 'end';
  Start := AsmTok.Pos + Length(AsmTok.Text);
  if HasEnd then
    RawText := Copy(Res.Source, Start, EndTok.Pos - Start)
  else
    RawText := Copy(Res.Source, Start, MaxInt);
  for I := 1 to High(Toks) do
    MarkUsed(Toks[I]);
  Parts := SplitLines(RawText);
  First := StripSpace(Parts[0]);
  if First <> '' then
    Line(Indent, AsmTok.Text + ' ' + First)
  else
    Line(Indent, AsmTok.Text);
  for I := 1 to High(Parts) do
    Raw(RStripSpace(Parts[I]));
  if HasEnd then
  begin
    if (Count > 0) and (StripSpace(LastLine) = '') then
      Dec(Count);
    Line(Indent, EndTok.Text + Term);
  end;
end;

procedure TFormatter.EmitStmtList(Lst: TNode; Indent: Integer);
var
  First: Boolean;
  K: TObject;
begin
  First := True;
  for K in Lst.Kids do
    if K is TToken then
      Lead(K, Indent, False)
    else if Nd(K).Kind = nkEmpty then
      Continue
    else if Nd(K).Kind = nkError then
      raise EFormatError.Create('syntax error')
    else
    begin
      Lead(K, Indent, not First);
      First := False;
      EmitStmt(Nd(K), Indent, ';');
    end;
end;

procedure TFormatter.EmitBranch(Stmt: TNode; Indent: Integer; const Term: string);
begin
  if Stmt.Kind = nkEmpty then
  begin
    if (Term <> '') and (Count > 0) then
      AppendLast(Term);
    Exit;
  end;
  if Stmt.Kind = nkCompound then
  begin
    Lead(Stmt, Indent, False);
    EmitStmt(Stmt, Indent, Term);
  end
  else
  begin
    Lead(Stmt, Indent + IndentStep, False);
    EmitStmt(Stmt, Indent + IndentStep, Term);
  end;
end;

function TFormatter.Simple(S: TNode; First: Boolean): string;
begin
  case S.Kind of
    nkAssign:
      begin
        Result := R(S.Kids[0], First);
        Result := Result + ' ' + Tx(S.Kids[1]);
        Result := Result + ' ' + R(S.Kids[2]);
      end;
    nkProcCall:
      Result := R(S.Kids[0], First);
    nkGoto:
      begin
        Result := Tx(S.Kids[0], First);
        if Length(S.Kids) > 1 then
          Result := Result + ' ' + Tx(S.Kids[1]);
      end;
  else
    Result := R(S, First);
  end;
end;

procedure TFormatter.EmitIf(S: TNode; Indent: Integer; const Term, Prefix: string);
var
  K: TKids;
  Head: string;
  HasElse: Boolean;
begin
  K := S.Kids;
  Head := Prefix + Tok(K[0]).Text + ' ' + R(K[1]);
  Head := Head + ' ' + Tx(K[2]);
  Line(Indent, Head);
  HasElse := Length(K) > 4;
  if HasElse then
    EmitBranch(Nd(K[3]), Indent, '')
  else
    EmitBranch(Nd(K[3]), Indent, Term);
  if HasElse then
  begin
    Lead(K[4], Indent, False);
    if IsNode(K[5], nkIf) then
    begin
      Lead(K[5], Indent, False, False, True);
      EmitIf(Nd(K[5]), Indent, Term, Tok(K[4]).Text + ' ');
      Exit;
    end;
    Line(Indent, Tok(K[4]).Text);
    EmitBranch(Nd(K[5]), Indent, Term);
  end;
end;

procedure TFormatter.EmitStmt(S: TNode; Indent: Integer; const Term: string);
var
  K: TKids;
  Head: string;
  Body: TNode;
  Where: Integer;
begin
  K := S.Kids;
  case S.Kind of
    nkCompound:
      EmitCompound(S, Indent, Term);
    nkAssign, nkProcCall, nkGoto, nkInline, nkInherited:
      Line(Indent, Simple(S, True) + Term);
    nkAsm:
      EmitAsm(S, Indent, Term);
    nkLabeled:
      begin
        Head := Tok(K[0]).Text + Tx(K[1]);
        Where := Indent - IndentStep;
        if Where < 0 then
          Where := 0;
        if Nd(K[2]).Kind = nkEmpty then
        begin
          Line(Where, Head + Term);
          Exit;
        end;
        Line(Where, Head);
        Lead(K[2], Indent, False);
        EmitStmt(Nd(K[2]), Indent, Term);
      end;
    nkIf:
      EmitIf(S, Indent, Term, '');
    nkWhile, nkWith, nkFor:
      begin
        if S.Kind = nkWhile then
        begin
          Head := Tok(K[0]).Text + ' ' + R(K[1]);
          Head := Head + ' ' + Tx(K[2]);
          Body := Nd(K[3]);
        end
        else if S.Kind = nkWith then
        begin
          Head := Tok(K[0]).Text + ' ' + Seq(Slice(K, 1, Length(K) - 2));
          Head := Head + ' ' + Tx(K[Length(K) - 2]);
          Body := Nd(K[High(K)]);
        end
        else
        begin
          if Length(K) <> 8 then
            raise EFormatError.Create('syntax error in for');
          Head := Tok(K[0]).Text + ' ' + R(K[1]);
          Head := Head + ' ' + Tx(K[2]);
          Head := Head + ' ' + R(K[3]);
          Head := Head + ' ' + Tx(K[4]);
          Head := Head + ' ' + R(K[5]);
          Head := Head + ' ' + Tx(K[6]);
          Body := Nd(K[7]);
        end;
        Line(Indent, Head);
        EmitBranch(Body, Indent, Term);
      end;
    nkRepeat:
      begin
        Line(Indent, Tok(K[0]).Text);
        EmitStmtList(Nd(K[1]), Indent + IndentStep);
        Lead(K[2], Indent, False);
        Line(Indent, Tok(K[2]).Text + ' ' + R(K[3]) + Term);
      end;
    nkCase:
      EmitCase(S, Indent, Term);
    nkEmpty:
      ;
  else
    raise EFormatError.Create('no layout rule for statement ' + NodeKindNames[S.Kind]);
  end;
end;

procedure TFormatter.EmitCase(S: TNode; Indent: Integer; const Term: string);
var
  K, BK: TKids;
  BI: Integer;
  EndTok: TToken;
  X, Y: TObject;
  I: SizeInt;
  Lst: TNode;
  Stmts: TNodes;
  Head: string;
begin
  K := S.Kids;
  Head := Tok(K[0]).Text + ' ' + R(K[1]);
  Head := Head + ' ' + Tx(K[2]);
  Line(Indent, Head);
  BI := Indent + IndentStep;
  EndTok := nil;
  for I := 3 to High(K) do
  begin
    X := K[I];
    if X is TToken then
    begin
      if Tok(X).Lower = 'end' then
        EndTok := Tok(X)
      else
        Lead(X, BI, False);
    end
    else if IsNode(X, nkCaseBranch) then
    begin
      BK := Nd(X).Kids;
      Lead(BK[0], BI, False);
      Head := R(BK[0], True);
      Head := Head + Tx(BK[1]);
      CaseBody(Head, Nd(BK[2]), BI);
    end
    else if IsNode(X, nkCaseElse) then
    begin
      BK := Nd(X).Kids;
      Lead(BK[0], BI, False);
      Lst := Nd(BK[1]);
      Stmts := nil;
      for Y in Lst.Kids do
        if (Y is TNode) and (TNode(Y).Kind <> nkEmpty) then
        begin
          SetLength(Stmts, Length(Stmts) + 1);
          Stmts[High(Stmts)] := TNode(Y);
        end;
      if (Length(Stmts) = 1) and (Stmts[0].Kind in SimpleKinds + [nkCompound]) then
      begin
        CaseBody(Tok(BK[0]).Text, Stmts[0], BI);
        for Y in Lst.Kids do
          if Y is TToken then
            Lead(Y, BI, False);
      end
      else
      begin
        Line(BI, Tok(BK[0]).Text);
        EmitStmtList(Lst, BI + IndentStep);
      end;
    end
    else
      raise EFormatError.Create('syntax error in case');
  end;
  if EndTok <> nil then
  begin
    Lead(EndTok, Indent, False);
    Line(Indent, EndTok.Text + Term);
  end;
end;

procedure TFormatter.CaseBody(const Head: string; Stmt: TNode; Indent: Integer);
begin
  if Stmt.Kind = nkCompound then
  begin
    Line(Indent, Head + ' ' + Tx(Stmt.Kids[0]));
    EmitStmtList(Nd(Stmt.Kids[1]), Indent + IndentStep);
    if Length(Stmt.Kids) > 2 then
    begin
      Lead(Stmt.Kids[2], Indent, False);
      Line(Indent, Tok(Stmt.Kids[2]).Text + ';');
    end;
  end
  else if Stmt.Kind in SimpleKinds then
    Line(Indent, Head + ' ' + Simple(Stmt, False) + ';')
  else if Stmt.Kind = nkEmpty then
    Line(Indent, Head + ' ;')
  else
  begin
    Line(Indent, Head);
    Lead(Stmt, Indent + IndentStep, False);
    EmitStmt(Stmt, Indent + IndentStep, ';');
  end;
end;

function TFormatter.Wrapped: TStringArray;
var
  I, N: SizeInt;
  S: string;
begin
  Result := nil;
  for I := 0 to Count - 1 do
    if (Width > 0) and Code[I] and (CharLen(Lines[I]) > Width) and not HasNewline(Lines[I]) then
      for S in WrapLine(Lines[I], Width) do
        PushStr(Result, S)
    else
      PushStr(Result, Lines[I]);
  if Warnings <> nil then
    for N := 0 to High(Result) do
      if CharLen(Result[N]) > TpLineLimit then
        Warnings.Add(Format('line %d: %d characters, Turbo Pascal 7 accepts at most %d',
          [N + 1, CharLen(Result[N]), TpLineLimit]));
end;

procedure TFormatter.CheckConservation;
var
  T, L: TToken;
begin
  for T in Res.Sig do
    for L in T.Leading do
      if ((L.Kind in [tkComment, tkDirective]) or not L.Active) and not IsUsed(T) then
        raise EFormatBug.CreateFmt('trivia lost in front of %s (line %d)', [PyRepr(T.Text), T.Line]);
end;

procedure TFormatter.EmitUnit(U: TNode);
var
  K: TKids;
  I: SizeInt;
  S: string;
begin
  K := U.Kids;
  Lead(K[0], 0, False);
  S := Tok(K[0]).Text + ' ' + R(K[1]);
  S := S + Tx(K[2]);
  Line(0, S);
  for I := 3 to High(K) do
  begin
    if K[I] is TToken then
      Continue;
    case Nd(K[I]).Kind of
      nkInterface, nkImplementation:
        EmitPart(Nd(K[I]));
      nkInitSection:
        EmitInit(Nd(K[I]));
      nkError:
        raise EFormatError.Create('syntax error');
    end;
  end;
  if IsTok(K[High(K)], ['.']) then
    AppendLast(Tx(K[High(K)]));
end;

procedure TFormatter.EmitPart(Part: TNode);
var
  I: SizeInt;
  K: TObject;
begin
  Lead(Part.Kids[0], 0, False, True);
  Line(0, Tok(Part.Kids[0]).Text);
  for I := 1 to High(Part.Kids) do
  begin
    K := Part.Kids[I];
    if IsNode(K, nkUsesClause) then
      EmitUses(Nd(K), True)
    else if (K is TNode) and (Nd(K).Kind in SectionKinds) then
      EmitSection(Nd(K), 0, True)
    else if IsNode(K, nkRoutine) then
      EmitRoutine(Nd(K), 0, True)
    else
      raise EFormatError.Create('syntax error');
  end;
end;

procedure TFormatter.EmitInit(Init: TNode);
var
  First: TObject;
begin
  First := Init.Kids[0];
  Lead(First, 0, False, True);
  if IsNode(First, nkCompound) then
    EmitCompound(Nd(First), 0, '')
  else
    Line(0, Tok(First).Text);
end;

procedure TFormatter.EmitProgram(P: TNode);
var
  K, B, T: TObject;
  HK: TKids;
  I: SizeInt;
  S: string;
begin
  for K in P.Kids do
    if K is TToken then
      AppendLast(Tx(K))
    else if IsNode(K, nkProgramHeader) then
    begin
      HK := Nd(K).Kids;
      Lead(HK[0], 0, False);
      S := Tok(HK[0]).Text + ' ' + R(HK[1]);
      for I := 2 to High(HK) do
      begin
        T := HK[I];
        S := S + R(T);
      end;
      Line(0, S);
    end
    else if IsNode(K, nkUsesClause) then
      EmitUses(Nd(K), True)
    else if IsNode(K, nkBlock) then
    begin
      for B in Nd(K).Kids do
        if Nd(B).Kind in SectionKinds then
          EmitSection(Nd(B), 0, True)
        else if Nd(B).Kind = nkRoutine then
          EmitRoutine(Nd(B), 0, True)
        else if Nd(B).Kind = nkCompound then
        begin
          Lead(B, 0, False, True);
          EmitCompound(Nd(B), 0, '');
        end
        else if Nd(B).Kind = nkAsm then
        begin
          Lead(B, 0, False, True);
          EmitAsm(Nd(B), 0, '');
        end
        else
          raise EFormatError.Create('syntax error');
    end
    else
      raise EFormatError.Create('syntax error');
end;

function TFormatter.Run: string;
var
  Root: TObject;
  Body, Src: string;
begin
  if Res.Tree.Kids = nil then
    Exit(Res.Source);
  Root := Res.Tree.Kids[0];
  if IsNode(Root, nkUnit) then
    EmitUnit(Nd(Root))
  else if IsNode(Root, nkProgram) then
    EmitProgram(Nd(Root))
  else
    raise EFormatError.Create('unsupported file structure');
  Lead(Res.Sig[High(Res.Sig)], 0, False);
  Result := JoinStr(Wrapped, Eol);
  Src := Res.Source;
  Body := Src;
  while (Body <> '') and (Body[Length(Body)] = #26) do
    SetLength(Body, Length(Body) - 1);
  if HasNewline(LastChars(Body, 2)) and (Copy(Result, Length(Result) - Length(Eol) + 1, MaxInt) <> Eol) then
    Result := Result + Eol;
  if (Src <> '') and (Src[Length(Src)] = #26) then
    Result := Result + #26;
  CheckConservation;
end;

{ entry points }

function FormatParsed(R: TParseResult; Width: Integer; Warnings: TStrings): string;
var
  F: TFormatter;
begin
  F := TFormatter.Create(R, Width, Warnings);
  try
    Result := F.Run;
  finally
    F.Free;
  end;
end;

function FormatSource(const Src: string): string;
begin
  Result := FormatSource(Src, DefaultDefines);
end;

function FormatSource(const Src: string; const Defines: array of string; Width: Integer;
  Warnings: TStrings; Normalize: Boolean; Provider: TProvider): string;
var
  R: TParseResult;
  T: TToken;
begin
  R := Parse(Src, Defines);
  try
    if R.Diags <> nil then
    begin
      T := R.Diags[0].Token;
      raise EFormatError.CreateFmt('not formatting a file with syntax problems (%d:%d: %s)',
        [T.Line, Utf8Length(Src, T.Pos - T.Col + 1, T.Pos - 1) + 1, R.Diags[0].Message]);
    end;
    if Normalize then
      NormalizeCase(R, Provider);
    Result := FormatParsed(R, Width, Warnings);
  finally
    R.Free;
  end;
end;

end.
