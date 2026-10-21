program tp7tests;

{$mode objfpc}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  consoletestrunner,
  tlex,
  tparse,
  tinc,
  tfmt,
  ttpu,
  tsema,
  tindex,
  ttyperules,
  tstubs,
  ttpuobj,
  tlsp;

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
