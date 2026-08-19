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
//  Concurrency model — two modes, chosen by the server via AsyncMode:
//
//  Synchronous (AsyncMode=False, the historical default): OnRequest runs
//  inline inside FeedIncoming and calls nghttp2_submit_response before
//  returning. One request at a time per connection.
//
//  Async (AsyncMode=True): OnRequest hands the stream to a worker pool and
//  returns immediately, so many streams on one connection execute in
//  parallel. This is constrained by a hard libnghttp2 rule
//  (doc/programmers-guide.rst): nghttp2_session_send / _mem_send / _recv /
//  _mem_recv must NEVER be called from inside a callback or from a second
//  thread — "it will lead to the crash". Only the nghttp2_submit_* family is
//  safe to call while holding the session, and even that must be serialised.
//
//  So in async mode nothing but the connection thread ever touches the
//  native session. A worker stages its response on the stream object and
//  enqueues the stream here; the connection thread drains that queue between
//  recv calls, calls nghttp2_submit_response for each, then pumps the wire.
//
//  Two consequences fall out of workers outliving the callback:
//
//  (1) Stream lifetime. on_stream_close can fire (client RST_STREAM, dead
//      connection) while a worker still holds the stream, so stream state is
//      reference-counted — see TNghttp2StreamState below.
//
//  (2) Loop liveness. The pump must not tear the connection down while work
//      is outstanding, and must wake to flush responses even when the client
//      has gone quiet. BeginAsyncDispatch/EndAsyncDispatch track that via
//      PendingDispatch, which the server's pump consults.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, DateUtils, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.DateUtils,
  System.Generics.Collections,
{$ENDIF}
  Nghttp2.Native,
  Nghttp2.Types;

const
  { Minimum spacing between the two shutdown GOAWAYs, standing in for one
    round trip. Generous for a LAN or loopback and still imperceptible next
    to any real drain; only an idle connection ever waits the full amount.
    Measuring the round trip with PING/ACK would remove the guess. }
  GOAWAY_GRACE_MS = 100;

type
  TNghttp2Session = class;   // forward

  { Internal counterpart to INghttp2Stream. Exists so the deferred-response
    queue can hold a reference that both keeps the stream alive and reaches
    its submit entry point, with no interface-to-class downcast (which has no
    portable spelling across Delphi and FPC). Not part of the public stream
    contract — implemented by TNghttp2StreamState only. }
  INghttp2StreamInternal = interface
    ['{2B7F4C1D-9E30-4A55-B6C8-7D1E0F3A9B24}']
    procedure SubmitStagedResponse;
  end;

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
  //     TInterfacedObject with live reference counting. It was
  //     TInterfacedPersistent (refcount disabled, freed by the session's
  //     TObjectDictionary) back when dispatch was strictly synchronous and
  //     every interface reference provably lived inside one call stack.
  //     Async dispatch breaks that: a worker thread holds this stream across
  //     recv iterations, and on_stream_close can fire in the meantime — a
  //     client RST_STREAM or a dropped connection closes streams that never
  //     got a response. Under the old ownership the dictionary would free the
  //     stream out from under the running worker.
  //
  //     With refcounting the session's dictionary, the deferred-response
  //     queue, and the worker each hold a reference; the last one out frees.
  //     on_stream_close therefore drops a reference rather than destroying.
  TNghttp2StreamState = class(TInterfacedObject, INghttp2Stream, INghttp2StreamInternal)
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
    // Set the moment Send/SendStream stages a response, which in async mode
    // is well before FResponseSubmitted — submission happens later, on the
    // connection thread. Guards everything that must not change after the
    // response is composed; FResponseSubmitted alone would stop guarding it.
    FResponseStaged:    Boolean;
    FTrailerSubmitted:  Boolean;   // FIX-TRAILER-ORDER (2026-08-08) — guards single-shot submit_trailer call from within read_callback
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

    // ─── Async dispatch handshake — see INghttp2Stream contract ───────────
    procedure BeginAsyncDispatch;
    procedure EndAsyncDispatch;

    { INghttp2StreamInternal }
    procedure SubmitStagedResponse;
  end;

  // ─── Session — owns the nghttp2_session and the stream table ────────────
  // Plain procedure type (not `of object`) — accepts unit-scope trampolines.
  // Class methods on THorseProviderNghttp2 wrap into such a trampoline; see
  // ExecutePipelineTrampoline in Horse.Provider.Nghttp2.pas.
  TNghttp2OnRequestProc = procedure(const AStream: INghttp2Stream);

  { Notifies a driver that a worker has just staged a response.

    A method pointer, NOT an anonymous method — FPC without FUNCTIONREFERENCES
    compiles no anonymous procs, and this has to work on both compilers. A
    plain `procedure of object` is ordinary Object Pascal and does.

    Exists because FResponseReady only reaches a driver that WAITS on it. The
    thread pump does; an event loop is parked in epoll_wait and cannot, so it
    needs to be poked through its own wake descriptor instead. Without this
    an event-loop driver holds every reply until its poll interval expires —
    measured at 2.8x the thread driver on the 94-check suite, which is the
    same defect the thread pump had before FResponseReady existed. }
  TNghttp2WakeProc = procedure of object;

  TNghttp2Session = class
  private
    FNativeSession: Pnghttp2_session;
    FCallbacks:     Pnghttp2_session_callbacks;
    // Raw lookup for the callbacks — non-owning; FStreamRefs owns.
    FStreams:       TDictionary<Int32, TNghttp2StreamState>;
    // Parallel table holding the reference that keeps each stream alive.
    // Split from FStreams so every existing callback lookup stays untouched.
    FStreamRefs:    TDictionary<Int32, INghttp2StreamInternal>;
    FConnection:    INghttp2Connection;
    FOnRequest:     TNghttp2OnRequestProc;
    FMaxConcurrentStreams: Integer;

    // ─── Async-mode state (all no-ops while FAsyncMode is False) ──────────
    FAsyncMode:       Boolean;
    FPendingQueue:    TQueue<INghttp2StreamInternal>;
    FQueueLock:       TCriticalSection;
    // Signalled by a worker the instant it stages a response. Without it the
    // pump would only notice on its next poll tick, and since the client is
    // typically waiting on that very response it sends nothing meanwhile —
    // so the reply would sit for the whole poll interval. Auto-reset, and
    // the signal latches, so a worker finishing mid-wait is never missed.
    FResponseReady:   TEvent;
    // Optional second signal, for a driver that cannot wait on the event
    // above. Called on the WORKER's thread, so an implementation must be
    // thread-safe and must not block — the engine's is a single write() to
    // an eventfd.
    FOnWorkStaged:    TNghttp2WakeProc;
    // Streams handed to a worker and not yet finished. The server's pump
    // keeps the connection alive and keeps polling while this is > 0.
    FPendingDispatch: Integer;   // TInterlocked-managed
    FShutdownNoticeSent: Boolean;
    FShutdownNoticeAt:   TDateTime;
    FFinalGoawaySent:    Boolean;
    // Holds references to the streams drained on the previous pass, so a
    // stream stays alive across the caller's subsequent ExtractOutgoing
    // loop — that is when its data-provider read_callback actually runs.
    FDrained:         TList<INghttp2StreamInternal>;

    procedure BuildCallbacks;
    procedure SendInitialSettings;
    // Called by TNghttp2StreamState.Send/SendStream. Submits inline in
    // synchronous mode; enqueues for the connection thread in async mode.
    procedure SubmitOrDefer(const AStream: TNghttp2StreamState);
  public
    constructor Create(const AConnection: INghttp2Connection;
      AMaxConcurrentStreams: Integer = 100);
    destructor  Destroy; override;

    // Submits every response staged by a worker since the last call. MUST be
    // called only from the connection thread, and only outside FeedIncoming /
    // ExtractOutgoing — nghttp2_submit_response is safe to call while holding
    // the session but not re-entrantly from within the pump.
    // Returns True if at least one response was submitted.
    function DrainPendingResponses: Boolean;

    // True when a worker has staged a response that DrainPendingResponses has
    // not submitted yet. The pump must consult this before any blocking wait:
    // a worker can stage its response and retire its dispatch count in the
    // window between the pump's last drain and its next wait, and a pump that
    // then blocked on the socket would hold the reply for a full poll tick.
    function HasPendingResponses: Boolean;

    // Blocks until a worker stages a response or ATimeoutMS elapses.
    procedure WaitForResponse(ATimeoutMS: Integer);

    // Streams currently owned by a worker thread.
    function PendingDispatch: Integer;

    { DRAIN-DIAG-2. The cutoff SubmitFinalGoaway is about to name — nghttp2's
      "highest stream I actually processed". Exposed read-only so a driver can
      LOG it rather than infer it.

      Worth observing because it decides, on the wire, which requests the peer
      must replay: a client receiving a final GOAWAY abandons every stream
      ABOVE this number. A value of 0 says "I processed nothing", so a peer
      with one open stream correctly gives up on it — indistinguishable at the
      client from a severed reply. build-fpc.sh stage 8 has reported this as
      13 on some runs and 0 on others for the SAME single-request test, while
      passing both times, because it asserts only that two GOAWAY frames
      appeared and never that the cutoff covers the streams in flight. }
    function LastProcStreamId: Integer;

    { Graceful-shutdown notice: GOAWAY carrying last_stream_id = 2^31-1 and
      NO_ERROR. Tells the peer to stop opening new streams while leaving every
      stream already in flight to finish normally — the standard HTTP/2
      shutdown signal (RFC 9113 §6.8).

      Without it a drain cannot converge against a closed-loop client: h2load
      and any connection-pooling client keep issuing new requests as responses
      come back, so "wait until nothing is outstanding" never becomes true and
      the drain runs to its deadline.

      Idempotent — the pump calls it on every iteration while draining. }
    procedure SubmitShutdownNotice;

    { Stage two of the same sequence: GOAWAY carrying the real last_stream_id,
      sent once the pump is finished and immediately before the connection
      closes. Without it the peer only ever sees the open-ended notice and
      then a dead socket, leaving it unable to distinguish a request the
      server processed from one it must replay elsewhere.

      Spaced at least GOAWAY_GRACE_MS after the notice — see the body — and
      idempotent. Only enqueues, so the caller must flush; it deliberately
      does NOT terminate the session, which would discard responses already
      submitted for open streams. }
    procedure SubmitFinalGoaway;

    // Set by the server before the pump starts; see the unit header.
    property AsyncMode: Boolean read FAsyncMode write FAsyncMode;

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

    { Set by a driver that cannot wait on FResponseReady. Fires on the
      worker's thread the moment a response is staged. Leave unset for the
      thread pump, which waits on the event directly.

      Assigned through a method rather than a property setter because a
      `procedure of object` is TWO pointers — code and data — so a plain
      assignment is not atomic and a worker reading it mid-write can see a
      torn value: a valid code pointer against a stale instance. Both the
      write and the read happen under FQueueLock. Pass nil to detach, which
      a driver MUST do before it can be freed. }
    procedure SetWakeProc(const AProc: TNghttp2WakeProc);

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
      begin
        data_flags^ := NGHTTP2_DATA_FLAG_EOF or NGHTTP2_DATA_FLAG_NO_END_STREAM;
        LState.DoSubmitTrailers;   // FIX-TRAILER-ORDER — submit AFTER EOF signal
      end
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
      begin
        data_flags^ := NGHTTP2_DATA_FLAG_EOF or NGHTTP2_DATA_FLAG_NO_END_STREAM;
        LState.DoSubmitTrailers;   // FIX-TRAILER-ORDER — submit AFTER EOF signal
      end
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
  FResponseStaged    := False;
  FTrailerSubmitted  := False;
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
  if FResponseStaged then
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

// First response wins. A second Send used to overwrite the staged body while
// DoSubmitResponse quietly ignored the repeat, so the wire could carry the
// first response's headers over the second's body; deferred submission would
// widen that into a cross-thread race and a duplicate queue entry.
procedure TNghttp2StreamState.Send(const AData: TBytes);
begin
  if FResponseStaged then Exit;
  FResponseBody.Clear;
  if Length(AData) > 0 then
    FResponseBody.WriteBuffer(AData[0], Length(AData));
  FResponseStream := nil;
  FResponseStaged := True;
  FSession.SubmitOrDefer(Self);
end;

procedure TNghttp2StreamState.SendStream(const ASource: TStream);
begin
  if FResponseStaged then Exit;
  FResponseBody.Clear;
  FResponseStream := ASource;
  FResponseStaged := True;
  FSession.SubmitOrDefer(Self);
end;

procedure TNghttp2StreamState.SubmitStagedResponse;
begin
  // Connection thread only — reached from TNghttp2Session.DrainPendingResponses.
  DoSubmitResponse;
end;

procedure TNghttp2StreamState.BeginAsyncDispatch;
begin
  TInterlocked.Increment(FSession.FPendingDispatch);
end;

procedure TNghttp2StreamState.EndAsyncDispatch;
begin
  TInterlocked.Decrement(FSession.FPendingDispatch);
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

  { FIX-TRAILER-ORDER (2026-08-08) — DO NOT call DoSubmitTrailers here.

    nghttp2_submit_trailer has a strict precondition: the data provider's
    read_callback MUST have already returned EOF|NO_END_STREAM before
    submit_trailer is called. Calling it here — immediately after
    submit_response and BEFORE the read_callback has ever fired — leaves
    the stream in a state where libnghttp2 silently skips the DATA phase
    entirely and emits initial HEADERS → trailer HEADERS(END_STREAM)
    with no body between them. Client sees empty body + valid trailers
    (grpcurl reports "EOF"; TNghttp2Client sees length-0 body).

    Correct sequence: submit_response here → callback fires and returns
    EOF|NO_END_STREAM → callback itself calls DoSubmitTrailers (guarded
    by FTrailerSubmitted). See ReadResponseBodyCallback EOF branches. }
end;

procedure TNghttp2StreamState.DoSubmitTrailers;
var
  LNvs:                 array of Tnghttp2_nv;
  LNameBufs, LValueBufs: array of RawByteString;
  I, LCount:            Integer;
begin
  { Idempotent — read_callback may fire multiple times; only submit once. }
  if FTrailerSubmitted then Exit;
  FTrailerSubmitted := True;

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

constructor TNghttp2Session.Create(const AConnection: INghttp2Connection;
  AMaxConcurrentStreams: Integer);
var
  LRc: Integer;
begin
  inherited Create;
  FConnection := AConnection;
  // Non-owning: FStreamRefs holds the reference that governs lifetime.
  FStreams      := TDictionary<Int32, TNghttp2StreamState>.Create;
  FStreamRefs   := TDictionary<Int32, INghttp2StreamInternal>.Create;
  FPendingQueue := TQueue<INghttp2StreamInternal>.Create;
  FDrained      := TList<INghttp2StreamInternal>.Create;
  FQueueLock    := TCriticalSection.Create;
  FResponseReady := TEvent.Create(nil, {ManualReset=}False, {InitialState=}False, '');
  FAsyncMode    := False;
  FPendingDispatch := 0;
  FShutdownNoticeSent := False;
  FShutdownNoticeAt   := 0;
  FFinalGoawaySent    := False;
  if AMaxConcurrentStreams > 0 then
    FMaxConcurrentStreams := AMaxConcurrentStreams
  else
    FMaxConcurrentStreams := 100;

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
  // Release order matters: FStreams is a bare lookup table, so every
  // reference-holding container must go first. Any stream a worker still
  // holds survives all of these and frees when that worker lets go.
  FDrained.Free;
  FPendingQueue.Free;
  FStreamRefs.Free;
  FStreams.Free;
  FResponseReady.Free;
  FQueueLock.Free;
  inherited;
end;

function TNghttp2Session.HasPendingResponses: Boolean;
begin
  if not FAsyncMode then Exit(False);
  FQueueLock.Enter;
  try
    Result := FPendingQueue.Count > 0;
  finally
    FQueueLock.Leave;
  end;
end;

procedure TNghttp2Session.WaitForResponse(ATimeoutMS: Integer);
begin
  FResponseReady.WaitFor(ATimeoutMS);
end;

function TNghttp2Session.PendingDispatch: Integer;
begin
  Result := TInterlocked.CompareExchange(FPendingDispatch, 0, 0);
end;

procedure TNghttp2Session.SubmitShutdownNotice;
const
  // 2^31-1: "I will still process every stream you have already opened."
  // A real last_stream_id here would reset streams above it; this value
  // is the notice, not the cutoff.
  LAST_STREAM_ID_MAX = Int32($7FFFFFFF);
begin
  // Connection thread only, and only between pump calls — submit_* is safe
  // there, unlike the send/recv family.
  if FShutdownNoticeSent then Exit;
  FShutdownNoticeSent := True;
  FShutdownNoticeAt   := Now;
  nghttp2_submit_goaway(FNativeSession, NGHTTP2_FLAG_NONE,
    LAST_STREAM_ID_MAX, NGHTTP2_NO_ERROR, nil, 0);
end;

function TNghttp2Session.LastProcStreamId: Integer;
begin
  // Same call SubmitFinalGoaway makes, so what a driver logs is exactly what
  // goes on the wire — not a re-derivation that could disagree with it.
  Result := nghttp2_session_get_last_proc_stream_id(FNativeSession);
end;

procedure TNghttp2Session.SubmitFinalGoaway;
var
  LElapsed: Integer;
begin
  if FFinalGoawaySent then Exit;
  FFinalGoawaySent := True;

  { Space the two GOAWAYs. The notice says "stop opening streams" without
    naming a cutoff; this one names it. A peer that opened a stream in the
    window between deciding to and receiving the notice needs that stream to
    fall at or below the final last_stream_id, or it cannot tell a request
    that was processed from one it must replay — the entire reason RFC 9113
    describes two frames rather than one.

    In practice the drain supplies far more than a round trip, because it
    waits for in-flight work. The wait below only matters for the degenerate
    case: an idle connection, where the drain completes at once and both
    frames would otherwise be emitted back to back. Connections do this
    concurrently, so it costs the shutdown one grace period in total, not one
    per connection.

    A PING/ACK exchange would measure the real round trip instead of assuming
    one. That is the more precise design and the natural next step if this
    ever needs to serve high-latency links. }
  if FShutdownNoticeSent then
  begin
    LElapsed := MilliSecondsBetween(Now, FShutdownNoticeAt);
    if LElapsed < GOAWAY_GRACE_MS then
      Sleep(GOAWAY_GRACE_MS - LElapsed);
  end;

  { submit_goaway, NOT terminate_session.

    terminate_session looks like the natural fit — it derives last_stream_id
    itself — but it does what its name says: it ends the session, discarding
    frames already submitted for open streams. Calling it here, right after
    the final response was queued, threw that response away. A frame trace
    showed the two GOAWAYs arriving correctly and the reply never arriving at
    all, with the client reporting `processed=0`.

    submit_goaway only enqueues a frame, so it lines up behind the response
    instead of replacing it. The stream ID comes from
    get_last_proc_stream_id, which is the same number terminate_session would
    have used — the highest stream actually processed. }
  nghttp2_submit_goaway(FNativeSession, NGHTTP2_FLAG_NONE,
    nghttp2_session_get_last_proc_stream_id(FNativeSession),
    NGHTTP2_NO_ERROR, nil, 0);
end;

procedure TNghttp2Session.SubmitOrDefer(const AStream: TNghttp2StreamState);
var
  LWake: TNghttp2WakeProc;
begin
  if not FAsyncMode then
  begin
    // Historical path, byte-for-byte unchanged: the caller is the connection
    // thread inside a callback, and nghttp2_submit_response is documented as
    // safe there.
    AStream.DoSubmitResponse;
    Exit;
  end;

  // Async: the caller is (usually) a worker thread, which must not touch the
  // native session at all. Park the staged response for the connection
  // thread. Enqueuing as an interface also pins the stream until submitted,
  // which matters when the client RSTs the stream mid-handler.
  LWake := nil;
  FQueueLock.Enter;
  try
    FPendingQueue.Enqueue(AStream as INghttp2StreamInternal);
    // Copied under the lock so it cannot tear against SetWakeProc; invoked
    // outside it so a driver's wake (a syscall) never runs with the queue
    // lock held, where it would block every other worker staging a response.
    LWake := FOnWorkStaged;
  finally
    FQueueLock.Leave;
  end;

  { Wake the driver now rather than letting it sit out its poll interval. The
    client that sent this request is waiting on the answer, so it is sending
    nothing that would wake anyone on its own.

    Both signals fire, because the two drivers listen differently: the thread
    pump waits on the event, an event loop waits in epoll_wait and can only be
    reached through its own descriptor. Signalling the event alone is exactly
    what left the epoll engine flushing replies a poll interval late. }
  FResponseReady.SetEvent;
  if Assigned(LWake) then
    LWake;
end;

procedure TNghttp2Session.SetWakeProc(const AProc: TNghttp2WakeProc);
begin
  FQueueLock.Enter;
  try
    FOnWorkStaged := AProc;
  finally
    FQueueLock.Leave;
  end;
end;

function TNghttp2Session.DrainPendingResponses: Boolean;
var
  LItem: INghttp2StreamInternal;
begin
  Result := False;
  if not FAsyncMode then Exit;

  // Streams drained on the previous pass have had their DATA frames pulled by
  // now (the caller ran ExtractOutgoing to completion after that drain), so
  // it is safe to drop those references here.
  FDrained.Clear;

  while True do
  begin
    FQueueLock.Enter;
    try
      if FPendingQueue.Count = 0 then Break;
      LItem := FPendingQueue.Dequeue;
    finally
      FQueueLock.Leave;
    end;

    // Outside the lock: submit touches the native session, and a handler
    // must never be able to deadlock the queue behind it.
    FDrained.Add(LItem);
    LItem.SubmitStagedResponse;
    LItem := nil;
    Result := True;
  end;
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
  // Clients self-limit to this many in-flight streams per connection, which
  // is the cheapest backpressure available: it throttles at the protocol
  // layer, before a request ever reaches the worker pool.
  LIv[0].settings_id := NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS;
  LIv[0].value       := FMaxConcurrentStreams;
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
  // FStreamRefs takes the owning reference (bumping refcount from 0 to 1);
  // FStreams keeps the bare pointer the other callbacks look up.
  FStreamRefs.Add(AFrame^.hd.stream_id, LState as INghttp2StreamInternal);
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
  // Drops the session's reference rather than destroying the stream. In
  // synchronous mode that is the only reference and the stream dies here,
  // exactly as before. In async mode this callback can fire while a worker is
  // still running (client RST_STREAM, connection reset), and then the worker's
  // own reference keeps the object alive until it finishes — the response it
  // eventually stages is submitted against a closed stream and harmlessly
  // rejected by nghttp2.
  FStreams.Remove(AStreamId);
  FStreamRefs.Remove(AStreamId);
  Result := 0;
end;

end.
