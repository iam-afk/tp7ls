unit tindex;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TTreeTest = class(TTestCase)
  private
    D: string;
    function Put(const Rel: string; const Text: string = 'x'): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestUnitsBelowTheRootAreFoundPasBeforeTpu;
    procedure TestNearestOfSeveralWins;
    procedure TestChangesAreSeenAndGenerationMoves;
    procedure TestHiddenFoldersAndLimits;
    procedure TestIncludeByNameInAnotherFolder;
    procedure TestProviderLoadsAUnitFromASubfolder;
  end;

implementation

uses
  SysUtils, tp7index, tp7sema, tp7os, tutil;

function UnitText(const Name: string): string;
begin
  Result := Format('unit %s;'#10'interface'#10'var V%s: Integer;'#10'procedure P%s;'#10'implementation'#10 +
    'procedure P%s;'#10'begin'#10'end;'#10'end.'#10, [Name, Name, Name, Name]);
end;

procedure TTreeTest.SetUp;
begin
  D := MakeTempDir;
end;

procedure TTreeTest.TearDown;
begin
  RemoveTree(D);
end;

function TTreeTest.Put(const Rel, Text: string): string;
begin
  Result := JoinPath(D, Rel);
  WriteText(Result, Text);
end;

procedure TTreeTest.TestUnitsBelowTheRootAreFoundPasBeforeTpu;
var
  A, S: string;
  Ix: TProjectIndex;
  Names: TStringArray;
begin
  A := Put('src/deep/Alpha.pas', UnitText('Alpha'));
  Put('lib/ALPHA.TPU');
  Put('lib/Beta.tpu');
  Ix := TProjectIndex.Create([D], MaxIndexFiles, 0);
  try
    AssertEquals(A, Ix.FindUnit('alpha', '.pas'));
    S := Ix.FindUnit('ALPHA', '.tpu');
    AssertEquals('ALPHA.TPU', BaseName(S));
    Names := Ix.UnitNames;
    AssertEquals('Alpha Beta', string.Join(' ', Names));
    AssertEquals(1, Length(Ix.Sources));
    AssertEquals('Alpha.pas', BaseName(Ix.Sources[0]));
  finally
    Ix.Free;
  end;
end;

procedure TTreeTest.TestNearestOfSeveralWins;
var
  B, User: string;
  Ix: TProjectIndex;
  Dups: TPathLists;
  L: TPathList;
  N: Integer;
begin
  Put('a/x/Util.pas', UnitText('Util'));
  B := Put('b/Util.pas', UnitText('Util'));
  User := Put('b/sub/main.pas');
  Ix := TProjectIndex.Create([D], MaxIndexFiles, 0);
  try
    AssertEquals(B, Ix.FindUnit('util', '.pas', User));
    Dups := Ix.Duplicates;
    N := 0;
    for L in Dups do
      if L.Key = 'util' then
        N := Length(L.Paths);
    AssertEquals(2, N);
  finally
    Ix.Free;
  end;
end;

procedure TTreeTest.TestChangesAreSeenAndGenerationMoves;
var
  Ix: TProjectIndex;
  G: Integer;
begin
  Ix := TProjectIndex.Create([D], MaxIndexFiles, 0);
  try
    Ix.Refresh;
    G := Ix.Generation;
    AssertEquals('', Ix.FindUnit('late', '.pas'));
    Put('new/dir/Late.pas', UnitText('Late'));
    AssertTrue(Ix.FindUnit('late', '.pas') <> '');
    AssertTrue(Ix.Generation > G);
    G := Ix.Generation;
    Ix.Refresh(True);
    AssertEquals(G, Ix.Generation);
    DeleteFile(JoinPath(D, 'new/dir/Late.pas'));
    AssertEquals('', Ix.FindUnit('late', '.pas'));
  finally
    Ix.Free;
  end;
end;

procedure TTreeTest.TestHiddenFoldersAndLimits;
var
  Ix: TProjectIndex;
  I: Integer;
begin
  Put('.git/Hid.pas');
  for I := 0 to 29 do
    Put(Format('f/U%d.pas', [I]));
  Ix := TProjectIndex.Create([D], 10, 0);
  try
    Ix.Refresh;
    AssertTrue(Ix.Truncated);
    AssertEquals('', Ix.FindUnit('hid', '.pas'));
  finally
    Ix.Free;
  end;
end;

procedure TTreeTest.TestIncludeByNameInAnotherFolder;
var
  P: string;
  Ix: TProjectIndex;
begin
  P := Put('common/defs.inc', 'const K = 1;');
  Ix := TProjectIndex.Create([D], MaxIndexFiles, 0);
  try
    AssertEquals(P, Ix.FindFile('DEFS.INC'));
    AssertEquals(P, Ix.FindFile('common\defs.inc'));
    AssertEquals('', Ix.FindFile('other/defs.inc'));
  finally
    Ix.Free;
  end;
end;

procedure TTreeTest.TestProviderLoadsAUnitFromASubfolder;
var
  Ix: TProjectIndex;
  Prov: TProvider;
  U: TUnitInfo;
begin
  Put('src/Alpha.pas', UnitText('Alpha'));
  Ix := TProjectIndex.Create([D], MaxIndexFiles, 0);
  Prov := TProvider.Create([D], '', Ix);
  try
    U := Prov.Get('alpha');
    AssertNotNull(U);
    AssertTrue(U.Exports_.Has('valpha'));
    AssertTrue(Pos(' Alpha ', ' ' + string.Join(' ', Prov.UnitNames) + ' ') > 0);
    AssertTrue(Prov.StillValid);
    Put('src2/Gamma.pas', UnitText('Gamma'));
    AssertFalse(Prov.StillValid);
  finally
    Prov.Free;
    Ix.Free;
  end;
end;

initialization
  RegisterTest(TTreeTest);
end.
