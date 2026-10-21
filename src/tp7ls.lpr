program tp7ls;

{$mode objfpc}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  Classes, SysUtils, tp7lsp;

var
  Input_, Output_: THandleStream;
  Server: TServer;
  Transport: TStreamTransport;
  Code: Integer;

begin
  if (ParamCount = 1) and (ParamStr(1) = '--version') then
  begin
    WriteLn(ServerName, ' ', ServerVersion);
    Exit;
  end;
  Input_ := THandleStream.Create(StdInputHandle);
  Output_ := THandleStream.Create(StdOutputHandle);
  Transport := TStreamTransport.Create(Input_, Output_);
  Server := TServer.Create(Transport);
  Code := Server.Run;
  Flush(StdErr);
  if Server.ReaderFinished then
  begin
    Server.Free;
    Transport.Free;
    Output_.Free;
    Input_.Free;
  end;
  Halt(Code);
end.
