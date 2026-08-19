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
