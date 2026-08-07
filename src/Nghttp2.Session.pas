unit Nghttp2.Session;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Session
//  Per-connection HTTP/2 session wrapper — pure byte-in / byte-out.
//
//  This unit knows nothing about sockets. The Server unit will:
//    1) create a TNghttp2Session per accepted connection
//    2) recv() bytes → session.FeedIncoming(buf, len)
//    3) loop: session.ExtractOutgoing(out buf) → send(buf)
//    4) callback OnRequest fires synchronously inside FeedIncoming when a
//       stream reaches END_STREAM — the handler pushes the response into
//       the INghttp2Stream, which triggers nghttp2_submit_response, which
//       queues DATA frames for the next ExtractOutgoing round
//    5) session.WantRead / WantWrite gate the loop; both False → close
//
//  Concurrency model in v1: one thread per connection (the server owns it).
//  Streams multiplex within that one thread — Horse pipeline dispatch is
//  synchronous per stream. Applications needing per-stream parallelism can
//  offload to the WorkerPool from inside their route handler.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections,
{$ENDIF}
  Nghttp2.Native,
  Nghttp2.Types;

type
  TNghttp2Session = class;   // forward

  // ─── Connection info (peer + local port) ────────────────────────────────
  TNghttp2ConnectionState = class(TInterfacedObject, INghttp2Connection)
  private
    FPeerAddr:  string;
    FLocalPort: Integer;
  public
    constructor Create(const APeerAddr: string; ALocalPort: Integer);
    { INghttp2Connection }
    function GetPeerAddr: string;
    function GetLocalPort: Integer;
  end;

  // ─── One HTTP/2 stream (request + accumulated body + staged response) ──
  //     TInterfacedPersistent (not TInterfacedObject) — refcount is disabled
  //     so the owning Session's TObjectDictionary can free us on stream close
  //     without racing with any INghttp2Stream interface references still
  //     held by the request bridge (they all live inside one synchronous
  //     dispatch call stack).
  TNghttp2StreamState = class(TInterfacedPersistent, INghttp2Stream)
  private
    FStreamId:          Int32;
    FSession:           TNghttp2Session;         // weak — session owns us
    FConnection:        INghttp2Connection;      // interface ref (shared with session)
    FRequestHeaders:    TDictionary<string, string>;   // lower-cased names
    FRequestBody:       TMemoryStream;
    FStatus:            Integer;
    FResponseHeaders:   TStringList;             // 'name=value' in emit order
    FResponseTrailers:  TStringList;             // 'name=value' — M2b, HTTP/2 trailers via submit_trailer
    FResponseBody:      TMemoryStream;
    FResponseBodyPos:   NativeInt;
    FResponseStream:    TStream;                 // set by SendStream — WEAK
    FResponseSubmitted: Boolean;
    procedure DoSubmitResponse;
    procedure DoSubmitTrailers;
  public
    constructor Create(ASession: TNghttp2Session; AStreamId: Int32;
      const AConnection: INghttp2Connection);
    destructor  Destroy; override;

    // Called by the session's HPACK callback for every request header
    procedure AddRequestHeader(const AName, AValue: string);
    // Called by the session's on_data_chunk_recv callback
    procedure AppendRequestBody(const AData: PByte; ALen: NativeUInt);

    property StreamId: Int32 read FStreamId;
    // Read-only accessor for the response data-provider read callback
    property ResponseBody:    TMemoryStream read FResponseBody;
    property ResponseStream:  TStream       read FResponseStream;

    { INghttp2Stream }
    function  GetHeader(const AName: string): string;
    procedure SetHeader(const AName, AValue: string);
    procedure AddHeader(const AName, AValue: string);
    function  GetBody: TStream;
    function  GetConnection: INghttp2Connection;
    procedure PopulateRequestHeadersInto(const ADest: TStrings);
    function  GetStatusCode: Integer;
    procedure SetStatusCode(const AValue: Integer);
    procedure Send(const AData: TBytes);
    procedure SendStream(const ASource: TStream);

    // ─── HTTP/2 trailer (M2b) — see INghttp2Stream contract ───────────────
    procedure AddTrailer(const AName, AValue: string);
  end;

  // ─── Session — owns the nghttp2_session and the stream table ────────────
  // Plain procedure type (not `of object`) — accepts unit-scope trampolines.
  // Class methods on THorseProviderNghttp2 wrap into such a trampoline; see
  // ExecutePipelineTrampoline in Horse.Provider.Nghttp2.pas.
  TNghttp2OnRequestProc = procedure(const AStream: INghttp2Stream);

  TNghttp2Session = class
  private
    FNativeSession: Pnghttp2_session;
    FCallbacks:     Pnghttp2_session_callbacks;
    FStreams:       TObjectDictionary<Int32, TNghttp2StreamState>;
    FConnection:    INghttp2Connection;
    FOnRequest:     TNghttp2OnRequestProc;

    procedure BuildCallbacks;
    procedure SendInitialSettings;
  public
    constructor Create(const AConnection: INghttp2Connection);
    destructor  Destroy; override;

    // Byte pump — used by the server's per-connection thread
    function  FeedIncoming(const AData: PByte; ALen: NativeUInt): NativeInt;
    // Returns the number of bytes now available in ABuf, or 0 if none pending,
    // or negative on error (see NGHTTP2_ERR_*).
    function  ExtractOutgoing(out ABuf: PByte): NativeInt;
    function  WantRead:  Boolean;
    function  WantWrite: Boolean;
    procedure Terminate(AErrorCode: UInt32);

    property NativeSession: Pnghttp2_session   read FNativeSession;
    property OnRequest:     TNghttp2OnRequestProc read FOnRequest write FOnRequest;

    // Called by the cdecl trampolines below — these are the real handlers
    function DoBeginHeaders(const AFrame: Pnghttp2_frame): Integer;
    function DoHeader(const AFrame: Pnghttp2_frame;
      const AName, AValue: PByte; ANameLen, AValueLen: NativeUInt): Integer;
    function DoFrameRecv(const AFrame: Pnghttp2_frame): Integer;
    function DoDataChunk(AStreamId: Int32; AFlags: Byte;
      const AData: PByte; ALen: NativeUInt): Integer;
    function DoStreamClose(AStreamId: Int32; AErrorCode: UInt32): Integer;
  end;

implementation

// ─── Byte-buffer → string helper ─────────────────────────────────────────
//     HTTP/2 headers are opaque byte strings; ASCII in practice. We route
//     through AnsiString for a byte-exact copy, then let Pascal's implicit
//     conversion promote to UnicodeString on Delphi 2009+.
function BytesToStr(ABuf: PByte; ALen: NativeUInt): string;
var
  LAnsi: AnsiString;
begin
  if ALen = 0 then Exit('');
  SetLength(LAnsi, ALen);
  Move(ABuf^, LAnsi[1], ALen);
  Result := string(LAnsi);
end;

// ─── Data-provider read_callback — outgoing DATA frame source ────────────
//     Registered per-stream via the Tnghttp2_data_provider passed to
//     nghttp2_submit_response. The source pointer is Pnghttp2_data_source;
//     its ptr field is the TNghttp2StreamState we set at submit time.
function ReadResponseBodyCallback(
  session:    Pnghttp2_session;
  stream_id:  Int32;
  buf:        PByte;
  length:     NativeUInt;
  data_flags: PUInt32;
  source:     Pointer;
  user_data:  Pointer): NativeInt; cdecl;
var
  LState:       TNghttp2StreamState;
  LRemaining:   NativeInt;
  LToRead:      NativeInt;
  LHasTrailers: Boolean;
begin
  LState := TNghttp2StreamState(Pnghttp2_data_source(source)^.ptr);

  { M2b: when the response has trailers pending, EOF must NOT auto-close the
    stream — nghttp2 emits the trailer HEADERS frame with END_STREAM itself
    (queued by nghttp2_submit_trailer in DoSubmitTrailers).

    FIX-CALLBACK-TRAILER (2026-08-07): when trailers are pending we MUST use
    a two-step pattern — return bytes with NO flags on the first invocation,
    then return 0 with EOF|NO_END_STREAM on the second. Combining >0 bytes
    with EOF|NO_END_STREAM in a single invocation causes libnghttp2 to skip
    the DATA frame entirely when a trailer HEADERS frame is queued behind
    it — client receives empty body and grpcurl reports "EOF".

    For streams WITHOUT trailers the single-shot EOF (bytes + EOF in one
    invocation) still works and is preserved — it's the historical path
    validated by the 94/94 nghttp2 test suite. }
  LHasTrailers := (LState.FResponseTrailers <> nil) and (LState.FResponseTrailers.Count > 0);

  if LState.ResponseStream <> nil then
  begin
    LRemaining := NativeInt(LState.ResponseStream.Size) - NativeInt(LState.ResponseStream.Position);
    if LRemaining <= 0 then
    begin
      if LHasTrailers then
        data_flags^ := NGHTTP2_DATA_FLAG_EOF or NGHTTP2_DATA_FLAG_NO_END_STREAM
      else
        data_flags^ := NGHTTP2_DATA_FLAG_EOF;
      Exit(0);
    end;
    LToRead := LRemaining;
    if NativeInt(length) < LToRead then
      LToRead := NativeInt(length);
    LToRead := LState.ResponseStream.Read(buf^, LToRead);
    { Only set EOF in the same invocation as data when there are NO trailers.
      With trailers, force a follow-up 0-length call to carry EOF cleanly. }
    if (not LHasTrailers) and (LState.ResponseStream.Position >= LState.ResponseStream.Size) then
      data_flags^ := NGHTTP2_DATA_FLAG_EOF;
    Result := LToRead;
  end
  else
  begin
    LRemaining := NativeInt(LState.ResponseBody.Size) - LState.FResponseBodyPos;
    if LRemaining <= 0 then
    begin
      if LHasTrailers then
        data_flags^ := NGHTTP2_DATA_FLAG_EOF or NGHTTP2_DATA_FLAG_NO_END_STREAM
      else
        data_flags^ := NGHTTP2_DATA_FLAG_EOF;
      Exit(0);
    end;
    LToRead := LRemaining;
    if NativeInt(length) < LToRead then
      LToRead := NativeInt(length);
    LState.ResponseBody.Position := LState.FResponseBodyPos;
    LState.ResponseBody.Read(buf^, LToRead);
    Inc(LState.FResponseBodyPos, LToRead);
    if (not LHasTrailers) and (LState.FResponseBodyPos >= NativeInt(LState.ResponseBody.Size)) then
      data_flags^ := NGHTTP2_DATA_FLAG_EOF;
    Result := LToRead;
  end;
end;

// ─── Session-callback cdecl trampolines ──────────────────────────────────
//     Each unpacks user_data (a TNghttp2Session cast) and dispatches to
//     the method-form handler. Return 0 for success or a negative
//     NGHTTP2_ERR_* code to abort the session.

function OnBeginHeadersCB(session: Pnghttp2_session;
  const frame: Pnghttp2_frame; user_data: Pointer): Integer; cdecl;
begin
  Result := TNghttp2Session(user_data).DoBeginHeaders(frame);
end;

function OnHeaderCB(session: Pnghttp2_session;
  const frame: Pnghttp2_frame;
  const name:  PByte; namelen:  NativeUInt;
  const value: PByte; valuelen: NativeUInt;
  flags: Byte; user_data: Pointer): Integer; cdecl;
begin
  Result := TNghttp2Session(user_data).DoHeader(frame, name, value, namelen, valuelen);
end;

function OnFrameRecvCB(session: Pnghttp2_session;
  const frame: Pnghttp2_frame; user_data: Pointer): Integer; cdecl;
begin
  Result := TNghttp2Session(user_data).DoFrameRecv(frame);
end;

function OnDataChunkCB(session: Pnghttp2_session; flags: Byte;
  stream_id: Int32; const data: PByte; len: NativeUInt;
  user_data: Pointer): Integer; cdecl;
begin
  Result := TNghttp2Session(user_data).DoDataChunk(stream_id, flags, data, len);
end;

function OnStreamCloseCB(session: Pnghttp2_session; stream_id: Int32;
  error_code: UInt32; user_data: Pointer): Integer; cdecl;
begin
  Result := TNghttp2Session(user_data).DoStreamClose(stream_id, error_code);
end;

// ============================================================================
// TNghttp2ConnectionState
// ============================================================================

constructor TNghttp2ConnectionState.Create(const APeerAddr: string; ALocalPort: Integer);
begin
  inherited Create;
  FPeerAddr  := APeerAddr;
  FLocalPort := ALocalPort;
end;

function TNghttp2ConnectionState.GetPeerAddr: string;
begin
  Result := FPeerAddr;
end;

function TNghttp2ConnectionState.GetLocalPort: Integer;
begin
  Result := FLocalPort;
end;

// ============================================================================
// TNghttp2StreamState
// ============================================================================

constructor TNghttp2StreamState.Create(ASession: TNghttp2Session; AStreamId: Int32;
  const AConnection: INghttp2Connection);
begin
  inherited Create;
  FSession           := ASession;
  FStreamId          := AStreamId;
  FConnection        := AConnection;
  FRequestHeaders    := TDictionary<string, string>.Create;
  FRequestBody       := TMemoryStream.Create;
  FStatus            := 0;
  FResponseHeaders   := TStringList.Create;
  FResponseTrailers  := nil;   // M2b: lazy-allocated on first AddTrailer
  FResponseBody      := TMemoryStream.Create;
  FResponseBodyPos   := 0;
  FResponseStream    := nil;
  FResponseSubmitted := False;
end;

destructor TNghttp2StreamState.Destroy;
begin
  FRequestHeaders.Free;
  FRequestBody.Free;
  FResponseHeaders.Free;
  FResponseTrailers.Free;   // nil-safe (M2b)
  FResponseBody.Free;
  // FResponseStream is non-owning; do not free
  // FConnection is an interface — released automatically
  inherited;
end;

// ── M2b: HTTP/2 trailer (see INghttp2Stream.AddTrailer) ────────────────────

procedure TNghttp2StreamState.AddTrailer(const AName, AValue: string);
begin
  if FResponseSubmitted then
    raise Exception.Create('AddTrailer: trailers must be added BEFORE Send/SendStream');
  if FResponseTrailers = nil then
    FResponseTrailers := TStringList.Create;
  // HTTP/2 wire format requires lowercase names.  Store as name=value like
  // FResponseHeaders — DoSubmitTrailers walks the list into an nv-pair array.
  FResponseTrailers.Add(LowerCase(AName) + '=' + AValue);
end;

procedure TNghttp2StreamState.AddRequestHeader(const AName, AValue: string);
begin
  // HTTP/2 wire format guarantees lower-case names; store as-received.
  FRequestHeaders.AddOrSetValue(AName, AValue);
end;

procedure TNghttp2StreamState.AppendRequestBody(const AData: PByte; ALen: NativeUInt);
begin
  if ALen = 0 then Exit;
  FRequestBody.WriteBuffer(AData^, ALen);
end;

function TNghttp2StreamState.GetHeader(const AName: string): string;
begin
  if not FRequestHeaders.TryGetValue(LowerCase(AName), Result) then
    Result := '';
end;

procedure TNghttp2StreamState.SetHeader(const AName, AValue: string);
var
  LName: string;
  I:     Integer;
begin
  LName := LowerCase(AName);
  // Idempotent replace: if already emitted, overwrite in place
  for I := 0 to FResponseHeaders.Count - 1 do
    if SameText(FResponseHeaders.Names[I], LName) then
    begin
      FResponseHeaders.ValueFromIndex[I] := AValue;
      Exit;
    end;
  FResponseHeaders.Add(LName + '=' + AValue);
end;

procedure TNghttp2StreamState.AddHeader(const AName, AValue: string);
begin
  // Duplicate-allowing counterpart to SetHeader. Used by the response bridge
  // for Set-Cookie (RFC 6265 §3) and any other header that legally repeats.
  // libnghttp2 emits one HPACK nv-pair per FResponseHeaders entry, so two
  // 'set-cookie' rows here become two separate response headers on the wire.
  FResponseHeaders.Add(LowerCase(AName) + '=' + AValue);
end;

function TNghttp2StreamState.GetBody: TStream;
begin
  // Rewind for downstream readers (RawRequest.GetContent, ReadBody)
  FRequestBody.Position := 0;
  Result := FRequestBody;
end;

function TNghttp2StreamState.GetConnection: INghttp2Connection;
begin
  Result := FConnection;
end;

procedure TNghttp2StreamState.PopulateRequestHeadersInto(const ADest: TStrings);
var
  LPair: TPair<string, string>;
begin
  ADest.Clear;
  for LPair in FRequestHeaders do
    ADest.Add(LPair.Key + '=' + LPair.Value);
end;

function TNghttp2StreamState.GetStatusCode: Integer;
begin
  Result := FStatus;
end;

procedure TNghttp2StreamState.SetStatusCode(const AValue: Integer);
begin
  FStatus := AValue;
end;

procedure TNghttp2StreamState.Send(const AData: TBytes);
begin
  FResponseBody.Clear;
  if Length(AData) > 0 then
    FResponseBody.WriteBuffer(AData[0], Length(AData));
  FResponseStream := nil;
  DoSubmitResponse;
end;

procedure TNghttp2StreamState.SendStream(const ASource: TStream);
begin
  FResponseBody.Clear;
  FResponseStream := ASource;
  DoSubmitResponse;
end;

procedure TNghttp2StreamState.DoSubmitResponse;
var
  LNvs:                 array of Tnghttp2_nv;
  LNameBufs, LValueBufs: array of RawByteString;
  I, LCount:            Integer;
  LProvider:            Tnghttp2_data_provider;
  LStatusVal:           Integer;
begin
  if FResponseSubmitted then Exit;
  FResponseSubmitted := True;

  LStatusVal := FStatus;
  if LStatusVal = 0 then LStatusVal := 200;

  LCount := FResponseHeaders.Count + 1;   // +1 for :status
  SetLength(LNvs,       LCount);
  SetLength(LNameBufs,  LCount);
  SetLength(LValueBufs, LCount);

  // :status pseudo-header — MUST be first per RFC 7540 §8.1.2.1
  LNameBufs[0]      := ':status';
  LValueBufs[0]     := RawByteString(IntToStr(LStatusVal));
  LNvs[0].name      := PByte(PAnsiChar(LNameBufs[0]));
  LNvs[0].value     := PByte(PAnsiChar(LValueBufs[0]));
  LNvs[0].namelen   := Length(LNameBufs[0]);
  LNvs[0].valuelen  := Length(LValueBufs[0]);
  LNvs[0].flags     := NGHTTP2_NV_FLAG_NONE;

  // Response headers
  for I := 0 to FResponseHeaders.Count - 1 do
  begin
    LNameBufs[I + 1]     := RawByteString(FResponseHeaders.Names[I]);
    LValueBufs[I + 1]    := RawByteString(FResponseHeaders.ValueFromIndex[I]);
    LNvs[I + 1].name     := PByte(PAnsiChar(LNameBufs[I + 1]));
    LNvs[I + 1].value    := PByte(PAnsiChar(LValueBufs[I + 1]));
    LNvs[I + 1].namelen  := Length(LNameBufs[I + 1]);
    LNvs[I + 1].valuelen := Length(LValueBufs[I + 1]);
    LNvs[I + 1].flags    := NGHTTP2_NV_FLAG_NONE;
  end;

  // Data provider — Self is captured through source.ptr; the read_callback
  // is our top-level cdecl above. Position tracking uses FResponseBodyPos
  // (for in-memory body) or FResponseStream.Position (for streamed body).
  FResponseBodyPos := 0;
  if FResponseStream <> nil then
    FResponseStream.Position := 0;

  LProvider.source.ptr    := Self;
  LProvider.read_callback := @ReadResponseBodyCallback;

  nghttp2_submit_response(
    FSession.NativeSession, FStreamId,
    @LNvs[0], NativeUInt(LCount),
    @LProvider);

  // LNameBufs / LValueBufs / LProvider go out of scope on return.
  // NGHTTP2_NV_FLAG_NONE means nghttp2 copies name+value internally.
  // nghttp2 also copies the data_provider struct (docs: "safe to reuse or
  // free the memory used by data_prd after this function returns").

  { M2b: HTTP/2 trailers.  If AddTrailer was called before Send/SendStream,
    queue the trailer HEADERS frame now — nghttp2 emits it AFTER the data
    provider signals EOF with NGHTTP2_DATA_FLAG_NO_END_STREAM (see the
    ReadResponseBodyCallback EOF branches). }
  if (FResponseTrailers <> nil) and (FResponseTrailers.Count > 0) then
    DoSubmitTrailers;
end;

procedure TNghttp2StreamState.DoSubmitTrailers;
var
  LNvs:                 array of Tnghttp2_nv;
  LNameBufs, LValueBufs: array of RawByteString;
  I, LCount:            Integer;
begin
  LCount := FResponseTrailers.Count;
  SetLength(LNvs,       LCount);
  SetLength(LNameBufs,  LCount);
  SetLength(LValueBufs, LCount);

  for I := 0 to LCount - 1 do
  begin
    LNameBufs[I]     := RawByteString(FResponseTrailers.Names[I]);
    LValueBufs[I]    := RawByteString(FResponseTrailers.ValueFromIndex[I]);
    LNvs[I].name     := PByte(PAnsiChar(LNameBufs[I]));
    LNvs[I].value    := PByte(PAnsiChar(LValueBufs[I]));
    LNvs[I].namelen  := Length(LNameBufs[I]);
    LNvs[I].valuelen := Length(LValueBufs[I]);
    LNvs[I].flags    := NGHTTP2_NV_FLAG_NONE;
  end;

  nghttp2_submit_trailer(
    FSession.NativeSession, FStreamId,
    @LNvs[0], NativeUInt(LCount));
end;

// ============================================================================
// TNghttp2Session
// ============================================================================

constructor TNghttp2Session.Create(const AConnection: INghttp2Connection);
var
  LRc: Integer;
begin
  inherited Create;
  FConnection := AConnection;
  FStreams    := TObjectDictionary<Int32, TNghttp2StreamState>.Create([doOwnsValues]);

  BuildCallbacks;

  LRc := nghttp2_session_server_new(FNativeSession, FCallbacks, Self);
  if LRc <> NGHTTP2_NO_ERROR then
    raise Exception.CreateFmt(
      'nghttp2_session_server_new failed: %d (%s)',
      [LRc, string(AnsiString(nghttp2_strerror(LRc)))]);

  SendInitialSettings;
end;

destructor TNghttp2Session.Destroy;
begin
  if FNativeSession <> nil then
    nghttp2_session_del(FNativeSession);
  if FCallbacks <> nil then
    nghttp2_session_callbacks_del(FCallbacks);
  FStreams.Free;
  inherited;
end;

procedure TNghttp2Session.BuildCallbacks;
var
  LRc: Integer;
begin
  LRc := nghttp2_session_callbacks_new(FCallbacks);
  if LRc <> NGHTTP2_NO_ERROR then
    raise Exception.CreateFmt('nghttp2_session_callbacks_new failed: %d', [LRc]);

  nghttp2_session_callbacks_set_on_begin_headers_callback(FCallbacks, @OnBeginHeadersCB);
  nghttp2_session_callbacks_set_on_header_callback       (FCallbacks, @OnHeaderCB);
  nghttp2_session_callbacks_set_on_frame_recv_callback   (FCallbacks, @OnFrameRecvCB);
  nghttp2_session_callbacks_set_on_data_chunk_recv_callback(FCallbacks, @OnDataChunkCB);
  nghttp2_session_callbacks_set_on_stream_close_callback (FCallbacks, @OnStreamCloseCB);
  // Note: no send_callback — we use mem_send to pull outgoing bytes.
end;

procedure TNghttp2Session.SendInitialSettings;
var
  LIv: array[0..0] of Tnghttp2_settings_entry;
begin
  // Advertise reasonable server defaults. Everything else uses nghttp2 defaults:
  //   HEADER_TABLE_SIZE=4096, ENABLE_PUSH=0 (server ignores anyway),
  //   INITIAL_WINDOW_SIZE=65535, MAX_FRAME_SIZE=16384.
  LIv[0].settings_id := NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS;
  LIv[0].value       := 100;
  nghttp2_submit_settings(FNativeSession, NGHTTP2_FLAG_NONE, @LIv[0], 1);
end;

function TNghttp2Session.FeedIncoming(const AData: PByte; ALen: NativeUInt): NativeInt;
begin
  Result := nghttp2_session_mem_recv(FNativeSession, AData, ALen);
end;

function TNghttp2Session.ExtractOutgoing(out ABuf: PByte): NativeInt;
begin
  Result := nghttp2_session_mem_send(FNativeSession, ABuf);
end;

function TNghttp2Session.WantRead: Boolean;
begin
  Result := nghttp2_session_want_read(FNativeSession) <> 0;
end;

function TNghttp2Session.WantWrite: Boolean;
begin
  Result := nghttp2_session_want_write(FNativeSession) <> 0;
end;

procedure TNghttp2Session.Terminate(AErrorCode: UInt32);
begin
  nghttp2_session_terminate_session(FNativeSession, AErrorCode);
end;

// ─── Callback handlers ────────────────────────────────────────────────────

function TNghttp2Session.DoBeginHeaders(const AFrame: Pnghttp2_frame): Integer;
var
  LState: TNghttp2StreamState;
begin
  // Only care about client-initiated request HEADERS (odd stream IDs).
  if AFrame^.hd.ftype <> NGHTTP2_HEADERS then Exit(0);

  // Ignore if we already know this stream (trailers, continuation, etc. v1
  // doesn't handle these — reject them politely).
  if FStreams.ContainsKey(AFrame^.hd.stream_id) then Exit(0);

  LState := TNghttp2StreamState.Create(Self, AFrame^.hd.stream_id, FConnection);
  FStreams.Add(AFrame^.hd.stream_id, LState);
  Result := 0;
end;

function TNghttp2Session.DoHeader(const AFrame: Pnghttp2_frame;
  const AName, AValue: PByte; ANameLen, AValueLen: NativeUInt): Integer;
var
  LState: TNghttp2StreamState;
begin
  if AFrame^.hd.ftype <> NGHTTP2_HEADERS then Exit(0);
  if not FStreams.TryGetValue(AFrame^.hd.stream_id, LState) then Exit(0);
  LState.AddRequestHeader(
    BytesToStr(AName, ANameLen),
    BytesToStr(AValue, AValueLen));
  Result := 0;
end;

function TNghttp2Session.DoFrameRecv(const AFrame: Pnghttp2_frame): Integer;
var
  LState: TNghttp2StreamState;
begin
  Result := 0;

  case AFrame^.hd.ftype of
    NGHTTP2_HEADERS, NGHTTP2_DATA:
      begin
        // Dispatch when END_STREAM arrives — client has finished sending
        if (AFrame^.hd.flags and NGHTTP2_FLAG_END_STREAM) <> 0 then
        begin
          if FStreams.TryGetValue(AFrame^.hd.stream_id, LState) then
            if Assigned(FOnRequest) then
              FOnRequest(LState as INghttp2Stream);
        end;
      end;
  end;
end;

function TNghttp2Session.DoDataChunk(AStreamId: Int32; AFlags: Byte;
  const AData: PByte; ALen: NativeUInt): Integer;
var
  LState: TNghttp2StreamState;
begin
  if FStreams.TryGetValue(AStreamId, LState) then
    LState.AppendRequestBody(AData, ALen);
  Result := 0;
end;

function TNghttp2Session.DoStreamClose(AStreamId: Int32; AErrorCode: UInt32): Integer;
begin
  // Remove from FStreams — the TObjectDictionary owns and frees the state.
  // This is safe here because dispatch happens on the same thread as recv,
  // and this callback fires only after the stream has fully drained both ways.
  FStreams.Remove(AStreamId);
  Result := 0;
end;

end.
