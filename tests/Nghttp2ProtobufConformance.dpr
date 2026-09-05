program Nghttp2ProtobufConformance;

// ============================================================================
//  Nghttp2ProtobufConformance — C0a of plans/horse-grpc-codegen.md.
//
//  WHAT THIS IS FOR
//
//  Codegen can only be as correct as the codec beneath it. Before a generator
//  emits a single line, we need EVIDENCE for each proto3 scalar type: does the
//  RTTI serializer encode it the way proto3 says, or not? Section 3 of the plan
//  was written from reading the source; this program replaces that inference
//  with measurement.
//
//  WHY IT IS A SEPARATE PROGRAM, AND REPORT-ONLY
//
//  Several probes here are EXPECTED to deviate. Adding them to
//  Nghttp2ProtobufTests would take stage 1 of build-codec-fpc.sh off its 75/75
//  gate and make a known gap look like a regression. Same precedent as
//  Nghttp2AllocBench: reports, never gates.
//
//  ExitCode is 0 even when deviations are found — a deviation is a finding, not
//  a failure. ExitCode is 1 only for a BROKEN probe (something that should hold
//  and does not) and 2 for an unhandled exception.
//
//  THREE OUTCOMES, and the distinction matters for the plan's decision 6.1:
//
//    CONFORMS  — matches proto3. Safe for the generator to emit.
//    DEVIATES  — encodes, but not as proto3 specifies. THE DANGEROUS CASE:
//                silently wrong bytes on the wire. The generator MUST refuse
//                these types until fixed.
//    REFUSES   — raises instead of encoding. Not conformant either, but it
//                fails loudly, so a user cannot ship corrupt data unknowingly.
//
//  Build (FPC trunk):
//    fpc -MDelphi -O1 -Fu../src Nghttp2ProtobufConformance.dpr
//  Build (Windows):
//    dcc32 -CC -B Nghttp2ProtobufConformance.dpr
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}
{$M+}
{$IF DEFINED(FPC)}
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
  GConforms: Integer = 0;
  GDeviates: Integer = 0;
  GRefuses:  Integer = 0;
  GBroken:   Integer = 0;

// ── Infrastructure ──────────────────────────────────────────────────────────

procedure Section(const S: string);
begin
  WriteLn;
  WriteLn('-- ', S);
end;

procedure Conforms(const AName, ADetail: string);
begin
  WriteLn('  CONFORMS  ', AName);
  if ADetail <> '' then WriteLn('            ', ADetail);
  Inc(GConforms);
end;

{ ARequired / AActual are printed on separate lines because the whole value of
  this program is the gap between them being legible at a glance. }
procedure Deviates(const AName, ARequired, AActual: string);
begin
  WriteLn('  DEVIATES  ', AName);
  WriteLn('            proto3 requires : ', ARequired);
  WriteLn('            we produce      : ', AActual);
  Inc(GDeviates);
end;

procedure Refuses(const AName, AExceptionText: string);
begin
  WriteLn('  REFUSES   ', AName);
  WriteLn('            raised: ', AExceptionText);
  Inc(GRefuses);
end;

procedure Broken(const AName, ADetail: string);
begin
  WriteLn('  BROKEN    ', AName);
  WriteLn('            ', ADetail);
  Inc(GBroken);
end;

function BytesToHex(const B: TBytes): string;
var I: Integer;
begin
  Result := '';
  for I := 0 to Length(B) - 1 do
    Result := Result + IntToHex(B[I], 2) + ' ';
  if Length(Result) > 0 then SetLength(Result, Length(Result) - 1);
end;

{ Reference encoder, deliberately independent of the code under test: the
  canonical proto3 base-128 varint. If this program used TProtoWriter to derive
  its own expectations it would agree with the implementation by construction
  and prove nothing. }
function ExpectedVarint(AValue: UInt64): TBytes;
var
  LTmp: array[0..9] of Byte;
  LLen: Integer;
begin
  LLen := 0;
  repeat
    LTmp[LLen] := Byte(AValue and $7F);
    AValue := AValue shr 7;
    if AValue <> 0 then LTmp[LLen] := LTmp[LLen] or $80;
    Inc(LLen);
  until AValue = 0;
  SetLength(Result, LLen);
  Move(LTmp[0], Result[0], LLen);
end;

{ Strips the leading tag byte so a probe can compare payloads. Every message
  here has exactly one field with tag 1, so the tag is always a single byte. }
function PayloadAfterTag(const ABytes: TBytes): TBytes;
begin
  if Length(ABytes) < 1 then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  SetLength(Result, Length(ABytes) - 1);
  if Length(Result) > 0 then
    Move(ABytes[1], Result[0], Length(Result));
end;

function BytesEqual(const A, B: TBytes): Boolean;
var I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to Length(A) - 1 do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

// ── Probe message classes — one field each, always tag 1 ─────────────────────

type
  [TGrpcMessage]
  TU32Msg = class
  private
    Fv: Cardinal;
  published
    [TProtoMember(1)] property v: Cardinal read Fv write Fv;
  end;

  [TGrpcMessage]
  TU64Msg = class
  private
    Fv: UInt64;
  published
    [TProtoMember(1)] property v: UInt64 read Fv write Fv;
  end;

  [TGrpcMessage]
  TI32Msg = class
  private
    Fv: Integer;
  published
    [TProtoMember(1)] property v: Integer read Fv write Fv;
  end;

  [TGrpcMessage]
  TI64Msg = class
  private
    Fv: Int64;
  published
    [TProtoMember(1)] property v: Int64 read Fv write Fv;
  end;

  TSmallEnum = (seZero, seOne, seTwo);

  [TGrpcMessage]
  TEnumMsg = class
  private
    Fv: TSmallEnum;
  published
    [TProtoMember(1)] property v: TSmallEnum read Fv write Fv;
  end;

  [TGrpcMessage]
  TStrMsg = class
  private
    Fv: string;
  published
    [TProtoMember(1)] property v: string read Fv write Fv;
  end;

// ── 01 · uint32 ─────────────────────────────────────────────────────────────
// The plan's confirmed defect. Nghttp2.Protobuf.Rtti maps tkInteger -> pkInt32
// with no OrdType inspection, and marshals via TValue.AsInteger — so a Cardinal
// above MaxInt cannot survive the trip.

procedure ProbeUInt32;
var
  LMsg: TU32Msg;
  LBytes, LPayload, LWant: TBytes;
  LRt: TU32Msg;
begin
  Section('01  uint32');

  // --- small value, inside Integer range: expected to be fine
  LMsg := TU32Msg.Create;
  try
    LMsg.v := 100;
    try
      LBytes   := TProtoSerializer.Serialize(LMsg);
      LPayload := PayloadAfterTag(LBytes);
      LWant    := ExpectedVarint(100);
      if BytesEqual(LPayload, LWant) then
        Conforms('uint32 = 100', 'payload ' + BytesToHex(LPayload))
      else
        Deviates('uint32 = 100', BytesToHex(LWant), BytesToHex(LPayload));
    except
      on E: Exception do Refuses('uint32 = 100', E.ClassName + ': ' + E.Message);
    end;
  finally
    LMsg.Free;
  end;

  // --- 3 000 000 000: above MaxInt, below High(Cardinal). THE decisive case.
  //     proto3 wants the 5-byte varint of 3000000000. A sign-extended negative
  //     produces 10 bytes and a completely different value on the wire.
  LMsg := TU32Msg.Create;
  try
    LMsg.v := Cardinal(3000000000);
    try
      LBytes   := TProtoSerializer.Serialize(LMsg);
      LPayload := PayloadAfterTag(LBytes);
      LWant    := ExpectedVarint(3000000000);
      if BytesEqual(LPayload, LWant) then
        Conforms('uint32 = 3000000000 (> MaxInt)', 'payload ' + BytesToHex(LPayload))
      else
        Deviates('uint32 = 3000000000 (> MaxInt)',
          IntToStr(Length(LWant)) + ' bytes: ' + BytesToHex(LWant),
          IntToStr(Length(LPayload)) + ' bytes: ' + BytesToHex(LPayload));
    except
      on E: Exception do
        Refuses('uint32 = 3000000000 (> MaxInt)', E.ClassName + ': ' + E.Message);
    end;
  finally
    LMsg.Free;
  end;

  // --- round-trip: even if the wire form is wrong, does the value survive our
  //     own encoder+decoder pair? A symmetric bug round-trips cleanly and is
  //     invisible to every test that does not check bytes — which is precisely
  //     why the byte comparison above exists.
  LMsg := TU32Msg.Create;
  LRt  := TU32Msg.Create;
  try
    LMsg.v := Cardinal(3000000000);
    try
      LBytes := TProtoSerializer.Serialize(LMsg);
      TProtoSerializer.Deserialize(LBytes, LRt);
      if LRt.v = Cardinal(3000000000) then
        Conforms('uint32 = 3000000000 survives our own round-trip',
          'symmetric - but see the byte check above for interop')
      else
        Deviates('uint32 = 3000000000 survives our own round-trip',
          '3000000000', IntToStr(Int64(LRt.v)));
    except
      on E: Exception do
        Refuses('uint32 = 3000000000 round-trip', E.ClassName + ': ' + E.Message);
    end;
  finally
    LMsg.Free;
    LRt.Free;
  end;
end;

// ── 02 · uint64 ─────────────────────────────────────────────────────────────

procedure ProbeUInt64;
var
  LMsg: TU64Msg;
  LBytes, LPayload, LWant: TBytes;
  LBig: UInt64;
begin
  Section('02  uint64');

  // Above High(Int64): AsInt64 cannot represent it.
  LBig := UInt64(High(Int64)) + 1000;

  LMsg := TU64Msg.Create;
  try
    LMsg.v := LBig;
    try
      LBytes   := TProtoSerializer.Serialize(LMsg);
      LPayload := PayloadAfterTag(LBytes);
      LWant    := ExpectedVarint(LBig);
      if BytesEqual(LPayload, LWant) then
        Conforms('uint64 > High(Int64)', 'payload ' + BytesToHex(LPayload))
      else
        Deviates('uint64 > High(Int64)', BytesToHex(LWant), BytesToHex(LPayload));
    except
      on E: Exception do Refuses('uint64 > High(Int64)', E.ClassName + ': ' + E.Message);
    end;
  finally
    LMsg.Free;
  end;
end;

// ── 03 · negative int32 ─────────────────────────────────────────────────────
// proto3 is explicit: a negative int32 is sign-extended to 64 bits, so it is
// ALWAYS ten bytes on the wire. This is the one place where the sign-extension
// the unsigned probes complain about is exactly right.

procedure ProbeNegativeInt32;
var
  LMsg, LRt: TI32Msg;
  LBytes, LPayload, LWant: TBytes;
begin
  Section('03  int32, negative (proto3 sign-extends to 64 bits)');

  LMsg := TI32Msg.Create;
  LRt  := TI32Msg.Create;
  try
    LMsg.v := -1;
    try
      LBytes   := TProtoSerializer.Serialize(LMsg);
      LPayload := PayloadAfterTag(LBytes);
      LWant    := ExpectedVarint(High(UInt64));

      if BytesEqual(LPayload, LWant) then
        Conforms('int32 = -1 is a 10-byte sign-extended varint',
          IntToStr(Length(LPayload)) + ' bytes')
      else
        Deviates('int32 = -1 is a 10-byte sign-extended varint',
          IntToStr(Length(LWant)) + ' bytes: ' + BytesToHex(LWant),
          IntToStr(Length(LPayload)) + ' bytes: ' + BytesToHex(LPayload));

      TProtoSerializer.Deserialize(LBytes, LRt);
      if LRt.v = -1 then
        Conforms('int32 = -1 round-trips', '')
      else
        Broken('int32 = -1 round-trips', 'got ' + IntToStr(LRt.v));
    except
      on E: Exception do Refuses('int32 = -1', E.ClassName + ': ' + E.Message);
    end;
  finally
    LMsg.Free;
    LRt.Free;
  end;
end;

// ── 04 · sint32 / sint64 are unreachable ────────────────────────────────────
// TProtoMemberAttribute.Create takes only a tag, so nothing can ask for zigzag.
// This probe does not test a bug — it PINS the gap, by showing that the bytes
// the RTTI path produces for a negative Integer are not the zigzag bytes any
// sint32 peer will send. If a future attribute overload adds a wire form, this
// probe should start reporting the two as equal for a zigzag-marked field.

procedure ProbeZigZagUnreachable;
var
  LMsg: TI32Msg;
  LPayload, LZigZag: TBytes;
begin
  Section('04  sint32 / sint64 - zigzag not selectable through RTTI');

  LMsg := TI32Msg.Create;
  try
    LMsg.v := -1;
    try
      LPayload := PayloadAfterTag(TProtoSerializer.Serialize(LMsg));
      // What a real sint32 peer puts on the wire for -1: ZigZag(-1) = 1.
      LZigZag  := ExpectedVarint(ZigZagEncode32(-1));

      if BytesEqual(LPayload, LZigZag) then
        Conforms('sint32 = -1 encodes as zigzag',
          'unexpected - the RTTI layer gained a zigzag path')
      else
        Deviates('sint32 = -1 encodes as zigzag',
          'zigzag, ' + IntToStr(Length(LZigZag)) + ' byte(s): ' + BytesToHex(LZigZag),
          'plain varint, ' + IntToStr(Length(LPayload)) + ' bytes: ' + BytesToHex(LPayload));
    except
      on E: Exception do Refuses('sint32 zigzag probe', E.ClassName + ': ' + E.Message);
    end;
  finally
    LMsg.Free;
  end;
end;

// ── 05 · fixed32 / fixed64 are unreachable ──────────────────────────────────
// Same shape as 04. A fixed32 field is wire type 5 and always four payload
// bytes; the RTTI path can only produce a varint.

procedure ProbeFixedUnreachable;
var
  LMsg: TI32Msg;
  LBytes: TBytes;
begin
  Section('05  fixed32 / fixed64 - fixed-width not selectable through RTTI');

  LMsg := TI32Msg.Create;
  try
    LMsg.v := 1;
    try
      LBytes := TProtoSerializer.Serialize(LMsg);
      // Tag byte for field 1: wire type lives in the low 3 bits.
      // pwVarint = 0 gives $08; a fixed32 field would be $0D.
      if Length(LBytes) = 0 then
        Broken('fixed32 selectable',
          'non-default int32 = 1 serialised to zero bytes - probe cannot read a tag')
      else if (LBytes[0] and $07) = 5 then
        Conforms('fixed32 selectable', 'unexpected - RTTI layer gained a fixed path')
      else
        Deviates('fixed32 selectable',
          'wire type 5, tag byte $0D, 4 payload bytes',
          'wire type ' + IntToStr(LBytes[0] and $07) + ', tag byte $' +
            IntToHex(LBytes[0], 2) + ', varint payload');
    except
      on E: Exception do Refuses('fixed32 probe', E.ClassName + ': ' + E.Message);
    end;
  finally
    LMsg.Free;
  end;
end;

// ── 06 · default-valued scalars must be omitted ─────────────────────────────
// Found during M1c.2 and never addressed: proto3 says a field at its default
// value is not serialised. Emitting it is accepted by every decoder, so it is
// wire-legal and harmless for plain messages — but it makes `optional` presence
// impossible to express, and it inflates every message. Codegen must know which
// of the two it is dealing with before it can emit `optional`.

procedure ProbeDefaultOmission;
var
  LI32: TI32Msg;
  LStr: TStrMsg;
  LEnm: TEnumMsg;
  LBytes: TBytes;
begin
  Section('06  proto3 default-value omission');

  LI32 := TI32Msg.Create;
  try
    LI32.v := 0;
    LBytes := TProtoSerializer.Serialize(LI32);
    if Length(LBytes) = 0 then
      Conforms('int32 = 0 is omitted entirely', '')
    else
      Deviates('int32 = 0 is omitted entirely',
        '0 bytes', IntToStr(Length(LBytes)) + ' bytes: ' + BytesToHex(LBytes));
  finally
    LI32.Free;
  end;

  LStr := TStrMsg.Create;
  try
    LStr.v := '';
    LBytes := TProtoSerializer.Serialize(LStr);
    if Length(LBytes) = 0 then
      Conforms('string = "" is omitted entirely', '')
    else
      Deviates('string = "" is omitted entirely',
        '0 bytes', IntToStr(Length(LBytes)) + ' bytes: ' + BytesToHex(LBytes));
  finally
    LStr.Free;
  end;

  LEnm := TEnumMsg.Create;
  try
    LEnm.v := seZero;
    LBytes := TProtoSerializer.Serialize(LEnm);
    if Length(LBytes) = 0 then
      Conforms('enum = 0 is omitted entirely', '')
    else
      Deviates('enum = 0 is omitted entirely',
        '0 bytes', IntToStr(Length(LBytes)) + ' bytes: ' + BytesToHex(LBytes));
  finally
    LEnm.Free;
  end;
end;

// ── 07 · int64 boundary, as a control ───────────────────────────────────────
// Not a suspected gap. It is here so the report contains at least one wide
// signed value that SHOULD conform — if this one deviates too, the problem is
// broader than the unsigned path and the plan's section 3 needs rewriting
// rather than extending.

procedure ProbeInt64Control;
var
  LMsg, LRt: TI64Msg;
  LBytes, LPayload, LWant: TBytes;
begin
  Section('07  int64 = High(Int64)  [control - expected to conform]');

  LMsg := TI64Msg.Create;
  LRt  := TI64Msg.Create;
  try
    LMsg.v := High(Int64);
    try
      LBytes   := TProtoSerializer.Serialize(LMsg);
      LPayload := PayloadAfterTag(LBytes);
      LWant    := ExpectedVarint(UInt64(High(Int64)));

      if BytesEqual(LPayload, LWant) then
        Conforms('int64 = High(Int64)', IntToStr(Length(LPayload)) + ' bytes')
      else
        Deviates('int64 = High(Int64)', BytesToHex(LWant), BytesToHex(LPayload));

      TProtoSerializer.Deserialize(LBytes, LRt);
      if LRt.v = High(Int64) then
        Conforms('int64 = High(Int64) round-trips', '')
      else
        Broken('int64 = High(Int64) round-trips', 'got ' + IntToStr(LRt.v));
    except
      on E: Exception do Refuses('int64 control', E.ClassName + ': ' + E.Message);
    end;
  finally
    LMsg.Free;
    LRt.Free;
  end;
end;

// ── Report ──────────────────────────────────────────────────────────────────

procedure PrintVerdict;
begin
  WriteLn;
  WriteLn('================================================================');
  WriteLn(Format('  CONFORMS %d   DEVIATES %d   REFUSES %d   BROKEN %d',
    [GConforms, GDeviates, GRefuses, GBroken]));
  WriteLn('================================================================');
  WriteLn;
  WriteLn('  Reading this, for plans/horse-grpc-codegen.md decision 6.1:');
  WriteLn;
  WriteLn('    DEVIATES is the dangerous column. Those types encode, and the');
  WriteLn('    bytes are wrong - a peer decodes a different value with no');
  WriteLn('    error anywhere. The generator MUST refuse every proto3 type');
  WriteLn('    listed there until the serializer grows a path for it.');
  WriteLn;
  WriteLn('    REFUSES is survivable. The runtime already fails loudly, so a');
  WriteLn('    user cannot ship corrupt data unknowingly; the generator should');
  WriteLn('    still refuse at build time, which is earlier and cheaper.');
  WriteLn;
  WriteLn('    BROKEN means a probe that should have held did not. Unlike the');
  WriteLn('    other two this is not a known gap - investigate before writing');
  WriteLn('    any generator code.');
  WriteLn;

  if GBroken > 0 then
    ExitCode := 1
  else
    ExitCode := 0;
end;

begin
  try
    WriteLn('Nghttp2ProtobufConformance - proto3 scalar conformance probe');
    WriteLn('C0a of plans/horse-grpc-codegen.md. Report only; deviations are');
    WriteLn('findings, not failures, so ExitCode stays 0 unless a probe BREAKS.');

    ProbeUInt32;
    ProbeUInt64;
    ProbeNegativeInt32;
    ProbeZigZagUnreachable;
    ProbeFixedUnreachable;
    ProbeDefaultOmission;
    ProbeInt64Control;

    PrintVerdict;
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
