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
    // PRESENCE-1 — proto3 `optional`
    function  NeedsHasBit(AField: TProtoFieldNode): Boolean;
    procedure EmitOptionalBodies;
  public
    // The generated has-bit property name for a field's Pascal property name.
    // Public so the C2 gate can assert against it rather than re-deriving the
    // rule and agreeing with itself.
    class function HasBitName(const APropName: string): string;

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

{ PRESENCE-1. True when this field needs a has-bit: `optional` on something the
  codec treats as a scalar on the wire.

  A message field is excluded and REFUSED rather than silently downgraded — it
  already carries explicit presence through nil, so a has-bit would be a
  second, contradictory source of truth, and the RTTI layer rejects that
  pairing outright. An ENUM is included: it is a varint on the wire like any
  other scalar and needs a bit exactly as much.

  The parser cannot make this distinction — psNone means only "not a built-in
  scalar", and a forward reference is unresolvable there — so it is made here,
  where the whole file is in hand. }
function TMessagesEmitter.NeedsHasBit(AField: TProtoFieldNode): Boolean;
begin
  Result := False;
  if AField.FieldLabel <> plOptional then Exit;

  if AField.Scalar <> psNone then Exit(True);      // a built-in scalar

  if FFile.FindEnum(AField.TypeName) <> nil then
    Exit(True);                                    // enum: varint, needs a bit

  raise EEmitError.CreateFmt(
    'Field %s is `optional %s`, and %s is a message. A message field already ' +
    'has explicit presence - unset means nil, and nil is not emitted - so a ' +
    'has-bit would be a second, contradictory source of truth and the ' +
    'serializer refuses that pairing. Drop `optional`.',
    [QuotedStr(AField.Name), AField.TypeName, AField.TypeName]);
end;

{ The generated has-bit / setter / clear names for one optional field.

  `Has` + PropName rather than the proto convention `has_x`, because the
  emitted identifier is Pascal and reads as Pascal. Pascal is case-insensitive,
  so a proto field literally named `hasOpt` alongside `optional opt` WOULD
  collide - caught in EmitMessage rather than left to produce a duplicate-
  identifier error in generated code the user did not write. }
class function TMessagesEmitter.HasBitName(const APropName: string): string;
begin
  Result := 'Has' + APropName;
end;

procedure TMessagesEmitter.EmitMessage(AMsg: TProtoMessageNode);
var
  I, J: Integer;
  LField, LOther: TProtoFieldNode;
  LPropName, LRenamedFrom, LBackField, LFieldType: string;
  LOtherName, LOtherRenamed: string;
  LAnyOptional: Boolean;
begin
  { Collision check first, so the diagnostic names the two proto fields rather
    than surfacing as a duplicate identifier in generated Pascal. }
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField := AMsg.Fields[I];
    if not NeedsHasBit(LField) then Continue;
    LPropName := PascalFieldName(LField.Name, LRenamedFrom);
    for J := 0 to AMsg.Fields.Count - 1 do
    begin
      if J = I then Continue;
      LOther     := AMsg.Fields[J];
      LOtherName := PascalFieldName(LOther.Name, LOtherRenamed);
      if SameText(LOtherName, HasBitName(LPropName)) then
        raise EEmitError.CreateFmt(
          'Field %s is `optional`, so the generator emits a has-bit named ' +
          '%s - but field %s already takes that name. Pascal is ' +
          'case-insensitive, so the two would collide. Rename one of them.',
          [QuotedStr(LField.Name), QuotedStr(HasBitName(LPropName)),
           QuotedStr(LOther.Name)]);
    end;
  end;

  LAnyOptional := False;

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
    if NeedsHasBit(LField) then
    begin
      LAnyOptional := True;
      W('    F' + HasBitName(LPropName) + ': Boolean;');
      { The setter is the mechanism, not a convenience: deserialisation writes
        through TRttiProperty.SetValue, which calls this, which raises the bit.
        That is why the bit below is read-only and why nothing on the decode
        side has to know about presence at all. }
      W('    procedure Set' + LPropName + '(const AValue: ' + LFieldType + ');');
    end;
  end;

  if LAnyOptional then
  begin
    W('  public');
    for I := 0 to AMsg.Fields.Count - 1 do
    begin
      LField := AMsg.Fields[I];
      if not NeedsHasBit(LField) then Continue;
      LPropName := PascalFieldName(LField.Name, LRenamedFrom);
      { Clearing needs its own entry point. Assigning the zero value through
        the setter SETS the field to zero, which on the wire is the opposite
        of absent. }
      W('    procedure Clear' + LPropName + ';');
    end;
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
    if NeedsHasBit(LField) then
    begin
      W('    property ' + LPropName + ': ' + LFieldType +
        ' read ' + LBackField + ' write Set' + LPropName + ';');
      W('    [TProtoHas(' + IntToStr(LField.Number) + ')]');
      { No writer. The serializer rejects a writable has-bit, because a bit the
        author maintains by hand desyncs the moment a decoded field arrives. }
      W('    property ' + HasBitName(LPropName) + ': Boolean read F' +
        HasBitName(LPropName) + ';');
    end
    else
      W('    property ' + LPropName + ': ' + LFieldType +
        ' read ' + LBackField + ' write ' + LBackField + ';');
  end;
  W('  end;');
  W;
end;

{ Method bodies for every optional field, emitted into the implementation
  section. Declaration and body are produced from the same PascalFieldName and
  HasBitName calls, so they cannot drift - a drift there is a link error. }
procedure TMessagesEmitter.EmitOptionalBodies;
var
  M, I: Integer;
  LMsg: TProtoMessageNode;
  LField: TProtoFieldNode;
  LClass, LPropName, LRenamedFrom, LFieldType: string;
begin
  for M := 0 to FFile.Messages.Count - 1 do
  begin
    LMsg   := FFile.Messages[M];
    LClass := PascalTypeName(LMsg.QualifiedName);
    for I := 0 to LMsg.Fields.Count - 1 do
    begin
      LField := LMsg.Fields[I];
      if not NeedsHasBit(LField) then Continue;
      LPropName  := PascalFieldName(LField.Name, LRenamedFrom);
      LFieldType := PascalFieldType(LField, FFile);

      W('procedure ' + LClass + '.Set' + LPropName +
        '(const AValue: ' + LFieldType + ');');
      W('begin');
      W('  F' + LPropName + ' := AValue;');
      W('  F' + HasBitName(LPropName) + ' := True;');
      W('end;');
      W;
      W('procedure ' + LClass + '.Clear' + LPropName + ';');
      W('begin');
      W('  F' + LPropName + ' := Default(' + LFieldType + ');');
      W('  F' + HasBitName(LPropName) + ' := False;');
      W('end;');
      W;
    end;
  end;
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
  EmitOptionalBodies;
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
