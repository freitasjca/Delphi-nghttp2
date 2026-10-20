program Nghttp2ClientPoolObservability;

// ============================================================================
//  Nghttp2ClientPoolObservability - CL5.5 POOLSTATS-1: the pool's diagnostics.
//
//  TNghttp2ClientPool.TotalCount/IdleCount/InUseCount are instantaneous. A
//  concurrency problem (contention, churn, a dead endpoint) needs CUMULATIVE
//  numbers: how often Acquire had to wait at the ceiling and for how long, how
//  many idle connections were evicted, how many connects failed. Stats returns
//  all of them in one locked snapshot. This gate drives each counter off zero.
//
//  Entirely in-process and single-threaded - the ceiling wait is forced by
//  holding the one slot and acquiring again until the budget expires, so no
//  background thread and no python peer. Always runs.
//
//  Each counter is the teeth of its own check: remove the matching Inc and that
//  check alone fails (it would stay 0).
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientPoolObservability.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientPoolObservability.dpr
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$IFEND}
  Nghttp2.Types,
  Nghttp2.Native,
  Nghttp2.Server,
  Nghttp2.Client,
  Nghttp2.Client.Pool;

const
  PORT      = 19320;   { in-process server }
  DEAD_PORT = 19399;   { nobody listens here }

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  REQ_TIMEOUT_MS = 5000;

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

{ Plain procedure type - the only OnRequest shape that compiles on FPC. }
procedure HandleRequest(const AStream: INghttp2Stream);
begin
  AStream.StatusCode := 200;
  AStream.Header['content-type'] := 'text/plain; charset=utf-8';
  AStream.Send(TEncoding.UTF8.GetBytes('ok'));
end;

function OnePerKey(AIdleMS, AAcquireMS: Integer): TNghttp2ClientPoolConfig;
begin
  Result := TNghttp2ClientPoolConfig.Default;
  Result.MaxClientsPerKey := 1;
  Result.IdleTimeoutMS    := AIdleMS;
  Result.AcquireTimeoutMS := AAcquireMS;
end;

procedure RunAcquiresAndWaits(AServerUp: Boolean);
var
  LPool:   TNghttp2ClientPool;
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
  LStats:  TNghttp2ClientPoolStats;
  LRaised: Boolean;
  I:       Integer;
begin
  { ── fresh pool: every cumulative counter starts at zero ──────────────────── }
  LPool := TNghttp2ClientPool.Create(OnePerKey(0, 1000));
  try
    LStats := LPool.Stats;
    Check('fresh pool: Acquires = 0', LStats.Acquires = 0, 'got ' + IntToStr(LStats.Acquires));
    Check('fresh pool: AcquireWaits = 0', LStats.AcquireWaits = 0, 'got ' + IntToStr(LStats.AcquireWaits));
    Check('fresh pool: Evictions = 0', LStats.Evictions = 0, 'got ' + IntToStr(LStats.Evictions));
    Check('fresh pool: ConnectFailures = 0', LStats.ConnectFailures = 0, 'got ' + IntToStr(LStats.ConnectFailures));

    { ── three uncontended acquire/release cycles: Acquires counts, no wait ──── }
    for I := 1 to 3 do
    begin
      LClient := LPool.Acquire('127.0.0.1', PORT);
      try
        LResp := LClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
        if LResp.Status <> 200 then
          Check('acquire cycle ' + IntToStr(I) + ' got 200', False,
                'status ' + IntToStr(LResp.Status));
      finally
        LPool.Release(LClient);
      end;
    end;
    LStats := LPool.Stats;
    Check('three acquire/release cycles -> Acquires = 3', LStats.Acquires = 3,
          'got ' + IntToStr(LStats.Acquires));
    Check('uncontended acquires did not wait (AcquireWaits = 0)',
          LStats.AcquireWaits = 0, 'got ' + IntToStr(LStats.AcquireWaits));
  finally
    LPool.Free;
  end;

  { ── a ceiling wait: hold the one slot, acquire again, it waits then times out }
  LPool := TNghttp2ClientPool.Create(OnePerKey(0, 200));
  try
    LClient := LPool.Acquire('127.0.0.1', PORT);   { the only slot, held }
    try
      LRaised := False;
      try
        LPool.Acquire('127.0.0.1', PORT);          { must wait, then raise }
      except
        on E: ENghttp2ClientPool do
          LRaised := True;
      end;
      Check('a 2nd acquire at the ceiling raises after waiting', LRaised);
      LStats := LPool.Stats;
      Check('the held acquire counted (Acquires = 1)', LStats.Acquires = 1,
            'got ' + IntToStr(LStats.Acquires));
      Check('the ceiling wait was counted (AcquireWaits = 1)',
            LStats.AcquireWaits = 1, 'got ' + IntToStr(LStats.AcquireWaits));
      Check('WaitMS reflects the ~200 ms budget (>= 150)', LStats.WaitMS >= 150,
            'WaitMS ' + IntToStr(LStats.WaitMS));
      Check('MaxWaitMS reflects the single wait (>= 150)', LStats.MaxWaitMS >= 150,
            'MaxWaitMS ' + IntToStr(LStats.MaxWaitMS));
    finally
      LPool.Release(LClient);
    end;
  finally
    LPool.Free;
  end;
end;

procedure RunEvictions;
var
  LPool:   TNghttp2ClientPool;
  LClient: TNghttp2Client;
  LStats:  TNghttp2ClientPoolStats;
begin
  LPool := TNghttp2ClientPool.Create(OnePerKey(50, 1000));   { idle > 50 ms is evictable }
  try
    LClient := LPool.Acquire('127.0.0.1', PORT);
    LPool.Release(LClient);                                   { now idle }
    TThread.Sleep(120);                                       { let it age past 50 ms }
    LPool.Sweep;
    LStats := LPool.Stats;
    Check('Sweep of an aged-out idle client -> Evictions = 1', LStats.Evictions = 1,
          'got ' + IntToStr(LStats.Evictions));
    Check('... and the pool is empty afterwards (Total = 0)', LStats.Total = 0,
          'Total ' + IntToStr(LStats.Total));
  finally
    LPool.Free;
  end;
end;

procedure RunConnectFailures;
var
  LPool:   TNghttp2ClientPool;
  LStats:  TNghttp2ClientPoolStats;
  LRaised: Boolean;
begin
  LPool := TNghttp2ClientPool.Create(OnePerKey(0, 1000));
  try
    LRaised := False;
    try
      LPool.Acquire('127.0.0.1', DEAD_PORT);
    except
      on E: Exception do
        LRaised := True;
    end;
    Check('Acquire on a dead port raises', LRaised);
    LStats := LPool.Stats;
    Check('a failed connect counted (ConnectFailures = 1)', LStats.ConnectFailures = 1,
          'got ' + IntToStr(LStats.ConnectFailures));
    Check('a failed connect is NOT counted as an Acquire (Acquires = 0)',
          LStats.Acquires = 0, 'got ' + IntToStr(LStats.Acquires));
  finally
    LPool.Free;
  end;
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;

begin
  WriteLn('Nghttp2ClientPoolObservability - CL5.5 POOLSTATS-1: the pool''s diagnostics');
  WriteLn;

  if not NghttpLoad then
  begin
    WriteLn('  ================================================================');
    WriteLn('   SKIPPED - libnghttp2 is not present on this machine.');
    WriteLn('   ', NghttpLoadError);
    WriteLn('  ================================================================');
    ExitCode := EXIT_SKIP;
    Exit;
  end;

  GServer := TNghttp2Server.Create;
  try
    GServer.OnRequest := HandleRequest;
    GConfig := TNghttp2Config.Default;
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
    Check('server started on port ' + IntToStr(PORT), True);

    RunAcquiresAndWaits(True);
    RunEvictions;
    RunConnectFailures;

    GServer.Stop;
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
