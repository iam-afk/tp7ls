unit tp7sema;

{$mode objfpc}{$H+}

interface

uses
  Classes, Contnrs, SysUtils, tp7lex, tp7parse, tpudump, tp7index, tp7maps, tp7os;

type
  EBroken = class(Exception);

  TSymKind = (skVar, skConst, skType, skRoutine, skParam, skField, skEnum, skLabel, skUnit, skBuiltin);
  TTInfoKind = (tiRecord, tiArray, tiPointer, tiString, tiPrim, tiUnknown);
  TTfKind = (tfUnknown, tfPrim, tfLibDesc, tfNode, tfResult, tfFixed);
  TMembersFrom = (mfNone, mfSource, mfLibRecord, mfLibObject);
  TComputeState = (csNone, csBusy, csDone);

  TSym = class;
  TTInfo = class;
  TScope = class;
  TUnitInfo = class;
  TProvider = class;
  TBinder = class;
  TSymTable = TStrMap;
  TSyms = array of TSym;

  TSym = class
  public
    Name: string;
    Kind: TSymKind;
    Tok: TToken;
    TNode: TObject;
    Scope: TScope;
    Node: TNode;
    UnitInfo: TUnitInfo;
    Params: TSyms;
    ParamsScope: TScope;
    Home: string;
    TypeTok: TToken;
    Lib: Boolean;
    StubOwner: string;
    HasTypeRef: Boolean;
    TypeRefUnit, TypeRefName: string;
    FileName: string;
    ImplTok: TToken;
    TDesc: TTypeDesc;
    LParams: TParams;
    HasLParams: Boolean;
    CValueKind: TValueKind;
    CInt: Int64;
    CStr: string;
    CDisplay: string;
    TypedConst: Boolean;
    Binder: TBinder;
    MethodKind: string;
    Owner: TSym;
    Implicit: Boolean;
    HasBody: Boolean;
    HeaderParams: TNode;
    TfKind: TTfKind;
    TfDesc: TTypeDesc;
    TfDepth: Integer;
    TfHome, TfOwner: string;
    TfProv: TProvider;
    TfNode: TObject;
    TfScope: TScope;
    TfBinder: TBinder;
    TfFixed: TTInfo;
    T: TTInfo;
    Busy: Boolean;
    constructor Create(const AName: string; AKind: TSymKind; ATok: TToken = nil; ATNode: TObject = nil;
      AScope: TScope = nil; ANode: TNode = nil);
  end;

  TTInfo = class
  private
    FFields, FOwn: TSymTable;
    FFieldsState, FOwnState: TComputeState;
    FElem, FTarget: TTInfo;
    FElemDone, FTargetDone: Boolean;
    function BuildFields: TSymTable;
    function BuildOwn: TSymTable;
  public
    Kind: TTInfoKind;
    Obj: Boolean;
    Node: TNode;
    Dims: Integer;
    Arena: TObjectList;
    Binder: TBinder;
    Scope: TScope;
    Members: TMembersFrom;
    HerName: TNode;
    PtrName: TNode;
    ElemNode: TObject;
    ElemFrom: TTInfo;
    Prov: TProvider;
    Desc: TTypeDesc;
    Depth: Integer;
    Home, Owner: string;
    LibAnc: TTypeDesc;
    constructor Create(AKind: TTInfoKind; AArena: TObjectList);
    function GetFields: TSymTable;
    function GetOwn: TSymTable;
    function GetAncestor: TTInfo;
    function GetTarget: TTInfo;
    function Elem: TTInfo;
  end;

  TUnitInfos = array of TUnitInfo;

  TScope = class
  public
    Table: TSymTable;
    Parent: TScope;
    Units: TUnitInfos;
    function Lookup(const Key: string): TSym;
  end;

  TUnitInfo = class
  public
    Name: string;
    Exports_: TSymTable;
    Path: string;
    Tpu: TUnit;
    Origin: string;
  end;

  TIncludeFinder = class
  public
    Prov: TProvider;
    BasePath: string;
    function Resolve(const Name, FromPath: string; out Path, Text: string): Boolean;
  end;

  TTextHolder = class
  public
    Text: string;
  end;

  TStampEntry = record
    Path: string;
    St: TStamp;
  end;

  TProvider = class
  private
    FArena: TObjectList;
    FCache: TStrMap;
    FCacheHas: TStringList;
    FLoading: TStringList;
    FStd: TLoader;
    function Keep(O: TObject): TObject;
    function NewSym(const AName: string; AKind: TSymKind): TSym;
    function NewTable: TSymTable;
    function NewTInfo(AKind: TTInfoKind): TTInfo;
    procedure SetStamp(const Path: string);
    function FindFile(const Key, Ext, First: string; Deep: Boolean; const Near: string): string;
    function FromSource(const Key: string): TUnitInfo;
    function FromTpuFile(const Key: string): TUnitInfo;
    function TpuDependencies(const Imgs: TImages; const Home: string): TImages;
    function FromTpuUnit(U: TUnit; const Origin: string): TUnitInfo;
  public
    Dirs: TStringArray;
    Near: string;
    Index: TProjectIndex;
    IndexGen: Integer;
    Overlay: TStrMap;
    Errors: TStringList;
    Warnings: TStringList;
    LibImages: TImages;
    StdNames: TStringArray;
    TplPath: string;
    Stamps: array of TStampEntry;
    DirStamps: array of TStampEntry;
    constructor Create(const ADirs: array of string; const ATpl: string = ''; AIndex: TProjectIndex = nil);
    destructor Destroy; override;
    function StillValid: Boolean;
    function System_: TUnitInfo;
    function UnitNames: TStringArray;
    function Get(const Name: string): TUnitInfo;
    function IncludeResolver(const BasePath: string = ''): TIncludeResolver;
    function ReadText(const Path: string): string;
    procedure SetOverlay(const Path, Text: string);
    procedure ClearOverlay(const Path: string);
    function TInfoFromTDesc(TD: TTypeDesc; Depth: Integer = 0; const Home: string = ''; const Owner: string = ''): TTInfo;
  end;

  TSymNodePair = record
    Node: TNode;
    Scope: TScope;
  end;

  TDup = record
    Tok: TToken;
    Old: TSym;
  end;

  TWiths = array of TTInfo;

  TChainKind = (ckName, ckIndex, ckDeref, ckCall);

  TChainStep = record
    Kind: TChainKind;
    Text: string;
    N: Integer;
  end;

  TChain = array of TChainStep;

  TBinder = class
  private
    FArena: TObjectList;
    FTiCache: TPtrMap;
    function Keep(O: TObject): TObject;
    function NewScope(ATable: TSymTable; AParent: TScope): TScope;
    function NewTable: TSymTable;
    function NewTInfo(AKind: TTInfoKind): TTInfo;
    procedure Rewrite(Tok: TToken; Sym: TSym);
    function SystemScope: TScope;
    function UsesScope(Uses_: TNode; Parent: TScope): TScope;
    function TiNodeUncached(Node: TObject; Scope: TScope): TTInfo;
    function TypeTi(Sym: TSym): TTInfo;
    procedure NoteDecl(Tok: TToken; Sym: TSym);
    function MakeSym(Tok: TToken; Kind: TSymKind; TNode: TObject; Scope: TScope; Node: TNode = nil): TSym;
    procedure Declare(Scope: TScope; Sym: TSym);
    procedure Collect(const Items: TNodes; Scope: TScope; LinkTable: TSymTable = nil);
    procedure CollectDecl(K: TNodeKind; D: TNode; Scope: TScope);
    procedure DeclareEnums(TN: TNode; Scope: TScope; Owner: TToken = nil);
    procedure RoutineParts(R: TNode; out NameTok: TToken; out Params, Res: TNode);
    procedure MethodOf(R: TNode; Scope: TScope; LinkTable: TSymTable; out TSym_, M: TSym);
    procedure CollectRoutine(R: TNode; Scope: TScope; LinkTable: TSymTable);
    procedure ResolveDecls(const Items: TNodes; Scope: TScope);
    procedure ResolveDecl(K: TNodeKind; D: TNode; Scope: TScope);
    procedure ResolveHeader(R: TNode; Scope: TScope);
    procedure BindBodies(const Items: TNodes; Scope: TScope);
    procedure BindRoutine(R: TNode; Scope: TScope);
    procedure DeclareParams(Params: TNode; Into, TScope_: TScope);
    procedure ResolveType(Node: TObject; Scope: TScope);
    procedure NoteFieldDecl(NameNode: TNode);
    procedure ResolveFieldList(FL: TNode; Scope: TScope);
    procedure ResolveStmt(S: TNode; Scope: TScope; const Withs: TWiths);
    function LookupTokens(Tok: TToken; Scope: TScope; const Withs: TWiths): TSym;
    function ValueType(Sym: TSym; Cur: TTInfo): TTInfo;
    function Peel(T: TTInfo; N: Integer): TTInfo;
    function PointeeMembers(Args: TNode; Scope: TScope; const Withs: TWiths): TSymTable;
    function ValuePeek(D: TNode; Scope: TScope; const Withs: TWiths): TTInfo;
    procedure ResolveValue(V: TObject; T: TTInfo; Scope: TScope; const Withs: TWiths);
    procedure RunUnit(U: TNode);
    procedure RunProgram(P: TNode);
  public
    Res: TParseResult;
    Provider: TProvider;
    ExportOnly: Boolean;
    Unresolved, Uncertain, MissingUnits: TTokens;
    Renamed: Integer;
    IfaceTable: TSymTable;
    Links: TPtrMap;
    Path: string;
    Refs: TPtrMap;
    Decls: TPtrMap;
    Owners: TPtrMap;
    NodeScopes: array of TSymNodePair;
    Dups: array of TDup;
    CurTi: TTInfo;
    constructor Create(ARes: TParseResult; AProvider: TProvider; AExportOnly: Boolean = False);
    destructor Destroy; override;
    function TiNode(Node: TObject; Scope: TScope): TTInfo;
    function RecordTi(Node: TNode; Scope: TScope): TTInfo;
    function PtrTarget(NameNode: TNode; Scope: TScope): TTInfo;
    function TypeSym(NameNode: TObject; Scope: TScope; DoRewrite: Boolean = False): TSym;
    procedure Note(Tok: TToken; Sym: TSym);
    function BuildMembers(Rec: TNode; Scope: TScope): TSymTable;
    function ResultTi(RSym: TSym): TTInfo;
    function Find(const Key: string; Scope: TScope; const Withs: TWiths): TSym;
    function ResolveExpr(E: TObject; Scope: TScope; const Withs: TWiths): TTInfo;
    function Designator(D: TNode; Scope: TScope; const Withs: TWiths; Members: TSymTable = nil;
      HasMembers: Boolean = False): TTInfo;
    procedure ChainType(const Chain: TChain; Scope: TScope; out U: TUnitInfo; out T: TTInfo);
    procedure Run;
  end;

  TReport = record
    Renamed: Integer;
    Unresolved, Uncertain, MissingUnits: TTokens;
  end;

const
  SymKindNames: array[TSymKind] of string = ('var', 'const', 'type', 'routine', 'param', 'field', 'enum', 'label',
    'unit', 'builtin');
  TInfoKindNames: array[TTInfoKind] of string = ('record', 'array', 'pointer', 'string', 'prim', 'unknown');

var
  UnknownTi, PrimTi, StringTi: TTInfo;
  UncertainSym: TSym;

function TiOfSym(Sym: TSym): TTInfo;
function LabelKey(const Text: string): string;
function NormalizeCase(Res: TParseResult; Provider: TProvider): TReport;
function NormalizeCaseKeep(Res: TParseResult; Provider: TProvider; out Binder: TBinder): TReport;
procedure LoadLibrary(const Tpl: string; out Images: TImages; out Loader: TLoader);

implementation

uses
  tp7enc;

var
  GlobalArena: TObjectList;
  EmptyTable: TSymTable;
  LibKey: string;
  LibStamp: TStamp;
  LibImages_: TImages;
  LibLoader: TLoader;

{ checked access: what a broken tree does to Python's indexing }

function Kid(N: TObject; I: Integer): TObject;
var
  K: TKids;
begin
  if not (N is TNode) then
    raise EBroken.Create('not a node');
  K := TNode(N).Kids;
  if I < 0 then
    I := Length(K) + I;
  if (I < 0) or (I >= Length(K)) then
    raise EBroken.Create('index out of range');
  Result := K[I];
end;

function KN(X: TObject): TNode;
begin
  if not (X is TNode) then
    raise EBroken.Create('not a node');
  Result := TNode(X);
end;

function KT(X: TObject): TToken;
begin
  if not (X is TToken) then
    raise EBroken.Create('not a token');
  Result := TToken(X);
end;

function IsNodeOf(X: TObject; Kind: TNodeKind): Boolean;
begin
  Result := (X is TNode) and (TNode(X).Kind = Kind);
end;

function IsTok(X: TObject; const Text: string): Boolean;
begin
  Result := (X is TToken) and (TToken(X).Lower = Text);
end;

function FirstKid(N: TNode; Kind: TNodeKind): TNode;
var
  K: TObject;
begin
  for K in N.Kids do
    if IsNodeOf(K, Kind) then
      Exit(TNode(K));
  Result := nil;
end;

function NodeKidsExcept(N: TNode; const Skip: array of TNodeKind): TNodes;
var
  K: TObject;
  S: TNodeKind;
  Ok: Boolean;
begin
  Result := nil;
  for K in N.Kids do
    if K is TNode then
    begin
      Ok := True;
      for S in Skip do
        if TNode(K).Kind = S then
          Ok := False;
      if Ok then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := TNode(K);
      end;
    end;
end;

procedure PushTok(var A: TTokens; T: TToken);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := T;
end;

function Strs2(const A, B: string): TStringArray;
begin
  Result := nil;
  SetLength(Result, 2);
  Result[0] := A;
  Result[1] := B;
end;

function LabelKey(const Text: string): string;
var
  C: Char;
  I: Integer;
begin
  if Text = '' then
    Exit('');
  for C in Text do
    if not (C in ['0'..'9']) then
      Exit(LowerText(Text));
  I := 1;
  while (I < Length(Text)) and (Text[I] = '0') do
    Inc(I);
  Result := Copy(Text, I, MaxInt);
end;

{ TSym }

constructor TSym.Create(const AName: string; AKind: TSymKind; ATok: TToken; ATNode: TObject; AScope: TScope;
  ANode: TNode);
begin
  Name := AName;
  Kind := AKind;
  Tok := ATok;
  TNode := ATNode;
  Scope := AScope;
  Node := ANode;
end;

function TiOfSym(Sym: TSym): TTInfo;
begin
  if Sym.T <> nil then
    Exit(Sym.T);
  if Sym.Busy then
    Exit(UnknownTi);
  Sym.Busy := True;
  try
    case Sym.TfKind of
      tfPrim:
        Result := PrimTi;
      tfLibDesc:
        Result := Sym.TfProv.TInfoFromTDesc(Sym.TfDesc, Sym.TfDepth, Sym.TfHome, Sym.TfOwner);
      tfNode:
        Result := Sym.TfBinder.TiNode(Sym.TfNode, Sym.TfScope);
      tfResult:
        Result := Sym.TfBinder.ResultTi(Sym);
      tfFixed:
        Result := Sym.TfFixed;
    else
      Result := UnknownTi;
    end;
    Sym.T := Result;
  finally
    Sym.Busy := False;
  end;
end;

{ TTInfo }

constructor TTInfo.Create(AKind: TTInfoKind; AArena: TObjectList);
begin
  Kind := AKind;
  Arena := AArena;
  Dims := 1;
end;

function TTInfo.BuildOwn: TSymTable;
var
  F: TFieldInfo;
  M: TMethodInfo;
  S: TSym;
begin
  if Members = mfSource then
    Exit(Binder.BuildMembers(Node, Scope));
  Result := TSymTable.Create;
  Arena.Add(Result);
  if Members <> mfLibObject then
    Exit;
  for F in Desc.Fields do
  begin
    if F.Private_ then
      Continue;
    S := TSym.Create(F.Name, skField);
    Arena.Add(S);
    S.Lib := True;
    S.TDesc := F.TypeDesc;
    S.Home := Home;
    S.StubOwner := Owner;
    if (F.TypeDesc <> nil) and (F.TypeDesc.Kind = tdNamed) and (F.TypeDesc.Name <> '') and (F.TypeDesc.UnitOf <> '') then
    begin
      S.HasTypeRef := True;
      S.TypeRefUnit := F.TypeDesc.UnitOf;
      S.TypeRefName := F.TypeDesc.Name;
    end;
    S.TfKind := tfLibDesc;
    S.TfProv := Prov;
    S.TfDesc := F.TypeDesc;
    S.TfDepth := Depth + 1;
    Result.Put(LowerText(F.Name), S);
  end;
  for M in Desc.Methods do
  begin
    if M.Private_ then
      Continue;
    S := TSym.Create(M.Name, skRoutine);
    Arena.Add(S);
    S.Lib := True;
    S.TDesc := M.Result;
    S.LParams := M.Params;
    S.HasLParams := True;
    S.Home := Home;
    S.StubOwner := Owner;
    S.MethodKind := M.Kind;
    if M.Result <> nil then
    begin
      if (M.Result.Kind = tdNamed) and (M.Result.Name <> '') and (M.Result.UnitOf <> '') then
      begin
        S.HasTypeRef := True;
        S.TypeRefUnit := M.Result.UnitOf;
        S.TypeRefName := M.Result.Name;
      end;
      S.TfKind := tfLibDesc;
      S.TfProv := Prov;
      S.TfDesc := M.Result;
      S.TfDepth := Depth + 1;
    end
    else
      S.TfKind := tfUnknown;
    Result.Put(LowerText(M.Name), S);
  end;
end;

function TTInfo.BuildFields: TSymTable;
var
  F: TFieldInfo;
  S: TSym;
  A: TTInfo;
  AF: TSymTable;
  I: Integer;
begin
  Result := TSymTable.Create;
  Arena.Add(Result);
  if Members = mfLibRecord then
  begin
    for F in Desc.Fields do
    begin
      S := TSym.Create(F.Name, skField);
      Arena.Add(S);
      S.Lib := True;
      S.TDesc := F.TypeDesc;
      S.Home := Home;
      S.StubOwner := Owner;
      if (F.TypeDesc <> nil) and (F.TypeDesc.Kind = tdNamed) and (F.TypeDesc.Name <> '') and (F.TypeDesc.UnitOf <> '') then
      begin
        S.HasTypeRef := True;
        S.TypeRefUnit := F.TypeDesc.UnitOf;
        S.TypeRefName := F.TypeDesc.Name;
      end;
      S.TfKind := tfLibDesc;
      S.TfProv := Prov;
      S.TfDesc := F.TypeDesc;
      S.TfDepth := Depth + 1;
      Result.Put(LowerText(F.Name), S);
    end;
    Exit;
  end;
  Result.Assign(GetOwn);
  A := GetAncestor;
  if A <> nil then
  begin
    AF := A.GetFields;
    for I := 0 to AF.Count - 1 do
      Result.SetDefault(AF.KeyAt(I), AF.At(I));
  end;
end;

function TTInfo.GetFields: TSymTable;
begin
  if Members = mfNone then
    Exit(EmptyTable);
  case FFieldsState of
    csBusy:
      Exit(EmptyTable);
    csDone:
      Exit(FFields);
  end;
  FFieldsState := csBusy;
  try
    FFields := BuildFields;
  except
    FFields := EmptyTable;
    FFieldsState := csDone;
    raise;
  end;
  FFieldsState := csDone;
  Result := FFields;
end;

function TTInfo.GetOwn: TSymTable;
begin
  if not (Members in [mfSource, mfLibObject]) then
    Exit(GetFields);
  case FOwnState of
    csBusy:
      Exit(EmptyTable);
    csDone:
      Exit(FOwn);
  end;
  FOwnState := csBusy;
  try
    FOwn := BuildOwn;
  except
    FOwn := EmptyTable;
    FOwnState := csDone;
    raise;
  end;
  FOwnState := csDone;
  Result := FOwn;
end;

function TTInfo.GetAncestor: TTInfo;
var
  Sym: TSym;
  A: TTInfo;
begin
  Result := nil;
  if HerName <> nil then
  begin
    Sym := Binder.TypeSym(HerName, Scope);
    if (Sym <> nil) and (Sym.Kind = skType) then
      A := TiOfSym(Sym)
    else
      A := nil;
    if (A <> nil) and (A.Kind = tiRecord) then
      Result := A;
  end
  else if LibAnc <> nil then
  begin
    A := Prov.TInfoFromTDesc(LibAnc, Depth + 1);
    if (A <> nil) and (A.Kind = tiRecord) then
      Result := A;
  end;
end;

function TTInfo.GetTarget: TTInfo;
begin
  if Kind <> tiPointer then
    Exit(nil);
  if PtrName <> nil then
    Exit(Binder.PtrTarget(PtrName, Scope));
  if Desc = nil then
    Exit(nil);
  if not FTargetDone then
  begin
    FTarget := Prov.TInfoFromTDesc(Desc.Target, Depth + 1);
    FTargetDone := True;
  end;
  Result := FTarget;
end;

function TTInfo.Elem: TTInfo;
begin
  if ElemFrom <> nil then
    Exit(ElemFrom.Elem);
  if Binder <> nil then
    Exit(Binder.TiNode(ElemNode, Scope));
  if not FElemDone then
  begin
    FElem := Prov.TInfoFromTDesc(Desc.Elem, Depth + 1);
    FElemDone := True;
  end;
  Result := FElem;
end;

{ TScope }

function TScope.Lookup(const Key: string): TSym;
var
  S: TScope;
  I: Integer;
begin
  S := Self;
  while S <> nil do
  begin
    for I := High(S.Units) downto 0 do
    begin
      Result := TSym(S.Units[I].Exports_.Get(Key));
      if Result <> nil then
        Exit;
    end;
    Result := TSym(S.Table.Get(Key));
    if Result <> nil then
      Exit;
    S := S.Parent;
  end;
  Result := nil;
end;

{ the library cache }

procedure LoadLibrary(const Tpl: string; out Images: TImages; out Loader: TLoader);
var
  St: TStamp;
  Key: string;
begin
  St := Stamp(Tpl);
  Key := AbsPath(Tpl);
  if (LibLoader = nil) or (Key <> LibKey) or not SameStamp(St, LibStamp) then
  begin
    FreeAndNil(LibLoader);
    FreeImages(LibImages_);
    LibImages_ := ReadImages(Tpl);
    LibLoader := TLoader.Create(LibImages_);
    LibKey := Key;
    LibStamp := St;
  end;
  Images := LibImages_;
  Loader := LibLoader;
end;

function CiJoin(const Base, Rel: string): string;
var
  Cur, Part, Hit, N: string;
  Names: TStringArray;
begin
  Cur := Base;
  for Part in Rel.Split(['/']) do
  begin
    if (Part = '') or (Part = '.') then
      Continue;
    if Part = '..' then
    begin
      Cur := DirName(Cur);
      Continue;
    end;
    if not ListDir(Cur, Names) then
      Exit('');
    Hit := '';
    for N in Names do
      if LowerText(N) = LowerText(Part) then
      begin
        Hit := N;
        Break;
      end;
    if Hit = '' then
      Exit('');
    Cur := JoinPath(Cur, Hit);
  end;
  if IsFile(Cur) then
    Result := Cur
  else
    Result := '';
end;

{ TIncludeFinder }

function TIncludeFinder.Resolve(const Name, FromPath: string; out Path, Text: string): Boolean;
var
  Rel, Stripped, Root, Ext, D, P: string;
  Bases: TStringArray;
  I: Integer;
begin
  Result := False;
  Path := '';
  Text := '';
  Stripped := StripSpace(Name);
  if Stripped = '' then
    Exit(False);
  I := 1;
  while (I <= Length(Stripped)) and (Stripped[I] in ['''', '"']) do
    Inc(I);
  Stripped := Copy(Stripped, I, MaxInt);
  I := Length(Stripped);
  while (I > 0) and (Stripped[I] in ['''', '"']) do
    Dec(I);
  Stripped := Copy(Stripped, 1, I);
  Rel := FirstWord(Stripped);
  if Rel = '' then
    raise EBroken.Create('list index out of range');
  Rel := StringReplace(Rel, '\', '/', [rfReplaceAll]);
  SplitExt(Rel, Root, Ext);
  if Ext = '' then
    Rel := Rel + '.pas';
  Bases := nil;
  for P in Strs2(FromPath, BasePath) do
    if P <> '' then
    begin
      SetLength(Bases, Length(Bases) + 1);
      Bases[High(Bases)] := DirName(AbsPath(P));
    end;
  Bases := Concat(Bases, Prov.Dirs);
  for D in Bases do
  begin
    P := CiJoin(D, Rel);
    if P <> '' then
      try
        Text := Prov.ReadText(P);
        Path := P;
        Exit(True);
      except
        on EStreamError do
          Continue;
        on EInOutError do
          Continue;
      end;
  end;
  if Prov.Index <> nil then
  begin
    if FromPath <> '' then
      P := Prov.Index.FindFile(Rel, FromPath)
    else
      P := Prov.Index.FindFile(Rel, BasePath);
    if P <> '' then
      try
        Text := Prov.ReadText(P);
        Path := P;
        Exit(True);
      except
        on EStreamError do
          ;
        on EInOutError do
          ;
      end;
  end;
end;

{ TProvider }

constructor TProvider.Create(const ADirs: array of string; const ATpl: string; AIndex: TProjectIndex);
var
  D: string;
  I: Integer;
begin
  FArena := TObjectList.Create(True);
  FCache := TStrMap.Create;
  FCacheHas := TStringList.Create;
  FCacheHas.Sorted := True;
  FCacheHas.CaseSensitive := True;
  FLoading := TStringList.Create;
  FLoading.Sorted := True;
  FLoading.CaseSensitive := True;
  Overlay := TStrMap.Create;
  Errors := TStringList.Create;
  Warnings := TStringList.Create;
  Dirs := nil;
  for D in ADirs do
  begin
    SetLength(Dirs, Length(Dirs) + 1);
    Dirs[High(Dirs)] := D;
  end;
  Index := AIndex;
  if Index <> nil then
  begin
    Index.Refresh;
    IndexGen := Index.Generation;
  end;
  TplPath := ATpl;
  for D in Dirs do
  begin
    SetLength(DirStamps, Length(DirStamps) + 1);
    DirStamps[High(DirStamps)].Path := D;
    DirStamps[High(DirStamps)].St := Stamp(D);
  end;
  if ATpl <> '' then
  begin
    SetStamp(ATpl);
    LoadLibrary(ATpl, LibImages, FStd);
    StdNames := nil;
    for I := 0 to FStd.UnitCount - 1 do
    begin
      SetLength(StdNames, Length(StdNames) + 1);
      StdNames[High(StdNames)] := FStd.UnitKey(I);
    end;
  end;
end;

destructor TProvider.Destroy;
var
  I: Integer;
begin
  FArena.Free;
  FCache.Free;
  FCacheHas.Free;
  FLoading.Free;
  for I := 0 to Overlay.Count - 1 do
    Overlay.At(I).Free;
  Overlay.Free;
  Errors.Free;
  Warnings.Free;
  inherited Destroy;
end;

function TProvider.Keep(O: TObject): TObject;
begin
  FArena.Add(O);
  Result := O;
end;

function TProvider.NewSym(const AName: string; AKind: TSymKind): TSym;
begin
  Result := TSym(Keep(TSym.Create(AName, AKind)));
end;

function TProvider.NewTable: TSymTable;
begin
  Result := TSymTable(Keep(TSymTable.Create));
end;

function TProvider.NewTInfo(AKind: TTInfoKind): TTInfo;
begin
  Result := TTInfo(Keep(TTInfo.Create(AKind, FArena)));
  Result.Prov := Self;
end;

procedure TProvider.SetStamp(const Path: string);
var
  I: Integer;
begin
  for I := 0 to High(Stamps) do
    if Stamps[I].Path = Path then
    begin
      Stamps[I].St := Stamp(Path);
      Exit;
    end;
  SetLength(Stamps, Length(Stamps) + 1);
  Stamps[High(Stamps)].Path := Path;
  Stamps[High(Stamps)].St := Stamp(Path);
end;

function TProvider.StillValid: Boolean;
var
  E: TStampEntry;
begin
  if Index <> nil then
  begin
    Index.Refresh;
    if Index.Generation <> IndexGen then
      Exit(False);
  end;
  for E in Stamps do
    if not SameStamp(Stamp(E.Path), E.St) then
      Exit(False);
  for E in DirStamps do
    if not SameStamp(Stamp(E.Path), E.St) then
      Exit(False);
  Result := True;
end;

function TProvider.System_: TUnitInfo;
begin
  Result := Get('System');
end;

function TProvider.UnitNames: TStringArray;
var
  Seen: TStringList;
  N, D, Fn, Root, Ext, T: string;
  Names: TStringArray;
  U: TUnit;
  I, J: Integer;

  procedure Add(const Key, Value: string);
  begin
    if Seen.IndexOf(Key) >= 0 then
      Exit;
    Seen.Add(Key);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Value;
  end;

begin
  Result := nil;
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.CaseSensitive := True;
    for N in StdNames do
    begin
      U := FStd.FindUnit(N);
      if (U <> nil) and (U.Name <> '') then
        Add(N, U.Name)
      else
        Add(N, N);
    end;
    for D in Dirs do
    begin
      if not ListDir(D, Names) then
        Continue;
      for Fn in Names do
      begin
        SplitExt(Fn, Root, Ext);
        if (LowerText(Ext) = '.pas') or (LowerText(Ext) = '.tpu') then
          Add(LowerText(Root), Root);
      end;
    end;
    if Index <> nil then
      for Root in Index.UnitNames do
        Add(LowerText(Root), Root);
    for I := 0 to Overlay.Count - 1 do
    begin
      if Overlay.At(I) = nil then
        Continue;
      SplitExt(BaseName(Overlay.KeyAt(I)), Root, Ext);
      if LowerText(Ext) = '.pas' then
        Add(LowerText(Root), Root);
    end;
  finally
    Seen.Free;
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

function TProvider.Get(const Name: string): TUnitInfo;
var
  Key: string;
  U: TUnit;
begin
  Key := LowerText(Name);
  if FCacheHas.IndexOf(Key) >= 0 then
    Exit(TUnitInfo(FCache.Get(Key)));
  if FLoading.IndexOf(Key) >= 0 then
    Exit(nil);
  FLoading.Add(Key);
  try
    Result := nil;
    try
      if FStd <> nil then
      begin
        U := FStd.FindUnit(Key);
        if U <> nil then
          Result := FromTpuUnit(U, TplPath);
      end;
      if Result = nil then
      begin
        Result := FromSource(Key);
        if Result = nil then
          Result := FromTpuFile(Key);
      end;
    except
      on E: Exception do
      begin
        Result := nil;
        Errors.Add(Name + ': ' + E.ClassName + ': ' + E.Message);
      end;
    end;
    FCache.Put(Key, Result);
    FCacheHas.Add(Key);
  finally
    FLoading.Delete(FLoading.IndexOf(Key));
  end;
end;

function TProvider.FindFile(const Key, Ext, First: string; Deep: Boolean; const Near: string): string;
var
  Search, Names, All: TStringArray;
  D, Fn: string;
begin
  Search := nil;
  if First <> '' then
    Search := [First];
  Search := Concat(Search, Dirs);
  for D in Search do
    if ListDir(D, Names) then
      for Fn in Names do
        if LowerText(Fn) = Key + Ext then
          Exit(JoinPath(D, Fn));
  if Deep and (Index <> nil) then
  begin
    All := Index.FindUnitAll(Key, Ext, Near);
    if All <> nil then
    begin
      if Length(All) > 1 then
        Warnings.Add(Format('unit %s: %d files of that name in the project, using %s', [Key, Length(All), All[0]]));
      Exit(All[0]);
    end;
  end;
  Result := '';
end;

function TProvider.IncludeResolver(const BasePath: string): TIncludeResolver;
var
  F: TIncludeFinder;
begin
  F := TIncludeFinder(Keep(TIncludeFinder.Create));
  F.Prov := Self;
  F.BasePath := BasePath;
  Result := @F.Resolve;
end;

function TProvider.ReadText(const Path: string): string;
var
  H: TObject;
begin
  H := Overlay.Get(NormCase(AbsPath(Path)));
  if H <> nil then
    Exit(TTextHolder(H).Text);
  SetStamp(Path);
  Result := ReadSource(Path);
end;

procedure TProvider.SetOverlay(const Path, Text: string);
var
  Key: string;
  H: TObject;
begin
  Key := NormCase(AbsPath(Path));
  H := Overlay.Get(Key);
  if H = nil then
  begin
    H := TTextHolder.Create;
    Overlay.Put(Key, H);
  end;
  TTextHolder(H).Text := Text;
end;

procedure TProvider.ClearOverlay(const Path: string);
var
  Key: string;
  H: TObject;
begin
  Key := NormCase(AbsPath(Path));
  H := Overlay.Get(Key);
  if H <> nil then
  begin
    H.Free;
    Overlay.Put(Key, nil);
  end;
end;

function TProvider.FromSource(const Key: string): TUnitInfo;
var
  Path, Src: string;
  Res: TParseResult;
  Root: TObject;
  B: TBinder;
begin
  Path := FindFile(Key, '.pas', '', True, Near);
  if Path = '' then
    Exit(nil);
  Src := ReadText(Path);
  Res := TParseResult(Keep(Parse(Src, DefaultDefines, IncludeResolver(Path), Path)));
  if Res.Tree.Kids = nil then
    Exit(nil);
  Root := Res.Tree.Kids[0];
  if not IsNodeOf(Root, nkUnit) then
    Exit(nil);
  B := TBinder(Keep(TBinder.Create(Res, Self, True)));
  B.Path := Path;
  B.Run;
  Result := TUnitInfo(Keep(TUnitInfo.Create));
  Result.Name := KT(Kid(Kid(Root, 1), 0)).Text;
  Result.Exports_ := B.IfaceTable;
  Result.Path := Path;
end;

function TProvider.FromTpuFile(const Key: string): TUnitInfo;
var
  Path: string;
  Imgs, Deps: TImages;
  N, I: Integer;
  Ld: TLoader;
  U: TUnit;
  Keys: TStringArray;
begin
  Path := FindFile(Key, '.tpu', '', True, Near);
  if Path = '' then
    Exit(nil);
  SetStamp(Path);
  Imgs := ReadImages(Path);
  for I := 0 to High(Imgs) do
    Keep(Imgs[I]);
  if Imgs = nil then
    Exit(nil);
  N := Length(Imgs);
  Ld := nil;
  try
    Deps := TpuDependencies(Imgs, DirName(Path));
    Ld := TLoader.Create(Concat(Imgs, Deps, LibImages), N);
    Keep(Ld);
  except
    on E: Exception do
    begin
      Warnings.Add(Key + ': dependencies skipped: ' + E.ClassName + ': ' + E.Message);
      Ld := nil;
    end;
  end;
  if Ld = nil then
  begin
    Ld := TLoader.Create(Concat(Imgs, LibImages), N);
    Keep(Ld);
  end;
  U := Ld.FindUnit(Key);
  if U = nil then
  begin
    Keys := nil;
    for I := 0 to Ld.UnitCount - 1 do
      Keys := Concat(Keys, [Ld.UnitKey(I)]);
    SortStrings(Keys);
    Warnings.Add(Key + ': ' + Path + ' holds the units ' + string.Join(', ', Keys));
    Exit(nil);
  end;
  Result := FromTpuUnit(U, Path);
end;

function OwnUnitName(Im: TImage; out Name: string): Boolean;
var
  R: TRec;
  Best: Integer;
begin
  Best := -1;
  Name := '';
  for R in Im.Records do
    if (R.Tag = 'S') and ((Best < 0) or (R.Off < Best)) then
    begin
      Best := R.Off;
      Name := R.Name;
    end;
  Result := Best >= 0;
end;

function TProvider.TpuDependencies(const Imgs: TImages; const Home: string): TImages;
type
  TTodo = record
    Im: TImage;
    Where: string;
  end;
var
  Have: TStringList;
  Im: TImage;
  Name, K, Path: string;
  Todo: array of TTodo;
  T: TTodo;
  R: TRec;
  Sub: TImages;
  X: TImage;
begin
  Result := nil;
  Have := TStringList.Create;
  try
    Have.Sorted := True;
    Have.CaseSensitive := True;
    Have.Duplicates := dupIgnore;
    for Im in Concat(Imgs, LibImages) do
      if OwnUnitName(Im, Name) then
        Have.Add(LowerText(Name));
    Todo := nil;
    for Im in Imgs do
    begin
      SetLength(Todo, Length(Todo) + 1);
      Todo[High(Todo)].Im := Im;
      Todo[High(Todo)].Where := Home;
    end;
    while Todo <> nil do
    begin
      T := Todo[High(Todo)];
      SetLength(Todo, Length(Todo) - 1);
      for R in T.Im.Records do
      begin
        if R.Tag <> 'S' then
          Continue;
        K := LowerText(R.Name);
        if Have.IndexOf(K) >= 0 then
          Continue;
        Have.Add(K);
        Path := FindFile(K, '.tpu', T.Where, False, '');
        if Path = '' then
          Continue;
        SetStamp(Path);
        try
          Sub := ReadImages(Path);
        except
          on EStreamError do
            Continue;
          on EInOutError do
            Continue;
        end;
        for X in Sub do
        begin
          Keep(X);
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := X;
          SetLength(Todo, Length(Todo) + 1);
          Todo[High(Todo)].Im := X;
          Todo[High(Todo)].Where := DirName(Path);
        end;
      end;
    end;
  finally
    Have.Free;
  end;
end;

function TProvider.FromTpuUnit(U: TUnit; const Origin: string): TUnitInfo;
var
  S: tpudump.TSym;
  Sym: TSym;
  K: TSymKind;
  TD: TTypeDesc;
begin
  Result := TUnitInfo(Keep(TUnitInfo.Create));
  Result.Name := U.Name;
  Result.Exports_ := NewTable;
  Result.Tpu := U;
  Result.Origin := Origin;
  for S in U.Symbols do
  begin
    if S.Kind = 'routine' then
      K := skRoutine
    else if S.Kind = 'var' then
      K := skVar
    else if S.Kind = 'const' then
      K := skConst
    else if S.Kind = 'type' then
      K := skType
    else
      K := skBuiltin;
    Sym := NewSym(S.Name, K);
    Sym.Lib := True;
    Sym.Home := U.Name;
    TD := S.TypeDesc;
    Sym.TDesc := TD;
    Sym.LParams := S.Params;
    Sym.HasLParams := S.HasParams;
    Sym.TypedConst := S.TypedConst;
    if K = skConst then
    begin
      Sym.CValueKind := S.ValueKind;
      Sym.CInt := S.IntValue;
      Sym.CStr := S.StrValue;
      Sym.CDisplay := S.Display;
      Sym.TfKind := tfPrim;
    end
    else if TD <> nil then
    begin
      Sym.TfKind := tfLibDesc;
      Sym.TfProv := Self;
      Sym.TfDesc := TD;
      if K = skType then
      begin
        Sym.TfHome := U.Name;
        Sym.TfOwner := S.Name;
      end;
    end;
    if (K in [skVar, skConst, skRoutine]) and (TD <> nil) and (TD.Kind = tdNamed) and (TD.Name <> '')
      and (TD.UnitOf <> '') then
    begin
      Sym.HasTypeRef := True;
      Sym.TypeRefUnit := TD.UnitOf;
      Sym.TypeRefName := TD.Name;
    end;
    Result.Exports_.Put(LowerText(S.Name), Sym);
  end;
end;

function TProvider.TInfoFromTDesc(TD: TTypeDesc; Depth: Integer; const Home: string; const Owner: string): TTInfo;
var
  U: TUnitInfo;
  Sym: TSym;
begin
  if (Depth > 12) or (TD = nil) then
    Exit(UnknownTi);
  case TD.Kind of
    tdNamed:
      begin
        if TD.UnitOf <> '' then
        begin
          U := Get(TD.UnitOf);
          if U <> nil then
            Sym := TSym(U.Exports_.Get(LowerText(TD.Name)))
          else
            Sym := nil;
          if (Sym <> nil) and (Sym.Kind = skType) then
            Exit(TiOfSym(Sym));
        end;
        if TD.Name = 'string' then
          Result := StringTi
        else
          Result := PrimTi;
      end;
    tdUnresolved:
      Result := UnknownTi;
    tdRecord:
      begin
        Result := NewTInfo(tiRecord);
        Result.Members := mfLibRecord;
        Result.Desc := TD;
        Result.Depth := Depth;
        Result.Home := Home;
        Result.Owner := Owner;
      end;
    tdObject:
      begin
        Result := NewTInfo(tiRecord);
        Result.Obj := True;
        Result.Members := mfLibObject;
        Result.Desc := TD;
        Result.Depth := Depth;
        Result.Home := Home;
        Result.Owner := Owner;
        if (TD.Ancestor <> nil) and (TD.Ancestor.Kind = tdNamed) and (TD.Ancestor.Name <> '') then
          Result.LibAnc := TD.Ancestor;
      end;
    tdArray:
      begin
        Result := NewTInfo(tiArray);
        Result.Dims := 1;
        Result.Desc := TD;
        Result.Depth := Depth;
      end;
    tdPointer:
      begin
        Result := NewTInfo(tiPointer);
        Result.Desc := TD;
        Result.Depth := Depth;
      end;
    tdString:
      Result := StringTi;
  else
    Result := PrimTi;
  end;
end;

{ TBinder }

constructor TBinder.Create(ARes: TParseResult; AProvider: TProvider; AExportOnly: Boolean);
begin
  FArena := TObjectList.Create(True);
  FTiCache := TPtrMap.Create;
  Res := ARes;
  Provider := AProvider;
  ExportOnly := AExportOnly;
  IfaceTable := NewTable;
  Links := TPtrMap.Create;
  Refs := TPtrMap.Create;
  Decls := TPtrMap.Create;
  Owners := TPtrMap.Create;
end;

destructor TBinder.Destroy;
begin
  FArena.Free;
  FTiCache.Free;
  Links.Free;
  Refs.Free;
  Decls.Free;
  Owners.Free;
  inherited Destroy;
end;

function TBinder.Keep(O: TObject): TObject;
begin
  FArena.Add(O);
  Result := O;
end;

function TBinder.NewScope(ATable: TSymTable; AParent: TScope): TScope;
begin
  Result := TScope(Keep(TScope.Create));
  if ATable = nil then
    ATable := NewTable;
  Result.Table := ATable;
  Result.Parent := AParent;
end;

function TBinder.NewTable: TSymTable;
begin
  Result := TSymTable(Keep(TSymTable.Create));
end;

function TBinder.NewTInfo(AKind: TTInfoKind): TTInfo;
begin
  Result := TTInfo(Keep(TTInfo.Create(AKind, FArena)));
end;

procedure TBinder.Rewrite(Tok: TToken; Sym: TSym);
begin
  if ExportOnly or (Sym = nil) or not (Tok.Kind in [tkIdent, tkInt]) then
    Exit;
  Refs.Put(Tok, Sym);
  if Tok.Kind = tkInt then
    Exit;
  if Tok.Text <> Sym.Name then
  begin
    Tok.Text := Sym.Name;
    Inc(Renamed);
  end;
end;

function TBinder.SystemScope: TScope;
var
  SysU: TUnitInfo;
begin
  SysU := nil;
  if Provider <> nil then
    SysU := Provider.System_;
  Result := NewScope(nil, nil);
  if SysU <> nil then
    Result.Units := [SysU];
end;

function TBinder.UsesScope(Uses_: TNode; Parent: TScope): TScope;
var
  Units: TUnitInfos;
  Table: TSymTable;
  Nm: TObject;
  Tok: TToken;
  Info: TUnitInfo;
  S: TSym;
begin
  Units := nil;
  Table := NewTable;
  if Uses_ <> nil then
    for Nm in Uses_.Kids do
    begin
      if not IsNodeOf(Nm, nkName) then
        Continue;
      Tok := KT(Kid(Nm, 0));
      Info := nil;
      if Provider <> nil then
        Info := Provider.Get(Tok.Text);
      if Info = nil then
      begin
        PushTok(MissingUnits, Tok);
        Continue;
      end;
      S := TSym(Keep(TSym.Create(Info.Name, skUnit)));
      S.UnitInfo := Info;
      S.FileName := Info.Path;
      S.Lib := Info.Path = '';
      Rewrite(Tok, S);
      SetLength(Units, Length(Units) + 1);
      Units[High(Units)] := Info;
      Table.Put(LowerText(Info.Name), S);
    end;
  Result := NewScope(Table, Parent);
  Result.Units := Units;
end;

function TBinder.TiNode(Node: TObject; Scope: TScope): TTInfo;
begin
  if Node = nil then
    Exit(UnknownTi);
  if FTiCache.Has(Node) then
    Exit(TTInfo(FTiCache.Get(Node)));
  FTiCache.Put(Node, UnknownTi);
  Result := TiNodeUncached(Node, Scope);
  FTiCache.Put(Node, Result);
end;

function TBinder.TiNodeUncached(Node: TObject; Scope: TScope): TTInfo;
var
  N: TNode;
  Sym: TSym;
  IOf, I, Dims: Integer;
begin
  if not (Node is TNode) then
    Exit(PrimTi);
  N := TNode(Node);
  case N.Kind of
    nkNamedType:
      begin
        Sym := TypeSym(Kid(N, 0), Scope);
        if (Sym <> nil) and (Sym.Kind = skType) then
          Result := TiOfSym(Sym)
        else
          Result := UnknownTi;
      end;
    nkPackedType:
      Result := TiNode(Kid(N, 1), Scope);
    nkPointerType:
      begin
        Result := NewTInfo(tiPointer);
        Result.Binder := Self;
        Result.Scope := Scope;
        Result.PtrName := KN(Kid(N, 1));
      end;
    nkArrayType:
      begin
        IOf := -1;
        for I := High(N.Kids) downto 1 do
          if IsTok(N.Kids[I], 'of') then
          begin
            IOf := I;
            Break;
          end;
        if IOf < 0 then
          Exit(UnknownTi);
        Dims := 0;
        for I := 2 to IOf - 2 do
          if N.Kids[I] is TNode then
            Inc(Dims);
        if Dims < 1 then
          Dims := 1;
        Result := NewTInfo(tiArray);
        Result.Dims := Dims;
        Result.Binder := Self;
        Result.Scope := Scope;
        Result.ElemNode := Kid(N, IOf + 1);
      end;
    nkRecordType, nkObjectType:
      Result := RecordTi(N, Scope);
    nkStringType:
      Result := StringTi;
  else
    Result := PrimTi;
  end;
end;

function TBinder.RecordTi(Node: TNode; Scope: TScope): TTInfo;
var
  Her: TNode;
begin
  Her := FirstKid(Node, nkHeritage);
  Result := NewTInfo(tiRecord);
  Result.Obj := Node.Kind = nkObjectType;
  Result.Node := Node;
  Result.Binder := Self;
  Result.Scope := Scope;
  Result.Members := mfSource;
  if (Her <> nil) and (Length(Her.Kids) > 1) and (Her.Kids[1] is TNode) then
    Result.HerName := TNode(Her.Kids[1]);
end;

function TBinder.TypeTi(Sym: TSym): TTInfo;
var
  Inner: TObject;
begin
  if (Sym = nil) or (Sym.Kind <> skType) or (Sym.TNode = nil) then
    Exit(nil);
  Inner := Sym.TNode;
  while IsNodeOf(Inner, nkPackedType) and (Length(TNode(Inner).Kids) > 1) do
    Inner := TNode(Inner).Kids[1];
  if not (IsNodeOf(Inner, nkRecordType) or IsNodeOf(Inner, nkObjectType)) then
    Exit(nil);
  Result := TiNode(Inner, Sym.Scope);
end;

function TBinder.PtrTarget(NameNode: TNode; Scope: TScope): TTInfo;
var
  Sym: TSym;
begin
  Sym := TypeSym(NameNode, Scope);
  if (Sym <> nil) and (Sym.Kind = skType) then
    Result := TiOfSym(Sym)
  else
    Result := UnknownTi;
end;

function TBinder.TypeSym(NameNode: TObject; Scope: TScope; DoRewrite: Boolean): TSym;
var
  Toks: TTokens;
  K: TObject;
begin
  Toks := nil;
  for K in KN(NameNode).Kids do
    if (K is TToken) and (TToken(K).Kind = tkIdent) then
      PushTok(Toks, TToken(K));
  if Toks = nil then
    Exit(nil);
  Result := Scope.Lookup(LowerText(Toks[0].Text));
  if DoRewrite then
    Note(Toks[0], Result);
  if (Result <> nil) and (Result.Kind = skUnit) and (Length(Toks) > 1) then
  begin
    Result := TSym(Result.UnitInfo.Exports_.Get(LowerText(Toks[1].Text)));
    if DoRewrite then
      Note(Toks[1], Result);
  end;
end;

procedure TBinder.Note(Tok: TToken; Sym: TSym);
begin
  if Sym = nil then
    PushTok(Unresolved, Tok)
  else
    Rewrite(Tok, Sym);
end;

function TBinder.BuildMembers(Rec: TNode; Scope: TScope): TSymTable;
var
  Out_: TSymTable;
  Owner: TSym;
  Body: TNode;

  procedure Field(Tok: TToken; TN: TObject);
  var
    S, Old: TSym;
  begin
    S := TSym(Keep(TSym.Create(Tok.Text, skField, Tok, TN, Scope)));
    S.Binder := Self;
    if Tok.FileName <> '' then
      S.FileName := Tok.FileName
    else
      S.FileName := Path;
    S.Owner := Owner;
    NoteDecl(Tok, S);
    S.TfKind := tfNode;
    S.TfBinder := Self;
    S.TfNode := TN;
    S.TfScope := Scope;
    Old := TSym(Out_.SetDefault(LowerText(Tok.Text), S));
    if (Old <> S) and not ExportOnly then
    begin
      SetLength(Dups, Length(Dups) + 1);
      Dups[High(Dups)].Tok := Tok;
      Dups[High(Dups)].Old := Old;
    end;
  end;

  procedure FL(Node: TNode);
  var
    K, X, V: TObject;
    Kids: TKids;
    Colon, I: Integer;
    NameTok: TToken;
    Params, Res_: TNode;
    M, Old: TSym;
  begin
    for K in Node.Kids do
    begin
      if K is TToken then
        Continue;
      case TNode(K).Kind of
        nkFieldDecl:
          begin
            Kids := TNode(K).Kids;
            Colon := -1;
            for I := 0 to High(Kids) do
              if IsTok(Kids[I], ':') then
                Colon := I;
            if (Colon < 0) or (Colon + 1 >= Length(Kids)) then
              Continue;
            for I := 0 to Colon - 1 do
              if IsNodeOf(Kids[I], nkDeclName) and (TNode(Kids[I]).Kids <> nil) then
                Field(KT(TNode(Kids[I]).Kids[0]), Kids[Colon + 1]);
          end;
        nkRoutine:
          begin
            RoutineParts(TNode(K), NameTok, Params, Res_);
            M := MakeSym(NameTok, skRoutine, Res_, Scope, TNode(K));
            M.Owner := Owner;
            M.HasBody := False;
            M.HeaderParams := Params;
            Old := TSym(Out_.SetDefault(LowerText(NameTok.Text), M));
            if (Old <> M) and not ExportOnly then
            begin
              SetLength(Dups, Length(Dups) + 1);
              Dups[High(Dups)].Tok := NameTok;
              Dups[High(Dups)].Old := Old;
            end;
          end;
        nkVariantPart:
          begin
            Kids := TNode(K).Kids;
            if (Length(Kids) > 3) and IsNodeOf(Kids[1], nkDeclName) and IsTok(Kids[2], ':') then
              Field(KT(Kid(Kids[1], 0)), Kids[3]);
            for V in Kids do
              if IsNodeOf(V, nkVariant) then
                for X in TNode(V).Kids do
                  if IsNodeOf(X, nkFieldList) then
                    FL(TNode(X));
          end;
      end;
    end;
  end;

begin
  Out_ := NewTable;
  Owner := TSym(Owners.Get(Rec));
  Body := FieldListOf(Rec);
  if Body <> nil then
    FL(Body);
  Result := Out_;
end;

procedure TBinder.NoteDecl(Tok: TToken; Sym: TSym);
begin
  if not ExportOnly then
    Decls.Put(Tok, Sym);
end;

function TBinder.MakeSym(Tok: TToken; Kind: TSymKind; TNode: TObject; Scope: TScope; Node: TNode): TSym;
begin
  Result := TSym(Keep(TSym.Create(Tok.Text, Kind, Tok, TNode, Scope, Node)));
  Result.Binder := Self;
  if Tok.FileName <> '' then
    Result.FileName := Tok.FileName
  else
    Result.FileName := Path;
  NoteDecl(Tok, Result);
  Result.TfBinder := Self;
  Result.TfNode := TNode;
  Result.TfScope := Scope;
  case Kind of
    skVar, skParam, skField:
      if TNode <> nil then
        Result.TfKind := tfNode
      else
        Result.TfKind := tfUnknown;
    skType:
      Result.TfKind := tfNode;
    skConst:
      if TNode <> nil then
        Result.TfKind := tfNode
      else
        Result.TfKind := tfPrim;
    skEnum:
      Result.TfKind := tfPrim;
    skRoutine:
      Result.TfKind := tfResult;
  else
    Result.TfKind := tfUnknown;
  end;
end;

function TBinder.ResultTi(RSym: TSym): TTInfo;
begin
  if RSym.TNode <> nil then
    Result := TiNode(RSym.TNode, RSym.Scope)
  else
    Result := UnknownTi;
end;

procedure TBinder.Declare(Scope: TScope; Sym: TSym);
var
  Key: string;
  Old: TSym;
begin
  if Sym.Kind = skLabel then
    Key := LabelKey(Sym.Name)
  else
    Key := LowerText(Sym.Name);
  Old := TSym(Scope.Table.SetDefault(Key, Sym));
  if (Old <> Sym) and (Sym.Tok <> nil) and not ExportOnly then
  begin
    SetLength(Dups, Length(Dups) + 1);
    Dups[High(Dups)].Tok := Sym.Tok;
    Dups[High(Dups)].Old := Old;
  end;
end;

procedure TBinder.Collect(const Items: TNodes; Scope: TScope; LinkTable: TSymTable);
var
  Sec: TNode;
  T, D: TObject;
  I: Integer;
  Lab: TSym;
begin
  for Sec in Items do
    case Sec.Kind of
      nkRoutine:
        try
          CollectRoutine(Sec, Scope, LinkTable);
        except
          on EBroken do
            ;
        end;
      nkLabelSection:
        for I := 1 to High(Sec.Kids) do
        begin
          T := Sec.Kids[I];
          if (T is TToken) and (TToken(T).Kind in [tkIdent, tkInt]) then
          begin
            Lab := TSym(Keep(TSym.Create(TToken(T).Text, skLabel, TToken(T))));
            if TToken(T).FileName <> '' then
              Lab.FileName := TToken(T).FileName
            else
              Lab.FileName := Path;
            NoteDecl(TToken(T), Lab);
            Declare(Scope, Lab);
          end;
        end;
      nkConstSection, nkTypeSection, nkVarSection:
        for I := 1 to High(Sec.Kids) do
        begin
          D := Sec.Kids[I];
          if not (D is TNode) then
            Continue;
          try
            CollectDecl(Sec.Kind, TNode(D), Scope);
          except
            on EBroken do
              ;
          end;
        end;
    end;
end;

procedure TBinder.CollectDecl(K: TNodeKind; D: TNode; Scope: TScope);
var
  Kids: TKids;
  TN, Inner: TObject;
  TSym_: TSym;
  Colon, I: Integer;
begin
  Kids := D.Kids;
  if K = nkConstSection then
  begin
    TN := nil;
    if (Length(Kids) > 2) and IsTok(Kids[1], ':') then
      TN := Kids[2];
    Declare(Scope, MakeSym(KT(Kid(Kid(D, 0), 0)), skConst, TN, Scope, D));
    if TN is TNode then
      DeclareEnums(TNode(TN), Scope);
  end
  else if K = nkTypeSection then
  begin
    TN := Kid(D, 2);
    if not (TN is TNode) then
      Exit;
    TSym_ := MakeSym(KT(Kid(Kid(D, 0), 0)), skType, TN, Scope, D);
    Declare(Scope, TSym_);
    Inner := TN;
    while IsNodeOf(Inner, nkPackedType) and (Length(TNode(Inner).Kids) > 1) do
      Inner := TNode(Inner).Kids[1];
    if IsNodeOf(Inner, nkRecordType) or IsNodeOf(Inner, nkObjectType) or IsNodeOf(Inner, nkEnumType) then
      Owners.Put(Inner, TSym_);
    DeclareEnums(TNode(TN), Scope, KT(Kid(Kid(D, 0), 0)));
  end
  else
  begin
    Colon := -1;
    for I := 0 to High(Kids) do
      if IsTok(Kids[I], ':') then
      begin
        Colon := I;
        Break;
      end;
    if Colon < 0 then
      raise EBroken.Create('StopIteration');
    TN := Kid(D, Colon + 1);
    if not (TN is TNode) then
      Exit;
    for I := 0 to Colon - 1 do
      if IsNodeOf(Kids[I], nkDeclName) and (TNode(Kids[I]).Kids <> nil) then
        Declare(Scope, MakeSym(KT(TNode(Kids[I]).Kids[0]), skVar, TN, Scope, D));
    DeclareEnums(TNode(TN), Scope);
  end;
end;

procedure TBinder.DeclareEnums(TN: TNode; Scope: TScope; Owner: TToken);
var
  N: TNode;
  M: TObject;
  Sym: TSym;
begin
  for N in TN.Walk do
    if N.Kind = nkEnumType then
      for M in N.Kids do
        if IsNodeOf(M, nkDeclName) then
        begin
          Sym := MakeSym(KT(Kid(M, 0)), skEnum, N, Scope);
          if N = TN then
            Sym.TypeTok := Owner;
          Declare(Scope, Sym);
        end;
end;

procedure TBinder.RoutineParts(R: TNode; out NameTok: TToken; out Params, Res: TNode);
var
  Kids: TKids;
  Owner, DN: TNode;
  I: Integer;
begin
  Kids := R.Kids;
  RoutineNames(R, Owner, DN);
  if DN = nil then
    raise EBroken.Create('no name');
  NameTok := KT(Kid(DN, 0));
  if Owner <> nil then
    I := 4
  else
    I := 2;
  Params := nil;
  if (I < Length(Kids)) and IsNodeOf(Kids[I], nkParams) then
  begin
    Params := TNode(Kids[I]);
    Inc(I);
  end;
  Res := nil;
  if (I + 1 < Length(Kids)) and IsTok(Kids[I], ':') and (Kids[I + 1] is TNode) then
    Res := TNode(Kids[I + 1]);
end;

procedure TBinder.MethodOf(R: TNode; Scope: TScope; LinkTable: TSymTable; out TSym_, M: TSym);
var
  Owner, DN: TNode;
  Key: string;
  Ti: TTInfo;
  NameTok: TToken;
begin
  TSym_ := nil;
  M := nil;
  RoutineNames(R, Owner, DN);
  if (Owner = nil) or (Owner.Kids = nil) or not (Owner.Kids[0] is TToken) then
    Exit;
  Key := LowerText(TToken(Owner.Kids[0]).Text);
  TSym_ := Scope.Lookup(Key);
  if (TSym_ = nil) and (LinkTable <> nil) then
    TSym_ := TSym(LinkTable.Get(Key));
  Ti := TypeTi(TSym_);
  if Ti = nil then
    Exit;
  if DN = nil then
    raise EBroken.Create('no name');
  NameTok := KT(Kid(DN, 0));
  M := TSym(Ti.GetOwn.Get(LowerText(NameTok.Text)));
  if (M <> nil) and (M.Kind <> skRoutine) then
    M := nil;
end;

procedure TBinder.CollectRoutine(R: TNode; Scope: TScope; LinkTable: TSymTable);
var
  NameTok: TToken;
  Params, Res_, Owner, DN: TNode;
  Key: string;
  HasBody: Boolean;
  TS, M, Existing, Sym: TSym;
begin
  RoutineParts(R, NameTok, Params, Res_);
  Key := LowerText(NameTok.Text);
  HasBody := FirstKid(R, nkBlock) <> nil;
  RoutineNames(R, Owner, DN);
  if Owner <> nil then
  begin
    MethodOf(R, Scope, LinkTable, TS, M);
    if (M <> nil) and HasBody and not M.HasBody then
    begin
      Links.Put(R, M);
      M.HasBody := True;
      M.ImplTok := NameTok;
      NoteDecl(NameTok, M);
    end;
    Exit;
  end;
  if LinkTable <> nil then
    Existing := TSym(LinkTable.Get(Key))
  else
    Existing := TSym(Scope.Table.Get(Key));
  if (Existing <> nil) and (Existing.Kind = skRoutine) and HasBody and not Existing.HasBody then
  begin
    Links.Put(R, Existing);
    Existing.HasBody := True;
    Existing.ImplTok := NameTok;
    NoteDecl(NameTok, Existing);
    Exit;
  end;
  Sym := MakeSym(NameTok, skRoutine, Res_, Scope, R);
  Sym.HasBody := HasBody;
  Sym.HeaderParams := Params;
  Declare(Scope, Sym);
end;

procedure TBinder.ResolveDecls(const Items: TNodes; Scope: TScope);
var
  Sec: TNode;
  I: Integer;
begin
  for Sec in Items do
    case Sec.Kind of
      nkRoutine:
        try
          ResolveHeader(Sec, Scope);
        except
          on EBroken do
            ;
        end;
      nkConstSection, nkTypeSection, nkVarSection:
        for I := 1 to High(Sec.Kids) do
          if Sec.Kids[I] is TNode then
            try
              ResolveDecl(Sec.Kind, TNode(Sec.Kids[I]), Scope);
            except
              on EBroken do
                ;
            end;
    end;
end;

procedure TBinder.ResolveDecl(K: TNodeKind; D: TNode; Scope: TScope);
var
  Kids: TKids;
  Eq, Colon, I: Integer;
  X, E, V: TObject;
  T: TTInfo;
begin
  Kids := D.Kids;
  if K = nkConstSection then
  begin
    if IsTok(Kid(D, 1), ':') then
    begin
      ResolveType(Kid(D, 2), Scope);
      Eq := -1;
      for I := 0 to High(Kids) do
        if IsTok(Kids[I], '=') then
        begin
          Eq := I;
          Break;
        end;
      if Eq < 0 then
        raise EBroken.Create('StopIteration');
      V := Kid(D, Eq + 1);
      T := TiNode(Kid(D, 2), Scope);
      ResolveValue(V, T, Scope, nil);
    end
    else
      ResolveExpr(Kid(D, 2), Scope, nil);
  end
  else if K = nkTypeSection then
    ResolveType(Kid(D, 2), Scope)
  else
  begin
    Colon := -1;
    for I := 0 to High(Kids) do
      if IsTok(Kids[I], ':') then
      begin
        Colon := I;
        Break;
      end;
    if Colon < 0 then
      raise EBroken.Create('StopIteration');
    ResolveType(Kid(D, Colon + 1), Scope);
    for I := Colon + 2 to High(Kids) do
    begin
      X := Kids[I];
      if IsNodeOf(X, nkAbsolute) then
        for E in TNode(X).Kids do
          if E is TNode then
            ResolveExpr(E, Scope, nil);
    end;
  end;
end;

procedure TBinder.ResolveHeader(R: TNode; Scope: TScope);
var
  NameTok: TToken;
  Params, Res_, Owner, DN: TNode;
  Link, TS, M: TSym;
begin
  RoutineParts(R, NameTok, Params, Res_);
  Link := TSym(Links.Get(R));
  RoutineNames(R, Owner, DN);
  if Owner <> nil then
  begin
    MethodOf(R, Scope, nil, TS, M);
    Note(KT(Kid(Owner, 0)), TS);
    if M = nil then
      PushTok(Unresolved, NameTok);
  end;
  if Link <> nil then
    Rewrite(NameTok, Link);
  if Params <> nil then
    ResolveType(Params, Scope);
  if Res_ <> nil then
    ResolveType(Res_, Scope);
end;

procedure TBinder.BindBodies(const Items: TNodes; Scope: TScope);
var
  R: TNode;
begin
  for R in Items do
    if R.Kind = nkRoutine then
      try
        BindRoutine(R, Scope);
      except
        on EBroken do
          ;
      end;
end;

procedure TBinder.BindRoutine(R: TNode; Scope: TScope);
var
  Block, Params, Res_, Owner, DN: TNode;
  NameTok: TToken;
  Link, TS, M, Me: TSym;
  RS: TScope;
  Saved, Ti: TTInfo;
  Items: TNodes;
  X: TObject;
begin
  Block := FirstKid(R, nkBlock);
  if Block = nil then
    Exit;
  RoutineParts(R, NameTok, Params, Res_);
  Link := TSym(Links.Get(R));
  RS := NewScope(nil, Scope);
  SetLength(NodeScopes, Length(NodeScopes) + 1);
  NodeScopes[High(NodeScopes)].Node := R;
  NodeScopes[High(NodeScopes)].Scope := RS;
  Saved := CurTi;
  RoutineNames(R, Owner, DN);
  if Owner <> nil then
  begin
    MethodOf(R, Scope, nil, TS, M);
    Ti := TypeTi(TS);
    if Ti <> nil then
    begin
      RS := NewScope(nil, NewScope(Ti.GetFields, Scope));
      NodeScopes[High(NodeScopes)].Scope := RS;
      Me := TSym(Keep(TSym.Create('Self', skParam, nil, nil, Scope)));
      Me.Implicit := True;
      Me.Owner := TS;
      Me.TfKind := tfFixed;
      Me.TfFixed := Ti;
      RS.Table.Put('self', Me);
      CurTi := Ti;
    end;
  end;
  try
    if Params <> nil then
      DeclareParams(Params, RS, Scope)
    else if (Link <> nil) and (Link.HeaderParams <> nil) then
      DeclareParams(Link.HeaderParams, RS, Link.Scope);
    Items := NodeKidsExcept(Block, [nkCompound, nkAsm]);
    Collect(Items, RS);
    ResolveDecls(Items, RS);
    BindBodies(Items, RS);
    for X in Block.Kids do
      if IsNodeOf(X, nkCompound) then
        ResolveStmt(TNode(X), RS, nil);
  finally
    CurTi := Saved;
  end;
end;

procedure TBinder.DeclareParams(Params: TNode; Into, TScope_: TScope);
var
  G, X: TObject;
  TN: TObject;
  Colon: Boolean;
begin
  for G in Params.Kids do
    if IsNodeOf(G, nkParamGroup) then
    begin
      TN := nil;
      Colon := False;
      for X in TNode(G).Kids do
        if IsTok(X, ':') then
          Colon := True;
      if Colon and (TNode(G).Kids[High(TNode(G).Kids)] is TNode) then
        TN := TNode(G).Kids[High(TNode(G).Kids)];
      for X in TNode(G).Kids do
        if IsNodeOf(X, nkDeclName) then
          Declare(Into, MakeSym(KT(Kid(X, 0)), skParam, TN, TScope_));
    end;
end;

procedure TBinder.ResolveType(Node: TObject; Scope: TScope);
var
  N, Her, Body: TNode;
  X: TObject;
begin
  if not (Node is TNode) then
    Exit;
  N := TNode(Node);
  case N.Kind of
    nkNamedType:
      TypeSym(Kid(N, 0), Scope, True);
    nkPointerType:
      TypeSym(Kid(N, 1), Scope, True);
    nkArrayType, nkPackedType, nkSetType, nkFileType, nkProcType, nkParams, nkParamGroup, nkSubrangeType,
    nkStringType:
      for X in N.Kids do
        if X is TNode then
          if N.Kind in [nkSubrangeType, nkStringType] then
            ResolveExpr(X, Scope, nil)
          else
            ResolveType(X, Scope);
    nkRecordType, nkObjectType:
      begin
        TiNode(N, Scope).GetOwn;
        Her := FirstKid(N, nkHeritage);
        if (Her <> nil) and (Length(Her.Kids) > 1) and (Her.Kids[1] is TNode) then
          TypeSym(Her.Kids[1], Scope, True);
        Body := FieldListOf(N);
        if Body <> nil then
          ResolveFieldList(Body, Scope);
      end;
  end;
end;

procedure TBinder.NoteFieldDecl(NameNode: TNode);
var
  Tok: TObject;
  S: TSym;
begin
  if NameNode.Kids = nil then
    Exit;
  Tok := NameNode.Kids[0];
  if (Tok is TToken) and not Decls.Has(Tok) then
  begin
    S := TSym(Keep(TSym.Create(TToken(Tok).Text, skField, TToken(Tok))));
    if TToken(Tok).FileName <> '' then
      S.FileName := TToken(Tok).FileName
    else
      S.FileName := Path;
    NoteDecl(TToken(Tok), S);
  end;
end;

procedure TBinder.ResolveFieldList(FL: TNode; Scope: TScope);
var
  K, X, Y, E: TObject;
  NameTok: TToken;
  Params, Res_: TNode;
begin
  for K in FL.Kids do
  begin
    if not (K is TNode) then
      Continue;
    case TNode(K).Kind of
      nkRoutine:
        begin
          RoutineParts(TNode(K), NameTok, Params, Res_);
          if Params <> nil then
            ResolveType(Params, Scope);
          if Res_ <> nil then
            ResolveType(Res_, Scope);
        end;
      nkFieldDecl:
        begin
          for X in TNode(K).Kids do
            if IsNodeOf(X, nkDeclName) then
              NoteFieldDecl(TNode(X));
          ResolveType(Kid(K, -1), Scope);
        end;
      nkVariantPart:
        for X in TNode(K).Kids do
          if X is TNode then
          begin
            if TNode(X).Kind = nkDeclName then
              NoteFieldDecl(TNode(X));
            if TNode(X).Kind = nkVariant then
            begin
              for Y in TNode(X).Kids do
                if Y is TNode then
                  if TNode(Y).Kind = nkLabels then
                  begin
                    for E in TNode(Y).Kids do
                      if E is TNode then
                        ResolveExpr(E, Scope, nil);
                  end
                  else if TNode(Y).Kind = nkFieldList then
                    ResolveFieldList(TNode(Y), Scope);
            end
            else if TNode(X).Kind <> nkDeclName then
              ResolveType(X, Scope);
          end;
    end;
  end;
end;

const
  StmtKinds = [nkCompound, nkStmtList, nkIf, nkWhile, nkRepeat, nkFor, nkCase, nkWith, nkAssign, nkProcCall, nkGoto,
    nkLabeled, nkEmpty, nkAsm, nkInline, nkInherited];

procedure TBinder.ResolveStmt(S: TNode; Scope: TScope; const Withs: TWiths);
var
  X, Y, E: TObject;
  I: Integer;
  New_: TWiths;
  T: TTInfo;
  Lab: TToken;
  Sym: TSym;
begin
  case S.Kind of
    nkCompound, nkStmtList:
      for X in S.Kids do
        if X is TNode then
          ResolveStmt(TNode(X), Scope, Withs);
    nkAssign:
      begin
        ResolveExpr(Kid(S, 0), Scope, Withs);
        ResolveExpr(Kid(S, 2), Scope, Withs);
      end;
    nkProcCall:
      ResolveExpr(Kid(S, 0), Scope, Withs);
    nkInherited:
      ResolveExpr(S, Scope, Withs);
    nkIf, nkWhile, nkRepeat:
      for X in S.Kids do
        if X is TNode then
          if TNode(X).Kind in StmtKinds then
            ResolveStmt(TNode(X), Scope, Withs)
          else
            ResolveExpr(X, Scope, Withs);
    nkFor:
      for I := 1 to High(S.Kids) do
      begin
        X := S.Kids[I];
        if not (X is TNode) then
          Continue;
        if TNode(X).Kind = nkName then
          LookupTokens(KT(Kid(X, 0)), Scope, Withs)
        else if TNode(X).Kind in StmtKinds - [nkStmtList] then
          ResolveStmt(TNode(X), Scope, Withs)
        else
          ResolveExpr(X, Scope, Withs);
      end;
    nkCase:
      for X in S.Kids do
        if X is TNode then
          if TNode(X).Kind = nkCaseBranch then
          begin
            for Y in TNode(X).Kids do
              if Y is TNode then
                if TNode(Y).Kind = nkLabels then
                begin
                  for E in TNode(Y).Kids do
                    if E is TNode then
                      ResolveExpr(E, Scope, Withs);
                end
                else
                  ResolveStmt(TNode(Y), Scope, Withs);
          end
          else if TNode(X).Kind = nkCaseElse then
          begin
            for Y in TNode(X).Kids do
              if Y is TNode then
                ResolveStmt(TNode(Y), Scope, Withs);
          end
          else
            ResolveExpr(X, Scope, Withs);
    nkWith:
      begin
        New_ := Copy(Withs);
        for X in S.Kids do
          if IsNodeOf(X, nkDesignator) then
          begin
            T := ResolveExpr(X, Scope, New_);
            SetLength(New_, Length(New_) + 1);
            if (T <> nil) and (T.Kind = tiRecord) then
              New_[High(New_)] := T
            else
              New_[High(New_)] := nil;
          end
          else if X is TNode then
            ResolveStmt(TNode(X), Scope, New_);
      end;
    nkLabeled:
      begin
        Lab := KT(Kid(S, 0));
        if Lab.Kind in [tkIdent, tkInt] then
        begin
          Sym := LookupTokens(Lab, Scope, nil);
          if (Sym <> nil) and (Sym.Kind = skLabel) and (Sym.ImplTok = nil) then
            Sym.ImplTok := Lab;
        end;
        ResolveStmt(KN(Kid(S, 2)), Scope, Withs);
      end;
    nkGoto:
      if (Length(S.Kids) > 1) and (S.Kids[1] is TToken) and (TToken(S.Kids[1]).Kind in [tkIdent, tkInt]) then
        LookupTokens(TToken(S.Kids[1]), Scope, nil);
  end;
end;

function TBinder.LookupTokens(Tok: TToken; Scope: TScope; const Withs: TWiths): TSym;
var
  Key: string;
begin
  if Tok.Kind = tkInt then
    Key := LabelKey(Tok.Text)
  else
    Key := LowerText(Tok.Text);
  Result := Find(Key, Scope, Withs);
  if Result = UncertainSym then
  begin
    PushTok(Uncertain, Tok);
    Exit(nil);
  end;
  if Result = nil then
  begin
    PushTok(Unresolved, Tok);
    Exit(nil);
  end;
  Rewrite(Tok, Result);
end;

function TBinder.Find(const Key: string; Scope: TScope; const Withs: TWiths): TSym;
var
  I: Integer;
begin
  for I := High(Withs) downto 0 do
  begin
    if Withs[I] = nil then
      Exit(UncertainSym);
    Result := TSym(Withs[I].GetFields.Get(Key));
    if Result <> nil then
      Exit;
  end;
  Result := Scope.Lookup(Key);
end;

function TBinder.ResolveExpr(E: TObject; Scope: TScope; const Withs: TWiths): TTInfo;
var
  N, D: TNode;
  X: TObject;
  Anc: TTInfo;
begin
  Result := nil;
  if not (E is TNode) then
    Exit;
  N := TNode(E);
  case N.Kind of
    nkDesignator:
      Result := Designator(N, Scope, Withs);
    nkInherited:
      begin
        D := FirstKid(N, nkDesignator);
        if D = nil then
          Exit(nil);
        Anc := nil;
        if CurTi <> nil then
          Anc := CurTi.GetAncestor;
        if Anc <> nil then
          Result := Designator(D, Scope, Withs, Anc.GetFields, True)
        else
          Result := Designator(D, Scope, Withs, EmptyTable, True);
      end;
    nkParen:
      Result := ResolveExpr(Kid(N, 1), Scope, Withs);
    nkUnary:
      ResolveExpr(Kid(N, 1), Scope, Withs);
    nkBinary:
      begin
        ResolveExpr(Kid(N, 0), Scope, Withs);
        ResolveExpr(Kid(N, 2), Scope, Withs);
      end;
    nkSetCtor, nkArg, nkLabels:
      for X in N.Kids do
        if X is TNode then
          ResolveExpr(X, Scope, Withs);
    nkStringLit:
      Result := StringTi;
    nkAggregate:
      ResolveValue(N, nil, Scope, Withs);
  end;
end;

function TBinder.ValueType(Sym: TSym; Cur: TTInfo): TTInfo;
begin
  if Cur <> nil then
    Exit(Cur);
  if Sym = nil then
    Exit(nil);
  if Sym.Kind in [skVar, skParam, skField, skConst, skRoutine, skEnum] then
    Result := TiOfSym(Sym)
  else
    Result := nil;
end;

function TBinder.Peel(T: TTInfo; N: Integer): TTInfo;
var
  P: TTInfo;
begin
  while (T <> nil) and (N > 0) do
    if T.Kind = tiArray then
    begin
      if T.Dims > N then
      begin
        P := NewTInfo(tiArray);
        P.Dims := T.Dims - N;
        P.ElemFrom := T;
        Exit(P);
      end;
      N := N - T.Dims;
      T := T.Elem;
    end
    else if T.Kind = tiString then
    begin
      Dec(N);
      T := PrimTi;
    end
    else
      Exit(nil);
  Result := T;
end;

function TBinder.Designator(D: TNode; Scope: TScope; const Withs: TWiths; Members: TSymTable;
  HasMembers: Boolean): TTInfo;
var
  Kids: TKids;
  Tok, Ft: TToken;
  Sym, CurSym, S2, F: TSym;
  CurT, T: TTInfo;
  Post, X, A: TObject;
  I, N, NArgs: Integer;
  Target: TSymTable;
begin
  Kids := D.Kids;
  if (Kids = nil) or not (Kids[0] is TNode) or (TNode(Kids[0]).Kids = nil) or not (TNode(Kids[0]).Kids[0] is TToken) then
    Exit(nil);
  Tok := TToken(TNode(Kids[0]).Kids[0]);
  if HasMembers then
    Sym := TSym(Members.Get(LowerText(Tok.Text)))
  else
    Sym := Find(LowerText(Tok.Text), Scope, Withs);
  CurSym := nil;
  CurT := nil;
  if Sym = UncertainSym then
    PushTok(Uncertain, Tok)
  else if Sym = nil then
    PushTok(Unresolved, Tok)
  else
  begin
    Rewrite(Tok, Sym);
    CurSym := Sym;
  end;
  for I := 1 to High(Kids) do
  begin
    Post := Kids[I];
    case KN(Post).Kind of
      nkField:
        begin
          Ft := KT(Kid(Post, 1));
          if (CurSym <> nil) and (CurSym.Kind = skUnit) and (CurT = nil) then
          begin
            S2 := TSym(CurSym.UnitInfo.Exports_.Get(LowerText(Ft.Text)));
            Note(Ft, S2);
            CurSym := S2;
            CurT := nil;
          end
          else
          begin
            T := ValueType(CurSym, CurT);
            if (T <> nil) and (T.Kind = tiRecord) then
            begin
              F := TSym(T.GetFields.Get(LowerText(Ft.Text)));
              Note(Ft, F);
              CurSym := F;
              CurT := nil;
            end
            else
            begin
              CurSym := nil;
              CurT := nil;
            end;
          end;
        end;
      nkIndex:
        begin
          N := 0;
          for X in TNode(Post).Kids do
            if X is TNode then
            begin
              ResolveExpr(X, Scope, Withs);
              Inc(N);
            end;
          T := ValueType(CurSym, CurT);
          if N < 1 then
            N := 1;
          CurT := Peel(T, N);
          CurSym := nil;
        end;
      nkDeref:
        begin
          T := ValueType(CurSym, CurT);
          if (T <> nil) and (T.Kind = tiPointer) then
            CurT := T.GetTarget
          else
            CurT := nil;
          CurSym := nil;
        end;
      nkArgs:
        begin
          Target := nil;
          if (CurSym <> nil) and (CurSym.Kind in [skRoutine, skBuiltin]) and CurSym.Lib
            and ((LowerText(CurSym.Name) = 'new') or (LowerText(CurSym.Name) = 'dispose')) then
            Target := PointeeMembers(TNode(Post), Scope, Withs);
          NArgs := 0;
          for A in TNode(Post).Kids do
            if A is TNode then
            begin
              Inc(NArgs);
              if (Target <> nil) and (NArgs = 2) and (TNode(A).Kids <> nil) and IsNodeOf(TNode(A).Kids[0], nkDesignator) then
                Designator(TNode(TNode(A).Kids[0]), Scope, Withs, Target, True)
              else
                ResolveExpr(A, Scope, Withs);
            end;
          if (CurT = nil) and (CurSym <> nil) then
          begin
            if CurSym.Kind in [skRoutine, skType] then
              CurT := TiOfSym(CurSym)
            else
              CurT := nil;
          end
          else
            CurT := nil;
          CurSym := nil;
        end;
    end;
  end;
  Result := ValueType(CurSym, CurT);
end;

procedure TBinder.ChainType(const Chain: TChain; Scope: TScope; out U: TUnitInfo; out T: TTInfo);
var
  Sym, CurSym, F: TSym;
  CurT, Ty: TTInfo;
  I: Integer;
  Step: TChainStep;
begin
  U := nil;
  T := nil;
  if (Chain = nil) or (Chain[0].Kind <> ckName) then
    Exit;
  Sym := Scope.Lookup(LowerText(Chain[0].Text));
  if (Sym = nil) or (Sym = UncertainSym) then
    Exit;
  CurSym := Sym;
  CurT := nil;
  for I := 1 to High(Chain) do
  begin
    Step := Chain[I];
    if (CurSym <> nil) and (CurSym.Kind = skUnit) and (CurT = nil) then
    begin
      if Step.Kind <> ckName then
        Exit;
      CurSym := TSym(CurSym.UnitInfo.Exports_.Get(LowerText(Step.Text)));
      if CurSym = nil then
        Exit;
      Continue;
    end;
    Ty := ValueType(CurSym, CurT);
    case Step.Kind of
      ckName:
        begin
          F := nil;
          if (Ty <> nil) and (Ty.Kind = tiRecord) then
            F := TSym(Ty.GetFields.Get(LowerText(Step.Text)));
          CurSym := F;
          CurT := nil;
          if F = nil then
            Exit;
        end;
      ckIndex:
        begin
          if Step.N < 1 then
            CurT := Peel(Ty, 1)
          else
            CurT := Peel(Ty, Step.N);
          CurSym := nil;
        end;
      ckDeref:
        begin
          if (Ty <> nil) and (Ty.Kind = tiPointer) then
            CurT := Ty.GetTarget
          else
            CurT := nil;
          CurSym := nil;
        end;
    else
      if (CurT = nil) and (CurSym <> nil) and (CurSym.Kind in [skRoutine, skType]) then
        CurT := TiOfSym(CurSym)
      else
        CurT := nil;
      CurSym := nil;
    end;
    if (CurSym = nil) and (CurT = nil) then
      Exit;
  end;
  if (CurSym <> nil) and (CurSym.Kind = skUnit) and (CurT = nil) then
  begin
    U := CurSym.UnitInfo;
    Exit;
  end;
  T := ValueType(CurSym, CurT);
end;

function TBinder.PointeeMembers(Args: TNode; Scope: TScope; const Withs: TWiths): TSymTable;
var
  A: TNodes;
  X: TObject;
  D: TNode;
  Head: TSym;
  T, Tgt: TTInfo;
begin
  A := nil;
  for X in Args.Kids do
    if X is TNode then
    begin
      SetLength(A, Length(A) + 1);
      A[High(A)] := TNode(X);
    end;
  if (Length(A) < 2) or (A[0].Kids = nil) or not IsNodeOf(A[0].Kids[0], nkDesignator) then
    Exit(nil);
  D := TNode(A[0].Kids[0]);
  Head := Find(LowerText(KT(Kid(Kid(D, 0), 0)).Text), Scope, Withs);
  if (Head = nil) or (Head = UncertainSym) then
    Exit(nil);
  if (Length(D.Kids) = 1) and (Head.Kind = skType) then
    T := TiOfSym(Head)
  else
    T := ValuePeek(D, Scope, Withs);
  Tgt := nil;
  if (T <> nil) and (T.Kind = tiPointer) then
    Tgt := T.GetTarget;
  if (Tgt <> nil) and (Tgt.Kind = tiRecord) then
    Result := Tgt.GetFields
  else
    Result := nil;
end;

function TBinder.ValuePeek(D: TNode; Scope: TScope; const Withs: TWiths): TTInfo;
var
  SavedUnresolved, SavedUncertain: TTokens;
  SavedRefs: TPtrMap;
  SavedRenamed, I: Integer;
  Toks: TTokens;
  Texts: TStringArray;
  T: TToken;
begin
  SavedUnresolved := Copy(Unresolved);
  SavedUncertain := Copy(Uncertain);
  SavedRefs := TPtrMap.Create;
  SavedRefs.Assign(Refs);
  SavedRenamed := Renamed;
  Toks := nil;
  Texts := nil;
  for T in D.Tokens do
    if T.Kind = tkIdent then
    begin
      PushTok(Toks, T);
      SetLength(Texts, Length(Texts) + 1);
      Texts[High(Texts)] := T.Text;
    end;
  try
    Result := Designator(D, Scope, Withs);
  finally
    Unresolved := SavedUnresolved;
    Uncertain := SavedUncertain;
    Refs.Assign(SavedRefs);
    SavedRefs.Free;
    Renamed := SavedRenamed;
    for I := 0 to High(Toks) do
      Toks[I].Text := Texts[I];
  end;
end;

procedure TBinder.ResolveValue(V: TObject; T: TTInfo; Scope: TScope; const Withs: TWiths);
var
  Kids: TKids;
  I: Integer;
  X: TObject;
  F: TSym;
  Sub: TTInfo;
begin
  if not (V is TNode) then
    Exit;
  if TNode(V).Kind <> nkAggregate then
  begin
    ResolveExpr(V, Scope, Withs);
    Exit;
  end;
  Kids := TNode(V).Kids;
  I := 0;
  while I < Length(Kids) do
  begin
    X := Kids[I];
    if (X is TToken) and (TToken(X).Kind = tkIdent) and (I + 1 < Length(Kids)) and IsTok(Kids[I + 1], ':') then
    begin
      F := nil;
      if (T <> nil) and (T.Kind = tiRecord) then
        F := TSym(T.GetFields.Get(LowerText(TToken(X).Text)));
      if F <> nil then
        Note(TToken(X), F)
      else
        PushTok(Unresolved, TToken(X));
      if F <> nil then
        Sub := TiOfSym(F)
      else
        Sub := nil;
      if I + 2 < Length(Kids) then
        ResolveValue(Kids[I + 2], Sub, Scope, Withs);
      Inc(I, 3);
      Continue;
    end;
    if X is TNode then
    begin
      if (T <> nil) and (T.Kind = tiArray) then
        Sub := Peel(T, 1)
      else
        Sub := nil;
      ResolveValue(X, Sub, Scope, Withs);
    end;
    Inc(I);
  end;
end;

procedure TBinder.Run;
var
  Root: TObject;
begin
  if Res.Tree.Kids = nil then
    Exit;
  Root := Res.Tree.Kids[0];
  if IsNodeOf(Root, nkUnit) then
    RunUnit(TNode(Root))
  else if IsNodeOf(Root, nkProgram) then
    RunProgram(TNode(Root));
end;

function DeclItems(Part: TNode): TNodes;
begin
  Result := NodeKidsExcept(Part, [nkUsesClause]);
end;

procedure TBinder.RunUnit(U: TNode);
var
  Iface, Impl, Init: TNode;
  SysScope, IU, IfS, MU, IfS2, ImS: TScope;
  Own: TSym;
  Items, MItems: TNodes;
  X: TObject;
begin
  Iface := FirstKid(U, nkInterface);
  Impl := FirstKid(U, nkImplementation);
  if Iface = nil then
    Exit;
  SysScope := SystemScope;
  IU := UsesScope(FirstKid(Iface, nkUsesClause), SysScope);
  IfS := NewScope(IfaceTable, IU);
  Own := TSym(Keep(TSym.Create(KT(Kid(Kid(U, 1), 0)).Text, skUnit)));
  Own.UnitInfo := TUnitInfo(Keep(TUnitInfo.Create));
  Own.UnitInfo.Name := Own.Name;
  Own.UnitInfo.Exports_ := IfaceTable;
  IfS.Parent.Table.SetDefault(LowerText(Own.Name), Own);
  Items := DeclItems(Iface);
  Collect(Items, IfS);
  if ExportOnly then
  begin
    if Impl <> nil then
      Collect(DeclItems(Impl), NewScope(nil, nil), IfaceTable);
    Exit;
  end;
  SetLength(NodeScopes, Length(NodeScopes) + 1);
  NodeScopes[High(NodeScopes)].Node := Iface;
  NodeScopes[High(NodeScopes)].Scope := IfS;
  ResolveDecls(Items, IfS);
  if Impl = nil then
    Exit;
  MU := UsesScope(FirstKid(Impl, nkUsesClause), IU);
  IfS2 := NewScope(IfaceTable, MU);
  ImS := NewScope(nil, IfS2);
  SetLength(NodeScopes, Length(NodeScopes) + 1);
  NodeScopes[High(NodeScopes)].Node := Impl;
  NodeScopes[High(NodeScopes)].Scope := ImS;
  MItems := DeclItems(Impl);
  Collect(MItems, ImS, IfaceTable);
  ResolveDecls(MItems, ImS);
  BindBodies(MItems, ImS);
  Init := FirstKid(U, nkInitSection);
  if Init <> nil then
    for X in Init.Kids do
      if IsNodeOf(X, nkCompound) then
        ResolveStmt(TNode(X), ImS, nil);
end;

procedure TBinder.RunProgram(P: TNode);
var
  SysScope, US, Scope: TScope;
  Block: TNode;
  Items: TNodes;
  X: TObject;
begin
  SysScope := SystemScope;
  US := UsesScope(FirstKid(P, nkUsesClause), SysScope);
  Scope := NewScope(nil, US);
  SetLength(NodeScopes, Length(NodeScopes) + 1);
  NodeScopes[High(NodeScopes)].Node := P;
  NodeScopes[High(NodeScopes)].Scope := Scope;
  Block := FirstKid(P, nkBlock);
  if Block = nil then
    Exit;
  Items := NodeKidsExcept(Block, [nkCompound, nkAsm]);
  Collect(Items, Scope);
  ResolveDecls(Items, Scope);
  BindBodies(Items, Scope);
  for X in Block.Kids do
    if IsNodeOf(X, nkCompound) then
      ResolveStmt(TNode(X), Scope, nil);
end;

function InNames(const S: string; const Names: array of string): Boolean;
var
  N: string;
begin
  for N in Names do
    if N = S then
      Exit(True);
  Result := False;
end;

function NormalizeCaseKeep(Res: TParseResult; Provider: TProvider; out Binder: TBinder): TReport;
var
  T: TToken;
  N: TNode;
  K: TObject;
  B: TBinder;
begin
  for T in Res.Sig do
    if T.Kind = tkKW then
      T.Text := LowerCase(T.Text);
  for N in Res.Tree.Walk do
    if N.Kind = nkDirectives then
    begin
      for K in N.Kids do
        if (K is TToken) and (TToken(K).Kind = tkIdent) and InNames(TToken(K).Lower, RoutineDirectives) then
          TToken(K).Text := TToken(K).Lower;
    end
    else if (N.Kind in [nkAbsolute, nkSection]) and (N.Kids <> nil) and (N.Kids[0] is TToken) then
      TToken(N.Kids[0]).Text := TToken(N.Kids[0]).Lower;
  B := TBinder.Create(Res, Provider);
  try
    B.Run;
    Result.Renamed := B.Renamed;
    Result.Unresolved := B.Unresolved;
    Result.Uncertain := B.Uncertain;
    Result.MissingUnits := B.MissingUnits;
  except
    B.Free;
    raise;
  end;
  Binder := B;
end;

function NormalizeCase(Res: TParseResult; Provider: TProvider): TReport;
var
  B: TBinder;
begin
  Result := NormalizeCaseKeep(Res, Provider, B);
  B.Free;
end;

initialization
  GlobalArena := TObjectList.Create(True);
  UnknownTi := TTInfo.Create(tiUnknown, GlobalArena);
  PrimTi := TTInfo.Create(tiPrim, GlobalArena);
  StringTi := TTInfo.Create(tiString, GlobalArena);
  GlobalArena.Add(UnknownTi);
  GlobalArena.Add(PrimTi);
  GlobalArena.Add(StringTi);
  UncertainSym := TSym.Create('<uncertain>', skVar);
  GlobalArena.Add(UncertainSym);
  EmptyTable := TSymTable.Create;
  GlobalArena.Add(EmptyTable);

finalization
  FreeAndNil(LibLoader);
  FreeImages(LibImages_);
  GlobalArena.Free;
end.
