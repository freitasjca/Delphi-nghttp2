unit Nghttp2.Grpc.Registry;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Grpc.Registry
//  Process-wide registry of gRPC methods → handler dispatch info.
//  M4a of the horse-provider-nghttp2 gRPC plan (2026-08-07).
//  M4c ergonomic layer added 2026-08-09 — RegisterService<T> generic.
//
//  Two registration styles, both routed to the same internal storage:
//
//  1. **Procedural (M4a)** — `TGrpcRegistry.RegisterMethod(path, ReqClass,
//     RespClass, handler)` — explicit per-method registration with a
//     `procedure(AReq, AResp: TObject) of object` handler that mutates the
//     dispatcher-created response instance. Backward-compatible; no ARC
//     gymnastics; works on Delphi + FPC.
//
//  2. **IInvokable (M4c)** — `TGrpcRegistry.RegisterService<IGreeter>(impl)` —
//     walks the interface via RTTI, extracts path from `[TGrpcService]`
//     attribute + method name, extracts request/response classes from
//     method signature, and wires each method through
//     `TGrpcInvokableWrapper` (owned by the registry, freed at Shutdown).
//     User's methods RETURN the response instance (dispatcher frees it).
//     Requires `_AddRef`/`_Release` = -1 on the impl class — see
//     horse-grpc SKILL §2.
//
//  Path convention (both styles): `/<PackageName>.<ServiceName>/<MethodName>`
//  per the gRPC-over-HTTP/2 spec. Case-sensitive, no normalization.
//
//  Extracted from horse-provider-nghttp2 on 2026-08-23. The layer never
//  depended on Horse — only its unit name did; the sole input here is an
//  INghttp2Stream. Any host that owns one can serve gRPC with it.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Rtti, TypInfo, Generics.Collections
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs, System.Rtti,
  System.TypInfo, System.Generics.Collections
{$IFEND}
  ,Nghttp2.Grpc.Attributes;

type
  { Signature of a gRPC method handler (M4a procedural path).
    - ARequest is a fresh instance of the registered request class,
      populated by the dispatcher from the deserialised protobuf body.
    - AResponse is a fresh instance of the registered response class;
      the handler populates its properties.
    Ownership: dispatcher creates + frees BOTH — handler MUST NOT free
    either. Handler may raise; dispatcher catches and returns
    grpc-status 13 (INTERNAL) with the exception message. }
  TGrpcHandler = procedure(const ARequest: TObject; const AResponse: TObject) of object;

  { Signature of a gRPC invoke callback (M4c interface path).
    - ARequest is a fresh instance of the request class (populated).
    - Return value is a NEW response instance the callback allocates.
      Dispatcher frees it after serialising to protobuf.
    Ownership: dispatcher frees the returned response. }
  TGrpcInvokeMethod = function(const ARequest: TObject): TObject of object;

  { ── Server-streaming (M6a) ────────────────────────────────────────────────
    One request in, many responses out, then a grpc-status trailer. The wire
    shape is unchanged from unary — each message is still
    `[compressed flag][4-byte length][payload]` — they simply concatenate in
    the DATA stream instead of there being exactly one.

    The handler is given a writer instead of a response object, because it
    decides how many responses there are and when. }
  IGrpcStreamWriter = interface
    ['{7B1E4C93-6A2F-4D58-9E3B-8C5A0D1F2E64}']
    { Serialises, gRPC-frames and queues one response message.

      TAKES OWNERSHIP of AResponse and frees it — matching TGrpcInvokeMethod,
      where the dispatcher frees what the callback returns. A streaming handler
      allocates in a loop, so leaving ownership with the caller would make a
      leak the default outcome rather than the exceptional one. }
    procedure Send(const AResponse: TObject);

    { False once the peer is gone (RST_STREAM, GOAWAY, dead connection). Check
      it in the producing loop: on HTTP/2 a departed client does not surface as
      a write error, so a loop that ignores this runs to completion with
      nowhere to send. }
    function IsConnected: Boolean;

    { Messages handed to Send so far — for logging and tests. }
    function Count: Integer;
  end;

  { Signature of a server-streaming gRPC handler.
    - ARequest is a fresh populated instance; the dispatcher frees it.
    - AWriter emits zero or more responses. Returning normally means success:
      the dispatcher appends grpc-status 0. Raising means failure: the
      dispatcher appends grpc-status 13 (INTERNAL) instead — note that any
      messages already sent have gone, which is inherent to streaming and not
      a defect. }
  TGrpcServerStreamHandler = procedure(const ARequest: TObject;
    const AWriter: IGrpcStreamWriter) of object;

  { ── Client-streaming / bidirectional (M6b) ────────────────────────────────
    Reads request messages as they arrive. Each is still
    `[compressed flag][4-byte length][payload]`, but they are NOT aligned to
    DATA frames — one frame may carry several messages, one message may span
    several frames — so the reader reassembles rather than decoding per frame. }
  IGrpcStreamReader = interface
    ['{4D8A2F17-0C63-4B9E-A5D1-3E7F6B240C58}']
    { Blocks until the next complete message arrives, then returns True with
      AMessage populated. Returns False once the peer half-closes and the
      buffer is drained — the normal way to end a read loop.

      AMessage is OWNED BY THE READER and is only valid until the next call to
      Next. Do not free it, and do not retain it across iterations; copy out
      anything you need to keep. Reader-owned deliberately: a handler loops
      over an unknown number of messages, so caller-frees would make leaking
      the default outcome, and a caller-supplied buffer would carry stale
      fields from the previous message into any field the next one omits. }
    function Next(out AMessage: TObject): Boolean;

    { Messages returned by Next so far. }
    function Count: Integer;
  end;

  { Client-streaming: many requests in, ONE response out.
    - AReader drains the request messages.
    - AResponse is a fresh instance the dispatcher created and frees; the
      handler populates it, exactly as in the unary procedural path. }
  TGrpcClientStreamHandler = procedure(const AReader: IGrpcStreamReader;
    const AResponse: TObject) of object;

  { Bidirectional: many in, many out, concurrently on one stream.
    Reading and writing are independent — a handler may interleave them
    freely, and does not have to drain the reader before writing. }
  TGrpcBidiStreamHandler = procedure(const AReader: IGrpcStreamReader;
    const AWriter: IGrpcStreamWriter) of object;

  TGrpcMethodInfo = record
    Path:          string;
    RequestClass:  TClass;
    ResponseClass: TClass;
    Handler:       TGrpcHandler;       // set for procedural M4a path
    InvokeMethod:  TGrpcInvokeMethod;  // set for IInvokable M4c path (mutually exclusive with Handler)
    StreamHandler: TGrpcServerStreamHandler;  // set for server-streaming M6a path
    ClientHandler: TGrpcClientStreamHandler;  // set for client-streaming M6b path
    BidiHandler:   TGrpcBidiStreamHandler;    // set for bidirectional  M6b path
    { True when StreamHandler is the one to call. Kept as an explicit flag
      rather than inferred from Assigned(StreamHandler) so the dispatcher's
      branch reads as a declared property of the method, not as a side effect
      of which field happens to be populated. }
    IsServerStream: Boolean;
    { True for client-streaming and bidi alike — both consume the request body
      incrementally, which is what the transport needs to know. The dispatcher
      then picks between them by which handler field is set. }
    IsClientStream: Boolean;
  end;

  EGrpcRegistry = class(Exception);

  { Internal — one wrapper instance per registered interface method.
    Holds a strong ref to the service interface (which has ARC disabled
    per horse-grpc SKILL §2) and the TRttiMethod for invocation.
    Owned by TGrpcRegistry.FWrappers, freed on Shutdown.

    GENERIC IN T ON PURPOSE — do not "simplify" this back to a plain
    `FIntf: IInterface` field. Erasing the interface type before building
    the instance TValue makes TRttiMethod.Invoke fail on FPC with

        expected IGreeter, but got IUnknown

    because the method's hidden Self parameter is typed to the DECLARING
    interface, and Invoke VALIDATES the TValue's type info — it does not
    merely dispatch through the vtable. Delphi tolerates the erased form;
    FPC does not. Diagnosed 2026-08-12, gRPC FPC Phase 2.

    Each specialisation is a distinct class with no common ancestor beyond
    TObject, so FWrappers is a TObjectList<TObject> — the list only owns
    lifetimes, it never calls back in. }
  TGrpcInvokableWrapper<T: IInvokable> = class
  strict private
    FIntf:   T;
    FMethod: TRttiMethod;
  public
    constructor Create(const AIntf: T; const AMethod: TRttiMethod);
    { The `of object` method-pointer matching TGrpcInvokeMethod. }
    function Invoke(const ARequest: TObject): TObject;
  end;

  { Process-wide singleton via class methods + class vars.
    Same shape as TProtobufRtti (see Nghttp2.Protobuf.Rtti.pas). }
  TGrpcRegistry = class
  strict private
    class var FRegistry: TDictionary<string, TGrpcMethodInfo>;
    class var FWrappers: TObjectList<TObject>;   // holds TGrpcInvokableWrapper<T> of assorted T
    class var FLock:     TCriticalSection;
    class var FReady:    Boolean;
    { Process-lifetime RTTI context — horse-grpc SKILL §3 "RTTI Context
      Lifetime". MUST NOT be a local in RegisterService: the TRttiMethod
      handed to each wrapper is owned by the context's pool and is used on
      every later dispatch, so a local context freed at the end of
      registration leaves every FMethod dangling. Same shape as
      TProtobufRtti.FContext. }
    class var FCtx:      TRttiContext;
    class procedure LazyInit;
    { Internal — invariant checks + insertion under the already-held lock.
      Used by both RegisterMethod (with Handler) and RegisterService<T>
      (with InvokeMethod). Caller must hold FLock. }
    class procedure InsertLocked(const AInfo: TGrpcMethodInfo);
  public
    { M4a — Register a single method with a procedural handler. Called once
      at startup per method. Raises EGrpcRegistry on invalid input
      (nil handler, non-slash-prefixed path, duplicate registration).

      Example:
        TGrpcRegistry.RegisterMethod(
          '/users.UserService/GetUser',
          TUserRequest, TUserResponse,
          FUserServiceInstance.GetUser); }
    { Registers a server-streaming method (M6a).

        TGrpcRegistry.RegisterServerStream(
          '/greeter.Greeter/ListGreetings',
          TGreetRequest, TGreetReply,
          GreeterImpl.ListGreetings);

      Same path rules as RegisterMethod. AResponseClass is the type of EACH
      streamed message, not of a wrapper. }
    class procedure RegisterServerStream(
      const APath:    string;
      ARequestClass:  TClass;
      AResponseClass: TClass;
      AHandler:       TGrpcServerStreamHandler); static;

    { Registers a client-streaming method (M6b): many requests in, one
      response out. }
    class procedure RegisterClientStream(
      const APath:    string;
      ARequestClass:  TClass;
      AResponseClass: TClass;
      AHandler:       TGrpcClientStreamHandler); static;

    { Registers a bidirectional method (M6b): many in, many out, concurrent. }
    class procedure RegisterBidiStream(
      const APath:    string;
      ARequestClass:  TClass;
      AResponseClass: TClass;
      AHandler:       TGrpcBidiStreamHandler); static;

    { True when APath consumes its request body incrementally — client-stream
      or bidi. Wired to the transport's OnShouldStreamInbound hook, which asks
      once per request on HEADERS, so this must stay a cheap lookup. }
    class function IsInboundStreaming(const APath: string): Boolean; static;

    class procedure RegisterMethod(
      const APath:      string;
      ARequestClass:    TClass;
      AResponseClass:   TClass;
      AHandler:         TGrpcHandler);

    { M4c — Register a whole service interface. Walks TypeInfo(T) via RTTI:
      reads [TGrpcService('name')] attribute for the service name, walks
      each declared method, extracts request class from its single
      `const ARequest: TFoo` parameter, extracts response class from the
      return type, and registers each as `/<Name>/<MethodName>`.

      T must derive from IInvokable and carry [TGrpcService(...)]. AImpl is
      the concrete implementation; the registry holds an interface reference
      so ARC is engaged — override `_AddRef`/`_Release` to return -1 on the
      impl to prevent auto-destruction during dispatch (horse-grpc SKILL §2).

      Example:
        TGrpcRegistry.RegisterService<IGreeter>(TGreeterServiceImpl.Create);

      Raises EGrpcRegistry on invalid input (missing attribute, bad
      method signature, duplicate path). Partial registration is possible
      if failure occurs mid-walk — call Shutdown then re-register. }
    class procedure RegisterService<T: IInvokable>(const AImpl: T);

    { Registry lookup. Returns True + populates AInfo when found;
      False otherwise. Thread-safe. }
    class function TryGet(const APath: string; out AInfo: TGrpcMethodInfo): Boolean;

    { Count of currently-registered methods (for diagnostics). }
    class function Count: Integer;

    { Explicit shutdown — rarely needed; finalization does this too. }
    class procedure Shutdown;
  end;

  { Pre-1.6.0 names. The Horse prefix was a leftover from where these units
    were written; nothing here has ever depended on Horse. ALIASES, not
    subclasses, so `TGrpcRegistry.RegisterService<T>` still resolves to the
    real generic class method and `except on E: EHorseGrpcRegistry` still
    catches what this unit raises. REMOVED IN 2.0.0. }
  THorseGrpc = TGrpcRegistry
    deprecated 'Renamed to TGrpcRegistry. Removed in 2.0.0.';
  EHorseGrpcRegistry = EGrpcRegistry
    deprecated 'Renamed to EGrpcRegistry. Removed in 2.0.0.';

implementation

{$IF DEFINED(FPC) AND NOT DEFINED(HORSE_GRPC_NO_FFI)}
uses
  { Imported for its INITIALIZATION SIDE EFFECT ONLY — nothing here calls
    into it. FPC ships no built-in function-call manager, so a bare
    TRttiMethod.Invoke fails at run time with:

      ENotImplemented: Invoke functionality is not implemented on this
      platform. Use external managers, e.g. ffi.manager.

    ffi.manager (FPC package libffi) registers a libffi-backed manager in
    its initialization section, which is what makes Invoke work. Delphi
    needs none of this — its Invoke is native.

    Build requirements on FPC:
      - add  -Fu<fpc-units>/libffi  to the compile line
      - libffi present at run time (Ubuntu: libffi8; Windows: libffi.dll)

    Escape hatch: define HORSE_GRPC_NO_FFI to drop the dependency. The M4a
    procedural API (RegisterMethod) keeps working — it never touches RTTI
    invoke — but RegisterService<T> will then fail with the ENotImplemented
    above on first call. }
  ffi.manager;
{$IFEND}

// ── TGrpcInvokableWrapper ────────────────────────────────────────────────

constructor TGrpcInvokableWrapper<T>.Create(const AIntf: T; const AMethod: TRttiMethod);
begin
  inherited Create;
  FIntf   := AIntf;
  FMethod := AMethod;
end;

function TGrpcInvokableWrapper<T>.Invoke(const ARequest: TObject): TObject;
var
  LArgs:   array of TValue;
  LResult: TValue;
begin
  SetLength(LArgs, 1);
  LArgs[0] := TValue.From<TObject>(ARequest);

  { Invoke on the interface reference — RTTI dispatches through the vtable.
    `_AddRef`/`_Release` returning -1 on the impl prevents ARC from
    destroying the service instance mid-dispatch (horse-grpc SKILL §2).
    TValue.From<T> (not <IInterface>) keeps the declaring interface's type
    info on the instance value — FPC's invoke path needs it. }
  LResult := FMethod.Invoke(TValue.From<T>(FIntf), LArgs);

  if LResult.IsEmpty or not LResult.IsObject then
    raise EGrpcRegistry.CreateFmt(
      'RegisterService: method %s did not return a TObject instance',
      [FMethod.Name]);

  Result := LResult.AsObject;
end;

// ── TGrpcRegistry ────────────────────────────────────────────────────────────

class procedure TGrpcRegistry.LazyInit;
begin
  if FReady then Exit;
  if FLock = nil then
    FLock := TCriticalSection.Create;
  FLock.Enter;
  try
    if FReady then Exit;
    FRegistry := TDictionary<string, TGrpcMethodInfo>.Create;
    FWrappers := TObjectList<TObject>.Create({AOwnsObjects=}True);
    FReady := True;
  finally
    FLock.Leave;
  end;
end;

class procedure TGrpcRegistry.Shutdown;
begin
  if not FReady then Exit;
  FLock.Enter;
  try
    if not FReady then Exit;
    FRegistry.Free;
    FRegistry := nil;
    FWrappers.Free;   // OwnsObjects=True — frees every wrapper
    FWrappers := nil;
    FCtx.Free;        // releases the RTTI pool token; wrappers are already gone
    FReady := False;
  finally
    FLock.Leave;
  end;
  FLock.Free;
  FLock := nil;
end;

class procedure TGrpcRegistry.InsertLocked(const AInfo: TGrpcMethodInfo);
begin
  if FRegistry.ContainsKey(AInfo.Path) then
    raise EGrpcRegistry.CreateFmt(
      'RegisterMethod: %s already registered — duplicate registration', [AInfo.Path]);
  FRegistry.Add(AInfo.Path, AInfo);
end;

class procedure TGrpcRegistry.RegisterMethod(
  const APath:    string;
  ARequestClass:  TClass;
  AResponseClass: TClass;
  AHandler:       TGrpcHandler);
var
  LInfo: TGrpcMethodInfo;
begin
  if APath = '' then
    raise EGrpcRegistry.Create('RegisterMethod: APath cannot be empty');
  if (Length(APath) < 2) or (APath[1] <> '/') then
    raise EGrpcRegistry.CreateFmt(
      'RegisterMethod: APath %s must start with "/" and follow /<Service>/<Method> form',
      [APath]);
  if ARequestClass = nil then
    raise EGrpcRegistry.CreateFmt('RegisterMethod(%s): ARequestClass is nil', [APath]);
  if AResponseClass = nil then
    raise EGrpcRegistry.CreateFmt('RegisterMethod(%s): AResponseClass is nil', [APath]);
  if not Assigned(AHandler) then
    raise EGrpcRegistry.CreateFmt('RegisterMethod(%s): AHandler is nil', [APath]);

  LazyInit;
  FLock.Enter;
  try
    LInfo.Path           := APath;
    LInfo.RequestClass   := ARequestClass;
    LInfo.ResponseClass  := AResponseClass;
    LInfo.Handler        := AHandler;
    LInfo.InvokeMethod   := nil;
    LInfo.StreamHandler  := nil;
    LInfo.ClientHandler  := nil;
    LInfo.BidiHandler    := nil;
    LInfo.IsServerStream := False;
    LInfo.IsClientStream := False;
    InsertLocked(LInfo);
  finally
    FLock.Leave;
  end;
end;

class procedure TGrpcRegistry.RegisterServerStream(
  const APath:    string;
  ARequestClass:  TClass;
  AResponseClass: TClass;
  AHandler:       TGrpcServerStreamHandler);
var
  LInfo: TGrpcMethodInfo;
begin
  if APath = '' then
    raise EGrpcRegistry.Create('RegisterServerStream: APath cannot be empty');
  if (Length(APath) < 2) or (APath[1] <> '/') then
    raise EGrpcRegistry.CreateFmt(
      'RegisterServerStream: APath %s must start with "/" and follow /<Service>/<Method> form',
      [APath]);
  if ARequestClass = nil then
    raise EGrpcRegistry.CreateFmt('RegisterServerStream(%s): ARequestClass is nil', [APath]);
  if AResponseClass = nil then
    raise EGrpcRegistry.CreateFmt('RegisterServerStream(%s): AResponseClass is nil', [APath]);
  if not Assigned(AHandler) then
    raise EGrpcRegistry.CreateFmt('RegisterServerStream(%s): AHandler is nil', [APath]);

  LazyInit;
  FLock.Enter;
  try
    LInfo.Path           := APath;
    LInfo.RequestClass   := ARequestClass;
    LInfo.ResponseClass  := AResponseClass;
    LInfo.Handler        := nil;
    LInfo.InvokeMethod   := nil;
    LInfo.StreamHandler  := AHandler;
    LInfo.ClientHandler  := nil;
    LInfo.BidiHandler    := nil;
    LInfo.IsServerStream := True;
    LInfo.IsClientStream := False;
    InsertLocked(LInfo);
  finally
    FLock.Leave;
  end;
end;

class procedure TGrpcRegistry.RegisterService<T>(const AImpl: T);
var
  LIntfType:  TRttiInterfaceType;
  LMethods:   TArray<TRttiMethod>;
  LMethod:    TRttiMethod;
  LParams:    TArray<TRttiParameter>;
  LAttr:      TCustomAttribute;
  LSvcName:   string;
  LReqClass:  TClass;
  LRespClass: TClass;
  LWrapper:   TGrpcInvokableWrapper<T>;
  LInfo:      TGrpcMethodInfo;
begin
  if TypeInfo(T) = nil then
    raise EGrpcRegistry.Create(
      'RegisterService<T>: no RTTI for T (compile with {$M+} on the interface unit)');

  LazyInit;

  { `as TRttiInterfaceType` raises EInvalidCast if T isn't an interface —
    no need for a separate nil check. }
  LIntfType := FCtx.GetType(TypeInfo(T)) as TRttiInterfaceType;

  { Locate [TGrpcService('...')] on the interface. Direct `is` test against
    the attribute class — the unit is already in our uses clause, so the
    earlier ClassName-string + RTTI-property dance bought nothing. }
  LSvcName := '';
  for LAttr in LIntfType.GetAttributes do
    if LAttr is TGrpcServiceAttribute then
    begin
      LSvcName := TGrpcServiceAttribute(LAttr).Name;
      Break;
    end;

  if LSvcName = '' then
    raise EGrpcRegistry.CreateFmt(
      'RegisterService<T>: interface %s lacks a [TGrpcService(''name'')] attribute ' +
      '(on FPC, also check the unit declaring it carries the {$RTTI EXPLICIT ...} directive)',
      [LIntfType.Name]);

  { A service interface with zero visible methods means the RTTI directive
    is missing on the declaring unit — fail loudly instead of registering
    nothing and answering UNIMPLEMENTED to every call at run time. }
  LMethods := LIntfType.GetDeclaredMethods;
  if Length(LMethods) = 0 then
    raise EGrpcRegistry.CreateFmt(
      'RegisterService<T>: interface %s exposes no methods via RTTI — ' +
      'declare it in a unit with {$M+} (and, on FPC, {$RTTI EXPLICIT METHODS([vcPublic])})',
      [LIntfType.Name]);

  for LMethod in LMethods do
  begin
    { Signature validation — exactly one class parameter + class return type. }
    LParams := LMethod.GetParameters;
    if Length(LParams) <> 1 then
      raise EGrpcRegistry.CreateFmt(
        'RegisterService(%s.%s): expected 1 parameter, got %d — must be `function %s(const ARequest: TRequestClass): TResponseClass`',
        [LIntfType.Name, LMethod.Name, Length(LParams), LMethod.Name]);
    if (LParams[0].ParamType = nil) or (LParams[0].ParamType.TypeKind <> tkClass) then
      raise EGrpcRegistry.CreateFmt(
        'RegisterService(%s.%s): parameter must be a TObject subclass',
        [LIntfType.Name, LMethod.Name]);
    if (LMethod.ReturnType = nil) or (LMethod.ReturnType.TypeKind <> tkClass) then
      raise EGrpcRegistry.CreateFmt(
        'RegisterService(%s.%s): return type must be a TObject subclass',
        [LIntfType.Name, LMethod.Name]);

    LReqClass  := (LParams[0].ParamType as TRttiInstanceType).MetaclassType;
    LRespClass := (LMethod.ReturnType   as TRttiInstanceType).MetaclassType;

    LWrapper := TGrpcInvokableWrapper<T>.Create(AImpl, LMethod);
    FLock.Enter;
    try
      FWrappers.Add(LWrapper);   { Registry owns; freed on Shutdown }
    finally
      FLock.Leave;
    end;

    LInfo.Path          := '/' + LSvcName + '/' + LMethod.Name;
    LInfo.RequestClass  := LReqClass;
    LInfo.ResponseClass := LRespClass;
    LInfo.Handler       := nil;
    LInfo.InvokeMethod  := LWrapper.Invoke;
    { RegisterService<T> reflects unary methods only. A streaming RPC has no
      natural IInvokable shape — its return is a sequence, not a value — so
      those go through RegisterServerStream explicitly. }
    LInfo.StreamHandler  := nil;
    LInfo.ClientHandler  := nil;
    LInfo.BidiHandler    := nil;
    LInfo.IsServerStream := False;
    LInfo.IsClientStream := False;

    FLock.Enter;
    try
      InsertLocked(LInfo);
    finally
      FLock.Leave;
    end;
  end;
end;


{ Shared validation for the two M6b registrations — identical rules to
  RegisterMethod, differing only in the handler that must be present. }
procedure ValidateStreamPath(const AKind, APath: string;
  ARequestClass, AResponseClass: TClass);
begin
  if APath = '' then
    raise EGrpcRegistry.CreateFmt('%s: APath cannot be empty', [AKind]);
  if (Length(APath) < 2) or (APath[1] <> '/') then
    raise EGrpcRegistry.CreateFmt(
      '%s: APath %s must start with "/" and follow /<Service>/<Method> form',
      [AKind, APath]);
  if ARequestClass = nil then
    raise EGrpcRegistry.CreateFmt('%s(%s): ARequestClass is nil', [AKind, APath]);
  if AResponseClass = nil then
    raise EGrpcRegistry.CreateFmt('%s(%s): AResponseClass is nil', [AKind, APath]);
end;

class procedure TGrpcRegistry.RegisterClientStream(
  const APath:    string;
  ARequestClass:  TClass;
  AResponseClass: TClass;
  AHandler:       TGrpcClientStreamHandler);
var
  LInfo: TGrpcMethodInfo;
begin
  ValidateStreamPath('RegisterClientStream', APath, ARequestClass, AResponseClass);
  if not Assigned(AHandler) then
    raise EGrpcRegistry.CreateFmt('RegisterClientStream(%s): AHandler is nil', [APath]);

  LazyInit;
  FLock.Enter;
  try
    LInfo.Path           := APath;
    LInfo.RequestClass   := ARequestClass;
    LInfo.ResponseClass  := AResponseClass;
    LInfo.Handler        := nil;
    LInfo.InvokeMethod   := nil;
    LInfo.StreamHandler  := nil;
    LInfo.ClientHandler  := AHandler;
    LInfo.BidiHandler    := nil;
    LInfo.IsServerStream := False;
    LInfo.IsClientStream := True;
    InsertLocked(LInfo);
  finally
    FLock.Leave;
  end;
end;

class procedure TGrpcRegistry.RegisterBidiStream(
  const APath:    string;
  ARequestClass:  TClass;
  AResponseClass: TClass;
  AHandler:       TGrpcBidiStreamHandler);
var
  LInfo: TGrpcMethodInfo;
begin
  ValidateStreamPath('RegisterBidiStream', APath, ARequestClass, AResponseClass);
  if not Assigned(AHandler) then
    raise EGrpcRegistry.CreateFmt('RegisterBidiStream(%s): AHandler is nil', [APath]);

  LazyInit;
  FLock.Enter;
  try
    LInfo.Path           := APath;
    LInfo.RequestClass   := ARequestClass;
    LInfo.ResponseClass  := AResponseClass;
    LInfo.Handler        := nil;
    LInfo.InvokeMethod   := nil;
    LInfo.StreamHandler  := nil;
    LInfo.ClientHandler  := nil;
    LInfo.BidiHandler    := AHandler;
    { Bidi is inbound-streaming AND outbound-streaming. Only the inbound half
      concerns the transport hook — the outbound half is the handler's own
      choice of when to call AWriter.Send. }
    LInfo.IsServerStream := False;
    LInfo.IsClientStream := True;
    InsertLocked(LInfo);
  finally
    FLock.Leave;
  end;
end;

class function TGrpcRegistry.IsInboundStreaming(const APath: string): Boolean;
var
  LInfo: TGrpcMethodInfo;
begin
  { Called on the connection thread for EVERY request, before dispatch. An
    unregistered path answers False and takes the ordinary accumulate-then-
    dispatch route, where the dispatcher will reply UNIMPLEMENTED as usual. }
  Result := TryGet(APath, LInfo) and LInfo.IsClientStream;
end;

class function TGrpcRegistry.TryGet(const APath: string; out AInfo: TGrpcMethodInfo): Boolean;
begin
  if not FReady then Exit(False);
  FLock.Enter;
  try
    Result := FRegistry.TryGetValue(APath, AInfo);
  finally
    FLock.Leave;
  end;
end;

class function TGrpcRegistry.Count: Integer;
begin
  if not FReady then Exit(0);
  FLock.Enter;
  try
    Result := FRegistry.Count;
  finally
    FLock.Leave;
  end;
end;

initialization
  // FReady starts False by class-var default; LazyInit bootstraps on first use.

finalization
  TGrpcRegistry.Shutdown;

end.
