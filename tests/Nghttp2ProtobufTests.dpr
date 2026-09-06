program Nghttp2ProtobufTests;

// ============================================================================
//  Nghttp2ProtobufTests — round-trip validation for the M1 protobuf codec
//  and M1b RTTI-driven serializer.
//
//  Bash-style PASS/FAIL output, ExitCode = failure count. Mirrors the
//  pattern used by HorseNghttp2TestClient.dpr.
//
//  Build (Windows):
//    dcc32 -CC -B Nghttp2ProtobufTests.dpr
//  Build (Linux via PAServer):
//    Delphi IDE → Add Platform 64-bit Linux → Deploy → Run
//  Build (FPC/Lazarus):
//    fpc -MDelphi -O1 Nghttp2ProtobufTests.dpr    (once dual-compile validated)
//
//  Coverage:
//    Wire primitives: varint 32/64, ZigZag 32/64, tag pack/unpack
//    Writer round-trips: int32 / int64 / string / bool typed fields
//    RTTI serializer: full round-trip of a hand-written message class
//    Edge cases: empty message, unknown-field skip, all-zero-defaults
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}
{$M+}   // enable RTTI for message classes below
{$IF DEFINED(FPC)}
  // FPC: {$M+} alone only emits CLASSIC RTTI (accessible via TypInfo
  // GetPropList). System.Rtti / TRttiType.GetProperties reads EXTENDED
  // RTTI, which Delphi enables implicitly but FPC requires via this
  // directive. Without it, TRttiType.GetProperties returns 0.
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti,
  Nghttp2.Protobuf.WellKnown,
  Nghttp2.Protobuf.Any;

var
  GPassCount: Integer = 0;
  GFailCount: Integer = 0;

// ── Test infrastructure ────────────────────────────────────────────────────

procedure Section(const S: string);
begin
  WriteLn;
  WriteLn('-- ', S);
end;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    WriteLn('  PASS  ', AName);
    Inc(GPassCount);
  end
  else
  begin
    if ADetail = '' then
      WriteLn('  FAIL  ', AName)
    else
      WriteLn('  FAIL  ', AName, '  [', ADetail, ']');
    Inc(GFailCount);
  end;
end;

function BytesToHex(const B: TBytes): string;
var I: Integer;
begin
  Result := '';
  for I := 0 to Length(B) - 1 do
    Result := Result + IntToHex(B[I], 2) + ' ';
  if Length(Result) > 0 then SetLength(Result, Length(Result) - 1);
end;

function BytesEqual(const A, B: TBytes): Boolean;
var I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to Length(A) - 1 do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

// ── Test message classes ────────────────────────────────────────────────────

type
  (* A minimal message with one of each M1b-supported type -- covers the
     happy path for pkInt32/pkInt64/pkString/pkBool. Field tags chosen out
     of order (5, 1, 3, 2) to exercise the tag-sort logic in the RTTI scanner.
     Attributes use the [T<Name>] form: Delphi resolves the [Attribute]-suffix
     drop but does NOT strip the T prefix -- [TGrpcMessage] is required for
     class name TGrpcMessageAttribute. *)
  [TGrpcMessage]
  TUserMessage = class
  private
    Fid:       Integer;
    Fname:     string;
    Factive:   Boolean;
    Fbalance:  Int64;
  published
    [TProtoMember(5)]
    property balance: Int64 read Fbalance write Fbalance;
    [TProtoMember(1)]
    property id: Integer read Fid write Fid;
    [TProtoMember(3)]
    property active: Boolean read Factive write Factive;
    [TProtoMember(2)]
    property name: string read Fname write Fname;
  end;

  // ── M1c additions: Float / Double / Enum / TBytes / Submessage ────────────

  TStatusCode = (scOk, scFailed, scPending, scRetry);

  [TGrpcMessage]
  TAddress = class
  private
    Fcity:    string;
    Fzip:     Integer;
  published
    [TProtoMember(1)]
    property city: string read Fcity write Fcity;
    [TProtoMember(2)]
    property zip:  Integer read Fzip  write Fzip;
  end;

  [TGrpcMessage]
  TAdvancedMessage = class
  private
    Fratio:    Single;
    Ftimestamp: Double;
    Fstatus:   TStatusCode;
    Fpayload:  TBytes;
    Faddress:  TAddress;
  public
    destructor Destroy; override;
  published
    [TProtoMember(1)]
    property ratio: Single read Fratio write Fratio;
    [TProtoMember(2)]
    property timestamp: Double read Ftimestamp write Ftimestamp;
    [TProtoMember(3)]
    property status: TStatusCode read Fstatus write Fstatus;
    [TProtoMember(4)]
    property payload: TBytes read Fpayload write Fpayload;
    [TProtoMember(5)]
    property address: TAddress read Faddress write Faddress;
  end;

  // ── M1c.2 additions: repeated fields ──────────────────────────────────────
  //  One repeated field per encoding family, because the two families are
  //  framed completely differently on the wire and a test covering only one
  //  proves nothing about the other:
  //    packed   — numerics collapse into ONE length-delimited record
  //    unpacked — string/bytes/message repeat the tag per element
  //  `payload` is deliberately a plain TBytes, not repeated: proto3 `bytes` is
  //  a scalar, and this field is what catches a regression that starts
  //  treating TArray<Byte> as `repeated uint8`.

  [TGrpcMessage]
  TRepeatedMessage = class
  private
    Fids:       TArray<Integer>;
    Fscores:    TArray<Double>;
    Fflags:     TArray<Boolean>;
    Fstates:    TArray<TStatusCode>;
    Ftags:      TArray<string>;
    Faddresses: TArray<TAddress>;
    Fpayload:   TBytes;
  public
    destructor Destroy; override;
  published
    [TProtoMember(1)]
    property ids: TArray<Integer> read Fids write Fids;             // packed varint
    [TProtoMember(2)]
    property scores: TArray<Double> read Fscores write Fscores;     // packed fixed64
    [TProtoMember(3)]
    property flags: TArray<Boolean> read Fflags write Fflags;       // packed varint
    [TProtoMember(4)]
    property states: TArray<TStatusCode> read Fstates write Fstates; // packed enum
    [TProtoMember(5)]
    property tags: TArray<string> read Ftags write Ftags;           // unpacked LEN
    [TProtoMember(6)]
    property addresses: TArray<TAddress> read Faddresses write Faddresses; // unpacked LEN
    [TProtoMember(7)]
    property payload: TBytes read Fpayload write Fpayload;          // scalar bytes
  end;

  { One repeated field and nothing else, for the byte-exact wire assertions.

    TRepeatedMessage cannot serve there: this codec emits EVERY scalar field
    unconditionally, including ones holding their proto3 default, so its empty
    `payload: TBytes` contributes a stray tag+len(0) — two bytes that have
    nothing to do with repeated framing but land in any byte count taken over
    the whole message. Isolating the field under test is what makes the
    assertion about packing rather than about the rest of the class. }
  [TGrpcMessage]
  TPackedOnlyMessage = class
  private
    Fids: TArray<Integer>;
  published
    [TProtoMember(1)]
    property ids: TArray<Integer> read Fids write Fids;
  end;

  { FIX-PROTO-UINT32-1. One unsigned field each, isolated for the same reason
    TPackedOnlyMessage is: the byte assertions below must be about the value
    under test and nothing else. }
  [TGrpcMessage]
  TUnsignedMessage = class
  private
    Fu32: Cardinal;
    Fu64: UInt64;
  published
    [TProtoMember(1)] property u32: Cardinal read Fu32 write Fu32;
    [TProtoMember(2)] property u64: UInt64   read Fu64 write Fu64;
  end;

  { A genuinely fieldless message — the shape of google.protobuf.Empty, which
    gRPC returns constantly. The scanner used to refuse ANY zero-field class,
    because it could not tell a deliberate empty message from someone who
    forgot the M+ directive. [TGrpcMessage] is now that discriminator. }
  [TGrpcMessage]
  TEmptyMessage = class
  end;

  { The control: same zero fields, NO attribute. Must still be refused, or the
    fix has thrown away the diagnostic it was protecting. }
  TUnmarkedEmptyMessage = class
  end;

  // ── PRESENCE-1 · proto3 `optional` (explicit presence) ────────────────────
  //
  //  The has-bit is READ-ONLY and raised by the value's setter. That is the
  //  whole mechanism: deserialisation writes the value through SetValue, which
  //  calls SetOpt, which raises FhasOpt. A writable bit is refused at
  //  discovery precisely so this is the only path.
  //
  //  `plain` sits alongside deliberately - it has IMPLICIT presence and must
  //  keep being emitted unconditionally, proving the feature is additive.

  [TGrpcMessage]
  TOptionalMessage = class
  private
    Fplain:  Integer;
    Fopt:    Integer;
    FhasOpt: Boolean;
    procedure SetOpt(const AValue: Integer);
  public
    procedure ClearOpt;
  published
    [TProtoMember(1)] property plain:  Integer read Fplain write Fplain;
    [TProtoMember(2)] property opt:    Integer read Fopt   write SetOpt;
    [TProtoHas(2)]    property hasOpt: Boolean read FhasOpt;
  end;

  { Five refusals. Each declares something that ENCODES and DECODES fine while
    meaning something other than the schema said - a field that never
    transmits, or a presence that is always False. Silent-wrong is the failure
    mode being designed out, so each must raise. }

  [TGrpcMessage]
  TBadWritableHas = class          // has-bit the author could desync by hand
  private
    Fv: Integer; Fhas: Boolean;
  published
    [TProtoMember(1)] property v:   Integer read Fv   write Fv;
    [TProtoHas(1)]    property has: Boolean read Fhas write Fhas;
  end;

  [TGrpcMessage]
  TBadNonBooleanHas = class        // has-bit that is not a Boolean
  private
    Fv: Integer; Fhas: Integer;
  published
    [TProtoMember(1)] property v:   Integer read Fv;
    [TProtoHas(1)]    property has: Integer read Fhas;
  end;

  [TGrpcMessage]
  TBadOrphanHas = class            // has-bit naming a tag no field carries
  private
    Fv: Integer; Fhas: Boolean;
  published
    [TProtoMember(1)] property v:   Integer read Fv;
    [TProtoHas(7)]    property has: Boolean read Fhas;
  end;

  [TGrpcMessage]
  TBadRepeatedHas = class          // repeated has no presence to express
  private
    Fids: TArray<Integer>; Fhas: Boolean;
  published
    [TProtoMember(1)] property ids: TArray<Integer> read Fids;
    [TProtoHas(1)]    property has: Boolean read Fhas;
  end;

  [TGrpcMessage]
  TBadSubmessageHas = class        // submessage already has presence via nil
  private
    Faddr: TAddress; Fhas: Boolean;
  published
    [TProtoMember(1)] property addr: TAddress read Faddr;
    [TProtoHas(1)]    property has:  Boolean  read Fhas;
  end;

// ── PRESENCE-1 · TOptionalMessage members ───────────────────────────────────

{ The setter IS the mechanism. Deserialisation reaches it through
  TRttiProperty.SetValue, so a field arriving on the wire raises the bit with
  no deserialiser-side code at all. }
procedure TOptionalMessage.SetOpt(const AValue: Integer);
begin
  Fopt    := AValue;
  FhasOpt := True;
end;

{ Clearing needs its own path: assigning 0 through the setter would SET the
  field to zero, which on the wire is the opposite of absent. }
procedure TOptionalMessage.ClearOpt;
begin
  Fopt    := 0;
  FhasOpt := False;
end;

// ── Destructor for TAdvancedMessage — implementation outside type block ─────

destructor TAdvancedMessage.Destroy;
begin
  Faddress.Free;
  inherited;
end;

{ The deserializer allocates one TAddress per repeated element and hands
  ownership to the array, so the message must free them — the same contract a
  scalar submessage property carries. }
destructor TRepeatedMessage.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Faddresses) do
    Faddresses[I].Free;
  inherited;
end;

// ── Test — wire primitives ─────────────────────────────────────────────────

procedure TestZigZag;
begin
  Section('01  ZigZag encode/decode 32/64');
  Check('ZigZagEncode32(0) = 0',   ZigZagEncode32(0)  = 0);
  Check('ZigZagEncode32(-1) = 1',  ZigZagEncode32(-1) = 1);
  Check('ZigZagEncode32(1) = 2',   ZigZagEncode32(1)  = 2);
  Check('ZigZagEncode32(-2) = 3',  ZigZagEncode32(-2) = 3);
  Check('ZigZagEncode32(MaxInt) = MaxUInt-1',
    ZigZagEncode32(MaxInt) = UInt32($FFFFFFFE));
  Check('ZigZagEncode32(-MaxInt-1) = MaxUInt',
    ZigZagEncode32(Low(Int32)) = UInt32($FFFFFFFF));
  Check('ZigZagDecode32(0) = 0',   ZigZagDecode32(0)  = 0);
  Check('ZigZagDecode32(1) = -1',  ZigZagDecode32(1)  = -1);
  Check('ZigZagDecode32(2) = 1',   ZigZagDecode32(2)  = 1);
  Check('ZigZagDecode32(3) = -2',  ZigZagDecode32(3)  = -2);

  Check('ZigZagEncode64(0) = 0',        ZigZagEncode64(0) = 0);
  Check('ZigZagEncode64(-1) = 1',       ZigZagEncode64(-1) = 1);
  Check('ZigZagEncode64(Low(Int64)) = MaxUInt64',
    ZigZagEncode64(Low(Int64)) = UInt64($FFFFFFFFFFFFFFFF));
  Check('ZigZagDecode64(round-trip -12345)', ZigZagDecode64(ZigZagEncode64(-12345)) = -12345);
end;

procedure TestTagPacking;
var
  LFieldNumber: Integer;
  LWire: TProtoWireType;
begin
  Section('02  Tag pack/unpack');
  Check('MakeTag(1, pwVarint) = 8', MakeTag(1, pwVarint) = 8);
  Check('MakeTag(2, pwLen)    = 18', MakeTag(2, pwLen)    = 18);
  Check('MakeTag(15, pwFixed32) = 125', MakeTag(15, pwFixed32) = 125);

  ParseTag(8, LFieldNumber, LWire);
  Check('ParseTag(8) fieldNumber = 1',  LFieldNumber = 1);
  Check('ParseTag(8) wire = pwVarint',  LWire = pwVarint);

  ParseTag(18, LFieldNumber, LWire);
  Check('ParseTag(18) fieldNumber = 2', LFieldNumber = 2);
  Check('ParseTag(18) wire = pwLen',    LWire = pwLen);
end;

procedure TestVarintRoundTrip;
var
  LW: TProtoWriter;
  LR: TProtoReader;
  LB: TBytes;
begin
  Section('03  Varint round-trip via TProtoWriter/Reader');
  LW := TProtoWriter.Create;
  try
    LW.WriteVarint(0);
    LW.WriteVarint(1);
    LW.WriteVarint(127);
    LW.WriteVarint(128);
    LW.WriteVarint(16384);
    LW.WriteVarint(UInt64($7FFFFFFFFFFFFFFF));   // 63-bit max
    LB := LW.ToBytes;
  finally
    LW.Free;
  end;

  LR := TProtoReader.Create(LB);
  try
    Check('varint 0',           LR.ReadVarint = 0);
    Check('varint 1',           LR.ReadVarint = 1);
    Check('varint 127',         LR.ReadVarint = 127);
    Check('varint 128',         LR.ReadVarint = 128);
    Check('varint 16384',       LR.ReadVarint = 16384);
    Check('varint 63-bit max',  LR.ReadVarint = UInt64($7FFFFFFFFFFFFFFF));
    Check('reader at EOF',      LR.Eof);
  finally
    LR.Free;
  end;
end;

// ── Test — RTTI serializer round-trip ──────────────────────────────────────

procedure TestRttiRoundTripPopulated;
var
  LSrc, LDst: TUserMessage;
  LBytes: TBytes;
begin
  Section('04  RTTI serializer - populated message round-trip');
  LSrc := TUserMessage.Create;
  LDst := TUserMessage.Create;
  try
    LSrc.id       := 42;
    LSrc.name     := 'Alice';
    LSrc.active   := True;
    LSrc.balance  := Int64(1234567890123);

    LBytes := TProtoSerializer.Serialize(LSrc);
    Check('serialized bytes non-empty', Length(LBytes) > 0,
      'got ' + IntToStr(Length(LBytes)) + ' bytes: ' + BytesToHex(LBytes));

    TProtoSerializer.Deserialize(LBytes, LDst);

    Check('round-trip id = 42',                LDst.id = 42,          IntToStr(LDst.id));
    Check('round-trip name = "Alice"',         LDst.name = 'Alice',   LDst.name);
    Check('round-trip active = True',          LDst.active = True);
    Check('round-trip balance = 1234567890123', LDst.balance = 1234567890123,
      IntToStr(LDst.balance));
  finally
    LSrc.Free;
    LDst.Free;
  end;
end;

procedure TestRttiRoundTripEmpty;
var
  LSrc, LDst: TUserMessage;
  LBytes: TBytes;
begin
  Section('05  all-default message: canonical encoding + MERGE semantics');
  LSrc := TUserMessage.Create;
  LDst := TUserMessage.Create;
  try
    // Leave all fields at Pascal default (0 / '' / False).
    LBytes := TProtoSerializer.Serialize(LSrc);

    { CANONICAL-1. Every field holds its proto3 default, so a canonical
      encoder emits NOTHING. This used to be 8 bytes of tag+zero pairs. }
    Check('all-default instance serialises to ZERO bytes',
      Length(LBytes) = 0,
      IntToStr(Length(LBytes)) + ' bytes: ' + BytesToHex(LBytes));

    // Into a FRESH target - the normal case, and what every path in this
    // library actually does.
    TProtoSerializer.Deserialize(LBytes, LDst);
    Check('fresh target decodes to defaults',
      (LDst.id = 0) and (LDst.name = '') and (not LDst.active)
      and (LDst.balance = 0));
  finally
    LSrc.Free;
    LDst.Free;
  end;

  { The other half, and this test USED to assert the opposite.

    It pre-populated the target and checked that an all-default message
    overwrote it with zeros - which passed only because we emitted those
    zeros. Now they are absent from the wire, so nothing overwrites, and the
    old values remain.

    That is MERGE semantics (protobuf's MergeFromString), which is what
    Deserialize has always implemented; the non-canonical output merely hid
    it. It cannot be changed to clear-first either: PRESENCE-1 makes has-bits
    read-only, so a has-bit field cannot be reset from outside its class.

    Asserted rather than deleted, because leaving it untested would make the
    contract discoverable only by being bitten by it. Note this is also
    exactly what talking to Python/Go/C++ has always done - they have always
    omitted defaults. }
  LSrc := TUserMessage.Create;
  LDst := TUserMessage.Create;
  try
    LBytes := TProtoSerializer.Serialize(LSrc);   // zero bytes

    LDst.id      := 999;
    LDst.name    := 'GARBAGE';
    LDst.active  := True;
    LDst.balance := 999;

    TProtoSerializer.Deserialize(LBytes, LDst);

    Check('MERGE: absent fields leave a populated target untouched',
      (LDst.id = 999) and (LDst.name = 'GARBAGE') and LDst.active
      and (LDst.balance = 999),
      'Deserialize is MergeFromString, not ParseFromString - pass a fresh '
      + 'instance if you want parse-from-scratch');

    { The control that keeps the above honest: a field PRESENT on the wire
      must still overwrite. Without this, the assertion above would also pass
      if Deserialize had silently stopped writing anything at all. }
    LSrc.id := 7;
    LBytes := TProtoSerializer.Serialize(LSrc);
    TProtoSerializer.Deserialize(LBytes, LDst);
    Check('MERGE: a field PRESENT on the wire still overwrites',
      LDst.id = 7);
    Check('MERGE: and the others are still left alone',
      LDst.name = 'GARBAGE');
  finally
    LSrc.Free;
    LDst.Free;
  end;
end;

procedure TestRttiUnknownFieldSkip;
var
  LW: TProtoWriter;
  LDst: TUserMessage;
  LBytes: TBytes;
begin
  Section('06  RTTI serializer - unknown-field skip (proto3 forward-compat)');
  // Hand-build a message containing:
  //   tag 1 (id, varint):      99
  //   tag 99 (unknown, varint): 42  ← must be silently skipped
  //   tag 2 (name, string):    "kept"
  LW := TProtoWriter.Create;
  try
    LW.WriteInt32Field(1, 99);
    LW.WriteInt32Field(99, 42);    // unknown field — deserializer should skip
    LW.WriteStringField(2, 'kept');
    LBytes := LW.ToBytes;
  finally
    LW.Free;
  end;

  LDst := TUserMessage.Create;
  try
    TProtoSerializer.Deserialize(LBytes, LDst);
    Check('known field id = 99',           LDst.id = 99, IntToStr(LDst.id));
    Check('known field name = "kept"',     LDst.name = 'kept', LDst.name);
    Check('unknown field silently skipped (no crash)', True);
  finally
    LDst.Free;
  end;
end;

// ── M1c: Float / Double / Enum / TBytes / Submessage round-trip ────────────

procedure TestAdvancedTypes;
var
  LSrc, LDst: TAdvancedMessage;
  LBytes:     TBytes;
  I:          Integer;
begin
  Section('08  M1c - Float/Double/Enum/TBytes/Submessage round-trip');
  LSrc := TAdvancedMessage.Create;
  LDst := TAdvancedMessage.Create;
  try
    LSrc.ratio     := 3.14;
    LSrc.timestamp := 1234567890.5;
    LSrc.status    := scPending;

    // TBytes: 5-byte payload
    SetLength(LSrc.Fpayload, 5);
    LSrc.Fpayload[0] := $DE;
    LSrc.Fpayload[1] := $AD;
    LSrc.Fpayload[2] := $BE;
    LSrc.Fpayload[3] := $EF;
    LSrc.Fpayload[4] := $42;

    // Nested submessage
    LSrc.Faddress := TAddress.Create;
    LSrc.Faddress.city := 'Lisbon';
    LSrc.Faddress.zip  := 1000;

    LBytes := TProtoSerializer.Serialize(LSrc);
    Check('serialize succeeded, non-empty bytes', Length(LBytes) > 0,
      IntToStr(Length(LBytes)) + ' bytes');

    TProtoSerializer.Deserialize(LBytes, LDst);

    Check('round-trip ratio ~= 3.14',
      Abs(LDst.ratio - 3.14) < 0.0001,
      FloatToStr(LDst.ratio));
    Check('round-trip timestamp ~= 1234567890.5',
      Abs(LDst.timestamp - 1234567890.5) < 0.001,
      FloatToStr(LDst.timestamp));
    Check('round-trip status = scPending (enum ordinal 2)',
      LDst.status = scPending,
      IntToStr(Ord(LDst.status)));
    Check('round-trip payload length = 5',
      Length(LDst.payload) = 5,
      IntToStr(Length(LDst.payload)));
    if Length(LDst.payload) = 5 then
    begin
      Check('round-trip payload[0] = $DE', LDst.payload[0] = $DE);
      Check('round-trip payload[4] = $42', LDst.payload[4] = $42);
    end;
    Check('round-trip submessage address non-nil',
      LDst.Faddress <> nil);
    if LDst.Faddress <> nil then
    begin
      Check('round-trip address.city = "Lisbon"',
        LDst.Faddress.city = 'Lisbon',
        LDst.Faddress.city);
      Check('round-trip address.zip = 1000',
        LDst.Faddress.zip = 1000,
        IntToStr(LDst.Faddress.zip));
    end;
  finally
    LSrc.Free;
    LDst.Free;
  end;
end;

procedure TestBytesEqualForKnownEncoding;
var
  LSrc: TUserMessage;
  LBytes, LExpected: TBytes;
begin
  Section('07  RTTI serializer - known bytes for known input');
  LSrc := TUserMessage.Create;
  try
    LSrc.id := 1;
    // Leave name, active, balance at defaults.
    LBytes := TProtoSerializer.Serialize(LSrc);

    { CANONICAL-1 changed this, and the change IS the feature.
      Before: 8 bytes - every field emitted, defaults included.
        [08 01] tag 1 = 1
        [12 00] tag 2 LEN 0   (empty string)
        [18 00] tag 3 = 0     (False)
        [28 00] tag 5 = 0
      Now: 2 bytes. Only the non-default field goes on the wire, which is
      what proto3 specifies and what every other implementation emits. A
      conforming decoder fills the three absent fields with their defaults,
      so the peer reads exactly what it read before from a quarter of the
      bytes.

      This assertion is the byte-exact proof of the fix - the conformance
      probe reports it, but only this compares against a literal. }
    SetLength(LExpected, 2);
    LExpected[0] := $08; LExpected[1] := $01;

    Check('bytes match expected encoding (canonical: defaults omitted)',
      BytesEqual(LBytes, LExpected),
      'expected: ' + BytesToHex(LExpected) + '  got: ' + BytesToHex(LBytes));
  finally
    LSrc.Free;
  end;
end;

// ── M1c.2 — repeated fields ────────────────────────────────────────────────
//
//  Array literals are built through these open-array helpers rather than
//  `TArray<T>.Create(...)`. The rest of this file already builds every array
//  with SetLength for the same reason: the dynamic-array constructor form is
//  a Delphi idiom whose generic spelling is not reliably available under FPC
//  {$MODE DELPHI}, and this suite has to pass on both compilers. An open-array
//  parameter is plain Object Pascal and behaves identically on each.

function ArrInt(const A: array of Integer): TArray<Integer>;
var I: Integer;
begin
  Result := nil;   // silences FPC's uninitialised-result warning
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function ArrDbl(const A: array of Double): TArray<Double>;
var I: Integer;
begin
  Result := nil;   // silences FPC's uninitialised-result warning
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function ArrBool(const A: array of Boolean): TArray<Boolean>;
var I: Integer;
begin
  Result := nil;   // silences FPC's uninitialised-result warning
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function ArrStr(const A: array of string): TArray<string>;
var I: Integer;
begin
  Result := nil;   // silences FPC's uninitialised-result warning
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function ArrStatus(const A: array of TStatusCode): TArray<TStatusCode>;
var I: Integer;
begin
  Result := nil;   // silences FPC's uninitialised-result warning
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function ArrBytes(const A: array of Byte): TBytes;
var I: Integer;
begin
  Result := nil;   // silences FPC's uninitialised-result warning
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

procedure TestRepeatedRoundTrip;
var
  LSrc, LDst: TRepeatedMessage;
  LBytes:     TBytes;
  I:          Integer;
  LOk:        Boolean;
begin
  Section('09  Repeated fields - round-trip (packed + unpacked)');

  LSrc := TRepeatedMessage.Create;
  LDst := TRepeatedMessage.Create;
  try
    LSrc.ids    := ArrInt([1, -2, 300, 0, MaxInt]);
    LSrc.scores := ArrDbl([1.5, -2.25, 1E10]);
    LSrc.flags  := ArrBool([True, False, True]);
    LSrc.states := ArrStatus([scRetry, scOk, scPending]);
    LSrc.tags   := ArrStr(['alpha', '', 'ünïcødé', 'delta']);
    LSrc.payload := ArrBytes([9, 8, 7]);

    SetLength(LSrc.Faddresses, 2);
    LSrc.Faddresses[0] := TAddress.Create;
    LSrc.Faddresses[0].city := 'Lisboa';
    LSrc.Faddresses[0].zip  := 1000;
    LSrc.Faddresses[1] := TAddress.Create;
    LSrc.Faddresses[1].city := 'Porto';
    LSrc.Faddresses[1].zip  := 4000;

    LBytes := TProtoSerializer.Serialize(LSrc);
    TProtoSerializer.Deserialize(LBytes, LDst);

    // ── packed numerics ────────────────────────────────────────────────────
    Check('ids length 5', Length(LDst.ids) = 5, IntToStr(Length(LDst.ids)));
    LOk := Length(LDst.ids) = 5;
    if LOk then
      for I := 0 to High(LSrc.ids) do
        LOk := LOk and (LDst.ids[I] = LSrc.ids[I]);
    Check('ids values match (incl. negative + zero + MaxInt)', LOk);

    Check('scores length 3', Length(LDst.scores) = 3, IntToStr(Length(LDst.scores)));
    LOk := Length(LDst.scores) = 3;
    if LOk then
      for I := 0 to High(LSrc.scores) do
        LOk := LOk and (Abs(LDst.scores[I] - LSrc.scores[I]) < 1E-9);
    Check('scores values match', LOk);

    Check('flags length 3', Length(LDst.flags) = 3, IntToStr(Length(LDst.flags)));
    Check('flags values match',
      (Length(LDst.flags) = 3) and LDst.flags[0] and (not LDst.flags[1]) and LDst.flags[2]);

    Check('states length 3', Length(LDst.states) = 3, IntToStr(Length(LDst.states)));
    Check('states values match',
      (Length(LDst.states) = 3) and (LDst.states[0] = scRetry)
      and (LDst.states[1] = scOk) and (LDst.states[2] = scPending));

    // ── unpacked LEN-per-element ───────────────────────────────────────────
    // The empty string at index 1 matters: it is a zero-length LEN record, the
    // element most likely to be dropped by a decoder that treats "no bytes" as
    // "no element" — which would silently shift every later index.
    Check('tags length 4', Length(LDst.tags) = 4, IntToStr(Length(LDst.tags)));
    LOk := Length(LDst.tags) = 4;
    if LOk then
      for I := 0 to High(LSrc.tags) do
        LOk := LOk and (LDst.tags[I] = LSrc.tags[I]);
    Check('tags values match (incl. empty string + non-ASCII)', LOk);

    Check('addresses length 2', Length(LDst.addresses) = 2, IntToStr(Length(LDst.addresses)));
    Check('addresses[0] round-tripped',
      (Length(LDst.addresses) = 2) and (LDst.addresses[0].city = 'Lisboa')
      and (LDst.addresses[0].zip = 1000));
    Check('addresses[1] round-tripped',
      (Length(LDst.addresses) = 2) and (LDst.addresses[1].city = 'Porto')
      and (LDst.addresses[1].zip = 4000));

    // ── the regression guard ───────────────────────────────────────────────
    Check('payload (TBytes) still a scalar, not repeated',
      (Length(LDst.payload) = 3) and (LDst.payload[0] = 9)
      and (LDst.payload[1] = 8) and (LDst.payload[2] = 7));
  finally
    LSrc.Free;
    LDst.Free;
  end;
end;

procedure TestRepeatedEmptyAndWire;
var
  LSrc, LDst: TPackedOnlyMessage;
  LFull:      TRepeatedMessage;
  LBytes:     TBytes;
  LW:         TProtoWriter;
  LPacked:    TBytes;
begin
  Section('10  Repeated fields - empty arrays + wire shape');

  { An empty repeated field emits NOTHING — proto3 cannot distinguish "empty"
    from "absent", so any byte here is waste. Measured on TPackedOnlyMessage
    so the count reflects only the repeated field; see that class's comment
    for why the fuller message cannot answer this question. }
  LSrc := TPackedOnlyMessage.Create;
  LDst := TPackedOnlyMessage.Create;
  try
    LBytes := TProtoSerializer.Serialize(LSrc);
    Check('empty repeated field emits 0 bytes',
      Length(LBytes) = 0, IntToStr(Length(LBytes)));

    TProtoSerializer.Deserialize(LBytes, LDst);
    Check('empty round-trip leaves ids empty', Length(LDst.ids) = 0);
  finally
    LSrc.Free;
    LDst.Free;
  end;

  // Same question against the full message, which additionally has scalars.
  LFull := TRepeatedMessage.Create;
  try
    TProtoSerializer.Deserialize(TProtoSerializer.Serialize(LFull), LFull);
    Check('empty round-trip leaves tags empty', Length(LFull.tags) = 0);
    Check('empty round-trip leaves addresses empty', Length(LFull.addresses) = 0);
  finally
    LFull.Free;
  end;

  { Packed framing, byte-exact rather than by round-trip. A codec emitting one
    tagged varint per element would round-trip perfectly against itself and
    still be wrong against every other proto3 stack — only the byte shape
    catches that. Expected: tag(1,pwLen) len(3) 01 02 03 = 5 bytes. }
  LSrc := TPackedOnlyMessage.Create;
  try
    LSrc.ids := ArrInt([1, 2, 3]);
    LBytes := TProtoSerializer.Serialize(LSrc);

    LW := TProtoWriter.Create;
    try
      LPacked := ArrBytes([1, 2, 3]);       // three single-byte varints
      LW.WriteSubmessageField(1, LPacked);  // tag 1, pwLen, len 3
      Check('packed ids wire bytes = tag+len+3 varints',
        BytesEqual(LBytes, LW.ToBytes),
        Format('got [%s], expected [%s]',
          [BytesToHex(LBytes), BytesToHex(LW.ToBytes)]));
    finally
      LW.Free;
    end;
  finally
    LSrc.Free;
  end;
end;

procedure TestRepeatedAcceptsUnpackedNumeric;
var
  LW:   TProtoWriter;
  LW2:  TProtoWriter;   // second message — a separate variable so neither
                        // writer is ever reassigned inside its own try/finally
  LDst: TRepeatedMessage;
begin
  Section('11  Repeated numerics decode from UNPACKED wire form');

  { proto3 requires a decoder to accept both forms for packable types, whatever
    the encoder chose. Nothing we emit exercises this — our writer always packs
    — so the input is hand-built as three separately tagged varints, which is
    what an older or differently-configured peer sends. Without this the
    decoder could reject every such peer and the suite would stay green. }
  LW  := TProtoWriter.Create;
  LW2 := TProtoWriter.Create;
  LDst := TRepeatedMessage.Create;
  try
    LW.WriteInt32Field(1, 10);
    LW.WriteInt32Field(1, 20);
    LW.WriteInt32Field(1, 30);

    TProtoSerializer.Deserialize(LW.ToBytes, LDst);

    Check('unpacked ids length 3', Length(LDst.ids) = 3, IntToStr(Length(LDst.ids)));
    Check('unpacked ids values match',
      (Length(LDst.ids) = 3) and (LDst.ids[0] = 10)
      and (LDst.ids[1] = 20) and (LDst.ids[2] = 30));

    // Split across records: a sender may emit a repeated field in fragments,
    // packed or not. Accumulation must append, never overwrite.
    LDst.ids := nil;
    LW2.WriteSubmessageField(1, ArrBytes([1, 2]));   // packed   [1,2]
    LW2.WriteInt32Field(1, 3);                       // unpacked  3
    LW2.WriteSubmessageField(1, ArrBytes([4]));      // packed   [4]

    TProtoSerializer.Deserialize(LW2.ToBytes, LDst);
    Check('mixed packed/unpacked fragments accumulate to 4 elements',
      Length(LDst.ids) = 4, IntToStr(Length(LDst.ids)));
    Check('fragment order preserved [1,2,3,4]',
      (Length(LDst.ids) = 4) and (LDst.ids[0] = 1) and (LDst.ids[1] = 2)
      and (LDst.ids[2] = 3) and (LDst.ids[3] = 4));
  finally
    LW.Free;
    LW2.Free;
    LDst.Free;
  end;
end;

{ FIX-PROTO-UINT32-1 — proto3 uint32 / uint64.

  These assert BYTES, not just a round-trip, and that is the whole point. On
  the unfixed code a Cardinal above MaxInt round-tripped PERFECTLY: the
  encoder overflowed it to negative and the decoder reversed the same
  overflow, so the pair agreed with itself while putting a completely
  different number on the wire. Every test that checked only round-trip passed.
  Any future test added here must compare bytes for the same reason.

  Expected encodings, from the proto3 spec rather than from our own writer:
    uint32 3000000000 -> 80 BC C1 96 0B          (5-byte varint)
    uint64 2^63       -> 80 80 80 80 80 80 80 80 80 01
  The unfixed encoder produced 80 BC C1 96 FB FF FF FF FF 01 for the first —
  note the shared 4-byte prefix, which is what made it look plausible. }
{ An empty message must serialise to zero bytes and survive a round trip.

  Both halves are asserted, and the second is the one that keeps the change
  honest: an UNMARKED zero-field class must still be refused, because that is
  the M+ / published / missing-import mistake the original guard exists to
  catch. Relaxing the guard without keeping that control would trade a loud,
  accurate diagnostic for messages that silently serialise as nothing.

  This also exercises TRttiType.GetAttributes on a CLASS, which is the part
  most at risk of behaving differently on FPC — hence a gate rather than a
  report. }
procedure TestEmptyMessage;
var
  LSrc, LDst: TEmptyMessage;
  LBad: TUnmarkedEmptyMessage;
  LBytes: TBytes;
  LRefused: Boolean;
begin
  Section('13  empty message ([TGrpcMessage], zero fields)');

  LSrc := TEmptyMessage.Create;
  LDst := TEmptyMessage.Create;
  try
    LBytes := TProtoSerializer.Serialize(LSrc);
    Check('empty message serialises to 0 bytes', Length(LBytes) = 0,
      IntToStr(Length(LBytes)) + ' bytes: ' + BytesToHex(LBytes));

    TProtoSerializer.Deserialize(LBytes, LDst);
    Check('empty message round-trips without raising', True);
  finally
    LSrc.Free;
    LDst.Free;
  end;

  LRefused := False;
  LBad := TUnmarkedEmptyMessage.Create;
  try
    try
      TProtoSerializer.Serialize(LBad);
    except
      on E: EProtoRttiError do
        LRefused := True;
    end;
  finally
    LBad.Free;
  end;
  Check('zero fields WITHOUT [TGrpcMessage] is still refused', LRefused,
    'the {$M+} diagnostic must survive');
end;

{ Serialises AObj and reports whether tag ATag actually appears as a FIELD.

  Decoded with the real reader rather than scanned for the tag byte. A byte
  scan is subtly wrong: tag 2 varint is $10, and a preceding field holding the
  VALUE 16 also puts $10 in the buffer, so `plain := 16` would make an absent
  optional field read as present. It does not fire while plain is 0 - which is
  exactly what would make it a false pass discovered much later. }
function EmitsTag(AObj: TObject; ATag: Integer; out ABytes: TBytes): Boolean;
var
  LReader: TProtoReader;
  LTag:    Integer;
  LWire:   TProtoWireType;
begin
  ABytes := TProtoSerializer.Serialize(AObj);
  Result := False;
  LReader := TProtoReader.Create(ABytes);
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

{ Runs discovery on a deliberately-malformed class and reports whether it was
  refused AND whether the message explains itself.

  Asserting only "it raised" would pass for an access violation, and a
  diagnostic that merely restates the construct sends the reader hunting for a
  typo - so the message must also mention ANEEDLE. Same three-part rule the
  protogen negative tests use. }
function RefusedWithReason(AObj: TObject; const ANeedle: string;
  out AMsg: string): Boolean;
begin
  Result := False;
  AMsg   := '';
  try
    TProtoSerializer.Serialize(AObj);
  except
    on E: EProtoRttiError do
    begin
      AMsg   := E.Message;
      Result := Pos(LowerCase(ANeedle), LowerCase(E.Message)) > 0;
    end;
  end;
end;

procedure TestExplicitPresence;
var
  LMsg, LDst: TOptionalMessage;
  LBytes: TBytes;
  LEmitted: Boolean;
  LText: string;
  LBadW: TBadWritableHas;
  LBadN: TBadNonBooleanHas;
  LBadO: TBadOrphanHas;
  LBadR: TBadRepeatedHas;
  LBadS: TBadSubmessageHas;
begin
  Section('14  explicit presence - proto3 `optional` (PRESENCE-1)');

  // ── unset must NOT go out ────────────────────────────────────────────────
  LMsg := TOptionalMessage.Create;
  try
    { `plain` is set to a NON-default value on purpose. Since CANONICAL-1 an
      implicit-presence field at its default is omitted like any other, so
      leaving it at 0 here would assert the pre-canonical behaviour - which is
      exactly what this check did until CANONICAL-1 landed and failed it. The
      intent is unchanged: an ordinary field beside an optional one still
      works normally. }
    LMsg.plain := 5;
    LEmitted := EmitsTag(LMsg, 2, LBytes);
    Check('optional field UNSET is not emitted', not LEmitted,
      BytesToHex(LBytes));
    Check('a NON-default implicit-presence field beside it still emits',
      (Length(LBytes) >= 2) and (LBytes[0] = $08),
      BytesToHex(LBytes));

    { The other half, and the new behaviour: at its DEFAULT the same field is
      now omitted. Asserted here rather than left to the conformance probe,
      because this suite is where a regression would be noticed. }
    LMsg.plain := 0;
    LEmitted := EmitsTag(LMsg, 1, LBytes);
    Check('CANONICAL-1: an implicit-presence field at its DEFAULT is omitted',
      not LEmitted, BytesToHex(LBytes));
  finally
    LMsg.Free;
  end;

  // ── set to ZERO must go out. This is the entire point of the feature ─────
  LMsg := TOptionalMessage.Create;
  try
    LMsg.opt := 0;
    LEmitted := EmitsTag(LMsg, 2, LBytes);
    Check('optional field SET TO ZERO is emitted', LEmitted,
      'set-to-zero must be distinguishable from unset: ' + BytesToHex(LBytes));
    Check('assigning through the setter raised the has-bit', LMsg.hasOpt);
  finally
    LMsg.Free;
  end;

  // ── set to non-zero ──────────────────────────────────────────────────────
  LMsg := TOptionalMessage.Create;
  try
    LMsg.opt := 42;
    LEmitted := EmitsTag(LMsg, 2, LBytes);
    Check('optional field set to non-zero is emitted', LEmitted);
  finally
    LMsg.Free;
  end;

  // ── ClearOpt puts it back to absent ──────────────────────────────────────
  LMsg := TOptionalMessage.Create;
  try
    LMsg.opt := 7;
    LMsg.ClearOpt;
    LEmitted := EmitsTag(LMsg, 2, LBytes);
    Check('ClearOpt returns the field to absent', not LEmitted);
    Check('ClearOpt lowered the has-bit', not LMsg.hasOpt);
  finally
    LMsg.Free;
  end;

  // ── ROUND TRIP: set-to-zero survives as PRESENT ──────────────────────────
  //  The check that proves the deserialise side needs no code of its own:
  //  SetValue goes through SetOpt, which raises the bit.
  LMsg := TOptionalMessage.Create;
  LDst := TOptionalMessage.Create;
  try
    LMsg.opt := 0;
    LBytes := TProtoSerializer.Serialize(LMsg);
    TProtoSerializer.Deserialize(LBytes, LDst);
    Check('round-trip: set-to-zero arrives with value 0', LDst.opt = 0);
    Check('round-trip: set-to-zero arrives PRESENT (has-bit raised by setter)',
      LDst.hasOpt, 'deserialise must reach the setter, not the field');
  finally
    LMsg.Free;
    LDst.Free;
  end;

  // ── ROUND TRIP: unset stays unset ────────────────────────────────────────
  LMsg := TOptionalMessage.Create;
  LDst := TOptionalMessage.Create;
  try
    LBytes := TProtoSerializer.Serialize(LMsg);
    TProtoSerializer.Deserialize(LBytes, LDst);
    Check('round-trip: unset arrives ABSENT', not LDst.hasOpt);
  finally
    LMsg.Free;
    LDst.Free;
  end;

  // ── the five refusals ────────────────────────────────────────────────────
  LBadW := TBadWritableHas.Create;
  try
    Check('writable has-bit is refused, naming read-only',
      RefusedWithReason(LBadW, 'read-only', LText), LText);
  finally
    LBadW.Free;
  end;

  LBadN := TBadNonBooleanHas.Create;
  try
    Check('non-Boolean has-bit is refused, naming Boolean',
      RefusedWithReason(LBadN, 'boolean', LText), LText);
  finally
    LBadN.Free;
  end;

  LBadO := TBadOrphanHas.Create;
  try
    Check('has-bit with no matching field is refused',
      RefusedWithReason(LBadO, 'no published property', LText), LText);
  finally
    LBadO.Free;
  end;

  LBadR := TBadRepeatedHas.Create;
  try
    Check('has-bit on a repeated field is refused',
      RefusedWithReason(LBadR, 'repeated', LText), LText);
  finally
    LBadR.Free;
  end;

  LBadS := TBadSubmessageHas.Create;
  try
    Check('has-bit on a submessage field is refused',
      RefusedWithReason(LBadS, 'submessage', LText), LText);
  finally
    LBadS.Free;
  end;
end;

// ── 15 · the Struct family (STRUCT-1) ───────────────────────────────────────
//  Nghttp2.Protobuf.WellKnown had NO runtime test at all before this: the
//  classes were asserted only by compiling. That was survivable while every
//  one of them was a bag of scalars with no behaviour. Struct/Value/ListValue
//  have behaviour - ownership, sibling-clearing, two presence mechanisms in
//  one class - so "it compiles" stops being evidence.
//
//  ProtoStructProbe already showed the RUNTIME carries this shape. What it
//  could not show is that the SHIPPED classes are the ones it validated: the
//  probe used its own private copies. This is the same questions asked of the
//  real types.
procedure TestStructFamily;
var
  LS, LS2:  TProtobufStruct;
  LV, LV2:  TProtobufValue;
  LL:       TProtobufListValue;
  LInner:   TProtobufValue;
  LBytes:   TBytes;
begin
  Section('15  the Struct family (STRUCT-1)');

  { A fresh Value has nothing set, and says so through the discriminator
    rather than through six separate reads. }
  LV := TProtobufValue.Create;
  try
    Check('fresh Value reports no member set',
      LV.KindCase = ProtobufValueKindCaseNone);
    Check('fresh Value serialises to zero bytes',
      Length(TProtoSerializer.Serialize(LV)) = 0);
  finally
    LV.Free;
  end;

  { The scalar half: a has-bit, because 0 / "" / False are otherwise
    indistinguishable from absent. Each set to its DEFAULT on purpose - that
    is the case the mechanism exists for. }
  LV := TProtobufValue.Create;
  try
    LV.number_value := 0;
    Check('number_value := 0 raises its has-bit', LV.has_number_value);
    Check('  and reports the case', LV.KindCase = ProtobufValueKindCaseNumber_value);
    Check('  and goes on the wire despite being 0',
      Length(TProtoSerializer.Serialize(LV)) > 0);

    LV.string_value := '';
    Check('setting a sibling CLEARED number_value', not LV.has_number_value);
    Check('  and the case follows the last one set',
      LV.KindCase = ProtobufValueKindCaseString_value);
  finally
    LV.Free;
  end;

  { The message half: nil is the presence signal, and clearing means FREEING.
    A leak here is invisible; a double-free is not, so the check is that this
    survives at all. }
  LV := TProtobufValue.Create;
  try
    LV.struct_value := TProtobufStruct.Create;
    Check('struct_value reports its case',
      LV.KindCase = ProtobufValueKindCaseStruct_value);
    LV.list_value := TProtobufListValue.Create;
    Check('setting list_value freed and cleared struct_value',
      LV.struct_value = nil);
    Check('  and the case moved', LV.KindCase = ProtobufValueKindCaseList_value);
    LV.ClearKind;
    Check('ClearKind returns to None', LV.KindCase = ProtobufValueKindCaseNone);
    Check('  and freed the message member', LV.list_value = nil);
  finally
    LV.Free;
  end;

  { Self-assignment. Without the guard this frees the instance and stores the
    pointer it just freed - the next read touches freed memory. }
  LV := TProtobufValue.Create;
  try
    LV.struct_value := TProtobufStruct.Create;
    LV.struct_value := LV.struct_value;
    Check('re-setting struct_value to ITSELF does not free it',
      LV.struct_value <> nil);
  finally
    LV.Free;
  end;

  { Struct's map accessors - the hand-written twin of what MAP-1 generates. }
  LS := TProtobufStruct.Create;
  try
    Check('fresh Struct is empty', LS.FieldsCount = 0);
    Check('absent key reads as nil', LS.GetFields('nope') = nil);
    Check('absent key reports absent', not LS.HasFields('nope'));

    LInner := TProtobufValue.Create;
    LInner.string_value := 'one';
    LS.SetFields('a', LInner);
    Check('SetFields stores by key', LS.GetFields('a').string_value = 'one');
    Check('  and reports present', LS.HasFields('a'));

    { Replace. The displaced Value is freed by SetFields; an append-only
      implementation passes every check above and still puts a duplicate key
      on the wire. }
    LInner := TProtobufValue.Create;
    LInner.string_value := 'two';
    LS.SetFields('a', LInner);
    Check('re-setting a key REPLACES rather than appends', LS.FieldsCount = 1);
    Check('  and yields the new value', LS.GetFields('a').string_value = 'two');

    LS.ClearFields;
    Check('ClearFields empties the map', LS.FieldsCount = 0);
  finally
    LS.Free;
  end;

  // The whole point: a nested, mutually recursive value round-trips. In JSON
  // terms the value is  { "k": [ 1 ] }  - which as classes is
  // Struct -> entry -> Value -> ListValue -> Value, the cycle that could not
  // be generated and is the reason these four are hand-written.
  LS  := TProtobufStruct.Create;
  LS2 := TProtobufStruct.Create;
  try
    LL := TProtobufListValue.Create;
    LInner := TProtobufValue.Create;
    LInner.number_value := 1;
    LL.Add(LInner);

    LV := TProtobufValue.Create;
    LV.list_value := LL;
    LS.SetFields('k', LV);

    LBytes := TProtoSerializer.Serialize(LS);
    Check('a recursive value encodes to something', Length(LBytes) > 0);

    TProtoSerializer.Deserialize(LBytes, LS2);
    Check('round-trip: one entry survives', LS2.FieldsCount = 1);
    LV2 := LS2.GetFields('k');
    Check('round-trip: the key resolves', LV2 <> nil);
    if LV2 <> nil then
    begin
      Check('round-trip: the case survives the wire',
        LV2.KindCase = ProtobufValueKindCaseList_value);
      Check('round-trip: the list has one element',
        (LV2.list_value <> nil) and (Length(LV2.list_value.values) = 1));
      if (LV2.list_value <> nil) and (Length(LV2.list_value.values) = 1) then
      begin
        Check('round-trip: the innermost number arrives',
          LV2.list_value.values[0].number_value = 1);
        { PRESENCE, not just equality: without the has-bit a decoded 1 and a
          never-set 0 would both compare "fine" for the wrong reason. }
        Check('round-trip: and arrives PRESENT',
          LV2.list_value.values[0].has_number_value);
      end;
    end;
  finally
    LS.Free;    { frees entry -> Value -> ListValue -> Value }
    LS2.Free;   { frees the codec-allocated tree }
  end;

  { NullValue is an ENUM. Asserted here because the emitter has to know that
    too - treated as a message it lands in a destructor and gets Freed. }
  LV := TProtobufValue.Create;
  try
    LV.null_value := NULL_VALUE;
    Check('null_value is settable and raises its bit', LV.has_null_value);
    Check('  and reports its case',
      LV.KindCase = ProtobufValueKindCaseNull_value);
  finally
    LV.Free;
  end;
end;


procedure TestUnsignedWireForm;
var
  LSrc, LDst: TUnsignedMessage;
  LBytes: TBytes;
  LW: TProtoWriter;
  LWant: TBytes;
begin
  Section('12  uint32 / uint64 wire form (FIX-PROTO-UINT32-1)');

  LSrc := TUnsignedMessage.Create;
  LDst := TUnsignedMessage.Create;
  LW   := TProtoWriter.Create;
  try
    LSrc.u32 := Cardinal(3000000000);
    LSrc.u64 := UInt64(1) shl 63;

    LBytes := TProtoSerializer.Serialize(LSrc);

    { Reference bytes built with the wire-level API, which has always had
      WriteUInt32Field/WriteUInt64Field — the defect was that the RTTI layer
      never called them. Comparing the two layers is exactly the assertion. }
    LW.WriteUInt32Field(1, Cardinal(3000000000));
    LW.WriteUInt64Field(2, UInt64(1) shl 63);
    LWant := LW.ToBytes;

    Check('uint32/uint64 bytes match the wire-level encoders',
      BytesEqual(LBytes, LWant),
      'got ' + BytesToHex(LBytes) + '  want ' + BytesToHex(LWant));

    Check('uint32 = 3000000000 did not sign-extend',
      Length(LBytes) = Length(LWant),
      'got ' + IntToStr(Length(LBytes)) + ' bytes, want ' +
      IntToStr(Length(LWant)) + ' - a longer result means sign extension');

    TProtoSerializer.Deserialize(LBytes, LDst);
    Check('uint32 round-trips above MaxInt',
      LDst.u32 = Cardinal(3000000000), IntToStr(Int64(LDst.u32)));
    Check('uint64 round-trips above High(Int64)',
      LDst.u64 = (UInt64(1) shl 63), 'high bit set');
  finally
    LW.Free;
    LSrc.Free;
    LDst.Free;
  end;
end;

// ── Main ───────────────────────────────────────────────────────────────────

// ── 16 · google.protobuf.Any (ANY-1) ────────────────────────────────────────
//  Any is the only well-known type whose payload is a MESSAGE identified by a
//  string that ARRIVES FROM THE PEER. So the checks that matter are not the
//  round trip - that is two fields - but the refusals: what happens when
//  type_url does not say what the caller assumed.
//
//  Registration order matters here, so the registry is cleared first and last.
//  That is the only reason TProtoAnyRegistry.Clear exists.

type
  // One try/except serving many cases. Anonymous procedures would read better,
  // but FPC in Delphi mode refuses them without a modeswitch and nothing else
  // in this repo uses one - so the shape is a case statement rather than a
  // closure. Same reason Horse.CORS is a plain unit-scope procedure.
  TAnyCase = (acEmptyName, acNilClass, acUrlAsName, acDupName, acDupClass,
              acPackNil, acPackUnregistered, acUnpackNewUnknown,
              acUnpackToUnknown);

function AnyRefused(ACase: TAnyCase; AAny: TProtobufAny;
  out AMsg: string): Boolean;
var
  LTmp: TObject;
begin
  Result := False;
  AMsg   := '';
  LTmp   := nil;
  try
    try
      case ACase of
        acEmptyName:
          TProtoAnyRegistry.RegisterType('', TProtobufTimestamp);
        acNilClass:
          TProtoAnyRegistry.RegisterType('x.Y', nil);
        acUrlAsName:
          TProtoAnyRegistry.RegisterType('type.googleapis.com/x.Y',
            TProtobufTimestamp);
        acDupName:
          TProtoAnyRegistry.RegisterType('google.protobuf.Timestamp',
            TProtobufDuration);
        acDupClass:
          TProtoAnyRegistry.RegisterType('other.Name', TProtobufTimestamp);
        acPackNil:
          TProtoAny.Pack(AAny, nil);
        acPackUnregistered:
          begin
            LTmp := TProtobufFieldMask.Create;
            TProtoAny.Pack(AAny, LTmp);
          end;
        acUnpackNewUnknown:
          LTmp := TProtoAny.UnpackNew(AAny);
        acUnpackToUnknown:
          begin
            LTmp := TProtobufTimestamp.Create;
            TProtoAny.UnpackTo(AAny, LTmp);
          end;
      end;
    except
      on E: EProtoAnyError do
      begin
        Result := True;
        AMsg   := E.Message;
      end;
    end;
  finally
    LTmp.Free;
  end;
end;

procedure TestAny;
var
  LAny:  TProtobufAny;
  LTs:   TProtobufTimestamp;
  LDur:  TProtobufDuration;
  LOut:  TObject;
  LOk:   Boolean;
  LMsg:  string;
begin
  Section('16  google.protobuf.Any (ANY-1)');

  TProtoAnyRegistry.Clear;
  Check('a cleared registry is empty', TProtoAnyRegistry.Count = 0);

  { type_url parsing first, because everything below depends on it. Only the
    segment after the LAST slash is significant - the host part is decoration
    and must never be fetched. }
  Check('TypeNameOf strips the conventional prefix',
    TProtoAny.TypeNameOf('type.googleapis.com/google.protobuf.Duration')
      = 'google.protobuf.Duration');
  Check('TypeNameOf accepts a bare name',
    TProtoAny.TypeNameOf('google.protobuf.Duration')
      = 'google.protobuf.Duration');
  Check('TypeNameOf takes the LAST segment, not the first',
    TProtoAny.TypeNameOf('a/b/c.D') = 'c.D');
  Check('TypeNameOf of a trailing slash is empty',
    TProtoAny.TypeNameOf('x/') = '');
  Check('TypeNameOf of empty is empty', TProtoAny.TypeNameOf('') = '');

  // ── registration invariants ──────────────────────────────────────────────
  LOk := AnyRefused(acEmptyName, nil, LMsg);
  Check('an empty proto name is refused', LOk, LMsg);

  LOk := AnyRefused(acNilClass, nil, LMsg);
  Check('a nil class is refused', LOk, LMsg);

  { A type_url where a proto NAME belongs registers happily and then never
    matches an incoming url, because that one gets its prefix stripped and
    this one does not. Silent, so it is refused where the mistake is made. }
  LOk := AnyRefused(acUrlAsName, nil, LMsg);
  Check('a type_url passed as a proto name is refused', LOk, LMsg);
  Check('  and the message shows the name to use instead',
    Pos('x.Y', LMsg) > 0, LMsg);

  TProtoAnyRegistry.RegisterType('google.protobuf.Timestamp', TProtobufTimestamp);
  TProtoAnyRegistry.RegisterType('google.protobuf.Duration',  TProtobufDuration);
  Check('two types registered', TProtoAnyRegistry.Count = 2);

  { Idempotent, so a unit registering in its initialization section stays safe
    if it is pulled in twice. }
  TProtoAnyRegistry.RegisterType('google.protobuf.Timestamp', TProtobufTimestamp);
  Check('re-registering the SAME pair is a no-op', TProtoAnyRegistry.Count = 2);

  LOk := AnyRefused(acDupName, nil, LMsg);
  Check('one name for two classes is refused', LOk, LMsg);

  LOk := AnyRefused(acDupClass, nil, LMsg);
  Check('one class under two names is refused', LOk, LMsg);
  Check('  and neither conflict left a partial entry',
    TProtoAnyRegistry.Count = 2);

  // ── pack / unpack round trip ─────────────────────────────────────────────
  LAny := TProtobufAny.Create;
  try
    LTs := TProtobufTimestamp.Create;
    try
      LTs.seconds := 1700000000;
      LTs.nanos   := 42;
      TProtoAny.Pack(LAny, LTs);
      Check('Pack wrote the conventional type_url',
        LAny.type_url = 'type.googleapis.com/google.protobuf.Timestamp',
        LAny.type_url);
      Check('Pack wrote a non-empty payload', Length(LAny.value) > 0);
      Check('IsType recognises the packed type',
        TProtoAny.IsType(LAny, TProtobufTimestamp));
      Check('IsType rejects a different type',
        not TProtoAny.IsType(LAny, TProtobufDuration));
    finally
      LTs.Free;
    end;

    LTs := TProtobufTimestamp.Create;
    try
      TProtoAny.UnpackTo(LAny, LTs);
      Check('UnpackTo restored seconds', LTs.seconds = 1700000000);
      Check('UnpackTo restored nanos',   LTs.nanos = 42);
    finally
      LTs.Free;
    end;

    { THE security check, and the reason these two types were chosen: Timestamp
      and Duration have IDENTICAL field numbers and types, so decoding one as
      the other SUCCEEDS and is silently wrong. A test using two dissimilar
      messages would pass because the decode happened to fail, proving nothing
      about the type check. Written inline rather than through AnyRefused so
      the destination can be inspected afterwards. }
    LDur := TProtobufDuration.Create;
    try
      LOk  := False;
      LMsg := '';
      try
        TProtoAny.UnpackTo(LAny, LDur);
      except
        on E: EProtoAnyError do
        begin
          LOk  := True;
          LMsg := E.Message;
        end;
      end;
      Check('UnpackTo REFUSES a wire-compatible type mismatch', LOk, LMsg);
      Check('  and the message names both types',
        (Pos('Timestamp', LMsg) > 0) and (Pos('Duration', LMsg) > 0), LMsg);
      Check('  and the destination was left untouched', LDur.seconds = 0);
    finally
      LDur.Free;
    end;

    // UnpackNew resolves through the registry and hands over ownership.
    LOut := TProtoAny.UnpackNew(LAny);
    try
      Check('UnpackNew built the registered class', LOut is TProtobufTimestamp);
      Check('UnpackNew decoded the payload',
        (LOut as TProtobufTimestamp).seconds = 1700000000);
    finally
      LOut.Free;
    end;
  finally
    LAny.Free;
  end;

  // ── refusals on hostile or incomplete input ──────────────────────────────
  LAny := TProtobufAny.Create;
  try
    { An empty type_url is what a default-constructed Any carries, and what a
      peer sends when it wants the payload interpreted by guesswork. }
    LOk := AnyRefused(acUnpackNewUnknown, LAny, LMsg);
    Check('an empty type_url is refused', LOk, LMsg);

    LAny.type_url := 'type.googleapis.com/nobody.Knows';
    LOk := AnyRefused(acUnpackNewUnknown, LAny, LMsg);
    Check('an UNREGISTERED type is refused, not returned as nil', LOk, LMsg);
    Check('  and the message names the unknown type',
      Pos('nobody.Knows', LMsg) > 0, LMsg);

    LOk := AnyRefused(acUnpackToUnknown, LAny, LMsg);
    Check('UnpackTo also refuses an unknown type_url', LOk, LMsg);

    LOk := AnyRefused(acPackNil, LAny, LMsg);
    Check('Pack refuses a nil message', LOk, LMsg);

    { Pack must not invent a type_url from the Pascal class name -
      'TProtobufFieldMask' is not a proto name and no other implementation
      would recognise it. }
    LOk := AnyRefused(acPackUnregistered, LAny, LMsg);
    Check('Pack refuses an unregistered class rather than guessing', LOk, LMsg);
    Check('  and the message says how to register it',
      Pos('RegisterType', LMsg) > 0, LMsg);
  finally
    LAny.Free;
  end;

  { The explicit-name overload needs no registry at all - the path for a
    program that only ever PRODUCES Any values. }
  LAny := TProtobufAny.Create;
  try
    LDur := TProtobufDuration.Create;
    try
      LDur.seconds := 7;
      TProtoAny.Pack(LAny, LDur, 'custom.Thing');
      Check('the explicit-name overload bypasses the registry',
        LAny.type_url = 'type.googleapis.com/custom.Thing', LAny.type_url);
    finally
      LDur.Free;
    end;

    { And an Any is an ordinary submessage to the codec - which is the whole
      claim that ANY-1 needed no codec change. }
    Check('a packed Any serialises through the ordinary path',
      Length(TProtoSerializer.Serialize(LAny)) > 0);
  finally
    LAny.Free;
  end;

  TProtoAnyRegistry.Clear;
end;

begin
  try
    WriteLn('Nghttp2ProtobufTests - M1 wire codec + M1b RTTI serializer');
    WriteLn;

    TestZigZag;
    TestTagPacking;
    TestVarintRoundTrip;
    TestRttiRoundTripPopulated;
    TestRttiRoundTripEmpty;
    TestRttiUnknownFieldSkip;
    TestBytesEqualForKnownEncoding;
    TestAdvancedTypes;
    TestRepeatedRoundTrip;
    TestRepeatedEmptyAndWire;
    TestRepeatedAcceptsUnpackedNumeric;
    TestUnsignedWireForm;
    TestEmptyMessage;
    TestExplicitPresence;
    TestStructFamily;
    TestAny;

    WriteLn;
    WriteLn(Format('[Nghttp2Protobuf] %d passed, %d failed', [GPassCount, GFailCount]));
    if GFailCount > 0 then
    begin
      WriteLn('[Nghttp2Protobuf] Some tests FAILED.');
      ExitCode := 1;
    end
    else
      WriteLn('[Nghttp2Protobuf] All tests PASSED.');
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'FATAL: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;

  WriteLn;
  Write('Press ENTER to exit...');
  ReadLn;
end.
