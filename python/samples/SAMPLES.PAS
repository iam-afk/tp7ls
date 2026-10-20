{ SAMPLES.PAS - declarations for checking how tp7ls reads a TPU.
  Compile (Alt-F9 / tpc) with debug info ON (switches D+ and L+, the default) and send SAMPLES.TPU back.
  If you can, ALSO compile it once more with D- and L- and send that as SAMPLESN.TPU
  (rename the unit line to SAMPLESN and the file to SAMPLESN.PAS) - to see what a TPU without debug info looks like. }
{$D+,L+,N+,E+}
unit Samples;

interface

{ ---- constants ----------------------------------------------------------------------------- }
const
  cInt      = 100;
  cNeg      = -32768;
  cWordMax  = 65535;
  cLong     = 123456789;
  cLongNeg  = -2000000000;
  cHex      = $FF00;
  cExpr     = 1000 * 60 + 5;
  cChar     = 'A';
  cCtl      = #13;
  cCyr      = 'Ж';
  cBoolT    = True;
  cBoolF    = False;
  cReal     = 3.14159;
  cRealExp  = 1.5E10;
  cRealNeg  = -0.001;
  cStr      = 'it''s a string';
  cStrEmpty = '';
  cStrCyr   = 'Привет';
  cStrCtl   = #27'[0m';
  cStrLong  = '0123456789012345678901234567890123456789012345678901234567890123456789';
  cSetDigit = ['0'..'9'];
  cSetSmall = [1, 3, 5..7];

type
  TColor    = (clRed, clGreen, clBlue, clYellow);
  TColors   = set of TColor;
  TDay      = (dMon, dTue, dWed, dThu, dFri, dSat, dSun);
  TWeek     = array [TDay] of Boolean;
  TSmall    = 1..10;
  TLetter   = 'A'..'Z';
  TCharSet  = set of Char;
  TByteSet  = set of Byte;

const
  cColor    = clGreen;
  cColors   = [clRed, clBlue];
  cDay      = dFri;
  cSmall    = 7;

{ ---- typed constants ----------------------------------------------------------------------- }
const
  kInt      : Integer = 5;
  kWord     : Word = 65535;
  kLong     : LongInt = -1;
  kByte     : Byte = 200;
  kChar     : Char = 'z';
  kBool     : Boolean = True;
  kReal     : Real = 0.5;
  kDouble   : Double = 2.5;
  kExt      : Extended = 1.0E-5;
  kStr      : string[10] = 'abc';
  kStrFull  : string = 'full string';
  kColor    : TColor = clBlue;
  kColors   : TColors = [clRed, clGreen];
  kTable    : array [0..3] of Byte = (1, 2, 3, 4);
  kTable2   : array [0..1, 0..2] of Integer = ((1, 2, 3), (4, 5, 6));
  kNames    : array [TColor] of string[6] = ('red', 'green', 'blue', 'yellow');

{ ---- types --------------------------------------------------------------------------------- }
type
  PByteBuf  = ^TByteBuf;
  TByteBuf  = array [0..255] of Byte;
  TMatrix   = array [1..3, 1..3] of Real;
  TPacked   = packed array [0..7] of Boolean;
  TName     = string[20];
  PName     = ^TName;
  TFileB    = file of Byte;
  TFileU    = file;
  TFileRec  = file of TName;

  TPoint = record
    X, Y: Integer;
  end;

  TRect = record
    A, B: TPoint;
  end;

  TVariant = record
    Tag: Byte;
    case Kind: Byte of
      0: (I: Integer);
      1: (R: Real);
      2: (S: string[8]);
      3: (P: TPoint; Flag: Boolean);
  end;

  TProc     = procedure;
  TProcVar  = procedure (var X: Integer; Y: Word);
  TFunc     = function (A: Integer; const S: string): Boolean;
  TFuncReal = function: Real;

  { ---- objects ----------------------------------------------------------------------------- }
  PBase = ^TBase;
  TBase = object
    Id: Integer;
    Name: string[12];
    constructor Init(AId: Integer);
    destructor Done; virtual;
    procedure Show; virtual;
    procedure Hide;
    function GetId: Integer;
    function Describe(const Prefix: string; Width: Word): string; virtual;
    procedure Abstract; virtual;
  end;

  PChild = ^TChild;
  TChild = object(TBase)
    Extra: LongInt;
    Pos: TPoint;
    constructor Init(AId: Integer; AExtra: LongInt);
    destructor Done; virtual;
    procedure Show; virtual;
    procedure Move(var P: TPoint; DX, DY: Integer);
    function Describe(const Prefix: string; Width: Word): string; virtual;
    procedure Abstract; virtual;
  end;

  PGrand = ^TGrand;
  TGrand = object(TChild)
    Color: TColor;
    Flags: Word;
    procedure Show; virtual;
    procedure Paint(C: TColor; Fill: Boolean);
  end;

  TPlain = object
    A, B: Integer;
    procedure Reset;
    function Sum: Integer;
  end;

  TNoMethods = object
    X, Y: Word;
  end;

  { private / public sections (TP 7.0) }
  TSecret = object
    Open1: Integer;
  private
    Hidden: Integer;
    procedure Internal;
  public
    Open2: Integer;
    constructor Init;
    destructor Done;
    function Peek: Integer;
  end;

  TWithDtor = object
    Data: Pointer;
    constructor Init;
    destructor Done;
  end;

{ ---- variables ----------------------------------------------------------------------------- }
var
  gInt: Integer;
  gLong: LongInt;
  gReal: Real;
  gStr: string;
  gName: TName;
  gBuf: TByteBuf;
  gPtr: Pointer;
  gColor: TColor;
  gColors: TColors;
  gPoint: TPoint;
  gRect: TRect;
  gBase: TBase;
  gChild: TChild;
  gChildPtr: PChild;
  gProc: TProc;
  gFile: Text;
  gFileB: TFileB;
  gA, gB, gC: Word;
  gVideo: array [0..3999] of Byte absolute $B800:0;
  gMonoSeg: Word absolute $0040:$0063;

{ ---- routines ------------------------------------------------------------------------------ }
procedure P0;
procedure P1(X: Integer);
procedure P2(var X: Integer; Y: Word; const S: string);
procedure PUntyped(var Buf; Size: Word);
procedure POpen(const A: array of Integer; var B: array of Char);
procedure PMany(A, B, C: Integer; D, E: string; var F, G: Real);
procedure PObj(var O: TBase; P: PChild; Color: TColor; Cs: TColors);
procedure PProc(Callback: TProc; Cmp: TFunc);
procedure PFar; far;
procedure PInt(Flags, CS, IP, AX, BX, CX, DX, SI, DI, DS, ES, BP: Word); interrupt;
procedure PInline(X: Byte); inline($58);
function F0: Integer;
function FStr(N: Integer): string;
function FReal(X, Y: Real): Real;
function FBool(const S: string; C: Char): Boolean;
function FPtr: Pointer;
function FObj: PChild;
function FChar(B: Byte): Char;
function FColor(N: Byte): TColor;
function FLong(var X: LongInt): LongInt;
function FFar(X: Integer): Integer; far;

implementation

constructor TBase.Init(AId: Integer);
begin
  Id := AId;
  Name := '';
end;

destructor TBase.Done;
begin
end;

procedure TBase.Show;
begin
end;

procedure TBase.Hide;
begin
end;

function TBase.GetId: Integer;
begin
  GetId := Id;
end;

function TBase.Describe(const Prefix: string; Width: Word): string;
begin
  Describe := Prefix;
end;

procedure TBase.Abstract;
begin
end;

constructor TChild.Init(AId: Integer; AExtra: LongInt);
begin
  TBase.Init(AId);
  Extra := AExtra;
end;

destructor TChild.Done;
begin
  TBase.Done;
end;

procedure TChild.Show;
begin
  TBase.Show;
end;

procedure TChild.Move(var P: TPoint; DX, DY: Integer);
begin
  Inc(P.X, DX);
  Inc(P.Y, DY);
end;

function TChild.Describe(const Prefix: string; Width: Word): string;
begin
  Describe := Prefix + Name;
end;

procedure TChild.Abstract;
begin
end;

procedure TGrand.Show;
begin
  TChild.Show;
end;

procedure TGrand.Paint(C: TColor; Fill: Boolean);
begin
  Color := C;
end;

procedure TPlain.Reset;
begin
  A := 0;
  B := 0;
end;

function TPlain.Sum: Integer;
begin
  Sum := A + B;
end;

procedure TSecret.Internal;
begin
  Hidden := 0;
end;

constructor TSecret.Init;
begin
  Open1 := 0;
  Open2 := 0;
  Hidden := 0;
end;

destructor TSecret.Done;
begin
end;

function TSecret.Peek: Integer;
begin
  Peek := Hidden;
end;

constructor TWithDtor.Init;
begin
  Data := nil;
end;

destructor TWithDtor.Done;
begin
  Data := nil;
end;

procedure P0;
begin
end;

procedure P1(X: Integer);
begin
end;

procedure P2(var X: Integer; Y: Word; const S: string);
begin
end;

procedure PUntyped(var Buf; Size: Word);
begin
end;

procedure POpen(const A: array of Integer; var B: array of Char);
begin
end;

procedure PMany(A, B, C: Integer; D, E: string; var F, G: Real);
begin
end;

procedure PObj(var O: TBase; P: PChild; Color: TColor; Cs: TColors);
begin
end;

procedure PProc(Callback: TProc; Cmp: TFunc);
begin
end;

procedure PFar;
begin
end;

procedure PInt(Flags, CS, IP, AX, BX, CX, DX, SI, DI, DS, ES, BP: Word);
begin
end;

function F0: Integer;
begin
  F0 := 0;
end;

function FStr(N: Integer): string;
begin
  FStr := '';
end;

function FReal(X, Y: Real): Real;
begin
  FReal := X + Y;
end;

function FBool(const S: string; C: Char): Boolean;
begin
  FBool := True;
end;

function FPtr: Pointer;
begin
  FPtr := nil;
end;

function FObj: PChild;
begin
  FObj := nil;
end;

function FChar(B: Byte): Char;
begin
  FChar := Chr(B);
end;

function FColor(N: Byte): TColor;
begin
  FColor := clRed;
end;

function FLong(var X: LongInt): LongInt;
begin
  FLong := X;
end;

function FFar(X: Integer): Integer;
begin
  FFar := X;
end;

begin
end.
