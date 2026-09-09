program RestAndGrpc;

// ============================================================================
//  RestAndGrpc — one binary, two listeners.
//
//  Horse answers REST on :9000 with its full middleware pipeline, over an
//  HTTP/1.1 transport. Delphi-nghttp2 answers gRPC on :50051. Same process,
//  same executable, and they share nothing else.
//
//  ── Why this is not a contradiction ──
//
//  A Horse provider is selected by a compile-time define and they are mutually
//  exclusive: HORSE_PROVIDER_NGHTTP2 cannot be combined with
//  HORSE_PROVIDER_CROSSSOCKET. One binary, one transport that owns Horse's
//  socket. THorseInstance gives several logical servers, but all on that one
//  transport, so it does not change this.
//
//  What that constraint binds is Horse PROVIDERS. Serving gRPC here needs no
//  provider at all — the gRPC layer takes an INghttp2Stream and nothing else.
//  So the second listener is not a second Horse; it is the library used
//  directly, and the define never comes into it.
//
//  Look at the uses clause below. `Horse` and the CrossSocket provider are
//  there for the REST half. `Nghttp2.*` is there for the gRPC half. Neither
//  group references the other, and that is the whole design.
//
//  ── Threading ──
//
//  TNghttp2Server.Start is NON-BLOCKING: it binds, spawns its own threads and
//  returns. THorse.Listen blocks. So gRPC starts first and Horse owns the main
//  thread — no thread is created by this file, and none is needed.
//
//  ── Build ──
//
//  Delphi (from this directory). The -NS list is NOT optional: several Horse
//  units spell RTL units unqualified (`SyncObjs`, not `System.SyncObjs`), and
//  unit scope names are what resolve those. The IDE supplies them from project
//  options; a bare dcc64 command line does not, and the build dies 18 units in
//  with "F2613 Unit 'SyncObjs' not found". The -I paths are separate from -U
//  and equally required: a unit path does not satisfy an include, and every
//  Delphi-Cross-Socket unit opens {$I zLib.inc} from that repo's ROOT.
//    dcc64 -DHORSE_PROVIDER_CROSSSOCKET ^
//      "-NSSystem;System.Win;Winapi;Data;Web;Xml" ^
//      -U..\..\src ^
//      -U..\..\..\horse\src ^
//      -U..\..\..\horse-provider-crosssocket\src ^
//      -U..\..\..\Delphi-Cross-Socket\Net ^
//      -U..\..\..\Delphi-Cross-Socket\Utils ^
//      -U..\..\..\Delphi-Cross-Socket\CnPack\Common ^
//      -U..\..\..\Delphi-Cross-Socket\CnPack\Crypto ^
//      -I..\..\..\Delphi-Cross-Socket ^
//      -I..\..\..\Delphi-Cross-Socket\CnPack\Common ^
//      -U..\grpc-server ^
//      RestAndGrpc.dpr
//
//  FPC trunk 3.3.1 (3.2.2 cannot build the gRPC layer — its Rtti unit declares
//  no TCustomAttribute):
//  (FPC needs no equivalent — it has no unit scope names, and the FPC branch
//  of those uses clauses spells everything unqualified already.)
//
//    fpc -MDelphi -dHORSE_PROVIDER_CROSSSOCKET -dNGHTTP2_GRPC_NO_FFI \
//        -Fu../../src -Fu../../../horse/src \
//        -Fu../../../horse-provider-crosssocket/src \
//        -Fu../../../Delphi-Cross-Socket/Net -Fu../grpc-server \
//        RestAndGrpc.dpr
//
//  NGHTTP2_GRPC_NO_FFI is required on FPC and only because this sample
//  registers with RegisterMethod. See the note above the registry calls.
//
//  ── Run ──
//
//    curl http://localhost:9000/ping
//    curl http://localhost:9000/health
//    grpcurl -plaintext -import-path ../grpc-server -proto echo.proto \
//            -d '{"name":"World"}' localhost:50051 echo.Echo/Say
//
//  Requires libnghttp2 >= 1.59 at run time for the gRPC half only. The REST
//  half has no native dependency.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

{$IF NOT DEFINED(HORSE_PROVIDER_CROSSSOCKET) AND NOT DEFINED(HORSE_CROSSSOCKET)}
  {$MESSAGE FATAL 'Define HORSE_PROVIDER_CROSSSOCKET (or another HTTP/1.1 provider). This sample deliberately does NOT use HORSE_PROVIDER_NGHTTP2 — the gRPC half needs no provider.'}
{$IFEND}

uses
{$IF DEFINED(FPC)}
  { cthreads MUST come first on Unix, before anything that might start a
    thread — both servers do. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
{$IF DEFINED(LINUX) AND NOT DEFINED(FPC)}
  Posix.Signal,
{$IFEND}
  { ── the REST half ── }
  Horse,
  { Only so the inline accessors behind THorse.ActiveRequests and
    THorse.IsShuttingDown can be expanded. Without it the build is still
    correct, but Delphi emits H2443 for each — "inline function has not been
    expanded because unit 'Horse.Core' is not specified in USES list" — and a
    sample that others copy should compile clean. }
  Horse.Core,
  { ── the gRPC half: note that nothing below knows Horse exists ── }
  Nghttp2.Types,
  Nghttp2.Server,
  Nghttp2.Grpc.Registry,
  Nghttp2.Grpc.Dispatcher,
  Sample.Echo.Messages;

const
  REST_PORT = 9000;
  GRPC_PORT = 50051;

type
  { gRPC handlers are `procedure(const AReq, AResp: TObject) of object`, so they
    need an instance. The dispatcher creates BOTH objects and frees BOTH — a
    handler fills the response in and must not free either. }
  TEchoService = class
  public
    procedure Say(const AReq: TObject; const AResp: TObject);
    procedure Upper(const AReq: TObject; const AResp: TObject);
  end;

var
  GService: TEchoService;
  GGrpc:    TNghttp2Server;
  GConfig:  TNghttp2Config;

// ── gRPC service ────────────────────────────────────────────────────────────

procedure TEchoService.Say(const AReq: TObject; const AResp: TObject);
var
  LReq:  TSayRequest;
  LResp: TSayResponse;
begin
  LReq  := TSayRequest(AReq);
  LResp := TSayResponse(AResp);
  LResp.text   := 'Hello, ' + LReq.name + '!';
  LResp.length := Length(LResp.text);
end;

procedure TEchoService.Upper(const AReq: TObject; const AResp: TObject);
var
  LReq:  TSayRequest;
  LResp: TSayResponse;
begin
  LReq  := TSayRequest(AReq);
  LResp := TSayResponse(AResp);
  LResp.text   := UpperCase(LReq.name);
  LResp.length := Length(LResp.text);
end;

{ The nghttp2 stream handler. OnRequest is a PLAIN procedure type — not
  `of object`, not an anonymous method — because a plain type is the only shape
  that compiles on FPC without FUNCTIONREFERENCES. }
procedure HandleGrpcStream(const AStream: INghttp2Stream);
var
  LBody: TBytes;
begin
  { Returns True when the request was application/grpc* and has been answered
    in full, body plus grpc-status trailer. }
  if TGrpcDispatcher.TryDispatch(AStream) then
    Exit;

  { Anything non-gRPC that reaches the gRPC port. Deliberately terse: the REST
    surface lives on the other listener, and answering it here too would blur
    exactly the separation this sample exists to show. }
  AStream.StatusCode := 404;
  AStream.Header['content-type'] := 'text/plain; charset=utf-8';
  LBody := TEncoding.UTF8.GetBytes('this port serves gRPC only; REST is on '
    + IntToStr(REST_PORT));
  AStream.Send(LBody);
end;

// ── REST routes ─────────────────────────────────────────────────────────────
//
// Plain unit-scope procedures, not anonymous methods. Horse's own guidance is
// to avoid inline anonymous procedures in routes so the same source compiles
// on FPC/Lazarus, where they are not available.

procedure GetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('text/plain; charset=utf-8');
  Res.Send('pong');
end;

{ Reports both listeners, and reads the framework's own telemetry rather than
  counting anything itself — ActiveRequests and IsShuttingDown are exposed on
  the facade precisely so a health endpoint can use them. }
procedure GetHealth(Req: THorseRequest; Res: THorseResponse);
var
  LStatus: string;
begin
  { Not BoolToStr: with UseBoolStrs False it yields '0'/'-1', so the field read
    "status":"0" — technically the answer, useless to a load balancer. A health
    endpoint is consumed by something deciding whether to send traffic, so it
    says which state it is in, in words. }
  if THorse.IsShuttingDown then
    LStatus := 'draining'
  else
    LStatus := 'ok';

  Res.ContentType('application/json');
  Res.Send(Format(
    '{"status":"%s","rest":{"port":%d,"activeRequests":%d},' +
    '"grpc":{"port":%d,"methods":%d}}',
    [LStatus,
     REST_PORT, THorse.ActiveRequests,
     GRPC_PORT, TGrpcRegistry.Count]));
end;

{ Shows the two halves meeting in application code rather than in the plumbing:
  an ordinary REST route calling the same object the gRPC dispatcher calls. }
procedure GetEcho(Req: THorseRequest; Res: THorseResponse);
var
  LReq:  TSayRequest;
  LResp: TSayResponse;
begin
  LReq  := TSayRequest.Create;
  LResp := TSayResponse.Create;
  try
    LReq.name := Req.Query.Field('name').AsString;
    GService.Say(LReq, LResp);
    Res.ContentType('application/json');
    Res.Send(Format('{"text":"%s","length":%d}', [LResp.text, LResp.length]));
  finally
    LResp.Free;
    LReq.Free;
  end;
end;

{$IF DEFINED(LINUX) AND NOT DEFINED(FPC)}
{ Unblocks the Listen below, so the finally clause runs and both servers shut
  down in order. Setting a flag instead would not work: on Linux Listen BLOCKS,
  so nothing would be left to poll the flag. }
procedure HandleSignal(Sig: Integer); cdecl;
begin
  THorse.StopListen;
end;
{$IFEND}

// ── main ────────────────────────────────────────────────────────────────────

begin
{$IFDEF MSWINDOWS}
  { IsConsole := False makes THorse.Listen non-blocking, so the main thread can
    wait on ReadLn and shut both servers down in order. }
  IsConsole := False;
  ReportMemoryLeaksOnShutdown := True;
{$ENDIF}
{$IF DEFINED(LINUX) AND NOT DEFINED(FPC)}
  signal(SIGTERM, HandleSignal);
  signal(SIGINT,  HandleSignal);
{$IFEND}

  GService := TEchoService.Create;
  try
    // ── 1. gRPC: register, then start. Start binds and returns. ────────────
    //
    // RegisterMethod is the PROCEDURAL style. It never reaches
    // TRttiMethod.Invoke, so it needs no libffi on FPC — which is why this
    // sample builds with -dNGHTTP2_GRPC_NO_FFI. RegisterService<T> is the
    // other style and does need it.
    TGrpcRegistry.RegisterMethod('/echo.Echo/Say',
      TSayRequest, TSayResponse, GService.Say);
    TGrpcRegistry.RegisterMethod('/echo.Echo/Upper',
      TSayRequest, TSayResponse, GService.Upper);

    GGrpc := TNghttp2Server.Create;
    try
      GGrpc.OnRequest := HandleGrpcStream;

      GConfig      := TNghttp2Config.Default;
      GConfig.Port := GRPC_PORT;
      { Start loads libnghttp2 and raises if it is missing. Deliberately before
        the REST routes: if the native library is absent this fails now, with a
        clear message, instead of after the HTTP listener is already up. }
      GGrpc.Start(GConfig);

      // ── 2. REST: ordinary Horse, ordinary provider ──────────────────────
      THorse.Get('/ping',   GetPing);
      THorse.Get('/health', GetHealth);
      THorse.Get('/echo',   GetEcho);

      WriteLn('REST  http://localhost:', REST_PORT, '/ping   (HTTP/1.1, Horse pipeline)');
      WriteLn('gRPC  h2c://localhost:',  GRPC_PORT, '        (',
              TGrpcRegistry.Count, ' methods, no framework)');
      WriteLn;

      try
        { ── 3. Horse owns the main thread. ──────────────────────────────────
          On Windows IsConsole := False above makes this return immediately, so
          the ReadLn is what holds the process open. Everywhere else it BLOCKS
          until StopListen is called — from the signal handler, or by whatever
          supervises the process. Two shapes, one line, and the difference is
          worth knowing before copying this. }
        THorse.Listen(REST_PORT);

      {$IFDEF MSWINDOWS}
        WriteLn('ENTER to stop.');
        ReadLn;
      {$ENDIF}
      finally
        // ── 4. Drain REST first, then stop gRPC. ──────────────────────────
        //
        // Order matters. A Horse route may call into the same objects the gRPC
        // dispatcher uses (GetEcho does), so let in-flight requests finish
        // before anything they might touch goes away.
        THorse.StopListenGraceful(5000);
        GGrpc.Stop;
      end;
    finally
      GGrpc.Free;
    end;

    { The registry holds method pointers into GService, so it must be torn down
      before the instance is. Nothing dispatches after Stop, so this is
      belt-and-braces — but the ordering is the part worth copying. }
    TGrpcRegistry.Shutdown;
  finally
    GService.Free;
  end;
end.
