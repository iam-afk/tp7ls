unit tp7parse;

{$mode objfpc}{$H+}

interface

uses
  Contnrs, SysUtils, tp7lex;

type
  TNodeKind = (nkFile, nkProgram, nkProgramHeader, nkUnit, nkInterface, nkImplementation, nkInitSection,
    nkUsesClause, nkLabelSection, nkConstSection, nkConstDecl, nkTypeSection, nkTypeDecl, nkVarSection, nkVarDecl,
    nkAbsolute, nkRoutine, nkParams, nkParamGroup, nkDirectives, nkBlock, nkCompound, nkAsm, nkInline, nkNamedType,
    nkPointerType, nkArrayType, nkRecordType, nkFieldList, nkFieldDecl, nkVariantPart, nkVariant, nkLabels,
    nkSetType, nkFileType, nkStringType, nkProcType, nkEnumType, nkSubrangeType, nkPackedType, nkObjectType,
    nkHeritage, nkSection, nkStmtList, nkEmpty, nkAssign, nkProcCall, nkInherited, nkIf, nkWhile, nkRepeat, nkFor,
    nkCase, nkCaseBranch, nkCaseElse, nkWith, nkGoto, nkLabeled, nkBinary, nkUnary, nkParen, nkSetCtor, nkLiteral,
    nkStringLit, nkDesignator, nkName, nkField, nkIndex, nkDeref, nkArgs, nkArg, nkAggregate, nkDeclName, nkError);

  TDirectiveKind = (dkIfdef, dkIfndef, dkIfopt, dkElse, dkEndif, dkDefine, dkUndef, dkInclude, dkLink, dkSwitch,
    dkOther);

  TNode = class;
  TNodes = array of TNode;
  TKids = array of TObject;

  TNode = class
  public
    Kind: TNodeKind;
    Kids: TKids;
    function Tokens: TTokens;
    function Walk: TNodes;
    function Nodes(AKind: TNodeKind): TNodes;
    function First(AKind: TNodeKind): TNode;
    function Text: string;
    function Sexp: string;
    function Dump(Depth: Integer = 0): string;
  end;

  TDiag = record
    Token: TToken;
    Message: string;
  end;

  TDiags = array of TDiag;

  TInclude = record
    Token: TToken;
    Name: string;
    Path: string;
    Resolved: Boolean;
  end;

  TIncludes = array of TInclude;

  TIncludeResolver = function(const Name, FromPath: string; out Path, Text: string): Boolean of object;

  TParseResult = class
  private
    FNodes: TObjectList;
    FIncluded: TObjectList;
    FDocSig: TTokens;
    FDocSigDone: Boolean;
  public
    Tree: TNode;
    Tokens: TTokens;
    Sig: TTokens;
    Diags: TDiags;
    Includes: TIncludes;
    Source: string;
    constructor Create;
    destructor Destroy; override;
    function DocSig: TTokens;
  end;

const
  NodeKindNames: array[TNodeKind] of string = ('File', 'Program', 'ProgramHeader', 'Unit', 'Interface',
    'Implementation', 'InitSection', 'UsesClause', 'LabelSection', 'ConstSection', 'ConstDecl', 'TypeSection',
    'TypeDecl', 'VarSection', 'VarDecl', 'Absolute', 'Routine', 'Params', 'ParamGroup', 'Directives', 'Block',
    'Compound', 'Asm', 'Inline', 'NamedType', 'PointerType', 'ArrayType', 'RecordType', 'FieldList', 'FieldDecl',
    'VariantPart', 'Variant', 'Labels', 'SetType', 'FileType', 'StringType', 'ProcType', 'EnumType', 'SubrangeType',
    'PackedType', 'ObjectType', 'Heritage', 'Section', 'StmtList', 'Empty', 'Assign', 'ProcCall', 'Inherited', 'If',
    'While', 'Repeat', 'For', 'Case', 'CaseBranch', 'CaseElse', 'With', 'Goto', 'Labeled', 'Binary', 'Unary', 'Paren',
    'SetCtor', 'Literal', 'StringLit', 'Designator', 'Name', 'Field', 'Index', 'Deref', 'Args', 'Arg', 'Aggregate',
    'DeclName', 'Error');

  DefaultDefines: array[0..2] of string = ('VER70', 'MSDOS', 'CPU86');
  RoutineDirectives: array[0..8] of string = ('forward', 'external', 'far', 'near', 'interrupt', 'assembler',
    'export', 'virtual', 'override');
  MaxIncludeDepth = 8;
  MaxNesting = 1000;

procedure ParseDirective(const Text: string; out Kind: TDirectiveKind; out Arg: string);
procedure Prepare(const Tokens: TTokens; const Defines: array of string; Include: TIncludeResolver;
  const Path: string; Owned: TObjectList; out Sig: TTokens; out Diags: TDiags; out Includes: TIncludes);
function Parse(const Src: string): TParseResult;
function Parse(const Src: string; const Defines: array of string; Include: TIncludeResolver = nil;
  const Path: string = ''): TParseResult;
function Reconstruct(R: TParseResult): string;
procedure RoutineNames(R: TNode; out Owner, Decl: TNode);
function FieldListOf(T: TNode): TNode;
function PyRepr(const S: string): string;

implementation

uses
  Classes, tp7enc;

type
  ENestingTooDeep = class(Exception);

  TStop = (stNever, stDeclaration, stAggregate, stParams, stBracket, stArgs);

const
  DeclKw: array[0..12] of string = ('const', 'type', 'var', 'label', 'procedure', 'function', 'constructor',
    'destructor', 'implementation', 'interface', 'unit', 'program', 'uses');
  RelOps: array[0..5] of string = ('=', '<>', '<', '>', '<=', '>=');

procedure AddKid(var Kids: TKids; Kid: TObject);
begin
  if Kid = nil then
    Exit;
  SetLength(Kids, Length(Kids) + 1);
  Kids[High(Kids)] := Kid;
end;

procedure AddToken(var Tokens: TTokens; T: TToken);
begin
  SetLength(Tokens, Length(Tokens) + 1);
  Tokens[High(Tokens)] := T;
end;

function PyRepr(const S: string): string;
var
  Quote: Char;
  I: SizeInt;
  C: Char;
begin
  if (Pos('''', S) > 0) and (Pos('"', S) = 0) then
    Quote := '"'
  else
    Quote := '''';
  Result := Quote;
  I := 1;
  while I <= Length(S) do
  begin
    C := S[I];
    if C = '\' then
      Result := Result + '\\'
    else if C = Quote then
      Result := Result + '\' + C
    else if C = #9 then
      Result := Result + '\t'
    else if C = #10 then
      Result := Result + '\n'
    else if C = #13 then
      Result := Result + '\r'
    else if (C < ' ') or (C = #127) then
      Result := Result + '\x' + LowerCase(IntToHex(Ord(C), 2))
    else if (C = #$C2) and (I < Length(S)) and (S[I + 1] in [#$85, #$A0]) then
    begin
      Result := Result + '\x' + LowerCase(IntToHex(Ord(S[I + 1]), 2));
      Inc(I);
    end
    else
      Result := Result + C;
    Inc(I);
  end;
  Result := Result + Quote;
end;

{ TNode }

procedure CollectTokens(N: TNode; var Acc: TTokens; var Count: SizeInt);
var
  K: TObject;
begin
  for K in N.Kids do
    if K is TNode then
      CollectTokens(TNode(K), Acc, Count)
    else
    begin
      if Count = Length(Acc) then
        SetLength(Acc, 2 * Count + 16);
      Acc[Count] := TToken(K);
      Inc(Count);
    end;
end;

function TNode.Tokens: TTokens;
var
  Count: SizeInt;
begin
  Result := nil;
  Count := 0;
  CollectTokens(Self, Result, Count);
  SetLength(Result, Count);
end;

function TNode.Walk: TNodes;
var
  Stack: TNodes;
  Top, Count, J: SizeInt;
  N: TNode;
begin
  Result := nil;
  Count := 0;
  Stack := [Self];
  Top := 1;
  while Top > 0 do
  begin
    Dec(Top);
    N := Stack[Top];
    if Count = Length(Result) then
      SetLength(Result, 2 * Count + 16);
    Result[Count] := N;
    Inc(Count);
    for J := High(N.Kids) downto 0 do
      if N.Kids[J] is TNode then
      begin
        if Top = Length(Stack) then
          SetLength(Stack, 2 * Top + 16);
        Stack[Top] := TNode(N.Kids[J]);
        Inc(Top);
      end;
  end;
  SetLength(Result, Count);
end;

function TNode.Nodes(AKind: TNodeKind): TNodes;
var
  N: TNode;
begin
  Result := nil;
  for N in Walk do
    if N.Kind = AKind then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := N;
    end;
end;

function TNode.First(AKind: TNodeKind): TNode;
var
  N: TNode;
begin
  for N in Walk do
    if N.Kind = AKind then
      Exit(N);
  Result := nil;
end;

function TNode.Text: string;
var
  T: TToken;
begin
  Result := '';
  for T in Tokens do
    if Result = '' then
      Result := T.Text
    else
      Result := Result + ' ' + T.Text;
end;

function TNode.Sexp: string;
var
  K: TObject;
begin
  Result := '(' + NodeKindNames[Kind];
  for K in Kids do
    if K is TNode then
      Result := Result + ' ' + TNode(K).Sexp
    else if TToken(K).Kind = tkString then
      Result := Result + ' ' + PyRepr(TToken(K).Text)
    else
      Result := Result + ' ' + TToken(K).Text;
  Result := Result + ')';
end;

function TNode.Dump(Depth: Integer): string;
var
  Pad: string;
  K: TObject;
begin
  Pad := StringOfChar(' ', 2 * Depth);
  Result := Pad + NodeKindNames[Kind];
  for K in Kids do
    if K is TNode then
      Result := Result + LineEnding + TNode(K).Dump(Depth + 1)
    else
      Result := Result + LineEnding + Pad + '  ' + TokenKindNames[TToken(K).Kind] + ' ' + PyRepr(TToken(K).Text);
end;

{ TParseResult }

constructor TParseResult.Create;
begin
  FNodes := TObjectList.Create(True);
  FIncluded := TObjectList.Create(True);
end;

destructor TParseResult.Destroy;
begin
  FNodes.Free;
  FIncluded.Free;
  FreeTokens(Tokens);
  inherited Destroy;
end;

function TParseResult.DocSig: TTokens;
var
  T: TToken;
begin
  if not FDocSigDone then
  begin
    if Includes = nil then
      FDocSig := Sig
    else
      for T in Sig do
        if T.Via = nil then
          AddToken(FDocSig, T);
    FDocSigDone := True;
  end;
  Result := FDocSig;
end;

{ directives and conditional compilation }

function IsSwitchList(const S: string): Boolean;
var
  I: SizeInt;

  function Pair: Boolean;
  begin
    Result := (I < Length(S)) and (S[I] in ['A'..'Z', 'a'..'z']) and (S[I + 1] in ['+', '-']);
    if Result then
      Inc(I, 2);
  end;

  procedure SkipSpace;
  var
    L: SizeInt;
  begin
    repeat
      L := SpaceLen(S, I);
      Inc(I, L);
    until L = 0;
  end;

begin
  I := 1;
  if not Pair then
    Exit(False);
  while I <= Length(S) do
  begin
    SkipSpace;
    if (I > Length(S)) or (S[I] <> ',') then
      Exit(False);
    Inc(I);
    SkipSpace;
    if not Pair then
      Exit(False);
  end;
  Result := True;
end;

procedure ParseDirective(const Text: string; out Kind: TDirectiveKind; out Arg: string);
var
  Inner, Name, Rest: string;
  I, Start: SizeInt;
begin
  if (Text <> '') and (Text[1] = '{') then
    Inner := Copy(Text, 3, Length(Text) - 3)
  else
    Inner := Copy(Text, 4, Length(Text) - 5);
  I := 1;
  while SpaceLen(Inner, I) > 0 do
    Inc(I, SpaceLen(Inner, I));
  Start := I;
  while (I <= Length(Inner)) and (Inner[I] in ['A'..'Z', 'a'..'z']) do
    Inc(I);
  Kind := dkOther;
  Arg := '';
  if I = Start then
    Exit;
  Name := UpperCase(Copy(Inner, Start, I - Start));
  Rest := StripSpace(Copy(Inner, I, MaxInt));
  if (Name = 'IFDEF') or (Name = 'IFNDEF') or (Name = 'DEFINE') or (Name = 'UNDEF') then
  begin
    if Name = 'IFDEF' then
      Kind := dkIfdef
    else if Name = 'IFNDEF' then
      Kind := dkIfndef
    else if Name = 'DEFINE' then
      Kind := dkDefine
    else
      Kind := dkUndef;
    Arg := UpperText(FirstWord(Rest));
  end
  else if Name = 'IFOPT' then
  begin
    Kind := dkIfopt;
    Arg := UpperText(StringReplace(Rest, ' ', '', [rfReplaceAll]));
  end
  else if Name = 'ELSE' then
    Kind := dkElse
  else if Name = 'ENDIF' then
    Kind := dkEndif
  else if (Name = 'INCLUDE') or ((Name = 'I') and (Rest <> '') and not (Rest[1] in ['+', '-'])) then
  begin
    Kind := dkInclude;
    Arg := Rest;
  end
  else if (Name = 'L') and (Rest <> '') and not (Rest[1] in ['+', '-']) then
  begin
    Kind := dkLink;
    Arg := Rest;
  end
  else if (Length(Name) = 1) and IsSwitchList(Name + Rest) then
  begin
    Kind := dkSwitch;
    Arg := Name + Rest;
  end
  else
    Arg := Rest;
end;

procedure Prepare(const Tokens: TTokens; const Defines: array of string; Include: TIncludeResolver;
  const Path: string; Owned: TObjectList; out Sig: TTokens; out Diags: TDiags; out Includes: TIncludes);
type
  TCond = record
    ParentActive, Taken: Boolean;
    Opener: TToken;
  end;
var
  Defs: TStringList;
  Switches: array['A'..'Z'] of Char;
  Stack: array of TCond;
  Active: Boolean;
  Pending: TTokens;
  D: string;
  C: TCond;
  SigCount: SizeInt;

  procedure AddDiag(T: TToken; const Msg: string);
  begin
    SetLength(Diags, Length(Diags) + 1);
    Diags[High(Diags)].Token := T;
    Diags[High(Diags)].Message := Msg;
  end;

  procedure AddInclude(T: TToken; const Name, IncPath: string; Resolved: Boolean);
  begin
    SetLength(Includes, Length(Includes) + 1);
    Includes[High(Includes)].Token := T;
    Includes[High(Includes)].Name := Name;
    Includes[High(Includes)].Path := IncPath;
    Includes[High(Includes)].Resolved := Resolved;
  end;

  procedure AddSig(T: TToken);
  begin
    if SigCount = Length(Sig) then
      SetLength(Sig, 2 * SigCount + 64);
    Sig[SigCount] := T;
    Inc(SigCount);
  end;

  function InChain(const P: string; const Chain: TStringArray): Boolean;
  var
    S: string;
  begin
    for S in Chain do
      if (S <> '') and SameFileName(ExpandFileName(P), ExpandFileName(S)) then
        Exit(True);
    Result := False;
  end;

  procedure ApplySwitches(const Arg: string);
  var
    I: SizeInt;
  begin
    I := 1;
    while I < Length(Arg) do
      if (Arg[I] in ['A'..'Z', 'a'..'z']) and (Arg[I + 1] in ['+', '-']) then
      begin
        Switches[UpCase(Arg[I])] := Arg[I + 1];
        Inc(I, 2);
      end
      else
        Inc(I);
  end;

  procedure Feed(const Toks: TTokens; const Chain: TStringArray; Via: TToken);
  var
    Own, Cond, Got: Boolean;
    T: TToken;
    Kind: TDirectiveKind;
    Arg, IncPath, IncText: string;
    Sub: TTokens;
    J: SizeInt;
  begin
    Own := Via = nil;
    for T in Toks do
    begin
      T.Leading := nil;
      if not Own then
      begin
        T.Via := Via;
        T.FileName := Chain[High(Chain)];
      end;
      if T.Kind = tkDirective then
      begin
        ParseDirective(T.Text, Kind, Arg);
        case Kind of
          dkIfdef, dkIfndef, dkIfopt:
            begin
              T.Active := Active;
              if Kind = dkIfdef then
                Cond := Defs.IndexOf(Arg) >= 0
              else if Kind = dkIfndef then
                Cond := Defs.IndexOf(Arg) < 0
              else
                Cond := (Length(Arg) = 2) and (Arg[1] in ['A'..'Z']) and (Switches[Arg[1]] = Arg[2]);
              SetLength(Stack, Length(Stack) + 1);
              Stack[High(Stack)].ParentActive := Active;
              Stack[High(Stack)].Taken := Active and Cond;
              Stack[High(Stack)].Opener := T;
              Active := Active and Cond;
            end;
          dkElse:
            if Stack = nil then
            begin
              AddDiag(T, '{$ELSE} without {$IFDEF}');
              T.Active := Active;
            end
            else
            begin
              T.Active := Stack[High(Stack)].ParentActive;
              Active := Stack[High(Stack)].ParentActive and not Stack[High(Stack)].Taken;
              Stack[High(Stack)].Taken := Stack[High(Stack)].Taken or Active;
            end;
          dkEndif:
            if Stack = nil then
            begin
              AddDiag(T, '{$ENDIF} without {$IFDEF}');
              T.Active := Active;
            end
            else
            begin
              T.Active := Stack[High(Stack)].ParentActive;
              Active := Stack[High(Stack)].ParentActive;
              SetLength(Stack, Length(Stack) - 1);
            end;
        else
          T.Active := Active;
          if Active then
            case Kind of
              dkDefine:
                Defs.Add(Arg);
              dkUndef:
                if Defs.IndexOf(Arg) >= 0 then
                  Defs.Delete(Defs.IndexOf(Arg));
              dkInclude:
                begin
                  Got := Assigned(Include) and (Length(Chain) <= MaxIncludeDepth)
                    and Include(Arg, Chain[High(Chain)], IncPath, IncText);
                  if Got and InChain(IncPath, Chain) then
                    Got := False;
                  if not Got then
                    if Own then
                      AddInclude(T, Arg, '', False)
                    else
                      AddInclude(Via, Arg, '', False)
                  else
                  begin
                    if Own then
                      AddInclude(T, Arg, IncPath, True)
                    else
                      AddInclude(Via, Arg, IncPath, True);
                    Sub := Lex(IncText);
                    for J := 0 to High(Sub) do
                    begin
                      Sub[J].Idx := J;
                      Owned.Add(Sub[J]);
                    end;
                    if Own then
                    begin
                      AddToken(Pending, T);
                      Feed(Copy(Sub, 0, High(Sub)), Concat(Chain, [IncPath]), T);
                    end
                    else
                      Feed(Copy(Sub, 0, High(Sub)), Concat(Chain, [IncPath]), Via);
                    Continue;
                  end;
                end;
              dkSwitch:
                ApplySwitches(Arg);
            end;
        end;
        if Own then
          AddToken(Pending, T);
        Continue;
      end;
      T.Active := Active;
      if (T.Kind <> tkEOF) and ((T.Kind in Trivia) or not Active) then
      begin
        if Own then
          AddToken(Pending, T);
      end
      else
      begin
        if Own then
        begin
          T.Leading := Pending;
          Pending := nil;
        end;
        AddSig(T);
      end;
    end;
  end;

begin
  Sig := nil;
  Diags := nil;
  Includes := nil;
  Stack := nil;
  Pending := nil;
  SigCount := 0;
  Active := True;
  Defs := TStringList.Create;
  try
    Defs.CaseSensitive := True;
    Defs.Sorted := True;
    Defs.Duplicates := dupIgnore;
    for D in Defines do
      Defs.Add(UpperText(D));
    FillChar(Switches, SizeOf(Switches), 0);
    ApplySwitches('A+B-D+E+F-G-I+L+N-O-P-Q-R-S+T-V+X+Y+');
    Feed(Tokens, [Path], nil);
  finally
    Defs.Free;
  end;
  SetLength(Sig, SigCount);
  for C in Stack do
    AddDiag(C.Opener, 'conditional directive is never closed with {$ENDIF}');
end;

{ helpers on the tree }

procedure RoutineNames(R: TNode; out Owner, Decl: TNode);
var
  K: TKids;
begin
  K := R.Kids;
  Owner := nil;
  Decl := nil;
  if (Length(K) > 3) and (K[1] is TNode) and (TNode(K[1]).Kind = nkName) and (K[2] is TToken)
    and (TToken(K[2]).Text = '.') then
  begin
    Owner := TNode(K[1]);
    if K[3] is TNode then
      Decl := TNode(K[3]);
  end
  else if (Length(K) > 1) and (K[1] is TNode) then
    Decl := TNode(K[1]);
end;

function FieldListOf(T: TNode): TNode;
var
  K: TObject;
begin
  for K in T.Kids do
    if (K is TNode) and (TNode(K).Kind = nkFieldList) then
      Exit(TNode(K));
  Result := nil;
end;

{ the parser }

type
  TParser = class
  private
    T: TTokens;
    I: SizeInt;
    Depth: Integer;
    Arena: TObjectList;
  public
    Diags: TDiags;
    constructor Create(const ASig: TTokens; const ADiags: TDiags; AArena: TObjectList);
    function NewNode(Kind: TNodeKind; const Kids: array of TObject): TNode;
    procedure Enter;
    procedure Leave;
    function Cur: TToken;
    function La(K: SizeInt): TToken;
    function Take: TToken;
    function Eof: Boolean;
    function Kw(const Names: array of string; K: SizeInt = 0): Boolean;
    function Sym(const S: array of string; K: SizeInt = 0): Boolean;
    function Ident(K: SizeInt = 0): Boolean;
    function Idn(const Names: array of string; K: SizeInt = 0): Boolean;
    function Lbr(K: SizeInt = 0): Boolean;
    function Rbr(K: SizeInt = 0): Boolean;
    procedure AddDiag(Token: TToken; const Msg: string);
    procedure Diag(const Msg: string);
    function WantKw(var Kids: TKids; const Name: string): Boolean;
    function WantSym(var Kids: TKids; const S: array of string): Boolean;
    procedure Semi(var Kids: TKids);
    function Stopped(Stop: TStop): Boolean;
    function ErrorSkip(Stop: TStop = stNever; AtLeastOne: Boolean = True): TNode;
    function DeclName: TNode;
    function Name: TNode;
    function QualifiedName: TNode;
    function ParseFile: TNode;
    function ProgramFile: TNode;
    function UsesClause: TNode;
    function UnitFile: TNode;
    procedure Declarations(var Kids: TKids; InInterface: Boolean);
    function LabelSection: TNode;
    function ConstSection: TNode;
    function TypeSection: TNode;
    function VarSection: TNode;
    function ConstValue: TNode;
    function LooksLikeAggregate: Boolean;
    function Aggregate: TNode;
    function Params: TNode;
    function Routine(InInterface: Boolean): TNode;
    function InlineCode: TNode;
    function Block: TNode;
    function TypeSpec: TNode;
    function LooksLikeEnum: Boolean;
    function ObjectType: TNode;
    function FieldList(Methods: Boolean = False): TNode;
    function VariantPart: TNode;
    function LabelList: TNode;
    function Compound: TNode;
    function AsmBlock: TNode;
    function AtStop(const Stops: array of string): Boolean;
    function StmtList(const Stops: array of string): TNode;
    function Statement: TNode;
    function Inherited_: TNode;
    function CaseStmt: TNode;
    function Expr: TNode;
    function SimpleExpr: TNode;
    function Term: TNode;
    function Factor: TNode;
    function SetCtor: TNode;
    function Designator: TNode;
  end;

constructor TParser.Create(const ASig: TTokens; const ADiags: TDiags; AArena: TObjectList);
begin
  T := ASig;
  Diags := ADiags;
  Arena := AArena;
end;

function TParser.NewNode(Kind: TNodeKind; const Kids: array of TObject): TNode;
var
  K: TObject;
begin
  Result := TNode.Create;
  Arena.Add(Result);
  Result.Kind := Kind;
  for K in Kids do
    AddKid(Result.Kids, K);
end;

procedure TParser.Enter;
begin
  Inc(Depth);
  if Depth > MaxNesting then
    raise ENestingTooDeep.Create('nesting too deep');
end;

procedure TParser.Leave;
begin
  Dec(Depth);
end;

function TParser.Cur: TToken;
begin
  Result := T[I];
end;

function TParser.La(K: SizeInt): TToken;
begin
  if I + K < High(T) then
    Result := T[I + K]
  else
    Result := T[High(T)];
end;

function TParser.Take: TToken;
begin
  Result := T[I];
  if Result.Kind <> tkEOF then
    Inc(I);
end;

function TParser.Eof: Boolean;
begin
  Result := Cur.Kind = tkEOF;
end;

function InNames(const S: string; const Names: array of string): Boolean;
var
  N: string;
begin
  for N in Names do
    if SameText(S, N) then
      Exit(True);
  Result := False;
end;

function TParser.Kw(const Names: array of string; K: SizeInt): Boolean;
begin
  Result := (La(K).Kind = tkKW) and InNames(La(K).Text, Names);
end;

function TParser.Sym(const S: array of string; K: SizeInt): Boolean;
var
  X: string;
begin
  if La(K).Kind <> tkSym then
    Exit(False);
  for X in S do
    if La(K).Text = X then
      Exit(True);
  Result := False;
end;

function TParser.Ident(K: SizeInt): Boolean;
begin
  Result := La(K).Kind = tkIdent;
end;

function TParser.Idn(const Names: array of string; K: SizeInt): Boolean;
begin
  Result := (La(K).Kind = tkIdent) and InNames(La(K).Text, Names);
end;

function TParser.Lbr(K: SizeInt): Boolean;
begin
  Result := Sym(['[', '(.'], K);
end;

function TParser.Rbr(K: SizeInt): Boolean;
begin
  Result := Sym([']', '.)'], K);
end;

procedure TParser.AddDiag(Token: TToken; const Msg: string);
begin
  SetLength(Diags, Length(Diags) + 1);
  Diags[High(Diags)].Token := Token;
  Diags[High(Diags)].Message := Msg;
end;

procedure TParser.Diag(const Msg: string);
begin
  AddDiag(Cur, Msg);
end;

function TParser.WantKw(var Kids: TKids; const Name: string): Boolean;
begin
  Result := Kw([Name]);
  if Result then
    AddKid(Kids, Take)
  else
    Diag('expected ''' + Name + '''');
end;

function TParser.WantSym(var Kids: TKids; const S: array of string): Boolean;
begin
  Result := Sym(S);
  if Result then
    AddKid(Kids, Take)
  else
    Diag('expected ''' + S[0] + '''');
end;

procedure TParser.Semi(var Kids: TKids);
begin
  if Sym([';']) then
    AddKid(Kids, Take)
  else
    Diag('expected '';''');
end;

function TParser.Stopped(Stop: TStop): Boolean;
begin
  case Stop of
    stDeclaration:
      Result := Kw(['begin', 'end', 'asm', 'const', 'type', 'var', 'label', 'procedure', 'function',
        'implementation', 'constructor', 'destructor']);
    stAggregate:
      Result := Sym([')', ';']);
    stParams:
      Result := Sym([')', ';']) or Kw(['begin', 'var']);
    stBracket:
      Result := Rbr or Sym([';']);
    stArgs:
      Result := Sym([')', ';']);
  else
    Result := False;
  end;
end;

function TParser.ErrorSkip(Stop: TStop; AtLeastOne: Boolean): TNode;
var
  K: TKids;
begin
  K := nil;
  while not Eof and not Stopped(Stop) do
  begin
    AddKid(K, Take);
    AtLeastOne := False;
  end;
  if AtLeastOne and not Eof then
    AddKid(K, Take);
  Result := NewNode(nkError, K);
end;

function TParser.DeclName: TNode;
begin
  if Ident then
    Exit(NewNode(nkDeclName, [Take]));
  Diag('identifier expected');
  Result := NewNode(nkError, []);
end;

function TParser.Name: TNode;
begin
  if Ident then
    Exit(NewNode(nkName, [Take]));
  Diag('identifier expected');
  Result := NewNode(nkError, []);
end;

function TParser.QualifiedName: TNode;
var
  K: TKids;
  Kid: TObject;
begin
  K := nil;
  for Kid in Name.Kids do
    AddKid(K, Kid);
  while Sym(['.']) and Ident(1) do
  begin
    AddKid(K, Take);
    AddKid(K, Take);
  end;
  Result := NewNode(nkName, K);
end;

function TParser.ParseFile: TNode;
var
  K: TKids;
begin
  K := nil;
  if Kw(['unit']) then
    AddKid(K, UnitFile)
  else
    AddKid(K, ProgramFile);
  if not Eof then
  begin
    Diag('unexpected text after the end of the file');
    AddKid(K, ErrorSkip(stNever, False));
  end;
  Result := NewNode(nkFile, K);
end;

function TParser.ProgramFile: TNode;
var
  K, H: TKids;
begin
  K := nil;
  if Kw(['program']) then
  begin
    H := nil;
    AddKid(H, Take);
    AddKid(H, DeclName);
    if Sym(['(']) then
    begin
      AddKid(H, Take);
      while not Eof and not Sym([')']) and not Sym([';']) do
        AddKid(H, Take);
      WantSym(H, [')']);
    end;
    Semi(H);
    AddKid(K, NewNode(nkProgramHeader, H));
  end;
  if Kw(['uses']) then
    AddKid(K, UsesClause);
  AddKid(K, Block);
  WantSym(K, ['.']);
  Result := NewNode(nkProgram, K);
end;

function TParser.UsesClause: TNode;
var
  K: TKids;
begin
  K := nil;
  AddKid(K, Take);
  while True do
  begin
    AddKid(K, Name);
    if not Sym([',']) then
      Break;
    AddKid(K, Take);
  end;
  Semi(K);
  Result := NewNode(nkUsesClause, K);
end;

function TParser.UnitFile: TNode;
var
  K, Sub: TKids;
  C: TNode;
begin
  K := nil;
  AddKid(K, Take);
  AddKid(K, DeclName);
  Semi(K);
  Sub := nil;
  WantKw(Sub, 'interface');
  if Kw(['uses']) then
    AddKid(Sub, UsesClause);
  Declarations(Sub, True);
  AddKid(K, NewNode(nkInterface, Sub));
  Sub := nil;
  WantKw(Sub, 'implementation');
  if Kw(['uses']) then
    AddKid(Sub, UsesClause);
  Declarations(Sub, False);
  AddKid(K, NewNode(nkImplementation, Sub));
  if Kw(['begin']) then
  begin
    C := Compound;
    AddKid(K, NewNode(nkInitSection, [C]));
  end
  else
  begin
    Sub := nil;
    WantKw(Sub, 'end');
    AddKid(K, NewNode(nkInitSection, Sub));
  end;
  WantSym(K, ['.']);
  Result := NewNode(nkUnit, K);
end;

procedure TParser.Declarations(var Kids: TKids; InInterface: Boolean);
var
  P: SizeInt;
begin
  while True do
  begin
    P := I;
    if Kw(['label']) then
      AddKid(Kids, LabelSection)
    else if Kw(['const']) then
      AddKid(Kids, ConstSection)
    else if Kw(['type']) then
      AddKid(Kids, TypeSection)
    else if Kw(['var']) then
      AddKid(Kids, VarSection)
    else if Kw(['procedure', 'function', 'constructor', 'destructor']) then
      AddKid(Kids, Routine(InInterface))
    else
    begin
      if not (Kw(['begin', 'end', 'asm', 'implementation', 'interface']) or Eof) then
      begin
        Diag('declaration expected');
        AddKid(Kids, ErrorSkip(stDeclaration));
        if I = P then
          Break;
        Continue;
      end;
      Break;
    end;
    if I = P then
      Break;
  end;
end;

function TParser.LabelSection: TNode;
var
  K: TKids;
begin
  K := nil;
  AddKid(K, Take);
  while Cur.Kind in [tkInt, tkIdent] do
  begin
    AddKid(K, Take);
    if Sym([',']) then
      AddKid(K, Take)
    else
      Break;
  end;
  Semi(K);
  Result := NewNode(nkLabelSection, K);
end;

function TParser.ConstSection: TNode;
var
  K, D: TKids;
begin
  K := nil;
  AddKid(K, Take);
  while Ident do
  begin
    D := nil;
    AddKid(D, DeclName);
    if Sym([':']) then
    begin
      AddKid(D, Take);
      AddKid(D, TypeSpec());
      WantSym(D, ['=']);
      AddKid(D, ConstValue);
    end
    else
    begin
      WantSym(D, ['=']);
      AddKid(D, Expr);
    end;
    Semi(D);
    AddKid(K, NewNode(nkConstDecl, D));
  end;
  Result := NewNode(nkConstSection, K);
end;

function TParser.TypeSection: TNode;
var
  K, D: TKids;
begin
  K := nil;
  AddKid(K, Take);
  while Ident do
  begin
    D := nil;
    AddKid(D, DeclName);
    WantSym(D, ['=']);
    AddKid(D, TypeSpec());
    Semi(D);
    AddKid(K, NewNode(nkTypeDecl, D));
  end;
  Result := NewNode(nkTypeSection, K);
end;

function TParser.VarSection: TNode;
var
  K, D, A: TKids;
begin
  K := nil;
  AddKid(K, Take);
  while Ident do
  begin
    D := nil;
    AddKid(D, DeclName);
    while Sym([',']) do
    begin
      AddKid(D, Take);
      AddKid(D, DeclName);
    end;
    WantSym(D, [':']);
    AddKid(D, TypeSpec());
    if Idn(['absolute']) then
    begin
      A := nil;
      AddKid(A, Take);
      AddKid(A, Expr);
      if Sym([':']) then
      begin
        AddKid(A, Take);
        AddKid(A, Expr);
      end;
      AddKid(D, NewNode(nkAbsolute, A));
    end;
    Semi(D);
    AddKid(K, NewNode(nkVarDecl, D));
  end;
  Result := NewNode(nkVarSection, K);
end;

function TParser.ConstValue: TNode;
begin
  Enter;
  if Sym(['(']) and LooksLikeAggregate then
    Result := Aggregate
  else
    Result := Expr;
  Leave;
end;

function TParser.LooksLikeAggregate: Boolean;
var
  D, J: SizeInt;
  Tk: TToken;
begin
  D := 0;
  J := I;
  while J < Length(T) do
  begin
    Tk := T[J];
    if Tk.Kind = tkEOF then
      Exit(False);
    if Tk.Kind = tkSym then
      if Tk.Text = '(' then
        Inc(D)
      else if Tk.Text = ')' then
      begin
        Dec(D);
        if D = 0 then
          Exit(False);
      end
      else if (D = 1) and ((Tk.Text = ',') or (Tk.Text = ';') or (Tk.Text = ':')) then
        Exit(True);
    Inc(J);
  end;
  Result := False;
end;

function TParser.Aggregate: TNode;
var
  K: TKids;
  P: SizeInt;
begin
  K := nil;
  AddKid(K, Take);
  while not Eof and not Sym([')']) do
  begin
    P := I;
    if Ident and Sym([':'], 1) then
    begin
      AddKid(K, Take);
      AddKid(K, Take);
    end;
    AddKid(K, ConstValue);
    if Sym([',', ';']) then
      AddKid(K, Take)
    else if not Sym([')']) then
    begin
      Diag('expected '','' or '')''');
      if I = P then
        AddKid(K, ErrorSkip(stAggregate));
    end;
  end;
  WantSym(K, [')']);
  Result := NewNode(nkAggregate, K);
end;

function TParser.Params: TNode;
var
  K, G: TKids;
  P: SizeInt;
begin
  K := nil;
  AddKid(K, Take);
  while not Eof and not Sym([')']) do
  begin
    P := I;
    G := nil;
    if Kw(['var', 'const']) then
      AddKid(G, Take);
    AddKid(G, DeclName);
    while Sym([',']) do
    begin
      AddKid(G, Take);
      AddKid(G, DeclName);
    end;
    if Sym([':']) then
    begin
      AddKid(G, Take);
      AddKid(G, TypeSpec());
    end;
    AddKid(K, NewNode(nkParamGroup, G));
    if Sym([';']) then
      AddKid(K, Take)
    else if not Sym([')']) then
    begin
      Diag('expected '';'' or '')''');
      AddKid(K, ErrorSkip(stParams));
    end;
    if I = P then
      AddKid(K, ErrorSkip);
  end;
  WantSym(K, [')']);
  Result := NewNode(nkParams, K);
end;

function TParser.Routine(InInterface: Boolean): TNode;
var
  K, D: TKids;
  FirstName: TNode;
  Directive: string;
  Fwd: Boolean;
begin
  Enter;
  K := nil;
  AddKid(K, Take);
  FirstName := DeclName;
  if (FirstName.Kind = nkDeclName) and Sym(['.']) and Ident(1) then
  begin
    AddKid(K, NewNode(nkName, FirstName.Kids));
    AddKid(K, Take);
    AddKid(K, DeclName);
  end
  else
    AddKid(K, FirstName);
  if Sym(['(']) then
    AddKid(K, Params);
  if Sym([':']) then
  begin
    AddKid(K, Take);
    AddKid(K, TypeSpec());
  end;
  Semi(K);
  D := nil;
  Fwd := False;
  while True do
    if Idn(RoutineDirectives) then
    begin
      Directive := Cur.Lower;
      AddKid(D, Take);
      if (Directive = 'forward') or (Directive = 'external') then
        Fwd := True;
      if Directive = 'external' then
        while not Eof and not Sym([';']) and not Kw(['begin']) do
          AddKid(D, Take);
      Semi(D);
    end
    else if Kw(['inline']) then
    begin
      AddKid(D, InlineCode);
      Semi(D);
      Fwd := True;
    end
    else
      Break;
  if D <> nil then
    AddKid(K, NewNode(nkDirectives, D));
  if not InInterface and not Fwd then
  begin
    AddKid(K, Block);
    Semi(K);
  end;
  Result := NewNode(nkRoutine, K);
  Leave;
end;

function TParser.InlineCode: TNode;
var
  K: TKids;
  D: Integer;
  Tk: TToken;
begin
  K := nil;
  AddKid(K, Take);
  if Sym(['(']) then
  begin
    D := 0;
    while not Eof do
    begin
      Tk := Take;
      AddKid(K, Tk);
      if (Tk.Kind = tkSym) and (Tk.Text = '(') then
        Inc(D)
      else if (Tk.Kind = tkSym) and (Tk.Text = ')') then
      begin
        Dec(D);
        if D = 0 then
          Break;
      end;
    end;
  end;
  Result := NewNode(nkInline, K);
end;

function TParser.Block: TNode;
var
  K: TKids;
begin
  K := nil;
  Declarations(K, False);
  if Kw(['begin']) then
    AddKid(K, Compound)
  else if Kw(['asm']) then
    AddKid(K, AsmBlock)
  else
    Diag('''begin'' expected');
  Result := NewNode(nkBlock, K);
end;

function TParser.TypeSpec: TNode;
var
  K: TKids;
  Caret, Tk: TToken;
  Sub: TNode;
begin
  Enter;
  K := nil;
  if Kw(['packed']) then
  begin
    Tk := Take;
    Sub := TypeSpec();
    Result := NewNode(nkPackedType, [Tk, Sub]);
  end
  else if Sym(['^']) then
  begin
    Caret := Take;
    if Kw(['string']) then
    begin
      Tk := Take;
      Sub := NewNode(nkName, [Tk]);
    end
    else
      Sub := QualifiedName;
    Result := NewNode(nkPointerType, [Caret, Sub]);
  end
  else if Kw(['array']) then
  begin
    AddKid(K, Take);
    if Lbr then
    begin
      AddKid(K, Take);
      while True do
      begin
        AddKid(K, TypeSpec());
        if not Sym([',']) then
          Break;
        AddKid(K, Take);
      end;
      if Rbr then
        AddKid(K, Take)
      else
        Diag('expected '']''');
    end
    else if not Kw(['of']) then
      Diag('expected ''[''');
    WantKw(K, 'of');
    AddKid(K, TypeSpec());
    Result := NewNode(nkArrayType, K);
  end
  else if Kw(['record']) then
  begin
    AddKid(K, Take);
    AddKid(K, FieldList(True));
    WantKw(K, 'end');
    Result := NewNode(nkRecordType, K);
  end
  else if Kw(['set']) then
  begin
    AddKid(K, Take);
    WantKw(K, 'of');
    AddKid(K, TypeSpec());
    Result := NewNode(nkSetType, K);
  end
  else if Kw(['file']) then
  begin
    AddKid(K, Take);
    if Kw(['of']) then
    begin
      AddKid(K, Take);
      AddKid(K, TypeSpec());
    end;
    Result := NewNode(nkFileType, K);
  end
  else if Kw(['string']) then
  begin
    AddKid(K, Take);
    if Lbr then
    begin
      AddKid(K, Take);
      AddKid(K, Expr);
      if Rbr then
        AddKid(K, Take)
      else
        Diag('expected '']''');
    end;
    Result := NewNode(nkStringType, K);
  end
  else if Kw(['object']) then
    Result := ObjectType
  else if Kw(['procedure', 'function']) then
  begin
    AddKid(K, Take);
    if Sym(['(']) then
      AddKid(K, Params);
    if Sym([':']) then
    begin
      AddKid(K, Take);
      AddKid(K, TypeSpec());
    end;
    Result := NewNode(nkProcType, K);
  end
  else if Sym(['(']) and LooksLikeEnum then
  begin
    AddKid(K, Take);
    AddKid(K, DeclName);
    while Sym([',']) do
    begin
      AddKid(K, Take);
      AddKid(K, DeclName);
    end;
    WantSym(K, [')']);
    Result := NewNode(nkEnumType, K);
  end
  else if Ident and not Sym(['..'], 1) then
  begin
    Sub := QualifiedName;
    Result := NewNode(nkNamedType, [Sub]);
  end
  else if (Cur.Kind in [tkInt, tkHex, tkReal, tkString, tkCharCode, tkIdent]) or Sym(['+', '-', '(']) then
  begin
    AddKid(K, SimpleExpr);
    WantSym(K, ['..']);
    AddKid(K, SimpleExpr);
    Result := NewNode(nkSubrangeType, K);
  end
  else
  begin
    Diag('type expected');
    Result := NewNode(nkError, []);
  end;
  Leave;
end;

function TParser.LooksLikeEnum: Boolean;
var
  J: SizeInt;
  Nxt: TToken;
begin
  J := I + 1;
  if J > High(T) then
    J := High(T);
  if T[J].Kind <> tkIdent then
    Exit(False);
  if J + 1 > High(T) then
    Nxt := T[High(T)]
  else
    Nxt := T[J + 1];
  Result := (Nxt.Kind = tkSym) and ((Nxt.Text = ',') or (Nxt.Text = ')'));
end;

function TParser.ObjectType: TNode;
var
  K, H: TKids;
begin
  K := nil;
  AddKid(K, Take);
  if Sym(['(']) then
  begin
    H := nil;
    AddKid(H, Take);
    AddKid(H, QualifiedName);
    WantSym(H, [')']);
    AddKid(K, NewNode(nkHeritage, H));
  end;
  AddKid(K, FieldList(True));
  WantKw(K, 'end');
  Result := NewNode(nkObjectType, K);
end;

function TParser.FieldList(Methods: Boolean): TNode;
var
  K, F: TKids;
  P: SizeInt;
  Tk: TToken;
begin
  K := nil;
  while True do
  begin
    P := I;
    if Kw(['case']) then
    begin
      AddKid(K, VariantPart);
      Break;
    end
    else if Methods and Kw(['procedure', 'function', 'constructor', 'destructor']) then
      AddKid(K, Routine(True))
    else if Methods and Idn(['private', 'public']) and not Sym([':', ','], 1) then
    begin
      Tk := Take;
      AddKid(K, NewNode(nkSection, [Tk]));
    end
    else if Ident then
    begin
      F := nil;
      AddKid(F, DeclName);
      while Sym([',']) do
      begin
        AddKid(F, Take);
        AddKid(F, DeclName);
      end;
      WantSym(F, [':']);
      AddKid(F, TypeSpec());
      AddKid(K, NewNode(nkFieldDecl, F));
      if Sym([';']) then
        AddKid(K, Take);
    end
    else if Sym([';']) then
      AddKid(K, Take)
    else
      Break;
    if I = P then
      Break;
  end;
  Result := NewNode(nkFieldList, K);
end;

function TParser.VariantPart: TNode;
var
  K, V: TKids;
  P: SizeInt;
begin
  K := nil;
  AddKid(K, Take);
  if Ident and Sym([':'], 1) then
  begin
    AddKid(K, DeclName);
    AddKid(K, Take);
  end;
  AddKid(K, TypeSpec());
  WantKw(K, 'of');
  while not Eof and not Kw(['end']) and not Sym([')']) do
  begin
    P := I;
    V := nil;
    AddKid(V, LabelList);
    WantSym(V, [':']);
    WantSym(V, ['(']);
    AddKid(V, FieldList);
    WantSym(V, [')']);
    AddKid(K, NewNode(nkVariant, V));
    if Sym([';']) then
      AddKid(K, Take);
    if I = P then
      AddKid(K, ErrorSkip);
  end;
  Result := NewNode(nkVariantPart, K);
end;

function TParser.LabelList: TNode;
var
  K: TKids;
begin
  K := nil;
  while True do
  begin
    AddKid(K, Expr);
    if Sym(['..']) then
    begin
      AddKid(K, Take);
      AddKid(K, Expr);
    end;
    if not Sym([',']) then
      Break;
    AddKid(K, Take);
  end;
  Result := NewNode(nkLabels, K);
end;

function TParser.Compound: TNode;
var
  K: TKids;
begin
  K := nil;
  AddKid(K, Take);
  AddKid(K, StmtList(['end']));
  WantKw(K, 'end');
  Result := NewNode(nkCompound, K);
end;

function TParser.AsmBlock: TNode;
var
  K: TKids;
begin
  K := nil;
  AddKid(K, Take);
  while not Eof and not Kw(['end']) do
    AddKid(K, Take);
  WantKw(K, 'end');
  Result := NewNode(nkAsm, K);
end;

function TParser.AtStop(const Stops: array of string): Boolean;
begin
  Result := Eof or Kw(Stops) or Kw(DeclKw);
end;

function TParser.StmtList(const Stops: array of string): TNode;
var
  K: TKids;
  P: SizeInt;
  Last: TNode;
begin
  K := nil;
  while not AtStop(Stops) do
  begin
    P := I;
    Last := Statement();
    AddKid(K, Last);
    if (Last.Kind = nkError) and (Length(Last.Kids) = 1) and (Last.Kids[0] is TToken)
      and SameText(TToken(Last.Kids[0]).Text, 'else') then
      Continue;
    if Sym([';']) then
      AddKid(K, Take)
    else if AtStop(Stops) then
      Break
    else if I = P then
    begin
      Diag('statement expected');
      AddKid(K, ErrorSkip);
    end
    else
      Diag('expected '';''');
  end;
  if Kw(DeclKw) and not Eof then
    Diag('unexpected ''' + Cur.Text + ''' inside a statement list (missing ''end''?)');
  Result := NewNode(nkStmtList, K);
end;

function TParser.Statement: TNode;
var
  Tk, A, B: TToken;
  W, Msg: string;
  K: TKids;
  S, D, E: TNode;
begin
  Enter;
  Tk := Cur;
  K := nil;
  Result := nil;
  if (Tk.Kind in [tkInt, tkIdent]) and Sym([':'], 1) then
  begin
    A := Take;
    B := Take;
    S := Statement();
    Result := NewNode(nkLabeled, [A, B, S]);
  end
  else if Tk.Kind = tkKW then
  begin
    W := Tk.Lower;
    if W = 'begin' then
      Result := Compound
    else if W = 'if' then
    begin
      AddKid(K, Take);
      AddKid(K, Expr);
      WantKw(K, 'then');
      if Kw(['else']) then
        AddKid(K, NewNode(nkEmpty, []))
      else
        AddKid(K, Statement());
      if Kw(['else']) then
      begin
        AddKid(K, Take);
        AddKid(K, Statement());
      end;
      Result := NewNode(nkIf, K);
    end
    else if W = 'while' then
    begin
      AddKid(K, Take);
      AddKid(K, Expr);
      WantKw(K, 'do');
      AddKid(K, Statement());
      Result := NewNode(nkWhile, K);
    end
    else if W = 'repeat' then
    begin
      AddKid(K, Take);
      AddKid(K, StmtList(['until']));
      WantKw(K, 'until');
      AddKid(K, Expr);
      Result := NewNode(nkRepeat, K);
    end
    else if W = 'for' then
    begin
      AddKid(K, Take);
      AddKid(K, Name);
      WantSym(K, [':=']);
      AddKid(K, Expr);
      if Kw(['to', 'downto']) then
        AddKid(K, Take)
      else
        Diag('expected ''to'' or ''downto''');
      AddKid(K, Expr);
      WantKw(K, 'do');
      AddKid(K, Statement());
      Result := NewNode(nkFor, K);
    end
    else if W = 'case' then
      Result := CaseStmt
    else if W = 'with' then
    begin
      AddKid(K, Take);
      AddKid(K, Designator);
      while Sym([',']) do
      begin
        AddKid(K, Take);
        AddKid(K, Designator);
      end;
      WantKw(K, 'do');
      AddKid(K, Statement());
      Result := NewNode(nkWith, K);
    end
    else if W = 'goto' then
    begin
      AddKid(K, Take);
      if Cur.Kind in [tkInt, tkIdent] then
        AddKid(K, Take)
      else
        Diag('label expected');
      Result := NewNode(nkGoto, K);
    end
    else if W = 'asm' then
      Result := AsmBlock
    else if W = 'inline' then
      Result := InlineCode
    else if W = 'inherited' then
      Result := Inherited_
    else if (W = 'end') or (W = 'until') or (W = 'else') then
    begin
      if W = 'else' then
      begin
        Msg := 'unexpected ''else''';
        if (I > 0) and (T[I - 1].Text = ';') then
          Msg := Msg + ' (the '';'' before ''else'' ended the if statement: remove it)';
        Diag(Msg);
        A := Take;
        Result := NewNode(nkError, [A]);
      end
      else
        Result := NewNode(nkEmpty, []);
    end
    else
    begin
      Diag('statement expected');
      if not Kw(DeclKw) then
      begin
        A := Take;
        Result := NewNode(nkError, [A]);
      end
      else
        Result := NewNode(nkEmpty, []);
    end;
  end
  else if Tk.Kind = tkIdent then
  begin
    D := Designator;
    if Sym([':=']) then
    begin
      A := Take;
      E := Expr;
      Result := NewNode(nkAssign, [D, A, E]);
    end
    else
      Result := NewNode(nkProcCall, [D]);
  end
  else if ((Tk.Kind = tkSym) and (Tk.Text = ';')) or (Tk.Kind = tkEOF) then
    Result := NewNode(nkEmpty, [])
  else
  begin
    Diag('statement expected');
    A := Take;
    Result := NewNode(nkError, [A]);
  end;
  Leave;
end;

function TParser.Inherited_: TNode;
var
  K: TKids;
begin
  K := nil;
  AddKid(K, Take);
  if Ident then
    AddKid(K, Designator);
  Result := NewNode(nkInherited, K);
end;

function TParser.CaseStmt: TNode;
var
  K, B, E: TKids;
  P: SizeInt;
begin
  K := nil;
  AddKid(K, Take);
  AddKid(K, Expr);
  WantKw(K, 'of');
  while not Eof and not Kw(['end', 'else']) and not Kw(DeclKw) do
  begin
    P := I;
    B := nil;
    AddKid(B, LabelList);
    WantSym(B, [':']);
    AddKid(B, Statement());
    AddKid(K, NewNode(nkCaseBranch, B));
    if Sym([';']) then
      AddKid(K, Take)
    else if not Kw(['end', 'else']) then
      Diag('expected '';''');
    if I = P then
      AddKid(K, ErrorSkip);
  end;
  if Kw(['else']) then
  begin
    E := nil;
    AddKid(E, Take);
    AddKid(E, StmtList(['end']));
    AddKid(K, NewNode(nkCaseElse, E));
  end;
  WantKw(K, 'end');
  Result := NewNode(nkCase, K);
end;

function TParser.Expr: TNode;
var
  Op: TToken;
  R: TNode;
begin
  Enter;
  Result := SimpleExpr;
  while Kw(['in']) or Sym(RelOps) do
  begin
    Op := Take;
    R := SimpleExpr;
    Result := NewNode(nkBinary, [Result, Op, R]);
  end;
  Leave;
end;

function TParser.SimpleExpr: TNode;
var
  Op: TToken;
  R: TNode;
begin
  if Sym(['+', '-']) then
  begin
    Op := Take;
    R := Term;
    Result := NewNode(nkUnary, [Op, R]);
  end
  else
    Result := Term;
  while Sym(['+', '-']) or Kw(['or', 'xor']) do
  begin
    Op := Take;
    R := Term;
    Result := NewNode(nkBinary, [Result, Op, R]);
  end;
end;

function TParser.Term: TNode;
var
  Op: TToken;
  R: TNode;
begin
  Result := Factor();
  while Sym(['*', '/']) or Kw(['div', 'mod', 'and', 'shl', 'shr']) do
  begin
    Op := Take;
    R := Factor();
    Result := NewNode(nkBinary, [Result, Op, R]);
  end;
end;

function TParser.Factor: TNode;
var
  Tk, Op: TToken;
  W: string;
  K: TKids;
  R: TNode;
begin
  Enter;
  Tk := Cur;
  K := nil;
  Result := nil;
  case Tk.Kind of
    tkKW:
      begin
        W := Tk.Lower;
        if W = 'not' then
        begin
          Op := Take;
          R := Factor();
          Result := NewNode(nkUnary, [Op, R]);
        end
        else if W = 'nil' then
        begin
          Op := Take;
          Result := NewNode(nkLiteral, [Op]);
        end
        else if W = 'inherited' then
          Result := Inherited_;
      end;
    tkSym:
      if (Tk.Text = '@') or (Tk.Text = '+') or (Tk.Text = '-') then
      begin
        Op := Take;
        R := Factor();
        Result := NewNode(nkUnary, [Op, R]);
      end
      else if Tk.Text = '(' then
      begin
        AddKid(K, Take);
        AddKid(K, Expr);
        WantSym(K, [')']);
        Result := NewNode(nkParen, K);
      end
      else if (Tk.Text = '[') or (Tk.Text = '(.') then
        Result := SetCtor;
    tkInt, tkHex, tkReal:
      begin
        Op := Take;
        Result := NewNode(nkLiteral, [Op]);
      end;
    tkString, tkCharCode:
      begin
        AddKid(K, Take);
        while (Cur.Kind in [tkString, tkCharCode]) and (Cur.Leading = nil) do
          AddKid(K, Take);
        Result := NewNode(nkStringLit, K);
      end;
    tkIdent:
      Result := Designator;
  end;
  if Result = nil then
  begin
    Diag('expression expected');
    Result := NewNode(nkError, []);
  end;
  Leave;
end;

function TParser.SetCtor: TNode;
var
  K: TKids;
  P: SizeInt;
begin
  K := nil;
  AddKid(K, Take);
  while not Eof and not Rbr do
  begin
    P := I;
    AddKid(K, Expr);
    if Sym(['..']) then
    begin
      AddKid(K, Take);
      AddKid(K, Expr);
    end;
    if Sym([',']) then
      AddKid(K, Take)
    else if not Rbr then
    begin
      Diag('expected '','' or '']''');
      AddKid(K, ErrorSkip(stBracket));
    end;
    if I = P then
      AddKid(K, ErrorSkip);
  end;
  if Rbr then
    AddKid(K, Take)
  else
    Diag('expected '']''');
  Result := NewNode(nkSetCtor, K);
end;

function TParser.Designator: TNode;
var
  K, Sub, G: TKids;
  P: SizeInt;
  A, B: TToken;
begin
  K := nil;
  AddKid(K, Name);
  while True do
    if Sym(['.']) and Ident(1) then
    begin
      A := Take;
      B := Take;
      AddKid(K, NewNode(nkField, [A, B]));
    end
    else if Lbr then
    begin
      Sub := nil;
      AddKid(Sub, Take);
      while not Eof and not Rbr do
      begin
        P := I;
        AddKid(Sub, Expr);
        if Sym([',']) then
          AddKid(Sub, Take)
        else if not Rbr then
        begin
          Diag('expected '','' or '']''');
          AddKid(Sub, ErrorSkip(stBracket));
        end;
        if I = P then
          AddKid(Sub, ErrorSkip);
      end;
      if Rbr then
        AddKid(Sub, Take)
      else
        Diag('expected '']''');
      AddKid(K, NewNode(nkIndex, Sub));
    end
    else if Sym(['^']) then
    begin
      A := Take;
      AddKid(K, NewNode(nkDeref, [A]));
    end
    else if Sym(['(']) then
    begin
      Sub := nil;
      AddKid(Sub, Take);
      while not Eof and not Sym([')']) do
      begin
        P := I;
        G := nil;
        AddKid(G, Expr);
        while Sym([':']) do
        begin
          AddKid(G, Take);
          AddKid(G, Expr);
        end;
        AddKid(Sub, NewNode(nkArg, G));
        if Sym([',']) then
          AddKid(Sub, Take)
        else if not Sym([')']) then
        begin
          Diag('expected '','' or '')''');
          AddKid(Sub, ErrorSkip(stArgs));
        end;
        if I = P then
          AddKid(Sub, ErrorSkip);
      end;
      WantSym(Sub, [')']);
      AddKid(K, NewNode(nkArgs, Sub));
    end
    else
      Break;
  Result := NewNode(nkDesignator, K);
end;

{ entry points }

function Parse(const Src: string): TParseResult;
begin
  Result := Parse(Src, DefaultDefines);
end;

function Parse(const Src: string; const Defines: array of string; Include: TIncludeResolver;
  const Path: string): TParseResult;
var
  Sig: TTokens;
  Diags: TDiags;
  Includes: TIncludes;
  P: TParser;
  J: SizeInt;
  Flat: TKids;
begin
  Result := TParseResult.Create;
  Result.Source := Src;
  Result.Tokens := Lex(Src);
  for J := 0 to High(Result.Tokens) do
    Result.Tokens[J].Idx := J;
  Prepare(Result.Tokens, Defines, Include, Path, Result.FIncluded, Sig, Diags, Includes);
  Result.Sig := Sig;
  Result.Includes := Includes;
  P := TParser.Create(Sig, Diags, Result.FNodes);
  try
    try
      Result.Tree := P.ParseFile;
    except
      on ENestingTooDeep do
      begin
        P.AddDiag(Sig[0], 'nesting too deep');
        Flat := nil;
        for J := 0 to High(Sig) - 1 do
          AddKid(Flat, Sig[J]);
        Result.Tree := P.NewNode(nkFile, [P.NewNode(nkError, Flat)]);
      end;
    end;
    Result.Diags := P.Diags;
  finally
    P.Free;
  end;
end;

function Reconstruct(R: TParseResult): string;
var
  Parts: TStringList;
  T, L: TToken;
begin
  Parts := TStringList.Create;
  try
    for T in Concat(R.Tree.Tokens, [R.Sig[High(R.Sig)]]) do
    begin
      for L in T.Leading do
        Parts.Add(L.Text);
      Parts.Add(T.Text);
    end;
    Parts.LineBreak := '';
    Parts.SkipLastLineBreak := True;
    Result := Parts.Text;
  finally
    Parts.Free;
  end;
end;

end.
