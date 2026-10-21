unit tp7lsp;

{$mode objfpc}{$H+}

interface

uses
  Classes, Contnrs, SysUtils, SyncObjs, fpjson, tp7lex, tp7parse, tp7sema, tp7fmt, tp7stub, tp7index, tp7types,
  tp7maps, tp7os;

const
  ServerName = 'tp7ls';
  ServerVersion = '0.1';
  ParseErrorCode = -32700;
  InvalidRequest = -32600;
  MethodNotFound = -32601;
  InvalidParams = -32602;
  InternalError = -32603;
  ServerNotInitialized = -32002;
  RequestFailed = -32803;
  RequestCancelled = -32800;
  ContentModified = -32801;
  DiagDelay = 0.15;
  DiagMaxDelay = 1.0;
  MaxScanBytes = 2000000;

type
  ERequestError = class(Exception)
  public
    Code: Integer;
    constructor Create(ACode: Integer; const AMessage: string);
  end;

  TLspPos = record
    Line, Ch: Integer;
  end;

  TLspRange = record
    S, E: TLspPos;
  end;

  TBound = class
  public
    Key, Uri, Text: string;
    Res: TParseResult;
    Binder: TBinder;
    Prov: TProvider;
    Lines: TStringArray;
    constructor Create(const AKey, AUri, AText: string; ARes: TParseResult; ABinder: TBinder; AProv: TProvider);
    destructor Destroy; override;
  end;

  TKeyed = record
    Tok: TToken;
    Key: string;
    Sym: TSym;
    Decl: Boolean;
  end;

  TKeyeds = array of TKeyed;

  TDoc = class
  public
    Uri, Text, Path: string;
    Version: TJSONData;
    constructor Create(const AUri: string; AVersion: TJSONData; const AText: string);
    destructor Destroy; override;
  end;

  TTransport = class
  public
    function Read: TJSONData; virtual; abstract;
    procedure Send(Msg: TJSONObject); virtual; abstract;
  end;

  TStreamTransport = class(TTransport)
  private
    FIn, FOut: TStream;
    FBuf: array[0..65535] of Byte;
    FLen, FPos: Integer;
    function Fill: Boolean;
    function ReadLine(out Line: RawByteString): Boolean;
    function ReadBytes(N: Integer; out Data: RawByteString): Boolean;
  public
    constructor Create(AIn, AOut: TStream);
    function Read: TJSONData; override;
    procedure Send(Msg: TJSONObject); override;
  end;

  TPending = record
    Uri: string;
    First, Last: Double;
  end;

  TInbox = class
  private
    FLock: TCriticalSection;
    FEvent: TEvent;
    FItems: TFPList;
    FClosed: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Put(Msg: TJSONData);
    procedure Close;
    function Get(Timeout: Integer; out Msg: TJSONData; out Ended: Boolean): Boolean;
    function ChangeWaiting(const Uri: string): Boolean;
  end;

  TServer = class;

  TReader = class(TThread)
  public
    Server: TServer;
    procedure Execute; override;
  end;

  TServer = class
  private
    FGraveBounds, FGraveProvs, FGraveMisc: TObjectList;
    FCancelLock: TCriticalSection;
    FCancelled: TStringList;
    FReports: TJSONArray;
    FReportLines: TStringArray;
    FReader: TReader;
    procedure Bury;
    procedure DropProvider(P: TProvider);
    procedure AddReport(Tok: TToken; const Msg: string);
  public
    Channel: TTransport;
    Docs: TStrMap;
    Roots: TStringArray;
    Tp7Dir, Tpl: string;
    Stubs: TStubStore;
    BoundCache: TStrMap;
    ProvCache: TObjectList;
    CanWatch: Boolean;
    Inlay: TJSONObject;
    TypeChecks: Boolean;
    Index: TProjectIndex;
    SymbolCache: TStrMap;
    Hierarchical: Boolean;
    Initialized, Shutdown: Boolean;
    Inbox: TInbox;
    Pending: array of TPending;
    ExitCode: Integer;
    HasExitCode: Boolean;
    Utf8Positions: Boolean;
    constructor Create(ATransport: TTransport);
    destructor Destroy; override;
    procedure Reply(Id: TJSONData; Result: TJSONData);
    procedure ReplyError(Id: TJSONData; Code: Integer; const Message: string);
    procedure Notify(const Method: string; Params: TJSONData);
    procedure Cancel(Id: TJSONData);
    function IsCancelled(Id: TJSONData): Boolean;
    function Run: Integer;
    function ReaderFinished: Boolean;
    function PendingIndex(const Uri: string): Integer;
    procedure SchedulePending(const Uri: string);
    procedure DropPending(const Uri: string);
    procedure ScheduleDiagnostics(Doc: TDoc);
    procedure FlushDiagnostics(Force: Boolean = False);
    procedure DispatchMsg(Msg: TJSONObject);
    function Handle(const Method, Original: string; P: TJSONObject; IsRequest: Boolean): TJSONData;
    function DocOf(P: TJSONObject; Required: Boolean = True): TDoc;
    function IsStub(const Path: string): Boolean;
    function ProviderFor(Doc: TDoc; IncludeSelf: Boolean = False; Texts: TStrMap = nil): TProvider;
    function BindDoc(Doc: TDoc; Prov: TProvider): TBound;
    function NewBound(const Key, Uri, Text: string; Prov: TProvider; WithIncludes: Boolean = False): TBound;
    function DocKey(Doc: TDoc): string;
    procedure Publish(Doc: TDoc);
    function Diagnose(Doc: TDoc): TJSONArray;
    function SemanticDiagnostics(Doc: TDoc; Bound: TBound; Prov: TProvider): TJSONArray;
    function UnusedItems(Doc: TDoc; Bound: TBound; Prov: TProvider): TObjectList;
    procedure RefreshDependents(Changed: TDoc; OnlyUnits: Boolean = True; OnlyIncludes: Boolean = False);
    function FormatText(Doc: TDoc): string;
  end;

function Units(const S: string): Integer;
function SplitLines(const Text: string): TStringArray;
function SplitNL(const Text: string): TStringArray;
function TokenRange(Tok: TToken; const Lines: TStringArray; Raw: Boolean = False): TLspRange;
function RangeJSON(const R: TLspRange): TJSONObject;
function PosJSON(const P: TLspPos): TJSONObject;
function ComputeEdits(const Old, New: string): TJSONArray;
function RangeEdits(const Old, New: string; First, Last: Integer): TJSONArray;
function UriToPath(const Uri: string; out Path: string): Boolean;
function PathToUri(const Path: string): string;
function DocumentSymbols(const Text: string): TJSONArray;
function Compact(const Toks: TTokens; Limit: Integer = 80): string;

var
  PositionsInBytes: Boolean = False;

implementation

uses
  jsonparser, tp7enc, tp7diff;

procedure Log(const Msg: string);
begin
  WriteLn(StdErr, '[', ServerName, '] ', Msg);
  Flush(StdErr);
end;

constructor ERequestError.Create(ACode: Integer; const AMessage: string);
begin
  inherited Create(AMessage);
  Code := ACode;
end;

{ text helpers }

function Units(const S: string): Integer;
begin
  if PositionsInBytes then
    Result := Length(S)
  else
    Result := Utf16Length(S);
end;

function UnitsToBytes(const S: string; N: Integer): Integer;
var
  I, U: Integer;
  B: Byte;
begin
  if PositionsInBytes then
  begin
    if N > Length(S) then
      N := Length(S);
    if N < 0 then
      N := 0;
    Exit(N);
  end;
  I := 1;
  U := 0;
  while (I <= Length(S)) and (U < N) do
  begin
    B := Ord(S[I]);
    if B >= $F0 then
      Inc(U, 2)
    else
      Inc(U);
    Inc(I);
    while (I <= Length(S)) and (Ord(S[I]) and $C0 = $80) do
      Inc(I);
  end;
  Result := I - 1;
end;

function CharsBefore(const S: string; N: Integer): string;
begin
  Result := Copy(S, 1, UnitsToBytes(S, N));
end;

function CharsFrom(const S: string; N: Integer): string;
begin
  Result := Copy(S, UnitsToBytes(S, N) + 1, MaxInt);
end;

function UnitsOf(const S: string; N: Integer): Integer;
var
  I: Integer;
  B: Byte;
begin
  if N > Length(S) then
    N := Length(S);
  if PositionsInBytes then
    Exit(N);
  Result := 0;
  for I := 1 to N do
  begin
    B := Ord(S[I]);
    if B and $C0 <> $80 then
      Inc(Result);
    if B >= $F0 then
      Inc(Result);
  end;
end;

function IsAbsPath(const S: string): Boolean;
begin
{$IFDEF WINDOWS}
  Result := ((Length(S) >= 3) and (S[2] = ':') and (S[3] in ['\', '/'])) or ((S <> '') and (S[1] in ['\', '/']));
{$ELSE}
  Result := (S <> '') and (S[1] = '/');
{$ENDIF}
end;

function IsNL(C: Char): Boolean; inline;
begin
  Result := (C = #13) or (C = #10);
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
  I := 1;
  Start := 1;
  while I <= Length(Text) do
  begin
    if Text[I] = #13 then
    begin
      if (I < Length(Text)) and (Text[I + 1] = #10) then
        Inc(I);
      PushStr(Result, Copy(Text, Start, I - Start + 1));
      Start := I + 1;
    end
    else if Text[I] = #10 then
    begin
      PushStr(Result, Copy(Text, Start, I - Start + 1));
      Start := I + 1;
    end;
    Inc(I);
  end;
  if Start <= Length(Text) then
    PushStr(Result, Copy(Text, Start, MaxInt));
end;

function SplitNL(const Text: string): TStringArray;
var
  I, Start: SizeInt;
begin
  Result := nil;
  I := 1;
  Start := 1;
  while I <= Length(Text) do
  begin
    if Text[I] = #13 then
    begin
      PushStr(Result, Copy(Text, Start, I - Start));
      if (I < Length(Text)) and (Text[I + 1] = #10) then
        Inc(I);
      Start := I + 1;
    end
    else if Text[I] = #10 then
    begin
      PushStr(Result, Copy(Text, Start, I - Start));
      Start := I + 1;
    end;
    Inc(I);
  end;
  PushStr(Result, Copy(Text, Start, MaxInt));
end;

function HasEol(const Line: string): Boolean;
begin
  Result := (Line <> '') and IsNL(Line[Length(Line)]);
end;

function LineAt(const Lines: TStringArray; N: Integer): string;
begin
  if (N >= 0) and (N <= High(Lines)) then
    Result := Lines[N]
  else
    Result := '';
end;

function MkPos(Line, Ch: Integer): TLspPos;
begin
  Result.Line := Line;
  Result.Ch := Ch;
end;

function MkRange(const S, E: TLspPos): TLspRange;
begin
  Result.S := S;
  Result.E := E;
end;

function PosLess(const A, B: TLspPos): Boolean;
begin
  Result := (A.Line < B.Line) or ((A.Line = B.Line) and (A.Ch < B.Ch));
end;

function PosLE(const A, B: TLspPos): Boolean;
begin
  Result := not PosLess(B, A);
end;

function PosJSON(const P: TLspPos): TJSONObject;
begin
  Result := TJSONObject.Create(['line', P.Line, 'character', P.Ch]);
end;

function RangeJSON(const R: TLspRange): TJSONObject;
begin
  Result := TJSONObject.Create(['start', PosJSON(R.S), 'end', PosJSON(R.E)]);
end;

function TokenRange(Tok: TToken; const Lines: TStringArray; Raw: Boolean): TLspRange;
var
  Ln, I, Start, NLines: Integer;
  TextLine, Last: string;
begin
  if not Raw and (Tok.Via <> nil) then
    Tok := Tok.Via;
  Ln := Tok.Line - 1;
  TextLine := LineAt(Lines, Ln);
  Result.S := MkPos(Ln, UnitsOf(TextLine, Tok.Col - 1));
  NLines := 0;
  Start := 1;
  I := 1;
  while I <= Length(Tok.Text) do
  begin
    if Tok.Text[I] = #13 then
    begin
      if (I < Length(Tok.Text)) and (Tok.Text[I + 1] = #10) then
        Inc(I);
      Inc(NLines);
      Start := I + 1;
    end
    else if Tok.Text[I] = #10 then
    begin
      Inc(NLines);
      Start := I + 1;
    end;
    Inc(I);
  end;
  if NLines = 0 then
    Result.E := MkPos(Ln, Result.S.Ch + Units(Tok.Text))
  else
  begin
    Last := Copy(Tok.Text, Start, MaxInt);
    Result.E := MkPos(Ln + NLines, Units(Last));
  end;
end;

function ComputeEdits(const Old, New: string): TJSONArray;
var
  A, B: TStringArray;
  P, S, EndLine, I: Integer;
  E: TLspPos;
  Text: string;
  Same: Boolean;
begin
  Result := TJSONArray.Create;
  A := SplitLines(Old);
  B := SplitLines(New);
  Same := Length(A) = Length(B);
  if Same then
    for I := 0 to High(A) do
      if A[I] <> B[I] then
      begin
        Same := False;
        Break;
      end;
  if Same then
    Exit;
  P := 0;
  while (P < Length(A)) and (P < Length(B)) and (A[P] = B[P]) do
    Inc(P);
  S := 0;
  while (S < Length(A) - P) and (S < Length(B) - P) and (A[High(A) - S] = B[High(B) - S]) do
    Inc(S);
  EndLine := Length(A) - S;
  if (EndLine = Length(A)) and (A <> nil) and not HasEol(A[High(A)]) then
    E := MkPos(High(A), Units(A[High(A)]))
  else
    E := MkPos(EndLine, 0);
  Text := '';
  for I := P to Length(B) - S - 1 do
    Text := Text + B[I];
  Result.Add(TJSONObject.Create(['range', RangeJSON(MkRange(MkPos(P, 0), E)), 'newText', Text]));
end;

function RangeEdits(const Old, New: string; First, Last: Integer): TJSONArray;
var
  A, B: TStringArray;
  Ops: TOpcodes;
  O: TOpcode;
  K, I: Integer;
  Touches, Same: Boolean;
  E: TLspPos;
  Text: string;
begin
  Result := TJSONArray.Create;
  A := SplitLines(Old);
  B := SplitLines(New);
  Same := Length(A) = Length(B);
  if Same then
    for I := 0 to High(A) do
      if A[I] <> B[I] then
      begin
        Same := False;
        Break;
      end;
  if Same then
    Exit;
  Ops := LineOpcodes(A, B, False);
  for O in Ops do
  begin
    if O.Tag = opEqual then
      Continue;
    if (O.Tag = opReplace) and (O.I2 - O.I1 = O.J2 - O.J1) and (O.I2 < Length(A)) then
    begin
      for K := 0 to O.I2 - O.I1 - 1 do
        if (First <= O.I1 + K) and (O.I1 + K <= Last) and (A[O.I1 + K] <> B[O.J1 + K]) then
          Result.Add(TJSONObject.Create(['range', RangeJSON(MkRange(MkPos(O.I1 + K, 0), MkPos(O.I1 + K + 1, 0))),
            'newText', B[O.J1 + K]]));
      Continue;
    end;
    if O.I1 = O.I2 then
      Touches := (First <= O.I1) and (O.I1 <= Last + 1)
    else
      Touches := (O.I1 <= Last) and (O.I2 > First);
    if not Touches then
      Continue;
    Text := '';
    for I := O.J1 to O.J2 - 1 do
      Text := Text + B[I];
    if (O.I2 = Length(A)) and (A <> nil) and not HasEol(A[High(A)]) then
    begin
      E := MkPos(High(A), Units(A[High(A)]));
      if O.I1 = O.I2 then
        Continue;
    end
    else
      E := MkPos(O.I2, 0);
    Result.Add(TJSONObject.Create(['range', RangeJSON(MkRange(MkPos(O.I1, 0), E)), 'newText', Text]));
  end;
end;

function IsKind(X: TObject; K: TNodeKind): Boolean; inline;
begin
  Result := (X is TNode) and (TNode(X).Kind = K);
end;

function TokText(X: TObject): string;
begin
  if X is TToken then
    Result := TToken(X).Text
  else
    Result := '';
end;

function IdentAt(const Sig: TTokens; const Lines: TStringArray; Line, Character: Integer): TToken;
var
  Tok: TToken;
  R: TLspRange;
begin
  for Tok in Sig do
  begin
    if not (Tok.Kind in [tkIdent, tkInt]) or (Tok.Line - 1 <> Line) then
      Continue;
    R := TokenRange(Tok, Lines);
    if (R.S.Ch <= Character) and (Character <= R.E.Ch) then
      Exit(Tok);
  end;
  Result := nil;
end;

function TokenUnder(const Sig: TTokens; const Lines: TStringArray; Line, Character: Integer): TToken;
var
  Tok: TToken;
  R: TLspRange;
begin
  for Tok in Sig do
  begin
    if Tok.Line - 1 <> Line then
      Continue;
    R := TokenRange(Tok, Lines);
    if (R.S.Ch <= Character) and (Character < R.E.Ch) and (R.E.Line = Line) then
      Exit(Tok);
  end;
  Result := nil;
end;

function TokensBefore(const Sig: TTokens; const Lines: TStringArray; const Here: TLspPos): TTokens;
var
  Tok: TToken;
  N: Integer;
begin
  Result := nil;
  N := 0;
  for Tok in Sig do
    if PosLess(TokenRange(Tok, Lines).S, Here) then
      Inc(N)
    else
      Break;
  Result := Copy(Sig, 0, N);
end;

const
  CallStop: array[0..14] of string = ('begin', 'end', 'then', 'do', 'else', 'of', 'repeat', 'until', 'var', 'const',
    'type', 'procedure', 'function', 'implementation', 'interface');

function InList(const S: string; const A: array of string): Boolean;
var
  X: string;
begin
  for X in A do
    if X = S then
      Exit(True);
  Result := False;
end;

function CallContext(const Sig: TTokens; const Lines: TStringArray; Line, Character: Integer; out Tok: TToken;
  out Commas: Integer): Boolean;
var
  Before: TTokens;
  Depth, I: Integer;
  T: TToken;
  Text: string;
begin
  Tok := nil;
  Commas := 0;
  Result := False;
  Before := TokensBefore(Sig, Lines, MkPos(Line, Character));
  Depth := 0;
  for I := High(Before) downto 0 do
  begin
    T := Before[I];
    Text := T.Text;
    if T.Kind in [tkString, tkComment] then
      Continue;
    if (Text = ')') or (Text = ']') then
      Inc(Depth)
    else if (Text = '(') or (Text = '[') then
    begin
      if Depth > 0 then
        Dec(Depth)
      else if Text = '(' then
      begin
        if (I > 0) and (Before[I - 1].Kind = tkIdent) then
        begin
          Tok := Before[I - 1];
          Exit(True);
        end;
        Commas := 0;
      end
      else
        Commas := 0;
    end
    else if Depth = 0 then
    begin
      if Text = ',' then
        Inc(Commas)
      else if (Text = ';') or ((T.Kind <> tkIdent) and InList(LowerText(Text), CallStop)) then
        Exit(False);
    end;
  end;
end;

type
  TSpan = record
    A, B: Integer;
  end;

  TSpans = array of TSpan;

function IsSpaceOrBracket(C: Char): Boolean;
begin
  Result := C in [' ', '[', ']'];
end;

function SignatureParams(const Lab: string): TSpans;
type
  TSeg = record
    A, B: Integer;
  end;
var
  O, Depth, EndAt, I, Start, A, B, Kw, Colon, J, K, First: Integer;
  Len: SizeInt;
  Segs: array of TSeg;
  Seg: TSeg;
  Ch: Char;
  Text, Names, Word: string;
  Found: TSpans;
begin
  Result := nil;
  O := Pos('(', Lab);
  if O = 0 then
    Exit;
  O := O - 1;
  Depth := 0;
  EndAt := Length(Lab);
  for I := O to Length(Lab) - 1 do
    if Lab[I + 1] = '(' then
      Inc(Depth)
    else if Lab[I + 1] = ')' then
    begin
      Dec(Depth);
      if Depth = 0 then
      begin
        EndAt := I;
        Break;
      end;
    end;
  Segs := nil;
  Start := O + 1;
  Depth := 0;
  for I := O + 1 to EndAt do
  begin
    if I < EndAt then
      Ch := Lab[I + 1]
    else
      Ch := ';';
    if Ch = '(' then
      Inc(Depth)
    else if Ch = ')' then
      Dec(Depth)
    else if (Ch = ';') and (Depth <= 0) then
    begin
      SetLength(Segs, Length(Segs) + 1);
      Segs[High(Segs)].A := Start;
      Segs[High(Segs)].B := I;
      Start := I + 1;
    end;
  end;
  for Seg in Segs do
  begin
    A := Seg.A;
    B := Seg.B;
    while (A < B) and IsSpaceOrBracket(Lab[A + 1]) do
      Inc(A);
    while (B > A) and IsSpaceOrBracket(Lab[B]) do
      Dec(B);
    if B <= A then
      Continue;
    Text := Copy(Lab, A + 1, B - A);
    Kw := 0;
    Word := LowerText(Copy(Text, 1, 5));
    if (Copy(Word, 1, 3) = 'var') and (Length(Text) > 3) and (SpaceLen(Text, 4) > 0) then
      Kw := 3
    else if (Word = 'const') and (Length(Text) > 5) and (SpaceLen(Text, 6) > 0) then
      Kw := 5;
    if Kw > 0 then
      while (Kw < Length(Text)) and (SpaceLen(Text, Kw + 1) > 0) do
        Inc(Kw, SpaceLen(Text, Kw + 1));
    Colon := Pos(':', Text) - 1;
    if Colon >= 0 then
      Names := Copy(Text, Kw + 1, Colon - Kw)
    else
      Names := Copy(Text, Kw + 1, MaxInt);
    Found := nil;
    J := 1;
    while J <= Length(Names) do
    begin
      if Names[J] in ['A'..'Z', 'a'..'z', '_'] then
      begin
        First := J;
        K := J + 1;
        while IsWordAt(Names, K, Len) do
          Inc(K, Len);
        SetLength(Found, Length(Found) + 1);
        Found[High(Found)].A := A + Kw + First - 1;
        Found[High(Found)].B := A + Kw + K - 1;
        J := K;
      end
      else
        Inc(J);
    end;
    if Found <> nil then
    begin
      Found[0].A := A;
      if (Colon >= 0) and (Pos('[', Text) = 0) then
        Found[High(Found)].B := B;
      for I := 0 to High(Found) do
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Found[I];
      end;
    end;
  end;
end;

const
  PasKeywords: array[0..48] of string = ('and', 'array', 'asm', 'begin', 'case', 'const', 'constructor', 'destructor',
    'div', 'do', 'downto', 'else', 'end', 'file', 'for', 'function', 'goto', 'if', 'implementation', 'in',
    'inherited', 'inline', 'interface', 'label', 'mod', 'nil', 'not', 'object', 'of', 'or', 'packed', 'procedure',
    'program', 'record', 'repeat', 'set', 'shl', 'shr', 'string', 'then', 'to', 'type', 'unit', 'until', 'uses',
    'var', 'while', 'with', 'xor');
  CkMethod = 2;
  CkFunction = 3;
  CkConstructor = 4;
  CkField = 5;
  CkVariable = 6;
  CkClass = 7;
  CkModule = 9;
  CkKeyword = 14;
  CkConstant = 21;
  CkEnumMember = 20;
  CkStruct = 22;
  CkReference = 18;
  NoNameAfter: array[0..6] of string = ('procedure', 'function', 'constructor', 'destructor', 'program', 'unit',
    'label');

function FirstToken(Node: TNode): TToken;
var
  K: TObject;
begin
  for K in Node.Kids do
  begin
    if K is TToken then
      Exit(TToken(K));
    Result := FirstToken(TNode(K));
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function LastToken(Node: TNode): TToken;
var
  I: Integer;
begin
  for I := High(Node.Kids) downto 0 do
  begin
    if Node.Kids[I] is TToken then
      Exit(TToken(Node.Kids[I]));
    Result := LastToken(TNode(Node.Kids[I]));
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function ToksOf(X: TObject): TTokens;
begin
  if X is TToken then
    Result := [TToken(X)]
  else if X is TNode then
    Result := TNode(X).Tokens
  else
    Result := nil;
end;

function ToksOfKids(const Kids: TKids; From, Upto: Integer): TTokens;
var
  I: Integer;
begin
  Result := nil;
  if From < 0 then
    From := 0;
  for I := From to Upto - 1 do
    if I <= High(Kids) then
      Result := Concat(Result, ToksOf(Kids[I]));
end;

function SignatureToks(R: TNode): TTokens;
var
  Owner, Decl: TNode;
  Start, EndAt, I: Integer;
begin
  RoutineNames(R, Owner, Decl);
  if Owner <> nil then
    Start := 4
  else
    Start := 2;
  EndAt := Length(R.Kids);
  for I := Start to High(R.Kids) do
    if IsTok(R.Kids[I], ';') then
    begin
      EndAt := I;
      Break;
    end;
  Result := ToksOfKids(R.Kids, Start, EndAt);
end;

const
  Tight: array[0..11, 0..1] of string = ((' ,', ','), (' ;', ';'), (' :', ':'), ('( ', '('), (' )', ')'),
    ('[ ', '['), (' ]', ']'), (' ..', '..'), ('.. ', '..'), ('^ ', '^'), (' .', '.'), ('. ', '.'));
  Ellipsis = #$E2#$80#$A6;

function Compact(const Toks: TTokens; Limit: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Toks) do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + Toks[I].Text;
  end;
  for I := 0 to High(Tight) do
    Result := StringReplace(Result, Tight[I, 0], Tight[I, 1], [rfReplaceAll]);
  if Utf8Length(Result, 1, Length(Result)) > Limit then
    Result := CharCopy(Result, Limit - 1) + Ellipsis;
end;

function KindOfObj(X: TObject): TNodeKind;
begin
  if X is TNode then
    Result := TNode(X).Kind
  else
    Result := nkError;
end;

function KeywordOf(Node: TNode): string;
begin
  if (Node <> nil) and (Node.Kids <> nil) and (Node.Kids[0] is TToken) then
    Result := LowerText(TToken(Node.Kids[0]).Text)
  else
    Result := '';
end;

function CompletionKind(Sym: TSym): Integer;
var
  Inner: TObject;
  Kw: string;
begin
  case Sym.Kind of
    skRoutine, skBuiltin:
      begin
        if Sym.MethodKind <> '' then
        begin
          if (Sym.MethodKind = 'constructor') or (Sym.MethodKind = 'destructor') then
            Exit(CkConstructor);
          Exit(CkMethod);
        end;
        if Sym.Owner <> nil then
        begin
          Kw := '';
          if (Sym.Node <> nil) and (Sym.Node.Kids <> nil) then
            Kw := LowerText(KT(Sym.Node.Kids[0]).Text);
          if (Kw = 'constructor') or (Kw = 'destructor') then
            Exit(CkConstructor);
          Exit(CkMethod);
        end;
        Result := CkFunction;
      end;
    skType:
      begin
        Inner := Sym.TNode;
        while IsKind(Inner, nkPackedType) and (Length(TNode(Inner).Kids) > 1) do
          Inner := TNode(Inner).Kids[1];
        if IsKind(Inner, nkObjectType) then
          Result := CkClass
        else
          Result := CkStruct;
      end;
    skVar, skParam:
      Result := CkVariable;
    skConst:
      Result := CkConstant;
    skEnum:
      Result := CkEnumMember;
    skField:
      Result := CkField;
    skUnit:
      Result := CkModule;
  else
    Result := CkVariable;
  end;
end;

function SigText(const Sig: string): string;
begin
  if Copy(Sig, 1, 1) = '(' then
    Result := Sig
  else if Sig <> '' then
    Result := ' ' + Sig
  else
    Result := '';
end;

function CompletionDetail(Sym: TSym): string;
begin
  if (Sym.Kind = skRoutine) and (Sym.Node <> nil) and (Sym.Node.Kids <> nil) then
    Exit(SigText(StringReplace(Compact(SignatureToks(Sym.Node), 120), ' :', ':', [rfReplaceAll])));
  if Sym.Lib and (Sym.Home <> '') then
    Exit('unit ' + Sym.Home);
  if Sym.Kind = skUnit then
    Result := 'unit'
  else if Sym.Kind = skBuiltin then
    Result := 'System'
  else
    Result := '';
end;

function MemberChain(const Before: TTokens; out Chain: TChain): Boolean;
var
  I, J, Depth, Commas: Integer;
  T: TToken;
  X, Close: string;
  Rev: TChain;

  procedure Add(K: TChainKind; const Text: string; N: Integer);
  begin
    SetLength(Rev, Length(Rev) + 1);
    Rev[High(Rev)].Kind := K;
    Rev[High(Rev)].Text := Text;
    Rev[High(Rev)].N := N;
  end;

begin
  Chain := nil;
  Rev := nil;
  Result := False;
  I := High(Before);
  while I >= 0 do
  begin
    T := Before[I];
    if T.Text = '^' then
    begin
      Add(ckDeref, '', 0);
      Dec(I);
    end
    else if (T.Text = ')') or (T.Text = ']') then
    begin
      Close := T.Text;
      Depth := 0;
      Commas := 0;
      J := I;
      while J >= 0 do
      begin
        X := Before[J].Text;
        if (X = ')') or (X = ']') then
          Inc(Depth)
        else if (X = '(') or (X = '[') then
        begin
          Dec(Depth);
          if Depth = 0 then
            Break;
        end
        else if (X = ',') and (Depth = 1) then
          Inc(Commas);
        Dec(J);
      end;
      if J < 0 then
        Exit(False);
      if Close = ']' then
        Add(ckIndex, '', Commas + 1)
      else
        Add(ckCall, '', 0);
      I := J - 1;
    end
    else if T.Kind = tkIdent then
    begin
      Add(ckName, T.Text, 0);
      if (I > 0) and (Before[I - 1].Text = '.') then
      begin
        Dec(I, 2);
        Continue;
      end;
      SetLength(Chain, Length(Rev));
      for J := 0 to High(Rev) do
        Chain[J] := Rev[High(Rev) - J];
      Exit(True);
    end
    else
      Exit(False);
  end;
end;

type
  TSel = record
    A, B: TLspPos;
  end;

  TSels = array of TSel;

function NodeSpan(Node: TNode; const Lines: TStringArray; out Sp: TSel): Boolean;
var
  A, B: TToken;
begin
  A := FirstToken(Node);
  B := LastToken(Node);
  Result := (A <> nil) and (B <> nil);
  if Result then
  begin
    Sp.A := TokenRange(A, Lines).S;
    Sp.B := TokenRange(B, Lines).E;
  end;
end;

function SelLess(const X, Y: TSel): Boolean;
var
  DX, DY, CX, CY: Integer;
begin
  DX := X.B.Line - X.A.Line;
  DY := Y.B.Line - Y.A.Line;
  if DX <> DY then
    Exit(DX < DY);
  if X.A.Line = X.B.Line then
    CX := X.B.Ch - X.A.Ch
  else
    CX := 0;
  if Y.A.Line = Y.B.Line then
    CY := Y.B.Ch - Y.A.Ch
  else
    CY := 0;
  Result := CX < CY;
end;

function SameSel(const X, Y: TSel): Boolean;
begin
  Result := (X.A.Line = Y.A.Line) and (X.A.Ch = Y.A.Ch) and (X.B.Line = Y.B.Line) and (X.B.Ch = Y.B.Ch);
end;

function SelectionChain(Res: TParseResult; const Lines: TStringArray; Line, Character: Integer): TSels;
var
  Here: TLspPos;
  Spans: TSels;
  Node, Nxt: TNode;
  Sp, KS, NS: TSel;
  K: TObject;
  R: TLspRange;
  I, J: Integer;
  X: TSel;
  HasLast: Boolean;
  Last: TSel;

  procedure AddSpan(const S: TSel);
  begin
    SetLength(Spans, Length(Spans) + 1);
    Spans[High(Spans)] := S;
  end;

begin
  Here := MkPos(Line, Character);
  Spans := nil;
  Node := Res.Tree;
  while Node <> nil do
  begin
    if NodeSpan(Node, Lines, Sp) and PosLE(Sp.A, Here) and PosLE(Here, Sp.B) then
      AddSpan(Sp);
    Nxt := nil;
    for K in Node.Kids do
      if K is TToken then
      begin
        R := TokenRange(TToken(K), Lines);
        if PosLE(R.S, Here) and PosLE(Here, R.E) and (TToken(K).Kind <> tkEOF) then
        begin
          X.A := R.S;
          X.B := R.E;
          AddSpan(X);
        end;
      end
      else if NodeSpan(TNode(K), Lines, KS) and PosLE(KS.A, Here) and PosLE(Here, KS.B) then
      begin
        if Nxt = nil then
          Nxt := TNode(K)
        else
        begin
          NodeSpan(Nxt, Lines, NS);
          if PosLE(NS.A, KS.A) then
            Nxt := TNode(K);
        end;
      end;
    Node := Nxt;
  end;
  for I := 1 to High(Spans) do
  begin
    X := Spans[I];
    J := I - 1;
    while (J >= 0) and SelLess(X, Spans[J]) do
    begin
      Spans[J + 1] := Spans[J];
      Dec(J);
    end;
    Spans[J + 1] := X;
  end;
  Result := nil;
  HasLast := False;
  Last.A := MkPos(0, 0);
  Last.B := MkPos(0, 0);
  for X in Spans do
    if (not HasLast or not SameSel(X, Last)) and (not HasLast or (PosLE(X.A, Last.A) and PosLE(Last.B, X.B))) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := X;
      Last := X;
      HasLast := True;
    end;
end;

function SelectionRange(Res: TParseResult; const Lines: TStringArray; Line, Character: Integer): TJSONObject;
var
  Chain: TSels;
  I: Integer;
  R: TJSONObject;
begin
  Chain := SelectionChain(Res, Lines, Line, Character);
  if Chain = nil then
  begin
    SetLength(Chain, 1);
    Chain[0].A := MkPos(Line, Character);
    Chain[0].B := MkPos(Line, Character);
  end;
  Result := nil;
  for I := High(Chain) downto 0 do
  begin
    R := TJSONObject.Create(['range', RangeJSON(MkRange(Chain[I].A, Chain[I].B))]);
    if Result <> nil then
      R.Add('parent', Result);
    Result := R;
  end;
end;

function IsSubsequence(const Needle, Hay: string): Boolean;
var
  I, J, LN, LH: SizeInt;
  C: LongWord;
begin
  J := 1;
  I := 1;
  while I <= Length(Needle) do
  begin
    C := DecodeUtf8(Needle, I, LN);
    while (J <= Length(Hay)) and (DecodeUtf8(Hay, J, LH) <> C) do
      Inc(J, LH);
    if J > Length(Hay) then
      Exit(False);
    DecodeUtf8(Hay, J, LH);
    Inc(J, LH);
    Inc(I, LN);
  end;
  Result := True;
end;

function WholeLines(const Lines: TStringArray; const S, E: TLspPos): TLspRange;
begin
  if (S.Line < Length(Lines)) and (E.Line < Length(Lines)) and
    (StripSpace(CharsBefore(Lines[S.Line], S.Ch)) = '') and (StripSpace(CharsFrom(Lines[E.Line], E.Ch)) = '') then
    Result := MkRange(MkPos(S.Line, 0), MkPos(E.Line + 1, 0))
  else
    Result := MkRange(S, E);
end;

function NamesEdit(const Lines: TStringArray; const NameToks, Keep: TTokens): TJSONObject;
var
  Text: string;
  I: Integer;
begin
  Text := '';
  for I := 0 to High(Keep) do
  begin
    if I > 0 then
      Text := Text + ', ';
    Text := Text + Keep[I].Text;
  end;
  Result := TJSONObject.Create(['range', RangeJSON(MkRange(TokenRange(NameToks[0], Lines).S,
    TokenRange(NameToks[High(NameToks)], Lines).E)), 'newText', Text]);
end;

function TokenAncestors(Tree: TNode; Tok: TToken): TNodes;
var
  Path: TNodes;
  Node, Nxt: TNode;
  K: TObject;
  A, B: TToken;
  I: Integer;
begin
  Path := nil;
  Result := nil;
  Node := Tree;
  while Node <> nil do
  begin
    SetLength(Path, Length(Path) + 1);
    Path[High(Path)] := Node;
    Nxt := nil;
    for K in Node.Kids do
    begin
      if K = Tok then
      begin
        SetLength(Result, Length(Path));
        for I := 0 to High(Path) do
          Result[I] := Path[High(Path) - I];
        Exit;
      end;
      if K is TNode then
      begin
        A := FirstToken(TNode(K));
        B := LastToken(TNode(K));
        if (A <> nil) and (B <> nil) and (A.Idx <= Tok.Idx) and (Tok.Idx <= B.Idx) then
        begin
          Nxt := TNode(K);
          Break;
        end;
      end;
    end;
    Node := Nxt;
  end;
end;

const
  TypeStarters: array[0..5] of string = ('array', 'record', 'set', 'file', 'string', 'packed');

function InTypePosition(Prev: TToken; const Ancestors: TNodes): Boolean;
var
  Parent: TNode;
  Text: string;
begin
  if (Prev = nil) or (Ancestors = nil) then
    Exit(False);
  Parent := Ancestors[0];
  Text := LowerText(Prev.Text);
  if Text = ':' then
    Exit(Parent.Kind in [nkVarDecl, nkFieldDecl, nkParamGroup, nkConstDecl, nkRoutine]);
  if Text = '=' then
    Exit(Parent.Kind = nkTypeDecl);
  if Text = 'of' then
    Exit(Parent.Kind in [nkArrayType, nkSetType, nkFileType]);
  if Text = '^' then
    Exit(Parent.Kind = nkPointerType);
  Result := (Text = 'packed') and (Parent.Kind = nkPackedType);
end;

const
  SemTypes: array[0..11] of string = ('namespace', 'type', 'enumMember', 'function', 'parameter', 'variable',
    'property', 'label', 'comment', 'macro', 'keyword', 'method');
  SemMods: array[0..2] of string = ('declaration', 'readonly', 'defaultLibrary');
  StComment = 8;
  StMacro = 9;
  StKeyword = 10;
  StMethod = 11;

function SemClass(Sym: TSym; IsDecl: Boolean; out Typ, Mods: Integer): Boolean;
begin
  Result := True;
  case Sym.Kind of
    skUnit: Typ := 0;
    skType: Typ := 1;
    skEnum: Typ := 2;
    skRoutine, skBuiltin: Typ := 3;
    skParam: Typ := 4;
    skVar, skConst: Typ := 5;
    skField: Typ := 6;
    skLabel: Typ := 7;
  else
    Exit(False);
  end;
  if (Sym.Kind = skRoutine) and ((Sym.Owner <> nil) or (Sym.MethodKind <> '')) then
    Typ := StMethod;
  Mods := 0;
  if IsDecl then
    Mods := Mods or 1;
  if Sym.Kind in [skConst, skEnum] then
    Mods := Mods or 2;
  if Sym.Lib then
    Mods := Mods or 4;
end;

type
  TSemItem = record
    Line, Start, Len, Typ, Mods: Integer;
  end;

  TSemItems = array of TSemItem;

function SemLess(const A, B: TSemItem): Boolean;
begin
  if A.Line <> B.Line then
    Exit(A.Line < B.Line);
  if A.Start <> B.Start then
    Exit(A.Start < B.Start);
  if A.Len <> B.Len then
    Exit(A.Len < B.Len);
  if A.Typ <> B.Typ then
    Exit(A.Typ < B.Typ);
  Result := A.Mods < B.Mods;
end;

procedure SortSem(var A: TSemItems; Lo, Hi: Integer);
var
  I, J: Integer;
  P, T: TSemItem;
begin
  while Lo < Hi do
  begin
    P := A[(Lo + Hi) div 2];
    I := Lo;
    J := Hi;
    repeat
      while SemLess(A[I], P) do
        Inc(I);
      while SemLess(P, A[J]) do
        Dec(J);
      if I <= J then
      begin
        T := A[I];
        A[I] := A[J];
        A[J] := T;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    if J - Lo < Hi - I then
    begin
      SortSem(A, Lo, J);
      Lo := I;
    end
    else
    begin
      SortSem(A, I, Hi);
      Hi := J;
    end;
  end;
end;

function RStripSpace(const S: string): string;
var
  I, Len, Stop: SizeInt;
begin
  I := 1;
  Stop := 0;
  while I <= Length(S) do
  begin
    Len := SpaceLen(S, I);
    if Len = 0 then
    begin
      Inc(I);
      while (I <= Length(S)) and (Ord(S[I]) and $C0 = $80) do
        Inc(I);
      Stop := I - 1;
    end
    else
      Inc(I, Len);
  end;
  Result := Copy(S, 1, Stop);
end;

function LStripSpace(const S: string): string;
var
  I, Len: SizeInt;
begin
  I := 1;
  while I <= Length(S) do
  begin
    Len := SpaceLen(S, I);
    if Len = 0 then
      Break;
    Inc(I, Len);
  end;
  Result := Copy(S, I, MaxInt);
end;

function SemanticData(Res: TParseResult; Binder: TBinder; const Lines: TStringArray; First: Integer;
  HasLast: Boolean; Last: Integer): TJSONArray;
var
  Items: TSemItems;
  N: Integer;

  procedure Add(Line, Col: Integer; const Text: string; Typ, Mods: Integer);
  var
    It: TSemItem;
  begin
    if (Line < First) or (HasLast and (Line > Last)) or (Line >= Length(Lines)) then
      Exit;
    It.Line := Line;
    It.Start := UnitsOf(Lines[Line], Col);
    It.Len := Units(RStripSpace(Text));
    It.Typ := Typ;
    It.Mods := Mods;
    if N = Length(Items) then
      SetLength(Items, 2 * N + 64);
    Items[N] := It;
    Inc(N);
  end;

  procedure Pieces(Tok: TToken; Typ: Integer);
  var
    Parts: TStringArray;
    I: Integer;
  begin
    Parts := SplitNL(Tok.Text);
    for I := 0 to High(Parts) do
      if StripSpace(Parts[I]) <> '' then
        if I = 0 then
          Add(Tok.Line - 1, Tok.Col - 1, Parts[I], Typ, 0)
        else
          Add(Tok.Line - 1 + I, 0, Parts[I], Typ, 0);
  end;

var
  Tok, T: TToken;
  Node: TNode;
  K: TObject;
  Sym: TSym;
  Typ, Mods, PL, PC, EL, EC: Integer;
  It: TSemItem;
  HasPend: Boolean;
begin
  Items := nil;
  N := 0;
  for Tok in Res.Tokens do
    if Tok.Kind = tkDirective then
      Pieces(Tok, StMacro)
    else if not Tok.Active and not (Tok.Kind in [tkWS, tkNL, tkCtrlZ, tkEOF]) then
      Pieces(Tok, StComment);
  for Node in Res.Tree.Walk do
    if Node.Kind = nkDirectives then
    begin
      for K in Node.Kids do
        if (K is TToken) and (TToken(K).Kind = tkIdent) and InList(LowerText(TToken(K).Text), RoutineDirectives) then
          Add(TToken(K).Line - 1, TToken(K).Col - 1, TToken(K).Text, StKeyword, 0);
    end
    else if (Node.Kind in [nkAbsolute, nkSection]) and (Node.Kids <> nil) and (Node.Kids[0] is TToken) then
    begin
      T := TToken(Node.Kids[0]);
      Add(T.Line - 1, T.Col - 1, T.Text, StKeyword, 0);
    end;
  for Tok in Res.DocSig do
  begin
    if Tok.Kind = tkKW then
    begin
      Add(Tok.Line - 1, Tok.Col - 1, Tok.Text, StKeyword, 0);
      Continue;
    end;
    if Tok.Kind <> tkIdent then
      Continue;
    Sym := TSym(Binder.Refs.Get(Tok));
    if Sym = nil then
      Sym := TSym(Binder.Decls.Get(Tok));
    if Sym = nil then
      Continue;
    if SemClass(Sym, Binder.Decls.Has(Tok), Typ, Mods) then
      Add(Tok.Line - 1, Tok.Col - 1, Tok.Text, Typ, Mods);
  end;
  SetLength(Items, N);
  if N > 1 then
    SortSem(Items, 0, N - 1);
  Result := TJSONArray.Create;
  PL := 0;
  PC := 0;
  EL := -1;
  EC := 0;
  HasPend := False;
  for It in Items do
  begin
    if (It.Len <= 0) or (HasPend and ((It.Line < EL) or ((It.Line = EL) and (It.Start < EC)))) then
      Continue;
    Result.Add(It.Line - PL);
    if It.Line = PL then
      Result.Add(It.Start - PC)
    else
      Result.Add(It.Start);
    Result.Add(It.Len);
    Result.Add(It.Typ);
    Result.Add(It.Mods);
    PL := It.Line;
    PC := It.Start;
    EL := It.Line;
    EC := It.Start + It.Len;
    HasPend := True;
  end;
end;

const
  OkModule = 2;
  OkNamespace = 3;
  OkClass = 5;
  OkMethod = 6;
  OkField = 8;
  OkConstructor = 9;
  OkEnum = 10;
  OkFunction = 12;
  OkVariable = 13;
  OkConstant = 14;
  OkArray = 18;
  OkEnumMember = 22;
  OkStruct = 23;
  OkTypeParameter = 26;

function ExtentOf(const Toks: TTokens; const Lines: TStringArray): TLspRange;
begin
  if Toks = nil then
    raise EBroken.Create('list index out of range');
  Result := MkRange(TokenRange(Toks[0], Lines).S, TokenRange(Toks[High(Toks)], Lines).E);
end;

function OutlineSym(NameTok: TToken; Kind: Integer; const Detail: string; const Extent: TLspRange;
  const Lines: TStringArray; Children: TJSONArray = nil; const Name: string = ''): TJSONObject;
var
  N: string;
begin
  N := Name;
  if N = '' then
    N := NameTok.Text;
  Result := TJSONObject.Create(['name', N, 'kind', Kind, 'range', RangeJSON(Extent), 'selectionRange',
    RangeJSON(TokenRange(NameTok, Lines))]);
  if Detail <> '' then
    Result.Add('detail', Detail);
  if (Children <> nil) and (Children.Count > 0) then
    Result.Add('children', Children)
  else
    Children.Free;
end;

function DeclNames(const Kids: TKids; From, Upto: Integer): TTokens;
var
  I: Integer;
  X: TNode;
begin
  Result := nil;
  if From < 0 then
    From := 0;
  for I := From to Upto - 1 do
    if (I <= High(Kids)) and IsKind(Kids[I], nkDeclName) then
    begin
      X := TNode(Kids[I]);
      if (X.Kids <> nil) and (X.Kids[0] is TToken) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := TToken(X.Kids[0]);
      end;
    end;
end;

function DeclNamesOf(N: TNode): TTokens;
begin
  if N = nil then
    Result := nil
  else
    Result := DeclNames([N], 0, 1);
end;

function MethodSymKind(R: TNode): Integer;
var
  Kw: string;
begin
  Kw := KeywordOf(R);
  if (Kw = 'constructor') or (Kw = 'destructor') then
    Result := OkConstructor
  else
    Result := OkMethod;
end;

procedure AddAll(Dst, Src: TJSONArray);
begin
  while Src.Count > 0 do
    Dst.Add(Src.Extract(0));
  Src.Free;
end;

function OutlineFields(FL: TNode; const Lines: TStringArray): TJSONArray;
var
  K, V: TObject;
  N: TNode;
  Owner, Decl: TNode;
  Names: TTokens;
  T: TToken;
  Colon, I: Integer;
  Detail: string;
  Kids: TKids;
begin
  Result := TJSONArray.Create;
  for K in FL.Kids do
  begin
    if not (K is TNode) then
      Continue;
    N := TNode(K);
    if N.Kind = nkRoutine then
    begin
      RoutineNames(N, Owner, Decl);
      Names := DeclNamesOf(Decl);
      if Names <> nil then
        Result.Add(OutlineSym(Names[0], MethodSymKind(N), Compact(SignatureToks(N)), ExtentOf(N.Tokens, Lines),
          Lines));
    end
    else if N.Kind = nkFieldDecl then
    begin
      Colon := -1;
      for I := 0 to High(N.Kids) do
        if IsTok(N.Kids[I], ':') then
          Colon := I;
      if (Colon < 0) or (Colon + 1 >= Length(N.Kids)) then
        Continue;
      Detail := Compact(ToksOf(N.Kids[Colon + 1]));
      for T in DeclNames(N.Kids, 0, Colon) do
        Result.Add(OutlineSym(T, OkField, Detail, ExtentOf(N.Tokens, Lines), Lines));
    end
    else if N.Kind = nkVariantPart then
    begin
      Kids := N.Kids;
      if (Length(Kids) > 3) and IsKind(Kids[1], nkDeclName) and IsTok(Kids[2], ':') then
        for T in DeclNames(Kids, 1, 2) do
          Result.Add(OutlineSym(T, OkField, Compact(ToksOf(Kids[3])), ExtentOf(ToksOfKids(Kids, 1, 4), Lines),
            Lines));
      for V in Kids do
        if IsKind(V, nkVariant) and (Length(TNode(V).Kids) > 3) and (TNode(V).Kids[3] is TNode) then
          AddAll(Result, OutlineFields(TNode(TNode(V).Kids[3]), Lines));
    end;
  end;
end;

function HeritageOf(N: TNode): TNode;
var
  K: TObject;
begin
  Result := nil;
  if N <> nil then
    for K in N.Kids do
      if IsKind(K, nkHeritage) then
        Exit(TNode(K));
end;

function TypeSymbol(D: TNode; const Lines: TStringArray): TJSONArray;
var
  Names: TTokens;
  Ty, FL, Her: TNode;
  Detail: string;
  Kind: Integer;
  Members, Fields: TJSONArray;
  T: TToken;
begin
  Result := TJSONArray.Create;
  Names := DeclNames(D.Kids, 0, 1);
  if (Names = nil) or (Length(D.Kids) < 3) or not (D.Kids[2] is TNode) then
    Exit;
  Ty := TNode(D.Kids[2]);
  while (Ty.Kind = nkPackedType) and (Length(Ty.Kids) > 1) and (Ty.Kids[1] is TNode) do
    Ty := TNode(Ty.Kids[1]);
  if Ty.Kind in [nkRecordType, nkObjectType] then
  begin
    FL := FieldListOf(Ty);
    Her := HeritageOf(Ty);
    if Her <> nil then
      Detail := 'object' + Compact(Her.Tokens)
    else if Ty.Kind = nkObjectType then
      Detail := 'object'
    else
      Detail := '';
    if Ty.Kind = nkObjectType then
      Kind := OkClass
    else
      Kind := OkStruct;
    if FL <> nil then
      Fields := OutlineFields(FL, Lines)
    else
      Fields := nil;
    Result.Add(OutlineSym(Names[0], Kind, Detail, ExtentOf(D.Tokens, Lines), Lines, Fields));
    Exit;
  end;
  if Ty.Kind = nkEnumType then
  begin
    Members := TJSONArray.Create;
    for T in DeclNames(Ty.Kids, 0, Length(Ty.Kids)) do
      Members.Add(OutlineSym(T, OkEnumMember, '', ExtentOf([T], Lines), Lines));
    Result.Add(OutlineSym(Names[0], OkEnum, '', ExtentOf(D.Tokens, Lines), Lines, Members));
    Exit;
  end;
  if Ty.Kind = nkArrayType then
    Kind := OkArray
  else
    Kind := OkTypeParameter;
  Result.Add(OutlineSym(Names[0], Kind, Compact(ToksOf(D.Kids[2])), ExtentOf(D.Tokens, Lines), Lines));
end;

function OutlineItems(const Kids: TKids; const Lines: TStringArray): TJSONArray; forward;

function RoutineSymbol(R: TNode; const Lines: TStringArray): TJSONArray;
var
  Owner, Decl, Block: TNode;
  Names: TTokens;
  Sig: TTokens;
  Nested, Kept: TJSONArray;
  K: TObject;
  I: Integer;
begin
  Result := TJSONArray.Create;
  RoutineNames(R, Owner, Decl);
  Names := DeclNamesOf(Decl);
  if Names = nil then
    Exit;
  Sig := SignatureToks(R);
  Block := nil;
  for K in R.Kids do
    if IsKind(K, nkBlock) then
    begin
      Block := TNode(K);
      Break;
    end;
  Kept := TJSONArray.Create;
  if Block <> nil then
  begin
    Nested := OutlineItems(Block.Kids, Lines);
    for I := 0 to Nested.Count - 1 do
      if TJSONObject(Nested[I]).Integers['kind'] = OkFunction then
        Kept.Add(Nested[I].Clone);
    Nested.Free;
  end;
  if (Owner <> nil) and (Owner.Kids <> nil) then
    Result.Add(OutlineSym(Names[0], MethodSymKind(R), Compact(Sig), ExtentOf(R.Tokens, Lines), Lines, Kept,
      TokText(Owner.Kids[0]) + '.' + Names[0].Text))
  else
    Result.Add(OutlineSym(Names[0], OkFunction, Compact(Sig), ExtentOf(R.Tokens, Lines), Lines, Kept));
end;

function OutlineItems(const Kids: TKids; const Lines: TStringArray): TJSONArray;
var
  Sec, D: TObject;
  S, DN: TNode;
  I, J, Colon: Integer;
  All, Body: TTokens;
  T: TToken;
  Detail: string;
begin
  Result := TJSONArray.Create;
  for Sec in Kids do
  begin
    if not (Sec is TNode) then
      Continue;
    S := TNode(Sec);
    case S.Kind of
      nkConstSection:
        for I := 1 to High(S.Kids) do
        begin
          D := S.Kids[I];
          if not IsKind(D, nkConstDecl) then
            Continue;
          DN := TNode(D);
          All := DN.Tokens;
          Body := ToksOfKids(DN.Kids, 1, Length(DN.Kids));
          if (Body <> nil) and (All <> nil) and (Body[High(Body)] = All[High(All)]) and (Body[High(Body)].Text = ';') then
            SetLength(Body, Length(Body) - 1);
          for T in DeclNames(DN.Kids, 0, 1) do
            Result.Add(OutlineSym(T, OkConstant, Compact(Body), ExtentOf(All, Lines), Lines));
        end;
      nkTypeSection:
        for I := 1 to High(S.Kids) do
          if IsKind(S.Kids[I], nkTypeDecl) then
            AddAll(Result, TypeSymbol(TNode(S.Kids[I]), Lines));
      nkVarSection:
        for I := 1 to High(S.Kids) do
        begin
          D := S.Kids[I];
          if not IsKind(D, nkVarDecl) then
            Continue;
          DN := TNode(D);
          Colon := -1;
          for J := 0 to High(DN.Kids) do
            if IsTok(DN.Kids[J], ':') then
            begin
              Colon := J;
              Break;
            end;
          if (Colon < 0) or (Colon + 1 >= Length(DN.Kids)) then
            Continue;
          Detail := Compact(ToksOf(DN.Kids[Colon + 1]));
          for T in DeclNames(DN.Kids, 0, Colon) do
            Result.Add(OutlineSym(T, OkVariable, Detail, ExtentOf(DN.Tokens, Lines), Lines));
        end;
      nkRoutine:
        AddAll(Result, RoutineSymbol(S, Lines));
    end;
  end;
end;

function DocumentSymbols(const Text: string): TJSONArray;
var
  Res: TParseResult;
  Lines: TStringArray;
  Root, Header, Block, Part: TNode;
  Whole: TLspRange;
  Names: TTokens;
  Parts, Kids: TJSONArray;
  K: TObject;
  Sig: TTokens;

  function Module(NameTok: TToken; Children: TJSONArray; const Fallback: string): TJSONArray;
  var
    D: TJSONObject;
    Sel: TLspRange;
    N: string;
  begin
    if NameTok <> nil then
    begin
      N := NameTok.Text;
      Sel := TokenRange(NameTok, Lines);
    end
    else
    begin
      N := Fallback;
      Sel := MkRange(Whole.S, TokenRange(Sig[0], Lines).E);
    end;
    D := TJSONObject.Create(['name', N, 'kind', OkModule, 'range', RangeJSON(Whole), 'selectionRange',
      RangeJSON(Sel)]);
    if (Children <> nil) and (Children.Count > 0) then
      D.Add('children', Children)
    else
      Children.Free;
    Result := TJSONArray.Create([D]);
  end;

begin
  Res := Parse(Text);
  try
    Lines := SplitNL(Text);
    Root := nil;
    if (Res.Tree.Kids <> nil) and (Res.Tree.Kids[0] is TNode) then
      Root := TNode(Res.Tree.Kids[0]);
    Sig := Res.DocSig;
    if (Root = nil) or (Length(Sig) < 2) then
      Exit(TJSONArray.Create);
    Whole := MkRange(TokenRange(Sig[0], Lines).S, TokenRange(Sig[High(Sig) - 1], Lines).E);
    if Root.Kind = nkUnit then
    begin
      Names := DeclNames(Root.Kids, 1, 2);
      Parts := TJSONArray.Create;
      for K in Root.Kids do
        if IsKind(K, nkInterface) or IsKind(K, nkImplementation) then
        begin
          Part := TNode(K);
          Kids := OutlineItems(Part.Kids, Lines);
          Parts.Add(OutlineSym(KT(Kid(Part, 0)), OkNamespace, '', ExtentOf(Part.Tokens, Lines), Lines, Kids,
            LowerText(KT(Kid(Part, 0)).Text)));
        end;
      if Names <> nil then
        Exit(Module(Names[0], Parts, 'unit'));
      Exit(Module(nil, Parts, 'unit'));
    end;
    if Root.Kind = nkProgram then
    begin
      Header := nil;
      Block := nil;
      for K in Root.Kids do
        if IsKind(K, nkProgramHeader) and (Header = nil) then
          Header := TNode(K)
        else if IsKind(K, nkBlock) and (Block = nil) then
          Block := TNode(K);
      Names := nil;
      if Header <> nil then
        Names := DeclNames(Header.Kids, 0, Length(Header.Kids));
      if Block <> nil then
        Kids := OutlineItems(Block.Kids, Lines)
      else
        Kids := TJSONArray.Create;
      if Names <> nil then
        Exit(Module(Names[0], Kids, 'program'));
      Exit(Module(nil, Kids, 'program'));
    end;
    Result := TJSONArray.Create;
  finally
    Res.Free;
  end;
end;

function FlattenSymbols(Symbols: TJSONArray; const Uri: string; const Container: string = ''): TJSONArray;
var
  I: Integer;
  S, Info: TJSONObject;
  Kids: TJSONData;
begin
  Result := TJSONArray.Create;
  for I := 0 to Symbols.Count - 1 do
  begin
    S := TJSONObject(Symbols[I]);
    Info := TJSONObject.Create(['name', S.Strings['name'], 'kind', S.Integers['kind'], 'location',
      TJSONObject.Create(['uri', Uri, 'range', S.Objects['range'].Clone])]);
    if Container <> '' then
      Info.Add('containerName', Container);
    Result.Add(Info);
    Kids := S.Find('children');
    if Kids is TJSONArray then
      AddAll(Result, FlattenSymbols(TJSONArray(Kids), Uri, S.Strings['name']));
  end;
end;

function PathKey(const Path: string): string;
begin
  Result := NormCase(AbsPath(Path));
end;

function SymKey(Sym: TSym; const Here: string): string;
begin
  if Sym.Kind = skUnit then
    Exit(#1'unit'#0 + LowerText(Sym.Name));
  if Sym.Implicit then
  begin
    if Sym.Owner <> nil then
      Exit(#1'self'#0 + SymKey(Sym.Owner, Here));
    Exit(#1'self'#0#1'none');
  end;
  if Sym.Tok = nil then
    Exit(#1'lib'#0 + SymKindNames[Sym.Kind] + #0 + LowerText(Sym.Name));
  if Sym.FileName <> '' then
    Result := PathKey(Sym.FileName)
  else
    Result := Here;
  Result := Result + #0 + IntToStr(Sym.Tok.Idx);
end;

constructor TBound.Create(const AKey, AUri, AText: string; ARes: TParseResult; ABinder: TBinder; AProv: TProvider);
begin
  Key := AKey;
  Uri := AUri;
  Text := AText;
  Res := ARes;
  Binder := ABinder;
  Prov := AProv;
  Lines := SplitNL(AText);
end;

destructor TBound.Destroy;
begin
  Binder.Free;
  Res.Free;
  inherited;
end;

function RefOrDecl(B: TBinder; Tok: TToken): TSym;
begin
  Result := TSym(B.Refs.Get(Tok));
  if Result = nil then
    Result := TSym(B.Decls.Get(Tok));
end;

function Keyed(B: TBound): TKeyeds;
var
  Tok: TToken;
  Sym: TSym;
  N: Integer;
begin
  Result := nil;
  N := 0;
  for Tok in B.Res.DocSig do
  begin
    if not (Tok.Kind in [tkIdent, tkInt]) then
      Continue;
    Sym := RefOrDecl(B.Binder, Tok);
    if (Sym = nil) and (Tok.Kind = tkInt) then
      Continue;
    if N = Length(Result) then
      SetLength(Result, 2 * N + 64);
    Result[N].Tok := Tok;
    Result[N].Sym := Sym;
    if Sym <> nil then
      Result[N].Key := SymKey(Sym, B.Key)
    else
      Result[N].Key := '';
    Result[N].Decl := B.Binder.Decls.Has(Tok);
    Inc(N);
  end;
  SetLength(Result, N);
end;

function DirectivesOf(N: TNode): TNode;
var
  K: TObject;
begin
  Result := nil;
  if N <> nil then
    for K in N.Kids do
      if IsKind(K, nkDirectives) then
        Exit(TNode(K));
end;

function IsVirtual(M: TSym): Boolean;
var
  Dirs: TNode;
  K: TObject;
begin
  Dirs := DirectivesOf(M.Node);
  if Dirs <> nil then
    for K in Dirs.Kids do
      if (K is TToken) and (LowerText(TToken(K).Text) = 'virtual') then
        Exit(True);
  Result := False;
end;

function VirtualChain(Binder: TBinder; M: TSym): TSyms;
var
  Ti, Anc: TTInfo;
  Up: TSym;
  Seen: Integer;
begin
  Result := [M];
  if (M.Owner = nil) or not IsVirtual(M) then
    Exit;
  Ti := Binder.TypeTi(M.Owner);
  if Ti <> nil then
    Anc := Ti.GetAncestor
  else
    Anc := nil;
  Seen := 0;
  while (Anc <> nil) and (Seen < 100) do
  begin
    Inc(Seen);
    Up := TSym(Anc.GetOwn.Get(LowerText(M.Name)));
    if (Up <> nil) and (Up.Kind = skRoutine) and (Up.Owner <> nil) and IsVirtual(Up) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Up;
    end
    else if Up <> nil then
      Break;
    Anc := Anc.GetAncestor;
  end;
end;

function ObjectNode(Sym: TSym): TNode;
begin
  if (Sym <> nil) and (Sym.Kind = skType) and IsKind(Sym.TNode, nkObjectType) then
    Result := TNode(Sym.TNode)
  else
    Result := nil;
end;

function AncestorSym(Binder: TBinder; Sym: TSym): TSym;
var
  Her: TNode;
begin
  Her := HeritageOf(ObjectNode(Sym));
  if (Her = nil) or (Length(Her.Kids) < 2) or not (Her.Kids[1] is TNode) then
    Exit(nil);
  Result := Binder.TypeSym(Her.Kids[1], Sym.Scope);
end;

function WriteTargets(Res: TParseResult): TPtrMap;

  function Head(D: TObject): TToken;
  var
    Fields: TNodes;
    I: Integer;
    N: TNode;
  begin
    if D is TToken then
      Exit(TToken(D));
    N := TNode(D);
    if N.Kind = nkDesignator then
    begin
      Fields := nil;
      for I := 1 to High(N.Kids) do
        if IsKind(N.Kids[I], nkField) and (Length(TNode(N.Kids[I]).Kids) > 1) then
        begin
          SetLength(Fields, Length(Fields) + 1);
          Fields[High(Fields)] := TNode(N.Kids[I]);
        end;
      if (Fields <> nil) and (Fields[High(Fields)].Kids[1] is TToken) then
        Exit(TToken(Fields[High(Fields)].Kids[1]));
      D := N.Kids[0];
    end;
    while (D is TNode) and (TNode(D).Kids <> nil) do
      D := TNode(D).Kids[0];
    if D is TToken then
      Result := TToken(D)
    else
      Result := nil;
  end;

var
  N: TNode;
  T: TToken;
begin
  Result := TPtrMap.Create;
  for N in Res.Tree.Walk do
  begin
    if (N.Kind = nkAssign) and (N.Kids <> nil) then
      T := Head(N.Kids[0])
    else if (N.Kind = nkFor) and (Length(N.Kids) > 1) then
      T := Head(N.Kids[1])
    else
      Continue;
    if (T <> nil) and (T.Kind = tkIdent) then
      Result.Put(T, T);
  end;
end;

function ApplyTokenEdits(const Text: string; const Toks: TTokens; const New: string): string;
var
  Sorted: TTokens;
  I, J: Integer;
  X: TToken;
begin
  Sorted := Copy(Toks);
  for I := 1 to High(Sorted) do
  begin
    X := Sorted[I];
    J := I - 1;
    while (J >= 0) and (Sorted[J].Pos < X.Pos) do
    begin
      Sorted[J + 1] := Sorted[J];
      Dec(J);
    end;
    Sorted[J + 1] := X;
  end;
  Result := Text;
  for X in Sorted do
    Result := Copy(Result, 1, X.Pos - 1) + New + Copy(Result, X.Pos + Length(X.Text), MaxInt);
end;

function TypeNameNode(TN: TObject): TNode;
var
  N, Nxt: TNode;
  I: Integer;
begin
  while TN is TNode do
  begin
    N := TNode(TN);
    case N.Kind of
      nkNamedType:
        if (N.Kids <> nil) and (N.Kids[0] is TNode) then
          Exit(TNode(N.Kids[0]))
        else
          Exit(nil);
      nkPointerType:
        if (Length(N.Kids) > 1) and (N.Kids[1] is TNode) then
          Exit(TNode(N.Kids[1]))
        else
          Exit(nil);
      nkArrayType, nkPackedType, nkSetType, nkFileType:
        begin
          Nxt := nil;
          for I := High(N.Kids) downto 0 do
            if N.Kids[I] is TNode then
            begin
              Nxt := TNode(N.Kids[I]);
              Break;
            end;
          if (Nxt = nil) or (Nxt = N) then
            Exit(nil);
          TN := Nxt;
        end;
    else
      Exit(nil);
    end;
  end;
  Result := nil;
end;

function MethodLineOf(R: TNode): string;
var
  Owner, Decl, Dirs: TNode;
  Sig, Name: string;
  K: TObject;
begin
  RoutineNames(R, Owner, Decl);
  Sig := Compact(SignatureToks(R), 200);
  Name := '';
  if (Decl <> nil) and (Decl.Kids <> nil) then
    Name := TokText(Decl.Kids[0]);
  Result := StringReplace(LowerText(KT(Kid(R, 0)).Text) + ' ' + Name + SigText(Sig), ' :', ':', [rfReplaceAll]);
  Dirs := DirectivesOf(R);
  if Dirs <> nil then
    for K in Dirs.Kids do
      if (K is TToken) and (TToken(K).Kind = tkIdent) then
        Result := Result + '; ' + LowerText(TToken(K).Text);
  Result := Result + ';';
end;

function MembersText(Inner: TNode; Limit: Integer = 14): TStringArray;
var
  FL: TNode;
  K: TObject;
  N: TNode;
  IOf, I: Integer;
begin
  Result := nil;
  FL := FieldListOf(Inner);
  if FL <> nil then
    for K in FL.Kids do
    begin
      if not (K is TNode) then
        Continue;
      N := TNode(K);
      case N.Kind of
        nkFieldDecl:
          PushStr(Result, '  ' + Compact(N.Tokens, 120) + ';');
        nkRoutine:
          PushStr(Result, '  ' + MethodLineOf(N));
        nkSection:
          PushStr(Result, LowerText(KT(Kid(N, 0)).Text));
        nkVariantPart:
          begin
            IOf := -1;
            for I := 0 to High(N.Kids) do
              if (N.Kids[I] is TToken) and (LowerText(TToken(N.Kids[I]).Text) = 'of') then
              begin
                IOf := I;
                Break;
              end;
            if IOf >= 0 then
              PushStr(Result, '  ' + Compact(ToksOfKids(N.Kids, 0, IOf + 1), 120) + ' ...');
          end;
      end;
    end;
  if Length(Result) > Limit then
  begin
    SetLength(Result, Limit);
    PushStr(Result, '  ...');
  end;
end;

function LibLabel(K: TSymKind): string;
begin
  case K of
    skRoutine: Result := 'routine';
    skBuiltin: Result := 'standard routine';
    skVar: Result := 'var';
    skConst: Result := 'const';
    skType: Result := 'type';
    skField: Result := 'field';
    skEnum: Result := 'enumeration constant';
    skParam: Result := 'parameter';
    skUnit: Result := 'unit';
    skLabel: Result := 'label';
  end;
end;

function JoinLines(const A: TStringArray; const Sep: string = #10): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then
      Result := Result + Sep;
    Result := Result + A[I];
  end;
end;

function HoverMarkdown(Sym: TSym): string;
var
  Node, Inner, Her, Dirs: TNode;
  Owner, Text, Sig, Extra, Head, Enum: string;
  Parts: TTokens;
  K: TObject;
  Words: TStringArray;
begin
  if Sym.Kind = skUnit then
  begin
    if Sym.FileName <> '' then
      Extra := '*source: ' + BaseName(Sym.FileName) + '*'
    else
      Extra := '*standard library unit (no source)*';
    Exit('```pascal'#10'unit ' + Sym.Name + #10'```'#10 + Extra);
  end;
  if Sym.Implicit then
  begin
    if Sym.Owner <> nil then
      Owner := Sym.Owner.Name
    else
      Owner := '?';
    Exit('```pascal'#10'Self: ' + Owner + #10'```'#10'*the object this method works on*');
  end;
  if Sym.Tok = nil then
  begin
    if Sym.Kind in [skVar, skConst, skType, skRoutine, skBuiltin] then
      Text := LibLabel(Sym.Kind) + ' ' + Sym.Name
    else
      Text := Sym.Name;
    if Sym.Home <> '' then
      Extra := '*unit ' + Sym.Home + '*'
    else
      Extra := '';
    Exit('```pascal'#10 + Text + #10'```'#10 + Extra);
  end;
  Node := Sym.Node;
  if Sym.Owner <> nil then
    Owner := Sym.Owner.Name + '.'
  else
    Owner := '';
  if (Sym.Kind = skRoutine) and (Node <> nil) and (Node.Kids <> nil) then
  begin
    Sig := Compact(SignatureToks(Node), 300);
    Text := StringReplace(LowerText(KT(Node.Kids[0]).Text) + ' ' + Owner + Sym.Name + SigText(Sig), ' :', ':',
      [rfReplaceAll]);
    Dirs := DirectivesOf(Node);
    if (Dirs <> nil) and (Sym.Owner <> nil) then
    begin
      Words := nil;
      for K in Dirs.Kids do
        if (K is TToken) and (TToken(K).Kind = tkIdent) then
          PushStr(Words, LowerText(TToken(K).Text));
      if Words <> nil then
        Text := Text + '; ' + JoinLines(Words, '; ');
    end;
  end
  else if (Sym.Kind in [skVar, skParam, skField]) and (Sym.TNode <> nil) then
  begin
    if Sym.Kind = skVar then
      Text := 'var '
    else
      Text := '';
    Text := Text + Sym.Name + ': ' + Compact(ToksOf(Sym.TNode), 300);
  end
  else if (Sym.Kind = skConst) and (Node <> nil) then
  begin
    Parts := ToksOfKids(Node.Kids, 1, Length(Node.Kids));
    if (Parts <> nil) and (Parts[High(Parts)].Text = ';') then
      SetLength(Parts, Length(Parts) - 1);
    Text := StringReplace('const ' + Sym.Name + ' ' + Compact(Parts, 300), ' :', ':', [rfReplaceAll]);
  end
  else if (Sym.Kind = skType) and (Sym.TNode is TNode) then
  begin
    Inner := TNode(Sym.TNode);
    while (Inner.Kind = nkPackedType) and (Length(Inner.Kids) > 1) and (Inner.Kids[1] is TNode) do
      Inner := TNode(Inner.Kids[1]);
    if (Inner.Kind in [nkRecordType, nkObjectType]) and (FieldListOf(Inner) <> nil) then
    begin
      Her := HeritageOf(Inner);
      Head := LowerText(Inner.Tokens[0].Text);
      if Her <> nil then
        Head := Head + Compact(Her.Tokens);
      Text := 'type ' + Sym.Name + ' = ' + Head + #10 + JoinLines(MembersText(Inner)) + #10'end';
    end
    else
      Text := 'type ' + Sym.Name + ' = ' + Compact(ToksOf(Sym.TNode), 300);
  end
  else if (Sym.Kind = skType) and (Sym.TNode <> nil) then
    Text := 'type ' + Sym.Name + ' = ' + Compact(ToksOf(Sym.TNode), 300)
  else if Sym.Kind = skEnum then
  begin
    if Sym.TNode <> nil then
      Enum := Compact(ToksOf(Sym.TNode), 200)
    else
      Enum := '';
    Exit('```pascal'#10 + Sym.Name + #10'```'#10'*enumeration constant* of ' + Enum);
  end
  else if Sym.Kind = skLabel then
    Text := 'label ' + Sym.Name
  else
    Text := Sym.Name;
  if Sym.Kind = skParam then
    Extra := '*parameter*'
  else if Sym.Kind = skField then
    Extra := '*field*'
  else
    Extra := '';
  if (Sym.Owner <> nil) and (Sym.Kind in [skField, skRoutine]) then
    if Sym.Kind = skRoutine then
      Extra := '*method of ' + Sym.Owner.Name + '*'
    else
      Extra := '*field of ' + Sym.Owner.Name + '*';
  Result := '```pascal'#10 + Text + #10'```';
  if Extra <> '' then
    Result := Result + #10 + Extra;
end;

function DiagJSON(const R: TLspRange; Severity: Integer; const Msg: string; Unnecessary: Boolean = False): TJSONObject;
begin
  Result := TJSONObject.Create(['range', RangeJSON(R), 'severity', Severity]);
  if Unnecessary then
    Result.Add('tags', TJSONArray.Create([1]));
  Result.Add('source', ServerName);
  Result.Add('message', Msg);
end;

function DiagnosticsFor(const Text: string; Res: TParseResult): TJSONArray;
var
  Lines: TStringArray;
  D: TDiag;
  N, Len: Integer;
begin
  Result := TJSONArray.Create;
  Lines := SplitNL(Text);
  for D in Res.Diags do
    Result.Add(DiagJSON(TokenRange(D.Token, Lines), 1, D.Message));
  for N := 0 to High(Lines) do
  begin
    Len := Utf8Length(Lines[N], 1, Length(Lines[N]));
    if Len > TpLineLimit then
      Result.Add(DiagJSON(MkRange(MkPos(N, Units(CharCopy(Lines[N], TpLineLimit))), MkPos(N, Units(Lines[N]))), 1,
        Format('line too long (%d characters): Turbo Pascal 7 accepts at most %d', [Len, TpLineLimit])));
  end;
end;

function HexVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function Unquote(const S: string): string;
var
  I: Integer;
  Raw: RawByteString;
begin
  Raw := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '%') and (I + 2 <= Length(S)) and (HexVal(S[I + 1]) >= 0) and (HexVal(S[I + 2]) >= 0) then
    begin
      Raw := Raw + Chr(HexVal(S[I + 1]) * 16 + HexVal(S[I + 2]));
      Inc(I, 3);
    end
    else
    begin
      Raw := Raw + S[I];
      Inc(I);
    end;
  end;
  Result := Raw;
end;

function UriToPath(const Uri: string; out Path: string): Boolean;
var
  I, J: Integer;
  Scheme, Rest: string;
begin
  Path := '';
  I := Pos(':', Uri);
  if (I < 2) or not (Uri[1] in ['A'..'Z', 'a'..'z']) then
    Exit(False);
  for J := 2 to I - 1 do
    if not (Uri[J] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.']) then
      Exit(False);
  Scheme := LowerCase(Copy(Uri, 1, I - 1));
  if Scheme <> 'file' then
    Exit(False);
  Rest := Copy(Uri, I + 1, MaxInt);
  if Copy(Rest, 1, 2) = '//' then
  begin
    J := 3;
    while (J <= Length(Rest)) and not (Rest[J] in ['/', '?', '#']) do
      Inc(J);
    Rest := Copy(Rest, J, MaxInt);
  end;
  for J := 1 to Length(Rest) do
    if Rest[J] in ['?', '#'] then
    begin
      Rest := Copy(Rest, 1, J - 1);
      Break;
    end;
  Path := AbsPath(Unquote(Rest));
  Result := True;
end;

function PathToUri(const Path: string): string;
const
  Hex = '0123456789ABCDEF';
var
  P: string;
  C: Char;
begin
  P := AbsPath(Path);
  Result := 'file://';
  for C in P do
    if C in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-', '~', '/'] then
      Result := Result + C
    else
      Result := Result + '%' + Hex[Ord(C) shr 4 + 1] + Hex[Ord(C) and 15 + 1];
end;

function ListCi(const Dir, Name: string): string;
var
  Names: TStringArray;
  N: string;
begin
  Result := '';
  if not ListDir(Dir, Names) then
    Exit;
  for N in Names do
    if LowerText(N) = LowerText(Name) then
      Exit(JoinPath(Dir, N));
end;

function FindTpl(const Bases: TStringArray): string;
var
  Base, D, P: string;
  K: Integer;
begin
  for Base in Bases do
    for K := 0 to 1 do
    begin
      if K = 0 then
        D := Base
      else
        D := ListCi(Base, 'bin');
      if (D <> '') and IsDir(D) then
      begin
        P := ListCi(D, 'turbo.tpl');
        if (P <> '') and IsFile(P) then
          Exit(P);
      end;
    end;
  Result := '';
end;

{ documents, transport, inbox }

constructor TDoc.Create(const AUri: string; AVersion: TJSONData; const AText: string);
begin
  Uri := AUri;
  if AVersion <> nil then
    Version := AVersion.Clone
  else
    Version := nil;
  Text := AText;
  if not UriToPath(AUri, Path) then
    Path := '';
end;

destructor TDoc.Destroy;
begin
  Version.Free;
  inherited;
end;

constructor TStreamTransport.Create(AIn, AOut: TStream);
begin
  FIn := AIn;
  FOut := AOut;
end;

function TStreamTransport.Fill: Boolean;
begin
  FPos := 0;
  FLen := FIn.Read(FBuf, SizeOf(FBuf));
  if FLen < 0 then
    FLen := 0;
  Result := FLen > 0;
end;

function TStreamTransport.ReadLine(out Line: RawByteString): Boolean;
var
  Start: Integer;
begin
  Line := '';
  repeat
    if (FPos >= FLen) and not Fill then
      Exit(Line <> '');
    Start := FPos;
    while (FPos < FLen) and (FBuf[FPos] <> 10) do
      Inc(FPos);
    if FPos > Start then
    begin
      SetLength(Line, Length(Line) + FPos - Start);
      Move(FBuf[Start], Line[Length(Line) - (FPos - Start) + 1], FPos - Start);
    end;
    if FPos < FLen then
    begin
      Inc(FPos);
      Exit(True);
    end;
  until False;
end;

function TStreamTransport.ReadBytes(N: Integer; out Data: RawByteString): Boolean;
var
  Got, Take: Integer;
begin
  SetLength(Data, N);
  Got := 0;
  while Got < N do
  begin
    if (FPos >= FLen) and not Fill then
    begin
      SetLength(Data, Got);
      Exit(False);
    end;
    Take := FLen - FPos;
    if Take > N - Got then
      Take := N - Got;
    Move(FBuf[FPos], Data[Got + 1], Take);
    Inc(FPos, Take);
    Inc(Got, Take);
  end;
  Result := True;
end;

function Utf8Of(C: LongWord): RawByteString;
begin
  if C < $80 then
    Result := Chr(C)
  else if C < $800 then
    Result := Chr($C0 or (C shr 6)) + Chr($80 or (C and $3F))
  else if C < $10000 then
    Result := Chr($E0 or (C shr 12)) + Chr($80 or ((C shr 6) and $3F)) + Chr($80 or (C and $3F))
  else
    Result := Chr($F0 or (C shr 18)) + Chr($80 or ((C shr 12) and $3F)) + Chr($80 or ((C shr 6) and $3F)) +
      Chr($80 or (C and $3F));
end;

function Hex4(const S: RawByteString; I: Integer; out V: LongWord): Boolean;
var
  K, H: Integer;
begin
  V := 0;
  if I + 3 > Length(S) then
    Exit(False);
  for K := I to I + 3 do
  begin
    case S[K] of
      '0'..'9': H := Ord(S[K]) - Ord('0');
      'a'..'f': H := Ord(S[K]) - Ord('a') + 10;
      'A'..'F': H := Ord(S[K]) - Ord('A') + 10;
    else
      Exit(False);
    end;
    V := V * 16 + LongWord(H);
  end;
  Result := True;
end;

function DecodeEscapes(const S: RawByteString): RawByteString;
var
  I, Start: Integer;
  C, Lo: LongWord;
begin
  Result := '';
  I := 1;
  Start := 1;
  while I <= Length(S) do
  begin
    if S[I] <> '\' then
    begin
      Inc(I);
      Continue;
    end;
    if (I < Length(S)) and (S[I + 1] = 'u') and Hex4(S, I + 2, C) and (C >= $20) and (C <> $22) and (C <> $5C) then
    begin
      Result := Result + Copy(S, Start, I - Start);
      Inc(I, 6);
      if (C >= $D800) and (C <= $DBFF) and (I + 5 <= Length(S)) and (S[I] = '\') and (S[I + 1] = 'u') and
        Hex4(S, I + 2, Lo) and (Lo >= $DC00) and (Lo <= $DFFF) then
      begin
        C := $10000 + ((C - $D800) shl 10) + (Lo - $DC00);
        Inc(I, 6);
      end
      else if (C >= $D800) and (C <= $DFFF) then
        C := $FFFD;
      Result := Result + Utf8Of(C);
      Start := I;
    end
    else
      Inc(I, 2);
  end;
  Result := Result + Copy(S, Start, MaxInt);
end;

type
  TOutBuf = record
    Data: RawByteString;
    Len: Integer;
  end;

procedure Put(var B: TOutBuf; const S: RawByteString);
var
  N: Integer;
begin
  N := Length(S);
  if N = 0 then
    Exit;
  if B.Len + N > Length(B.Data) then
    SetLength(B.Data, 2 * (B.Len + N) + 256);
  Move(S[1], B.Data[B.Len + 1], N);
  Inc(B.Len, N);
end;

procedure WriteStr(const S: string; var B: TOutBuf);
const
  Hex = '0123456789abcdef';
var
  I, Start: Integer;
  C: Char;
  Esc: RawByteString;
begin
  Put(B, '"');
  Start := 1;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"': Esc := '\"';
      '\': Esc := '\\';
      #10: Esc := '\n';
      #13: Esc := '\r';
      #9: Esc := '\t';
      #8: Esc := '\b';
      #12: Esc := '\f';
      #0..#7, #11, #14..#31: Esc := '\u00' + Hex[Ord(C) shr 4 + 1] + Hex[Ord(C) and 15 + 1];
    else
      Continue;
    end;
    Put(B, Copy(S, Start, I - Start));
    Put(B, Esc);
    Start := I + 1;
  end;
  Put(B, Copy(S, Start, MaxInt));
  Put(B, '"');
end;

procedure WriteJSON(D: TJSONData; var B: TOutBuf);
var
  I: Integer;
begin
  case D.JSONType of
    jtNull: Put(B, 'null');
    jtBoolean:
      if D.AsBoolean then
        Put(B, 'true')
      else
        Put(B, 'false');
    jtNumber:
      if D is TJSONFloatNumber then
        Put(B, FloatToStr(D.AsFloat, DefaultFormatSettings))
      else
        Put(B, IntToStr(D.AsInt64));
    jtString: WriteStr(D.AsString, B);
    jtArray:
      begin
        Put(B, '[');
        for I := 0 to D.Count - 1 do
        begin
          if I > 0 then
            Put(B, ',');
          WriteJSON(D.Items[I], B);
        end;
        Put(B, ']');
      end;
    jtObject:
      begin
        Put(B, '{');
        for I := 0 to D.Count - 1 do
        begin
          if I > 0 then
            Put(B, ',');
          WriteStr(TJSONObject(D).Names[I], B);
          Put(B, ':');
          WriteJSON(D.Items[I], B);
        end;
        Put(B, '}');
      end;
  end;
end;

function TStreamTransport.Read: TJSONData;
var
  Line, Body: RawByteString;
  Length_, I, Code: Integer;
  Name, Value: string;
begin
  repeat
    Length_ := -1;
    repeat
      if not ReadLine(Line) then
        Exit(nil);
      while (Line <> '') and (Line[Length(Line)] in [#13, #10]) do
        SetLength(Line, Length(Line) - 1);
      if Line = '' then
        Break;
      I := Pos(':', Line);
      if I > 0 then
      begin
        Name := LowerCase(Trim(Copy(Line, 1, I - 1)));
        Value := Trim(Copy(Line, I + 1, MaxInt));
      end
      else
      begin
        Name := LowerCase(Trim(Line));
        Value := '';
      end;
      if Name = 'content-length' then
      begin
        Val(Value, Length_, Code);
        if (Code <> 0) or (Length_ < 0) then
          Length_ := -1;
      end;
    until False;
    if Length_ < 0 then
      Continue;
    if not ReadBytes(Length_, Body) then
      Exit(nil);
    try
      Exit(GetJSON(DecodeEscapes(Body)));
    except
      on E: Exception do
        Log('invalid JSON ignored: ' + E.Message);
    end;
  until False;
end;

procedure TStreamTransport.Send(Msg: TJSONObject);
var
  Body, Head: RawByteString;
  Buf: TOutBuf;
begin
  Buf.Data := '';
  Buf.Len := 0;
  WriteJSON(Msg, Buf);
  Body := Copy(Buf.Data, 1, Buf.Len);
  Head := 'Content-Length: ' + IntToStr(Length(Body)) + #13#10#13#10;
  FOut.WriteBuffer(Head[1], Length(Head));
  if Body <> '' then
    FOut.WriteBuffer(Body[1], Length(Body));
end;

constructor TInbox.Create;
begin
  FLock := TCriticalSection.Create;
  FEvent := TEvent.Create(nil, True, False, '');
  FItems := TFPList.Create;
end;

destructor TInbox.Destroy;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TObject(FItems[I]).Free;
  FItems.Free;
  FEvent.Free;
  FLock.Free;
  inherited;
end;

procedure TInbox.Put(Msg: TJSONData);
begin
  FLock.Enter;
  try
    FItems.Add(Msg);
    FEvent.SetEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TInbox.Close;
begin
  FLock.Enter;
  try
    FClosed := True;
    FEvent.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TInbox.Get(Timeout: Integer; out Msg: TJSONData; out Ended: Boolean): Boolean;
var
  W: Cardinal;
begin
  Msg := nil;
  Ended := False;
  repeat
    FLock.Enter;
    try
      if FItems.Count > 0 then
      begin
        Msg := TJSONData(FItems[0]);
        FItems.Delete(0);
        if (FItems.Count = 0) and not FClosed then
          FEvent.ResetEvent;
        Exit(True);
      end;
      if FClosed then
      begin
        Ended := True;
        Exit(True);
      end;
      FEvent.ResetEvent;
    finally
      FLock.Leave;
    end;
    if Timeout < 0 then
      W := INFINITE
    else
      W := Timeout;
    if FEvent.WaitFor(W) <> wrSignaled then
      Exit(False);
  until False;
end;

function TInbox.ChangeWaiting(const Uri: string): Boolean;
var
  I: Integer;
  M: TJSONData;
  P, TD: TJSONData;
begin
  Result := False;
  FLock.Enter;
  try
    for I := 0 to FItems.Count - 1 do
    begin
      M := TJSONData(FItems[I]);
      if not (M is TJSONObject) or (TJSONObject(M).Get('method', '') <> 'textDocument/didChange') then
        Continue;
      P := TJSONObject(M).Find('params');
      if not (P is TJSONObject) then
        Continue;
      TD := TJSONObject(P).Find('textDocument');
      if (TD is TJSONObject) and (TJSONObject(TD).Get('uri', '') = Uri) then
        Exit(True);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TReader.Execute;
var
  Msg: TJSONData;
  P: TJSONData;
begin
  repeat
    try
      Msg := Server.Channel.Read;
    except
      on E: Exception do
      begin
        Log('reader stopped: ' + E.Message);
        Msg := nil;
      end;
    end;
    if Msg = nil then
    begin
      Server.Inbox.Close;
      Exit;
    end;
    if (Msg is TJSONObject) and (TJSONObject(Msg).Get('method', '') = '$/cancelRequest') then
    begin
      P := TJSONObject(Msg).Find('params');
      if P is TJSONObject then
        Server.Cancel(TJSONObject(P).Find('id'))
      else
        Server.Cancel(nil);
      Msg.Free;
      Continue;
    end;
    Server.Inbox.Put(Msg);
  until False;
end;

{ JSON access }

function JObj(D: TJSONData; const Key: string): TJSONObject;
var
  X: TJSONData;
begin
  Result := nil;
  if D is TJSONObject then
  begin
    X := TJSONObject(D).Find(Key);
    if X is TJSONObject then
      Result := TJSONObject(X);
  end;
end;

function JStr(D: TJSONData; const Key: string; const Default: string = ''): string;
var
  X: TJSONData;
begin
  Result := Default;
  if D is TJSONObject then
  begin
    X := TJSONObject(D).Find(Key);
    if X is TJSONString then
      Result := X.AsString;
  end;
end;

function JInt(D: TJSONData; const Key: string; Default: Integer = 0): Integer;
var
  X: TJSONData;
begin
  Result := Default;
  if D is TJSONObject then
  begin
    X := TJSONObject(D).Find(Key);
    if X is TJSONNumber then
      Result := X.AsInteger;
  end;
end;

function JHas(D: TJSONData; const Key: string): Boolean;
begin
  Result := (D is TJSONObject) and (TJSONObject(D).Find(Key) <> nil);
end;

function Truthy(D: TJSONData): Boolean;
begin
  if D = nil then
    Exit(False);
  case D.JSONType of
    jtNull: Result := False;
    jtBoolean: Result := D.AsBoolean;
    jtNumber: Result := D.AsFloat <> 0;
    jtString: Result := D.AsString <> '';
    jtArray, jtObject: Result := D.Count > 0;
  else
    Result := True;
  end;
end;

function IdKey(D: TJSONData): string;
begin
  if D = nil then
    Exit('null');
  case D.JSONType of
    jtNumber:
      if Frac(D.AsFloat) = 0 then
        Result := 'n' + IntToStr(D.AsInt64)
      else
        Result := 'f' + D.AsString;
    jtString: Result := 's' + D.AsString;
    jtBoolean:
      if D.AsBoolean then
        Result := 'n1'
      else
        Result := 'n0';
    jtNull: Result := 'null';
  else
    Result := 'x' + D.AsJSON;
  end;
end;

function SameJSON(A, B: TJSONData): Boolean;
var
  I, J: Integer;
  O: TJSONObject;
begin
  if (A = nil) or (B = nil) then
    Exit(A = B);
  if (A.JSONType = jtNumber) and (B.JSONType = jtNumber) then
    Exit(A.AsFloat = B.AsFloat);
  if A.JSONType <> B.JSONType then
    Exit(False);
  case A.JSONType of
    jtString: Result := A.AsString = B.AsString;
    jtBoolean: Result := A.AsBoolean = B.AsBoolean;
    jtNull: Result := True;
    jtArray:
      begin
        if A.Count <> B.Count then
          Exit(False);
        for I := 0 to A.Count - 1 do
          if not SameJSON(A.Items[I], B.Items[I]) then
            Exit(False);
        Result := True;
      end;
    jtObject:
      begin
        if A.Count <> B.Count then
          Exit(False);
        O := TJSONObject(B);
        for I := 0 to A.Count - 1 do
        begin
          J := O.IndexOfName(TJSONObject(A).Names[I]);
          if (J < 0) or not SameJSON(A.Items[I], O.Items[J]) then
            Exit(False);
        end;
        Result := True;
      end;
  else
    Result := False;
  end;
end;

function PosOf(P: TJSONData): TLspPos;
var
  Q: TJSONObject;
begin
  Q := JObj(P, 'position');
  Result := MkPos(JInt(Q, 'line'), JInt(Q, 'character'));
end;

{$PUSH}{$Q-}{$R-}
function TextHash(const S: string): string;
var
  H: QWord;
  C: Char;
begin
  H := QWord($CBF29CE484222325);
  for C in S do
    H := (H xor Ord(C)) * QWord($100000001B3);
  Result := IntToHex(H, 16);
end;
{$POP}

function BaseNoExt(const Path: string): string;
var
  Root, Ext: string;
begin
  SplitExt(BaseName(Path), Root, Ext);
  Result := Root;
end;

{ TServer: plumbing }

type
  TProvEntry = class
  public
    Key: string;
    Prov: TProvider;
  end;

  TSymbolsEntry = class
  public
    Stamp: string;
    Symbols: TJSONArray;
    destructor Destroy; override;
  end;

  TUnusedItem = class
  public
    Kind: string;
    Tok: TToken;
    Msg: string;
    Sym: TSym;
  end;

destructor TSymbolsEntry.Destroy;
begin
  Symbols.Free;
  inherited;
end;

constructor TServer.Create(ATransport: TTransport);
begin
  Channel := ATransport;
  Docs := TStrMap.Create;
  BoundCache := TStrMap.Create;
  ProvCache := TObjectList.Create(True);
  SymbolCache := TStrMap.Create;
  Inlay := TJSONObject.Create(['parameters', True, 'constants', True, 'endLabels', 25]);
  TypeChecks := True;
  Inbox := TInbox.Create;
  FGraveBounds := TObjectList.Create(True);
  FGraveProvs := TObjectList.Create(True);
  FGraveMisc := TObjectList.Create(True);
  FCancelLock := TCriticalSection.Create;
  FCancelled := TStringList.Create;
  FCancelled.Sorted := True;
  FCancelled.Duplicates := dupIgnore;
end;

destructor TServer.Destroy;
var
  I: Integer;
begin
  for I := 0 to BoundCache.Count - 1 do
    FGraveBounds.Add(BoundCache.At(I));
  BoundCache.Free;
  for I := 0 to ProvCache.Count - 1 do
    FGraveProvs.Add(TProvEntry(ProvCache[I]).Prov);
  ProvCache.Free;
  Bury;
  for I := 0 to Docs.Count - 1 do
    Docs.At(I).Free;
  Docs.Free;
  for I := 0 to SymbolCache.Count - 1 do
    SymbolCache.At(I).Free;
  SymbolCache.Free;
  Inlay.Free;
  Stubs.Free;
  Index.Free;
  Inbox.Free;
  FGraveBounds.Free;
  FGraveProvs.Free;
  FGraveMisc.Free;
  FCancelled.Free;
  FCancelLock.Free;
  if FReader <> nil then
  begin
    FReader.WaitFor;
    FReader.Free;
  end;
  inherited;
end;

procedure TServer.Bury;
begin
  FGraveMisc.Clear;
  FGraveBounds.Clear;
  FGraveProvs.Clear;
end;

procedure TServer.DropProvider(P: TProvider);
var
  I: Integer;
  Keep: TStrMap;
begin
  Keep := TStrMap.Create;
  for I := 0 to BoundCache.Count - 1 do
    if TBound(BoundCache.At(I)).Prov = P then
      FGraveBounds.Add(BoundCache.At(I))
    else
      Keep.Put(BoundCache.KeyAt(I), BoundCache.At(I));
  BoundCache.Free;
  BoundCache := Keep;
  FGraveProvs.Add(P);
end;

procedure TServer.Reply(Id: TJSONData; Result: TJSONData);
var
  M: TJSONObject;
begin
  M := TJSONObject.Create(['jsonrpc', '2.0']);
  try
    if Id <> nil then
      M.Add('id', Id.Clone)
    else
      M.Add('id', TJSONNull.Create);
    if Result = nil then
      Result := TJSONNull.Create;
    M.Add('result', Result);
    Channel.Send(M);
  finally
    M.Free;
  end;
end;

procedure TServer.ReplyError(Id: TJSONData; Code: Integer; const Message: string);
var
  M: TJSONObject;
begin
  M := TJSONObject.Create(['jsonrpc', '2.0']);
  try
    if Id <> nil then
      M.Add('id', Id.Clone)
    else
      M.Add('id', TJSONNull.Create);
    M.Add('error', TJSONObject.Create(['code', Code, 'message', Message]));
    Channel.Send(M);
  finally
    M.Free;
  end;
end;

procedure TServer.Notify(const Method: string; Params: TJSONData);
var
  M: TJSONObject;
begin
  M := TJSONObject.Create(['jsonrpc', '2.0', 'method', Method, 'params', Params]);
  try
    Channel.Send(M);
  finally
    M.Free;
  end;
end;

procedure TServer.Cancel(Id: TJSONData);
begin
  FCancelLock.Enter;
  try
    FCancelled.Add(IdKey(Id));
  finally
    FCancelLock.Leave;
  end;
end;

function TServer.IsCancelled(Id: TJSONData): Boolean;
var
  I: Integer;
begin
  FCancelLock.Enter;
  try
    I := FCancelled.IndexOf(IdKey(Id));
    Result := I >= 0;
    if Result then
      FCancelled.Delete(I);
  finally
    FCancelLock.Leave;
  end;
end;

function TServer.Run: Integer;
var
  Reader: TReader;
  Wait, Due, Now_: Double;
  P: TPending;
  Ms: Integer;
  Msg: TJSONData;
  Ended: Boolean;
begin
  Reader := TReader.Create(True);
  Reader.Server := Self;
  Reader.FreeOnTerminate := False;
  FReader := Reader;
  Reader.Start;
  while not HasExitCode do
  begin
    Ms := -1;
    if Pending <> nil then
    begin
      Now_ := MonotonicSeconds;
      Wait := 1e30;
      for P in Pending do
      begin
        Due := P.Last + DiagDelay;
        if P.First + DiagMaxDelay < Due then
          Due := P.First + DiagMaxDelay;
        if Due - Now_ < Wait then
          Wait := Due - Now_;
      end;
      if Wait < 0 then
        Wait := 0;
      Ms := Trunc(Wait * 1000) + 1;
    end;
    if not Inbox.Get(Ms, Msg, Ended) then
    begin
      FlushDiagnostics;
      Bury;
      Continue;
    end;
    if Ended then
    begin
      if Shutdown then
        Exit(0);
      Exit(1);
    end;
    try
      if Msg is TJSONObject then
        DispatchMsg(TJSONObject(Msg));
    finally
      Msg.Free;
      Bury;
    end;
  end;
  Result := ExitCode;
end;

function TServer.ReaderFinished: Boolean;
begin
  Result := (FReader = nil) or FReader.Finished;
end;

function TServer.PendingIndex(const Uri: string): Integer;
begin
  for Result := 0 to High(Pending) do
    if Pending[Result].Uri = Uri then
      Exit;
  Result := -1;
end;

procedure TServer.SchedulePending(const Uri: string);
var
  I: Integer;
  Now_: Double;
begin
  Now_ := MonotonicSeconds;
  I := PendingIndex(Uri);
  if I < 0 then
  begin
    SetLength(Pending, Length(Pending) + 1);
    I := High(Pending);
    Pending[I].Uri := Uri;
    Pending[I].First := Now_;
  end;
  Pending[I].Last := Now_;
end;

procedure TServer.DropPending(const Uri: string);
var
  I: Integer;
begin
  I := PendingIndex(Uri);
  if I >= 0 then
    Delete(Pending, I, 1);
end;

procedure TServer.ScheduleDiagnostics(Doc: TDoc);
begin
  SchedulePending(Doc.Uri);
end;

procedure TServer.FlushDiagnostics(Force: Boolean);
var
  Snapshot: array of TPending;
  P: TPending;
  Now_, Due: Double;
  Doc: TDoc;
begin
  Now_ := MonotonicSeconds;
  Snapshot := Copy(Pending);
  for P in Snapshot do
  begin
    Due := P.Last + DiagDelay;
    if P.First + DiagMaxDelay < Due then
      Due := P.First + DiagMaxDelay;
    if not Force and (Now_ < Due) then
      Continue;
    DropPending(P.Uri);
    Doc := TDoc(Docs.Get(P.Uri));
    if Doc <> nil then
      Publish(Doc);
  end;
end;

const
  StaleOk: array[0..3] of string = ('textDocument/semanticTokens/full', 'textDocument/semanticTokens/range',
    'textDocument/documentHighlight', 'textDocument/codeAction');

function HandlerName(const Method: string): string;
var
  I: Integer;
begin
  Result := Method;
  for I := 1 to Length(Result) do
    if not (Result[I] in ['A'..'Z', 'a'..'z', '0'..'9']) then
      Result[I] := '_';
end;

procedure TServer.DispatchMsg(Msg: TJSONObject);
var
  MethodData, Id, PD: TJSONData;
  Method: string;
  IsRequest: Boolean;
  P: TJSONObject;
  Res: TJSONData;
begin
  MethodData := Msg.Find('method');
  if (MethodData = nil) or (MethodData.JSONType = jtNull) then
    Exit;
  Method := MethodData.AsString;
  Id := Msg.Find('id');
  IsRequest := Id <> nil;
  if (Id <> nil) and (Id.JSONType = jtNull) then
    Id := nil;
  PD := Msg.Find('params');
  if (PD is TJSONObject) and Truthy(PD) then
    P := TJSONObject(PD)
  else
    P := TJSONObject.Create;
  try
    try
      if Method = 'exit' then
      begin
        HasExitCode := True;
        if Shutdown then
          ExitCode := 0
        else
          ExitCode := 1;
        Exit;
      end;
      if not Initialized and (Method <> 'initialize') then
      begin
        if IsRequest then
          raise ERequestError.Create(ServerNotInitialized, 'server not initialized');
        Exit;
      end;
      if Shutdown and IsRequest then
        raise ERequestError.Create(InvalidRequest, 'server is shutting down');
      if IsRequest and IsCancelled(Id) then
        raise ERequestError.Create(RequestCancelled, 'request cancelled');
      if IsRequest and InList(Method, StaleOk) and Inbox.ChangeWaiting(JStr(JObj(P, 'textDocument'), 'uri')) then
        raise ERequestError.Create(ContentModified, 'the document changed');
      Res := Handle(HandlerName(Method), Method, P, IsRequest);
      if IsRequest then
        Reply(Id, Res)
      else
        Res.Free;
    except
      on E: ERequestError do
        if IsRequest then
          ReplyError(Id, E.Code, E.Message)
        else
          Log('notification ' + Method + ' failed: ' + E.Message);
      on E: Exception do
      begin
        Log('internal error in ' + Method + ': ' + E.ClassName + ': ' + E.Message);
        DumpExceptionBackTrace(StdErr);
        if IsRequest then
          ReplyError(Id, InternalError, E.ClassName + ': ' + E.Message);
      end;
    end;
  finally
    if P <> PD then
      P.Free;
  end;
end;

function TServer.DocOf(P: TJSONObject; Required: Boolean): TDoc;
var
  TD: TJSONObject;
  Uri: string;
begin
  TD := JObj(P, 'textDocument');
  if TD = nil then
    raise Exception.Create('KeyError: ''textDocument''');
  if not JHas(TD, 'uri') then
    raise Exception.Create('KeyError: ''uri''');
  Uri := JStr(TD, 'uri');
  Result := TDoc(Docs.Get(Uri));
  if (Result = nil) and Required then
    raise ERequestError.Create(InvalidParams, 'document is not open: ' + Uri);
end;

function TServer.IsStub(const Path: string): Boolean;
begin
  Result := (Stubs <> nil) and Stubs.IsStub(Path);
end;

function TServer.DocKey(Doc: TDoc): string;
begin
  if Doc.Path <> '' then
    Result := PathKey(Doc.Path)
  else
    Result := Doc.Uri;
end;

type
  TKeyText = record
    Key, Uri, Text: string;
  end;

  TKeyTexts = array of TKeyText;

function TServer.ProviderFor(Doc: TDoc; IncludeSelf: Boolean; Texts: TStrMap): TProvider;
var
  Dirs, Uniq, Seen: TStringArray;
  D, U, TplDir, K, Key: string;
  I, J: Integer;
  Overlay: TStrMap;
  O: TDoc;
  Keys: TStringList;
  E, Stale: TProvEntry;
  Found: Boolean;
begin
  Dirs := nil;
  if (Doc.Path <> '') and not IsStub(Doc.Path) then
    PushStr(Dirs, DirName(Doc.Path));
  for D in Roots do
    PushStr(Dirs, D);
  if Tp7Dir <> '' then
  begin
    U := ListCi(Tp7Dir, 'units');
    if U <> '' then
      PushStr(Dirs, U);
    PushStr(Dirs, Tp7Dir);
  end;
  if Tpl <> '' then
  begin
    TplDir := DirName(Tpl);
    if LowerText(BaseName(TplDir)) = 'bin' then
    begin
      U := ListCi(DirName(TplDir), 'units');
      if U <> '' then
        PushStr(Dirs, U);
    end;
  end;
  Uniq := nil;
  Seen := nil;
  for D in Dirs do
  begin
    K := NormCase(AbsPath(D));
    Found := False;
    for U in Seen do
      if U = K then
        Found := True;
    if not Found then
    begin
      PushStr(Seen, K);
      PushStr(Uniq, D);
    end;
  end;
  Overlay := TStrMap.Create;
  Keys := TStringList.Create;
  try
    for I := 0 to Docs.Count - 1 do
    begin
      O := TDoc(Docs.At(I));
      if (O.Path <> '') and (IncludeSelf or (O <> Doc)) then
        Overlay.Put(PathKey(O.Path), O);
    end;
    if Texts <> nil then
      for I := 0 to Texts.Count - 1 do
        Overlay.Put(Texts.KeyAt(I), Texts.At(I));
    for I := 0 to Overlay.Count - 1 do
      Keys.Add(Overlay.KeyAt(I));
    Keys.Sorted := False;
    Keys.CaseSensitive := True;
    Keys.Sort;
    Key := '';
    for K in Seen do
      Key := Key + K + #1;
    Key := Key + #2 + Tpl + #2;
    for I := 0 to Keys.Count - 1 do
    begin
      if Overlay.Get(Keys[I]) is TDoc then
        D := TDoc(Overlay.Get(Keys[I])).Text
      else
        D := TTextHolder(Overlay.Get(Keys[I])).Text;
      Key := Key + Keys[I] + #0 + TextHash(D) + #1;
    end;
    Stale := nil;
    for J := 0 to ProvCache.Count - 1 do
    begin
      E := TProvEntry(ProvCache[J]);
      if E.Key <> Key then
        Continue;
      if E.Prov.StillValid then
      begin
        ProvCache.Extract(E);
        ProvCache.Add(E);
        Exit(E.Prov);
      end;
      Stale := E;
      Break;
    end;
    Result := TProvider.Create(Uniq, Tpl, Index);
    Result.Near := Doc.Path;
    for I := 0 to Overlay.Count - 1 do
      if Overlay.At(I) is TDoc then
        Result.SetOverlay(Overlay.KeyAt(I), TDoc(Overlay.At(I)).Text)
      else
        Result.SetOverlay(Overlay.KeyAt(I), TTextHolder(Overlay.At(I)).Text);
    if Stale <> nil then
    begin
      DropProvider(Stale.Prov);
      Stale.Prov := Result;
    end
    else
    begin
      E := TProvEntry.Create;
      E.Key := Key;
      E.Prov := Result;
      ProvCache.Add(E);
    end;
    while ProvCache.Count > 6 do
    begin
      DropProvider(TProvEntry(ProvCache[0]).Prov);
      ProvCache.Delete(0);
    end;
  finally
    Keys.Free;
    Overlay.Free;
  end;
end;

function TServer.NewBound(const Key, Uri, Text: string; Prov: TProvider; WithIncludes: Boolean): TBound;
var
  Res: TParseResult;
  B: TBinder;
  Path: string;
begin
  if WithIncludes then
  begin
    if IsAbsPath(Key) then
      Path := Key
    else
      Path := '';
    Res := Parse(Text, DefaultDefines, Prov.IncludeResolver(Path), Path);
  end
  else
    Res := Parse(Text);
  B := nil;
  try
    B := TBinder.Create(Res, Prov);
    B.Run;
  except
    B.Free;
    Res.Free;
    raise;
  end;
  Result := TBound.Create(Key, Uri, Text, Res, B, Prov);
  FGraveBounds.Add(Result);
end;

function TServer.BindDoc(Doc: TDoc; Prov: TProvider): TBound;
var
  Got: TBound;
  Res: TParseResult;
  B: TBinder;
begin
  Got := TBound(BoundCache.Get(Doc.Uri));
  if (Got <> nil) and (Got.Prov = Prov) and (Got.Text = Doc.Text) then
    Exit(Got);
  Res := Parse(Doc.Text, DefaultDefines, Prov.IncludeResolver(Doc.Path), Doc.Path);
  B := nil;
  try
    B := TBinder.Create(Res, Prov);
    B.Run;
  except
    B.Free;
    Res.Free;
    raise;
  end;
  Result := TBound.Create(DocKey(Doc), Doc.Uri, Doc.Text, Res, B, Prov);
  if Got <> nil then
    FGraveBounds.Add(Got);
  BoundCache.Put(Doc.Uri, Result);
end;

procedure TServer.Publish(Doc: TDoc);
var
  Diags: TJSONArray;
  V: TJSONData;
begin
  Diags := Diagnose(Doc);
  if Doc.Version <> nil then
    V := Doc.Version.Clone
  else
    V := TJSONNull.Create;
  Notify('textDocument/publishDiagnostics', TJSONObject.Create(['uri', Doc.Uri, 'version', V, 'diagnostics', Diags]));
end;

function InactiveHints(Bound: TBound): TJSONArray;
var
  Run: TTokens;
  Tok: TToken;

  procedure Flush_;
  var
    A, B: Integer;
  begin
    A := 0;
    B := High(Run);
    while (B >= A) and (Run[B].Kind in [tkWS, tkNL]) do
      Dec(B);
    while (A <= B) and (Run[A].Kind in [tkWS, tkNL]) do
      Inc(A);
    if A <= B then
      Result.Add(DiagJSON(MkRange(TokenRange(Run[A], Bound.Lines).S, TokenRange(Run[B], Bound.Lines).E), 4,
        'inactive code: this branch of the conditional compilation is switched off', True));
    Run := nil;
  end;

begin
  Result := TJSONArray.Create;
  Run := nil;
  for Tok in Bound.Res.Tokens do
    if Tok.Active or (Tok.Kind = tkEOF) then
      Flush_
    else
    begin
      SetLength(Run, Length(Run) + 1);
      Run[High(Run)] := Tok;
    end;
  Flush_;
end;

function TServer.Diagnose(Doc: TDoc): TJSONArray;
var
  Prov: TProvider;
  Bound: TBound;
  More: TJSONArray;
begin
  if IsStub(Doc.Path) then
    Exit(TJSONArray.Create);
  Prov := ProviderFor(Doc);
  Bound := BindDoc(Doc, Prov);
  Result := DiagnosticsFor(Doc.Text, Bound.Res);
  AddAll(Result, InactiveHints(Bound));
  try
    More := SemanticDiagnostics(Doc, Bound, Prov);
    AddAll(Result, More);
  except
    on E: Exception do
      Log('semantic diagnostics failed: ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure TServer.AddReport(Tok: TToken; const Msg: string);
begin
  FReports.Add(DiagJSON(TokenRange(Tok, FReportLines), 1, Msg));
end;

function RoutineHasNoBodyByDesign(Node: TNode): Boolean;
var
  T: TToken;
  L: string;
begin
  for T in Node.Tokens do
  begin
    L := LowerText(T.Text);
    if (L = 'external') or (L = 'inline') then
      Exit(True);
  end;
  Result := False;
end;

function VisibleOutside(Sym: TSym; Bound: TBound): Boolean;
var
  Root, Impl: TNode;
  K: TObject;
  First: TToken;
begin
  if Sym.Implicit then
    Exit(False);
  if Sym.Tok = nil then
    Exit(True);
  if Sym.Kind in [skParam, skLabel] then
    Exit(False);
  if (Sym.FileName <> '') and (PathKey(Sym.FileName) <> Bound.Key) then
    Exit(True);
  Root := nil;
  if (Bound.Res.Tree.Kids <> nil) and (Bound.Res.Tree.Kids[0] is TNode) then
    Root := TNode(Bound.Res.Tree.Kids[0]);
  if (Root = nil) or (Root.Kind <> nkUnit) then
    Exit(False);
  Impl := nil;
  for K in Root.Kids do
    if IsKind(K, nkImplementation) then
    begin
      Impl := TNode(K);
      Break;
    end;
  First := nil;
  if Impl <> nil then
    First := FirstToken(Impl);
  Result := (First = nil) or (Sym.Tok.Idx < First.Idx);
end;

function SplitWords(const Text: string; Into: TStrMap): Boolean;
var
  I, Start, Len: SizeInt;
begin
  I := 1;
  while I <= Length(Text) do
    if Text[I] in ['A'..'Z', 'a'..'z', '_'] then
    begin
      Start := I;
      Inc(I);
      while IsWordAt(Text, I, Len) do
        Inc(I, Len);
      Into.Put(LowerText(Copy(Text, Start, I - Start)), Into);
    end
    else
      Inc(I);
  Result := True;
end;

function HiddenWords(Res: TParseResult; const AsmNodes: TNodes): TStrMap;
var
  Tok, T: TToken;
  N: TNode;
  Toks: TTokens;
begin
  Result := TStrMap.Create;
  for Tok in Res.DocSig do
    for T in Tok.Leading do
      if not T.Active then
        SplitWords(T.Text, Result);
  for N in AsmNodes do
  begin
    Toks := N.Tokens;
    if Toks <> nil then
      SplitWords(Copy(Res.Source, Toks[0].Pos, Toks[High(Toks)].Pos + Length(Toks[High(Toks)].Text) - Toks[0].Pos),
        Result);
  end;
end;

function TServer.UnusedItems(Doc: TDoc; Bound: TBound; Prov: TProvider): TObjectList;
var
  Res: TParseResult;
  B: TBinder;
  UsesNodes, AsmNodes: TNodes;
  N, Nm: TNode;
  Hidden, UsedUnits, UsedPaths: TStrMap;
  PIn, PEnum, PById, PSyms: TPtrMap;
  T, Tok: TToken;
  I: Integer;
  Sym: TSym;
  Info: TUnitInfo;
  K: TObject;
  Lbl: string;
  Skip: Boolean;

  procedure Hint(ATok: TToken; const AMsg, AKind: string; ASym: TSym);
  var
    It: TUnusedItem;
  begin
    It := TUnusedItem.Create;
    It.Tok := ATok;
    It.Msg := AMsg;
    It.Kind := AKind;
    It.Sym := ASym;
    Result.Add(It);
  end;

begin
  Result := TObjectList.Create(True);
  Res := Bound.Res;
  B := Bound.Binder;
  UsesNodes := nil;
  AsmNodes := nil;
  for N in Res.Tree.Walk do
    if N.Kind = nkUsesClause then
    begin
      SetLength(UsesNodes, Length(UsesNodes) + 1);
      UsesNodes[High(UsesNodes)] := N;
    end
    else if N.Kind = nkAsm then
    begin
      SetLength(AsmNodes, Length(AsmNodes) + 1);
      AsmNodes[High(AsmNodes)] := N;
    end;
  Hidden := HiddenWords(Res, AsmNodes);
  PIn := TPtrMap.Create;
  PSyms := TPtrMap.Create;
  PEnum := TPtrMap.Create;
  PById := TPtrMap.Create;
  UsedUnits := TStrMap.Create;
  UsedPaths := TStrMap.Create;
  try
    for N in UsesNodes do
      for T in N.Tokens do
        PIn.Put(T, T);
    for I := 0 to B.Refs.Count - 1 do
    begin
      Tok := TToken(B.Refs.KeyAt(I));
      if B.Decls.Has(Tok) or PIn.Has(Tok) then
        Continue;
      Sym := TSym(B.Refs.At(I));
      PSyms.Put(Sym, Sym);
      if Sym.Kind = skUnit then
        UsedUnits.Put(LowerText(Sym.Name), Sym)
      else if Sym.Lib and (Sym.Home <> '') then
        UsedUnits.Put(LowerText(Sym.Home), Sym)
      else if Sym.FileName <> '' then
        UsedPaths.Put(PathKey(Sym.FileName), Sym);
    end;
    for I := 0 to B.Refs.Count - 1 do
    begin
      Sym := TSym(B.Refs.At(I));
      if (Sym.Kind = skEnum) and (Sym.TypeTok <> nil) and not B.Decls.Has(B.Refs.KeyAt(I)) then
        PEnum.Put(Sym.TypeTok, Sym);
    end;
    for T in Res.Sig do
      if T.Via = nil then
        PById.Put(T, T);
    for I := 0 to B.Decls.Count - 1 do
    begin
      Tok := TToken(B.Decls.KeyAt(I));
      if not PById.Has(Tok) then
        Continue;
      Sym := TSym(B.Decls.At(I));
      if (Sym.Tok <> Tok) or not (Sym.Kind in [skVar, skConst, skType]) or Sym.Implicit then
        Continue;
      if PSyms.Has(Sym) or Hidden.Has(LowerText(Sym.Name)) or VisibleOutside(Sym, Bound) then
        Continue;
      if (Sym.Kind = skType) and PEnum.Has(Tok) then
        Continue;
      case Sym.Kind of
        skVar: Lbl := 'variable';
        skConst: Lbl := 'constant';
      else
        Lbl := 'type';
      end;
      Hint(Tok, Format('%s ''%s'' is declared but never used', [Lbl, Sym.Name]), SymKindNames[Sym.Kind], Sym);
    end;
    for N in UsesNodes do
      for K in N.Kids do
      begin
        if not IsKind(K, nkName) or (TNode(K).Kids = nil) then
          Continue;
        Nm := TNode(K);
        Tok := KT(Nm.Kids[0]);
        Info := Prov.Get(Tok.Text);
        if (Info = nil) or (LowerText(Info.Name) = 'system') then
          Continue;
        if UsedUnits.Has(LowerText(Info.Name)) or ((Info.Path <> '') and UsedPaths.Has(PathKey(Info.Path))) then
          Continue;
        Skip := False;
        for I := 0 to Info.Exports_.Count - 1 do
          if Hidden.Has(Info.Exports_.KeyAt(I)) then
          begin
            Skip := True;
            Break;
          end;
        if Skip then
          Continue;
        Hint(Tok, Format('unit ''%s'' is not used: no name declared in it appears in this file', [Info.Name]), 'unit',
          nil);
      end;
  finally
    UsedPaths.Free;
    UsedUnits.Free;
    PById.Free;
    PEnum.Free;
    PSyms.Free;
    PIn.Free;
    Hidden.Free;
  end;
end;

function TServer.SemanticDiagnostics(Doc: TDoc; Bound: TBound; Prov: TProvider): TJSONArray;
var
  Res: TParseResult;
  B: TBinder;
  Lines: TStringArray;
  Tok, T: TToken;
  Err, Name, Rest, Where, What: string;
  I, J: Integer;
  Inc_: TInclude;
  Included, Blind, IsMissing: Boolean;
  Seen: TPtrMap;
  D: TDup;
  Sym: TSym;
  Items: TObjectList;

  procedure Add(ATok: TToken; Severity: Integer; const Msg: string);
  begin
    Result.Add(DiagJSON(TokenRange(ATok, Lines), Severity, Msg));
  end;

begin
  Result := TJSONArray.Create;
  Res := Bound.Res;
  B := Bound.Binder;
  if Res.Diags <> nil then
    Exit;
  Lines := Bound.Lines;
  for Tok in B.MissingUnits do
    Add(Tok, 1, Format('unit ''%s'' not found: there is no %s.pas or %s.tpu in the search path (Turbo Pascal: file not found)',
      [Tok.Text, Tok.Text, Tok.Text]));
  for I := 0 to Prov.Errors.Count - 1 do
  begin
    Err := Prov.Errors[I];
    J := Pos(':', Err);
    if J > 0 then
    begin
      Name := LowerText(StripSpace(Copy(Err, 1, J - 1)));
      Rest := StripSpace(Copy(Err, J + 1, MaxInt));
    end
    else
    begin
      Name := LowerText(StripSpace(Err));
      Rest := Err;
    end;
    Tok := nil;
    for T in Res.Sig do
      if (T.Kind = tkIdent) and (LowerText(T.Text) = Name) then
      begin
        Tok := T;
        Break;
      end;
    if Tok = nil then
      Continue;
    IsMissing := False;
    for T in B.MissingUnits do
      if T = Tok then
        IsMissing := True;
    if not IsMissing then
      Add(Tok, 2, Format('unit ''%s'' could not be read, so the names it declares are not checked (%s)', [Tok.Text, Rest]));
  end;
  Included := False;
  for Inc_ in Res.Includes do
    if not Inc_.Resolved then
    begin
      Included := True;
      Add(Inc_.Token, 1, Format('include file ''%s'' not found: there is no such file next to this one or in the search path (Turbo Pascal: file not found)',
        [StripSpace(Inc_.Name)]));
    end;
  Blind := (B.MissingUnits <> nil) or (Prov.Errors.Count > 0) or Included;
  if not Blind then
  begin
    Seen := TPtrMap.Create;
    try
      for Tok in B.Unresolved do
        if not Seen.Has(Tok) then
        begin
          Seen.Put(Tok, Tok);
          if Tok.Kind = tkInt then
            Add(Tok, 1, Format('label ''%s'' is not declared', [Tok.Text]))
          else
            Add(Tok, 1, Format('unknown identifier ''%s''', [Tok.Text]));
        end;
    finally
      Seen.Free;
    end;
  end;
  for D in B.Dups do
    if (LowerText(D.Tok.Text) = LowerText(D.Old.Name)) and (D.Old.Tok <> nil) and (D.Old.Tok <> D.Tok) then
    begin
      if D.Old.Tok.FileName <> '' then
        Where := Format('in %s, line %d', [BaseName(D.Old.Tok.FileName), D.Old.Tok.Line])
      else
        Where := Format('on line %d', [D.Old.Tok.Line]);
      Add(D.Tok, 1, Format('duplicate identifier ''%s'' (first declared %s)', [D.Tok.Text, Where]));
    end;
  if TypeChecks and not Blind then
  begin
    FReports := Result;
    FReportLines := Lines;
    try
      CheckTypes(Res, B, Prov, @AddReport);
    except
      on E: Exception do
        Log('type check failed: ' + E.ClassName + ': ' + E.Message);
    end;
    FReports := nil;
  end;
  if not Included then
  begin
    for I := 0 to B.Decls.Count - 1 do
    begin
      Sym := TSym(B.Decls.At(I));
      if (Sym.Kind = skRoutine) and (Sym.Tok <> nil) and (Pointer(Sym.Tok) = B.Decls.KeyAt(I)) and not Sym.Lib and
        (Sym.Tok.Via = nil) and not Sym.HasBody and (Sym.Node <> nil) and not RoutineHasNoBodyByDesign(Sym.Node) then
      begin
        if Sym.Owner <> nil then
          What := 'method'
        else
          What := 'routine';
        if Sym.Owner <> nil then
          Add(Sym.Tok, 1, Format('%s ''%s'' is declared but has no implementation in this file', [What, Sym.Name]))
        else
          Add(Sym.Tok, 2, Format('%s ''%s'' is declared but has no implementation in this file', [What, Sym.Name]));
      end;
    end;
    Items := UnusedItems(Doc, Bound, Prov);
    try
      for I := 0 to Items.Count - 1 do
        Result.Add(DiagJSON(TokenRange(TUnusedItem(Items[I]).Tok, Lines), 4, TUnusedItem(Items[I]).Msg, True));
    finally
      Items.Free;
    end;
  end;
end;

function UnitHead(const Text: string): Boolean;
var
  I, Len: SizeInt;
begin
  I := 1;
  repeat
    while (I <= Length(Text)) and (SpaceLen(Text, I) > 0) do
      Inc(I, SpaceLen(Text, I));
    if (I <= Length(Text)) and (Text[I] = '{') then
    begin
      while (I <= Length(Text)) and (Text[I] <> '}') do
        Inc(I);
      if I > Length(Text) then
        Exit(False);
      Inc(I);
    end
    else if Copy(Text, I, 2) = '(*' then
    begin
      Len := Pos('*)', Copy(Text, I + 2, MaxInt));
      if Len = 0 then
        Exit(False);
      I := I + 2 + Len + 1;
    end
    else
      Break;
  until False;
  Result := (LowerCase(Copy(Text, I, 4)) = 'unit') and not IsWordAt(Text, I + 4, Len);
end;

function ContainsWord(const Text, Word: string): Boolean;
var
  LT, LW: string;
  I, Len: SizeInt;
begin
  LT := LowerText(Text);
  LW := LowerText(Word);
  if LW = '' then
    Exit(False);
  I := Pos(LW, LT);
  while I > 0 do
  begin
    if (IsWordBefore(LT, I) <> IsWordAt(LW, 1, Len)) and
      (IsWordAt(LT, I + Length(LW), Len) <> IsWordBefore(LW, Length(LW) + 1)) then
      Exit(True);
    I := Pos(LW, LT, I + 1);
  end;
  Result := False;
end;

function IncludesName(const Text, Name: string): Boolean;
var
  LT, LN, Seg: string;
  I, Q, J: SizeInt;
begin
  LT := LowerText(Text);
  LN := LowerText(Name);
  for I := 1 to Length(LT) - 2 do
  begin
    if not (LT[I] in ['{', '(', '*']) or (LT[I + 1] <> '$') or (LT[I + 2] <> 'i') then
      Continue;
    Q := I + 3;
    if Copy(LT, Q, 6) = 'nclude' then
      if (Q + 6 <= Length(LT)) and (SpaceLen(LT, Q + 6) > 0) then
        Q := Q + 6;
    if (Q > Length(LT)) or (SpaceLen(LT, Q) = 0) then
      Continue;
    while (Q <= Length(LT)) and (SpaceLen(LT, Q) > 0) do
      Inc(Q, SpaceLen(LT, Q));
    J := Q;
    while (J <= Length(LT)) and not (LT[J] in ['}', '*']) do
      Inc(J);
    Seg := Copy(LT, Q, J - Q);
    if Pos(LN, Seg) > 0 then
      Exit(True);
  end;
  Result := False;
end;

procedure TServer.RefreshDependents(Changed: TDoc; OnlyUnits: Boolean; OnlyIncludes: Boolean);
var
  Name: string;
  I: Integer;
  D: TDoc;
  Hit: Boolean;
begin
  if Changed <> nil then
    Name := BaseNoExt(Changed.Path)
  else
    Name := '';
  if OnlyIncludes and (Name = '') then
    Exit;
  for I := 0 to Docs.Count - 1 do
  begin
    D := TDoc(Docs.At(I));
    if (D = Changed) or IsStub(D.Path) then
      Continue;
    if OnlyIncludes then
      Hit := IncludesName(D.Text, Name)
    else if Name = '' then
      Hit := True
    else
      Hit := ContainsWord(D.Text, Name);
    if Hit then
      ScheduleDiagnostics(D);
  end;
end;

function TServer.FormatText(Doc: TDoc): string;
var
  Prov: TProvider;
begin
  Prov := ProviderFor(Doc);
  Result := FormatSource(Doc.Text, DefaultDefines, MaxWidth, nil, True, Prov);
  if Prov.Errors.Count > 0 then
    Log('units that could not be loaded: ' + JoinLines(Prov.Errors.ToStringArray, '; '));
  if Prov.Warnings.Count > 0 then
    Log('unit loading notes: ' + JoinLines(Prov.Warnings.ToStringArray, '; '));
end;

{ TServer: lifecycle and documents }

type
  TSymAt = record
    Doc: TDoc;
    Prov: TProvider;
    Bound: TBound;
    Tok: TToken;
    Sym: TSym;
    Key: string;
  end;

  THandlerServer = class helper for TServer
    function OnInitialize(P: TJSONObject): TJSONData;
    function OnInitialized(P: TJSONObject): TJSONData;
    function OnDidOpen(P: TJSONObject): TJSONData;
    function OnDidChange(P: TJSONObject): TJSONData;
    function OnDidSave(P: TJSONObject): TJSONData;
    function OnDidChangeWatchedFiles(P: TJSONObject): TJSONData;
    function OnDidClose(P: TJSONObject): TJSONData;
    function OnFormatting(P: TJSONObject): TJSONData;
    function StubTarget(Prov: TProvider; Sym: TSym; out Path: string; out Stub: TStub; out E: TStubEntry): Boolean;
    function StubHover(Prov: TProvider; Sym: TSym): string;
    function StubLocation(Prov: TProvider; Sym: TSym): TJSONData;
    function Locate(P: TJSONObject; Definition: Boolean): TJSONData;
    function Location(Doc: TDoc; Prov: TProvider; const Lines: TStringArray; const Path: string; DTok: TToken): TJSONData;
    function OnHover(P: TJSONObject): TJSONData;
    function ExprHover(P: TJSONObject): TJSONData;
    function OnCompletion(P: TJSONObject): TJSONData;
    function OnInlayHint(P: TJSONObject): TJSONData;
    function OnSignatureHelp(P: TJSONObject): TJSONData;
    function OnTypeDefinition(P: TJSONObject): TJSONData;
    function SymbolAt(P: TJSONObject): TSymAt;
    function OnImplementation(P: TJSONObject): TJSONData;
    function ObjectTypes(Doc: TDoc; Bound: TBound): TObjectList;
    function HierarchyType(Bound: TBound; Sym: TSym): TSym;
    function HierItem(const Uri: string; const Lines: TStringArray; Sym: TSym): TJSONObject;
    function OnPrepareTypeHierarchy(P: TJSONObject): TJSONData;
    function ItemType(Item: TJSONObject; out Doc: TDoc; out Prov: TProvider; out Bound: TBound): TSym;
    function OnSupertypes(P: TJSONObject): TJSONData;
    function OnSubtypes(P: TJSONObject): TJSONData;
    function Candidates(Doc: TDoc): TKeyTexts;
    function Occurrences(Doc: TDoc; Bound: TBound; Sym: TSym; const Key: string; Family: Boolean): TObjectList;
    function OnDocumentHighlight(P: TJSONObject): TJSONData;
    function OnReferences(P: TJSONObject): TJSONData;
    function OnPrepareRename(P: TJSONObject): TJSONData;
    function OnRename(P: TJSONObject): TJSONData;
    function OnDocumentSymbol(P: TJSONObject): TJSONData;
    function OnSelectionRange(P: TJSONObject): TJSONData;
    function OnRangeFormatting(P: TJSONObject): TJSONData;
    function OnWorkspaceSymbol(P: TJSONObject): TJSONData;
    function OnCodeAction(P: TJSONObject): TJSONData;
    function Semantic(P: TJSONObject; Ranged: Boolean): TJSONData;
  end;

function TServer.Handle(const Method, Original: string; P: TJSONObject; IsRequest: Boolean): TJSONData;
begin
  Result := nil;
  case Method of
    'initialize': Result := OnInitialize(P);
    'initialized': Result := OnInitialized(P);
    'shutdown':
      begin
        Shutdown := True;
        Result := nil;
      end;
    'textDocument_didOpen': Result := OnDidOpen(P);
    'textDocument_didChange': Result := OnDidChange(P);
    'textDocument_didSave': Result := OnDidSave(P);
    'workspace_didChangeWatchedFiles': Result := OnDidChangeWatchedFiles(P);
    'textDocument_didClose': Result := OnDidClose(P);
    'textDocument_formatting': Result := OnFormatting(P);
    'textDocument_definition': Result := Locate(P, True);
    'textDocument_declaration': Result := Locate(P, False);
    'textDocument_hover': Result := OnHover(P);
    'textDocument_completion': Result := OnCompletion(P);
    'textDocument_inlayHint': Result := OnInlayHint(P);
    'textDocument_signatureHelp': Result := OnSignatureHelp(P);
    'textDocument_typeDefinition': Result := OnTypeDefinition(P);
    'textDocument_implementation': Result := OnImplementation(P);
    'textDocument_prepareTypeHierarchy': Result := OnPrepareTypeHierarchy(P);
    'typeHierarchy_supertypes': Result := OnSupertypes(P);
    'typeHierarchy_subtypes': Result := OnSubtypes(P);
    'textDocument_documentHighlight': Result := OnDocumentHighlight(P);
    'textDocument_references': Result := OnReferences(P);
    'textDocument_prepareRename': Result := OnPrepareRename(P);
    'textDocument_rename': Result := OnRename(P);
    'textDocument_documentSymbol': Result := OnDocumentSymbol(P);
    'textDocument_selectionRange': Result := OnSelectionRange(P);
    'textDocument_rangeFormatting': Result := OnRangeFormatting(P);
    'workspace_symbol': Result := OnWorkspaceSymbol(P);
    'textDocument_codeAction': Result := OnCodeAction(P);
    'textDocument_semanticTokens_full': Result := Semantic(P, False);
    'textDocument_semanticTokens_range': Result := Semantic(P, True);
  else
    if IsRequest then
      raise ERequestError.Create(MethodNotFound, 'method not supported: ' + Original);
  end;
end;

function StrArray(const A: array of string): TJSONArray;
var
  S: string;
begin
  Result := TJSONArray.Create;
  for S in A do
    Result.Add(S);
end;

function THandlerServer.OnInitialize(P: TJSONObject): TJSONData;
var
  Folders, Opts, Caps, Enc, Wf, Hints: TJSONData;
  I: Integer;
  Path, StubDir, PosEnc: string;
  Bases: TStringArray;
  Ds: TJSONObject;
begin
  Folders := P.Find('workspaceFolders');
  if Folders is TJSONArray then
    for I := 0 to Folders.Count - 1 do
      if UriToPath(JStr(Folders.Items[I], 'uri'), Path) then
        PushStr(Roots, Path);
  if Roots = nil then
  begin
    if not UriToPath(JStr(P, 'rootUri'), Path) then
    begin
      Path := JStr(P, 'rootPath');
      if Path <> '' then
        Path := AbsPath(Path);
    end;
    if Path <> '' then
      PushStr(Roots, Path);
  end;
  Caps := JObj(P, 'capabilities');
  Ds := JObj(JObj(Caps, 'textDocument'), 'documentSymbol');
  Hierarchical := Truthy(TJSONData(Ds)) and Truthy(Ds.Find('hierarchicalDocumentSymbolSupport'));
  PosEnc := 'utf-16';
  Enc := nil;
  if JObj(Caps, 'general') <> nil then
    Enc := JObj(Caps, 'general').Find('positionEncodings');
  if Enc is TJSONArray then
    for I := 0 to Enc.Count - 1 do
      if (Enc.Items[I].JSONType = jtString) and (Enc.Items[I].AsString = 'utf-8') then
        PosEnc := 'utf-8';
  Utf8Positions := PosEnc = 'utf-8';
  PositionsInBytes := Utf8Positions;
  Opts := P.Find('initializationOptions');
  Tp7Dir := JStr(Opts, 'tp7Dir');
  if Tp7Dir = '' then
    Tp7Dir := GetEnvironmentVariable('TP7_DIR');
  Bases := nil;
  if Tp7Dir <> '' then
    PushStr(Bases, Tp7Dir);
  Bases := Concat(Bases, Roots);
  Tpl := FindTpl(Bases);
  StubDir := JStr(Opts, 'stubDir');
  if StubDir = '' then
    StubDir := GetEnvironmentVariable('TP7LS_STUB_DIR');
  if StubDir = '' then
    StubDir := DefaultStubDir;
  Stubs.Free;
  Stubs := TStubStore.Create(StubDir);
  Index.Free;
  Index := TProjectIndex.Create(Roots);
  Hints := nil;
  if Opts is TJSONObject then
    Hints := TJSONObject(Opts).Find('inlayHints');
  if Hints is TJSONObject then
    for I := 0 to Hints.Count - 1 do
    begin
      if Inlay.IndexOfName(TJSONObject(Hints).Names[I]) >= 0 then
        Inlay.Delete(TJSONObject(Hints).Names[I]);
      Inlay.Add(TJSONObject(Hints).Names[I], Hints.Items[I].Clone);
    end;
  TypeChecks := True;
  if Opts is TJSONObject then
    if (TJSONObject(Opts).Find('typeDiagnostics') <> nil) and
      (TJSONObject(Opts).Find('typeDiagnostics').JSONType = jtBoolean) and
      not TJSONObject(Opts).Find('typeDiagnostics').AsBoolean then
      TypeChecks := False;
  Wf := JObj(JObj(Caps, 'workspace'), 'didChangeWatchedFiles');
  CanWatch := (Wf <> nil) and Truthy(TJSONObject(Wf).Find('dynamicRegistration'));
  Initialized := True;
  Result := TJSONObject.Create([
    'capabilities', TJSONObject.Create([
      'positionEncoding', PosEnc,
      'textDocumentSync', TJSONObject.Create(['openClose', True, 'change', 1, 'save',
        TJSONObject.Create(['includeText', False])]),
      'documentFormattingProvider', True,
      'definitionProvider', True,
      'declarationProvider', True,
      'documentSymbolProvider', True,
      'documentHighlightProvider', True,
      'hoverProvider', True,
      'inlayHintProvider', True,
      'selectionRangeProvider', True,
      'documentRangeFormattingProvider', True,
      'workspaceSymbolProvider', True,
      'codeActionProvider', TJSONObject.Create(['codeActionKinds', StrArray(['quickfix', 'source.organizeImports'])]),
      'completionProvider', TJSONObject.Create(['triggerCharacters', StrArray(['.']), 'resolveProvider', False]),
      'signatureHelpProvider', TJSONObject.Create(['triggerCharacters', StrArray(['(', ',']),
        'retriggerCharacters', StrArray([','])]),
      'typeDefinitionProvider', True,
      'implementationProvider', True,
      'typeHierarchyProvider', True,
      'referencesProvider', True,
      'renameProvider', TJSONObject.Create(['prepareProvider', True]),
      'semanticTokensProvider', TJSONObject.Create([
        'legend', TJSONObject.Create(['tokenTypes', StrArray(SemTypes), 'tokenModifiers', StrArray(SemMods)]),
        'full', True, 'range', True])]),
    'serverInfo', TJSONObject.Create(['name', ServerName, 'version', ServerVersion])]);
end;

function THandlerServer.OnInitialized(P: TJSONObject): TJSONData;
var
  M: TJSONObject;
  Note: string;
begin
  Result := nil;
  if CanWatch and (Roots <> nil) then
  begin
    M := TJSONObject.Create(['jsonrpc', '2.0', 'id', 'tp7ls-watch', 'method', 'client/registerCapability', 'params',
      TJSONObject.Create(['registrations', TJSONArray.Create([TJSONObject.Create(['id', 'tp7ls-files', 'method',
      'workspace/didChangeWatchedFiles', 'registerOptions', TJSONObject.Create(['watchers',
      TJSONArray.Create([TJSONObject.Create(['globPattern', '**/*.{pas,PAS,tpu,TPU,inc,INC}'])])])])])])]);
    try
      Channel.Send(M);
    finally
      M.Free;
    end;
  end;
  if Index <> nil then
  begin
    Index.Refresh(True);
    if Index.Truncated then
      Note := Format(' (cut off at %d files)', [Index.MaxFiles])
    else
      Note := '';
    Log(Format('project index: %d units, %d sources%s', [Length(Index.UnitNames), Length(Index.Sources), Note]));
  end;
  if Tpl <> '' then
    Log('TURBO.TPL: ' + Tpl)
  else
    Notify('window/showMessage', TJSONObject.Create(['type', 2, 'message',
      'tp7ls: TURBO.TPL not found - identifiers of System/Crt/Dos... keep their spelling. Set TP7_DIR or ' +
      'initializationOptions.tp7Dir.']));
end;

function THandlerServer.OnDidOpen(P: TJSONObject): TJSONData;
var
  TD: TJSONObject;
  Doc, Old: TDoc;
begin
  Result := nil;
  TD := JObj(P, 'textDocument');
  if TD = nil then
    raise Exception.Create('KeyError: ''textDocument''');
  if not JHas(TD, 'uri') then
    raise Exception.Create('KeyError: ''uri''');
  Doc := TDoc.Create(JStr(TD, 'uri'), TD.Find('version'), JStr(TD, 'text'));
  Old := TDoc(Docs.Get(Doc.Uri));
  if Old <> nil then
    FGraveMisc.Add(Old);
  Docs.Put(Doc.Uri, Doc);
  DropPending(Doc.Uri);
  Publish(Doc);
  RefreshDependents(Doc, True, True);
end;

function THandlerServer.OnDidChange(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Changes, Ch, V: TJSONData;
  I: Integer;
begin
  Result := nil;
  Doc := DocOf(P, False);
  if Doc = nil then
    Exit;
  Changes := P.Find('contentChanges');
  if Changes is TJSONArray then
    for I := 0 to Changes.Count - 1 do
    begin
      Ch := Changes.Items[I];
      if (Ch is TJSONObject) and (TJSONObject(Ch).Find('range') <> nil) and
        (TJSONObject(Ch).Find('range').JSONType <> jtNull) then
        raise ERequestError.Create(InvalidParams, 'incremental changes are not supported (full sync was announced)');
      Doc.Text := JStr(Ch, 'text');
    end;
  V := JObj(P, 'textDocument').Find('version');
  if V <> nil then
  begin
    Doc.Version.Free;
    Doc.Version := V.Clone;
  end;
  ScheduleDiagnostics(Doc);
  if UnitHead(Doc.Text) then
    RefreshDependents(Doc)
  else
    RefreshDependents(Doc, True, True);
end;

function THandlerServer.OnDidSave(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
begin
  Result := nil;
  Doc := TDoc(Docs.Get(JStr(JObj(P, 'textDocument'), 'uri')));
  if Doc <> nil then
    RefreshDependents(Doc, False);
end;

function THandlerServer.OnDidChangeWatchedFiles(P: TJSONObject): TJSONData;
begin
  Result := nil;
  if Index <> nil then
    Index.Invalidate;
  RefreshDependents(nil);
end;

function THandlerServer.OnDidClose(P: TJSONObject): TJSONData;
var
  Uri: string;
  Closed: TDoc;
  B: TObject;
  Keep: TStrMap;
  I: Integer;
begin
  Result := nil;
  Uri := JStr(JObj(P, 'textDocument'), 'uri');
  DropPending(Uri);
  B := BoundCache.Get(Uri);
  if B <> nil then
  begin
    Keep := TStrMap.Create;
    for I := 0 to BoundCache.Count - 1 do
      if BoundCache.KeyAt(I) <> Uri then
        Keep.Put(BoundCache.KeyAt(I), BoundCache.At(I));
    BoundCache.Free;
    BoundCache := Keep;
    FGraveBounds.Add(B);
  end;
  Closed := TDoc(Docs.Get(Uri));
  if Closed <> nil then
  begin
    Keep := TStrMap.Create;
    for I := 0 to Docs.Count - 1 do
      if Docs.KeyAt(I) <> Uri then
        Keep.Put(Docs.KeyAt(I), Docs.At(I));
    Docs.Free;
    Docs := Keep;
    FGraveMisc.Add(Closed);
    Notify('textDocument/publishDiagnostics', TJSONObject.Create(['uri', Uri, 'diagnostics', TJSONArray.Create]));
    RefreshDependents(Closed, True, True);
  end;
end;

function THandlerServer.OnFormatting(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  New: string;
begin
  Doc := DocOf(P);
  if IsStub(Doc.Path) then
    Exit(TJSONArray.Create);
  try
    New := FormatText(Doc);
  except
    on E: EFormatError do
      raise ERequestError.Create(RequestFailed, E.Message);
  end;
  Result := ComputeEdits(Doc.Text, New);
end;

{ stubs, locations, hover }

function THandlerServer.StubTarget(Prov: TProvider; Sym: TSym; out Path: string; out Stub: TStub;
  out E: TStubEntry): Boolean;
var
  Info: TUnitInfo;
  Kind, Owner: string;
begin
  Result := False;
  Path := '';
  Stub := nil;
  E := nil;
  if (Stubs = nil) or (Sym = nil) then
    Exit;
  if Sym.Kind = skUnit then
  begin
    Info := Sym.UnitInfo;
    Kind := 'unit';
    Owner := '';
  end
  else if Sym.Lib and (Sym.Home <> '') then
  begin
    Info := Prov.Get(Sym.Home);
    Kind := SymKindNames[Sym.Kind];
    Owner := Sym.StubOwner;
  end
  else
    Exit;
  if (Info = nil) or not Stubs.Get(Info, Path, Stub) then
    Exit;
  E := Stub.Find(Kind, Sym.Name, Owner);
  Result := E <> nil;
end;

function StripDeclSemicolon(const S: string): string;
var
  K, J: Integer;
begin
  Result := S;
  if (Result <> '') and (Result[Length(Result)] = ';') then
    Exit(Copy(Result, 1, Length(Result) - 1));
  if (Result = '') or (Result[Length(Result)] <> '}') then
    Exit;
  J := Length(Result) - 1;
  while (J > 0) and not (Result[J] in ['{', '}']) do
    Dec(J);
  if (J = 0) or (Result[J] <> '{') then
    Exit;
  K := J - 1;
  while (K > 0) and (Result[K] in [#9..#13, ' ']) do
    Dec(K);
  if (K > 0) and (Result[K] = ';') then
    Result := Copy(Result, 1, K - 1) + Copy(Result, K + 1, MaxInt);
end;

function HasWordP1(const S: string): Boolean;
var
  I, Len: SizeInt;
begin
  I := Pos('P1', S);
  while I > 0 do
  begin
    if not IsWordBefore(S, I) and not IsWordAt(S, I + 2, Len) then
      Exit(True);
    I := Pos('P1', S, I + 1);
  end;
  Result := False;
end;

function THandlerServer.StubHover(Prov: TProvider; Sym: TSym): string;
var
  Path, First, Text, Extra, Unit_, OwnerName, X: string;
  Stub: TStub;
  E: TStubEntry;
  Block: TStringArray;
  Indent, I, J: Integer;
  Len: SizeInt;
  Member: Boolean;
begin
  Result := '';
  if not StubTarget(Prov, Sym, Path, Stub, E) or (Sym.Kind = skUnit) then
    Exit;
  Block := Stub.Block(SymKindNames[Sym.Kind], Sym.Name, Sym.StubOwner);
  if Block = nil then
    Exit;
  First := Block[0];
  Indent := Length(First) - Length(LStripSpace(First));
  Member := (Sym.Kind = skConst) and ((E.Col <> Indent) or
    (Copy(LowerText(LStripSpace(First)), 1, Length(LowerText(Sym.Name))) <> LowerText(Sym.Name)));
  if Member then
  begin
    I := 1;
    while (I <= Length(First)) and (SpaceLen(First, I) > 0) do
      Inc(I, SpaceLen(First, I));
    J := I;
    while IsWordAt(First, J, Len) do
      Inc(J, Len);
    if J > I then
      OwnerName := Copy(First, I, J - I)
    else
      OwnerName := 'an enumeration';
    Text := 'const ' + Sym.Name;
    Extra := '*constant of ' + OwnerName + '*';
  end
  else
  begin
    Text := '';
    for I := 0 to High(Block) do
    begin
      X := StripDeclSemicolon(RStripSpace(Copy(Block[I], Indent + 1, MaxInt)));
      if I > 0 then
        Text := Text + #10;
      Text := Text + X;
    end;
    case Sym.Kind of
      skConst: Text := 'const ' + Text;
      skType: Text := 'type ' + Text;
      skVar: Text := 'var ' + Text;
    end;
    Extra := '';
    if (Sym.Kind = skField) and (Sym.StubOwner <> '') then
      Extra := '*field of ' + Sym.StubOwner + '*'
    else if (Sym.Kind = skRoutine) and HasWordP1(Text) then
      Extra := '*parameter names are not stored in TPU files: P1, P2... are placeholders*'
    else if Sym.Kind = skBuiltin then
      Extra := '*built-in: the signature is informal*';
  end;
  if Sym.Home <> '' then
    Unit_ := '*unit ' + Sym.Home + '*'
  else
    Unit_ := '';
  if (Unit_ <> '') and (Extra <> '') then
    Extra := Unit_ + ' '#$C2#$B7' ' + Extra
  else
    Extra := Unit_ + Extra;
  Result := '```pascal'#10 + Text + #10'```'#10 + Extra;
end;

function THandlerServer.StubLocation(Prov: TProvider; Sym: TSym): TJSONData;
var
  Path: string;
  Stub: TStub;
  E: TStubEntry;
  Line: string;
begin
  if not StubTarget(Prov, Sym, Path, Stub, E) then
    Exit(nil);
  Line := Stub.Lines[E.Line];
  Result := TJSONObject.Create(['uri', PathToUri(Path), 'range', RangeJSON(MkRange(MkPos(E.Line,
    UnitsOf(Line, E.Col)), MkPos(E.Line, UnitsOf(Line, E.Col + E.Len))))]);
end;

procedure LogProv(Prov: TProvider);
begin
  if Prov.Errors.Count > 0 then
    Log('units that could not be loaded: ' + JoinLines(Prov.Errors.ToStringArray, '; '));
  if Prov.Warnings.Count > 0 then
    Log('unit loading notes: ' + JoinLines(Prov.Warnings.ToStringArray, '; '));
end;

function THandlerServer.Location(Doc: TDoc; Prov: TProvider; const Lines: TStringArray; const Path: string;
  DTok: TToken): TJSONData;
var
  DLines: TStringArray;
  Uri: string;
  R: TLspRange;
begin
  if Path = '' then
  begin
    Uri := Doc.Uri;
    DLines := Lines;
  end
  else
  begin
    try
      DLines := SplitNL(Prov.ReadText(Path));
    except
      on EStreamError do
        Exit(nil);
      on EInOutError do
        Exit(nil);
    end;
    Uri := PathToUri(Path);
  end;
  if DTok = nil then
    R := MkRange(MkPos(0, 0), MkPos(0, 0))
  else
    R := TokenRange(DTok, DLines, Path <> '');
  Result := TJSONObject.Create(['uri', Uri, 'range', RangeJSON(R)]);
end;

function THandlerServer.Locate(P: TJSONObject; Definition: Boolean): TJSONData;
var
  Doc: TDoc;
  Prov: TProvider;
  Bound: TBound;
  Tok, Target: TToken;
  Pos_: TLspPos;
  Sym: TSym;
  Path: string;
begin
  Doc := DocOf(P);
  Pos_ := PosOf(P);
  Prov := ProviderFor(Doc);
  Bound := BindDoc(Doc, Prov);
  Tok := IdentAt(Bound.Res.DocSig, Bound.Lines, Pos_.Line, Pos_.Ch);
  if Tok = nil then
    Exit(nil);
  LogProv(Prov);
  Sym := RefOrDecl(Bound.Binder, Tok);
  if Sym = nil then
    Exit(nil);
  if Sym.Implicit then
  begin
    if (Sym.Owner = nil) or (Sym.Owner.Tok = nil) then
      Exit(nil);
    Path := Sym.Owner.FileName;
    Target := Sym.Owner.Tok;
  end
  else if Sym.Kind = skUnit then
  begin
    if Sym.FileName = '' then
      Exit(StubLocation(Prov, Sym));
    Path := Sym.FileName;
    Target := nil;
  end
  else if Sym.Tok = nil then
    Exit(StubLocation(Prov, Sym))
  else if Definition and (Sym.Kind in [skRoutine, skLabel]) and (Sym.ImplTok <> nil) then
  begin
    Path := Sym.FileName;
    Target := Sym.ImplTok;
  end
  else
  begin
    Path := Sym.FileName;
    Target := Sym.Tok;
  end;
  Result := Location(Doc, Prov, Bound.Lines, Path, Target);
end;

function THandlerServer.SymbolAt(P: TJSONObject): TSymAt;
var
  Pos_: TLspPos;
begin
  Result.Doc := DocOf(P);
  Result.Prov := ProviderFor(Result.Doc);
  Result.Bound := BindDoc(Result.Doc, Result.Prov);
  Pos_ := PosOf(P);
  Result.Tok := IdentAt(Result.Bound.Res.DocSig, Result.Bound.Lines, Pos_.Line, Pos_.Ch);
  Result.Sym := nil;
  Result.Key := '';
  if Result.Tok = nil then
    Exit;
  Result.Sym := RefOrDecl(Result.Bound.Binder, Result.Tok);
  if (Result.Sym = nil) and (Result.Tok.Kind = tkInt) then
  begin
    Result.Tok := nil;
    Exit;
  end;
  if Result.Sym <> nil then
    Result.Key := SymKey(Result.Sym, Result.Bound.Key);
end;

function THandlerServer.OnHover(P: TJSONObject): TJSONData;
var
  At: TSymAt;
  Md: string;
begin
  Result := ExprHover(P);
  if Result <> nil then
    Exit;
  At := SymbolAt(P);
  if At.Sym = nil then
    Exit(nil);
  Md := '';
  if At.Sym.Lib and not At.Sym.Implicit then
    Md := StubHover(At.Prov, At.Sym);
  if Md = '' then
    Md := HoverMarkdown(At.Sym);
  if (At.Sym.Tok <> nil) and (At.Sym.FileName <> '') and (PathKey(At.Sym.FileName) <> At.Bound.Key) then
    Md := Md + Format(#10'*declared in %s, line %d*', [BaseName(At.Sym.FileName), At.Sym.Tok.Line]);
  Result := TJSONObject.Create(['contents', TJSONObject.Create(['kind', 'markdown', 'value', Md]), 'range',
    RangeJSON(TokenRange(At.Tok, At.Bound.Lines))]);
end;

function SplitJoinSpace(const S: string): string;
var
  I, Len, Start: SizeInt;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    Len := SpaceLen(S, I);
    if Len > 0 then
    begin
      Inc(I, Len);
      Continue;
    end;
    Start := I;
    while (I <= Length(S)) and (SpaceLen(S, I) = 0) do
      Inc(I);
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Copy(S, Start, I - Start);
  end;
end;

function THandlerServer.ExprHover(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Prov: TProvider;
  Bound: TBound;
  Pos_: TLspPos;
  Tok, A, B: TToken;
  Refs: TBinderRefs;
  Got: TExprAt;
  Toks: TTokens;
  Inside: Boolean;
  Text, Code, Md: string;
  R: TLspRange;
begin
  Doc := DocOf(P, False);
  if Doc = nil then
    Exit(nil);
  Prov := ProviderFor(Doc);
  Bound := BindDoc(Doc, Prov);
  Pos_ := PosOf(P);
  Tok := TokenUnder(Bound.Res.DocSig, Bound.Lines, Pos_.Line, Pos_.Ch);
  if (Tok = nil) or not (Tok.Kind in [tkSym, tkKW]) then
    Exit(nil);
  Refs := TBinderRefs.Create(Bound.Binder);
  try
    Got := ExprAt(Bound.Res.Tree, Refs, Prov, Tok);
  finally
    Refs.Free;
  end;
  if Got = nil then
    Exit(nil);
  try
    Toks := Got.Tokens;
    Inside := True;
    for A in Toks do
      if (A.Via <> nil) or (A.FileName <> '') then
        Inside := False;
    if Inside then
    begin
      A := Toks[0];
      B := Toks[High(Toks)];
      Text := SplitJoinSpace(Copy(Bound.Text, A.Pos, B.Pos + Length(B.Text) - A.Pos));
      if Utf8Length(Text, 1, Length(Text)) > 80 then
        Text := CharCopy(Text, 79) + Ellipsis;
      R := MkRange(TokenRange(A, Bound.Lines).S, TokenRange(B, Bound.Lines).E);
    end
    else
    begin
      Text := Compact(Toks);
      R := TokenRange(Tok, Bound.Lines);
    end;
    Code := Text + ': ' + TypeText(Got.Ty);
    if (Got.Ty.Kind = tyInt) and Got.Ty.HasValue then
      Code := Format('%s: %s = %d', [Text, ConstTypeName(Got.Ty), Got.Ty.Value]);
    Md := '```pascal'#10 + Code + #10'```';
    if Got.Ty = FloatTy then
      Md := Md + #10'*Extended in {$N+} code*';
  finally
    Got.Free;
  end;
  Result := TJSONObject.Create(['contents', TJSONObject.Create(['kind', 'markdown', 'value', Md]), 'range',
    RangeJSON(R)]);
end;

{ completion, inlay hints, signature help }

function CompletionItem(Sym: TSym; const Group: string): TJSONObject;
var
  Detail: string;
begin
  Result := TJSONObject.Create(['label', Sym.Name, 'kind', CompletionKind(Sym), 'sortText', Group + LowerText(Sym.Name)]);
  Detail := CompletionDetail(Sym);
  if Detail <> '' then
    Result.Add('detail', Detail);
end;

function ScopeAt(Bound: TBound; const Here: TLspPos): TScope;
var
  Pair: TSymNodePair;
  A: TToken;
  Lo, Hi: TLspPos;
  BestL, BestC, L, C: Integer;
begin
  Result := nil;
  BestL := 0;
  BestC := 0;
  for Pair in Bound.Binder.NodeScopes do
  begin
    A := FirstToken(Pair.Node);
    if A = nil then
      Continue;
    Lo := TokenRange(A, Bound.Lines).S;
    Hi := TokenRange(LastToken(Pair.Node), Bound.Lines).E;
    if PosLE(Lo, Here) and PosLE(Here, Hi) then
    begin
      L := Hi.Line - Lo.Line;
      C := Hi.Ch - Lo.Ch;
      if (Result = nil) or (L < BestL) or ((L = BestL) and (C < BestC)) then
      begin
        Result := Pair.Scope;
        BestL := L;
        BestC := C;
      end;
    end;
  end;
end;

function InUsesClause(const Before: TTokens): Boolean;
var
  I: Integer;
  T: TToken;
begin
  for I := High(Before) downto 0 do
  begin
    T := Before[I];
    if (T.Text = ',') or (T.Kind = tkIdent) then
      Continue;
    Exit((T.Kind = tkKW) and (LowerText(T.Text) = 'uses'));
  end;
  Result := False;
end;

function WithFields(Bound: TBound; Prev: TToken; const Ancestors: TNodes; Scope: TScope): TFPList;
var
  Node: TNode;
  Do_: TObject;
  I: Integer;
  Chain: TChain;
  U: TUnitInfo;
  Ti: TTInfo;
begin
  Result := TFPList.Create;
  for Node in Ancestors do
  begin
    if (Node.Kind <> nkWith) or (Length(Node.Kids) < 3) then
      Continue;
    Do_ := Node.Kids[High(Node.Kids) - 1];
    if not (Do_ is TToken) or (Prev.Idx < TToken(Do_).Idx) then
      Continue;
    for I := High(Node.Kids) - 2 downto 1 do
      if Node.Kids[I] is TNode then
        if MemberChain(TNode(Node.Kids[I]).Tokens, Chain) then
        begin
          Bound.Binder.ChainType(Chain, Scope, U, Ti);
          if (U = nil) and (Ti <> nil) and (Ti.Kind = tiRecord) then
            Result.Add(Ti.GetFields);
        end;
  end;
end;

function Items_(Items: TJSONArray): TJSONObject;
begin
  Result := TJSONObject.Create(['isIncomplete', False, 'items', Items]);
end;

function THandlerServer.OnCompletion(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Prov: TProvider;
  Bound: TBound;
  Here, Pos_: TLspPos;
  Tok, Prev: TToken;
  R: TLspRange;
  Before: TTokens;
  Scope, Sc: TScope;
  Items: TJSONArray;
  Chain: TChain;
  U: TUnitInfo;
  Ti: TTInfo;
  Members: TStrMap;
  I, J, Depth, Rank: Integer;
  Seen: TStrMap;
  Sym: TSym;
  Ancestors: TNodes;
  Tables: array of TStrMap;
  Own, Name, Kw: string;
  Withs: TFPList;
begin
  Doc := DocOf(P);
  Prov := ProviderFor(Doc);
  Bound := BindDoc(Doc, Prov);
  Pos_ := PosOf(P);
  Here := Pos_;
  for Tok in Bound.Res.Tokens do
    if Tok.Kind in [tkComment, tkDirective, tkString] then
    begin
      R := TokenRange(Tok, Bound.Lines);
      if PosLess(R.S, Here) and PosLess(Here, R.E) then
        Exit(nil);
    end;
  Before := TokensBefore(Bound.Res.DocSig, Bound.Lines, Here);
  if (Before <> nil) and (Before[High(Before)].Kind = tkIdent) then
    if PosLE(Here, TokenRange(Before[High(Before)], Bound.Lines).E) then
      SetLength(Before, Length(Before) - 1);
  if Before <> nil then
    Prev := Before[High(Before)]
  else
    Prev := nil;
  Scope := ScopeAt(Bound, Here);
  Items := TJSONArray.Create;
  if (Prev <> nil) and (Prev.Text = '.') then
  begin
    if (Scope = nil) or not MemberChain(Copy(Before, 0, Length(Before) - 1), Chain) then
    begin
      Items.Free;
      Exit(nil);
    end;
    Bound.Binder.ChainType(Chain, Scope, U, Ti);
    if U <> nil then
      Members := U.Exports_
    else if (Ti <> nil) and (Ti.Kind = tiRecord) then
      Members := Ti.GetFields
    else
    begin
      Items.Free;
      Exit(nil);
    end;
    for I := 0 to Members.Count - 1 do
      Items.Add(CompletionItem(TSym(Members.At(I)), '0'));
    Exit(Items_(Items));
  end;
  if (Prev <> nil) and (Prev.Kind = tkKW) and InList(LowerText(Prev.Text), NoNameAfter) then
  begin
    Items.Free;
    Exit(nil);
  end;
  if (Prev <> nil) and (Prev.Kind = tkKW) and (LowerText(Prev.Text) = 'goto') then
  begin
    Sc := Scope;
    Seen := TStrMap.Create;
    try
      while Sc <> nil do
      begin
        for I := 0 to Sc.Table.Count - 1 do
        begin
          Sym := TSym(Sc.Table.At(I));
          if (Sym.Kind = skLabel) and not Seen.Has(Sc.Table.KeyAt(I)) then
          begin
            Seen.Put(Sc.Table.KeyAt(I), Sym);
            Rank := Seen.Count;
            if Rank > 9 then
              Rank := 9;
            Items.Add(TJSONObject.Create(['label', Sym.Name, 'kind', CkReference, 'detail', 'label', 'sortText',
              IntToStr(Rank) + LowerText(Sym.Name)]));
          end;
        end;
        Sc := Sc.Parent;
      end;
    finally
      Seen.Free;
    end;
    Exit(Items_(Items));
  end;
  if Prev <> nil then
    Ancestors := TokenAncestors(Bound.Res.Tree, Prev)
  else
    Ancestors := nil;
  if (Scope <> nil) and InTypePosition(Prev, Ancestors) then
  begin
    Seen := TStrMap.Create;
    try
      Depth := 0;
      Sc := Scope;
      while Sc <> nil do
      begin
        Tables := nil;
        for I := High(Sc.Units) downto 0 do
        begin
          SetLength(Tables, Length(Tables) + 1);
          Tables[High(Tables)] := Sc.Units[I].Exports_;
        end;
        SetLength(Tables, Length(Tables) + 1);
        Tables[High(Tables)] := Sc.Table;
        for J := 0 to High(Tables) do
          for I := 0 to Tables[J].Count - 1 do
          begin
            Sym := TSym(Tables[J].At(I));
            if not Seen.Has(Tables[J].KeyAt(I)) and (Sym.Kind in [skType, skUnit]) then
            begin
              Seen.Put(Tables[J].KeyAt(I), Sym);
              if Depth < 8 then
                Items.Add(CompletionItem(Sym, IntToStr(Depth)))
              else
                Items.Add(CompletionItem(Sym, '8'));
            end;
          end;
        Inc(Depth);
        Sc := Sc.Parent;
      end;
    finally
      Seen.Free;
    end;
    for Kw in TypeStarters do
      Items.Add(TJSONObject.Create(['label', Kw, 'kind', CkKeyword, 'sortText', '9' + Kw]));
    if Ancestors[0].Kind = nkTypeDecl then
      Items.Add(TJSONObject.Create(['label', 'object', 'kind', CkKeyword, 'sortText', '9object']));
    Exit(Items_(Items));
  end;
  if InUsesClause(Before) then
  begin
    Own := LowerText(BaseNoExt(Doc.Path));
    for Name in Prov.UnitNames do
    begin
      if LowerText(Name) = Own then
        Continue;
      Items.Add(TJSONObject.Create(['label', Name, 'kind', CkModule, 'sortText', '0' + LowerText(Name)]));
    end;
    Exit(Items_(Items));
  end;
  if Scope <> nil then
  begin
    Withs := WithFields(Bound, Prev, Ancestors, Scope);
    try
      for J := 0 to Withs.Count - 1 do
      begin
        Members := TStrMap(Withs[J]);
        Rank := J;
        if Rank > 9 then
          Rank := 9;
        for I := 0 to Members.Count - 1 do
          Items.Add(CompletionItem(TSym(Members.At(I)), '0' + IntToStr(Rank)));
      end;
    finally
      Withs.Free;
    end;
    Seen := TStrMap.Create;
    try
      Depth := 0;
      Sc := Scope;
      while Sc <> nil do
      begin
        Tables := nil;
        for I := High(Sc.Units) downto 0 do
        begin
          SetLength(Tables, Length(Tables) + 1);
          Tables[High(Tables)] := Sc.Units[I].Exports_;
        end;
        SetLength(Tables, Length(Tables) + 1);
        Tables[High(Tables)] := Sc.Table;
        for J := 0 to High(Tables) do
          for I := 0 to Tables[J].Count - 1 do
          begin
            Sym := TSym(Tables[J].At(I));
            if Seen.Has(Tables[J].KeyAt(I)) or (Sym.Kind = skLabel) then
              Continue;
            Seen.Put(Tables[J].KeyAt(I), Sym);
            if Depth < 8 then
              Items.Add(CompletionItem(Sym, IntToStr(Depth)))
            else
              Items.Add(CompletionItem(Sym, '8'));
          end;
        Inc(Depth);
        Sc := Sc.Parent;
      end;
    finally
      Seen.Free;
    end;
  end;
  for Kw in PasKeywords do
    Items.Add(TJSONObject.Create(['label', Kw, 'kind', CkKeyword, 'sortText', '9' + Kw]));
  Result := Items_(Items);
end;

type
  THint = record
    Pos: TLspPos;
    Obj: TJSONObject;
  end;

function IntOf(D: TJSONData): Int64;
begin
  case D.JSONType of
    jtNumber: Result := Trunc(D.AsFloat);
    jtBoolean: Result := Ord(D.AsBoolean);
    jtString: Result := StrToInt64(Trim(D.AsString));
  else
    raise Exception.Create('TypeError: int() argument must be a string or a number');
  end;
end;

function THandlerServer.OnInlayHint(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Prov: TProvider;
  Bound: TBound;
  Rng: TJSONObject;
  First, Last, I, J: Integer;
  Data: TInlayData;
  Hints: array of THint;
  H: THint;
  Pos_: TLspPos;
  Mn: TJSONData;
  MinLines: Int64;
  Arr: TJSONArray;

  procedure AddHint(const At: TLspPos; O: TJSONObject);
  begin
    SetLength(Hints, Length(Hints) + 1);
    Hints[High(Hints)].Pos := At;
    Hints[High(Hints)].Obj := O;
  end;

  function Keep(const At: TLspPos): Boolean;
  begin
    Result := (First <= At.Line) and (At.Line <= Last);
  end;

begin
  Doc := TDoc(Docs.Get(JStr(JObj(P, 'textDocument'), 'uri')));
  if (Doc = nil) or IsStub(Doc.Path) then
    Exit(TJSONArray.Create);
  Prov := ProviderFor(Doc);
  Bound := BindDoc(Doc, Prov);
  if Bound.Res.Diags <> nil then
    Exit(TJSONArray.Create);
  Rng := JObj(P, 'range');
  First := JInt(JObj(Rng, 'start'), 'line', 0);
  Last := JInt(JObj(Rng, 'end'), 'line', 1 shl 30);
  Data := InlayData(Bound.Res, Bound.Binder, Prov);
  Hints := nil;
  if Truthy(Inlay.Find('parameters')) then
    for I := 0 to High(Data.Params) do
    begin
      Pos_ := TokenRange(Data.Params[I].Tok, Bound.Lines).S;
      if Keep(Pos_) then
        AddHint(Pos_, TJSONObject.Create(['position', PosJSON(Pos_), 'label', Data.Params[I].Text, 'kind', 2,
          'paddingRight', True]));
    end;
  if Truthy(Inlay.Find('constants')) then
    for I := 0 to High(Data.Consts) do
    begin
      Pos_ := TokenRange(Data.Consts[I].Tok, Bound.Lines).E;
      if Keep(Pos_) then
        AddHint(Pos_, TJSONObject.Create(['position', PosJSON(Pos_), 'label', Data.Consts[I].Text, 'kind', 1]));
    end;
  Mn := Inlay.Find('endLabels');
  if Truthy(Mn) then
  begin
    MinLines := IntOf(Mn);
    for I := 0 to High(Data.Ends) do
    begin
      Pos_ := TokenRange(Data.Ends[I].Tok, Bound.Lines).E;
      if (Data.Ends[I].Lines >= MinLines) and Keep(Pos_) then
        AddHint(Pos_, TJSONObject.Create(['position', PosJSON(Pos_), 'label', ' { ' + Data.Ends[I].Name + ' }',
          'paddingLeft', True]));
    end;
  end;
  for I := 1 to High(Hints) do
  begin
    H := Hints[I];
    J := I - 1;
    while (J >= 0) and PosLess(H.Pos, Hints[J].Pos) do
    begin
      Hints[J + 1] := Hints[J];
      Dec(J);
    end;
    Hints[J + 1] := H;
  end;
  Arr := TJSONArray.Create;
  for H in Hints do
    Arr.Add(H.Obj);
  Result := Arr;
end;

function THandlerServer.OnSignatureHelp(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Prov: TProvider;
  Bound: TBound;
  Pos_: TLspPos;
  Tok: TToken;
  Index, I, K: Integer;
  Sym: TSym;
  Md, Lab, Rest, Note, X: string;
  Params: TSpans;
  Sig: TJSONObject;
  Ps: TJSONArray;
  Parts: TStringArray;
const
  Fence = '```pascal'#10;
begin
  Doc := DocOf(P);
  Prov := ProviderFor(Doc);
  Bound := BindDoc(Doc, Prov);
  Pos_ := PosOf(P);
  if not CallContext(Bound.Res.DocSig, Bound.Lines, Pos_.Line, Pos_.Ch, Tok, Index) then
    Exit(nil);
  Sym := TSym(Bound.Binder.Refs.Get(Tok));
  if (Sym = nil) or not (Sym.Kind in [skRoutine, skBuiltin]) then
    Exit(nil);
  Md := '';
  if Sym.Lib and not Sym.Implicit then
    Md := StubHover(Prov, Sym);
  if Md = '' then
    Md := HoverMarkdown(Sym);
  if Copy(Md, 1, Length(Fence)) <> Fence then
    Exit(nil);
  K := Pos(#10'```', Copy(Md, Length(Fence) + 1, MaxInt));
  if K = 0 then
    Exit(nil);
  Lab := Copy(Md, Length(Fence) + 1, K - 1);
  Rest := Copy(Md, Length(Fence) + K + 4, MaxInt);
  if Copy(Rest, 1, 1) = #10 then
    Delete(Rest, 1, 1);
  I := Pos(#10, Lab);
  if I > 0 then
    Lab := Copy(Lab, 1, I - 1);
  while (Lab <> '') and (Lab[Length(Lab)] = ';') do
    SetLength(Lab, Length(Lab) - 1);
  Params := SignatureParams(Lab);
  if Params = nil then
    Exit(nil);
  Note := '';
  Parts := SplitNL(Rest);
  for X in Parts do
    if StripSpace(X) <> '' then
    begin
      if Note <> '' then
        Note := Note + ' '#$C2#$B7' ';
      Note := Note + StripSpace(X);
    end;
  Ps := TJSONArray.Create;
  for I := 0 to High(Params) do
    Ps.Add(TJSONObject.Create(['label', TJSONArray.Create([UnitsOf(Lab, Params[I].A),
      UnitsOf(Lab, Params[I].B)])]));
  Sig := TJSONObject.Create(['label', Lab, 'parameters', Ps]);
  if Note <> '' then
    Sig.Add('documentation', TJSONObject.Create(['kind', 'markdown', 'value', Note]));
  if (Index >= Length(Params)) and (Pos('...', Lab) > 0) then
    Index := High(Params);
  if Index < Length(Params) then
    Sig.Add('activeParameter', Index);
  Result := TJSONObject.Create(['signatures', TJSONArray.Create([Sig]), 'activeSignature', 0]);
  if Index < Length(Params) then
    TJSONObject(Result).Add('activeParameter', Index)
  else
    TJSONObject(Result).Add('activeParameter', TJSONNull.Create);
end;

function THandlerServer.OnTypeDefinition(P: TJSONObject): TJSONData;
var
  At: TSymAt;
  Sym, Ts: TSym;
  U: TUnitInfo;
  Name: TNode;
begin
  At := SymbolAt(P);
  Sym := At.Sym;
  if Sym = nil then
    Exit(nil);
  if Sym.Lib and not Sym.Implicit then
  begin
    if Sym.Kind = skType then
      Exit(StubLocation(At.Prov, Sym));
    if Sym.HasTypeRef then
    begin
      U := At.Prov.Get(Sym.TypeRefUnit);
      Ts := nil;
      if U <> nil then
        Ts := TSym(U.Exports_.Get(LowerText(Sym.TypeRefName)));
      if (Ts <> nil) and Ts.Lib then
        Exit(StubLocation(At.Prov, Ts));
      Exit(nil);
    end;
    Exit(nil);
  end;
  if Sym.Implicit and (Sym.Owner <> nil) and (Sym.Owner.Tok <> nil) then
    Exit(Location(At.Doc, At.Prov, At.Bound.Lines, Sym.Owner.FileName, Sym.Owner.Tok));
  if (Sym.Kind = skType) and (Sym.Tok <> nil) then
    Exit(Location(At.Doc, At.Prov, At.Bound.Lines, Sym.FileName, Sym.Tok));
  if (Sym.Kind = skEnum) and (Sym.TypeTok <> nil) then
    Exit(Location(At.Doc, At.Prov, At.Bound.Lines, Sym.FileName, Sym.TypeTok));
  if (Sym.TNode = nil) or (Sym.Scope = nil) or not (Sym.Kind in [skVar, skParam, skField, skConst, skRoutine]) then
    Exit(nil);
  Name := TypeNameNode(Sym.TNode);
  if Name = nil then
    Exit(nil);
  Ts := At.Bound.Binder.TypeSym(Name, Sym.Scope);
  if Ts = nil then
    Exit(nil);
  if Ts.Tok = nil then
  begin
    if Ts.Lib then
      Exit(StubLocation(At.Prov, Ts));
    Exit(nil);
  end;
  Result := Location(At.Doc, At.Prov, At.Bound.Lines, Ts.FileName, Ts.Tok);
end;

{ implementation, type hierarchy }

type
  TObjType = class
  public
    Bound: TBound;
    Sym, Anc: TSym;
  end;

function THandlerServer.ObjectTypes(Doc: TDoc; Bound: TBound): TObjectList;
var
  Prov: TProvider;
  Seen: TStrMap;
  Cands: TKeyTexts;
  C: TKeyText;
  B: TBound;

  procedure Collect(X: TBound);
  var
    I: Integer;
    S: TSym;
    K, F: string;
    O: TObjType;
  begin
    for I := 0 to X.Binder.Decls.Count - 1 do
    begin
      S := TSym(X.Binder.Decls.At(I));
      if (S.Kind <> skType) or (S.Tok = nil) or (ObjectNode(S) = nil) then
        Continue;
      F := S.FileName;
      if F = '' then
        F := X.Key;
      if PathKey(F) <> X.Key then
        Continue;
      K := SymKey(S, X.Key);
      if Seen.Has(K) then
        Continue;
      Seen.Put(K, S);
      O := TObjType.Create;
      O.Bound := X;
      O.Sym := S;
      O.Anc := AncestorSym(X.Binder, S);
      Result.Add(O);
    end;
  end;

begin
  Prov := ProviderFor(Doc, True);
  Result := TObjectList.Create(True);
  Seen := TStrMap.Create;
  try
    Collect(Bound);
    Cands := Candidates(Doc);
    for C in Cands do
      if Pos('object', LowerText(C.Text)) > 0 then
      begin
        B := NewBound(C.Key, C.Uri, C.Text, Prov);
        Collect(B);
      end;
  finally
    Seen.Free;
  end;
end;

function Descendants(Types: TObjectList; const RootKey: string): TFPList;
var
  Todo: TStringArray;
  Seen: TStrMap;
  K, Top: string;
  I: Integer;
  O: TObjType;
begin
  Result := TFPList.Create;
  Todo := [RootKey];
  Seen := TStrMap.Create;
  try
    Seen.Put(RootKey, Seen);
    while Todo <> nil do
    begin
      Top := Todo[High(Todo)];
      SetLength(Todo, Length(Todo) - 1);
      for I := 0 to Types.Count - 1 do
      begin
        O := TObjType(Types[I]);
        if (O.Anc = nil) or (SymKey(O.Anc, O.Bound.Key) <> Top) then
          Continue;
        K := SymKey(O.Sym, O.Bound.Key);
        if Seen.Has(K) then
          Continue;
        Seen.Put(K, O);
        Result.Add(O);
        PushStr(Todo, K);
      end;
    end;
  finally
    Seen.Free;
  end;
end;

function THandlerServer.OnImplementation(P: TJSONObject): TJSONData;
var
  At: TSymAt;
  Sym, M: TSym;
  Types: TObjectList;
  Subs: TFPList;
  I: Integer;
  O: TObjType;
  Arr: TJSONArray;
  Own: TToken;
  Loc: TJSONData;
  Ti: TTInfo;
  Name: string;
begin
  At := SymbolAt(P);
  Sym := At.Sym;
  if Sym = nil then
    Exit(nil);
  if Sym.Implicit and (Sym.Owner <> nil) then
    Sym := Sym.Owner;
  if (Sym.Kind = skType) and (ObjectNode(Sym) <> nil) then
  begin
    Types := ObjectTypes(At.Doc, At.Bound);
    Subs := Descendants(Types, SymKey(Sym, At.Bound.Key));
    Arr := TJSONArray.Create;
    for I := 0 to Subs.Count - 1 do
    begin
      O := TObjType(Subs[I]);
      Arr.Add(TJSONObject.Create(['uri', O.Bound.Uri, 'range', RangeJSON(TokenRange(O.Sym.Tok, O.Bound.Lines))]));
    end;
    Subs.Free;
    Types.Free;
    Exit(Arr);
  end;
  if (Sym.Kind = skRoutine) and (Sym.Owner <> nil) then
  begin
    Arr := TJSONArray.Create;
    Own := Sym.ImplTok;
    if Own = nil then
      Own := Sym.Tok;
    if Own <> nil then
    begin
      Loc := Location(At.Doc, At.Prov, At.Bound.Lines, Sym.FileName, Own);
      if Loc <> nil then
        Arr.Add(Loc);
    end;
    if IsVirtual(Sym) then
    begin
      Name := LowerText(Sym.Name);
      Types := ObjectTypes(At.Doc, At.Bound);
      Subs := Descendants(Types, SymKey(Sym.Owner, At.Bound.Key));
      for I := 0 to Subs.Count - 1 do
      begin
        O := TObjType(Subs[I]);
        Ti := O.Bound.Binder.TypeTi(O.Sym);
        M := nil;
        if Ti <> nil then
          M := TSym(Ti.GetOwn.Get(Name));
        if (M <> nil) and (M.Kind = skRoutine) then
        begin
          Own := M.ImplTok;
          if Own = nil then
            Own := M.Tok;
          if Own <> nil then
            Arr.Add(TJSONObject.Create(['uri', O.Bound.Uri, 'range', RangeJSON(TokenRange(Own, O.Bound.Lines))]));
        end;
      end;
      Subs.Free;
      Types.Free;
    end;
    Exit(Arr);
  end;
  Result := Locate(P, True);
end;

function THandlerServer.HierarchyType(Bound: TBound; Sym: TSym): TSym;
var
  Name: TNode;
begin
  if Sym = nil then
    Exit(nil);
  if Sym.Implicit then
    Sym := Sym.Owner
  else if (Sym.Kind = skRoutine) and (Sym.Owner <> nil) then
    Sym := Sym.Owner
  else if (Sym.Kind in [skVar, skParam, skField, skConst]) and (Sym.TNode <> nil) and (Sym.Scope <> nil) then
  begin
    Name := TypeNameNode(Sym.TNode);
    if Name <> nil then
      Sym := Bound.Binder.TypeSym(Name, Sym.Scope)
    else
      Sym := nil;
  end;
  if (ObjectNode(Sym) <> nil) and (Sym.Tok <> nil) then
    Result := Sym
  else
    Result := nil;
end;

function THandlerServer.HierItem(const Uri: string; const Lines: TStringArray; Sym: TSym): TJSONObject;
var
  R: TLspRange;
  Her: TNode;
  Detail: string;
begin
  R := TokenRange(Sym.Tok, Lines);
  Her := HeritageOf(ObjectNode(Sym));
  Detail := 'object';
  if Her <> nil then
    Detail := Detail + Compact(Her.Tokens);
  Result := TJSONObject.Create(['name', Sym.Name, 'kind', OkClass, 'detail', Detail, 'uri', Uri, 'range', RangeJSON(R),
    'selectionRange', RangeJSON(R)]);
end;

function ReadLinesOf(Prov: TProvider; const Path: string; out Lines: TStringArray): Boolean;
begin
  try
    Lines := SplitNL(Prov.ReadText(Path));
    Result := True;
  except
    on EStreamError do
      Result := False;
    on EInOutError do
      Result := False;
  end;
end;

function THandlerServer.OnPrepareTypeHierarchy(P: TJSONObject): TJSONData;
var
  At: TSymAt;
  Ts: TSym;
  Loc: TJSONData;
  Lines: TStringArray;
  Uri: string;
begin
  At := SymbolAt(P);
  Ts := HierarchyType(At.Bound, At.Sym);
  if Ts = nil then
    Exit(nil);
  if (Ts.FileName <> '') and (PathKey(Ts.FileName) <> At.Bound.Key) then
  begin
    Loc := Location(At.Doc, At.Prov, At.Bound.Lines, Ts.FileName, Ts.Tok);
    if Loc = nil then
      Exit(nil);
    Uri := TJSONObject(Loc).Strings['uri'];
    Loc.Free;
    if not ReadLinesOf(At.Prov, Ts.FileName, Lines) then
      Exit(nil);
    Exit(TJSONArray.Create([HierItem(Uri, Lines, Ts)]));
  end;
  Result := TJSONArray.Create([HierItem(At.Doc.Uri, At.Bound.Lines, Ts)]);
end;

function THandlerServer.ItemType(Item: TJSONObject; out Doc: TDoc; out Prov: TProvider; out Bound: TBound): TSym;
var
  Uri, Path, Text: string;
  Pos_: TJSONObject;
  Tok: TToken;
begin
  Uri := JStr(Item, 'uri');
  Doc := TDoc(Docs.Get(Uri));
  if Doc = nil then
  begin
    if not UriToPath(Uri, Path) or (JStr(Item, 'uri', #0) = #0) then
      raise ERequestError.Create(InvalidParams, 'cannot read ' + Uri);
    try
      Text := ReadSource(Path);
    except
      on EStreamError do
        raise ERequestError.Create(InvalidParams, 'cannot read ' + Uri);
      on EInOutError do
        raise ERequestError.Create(InvalidParams, 'cannot read ' + Uri);
    end;
    Doc := TDoc.Create(Uri, nil, Text);
    FGraveMisc.Add(Doc);
  end;
  Prov := ProviderFor(Doc, True);
  Bound := BindDoc(Doc, Prov);
  Pos_ := JObj(JObj(Item, 'selectionRange'), 'start');
  Tok := IdentAt(Bound.Res.DocSig, Bound.Lines, JInt(Pos_, 'line'), JInt(Pos_, 'character'));
  Result := nil;
  if Tok <> nil then
    Result := TSym(Bound.Binder.Decls.Get(Tok));
  if ObjectNode(Result) = nil then
    Result := nil;
end;

function THandlerServer.OnSupertypes(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Prov: TProvider;
  Bound: TBound;
  Sym, Anc: TSym;
  Loc: TJSONData;
  Lines: TStringArray;
  Uri: string;
begin
  Sym := ItemType(JObj(P, 'item'), Doc, Prov, Bound);
  if Sym = nil then
    Exit(TJSONArray.Create);
  Anc := AncestorSym(Bound.Binder, Sym);
  if (Anc = nil) or (Anc.Tok = nil) or (ObjectNode(Anc) = nil) then
    Exit(TJSONArray.Create);
  Loc := Location(Doc, Prov, Bound.Lines, Anc.FileName, Anc.Tok);
  if Loc = nil then
    Exit(TJSONArray.Create);
  Uri := TJSONObject(Loc).Strings['uri'];
  Loc.Free;
  if (Anc.FileName = '') or (PathKey(Anc.FileName) = Bound.Key) then
    Lines := Bound.Lines
  else if not ReadLinesOf(Prov, Anc.FileName, Lines) then
    Exit(TJSONArray.Create);
  Result := TJSONArray.Create([HierItem(Uri, Lines, Anc)]);
end;

function THandlerServer.OnSubtypes(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Prov: TProvider;
  Bound: TBound;
  Sym: TSym;
  Me: string;
  Types: TObjectList;
  I: Integer;
  O: TObjType;
  Arr: TJSONArray;
begin
  Sym := ItemType(JObj(P, 'item'), Doc, Prov, Bound);
  if Sym = nil then
    Exit(TJSONArray.Create);
  Me := SymKey(Sym, Bound.Key);
  Arr := TJSONArray.Create;
  Types := ObjectTypes(Doc, Bound);
  try
    for I := 0 to Types.Count - 1 do
    begin
      O := TObjType(Types[I]);
      if (O.Anc <> nil) and (SymKey(O.Anc, O.Bound.Key) = Me) then
        Arr.Add(HierItem(O.Bound.Uri, O.Bound.Lines, O.Sym));
    end;
  finally
    Types.Free;
  end;
  Result := Arr;
end;

{ references, highlight, rename }

function THandlerServer.Candidates(Doc: TDoc): TKeyTexts;
var
  Seen: TStrMap;
  I: Integer;
  D: TDoc;
  K, Path, R: string;
  Paths: TStringArray;
  Inside: Boolean;
  Extra: TProjectIndex;
  St: TStamp;

  procedure Add(const AKey, AUri, AText: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Key := AKey;
    Result[High(Result)].Uri := AUri;
    Result[High(Result)].Text := AText;
  end;

begin
  Result := nil;
  Seen := TStrMap.Create;
  try
    Seen.Put(DocKey(Doc), Seen);
    for I := 0 to Docs.Count - 1 do
    begin
      D := TDoc(Docs.At(I));
      K := DocKey(D);
      if not Seen.Has(K) and not IsStub(D.Path) then
      begin
        Seen.Put(K, D);
        Add(K, D.Uri, D.Text);
      end;
    end;
    Paths := nil;
    if Index <> nil then
      Paths := Index.Sources;
    if Doc.Path <> '' then
    begin
      Inside := False;
      for R in Roots do
        if Copy(PathKey(Doc.Path), 1, Length(PathKey(R))) = PathKey(R) then
          Inside := True;
      if not Inside then
      begin
        Extra := TProjectIndex.Create([DirName(Doc.Path)]);
        try
          Paths := Concat(Paths, Extra.Sources);
        finally
          Extra.Free;
        end;
      end;
    end;
    for Path in Paths do
    begin
      K := PathKey(Path);
      if Seen.Has(K) or IsStub(Path) then
        Continue;
      Seen.Put(K, Seen);
      St := Stamp(Path);
      if not St.Exists then
        Continue;
      if St.Size > MaxScanBytes then
        Continue;
      try
        Add(K, PathToUri(Path), ReadSource(Path));
      except
        on EStreamError do;
        on EInOutError do;
      end;
    end;
  finally
    Seen.Free;
  end;
end;

type
  THit = record
    Tok: TToken;
    Decl: Boolean;
  end;

  THits = array of THit;

  TOccur = class
  public
    Key: string;
    Bound: TBound;
    Hits: THits;
  end;

function HitsOf(B: TBound; Keys: TStringList): THits;
var
  K: TKeyed;
begin
  Result := nil;
  for K in Keyed(B) do
    if (K.Key <> '') and (Keys.IndexOf(K.Key) >= 0) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Tok := K.Tok;
      Result[High(Result)].Decl := K.Decl;
    end;
end;

function NewKeySet: TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Result.CaseSensitive := True;
end;

function THandlerServer.Occurrences(Doc: TDoc; Bound: TBound; Sym: TSym; const Key: string;
  Family: Boolean): TObjectList;
var
  Prov: TProvider;
  Root: TSym;
  Virtual_: Boolean;
  Chain: TSyms;
  Scan: TKeyTexts;
  C: TKeyText;
  Name, RootKey: string;
  Keys: TStringList;
  O: TOccur;
  Other: TBound;
  H: THits;

  procedure CollectFamily(B: TBound);
  var
    I: Integer;
    M, X: TSym;
    Ch: TSyms;
  begin
    for I := 0 to B.Binder.Decls.Count - 1 do
    begin
      M := TSym(B.Binder.Decls.At(I));
      if (M.Kind = skRoutine) and (M.Owner <> nil) and (LowerText(M.Name) = Name) and IsVirtual(M) then
      begin
        Ch := VirtualChain(B.Binder, M);
        if SymKey(Ch[High(Ch)], B.Key) = RootKey then
          for X in Ch do
            Keys.Add(SymKey(X, B.Key));
      end;
    end;
  end;

begin
  Prov := ProviderFor(Doc, True);
  Root := Sym;
  Virtual_ := Family and (Sym.Kind = skRoutine) and (Sym.Owner <> nil) and IsVirtual(Sym);
  if Virtual_ then
  begin
    Chain := VirtualChain(Bound.Binder, Sym);
    Root := Chain[High(Chain)];
  end;
  Scan := nil;
  if VisibleOutside(Sym, Bound) or VisibleOutside(Root, Bound) then
    Scan := Candidates(Doc);
  Name := LowerText(Sym.Name);
  Keys := NewKeySet;
  Result := TObjectList.Create(True);
  try
    if Virtual_ then
    begin
      RootKey := SymKey(Root, Bound.Key);
      Keys.Add(RootKey);
      Keys.Add(SymKey(Sym, Bound.Key));
      CollectFamily(Bound);
      for C in Scan do
        if Pos(Name, LowerText(C.Text)) > 0 then
          CollectFamily(NewBound(C.Key, C.Uri, C.Text, Prov));
    end
    else
      Keys.Add(Key);
    O := TOccur.Create;
    O.Key := Bound.Key;
    O.Bound := Bound;
    O.Hits := HitsOf(Bound, Keys);
    Result.Add(O);
    for C in Scan do
    begin
      if Pos(Name, LowerText(C.Text)) = 0 then
        Continue;
      Other := NewBound(C.Key, C.Uri, C.Text, Prov);
      H := HitsOf(Other, Keys);
      if H <> nil then
      begin
        O := TOccur.Create;
        O.Key := C.Key;
        O.Bound := Other;
        O.Hits := H;
        Result.Add(O);
      end;
    end;
  finally
    Keys.Free;
  end;
end;

function THandlerServer.OnDocumentHighlight(P: TJSONObject): TJSONData;
var
  At: TSymAt;
  Writes: TPtrMap;
  K: TKeyed;
  Arr: TJSONArray;
  Kind: Integer;
begin
  At := SymbolAt(P);
  if At.Key = '' then
    Exit(nil);
  Writes := WriteTargets(At.Bound.Res);
  Arr := TJSONArray.Create;
  try
    for K in Keyed(At.Bound) do
      if K.Key = At.Key then
      begin
        if Writes.Has(K.Tok) then
          Kind := 3
        else if K.Decl then
          Kind := 1
        else
          Kind := 2;
        Arr.Add(TJSONObject.Create(['range', RangeJSON(TokenRange(K.Tok, At.Bound.Lines)), 'kind', Kind]));
      end;
  finally
    Writes.Free;
  end;
  Result := Arr;
end;

function THandlerServer.OnReferences(P: TJSONObject): TJSONData;
var
  At: TSymAt;
  Include, AnyInc, Decl: Boolean;
  Ctx: TJSONObject;
  Occ: TObjectList;
  Order: array of TOccur;
  O, X: TOccur;
  I, J: Integer;
  H: THit;
  Arr: TJSONArray;
  Inc_: TInclude;
  T: TToken;
  Loc: TJSONData;
begin
  At := SymbolAt(P);
  if At.Key = '' then
    Exit(nil);
  Ctx := JObj(P, 'context');
  Include := True;
  if (Ctx <> nil) and (Ctx.Find('includeDeclaration') <> nil) then
    Include := Truthy(Ctx.Find('includeDeclaration'));
  Arr := TJSONArray.Create;
  Occ := Occurrences(At.Doc, At.Bound, At.Sym, At.Key, False);
  try
    SetLength(Order, Occ.Count);
    for I := 0 to Occ.Count - 1 do
      Order[I] := TOccur(Occ[I]);
    for I := 1 to High(Order) do
    begin
      X := Order[I];
      J := I - 1;
      while (J >= 0) and (Order[J].Bound.Uri > X.Bound.Uri) do
      begin
        Order[J + 1] := Order[J];
        Dec(J);
      end;
      Order[J + 1] := X;
    end;
    for O in Order do
      for H in O.Hits do
        if Include or not H.Decl then
          Arr.Add(TJSONObject.Create(['uri', O.Bound.Uri, 'range', RangeJSON(TokenRange(H.Tok, O.Bound.Lines))]));
  finally
    Occ.Free;
  end;
  AnyInc := False;
  for Inc_ in At.Bound.Res.Includes do
    if Inc_.Resolved then
      AnyInc := True;
  if AnyInc then
    for T in At.Bound.Res.Sig do
    begin
      if (T.Via = nil) or (T.Kind <> tkIdent) then
        Continue;
      Decl := At.Bound.Binder.Decls.Get(T) = At.Sym;
      if ((At.Bound.Binder.Refs.Get(T) = At.Sym) or Decl) and (Include or not Decl) then
      begin
        Loc := Location(At.Doc, At.Prov, At.Bound.Lines, T.FileName, T);
        if Loc <> nil then
          Arr.Add(Loc);
      end;
    end;
  Result := Arr;
end;

procedure Renameable(Tok: TToken; Sym: TSym);
var
  C: Char;
  Digits: Boolean;
begin
  if Sym = nil then
    raise ERequestError.Create(RequestFailed, 'cannot rename ' + Tok.Text + ': it is not a declared name');
  if Sym.Kind = skLabel then
  begin
    Digits := Sym.Name <> '';
    for C in Sym.Name do
      if not (C in ['0'..'9']) then
        Digits := False;
    if Digits then
      raise ERequestError.Create(RequestFailed, 'cannot rename the numeric label ' + Sym.Name);
  end;
  if Sym.Kind = skUnit then
    raise ERequestError.Create(RequestFailed, 'cannot rename the unit ' + Sym.Name +
      ': that would mean renaming its file');
  if Sym.Implicit then
    raise ERequestError.Create(RequestFailed, 'cannot rename Self: it is the object a method works on');
  if Sym.Tok = nil then
    raise ERequestError.Create(RequestFailed, 'cannot rename ' + Sym.Name +
      ': it comes from a TPU / the standard library');
end;

function LineNote(Tok: TToken): string;
begin
  if Tok = nil then
    Exit('');
  if Tok.FileName <> '' then
    Result := Format(' (%s, line %d)', [BaseName(Tok.FileName), Tok.Line])
  else
    Result := Format(' (line %d)', [Tok.Line]);
end;

function HasIdentWord(const Text, Word: string): Boolean;
var
  LT, LW: string;
  I: SizeInt;
begin
  LT := LowerCase(Text);
  LW := LowerCase(Word);
  if LW = '' then
    Exit(False);
  I := Pos(LW, LT);
  while I > 0 do
  begin
    if ((I = 1) or not (LT[I - 1] in ['a'..'z', '0'..'9', '_'])) and
      ((I + Length(LW) > Length(LT)) or not (LT[I + Length(LW)] in ['a'..'z', '0'..'9', '_'])) then
      Exit(True);
    I := Pos(LW, LT, I + 1);
  end;
  Result := False;
end;

procedure CheckIncludesForRename(Bound: TBound; Prov: TProvider; Sym: TSym; const New: string);
var
  Inc_: TInclude;
  Text, Word: string;
  Words: array[0..1] of string;
begin
  if (Sym.Tok <> nil) and (Sym.Tok.Via <> nil) then
    raise ERequestError.Create(RequestFailed, Format('%s is declared in the include file %s: rename it there',
      [Sym.Name, BaseName(Sym.FileName)]));
  Words[0] := Sym.Name;
  Words[1] := New;
  for Inc_ in Bound.Res.Includes do
  begin
    if not Inc_.Resolved then
      Continue;
    try
      Text := Prov.ReadText(Inc_.Path);
    except
      on EStreamError do
        Continue;
      on EInOutError do
        Continue;
    end;
    for Word in Words do
      if HasIdentWord(Text, Word) then
        raise ERequestError.Create(RequestFailed, Format('cannot rename: %s also appears in the include file %s, ' +
          'and edits inside include files are not made', [Word, BaseName(Inc_.Path)]));
  end;
end;

function THandlerServer.OnPrepareRename(P: TJSONObject): TJSONData;
var
  At: TSymAt;
begin
  At := SymbolAt(P);
  if At.Tok = nil then
    Exit(nil);
  Renameable(At.Tok, At.Sym);
  Result := TJSONObject.Create(['range', RangeJSON(TokenRange(At.Tok, At.Bound.Lines)), 'placeholder', At.Sym.Name]);
end;

function IsIdent(const S: string): Boolean;
var
  I, N: Integer;
begin
  N := Length(S);
  if (N > 0) and (S[N] = #10) then
    Dec(N);
  if (N = 0) or not (S[1] in ['A'..'Z', 'a'..'z', '_']) then
    Exit(False);
  for I := 2 to N do
    if not (S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit(False);
  Result := True;
end;

type
  TWatch = class
  public
    Key: string;
    Bound: TBound;
  end;

  TIdentKeys = record
    Present: array of Boolean;
    Keys: TStringArray;
  end;

function IdentKeys(B: TBound): TIdentKeys;
var
  All: TStringArray;
  Has: array of Boolean;
  K: TKeyed;
  T: TToken;
  N: Integer;
begin
  Result.Present := nil;
  Result.Keys := nil;
  N := Length(B.Res.Tokens);
  SetLength(All, N);
  SetLength(Has, N);
  SetLength(Result.Present, N);
  SetLength(Result.Keys, N);
  for K in Keyed(B) do
  begin
    All[K.Tok.Idx] := K.Key;
    Has[K.Tok.Idx] := True;
  end;
  for T in B.Res.DocSig do
    if T.Kind = tkIdent then
    begin
      Result.Present[T.Idx] := True;
      if Has[T.Idx] then
        Result.Keys[T.Idx] := All[T.Idx];
    end;
end;

function THandlerServer.OnRename(P: TJSONObject): TJSONData;
var
  At: TSymAt;
  New, Shown: string;
  Prov, Prov2: TProvider;
  Ti: TTInfo;
  Clash: TSym;
  Occ, Watch: TObjectList;
  O: TOccur;
  W: TWatch;
  C: TKeyText;
  Seen, Texts, AbsTexts: TStrMap;
  I, Idx, Skipped: Integer;
  Toks: TTokens;
  After: TBound;
  KB, KA: TIdentKeys;
  VB, VA: string;
  T: TToken;
  H: THit;
  Changes: TJSONObject;
  Holder: TTextHolder;
begin
  At := SymbolAt(P);
  New := JStr(P, 'newName');
  Prov := ProviderFor(At.Doc, True);
  if At.Tok = nil then
    raise ERequestError.Create(RequestFailed, 'there is no identifier at this position');
  Renameable(At.Tok, At.Sym);
  if not IsIdent(New) or IsReserved(LowerText(New)) then
    raise ERequestError.Create(RequestFailed, PyRepr(New) + ' is not a valid identifier (or it is a reserved word)');
  if (At.Sym.Owner <> nil) and (At.Sym.Kind in [skField, skRoutine]) then
  begin
    Ti := At.Bound.Binder.TypeTi(At.Sym.Owner);
    Clash := nil;
    if Ti <> nil then
      Clash := TSym(Ti.GetFields.Get(LowerText(New)));
    if (Clash <> nil) and (Clash <> At.Sym) and ((Clash.Tok = nil) or (Clash.Tok <> At.Sym.Tok)) then
      raise ERequestError.Create(RequestFailed, Format('%s is already a member of %s%s', [New, At.Sym.Owner.Name,
        LineNote(Clash.Tok)]));
  end
  else if (At.Sym.Kind in [skVar, skConst, skType, skRoutine, skEnum]) and (At.Sym.Scope <> nil) then
  begin
    Clash := TSym(At.Sym.Scope.Table.Get(LowerText(New)));
    if (Clash <> nil) and (Clash <> At.Sym) and ((Clash.Tok = nil) or (Clash.Tok <> At.Sym.Tok)) then
      raise ERequestError.Create(RequestFailed, Format('%s is already declared in this scope%s', [New,
        LineNote(Clash.Tok)]));
  end;
  CheckIncludesForRename(At.Bound, Prov, At.Sym, New);
  Occ := Occurrences(At.Doc, At.Bound, At.Sym, At.Key, True);
  Watch := TObjectList.Create(True);
  Texts := TStrMap.Create;
  Seen := TStrMap.Create;
  AbsTexts := TStrMap.Create;
  try
    for I := 0 to Occ.Count - 1 do
    begin
      O := TOccur(Occ[I]);
      Toks := nil;
      for H in O.Hits do
      begin
        SetLength(Toks, Length(Toks) + 1);
        Toks[High(Toks)] := H.Tok;
      end;
      W := TWatch.Create;
      W.Key := O.Key;
      W.Bound := O.Bound;
      Watch.Add(W);
      Seen.Put(O.Key, W);
      Holder := TTextHolder.Create;
      Holder.Text := ApplyTokenEdits(O.Bound.Text, Toks, New);
      FGraveMisc.Add(Holder);
      Texts.Put(O.Key, Holder);
    end;
    for C in Candidates(At.Doc) do
      if not Seen.Has(C.Key) and (Pos(LowerText(New), LowerText(C.Text)) > 0) then
      begin
        W := TWatch.Create;
        W.Key := C.Key;
        W.Bound := NewBound(C.Key, C.Uri, C.Text, Prov, True);
        Watch.Add(W);
        Seen.Put(C.Key, W);
        Holder := TTextHolder.Create;
        Holder.Text := C.Text;
        FGraveMisc.Add(Holder);
        Texts.Put(C.Key, Holder);
      end;
    for I := 0 to Texts.Count - 1 do
      if IsAbsPath(Texts.KeyAt(I)) then
        AbsTexts.Put(Texts.KeyAt(I), Texts.At(I));
    Prov2 := ProviderFor(At.Doc, True, AbsTexts);
    for I := 0 to Watch.Count - 1 do
    begin
      W := TWatch(Watch[I]);
      After := NewBound(W.Key, W.Bound.Uri, TTextHolder(Texts.Get(W.Key)).Text, Prov2, True);
      KB := IdentKeys(W.Bound);
      KA := IdentKeys(After);
      Idx := 0;
      while (Idx < Length(KB.Present)) or (Idx < Length(KA.Present)) do
      begin
        if ((Idx < Length(KB.Present)) and KB.Present[Idx]) or ((Idx < Length(KA.Present)) and KA.Present[Idx]) then
        begin
          VB := '';
          VA := '';
          if (Idx < Length(KB.Present)) and KB.Present[Idx] then
            VB := KB.Keys[Idx];
          if (Idx < Length(KA.Present)) and KA.Present[Idx] then
            VA := KA.Keys[Idx];
          if VB <> VA then
          begin
            if Idx > High(After.Res.Tokens) then
              raise Exception.Create('IndexError: list index out of range');
            T := After.Res.Tokens[Idx];
            if IsAbsPath(W.Key) then
              Shown := BaseName(W.Key)
            else
              Shown := W.Key;
            raise ERequestError.Create(RequestFailed, Format('renaming to %s would change the meaning of %s at %s:%d',
              [New, T.Text, Shown, T.Line]));
          end;
        end;
        Inc(Idx);
      end;
    end;
    Skipped := 0;
    for I := 0 to Occ.Count - 1 do
      for T in TOccur(Occ[I]).Bound.Res.Tokens do
        if not T.Active and (T.Kind = tkIdent) and (LowerText(T.Text) = LowerText(At.Sym.Name)) then
          Inc(Skipped);
    if Skipped > 0 then
      Notify('window/showMessage', TJSONObject.Create(['type', 2, 'message', Format('tp7ls: %d occurrence(s) of %s ' +
        'in inactive {$IFDEF} branches were not renamed', [Skipped, At.Sym.Name])]));
    Changes := TJSONObject.Create;
    for I := 0 to Occ.Count - 1 do
    begin
      O := TOccur(Occ[I]);
      if Changes.IndexOfName(O.Bound.Uri) < 0 then
        Changes.Add(O.Bound.Uri, TJSONArray.Create);
      for H in O.Hits do
        Changes.Arrays[O.Bound.Uri].Add(TJSONObject.Create(['range', RangeJSON(TokenRange(H.Tok, O.Bound.Lines)),
          'newText', New]));
    end;
    Result := TJSONObject.Create(['changes', Changes]);
  finally
    AbsTexts.Free;
    Seen.Free;
    Texts.Free;
    Watch.Free;
    Occ.Free;
  end;
end;

{ outline, selection, partial formatting, workspace symbols }

function THandlerServer.OnDocumentSymbol(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Symbols: TJSONArray;
begin
  Doc := DocOf(P);
  Symbols := DocumentSymbols(Doc.Text);
  if Hierarchical then
    Exit(Symbols);
  Result := FlattenSymbols(Symbols, Doc.Uri);
  Symbols.Free;
end;

function THandlerServer.OnSelectionRange(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Res: TParseResult;
  Lines: TStringArray;
  Ps: TJSONData;
  Arr: TJSONArray;
  I: Integer;
begin
  Doc := DocOf(P);
  Res := Parse(Doc.Text);
  Arr := TJSONArray.Create;
  try
    Lines := SplitNL(Doc.Text);
    Ps := P.Find('positions');
    if Ps is TJSONArray then
      for I := 0 to Ps.Count - 1 do
        Arr.Add(SelectionRange(Res, Lines, JInt(Ps.Items[I], 'line'), JInt(Ps.Items[I], 'character')));
  finally
    Res.Free;
  end;
  Result := Arr;
end;

function THandlerServer.OnRangeFormatting(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  New: string;
  R, E: TJSONObject;
  First, Last: Integer;
begin
  Doc := DocOf(P);
  if IsStub(Doc.Path) then
    Exit(TJSONArray.Create);
  try
    New := FormatText(Doc);
  except
    on Ex: EFormatError do
      raise ERequestError.Create(RequestFailed, Ex.Message);
  end;
  R := JObj(P, 'range');
  First := JInt(JObj(R, 'start'), 'line', 0);
  E := JObj(R, 'end');
  Last := JInt(E, 'line', First);
  if (JInt(E, 'character', 1) = 0) and (Last > First) then
    Dec(Last);
  Result := RangeEdits(Doc.Text, New, First, Last);
end;

function THandlerServer.OnWorkspaceSymbol(P: TJSONObject): TJSONData;
type
  TFound = record
    Rank: Integer;
    Base: string;
    Sym: TJSONObject;
  end;
var
  Query, Key, Uri, StampKey, Name, Base: string;
  Entry: TSymbolsEntry;
  Found: array of TFound;
  X: TFound;
  I, J, Rank: Integer;
  D: TDoc;
  Seen: TStrMap;
  Path: string;
  St: TStamp;
  Syms, Tmp: TJSONArray;
  Ok: Boolean;
  Text: string;

  procedure Consider(const AKey, AUri, AStamp: string; IsOpen: Boolean; const APath: string; ADoc: TDoc);
  var
    L, K: Integer;
  begin
    Entry := TSymbolsEntry(SymbolCache.Get(AKey));
    if (Entry = nil) or (Entry.Stamp <> AStamp) then
    begin
      Ok := True;
      try
        if IsOpen then
          Text := ADoc.Text
        else
          Text := ReadSource(APath);
      except
        on EStreamError do
          Ok := False;
        on EInOutError do
          Ok := False;
      end;
      if Ok then
      begin
        Tmp := DocumentSymbols(Text);
        Syms := FlattenSymbols(Tmp, AUri);
        Tmp.Free;
      end
      else
        Syms := TJSONArray.Create;
      if Entry = nil then
      begin
        Entry := TSymbolsEntry.Create;
        SymbolCache.Put(AKey, Entry);
      end
      else
        Entry.Symbols.Free;
      Entry.Stamp := AStamp;
      Entry.Symbols := Syms;
    end;
    for L := 0 to Entry.Symbols.Count - 1 do
    begin
      Name := LowerText(TJSONObject(Entry.Symbols[L]).Strings['name']);
      Base := Name;
      for K := 1 to Length(Name) do
        if (Name[K] in ['(', ':']) or (SpaceLen(Name, K) > 0) then
        begin
          Base := Copy(Name, 1, K - 1);
          Break;
        end;
      if Base = Query then
        Rank := 0
      else if Copy(Base, 1, Length(Query)) = Query then
        Rank := 1
      else if Pos(Query, Name) > 0 then
        Rank := 2
      else if IsSubsequence(Query, Base) then
        Rank := 3
      else
        Continue;
      SetLength(Found, Length(Found) + 1);
      Found[High(Found)].Rank := Rank;
      Found[High(Found)].Base := Base;
      Found[High(Found)].Sym := TJSONObject(Entry.Symbols[L]);
    end;
  end;

begin
  Query := LowerText(JStr(P, 'query'));
  Found := nil;
  Seen := TStrMap.Create;
  try
    for I := 0 to Docs.Count - 1 do
    begin
      D := TDoc(Docs.At(I));
      if IsStub(D.Path) then
        Continue;
      Key := DocKey(D);
      Seen.Put(Key, D);
      Consider(Key, D.Uri, 'open' + TextHash(D.Text), True, '', D);
    end;
    if Index <> nil then
      for Path in Index.Sources do
      begin
        Key := PathKey(Path);
        if Seen.Has(Key) or IsStub(Path) then
          Continue;
        Seen.Put(Key, Seen);
        St := Stamp(Path);
        if not St.Exists or (St.Size > MaxScanBytes) then
          Continue;
        StampKey := IntToStr(St.Size) + ':' + IntToStr(St.MTimeNs);
        Uri := PathToUri(Path);
        Consider(Key, Uri, StampKey, False, Path, nil);
      end;
  finally
    Seen.Free;
  end;
  for I := 1 to High(Found) do
  begin
    X := Found[I];
    J := I - 1;
    while (J >= 0) and ((Found[J].Rank > X.Rank) or ((Found[J].Rank = X.Rank) and (Found[J].Base > X.Base))) do
    begin
      Found[J + 1] := Found[J];
      Dec(J);
    end;
    Found[J + 1] := X;
  end;
  Result := TJSONArray.Create;
  for I := 0 to High(Found) do
    if I < 200 then
      TJSONArray(Result).Add(Found[I].Sym.Clone);
end;

{ code actions }

function UsesEdit(Res: TParseResult; const Lines: TStringArray; Drop: TPtrMap): TJSONArray;
var
  N: TNode;
  K: TObject;
  Names, Keep: TTokens;
  Gone: Boolean;
  T: TToken;
begin
  Result := TJSONArray.Create;
  for N in Res.Tree.Walk do
  begin
    if N.Kind <> nkUsesClause then
      Continue;
    Names := nil;
    for K in N.Kids do
      if IsKind(K, nkName) and (TNode(K).Kids <> nil) then
      begin
        SetLength(Names, Length(Names) + 1);
        Names[High(Names)] := KT(TNode(K).Kids[0]);
      end;
    Gone := False;
    Keep := nil;
    for T in Names do
      if Drop.Has(T) then
        Gone := True
      else
      begin
        SetLength(Keep, Length(Keep) + 1);
        Keep[High(Keep)] := T;
      end;
    if not Gone then
      Continue;
    if Keep <> nil then
      Result.Add(NamesEdit(Lines, Names, Keep))
    else
      Result.Add(TJSONObject.Create(['range', RangeJSON(WholeLines(Lines, TokenRange(FirstToken(N), Lines).S,
        TokenRange(LastToken(N), Lines).E)), 'newText', '']));
  end;
end;

function DeclEdit(Res: TParseResult; const Lines: TStringArray; Tok: TToken): TJSONObject;
var
  Sec, D, Target: TNode;
  K: TObject;
  Decls: TNodes;
  Names, Keep: TTokens;
  Found: Boolean;
  T: TToken;
begin
  for Sec in Res.Tree.Walk do
  begin
    if not (Sec.Kind in [nkVarSection, nkConstSection, nkTypeSection]) then
      Continue;
    Decls := nil;
    for K in Sec.Kids do
      if K is TNode then
      begin
        SetLength(Decls, Length(Decls) + 1);
        Decls[High(Decls)] := TNode(K);
      end;
    for D in Decls do
    begin
      Names := nil;
      for K in D.Kids do
        if IsKind(K, nkDeclName) and (TNode(K).Kids <> nil) then
        begin
          SetLength(Names, Length(Names) + 1);
          Names[High(Names)] := KT(TNode(K).Kids[0]);
        end;
      Found := False;
      for T in Names do
        if T = Tok then
          Found := True;
      if not Found then
        Continue;
      if (Length(Names) > 1) and (Sec.Kind = nkVarSection) then
      begin
        Keep := nil;
        for T in Names do
          if T <> Tok then
          begin
            SetLength(Keep, Length(Keep) + 1);
            Keep[High(Keep)] := T;
          end;
        Exit(NamesEdit(Lines, Names, Keep));
      end;
      if Length(Decls) = 1 then
        Target := Sec
      else
        Target := D;
      Exit(TJSONObject.Create(['range', RangeJSON(WholeLines(Lines, TokenRange(FirstToken(Target), Lines).S,
        TokenRange(LastToken(Target), Lines).E)), 'newText', '']));
    end;
  end;
  Result := nil;
end;

function ImplementationStub(Res: TParseResult; const Lines: TStringArray; Sym: TSym; const Eol: string): TJSONObject;
var
  Node, Root, Init, Block, Comp: TNode;
  K: TObject;
  Anchor: TToken;
  HasImpl: Boolean;
  Sig, Owner, Head: string;
  At: TLspPos;
begin
  Result := nil;
  Node := Sym.Node;
  if (Node = nil) or (Node.Kids = nil) then
    Exit;
  Root := nil;
  if (Res.Tree.Kids <> nil) and (Res.Tree.Kids[0] is TNode) then
    Root := TNode(Res.Tree.Kids[0]);
  Anchor := nil;
  if (Root <> nil) and (Root.Kind = nkUnit) then
  begin
    HasImpl := False;
    Init := nil;
    for K in Root.Kids do
      if IsKind(K, nkImplementation) then
        HasImpl := True
      else if IsKind(K, nkInitSection) and (Init = nil) then
        Init := TNode(K);
    if not HasImpl then
      Exit;
    if Init <> nil then
      Anchor := FirstToken(Init);
  end
  else if (Root <> nil) and (Root.Kind = nkProgram) then
  begin
    Block := nil;
    for K in Root.Kids do
      if IsKind(K, nkBlock) then
      begin
        Block := TNode(K);
        Break;
      end;
    Comp := nil;
    if Block <> nil then
      for K in Block.Kids do
        if IsKind(K, nkCompound) then
        begin
          Comp := TNode(K);
          Break;
        end;
    if Comp <> nil then
      Anchor := FirstToken(Comp);
  end;
  if Anchor = nil then
    Exit;
  Sig := StringReplace(Compact(SignatureToks(Node), 300), ' :', ':', [rfReplaceAll]);
  if Sym.Owner <> nil then
    Owner := Sym.Owner.Name + '.'
  else
    Owner := '';
  Head := LowerText(KT(Node.Kids[0]).Text) + ' ' + Owner + Sym.Name + SigText(Sig) + ';';
  At := TokenRange(Anchor, Lines).S;
  Result := TJSONObject.Create(['range', RangeJSON(MkRange(At, At)), 'newText', Head + Eol + 'begin' + Eol + 'end;' +
    Eol + Eol]);
end;

function THandlerServer.OnCodeAction(P: TJSONObject): TJSONData;
var
  Doc: TDoc;
  Pre: TParseResult;
  Prov: TProvider;
  Bound: TBound;
  Res: TParseResult;
  B: TBinder;
  Lines: TStringArray;
  Want: TJSONData;
  Rng, Ctx: TJSONObject;
  Lo, Hi: TLspPos;
  Eol, What, Kind: string;
  Out_: TJSONArray;
  Included, Blind: Boolean;
  Inc_: TInclude;
  Items: TObjectList;
  It: TUnusedItem;
  Units_: TFPList;
  I, J: Integer;
  Drop: TPtrMap;
  E: TJSONObject;
  Tok: TToken;
  Sc: TScope;
  Names: TStrMap;
  Tables: array of TStrMap;
  Keys, Close: TStringArray;
  Sym: TSym;

  function Near(T: TToken): Boolean;
  var
    R: TLspRange;
  begin
    R := TokenRange(T, Lines);
    Result := PosLE(Lo, R.E) and PosLE(R.S, Hi);
  end;

  function Allowed(const AKind: string): Boolean;
  var
    K: Integer;
    W: string;
  begin
    if not Truthy(Want) then
      Exit(True);
    if not (Want is TJSONArray) then
      Exit(False);
    for K := 0 to Want.Count - 1 do
    begin
      W := Want.Items[K].AsString;
      if (AKind = W) or (Copy(AKind, 1, Length(W) + 1) = W + '.') then
        Exit(True);
    end;
    Result := False;
  end;

  function Action(const Title, AKind: string; Edits: TJSONArray; T: TToken = nil): TJSONObject;
  var
    All: TJSONData;
    Tr: TJSONObject;
    Matched: TJSONArray;
    K: Integer;
  begin
    Matched := TJSONArray.Create;
    if T <> nil then
    begin
      Tr := RangeJSON(TokenRange(T, Lines));
      try
        All := nil;
        if Ctx <> nil then
          All := Ctx.Find('diagnostics');
        if All is TJSONArray then
          for K := 0 to All.Count - 1 do
            if (All.Items[K] is TJSONObject) and SameJSON(TJSONObject(All.Items[K]).Find('range'), Tr) then
              Matched.Add(All.Items[K].Clone);
      finally
        Tr.Free;
      end;
    end;
    Result := TJSONObject.Create(['title', Title, 'kind', AKind, 'edit', TJSONObject.Create(['changes',
      TJSONObject.Create([Doc.Uri, Edits])])]);
    if Matched.Count > 0 then
      Result.Add('diagnostics', Matched)
    else
      Matched.Free;
  end;

begin
  Doc := DocOf(P);
  if IsStub(Doc.Path) then
    Exit(TJSONArray.Create);
  Pre := Parse(Doc.Text);
  try
    if Pre.Diags <> nil then
      Exit(TJSONArray.Create);
  finally
    Pre.Free;
  end;
  Prov := ProviderFor(Doc);
  Bound := BindDoc(Doc, Prov);
  Res := Bound.Res;
  B := Bound.Binder;
  Lines := Bound.Lines;
  Ctx := JObj(P, 'context');
  Want := nil;
  if Ctx <> nil then
    Want := Ctx.Find('only');
  Rng := JObj(P, 'range');
  Lo := MkPos(JInt(JObj(Rng, 'start'), 'line'), JInt(JObj(Rng, 'start'), 'character'));
  Hi := MkPos(JInt(JObj(Rng, 'end'), 'line'), JInt(JObj(Rng, 'end'), 'character'));
  if Pos(#13#10, Doc.Text) > 0 then
    Eol := #13#10
  else
    Eol := #10;
  Out_ := TJSONArray.Create;
  Included := False;
  for Inc_ in Res.Includes do
    if not Inc_.Resolved then
      Included := True;
  if not Included then
  begin
    Items := UnusedItems(Doc, Bound, Prov);
    Units_ := TFPList.Create;
    try
      for I := 0 to Items.Count - 1 do
        if TUnusedItem(Items[I]).Kind = 'unit' then
          Units_.Add(Items[I]);
      if Allowed('quickfix') then
        for I := 0 to Items.Count - 1 do
        begin
          It := TUnusedItem(Items[I]);
          if not Near(It.Tok) then
            Continue;
          if It.Kind = 'unit' then
          begin
            Drop := TPtrMap.Create;
            Drop.Put(It.Tok, It.Tok);
            Out_.Add(Action(Format('Remove unused unit ''%s''', [It.Tok.Text]), 'quickfix', UsesEdit(Res, Lines, Drop),
              It.Tok));
            Drop.Free;
          end
          else
          begin
            E := DeclEdit(Res, Lines, It.Tok);
            if E <> nil then
            begin
              if It.Kind = 'var' then
                What := 'variable'
              else if It.Kind = 'const' then
                What := 'constant'
              else
                What := It.Kind;
              Out_.Add(Action(Format('Remove unused %s ''%s''', [What, It.Sym.Name]), 'quickfix',
                TJSONArray.Create([E]), It.Tok));
            end;
          end;
        end;
      if (Units_.Count > 0) and Allowed('source.organizeImports') then
      begin
        Drop := TPtrMap.Create;
        for I := 0 to Units_.Count - 1 do
          Drop.Put(TUnusedItem(Units_[I]).Tok, TObject(Units_[I]));
        Out_.Add(Action('Remove unused units', 'source.organizeImports', UsesEdit(Res, Lines, Drop)));
        Drop.Free;
      end;
    finally
      Units_.Free;
      Items.Free;
    end;
  end;
  if Allowed('quickfix') then
  begin
    Blind := (B.MissingUnits <> nil) or (Prov.Errors.Count > 0) or Included;
    if not Blind then
      for Tok in B.Unresolved do
      begin
        if not Near(Tok) then
          Continue;
        Sc := ScopeAt(Bound, TokenRange(Tok, Lines).S);
        Names := TStrMap.Create;
        try
          while Sc <> nil do
          begin
            Tables := nil;
            for I := 0 to High(Sc.Units) do
            begin
              SetLength(Tables, Length(Tables) + 1);
              Tables[High(Tables)] := Sc.Units[I].Exports_;
            end;
            SetLength(Tables, Length(Tables) + 1);
            Tables[High(Tables)] := Sc.Table;
            for J := 0 to High(Tables) do
              for I := 0 to Tables[J].Count - 1 do
                if not Names.Has(Tables[J].KeyAt(I)) then
                  Names.Put(Tables[J].KeyAt(I), Tables[J].At(I));
            Sc := Sc.Parent;
          end;
          SetLength(Keys, Names.Count);
          for I := 0 to Names.Count - 1 do
            Keys[I] := Names.KeyAt(I);
          Close := GetCloseMatches(LowerText(Tok.Text), Keys, 3, 0.7);
          for Kind in Close do
            Out_.Add(Action(Format('Change to ''%s''', [TSym(Names.Get(Kind)).Name]), 'quickfix',
              TJSONArray.Create([TJSONObject.Create(['range', RangeJSON(TokenRange(Tok, Lines)), 'newText',
              TSym(Names.Get(Kind)).Name])]), Tok));
        finally
          Names.Free;
        end;
      end;
    for I := 0 to B.Decls.Count - 1 do
    begin
      Sym := TSym(B.Decls.At(I));
      if (Sym.Kind = skRoutine) and (Sym.Tok <> nil) and (Pointer(Sym.Tok) = B.Decls.KeyAt(I)) and not Sym.Lib and
        not Sym.HasBody and (Sym.Node <> nil) and (Sym.Tok.Via = nil) and not RoutineHasNoBodyByDesign(Sym.Node) and
        Near(Sym.Tok) then
      begin
        E := ImplementationStub(Res, Lines, Sym, Eol);
        if E <> nil then
        begin
          if Sym.Owner <> nil then
            What := Sym.Owner.Name + '.' + Sym.Name
          else
            What := Sym.Name;
          Out_.Add(Action(Format('Add implementation of ''%s''', [What]), 'quickfix', TJSONArray.Create([E]), Sym.Tok));
        end;
      end;
    end;
  end;
  Result := Out_;
end;

function THandlerServer.Semantic(P: TJSONObject; Ranged: Boolean): TJSONData;
var
  Doc: TDoc;
  Prov: TProvider;
  Bound: TBound;
  First, Last: Integer;
  HasLast: Boolean;
  R, E: TJSONObject;
begin
  Doc := DocOf(P);
  Prov := ProviderFor(Doc);
  Bound := BindDoc(Doc, Prov);
  LogProv(Prov);
  First := 0;
  Last := 0;
  HasLast := False;
  if Ranged then
  begin
    R := JObj(P, 'range');
    First := JInt(JObj(R, 'start'), 'line', 0);
    E := JObj(R, 'end');
    if JHas(E, 'line') then
    begin
      HasLast := True;
      Last := JInt(E, 'line');
    end;
  end;
  Result := TJSONObject.Create(['data', SemanticData(Bound.Res, Bound.Binder, SplitNL(Doc.Text), First, HasLast, Last)]);
end;

initialization
  DefaultSystemCodePage := CP_UTF8;
  DefaultFileSystemCodePage := CP_UTF8;
  DefaultRTLFileSystemCodePage := CP_UTF8;
end.
