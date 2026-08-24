program Nghttp2ProtobufNegativeTests;

// ============================================================================
//  Nghttp2ProtobufNegativeTests - malformed-input tests for the codec and the
//  gRPC framing layer.
//
//  The positive suite (Nghttp2ProtobufTests) proves well-formed messages round
//  trip. This one proves malformed ones are REJECTED - which is the property
//  that matters for a parser fed from the network, and the one nothing covered
//  until 2026-08-24. It is the "error-path fuzzing" item deferred on the gRPC
//  v0.2 list.
//
//  Each section pins a specific defect found in the audit of that date. All
//  five were reachable from network input; two were memory-safety bugs.
//
//    F1  StripGrpcPrefix let a signed cast defeat its own truncation guard.
//        A prefix of 00 FF FF FF FF made `5 + Integer(LMsgLen)` evaluate to 4,
//        so the check passed, SetLength saw the unsigned value and asked for
//        4 GB, and the Move then read 4 GB past a ten-byte buffer.
//    F2  EnsureBytesAvailable tested `FPos + ACount > Length(FData)`, which
//        wraps negative for ACount near MaxInt - guard bypassed, 2 GB
//        allocation, out-of-bounds Move.
//    F3  The 4 MB message cap existed only on the streaming path. The unary
//        path had none.
//    F4  SkipField advanced FPos for fixed32/fixed64 with no bounds check, so
//        a truncated field pushed FPos past the end, Eof went True, and the
//        decode loop exited reporting SUCCESS on a malformed message.
//    F5  Deserialize recursed per submessage with no depth limit. Bounded by
//        the schema, so only reachable when a message type refers to itself -
//        which is how protobuf expresses trees, i.e. routinely.
//
//  Convention matches Nghttp2ProtobufTests: PASS/FAIL per check, ExitCode is
//  the failure count.
//
//  Build (Windows):
//    dcc64 -CC -B -U"..\src" Nghttp2ProtobufNegativeTests.dpr
//
//  Build (FPC trunk 3.3.1) - the flags matter, both of them:
//    TU=/usr/local/fpc-trunk/lib/fpc/3.3.1/units/x86_64-linux
//    fpc -MDelphi -dNGHTTP2_GRPC_NO_FFI -Fu../src \
//      -Fu$TU/rtl -Fu$TU/rtl-console -Fu$TU/rtl-objpas -Fu$TU/rtl-extra \
//      -Fu$TU/rtl-generics -Fu$TU/fcl-base -Fu$TU/fcl-web -Fu$TU/fcl-json \
//      -Fu$TU/regexpr -Fu$TU/pthreads -Fu$TU/openssl -Fu$TU/fcl-net \
//      -Fu$TU/hash  Nghttp2ProtobufNegativeTests.dpr
//
//  -dNGHTTP2_GRPC_NO_FFI: this suite needs one pure function from the
//  Dispatcher, but the Dispatcher's implementation pulls in Grpc.Registry
//  which pulls in ffi.manager. Nothing here dispatches a gRPC call, so the
//  define severs that and libffi is not needed at all.
//
//  The long -Fu list is not optional. With a shorter one FPC does not report a
//  missing path - it silently resolves ffi.manager from the SYSTEM-WIDE 3.2.2
//  install and fails later with `PPU Invalid Version 207 expecting 208`, which
//  reads like a compiler bug rather than a search-path gap. Take the list from
//  horse-provider-nghttp2/samples/tests/build-fpc.sh rather than hand-rolling
//  it; that script is the authority and already encodes both of these.
//
//  Note: uses zsh array syntax if you script it - zsh does NOT word-split an
//  unquoted $VAR the way bash does, so `fpc $FLAGS ...` passes one giant
//  argument and fails with `Illegal parameter`.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

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
  Nghttp2.Protobuf.Rtti,
  Nghttp2.Grpc.Dispatcher;

var
  GPass: Integer = 0;
  GFail: Integer = 0;

type
  { A plain target. Field 1 only, so any other tag is an UNKNOWN field and
    routes through TProtoReader.SkipField - which is the path F2 and F4 live
    on. }
  [TGrpcMessage]
  TSimple = class
  private
    Fid: Integer;
  published
    [TProtoMember(1)] property id: Integer read Fid write Fid;
  end;

  { Self-referential, which is what makes F5 reachable. Protobuf expresses
    trees and lists exactly this way, so this is an ordinary schema rather
    than a contrived one.

    The destructor matters: on the depth-exceeded path the exception unwinds
    with a partly built chain already attached, and without a cascading free
    the test would leak whatever it managed to allocate. }
  [TGrpcMessage]
  TNestNode = class
  private
    Fv:     Integer;
    Fchild: TNestNode;
  public
    destructor Destroy; override;
  published
    [TProtoMember(1)] property v: Integer read Fv write Fv;
    [TProtoMember(2)] property child: TNestNode read Fchild write Fchild;
  end;

destructor TNestNode.Destroy;
begin
  Fchild.Free;
  inherited;
end;

// ── harness ────────────────────────────────────────────────────────────────

procedure Section(const ATitle: string);
begin
  WriteLn;
  WriteLn('-- ', ATitle);
end;

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

function B(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

const
  OUTCOME_OK          = 0;   // decoded without raising
  OUTCOME_PROTO_ERROR = 1;   // rejected by the codec's own guard
  OUTCOME_OTHER       = 2;   // something else blew up

{ Decode AData into a fresh TSimple and classify the outcome.

  Distinguishing EProtoDecodeError from "any exception" is the whole point, and
  it is not pedantry - it is the difference between a test that works and one
  that does not. Proven on 2026-08-24: the MaxInt-length check below PASSED
  against vulnerable source, because the bypassed guard let SetLength ask for
  2 GB and the ALLOCATOR raised EOutOfMemory. `raised something` reported
  success while the parser was doing exactly the wrong thing; on a machine with
  more headroom the allocation would have succeeded and the out-of-bounds Move
  would have followed, with the test still green.

  A codec that rejects malformed input raises EProtoDecodeError, cheaply, before
  allocating. Anything else - EOutOfMemory, EAccessViolation - means the guard
  did not hold. }
function DecodeOutcome(const AData: TBytes; out AMsg: string): Integer;
var
  LObj: TSimple;
begin
  Result := OUTCOME_OK;
  AMsg := '';
  LObj := TSimple.Create;
  try
    try
      TProtoSerializer.Deserialize(AData, LObj);
    except
      on E: EProtoDecodeError do
      begin
        Result := OUTCOME_PROTO_ERROR;
        AMsg := E.ClassName + ': ' + E.Message;
      end;
      on E: Exception do
      begin
        Result := OUTCOME_OTHER;
        AMsg := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    LObj.Free;
  end;
end;

// ── 01  LEN prefix bounds (F2) ─────────────────────────────────────────────

procedure TestLenBounds;
var
  LOut: Integer;
  LMsg: string;
begin
  Section('01  LEN prefix bounds (F2 - EnsureBytesAvailable overflow)');

  { THE F2 probe. Tag 15, wire type 2 (LEN) = $7A, then varint MaxInt =
    FF FF FF FF 07. Unfixed, FPos + MaxInt wraps negative, the guard passes,
    and SetLength asks for 2 GB.

    It must be rejected BY THE CODEC - OUTCOME_PROTO_ERROR, not merely "an
    exception happened". Against vulnerable source this raises EOutOfMemory
    from the allocator instead, which an any-exception test scores as a pass.
    That is not hypothetical: this exact check passed on unfixed code before
    the assertion was tightened. }
  LOut := DecodeOutcome(B([$7A, $FF, $FF, $FF, $FF, $07]), LMsg);
  Check('LEN length = MaxInt is rejected by the codec, not by the allocator',
        LOut = OUTCOME_PROTO_ERROR,
        Format('outcome %d (%s) - expected EProtoDecodeError', [LOut, LMsg]));

  { Control, not an F2 probe: 15.1 MB (varint 80 C0 C4 07 = 15802368) is large
    but does NOT overflow FPos + ACount, so the ordinary bounds check has always
    caught it. Here to prove the normal path still works. }
  LOut := DecodeOutcome(B([$7A, $80, $C0, $C4, $07]), LMsg);
  Check('LEN length = 15.1 MB with empty remainder is rejected',
        LOut = OUTCOME_PROTO_ERROR, Format('outcome %d (%s)', [LOut, LMsg]));

  // Control: claims 8 bytes, supplies 2. Never broken.
  LOut := DecodeOutcome(B([$7A, $08, $01, $02]), LMsg);
  Check('LEN length overruns the buffer is rejected',
        LOut = OUTCOME_PROTO_ERROR, Format('outcome %d (%s)', [LOut, LMsg]));

  // Control: a well-formed unknown LEN field must still be skipped silently.
  LOut := DecodeOutcome(B([$7A, $02, $AA, $BB, $08, $2A]), LMsg);
  Check('well-formed unknown LEN field still skips cleanly',
        LOut = OUTCOME_OK, LMsg);
end;

// ── 02  varint bounds ──────────────────────────────────────────────────────

procedure TestVarintBounds;
var
  LOut: Integer;
  LMsg: string;
begin
  Section('02  varint bounds (controls - these guards were already correct)');

  // Continuation bit set on every byte, buffer then ends: read runs off.
  LOut := DecodeOutcome(B([$08, $FF, $FF, $FF]), LMsg);
  Check('truncated varint is rejected', LOut = OUTCOME_PROTO_ERROR,
        Format('outcome %d (%s)', [LOut, LMsg]));

  // Eleven continuation bytes - past what a 64-bit varint can hold.
  LOut := DecodeOutcome(B([$08, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF,
                           $FF, $FF, $01]), LMsg);
  Check('varint longer than 10 bytes is rejected', LOut = OUTCOME_PROTO_ERROR,
        Format('outcome %d (%s)', [LOut, LMsg]));
end;

// ── 03  SkipField fixed-width truncation (F4) ──────────────────────────────

procedure TestSkipFieldBounds;
var
  LOut: Integer;
  LMsg: string;
begin
  Section('03  SkipField fixed-width truncation (F4)');

  { Tag 15 wire type 5 (fixed32) = $7D, then only 2 of the 4 bytes.
    Before the fix FPos advanced past the end, Eof went True, and the decode
    loop RETURNED SUCCESS on a malformed message. }
  LOut := DecodeOutcome(B([$7D, $01, $02]), LMsg);
  Check('truncated unknown fixed32 is rejected, not silently accepted',
        LOut = OUTCOME_PROTO_ERROR,
        Format('outcome %d (%s) - F4 has regressed', [LOut, LMsg]));

  // Tag 15 wire type 1 (fixed64) = $79, then only 3 of the 8 bytes.
  LOut := DecodeOutcome(B([$79, $01, $02, $03]), LMsg);
  Check('truncated unknown fixed64 is rejected, not silently accepted',
        LOut = OUTCOME_PROTO_ERROR,
        Format('outcome %d (%s) - F4 has regressed', [LOut, LMsg]));

  // Controls: complete unknown fixed fields must still skip cleanly.
  LOut := DecodeOutcome(B([$7D, $01, $02, $03, $04, $08, $2A]), LMsg);
  Check('complete unknown fixed32 still skips cleanly', LOut = OUTCOME_OK, LMsg);

  LOut := DecodeOutcome(B([$79, $01, $02, $03, $04, $05, $06, $07, $08,
                           $08, $2A]), LMsg);
  Check('complete unknown fixed64 still skips cleanly', LOut = OUTCOME_OK, LMsg);
end;

// ── 04  submessage nesting depth (F5) ──────────────────────────────────────

{ Wraps APayload in ADepth nested `child` submessages, innermost first.
  Each level is tag $12 (field 2, wire type LEN) + varint(length) + payload.
  Lengths stay under 128 for shallow depths, but the varint writer handles
  any size, so this is correct for the 150-deep case too. }
function BuildNested(ADepth: Integer): TBytes;
var
  I: Integer;
  LWriter: TProtoWriter;
  LInner: TBytes;
begin
  SetLength(LInner, 0);
  for I := 1 to ADepth do
  begin
    LWriter := TProtoWriter.Create;
    try
      LWriter.WriteSubmessageField(2, LInner);
      LInner := LWriter.ToBytes;
    finally
      LWriter.Free;
    end;
  end;
  Result := LInner;
end;

{ Same classification as DecodeOutcome, for the self-referential target. A
  depth overrun must surface as EProtoDecodeError; if it arrives as anything
  else - most likely EStackOverflow - the guard did not hold, and on some
  platforms that is not catchable at all. }
function DecodeNestedOutcome(const AData: TBytes; out AMsg: string): Integer;
var
  LObj: TNestNode;
begin
  Result := OUTCOME_OK;
  AMsg := '';
  LObj := TNestNode.Create;
  try
    try
      TProtoSerializer.Deserialize(AData, LObj);
    except
      on E: EProtoDecodeError do
      begin
        Result := OUTCOME_PROTO_ERROR;
        AMsg := E.ClassName + ': ' + E.Message;
      end;
      on E: Exception do
      begin
        Result := OUTCOME_OTHER;
        AMsg := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    LObj.Free;
  end;
end;

procedure TestNestingDepth;
var
  LOut: Integer;
  LMsg: string;
begin
  Section('04  submessage nesting depth (F5)');

  // Well within the limit: must decode.
  LOut := DecodeNestedOutcome(BuildNested(10), LMsg);
  Check('10 levels of nesting decode normally', LOut = OUTCOME_OK, LMsg);

  { Past the limit: must be refused by the depth guard rather than recursing to
    stack exhaustion, which on some platforms is not catchable at all. }
  LOut := DecodeNestedOutcome(BuildNested(150), LMsg);
  Check('150 levels of nesting are rejected by the depth guard',
        LOut = OUTCOME_PROTO_ERROR,
        Format('outcome %d (%s) - F5 has regressed', [LOut, LMsg]));
  Check('the rejection names nesting as the cause',
        (LOut = OUTCOME_PROTO_ERROR) and (Pos('nesting', LowerCase(LMsg)) > 0), LMsg);

  { The depth counter must unwind on the exception path. If it did not, this
    second shallow decode would fail because the thread's counter never
    returned to zero - which is exactly how a naive Inc/Dec without try/finally
    breaks: one malformed message poisons every later decode on that thread. }
  LOut := DecodeNestedOutcome(BuildNested(10), LMsg);
  Check('depth counter unwinds after a rejection', LOut = OUTCOME_OK, LMsg);
end;

// ── 05  gRPC 5-byte frame prefix (F1, F3) ──────────────────────────────────

procedure TestGrpcPrefix;
var
  LBody: TBytes;
  LErr: string;
  LOk: Boolean;
begin
  Section('05  gRPC 5-byte frame prefix (F1, F3)');

  { THE one that mattered. 00 FF FF FF FF claims 4294967295 bytes. Before the
    fix `5 + Integer(LMsgLen)` was 4, the truncation guard passed, SetLength
    asked for 4 GB and the Move read 4 GB past a ten-byte buffer. }
  LOk := StripGrpcPrefix(B([$00, $FF, $FF, $FF, $FF, $01, $02, $03, $04, $05]),
                         LBody, LErr);
  Check('length $FFFFFFFF is rejected (F1)', not LOk,
        'accepted a 4 GB length - F1 has regressed');

  // Just over the 4 MB cap: 0x00400001 = 4194305.
  LOk := StripGrpcPrefix(B([$00, $00, $40, $00, $01, $AA]), LBody, LErr);
  Check('length just over the 4 MB cap is rejected (F3)', not LOk, 'accepted');
  Check('the cap rejection names the maximum',
        (not LOk) and (Pos('maximum', LowerCase(LErr)) > 0), LErr);

  // Honest but truncated: says 100, supplies 3.
  LOk := StripGrpcPrefix(B([$00, $00, $00, $00, $64, $01, $02, $03]), LBody, LErr);
  Check('truncated frame is rejected', not LOk, 'accepted');

  // Compression flag set - unsupported in v0.1.
  LOk := StripGrpcPrefix(B([$01, $00, $00, $00, $01, $AA]), LBody, LErr);
  Check('compression flag is rejected', not LOk, 'accepted');

  // Shorter than the prefix itself.
  LOk := StripGrpcPrefix(B([$00, $00, $00]), LBody, LErr);
  Check('buffer shorter than the 5-byte prefix is rejected', not LOk, 'accepted');

  // Control: a valid frame must still be accepted, with the right body.
  LOk := StripGrpcPrefix(B([$00, $00, $00, $00, $03, $AA, $BB, $CC]), LBody, LErr);
  Check('valid frame is accepted', LOk, LErr);
  Check('valid frame yields the right body length', LOk and (Length(LBody) = 3),
        Format('got %d bytes', [Length(LBody)]));
  Check('valid frame yields the right body bytes',
        LOk and (Length(LBody) = 3) and (LBody[0] = $AA) and
        (LBody[1] = $BB) and (LBody[2] = $CC), 'body mismatch');

  // Control: an empty message (length 0) is legal in gRPC.
  LOk := StripGrpcPrefix(B([$00, $00, $00, $00, $00]), LBody, LErr);
  Check('zero-length frame is accepted', LOk and (Length(LBody) = 0), LErr);
end;

// ───────────────────────────────────────────────────────────────────────────

begin
  WriteLn('Nghttp2ProtobufNegativeTests - malformed input must be REJECTED');
  WriteLn('Pins the five defects found in the 2026-08-24 audit.');
  try
    TestLenBounds;
    TestVarintBounds;
    TestSkipFieldBounds;
    TestNestingDepth;
    TestGrpcPrefix;
  except
    on E: Exception do
    begin
      Inc(GFail);
      WriteLn;
      WriteLn('  FATAL ', E.ClassName, ': ', E.Message);
      WriteLn('  An exception escaped a test body - that is itself a failure,');
      WriteLn('  because every one of these paths is supposed to fail CLEANLY.');
    end;
  end;

  WriteLn;
  WriteLn(Format('[Nghttp2ProtobufNegative] %d passed, %d failed', [GPass, GFail]));
  if GFail = 0 then
    WriteLn('[Nghttp2ProtobufNegative] All tests PASSED.')
  else
    WriteLn('[Nghttp2ProtobufNegative] FAILURES PRESENT.');
  ExitCode := GFail;
end.
