program Nghttp2ServerSmoke;

// ============================================================================
//  Nghttp2ServerSmoke - A4. The first stage in this repository that STARTS a
//  server.
//
//  ── Why this exists ──
//
//  `grep -rl TNghttp2Server tests/ tools/` returned nothing until this file.
//  Every other stage is codec or codegen: ProtogenGeneratedCompileCheck only
//  REGISTERS services, and the FPC harness lists samples/grpc-server as
//  compile-only. So "ALL STAGES PASSED" has never meant the transport works.
//
//  That was not noticed by audit. A sample was run on Windows, died with
//  "libnghttp2 could not be loaded", and there was no nghttp2.dll anywhere on
//  the machine - while the suite had been reporting green all day. Both facts
//  were true at once, because nothing here had ever needed the library.
//
//  This is the smallest thing that would have caught it: bind, answer one
//  request over h2c, shut down.
//
//  ── Why it needs no external tool ──
//
//  The library ships both halves. TNghttp2Server serves, TNghttp2Client speaks
//  h2c with prior knowledge, and this program drives one against the other in
//  a single process. No curl, no grpcurl, no fixture server.
//
//  ── The skip must be LOUD ──
//
//  libnghttp2 is a runtime dependency and a machine may legitimately not have
//  it. Absent it, this exits EXIT_SKIP and prints a block that cannot be
//  mistaken for a pass. A silent skip is precisely what let the gap survive:
//  a stage that quietly does nothing reads exactly like a stage that passed.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ServerSmoke.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ServerSmoke.dpr
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  { cthreads MUST come first on Unix: the server starts threads on its first
    connection, and this program makes one. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Types,
  Nghttp2.Native,
  Nghttp2.Server,
  Nghttp2.Client;

const
  { High and specific, to avoid colliding with anything else a developer may
    have listening - samples use 19000 and 50051, the provider suite 9000. }
  PORT = 19311;

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

var
  GPass: Integer = 0;
  GFail: Integer = 0;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    WriteLn('  PASS  ', AName);
    Inc(GPass);
  end
  else
  begin
    if ADetail = '' then
      WriteLn('  FAIL  ', AName)
    else
      WriteLn('  FAIL  ', AName, '  [', ADetail, ']');
    Inc(GFail);
  end;
end;

{ OnRequest is a PLAIN procedure type - not `of object`, not an anonymous
  method - because that is the only shape which compiles on FPC without
  FUNCTIONREFERENCES. }
procedure HandleRequest(const AStream: INghttp2Stream);
begin
  if AStream.Header[':path'] = '/smoke' then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes('ok'));
  end
  else
  begin
    { A second path, so the test proves the request REACHED the handler and was
      routed - not merely that something answered. A server that returned 200
      to everything would pass a one-path check. }
    AStream.StatusCode := 404;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes('nope'));
  end;
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;
  GClient: TNghttp2Client;
  GResp:   TNghttp2Response;

begin
  WriteLn('Nghttp2ServerSmoke - does the transport actually run here?');
  WriteLn;

  { The skip decision, made by ASKING rather than by catching. NghttpLoad is
    idempotent and returns False instead of raising, so the absent-library case
    is an ordinary branch rather than an exception path. }
  if not NghttpLoad then
  begin
    WriteLn('  ================================================================');
    WriteLn('   SKIPPED - libnghttp2 is not present on this machine.');
    WriteLn('   ', NghttpLoadError);
    WriteLn;
    WriteLn('   This stage is the ONLY one here that starts a server. Every');
    WriteLn('   other stage passes without the library, so a green run that');
    WriteLn('   skipped this one has NOT exercised the transport at all.');
    WriteLn;
    WriteLn('   Windows: see doc/getting-nghttp2-windows.md - the bitness must');
    WriteLn('   match the compiler (dcc64 needs the Win64 DLL).');
    WriteLn('  ================================================================');
    ExitCode := EXIT_SKIP;
    Exit;
  end;

  GServer := TNghttp2Server.Create;
  try
    GServer.OnRequest := HandleRequest;
    GConfig      := TNghttp2Config.Default;
    GConfig.Port := PORT;

    try
      GServer.Start(GConfig);
    except
      on E: Exception do
      begin
        WriteLn('  FAIL  server did not start: ', E.ClassName, ': ', E.Message);
        ExitCode := EXIT_FAIL;
        Exit;
      end;
    end;
    Check('server bound and started on port ' + IntToStr(PORT), True);

    GClient := TNghttp2Client.Create;
    try
      GClient.Connect('127.0.0.1', PORT);
      Check('client connected over h2c (prior knowledge)', GClient.Connected);

      GResp := GClient.SubmitRequest('GET', '/smoke', nil, nil);
      Check('GET /smoke returned 200', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));
      Check('GET /smoke returned the handler''s body',
            TEncoding.UTF8.GetString(GResp.Body) = 'ok',
            TEncoding.UTF8.GetString(GResp.Body));

      { Routing, not just liveness. }
      GResp := GClient.SubmitRequest('GET', '/nothing-here', nil, nil);
      Check('an unrouted path returned 404', GResp.Status = 404,
            'status ' + IntToStr(GResp.Status));
    finally
      GClient.Free;
    end;

    GServer.Stop;
    Check('server stopped cleanly', True);
  finally
    GServer.Free;
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed');
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
