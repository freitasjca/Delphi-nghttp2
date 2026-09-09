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
  Protogen.Ast,
  Protogen.FileSet;

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
    FNeedsSysUtils: Boolean;   // TBYTES-1 — a `bytes` field needs TBytes
    // IMPORT-1. Both nil for a single-file generation, and every cross-file
    // branch below is guarded on that: with no file set the emitter must
    // produce byte-identical output to what it produced before IMPORT-1,
    // which is what lets the C2 gate keep comparing against the hand-written
    // samples.
    FFileSet:     TProtoFileSet;
    FEntry:       TProtoFileEntry;
    FExternUnits: TStringList;   // generated units this one must `uses`

    procedure W(const ALine: string = '');
    // IMPORT-1 — the instance-level counterpart of the class function
    // PascalFieldType, which cannot see the file set.
    function  FieldType(AField: TProtoFieldNode): string;
    procedure NoteExternUnit(const AUnitName: string);
    procedure ScanForWKT;
    procedure ScanForBytes;
    procedure ScanForExternUnits;   // IMPORT-1
    procedure EmitBoilerplate;
    procedure EmitUsesClause;
    procedure EmitTypeSection;
    // ENUMCOLLIDE-1 — Pascal enum values share unit scope; proto's do not
    procedure CheckEnumValueCollisions;
    function  BaseEnumValueName(AEnum: TProtoEnumNode; AIndex: Integer): string;
    function  EnumValueName(AEnum: TProtoEnumNode; AIndex: Integer): string;
    // FORWARD-1 — class forwards for messages referenced before they are declared
    function  MessageIndex(AMsg: TProtoMessageNode): Integer;
    procedure EmitForwardDecls;
    procedure EmitEnum(AEnum: TProtoEnumNode);
    procedure EmitMessage(AMsg: TProtoMessageNode);
    // PRESENCE-1 — proto3 `optional`
    function  NeedsHasBit(AField: TProtoFieldNode): Boolean;
    // ONEOF-2 — a MESSAGE member of a oneof: nil is its presence, not a bit
    function  IsOneofMessageMember(AField: TProtoFieldNode): Boolean;
    function  NeedsSetter(AField: TProtoFieldNode): Boolean;
    procedure EmitImplementationBodies;
    // ONEOF-1 — proto3 `oneof`
    function  OneofGroups(AMsg: TProtoMessageNode): TArray<string>;
    { ONEOFNAME-1 — the deduped case-enum values for one group, index 0 being
      the None sentinel. ONE source, because the enum declaration and the case
      getter both need these names and computing them twice let them desync. }
    function  OneofCaseNames(AMsg: TProtoMessageNode;
      const AGroup: string): TArray<string>;
    procedure EmitOneofCaseEnums(AMsg: TProtoMessageNode);
    procedure EmitOneofBodies(AMsg: TProtoMessageNode);
    { Is this field's type an ENUM? Three call sites used to answer this
      separately and each missed a different case: FFile.Enums cannot see a
      bundled well-known enum (WKTENUM-1), cannot see an enum declared in an
      IMPORTED file, and cannot even see a same-file enum named through its
      package. Getting it wrong puts an enum in the destructor and emits
      `.Free` on it, or drops the has-bit a oneof member's own Clear then
      references. One predicate, so there is no fourth variant. }
    function  IsEnumField(AField: TProtoFieldNode): Boolean;
    // FORWARD-1 — the same-file message a field names, or nil
    function  LocalMessageTarget(AField: TProtoFieldNode): TProtoMessageNode;
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

    constructor Create;
    destructor Destroy; override;

    { IMPORT-1 / SVCWKT-1. The Pascal type name for a proto type reference,
      resolved through a file set.

      ONE rule, four emitters. Messages, Interfaces, Service skeletons and
      Registration all name proto types, and before IMPORT-1 the three service
      emitters called PascalTypeName directly — which mangles rather than
      resolves. That produced `TGoogleProtobufEmpty` for an rpc taking
      google.protobuf.Empty, a type nothing declares, and it would produce an
      undeclared name for any rpc whose request or response lives in an
      imported file.

      AExternUnit is the generated unit that must appear in the caller's uses
      clause, or '' when none is needed (a scalar, a same-file type, or a
      bundled well-known type). Callers collect it; this function does not
      know where their uses clause lives.

      Returns '' — NOT a guess — when the file set cannot resolve the name, so
      callers fall back to their own same-file rule. That rule handles one case
      this one does not: proto scoping is innermost-outward, so a field inside
      `message M` may name a type nested in M by its bare name. Resolving that
      here would need the enclosing scope threaded through; the AST's
      FindMessage/FindEnum already do it by simple-name lookup, which is
      unambiguous within a single file.

      Found by measurement, not by review: this returned a mangled `TState` for
      every `enum State` nested in its own message, and the corpus is full of
      them. }
    class function QualifiedTypeName(AFileSet: TProtoFileSet;
      AEntry: TProtoFileEntry; const ATypeName: string;
      out AExternUnit: string; const AScope: string = ''): string;

    // Emit a complete .Messages.pas into ALines. ALines is cleared first.
    // AUnitPrefix: dotted name prefix, e.g. 'Sample.Greeter' -- the unit
    // name becomes '<AUnitPrefix>.Messages'.
    // AProtoFileName: used only in the generated file-level comment.
    // AFileSet/AEntry supply cross-file resolution. Omit both (the default)
    // and the emitter behaves exactly as it did before IMPORT-1.
    procedure Emit(AFile: TProtoFileNode;
      const AUnitPrefix, AProtoFileName: string; ALines: TStrings;
      AFileSet: TProtoFileSet = nil; AEntry: TProtoFileEntry = nil);

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

    { FLATTEN-1. The Pascal type name for a declaration IN A GIVEN FILE.

      PascalTypeName strips dots, so a nested `Control.Family` and a top-level
      `ControlFamily` both come out `TControlFamily` — a duplicate identifier,
      and the largest real defect class in the first full corpus sweep
      (11 schemas; `TTemperatureUnit` is another).

      When a flattened name collides, the NESTED one restores the structure
      the flattening removed (`TControl_Family`) and the top-level one keeps
      its natural name. Only the ambiguous ones move, which is the same
      principle ENUMCOLLIDE-1 follows for enum values.

      Takes the file because the answer depends on what else that file
      declares — and a cross-file reference must use the name as computed in
      the DECLARING file, not the referring one. }
    class function TypeNameIn(AFile: TProtoFileNode;
      const AQualifiedName: string): string;

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

{ ENUMWORD-1. Identifiers a generated ENUM VALUE must not take.

  Two distinct hazards, and only the first is a reserved word:

    RESERVED    `END`, `STRING`, `AND`, `INHERITED` - the compiler stops at
                the token. Loud, and found immediately.
    INTRINSIC   `HIGH`, `LOW` and friends are NOT reserved; they are shadowable
                identifiers. Declaring `HIGH` as an enum value makes the
                generated destructor's own `High(FSomeArray)` stop resolving,
                and the error lands in the DESTRUCTOR - "DO expected but (
                found" - naming a line that is perfectly correct. That is
                the nastier of the two.

  Only the intrinsics the emitter itself EMITS matter, so this list is short
  and closed rather than a copy of the RTL: High and Low (destructors, map
  accessors), Length and SetLength (map accessors), Result and Exit (every
  generated function), Free and Create (ownership), Copy/Pos/Default. }
{ The leading segment of a dotted name — 'Demo.Google.Rpc' -> 'Demo'.
  The only part of a unit name that is resolved as a bare identifier, and so
  the only part an enum value can shadow. }
function FirstNameSegment(const ADotted: string): string;
var
  P: Integer;
begin
  P := Pos('.', ADotted);
  if P > 0 then
    Result := Copy(ADotted, 1, P - 1)
  else
    Result := ADotted;
end;

{ Routines the generated code CALLS. An identifier here is dangerous wherever
  it is in scope as an expression — including a property name, because a
  property is in scope inside its own class's method bodies. }
function IsGeneratedCodeRoutine(const AName: string): Boolean;
var
  LName: string;
begin
  LName := LowerCase(AName);
  Result :=
    (LName = 'high')   or (LName = 'low')       or (LName = 'length')   or
    (LName = 'setlength') or (LName = 'result')  or (LName = 'exit')     or
    (LName = 'free')   or (LName = 'create')    or (LName = 'default')  or
    (LName = 'copy')   or (LName = 'pos')       or (LName = 'ord')      or
    (LName = 'assigned') or (LName = 'inc')     or (LName = 'dec')      or
    (LName = 'true')   or (LName = 'false')     or (LName = 'nil')      or
    (LName = 'self');
end;

{ TYPE names the generated code emits. Missed on the first pass, which covered
  routines only - and an enum value shadowing a type fails in a stranger place:
  `BOOL`, `DOUBLE` and `INT64` in one googleapis enum made `TArray<Double>` on
  a LATER line report "Type mismatch". }
function IsGeneratedCodeTypeName(const AName: string): Boolean;
var
  LName: string;
begin
  LName := LowerCase(AName);
  Result :=
    (LName = 'integer') or (LName = 'int64')    or (LName = 'boolean')  or
    (LName = 'double')  or (LName = 'single')   or (LName = 'cardinal') or
    (LName = 'uint32')  or (LName = 'uint64')   or (LName = 'tbytes')   or
    (LName = 'tarray')  or (LName = 'byte')     or (LName = 'word')     or
    (LName = 'longint') or (LName = 'smallint') or (LName = 'shortint') or
    (LName = 'extended') or (LName = 'currency') or (LName = 'pointer') or
    (LName = 'tobject') or (LName = 'tclass');
end;

{ Both, for ENUM VALUES — they are declared into a type section, so a type name
  collides there just as a routine name does.

  FIELD names deliberately use the ROUTINE half alone. Renaming on the type
  half too was tried and reverted: it renamed ordinary proto fields called
  `single` and `double` that had always compiled, which broke the C2 sample
  comparison and every consumer spelling the old property name — churn with no
  safety bought, since a property shadows a type name only in the narrow case
  where its own class also declares a member of that type. }
function IsGeneratedCodeIntrinsic(const AName: string): Boolean;
begin
  Result := IsGeneratedCodeRoutine(AName) or IsGeneratedCodeTypeName(AName);
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

{ TBYTES-1. Does any field emit TBytes? Only `bytes` does - repeated or not,
  since TArray<TBytes> needs the element type just the same. }
procedure TMessagesEmitter.ScanForBytes;
var
  I, J: Integer;
begin
  FNeedsSysUtils := False;
  for I := 0 to FFile.Messages.Count - 1 do
    for J := 0 to FFile.Messages[I].Fields.Count - 1 do
      if FFile.Messages[I].Fields[J].Scalar = psBytes then
      begin
        FNeedsSysUtils := True;
        Exit;
      end;
end;

{ IMPORT-1. Which OTHER generated units does this one reference?

  Deliberately implemented by calling FieldType and discarding the result,
  rather than by re-deriving the resolution rules here. The two must agree
  exactly: a scan that missed a type would leave its unit out of the uses
  clause, and a scan that found one the emitter does not emit would add a unit
  nobody references. Sharing the one function makes disagreement impossible
  rather than merely unlikely.

  Map fields need the extra pass because their key and value types come from
  the synthesised entry message, which the field walk never visits directly. }
procedure TMessagesEmitter.ScanForExternUnits;
var
  I, J: Integer;
  LMsg: TProtoMessageNode;
  LField: TProtoFieldNode;
begin
  FExternUnits.Clear;
  if (FFileSet = nil) or (FEntry = nil) then
    Exit;
  for I := 0 to FFile.Messages.Count - 1 do
  begin
    LMsg := FFile.Messages[I];
    for J := 0 to LMsg.Fields.Count - 1 do
    begin
      LField := LMsg.Fields[J];
      FieldType(LField);
      if LField.IsMap then
      begin
        MapKeyType(LField);
        MapValueType(LField);
      end;
    end;
  end;
end;

procedure TMessagesEmitter.NoteExternUnit(const AUnitName: string);
begin
  if (AUnitName <> '') and (AUnitName <> FUnitPrefix + '.Messages') then
    FExternUnits.Add(AUnitName);
end;

{ The scope a field's type reference resolves against: the message it was
  declared in, or file scope when there is none.

  Read off the field rather than threaded through the twenty call sites of the
  five predicates that resolve a type. That is what keeps IsEnumField,
  LocalMessageTarget and FieldType from disagreeing about what a bare name
  means — a disagreement that puts .Free on an enum value. }
function ScopeOf(AField: TProtoFieldNode): string;
begin
  if (AField = nil) or (AField.Owner = nil) then
    Result := ''
  else
    Result := AField.Owner.QualifiedName;
end;

{ IMPORT-1. The Pascal type for a field, resolved across files.

  A cross-file reference is emitted FULLY QUALIFIED — Demo.Google.Rpc.Status.
  Messages.TStatus — because short names collide constantly in real schemas
  (Status, Error, Metadata, Operation all recur across googleapis packages)
  and a bare name binds to whichever unit comes last in the uses clause,
  silently and possibly wrongly. tests/qualref/ProtoQualRefProbe.dpr pins both
  halves of that: the qualified form resolves to the right unit, and the bare
  form really does bind to the last one. }
function TMessagesEmitter.FieldType(AField: TProtoFieldNode): string;
var
  LBase:  string;
  LExtern: string;
begin
  // No file set, or a scalar: the single-file path decides, unchanged.
  if (FFileSet = nil) or (FEntry = nil) or (AField.Scalar <> psNone) then
    Exit(PascalFieldType(AField, FFile));

  LBase := QualifiedTypeName(FFileSet, FEntry, AField.TypeName, LExtern,
    ScopeOf(AField));
  // Unresolved by the file set: the single-file path knows about nested types.
  if LBase = '' then
    Exit(PascalFieldType(AField, FFile));
  NoteExternUnit(LExtern);

  if AField.IsRepeated then
    Result := 'TArray<' + LBase + '>'
  else
    Result := LBase;
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

// TBYTES-1. A proto3 `bytes` field emits TBytes, which lives in SysUtils - and
// SysUtils was never named in a generated uses clause. So a generated unit for
// ANY schema with a bytes field did not compile: "Identifier not found TBytes".
// Ordinary proto3, broken since C2.
//
// It survived because the emitter had only ever been compiled against four
// schemas - echo, greeter, optional.proto and the runner fixture - and not one
// of them declares a bytes field. compile-check.sh found it in four of the
// first 302 real schemas it tried.
//
// CONDITIONAL, on the same reasoning as FNeedsWKT above it. Emitting SysUtils
// unconditionally is simpler to write and worse to live with: it changes every
// generated unit, which breaks the C2 gate's byte-for-byte comparison against
// the hand-written samples and would mean editing a sample in ANOTHER repo to
// accommodate it. A gate weakened to fit a change is worth more than the line
// of code it saved.
procedure TMessagesEmitter.EmitUsesClause;
var
  I: Integer;
begin
  W('uses');
  if FNeedsSysUtils then
  begin
    W('{$IF DEFINED(FPC)}');
    W('  SysUtils,');
    W('{$ELSE}');
    W('  System.SysUtils,');
    W('{$IFEND}');
  end;
  // IMPORT-1. Whichever entry ends up last carries the semicolon. With no
  // extern units this reproduces the pre-IMPORT-1 clause exactly, character
  // for character — the C2 gate compares generated output against
  // hand-written samples, so a stray comma here fails it.
  if FNeedsWKT or (FExternUnits.Count > 0) then
    W('  Nghttp2.Protobuf,')
  else
    W('  Nghttp2.Protobuf;');
  if FNeedsWKT then
  begin
    if FExternUnits.Count > 0 then
      W('  Nghttp2.Protobuf.WellKnown,')
    else
      W('  Nghttp2.Protobuf.WellKnown;');
  end;
  for I := 0 to FExternUnits.Count - 1 do
    if I = FExternUnits.Count - 1 then
      W('  ' + FExternUnits[I] + ';')
    else
      W('  ' + FExternUnits[I] + ',');
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
      LTarget := LocalMessageTarget(LField);
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
      W('  ' + TypeNameIn(FFile, FFile.Messages[I].QualifiedName) + ' = class;');
  W;
end;

// ENUMCOLLIDE-1, REVISED. Pascal enum values share UNIT scope; proto's do not.
//
// proto scopes an enum's values to the enum's ENCLOSING scope, so a nested enum
// keeps its values inside its message. This is legal proto3 and protoc compiles
// it happily:
//
//     message A { enum E { X = 0; } }
//     message B { enum E { X = 0; } }
//
// Pascal has no such scoping, and nested types are flattened here, so both
// would emit a bare `X` and the unit would not compile.
//
// The FIRST version of this REFUSED the schema, to match the has-bit and map
// collision checks. That was the wrong trade and the corpus said so: 336 of
// 7301 googleapis files, 4%, turned away for something we can simply resolve.
// Those other two checks fire on ambiguous USER INTENT - two fields fighting
// over one identifier, where only the author can choose. This one has an
// obvious correct answer, and the refusal message was already computing it.
//
// So a colliding value is RENAMED, prefixed from the enum's qualified name:
// A.E.X becomes A_E_X. Only the colliding ones - an enum whose values are
// unique keeps its spelling, so the common case is untouched and the C2
// byte-for-byte sample comparison keeps meaning what it meant.
//
// Still REFUSED: a duplicate value name WITHIN one enum. proto forbids it too,
// so there is no legal schema to accept and nothing sensible to rename to.
procedure TMessagesEmitter.CheckEnumValueCollisions;
var
  I, VI, VJ: Integer;
  LA: TProtoEnumNode;
begin
  for I := 0 to FFile.Enums.Count - 1 do
  begin
    LA := FFile.Enums[I];
    for VI := 0 to LA.Values.Count - 1 do
      for VJ := VI + 1 to LA.Values.Count - 1 do
        if SameText(LA.Values[VI].Name, LA.Values[VJ].Name) then
        begin
          { Two DIFFERENT reasons, and saying the wrong one sends the reader to
            the wrong place. Only the first is invalid proto3. }
          if LA.Values[VI].Name = LA.Values[VJ].Name then
            { BLOCKED-BY: invalid-proto3 }
            raise EEmitError.CreateFmt(
              'Enum %s declares the value %s twice. proto3 forbids that too, '
              + 'so the schema is invalid rather than merely unrepresentable.',
              [QuotedStr(LA.Name), QuotedStr(LA.Values[VI].Name)])
          else
            { BLOCKED-BY: pascal-language }
            raise EEmitError.CreateFmt(
              'Enum %s declares %s and %s, which differ ONLY IN CASE. That is '
              + 'legal proto3 - identifiers there are case-sensitive, and with '
              + 'option allow_alias both may even share a number - but Pascal '
              + 'identifiers are case-INSENSITIVE, so the two would be one. '
              + 'Unlike a collision BETWEEN enums this cannot be renamed '
              + 'automatically: both values sit in the same enum, so any '
              + 'prefix derived from it lands on both. Rename one in the '
              + '.proto. (Seen once in 7301 googleapis schemas: '
              + 'bigquery/v2/job.proto declares minimal and MINIMAL.)',
              [QuotedStr(LA.Name), QuotedStr(LA.Values[VI].Name),
               QuotedStr(LA.Values[VJ].Name)]);
        end;
  end;
end;

{ The Pascal identifier for one enum value. Four things can force a change, and
  each was found by compiling real schemas rather than by reasoning:

    1  RESERVED WORD      `END`, `STRING`, `AND`, `INHERITED`. Fields have been
                          renamed since C2; enum values never were.
    2  SHADOWED INTRINSIC  `HIGH`/`LOW`. Not reserved - which is why this is
                          worse: declaring one makes the generated destructor's
                          own High(...) stop resolving, and the compiler blames
                          a line in the destructor that is perfectly correct.
    3  CROSS-ENUM COLLISION  Pascal enum values share UNIT scope; proto scopes
                          them to the enclosing message.
    4  TOO LONG           FPC truncates identifiers at 127 characters, so two
                          googleads values differing only after char 128 become
                          the same identifier.

  1, 2 and 4 are checked BEFORE 3, because each can create a collision that 3
  then has to resolve - a truncated name is far more likely to clash than the
  original was. }
{ The escaped spelling of one enum value, WITHOUT the cross-enum collision
  step. Split out because the collision check must compare like with like:
  it used to test the other enum's RAW name against this one's ESCAPED name,
  so `LOW` and `LOW` in two enums — both escaped to `LOW_` because `low` is an
  intrinsic the generated code calls — compared as 'LOW' vs 'LOW_' and were
  declared not to collide.

  ENUMWORD-1 introduced that escaping and in doing so disabled ENUMCOLLIDE-1
  for exactly the values that need both. Neither gate saw it; backstory/udm.proto
  did. }
function TMessagesEmitter.BaseEnumValueName(AEnum: TProtoEnumNode;
  AIndex: Integer): string;
const
  { FPC truncates identifiers at 126 characters. MEASURED, not assumed - a
    minimal unit declaring two enum values differing only in their last
    character compiles at 90, 110 and 126, and at 127 fails with

        Error: Duplicate identifier "$XXXX..."   (126 X's)

    because both names truncate to the same 126. Delphi's limit is higher, but
    generating something that compiles on only one of the two supported
    compilers is not an option.

    120, not 126, so nothing generated here ever sits ON the boundary. That
    matters: at exactly 127 FPC misbehaves in two different ways - the toy case
    above reports a duplicate, while four real googleads schemas produced
    `Fatal: Internal error 2015071505`, a compiler crash rather than a
    diagnostic. A margin is cheaper than understanding why. }
  MAX_IDENT = 120;
var
  LHash: Cardinal;
  K: Integer;
begin
  Result := AEnum.Values[AIndex].Name;

  if IsDelphiReservedWord(LowerCase(Result)) or IsGeneratedCodeIntrinsic(Result) then
    Result := Result + '_';

  { SHADOW-1. A Pascal enum VALUE lives at unit scope and is matched
    case-insensitively, so a value spelled like the first segment of this
    unit's own name hides that namespace — and every cross-file reference is
    written through it. In google/cloud/discoveryengine, `CORPUS = 1` made
    every `Corpus.S234....TInterval` in the unit fail with "Identifier idents
    no member S234".

    Not an artefact of the corpus harness's prefix: with --unit-prefix Sample,
    an enum value SAMPLE breaks a generated unit exactly the same way. Only the
    FIRST segment matters — the rest are resolved as members of it. }
  if SameText(Result, FirstNameSegment(FUnitPrefix)) then
    Result := Result + '_';

  { Truncate with a hash of the FULL name, so two values sharing a long prefix
    stay distinct. Ugly, and the alternative was refusing a schema protoc
    accepts because one identifier is 150 characters long. }
  if Length(Result) > MAX_IDENT then
  begin
    LHash := 2166136261;                                   // FNV-1a
    for K := 1 to Length(AEnum.Values[AIndex].Name) do
      LHash := (LHash xor Ord(AEnum.Values[AIndex].Name[K])) * 16777619;
    Result := Copy(Result, 1, MAX_IDENT - 9) + '_' + IntToHex(LHash, 8);
  end;
end;

function TMessagesEmitter.EnumValueName(AEnum: TProtoEnumNode;
  AIndex: Integer): string;
var
  J, V: Integer;
  LOther: TProtoEnumNode;
begin
  Result := BaseEnumValueName(AEnum, AIndex);

  { Cross-enum collision, LAST, so it sees the name the other rules produced —
    on BOTH sides. Comparing against the other enum's escaped name is the whole
    point: raw-vs-escaped is what let LOW_ be declared twice. }
  for J := 0 to FFile.Enums.Count - 1 do
  begin
    LOther := FFile.Enums[J];
    if LOther = AEnum then Continue;
    for V := 0 to LOther.Values.Count - 1 do
      if SameText(BaseEnumValueName(LOther, V), Result) then
      begin
        Result := UpperCase(StringReplace(AEnum.QualifiedName, '.', '_',
                    [rfReplaceAll])) + '_' + Result;
        Exit;
      end;
  end;
end;


procedure TMessagesEmitter.EmitTypeSection;
var
  I: Integer;
begin
  if (FFile.Enums.Count = 0) and (FFile.Messages.Count = 0) then
    Exit;
  { ENUMCOLLIDE-1 before a line is written, so the diagnostic is not buried
    under partial output. }
  CheckEnumValueCollisions;
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
  W('  ' + TypeNameIn(FFile, AEnum.QualifiedName) + ' = (');
  for I := 0 to AEnum.Values.Count - 1 do
  begin
    LLine := '    ' + EnumValueName(AEnum, I) + ' = ' +
      IntToStr(AEnum.Values[I].Number);
    { A renamed value is called out where it is declared, so the difference
      from the .proto spelling is visible at the point of use. }
    if not SameText(EnumValueName(AEnum, I), AEnum.Values[I].Name) then
      W('    // proto3: ' + AEnum.Values[I].Name +
        ' - prefixed, another enum in this file declares that name too');
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
{ ONEOF-2. A oneof member whose type is a message: presence is nil, not a bit. }
function TMessagesEmitter.IsOneofMessageMember(AField: TProtoFieldNode): Boolean;
begin
  Result := AField.InOneof and IsMessageField(AField);
end;

{ Which fields get a generated Set<Prop>. Every has-bit field needs one (the
  setter is what raises the bit), and so does a message oneof member - not for
  a bit, but because the setter is where siblings are cleared. Without it the
  property would write straight to its backing field and the group would end up
  with two members set at once. }
function TMessagesEmitter.NeedsSetter(AField: TProtoFieldNode): Boolean;
begin
  Result := NeedsHasBit(AField) or IsOneofMessageMember(AField);
end;

function TMessagesEmitter.NeedsHasBit(AField: TProtoFieldNode): Boolean;
begin
  Result := False;

  { ONEOF-1 rides on exactly the same machinery. A oneof member IS a field
    with explicit presence; the only thing a oneof adds is that setting one
    clears its siblings, which lives in the generated setter. That is why
    supporting oneof needed no codec change. }
  if (AField.FieldLabel <> plOptional) and (not AField.InOneof) then Exit;

  if AField.Scalar <> psNone then Exit(True);      // a built-in scalar

  if IsEnumField(AField) then
    Exit(True);                                    // enum: varint, needs a bit

  { WKTENUM-1. A BUNDLED well-known enum - google.protobuf.NullValue - is an
    enum too, but FindEnum cannot see it: it is not declared in this .proto.
    Without this it fell through to the message branch and got no has-bit,
    while the group Clear and the case getter both emitted references to one.
    Result: "Identifier not found FHasnull_value", in three googleapis schemas.

    IMPORT-1 then found the SAME defect twice more, for an enum in an imported
    file and for one named through its own package, which is why all three
    checks now live in IsEnumField above rather than being repeated here. }

  { A MESSAGE. Neither case takes a has-bit - nil already carries presence -
    and neither is a reason to refuse the schema. }

  { ONEOF-2. This USED TO RAISE, on the grounds that clearing a oneof member
    means freeing it and protogen emitted no destructor. That reason expired
    when PROTOGEN-DTOR added destructors, and nobody revisited the refusal - a
    refusal that outlived its cause. It cost 1391 of 7301 googleapis schemas,
    19% of the corpus, and message members are the COMMON shape of a oneof.

    A message member takes NO has-bit: AttachHasBits refuses one on a
    submessage because nil already carries presence. So the group Clear frees
    it, the case getter tests nil, and the setter clears its siblings - exactly
    what the hand-written TProtobufValue.ClearKind does in
    Nghttp2.Protobuf.WellKnown, which is the proof the shape works. }
  if AField.InOneof then Exit(False);

  { OPTMSG-1. This USED TO RAISE, and the reasoning it gave was correct: a
    has-bit on a message WOULD be a second, contradictory source of truth, and
    AttachHasBits rejects that pairing. But the conclusion did not follow.

    In proto3 a message field ALWAYS has explicit presence, so `optional Foo x`
    and `Foo x` mean exactly the same thing - the label is a no-op on a message
    and protoc treats the two identically on the wire. The right answer was
    never to reject the schema; it was to emit no has-bit and carry on. The
    field then behaves as it always did: nil is absent, and nil is not emitted.

    Second refusal in this file whose stated reason was true while its verdict
    was wrong. ONEOF-2 was the first. Cost here: ~370 of 7301 googleapis
    schemas. }
  Result := False;
end;

{ PROTOGEN-DTOR. Does this field hold MESSAGE instance(s) the class must free?

  `psNone` means "not a built-in scalar", which covers both message and enum
  references; an enum is an ordinary ordinal and owns nothing, so it is the
  message case that matters. Well-known types count: `Timestamp` maps to a
  CLASS (`TProtobufTimestamp`) and the codec allocates it like any other
  submessage.

  Deliberately non-raising, unlike NeedsHasBit, because it is asked about
  every field of every message rather than only about ones the author marked. }
function TMessagesEmitter.IsEnumField(AField: TProtoFieldNode): Boolean;
var
  LRef: TProtoTypeRef;
begin
  if AField.Scalar <> psNone then
    Exit(False);

  // Bundled: google.protobuf.NullValue is an enum and appears in no .proto
  // this generator ever parses.
  if WellKnownIsEnum(AField.TypeName) then
    Exit(True);

  { The file set matches fully-qualified names and package-relative ones, so
    where it answers, it is exact. Ask it FIRST.

    FindEnum below falls back to a SIMPLE-NAME match, and that cannot tell a
    nested `enum Role` from a top-level `message Role`. backstory/udm.proto
    declares both: the field type resolved to the message and this predicate
    to the enum, so FORWARD-1 skipped the forward declaration and the unit
    named a class nothing had declared. }
  if (FFileSet <> nil) and (FEntry <> nil) then
  begin
    LRef := FFileSet.ResolveType(FEntry, AField.TypeName, ScopeOf(AField));
    if LRef.Found then
      Exit(LRef.Enum <> nil);
  end;

  { Unresolved by the file set — a type nested in the ENCLOSING message,
    named bare. Proto scoping is innermost-outward and the file set does not
    walk scopes; the simple-name lookup does, and within one file it is
    unambiguous enough for that case. }
  Result := FFile.FindEnum(AField.TypeName) <> nil;
end;

function TMessagesEmitter.LocalMessageTarget(AField: TProtoFieldNode): TProtoMessageNode;
var
  LRef: TProtoTypeRef;
begin
  { Exact resolution first, for the reason IsEnumField gives: a same-file
    message named through its own package (`grafeas.v1.Foo` inside package
    grafeas.v1) matches neither FindMessage key, and a simple-name match can
    land on the wrong declaration entirely. }
  if (FFileSet <> nil) and (FEntry <> nil) then
  begin
    LRef := FFileSet.ResolveType(FEntry, AField.TypeName, ScopeOf(AField));
    if LRef.Found then
    begin
      // Resolved elsewhere, or to an enum: no forward declaration belongs here.
      if LRef.Entry = FEntry then
        Result := LRef.Msg
      else
        Result := nil;
      Exit;
    end;
  end;
  // Nested in the enclosing message, named bare — the scope walk the file set
  // does not do.
  Result := FFile.FindMessage(AField.TypeName);
end;

function TMessagesEmitter.IsMessageField(AField: TProtoFieldNode): Boolean;
begin
  Result := (AField.Scalar = psNone) and not IsEnumField(AField);
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
    { BLOCKED-BY: internal-invariant }
    raise EEmitError.CreateFmt(
      'Map field %s names entry message %s, which is missing or malformed. '
      + 'The parser synthesises it with key=1 and value=2; this should be '
      + 'unreachable.', [QuotedStr(AField.Name), QuotedStr(AField.TypeName)]);
  Result := FieldType(LEntry.Fields[0]);
end;

function TMessagesEmitter.MapValueType(AField: TProtoFieldNode): string;
var
  LEntry: TProtoMessageNode;
begin
  LEntry := FFile.FindMessage(AField.TypeName);
  if (LEntry = nil) or (LEntry.Fields.Count < 2) then
    { BLOCKED-BY: internal-invariant }
    raise EEmitError.CreateFmt(
      'Map field %s names entry message %s, which is missing or malformed.',
      [QuotedStr(AField.Name), QuotedStr(AField.TypeName)]);
  Result := FieldType(LEntry.Fields[1]);
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
// ONEOFNAME-1. A oneof member named `none` produces CapFirst('none') = 'None',
// which is exactly the sentinel this enum already declares - so the generated
// enum had ConsolidationStrategyStrategyCaseNone twice and did not compile.
// Real: google/apps/drive/activity/v2 declares a oneof whose members include
// one literally named `none`.
//
// Any duplicate gets '_' appended until unique, and the comparison is
// case-INSENSITIVE because Pascal is - two members `none` and `None` are one
// identifier here even though proto keeps them apart.
//
// The sentinel is index 0 and never renamed: it is ours, the members are the
// user's, and moving ours would change the generated API for every schema to
// accommodate one.
function TMessagesEmitter.OneofCaseNames(AMsg: TProtoMessageNode;
  const AGroup: string): TArray<string>;
var
  I, J: Integer;
  LClass, LRenamed, LName: string;
  LDup: Boolean;
begin
  LClass := TypeNameIn(FFile, AMsg.QualifiedName);
  SetLength(Result, 1);
  Result[0] := CaseValueName(LClass, AGroup, '');
  for I := 0 to AMsg.Fields.Count - 1 do
    if SameText(AMsg.Fields[I].OneofName, AGroup) then
    begin
      LName := CaseValueName(LClass, AGroup,
                 PascalFieldName(AMsg.Fields[I].Name, LRenamed));
      repeat
        LDup := False;
        for J := 0 to High(Result) do
          if SameText(Result[J], LName) then
          begin
            LName := LName + '_';
            LDup  := True;
            Break;
          end;
      until not LDup;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := LName;
    end;
end;

procedure TMessagesEmitter.EmitOneofCaseEnums(AMsg: TProtoMessageNode);
var
  LGroups: TArray<string>;
  G, I: Integer;
  LClass, LRenamed: string;
  LNames: TArray<string>;
begin
  LGroups := OneofGroups(AMsg);
  if Length(LGroups) = 0 then Exit;
  LClass := TypeNameIn(FFile, AMsg.QualifiedName);

  for G := 0 to High(LGroups) do
  begin
    { Names collected first so the comma placement is decided once, against a
      known count, rather than guessed inside the emit loop. }
    LNames := OneofCaseNames(AMsg, LGroups[G]);

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
        { BLOCKED-BY: user-must-choose }
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
        { BLOCKED-BY: user-must-choose }
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
  W('  ' + TypeNameIn(FFile, AMsg.QualifiedName) + ' = class');
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
    LFieldType := FieldType(LField);
    W('    ' + LBackField + ': ' + LFieldType + ';');
    if NeedsHasBit(LField) then
    begin
      LAnyOptional := True;
      W('    F' + HasBitName(LPropName) + ': Boolean;');
    end
    { ONEOF-2. No has-bit - nil is the presence - but it still needs the
      Clear<Prop> DECLARATION that this flag gates. Emitting the body without
      it gives `Method identifier expected`, which names the Clear line and not
      the missing declaration. }
    else if IsOneofMessageMember(LField) then
      LAnyOptional := True;
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
    if not NeedsSetter(LField) then Continue;
    LPropName  := PascalFieldName(LField.Name, LRenamedFrom);
    LFieldType := FieldType(LField);
    W('    procedure Set' + LPropName + '(const AValue: ' + LFieldType + ');');
  end;

  // Pass 3 - one case-getter per oneof group.
  LGroups := OneofGroups(AMsg);
  for I := 0 to High(LGroups) do
    W('    function Get' + CapFirst(LGroups[I]) + 'Case: ' +
      CaseEnumName(TypeNameIn(FFile, AMsg.QualifiedName), LGroups[I]) + ';');

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
      if not NeedsSetter(LField) then Continue;
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
        CaseEnumName(TypeNameIn(FFile, AMsg.QualifiedName), LGroups[I]) +
        ' read Get' + CapFirst(LGroups[I]) + 'Case;');
    end;
  end;

  W('  published');
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField     := AMsg.Fields[I];
    LPropName  := PascalFieldName(LField.Name, LRenamedFrom);
    LBackField := 'F' + LPropName;
    LFieldType := FieldType(LField);
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
    else if IsOneofMessageMember(LField) then
      { ONEOF-2. Through the SETTER, so siblings are cleared - but with no
        [TProtoHas]: nil is the presence signal and AttachHasBits refuses a bit
        on a submessage. }
      W('    property ' + LPropName + ': ' + LFieldType +
        ' read ' + LBackField + ' write Set' + LPropName + ';')
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
    LClass := TypeNameIn(FFile, LMsg.QualifiedName);
    for I := 0 to LMsg.Fields.Count - 1 do
    begin
      LField := LMsg.Fields[I];
      if not NeedsSetter(LField) then Continue;
      LPropName  := PascalFieldName(LField.Name, LRenamedFrom);
      LFieldType := FieldType(LField);

      { ONEOF-2. A message member owns its instance, so its setter and Clear
        are about FREEING rather than about a bit. Same shape as MAP-1's
        Set<Field> and as TProtobufValue in Nghttp2.Protobuf.WellKnown. }
      if IsOneofMessageMember(LField) then
      begin
        W('procedure ' + LClass + '.Set' + LPropName +
          '(const AValue: ' + LFieldType + ');');
        W('begin');
        { Self-assignment guard FIRST. Clear frees this very instance, so
          without it Set(X, X) frees X and then stores the freed pointer -
          the same trap MAP-1's Set had. }
        W('  if F' + LPropName + ' = AValue then Exit;');
        W('  Clear' + CapFirst(LField.OneofName) + ';');
        W('  F' + LPropName + ' := AValue;');
        W('end;');
        W;
        W('procedure ' + LClass + '.Clear' + LPropName + ';');
        W('begin');
        { Not FreeAndNil: SysUtils is not in a generated unit's uses clause,
          and pulling it in for one call would change the imports of every
          unit protogen has ever emitted. Free-then-nil is the same two
          operations and is what the destructor already emits. }
        W('  F' + LPropName + '.Free;');
        W('  F' + LPropName + ' := nil;');
        W('end;');
        W;
        Continue;
      end;

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
  LClass := TypeNameIn(FFile, AMsg.QualifiedName);
  for I := 0 to AMsg.Fields.Count - 1 do
  begin
    LField := AMsg.Fields[I];
    if not LField.IsMap then Continue;
    LProp     := PascalFieldName(LField.Name, LRenamed);
    LName     := CapFirst(LProp);   // must match EmitMapAccessorDecls exactly
    LK        := MapKeyType(LField);
    LV        := MapValueType(LField);
    { Named from the entry message's own DECLARATION, not from the reference,
      so it agrees with how that class was emitted — FLATTEN-1 can rename it,
      and a reference computed independently would then name a class that does
      not exist. The lookup cannot fail: the parser synthesises the entry. }
    LEntryCls := TypeNameIn(FFile,
      FFile.FindMessage(LField.TypeName).QualifiedName);
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
  LClass := TypeNameIn(FFile, AMsg.QualifiedName);

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
  LClass, LProp, LRenamed, LType, LEnum, LTest: string;
  LCaseNames: TArray<string>;
  LMemberIdx: Integer;
  LFirst: Boolean;
begin
  LGroups := OneofGroups(AMsg);
  if Length(LGroups) = 0 then Exit;
  LClass := TypeNameIn(FFile, AMsg.QualifiedName);

  for G := 0 to High(LGroups) do
  begin
    LEnum := CaseEnumName(LClass, LGroups[G]);

    W('procedure ' + LClass + '.Clear' + CapFirst(LGroups[G]) + ';');
    W('begin');
    for I := 0 to AMsg.Fields.Count - 1 do
    begin
      if not SameText(AMsg.Fields[I].OneofName, LGroups[G]) then Continue;
      LProp := PascalFieldName(AMsg.Fields[I].Name, LRenamed);
      LType := FieldType(AMsg.Fields[I]);
      { ONEOF-2. A message member is FREED, not nilled - the class owns it, the
        same contract PROTOGEN-DTOR pinned for every other message field. }
      if IsOneofMessageMember(AMsg.Fields[I]) then
        begin
          W('  F' + LProp + '.Free;');
          W('  F' + LProp + ' := nil;');
        end
      else
      begin
        W('  F' + LProp + ' := Default(' + LType + ');');
        W('  F' + HasBitName(LProp) + ' := False;');
      end;
    end;
    W('end;');
    W;

    W('function ' + LClass + '.Get' + CapFirst(LGroups[G]) + 'Case: ' +
      LEnum + ';');
    W('begin');
    { ONEOFNAME-1. The SAME deduped list the enum declaration used - computing
      these names twice is how the two could disagree, and a case getter naming
      a value the enum does not declare is a compile error at best. }
    LCaseNames := OneofCaseNames(AMsg, LGroups[G]);
    LMemberIdx := 0;
    LFirst := True;
    for I := 0 to AMsg.Fields.Count - 1 do
    begin
      if not SameText(AMsg.Fields[I].OneofName, LGroups[G]) then Continue;
      Inc(LMemberIdx);
      LProp := PascalFieldName(AMsg.Fields[I].Name, LRenamed);
      { ONEOF-2. A message member has no has-bit - nil IS the answer. }
      if IsOneofMessageMember(AMsg.Fields[I]) then
        LTest := 'F' + LProp + ' <> nil'
      else
        LTest := 'F' + HasBitName(LProp);
      if LFirst then
        W('  if ' + LTest + ' then')
      else
        W('  else if ' + LTest + ' then');
      W('    Result := ' + LCaseNames[LMemberIdx]);
      LFirst := False;
    end;
    W('  else');
    W('    Result := ' + LCaseNames[0] + ';');
    W('end;');
    W;
  end;
end;

// ── TMessagesEmitter -- public ───────────────────────────────────────────────

constructor TMessagesEmitter.Create;
begin
  inherited Create;
  FExternUnits := TStringList.Create;
  FExternUnits.Duplicates := dupIgnore;
  FExternUnits.Sorted     := True;   // deterministic uses clause
end;

destructor TMessagesEmitter.Destroy;
begin
  FExternUnits.Free;
  inherited Destroy;
end;

procedure TMessagesEmitter.Emit(AFile: TProtoFileNode;
  const AUnitPrefix, AProtoFileName: string; ALines: TStrings;
  AFileSet: TProtoFileSet; AEntry: TProtoFileEntry);
begin
  FFile       := AFile;
  FUnitPrefix := AUnitPrefix;
  FProtoFile  := AProtoFileName;
  FOut        := ALines;
  FFileSet    := AFileSet;
  FEntry      := AEntry;
  FExternUnits.Clear;
  ALines.Clear;
  ScanForWKT;
  ScanForBytes;
  // Must precede EmitUsesClause: the clause names the units, so they have to
  // be known before it is written rather than discovered while emitting the
  // types below it.
  ScanForExternUnits;
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
  { Generic rename for a reserved word, or for `default`.

    FIELDWORD-1. A property is in scope inside its own class's method bodies,
    so a field named `default` leaves the generated Clear body unable to call
    Default():

        Fminimum := Default(Double);
        //          ^ binds to the property, not the intrinsic
        //   Incompatible types: got "TProtobufValue" expected "Double"
        //   Syntax error, ";" expected but "(" found

    google.api's OpenAPI Schema declares exactly that field.

    WHY ONLY `default`, and not the whole intrinsic list. Two wider rules were
    tried against the gates and reverted, in this order:

      - all intrinsics, routines AND type names: renamed ordinary fields
        called `single` and `double` that had always compiled. Enum values do
        need the type half — they are declared into a type section — but a
        property is not, so this bought nothing and broke every consumer
        spelling the old name.
      - all called routines: renamed `length` in echo.proto, whose class has no
        repeated or bytes field and so never calls Length() at all.

    Both failures are the same shape: whether a property shadows anything
    depends on what its OWN class's body calls, which this class function
    cannot see. `Default(` is the one call emitted for every has-bit field, so
    it is the one name worth renaming unconditionally.

    KNOWN GAP, unchanged by this fix: a message that has BOTH a repeated field
    and a field named `length`, `high` or `setlength` still collides. Not
    present in 305 googleapis schemas. Closing it properly means deciding the
    rename per message, from the routines that message's body will actually
    emit. }
  if IsDelphiReservedWord(AProtoName) or SameText(AProtoName, 'default') then
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
    { BLOCKED-BY: no-wire-form-selector }
    raise EEmitError.CreateFmt(
      'Cannot emit %s: no wire-form selector in TProtoMemberAttribute. ' +
      'Structural gap -- see plans/horse-grpc-codegen.md section 6.1.',
      [ScalarName(AScalar)]);
  end;
end;

class function TMessagesEmitter.TypeNameIn(AFile: TProtoFileNode;
  const AQualifiedName: string): string;
var
  LBase: string;
  I: Integer;
  LHash: Cardinal;
  K: Integer;

  // Does any OTHER declaration in this file flatten to ANAME?
  function TakenByAnother(const AName: string): Boolean;
  var
    J: Integer;
  begin
    Result := True;
    for J := 0 to AFile.Messages.Count - 1 do
      if not SameText(AFile.Messages[J].QualifiedName, AQualifiedName)
        and SameText(PascalTypeName(AFile.Messages[J].QualifiedName), AName) then
        Exit;
    for J := 0 to AFile.Enums.Count - 1 do
      if not SameText(AFile.Enums[J].QualifiedName, AQualifiedName)
        and SameText(PascalTypeName(AFile.Enums[J].QualifiedName), AName) then
        Exit;
    Result := False;
  end;

begin
  LBase := PascalTypeName(AQualifiedName);
  if AFile = nil then
    Exit(LBase);

  // A top-level name has nothing to restore, and is the one that keeps its
  // spelling when a nested sibling collides with it.
  if Pos('.', AQualifiedName) = 0 then
    Exit(LBase);

  if not TakenByAnother(LBase) then
    Exit(LBase);

  // Put the separators back: 'Control.Family' -> 'TControl_Family'.
  Result := 'T' + StringReplace(AQualifiedName, '.', '_', [rfReplaceAll]);

  { Last resort. A file could declare a type whose own name already contains
    the underscores this produces, in which case restoring them collides
    again. Hash the qualified name rather than loop. }
  if TakenByAnother(Result) then
  begin
    LHash := 2166136261;                                   // FNV-1a
    for K := 1 to Length(AQualifiedName) do
      LHash := (LHash xor Ord(AQualifiedName[K])) * 16777619;
    Result := Result + '_' + IntToHex(LHash, 8);
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

class function TMessagesEmitter.QualifiedTypeName(AFileSet: TProtoFileSet;
  AEntry: TProtoFileEntry; const ATypeName: string;
  out AExternUnit: string; const AScope: string): string;
var
  LRef: TProtoTypeRef;
  LWkt: string;
begin
  AExternUnit := '';

  // A bundled well-known type is satisfied by Nghttp2.Protobuf.WellKnown and
  // needs no generated unit — but it must NOT be mangled by PascalTypeName,
  // which is what the service emitters used to do to it.
  LWkt := WellKnownPascalClass(ATypeName);
  if LWkt <> '' then
    Exit(LWkt);

  // No file set: say so, and let the caller apply its own rule.
  Result := '';
  if (AFileSet = nil) or (AEntry = nil) then
    Exit;

  LRef := AFileSet.ResolveType(AEntry, ATypeName, AScope);
  if not LRef.Found then
    Exit;   // '' — the caller's same-file rule handles nested-type scoping

  { The declaring file's naming, not the referring file's: FLATTEN-1
    disambiguation depends on what the DECLARING file also declares. }
  if LRef.Entry <> nil then
  begin
    if LRef.Msg <> nil then
      Result := TypeNameIn(LRef.Entry.Node, LRef.Msg.QualifiedName)
    else if LRef.Enum <> nil then
      Result := TypeNameIn(LRef.Entry.Node, LRef.Enum.QualifiedName);
  end
  else if LRef.Msg <> nil then
    Result := PascalTypeName(LRef.Msg.QualifiedName)
  else if LRef.Enum <> nil then
    Result := PascalTypeName(LRef.Enum.QualifiedName);

  if (LRef.Entry = nil) or (LRef.Entry = AEntry) then
    Exit;   // same file — the short name is correct and unambiguous

  AExternUnit := LRef.Entry.UnitPrefix + '.Messages';
  Result := AExternUnit + '.' + Result;
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
        LBase := TypeNameIn(AFile, LMsg.QualifiedName)
      else
      begin
        LEnum := AFile.FindEnum(AField.TypeName);
        if LEnum <> nil then
          LBase := TypeNameIn(AFile, LEnum.QualifiedName)
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
