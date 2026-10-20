program tp7ls;

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  Version = '0.0.1';

procedure Usage;
begin
  WriteLn('usage: tp7ls [--version]');
  WriteLn('  the language server is not ported yet; use python/tp7lsp.py');
end;

begin
  if (ParamCount = 1) and (ParamStr(1) = '--version') then
    WriteLn('tp7ls ', Version)
  else
  begin
    Usage;
    if ParamCount > 0 then
      Halt(1);
  end;
end.
