program tpudumpcli;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, tpudump;

var
  Output: TStringStream;

procedure Put(const S: string);
begin
  Output.WriteString(S);
end;

function JStr(const S: string): string;
var
  C: Char;
begin
  Result := '"';
  for C in S do
    case C of
      '"':
        Result := Result + '\"';
      '\':
        Result := Result + '\\';
      #10:
        Result := Result + '\n';
      #13:
        Result := Result + '\r';
      #9:
        Result := Result + '\t';
      #0..#8, #11, #12, #14..#31:
        Result := Result + '\u' + LowerCase(IntToHex(Ord(C), 4));
    else
      Result := Result + C;
    end;
  Result := Result + '"';
end;

function JOpt(const S: string): string;
begin
  if S = '' then
    Result := 'null'
  else
    Result := JStr(S);
end;

function JBool(B: Boolean): string;
begin
  if B then
    Result := 'true'
  else
    Result := 'false';
end;

function JInt(V: Int64): string;
begin
  Result := IntToStr(V);
end;

function JDesc(T: TTypeDesc): string; forward;

function JParams(const Params: TParams): string;
var
  P: TParam;
begin
  Result := '[';
  for P in Params do
  begin
    if Result <> '[' then
      Result := Result + ',';
    Result := Result + '{"kind":' + JStr(P.Kind) + ',"type":' + JStr(P.TypeName) + ',"name":' + JOpt(P.Name) +
      ',"open":' + JBool(P.Open) + ',"tdesc":' + JDesc(P.TypeDesc) + '}';
  end;
  Result := Result + ']';
end;

function JFields(const Fields: TFieldInfos): string;
var
  F: TFieldInfo;
begin
  Result := '[';
  for F in Fields do
  begin
    if Result <> '[' then
      Result := Result + ',';
    Result := Result + '{"name":' + JStr(F.Name) + ',"offset":' + JInt(F.Offset);
    if F.IsMember then
      Result := Result + ',"private":' + JBool(F.Private_) + ',"seq":' + JInt(F.Seq);
    Result := Result + ',"type":' + JDesc(F.TypeDesc) + '}';
  end;
  Result := Result + ']';
end;

function JMethods(const Methods: TMethodInfos): string;
var
  M: TMethodInfo;
begin
  Result := '[';
  for M in Methods do
  begin
    if Result <> '[' then
      Result := Result + ',';
    Result := Result + '{"name":' + JStr(M.Name) + ',"kind":' + JStr(M.Kind) + ',"virtual":' + JBool(M.Virtual_) +
      ',"vmt":' + JInt(M.Vmt) + ',"params":' + JParams(M.Params) + ',"result":' + JDesc(M.Result) +
      ',"private":' + JBool(M.Private_) + ',"seq":' + JInt(M.Seq) + '}';
  end;
  Result := Result + ']';
end;

function JNames(const A: TStringArray): string;
var
  S: string;
begin
  Result := '[';
  for S in A do
  begin
    if Result <> '[' then
      Result := Result + ',';
    Result := Result + JStr(S);
  end;
  Result := Result + ']';
end;

function JSize(T: TTypeDesc): string;
begin
  if T.Size >= 0 then
    Result := ',"size":' + JInt(T.Size)
  else
    Result := '';
end;

function JDesc(T: TTypeDesc): string;
begin
  if T = nil then
    Exit('null');
  case T.Kind of
    tdNamed:
      Result := '{"named":' + JStr(T.Name) + ',"unit":' + JStr(T.UnitOf) + '}';
    tdUnresolved:
      Result := '{"unresolved":' + JStr(T.UnitOf) + ',"ofs":' + JInt(T.Ofs) + '}';
    tdArray:
      Result := '{"kind":"array"' + JSize(T) + ',"elem":' + JDesc(T.Elem) + ',"index":' + JDesc(T.Index) + '}';
    tdRecord:
      Result := '{"kind":"record"' + JSize(T) + ',"fields":' + JFields(T.Fields) + '}';
    tdObject:
      Result := '{"kind":"object"' + JSize(T) + ',"fields":' + JFields(T.Fields) + ',"methods":' +
        JMethods(T.Methods) + ',"ancestor":' + JDesc(T.Ancestor) + '}';
    tdPointer:
      Result := '{"kind":"pointer","to":' + JDesc(T.Target) + '}';
    tdString:
      Result := '{"kind":"string","max":' + JInt(T.MaxLen) + '}';
    tdSubrange:
      begin
        Result := '{"kind":"subrange"' + JSize(T) + ',"lo":' + JInt(T.Lo) + ',"hi":' + JInt(T.Hi);
        if T.Chars then
          Result := Result + ',"chars":true';
        Result := Result + '}';
      end;
    tdSet:
      Result := '{"kind":"set"' + JSize(T) + ',"base":' + JDesc(T.Base) + '}';
    tdFile:
      Result := '{"kind":"file"' + JSize(T) + ',"elem":' + JDesc(T.Elem) + '}';
    tdProc:
      Result := '{"kind":"proc"' + JSize(T) + ',"result":' + JDesc(T.Result) + ',"params":' + JParams(T.Params) + '}';
    tdPrimitive:
      Result := '{"kind":"primitive","code":' + JInt(T.CodeNum) + JSize(T) + '}';
    tdEnum:
      Result := '{"kind":"enum"' + JSize(T) + ',"unit":' + JStr(T.UnitOf) + ',"ofs":' + JInt(T.Ofs) + ',"members":' +
        JNames(T.Members.Names) + '}';
  else
    Result := '{"kind":"other","code":' + JStr(T.Code) + JSize(T) + '}';
  end;
end;

function JSym(S: TSym): string;
var
  F: TSymField;
  Fields: string;
begin
  Result := '{"kind":' + JStr(S.Kind) + ',"name":' + JStr(S.Name) + ',"tag":' + JStr(S.Tag) + ',"offset":' +
    JInt(S.Offset) + ',"type":' + JOpt(S.TypeName);
  if S.HasParams then
    Result := Result + ',"params":' + JParams(S.Params)
  else
    Result := Result + ',"params":null';
  if S.HasFields then
  begin
    Fields := '[';
    for F in S.Fields do
    begin
      if Fields <> '[' then
        Fields := Fields + ',';
      Fields := Fields + '{"name":' + JStr(F.Name) + ',"offset":' + JInt(F.Offset) + ',"type":' + JStr(F.TypeName) +
        ',"tdesc":' + JDesc(F.TypeDesc);
      if F.IsMember then
        Fields := Fields + ',"private":' + JBool(F.Private_) + ',"seq":' + JInt(F.Seq);
      Fields := Fields + '}';
    end;
    Result := Result + ',"fields":' + Fields + ']';
  end
  else
    Result := Result + ',"fields":null';
  case S.ValueKind of
    vkInt:
      Result := Result + ',"value":' + JInt(S.IntValue);
    vkStr:
      Result := Result + ',"value":' + JStr(S.StrValue);
  else
    Result := Result + ',"value":null';
  end;
  if S.Size >= 0 then
    Result := Result + ',"size":' + JInt(S.Size)
  else
    Result := Result + ',"size":null';
  Result := Result + ',"shape":' + JOpt(S.Shape) + ',"definition":' + JOpt(S.Definition);
  if S.HasMembers then
    Result := Result + ',"members":' + JNames(S.Members)
  else
    Result := Result + ',"members":null';
  if S.HasMethods then
    Result := Result + ',"methods":' + JMethods(S.Methods)
  else
    Result := Result + ',"methods":null';
  Result := Result + ',"ancestor":' + JDesc(S.Ancestor) + ',"tdesc":' + JDesc(S.TypeDesc) + ',"note":' + JOpt(S.Note) +
    ',"display":' + JOpt(S.Display) + ',"typed_const":' + JBool(S.TypedConst) + ',"init":' + JOpt(S.Init);
  if S.HasAbsolute then
    Result := Result + ',"absolute":[' + JInt(S.AbsSeg) + ',' + JInt(S.AbsOfs) + ']'
  else
    Result := Result + ',"absolute":null';
  Result := Result + ',"directive":' + JOpt(S.Directive) + '}';
end;

procedure DumpJson(const Units: array of TUnit);
var
  U: TUnit;
  S: TSym;
  First, FirstSym: Boolean;
begin
  Put('[');
  First := True;
  for U in Units do
  begin
    if not First then
      Put(',');
    First := False;
    Put('{"name":' + JStr(U.Name) + ',"used":' + JNames(U.Used) + ',"symbols":[');
    FirstSym := True;
    for S in U.Symbols do
    begin
      if not FirstSym then
        Put(',');
      FirstSym := False;
      Put(JSym(S) + #10);
    end;
    Put(']}');
  end;
  Put(']' + #10);
end;

procedure Walk(T: TTypeDesc; var Seen: TStringList; const UName, SName: string);
var
  F: TFieldInfo;
begin
  if T = nil then
    Exit;
  if T.Kind in [tdRecord, tdObject] then
    for F in T.Fields do
    begin
      if Seen.IndexOf(F.Name) < 0 then
      begin
        Seen.Add(F.Name);
        Put(UName + #9'field'#9 + SName + '.' + F.Name + #10);
      end;
      Walk(F.TypeDesc, Seen, UName, SName);
    end;
  if T.Kind in [tdArray, tdFile] then
    Walk(T.Elem, Seen, UName, SName);
  if T.Kind = tdPointer then
    Walk(T.Target, Seen, UName, SName);
end;

procedure DumpNames(const Units: array of TUnit);
var
  U: TUnit;
  S: TSym;
  M: string;
  Seen: TStringList;
begin
  Seen := TStringList.Create;
  try
    Seen.CaseSensitive := True;
    for U in Units do
      for S in U.Symbols do
      begin
        Put(U.Name + #9 + S.Kind + #9 + S.Name + #10);
        if S.HasMembers then
          for M in S.Members do
            Put(U.Name + #9'enum'#9 + M + #10);
        Seen.Clear;
        Walk(S.TypeDesc, Seen, U.Name, S.Name);
      end;
  finally
    Seen.Free;
  end;
end;

var
  Path, Lib, Mode, Only, Arg, Cand: string;
  I, NPrimary: Integer;
  Images, LibImages: TImages;
  Loader: TLoader;
  Units: array of TUnit;
  Rest: TStringArray;
  Std: THandleStream;
begin
  if (ParamCount = 0) or (ParamStr(1) = '-h') or (ParamStr(1) = '--help') then
  begin
    WriteLn('usage: tpudump FILE.TPU|FILE.TPL [--lib LIB.TPL] [--json|--pas|--names] [UNIT]');
    WriteLn('  --lib  extra file used only to resolve type references (default: TURBO.TPL next to FILE)');
    Halt(1);
  end;
  Path := ParamStr(1);
  Lib := '';
  for I := 1 to ParamCount - 1 do
    if ParamStr(I) = '--lib' then
      Lib := ParamStr(I + 1);
  if Lib = '' then
  begin
    Cand := IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(Path))) + 'TURBO.TPL';
    if FileExists(Cand) and (ExpandFileName(Cand) <> ExpandFileName(Path)) then
      Lib := Cand;
  end;
  try
    Images := ReadImages(Path);
    NPrimary := Length(Images);
    if Lib <> '' then
    begin
      LibImages := ReadImages(Lib);
      Images := Concat(Images, LibImages);
    end;
    Loader := TLoader.Create(Images, NPrimary);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'error: ', E.Message);
      Halt(1);
    end;
  end;
  Rest := nil;
  for I := 2 to ParamCount do
    if (ParamStr(I) <> '--lib') and (ParamStr(I) <> Lib) then
      Rest := Concat(Rest, [ParamStr(I)]);
  Mode := '--pas';
  for Arg in Rest do
    if Copy(Arg, 1, 2) = '--' then
    begin
      Mode := Arg;
      Break;
    end;
  Only := '';
  for Arg in Rest do
    if Copy(Arg, 1, 2) <> '--' then
    begin
      Only := LowerCase(Arg);
      Break;
    end;
  Units := nil;
  for Arg in Loader.Primary do
    if (Only = '') or (Only = Arg) then
      Units := Concat(Units, [Loader.FindUnit(Arg)]);
  Output := TStringStream.Create('');
  try
    if Mode = '--json' then
      DumpJson(Units)
    else if Mode = '--names' then
      DumpNames(Units)
    else
      for I := 0 to High(Units) do
        Put(RenderPas(Units[I]) + #10);
    Std := THandleStream.Create(StdOutputHandle);
    try
      Std.WriteBuffer(Pointer(Output.DataString)^, Length(Output.DataString));
    finally
      Std.Free;
    end;
  finally
    Output.Free;
  end;
  Loader.Free;
  FreeImages(Images);
end.
