program tp7tests;

{$mode objfpc}{$H+}

uses
  consoletestrunner,
  tlex,
  tparse,
  tinc,
  tfmt,
  ttpu,
  tsema,
  tindex;

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
