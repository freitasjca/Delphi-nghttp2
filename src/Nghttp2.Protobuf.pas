unit Nghttp2.Protobuf;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}
{$M+}   // enable RTTI on attribute classes so consumers with [attr] see full metadata

// ============================================================================
//  Nghttp2.Protobuf
//  Proto3 wire-format encoder/decoder — minimal focused implementation for
//  gRPC-over-HTTP/2 support (M1 of the horse-provider-nghttp2 gRPC plan).
//
//  Scope (proto3 subset — the 90% that gRPC actually uses):
//    Scalar types: int32, int64, uint32, uint64, sint32, sint64 (ZigZag),
//                  fixed32, fixed64, sfixed32, sfixed64, float, double,
//                  bool, string (UTF-8), bytes, enum (encoded as int32)
//    Composite:   repeated (packed encoding for numeric, LEN-prefix for
//                 string/bytes/submessage), submessages (LEN-prefix)
//
//  Excluded (do not add without a real need):
//    Maps (v0.2 — represent as repeated key/value submessages if needed)
//    Oneof (v0.2 — spec is complex, gRPC usage is niche)
//    Groups (deprecated in proto3, never implement)
//
//  API layers:
//    1. Wire primitives (WriteVarint, ReadVarint, WriteFixed32, ...)
//    2. TProtoWriter / TProtoReader — thin OO wrappers over primitives
//    3. RTTI-driven message-class scanner + serialise/deserialise
//       — DEFERRED to M1b (next session). See horse-grpc SKILL.md for the
//       target API: [ProtoMember(N)] attributes on `published` properties,
//       `THorseProtobufRtti` singleton, cross-compiler attribute discovery.
//
//  This file dual-compiles on Delphi (dcc32/dcc64) and FPC/Lazarus (fpc).
//  All I/O goes through TEncoding.UTF8 for string fields regardless of the
//  compiler's default `string` type (Delphi UnicodeString / FPC AnsiString).
//
//  Reference: https://protobuf.dev/programming-guides/encoding/
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes
{$ELSE}
  System.SysUtils, System.Classes
{$IFEND}
  ;

type
  // ── Wire types per proto3 spec ────────────────────────────────────────────
  // Encoded as the low 3 bits of the field-tag varint. Wire types 3 and 4
  // (start_group / end_group) were deprecated in proto3 and are not modelled.
  TProtoWireType = (
    pwVarint   = 0,   // int32, int64, uint32, uint64, sint32, sint64, bool, enum
    pwFixed64  = 1,   // fixed64, sfixed64, double
    pwLen      = 2,   // string, bytes, submessage, packed repeated
    pwFixed32  = 5    // fixed32, sfixed32, float
  );

  // ── Attributes for message-class annotation (RTTI scanner uses these) ─────
  // The scanner itself is deferred to M1b — declaring the attributes now so
  // downstream code (Horse.Grpc.Rtti in M3) can be written against a stable
  // API even before the scanner is implemented.

  { Marks a message class for gRPC serialization. Optional -- the RTTI scanner
    treats any class with [ProtoMember]-annotated properties as a message, but
    this marker allows for explicit registration and future extension. }
  TGrpcMessageAttribute = class(TCustomAttribute)
  public
    constructor Create;
  end;

  { Marks a service interface for gRPC dispatch. Used by Horse.Grpc.Registry
    (M4) to discover services. Not consumed by this unit. }
  TGrpcServiceAttribute = class(TCustomAttribute)
  public
    constructor Create;
  end;

  { Annotates a published property of a message class with its protobuf field
    tag. Field type is inferred from the Pascal type via RTTI (M1b scanner).
    Example:
      [ProtoMember(1)] property id: Integer read Fid write Fid;
      [ProtoMember(2)] property name: string read Fname write Fname; }
  TProtoMemberAttribute = class(TCustomAttribute)
  private
    FTag: Integer;
  public
    constructor Create(ATag: Integer);
    property Tag: Integer read FTag;
  end;

  // ── Exceptions ────────────────────────────────────────────────────────────
  EProtoDecodeError = class(Exception);
  EProtoEncodeError = class(Exception);

  // ── Encoder ───────────────────────────────────────────────────────────────
  { TProtoWriter accumulates encoded bytes in an internal buffer. Call
    ToBytes when done to snapshot the current buffer. Reuse for another
    message by calling Reset. Not thread-safe (one writer per encoding
    session). }
  TProtoWriter = class
  strict private
    FBuffer: TBytesStream;
    procedure WriteRawByte(AByte: Byte); inline;
    procedure WriteRawBytes(const ABytes: PByte; ALen: Integer); inline;
    function GetSize: Int64;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Reset;
    function ToBytes: TBytes;
    property Size: Int64 read GetSize;

    // Raw wire primitives — call these when writing custom field layouts.
    procedure WriteVarint(AValue: UInt64);
    procedure WriteFixed32(AValue: UInt32);
    procedure WriteFixed64(AValue: UInt64);
    procedure WriteLenBytes(const ABytes: TBytes);
    procedure WriteTag(AFieldNumber: Integer; AWireType: TProtoWireType);

    // Typed field emitters — WriteTag + Write<type> in one call.
    // These are what a code-generated (or hand-written) message serializer
    // calls, one per property, in tag order.
    procedure WriteInt32Field(AFieldNumber: Integer; AValue: Int32);
    procedure WriteInt64Field(AFieldNumber: Integer; AValue: Int64);
    procedure WriteUInt32Field(AFieldNumber: Integer; AValue: UInt32);
    procedure WriteUInt64Field(AFieldNumber: Integer; AValue: UInt64);
    procedure WriteSInt32Field(AFieldNumber: Integer; AValue: Int32);   // ZigZag
    procedure WriteSInt64Field(AFieldNumber: Integer; AValue: Int64);   // ZigZag
    procedure WriteFixed32Field(AFieldNumber: Integer; AValue: UInt32);
    procedure WriteFixed64Field(AFieldNumber: Integer; AValue: UInt64);
    procedure WriteSFixed32Field(AFieldNumber: Integer; AValue: Int32);
    procedure WriteSFixed64Field(AFieldNumber: Integer; AValue: Int64);
    procedure WriteBoolField(AFieldNumber: Integer; AValue: Boolean);
    procedure WriteFloatField(AFieldNumber: Integer; AValue: Single);
    procedure WriteDoubleField(AFieldNumber: Integer; AValue: Double);
    procedure WriteEnumField(AFieldNumber: Integer; AValue: Int32);     // same as int32
    procedure WriteStringField(AFieldNumber: Integer; const AValue: string);
    procedure WriteBytesField(AFieldNumber: Integer; const AValue: TBytes);
    procedure WriteSubmessageField(AFieldNumber: Integer; const ABytes: TBytes);
  end;

  // ── Decoder ───────────────────────────────────────────────────────────────
  { TProtoReader consumes a TBytes slice, advancing an internal cursor.
    Not thread-safe (one reader per decoding session).

    Standard decode loop:
      while not R.Eof do
      begin
        if not R.ReadTag(LFieldNumber, LWireType) then Break;
        case LFieldNumber of
          1: FId   := R.ReadVarintAsInt32;
          2: FName := R.ReadString;
          // ...
        else
          R.SkipField(LWireType);   // unknown field — proto3 requires ignore
        end;
      end; }
  TProtoReader = class
  strict private
    FData: TBytes;
    FPos: Integer;
    procedure EnsureBytesAvailable(ACount: Integer);
    function ReadRawByte: Byte; inline;
    procedure ReadRawBytes(ADest: PByte; ALen: Integer);
  public
    constructor Create(const AData: TBytes);

    function Eof: Boolean;
    function Position: Integer;
    function Remaining: Integer;

    { Reads the next field tag. Returns False if Eof, True with the field
      number and wire type otherwise. }
    function ReadTag(out AFieldNumber: Integer; out AWireType: TProtoWireType): Boolean;

    { Skip a field whose tag was just read but whose value is unknown or
      unwanted (proto3 requires unknown fields be preserved silently). }
    procedure SkipField(AWireType: TProtoWireType);

    // Raw wire primitives — mirror the writer.
    function ReadVarint: UInt64;
    function ReadFixed32: UInt32;
    function ReadFixed64: UInt64;
    function ReadLenBytes: TBytes;

    // Typed value readers — call after ReadTag has consumed the tag.
    // Wire-type mismatches raise EProtoDecodeError.
    function ReadVarintAsInt32: Int32;
    function ReadVarintAsInt64: Int64;
    function ReadVarintAsUInt32: UInt32;
    function ReadVarintAsUInt64: UInt64;
    function ReadZigZag32: Int32;
    function ReadZigZag64: Int64;
    function ReadFloat: Single;
    function ReadDouble: Double;
    function ReadBool: Boolean;
    function ReadEnum: Int32;
    function ReadString: string;
    function ReadBytes: TBytes;
  end;

// ── Standalone wire-format helpers ──────────────────────────────────────────
// Exposed for testing + for the RTTI serializer (M1b) which needs them
// outside a TProtoWriter/Reader context.

function ZigZagEncode32(AValue: Int32): UInt32; inline;
function ZigZagDecode32(AValue: UInt32): Int32; inline;
function ZigZagEncode64(AValue: Int64): UInt64; inline;
function ZigZagDecode64(AValue: UInt64): Int64; inline;

function MakeTag(AFieldNumber: Integer; AWireType: TProtoWireType): UInt32; inline;
procedure ParseTag(ATag: UInt32; out AFieldNumber: Integer; out AWireType: TProtoWireType); inline;

implementation

// ── TGrpcMessageAttribute / TGrpcServiceAttribute ───────────────────────────

constructor TGrpcMessageAttribute.Create;
begin
  inherited Create;
end;

constructor TGrpcServiceAttribute.Create;
begin
  inherited Create;
end;

// ── TProtoMemberAttribute ────────────────────────────────────────────────────

constructor TProtoMemberAttribute.Create(ATag: Integer);
begin
  inherited Create;
  if (ATag < 1) or (ATag > 536870911) or ((ATag >= 19000) and (ATag <= 19999)) then
    raise EProtoEncodeError.CreateFmt(
      'ProtoMember tag %d is out of range (must be 1..2^29-1 excluding the 19000-19999 reserved range).', [ATag]);
  FTag := ATag;
end;

// ── Standalone wire-format helpers ──────────────────────────────────────────

// Proto3 ZigZag encoding — the canonical spec formula is
//   (n shl 1) xor (n sar 31)     for 32-bit
//   (n shl 1) xor (n sar 63)     for 64-bit
// where `sar` is ARITHMETIC shift right (sign-extending).
//
// Delphi's `shr` operator is LOGICAL (zero-filling) even on signed operands,
// so `Int32(-1) shr 31` returns 1 rather than $FFFFFFFF. Delphi has no
// built-in `sar` operator. Workaround: build the sign mask explicitly.
//
// The decode path works with `shr` because we operate on UInt32/UInt64
// (unsigned — no sign bit to preserve).

function ZigZagEncode32(AValue: Int32): UInt32;
var
  LSignMask: UInt32;
begin
  if AValue < 0 then LSignMask := UInt32($FFFFFFFF) else LSignMask := 0;
  Result := (UInt32(AValue) shl 1) xor LSignMask;
end;

function ZigZagDecode32(AValue: UInt32): Int32;
begin
  Result := Int32((AValue shr 1) xor (UInt32(0) - (AValue and 1)));
end;

function ZigZagEncode64(AValue: Int64): UInt64;
var
  LSignMask: UInt64;
begin
  if AValue < 0 then LSignMask := UInt64($FFFFFFFFFFFFFFFF) else LSignMask := 0;
  Result := (UInt64(AValue) shl 1) xor LSignMask;
end;

function ZigZagDecode64(AValue: UInt64): Int64;
begin
  Result := Int64((AValue shr 1) xor (UInt64(0) - (AValue and 1)));
end;

function MakeTag(AFieldNumber: Integer; AWireType: TProtoWireType): UInt32;
begin
  Result := (UInt32(AFieldNumber) shl 3) or (UInt32(Ord(AWireType)) and $7);
end;

procedure ParseTag(ATag: UInt32; out AFieldNumber: Integer; out AWireType: TProtoWireType);
begin
  AFieldNumber := Integer(ATag shr 3);
  AWireType := TProtoWireType(ATag and $7);
end;

// ── TProtoWriter ─────────────────────────────────────────────────────────────

constructor TProtoWriter.Create;
begin
  inherited Create;
  FBuffer := TBytesStream.Create;
end;

destructor TProtoWriter.Destroy;
begin
  FBuffer.Free;
  inherited;
end;

procedure TProtoWriter.Reset;
begin
  FBuffer.Size := 0;
  FBuffer.Position := 0;
end;

function TProtoWriter.GetSize: Int64;
begin
  Result := FBuffer.Size;
end;

function TProtoWriter.ToBytes: TBytes;
begin
  // TBytesStream.Bytes returns the internal buffer — copy to trim to actual Size.
  SetLength(Result, FBuffer.Size);
  if FBuffer.Size > 0 then
    Move(FBuffer.Bytes[0], Result[0], FBuffer.Size);
end;

procedure TProtoWriter.WriteRawByte(AByte: Byte);
begin
  FBuffer.WriteBuffer(AByte, 1);
end;

procedure TProtoWriter.WriteRawBytes(const ABytes: PByte; ALen: Integer);
begin
  if ALen > 0 then
    FBuffer.WriteBuffer(ABytes^, ALen);
end;

procedure TProtoWriter.WriteVarint(AValue: UInt64);
begin
  // 7-bit chunks, MSB set on all but the last byte. Max 10 bytes for a 64-bit value.
  while AValue >= $80 do
  begin
    WriteRawByte(Byte((AValue and $7F) or $80));
    AValue := AValue shr 7;
  end;
  WriteRawByte(Byte(AValue));
end;

procedure TProtoWriter.WriteFixed32(AValue: UInt32);
begin
  // Proto3 fixed32 is little-endian on the wire.
  WriteRawBytes(@AValue, 4);
end;

procedure TProtoWriter.WriteFixed64(AValue: UInt64);
begin
  WriteRawBytes(@AValue, 8);
end;

procedure TProtoWriter.WriteLenBytes(const ABytes: TBytes);
begin
  WriteVarint(Length(ABytes));
  if Length(ABytes) > 0 then
    WriteRawBytes(@ABytes[0], Length(ABytes));
end;

procedure TProtoWriter.WriteTag(AFieldNumber: Integer; AWireType: TProtoWireType);
begin
  WriteVarint(MakeTag(AFieldNumber, AWireType));
end;

procedure TProtoWriter.WriteInt32Field(AFieldNumber: Integer; AValue: Int32);
begin
  // proto3 int32 is encoded as a varint. Negative values sign-extend to 10 bytes
  // per the spec — always use the 64-bit representation for safety.
  WriteTag(AFieldNumber, pwVarint);
  WriteVarint(UInt64(Int64(AValue)));
end;

procedure TProtoWriter.WriteInt64Field(AFieldNumber: Integer; AValue: Int64);
begin
  WriteTag(AFieldNumber, pwVarint);
  WriteVarint(UInt64(AValue));
end;

procedure TProtoWriter.WriteUInt32Field(AFieldNumber: Integer; AValue: UInt32);
begin
  WriteTag(AFieldNumber, pwVarint);
  WriteVarint(AValue);
end;

procedure TProtoWriter.WriteUInt64Field(AFieldNumber: Integer; AValue: UInt64);
begin
  WriteTag(AFieldNumber, pwVarint);
  WriteVarint(AValue);
end;

procedure TProtoWriter.WriteSInt32Field(AFieldNumber: Integer; AValue: Int32);
begin
  WriteTag(AFieldNumber, pwVarint);
  WriteVarint(ZigZagEncode32(AValue));
end;

procedure TProtoWriter.WriteSInt64Field(AFieldNumber: Integer; AValue: Int64);
begin
  WriteTag(AFieldNumber, pwVarint);
  WriteVarint(ZigZagEncode64(AValue));
end;

procedure TProtoWriter.WriteFixed32Field(AFieldNumber: Integer; AValue: UInt32);
begin
  WriteTag(AFieldNumber, pwFixed32);
  WriteFixed32(AValue);
end;

procedure TProtoWriter.WriteFixed64Field(AFieldNumber: Integer; AValue: UInt64);
begin
  WriteTag(AFieldNumber, pwFixed64);
  WriteFixed64(AValue);
end;

procedure TProtoWriter.WriteSFixed32Field(AFieldNumber: Integer; AValue: Int32);
begin
  WriteTag(AFieldNumber, pwFixed32);
  WriteFixed32(UInt32(AValue));
end;

procedure TProtoWriter.WriteSFixed64Field(AFieldNumber: Integer; AValue: Int64);
begin
  WriteTag(AFieldNumber, pwFixed64);
  WriteFixed64(UInt64(AValue));
end;

procedure TProtoWriter.WriteBoolField(AFieldNumber: Integer; AValue: Boolean);
begin
  WriteTag(AFieldNumber, pwVarint);
  if AValue then WriteVarint(1) else WriteVarint(0);
end;

procedure TProtoWriter.WriteFloatField(AFieldNumber: Integer; AValue: Single);
var
  U: UInt32;
begin
  WriteTag(AFieldNumber, pwFixed32);
  Move(AValue, U, 4);
  WriteFixed32(U);
end;

procedure TProtoWriter.WriteDoubleField(AFieldNumber: Integer; AValue: Double);
var
  U: UInt64;
begin
  WriteTag(AFieldNumber, pwFixed64);
  Move(AValue, U, 8);
  WriteFixed64(U);
end;

procedure TProtoWriter.WriteEnumField(AFieldNumber: Integer; AValue: Int32);
begin
  // Enums encode identically to int32 on the wire.
  WriteInt32Field(AFieldNumber, AValue);
end;

procedure TProtoWriter.WriteStringField(AFieldNumber: Integer; const AValue: string);
var
  LUtf8: TBytes;
begin
  // Proto3 strings are always UTF-8 on the wire — bypass the compiler's
  // default `string` encoding (UnicodeString on Delphi, AnsiString on FPC).
  WriteTag(AFieldNumber, pwLen);
  LUtf8 := TEncoding.UTF8.GetBytes(AValue);
  WriteLenBytes(LUtf8);
end;

procedure TProtoWriter.WriteBytesField(AFieldNumber: Integer; const AValue: TBytes);
begin
  WriteTag(AFieldNumber, pwLen);
  WriteLenBytes(AValue);
end;

procedure TProtoWriter.WriteSubmessageField(AFieldNumber: Integer; const ABytes: TBytes);
begin
  // Submessages are LEN-prefixed. Caller has already serialised the nested
  // message to bytes (typically via another TProtoWriter).
  WriteTag(AFieldNumber, pwLen);
  WriteLenBytes(ABytes);
end;

// ── TProtoReader ─────────────────────────────────────────────────────────────

constructor TProtoReader.Create(const AData: TBytes);
begin
  inherited Create;
  FData := AData;
  FPos := 0;
end;

function TProtoReader.Eof: Boolean;
begin
  Result := FPos >= Length(FData);
end;

function TProtoReader.Position: Integer;
begin
  Result := FPos;
end;

function TProtoReader.Remaining: Integer;
begin
  Result := Length(FData) - FPos;
end;

procedure TProtoReader.EnsureBytesAvailable(ACount: Integer);
begin
  if FPos + ACount > Length(FData) then
    raise EProtoDecodeError.CreateFmt(
      'Proto decode overrun: needed %d more bytes at position %d, buffer length %d.',
      [ACount, FPos, Length(FData)]);
end;

function TProtoReader.ReadRawByte: Byte;
begin
  EnsureBytesAvailable(1);
  Result := FData[FPos];
  Inc(FPos);
end;

procedure TProtoReader.ReadRawBytes(ADest: PByte; ALen: Integer);
begin
  EnsureBytesAvailable(ALen);
  if ALen > 0 then
    Move(FData[FPos], ADest^, ALen);
  Inc(FPos, ALen);
end;

function TProtoReader.ReadVarint: UInt64;
var
  LByte:  Byte;
  LShift: Integer;
begin
  Result := 0;
  LShift := 0;
  // Max 10 bytes for a 64-bit varint. After 10 bytes the value would overflow
  // even a UInt64 — the last valid byte can only have the low bit set.
  while LShift < 64 do
  begin
    LByte := ReadRawByte;
    Result := Result or (UInt64(LByte and $7F) shl LShift);
    if (LByte and $80) = 0 then Exit;
    Inc(LShift, 7);
  end;
  raise EProtoDecodeError.Create('Varint overflow: more than 10 continuation bytes.');
end;

function TProtoReader.ReadFixed32: UInt32;
begin
  EnsureBytesAvailable(4);
  Move(FData[FPos], Result, 4);
  Inc(FPos, 4);
end;

function TProtoReader.ReadFixed64: UInt64;
begin
  EnsureBytesAvailable(8);
  Move(FData[FPos], Result, 8);
  Inc(FPos, 8);
end;

function TProtoReader.ReadLenBytes: TBytes;
var
  LLen: UInt64;
begin
  LLen := ReadVarint;
  if LLen > UInt64(MaxInt) then
    raise EProtoDecodeError.CreateFmt('LEN prefix %u exceeds MaxInt.', [LLen]);
  EnsureBytesAvailable(Integer(LLen));
  SetLength(Result, Integer(LLen));
  if LLen > 0 then
  begin
    Move(FData[FPos], Result[0], Integer(LLen));
    Inc(FPos, Integer(LLen));
  end;
end;

function TProtoReader.ReadTag(out AFieldNumber: Integer; out AWireType: TProtoWireType): Boolean;
var
  LTag: UInt64;
begin
  if Eof then Exit(False);
  LTag := ReadVarint;
  if LTag > UInt64(High(UInt32)) then
    raise EProtoDecodeError.Create('Field tag exceeds UInt32.');
  ParseTag(UInt32(LTag), AFieldNumber, AWireType);
  Result := True;
end;

procedure TProtoReader.SkipField(AWireType: TProtoWireType);
begin
  case AWireType of
    pwVarint:   ReadVarint;                 // consume without storing
    pwFixed64:  Inc(FPos, 8);
    pwLen:      ReadLenBytes;               // consume length + data
    pwFixed32:  Inc(FPos, 4);
  else
    raise EProtoDecodeError.CreateFmt('Cannot skip unknown wire type %d.', [Ord(AWireType)]);
  end;
end;

function TProtoReader.ReadVarintAsInt32: Int32;
begin
  Result := Int32(ReadVarint);
end;

function TProtoReader.ReadVarintAsInt64: Int64;
begin
  Result := Int64(ReadVarint);
end;

function TProtoReader.ReadVarintAsUInt32: UInt32;
begin
  Result := UInt32(ReadVarint);
end;

function TProtoReader.ReadVarintAsUInt64: UInt64;
begin
  Result := ReadVarint;
end;

function TProtoReader.ReadZigZag32: Int32;
begin
  Result := ZigZagDecode32(UInt32(ReadVarint));
end;

function TProtoReader.ReadZigZag64: Int64;
begin
  Result := ZigZagDecode64(ReadVarint);
end;

function TProtoReader.ReadFloat: Single;
var
  U: UInt32;
begin
  U := ReadFixed32;
  Move(U, Result, 4);
end;

function TProtoReader.ReadDouble: Double;
var
  U: UInt64;
begin
  U := ReadFixed64;
  Move(U, Result, 8);
end;

function TProtoReader.ReadBool: Boolean;
begin
  Result := ReadVarint <> 0;
end;

function TProtoReader.ReadEnum: Int32;
begin
  Result := ReadVarintAsInt32;
end;

function TProtoReader.ReadString: string;
var
  LBytes: TBytes;
begin
  LBytes := ReadLenBytes;
  Result := TEncoding.UTF8.GetString(LBytes);
end;

function TProtoReader.ReadBytes: TBytes;
begin
  Result := ReadLenBytes;
end;

end.
