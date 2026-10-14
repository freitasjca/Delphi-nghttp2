program ProtogenGeneratedCompileCheck;

// ============================================================================
//  C6a — make a COMPILER read protogen's output.
//
//  Every gate so far compares generated text against expected text. None of
//  them has ever compiled a generated unit, so anything the emitters get
//  wrong at the language level — a type that does not exist, a method pointer
//  that is not assignment-compatible, a missing unit in a uses clause — is
//  invisible to all 228 checks.
//
//  This program exists to close that gap. It uses all four generated units and
//  calls the generated registration procedure, so the compiler must resolve
//  every type, every signature and every uses clause protogen emitted.
//
//  The specific thing under test: the generated
//      TGrpcRegistry.RegisterService<IGreeter>(AImpl)
//  passes the impl CLASS where the generic expects the INTERFACE. That relies
//  on an implicit class-to-interface conversion which was reasoned about but
//  never verified — the emit gates prove protogen writes that line, not that
//  the line compiles.
//
//  GC6 (B2 client plan) adds the fifth unit, Sample.Greeter.Client, and a
//  ROUND TRIP: a live TNghttp2Server dispatches to the generated skeleton, and
//  the generated client calls Greet, Echo (with options) and ListGreetings
//  through it. The skeleton raises ENotImplemented naming the method, so each
//  call must come back 13 INTERNAL carrying THAT method's name. A path the
//  client and the registration disagree on would come back 12 instead, so this
//  is where client/server path drift would show.
//
//  Usage — generate first, then compile against the output directory:
//
//    Protogen.exe -i <path>\greeter.proto -o %TEMP%\protogen-out ^
//                 --unit-prefix Sample --client
//
//    dcc64 -B -U"%TEMP%\protogen-out;..\..\src" ProtogenGeneratedCompileCheck.dpr
//
//  A successful COMPILE is the result. Running it additionally proves the
//  registration calls execute against a live registry.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Native,
  Nghttp2.Types,
  Nghttp2.Server,
  Nghttp2.Grpc.Registry,
  Nghttp2.Grpc.Dispatcher,
  Nghttp2.Grpc.Framing,
  Nghttp2.Grpc.Client,
  Sample.Greeter.Messages,
  Sample.Greeter.Interfaces,
  Sample.Greeter.Service,
  Sample.Greeter.Registration,
  Sample.Greeter.Client;

const
  PORT = 19334;

var
  GImpl: TGreeterServiceImpl;

procedure HandleRequest(const AStream: INghttp2Stream);
begin
  if TGrpcDispatcher.TryDispatch(AStream) then
    Exit;
  AStream.StatusCode := 404;
  AStream.Send(TEncoding.UTF8.GetBytes('not grpc'));
end;

procedure Report(const AName: string; APassed: Boolean; const AGot: string);
begin
  if APassed then
    WriteLn('PASS: ', AName)
  else
  begin
    WriteLn('FAIL: ', AName, ' - got ', AGot);
    ExitCode := 1;
  end;
end;

// The skeleton's answer for one method: status 13 and the method's name.
function IsSkeletonAnswer(AStatus: Integer; const AMessage, AMethod: string): Boolean;
begin
  Result := (AStatus = GRPC_STATUS_INTERNAL) and
    (Pos('TGreeterServiceImpl.' + AMethod, AMessage) > 0);
end;

procedure RoundTrip;
var
  LServer:  TNghttp2Server;
  LConfig:  TNghttp2Config;
  LChannel: TGrpcChannel;
  LClient:  TGreeterClient;
  LGreet:   TGreetRequest;
  LEcho:    TEchoRequest;
  LOpts:    TGrpcCallOptions;
  LStream:  TGreeterListGreetingsStream;
  LStatus, LCount: Integer;
  LMsg, LGot: string;
begin
  LServer := TNghttp2Server.Create;
  try
    LServer.OnRequest := HandleRequest;
    LConfig      := TNghttp2Config.Default;
    LConfig.Port := PORT;
    LServer.Start(LConfig);

    LChannel := TGrpcChannel.Create('127.0.0.1', PORT);
    LClient  := TGreeterClient.Create(LChannel);
    LGreet   := TGreetRequest.Create;
    LEcho    := TEchoRequest.Create;
    try
      LGreet.name := 'gc6';

      // Unary, plain overload.
      LStatus := -1; LMsg := ''; LGot := 'a reply';
      try
        LClient.Greet(LGreet).Free;
      except
        on E: EGrpcClientError do
        begin
          LStatus := E.Status; LMsg := E.GrpcMessage;
          LGot := Format('%d "%s"', [LStatus, LMsg]);
        end;
        on E: Exception do
          LGot := E.ClassName + ': ' + E.Message;
      end;
      Report('client Greet reached the server''s Greet (13 from the skeleton)',
        IsSkeletonAnswer(LStatus, LMsg, 'Greet'), LGot);

      // Unary, options overload.
      LOpts := TGrpcCallOptions.Default;
      LOpts.DeadlineMS := 5000;
      LStatus := -1; LMsg := ''; LGot := 'a reply';
      try
        LClient.Echo(LEcho, LOpts).Free;
      except
        on E: EGrpcClientError do
        begin
          LStatus := E.Status; LMsg := E.GrpcMessage;
          LGot := Format('%d "%s"', [LStatus, LMsg]);
        end;
        on E: Exception do
          LGot := E.ClassName + ': ' + E.Message;
      end;
      Report('client Echo with options reached the server''s Echo',
        IsSkeletonAnswer(LStatus, LMsg, 'Echo'), LGot);

      // Server streaming, through the typed wrapper.
      LStatus := -1; LMsg := ''; LCount := 0; LGot := 'a clean end';
      try
        LStream := LClient.ListGreetings(LGreet);
        try
          while LStream.MoveNext do
            Inc(LCount);
        finally
          LStream.Free;
        end;
      except
        on E: EGrpcClientError do
        begin
          LStatus := E.Status; LMsg := E.GrpcMessage;
          LGot := Format('%d "%s"', [LStatus, LMsg]);
        end;
        on E: Exception do
          LGot := E.ClassName + ': ' + E.Message;
      end;
      Report('client ListGreetings reached the server''s ListGreetings, no message',
        IsSkeletonAnswer(LStatus, LMsg, 'ListGreetings') and (LCount = 0),
        Format('%s after %d message(s)', [LGot, LCount]));
    finally
      LEcho.Free;
      LGreet.Free;
      LClient.Free;
      LChannel.Free;
    end;
    LServer.Stop;
  finally
    LServer.Free;
  end;
end;

begin
  try
    { The skeleton's stubs all raise ENotImplemented, so nothing here invokes a
      handler — the point is that the compiler had to accept them.

      Deliberately NOT freed. TGreeterServiceImpl descends from
      TInterfacedObject and does not override _AddRef/_Release (see the note in
      Sample.Greeter.Service.pas — overriding them causes an FPC-trunk AV when
      the interface enters a generic method). RegisterService<IGreeter> stores
      an interface reference, so the registry owns the instance from that point
      and a manual Free here would drop it under the registry's feet. Process
      exit reclaims it. }
    GImpl := TGreeterServiceImpl.Create;
    RegisterGreeter(GImpl);

    WriteLn('generated units compiled, and registration executed.');
    WriteLn('methods registered: ', TGrpcRegistry.Count);

    { greeter.proto declares five rpcs: two unary reached through
      RegisterService<IGreeter>, plus server-streaming, client-streaming and
      bidi registered explicitly. Anything less means an rpc was silently
      dropped somewhere between the parser and the registration unit — the
      failure mode that would otherwise show up as an unimplemented path at
      runtime with nothing in the build to explain it. }
    if TGrpcRegistry.Count <> 5 then
    begin
      WriteLn('FAIL: expected 5 registered methods, got ', TGrpcRegistry.Count);
      ExitCode := 1;
    end
    else
      WriteLn('PASS: all five rpcs registered.');

    // GC6. libnghttp2 is required by every other live stage of both runners,
    // so its absence here is a failure, not a skip.
    if not NghttpLoad then
    begin
      WriteLn('FAIL: libnghttp2 not loaded, the client round trip did not run - ',
        NghttpLoadError);
      ExitCode := 1;
    end
    else
      RoundTrip;
  except
    on E: Exception do
    begin
      WriteLn('FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
