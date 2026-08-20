unit Nghttp2.Types;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Types
//  Interface abstractions over one HTTP/2 stream and its connection.
//
//  These interfaces let request/response bridges compile without depending on
//  the session runtime. Concrete implementations live in Nghttp2.Session
//  (per-connection session state + per-stream wrappers that hold decoded
//  headers, accumulated DATA, and the outgoing response buffer).
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  Classes, SysUtils;   // SysUtils provides TBytes on both compilers
{$ELSE}
  System.Classes,
  System.SysUtils;
{$ENDIF}

type
  INghttp2Connection = interface
    ['{6F5A3E7C-8F0F-4E4D-A6E4-3D5B7C9E2A11}']
    function GetPeerAddr: string;
    function GetLocalPort: Integer;
    property PeerAddr:  string  read GetPeerAddr;
    property LocalPort: Integer read GetLocalPort;
  end;

  INghttp2Stream = interface
    ['{9C2E7A4B-3F1D-4C5E-8A7B-1E2F3D4C5B6A}']
    // ─── Request-side accessors (populated by Session before dispatch) ────
    function  GetHeader(const AName: string): string;
    procedure SetHeader(const AName, AValue: string);
    property  Header[const AName: string]: string read GetHeader write SetHeader;

    // Append a header without deduping — required for headers that legally
    // appear multiple times (Set-Cookie per RFC 6265 §3; Warning per
    // RFC 7234). Contrast with Header[]/SetHeader which replace-in-place.
    procedure AddHeader(const AName, AValue: string);

    function  GetBody: TStream;
    property  Body: TStream read GetBody;

    function  GetConnection: INghttp2Connection;
    property  Connection: INghttp2Connection read GetConnection;

    // Populate a target TStrings with all request headers as Name=Value lines.
    // Used by the Request bridge to fill THorseRequest.Headers.
    procedure PopulateRequestHeadersInto(const ADest: TStrings);

    // ─── Response-side (called by ResponseBridge.Flush) ───────────────────
    function  GetStatusCode: Integer;
    procedure SetStatusCode(const AValue: Integer);
    property  StatusCode: Integer read GetStatusCode write SetStatusCode;

    procedure Send(const AData: TBytes);
    procedure SendStream(const ASource: TStream);

    // ─── HTTP/2 trailers (M2b, 2026-08-07) ───────────────────────────────
    //  Adds one trailer header to be emitted AFTER the response body via
    //  nghttp2_submit_trailer. Required for gRPC (grpc-status is always a
    //  trailer). Must be called BEFORE Send/SendStream — trailers are queued
    //  at submit_response time and cannot be modified once the DATA frames
    //  start flowing. Names are lowercased (HTTP/2 requires it).
    procedure AddTrailer(const AName, AValue: string);

    // ─── Streaming responses (chunked/SSE equivalent) ────────────────────
    //  Send/SendStream stage a body whose size is known when they are called.
    //  A streaming response is open-ended: headers go out immediately and the
    //  body arrives in pieces the handler produces over time.
    //
    //  BeginStreaming submits the response headers with a data provider that
    //  stays hungry, so nothing is buffered waiting for a total length. Each
    //  PushStreamData appends one piece and wakes the pump; EndStreaming
    //  closes the stream. Call them in that order, exactly once for Begin and
    //  End. Mutually exclusive with Send/SendStream on the same stream.
    //
    //  PushStreamData is safe from a worker thread — it touches only the
    //  stream's own buffer and a resume flag the connection thread consumes.
    //  Every nghttp2_* call still happens on the connection thread.
    procedure BeginStreaming;
    procedure PushStreamData(const AData: TBytes);
    procedure EndStreaming;

    //  False once the peer has gone away (RST_STREAM, GOAWAY, or a dead
    //  connection). A streaming handler should poll this and stop producing —
    //  an SSE loop that ignores it runs until its own timeout with nowhere to
    //  send.
    function IsStreamAlive: Boolean;

    // ─── Incremental inbound (INBOUND-1) ─────────────────────────────────
    //  Body normally arrives whole: the session accumulates DATA and only
    //  dispatches once END_STREAM lands, so Body is complete when a handler
    //  first sees it. That is right for a request/response exchange and wrong
    //  for anything long-lived — client-streaming and bidirectional gRPC, and
    //  WebSocket over RFC 8441 — where the handler must consume DATA while the
    //  peer is still sending.
    //
    //  Inbound mode reverses that: the session dispatches on HEADERS and
    //  routes each DATA chunk to a queue the handler drains through
    //  ReadInbound. It is opt-in per stream, chosen by the host before
    //  dispatch (see TNghttp2Session.OnShouldStreamInbound); nothing changes
    //  for a stream that does not ask for it.
    //
    //  REQUIRES async dispatch. ReadInbound blocks, and in synchronous mode
    //  the handler IS the connection thread — the one that must return to
    //  read more socket data. Blocking there deadlocks permanently rather
    //  than slowly, so BeginInbound refuses outside async mode.

    { True once the session has put this stream in inbound mode. }
    function InboundStreaming: Boolean;

    { Blocks until at least one byte is available, the peer half-closes, or
      ATimeoutMS elapses. Returns:
        > 0  bytes copied into ABuffer
        = 0  end of stream — the peer sent END_STREAM, nothing more is coming
        < 0  timeout, with the stream still open; call again

      ABuffer is sized to ACount by the callee. Partial reads are normal: this
      returns what has arrived, not what was asked for. }
    function ReadInbound(var ABuffer: TBytes; ACount: Integer;
      ATimeoutMS: Integer): Integer;

    { True once END_STREAM has been seen on the request side. Note it can be
      true while ReadInbound still has buffered bytes to return — check the
      ReadInbound result for end-of-stream, not this. }
    function InboundEnded: Boolean;

    // ─── Async dispatch handshake ────────────────────────────────────────
    //  For hosts that answer OnRequest from a worker thread instead of
    //  inline. BeginAsyncDispatch says "a worker now owns this stream";
    //  EndAsyncDispatch says it is done, responded or not. Between the two
    //  the connection pump keeps the connection open and keeps polling, so
    //  the response is flushed even when the client has stopped sending.
    //
    //  Call BeginAsyncDispatch on the connection thread BEFORE handing the
    //  stream over — doing it inside the worker races the pump, which may
    //  already have concluded there is nothing left to wait for. Pair
    //  EndAsyncDispatch in the worker's finally: an unmatched Begin parks
    //  the connection until the peer disconnects.
    //
    //  Synchronous hosts ignore both; the counter simply stays at zero.
    procedure BeginAsyncDispatch;
    procedure EndAsyncDispatch;
  end;

implementation

end.
