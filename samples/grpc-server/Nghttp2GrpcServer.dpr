program Nghttp2GrpcServer;

// ============================================================================
//  Nghttp2GrpcServer — a gRPC server built on Delphi-nghttp2 and nothing else.
//
//  THE POINT OF THIS SAMPLE is what is absent from the uses clause. There is
//  no Horse, no web framework, no adapter layer: a TNghttp2Server, a handler
//  that is a plain procedure, and TGrpcDispatcher.TryDispatch. If the gRPC
//  layer had any framework dependency left in it, this program could not be
//  written — which is precisely why it exists rather than a README paragraph
//  asserting the same thing.
//
//  It also shows gRPC and ordinary HTTP/2 sharing one port and one connection:
//  TryDispatch answers `application/grpc*` and returns False for everything
//  else, so the fall-through below serves a plain /health on the same listener.
//
//  Registration uses the PROCEDURAL style (RegisterMethod) rather than
//  RegisterService<T>. Both work; procedural is used here because it never
//  touches TRttiMethod.Invoke, so it needs no libffi on FPC and runs on any
//  compiler that can build the layer at all.
//
//  Build — Delphi:
//    dcc64 -U"..\..\src" Nghttp2GrpcServer.dpr
//
//  Build — FPC (trunk 3.3.1; 3.2.2 cannot build the gRPC layer, its Rtti unit
//  declares no TCustomAttribute):
//    fpc -MDelphi -dNGHTTP2_GRPC_NO_FFI -Fu../../src -Fu. Nghttp2GrpcServer.dpr
//
//  The define matters and is not optional. Without it Nghttp2.Grpc.Registry
//  pulls in ffi.manager, which needs libffi units on the search path, and the
//  build stops with "Can't find unit ffi.manager". ffi.manager exists to make
//  TRttiMethod.Invoke work on FPC — which RegisterService<T> needs and
//  RegisterMethod never does. This sample uses only RegisterMethod, so the
//  dependency is dropped. Reinstate it (define OFF, -Fu<units>/libffi ON) if
//  you switch to RegisterService<T>. Delphi has a native Invoke and needs none
//  of this.
//
//  Run, then from another shell:
//    grpcurl -plaintext -import-path . -proto echo.proto \
//            -d '{"name":"World"}' localhost:19000 echo.Echo/Say
//    curl --http2-prior-knowledge http://localhost:19000/health
//
//  Requires libnghttp2 >= 1.59 at run time (nghttp2.dll / libnghttp2.so.14).
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

uses
{$IF DEFINED(FPC)}
  { cthreads MUST come first on Unix, before anything that might start a
    thread — the server does, on its first connection. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Types,
  Nghttp2.Server,
  Nghttp2.Grpc.Registry,
  Nghttp2.Grpc.Dispatcher,
  Sample.Echo.Messages in 'Sample.Echo.Messages.pas';

const
  PORT = 19000;

type
  { Handlers are `procedure(const AReq, AResp: TObject) of object`, so they
    need an instance. The dispatcher creates BOTH objects and frees BOTH —
    a handler fills the response in and must not free either one. }
  TEchoService = class
  public
    procedure Say(const AReq: TObject; const AResp: TObject);
    procedure Upper(const AReq: TObject; const AResp: TObject);
  end;

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

{ OnRequest is a PLAIN procedure type — not `of object`, not an anonymous
  method. That is deliberate on the library's side: a plain type accepts a
  unit-scope trampoline, which is the only shape that compiles on FPC without
  FUNCTIONREFERENCES. }
procedure HandleRequest(const AStream: INghttp2Stream);
var
  LBody: TBytes;
begin
  { gRPC first. Returns True when the request was application/grpc* and has
    been answered in full — body plus grpc-status trailer. }
  if TGrpcDispatcher.TryDispatch(AStream) then
    Exit;

  { Everything else is ordinary HTTP/2 on the same listener. }
  if AStream.Header[':path'] = '/health' then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'application/json';
    LBody := TEncoding.UTF8.GetBytes('{"status":"ok"}');
  end
  else
  begin
    AStream.StatusCode := 404;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    LBody := TEncoding.UTF8.GetBytes('not found');
  end;
  AStream.Send(LBody);
end;

var
  GService: TEchoService;
  GServer:  TNghttp2Server;
  GConfig:  TNghttp2Config;

begin
  GService := TEchoService.Create;
  try
    { Path convention is `/<package>.<Service>/<Method>`, matching echo.proto.
      Case-sensitive, no normalisation — it is compared as given. }
    TGrpcRegistry.RegisterMethod('/echo.Echo/Say',
      TSayRequest, TSayResponse, GService.Say);
    TGrpcRegistry.RegisterMethod('/echo.Echo/Upper',
      TSayRequest, TSayResponse, GService.Upper);

    GServer := TNghttp2Server.Create;
    try
      GServer.OnRequest := HandleRequest;

      GConfig      := TNghttp2Config.Default;
      GConfig.Port := PORT;
      { Start loads libnghttp2 and raises if it is missing, then binds. }
      GServer.Start(GConfig);

      WriteLn(Format('gRPC + HTTP/2 on h2c://localhost:%d  (%d methods)',
                     [PORT, TGrpcRegistry.Count]));
      WriteLn('  grpcurl -plaintext -import-path . -proto echo.proto \');
      WriteLn('          -d ''{"name":"World"}'' localhost:', PORT, ' echo.Echo/Say');
      WriteLn('  curl --http2-prior-knowledge http://localhost:', PORT, '/health');
      WriteLn;
      WriteLn('ENTER to stop.');
      ReadLn;

      GServer.Stop;
    finally
      GServer.Free;
    end;

    { Before the service instance goes: the registry holds method pointers
      into it. Nothing dispatches after Stop, so this is belt-and-braces —
      but the ordering is the point worth copying. }
    TGrpcRegistry.Shutdown;
  finally
    GService.Free;
  end;
end.
