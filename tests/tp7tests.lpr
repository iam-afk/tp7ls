program tp7tests;
{ Test runner (FPCUnit).  The Python suites in python/test_*.py are the specification: port their cases
  into units here, one unit per suite (test_tp7lex.py -> tlex.pas, ...), and add them to the uses clause. }

{$mode objfpc}{$H+}

uses
  consoletestrunner,
  tsmoke;

var
  App: TTestRunner;

begin
  DefaultFormat := fPlain;
  DefaultRunAllTests := True;
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'tp7ls tests';
    App.Run;
  finally
    App.Free;
  end;
end.
