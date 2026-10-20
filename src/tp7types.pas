unit tp7types;

{$mode objfpc}{$H+}

interface

uses
  Classes, Contnrs, SysUtils, tp7lex, tp7parse, tpudump, tp7sema, tp7maps;

type
  TTyKind = (tyUnknown, tyVoid, tyInt, tyReal, tyBool, tyChar, tyString, tyEnum, tySet, tyArray, tyRecord, tyObject,
    tyPointer, tyFile, tyProc, tyNil);
  TLazyKind = (lzNone, lzValue, lzTypeSym, lzTDesc, lzHeritage);

  TTy = class;
  TTypes = class;
  TTys = array of TTy;

  TSpec = class
  public
    Kind: string;
    Ty: TTy;
    Name: string;
    Open: Boolean;
  end;

  TSpecs = array of TSpec;

  TTy = class
  private
    FTarget, FAnc: TTy;
    TargetKind, AncKind: TLazyKind;
  public
    Kind: TTyKind;
    Name: string;
    Sym: TSym;
    Builtin: Boolean;
    HasLo, HasHi: Boolean;
    Lo, Hi: Int64;
    HasValue: Boolean;
    Value: Int64;
    Host: TTy;
    Elem: TTy;
    Index: TTys;
    HasMaxLen: Boolean;
    MaxLen: Int64;
    Open, Text, Comp: Boolean;
    Params: TSpecs;
    Result: TTy;
    HasStrLit: Boolean;
    StrLit: Int64;
    Types: TTypes;
    LazySym: TSym;
    LazyDesc: TTypeDesc;
    LazyHome: string;
    LazyNode: TObject;
    LazyScope: TScope;
    LazyBinder: TBinder;
    AncDesc: TTypeDesc;
    AncHome: string;
    function Target: TTy;
    function Ancestor: TTy;
    procedure SetTarget(T: TTy);
  end;

  TTypes = class
  private
    FArena: TObjectList;
    FSym, FTSym, FNode, FTd: TPtrMap;
    FBusy: TFPList;
    function OfSymUncached(Sym: TSym): TTy;
    function ConstTy(Sym: TSym): TTy;
    function OfTNodeUncached(Node: TNode; Scope: TScope; Binder: TBinder): TTy;
    function OfTDescUncached(TD: TTypeDesc; const Home: string): TTy;
  public
    Provider: TProvider;
    constructor Create(AProvider: TProvider);
    destructor Destroy; override;
    function NewTy(Kind: TTyKind; const Name: string = ''): TTy;
    function NewSpec(const Kind: string; Ty: TTy; const Name: string; Open: Boolean): TSpec;
    function IntConst(V: Int64): TTy;
    function CommonInt(A, B: TTy): TTy;
    function OfSym(Sym: TSym): TTy;
    function OfTypeSym(Sym: TSym): TTy;
    function OfTNode(Node: TObject; Scope: TScope; Binder: TBinder): TTy;
    function OfTDesc(TD: TTypeDesc; const Home: string): TTy;
    function SpecsOfParams(Params: TNode; Scope: TScope; Binder: TBinder): TSpecs;
    function SpecsOfSym(Sym: TSym; out Specs: TSpecs): Boolean;
  end;

  TR = record
    Ty: TTy;
    LValue: Boolean;
    Sym: TSym;
    Tok: TToken;
  end;

  TRs = array of TR;

  TRefSource = class
  public
    function Ref(Tok: TToken): TSym; virtual; abstract;
  end;

  TBinderRefs = class(TRefSource)
  public
    Binder: TBinder;
    constructor Create(ABinder: TBinder);
    function Ref(Tok: TToken): TSym; override;
  end;

  TReportProc = procedure(Tok: TToken; const Msg: string) of object;
  TCallProc = procedure(const Name: string; const Specs: TSpecs; const Args: TNodes) of object;

  TStateKind = (stValue, stRoutine, stType, stBuiltin, stUnknown);

  TState = record
    Kind: TStateKind;
    Ty: TTy;
    LValue: Boolean;
    Sym: TSym;
  end;

  TTyper = class
  private
    FDone: TPtrMap;
    function NewR(Ty: TTy; LValue: Boolean = False; Sym: TSym = nil; Tok: TToken = nil): TR;
    function StringLit(E: TNode): TTy;
    function SetCtor(E: TNode): TTy;
    function Unary(E: TNode): TR;
    function Binary(E: TNode): TR;
    function Inner(const Steps: TKids): TR;
    function IndexExprs(St: TNode): TRs;
    function Start(Sym: TSym): TState;
    function IndexOf_(Ty: TTy; St: TNode): TTy;
    function IndexMore(Elem: TTy; const Rs: TRs; St: TNode): TTy;
    procedure IndexCheck(Want: TTy; const R: TR; St: TNode);
    function Call(Sym: TSym; ArgsNode: TNode; Tok: TToken): TState;
    function CallValue(Ty: TTy; St: TNode; Tok: TToken): TState;
    function Magic(Sym: TSym; ArgsNode: TNode): TState;
    procedure CheckArgs(const Name: string; const Specs: TSpecs; HasSpecs: Boolean; ArgsNode: TNode; Tok: TToken);
    procedure CheckArg(const Name: string; I: Integer; Sp: TSpec; const R: TR; A: TNode);
  public
    Types: TTypes;
    RefOf: TRefSource;
    Report: TReportProc;
    OnCall: TCallProc;
    constructor Create(ATypes: TTypes; ARefOf: TRefSource; AReport: TReportProc);
    destructor Destroy; override;
    procedure Rep(Where: TObject; const Msg: string);
    function Expr(E: TObject; ProcVal: Boolean = False): TR;
    function Designator(D: TNode; Lhs: Boolean = False; ProcVal: Boolean = False): TR;
  end;

  TChecker = class
  private
    FRefs: TBinderRefs;
    procedure Condition(E: TObject);
    procedure StAssign(N: TNode);
    procedure StFor(N: TNode);
    procedure StCase(N: TNode);
  public
    Res: TParseResult;
    Binder: TBinder;
    Types: TTypes;
    T: TTyper;
    constructor Create(ARes: TParseResult; ABinder: TBinder; AProvider: TProvider; AReport: TReportProc);
    destructor Destroy; override;
    procedure Run;
  end;

  TInlayParam = record
    Tok: TToken;
    Text: string;
  end;

  TInlayEnd = record
    Tok: TToken;
    Name: string;
    Lines: Integer;
  end;

  TInlayData = record
    Params: array of TInlayParam;
    Consts: array of TInlayParam;
    Ends: array of TInlayEnd;
  end;

  TExprAt = class
  public
    Types: TTypes;
    Node: TNode;
    Tokens: TTokens;
    Ty: TTy;
    destructor Destroy; override;
  end;

var
  UnknownTy, VoidTy, NilTy, ByteTy, ShortIntTy, IntegerTy, WordTy, LongintTy, RealTy, SingleTy, DoubleTy, ExtendedTy,
  CompTy, BooleanTy, ByteBoolTy, WordBoolTy, LongBoolTy, CharTy, StringTy, PointerTy, TextTy, UntypedFileTy,
  FloatTy: TTy;

function Show(T: TTy): string;
function AssignError(Dst, Src: TTy): string;
function VarParamError(SpecTy, Arg: TTy): string;
function Derives(T, Anc: TTy): Boolean;
function IsOrdinal(T: TTy): Boolean;
procedure CheckTypes(Res: TParseResult; Binder: TBinder; Provider: TProvider; Report: TReportProc);
function ConstTypeName(T: TTy): string;
function InlayData(Res: TParseResult; Binder: TBinder; Provider: TProvider): TInlayData;
procedure RoutineNamesOf(R: TNode; out OwnerName, Name: string);
function TypeText(T: TTy; Depth: Integer = 0): string;
function ExprAt(Tree: TNode; RefOf: TRefSource; Provider: TProvider; Tok: TToken): TExprAt;

implementation

uses
  Math, tp7enc;

var
  GlobalTys: TObjectList;
  IntHost, BoolHost, CharHost: TTy;

const
  OrdinalKinds = [tyInt, tyBool, tyChar, tyEnum];
  KindNames: array[TTyKind] of string = ('unknown', 'void', 'int', 'real', 'bool', 'char', 'string', 'enum', 'set',
    'array', 'record', 'object', 'pointer', 'file', 'proc', 'nil');

function MakeBuiltin(Kind: TTyKind; const Name: string): TTy;
begin
  Result := TTy.Create;
  GlobalTys.Add(Result);
  Result.Kind := Kind;
  Result.Name := Name;
  Result.Builtin := True;
end;

function MakeRange(Kind: TTyKind; const Name: string; Lo, Hi: Int64): TTy;
begin
  Result := MakeBuiltin(Kind, Name);
  Result.HasLo := True;
  Result.HasHi := True;
  Result.Lo := Lo;
  Result.Hi := Hi;
end;

function BuiltinByName(const Lower: string): TTy;
begin
  case Lower of
    'byte': Result := ByteTy;
    'shortint': Result := ShortIntTy;
    'integer': Result := IntegerTy;
    'word': Result := WordTy;
    'longint': Result := LongintTy;
    'real': Result := RealTy;
    'single': Result := SingleTy;
    'double': Result := DoubleTy;
    'extended': Result := ExtendedTy;
    'comp': Result := CompTy;
    'boolean': Result := BooleanTy;
    'bytebool': Result := ByteBoolTy;
    'wordbool': Result := WordBoolTy;
    'longbool': Result := LongBoolTy;
    'char': Result := CharTy;
    'string': Result := StringTy;
    'pointer': Result := PointerTy;
    'text': Result := TextTy;
  else
    Result := nil;
  end;
end;

function IsOrdinal(T: TTy): Boolean;
begin
  Result := T.Kind in OrdinalKinds;
end;

{ TTy }

function TTy.Target: TTy;
var
  T: TTy;
begin
  case TargetKind of
    lzValue:
      Exit(FTarget);
    lzTypeSym:
      begin
        if (LazySym <> nil) and (LazySym.Kind = skType) then
          T := Types.OfTypeSym(LazySym)
        else
          T := UnknownTy;
      end;
    lzTDesc:
      T := Types.OfTDesc(LazyDesc, LazyHome);
  else
    Exit(nil);
  end;
  FTarget := T;
  TargetKind := lzValue;
  Result := T;
end;

procedure TTy.SetTarget(T: TTy);
begin
  FTarget := T;
  TargetKind := lzValue;
end;

function TTy.Ancestor: TTy;
var
  S: TSym;
  T: TTy;
begin
  case AncKind of
    lzValue:
      Exit(FAnc);
    lzHeritage:
      begin
        S := LazyBinder.TypeSym(LazyNode, LazyScope);
        if (S <> nil) and (S.Kind = skType) then
          T := Types.OfTypeSym(S)
        else
          T := UnknownTy;
      end;
    lzTDesc:
      T := Types.OfTDesc(AncDesc, AncHome);
  else
    Exit(nil);
  end;
  FAnc := T;
  AncKind := lzValue;
  Result := T;
end;

{ rules }

function Show(T: TTy): string;
var
  Tg: TTy;
begin
  if T = nil then
    Exit('?');
  if (T.Name <> '') and not ((T.Kind = tyInt) and T.HasValue) then
    Exit(T.Name);
  case T.Kind of
    tyInt:
      if T.HasValue then
        Result := 'integer constant'
      else
        Result := 'integer';
    tyString:
      if T.HasStrLit then
        Result := 'string constant'
      else
        Result := 'string';
    tyPointer:
      begin
        Tg := T.Target;
        if Tg <> nil then
          Result := '^' + Show(Tg)
        else
          Result := 'Pointer';
      end;
    tySet:
      if T.Elem <> nil then
        Result := 'set of ' + Show(T.Elem)
      else
        Result := 'set';
    tyArray:
      Result := 'array';
    tyProc:
      if T.Result <> nil then
        Result := 'function'
      else
        Result := 'procedure';
    tyEnum:
      Result := 'enumeration';
    tyRecord:
      Result := 'record';
    tyObject:
      Result := 'object';
    tyFile:
      Result := 'file';
    tyReal:
      Result := 'Real';
    tyChar:
      Result := 'Char';
    tyBool:
      Result := 'Boolean';
    tyNil:
      Result := 'nil';
  else
    Result := KindNames[T.Kind];
  end;
end;

function OrdinalHost(T: TTy): TTy;
begin
  case T.Kind of
    tyInt:
      Result := IntHost;
    tyBool:
      Result := BoolHost;
    tyChar:
      Result := CharHost;
    tyEnum:
      if T.Host <> nil then
        Result := T.Host
      else
        Result := T;
  else
    Result := nil;
  end;
end;

function IsCharArray(T: TTy): Boolean;
begin
  Result := (T.Kind = tyArray) and (T.Elem <> nil) and (T.Elem.Kind = tyChar);
end;

function Derives(T, Anc: TTy): Boolean;
var
  N: Integer;
begin
  N := 0;
  while (T <> nil) and (N < 50) do
  begin
    if T = Anc then
      Exit(True);
    T := T.Ancestor;
    Inc(N);
  end;
  Result := False;
end;

function OutOfRange(Dst: TTy; V: Int64): Boolean;
begin
  if not (Dst.Lo <= V) then
    Exit(True);
  if not Dst.HasHi then
    raise EBroken.Create('TypeError: comparison with None');
  Result := not (V <= Dst.Hi);
end;

function AssignError(Dst, Src: TTy): string;
var
  Bad: string;
  HA, HB, A, B: TTy;
begin
  Result := '';
  if (Dst = Src) or (Dst.Kind in [tyUnknown, tyVoid]) or (Src.Kind in [tyUnknown, tyVoid]) then
    Exit;
  Bad := 'cannot assign ' + Show(Src) + ' to ' + Show(Dst);
  case Dst.Kind of
    tyInt:
      begin
        if Src.Kind <> tyInt then
          Exit(Bad);
        if Src.HasValue and Dst.HasLo and OutOfRange(Dst, Src.Value) then
          Exit(Format('constant %d is out of range for %s (%d..%d)', [Src.Value, Show(Dst), Dst.Lo, Dst.Hi]));
      end;
    tyReal:
      if not (Src.Kind in [tyInt, tyReal]) then
        Result := Bad;
    tyBool:
      if Src.Kind <> tyBool then
        Result := Bad;
    tyChar:
      begin
        if Src.Kind <> tyChar then
          Exit(Bad);
        if Src.HasValue and Dst.HasLo and OutOfRange(Dst, Src.Value) then
          Exit('constant is out of range for ' + Show(Dst));
      end;
    tyString:
      if not ((Src.Kind in [tyString, tyChar]) or IsCharArray(Src) or (Src.Kind = tyPointer)) then
        Result := Bad;
    tyEnum:
      begin
        if Src.Kind <> tyEnum then
          Exit(Bad);
        if OrdinalHost(Dst) <> OrdinalHost(Src) then
          Result := Bad;
      end;
    tySet:
      begin
        if Src.Kind <> tySet then
          Exit(Bad);
        A := Dst.Elem;
        B := Src.Elem;
        if (A = nil) or (B = nil) or (A.Kind = tyUnknown) or (B.Kind = tyUnknown) then
          Exit;
        HA := OrdinalHost(A);
        HB := OrdinalHost(B);
        if not ((HA = nil) or (HB = nil) or (HA = HB)) then
          Result := Bad;
      end;
    tyPointer:
      begin
        if Src.Kind = tyNil then
          Exit;
        if Src.Kind in [tyString, tyArray] then
        begin
          if ((Dst.Target <> nil) and (Dst.Target.Kind = tyChar)) or (Src.Kind = tyArray) then
            Exit;
          Exit(Bad);
        end;
        if Src.Kind <> tyPointer then
          Exit(Bad);
        A := Dst.Target;
        B := Src.Target;
        if (A = nil) or (B = nil) or (A = B) or (A.Kind = tyUnknown) or (B.Kind = tyUnknown) then
          Exit;
        if A.Kind <> B.Kind then
          Exit(Bad);
        if (A.Kind = tyObject) and (Derives(B, A) or Derives(A, B)) then
          Exit;
        if (A.Kind in [tyRecord, tyObject]) and (A.Sym <> nil) and (B.Sym <> nil) then
          Exit(Bad);
      end;
    tyProc:
      if not (Src.Kind in [tyNil, tyProc, tyPointer]) then
        Result := Bad;
    tyObject:
      begin
        if Src.Kind <> tyObject then
          Exit(Bad);
        if not (Derives(Src, Dst) or (Dst.Sym = nil) or (Src.Sym = nil)) then
          Result := Bad;
      end;
    tyRecord:
      begin
        if Src.Kind <> tyRecord then
          Exit(Bad);
        if not ((Dst.Sym = nil) or (Src.Sym = nil)) then
          Result := Bad;
      end;
    tyArray:
      begin
        if (Src.Kind = tyString) and IsCharArray(Dst) then
          Exit;
        if Src.Kind <> tyArray then
          Exit(Bad);
        if not ((Dst.Sym = nil) or (Src.Sym = nil)) then
          Result := Bad;
      end;
    tyFile:
      if Src.Kind <> tyFile then
        Result := Bad;
  end;
end;

function VarParamError(SpecTy, Arg: TTy): string;
const
  Plain = [tyInt, tyReal, tyBool, tyChar, tyString, tyEnum, tySet, tyRecord, tyObject];
var
  Bad: string;
begin
  Result := '';
  if (SpecTy.Kind = tyUnknown) or (Arg.Kind = tyUnknown) or (SpecTy = Arg) then
    Exit;
  Bad := 'a variable of type ' + Show(SpecTy) + ' is required, not ' + Show(Arg);
  if SpecTy.Kind <> Arg.Kind then
  begin
    if (SpecTy.Kind = tyString) and (Arg.Kind in [tyChar, tyArray]) then
      Exit;
    if (Arg.Kind in Plain) and (SpecTy.Kind in Plain) then
      Result := Bad;
    Exit;
  end;
  if (SpecTy.Kind in [tyInt, tyReal, tyBool, tyChar]) and SpecTy.Builtin and Arg.Builtin then
  begin
    if SpecTy <> Arg then
      Result := Bad;
    Exit;
  end;
  if (SpecTy.Kind in [tyRecord, tyEnum]) and (SpecTy.Sym <> nil) and (Arg.Sym <> nil) then
    Exit(Bad);
  if (SpecTy.Kind = tyObject) and (SpecTy.Sym <> nil) and (Arg.Sym <> nil) and not Derives(Arg, SpecTy) then
    Exit(Bad);
end;

{ TTypes }

constructor TTypes.Create(AProvider: TProvider);
begin
  Provider := AProvider;
  FArena := TObjectList.Create(True);
  FSym := TPtrMap.Create;
  FTSym := TPtrMap.Create;
  FNode := TPtrMap.Create;
  FTd := TPtrMap.Create;
  FBusy := TFPList.Create;
end;

destructor TTypes.Destroy;
begin
  FArena.Free;
  FSym.Free;
  FTSym.Free;
  FNode.Free;
  FTd.Free;
  FBusy.Free;
  inherited Destroy;
end;

function TTypes.NewTy(Kind: TTyKind; const Name: string): TTy;
begin
  Result := TTy.Create;
  FArena.Add(Result);
  Result.Kind := Kind;
  Result.Name := Name;
  Result.Types := Self;
end;

function TTypes.NewSpec(const Kind: string; Ty: TTy; const Name: string; Open: Boolean): TSpec;
begin
  Result := TSpec.Create;
  FArena.Add(Result);
  Result.Kind := Kind;
  Result.Ty := Ty;
  Result.Name := Name;
  Result.Open := Open;
end;

function TTypes.IntConst(V: Int64): TTy;
begin
  Result := NewTy(tyInt);
  Result.HasLo := True;
  Result.HasHi := True;
  Result.Lo := V;
  Result.Hi := V;
  Result.HasValue := True;
  Result.Value := V;
end;

function TTypes.CommonInt(A, B: TTy): TTy;
var
  Lo, Hi: Int64;
  T: TTy;
begin
  for T in [A, B] do
    if not (T.Builtin or T.HasValue) or not T.HasLo or not T.HasHi then
      Exit(NewTy(tyInt));
  Lo := Min(A.Lo, B.Lo);
  Hi := Max(A.Hi, B.Hi);
  for T in [ShortIntTy, ByteTy, IntegerTy, WordTy, LongintTy] do
    if (T.Lo <= Lo) and (Hi <= T.Hi) then
    begin
      if (T = ShortIntTy) or (T = ByteTy) then
        Exit(NewTy(tyInt));
      Exit(T);
    end;
  Result := NewTy(tyInt);
end;

function TTypes.OfSym(Sym: TSym): TTy;
var
  T: TTy;
begin
  if FSym.Has(Sym) then
    Exit(TTy(FSym.Get(Sym)));
  if FBusy.IndexOf(Sym) >= 0 then
    Exit(UnknownTy);
  FBusy.Add(Sym);
  try
    T := OfSymUncached(Sym);
  finally
    FBusy.Remove(Sym);
  end;
  FSym.Put(Sym, T);
  Result := T;
end;

function TTypes.OfSymUncached(Sym: TSym): TTy;
begin
  case Sym.Kind of
    skVar, skParam, skField:
      begin
        if Sym.Lib then
          Exit(OfTDesc(Sym.TDesc, Sym.Home));
        if Sym.Implicit and (Sym.Owner <> nil) then
          Exit(OfTypeSym(Sym.Owner));
        if Sym.TNode = nil then
          Exit(UnknownTy);
        Result := OfTNode(Sym.TNode, Sym.Scope, Sym.Binder);
      end;
    skConst:
      Result := ConstTy(Sym);
    skEnum:
      if Sym.TNode <> nil then
        Result := OfTNode(Sym.TNode, Sym.Scope, Sym.Binder)
      else
        Result := UnknownTy;
    skRoutine:
      begin
        if Sym.Lib then
        begin
          if Sym.TDesc <> nil then
            Exit(OfTDesc(Sym.TDesc, Sym.Home));
          Exit(VoidTy);
        end;
        if Sym.TNode = nil then
          Exit(VoidTy);
        Result := OfTNode(Sym.TNode, Sym.Scope, Sym.Binder);
      end;
  else
    Result := UnknownTy;
  end;
end;

type
  TScopeRefs = class(TRefSource)
  public
    Scope: TScope;
    function Ref(Tok: TToken): TSym; override;
  end;

function TScopeRefs.Ref(Tok: TToken): TSym;
begin
  if Scope = nil then
    Exit(nil);
  Result := Scope.Lookup(LowerText(Tok.Text));
end;

function TypeOfExpr(Types: TTypes; Scope: TScope; E: TObject): TTy;
var
  Refs: TScopeRefs;
  Typer: TTyper;
begin
  Refs := TScopeRefs.Create;
  Refs.Scope := Scope;
  Typer := TTyper.Create(Types, Refs, nil);
  try
    Result := Typer.Expr(E).Ty;
  finally
    Typer.Free;
    Refs.Free;
  end;
end;

function TTypes.ConstTy(Sym: TSym): TTy;
var
  D: TNode;
begin
  if Sym.Lib then
  begin
    Result := OfTDesc(Sym.TDesc, Sym.Home);
    if (Result.Kind = tyInt) and (Sym.CValueKind = vkInt) then
      Exit(IntConst(Sym.CInt));
    if (Result.Kind = tyChar) and (Sym.CValueKind = vkInt) then
    begin
      Result := NewTy(tyChar);
      Result.HasLo := True;
      Result.HasHi := True;
      Result.Lo := Sym.CInt;
      Result.Hi := Sym.CInt;
      Result.HasValue := True;
      Result.Value := Sym.CInt;
    end;
    Exit;
  end;
  if Sym.TNode <> nil then
    Exit(OfTNode(Sym.TNode, Sym.Scope, Sym.Binder));
  D := Sym.Node;
  if (D = nil) or (Length(D.Kids) < 3) or not (D.Kids[2] is TNode) then
    Exit(UnknownTy);
  Result := TypeOfExpr(Self, Sym.Scope, D.Kids[2]);
end;

function TTypes.OfTypeSym(Sym: TSym): TTy;
var
  T: TTy;
begin
  if FTSym.Has(Sym) then
    Exit(TTy(FTSym.Get(Sym)));
  if FBusy.IndexOf(Sym) >= 0 then
    Exit(UnknownTy);
  FBusy.Add(Sym);
  try
    if Sym.Lib then
    begin
      T := nil;
      if (Sym.Home <> '') and (LowerText(Sym.Home) = 'system') then
        T := BuiltinByName(LowerText(Sym.Name));
      if T = nil then
        if Sym.TDesc <> nil then
          T := OfTDesc(Sym.TDesc, Sym.Home)
        else
          T := UnknownTy;
    end
    else if Sym.TNode <> nil then
      T := OfTNode(Sym.TNode, Sym.Scope, Sym.Binder)
    else
      T := UnknownTy;
  finally
    FBusy.Remove(Sym);
  end;
  if (T.Sym = nil) and not T.Builtin and (T.Kind <> tyUnknown) then
  begin
    T.Sym := Sym;
    T.Name := Sym.Name;
  end;
  FTSym.Put(Sym, T);
  Result := T;
end;

function TTypes.OfTNode(Node: TObject; Scope: TScope; Binder: TBinder): TTy;
var
  T: TTy;
begin
  if not (Node is TNode) or (Binder = nil) then
    Exit(UnknownTy);
  if FNode.Has(Node) then
    Exit(TTy(FNode.Get(Node)));
  FNode.Put(Node, UnknownTy);
  try
    T := OfTNodeUncached(TNode(Node), Scope, Binder);
  except
    on EBroken do
      T := UnknownTy;
  end;
  FNode.Put(Node, T);
  Result := T;
end;

function TTypes.OfTNodeUncached(Node: TNode; Scope: TScope; Binder: TBinder): TTy;
var
  Sym, Owner: TSym;
  V, Lo, Hi, Res: TTy;
  IOf, I: Integer;
  Idx: TTys;
  Elem: TTy;
  Nm: TObject;
  Her, Params: TNode;
  HasColon: Boolean;
  X: TObject;
begin
  case Node.Kind of
    nkNamedType:
      begin
        KN(Kid(Node, 0));
        Sym := Binder.TypeSym(Kid(Node, 0), Scope);
        if (Sym <> nil) and (Sym.Kind = skType) then
          Exit(OfTypeSym(Sym));
        Result := UnknownTy;
      end;
    nkPackedType:
      Result := OfTNode(Kid(Node, 1), Scope, Binder);
    nkStringType:
      begin
        if (Length(Node.Kids) > 2) and (Node.Kids[2] is TNode) then
        begin
          Result := NewTy(tyString);
          Result.HasMaxLen := True;
          Result.MaxLen := 255;
          V := TypeOfExpr(Self, Scope, Node.Kids[2]);
          if (V.Kind = tyInt) and V.HasValue then
            Result.MaxLen := V.Value;
          Exit;
        end;
        Result := StringTy;
      end;
    nkEnumType:
      begin
        Result := NewTy(tyEnum);
        Owner := TSym(Binder.Owners.Get(Node));
        if Owner <> nil then
        begin
          Result.Sym := Owner;
          Result.Name := Owner.Name;
        end;
      end;
    nkSubrangeType:
      begin
        Lo := TypeOfExpr(Self, Scope, Kid(Node, 0));
        Hi := TypeOfExpr(Self, Scope, Kid(Node, 2));
        if Lo.Kind = tyEnum then
        begin
          Result := NewTy(tyEnum);
          if Lo.Host <> nil then
            Result.Host := Lo.Host
          else
            Result.Host := Lo;
        end
        else if (Lo.Kind = tyChar) or (Hi.Kind = tyChar) then
        begin
          Result := NewTy(tyChar);
          Result.HasLo := Lo.HasValue;
          Result.Lo := Lo.Value;
          Result.HasHi := Hi.HasValue;
          Result.Hi := Hi.Value;
        end
        else if Lo.Kind = tyInt then
        begin
          Result := NewTy(tyInt);
          Result.HasLo := Lo.HasValue;
          Result.Lo := Lo.Value;
          if Hi.Kind = tyInt then
          begin
            Result.HasHi := Hi.HasValue;
            Result.Hi := Hi.Value;
          end;
        end
        else if Lo.Kind = tyBool then
          Result := NewTy(tyBool)
        else
          Result := UnknownTy;
      end;
    nkArrayType:
      begin
        IOf := -1;
        for I := High(Node.Kids) downto 1 do
          if (Node.Kids[I] is TToken) and (TToken(Node.Kids[I]).Lower = 'of') then
          begin
            IOf := I;
            Break;
          end;
        if IOf < 0 then
          Exit(UnknownTy);
        Idx := nil;
        for I := 2 to IOf - 2 do
          if Node.Kids[I] is TNode then
          begin
            SetLength(Idx, Length(Idx) + 1);
            Idx[High(Idx)] := OfTNode(Node.Kids[I], Scope, Binder);
          end;
        Elem := OfTNode(Kid(Node, IOf + 1), Scope, Binder);
        Result := NewTy(tyArray);
        Result.Elem := Elem;
        Result.Index := Idx;
        Result.Open := Idx = nil;
      end;
    nkSetType:
      begin
        Elem := OfTNode(Kid(Node, -1), Scope, Binder);
        Result := NewTy(tySet);
        Result.Elem := Elem;
      end;
    nkFileType:
      if Length(Node.Kids) > 2 then
      begin
        Elem := OfTNode(Kid(Node, -1), Scope, Binder);
        Result := NewTy(tyFile);
        Result.Elem := Elem;
      end
      else
        Result := NewTy(tyFile);
    nkPointerType:
      begin
        Nm := Kid(Node, 1);
        Sym := nil;
        if Nm is TNode then
          Sym := Binder.TypeSym(Nm, Scope);
        if (KN(Nm).Kids <> nil) and (TNode(Nm).Kids[0] is TToken) and (TToken(TNode(Nm).Kids[0]).Lower = 'string') then
        begin
          Result := NewTy(tyPointer);
          Result.SetTarget(StringTy);
          Exit;
        end;
        Result := NewTy(tyPointer);
        Result.TargetKind := lzTypeSym;
        Result.LazySym := Sym;
      end;
    nkRecordType, nkObjectType:
      begin
        if Node.Kind = nkObjectType then
          Result := NewTy(tyObject)
        else
          Result := NewTy(tyRecord);
        Her := FirstKid(Node, nkHeritage);
        if (Her <> nil) and (Length(Her.Kids) > 1) and (Her.Kids[1] is TNode) then
        begin
          Result.AncKind := lzHeritage;
          Result.LazyNode := Her.Kids[1];
          Result.LazyScope := Scope;
          Result.LazyBinder := Binder;
        end;
      end;
    nkProcType:
      begin
        Params := FirstKid(Node, nkParams);
        Res := nil;
        HasColon := False;
        for X in Node.Kids do
          if (X is TToken) and (TToken(X).Text = ':') then
            HasColon := True;
        if HasColon and (Node.Kids[High(Node.Kids)] is TNode) then
          Res := OfTNode(Node.Kids[High(Node.Kids)], Scope, Binder);
        Result := NewTy(tyProc);
        Result.Params := SpecsOfParams(Params, Scope, Binder);
        Result.Result := Res;
      end;
  else
    Result := UnknownTy;
  end;
end;

function TTypes.SpecsOfParams(Params: TNode; Scope: TScope; Binder: TBinder): TSpecs;
var
  G, X: TObject;
  Kids: TKids;
  Kind, Name: string;
  Names: TNodes;
  HasType, Opn: Boolean;
  TN: TObject;
  Ty: TTy;
  Nm: TNode;
begin
  Result := nil;
  if Params = nil then
    Exit;
  for G in Params.Kids do
  begin
    if not IsNodeOf(G, nkParamGroup) then
      Continue;
    Kids := TNode(G).Kids;
    Kind := 'value';
    if (Kids <> nil) and (Kids[0] is TToken) and ((TToken(Kids[0]).Lower = 'var') or (TToken(Kids[0]).Lower = 'const')) then
      Kind := TToken(Kids[0]).Lower;
    Names := nil;
    HasType := False;
    for X in Kids do
    begin
      if IsNodeOf(X, nkDeclName) then
      begin
        SetLength(Names, Length(Names) + 1);
        Names[High(Names)] := TNode(X);
      end;
      if (X is TToken) and (TToken(X).Text = ':') then
        HasType := True;
    end;
    TN := nil;
    if HasType and (Kids[High(Kids)] is TNode) then
      TN := Kids[High(Kids)];
    Ty := nil;
    Opn := False;
    if TN <> nil then
    begin
      Ty := OfTNode(TN, Scope, Binder);
      if (Ty.Kind = tyArray) and Ty.Open then
      begin
        Ty := Ty.Elem;
        Opn := True;
      end;
    end;
    for Nm in Names do
    begin
      if Nm.Kids <> nil then
        Name := TToken(Nm.Kids[0]).Text
      else
        Name := '';
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := NewSpec(Kind, Ty, Name, Opn);
    end;
  end;
end;

function TTypes.OfTDesc(TD: TTypeDesc; const Home: string): TTy;
var
  T: TTy;
begin
  if TD = nil then
    Exit(UnknownTy);
  if FTd.Has(TD) then
    Exit(TTy(FTd.Get(TD)));
  FTd.Put(TD, UnknownTy);
  T := OfTDescUncached(TD, Home);
  FTd.Put(TD, T);
  Result := T;
end;

function TTypes.OfTDescUncached(TD: TTypeDesc; const Home: string): TTy;
var
  UName, N: string;
  U: TUnitInfo;
  Sym: TSym;
  Idx, Elem: TTy;
  P: TParam;
  Ty: TTy;
  Kind: string;
begin
  case TD.Kind of
    tdNamed:
      begin
        N := TD.Name;
        UName := TD.UnitOf;
        if UName = '' then
          UName := Home;
        if (UName <> '') and (LowerText(UName) = 'system') and (BuiltinByName(LowerText(N)) <> nil) then
          Exit(BuiltinByName(LowerText(N)));
        if N = 'string' then
          Exit(StringTy);
        if (N = 'file') and (LowerText(UName) = 'system') then
          Exit(UntypedFileTy);
        U := nil;
        if UName <> '' then
        begin
          if Provider = nil then
            raise EBroken.Create('AttributeError: no provider');
          U := Provider.Get(UName);
        end;
        Sym := nil;
        if U <> nil then
          Sym := TSym(U.Exports_.Get(LowerText(N)));
        if (Sym <> nil) and (Sym.Kind = skType) then
          Exit(OfTypeSym(Sym));
        Result := UnknownTy;
      end;
    tdUnresolved:
      Result := UnknownTy;
    tdSubrange:
      begin
        if TD.Chars then
          Result := NewTy(tyChar)
        else
          Result := NewTy(tyInt);
        Result.HasLo := True;
        Result.HasHi := True;
        Result.Lo := TD.Lo;
        Result.Hi := TD.Hi;
      end;
    tdArray:
      begin
        Idx := OfTDesc(TD.Index, Home);
        Elem := OfTDesc(TD.Elem, Home);
        Result := NewTy(tyArray);
        if (Elem.Kind = tyArray) and not Elem.Open and (Elem.Sym = nil) and (Elem.Index <> nil) then
        begin
          Result.Elem := Elem.Elem;
          Result.Index := Concat([Idx], Elem.Index);
        end
        else
        begin
          Result.Elem := Elem;
          Result.Index := [Idx];
        end;
      end;
    tdRecord:
      Result := NewTy(tyRecord);
    tdObject:
      begin
        Result := NewTy(tyObject);
        if TD.Ancestor <> nil then
        begin
          Result.AncKind := lzTDesc;
          Result.AncDesc := TD.Ancestor;
          Result.AncHome := Home;
        end;
      end;
    tdPointer:
      begin
        Result := NewTy(tyPointer);
        Result.TargetKind := lzTDesc;
        Result.LazyDesc := TD.Target;
        Result.LazyHome := Home;
      end;
    tdString:
      begin
        Result := NewTy(tyString);
        Result.HasMaxLen := True;
        Result.MaxLen := TD.MaxLen;
      end;
    tdSet:
      begin
        Elem := OfTDesc(TD.Base, Home);
        Result := NewTy(tySet);
        Result.Elem := Elem;
      end;
    tdFile:
      begin
        Elem := OfTDesc(TD.Elem, Home);
        Result := NewTy(tyFile);
        Result.Elem := Elem;
      end;
    tdProc:
      begin
        Result := NewTy(tyProc);
        for P in TD.Params do
        begin
          if (P.Kind = 'var') or (P.Kind = 'const') then
            Kind := P.Kind
          else
            Kind := 'value';
          if P.TypeDesc <> nil then
            Ty := OfTDesc(P.TypeDesc, Home)
          else
            Ty := nil;
          SetLength(Result.Params, Length(Result.Params) + 1);
          Result.Params[High(Result.Params)] := NewSpec(Kind, Ty, P.Name, P.Open);
        end;
        if TD.Result <> nil then
          Result.Result := OfTDesc(TD.Result, Home);
      end;
    tdEnum:
      Result := NewTy(tyEnum);
  else
    Result := UnknownTy;
  end;
end;

function TTypes.SpecsOfSym(Sym: TSym; out Specs: TSpecs): Boolean;
var
  P: TParam;
  Ty: TTy;
  Kind: string;
begin
  Specs := nil;
  if Sym.Lib then
  begin
    if (Sym.Kind = skBuiltin) or not Sym.HasLParams then
      Exit(False);
    for P in Sym.LParams do
    begin
      if P.TypeDesc <> nil then
        Ty := OfTDesc(P.TypeDesc, Sym.Home)
      else
        Ty := nil;
      if (P.Kind = 'var') or (P.Kind = 'const') then
        Kind := P.Kind
      else
        Kind := 'value';
      SetLength(Specs, Length(Specs) + 1);
      Specs[High(Specs)] := NewSpec(Kind, Ty, P.Name, P.Open);
    end;
    Exit(True);
  end;
  if (Sym.Node = nil) or (Sym.Binder = nil) then
    Exit(False);
  Specs := SpecsOfParams(Sym.HeaderParams, Sym.Scope, Sym.Binder);
  Result := True;
end;

{ TBinderRefs }

constructor TBinderRefs.Create(ABinder: TBinder);
begin
  Binder := ABinder;
end;

function TBinderRefs.Ref(Tok: TToken): TSym;
begin
  Result := TSym(Binder.Refs.Get(Tok));
end;

{ TTyper }

function MagicResult(const Name: string): TTy;
begin
  case Name of
    'length', 'pos', 'hi', 'lo':
      Result := ByteTy;
    'copy', 'concat':
      Result := StringTy;
    'upcase', 'chr', 'readkey':
      Result := CharTy;
    'ord', 'round', 'trunc', 'filepos', 'filesize', 'memavail', 'maxavail':
      Result := LongintTy;
    'odd', 'eof', 'eoln', 'seekeof', 'seekeoln', 'keypressed':
      Result := BooleanTy;
    'sizeof', 'seg', 'ofs', 'cseg', 'dseg', 'sseg', 'sptr':
      Result := WordTy;
    'addr', 'ptr':
      Result := PointerTy;
    'sqrt', 'sin', 'cos', 'arctan', 'exp', 'ln', 'frac', 'int', 'pi':
      Result := FloatTy;
    'paramcount', 'ioresult':
      Result := IntegerTy;
  else
    Result := nil;
  end;
end;

function MagicArray(const Name: string): TTy;
begin
  case Name of
    'mem', 'port':
      Result := ByteTy;
    'memw', 'portw':
      Result := WordTy;
    'meml':
      Result := LongintTy;
  else
    Result := nil;
  end;
end;

function MagicSame(const Name: string): Boolean;
begin
  Result := (Name = 'abs') or (Name = 'sqr') or (Name = 'succ') or (Name = 'pred') or (Name = 'swap');
end;

function FirstTokOf(X: TObject): TToken;
var
  K: TObject;
begin
  if X = nil then
    Exit(nil);
  if X is TToken then
    Exit(TToken(X));
  for K in TNode(X).Kids do
  begin
    Result := FirstTokOf(K);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

function ValueState(Ty: TTy; LValue: Boolean): TState;
begin
  Result.Kind := stValue;
  Result.Ty := Ty;
  Result.LValue := LValue;
  Result.Sym := nil;
end;

function SymState(Kind: TStateKind; Sym: TSym): TState;
begin
  Result.Kind := Kind;
  Result.Ty := nil;
  Result.LValue := False;
  Result.Sym := Sym;
end;

constructor TTyper.Create(ATypes: TTypes; ARefOf: TRefSource; AReport: TReportProc);
begin
  Types := ATypes;
  RefOf := ARefOf;
  Report := AReport;
  FDone := TPtrMap.Create;
end;

destructor TTyper.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

function TTyper.NewR(Ty: TTy; LValue: Boolean; Sym: TSym; Tok: TToken): TR;
begin
  Result.Ty := Ty;
  Result.LValue := LValue;
  Result.Sym := Sym;
  Result.Tok := Tok;
end;

procedure TTyper.Rep(Where: TObject; const Msg: string);
var
  Tok: TToken;
begin
  if Report = nil then
    Exit;
  Tok := FirstTokOf(Where);
  if (Tok = nil) or FDone.Has(Tok) then
    Exit;
  FDone.Put(Tok, Tok);
  Report(Tok, Msg);
end;

function ParseInt64(const S: string; out V: Int64): Boolean;
var
  Code: Integer;
begin
  Val(S, V, Code);
  Result := Code = 0;
end;

function TTyper.Expr(E: TObject; ProcVal: Boolean): TR;
var
  N: TNode;
  T: TToken;
  V: Int64;
  R: TR;
begin
  Result := NewR(UnknownTy);
  if not (E is TNode) then
    Exit;
  N := TNode(E);
  try
    if ProcVal and (N.Kind = nkDesignator) then
      Exit(Designator(N, False, True));
    case N.Kind of
      nkLiteral:
        begin
          T := KT(Kid(N, 0));
          if T.Kind = tkInt then
          begin
            if ParseInt64(T.Text, V) then
              Exit(NewR(Types.IntConst(V)));
            Exit(NewR(Types.NewTy(tyInt)));
          end;
          if T.Kind = tkHex then
            Exit(NewR(Types.NewTy(tyInt)));
          if T.Kind = tkReal then
            Exit(NewR(FloatTy));
          if T.Lower = 'nil' then
            Exit(NewR(NilTy));
        end;
      nkStringLit:
        Exit(NewR(StringLit(N)));
      nkParen:
        begin
          R := Expr(Kid(N, 1));
          Exit(NewR(R.Ty));
        end;
      nkUnary:
        Exit(Unary(N));
      nkBinary:
        Exit(Binary(N));
      nkDesignator:
        Exit(Designator(N));
      nkSetCtor:
        Exit(NewR(SetCtor(N)));
    end;
  except
    on EBroken do
      Exit(NewR(UnknownTy));
  end;
end;

function Utf8Chars(const S: string): Integer;
begin
  Result := Utf8Length(S, 1, Length(S));
end;

function TTyper.StringLit(E: TNode): TTy;
var
  N: Int64;
  Code: Int64;
  HasCode: Boolean;
  K: TObject;
  T: TToken;
  Body, V: string;
  Raw: RawByteString;
  CodeI: Integer;
begin
  N := 0;
  Code := 0;
  HasCode := False;
  for K in E.Kids do
  begin
    T := TToken(K);
    if T.Kind = tkString then
    begin
      Body := StringReplace(Copy(T.Text, 2, Length(T.Text) - 2), '''''', '''', [rfReplaceAll]);
      Inc(N, Utf8Chars(Body));
      if Utf8Chars(Body) = 1 then
      begin
        Raw := Utf8ToCp866(Body);
        if (Raw = '?') and (Body <> '?') then
          Code := Ord('?')
        else
          Code := CodePointOf(Body);
        HasCode := True;
      end;
    end
    else
    begin
      V := Copy(T.Text, 2, MaxInt);
      if Copy(V, 1, 1) = '$' then
        Val('$' + Copy(V, 2, MaxInt), Code, CodeI)
      else
        Val(V, Code, CodeI);
      if CodeI <> 0 then
        raise EBroken.Create('ValueError: invalid literal for int()');
      HasCode := True;
      Inc(N);
    end;
  end;
  if N = 1 then
  begin
    if not HasCode then
      raise EBroken.Create('TypeError: no code');
    Result := Types.NewTy(tyChar);
    Result.HasLo := True;
    Result.HasHi := True;
    Result.Lo := Code;
    Result.Hi := Code;
    Result.HasValue := True;
    Result.Value := Code;
    Exit;
  end;
  Result := Types.NewTy(tyString);
  Result.HasMaxLen := True;
  Result.MaxLen := N;
  Result.HasStrLit := True;
  Result.StrLit := N;
end;

function TTyper.SetCtor(E: TNode): TTy;
var
  Base, T, Elem: TTy;
  X: TObject;
begin
  Base := nil;
  for X in E.Kids do
    if X is TNode then
    begin
      T := Expr(X).Ty;
      if (Base = nil) and (T.Kind <> tyUnknown) then
        Base := T;
    end;
  Elem := nil;
  if Base <> nil then
    if Base.Kind = tyInt then
      Elem := Types.NewTy(tyInt)
    else if Base.Kind = tyChar then
      Elem := CharTy
    else
      Elem := Base;
  Result := Types.NewTy(tySet);
  Result.Elem := Elem;
end;

function TTyper.Unary(E: TNode): TR;
var
  Op: string;
  R: TR;
  T: TTy;
begin
  Op := KT(Kid(E, 0)).Lower;
  R := Expr(Kid(E, 1));
  T := R.Ty;
  if Op = '@' then
    Exit(NewR(PointerTy));
  if T.Kind = tyUnknown then
    Exit(NewR(UnknownTy));
  if Op = 'not' then
  begin
    if T.Kind = tyBool then
      Exit(NewR(T));
    if T.Kind = tyInt then
      Exit(NewR(Types.NewTy(tyInt)));
    Rep(E.Kids[0], 'operator ''not'' cannot be applied to ' + Show(T));
    Exit(NewR(UnknownTy));
  end;
  if T.Kind in [tyInt, tyReal] then
  begin
    if (Op = '-') and (T.Kind = tyInt) and T.HasValue then
      Exit(NewR(Types.IntConst(-T.Value)));
    if T.HasValue or (T.Kind = tyReal) then
      Exit(NewR(T));
    Exit(NewR(Types.NewTy(tyInt)));
  end;
  Rep(E.Kids[0], 'operator ''' + Op + ''' cannot be applied to ' + Show(T));
  Result := NewR(UnknownTy);
end;

function Comparable(const Op: string; A, B: TTy): Boolean;
var
  KA, KB: TTyKind;
begin
  KA := A.Kind;
  KB := B.Kind;
  if (KA in [tyInt, tyReal]) and (KB in [tyInt, tyReal]) then
    Exit(True);
  if (KA in [tyString, tyChar]) and (KB in [tyString, tyChar]) then
    Exit(True);
  if ((KA in [tyString, tyChar]) and (KB = tyArray)) or ((KB in [tyString, tyChar]) and (KA = tyArray)) then
    Exit(True);
  if (KA = tyArray) and (KB = tyArray) then
    Exit(True);
  if (KA in OrdinalKinds) and (KB = KA) then
    Exit(OrdinalHost(A) = OrdinalHost(B));
  if (KA = tyPointer) or (KB = tyPointer) or (KA = tyNil) or (KB = tyNil) then
    Exit(((Op = '=') or (Op = '<>')) and (KA in [tyPointer, tyNil, tyProc]) and (KB in [tyPointer, tyNil, tyProc])
      or (KA in [tyArray, tyString]) or (KB in [tyArray, tyString]));
  if (KA = tySet) and (KB = tySet) then
    Exit((Op <> '<') and (Op <> '>'));
  if (KA = tyProc) and (KB = tyProc) then
    Exit((Op = '=') or (Op = '<>'));
  if (KA = tyFile) and (KB = tyFile) then
    Exit(True);
  Result := False;
end;

function CheckedAdd(A, B: Int64; out R: Int64): Boolean;
begin
  if ((B > 0) and (A > High(Int64) - B)) or ((B < 0) and (A < Low(Int64) - B)) then
    Exit(False);
  R := A + B;
  Result := True;
end;

function CheckedMul(A, B: Int64; out R: Int64): Boolean;
begin
  if (A = 0) or (B = 0) then
  begin
    R := 0;
    Exit(True);
  end;
  if (A = Low(Int64)) or (B = Low(Int64)) or (Abs(A) > High(Int64) div Abs(B)) then
    Exit(False);
  R := A * B;
  Result := True;
end;

function TTyper.Binary(E: TNode): TR;
var
  A, B: TObject;
  OpTok: TToken;
  Op: string;
  TA, TB: TTy;
  KA, KB: TTyKind;
  V, Q: Int64;
  Ok: Boolean;

  procedure Bad;
  begin
    Rep(OpTok, 'operator ''' + Op + ''' cannot be applied to ' + Show(TA) + ' and ' + Show(TB));
  end;

begin
  A := Kid(E, 0);
  OpTok := KT(Kid(E, 1));
  B := Kid(E, 2);
  Op := OpTok.Lower;
  TA := Expr(A).Ty;
  TB := Expr(B).Ty;
  if (TA.Kind = tyUnknown) or (TB.Kind = tyUnknown) then
  begin
    if (Op = '=') or (Op = '<>') or (Op = '<') or (Op = '>') or (Op = '<=') or (Op = '>=') or (Op = 'in') then
      Exit(NewR(BooleanTy));
    Exit(NewR(UnknownTy));
  end;
  KA := TA.Kind;
  KB := TB.Kind;
  if (Op = '=') or (Op = '<>') or (Op = '<') or (Op = '>') or (Op = '<=') or (Op = '>=') then
  begin
    if not Comparable(Op, TA, TB) then
      Rep(OpTok, 'cannot compare ' + Show(TA) + ' with ' + Show(TB));
    Exit(NewR(BooleanTy));
  end;
  if Op = 'in' then
  begin
    if not (KA in OrdinalKinds) or (KB <> tySet) then
      Bad;
    Exit(NewR(BooleanTy));
  end;
  if (Op = '+') or (Op = '-') or (Op = '*') then
  begin
    if (KA in [tyInt, tyReal]) and (KB in [tyInt, tyReal]) then
    begin
      if (KA = tyInt) and (KB = tyInt) then
      begin
        if TA.HasValue and TB.HasValue then
        begin
          if Op = '+' then
            Ok := CheckedAdd(TA.Value, TB.Value, V)
          else if Op = '-' then
            Ok := (TB.Value <> Low(Int64)) and CheckedAdd(TA.Value, -TB.Value, V)
          else
            Ok := CheckedMul(TA.Value, TB.Value, V);
          if Ok and (V >= -2147483648) and (V < 4294967296) then
            Exit(NewR(Types.IntConst(V)));
          Exit(NewR(Types.NewTy(tyInt)));
        end;
        Exit(NewR(Types.CommonInt(TA, TB)));
      end;
      Exit(NewR(FloatTy));
    end;
    if (Op = '+') and (KA in [tyString, tyChar]) and (KB in [tyString, tyChar]) then
      Exit(NewR(StringTy));
    if ((Op = '+') and IsCharArray(TA)) or ((Op = '+') and IsCharArray(TB)) then
      Exit(NewR(StringTy));
    if (KA = tySet) and (KB = tySet) then
    begin
      if TA.Elem <> nil then
        Exit(NewR(TA));
      Exit(NewR(TB));
    end;
    Bad;
    Exit(NewR(UnknownTy));
  end;
  if Op = '/' then
  begin
    if (KA in [tyInt, tyReal]) and (KB in [tyInt, tyReal]) then
      Exit(NewR(FloatTy));
    Bad;
    Exit(NewR(UnknownTy));
  end;
  if (Op = 'div') or (Op = 'mod') or (Op = 'shl') or (Op = 'shr') then
  begin
    if (KA = tyInt) and (KB = tyInt) then
    begin
      if TA.HasValue and TB.HasValue and ((Op = 'div') or (Op = 'mod')) and (TB.Value <> 0)
        and (TA.Value <> Low(Int64)) and (TB.Value <> Low(Int64)) then
      begin
        Q := Abs(TA.Value) div Abs(TB.Value);
        if (TA.Value >= 0) <> (TB.Value >= 0) then
          Q := -Q;
        if Op = 'div' then
          Exit(NewR(Types.IntConst(Q)));
        Exit(NewR(Types.IntConst(TA.Value - Q * TB.Value)));
      end;
      Exit(NewR(Types.CommonInt(TA, TB)));
    end;
    Bad;
    Exit(NewR(UnknownTy));
  end;
  if (Op = 'and') or (Op = 'or') or (Op = 'xor') then
  begin
    if (KA = tyBool) and (KB = tyBool) then
      Exit(NewR(TA));
    if (KA = tyInt) and (KB = tyInt) then
      Exit(NewR(Types.CommonInt(TA, TB)));
    Bad;
    Exit(NewR(UnknownTy));
  end;
  Result := NewR(UnknownTy);
end;

function TailKids(const K: TKids; From: Integer): TKids;
begin
  if From >= Length(K) then
    Exit(nil);
  Result := Copy(K, From, Length(K) - From);
end;

function TTyper.Designator(D: TNode; Lhs: Boolean; ProcVal: Boolean): TR;
var
  Kids, Steps, Args: TKids;
  Head: TNode;
  Tok: TToken;
  Sym, S2: TSym;
  State: TState;
  I: Integer;
  St: TNode;
  R: TR;
  HasR: Boolean;
  A: TObject;
  Ty, Tg, Res: TTy;
  Specs: TSpecs;
  P: TTy;
begin
  Kids := D.Kids;
  Head := KN(Kid(D, 0));
  Tok := nil;
  if (Head.Kids <> nil) and (Head.Kids[0] is TToken) then
    Tok := TToken(Head.Kids[0]);
  Steps := TailKids(Kids, 1);
  if Tok = nil then
    Exit(Inner(Steps));
  Sym := RefOf.Ref(Tok);
  if (Sym <> nil) and (Sym.Kind = skUnit) then
  begin
    if (Steps <> nil) and (KN(Steps[0]).Kind = nkField) then
    begin
      Tok := KT(Kid(Steps[0], 1));
      Sym := RefOf.Ref(Tok);
      Steps := TailKids(Steps, 1);
    end
    else
      Exit(NewR(UnknownTy));
  end;
  if Sym = nil then
    Exit(Inner(Steps));
  State := Start(Sym);
  I := 0;
  while I < Length(Steps) do
  begin
    St := KN(Steps[I]);
    case State.Kind of
      stRoutine:
        begin
          if St.Kind = nkArgs then
          begin
            State := Call(State.Sym, St, Tok);
            Inc(I);
          end
          else
            State := Call(State.Sym, nil, Tok);
          Continue;
        end;
      stType:
        begin
          if St.Kind = nkArgs then
          begin
            Args := nil;
            for A in St.Kids do
              if A is TNode then
                Args := Concat(Args, [A]);
            HasR := False;
            for A in Args do
            begin
              if TNode(A).Kids <> nil then
                R := Expr(TNode(A).Kids[0])
              else
                R := NewR(UnknownTy);
              HasR := True;
            end;
            Ty := Types.OfTypeSym(State.Sym);
            State := ValueState(Ty, HasR and (Length(Args) = 1) and R.LValue);
            Inc(I);
            Continue;
          end;
          Exit(Inner(TailKids(Steps, I)));
        end;
      stBuiltin:
        begin
          if (St.Kind = nkIndex) and (MagicArray(LowerText(State.Sym.Name)) <> nil) then
          begin
            IndexExprs(St);
            State := ValueState(MagicArray(LowerText(State.Sym.Name)), True);
            Inc(I);
            Continue;
          end;
          if St.Kind = nkArgs then
          begin
            State := Magic(State.Sym, St);
            Inc(I);
            Continue;
          end;
          State := Magic(State.Sym, nil);
          Continue;
        end;
      stUnknown:
        Exit(Inner(TailKids(Steps, I)));
    end;
    Ty := State.Ty;
    case St.Kind of
      nkField:
        begin
          S2 := RefOf.Ref(KT(Kid(St, 1)));
          if S2 = nil then
            Exit(Inner(TailKids(Steps, I + 1)));
          Tok := KT(Kid(St, 1));
          State := Start(S2);
        end;
      nkIndex:
        State := ValueState(IndexOf_(Ty, St), True);
      nkDeref:
        if Ty.Kind = tyPointer then
        begin
          Tg := Ty.Target;
          if Tg <> nil then
            State := ValueState(Tg, True)
          else
            State := ValueState(UnknownTy, True);
        end
        else if Ty.Kind in [tyInt, tyReal, tyBool, tyChar, tyString, tyEnum, tyRecord, tySet, tyArray, tyObject] then
        begin
          Rep(Kid(St, 0), '''^'' needs a pointer, not ' + Show(Ty));
          State.Kind := stUnknown;
        end
        else
          State := ValueState(UnknownTy, True);
      nkArgs:
        State := CallValue(Ty, St, Tok);
    end;
    Inc(I);
  end;
  if State.Kind = stRoutine then
  begin
    if Lhs then
      Exit(NewR(Types.OfSym(State.Sym), True, State.Sym, Tok));
    if ProcVal and (State.Sym.Kind = skRoutine) then
    begin
      Types.SpecsOfSym(State.Sym, Specs);
      Res := Types.OfSym(State.Sym);
      P := Types.NewTy(tyProc);
      P.Params := Specs;
      if Res.Kind <> tyVoid then
        P.Result := Res;
      Exit(NewR(P));
    end;
    State := Call(State.Sym, nil, Tok);
  end;
  if State.Kind = stType then
    Exit(NewR(UnknownTy, False, State.Sym, Tok));
  if State.Kind = stBuiltin then
    State := Magic(State.Sym, nil);
  if State.Kind = stValue then
  begin
    if Steps = nil then
      Exit(NewR(State.Ty, State.LValue, Sym, Tok));
    Exit(NewR(State.Ty, State.LValue, nil, Tok));
  end;
  Result := NewR(UnknownTy);
end;

function TTyper.Inner(const Steps: TKids): TR;
var
  St, A, X: TObject;
begin
  for St in Steps do
    if KN(St).Kind = nkArgs then
    begin
      for A in TNode(St).Kids do
        if A is TNode then
          for X in TNode(A).Kids do
            if X is TNode then
              Expr(X);
    end
    else if TNode(St).Kind = nkIndex then
      IndexExprs(TNode(St));
  Result := NewR(UnknownTy);
end;

function TTyper.IndexExprs(St: TNode): TRs;
var
  X: TObject;
begin
  Result := nil;
  for X in St.Kids do
    if X is TNode then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Expr(X);
    end;
end;

function TTyper.Start(Sym: TSym): TState;
var
  Typed: Boolean;
begin
  case Sym.Kind of
    skVar, skParam, skField:
      Result := ValueState(Types.OfSym(Sym), True);
    skConst:
      begin
        Typed := (Sym.Lib and Sym.TypedConst) or (not Sym.Lib and (Sym.TNode <> nil));
        Result := ValueState(Types.OfSym(Sym), Typed);
      end;
    skEnum:
      Result := ValueState(Types.OfSym(Sym), False);
    skRoutine:
      Result := SymState(stRoutine, Sym);
    skType:
      Result := SymState(stType, Sym);
    skBuiltin:
      Result := SymState(stBuiltin, Sym);
  else
    Result := SymState(stUnknown, nil);
  end;
end;

function TTyper.IndexOf_(Ty: TTy; St: TNode): TTy;
var
  Rs: TRs;
  N, J, Used: Integer;
  Idx: TTys;
  Elem, Tg: TTy;
begin
  Rs := IndexExprs(St);
  N := Max(Length(Rs), 1);
  case Ty.Kind of
    tyUnknown:
      Exit(UnknownTy);
    tyString:
      begin
        if N > 1 then
          Rep(St, 'a string has only one index');
        Exit(CharTy);
      end;
    tyPointer:
      begin
        Tg := Ty.Target;
        if (Tg <> nil) and (Tg.Kind = tyChar) then
          Exit(CharTy);
        Exit(UnknownTy);
      end;
    tyArray:
      begin
        Idx := Ty.Index;
        if Ty.Open then
          Idx := [IntegerTy];
        Used := 0;
        if Ty.Elem <> nil then
          Elem := Ty.Elem
        else
          Elem := UnknownTy;
        for J := 0 to High(Rs) do
          if J < Length(Idx) then
            IndexCheck(Idx[J], Rs[J], St);
        while Used < N do
        begin
          if Used >= Length(Idx) then
          begin
            if N - Used > 0 then
              Exit(IndexMore(Elem, Copy(Rs, Used, MaxInt), St));
            Break;
          end;
          Inc(Used);
        end;
        if N < Length(Idx) then
        begin
          Result := Types.NewTy(tyArray);
          Result.Elem := Elem;
          Result.Index := Copy(Idx, N, MaxInt);
          Exit;
        end;
        Exit(Elem);
      end;
    tyInt, tyReal, tyBool, tyChar, tyEnum, tyRecord, tyObject, tySet, tyProc:
      Rep(Kid(St, 0), Show(Ty) + ' cannot be indexed');
  end;
  Result := UnknownTy;
end;

function TTyper.IndexMore(Elem: TTy; const Rs: TRs; St: TNode): TTy;
var
  I: Integer;
begin
  Result := Elem;
  for I := 0 to High(Rs) do
    if Result.Kind = tyArray then
    begin
      if Result.Elem <> nil then
        Result := Result.Elem
      else
        Result := UnknownTy;
    end
    else if Result.Kind = tyString then
      Result := CharTy
    else
    begin
      if Result.Kind <> tyUnknown then
        Rep(St, 'too many indexes: ' + Show(Result) + ' cannot be indexed');
      Exit(UnknownTy);
    end;
end;

procedure TTyper.IndexCheck(Want: TTy; const R: TR; St: TNode);
var
  T: TTy;
begin
  T := R.Ty;
  if (Want.Kind = tyUnknown) or (T.Kind = tyUnknown) then
    Exit;
  if (Want.Kind in OrdinalKinds) and (T.Kind in OrdinalKinds) then
  begin
    if OrdinalHost(Want) <> OrdinalHost(T) then
      Rep(St, 'index of type ' + Show(T) + ' does not fit ' + Show(Want))
    else if (Want.Kind = tyInt) and T.HasValue and Want.HasLo and Want.HasHi
      and not ((Want.Lo <= T.Value) and (T.Value <= Want.Hi)) then
      Rep(St, Format('index %d is out of range %d..%d', [T.Value, Want.Lo, Want.Hi]));
  end
  else if (T.Kind in [tyReal, tyString, tyRecord, tySet, tyPointer]) and (Want.Kind in OrdinalKinds) then
    Rep(St, 'index of type ' + Show(T) + ' does not fit ' + Show(Want));
end;

function TTyper.Call(Sym: TSym; ArgsNode: TNode; Tok: TToken): TState;
var
  Specs: TSpecs;
  Has: Boolean;
  Res: TTy;
begin
  Has := Types.SpecsOfSym(Sym, Specs);
  Res := Types.OfSym(Sym);
  CheckArgs(Sym.Name, Specs, Has, ArgsNode, Tok);
  Result := ValueState(Res, False);
end;

function TTyper.CallValue(Ty: TTy; St: TNode; Tok: TToken): TState;
var
  Name: string;
begin
  if Ty.Kind = tyProc then
  begin
    if Tok <> nil then
      Name := Tok.Text
    else
      Name := 'procedure';
    CheckArgs(Name, Ty.Params, True, St, Tok);
    if Ty.Result <> nil then
      Exit(ValueState(Ty.Result, False));
    Exit(ValueState(VoidTy, False));
  end;
  if Ty.Kind = tyUnknown then
  begin
    CheckArgs('', nil, False, St, Tok);
    Exit(ValueState(UnknownTy, False));
  end;
  if Ty.Kind in [tyInt, tyReal, tyBool, tyChar, tyString, tyEnum, tyRecord, tySet] then
    if Tok <> nil then
      Rep(Tok, Tok.Text + ' is not a routine and cannot be called')
    else
      Rep(Tok, Show(Ty) + ' is not a routine and cannot be called');
  CheckArgs('', nil, False, St, Tok);
  Result := ValueState(UnknownTy, False);
end;

function TTyper.Magic(Sym: TSym; ArgsNode: TNode): TState;
var
  Name: string;
  Rs: TRs;
  A: TObject;
  J: Integer;
  T: TTy;
begin
  Name := LowerText(Sym.Name);
  Rs := nil;
  if ArgsNode <> nil then
    for A in ArgsNode.Kids do
      if A is TNode then
      begin
        SetLength(Rs, Length(Rs) + 1);
        if TNode(A).Kids <> nil then
          Rs[High(Rs)] := Expr(TNode(A).Kids[0])
        else
          Rs[High(Rs)] := NewR(UnknownTy);
        J := 2;
        while J <= High(TNode(A).Kids) do
        begin
          Expr(TNode(A).Kids[J]);
          Inc(J, 2);
        end;
      end;
  if MagicResult(Name) <> nil then
    Exit(ValueState(MagicResult(Name), False));
  if MagicSame(Name) and (Rs <> nil) and (Rs[0].Ty.Kind in [tyInt, tyReal, tyEnum, tyChar, tyBool]) then
  begin
    T := Rs[0].Ty;
    if T.Kind = tyInt then
      Exit(ValueState(Types.NewTy(tyInt), False));
    Exit(ValueState(T, False));
  end;
  Result := ValueState(UnknownTy, False);
end;

procedure TTyper.CheckArgs(const Name: string; const Specs: TSpecs; HasSpecs: Boolean; ArgsNode: TNode; Tok: TToken);
var
  Args: TNodes;
  Rs: TRs;
  A: TObject;
  J, N, M, K: Integer;
  WantProc: Boolean;
  Where: TObject;
begin
  Args := nil;
  if ArgsNode <> nil then
    for A in ArgsNode.Kids do
      if A is TNode then
      begin
        SetLength(Args, Length(Args) + 1);
        Args[High(Args)] := TNode(A);
      end;
  Rs := nil;
  for J := 0 to High(Args) do
  begin
    WantProc := HasSpecs and (J < Length(Specs)) and (Specs[J].Ty <> nil) and (Specs[J].Ty.Kind = tyProc);
    SetLength(Rs, Length(Rs) + 1);
    if Args[J].Kids <> nil then
      Rs[High(Rs)] := Expr(Args[J].Kids[0], WantProc)
    else
      Rs[High(Rs)] := NewR(UnknownTy);
    K := 2;
    while K <= High(Args[J].Kids) do
    begin
      Expr(Args[J].Kids[K]);
      Inc(K, 2);
    end;
  end;
  if not HasSpecs then
    Exit;
  if Assigned(OnCall) then
    OnCall(Name, Specs, Args);
  N := Length(Args);
  M := Length(Specs);
  if N > M then
  begin
    Rep(Args[M], Format('too many arguments in the call of ''%s'' (it takes %d)', [Name, M]));
    Exit;
  end;
  if N < M then
  begin
    if (ArgsNode <> nil) and (ArgsNode.Kids <> nil) then
      Where := ArgsNode.Kids[High(ArgsNode.Kids)]
    else
      Where := Tok;
    if (ArgsNode <> nil) and (Where is TToken) and (TToken(Where).Text <> ')') then
      Where := Tok;
    if Where = nil then
      Where := Tok;
    Rep(Where, Format('not enough arguments in the call of ''%s'': %d given, %d expected', [Name, N, M]));
    Exit;
  end;
  for J := 0 to M - 1 do
    CheckArg(Name, J + 1, Specs[J], Rs[J], Args[J]);
end;

function IsValueExpr(A: TNode): Boolean;
var
  E: TObject;
begin
  if A.Kids = nil then
    Exit(False);
  E := A.Kids[0];
  Result := (E is TNode) and (TNode(E).Kind in [nkLiteral, nkStringLit, nkBinary, nkUnary, nkSetCtor])
    and not ((TNode(E).Kind = nkUnary) and (TNode(E).Kids <> nil) and (TNode(E).Kids[0] is TToken)
    and (TToken(TNode(E).Kids[0]).Text = '@'));
end;

procedure TTyper.CheckArg(const Name: string; I: Integer; Sp: TSpec; const R: TR; A: TNode);
var
  Where: TObject;
  Pre, M: string;
  T: TTy;
begin
  if A.Kids <> nil then
    Where := A.Kids[0]
  else
    Where := A;
  Pre := Format('argument %d of ''%s'': ', [I, Name]);
  T := R.Ty;
  if Sp.Kind = 'var' then
  begin
    if not R.LValue and (IsValueExpr(A) or ((R.Sym <> nil) and (R.Sym.Kind in [skConst, skEnum]))) then
    begin
      Rep(Where, Pre + 'a variable is required for a var parameter');
      Exit;
    end;
    if (Sp.Ty <> nil) and not Sp.Open then
    begin
      M := VarParamError(Sp.Ty, T);
      if M <> '' then
        Rep(Where, Pre + M);
    end
    else if Sp.Open and (T.Kind in [tyInt, tyReal, tyBool, tyChar, tyEnum, tyRecord, tyObject, tySet]) then
      Rep(Where, Pre + 'an array is required, not ' + Show(T));
    Exit;
  end;
  if Sp.Open then
  begin
    if T.Kind in [tyInt, tyReal, tyBool, tyChar, tyEnum, tyRecord, tyObject, tySet, tyNil] then
      Rep(Where, Pre + 'an array is required, not ' + Show(T));
    Exit;
  end;
  if Sp.Ty = nil then
    Exit;
  M := AssignError(Sp.Ty, T);
  if M <> '' then
  begin
    if Copy(M, 1, Length('cannot assign')) = 'cannot assign' then
      M := 'cannot pass' + Copy(M, Length('cannot assign') + 1, MaxInt)
    else
      M := StringReplace(M, 'cannot assign', 'cannot pass', []);
    Rep(Where, Pre + M);
  end;
end;

{ TChecker }

constructor TChecker.Create(ARes: TParseResult; ABinder: TBinder; AProvider: TProvider; AReport: TReportProc);
begin
  Res := ARes;
  Binder := ABinder;
  Types := TTypes.Create(AProvider);
  FRefs := TBinderRefs.Create(ABinder);
  T := TTyper.Create(Types, FRefs, AReport);
end;

destructor TChecker.Destroy;
begin
  T.Free;
  FRefs.Free;
  Types.Free;
  inherited Destroy;
end;

procedure TChecker.Run;
var
  N: TNode;
begin
  for N in Res.Tree.Walk do
    case N.Kind of
      nkAssign:
        StAssign(N);
      nkProcCall:
        T.Designator(KN(Kid(N, 0)));
      nkIf, nkWhile:
        Condition(Kid(N, 1));
      nkRepeat:
        Condition(Kid(N, -1));
      nkFor:
        StFor(N);
      nkCase:
        StCase(N);
    end;
end;

procedure TChecker.StAssign(N: TNode);
var
  D, E: TObject;
  LR, RR: TR;
  M: string;
begin
  D := Kid(N, 0);
  E := Kid(N, 2);
  LR := T.Designator(KN(D), True);
  RR := T.Expr(E, LR.Ty.Kind = tyProc);
  if (LR.Sym <> nil) and (LR.Sym.Kind in [skConst, skEnum]) and not LR.LValue then
  begin
    T.Rep(D, 'cannot assign to the constant ''' + LR.Sym.Name + '''');
    Exit;
  end;
  M := AssignError(LR.Ty, RR.Ty);
  if M <> '' then
    if Copy(M, 1, 6) = 'cannot' then
      T.Rep(E, 'type mismatch: ' + M)
    else
      T.Rep(E, M);
end;

procedure TChecker.Condition(E: TObject);
var
  R: TR;
begin
  R := T.Expr(E);
  if not (R.Ty.Kind in [tyBool, tyUnknown, tyVoid]) then
    T.Rep(E, 'Boolean expression expected, found ' + Show(R.Ty));
end;

procedure TChecker.StFor(N: TNode);
var
  Kids: TKids;
  Name: TObject;
  Tok: TToken;
  Sym: TSym;
  VT: TTy;
  Exprs: TKids;
  I: Integer;
  R: TR;
  M: string;
begin
  Kids := N.Kids;
  Name := Kid(N, 1);
  Tok := nil;
  if (Name is TNode) and (TNode(Name).Kids <> nil) then
    Tok := TToken(TNode(Name).Kids[0]);
  Sym := nil;
  if Tok <> nil then
    Sym := TSym(Binder.Refs.Get(Tok));
  if (Sym <> nil) and (Sym.Kind in [skVar, skParam]) then
    VT := Types.OfSym(Sym)
  else
    VT := UnknownTy;
  if not (VT.Kind in OrdinalKinds) and not (VT.Kind in [tyUnknown, tyVoid]) then
  begin
    T.Rep(Name, 'the control variable of a for loop must be ordinal, not ' + Show(VT));
    VT := UnknownTy;
  end;
  Exprs := nil;
  for I := 2 to High(Kids) do
    if (Kids[I] is TNode) and (TNode(Kids[I]).Kind <> nkEmpty) and (Kids[I] <> Kids[High(Kids)]) then
      Exprs := Concat(Exprs, [Kids[I]]);
  for I := 0 to Min(High(Exprs), 1) do
  begin
    R := T.Expr(Exprs[I]);
    M := AssignError(VT, R.Ty);
    if M <> '' then
      if Copy(M, 1, 6) = 'cannot' then
        T.Rep(Exprs[I], 'type mismatch: ' + M)
      else
        T.Rep(Exprs[I], M);
  end;
end;

procedure TChecker.StCase(N: TNode);
var
  Sel, LT: TTy;
  B, E: TObject;
begin
  Sel := T.Expr(Kid(N, 1)).Ty;
  if not (Sel.Kind in OrdinalKinds) and not (Sel.Kind in [tyUnknown, tyVoid]) then
  begin
    T.Rep(Kid(N, 1), 'the selector of a case must be ordinal, not ' + Show(Sel));
    Sel := UnknownTy;
  end;
  for B in N.Kids do
    if IsNodeOf(B, nkCaseBranch) and (TNode(B).Kids <> nil) and (TNode(B).Kids[0] is TNode) then
      for E in TNode(TNode(B).Kids[0]).Kids do
        if E is TNode then
        begin
          LT := T.Expr(E).Ty;
          if (Sel.Kind in OrdinalKinds) and (LT.Kind in OrdinalKinds) and (OrdinalHost(Sel) <> OrdinalHost(LT)) then
            T.Rep(E, 'case label of type ' + Show(LT) + ' does not fit the selector ' + Show(Sel));
        end;
end;

procedure CheckTypes(Res: TParseResult; Binder: TBinder; Provider: TProvider; Report: TReportProc);
var
  C: TChecker;
begin
  C := TChecker.Create(Res, Binder, Provider, Report);
  try
    C.Run;
  finally
    C.Free;
  end;
end;

{ hints and hover }

function ConstTypeName(T: TTy): string;
begin
  case T.Kind of
    tyInt:
      begin
        if not T.HasValue then
          Exit(T.Name);
        if (T.Value >= -32768) and (T.Value <= 32767) then
          Exit('Integer');
        if (T.Value >= 0) and (T.Value <= 65535) then
          Exit('Word');
        Exit('Longint');
      end;
    tyChar:
      Exit('Char');
    tyString:
      if T.HasStrLit and (T.StrLit <> 0) then
        Exit(Format('string[%d]', [T.StrLit]))
      else
        Exit('string');
    tyUnknown, tyVoid, tyNil:
      Exit('');
  end;
  if T.Name <> '' then
    Result := T.Name
  else
    Result := Show(T);
end;

type
  TInlayCollector = class
  public
    Data: ^TInlayData;
    procedure OnCall(const Name: string; const Specs: TSpecs; const Args: TNodes);
  end;

procedure TInlayCollector.OnCall(const Name: string; const Specs: TSpecs; const Args: TNodes);
var
  I: Integer;
  Sp: TSpec;
  A: TNode;
  E: TObject;
  Tok: TToken;
begin
  for I := 0 to Min(High(Specs), High(Args)) do
  begin
    Sp := Specs[I];
    A := Args[I];
    if (Sp.Name = '') or (A.Kids = nil) then
      Continue;
    E := A.Kids[0];
    Tok := FirstTokOf(E);
    if (Tok = nil) or (Tok.Via <> nil) or (Tok.FileName <> '') then
      Continue;
    if IsNodeOf(E, nkDesignator) and (Length(TNode(E).Kids) = 1) and (Tok.Lower = LowerText(Sp.Name)) then
      Continue;
    SetLength(Data^.Params, Length(Data^.Params) + 1);
    Data^.Params[High(Data^.Params)].Tok := Tok;
    Data^.Params[High(Data^.Params)].Text := Sp.Name + ':';
  end;
end;

procedure RoutineNamesOf(R: TNode; out OwnerName, Name: string);
var
  Own, Nm: TNode;
begin
  RoutineNames(R, Own, Nm);
  OwnerName := '';
  Name := '';
  if (Own <> nil) and (Own.Kids <> nil) then
    OwnerName := TToken(Own.Kids[0]).Text;
  if (Nm <> nil) and (Nm.Kids <> nil) then
    Name := TToken(Nm.Kids[0]).Text;
end;

function InlayData(Res: TParseResult; Binder: TBinder; Provider: TProvider): TInlayData;
var
  Ch: TChecker;
  Col: TInlayCollector;
  Seen: TPtrMap;
  I: Integer;
  Sym: TSym;
  Name, Owner: string;
  N, Block, Comp: TNode;
  Toks: TTokens;
begin
  Result.Params := nil;
  Result.Consts := nil;
  Result.Ends := nil;
  Ch := TChecker.Create(Res, Binder, Provider, nil);
  Col := TInlayCollector.Create;
  Seen := TPtrMap.Create;
  try
    Col.Data := @Result;
    Ch.T.OnCall := @Col.OnCall;
    Ch.Run;
    for I := 0 to Binder.Decls.Count - 1 do
    begin
      Sym := TSym(Binder.Decls.At(I));
      if (Sym.Kind <> skConst) or (Sym.TNode <> nil) or (Sym.Tok = nil) or Seen.Has(Sym) or (Sym.Tok.Via <> nil)
        or (Sym.Tok.FileName <> '') or (Pointer(Sym.Tok) <> Binder.Decls.KeyAt(I)) then
        Continue;
      Seen.Put(Sym, Sym);
      Name := ConstTypeName(Ch.Types.OfSym(Sym));
      if Name <> '' then
      begin
        SetLength(Result.Consts, Length(Result.Consts) + 1);
        Result.Consts[High(Result.Consts)].Tok := Sym.Tok;
        Result.Consts[High(Result.Consts)].Text := ': ' + Name;
      end;
    end;
    for N in Res.Tree.Walk do
    begin
      if N.Kind <> nkRoutine then
        Continue;
      Block := FirstKid(N, nkBlock);
      Comp := nil;
      if Block <> nil then
        Comp := FirstKid(Block, nkCompound);
      if Comp = nil then
        Continue;
      Toks := Comp.Tokens;
      if (Length(Toks) < 2) or (Toks[High(Toks)].Lower <> 'end') or (Toks[High(Toks)].Via <> nil)
        or (Toks[High(Toks)].FileName <> '') then
        Continue;
      RoutineNamesOf(N, Owner, Name);
      SetLength(Result.Ends, Length(Result.Ends) + 1);
      Result.Ends[High(Result.Ends)].Tok := Toks[High(Toks)];
      if Owner <> '' then
        Result.Ends[High(Result.Ends)].Name := Owner + '.' + Name
      else
        Result.Ends[High(Result.Ends)].Name := Name;
      Result.Ends[High(Result.Ends)].Lines := Toks[High(Toks)].Line - Toks[0].Line + 1;
    end;
  finally
    Seen.Free;
    Col.Free;
    Ch.Free;
  end;
end;

function TypeText(T: TTy; Depth: Integer): string;
var
  Tg: TTy;
  Elem, Ps, Kw: string;
  X: TTy;
  P: TSpec;
  AllKnown: Boolean;
  Parts: TStringArray;
begin
  if ((T.Name <> '') and not ((T.Kind = tyInt) and T.HasValue)) or (Depth > 4) then
    Exit(Show(T));
  case T.Kind of
    tyInt:
      if not T.HasValue and T.HasLo and T.HasHi then
        Exit(Format('%d..%d', [T.Lo, T.Hi]));
    tyString:
      if not T.HasStrLit and T.HasMaxLen and (T.MaxLen <> 255) then
        Exit(Format('string[%d]', [T.MaxLen]));
    tyPointer:
      begin
        Tg := T.Target;
        if (Tg <> nil) and (Tg.Kind <> tyUnknown) then
          Exit('^' + TypeText(Tg, Depth + 1));
        Exit('Pointer');
      end;
    tySet:
      if (T.Elem <> nil) and (T.Elem.Kind <> tyUnknown) then
        Exit('set of ' + TypeText(T.Elem, Depth + 1));
    tyFile:
      if (T.Elem <> nil) and (T.Elem.Kind <> tyUnknown) then
        Exit('file of ' + TypeText(T.Elem, Depth + 1));
    tyArray:
      begin
        if (T.Elem <> nil) and (T.Elem.Kind <> tyUnknown) then
          Elem := TypeText(T.Elem, Depth + 1)
        else
          Elem := '?';
        if T.Open or (T.Index = nil) then
          Exit('array of ' + Elem);
        AllKnown := True;
        for X in T.Index do
          if X.Kind = tyUnknown then
            AllKnown := False;
        if AllKnown then
        begin
          Parts := nil;
          for X in T.Index do
            Parts := Concat(Parts, [TypeText(X, Depth + 1)]);
          Exit('array [' + string.Join(', ', Parts) + '] of ' + Elem);
        end;
        Exit('array of ' + Elem);
      end;
    tyProc:
      begin
        Parts := nil;
        for P in T.Params do
        begin
          if P.Kind = 'var' then
            Kw := 'var '
          else if P.Kind = 'const' then
            Kw := 'const '
          else
            Kw := '';
          if P.Ty <> nil then
            Parts := Concat(Parts, [Kw + TypeText(P.Ty, Depth + 1)])
          else
            Parts := Concat(Parts, [Kw + 'untyped']);
        end;
        Ps := string.Join('; ', Parts);
        if Ps <> '' then
          Ps := '(' + Ps + ')';
        if T.Result <> nil then
          Exit('function' + Ps + ': ' + TypeText(T.Result, Depth + 1));
        Exit('procedure' + Ps);
      end;
  end;
  Result := Show(T);
end;

destructor TExprAt.Destroy;
begin
  Node.Free;
  Types.Free;
  inherited Destroy;
end;

function IsExprBracket(const Text: string): Boolean;
begin
  Result := (Text = '(') or (Text = ')') or (Text = '[') or (Text = ']') or (Text = '(.') or (Text = '.)');
end;

function ExprAt(Tree: TNode; RefOf: TRefSource; Provider: TProvider; Tok: TToken): TExprAt;
var
  Parent: TPtrMap;
  Hit, D, Node: TNode;
  N: TNode;
  K: TObject;
  Text: string;
  I, J: Integer;
  Typer: TTyper;
  T: TTy;
  Types: TTypes;
  Owned: Boolean;
begin
  Result := nil;
  Parent := TPtrMap.Create;
  try
    Hit := nil;
    for N in Tree.Walk do
    begin
      for K in N.Kids do
      begin
        if K = Tok then
        begin
          Hit := N;
          Break;
        end;
        if K is TNode then
          Parent.Put(K, N);
      end;
      if Hit <> nil then
        Break;
    end;
    if Hit = nil then
      Exit;
    Text := Tok.Lower;
    Owned := False;
    if ((Hit.Kind = nkBinary) and (Length(Hit.Kids) > 2) and (Hit.Kids[1] = Tok))
      or ((Hit.Kind = nkUnary) and (Hit.Kids[0] = Tok))
      or ((Hit.Kind in [nkParen, nkSetCtor]) and IsExprBracket(Text)) then
      Node := Hit
    else if ((Hit.Kind in [nkIndex, nkArgs]) and IsExprBracket(Text)) or (Hit.Kind = nkDeref) then
    begin
      D := TNode(Parent.Get(Hit));
      if (D = nil) or (D.Kind <> nkDesignator) then
        Exit;
      I := -1;
      for J := 0 to High(D.Kids) do
        if D.Kids[J] = Hit then
        begin
          I := J;
          Break;
        end;
      Node := TNode.Create;
      Node.Kind := nkDesignator;
      Node.Kids := Copy(D.Kids, 0, I + 1);
      Owned := True;
    end
    else
      Exit;
    Types := TTypes.Create(Provider);
    Typer := TTyper.Create(Types, RefOf, nil);
    try
      T := Typer.Expr(Node).Ty;
    finally
      Typer.Free;
    end;
    if T.Kind in [tyUnknown, tyVoid] then
    begin
      Types.Free;
      if Owned then
        Node.Free;
      Exit;
    end;
    Result := TExprAt.Create;
    Result.Types := Types;
    if Owned then
      Result.Node := Node;
    Result.Tokens := Node.Tokens;
    Result.Ty := T;
  finally
    Parent.Free;
  end;
end;

initialization
  GlobalTys := TObjectList.Create(True);
  UnknownTy := MakeBuiltin(tyUnknown, '?');
  VoidTy := MakeBuiltin(tyVoid, 'procedure');
  NilTy := MakeBuiltin(tyNil, 'nil');
  ByteTy := MakeRange(tyInt, 'Byte', 0, 255);
  ShortIntTy := MakeRange(tyInt, 'ShortInt', -128, 127);
  IntegerTy := MakeRange(tyInt, 'Integer', -32768, 32767);
  WordTy := MakeRange(tyInt, 'Word', 0, 65535);
  LongintTy := MakeRange(tyInt, 'Longint', -2147483648, 2147483647);
  RealTy := MakeBuiltin(tyReal, 'Real');
  SingleTy := MakeBuiltin(tyReal, 'Single');
  DoubleTy := MakeBuiltin(tyReal, 'Double');
  ExtendedTy := MakeBuiltin(tyReal, 'Extended');
  CompTy := MakeBuiltin(tyReal, 'Comp');
  CompTy.Comp := True;
  BooleanTy := MakeBuiltin(tyBool, 'Boolean');
  ByteBoolTy := MakeBuiltin(tyBool, 'ByteBool');
  WordBoolTy := MakeBuiltin(tyBool, 'WordBool');
  LongBoolTy := MakeBuiltin(tyBool, 'LongBool');
  CharTy := MakeBuiltin(tyChar, 'Char');
  StringTy := MakeBuiltin(tyString, 'string');
  StringTy.HasMaxLen := True;
  StringTy.MaxLen := 255;
  PointerTy := MakeBuiltin(tyPointer, 'Pointer');
  TextTy := MakeBuiltin(tyFile, 'Text');
  TextTy.Text := True;
  UntypedFileTy := MakeBuiltin(tyFile, 'file');
  FloatTy := TTy.Create;
  GlobalTys.Add(FloatTy);
  FloatTy.Kind := tyReal;
  IntHost := TTy.Create;
  BoolHost := TTy.Create;
  CharHost := TTy.Create;
  GlobalTys.Add(IntHost);
  GlobalTys.Add(BoolHost);
  GlobalTys.Add(CharHost);

finalization
  GlobalTys.Free;
end.
