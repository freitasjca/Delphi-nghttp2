program ProtogenOptionalCompileCheck;

// ============================================================================
//  C6b — make a COMPILER, and then the RTTI layer, read protogen's `optional`
//  output.
//
//  C6a did this for the greeter path. It generates from greeter.proto, which
//  has no optional fields, so PRESENCE-1 shipped with all 14 of its emitter
//  checks comparing TEXT TO TEXT — the exact hole C6a exists to close.
//
//  Two distinct things are under test here, and the second is the interesting
//  one:
//
//   1. The generated unit COMPILES. A setter declaration that does not match
//      its body, a Default(TEnum) the compiler rejects, a [TProtoHas] that
//      does not resolve — none of that is visible to a text comparison.
//
//   2. The generated class is ACCEPTED BY AttachHasBits at run time, and then
//      behaves. The emitter and the RTTI validator were written to the same
//      contract, by the same author, in the same session; they agree with each
//      other by construction. Nothing had put that agreement in front of a
//      compiler and a live TProtobufRtti. If the emitter ever produced a
//      writable has-bit, or named it something AttachHasBits does not pair to
//      the field, the first Serialize would raise — and every text gate would
//      still be green.
//
//  Usage — generate first, then compile against the output directory:
//
//    Protogen.exe -i optional.proto -o <out> --unit-prefix Sample.Opt
//    dcc64 -B -U"<out>;..\..\src" ProtogenOptionalCompileCheck.dpr
//
//  A successful COMPILE is half the result; the run is the other half.
//  ExitCode is the failure count.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti,
  Nghttp2.Protobuf.WellKnown,   // STRUCT-1 - the bundled Struct family
  Nghttp2.Protobuf.Any,         // ANY-1 - the registry + Pack/Unpack
  Sample.Opt.Messages;      // <- generated. The point of the exercise.

var
  GPass: Integer = 0;
  GFail: Integer = 0;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    Inc(GPass);
    WriteLn('  PASS  ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('  FAIL  ', AName, '  <- ', ADetail)
    else
      WriteLn('  FAIL  ', AName);
  end;
end;

{ Does tag ATag appear as a field in AObj's encoding? Decoded with the real
  reader rather than scanned for a tag byte - a byte scan reports a false
  positive whenever a preceding field's VALUE happens to equal the tag byte. }
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
  GMsg, GDst: TOptMsg;
  GOne, GOneDst: TOneofMsg;      // ONEOF-1
  GOwn, GOwnDst: TOwnerMsg;      // PROTOGEN-DTOR
  GMap, GMapDst: TMapMsg;        // MAP-1
  GWkt, GWktDst: TWktMsg;        // STRUCT-1
  GAnyOk: Boolean;               // ANY-1
  GAnyErr: string;
  GPay: TPayload;
  GPayloads: TArray<TPayload>;
  GBytes: TBytes;
  GOk: Boolean;
  GErr: string;

begin
  WriteLn('ProtogenOptionalCompileCheck - C6b');
  WriteLn('The generated unit compiled. Now: does the RTTI layer accept it?');
  WriteLn;

  { THE assertion. If AttachHasBits rejects anything the emitter produced -
    a writable bit, a non-Boolean bit, a bit whose tag pairs to nothing - this
    raises, and it raises on the very first Serialize. Everything below is
    only reachable once the two layers have been shown to agree. }
  GOk  := False;
  GErr := '';
  GMsg := TOptMsg.Create;
  try
    try
      TProtoSerializer.Serialize(GMsg);
      GOk := True;
    except
      on E: Exception do
        GErr := E.ClassName + ': ' + E.Message;
    end;
  finally
    GMsg.Free;
  end;
  Check('generated class is ACCEPTED by AttachHasBits', GOk, GErr);
  if not GOk then
  begin
    WriteLn;
    WriteLn('Nothing further can be checked - the RTTI layer rejected the');
    WriteLn('emitter''s own output. That is a contract mismatch between');
    WriteLn('Protogen.Emitter and Nghttp2.Protobuf.Rtti.');
    ExitCode := GFail;
    Exit;
  end;

  // ── presence behaviour, on GENERATED code rather than a hand-written class
  GMsg := TOptMsg.Create;
  try
    Check('unset optional int32 is not emitted',    not EmitsTag(GMsg, 2));
    Check('unset optional string is not emitted',   not EmitsTag(GMsg, 3));
    Check('unset optional bool is not emitted',     not EmitsTag(GMsg, 4));
    Check('unset optional enum is not emitted',     not EmitsTag(GMsg, 5));
    Check('empty repeated field is not emitted',    not EmitsTag(GMsg, 6));

    { CANONICAL-1: an implicit-presence field at its DEFAULT is now omitted
      too. This check asserted the opposite until CANONICAL-1, because it
      left `plain` at 0 - the pre-canonical behaviour. }
    Check('implicit-presence field at its DEFAULT is omitted',
      not EmitsTag(GMsg, 1));

    GMsg.plain := 5;
    Check('implicit-presence field with a VALUE is emitted',
      EmitsTag(GMsg, 1));
  finally
    GMsg.Free;
  end;

  { Set-to-default is the whole feature: each of these assigns the type's ZERO
    value, which without a has-bit is indistinguishable from never having been
    set. }
  GMsg := TOptMsg.Create;
  try
    GMsg.i32 := 0;
    GMsg.s   := '';
    GMsg.b   := False;
    GMsg.col := OPT_COLOUR_UNSET;
    Check('optional int32 set to 0 IS emitted',       EmitsTag(GMsg, 2));
    Check('optional string set to "" IS emitted',     EmitsTag(GMsg, 3));
    Check('optional bool set to False IS emitted',    EmitsTag(GMsg, 4));
    Check('optional enum set to 0 IS emitted',        EmitsTag(GMsg, 5));

    { The generated setter must have raised each bit. A generated property that
      wrote straight to its backing field would leave these False, and the
      emissions above would not have happened either. }
    Check('generated setter raised HasI32', GMsg.HasI32);
    Check('generated setter raised HasS',   GMsg.HasS);
    Check('generated setter raised HasB',   GMsg.HasB);
    Check('generated setter raised HasCol', GMsg.HasCol);
  finally
    GMsg.Free;
  end;

  // ── the generated Clear methods ──────────────────────────────────────────
  GMsg := TOptMsg.Create;
  try
    GMsg.i32 := 7;
    GMsg.col := OPT_COLOUR_BLUE;
    GMsg.ClearI32;
    GMsg.ClearCol;      // Default(TOptColour) — the enum path
    Check('generated ClearI32 lowered the bit',  not GMsg.HasI32);
    Check('generated ClearCol lowered the bit',  not GMsg.HasCol);
    Check('cleared int32 is not emitted',        not EmitsTag(GMsg, 2));
    Check('cleared enum is not emitted',         not EmitsTag(GMsg, 5));
  finally
    GMsg.Free;
  end;

  { Round trip through generated code. The bit must be raised by the SETTER
    that deserialisation reaches - nothing on the decode side knows about
    presence, so if the generated property wrote to its field directly this
    comes back absent. }
  GMsg := TOptMsg.Create;
  GDst := TOptMsg.Create;
  try
    GMsg.i32 := 0;
    GMsg.s   := '';
    GBytes := TProtoSerializer.Serialize(GMsg);
    TProtoSerializer.Deserialize(GBytes, GDst);
    Check('round-trip: set-to-zero int32 arrives PRESENT', GDst.HasI32);
    Check('round-trip: set-to-zero int32 value is 0',      GDst.i32 = 0);
    Check('round-trip: set-to-empty string arrives PRESENT', GDst.HasS);
    Check('round-trip: untouched bool arrives ABSENT',     not GDst.HasB);
  finally
    GMsg.Free;
    GDst.Free;
  end;

  // ── ONEOF-1 · generated oneof code ───────────────────────────────────────
  //  Same two questions as above, one layer along: does it compile, and does
  //  the RTTI layer accept it? A oneof member is an ordinary has-bit field, so
  //  AttachHasBits must take it exactly as it takes an `optional` one.
  WriteLn;
  WriteLn('-- ONEOF-1: generated oneof code');

  GOk  := False;
  GErr := '';
  GOne := TOneofMsg.Create;
  try
    try
      TProtoSerializer.Serialize(GOne);
      GOk := True;
    except
      on E: Exception do GErr := E.ClassName + ': ' + E.Message;
    end;
  finally
    GOne.Free;
  end;
  Check('generated oneof class is ACCEPTED by AttachHasBits', GOk, GErr);

  if GOk then
  begin
    GOne := TOneofMsg.Create;
    try
      Check('fresh message reports no member set',
        GOne.PickCase = OneofMsgPickCaseNone);
      Check('unset members emit nothing',
        (not EmitsTag(GOne, 2)) and (not EmitsTag(GOne, 3))
        and (not EmitsTag(GOne, 4)));

      { Non-default on purpose - since CANONICAL-1 a plain field at its
        default is omitted like anything else, so leaving `before` at 0 would
        assert pre-canonical behaviour. The point being made is that a oneof
        group does not disturb the ordinary fields around it. }
      GOne.before := 5;
      Check('a plain field beside the group still emits', EmitsTag(GOne, 1));
    finally
      GOne.Free;
    end;

    // setting one member
    GOne := TOneofMsg.Create;
    try
      GOne.pick_i := 7;
      Check('setting a member raises its bit',      GOne.HasPick_i);
      Check('case reports THAT member',
        GOne.PickCase = OneofMsgPickCasePick_i);
      Check('only that member is emitted',
        EmitsTag(GOne, 2) and (not EmitsTag(GOne, 3))
        and (not EmitsTag(GOne, 4)));
    finally
      GOne.Free;
    end;

    { The rule that makes a oneof a oneof, and across two wire families:
      pick_i is a varint, pick_s is length-delimited. A clear that handled
      only one kind would pass a single-member test. }
    GOne := TOneofMsg.Create;
    try
      GOne.pick_i := 7;
      GOne.pick_s := 'now this one';
      Check('setting a second member CLEARED the first', not GOne.HasPick_i);
      Check('the second member is set',                  GOne.HasPick_s);
      Check('case follows the last one set',
        GOne.PickCase = OneofMsgPickCasePick_s);
      Check('only the last member goes on the wire',
        EmitsTag(GOne, 3) and (not EmitsTag(GOne, 2)));
    finally
      GOne.Free;
    end;

    { Group isolation. The easiest way to get clearing wrong is to clear every
      has-bit in the class rather than only the group's - which would silently
      wipe an unrelated `optional` field and the other group. }
    GOne := TOneofMsg.Create;
    try
      GOne.lone    := 99;
      GOne.other_a := 5;
      GOne.pick_i  := 1;
      Check('setting a member left the OTHER group alone', GOne.HasOther_a);
      Check('setting a member left a plain optional alone', GOne.HasLone);
      Check('the two groups report independently',
        (GOne.PickCase = OneofMsgPickCasePick_i)
        and (GOne.OtherCase = OneofMsgOtherCaseOther_a));
    finally
      GOne.Free;
    end;

    // the generated group Clear, including the enum member's Default(TEnum)
    GOne := TOneofMsg.Create;
    try
      GOne.pick_c := OPT_COLOUR_BLUE;
      Check('enum member sets its case',
        GOne.PickCase = OneofMsgPickCasePick_c);
      GOne.ClearPick;
      Check('ClearPick returns the group to None',
        GOne.PickCase = OneofMsgPickCaseNone);
      Check('ClearPick lowered the member bit', not GOne.HasPick_c);
      Check('cleared group emits nothing', not EmitsTag(GOne, 4));
    finally
      GOne.Free;
    end;

    { Round trip. Two members on the wire must leave only the last one set -
      proto3's rule - and it falls out of deserialisation reaching the setter,
      with no decoder-side knowledge of oneofs. }
    GOne := TOneofMsg.Create;
    GOneDst := TOneofMsg.Create;
    try
      GOne.pick_s := 'over the wire';
      GBytes := TProtoSerializer.Serialize(GOne);
      TProtoSerializer.Deserialize(GBytes, GOneDst);
      Check('round-trip: member value survives',
        GOneDst.pick_s = 'over the wire');
      Check('round-trip: member arrives PRESENT', GOneDst.HasPick_s);
      Check('round-trip: case survives the wire',
        GOneDst.PickCase = OneofMsgPickCasePick_s);
      Check('round-trip: the other members stay unset',
        (not GOneDst.HasPick_i) and (not GOneDst.HasPick_c));
    finally
      GOne.Free;
      GOneDst.Free;
    end;
  end;

  // ── PROTOGEN-DTOR · the generated destructor ─────────────────────────────
  //  What this CAN prove: the destructor compiles, and freeing a decoded
  //  message does not double-free (which would AV here, loudly).
  //
  //  What it CANNOT prove: that the leak is gone. Absence of a leak needs
  //  heap accounting - build this with -gh and read heaptrc's summary. Said
  //  plainly because "destructor emitted, tests green" is exactly the kind of
  //  claim that gets mistaken for "leak fixed".
  WriteLn;
  WriteLn('-- PROTOGEN-DTOR: generated destructor');

  GOk  := False;
  GErr := '';
  try
    GOwn := TOwnerMsg.Create;
    try
      GOwn.tag := 1;
    finally
      GOwn.Free;          // nothing allocated yet - both fields still empty
    end;
    GOk := True;
  except
    on E: Exception do GErr := E.ClassName + ': ' + E.Message;
  end;
  Check('destructor is safe when nothing was ever allocated', GOk, GErr);

  { Now the real case: let the CODEC allocate, then free. A destructor that
    freed something it did not own, or freed twice, dies here. }
  GOk  := False;
  GErr := '';
  try
    GOwn := TOwnerMsg.Create;
    try
      GOwn.tag := 7;
      GOwn.single := TPayload.Create;
      GOwn.single.id := 42;
      GBytes := TProtoSerializer.Serialize(GOwn);
    finally
      GOwn.Free;
    end;

    GOwnDst := TOwnerMsg.Create;
    try
      { Deserialize ALLOCATES TPayload for the singular field and one per
        repeated element - this is the ownership the destructor answers. }
      TProtoSerializer.Deserialize(GBytes, GOwnDst);
      GOk := (GOwnDst.single <> nil) and (GOwnDst.single.id = 42);
    finally
      GOwnDst.Free;       // frees the codec-allocated TPayload
    end;
  except
    on E: Exception do GErr := E.ClassName + ': ' + E.Message;
  end;
  Check('decode allocates a submessage, and Free does not double-free',
        GOk, GErr);

  { Repeated: one instance per element, so the destructor must loop. }
  GOk  := False;
  GErr := '';
  try
    GOwn := TOwnerMsg.Create;
    try
      SetLength(GPayloads, 2);
      GPayloads[0] := TPayload.Create; GPayloads[0].id := 1;
      GPayloads[1] := TPayload.Create; GPayloads[1].id := 2;
      GOwn.many := GPayloads;
      GBytes := TProtoSerializer.Serialize(GOwn);
    finally
      GOwn.Free;
    end;

    GOwnDst := TOwnerMsg.Create;
    try
      TProtoSerializer.Deserialize(GBytes, GOwnDst);
      GOk := (Length(GOwnDst.many) = 2) and (GOwnDst.many[1].id = 2);
    finally
      GOwnDst.Free;       // must free EACH element
    end;
  except
    on E: Exception do GErr := E.ClassName + ': ' + E.Message;
  end;
  Check('repeated submessage: every element freed, no double-free',
        GOk, GErr);

  // ── MAP-1 · the generated dictionary accessors ───────────────────────────
  //  A map is a repeated synthesised-entry message on the wire, so the codec
  //  needed no change at all. What is new is the five generated methods per
  //  map field, and they are only ever exercised here - the emitter tests
  //  compare their TEXT, which cannot tell a linear scan that returns the
  //  wrong element from one that does not.
  WriteLn;
  WriteLn('-- MAP-1: generated map accessors');

  GOk  := False;
  GErr := '';
  GMap := TMapMsg.Create;
  try
    try
      TProtoSerializer.Serialize(GMap);
      GOk := True;
    except
      on E: Exception do GErr := E.ClassName + ': ' + E.Message;
    end;
  finally
    GMap.Free;
  end;
  Check('generated map class + entry classes are ACCEPTED by the RTTI layer',
        GOk, GErr);

  if GOk then
  begin
    GMap := TMapMsg.Create;
    try
      Check('fresh map is empty',            GMap.countsCount = 0);
      Check('empty map emits nothing',       not EmitsTag(GMap, 2));
      { An absent key is the value type's ZERO, which is what proto3 says a
        missing entry means. Asserted because raising instead would be a
        defensible-looking choice that silently diverges from the spec. }
      Check('absent key reads as the value default',
        GMap.GetCounts('nothing here') = 0);
      Check('absent key is reported absent', not GMap.HasCounts('nothing'));
    finally
      GMap.Free;
    end;

    GMap := TMapMsg.Create;
    try
      GMap.SetCounts('a', 1);
      GMap.SetCounts('b', 2);
      Check('two keys give two entries',  GMap.countsCount = 2);
      Check('first key reads back',       GMap.GetCounts('a') = 1);
      Check('second key reads back',      GMap.GetCounts('b') = 2);
      Check('a present key is reported present', GMap.HasCounts('b'));

      { Replace-or-append. An append-only Set passes every check above and
        still corrupts the map, by putting a duplicate key on the wire. }
      GMap.SetCounts('a', 99);
      Check('re-setting a key REPLACES rather than appends',
        GMap.countsCount = 2);
      Check('the replaced value is the new one', GMap.GetCounts('a') = 99);

      Check('a populated map IS emitted', EmitsTag(GMap, 2));

      GMap.ClearCounts;
      Check('ClearCounts empties the map', GMap.countsCount = 0);
      Check('a cleared map emits nothing', not EmitsTag(GMap, 2));
    finally
      GMap.Free;
    end;

    { Boolean key. Both values used on purpose: `if entry.key = AKey` compiled
      for the wrong type, or a scan that stopped at the first entry, would
      still answer True for one of them. }
    GMap := TMapMsg.Create;
    try
      GMap.SetFlags(True,  'yes');
      GMap.SetFlags(False, 'no');
      Check('bool key: two distinct entries', GMap.flagsCount = 2);
      Check('bool key True reads back',  GMap.GetFlags(True)  = 'yes');
      Check('bool key False reads back', GMap.GetFlags(False) = 'no');
    finally
      GMap.Free;
    end;

    { CANONICAL-1 meets MAP-1. An entry whose key AND value are both at their
      default encodes as a ZERO-LENGTH submessage - every inner field is
      omitted - but the ENTRY itself must still go on the wire, because a
      repeated element is always emitted. protoc does exactly this; dropping
      the entry would silently lose a key. }
    GMap    := TMapMsg.Create;
    GMapDst := TMapMsg.Create;
    try
      GMap.SetCounts('', 0);
      Check('an all-default entry is still emitted', EmitsTag(GMap, 2));
      GBytes := TProtoSerializer.Serialize(GMap);
      TProtoSerializer.Deserialize(GBytes, GMapDst);
      Check('round-trip: the all-default entry survives',
        GMapDst.countsCount = 1);
      Check('round-trip: its key is the empty string', GMapDst.HasCounts(''));
    finally
      GMap.Free;
      GMapDst.Free;
    end;

    // ordinary round trip
    GMap    := TMapMsg.Create;
    GMapDst := TMapMsg.Create;
    try
      GMap.tag := 4;
      GMap.SetCounts('x', 10);
      GMap.SetCounts('y', 20);
      GBytes := TProtoSerializer.Serialize(GMap);
      TProtoSerializer.Deserialize(GBytes, GMapDst);
      Check('round-trip: entry count survives', GMapDst.countsCount = 2);
      Check('round-trip: values survive by key',
        (GMapDst.GetCounts('x') = 10) and (GMapDst.GetCounts('y') = 20));
      Check('round-trip: the plain field beside the map is untouched',
        GMapDst.tag = 4);
    finally
      GMap.Free;
      GMapDst.Free;
    end;

    { Message-VALUED map - the only shape here that owns heap. Three separate
      ways to get it wrong, and all three are fatal rather than silent:
      Set leaking the displaced instance, Set freeing an instance it then
      stores, and the destructor missing the entries entirely. }
    GOk  := False;
    GErr := '';
    try
      GMap := TMapMsg.Create;
      try
        GPay := TPayload.Create;
        GPay.id := 11;
        GMap.SetItems(1, GPay);       // map takes ownership
        Check('message-valued map stores the instance',
          GMap.GetItems(1).id = 11);

        { Replace. The displaced TPayload is freed by Set; if it were not,
          this is a leak, and if the guard against self-assignment were
          missing the NEXT read would touch freed memory. }
        GPay := TPayload.Create;
        GPay.id := 22;
        GMap.SetItems(1, GPay);
        Check('replacing a message value keeps one entry',
          GMap.itemsCount = 1);
        Check('replacing a message value yields the new instance',
          GMap.GetItems(1).id = 22);

        { Self-assignment: Set(k, GetItems(k)). Without the <> guard this
          frees the instance and then stores the dangling pointer. }
        GMap.SetItems(1, GMap.GetItems(1));
        Check('re-setting a key to its OWN value does not free it',
          GMap.GetItems(1).id = 22);

        Check('absent message key reads as nil', GMap.GetItems(999) = nil);
        GBytes := TProtoSerializer.Serialize(GMap);
      finally
        GMap.Free;      // frees the entry, which frees the TPayload
      end;

      GMapDst := TMapMsg.Create;
      try
        TProtoSerializer.Deserialize(GBytes, GMapDst);
        GOk := (GMapDst.itemsCount = 1) and (GMapDst.GetItems(1) <> nil)
               and (GMapDst.GetItems(1).id = 22);
      finally
        GMapDst.Free;   // frees the codec-allocated entry AND its payload
      end;
    except
      on E: Exception do GErr := E.ClassName + ': ' + E.Message;
    end;
    Check('message-valued map round-trips and frees without double-free',
          GOk, GErr);
  end;

  // ── STRUCT-1 · a GENERATED field whose type is a bundled well-known ──────
  //  The table says google.protobuf.Struct maps to TProtobufStruct, and
  //  section 15 of the codec suite says TProtobufStruct works. Neither shows
  //  that the EMITTER turns a Struct-typed field into Pascal that compiles,
  //  puts the right unit in `uses`, and - the part that can go quietly wrong -
  //  keeps the bundled ENUM out of the generated destructor.
  WriteLn;
  WriteLn('-- STRUCT-1: generated fields of bundled well-known types');

  GOk  := False;
  GErr := '';
  GWkt := TWktMsg.Create;
  try
    try
      TProtoSerializer.Serialize(GWkt);
      GOk := True;
    except
      on E: Exception do GErr := E.ClassName + ': ' + E.Message;
    end;
  finally
    GWkt.Free;
  end;
  Check('a class with WKT fields registers and serialises', GOk, GErr);

  if GOk then
  begin
    { The enum field. That this COMPILED at all is most of the result: had the
      emitter classified NullValue as a message it would have emitted
      `Fn.Free` in the destructor, and `.Free` on an enum does not compile.
      So reaching this line proves WellKnownIsEnum did its job. }
    GWkt := TWktMsg.Create;
    try
      GWkt.n := NULL_VALUE;
      Check('bundled ENUM field is a value, not an owned instance',
        GWkt.n = NULL_VALUE);
      Check('  and an enum at its default is omitted, like any other',
        not EmitsTag(GWkt, 3));
    finally
      GWkt.Free;      { must NOT try to free the enum }
    end;

    { The message WKTs. Both are OWNED - assigned here, freed by the generated
      destructor - so a missing destructor leaks and a wrong one crashes. }
    GWkt    := TWktMsg.Create;
    GWktDst := TWktMsg.Create;
    try
      GWkt.tag := 9;
      GWkt.s := TProtobufStruct.Create;
      GWkt.s.SetFields('inner', TProtobufValue.Create);
      GWkt.s.GetFields('inner').string_value := 'from a generated field';
      GWkt.t := TProtobufTimestamp.Create;     // the already-bundled control
      GWkt.t.seconds := 1700000000;

      Check('a Struct-typed generated field goes on the wire', EmitsTag(GWkt, 2));
      Check('the control Timestamp field does too',            EmitsTag(GWkt, 4));

      GBytes := TProtoSerializer.Serialize(GWkt);
      TProtoSerializer.Deserialize(GBytes, GWktDst);

      Check('round-trip: the plain field beside them is untouched',
        GWktDst.tag = 9);
      Check('round-trip: Struct arrives with its entry',
        (GWktDst.s <> nil) and (GWktDst.s.FieldsCount = 1));
      if (GWktDst.s <> nil) and (GWktDst.s.FieldsCount = 1) then
        Check('round-trip: and the value inside it survives',
          GWktDst.s.GetFields('inner').string_value = 'from a generated field');
      Check('round-trip: the control Timestamp survives',
        (GWktDst.t <> nil) and (GWktDst.t.seconds = 1700000000));
    finally
      GWkt.Free;        { the generated destructor frees s and t }
      GWktDst.Free;     { and the codec-allocated ones }
    end;
    { ANY-1 end-to-end, and the only place the registry meets GENERATED code.
      Section 16 of the codec suite registers hand-written well-known classes;
      what a user actually packs is a class protogen emitted, so that is what
      is packed here. }
    GAnyOk  := False;
    GAnyErr := '';
    try
      TProtoAnyRegistry.RegisterType('opt.Payload', TPayload);

      GWkt := TWktMsg.Create;
      GWktDst := TWktMsg.Create;
      try
        GPay := TPayload.Create;
        try
          GPay.id   := 77;
          GPay.note := 'packed into an Any';
          GWkt.a := TProtobufAny.Create;
          TProtoAny.Pack(GWkt.a, GPay);
        finally
          GPay.Free;      { Pack COPIES - the caller keeps ownership }
        end;

        Check('Pack resolved a GENERATED class through the registry',
          GWkt.a.type_url = 'type.googleapis.com/opt.Payload', GWkt.a.type_url);

        GBytes := TProtoSerializer.Serialize(GWkt);
        TProtoSerializer.Deserialize(GBytes, GWktDst);

        Check('round-trip: the Any field survives as a submessage',
          (GWktDst.a <> nil) and (Length(GWktDst.a.value) > 0));
        Check('round-trip: and still names the packed type',
          (GWktDst.a <> nil) and TProtoAny.IsType(GWktDst.a, TPayload));

        GPay := TPayload.Create;
        try
          TProtoAny.UnpackTo(GWktDst.a, GPay);
          GAnyOk := (GPay.id = 77) and (GPay.note = 'packed into an Any');
        finally
          GPay.Free;
        end;
      finally
        GWkt.Free;
        GWktDst.Free;
      end;
    except
      on E: Exception do GAnyErr := E.ClassName + ': ' + E.Message;
    end;
    Check('a generated class round-trips through a generated Any field',
          GAnyOk, GAnyErr);
    TProtoAnyRegistry.Clear;
  end;

  WriteLn;
  WriteLn(Format('[ProtogenOptional] %d passed, %d failed', [GPass, GFail]));
  if GFail = 0 then
    WriteLn('[ProtogenOptional] Generated `optional` code compiles, registers '
            + 'and behaves.')
  else
    WriteLn('[ProtogenOptional] FAILURES.');
  ExitCode := GFail;
end.
