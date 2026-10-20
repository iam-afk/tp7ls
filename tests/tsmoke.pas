unit tsmoke;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TSmokeTest = class(TTestCase)
  published
    procedure TestHarness;
  end;

implementation

procedure TSmokeTest.TestHarness;
begin
  AssertEquals(2, 1 + 1);
end;

initialization
  RegisterTest(TSmokeTest);
end.
