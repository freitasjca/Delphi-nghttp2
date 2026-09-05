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
//  Usage — generate first, then compile against the output directory:
//
//    Protogen.exe -i <path>\greeter.proto -o %TEMP%\protogen-out ^
//                 --unit-prefix Sample.Greeter
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
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Grpc.Registry,
  Sample.Greeter.Messages,
  Sample.Greeter.Interfaces,
  Sample.Greeter.Service,
  Sample.Greeter.Registration;

var
  GImpl: TGreeterServiceImpl;

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
  except
    on E: Exception do
    begin
      WriteLn('FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
