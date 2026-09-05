unit Protogen.Emitter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Protogen.Emitter -- C2 of plans/horse-grpc-codegen.md.
//
//  Consumes a TProtoFileNode produced by Protogen.Parser and writes a
//  compilable .Messages.pas unit to a caller-supplied TStrings.
//
//  Responsibilities (separated from the parser by design):
//    - Reserved-word renaming: proto `message` -> Delphi `text`, etc.
//    - Scalar -> Pascal type mapping: proto `int32` -> `Integer`, etc.
//    - Nested qualified-name flattening: `Outer.Inner` -> `TOuterInner`
//    - WKT class name lookup (shared with the parser via Protogen.Ast)
//    - TArray<> wrapping for `repeated` fields
//
//  Validation gate: the test ProtogenEmitTests.dpr re-emits both hand-written
//  samples and asserts byte-identical content modulo comments/whitespace.
//
//  This unit has no dependency on Nghttp2 -- only on Protogen.Ast and the RTL.
//  Keep it that way: the generator must stay buildable without the codec.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  Protogen.Ast;

type
  EEmitError = class(Exception);

  // Writes a complete .Messages.pas unit for the supplied file node.
  // All class functions are public so ProtogenEmitTests can test them
  // independently of a full parse+emit cycle.
  TMessagesEmitter = class
  private
    FFile:       TProtoFileNode;
    FUnitPrefix: string;
    FProtoFile:  string;
    FOut:        TStrings;
    FNeedsWKT:   Boolean;

    procedure W(const ALine: string = '');
    procedure ScanForWKT;
    procedure EmitBoilerplate;
    procedure EmitUsesClause;
    procedure EmitTypeSection;
    procedure EmitEnum(AEnum: TProtoEnumNode);
    procedure EmitMessage(AMsg: TProtoMessageNode);
  public
    // Emit a complete .Messages.pas into ALines. ALines is cleared first.
    // AUnitPrefix: dotted name prefix, e.g. 'Sample.Greeter' -- the unit
    // name becomes '<AUnitPrefix>.Messages'.
    // AProtoFileName: used only in the generated file-level comment.
    procedure Emit(AFile: TProtoFileNode;
      const AUnitPrefix, AProtoFileName: string; ALines: TStrings);

    // Maps a proto field name to a safe Delphi identifier.
    // Sets ARenamedFrom to the original proto name when a reserved-word
    // rename was applied, or '' when no rename was needed.
    class function PascalFieldName(const AProtoName: string;
      out ARenamedFrom: string): string;

    // Maps a proto3 scalar to its Delphi type name (e.g. psInt32 -> 'Integer').
    // Raises EEmitError for Group-B scalars (sint*, fixed*) whose wire form
    // cannot be selected via TProtoMemberAttribute.
    class function PascalScalarType(AScalar: TProtoScalar): string;

    // Maps a proto qualified name to a Delphi T-prefixed class name.
    // Dots are stripped: 'Outer.Inner' -> 'TOuterInner'.
    class function PascalTypeName(const AProtoQName: string): string;

    // The complete Delphi type for a field, including TArray<> for repeated.
    // Resolves message/enum refs through AFile.
    class function PascalFieldType(AField: TProtoFieldNode;
      AFile: TProtoFileNode): string;
  end;

implementation

// ── Reserved-word helpers ────────────────────────────────────────────────────
//
// proto3 field names are lowercase identifiers. When one collides with a
// Delphi reserved word:
//   - Known semantic substitutes get a specific rename (message -> text).
//   - Everything else gets '_' appended (type -> type_).
//
// The wire tag is the contract, not the identifier, so renaming is safe.
// The emitter documents each rename with a // comment above the property.

function IsDelphiReservedWord(const AName: string): Boolean;
begin
  Result :=
    (AName = 'and')          or (AName = 'array')        or (AName = 'as')          or
    (AName = 'asm')          or (AName = 'begin')         or (AName = 'case')        or
    (AName = 'class')        or (AName = 'const')         or (AName = 'constructor') or
    (AName = 'destructor')   or (AName = 'dispinterface') or (AName = 'div')         or
    (AName = 'do')           or (AName = 'downto')        or (AName = 'else')        or
    (AName = 'end')          or (AName = 'except')        or (AName = 'exports')     or
    (AName = 'file')         or (AName = 'finalization')  or (AName = 'finally')     or
    (AName = 'for')          or (AName = 'function')      or (AName = 'goto')        or
    (AName = 'if')           or (AName = 'implementation')or (AName = 'in')          or
    (AName = 'inherited')    or (AName = 'initialization') or (AName = 'inline')     or
    (AName = 'interface')    or (AName = 'is')            or (AName = 'label')       or
    (AName = 'library')      or (AName = 'message')       or (AName = 'mod')         or
    (AName = 'nil')          or (AName = 'not')           or (AName = 'object')      or
    (AName = 'of')           or (AName = 'on')            or (AName = 'or')          or
    (AName = 'out')          or (AName = 'packed')        or (AName = 'procedure')   or
    (AName = 'program')      or (AName = 'property')      or (AName = 'raise')       or
    (AName = 'record')       or (AName = 'repeat')        or (AName = 'resourcestring') or
    (AName = 'set')          or (AName = 'shl')           or (AName = 'shr')         or
    (AName = 'string')       or (AName = 'then')          or (AName = 'threadvar')   or
    (AName = 'to')           or (AName = 'try')           or (AName = 'type')        or
    (AName = 'unit')         or (AName = 'until')         or (AName = 'uses')        or
    (AName = 'var')          or (AName = 'while')         or (AName = 'with')        or
    (AName = 'xor');
end;

// ── TMessagesEmitter -- private ──────────────────────────────────────────────

procedure TMessagesEmitter.W(const ALine: string = '');
begin
  FOut.Add(ALine);
end;

procedure TMessagesEmitter.ScanForWKT;
var
  I, J: Integer;
  LMsg: TProtoMessageNode;
  LField: TProtoFieldNode;
begin
  FNeedsWKT := False;
  for I := 0 to FFile.Messages.Count - 1 do
  begin
    LMsg := FFile.Messages[I];
    for J := 0 to LMsg.Fields.Count - 1 do
    begin
      LField := LMsg.Fields[J];
      if (LField.Scalar = psNone) and (WellKnownPascalClass(LField.TypeName) <> '') then
      begin
        FNeedsWKT := True;
        Exit;
      end;
    end;
  end;
end;

procedure TMessagesEmitter.EmitBoilerplate;
begin
  W('unit ' + FUnitPrefix + '.Messages;');
  W;
  W('// generated from ' + FProtoFile);
  W('{$M+}');
  W('{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}');
  W;
  W('interface');
  W;
  W('{$IF DEFINED(FPC)}');
  W('  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}');
  W('{$ENDIF}');
  W;
end;

procedure TMessagesEmitter.EmitUsesClause;
begin
  W('uses');
  if FNeedsWKT then
  begin
    W('  Nghttp2.Protobuf,');
    W('  Nghttp2.Protobuf.WellKnown;');
  end
  else
    W('  Nghttp2.Protobuf;');
  W;
end;

procedure TMessagesEmitter.EmitTypeSection;
var
  I: Integer;
begin
  if (FFile.Enums.Count = 0) and (FFile.Messages.Count = 0) then
    Exit;
  W('type');
  for I := 0 to FFile.Enums.Count - 1 do
    EmitEnum(FFile.Enums[I]);
  for I := 0 to FFile.Messages.Count - 1 do
    EmitMessage(FFile.Messages[I]);
end;

procedure TMessagesEmitter.EmitEnum(AEnum: TProtoEnumNode);
var
  I: Integer;
  LLine: string;
begin
  W('  ' + PascalTypeName(AEnum.QualifiedName) + ' = (');
  for I := 0 to AEnum.Values.Count - 1 do
  begin
    LLine := '    ' + AEnum.Values[I].Name + ' = ' + IntToStr(AEnum.Values[I].Number);
    if I < AEnum.Values.Count - 1 then
      LLine := LLine + ',';
    W(LLine);
  end;
  W('  );');
  W;
end;

procedure TMessagesEmitter.EmitMessage(AMsg: TProtoMessageNode);
var
  I: Integer;
  LField: TProtoFieldNode;
  LPropName, LRenamedFrom, LBackField, LFieldType: string;
begin
  W('  [TGrpcMessage]');
  W('  ' + PascalTypeName(AMsg.QualifiedName) + ' = class');
  W('  private');
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField     := AMsg.Fields[I];
    LPropName  := PascalFieldName(LField.Name, LRenamedFrom);
    LBackField := 'F' + LPropName;
    LFieldType := PascalFieldType(LField, FFile);
    W('    ' + LBackField + ': ' + LFieldType + ';');
  end;
  W('  published');
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField     := AMsg.Fields[I];
    LPropName  := PascalFieldName(LField.Name, LRenamedFrom);
    LBackField := 'F' + LPropName;
    LFieldType := PascalFieldType(LField, FFile);
    if LRenamedFrom <> '' then
      W('    // proto3: ' + LField.TypeName + ' ' + LRenamedFrom + ' = ' +
        IntToStr(LField.Number) + '; renamed to ''' + LPropName +
        ''' because ''' + LRenamedFrom + ''' is a Delphi keyword');
    W('    [TProtoMember(' + IntToStr(LField.Number) + ')]');
    W('    property ' + LPropName + ': ' + LFieldType +
      ' read ' + LBackField + ' write ' + LBackField + ';');
  end;
  W('  end;');
  W;
end;

// ── TMessagesEmitter -- public ───────────────────────────────────────────────

procedure TMessagesEmitter.Emit(AFile: TProtoFileNode;
  const AUnitPrefix, AProtoFileName: string; ALines: TStrings);
begin
  FFile       := AFile;
  FUnitPrefix := AUnitPrefix;
  FProtoFile  := AProtoFileName;
  FOut        := ALines;
  ALines.Clear;
  ScanForWKT;
  EmitBoilerplate;
  EmitUsesClause;
  EmitTypeSection;
  W('implementation');
  W;
  W('end.');
end;

class function TMessagesEmitter.PascalFieldName(const AProtoName: string;
  out ARenamedFrom: string): string;
begin
  ARenamedFrom := '';
  // Semantic substitutes -- specific renames for common proto names that
  // collide with Delphi keywords but have a natural near-synonym.
  if AProtoName = 'message' then
  begin
    ARenamedFrom := AProtoName;
    Result := 'text';
    Exit;
  end;
  if AProtoName = 'string' then
  begin
    ARenamedFrom := AProtoName;
    Result := 'str';
    Exit;
  end;
  // Generic rename for any other reserved word.
  if IsDelphiReservedWord(AProtoName) then
  begin
    ARenamedFrom := AProtoName;
    Result := AProtoName + '_';
    Exit;
  end;
  Result := AProtoName;
end;

class function TMessagesEmitter.PascalScalarType(AScalar: TProtoScalar): string;
begin
  case AScalar of
    psInt32:  Result := 'Integer';
    psInt64:  Result := 'Int64';
    psUInt32: Result := 'UInt32';
    psUInt64: Result := 'UInt64';
    psBool:   Result := 'Boolean';
    psString: Result := 'string';
    psFloat:  Result := 'Single';
    psDouble: Result := 'Double';
    psBytes:  Result := 'TBytes';
  else
    // Group B (plan 6.1): wire layer has these, but TProtoMemberAttribute
    // carries only a tag, so no property can select an alternate wire form.
    raise EEmitError.CreateFmt(
      'Cannot emit %s: no wire-form selector in TProtoMemberAttribute. ' +
      'Structural gap -- see plans/horse-grpc-codegen.md section 6.1.',
      [ScalarName(AScalar)]);
  end;
end;

class function TMessagesEmitter.PascalTypeName(const AProtoQName: string): string;
var
  LName: string;
  I: Integer;
  LResult: string;
begin
  LName := AProtoQName;
  // Strip a leading dot (WKT leading-dot escape, e.g. '.google.protobuf.X').
  if (Length(LName) > 0) and (LName[1] = '.') then
    Delete(LName, 1, 1);
  // Strip all remaining dots: 'Outer.Inner' -> 'OuterInner'.
  // Proto name components are already PascalCase by convention, so no
  // capitalisation is needed at each component boundary.
  LResult := '';
  for I := 1 to Length(LName) do
    if LName[I] <> '.' then
      LResult := LResult + LName[I];
  Result := 'T' + LResult;
end;

class function TMessagesEmitter.PascalFieldType(AField: TProtoFieldNode;
  AFile: TProtoFileNode): string;
var
  LBase: string;
  LWKT: string;
  LMsg: TProtoMessageNode;
  LEnum: TProtoEnumNode;
begin
  if AField.Scalar <> psNone then
    LBase := PascalScalarType(AField.Scalar)
  else
  begin
    // Well-known type bundled in Nghttp2.Protobuf.WellKnown?
    LWKT := WellKnownPascalClass(AField.TypeName);
    if LWKT <> '' then
      LBase := LWKT
    else
    begin
      // Resolve through the file to get the canonical QualifiedName so that
      // nested types use their full flattened form: 'Outer.Inner' -> 'TOuterInner'.
      LMsg := AFile.FindMessage(AField.TypeName);
      if LMsg <> nil then
        LBase := PascalTypeName(LMsg.QualifiedName)
      else
      begin
        LEnum := AFile.FindEnum(AField.TypeName);
        if LEnum <> nil then
          LBase := PascalTypeName(LEnum.QualifiedName)
        else
          LBase := PascalTypeName(AField.TypeName);  // best effort for forward refs
      end;
    end;
  end;
  if AField.IsRepeated then
    Result := 'TArray<' + LBase + '>'
  else
    Result := LBase;
end;

end.
