program tp7fmtcli;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, tp7enc, tp7parse, tp7fmt;

var
  Defines: array of string;
  Path, OutPath, D, Text: string;
  Bytes: RawByteString;
  I, Width: Integer;
  Warnings: TStringList;
  Output: TStream;
begin
  Defines := nil;
  for D in DefaultDefines do
    Defines := Concat(Defines, [D]);
  Path := '';
  OutPath := '';
  Width := MaxWidth;
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '-D') and (I < ParamCount) then
    begin
      Inc(I);
      Defines := Concat(Defines, [ParamStr(I)]);
    end
    else if (ParamStr(I) = '-w') and (I < ParamCount) then
    begin
      Inc(I);
      Width := StrToInt(ParamStr(I));
    end
    else if (ParamStr(I) = '-o') and (I < ParamCount) then
    begin
      Inc(I);
      OutPath := ParamStr(I);
    end
    else
      Path := ParamStr(I);
    Inc(I);
  end;
  if Path = '' then
  begin
    WriteLn('usage: tp7fmt FILE.PAS [-o OUT] [-w WIDTH] [-D SYMBOL ...]');
    Halt(1);
  end;
  Warnings := TStringList.Create;
  try
    try
      Text := FormatSource(ReadSource(Path), Defines, Width, Warnings);
    except
      on E: EFormatError do
      begin
        WriteLn(StdErr, 'error: ', E.Message);
        Halt(2);
      end;
      on E: EFormatBug do
      begin
        WriteLn(StdErr, 'internal error: ', E.Message);
        Halt(1);
      end;
      on E: Exception do
      begin
        WriteLn(StdErr, 'error: ', E.Message);
        Halt(1);
      end;
    end;
    for D in Warnings do
      WriteLn(StdErr, 'warning: ', D);
  finally
    Warnings.Free;
  end;
  Bytes := Utf8ToCp866(Text);
  if OutPath <> '' then
    Output := TFileStream.Create(OutPath, fmCreate)
  else
    Output := THandleStream.Create(StdOutputHandle);
  try
    if Bytes <> '' then
      Output.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    Output.Free;
  end;
end.
