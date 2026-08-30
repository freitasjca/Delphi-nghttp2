unit Nghttp2.Protobuf.WellKnown;

// ============================================================================
//  Nghttp2.Protobuf.WellKnown — Pascal equivalents of the protobuf
//  "well-known types" that are ORDINARY MESSAGES.
//
//  ── Why this unit exists ──
//
//  These were never a codec limitation. google.protobuf.Timestamp is
//  int64 seconds + int32 nanos; FieldMask is a repeated string. The RTTI
//  serializer has handled shapes like that since M1b. They failed only because
//  nobody had written the Pascal.
//
//  A survey of 7300 googleapis schemas put them at 1504 files, 21% — the
//  single largest remaining gap once nested declarations were flattened, and
//  1395 of those want one of the plain types below.
//
//  ── What is deliberately NOT here ──
//
//  Struct, Value, ListValue, Any, Api, Type, DescriptorProto. Every one needs
//  either `oneof` (no presence model in the serializer) or dynamic type
//  resolution (Any carries a type URL and an opaque payload). ~109 files in
//  the same survey. They stay refused until presence exists, and refusing them
//  is honest where a half-working Any would not be.
//
//  ── Wire compatibility ──
//
//  Field numbers below are from google/protobuf/*.proto and are the contract.
//  A peer built with protoc encodes Timestamp as tag 1 varint + tag 2 varint;
//  so does this. Property NAMES are ours to choose and mean nothing on the
//  wire — see the `value` collision note on TProtobufBytesValue.
// ============================================================================

{$M+}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

// FPC needs the explicit extended-RTTI directive alongside {$M+}, INSIDE the
// interface section — without it TRttiType.GetProperties returns 0 and every
// message here silently serialises as empty. Same rule as every other message
// unit in this repo.
{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Protobuf;

type
  // ── google.protobuf.Timestamp ─────────────────────────────────────────────
  // Seconds since the Unix epoch plus a nanosecond fraction. 681 of 7300
  // googleapis files reference it — the most-used well-known type by a wide
  // margin.
  [TGrpcMessage]
  TProtobufTimestamp = class
  private
    Fseconds: Int64;
    Fnanos:   Integer;
  published
    [TProtoMember(1)] property seconds: Int64   read Fseconds write Fseconds;
    [TProtoMember(2)] property nanos:   Integer read Fnanos   write Fnanos;
  end;

  // ── google.protobuf.Duration ──────────────────────────────────────────────
  // Same shape as Timestamp, different meaning: a signed span rather than a
  // point in time. Kept as its own class because the wire types are distinct
  // and a generator must not substitute one for the other.
  [TGrpcMessage]
  TProtobufDuration = class
  private
    Fseconds: Int64;
    Fnanos:   Integer;
  published
    [TProtoMember(1)] property seconds: Int64   read Fseconds write Fseconds;
    [TProtoMember(2)] property nanos:   Integer read Fnanos   write Fnanos;
  end;

  // ── google.protobuf.FieldMask ─────────────────────────────────────────────
  // A set of field paths, used by partial-update APIs. 590 files.
  [TGrpcMessage]
  TProtobufFieldMask = class
  private
    Fpaths: TArray<string>;
  published
    [TProtoMember(1)] property paths: TArray<string> read Fpaths write Fpaths;
  end;

  // ── google.protobuf.Empty ─────────────────────────────────────────────────
  // Genuinely fieldless, and the reason TProtobufRtti had to learn that a
  // zero-field message can be deliberate: [TGrpcMessage] is what says so.
  // Overwhelmingly used as an RPC return type.
  [TGrpcMessage]
  TProtobufEmpty = class
  end;

  // ── The wrapper types ─────────────────────────────────────────────────────
  // Each boxes one scalar, so that a message field can distinguish "absent"
  // from "present and zero" WITHOUT proto3 explicit presence. That is the
  // whole point of them, and it works here: a nil submessage reference is
  // absent, a non-nil one is present.
  //
  // Which makes these the closest thing to `optional` this library can express
  // today — worth knowing, because `optional` itself remains refused.

  [TGrpcMessage]
  TProtobufDoubleValue = class
  private
    Fvalue: Double;
  published
    [TProtoMember(1)] property value: Double read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufFloatValue = class
  private
    Fvalue: Single;
  published
    [TProtoMember(1)] property value: Single read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufInt64Value = class
  private
    Fvalue: Int64;
  published
    [TProtoMember(1)] property value: Int64 read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufUInt64Value = class
  private
    Fvalue: UInt64;
  published
    [TProtoMember(1)] property value: UInt64 read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufInt32Value = class
  private
    Fvalue: Integer;
  published
    [TProtoMember(1)] property value: Integer read Fvalue write Fvalue;
  end;

  // uint32/uint64 wrappers depend on FIX-PROTO-UINT32-1 (1.10.0). Before that
  // fix a Cardinal above MaxInt sign-extended onto the wire, so these two
  // classes would have been quietly wrong rather than merely absent.
  [TGrpcMessage]
  TProtobufUInt32Value = class
  private
    Fvalue: Cardinal;
  published
    [TProtoMember(1)] property value: Cardinal read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufBoolValue = class
  private
    Fvalue: Boolean;
  published
    [TProtoMember(1)] property value: Boolean read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufStringValue = class
  private
    Fvalue: string;
  published
    [TProtoMember(1)] property value: string read Fvalue write Fvalue;
  end;

  [TGrpcMessage]
  TProtobufBytesValue = class
  private
    Fvalue: TBytes;
  published
    [TProtoMember(1)] property value: TBytes read Fvalue write Fvalue;
  end;

implementation

end.
