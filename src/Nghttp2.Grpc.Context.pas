unit Nghttp2.Grpc.Context;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Grpc.Context — CL5.6 server-side gRPC call context (slice 1).
//
//  Gives a gRPC handler read access to the call's inbound application metadata
//  WITHOUT changing any handler signature — the RTTI RegisterService<T> path
//  cannot grow a parameter (its signature is frozen by the interface), so the
//  context is reached through an AMBIENT accessor instead:
//
//      Ctx := TGrpcCallContext.Current;          // nil outside a dispatch
//      if Ctx.Metadata('authorization') = '' then ...;
//
//  TGrpcDispatcher sets the current context around every handler invoke and
//  clears it in a finally, so each call sees its own and a reused worker thread
//  never sees a stale one (the "current" slot is a threadvar, so concurrent
//  workers do not collide). The context is valid ONLY for the duration of the
//  call; do not retain the interface past the handler.
//
//  Metadata scope (decided 2026-10-22): APPLICATION headers only. Hidden from
//  Metadata/HasMetadata are HTTP/2 pseudo-headers (:path/:method/:authority/
//  :scheme) and gRPC-reserved names (content-type, te, grpc-*). Path is the
//  explicit path accessor; grpc-timeout is parsed internally for the deadline
//  (slice 2), not exposed here. Binary metadata (*-bin, base64) is NOT supported
//  this milestone. Name matching is case-insensitive and a single value per name
//  is returned, exactly as INghttp2Stream.Header[] gives it (the request-header
//  store is AddOrSetValue-keyed by lower-cased name, so the LAST occurrence of a
//  duplicated name wins).
//
//  Slice 2 (2026-10-22) wires the deadline: grpc-timeout is parsed into an
//  absolute deadline; HasDeadline/TimeRemainingMS/Cancelled/ThrowIfCancelled are
//  live. Cancellation is COOPERATIVE — a handler polls Cancelled or calls
//  ThrowIfCancelled (which raises EGrpcDeadlineExceeded, mapped to grpc-status 4
//  by the dispatcher); nothing preempts a handler that ignores the deadline.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$IFEND}
  Nghttp2.Types;

type
  { CL5.6 slice 2: a handler that calls Ctx.ThrowIfCancelled raises this; the
    dispatcher maps it to grpc-status 4 DEADLINE_EXCEEDED (HandlerFailureStatus). }
  EGrpcDeadlineExceeded = class(Exception);

  IGrpcCallContext = interface
    ['{7E3C1A52-9B4D-4C8E-A1F6-2D5B0E9C4A77}']
    { Inbound application metadata, case-insensitive. '' if absent OR filtered
      (a reserved protocol header / pseudo-header / *-bin). }
    function  Metadata(const AName: string): string;
    { True when a non-filtered header with a non-empty value is present. Cannot
      report a present-but-empty header (the stream getter collapses empty and
      absent to ''); empty metadata values are not used in practice. }
    function  HasMetadata(const AName: string): Boolean;
    { The request :path (e.g. /pkg.Service/Method). The explicit accessor for
      routing info — pseudo-headers are not reachable through Metadata. }
    function  Path: string;
    { Deadline / cancellation (slice 2): driven by grpc-timeout, cooperative. }
    function  HasDeadline: Boolean;
    function  TimeRemainingMS: Integer;
    function  Cancelled: Boolean;
    procedure ThrowIfCancelled;
  end;

  TGrpcCallContext = class(TInterfacedObject, IGrpcCallContext)
  private
    FStream: INghttp2Stream;   // held for the call so Header[] stays readable
    FPath:   string;
    FHasDeadline:  Boolean;    // CL5.6 slice 2: parsed from grpc-timeout
    FDeadlineTick: UInt64;     // absolute GetTickCount64 ms; valid iff FHasDeadline
  public
    constructor Create(const AStream: INghttp2Stream; const APath: string);

    function  Metadata(const AName: string): string;
    function  HasMetadata(const AName: string): Boolean;
    function  Path: string;
    function  HasDeadline: Boolean;
    function  TimeRemainingMS: Integer;
    function  Cancelled: Boolean;
    procedure ThrowIfCancelled;

    { Ambient accessor. Current is nil outside a dispatch. SetCurrent/ClearCurrent
      are called by TGrpcDispatcher only, around each handler invoke. }
    class function  Current: IGrpcCallContext; static;
    class procedure SetCurrent(const ACtx: IGrpcCallContext); static;
    class procedure ClearCurrent; static;
  end;

{ True if AName (ALREADY lower-cased) is a reserved protocol header hidden from
  the handler-facing metadata API. Exposed so the gate can pin the policy. }
function IsReservedGrpcMetadataName(const ALowerName: string): Boolean;

implementation

uses
{$IF DEFINED(FPC)}
  StrUtils;
{$ELSE}
  System.StrUtils;
{$IFEND}

{ Decode a gRPC "grpc-timeout" header (value = 1..8 digits, then one unit of
  H|M|S|m|u|n) to milliseconds. Returns False on absent/malformed input — the
  caller then treats the call as having no deadline (lenient, per the spec). }
function ParseGrpcTimeoutMS(const AValue: string; out AMS: Int64): Boolean;
var
  LLen, I: Integer;
  LUnit:   Char;
  LVal:    Int64;
begin
  Result := False;
  AMS := 0;
  LLen := Length(AValue);
  if (LLen < 2) or (LLen > 9) then   // 1..8 digits + exactly one unit char
    Exit;
  LVal := 0;
  for I := 1 to LLen - 1 do
  begin
    if (AValue[I] < '0') or (AValue[I] > '9') then
      Exit;
    LVal := LVal * 10 + (Ord(AValue[I]) - Ord('0'));
  end;
  LUnit := AValue[LLen];
  case LUnit of
    'H': AMS := LVal * 3600000;
    'M': AMS := LVal * 60000;
    'S': AMS := LVal * 1000;
    'm': AMS := LVal;
    'u': AMS := (LVal + 999) div 1000;         // micros -> ms, rounded up
    'n': AMS := (LVal + 999999) div 1000000;   // nanos -> ms, rounded up
  else
    Exit;
  end;
  Result := True;
end;

threadvar
  GCurrentContext: IGrpcCallContext;   // per dispatching thread; cleared in finally

function IsReservedGrpcMetadataName(const ALowerName: string): Boolean;
begin
  // Boolean or short-circuits (default BOOLEVAL off), so the empty-string guard
  // runs first and protects the [1] index below.
  Result :=
    (ALowerName = '') or
    (ALowerName[1] = ':') or              // HTTP/2 pseudo-header
    (ALowerName = 'content-type') or
    (ALowerName = 'te') or
    StartsStr('grpc-', ALowerName) or     // grpc-timeout, grpc-encoding, grpc-status, ...
    EndsStr('-bin', ALowerName);          // binary metadata — unsupported this milestone
end;

constructor TGrpcCallContext.Create(const AStream: INghttp2Stream; const APath: string);
var
  LTimeoutMS: Int64;
begin
  inherited Create;
  FStream := AStream;
  FPath   := APath;
  { CL5.6 slice 2: parse grpc-timeout into an absolute deadline. Absent or
    malformed leaves FHasDeadline False (no deadline). }
  if ParseGrpcTimeoutMS(AStream.Header['grpc-timeout'], LTimeoutMS) then
  begin
    FHasDeadline  := True;
    { Monotonic tick, NOT Now: Now is wall-clock (can jump) and the TDateTime +
      float math fired the deadline immediately on Delphi; integer ms is robust
      on both compilers. }
    FDeadlineTick := TThread.GetTickCount64 + UInt64(LTimeoutMS);
  end;
end;

function TGrpcCallContext.Metadata(const AName: string): string;
begin
  if IsReservedGrpcMetadataName(LowerCase(AName)) then
    Result := ''
  else
    Result := FStream.Header[AName];   // Header[] lowercases + returns one value
end;

function TGrpcCallContext.HasMetadata(const AName: string): Boolean;
begin
  if IsReservedGrpcMetadataName(LowerCase(AName)) then
    Result := False
  else
    Result := FStream.Header[AName] <> '';
end;

function TGrpcCallContext.Path: string;
begin
  Result := FPath;
end;

// ── deadline / cancellation (CL5.6 slice 2) ─────────────────────────────────

function TGrpcCallContext.HasDeadline: Boolean;
begin
  Result := FHasDeadline;
end;

function TGrpcCallContext.TimeRemainingMS: Integer;
var
  LNow, LRem: UInt64;
begin
  if not FHasDeadline then
  begin
    Result := High(Integer);   // no deadline: effectively unbounded
    Exit;
  end;
  LNow := TThread.GetTickCount64;
  if LNow >= FDeadlineTick then
    Result := 0                // past the deadline
  else
  begin
    LRem := FDeadlineTick - LNow;
    if LRem > UInt64(High(Integer)) then
      Result := High(Integer)
    else
      Result := Integer(LRem);
  end;
end;

function TGrpcCallContext.Cancelled: Boolean;
begin
  { Cooperative: the deadline passed. (Slice 2 tracks the deadline only; a peer
    reset is not folded in here.) }
  Result := FHasDeadline and (TThread.GetTickCount64 >= FDeadlineTick);
end;

procedure TGrpcCallContext.ThrowIfCancelled;
begin
  if Cancelled then
    raise EGrpcDeadlineExceeded.Create('deadline exceeded');
end;

// ── ambient accessor ────────────────────────────────────────────────────────

class function TGrpcCallContext.Current: IGrpcCallContext;
begin
  Result := GCurrentContext;
end;

class procedure TGrpcCallContext.SetCurrent(const ACtx: IGrpcCallContext);
begin
  GCurrentContext := ACtx;
end;

class procedure TGrpcCallContext.ClearCurrent;
begin
  GCurrentContext := nil;
end;

end.
