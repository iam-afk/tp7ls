unit ttpu;

{$mode objfpc}{$H+}

interface

uses
  Contnrs, fpcunit, testregistry, tpudump;

type
  TTpuTest = class(TTestCase)
  private
    FLoaders: TObjectList;
    FImages: array of TImages;
    function Path(const Name: string): string;
    function Load(const Name: string; Lib: Boolean = True): TLoader;
    function UnitOf(const FileName, Key: string): TUnit;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestPolskInterfaceMatchesSource;
    procedure TestNoUnresolvedTypes;
    procedure TestDosRecords;
    procedure TestDosRoutines;
    procedure TestSystemSpelling;
    procedure TestEveryNaiveScanNameIsFound;
    procedure TestTestUnit;
    procedure TestReferenceToUnloadedUnitIsReportedNotGuessed;
  end;

implementation

uses
  Classes, SysUtils, RegExpr, tp7enc, tutil;

function SymByName(U: TUnit; const Name: string): TSym;
var
  S: TSym;
begin
  for S in U.Symbols do
    if S.Name = Name then
      Exit(S);
  Result := nil;
end;

function FieldNames(const Fields: TSymFields): string;
var
  F: TSymField;
begin
  Result := '';
  for F in Fields do
    Result := Result + F.Name + ' ';
  Result := Trim(Result);
end;

procedure TTpuTest.SetUp;
begin
  FLoaders := TObjectList.Create(True);
  FImages := nil;
end;

procedure TTpuTest.TearDown;
var
  I: Integer;
begin
  FLoaders.Free;
  for I := 0 to High(FImages) do
    FreeImages(FImages[I]);
end;

function TTpuTest.Path(const Name: string): string;
begin
  Result := DataFile(Name);
  if Result = '' then
    Ignore(Name + ' is not in TP7LS_DATA');
end;

function TTpuTest.Load(const Name: string; Lib: Boolean): TLoader;
var
  Imgs: TImages;
  N: Integer;
begin
  Imgs := ReadImages(Path(Name));
  N := Length(Imgs);
  if Lib then
    Imgs := Concat(Imgs, ReadImages(Path('TURBO.TPL')));
  SetLength(FImages, Length(FImages) + 1);
  FImages[High(FImages)] := Imgs;
  Result := TLoader.Create(Imgs, N);
  FLoaders.Add(Result);
end;

function TTpuTest.UnitOf(const FileName, Key: string): TUnit;
begin
  Result := Load(FileName).FindUnit(Key);
  AssertNotNull(Key, Result);
end;

procedure TTpuTest.TestPolskInterfaceMatchesSource;
var
  Src, Lower, Iface, Want, Got, Res, Params, Part: string;
  R: TRegExpr;
  U: TUnit;
  S: TSym;
  N: Integer;
begin
  Src := ReadSource(Path('POLSK.PAS'));
  Lower := LowerText(Src);
  Iface := Copy(Src, Pos('interface', Lower), Pos('implementation', Lower) - Pos('interface', Lower));
  U := UnitOf('POLSK.TPU', 'polsk');
  Got := '';
  for S in U.Symbols do
    Got := Got + S.Name + ' ';
  Want := '';
  R := TRegExpr.Create('(function|procedure)\s+(\w+)\s*(\(([^)]*)\))?\s*(:\s*(\w+))?\s*;');
  try
    R.ModifierI := True;
    if R.Exec(Iface) then
      repeat
        Want := Want + R.Match[2] + ' ';
        S := SymByName(U, R.Match[2]);
        AssertNotNull(R.Match[2], S);
        Res := LowerCase(R.Match[6]);
        AssertEquals(R.Match[2], Res, LowerCase(S.TypeName));
        Params := R.Match[4];
        N := 0;
        if R.Match[3] <> '' then
          for Part in Params.Split([';']) do
            if Trim(Part) <> '' then
              Inc(N);
        AssertEquals(R.Match[2], N, Length(S.Params));
      until not R.ExecNext;
  finally
    R.Free;
  end;
  AssertEquals(Want, Got);
  AssertEquals('var', SymByName(U, 'NextChar').Params[0].Kind);
end;

procedure TTpuTest.TestNoUnresolvedTypes;
var
  F, K: string;
  Ld: TLoader;
  R: TRegExpr;
begin
  R := TRegExpr.Create('\?[\w]*@');
  try
    for F in Strs(['POLSK.TPU', 'GRAPH.TPU', 'TURBO.TPL']) do
    begin
      Ld := Load(F);
      for K in Ld.Primary do
        AssertFalse(F + ' ' + K, R.Exec(RenderPas(Ld.FindUnit(K))));
    end;
  finally
    R.Free;
  end;
end;

procedure TTpuTest.TestDosRecords;
var
  U: TUnit;
  F: TSymField;
  Types: TStringList;
begin
  U := UnitOf('TURBO.TPL', 'dos');
  AssertEquals('AX BX CX DX BP SI DI DS ES Flags AL AH BL BH CL CH DL DH', FieldNames(SymByName(U, 'Registers').Fields));
  Types := TStringList.Create;
  try
    for F in SymByName(U, 'SearchRec').Fields do
      Types.Add(F.Name + '=' + F.TypeName);
    Types.Sort;
    AssertEquals('Attr=Byte|Fill=array[1..21] of Byte|Name=string[12]|Size=Longint|Time=Longint',
      StringReplace(Trim(Types.Text), LineEnding, '|', [rfReplaceAll]));
  finally
    Types.Free;
  end;
  AssertEquals('^TextBuf', SymByName(U, 'TextRec').Fields[6].TypeName);
  AssertEquals(12, SymByName(U, 'DateTime').Size);
  AssertEquals(128, SymByName(U, 'FileRec').Size);
end;

procedure TTpuTest.TestDosRoutines;
var
  U: TUnit;
  Intr: TSym;
begin
  U := UnitOf('TURBO.TPL', 'dos');
  Intr := SymByName(U, 'Intr');
  AssertEquals(2, Length(Intr.Params));
  AssertEquals('value Byte', Intr.Params[0].Kind + ' ' + Intr.Params[0].TypeName);
  AssertEquals('var Registers', Intr.Params[1].Kind + ' ' + Intr.Params[1].TypeName);
  AssertEquals('Longint', SymByName(U, 'DiskFree').TypeName);
  AssertEquals('', SymByName(U, 'MsDos').TypeName);
end;

procedure TTpuTest.TestSystemSpelling;
var
  U: TUnit;
  N: string;
begin
  U := UnitOf('TURBO.TPL', 'system');
  for N in Strs(['WriteLn', 'ReadLn', 'Inc', 'Dec', 'Exit', 'Halt', 'SizeOf', 'FillChar', 'Integer', 'Boolean', 'True',
    'False', 'Bytebool', 'Longbool', 'Wordbool', 'OpenString', 'IOResult', 'Assign', 'Pos', 'HeapError']) do
    AssertNotNull(N, SymByName(U, N));
  for N in Strs(['Writeln', 'TRUE', 'FALSE', 'Readln']) do
    AssertNull(N, SymByName(U, N));
end;

procedure TTpuTest.TestEveryNaiveScanNameIsFound;
var
  Blob: RawByteString;
  Ld: TLoader;
  Found: TStringList;
  I: Integer;
  S: TSym;
  F: TSymField;
  N: string;
begin
  Blob := ReadFileBytes(Path('TURBO.TPL'));
  Ld := Load('TURBO.TPL');
  Found := TStringList.Create;
  try
    Found.CaseSensitive := True;
    for I := 0 to Ld.UnitCount - 1 do
      for S in Ld.UnitAt(I).Symbols do
      begin
        Found.Add(S.Name);
        for F in S.Fields do
          Found.Add(F.Name);
      end;
    for N in Strs(['Abs', 'Addr', 'Append', 'ParamStr', 'GetEnv', 'KeyPressed', 'ReadKey', 'Lst', 'FindFirst',
      'GetIntVec', 'Delay', 'NoSound', 'OvrInit', 'DirectVideo', 'Flags']) do
    begin
      AssertTrue(N, Pos(N, Blob) > 0);
      AssertTrue(N, Found.IndexOf(N) >= 0);
    end;
  finally
    Found.Free;
  end;
end;

procedure TTpuTest.TestTestUnit;
var
  Src, Lower, Decl, Part, Names, Section: string;
  U: TUnit;
  Members: string;
  R: TRegExpr;
  F: TSymField;
  Arr: TTypeDesc;
  FI: TFieldInfo;
  Vars: TStringList;
  S: TSym;
begin
  Src := ReadSource(Path('TEST.PAS'));
  U := UnitOf('TEST.TPU', 'test');
  AssertEquals('System vesa dos objects crt polsk option', string.Join(' ', U.Used));
  R := TRegExpr.Create('Ident=\((.*?)\);');
  try
    R.ModifierS := True;
    AssertTrue(R.Exec(Src));
    Decl := StringReplace(StringReplace(R.Match[1], #13, '', [rfReplaceAll]), #10, '', [rfReplaceAll]);
  finally
    R.Free;
  end;
  Names := '';
  for Part in Decl.Split([',']) do
    Names := Names + Trim(Part) + ' ';
  Members := string.Join(' ', SymByName(U, 'Ident').Members) + ' ';
  AssertEquals(Names, Members);
  AssertEquals('string[15]', SymByName(U, 'str_15').Definition);
  AssertEquals('^tZnach', SymByName(U, 'pZnach').Definition);
  AssertEquals('typ f i s c p', FieldNames(SymByName(U, 'tZnach').Fields));
  for F in SymByName(U, 'tZnach').Fields do
    if (F.Name = 'i') or (F.Name = 'p') or (F.Name = 'ip') or (F.Name = '') then
      AssertEquals(F.Name, 2, F.Offset);
  AssertEquals('next typ where what NotPrep op1 op2 then_ else_ Operation whereW whatW NotPrepW op1W op2W ' +
    'operationW bodyW ForI Body Name TypAss WhatAssign', FieldNames(SymByName(U, 'tNode').Fields));
  Arr := SymByName(U, 'tMainVar').TypeDesc;
  AssertTrue(Arr.Kind = tdArray);
  Names := '';
  for FI in Arr.Elem.Fields do
    Names := Names + FI.Name + ' ';
  AssertEquals('name typ i s c ', Names);
  Vars := TStringList.Create;
  try
    for S in U.Symbols do
      if S.Kind = 'var' then
        Vars.Add(LowerCase(S.Name));
    AssertEquals('array[Ident] of str_15', SymByName(U, 'MainLex').TypeName);
    AssertEquals('Pointer', SymByName(U, 'PGoth').TypeName);
    AssertEquals('Word', SymByName(U, 'SBP').TypeName);
    AssertEquals('Integer', SymByName(U, 'LexNum').TypeName);
    Lower := LowerText(Src);
    Section := Copy(Src, Pos('var prog', Lower), Pos('implementation', Lower) - Pos('var prog', Lower));
    R := TRegExpr.Create('(\w+)\s*(?:,\s*\w+\s*)*:\s*(?:text|integer|boolean|byte|word|pointer|char|string|\w+)\s*;');
    try
      R.ModifierI := True;
      if R.Exec(Section) then
        repeat
          AssertTrue(R.Match[1], Vars.IndexOf(LowerCase(R.Match[1])) >= 0);
        until not R.ExecNext;
    finally
      R.Free;
    end;
  finally
    Vars.Free;
  end;
end;

procedure TTpuTest.TestReferenceToUnloadedUnitIsReportedNotGuessed;
var
  Cur: TSym;
begin
  Cur := SymByName(UnitOf('TEST.TPU', 'test'), 'cursor');
  AssertTrue(Cur.TypeDesc.Kind = tdUnresolved);
  AssertEquals('option', Cur.TypeDesc.UnitOf);
end;

initialization
  RegisterTest(TTpuTest);
end.
