unit Nghttp2.Grpc.StreamWriter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Grpc.StreamWriter                             (M6a)
//  IGrpcStreamWriter over one HTTP/2 stream — server-streaming RPCs.
//
//  Server-streaming changes nothing about the gRPC wire format. Each message
//  is still `[compressed flag][4-byte big-endian length][payload]`; there are
//  simply many of them concatenated in the DATA stream instead of exactly one,
//  followed by the usual grpc-status trailer.
//
//  So this writer is thin by construction: serialise, frame, push. The
//  transport work was already done by STREAM-1 — PushStreamData handles the
//  cross-thread hand-off and the DEFERRED/resume dance that keeps nghttp2
//  asking for more data. What is added here is the gRPC framing and the
//  ownership contract.
//
//  Not covered: client-streaming and bidirectional RPCs. Both need incremental
//  INBOUND delivery — DATA frames surfaced to the handler as they arrive
//  rather than accumulated into a request body — which does not exist yet.
//  Server-streaming needs only the outbound half, which is why it ships first.
//
//  Extracted from horse-provider-nghttp2 on 2026-08-23. The layer never
//  depended on Horse — only its unit name did; the sole input here is an
//  INghttp2Stream. Any host that owns one can serve gRPC with it.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  Nghttp2.Types,
  Nghttp2.Grpc.Registry;

type
  TGrpcStreamWriter = class(TInterfacedObject, IGrpcStreamWriter)
  private
    FStream:        INghttp2Stream;
    FResponseClass: TClass;
    FCount:         Integer;
  public
    constructor Create(const AStream: INghttp2Stream; AResponseClass: TClass);
    procedure Send(const AResponse: TObject);
    function  IsConnected: Boolean;
    function  Count: Integer;
  end;

{ Frames one protobuf payload as a gRPC message. Shared with the dispatcher's
  unary path so the two cannot drift — a length-prefix bug that showed up in
  only one of them would be invisible to whichever suite covers the other. }
function WrapGrpcMessage(const AProtoBody: TBytes): TBytes;

implementation

uses
  Nghttp2.Protobuf.Rtti;

function WrapGrpcMessage(const AProtoBody: TBytes): TBytes;
var
  LLen: UInt32;
begin
  LLen := UInt32(Length(AProtoBody));
  SetLength(Result, 5 + Integer(LLen));
  Result[0] := 0;                          // compression flag = uncompressed
  Result[1] := Byte((LLen shr 24) and $FF);
  Result[2] := Byte((LLen shr 16) and $FF);
  Result[3] := Byte((LLen shr 8)  and $FF);
  Result[4] := Byte( LLen         and $FF);
  if LLen > 0 then
    Move(AProtoBody[0], Result[5], LLen);
end;

constructor TGrpcStreamWriter.Create(const AStream: INghttp2Stream;
  AResponseClass: TClass);
begin
  inherited Create;
  FStream        := AStream;
  FResponseClass := AResponseClass;
  FCount         := 0;
end;

{ Takes ownership of AResponse — see IGrpcStreamWriter.Send. The try/finally is
  what makes that contract hold even when serialisation raises: a streaming
  handler allocates in a loop, so an exception on message 500 must not leak
  that message on its way out. }
procedure TGrpcStreamWriter.Send(const AResponse: TObject);
var
  LProto: TBytes;
begin
  if AResponse = nil then
    raise EHorseGrpcRegistry.Create('IGrpcStreamWriter.Send: AResponse is nil');

  try
    { Guard rather than trust: a handler that sends the wrong message type
      would otherwise produce a stream the client decodes as garbage, with the
      first sign of trouble arriving as a protobuf error on the far side. }
    if (FResponseClass <> nil) and (not AResponse.InheritsFrom(FResponseClass)) then
      raise EHorseGrpcRegistry.CreateFmt(
        'IGrpcStreamWriter.Send: expected %s, got %s',
        [FResponseClass.ClassName, AResponse.ClassName]);

    LProto := TProtoSerializer.Serialize(AResponse);
  finally
    AResponse.Free;
  end;

  FStream.PushStreamData(WrapGrpcMessage(LProto));
  Inc(FCount);
end;

function TGrpcStreamWriter.IsConnected: Boolean;
begin
  Result := Assigned(FStream) and FStream.IsStreamAlive;
end;

function TGrpcStreamWriter.Count: Integer;
begin
  Result := FCount;
end;

end.
