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
//  Slice 1 is metadata only: the deadline/cancellation members exist but are
//  inert (HasDeadline=False, etc.). Slice 2 parses grpc-timeout and wires them.
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
    { Deadline / cancellation — INERT in slice 1; slice 2 wires grpc-timeout. }
    function  HasDeadline: Boolean;
    function  TimeRemainingMS: Integer;
    function  Cancelled: Boolean;
    procedure ThrowIfCancelled;
  end;

  TGrpcCallContext = class(TInterfacedObject, IGrpcCallContext)
  private
    FStream: INghttp2Stream;   // held for the call so Header[] stays readable
    FPath:   string;
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
begin
  inherited Create;
  FStream := AStream;
  FPath   := APath;
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

// ── deadline / cancellation — inert until slice 2 ───────────────────────────

function TGrpcCallContext.HasDeadline: Boolean;
begin
  Result := False;
end;

function TGrpcCallContext.TimeRemainingMS: Integer;
begin
  Result := 0;
end;

function TGrpcCallContext.Cancelled: Boolean;
begin
  Result := False;
end;

procedure TGrpcCallContext.ThrowIfCancelled;
begin
  // no deadline parsed yet — slice 2 wires grpc-timeout + grpc-status 4
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
