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
    // FORWARD-1 — class forwards for messages referenced before they are declared
    function  MessageIndex(AMsg: TProtoMessageNode): Integer;
    procedure EmitForwardDecls;
    procedure EmitEnum(AEnum: TProtoEnumNode);
    procedure EmitMessage(AMsg: TProtoMessageNode);
    // PRESENCE-1 — proto3 `optional`
    function  NeedsHasBit(AField: TProtoFieldNode): Boolean;
    procedure EmitImplementationBodies;
    // ONEOF-1 — proto3 `oneof`
    function  OneofGroups(AMsg: TProtoMessageNode): TArray<string>;
    procedure EmitOneofCaseEnums(AMsg: TProtoMessageNode);
    procedure EmitOneofBodies(AMsg: TProtoMessageNode);
    // PROTOGEN-DTOR — ownership of allocated submessages
    function  IsMessageField(AField: TProtoFieldNode): Boolean;
    function  OwnsMessages(AMsg: TProtoMessageNode): Boolean;
    procedure EmitDestructorBody(AMsg: TProtoMessageNode);
    // MAP-1 — dictionary accessors over the entry array
    function  MapKeyType(AField: TProtoFieldNode): string;
    function  MapValueType(AField: TProtoFieldNode): string;
    procedure EmitMapAccessorDecls(AMsg: TProtoMessageNode);
    procedure EmitMapAccessorBodies(AMsg: TProtoMessageNode);
  public
    // The generated has-bit property name for a field's Pascal property name.
    // Public so the C2 gate can assert against it rather than re-deriving the
    // rule and agreeing with itself.
    class function HasBitName(const APropName: string): string;

    // ONEOF-1 naming, public for the same reason.
    //   CaseEnumName  'TM', 'pick'      -> 'TMPickCase'
    //   CaseValueName 'TM', 'pick', 'a' -> 'MPickCaseA'   ('' member -> None)
    class function CaseEnumName(const AClassName, AOneof: string): string;
    class function CaseValueName(const AClassName, AOneof,
      AMemberProp: string): string;

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

{ FORWARD-1. Index of a message in the file's list, or -1.

  A linear scan rather than a dictionary: the list is small, and this runs once
  per message-typed field at generation time, never at run time. }
function TMessagesEmitter.MessageIndex(AMsg: TProtoMessageNode): Integer;
var
  I: Integer;
begin
  for I := 0 to FFile.Messages.Count - 1 do
    if FFile.Messages[I] = AMsg then Exit(I);
  Result := -1;
end;

// FORWARD-1. Emits `TFoo = class;` for every message REFERENCED BEFORE IT IS
// DECLARED.
//
// Declaration order in a .proto carries no meaning - protoc does not care, and
// a schema is free to write
//
//     message A { B b = 1; }
//     message B { }
//
// Pascal does care: classes are emitted in list order, so TA would name TB
// before TB exists. Until FORWARD-1 that generated a unit the compiler rejects,
// from a schema protoc accepts.
//
// ZERO of the 7301 googleapis schemas in corpus-check.sh hit this, which is why
// it went unnoticed - and that fact is worth distrusting rather than trusting.
// googleapis is one organisation with a house style that happens to declare in
// dependency order. A user writing their own .proto has no such discipline, so
// the corpus is systematically blind here: it measures what Google writes, not
// what a first-time user writes.
//
// Only what is NEEDED is emitted, for two reasons. A forward nobody needs is
// noise in generated code someone has to read. And the C2 gate compares emitted
// output byte-for-byte against the hand-written samples: those are all scalars,
// so they emit no forwards and the comparison keeps meaning what it meant.
//
// Two cases deliberately produce nothing:
//   - a SELF-reference, `message Node { Node next = 1; }`. The class name is
//     already in scope inside its own declaration.
//   - a bundled well-known type. TProtobufTimestamp is declared in another
//     unit entirely; a forward here would be a second, conflicting declaration.
procedure TMessagesEmitter.EmitForwardDecls;
var
  I, J, K: Integer;
  LMsg, LTarget: TProtoMessageNode;
  LField: TProtoFieldNode;
  LNeed: TArray<Boolean>;
  LAny: Boolean;
begin
  if FFile.Messages.Count = 0 then Exit;
  SetLength(LNeed, FFile.Messages.Count);

  for I := 0 to FFile.Messages.Count - 1 do
  begin
    LMsg := FFile.Messages[I];
    for J := 0 to LMsg.Fields.Count - 1 do
    begin
      LField := LMsg.Fields[J];
      if not IsMessageField(LField) then Continue;
      if WellKnownPascalClass(LField.TypeName) <> '' then Continue;
      LTarget := FFile.FindMessage(LField.TypeName);
      if LTarget = nil then Continue;
      K := MessageIndex(LTarget);
      { Strictly LATER only. K = I is a self-reference and needs nothing. }
      if K > I then LNeed[K] := True;
    end;
  end;

  LAny := False;
  for I := 0 to High(LNeed) do
    if LNeed[I] then LAny := True;
  if not LAny then Exit;

  W('  // Forward declarations - these messages are referenced by a message');
  W('  // declared earlier in the file. Order in a .proto is not significant;');
  W('  // in Pascal it is.');
  for I := 0 to High(LNeed) do
    if LNeed[I] then
      W('  ' + PascalTypeName(FFile.Messages[I].QualifiedName) + ' = class;');
  W;
end;

procedure TMessagesEmitter.EmitTypeSection;
var
  I: Integer;
begin
  if (FFile.Enums.Count = 0) and (FFile.Messages.Count = 0) then
    Exit;
  W('type');
  { FORWARD-1 first, so a forward precedes every possible use. }
  EmitForwardDecls;
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

  { ONEOF-1 rides on exactly the same machinery. A oneof member IS a field
    with explicit presence; the only thing a oneof adds is that setting one
    clears its siblings, which lives in the generated setter. That is why
    supporting oneof needed no codec change. }
  if (AField.FieldLabel <> plOptional) and (not AField.InOneof) then Exit;

  if AField.Scalar <> psNone then Exit(True);      // a built-in scalar

  if FFile.FindEnum(AField.TypeName) <> nil then
    Exit(True);                                    // enum: varint, needs a bit

  { A MESSAGE, which the two cases must refuse for different reasons. }

  if AField.InOneof then
    raise EEmitError.CreateFmt(
      'Field %s is a message inside oneof %s. Clearing a oneof member means ' +
      'FREEING the one previously set, and protogen emits no destructor for ' +
      'generated message classes - a submessage field has no ownership story ' +
      'here yet, so clearing one would either leak it or silently not clear ' +
      'it. Move the field out of the oneof, or give the oneof a wrapper ' +
      'message of its own.',
      [QuotedStr(AField.Name), QuotedStr(AField.OneofName)]);

  raise EEmitError.CreateFmt(
    'Field %s is `optional %s`, and %s is a message. A message field already ' +
    'has explicit presence - unset means nil, and nil is not emitted - so a ' +
    'has-bit would be a second, contradictory source of truth and the ' +
    'serializer refuses that pairing. Drop `optional`.',
    [QuotedStr(AField.Name), AField.TypeName, AField.TypeName]);
end;

{ PROTOGEN-DTOR. Does this field hold MESSAGE instance(s) the class must free?

  `psNone` means "not a built-in scalar", which covers both message and enum
  references; an enum is an ordinary ordinal and owns nothing, so it is the
  message case that matters. Well-known types count: `Timestamp` maps to a
  CLASS (`TProtobufTimestamp`) and the codec allocates it like any other
  submessage.

  Deliberately non-raising, unlike NeedsHasBit, because it is asked about
  every field of every message rather than only about ones the author marked. }
function TMessagesEmitter.IsMessageField(AField: TProtoFieldNode): Boolean;
begin
  { STRUCT-1. A bundled well-known ENUM is not in FFile.Enums - it is not
    declared in the .proto at all - so the FindEnum test alone calls
    google.protobuf.NullValue a message, puts it in the generated destructor,
    and emits `.Free` on an enum value. WellKnownIsEnum is the only thing that
    can tell them apart. }
  Result := (AField.Scalar = psNone)
            and (FFile.FindEnum(AField.TypeName) = nil)
            and not WellKnownIsEnum(AField.TypeName);
end;

function TMessagesEmitter.OwnsMessages(AMsg: TProtoMessageNode): Boolean;
var
  I: Integer;
begin
  for I := 0 to AMsg.Fields.Count - 1 do
    if IsMessageField(AMsg.Fields[I]) then Exit(True);
  Result := False;
end;

{ MAP-1. The Pascal key/value types of a map field, read off the SYNTHESISED
  entry message rather than stored on the field.

  The entry has exactly two fields, `key` = 1 and `value` = 2, because the
  parser built it that way from the proto3 definition of a map. Reading them
  back from there means the accessors and the wire representation cannot
  disagree - there is only one place the types are written down. }
function TMessagesEmitter.MapKeyType(AField: TProtoFieldNode): string;
var
  LEntry: TProtoMessageNode;
begin
  LEntry := FFile.FindMessage(AField.TypeName);
  if (LEntry = nil) or (LEntry.Fields.Count < 2) then
    raise EEmitError.CreateFmt(
      'Map field %s names entry message %s, which is missing or malformed. '
      + 'The parser synthesises it with key=1 and value=2; this should be '
      + 'unreachable.', [QuotedStr(AField.Name), QuotedStr(AField.TypeName)]);
  Result := PascalFieldType(LEntry.Fields[0], FFile);
end;

function TMessagesEmitter.MapValueType(AField: TProtoFieldNode): string;
var
  LEntry: TProtoMessageNode;
begin
  LEntry := FFile.FindMessage(AField.TypeName);
  if (LEntry = nil) or (LEntry.Fields.Count < 2) then
    raise EEmitError.CreateFmt(
      'Map field %s names entry message %s, which is missing or malformed.',
      [QuotedStr(AField.Name), QuotedStr(AField.TypeName)]);
  Result := PascalFieldType(LEntry.Fields[1], FFile);
end;

{ Upper-cases the first character only. proto names are conventionally
  lower_snake, and the generated identifiers built from them read as Pascal. }
function CapFirst(const S: string): string;
begin
  Result := S;
  if Result <> '' then
    Result[1] := UpCase(Result[1]);
end;

{ Distinct oneof group names, in first-appearance order. Field order rather
  than sorted, so generated output is stable against the .proto's own layout. }
function TMessagesEmitter.OneofGroups(AMsg: TProtoMessageNode): TArray<string>;
var
  I, J: Integer;
  LSeen: Boolean;
begin
  SetLength(Result, 0);
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    if not AMsg.Fields[I].InOneof then Continue;
    LSeen := False;
    for J := 0 to High(Result) do
      if SameText(Result[J], AMsg.Fields[I].OneofName) then
      begin
        LSeen := True;
        Break;
      end;
    if not LSeen then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := AMsg.Fields[I].OneofName;
    end;
  end;
end;

class function TMessagesEmitter.CaseEnumName(const AClassName,
  AOneof: string): string;
begin
  { AClassName already carries the leading T. }
  Result := AClassName + CapFirst(AOneof) + 'Case';
end;

class function TMessagesEmitter.CaseValueName(const AClassName, AOneof,
  AMemberProp: string): string;
begin
  { Pascal enum values are NOT scoped, so every value must be unique across
    the whole unit. Deriving from the enum type name (minus its leading T)
    makes collisions impossible between two oneofs, or two messages that
    happen to use the same member names. }
  Result := Copy(CaseEnumName(AClassName, AOneof), 2, MaxInt);
  if AMemberProp = '' then
    Result := Result + 'None'
  else
    Result := Result + CapFirst(AMemberProp);
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

{ ONEOF-1. One discriminator enum per oneof group, emitted immediately before
  the class that uses it. `None` is first so it is the zero value, which makes
  a freshly-constructed message report "nothing set" without any constructor. }
procedure TMessagesEmitter.EmitOneofCaseEnums(AMsg: TProtoMessageNode);
var
  LGroups: TArray<string>;
  G, I: Integer;
  LClass, LRenamed: string;
  LNames: TArray<string>;
begin
  LGroups := OneofGroups(AMsg);
  if Length(LGroups) = 0 then Exit;
  LClass := PascalTypeName(AMsg.QualifiedName);

  for G := 0 to High(LGroups) do
  begin
    { Names collected first so the comma placement is decided once, against a
      known count, rather than guessed inside the emit loop. }
    SetLength(LNames, 1);
    LNames[0] := CaseValueName(LClass, LGroups[G], '');
    for I := 0 to AMsg.Fields.Count - 1 do
      if SameText(AMsg.Fields[I].OneofName, LGroups[G]) then
      begin
        SetLength(LNames, Length(LNames) + 1);
        LNames[High(LNames)] := CaseValueName(LClass, LGroups[G],
          PascalFieldName(AMsg.Fields[I].Name, LRenamed));
      end;

    W('  { which member of oneof ' + LGroups[G] + ' is set, if any }');
    W('  ' + CaseEnumName(LClass, LGroups[G]) + ' = (');
    for I := 0 to High(LNames) do
      if I < High(LNames) then
        W('    ' + LNames[I] + ',')
      else
        W('    ' + LNames[I]);
    W('  );');
    W;
  end;
end;

procedure TMessagesEmitter.EmitMessage(AMsg: TProtoMessageNode);
var
  I, J: Integer;
  LField, LOther: TProtoFieldNode;
  LPropName, LRenamedFrom, LBackField, LFieldType: string;
  LOtherName, LOtherRenamed: string;
  LAnyOptional: Boolean;
  LAnyMap: Boolean;
  LGroups: TArray<string>;
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

  { MAP-1. Same problem, five identifiers wide: a map field `m` also claims
    MCount / HasM / GetM / SetM / ClearM. Checked here for the same reason -
    the user wrote the .proto, not the Pascal, so the diagnostic has to be in
    terms of the .proto. }
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField := AMsg.Fields[I];
    if not LField.IsMap then Continue;
    LPropName := CapFirst(PascalFieldName(LField.Name, LRenamedFrom));
    for J := 0 to AMsg.Fields.Count - 1 do
    begin
      if J = I then Continue;
      LOther     := AMsg.Fields[J];
      LOtherName := PascalFieldName(LOther.Name, LOtherRenamed);
      if SameText(LOtherName, LPropName + 'Count')
        or SameText(LOtherName, 'Has'   + LPropName)
        or SameText(LOtherName, 'Get'   + LPropName)
        or SameText(LOtherName, 'Set'   + LPropName)
        or SameText(LOtherName, 'Clear' + LPropName) then
        raise EEmitError.CreateFmt(
          'Field %s is a map, so the generator emits %sCount, Has%s, Get%s, ' +
          'Set%s and Clear%s - but field %s already takes one of those names. '
          + 'Pascal is case-insensitive, so the two would collide. Rename one '
          + 'of them.',
          [QuotedStr(LField.Name), LPropName, LPropName, LPropName, LPropName,
           LPropName, QuotedStr(LOther.Name)]);
    end;
  end;

  LAnyOptional := False;

  { The case enums must precede the class that uses them. }
  EmitOneofCaseEnums(AMsg);

  W('  [TGrpcMessage]');
  W('  ' + PascalTypeName(AMsg.QualifiedName) + ' = class');
  W('  private');

  { TWO passes, and the split is a language requirement rather than a style
    choice: within one visibility section Pascal demands every FIELD precede
    any METHOD or PROPERTY. Emitting field/has-bit/setter per iteration puts
    the second field after the first setter and the unit does not compile -

      Error: Fields cannot appear after a method or property definition,
             start a new visibility section first

    Found by the C6b gate on its first run, after fourteen text-comparison
    checks had passed against exactly this output. Emitting valid-LOOKING
    Pascal is not the same as emitting Pascal. }

  // Pass 1 - every backing field, including has-bits.
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
    end;
  end;

  // Pass 2 - the setters, which must come after every field above.
  { The setter is the mechanism, not a convenience: deserialisation writes
    through TRttiProperty.SetValue, which calls it, which raises the bit. That
    is why the has-bit property is read-only, and why nothing on the decode
    side has to know about presence at all.

    For a oneof member the same setter also clears its siblings, which is the
    entire behavioural difference between `oneof` and a set of `optional`
    fields - and it lands on the decode path for free, giving proto3's
    "last member on the wire wins" without the decoder knowing about oneofs. }
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField := AMsg.Fields[I];
    if not NeedsHasBit(LField) then Continue;
    LPropName  := PascalFieldName(LField.Name, LRenamedFrom);
    LFieldType := PascalFieldType(LField, FFile);
    W('    procedure Set' + LPropName + '(const AValue: ' + LFieldType + ');');
  end;

  // Pass 3 - one case-getter per oneof group.
  LGroups := OneofGroups(AMsg);
  for I := 0 to High(LGroups) do
    W('    function Get' + CapFirst(LGroups[I]) + 'Case: ' +
      CaseEnumName(PascalTypeName(AMsg.QualifiedName), LGroups[I]) + ';');

  { PROTOGEN-DTOR. The codec ALLOCATES submessage instances during decode
    (`ASubmessageClass.Create`) and its own comment states the contract: "the
    message class is responsible for freeing them in its destructor". protogen
    never emitted one, so every generated class with a message-typed field has
    leaked one instance per decode since codegen existed. }
  LAnyMap := False;
  for I := 0 to AMsg.Fields.Count - 1 do
    if AMsg.Fields[I].IsMap then LAnyMap := True;

  if OwnsMessages(AMsg) or LAnyOptional or LAnyMap then
    W('  public');

  if OwnsMessages(AMsg) then
    W('    destructor Destroy; override;');

  { MAP-1 accessors sit beside the destructor: a map field is a repeated
    submessage, so a message with one always owns instances too. }
  if LAnyMap then
    EmitMapAccessorDecls(AMsg);

  if LAnyOptional then
  begin
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

    { One Clear + one Case property per oneof group. The Case property is
      READ-ONLY and COMPUTED from the has-bits rather than stored, for the
      same reason the has-bit itself is read-only: a derived value cannot
      desync from the thing it describes. It carries no [TProtoMember], so
      TProtobufRtti skips it - discovery ignores unannotated properties. }
    for I := 0 to High(LGroups) do
    begin
      W('    procedure Clear' + CapFirst(LGroups[I]) + ';');
      W('    property ' + CapFirst(LGroups[I]) + 'Case: ' +
        CaseEnumName(PascalTypeName(AMsg.QualifiedName), LGroups[I]) +
        ' read Get' + CapFirst(LGroups[I]) + 'Case;');
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

{ Every method body the emitter produces, for every message: the PRESENCE-1
  setters and Clears, the ONEOF-1 group Clears and case-getters, and the
  PROTOGEN-DTOR destructor.

  Declarations and bodies are produced from the same PascalFieldName /
  HasBitName / CaseEnumName calls, so they cannot drift apart - a drift there
  is a link error rather than a silent wrong result.

  Named for what it does rather than for PRESENCE-1 alone, which is what it
  started as; a procedure emitting three unrelated body kinds under the name
  EmitOptionalBodies would mislead the next reader. }
procedure TMessagesEmitter.EmitImplementationBodies;
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
      { ONEOF-1. Clearing the whole group FIRST is what makes "at most one is
        set" true, and it is the only behavioural difference between a oneof
        member and an `optional` field. It also lands on the decode path for
        free: deserialisation reaches this setter, so two members arriving on
        the wire leave only the last one set - proto3's rule, without the
        decoder knowing oneofs exist. }
      if LField.InOneof then
        W('  Clear' + CapFirst(LField.OneofName) + ';');
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
    EmitOneofBodies(LMsg);
    EmitMapAccessorBodies(LMsg);
    EmitDestructorBody(LMsg);
  end;
end;

{ PROTOGEN-DTOR body. Frees every message instance the class owns.

  Repeated message fields free each ELEMENT: the codec allocates one instance
  per element and hands the array ownership, the same contract a scalar
  submessage property has. `.Free` is nil-safe, so an unset singular field and
  an empty array both cost nothing.

  Only message-typed fields appear here. Scalars own nothing, enums own
  nothing, and a repeated SCALAR array is managed by the RTL. }
{ MAP-1 declarations. The entry ARRAY stays the published property - it is
  what goes on the wire, and anyone wanting ordered access iterates it. These
  sit on top for the access pattern people actually want from a map.

  Lookup is a LINEAR SCAN, stated plainly rather than hidden: proto maps are
  typically small, and the alternative was a TDictionary the codec cannot
  serialise without dragging libffi in. If a large map ever matters, the array
  is public and a caller can build their own index. }
procedure TMessagesEmitter.EmitMapAccessorDecls(AMsg: TProtoMessageNode);
var
  I: Integer;
  LField: TProtoFieldNode;
  LProp, LName, LRenamed, LK, LV: string;
begin
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField := AMsg.Fields[I];
    if not LField.IsMap then Continue;
    LProp := PascalFieldName(LField.Name, LRenamed);
    LName := CapFirst(LProp);       // the METHOD half; the FIELD stays F<prop>
    LK    := MapKeyType(LField);
    LV    := MapValueType(LField);
    W('    function  ' + LName + 'Count: Integer;');
    W('    function  Has' + LName + '(const AKey: ' + LK + '): Boolean;');
    W('    function  Get' + LName + '(const AKey: ' + LK + '): ' + LV + ';');
    W('    procedure Set' + LName + '(const AKey: ' + LK +
      '; const AValue: ' + LV + ');');
    W('    procedure Clear' + LName + ';');
  end;
end;

procedure TMessagesEmitter.EmitMapAccessorBodies(AMsg: TProtoMessageNode);
var
  I: Integer;
  LField: TProtoFieldNode;
  LClass, LProp, LName, LRenamed, LK, LV, LEntryCls: string;
  LOwnsValue: Boolean;
begin
  LClass := PascalTypeName(AMsg.QualifiedName);
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField := AMsg.Fields[I];
    if not LField.IsMap then Continue;
    LProp     := PascalFieldName(LField.Name, LRenamed);
    LName     := CapFirst(LProp);   // must match EmitMapAccessorDecls exactly
    LK        := MapKeyType(LField);
    LV        := MapValueType(LField);
    LEntryCls := PascalTypeName(LField.TypeName);
    { A message-VALUED map owns an instance per entry, so Set has to dispose of
      what it displaces. Read off the entry's own `value` field for the same
      reason MapValueType is: one place says what the value is. }
    LOwnsValue := IsMessageField(FFile.FindMessage(LField.TypeName).Fields[1]);

    W('function ' + LClass + '.' + LName + 'Count: Integer;');
    W('begin');
    W('  Result := Length(F' + LProp + ');');
    W('end;');
    W;

    W('function ' + LClass + '.Has' + LName +
      '(const AKey: ' + LK + '): Boolean;');
    W('var');
    W('  I: Integer;');
    W('begin');
    W('  for I := 0 to High(F' + LProp + ') do');
    W('    if F' + LProp + '[I].key = AKey then Exit(True);');
    W('  Result := False;');
    W('end;');
    W;

    { An absent key yields the VALUE TYPE'S DEFAULT, which is what proto3
      itself says a missing map entry means - not an exception. Has<Field>
      exists for callers who need to tell absent from present-and-default. }
    W('function ' + LClass + '.Get' + LName +
      '(const AKey: ' + LK + '): ' + LV + ';');
    W('var');
    W('  I: Integer;');
    W('begin');
    W('  for I := 0 to High(F' + LProp + ') do');
    W('    if F' + LProp + '[I].key = AKey then Exit(F' + LProp + '[I].value);');
    W('  Result := Default(' + LV + ');');
    W('end;');
    W;

    { Replace-or-append, so a map cannot end up with duplicate keys through
      this API. The wire CAN carry duplicates - a hostile or buggy peer may
      send them - and decoding appends them as entries; last-wins lookup falls
      out of the scan order. }
    if LOwnsValue then
    begin
      W('{ Takes ownership of AValue: the entry frees it, as every other');
      W('  message-typed field on a generated class is freed. Replacing an');
      W('  existing key frees what was there - without that, an ordinary');
      W('  overwrite would leak an instance per call. }');
    end;
    W('procedure ' + LClass + '.Set' + LName +
      '(const AKey: ' + LK + '; const AValue: ' + LV + ');');
    W('var');
    W('  I: Integer;');
    W('  LEntry: ' + LEntryCls + ';');
    W('begin');
    W('  for I := 0 to High(F' + LProp + ') do');
    W('    if F' + LProp + '[I].key = AKey then');
    W('    begin');
    if LOwnsValue then
    begin
      { Guarded: Set(k, x) where x is ALREADY the stored instance must not free
        it and then store a dangling pointer. }
      W('      if F' + LProp + '[I].value <> AValue then');
      W('        F' + LProp + '[I].value.Free;');
    end;
    W('      F' + LProp + '[I].value := AValue;');
    W('      Exit;');
    W('    end;');
    W('  LEntry := ' + LEntryCls + '.Create;');
    W('  LEntry.key   := AKey;');
    W('  LEntry.value := AValue;');
    W('  SetLength(F' + LProp + ', Length(F' + LProp + ') + 1);');
    W('  F' + LProp + '[High(F' + LProp + ')] := LEntry;');
    W('end;');
    W;

    { Frees the entries: they are owned here, same contract the destructor
      answers. Emptying the array without freeing would leak exactly what
      PROTOGEN-DTOR was added to stop leaking. }
    W('procedure ' + LClass + '.Clear' + LName + ';');
    W('var');
    W('  I: Integer;');
    W('begin');
    W('  for I := 0 to High(F' + LProp + ') do');
    W('    F' + LProp + '[I].Free;');
    W('  SetLength(F' + LProp + ', 0);');
    W('end;');
    W;
  end;
end;

procedure TMessagesEmitter.EmitDestructorBody(AMsg: TProtoMessageNode);
var
  I: Integer;
  LField: TProtoFieldNode;
  LClass, LProp, LRenamed: string;
  LNeedsLoopVar: Boolean;
begin
  if not OwnsMessages(AMsg) then Exit;
  LClass := PascalTypeName(AMsg.QualifiedName);

  LNeedsLoopVar := False;
  for I := 0 to AMsg.Fields.Count - 1 do
    if IsMessageField(AMsg.Fields[I]) and AMsg.Fields[I].IsRepeated then
      LNeedsLoopVar := True;

  W('destructor ' + LClass + '.Destroy;');
  if LNeedsLoopVar then
  begin
    W('var');
    W('  I: Integer;');
  end;
  W('begin');
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField := AMsg.Fields[I];
    if not IsMessageField(LField) then Continue;
    LProp := PascalFieldName(LField.Name, LRenamed);
    if LField.IsRepeated then
    begin
      W('  for I := 0 to High(F' + LProp + ') do');
      W('    F' + LProp + '[I].Free;');
    end
    else
      W('  F' + LProp + '.Free;');
  end;
  W('  inherited;');
  W('end;');
  W;
end;

{ ONEOF-1 bodies: one Clear and one case-getter per group.

  Clear touches the fields DIRECTLY rather than calling the per-field Clear
  methods. Going through those would work today, but it makes the group's
  invariant depend on each member's Clear staying trivial - and the setters
  call this, so any future per-field Clear that itself touched the group would
  recurse. Writing the fields here keeps the group's rule in exactly one
  place.

  The case-getter is COMPUTED from the has-bits, never stored. A stored
  discriminator is a second copy of the truth, and the whole design of
  PRESENCE-1 is that presence has exactly one representation. }
procedure TMessagesEmitter.EmitOneofBodies(AMsg: TProtoMessageNode);
var
  LGroups: TArray<string>;
  G, I: Integer;
  LClass, LProp, LRenamed, LType, LEnum: string;
  LFirst: Boolean;
begin
  LGroups := OneofGroups(AMsg);
  if Length(LGroups) = 0 then Exit;
  LClass := PascalTypeName(AMsg.QualifiedName);

  for G := 0 to High(LGroups) do
  begin
    LEnum := CaseEnumName(LClass, LGroups[G]);

    W('procedure ' + LClass + '.Clear' + CapFirst(LGroups[G]) + ';');
    W('begin');
    for I := 0 to AMsg.Fields.Count - 1 do
    begin
      if not SameText(AMsg.Fields[I].OneofName, LGroups[G]) then Continue;
      LProp := PascalFieldName(AMsg.Fields[I].Name, LRenamed);
      LType := PascalFieldType(AMsg.Fields[I], FFile);
      W('  F' + LProp + ' := Default(' + LType + ');');
      W('  F' + HasBitName(LProp) + ' := False;');
    end;
    W('end;');
    W;

    W('function ' + LClass + '.Get' + CapFirst(LGroups[G]) + 'Case: ' +
      LEnum + ';');
    W('begin');
    LFirst := True;
    for I := 0 to AMsg.Fields.Count - 1 do
    begin
      if not SameText(AMsg.Fields[I].OneofName, LGroups[G]) then Continue;
      LProp := PascalFieldName(AMsg.Fields[I].Name, LRenamed);
      if LFirst then
        W('  if F' + HasBitName(LProp) + ' then')
      else
        W('  else if F' + HasBitName(LProp) + ' then');
      W('    Result := ' + CaseValueName(LClass, LGroups[G], LProp));
      LFirst := False;
    end;
    W('  else');
    W('    Result := ' + CaseValueName(LClass, LGroups[G], '') + ';');
    W('end;');
    W;
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
  EmitImplementationBodies;
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
