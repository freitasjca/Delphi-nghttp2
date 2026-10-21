program Nghttp2AsyncClient;

// ============================================================================
//  Nghttp2AsyncClient - the async HTTP/2 client API, end to end.
//
//  A self-contained demo: it starts an in-process TNghttp2Server on loopback,
//  then drives TNghttp2Client against it two ways.
//
//    1. The ASYNC API (CL6). Submit N requests from ONE thread with
//       BeginRequest, then pump cooperatively - Pump(ms) in a loop until it
//       returns 0 - and let an OnComplete callback reap each stream as it
//       finishes. There is no background thread: the library spins none
//       (libnghttp2's one-driver rule), so the whole flight runs on this thread
//       and the caller stays free to do other work between pump passes.
//
//    2. The CONNECTION POOL (CL5). Acquire a pooled connection, use it, release
//       it, acquire again - and watch Stats show the second Acquire REUSED the
//       first connection rather than opening a second.
//
//  This is the sample "beyond PingClient": PingClient is one blocking GET;
//  this shows many requests in flight at once, and the pool. The full client
//  reference is doc/client.md.
//
//  Build (Windows, Delphi):  dcc64 -CC -B -U..\..\src Nghttp2AsyncClient.dpr
//  Build (FPC):              fpc -MDelphi -Fu../../src Nghttp2AsyncClient.dpr
//  Run:                      ./Nghttp2AsyncClient
//
//  Needs libnghttp2 on the runtime search path - see doc/getting-nghttp2-linux.md
//  or doc/getting-nghttp2-windows.md.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  {$IFDEF UNIX}cthreads,{$ENDIF}   // the server's accept/connection threads
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Types,
  Nghttp2.Native,
  Nghttp2.Server,
  Nghttp2.Client,
  Nghttp2.Client.Pool;

const
  PORT       = 18080;   // loopback demo server
  NREQ       = 20;      // requests in flight at once
  PUMP_MS    = 200;     // one bounded pump pass
  OVERALL_MS = 10000;   // safety cap on the whole pump loop

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;
  GDone:   Integer = 0;   // OnComplete calls (single-threaded: this thread)
  GOk:     Integer = 0;   // of those, the ones that returned 200

{ The in-process server: one tiny route, always 200 "pong". Runs on the
  server's own connection thread, so it touches only its stream - never the
  client-side counters below. }
procedure HandleRequest(const AStream: INghttp2Stream);
begin
  AStream.StatusCode := 200;
  AStream.Header['content-type'] := 'text/plain; charset=utf-8';
  AStream.Send(TEncoding.UTF8.GetBytes('pong'));
end;

function ElapsedMS(const AStart: TDateTime): Int64;
begin
  Result := Round((Now - AStart) * 86400.0 * 1000.0);
end;

{ OnComplete: the pump calls this once per stream as it reaches a terminal
  state. Reap the stream here (push) instead of polling TakeResponse. A plain
  procedure, which is why the client type is a plain procedure and not a
  reference-to - it keeps the client FPC 3.2.2-clean. }
procedure OnStreamDone(AClient: TNghttp2Client; AStreamId: Int32);
var
  LResp: TNghttp2Response;
begin
  Inc(GDone);
  try
    LResp := AClient.TakeResponse(AStreamId);   // raises for a failed stream
    if LResp.Status = 200 then
      Inc(GOk);
  except
    on E: Exception do
      WriteLn('    stream ', AStreamId, ' failed: ', E.Message);
  end;
end;

{ 1 - the async API: N requests in flight from one thread, completed by push. }
procedure DemoAsync;
var
  LC:     TNghttp2Client;
  LStart: TDateTime;
  I:      Integer;
begin
  WriteLn('[1] async: ', NREQ, ' requests in flight from one thread');
  LC := TNghttp2Client.Create;
  try
    LC.Connect('127.0.0.1', PORT);
    LC.OnComplete := OnStreamDone;

    for I := 1 to NREQ do
      LC.BeginRequest('GET', '/ping', nil, nil);   // returns at once

    LStart := Now;
    while (LC.Pump(PUMP_MS) > 0) and (ElapsedMS(LStart) < OVERALL_MS) do
      ;   // nothing is blocked between passes - do other work here if you like

    WriteLn('    completed ', GDone, '/', NREQ, ', ', GOk, ' returned 200');
  finally
    LC.Free;
  end;
end;

{ 2 - the pool: one connection reused across Acquire / Release. }
procedure DemoPool;
var
  LPool:  TNghttp2ClientPool;
  LC:     TNghttp2Client;
  LR:     TNghttp2Response;
  LStats: TNghttp2ClientPoolStats;
begin
  WriteLn('[2] pool: acquire, release, acquire again (reuse)');
  LPool := TNghttp2ClientPool.Create;
  try
    LC := LPool.Acquire('127.0.0.1', PORT);   // AUseTls defaults False (h2c)
    try
      LR := LC.SubmitRequest('GET', '/ping', nil, nil);
      WriteLn('    first acquire  -> status ', LR.Status);
    finally
      LPool.Release(LC);                       // back to the idle set
    end;

    LC := LPool.Acquire('127.0.0.1', PORT);    // same key: reuses the idle one
    try
      LR := LC.SubmitRequest('GET', '/ping', nil, nil);
      WriteLn('    second acquire -> status ', LR.Status);
    finally
      LPool.Release(LC);
    end;

    LStats := LPool.Stats;
    WriteLn('    Stats: Acquires=', LStats.Acquires,
            ' Total=', LStats.Total, ' (one connection, used twice)');
    { The pool is for one-client-per-thread concurrency; its thread-safety is
      gated by tests/Nghttp2ClientPool.dpr (8 threads x 25 requests). Here it is
      single-threaded, to show the Acquire/Release/reuse shape plainly. }
  finally
    LPool.Free;
  end;
end;

begin
  WriteLn('Nghttp2AsyncClient - async client + connection pool demo');
  WriteLn;

  if not NghttpLoad then
  begin
    WriteLn('libnghttp2 is not available: ', NghttpLoadError);
    WriteLn('See doc/getting-nghttp2-linux.md or doc/getting-nghttp2-windows.md.');
    ExitCode := 1;
    Exit;
  end;

  GServer := TNghttp2Server.Create;
  try
    GServer.OnRequest := HandleRequest;
    GConfig := TNghttp2Config.Default;
    GConfig.Port := PORT;
    GServer.Start(GConfig);
    try
      DemoAsync;
      WriteLn;
      DemoPool;
    finally
      GServer.Stop;
    end;
  finally
    GServer.Free;
  end;

  WriteLn;
  if (GDone = NREQ) and (GOk = NREQ) then
  begin
    WriteLn('OK - every request completed with 200.');
    ExitCode := 0;
  end
  else
  begin
    WriteLn('Some requests did not complete as expected (see output above).');
    ExitCode := 1;
  end;
end.
