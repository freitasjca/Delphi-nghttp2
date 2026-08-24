unit Nghttp2.Grpc.Dispatcher;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Grpc.Dispatcher
//  Intercepts application/grpc requests, decodes the 5-byte-prefixed
//  protobuf body, invokes the registered handler, encodes the response,
//  and emits the grpc-status trailer.
//  M4a of the horse-provider-nghttp2 gRPC plan (2026-08-07).
//
//  Wire format per gRPC-over-HTTP/2 spec:
//    Request/Response body   = [1B compressed flag][4B BE length][protobuf]
//    Response trailer        = grpc-status: N  (+ optional grpc-message)
//
//  Content-Type recognition: `application/grpc` and `application/grpc+proto`
//  both match (StartsText check). `application/grpc-web` explicitly NOT
//  handled — needs a base64/framing translator, deferred to v0.2.
//
//  Status code mapping:
//    OK           = 0   — normal successful method invocation
//    UNIMPLEMENTED= 12  — path not in registry
//    INTERNAL     = 13  — protobuf decode error, handler exception,
//                        or dispatcher-side framing error
//    (Other codes 1-11, 14-16 available for handlers to signal via custom
//    exception classes; not yet implemented — see plan §M4 Deferred.)
//
//  Extracted from horse-provider-nghttp2 on 2026-08-23. The layer never
//  depended on Horse — only its unit name did; the sole input here is an
//  INghttp2Stream. Any host that owns one can serve gRPC with it.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,          { TBytes - needed in the INTERFACE for StripGrpcPrefix.
                       Pascal has no transitive imports: Nghttp2.Types using
                       SysUtils does not make TBytes visible here. }
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Types;

type
  TGrpcDispatcher = class
  public
    { Call this at the top of your request pipeline, before any per-request
      allocation the host would otherwise do. If the request is
      application/grpc*, this routine fully handles it — writes response and
      trailer — and returns True. Otherwise it returns False and the host
      falls through to its own routing, having paid one content-type lookup.

      No host framework is involved on either side: the only input is an
      INghttp2Stream. horse-provider-nghttp2 calls it from ExecutePipeline
      ahead of its context-pool acquire, which is the shape to copy. }
    class function TryDispatch(const AStream: INghttp2Stream): Boolean; static;
  end;

  { Pre-1.6.0 name. The Horse prefix was a leftover from where this unit was
    written; nothing here has ever depended on Horse. An ALIAS, not a subclass,
    so `is`/`as` and every existing call site keep working unchanged.
    REMOVED IN 2.0.0. }
  THorseGrpcDispatcher = TGrpcDispatcher
    deprecated 'Renamed in 1.6.0 to TGrpcDispatcher. Removed in 2.0.0.';

const
  // Standard gRPC status codes — https://github.com/grpc/grpc/blob/master/doc/statuscodes.md
  GRPC_STATUS_OK               = 0;
  GRPC_STATUS_INVALID_ARGUMENT = 3;
  GRPC_STATUS_NOT_FOUND        = 5;
  GRPC_STATUS_UNIMPLEMENTED    = 12;
  GRPC_STATUS_INTERNAL         = 13;

{ Exposed for the negative-test suite (Nghttp2ProtobufNegativeTests). It parses
  the 5-byte prefix off an attacker-controlled buffer and is the one place a
  malformed length can do damage, so it needs direct tests; reaching it through
  TryDispatch would mean stubbing INghttp2Stream for no added coverage. Pure
  function, no state - exposing it costs nothing. }
function StripGrpcPrefix(const AData: TBytes; out ABody: TBytes;
  out AError: string): Boolean;

implementation

uses
{$IF DEFINED(FPC)}
  { SysUtils moved to the interface uses - TBytes appears in StripGrpcPrefix's
    signature now. Not repeated here. }
  Classes, StrUtils,
{$ELSE}
  System.Classes, System.StrUtils,
{$IFEND}
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti,
  Nghttp2.Grpc.Registry,
  Nghttp2.Grpc.StreamWriter,   { M6a — TGrpcStreamWriter }
  Nghttp2.Grpc.StreamReader;   { M6b — TGrpcStreamReader }

// ── 5-byte prefix framing ──────────────────────────────────────────────────

function StripGrpcPrefix(const AData: TBytes; out ABody: TBytes; out AError: string): Boolean;
var
  LMsgLen: UInt32;
begin
  Result := False;
  if Length(AData) < 5 then
  begin
    AError := 'gRPC frame too short (< 5-byte prefix)';
    Exit;
  end;
  if AData[0] <> 0 then
  begin
    AError := 'gRPC compression flag set (per-message compression not supported in v0.1)';
    Exit;
  end;
  // 4-byte big-endian length prefix
  LMsgLen := (UInt32(AData[1]) shl 24) or
             (UInt32(AData[2]) shl 16) or
             (UInt32(AData[3]) shl 8)  or
              UInt32(AData[4]);

  { FIX-GRPC-LEN-1. The cap MUST be tested before any signed arithmetic on
    LMsgLen, and this ordering is the fix rather than an optimisation.

    The truncation check below used to read `Length(AData) < 5 + Integer(LMsgLen)`.
    LMsgLen is wire-supplied and unsigned, so a prefix of 00 FF FF FF FF makes
    Integer(LMsgLen) = -1 and the expression evaluates to 4 - the guard passes
    for any buffer of 4 bytes or more. SetLength then sees the UNSIGNED value
    and attempts a 4 GB allocation, and if that succeeds the Move reads 4 GB
    past the end of a ten-byte buffer. Remotely triggerable by a ten-byte
    request; an upstream body-size limit does not help, because the body is
    tiny and it is the header that lies.

    Testing the cap first bounds LMsgLen to 4 MB, after which Integer(LMsgLen)
    is provably safe. The same constant already guarded the STREAMING path in
    Nghttp2.Grpc.StreamReader; only the unary path was unprotected, which is
    exactly the two-copies-of-one-format asymmetry the comment below warns
    about. }
  if LMsgLen > GRPC_MAX_MESSAGE_BYTES then
  begin
    AError := Format('gRPC message length %u exceeds the %d-byte maximum',
                     [LMsgLen, GRPC_MAX_MESSAGE_BYTES]);
    Exit;
  end;

  if Length(AData) - 5 < Integer(LMsgLen) then
  begin
    AError := Format('gRPC frame truncated: header says %u bytes, buffer has %d',
                     [LMsgLen, Length(AData) - 5]);
    Exit;
  end;
  SetLength(ABody, LMsgLen);
  if LMsgLen > 0 then
    Move(AData[5], ABody[0], LMsgLen);
  Result := True;
end;

{ Outbound framing lives in Nghttp2.Grpc.StreamWriter as
  WrapGrpcMessage, and both the unary path below and the streaming writer call
  that one function. It was duplicated here originally; a length-prefix defect
  in one copy would have been invisible to whichever suite exercised the other,
  and unary and streaming are covered by different tests. }

// ── Body accumulation from the request stream ──────────────────────────────

function ReadStreamAsBytes(const AStream: TStream): TBytes;
begin
  if (AStream = nil) or (AStream.Size = 0) then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  SetLength(Result, AStream.Size);
  AStream.Position := 0;
  AStream.ReadBuffer(Result[0], AStream.Size);
end;

// ── Error-path helper: emit an empty body + grpc-status trailer ────────────

procedure SendGrpcStatusOnly(
  const AStream: INghttp2Stream;
  AStatus: Integer;
  const AMessage: string);
var
  LEmpty: TBytes;
begin
  AStream.StatusCode := 200;
  AStream.Header['content-type'] := 'application/grpc';
  AStream.AddTrailer('grpc-status', IntToStr(AStatus));
  if AMessage <> '' then
    AStream.AddTrailer('grpc-message', AMessage);
  // Empty framed body per gRPC spec — client sees zero-length message and
  // reads status from trailers. We still emit the 5-byte prefix for a
  // well-formed frame (compression=0, length=0).
  SetLength(LEmpty, 5);
  LEmpty[0] := 0;
  LEmpty[1] := 0;
  LEmpty[2] := 0;
  LEmpty[3] := 0;
  LEmpty[4] := 0;
  AStream.Send(LEmpty);
end;

// ── Main dispatcher ────────────────────────────────────────────────────────

class function TGrpcDispatcher.TryDispatch(const AStream: INghttp2Stream): Boolean;
var
  LContentType: string;
  LPath:        string;
  LInfo:        TGrpcMethodInfo;
  LReqBytes:    TBytes;
  LProtoBytes:  TBytes;
  LError:       string;
  LReqObj:      TObject;
  LRespObj:     TObject;
  LRespProto:   TBytes;
  LFramed:      TBytes;
  LWriter:      IGrpcStreamWriter;   // M6a server-streaming
  LReader:      IGrpcStreamReader;   // M6b client-streaming / bidi
begin
  // 1. Content-type check — only intercept application/grpc*
  LContentType := AStream.Header['content-type'];
  if not StartsText('application/grpc', LContentType) then
    Exit(False);

  // From here on, we own the response — always return True even on error,
  // because we've committed to writing a gRPC-format response.
  Result := True;

  // 2. Registry lookup — 404-equivalent is UNIMPLEMENTED status trailer
  LPath := AStream.Header[':path'];
  if not TGrpcRegistry.TryGet(LPath, LInfo) then
  begin
    SendGrpcStatusOnly(AStream, GRPC_STATUS_UNIMPLEMENTED,
      'method not registered: ' + LPath);
    Exit;
  end;

  { ── M6b inbound-streaming methods ──────────────────────────────────────
    Handled before the body is touched, and necessarily so: this stream was
    dispatched on HEADERS, so AStream.Body is empty and always will be — the
    DATA is arriving into the inbound queue the reader drains. Falling through
    to ReadStreamAsBytes would decode a zero-length body as a malformed frame. }
  if LInfo.IsClientStream then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'application/grpc';

    LReader := TGrpcStreamReader.Create(AStream, LInfo.RequestClass);

    if Assigned(LInfo.BidiHandler) then
    begin
      { Bidirectional — reading and writing are concurrent on one stream, so
        the response side opens up front exactly as it does for M6a. }
      AStream.BeginStreaming;
      LWriter := TGrpcStreamWriter.Create(AStream, LInfo.ResponseClass);
      try
        try
          LInfo.BidiHandler(LReader, LWriter);
          AStream.AddTrailer('grpc-status',  '0');
          AStream.AddTrailer('grpc-message', 'OK');
        except
          on E: Exception do
          begin
            AStream.AddTrailer('grpc-status',  IntToStr(GRPC_STATUS_INTERNAL));
            AStream.AddTrailer('grpc-message', E.ClassName + ': ' + E.Message);
          end;
        end;
      finally
        AStream.EndStreaming;
        LWriter := nil;
        LReader := nil;
      end;
      Exit;
    end;

    { Client-streaming — many in, ONE out. The single response is buffered and
      sent normally, so trailers may be added the ordinary way, before Send. }
    LRespObj := LInfo.ResponseClass.Create;
    try
      try
        LInfo.ClientHandler(LReader, LRespObj);
        LRespProto := TProtoSerializer.Serialize(LRespObj);
      except
        on E: Exception do
        begin
          SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
            E.ClassName + ': ' + E.Message);
          Exit;
        end;
      end;
    finally
      LRespObj.Free;
      LReader := nil;
    end;

    AStream.AddTrailer('grpc-status',  '0');
    AStream.AddTrailer('grpc-message', 'OK');
    AStream.Send(WrapGrpcMessage(LRespProto));
    Exit;
  end;

  // 3. Read + un-frame the request body
  LReqBytes := ReadStreamAsBytes(AStream.Body);
  if not StripGrpcPrefix(LReqBytes, LProtoBytes, LError) then
  begin
    SendGrpcStatusOnly(AStream, GRPC_STATUS_INVALID_ARGUMENT, LError);
    Exit;
  end;

  // 4. Deserialize request, invoke handler, serialize response.
  //    Two dispatch modes per LInfo — see TGrpcMethodInfo in Registry.pas:
  //      - LInfo.Handler        (M4a): dispatcher creates + frees BOTH req & resp;
  //                                    handler mutates the pre-created resp.
  //      - LInfo.InvokeMethod   (M4c): dispatcher creates req; handler creates +
  //                                    returns resp; dispatcher frees BOTH.
  try
    LReqObj := LInfo.RequestClass.Create;
    try
      try
        TProtoSerializer.Deserialize(LProtoBytes, LReqObj);
      except
        on E: Exception do
        begin
          SendGrpcStatusOnly(AStream, GRPC_STATUS_INVALID_ARGUMENT,
            'protobuf decode: ' + E.Message);
          Exit;
        end;
      end;

      { ── M6a server-streaming ───────────────────────────────────────────
        Returns from inside this branch: unlike the two unary paths below it
        emits its own response entirely, because the status trailer cannot be
        composed until the handler has finished producing.

        Order matters and is not interchangeable. Headers and BeginStreaming
        go first so the client sees a response immediately rather than after
        the first message. Trailers go last, which is legal here only because
        a streaming response reads its trailer list at EOF — see AddTrailer in
        Nghttp2.Session.pas. }
      if LInfo.IsServerStream then
      begin
        AStream.StatusCode := 200;
        AStream.Header['content-type'] := 'application/grpc';
        AStream.BeginStreaming;

        LWriter := TGrpcStreamWriter.Create(AStream, LInfo.ResponseClass);
        try
          try
            LInfo.StreamHandler(LReqObj, LWriter);
            AStream.AddTrailer('grpc-status',  '0');
            AStream.AddTrailer('grpc-message', 'OK');
          except
            on E: Exception do
            begin
              { Messages already sent have gone — a stream cannot be recalled.
                Reporting the failure in the trailer is the whole mechanism
                gRPC has for this, and it is why a streaming client must check
                grpc-status after the last message rather than assuming that
                receiving data means success. }
              AStream.AddTrailer('grpc-status',  IntToStr(GRPC_STATUS_INTERNAL));
              AStream.AddTrailer('grpc-message', E.ClassName + ': ' + E.Message);
            end;
          end;
        finally
          { EndStreaming inside the finally, so a handler that escapes by any
            route still closes the stream. Without it the client waits on a
            stream that will never carry END_STREAM. }
          AStream.EndStreaming;
          LWriter := nil;
        end;
        Exit;
      end;

      if Assigned(LInfo.InvokeMethod) then
      begin
        { M4c interface path — invoke user's method, which returns a NEW
          response instance the dispatcher owns. }
        LRespObj := nil;
        try
          try
            LRespObj := LInfo.InvokeMethod(LReqObj);
          except
            on E: Exception do
            begin
              SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
                E.ClassName + ': ' + E.Message);
              Exit;
            end;
          end;
          if LRespObj = nil then
          begin
            SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
              'service method returned nil response');
            Exit;
          end;

          try
            LRespProto := TProtoSerializer.Serialize(LRespObj);
          except
            on E: Exception do
            begin
              SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
                'protobuf encode: ' + E.Message);
              Exit;
            end;
          end;
        finally
          LRespObj.Free;
        end;
      end
      else
      begin
        { M4a procedural path — dispatcher owns both req + resp. }
        LRespObj := LInfo.ResponseClass.Create;
        try
          try
            LInfo.Handler(LReqObj, LRespObj);
          except
            on E: Exception do
            begin
              SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
                E.ClassName + ': ' + E.Message);
              Exit;
            end;
          end;

          try
            LRespProto := TProtoSerializer.Serialize(LRespObj);
          except
            on E: Exception do
            begin
              SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
                'protobuf encode: ' + E.Message);
              Exit;
            end;
          end;
        finally
          LRespObj.Free;
        end;
      end;
    finally
      LReqObj.Free;
    end;
  except
    on E: Exception do
    begin
      SendGrpcStatusOnly(AStream, GRPC_STATUS_INTERNAL,
        'dispatcher fault: ' + E.Message);
      Exit;
    end;
  end;

  // 5. Frame the response, set headers + status-0 trailer, send.
  LFramed := WrapGrpcMessage(LRespProto);
  AStream.StatusCode := 200;
  AStream.Header['content-type'] := 'application/grpc';
  AStream.AddTrailer('grpc-status',  '0');
  AStream.AddTrailer('grpc-message', 'OK');
  AStream.Send(LFramed);
end;

end.
