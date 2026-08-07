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

// ── Destructor for TAdvancedMessage — implementation outside type block ─────

destructor TAdvancedMessage.Destroy;
begin
  Faddress.Free;
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
