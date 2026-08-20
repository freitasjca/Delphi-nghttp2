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
  Nghttp2.Protobuf.Rtti;

var
  GPassCount: Integer = 0;
  GFailCount: Integer = 0;

// ── Test infrastructure ────────────────────────────────────────────────────

procedure Section(const S: string);
begin
  WriteLn;
  WriteLn('── ', S);
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
  Section('04  RTTI serializer — populated message round-trip');
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
  Section('05  RTTI serializer — all-default (proto3 zero-value) round-trip');
  LSrc := TUserMessage.Create;
  LDst := TUserMessage.Create;
  try
    // Leave all fields at Pascal default (0 / '' / False).
    LBytes := TProtoSerializer.Serialize(LSrc);
    // Proto3 default values MAY be omitted; we currently emit them, so the
    // buffer isn't empty — but the sizes are small and it round-trips fine.
    Check('serialize succeeds on default-valued instance', True,
      IntToStr(Length(LBytes)) + ' bytes: ' + BytesToHex(LBytes));

    // Pre-populate LDst so we can prove Deserialize overwrites with the
    // zero-values sent over the wire.
    LDst.id      := 999;
    LDst.name    := 'GARBAGE';
    LDst.active  := True;
    LDst.balance := 999;

    TProtoSerializer.Deserialize(LBytes, LDst);

    Check('empty-message overwrites id to 0',        LDst.id = 0);
    Check('empty-message overwrites name to ""',     LDst.name = '');
    Check('empty-message overwrites active to False', LDst.active = False);
    Check('empty-message overwrites balance to 0',    LDst.balance = 0);
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
  Section('06  RTTI serializer — unknown-field skip (proto3 forward-compat)');
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
  Section('08  M1c — Float/Double/Enum/TBytes/Submessage round-trip');
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
  Section('07  RTTI serializer — known bytes for known input');
  LSrc := TUserMessage.Create;
  try
    LSrc.id := 1;
    // Leave name, active, balance at defaults.
    LBytes := TProtoSerializer.Serialize(LSrc);

    // Expected byte sequence (tags emitted in sort order: 1, 2, 3, 5):
    //   [08 01]        tag 1 varint = 1
    //   [12 00]        tag 2 LEN, length 0 (empty string)
    //   [18 00]        tag 3 varint = 0 (False)
    //   [28 00]        tag 5 varint = 0
    SetLength(LExpected, 8);
    LExpected[0] := $08; LExpected[1] := $01;
    LExpected[2] := $12; LExpected[3] := $00;
    LExpected[4] := $18; LExpected[5] := $00;
    LExpected[6] := $28; LExpected[7] := $00;

    Check('bytes match expected encoding',
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
  Section('09  Repeated fields — round-trip (packed + unpacked)');

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
  Section('10  Repeated fields — empty arrays + wire shape');

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

// ── Main ───────────────────────────────────────────────────────────────────

begin
  try
    WriteLn('Nghttp2ProtobufTests — M1 wire codec + M1b RTTI serializer');
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
