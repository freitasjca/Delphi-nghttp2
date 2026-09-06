program ProtoStructProbe;

// ============================================================================
//  ProtoStructProbe - can the RTTI layer carry google.protobuf.Struct?
//
//  WHY
//  ---
//  The C1c corpus tally (2026-09-06) put the whole remaining opportunity in one
//  place: 286 of 7301 googleapis files are refused for the Struct family alone,
//  and closing it would take acceptance 94% -> 98.7%. Nothing else on the list
//  is within an order of magnitude - `any` is 37 files, Group B is 6.
//
//  Struct, Value, ListValue and NullValue are WELL-KNOWN TYPES, and the parser
//  already bundles Timestamp / Duration / FieldMask / Empty / the wrappers by
//  mapping them to hand-written Pascal classes. So the cheap route is to bundle
//  four more rather than teach the GENERATOR to emit them - hand-written Pascal
//  can declare a destructor and use forward declarations freely, which is
//  exactly what emitting Struct would otherwise require.
//
//  That is the plan. This probe is what has to hold for it to be a plan at all,
//  asked BEFORE writing the four classes for real.
//
//  WHAT IS ACTUALLY IN DOUBT
//  -------------------------
//  Q1  A oneof that MIXES presence mechanisms.
//      AttachHasBits REFUSES [TProtoHas] on a submessage field, on the stated
//      grounds that "nil already means absent". Value's oneof needs four
//      scalar members (has-bit) and two message members (nil) in ONE class.
//      The refusal implies that shape is intended; nothing has ever built it.
//
//  Q2  MUTUAL RECURSION, and this is the bigger risk.
//      Struct -> entry -> Value -> Struct, and Value -> ListValue -> Value.
//      The field-info cache is built by walking a class's properties; a cycle
//      in that walk either terminates or hangs, and no existing message graph
//      has one. Q1 failing costs a redesign; Q2 failing costs the approach.
//
//  Q3  Does a value of this shape survive a round trip, nested.
//
//  Q4  Does the depth guard still bound a decode? A recursive TYPE makes a
//      hostile peer's nesting unbounded in a way no current message allows,
//      so FIX-PROTO-DEPTH-1 has to be the thing that stops it.
//
//      Noted while writing this and NOT probed, because probing it means
//      crashing: PROTO_MAX_DEPTH guards DESERIALIZE only - there is no
//      corresponding counter on the serialize side. That costs nothing today
//      because no message type can nest into itself, so a value's depth is
//      bounded by its schema. A recursive type removes that bound, and a
//      value that contains ITSELF - Value.struct_value holding a Struct whose
//      entry points back at that same Value - would recurse until the stack
//      ends. It is a caller error rather than a wire input, and the
//      destructor would double-free such a graph anyway, but it is a hazard
//      the Struct bundle introduces and nothing else in the codec has.
//
//  Q5  Boolean VALUE beside Boolean has-bit, again - tkEnumeration on Delphi
//      and tkBool on FPC. Value has bool_value + has_bool_value, so the one
//      shape whose RTTI differs by compiler is present here too.
//
//  This is a PROBE, not a feature: the classes below are the minimum that asks
//  the question. They are deliberately NOT the shipping bundle - naming,
//  accessors and the JSON mapping Struct exists for are all out of scope until
//  the questions above are answered.
//
//  Build (FPC trunk):
//    fpc -MDelphi -O1 -FU<out> -FE<out> -Fu../src <unit paths> ProtoStructProbe.dpr
//  Build (Windows):
//    dcc64 -CC -B -U"..\src" ProtoStructProbe.dpr
//
//  ExitCode is the number of questions that came back NO.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}
// The M+ directive below, and the RTTI EXPLICIT one after `uses`, are
// LOAD-BEARING rather than boilerplate. Without them these classes carry no
// published RTTI at all: the codec discovers ZERO fields and every Serialize
// returns an empty TBytes - which does not raise. So a probe that asks only
// "did it raise" reports a confident YES about a class it never looked at.
// The first run of this file did exactly that, answering Q1 and Q2 YES
// against nothing, which is why Q0 now exists.
//
// Sample.Echo.Messages.pas carries the same pair for the same reason, and
// notes that FPC needs the RTTI directive after `uses`, not at unit scope.
// (Written with // and not a brace comment on purpose - a directive inside a
// brace comment closes it at its own closing brace. brace-scan.py caught
// exactly that here, in this comment, on its first outing.)
{$M+}

uses
{$IF DEFINED(FPC)}
  SysUtils, TypInfo, Rtti,
{$ELSE}
  System.SysUtils, System.TypInfo, System.Rtti,
{$IFEND}
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti;

{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

type
  // google.protobuf.NullValue - a single-member enum whose only value is 0.
  TProbeNullValue = (NULL_VALUE);

  // Forward declarations. This is the half a GENERATED unit cannot currently
  // produce: the emitter writes classes in declaration order with no forwards,
  // which is the second of the two blockers a hand-written bundle sidesteps.
  TProbeStruct    = class;
  TProbeValue     = class;
  TProbeListValue = class;

  { Struct.fields is map<string, Value>, which on the wire is a repeated
    synthesised entry - the shape MAP-1 just made real. Hand-written here for
    the same reason the rest is: to ask whether the RUNTIME carries it. }
  [TGrpcMessage]
  TProbeStructEntry = class
  private
    Fkey:   string;
    Fvalue: TProbeValue;
  public
    destructor Destroy; override;
  published
    [TProtoMember(1)] property key:   string      read Fkey   write Fkey;
    [TProtoMember(2)] property value: TProbeValue read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProbeStruct = class
  private
    Ffields: TArray<TProbeStructEntry>;
  public
    destructor Destroy; override;
  published
    [TProtoMember(1)] property fields: TArray<TProbeStructEntry>
      read Ffields write Ffields;
  end;

  { THE class under test. Six oneof members, two presence mechanisms:

      null_value / number_value / string_value / bool_value   has-bit
      struct_value / list_value                               nil

    Setting any member clears all five siblings, which for a message member
    means FREEING it. }
  [TGrpcMessage]
  TProbeValue = class
  private
    Fnull_value:       TProbeNullValue;
    Fhas_null_value:   Boolean;
    Fnumber_value:     Double;
    Fhas_number_value: Boolean;
    Fstring_value:     string;
    Fhas_string_value: Boolean;
    Fbool_value:       Boolean;
    Fhas_bool_value:   Boolean;
    Fstruct_value:     TProbeStruct;
    Flist_value:       TProbeListValue;
    procedure ClearKind;
    procedure Setnull_value  (const AValue: TProbeNullValue);
    procedure Setnumber_value(const AValue: Double);
    procedure Setstring_value(const AValue: string);
    procedure Setbool_value  (const AValue: Boolean);
    procedure Setstruct_value(const AValue: TProbeStruct);
    procedure Setlist_value  (const AValue: TProbeListValue);
  public
    destructor Destroy; override;
  published
    [TProtoMember(1)] property null_value: TProbeNullValue
      read Fnull_value write Setnull_value;
    [TProtoHas(1)]    property has_null_value: Boolean read Fhas_null_value;

    [TProtoMember(2)] property number_value: Double
      read Fnumber_value write Setnumber_value;
    [TProtoHas(2)]    property has_number_value: Boolean read Fhas_number_value;

    [TProtoMember(3)] property string_value: string
      read Fstring_value write Setstring_value;
    [TProtoHas(3)]    property has_string_value: Boolean read Fhas_string_value;

    { Q5. A Boolean VALUE next to a Boolean HAS-BIT: same Pascal type, two
      different jobs, and the kind differs by compiler. }
    [TProtoMember(4)] property bool_value: Boolean
      read Fbool_value write Setbool_value;
    [TProtoHas(4)]    property has_bool_value: Boolean read Fhas_bool_value;

    { Q1. No [TProtoHas] on these two, deliberately - AttachHasBits refuses one
      on a submessage because nil already carries the answer. }
    [TProtoMember(5)] property struct_value: TProbeStruct
      read Fstruct_value write Setstruct_value;
    [TProtoMember(6)] property list_value: TProbeListValue
      read Flist_value write Setlist_value;
  end;

  [TGrpcMessage]
  TProbeListValue = class
  private
    Fvalues: TArray<TProbeValue>;
  public
    destructor Destroy; override;
  published
    [TProtoMember(1)] property values: TArray<TProbeValue>
      read Fvalues write Fvalues;
  end;

{ ── implementations ─────────────────────────────────────────────────────── }

destructor TProbeStructEntry.Destroy;
begin
  Fvalue.Free;
  inherited;
end;

destructor TProbeStruct.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Ffields) do
    Ffields[I].Free;
  inherited;
end;

destructor TProbeListValue.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Fvalues) do
    Fvalues[I].Free;
  inherited;
end;

destructor TProbeValue.Destroy;
begin
  Fstruct_value.Free;
  Flist_value.Free;
  inherited;
end;

{ Clearing the group. The two message members are FREED, not merely nilled -
  the containing class owns them, the same contract PROTOGEN-DTOR pinned. }
procedure TProbeValue.ClearKind;
begin
  Fhas_null_value   := False;
  Fhas_number_value := False;
  Fhas_string_value := False;
  Fhas_bool_value   := False;
  FreeAndNil(Fstruct_value);
  FreeAndNil(Flist_value);
end;

procedure TProbeValue.Setnull_value(const AValue: TProbeNullValue);
begin
  ClearKind;
  Fnull_value := AValue;
  Fhas_null_value := True;
end;

procedure TProbeValue.Setnumber_value(const AValue: Double);
begin
  ClearKind;
  Fnumber_value := AValue;
  Fhas_number_value := True;
end;

procedure TProbeValue.Setstring_value(const AValue: string);
begin
  ClearKind;
  Fstring_value := AValue;
  Fhas_string_value := True;
end;

procedure TProbeValue.Setbool_value(const AValue: Boolean);
begin
  ClearKind;
  Fbool_value := AValue;
  Fhas_bool_value := True;
end;

{ Self-assignment guard, same reason MAP-1's Set needed one: ClearKind would
  free the instance and the assignment would then store a dangling pointer. }
procedure TProbeValue.Setstruct_value(const AValue: TProbeStruct);
begin
  if Fstruct_value = AValue then Exit;
  ClearKind;
  Fstruct_value := AValue;
end;

procedure TProbeValue.Setlist_value(const AValue: TProbeListValue);
begin
  if Flist_value = AValue then Exit;
  ClearKind;
  Flist_value := AValue;
end;

{ ── harness ─────────────────────────────────────────────────────────────── }

var
  GNo: Integer = 0;

procedure Answer(const AQuestion: string; AYes: Boolean;
  const ADetail: string = '');
begin
  if AYes then
    WriteLn('  YES  ', AQuestion)
  else
  begin
    Inc(GNo);
    if ADetail <> '' then
      WriteLn('  NO   ', AQuestion, '  <- ', ADetail)
    else
      WriteLn('  NO   ', AQuestion);
  end;
end;

{ Is tag ATag present in AObj's encoding? Decoded with the real reader rather
  than scanned for a byte, which would false-positive on a payload byte that
  happens to equal the tag. }
function EmitsTag(AObj: TObject; ATag: Integer): Boolean;
var
  LReader: TProtoReader;
  LTag: Integer;
  LWire: TProtoWireType;
begin
  Result := False;
  LReader := TProtoReader.Create(TProtoSerializer.Serialize(AObj));
  try
    while LReader.ReadTag(LTag, LWire) do
    begin
      if LTag = ATag then Exit(True);
      LReader.SkipField(LWire);
    end;
  finally
    LReader.Free;
  end;
end;

var
  GVal, GDst: TProbeValue;
  GStruct:    TProbeStruct;
  GEntry:     TProbeStructEntry;
  GList:      TProbeListValue;
  GInner:     TProbeValue;
  GBytes:     TBytes;
  GOk:        Boolean;
  GErr:       string;
  GDepth:     Integer;
  GCur:       TProbeValue;

// Q0. Are the properties DISCOVERABLE at all?
//
// This exists because its absence produced a confidently wrong answer. With no
// published RTTI the classes expose nothing, every Serialize returns empty, and
// "Serialize did not raise" - which was Q1's entire test - is satisfied by a
// class the codec never looked at. Q1 and Q2 both reported YES against nothing.
//
// So the field count is asserted FIRST, against a number written down here, and
// every question below is unreachable until it holds. The same instrument the
// framing suite needed: prove the measurement happened before reading it.
function PropertiesVisible(out ADetail: string): Boolean;
var
  LCtx:   TRttiContext;
  LType:  TRttiType;
  LProp:  TRttiProperty;
  LAttr:  TCustomAttribute;
  LMem, LHas: Integer;
begin
  LMem := 0; LHas := 0;
  LCtx := TRttiContext.Create;
  try
    LType := LCtx.GetType(TProbeValue);
    if LType = nil then
    begin
      ADetail := 'no RTTI for TProbeValue at all';
      Exit(False);
    end;
    for LProp in LType.GetProperties do
    begin
      if LProp.Visibility <> mvPublished then Continue;
      for LAttr in LProp.GetAttributes do
      begin
        if LAttr is TProtoMemberAttribute then Inc(LMem);
        if LAttr is TProtoHasAttribute    then Inc(LHas);
      end;
    end;
  finally
    LCtx.Free;
  end;
  ADetail := Format('%d [TProtoMember] + %d [TProtoHas] found, expected 6 + 4',
                    [LMem, LHas]);
  Result := (LMem = 6) and (LHas = 4);
end;

var
  GDetail: string;

begin
  WriteLn('ProtoStructProbe - can the runtime carry google.protobuf.Struct?');
  WriteLn('Asked BEFORE writing the bundle, not after.');
  WriteLn;

  // ── Q0 · the instrument ─────────────────────────────────────────────────
  WriteLn('-- Q0  are TProbeValue''s properties discoverable at all?');
  GOk := PropertiesVisible(GDetail);
  Answer('published RTTI carries all ten attributed properties', GOk, GDetail);
  if not GOk then
  begin
    WriteLn;
    WriteLn('  STOP. Nothing below would mean anything: with no discoverable');
    WriteLn('  fields every Serialize returns empty and every question would');
    WriteLn('  answer YES about a class the codec never read. Fix the probe');
    WriteLn('  ({$M+} / {$RTTI EXPLICIT}) before reading any result here.');
    ExitCode := GNo;
    Exit;
  end;
  WriteLn('     (' + GDetail + ')');

  // ── Q1 · a oneof mixing has-bits and nil-signalled messages ─────────────
  WriteLn;
  WriteLn('-- Q1  oneof mixing has-bit scalars and nil-signalled messages');
  GOk  := False;
  GErr := '';
  GVal := TProbeValue.Create;
  try
    try
      TProtoSerializer.Serialize(GVal);
      GOk := True;
    except
      on E: Exception do GErr := E.ClassName + ': ' + E.Message;
    end;
  finally
    GVal.Free;
  end;
  Answer('AttachHasBits accepts four has-bits beside two bare submessages',
         GOk, GErr);

  { Instrument. "Serialize did not raise" is also true of a class whose
    has-bits were never ATTACHED - the serializer just falls through to
    IsDefaultValue and skips everything. So prove a has-bit is consulted:
    set a field to a NON-default value and require it on the wire, then set
    one to its DEFAULT and require it there too. Only an attached has-bit
    produces the second. }
  if GOk then
  begin
    GVal := TProbeValue.Create;
    try
      GVal.string_value := 'x';
      Answer('  instrument: a non-default scalar member reaches the wire',
             EmitsTag(GVal, 3));
    finally
      GVal.Free;
    end;
    GVal := TProbeValue.Create;
    try
      GVal.string_value := '';
      Answer('  instrument: a DEFAULT-valued member reaches it too, so the '
             + 'has-bit is genuinely attached', EmitsTag(GVal, 3));
    finally
      GVal.Free;
    end;
  end;

  if not GOk then
  begin
    WriteLn;
    WriteLn('  Q1 failed, so Q2-Q5 cannot be asked - every one of them needs');
    WriteLn('  this class to register. Bundling Struct would need the mixed');
    WriteLn('  oneof to be expressible some other way first.');
    ExitCode := GNo;
    Exit;
  end;

  // ── Q2 · mutual recursion ───────────────────────────────────────────────
  //  Struct -> entry -> Value -> Struct is a CYCLE in the class graph. If the
  //  field-info walk does not terminate, this hangs rather than failing, so it
  //  is deliberately the first thing done after Q1 and before anything larger.
  WriteLn;
  WriteLn('-- Q2  mutual recursion in the class graph (Struct <-> Value)');
  GOk  := False;
  GErr := '';
  try
    GStruct := TProbeStruct.Create;
    try
      TProtoSerializer.Serialize(GStruct);
    finally
      GStruct.Free;
    end;
    GList := TProbeListValue.Create;
    try
      TProtoSerializer.Serialize(GList);
    finally
      GList.Free;
    end;
    GOk := True;
  except
    on E: Exception do GErr := E.ClassName + ': ' + E.Message;
  end;
  Answer('registering a cyclic class graph TERMINATES', GOk, GErr);

  // ── Q3 · round trip, nested ─────────────────────────────────────────────
  WriteLn;
  WriteLn('-- Q3  a nested value survives a round trip');
  GOk  := False;
  GErr := '';
  try
    // { "k": "hello" } as a Struct held inside a Value
    GVal := TProbeValue.Create;
    try
      GStruct := TProbeStruct.Create;
      GEntry  := TProbeStructEntry.Create;
      GEntry.key   := 'k';
      GInner       := TProbeValue.Create;
      GInner.string_value := 'hello';
      GEntry.value := GInner;
      GStruct.fields := [GEntry];
      GVal.struct_value := GStruct;     // Value now owns the whole tree

      Answer('setting a message member left the scalar bits down',
             not (GVal.has_string_value or GVal.has_number_value));
      Answer('only the message member goes on the wire',
             EmitsTag(GVal, 5) and (not EmitsTag(GVal, 3)));

      GBytes := TProtoSerializer.Serialize(GVal);
    finally
      GVal.Free;
    end;

    GDst := TProbeValue.Create;
    try
      TProtoSerializer.Deserialize(GBytes, GDst);
      GOk := (GDst.struct_value <> nil)
             and (Length(GDst.struct_value.fields) = 1)
             and (GDst.struct_value.fields[0].key = 'k')
             and (GDst.struct_value.fields[0].value <> nil)
             and (GDst.struct_value.fields[0].value.string_value = 'hello');
      if GOk then
        Answer('the inner scalar arrives PRESENT, not merely equal',
               GDst.struct_value.fields[0].value.has_string_value);
    finally
      GDst.Free;      // must free the whole tree without double-freeing
    end;
  except
    on E: Exception do GErr := E.ClassName + ': ' + E.Message;
  end;
  Answer('Struct{k: "hello"} round-trips three levels deep', GOk, GErr);

  // ── Q4 · the depth guard still bounds a recursive TYPE ───────────────────
  //  A recursive type lets a peer nest without limit, which no existing
  //  message shape allows. FIX-PROTO-DEPTH-1 has to be what stops it - so
  //  build a legitimately deep value and confirm the guard, not the stack,
  //  is what refuses it.
  WriteLn;
  WriteLn('-- Q4  depth guard bounds unbounded nesting of a recursive type');
  //  60 iterations, not 200: each one adds Value -> Struct -> entry -> Value,
  //  so this is ~180 wire levels against PROTO_MAX_DEPTH = 100. Comfortably
  //  over without building something absurd.
  GOk  := False;
  GErr := '';
  GBytes := nil;
  try
    GVal := TProbeValue.Create;
    GCur := GVal;
    for GDepth := 1 to 60 do
    begin
      GStruct := TProbeStruct.Create;
      GEntry  := TProbeStructEntry.Create;
      GEntry.key   := 'n';
      GInner       := TProbeValue.Create;
      GEntry.value := GInner;
      GStruct.fields := [GEntry];
      GCur.struct_value := GStruct;
      GCur := GInner;
    end;
    try
      GBytes := TProtoSerializer.Serialize(GVal);
    finally
      GVal.Free;
    end;
  except
    on E: Exception do
      GErr := 'building or encoding the deep value raised ' + E.ClassName
              + ': ' + E.Message;
  end;

  if GErr <> '' then
    Answer('a deep value can be built and encoded at all', False, GErr)
  else
  begin
    GDst := TProbeValue.Create;
    try
      try
        TProtoSerializer.Deserialize(GBytes, GDst);
        GErr := 'decoded ~180 levels without a refusal';
      except
        on E: EProtoDecodeError do
        begin
          GOk  := True;
          GErr := E.Message;
        end;
        on E: Exception do
          GErr := 'refused, but with ' + E.ClassName + ' - not the depth guard';
      end;
    finally
      GDst.Free;
    end;
    Answer('~180 levels are refused BY THE DEPTH GUARD, not by the stack',
           GOk, GErr);
  end;
  if GOk then
    Answer('and the refusal names nesting as the cause',
           Pos('nest', LowerCase(GErr)) > 0, GErr);

  // ── Q5 · Boolean value beside Boolean has-bit ───────────────────────────
  WriteLn;
  WriteLn('-- Q5  Boolean VALUE beside a Boolean has-bit');
  GOk  := False;
  GErr := '';
  try
    GVal := TProbeValue.Create;
    GDst := TProbeValue.Create;
    try
      { False is the interesting one: without a has-bit it is indistinguishable
        from never set, so this is the case the whole mechanism exists for. }
      GVal.bool_value := False;
      Answer('setting bool_value := False raised its bit', GVal.has_bool_value);
      Answer('bool_value = False IS emitted', EmitsTag(GVal, 4));
      GBytes := TProtoSerializer.Serialize(GVal);
      TProtoSerializer.Deserialize(GBytes, GDst);
      GOk := GDst.has_bool_value and (GDst.bool_value = False);
    finally
      GVal.Free;
      GDst.Free;
    end;
  except
    on E: Exception do GErr := E.ClassName + ': ' + E.Message;
  end;
  Answer('bool_value = False round-trips as PRESENT-and-False', GOk, GErr);

  WriteLn;
  if GNo = 0 then
  begin
    WriteLn('[ProtoStructProbe] every question came back YES.');
    WriteLn('  The runtime carries the Struct shape as-is. Bundling');
    WriteLn('  Struct/Value/ListValue/NullValue needs no codec change -');
    WriteLn('  it is four hand-written classes and a parser table entry.');
  end
  else
  begin
    WriteLn(Format('[ProtoStructProbe] %d question(s) came back NO.', [GNo]));
    WriteLn('  Read them before planning the bundle: each one is a thing');
    WriteLn('  the approach assumed and does not get.');
  end;
  ExitCode := GNo;
end.
