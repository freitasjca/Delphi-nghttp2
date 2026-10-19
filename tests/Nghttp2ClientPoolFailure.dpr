program Nghttp2ClientPoolFailure;

// ============================================================================
//  Nghttp2ClientPoolFailure - CL5.5 pool-level reliability: failure under the pool.
//
//  Nghttp2ClientFailure (stage 4o) pins what ONE client does when a peer
//  misbehaves. This gate pins what TNghttp2ClientPool does when a pooled
//  connection fails mid-request: the pool must NOT leak the slot, and it must
//  not hand the dead connection back on the next Acquire.
//
//  The contract, per the pool's own header ("on checkout the pool calls
//  Client.Connect, which ... reopens one that received GOAWAY or was torn
//  down"):
//    * after a failed request + Release, the pool is back to a known state -
//      InUseCount = 0, the entry kept (TotalCount unchanged), no leak;
//    * a re-Acquire for the SAME key (MaxClientsPerKey = 1, so it MUST be the
//      same entry) yields a USABLE client - a plain GET /ok then returns 200.
//
//  Part A (always runs): an in-process TNghttp2Server control proves the pool's
//  happy path and two invariants that need no adverse peer - a connect failure
//  leaves no reserved slot, and Release of a foreign client raises.
//
//  Part B (needs the python h2 adverse peer, client-failure-peer.py, passed as
//  peer=PORT): drive a pooled client through /abrupt and /truncated, Release,
//  then re-Acquire the same key and require recovery. SKIPS LOUDLY without the
//  peer - TNghttp2Server cannot drop a connection mid-response, so without it
//  the pool-level failure path is NOT exercised.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientPoolFailure.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientPoolFailure.dpr
//  Run:              Nghttp2ClientPoolFailure [peer=19329]
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
  Nghttp2.Types,
  Nghttp2.Native,
  Nghttp2.Server,
  Nghttp2.Client,
  Nghttp2.Client.Pool;

const
  PORT      = 19317;   { in-process control server (Part A) }
  DEAD_PORT = 19399;   { nobody listens here - the connect-failure case }

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  REQ_TIMEOUT_MS = 5000;   { adverse peers close/stall; keep the backstop short }

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSkip: Integer = 0;
  GPeerPort: Integer = 0;

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

procedure Skip(const AName, AReason: string);
begin
  WriteLn('  SKIP  ', AName, '  [', AReason, ']');
  Inc(GSkip);
end;

function PeerPortArg: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to ParamCount do
    if SameText(Copy(ParamStr(I), 1, 5), 'peer=') then
      Result := StrToIntDef(Copy(ParamStr(I), 6, MaxInt), 0);
end;

{ Plain procedure type - the only OnRequest shape that compiles on FPC. }
procedure HandleRequest(const AStream: INghttp2Stream);
begin
  if AStream.Header[':path'] = '/ok' then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes('ok'));
  end
  else
  begin
    AStream.StatusCode := 404;
    AStream.Send(TEncoding.UTF8.GetBytes('nope'));
  end;
end;

{ A pool capped at one connection per key, so a re-Acquire for a key that
  already has an entry MUST reuse that entry rather than opening a second. }
function OnePerKeyConfig: TNghttp2ClientPoolConfig;
begin
  Result := TNghttp2ClientPoolConfig.Default;
  Result.MaxClientsPerKey := 1;
  Result.IdleTimeoutMS    := 0;      { never evict during the test }
  Result.AcquireTimeoutMS := 1000;   { do not hang if something is wrong }
end;

{ ── Part A: in-process control + invariants that need no adverse peer ─────── }
procedure RunControl;
var
  LPool:   TNghttp2ClientPool;
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
  LRaised: Boolean;
  LForeign: TNghttp2Client;
begin
  LPool := TNghttp2ClientPool.Create(OnePerKeyConfig);
  try
    { A1 - happy path: acquire, a good request, release, counts settle. }
    LClient := LPool.Acquire('127.0.0.1', PORT);
    try
      LResp := LClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
      Check('A control: GET /ok via pool returns 200', LResp.Status = 200,
            'status ' + IntToStr(LResp.Status));
    finally
      LPool.Release(LClient);
    end;
    Check('A control: in use = 0 after release', LPool.InUseCount = 0,
          'InUseCount ' + IntToStr(LPool.InUseCount));
    Check('A control: one entry kept (TotalCount=1)', LPool.TotalCount = 1,
          'TotalCount ' + IntToStr(LPool.TotalCount));

    { A2 - reuse: a second acquire on the same key reuses the one entry. }
    LClient := LPool.Acquire('127.0.0.1', PORT);
    try
      LResp := LClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
      Check('A control: reused client still serves /ok (200)', LResp.Status = 200,
            'status ' + IntToStr(LResp.Status));
      Check('A control: still exactly one entry (reuse, not a 2nd connection)',
            LPool.TotalCount = 1, 'TotalCount ' + IntToStr(LPool.TotalCount));
    finally
      LPool.Release(LClient);
    end;

    { A4 - Release of a client that did not come from this pool raises. }
    LForeign := TNghttp2Client.Create;
    try
      LRaised := False;
      try
        LPool.Release(LForeign);
      except
        on E: ENghttp2ClientPool do
          LRaised := True;
      end;
      Check('A control: Release of a foreign client raises', LRaised);
    finally
      LForeign.Free;
    end;
  finally
    LPool.Free;
  end;

  { A3 - connect failure leaves NO reserved slot (its own pool: the failed
    endpoint must not pollute the control pool's counts). }
  LPool := TNghttp2ClientPool.Create(OnePerKeyConfig);
  try
    LRaised := False;
    try
      LClient := LPool.Acquire('127.0.0.1', DEAD_PORT);
      LPool.Release(LClient);   { should not get here }
    except
      on E: Exception do
        LRaised := True;
    end;
    Check('A control: Acquire on a dead port raises', LRaised);
    Check('A control: a failed connect leaves no reserved slot (TotalCount=0)',
          LPool.TotalCount = 0, 'TotalCount ' + IntToStr(LPool.TotalCount));
  finally
    LPool.Free;
  end;
end;

{ One adverse case through the pool: the request fails, Release leaves no leak,
  and a re-Acquire on the same key (capped at 1) yields a USABLE client. }
procedure PoolRecovers(const APool: TNghttp2ClientPool; const APath: string);
var
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
  LRaised: Boolean;
begin
  { fail a request on a leased connection }
  LClient := APool.Acquire('127.0.0.1', GPeerPort);
  try
    LRaised := False;
    try
      LResp := LClient.SubmitRequest('GET', APath, nil, nil, REQ_TIMEOUT_MS);
    except
      on E: Exception do
        LRaised := True;
    end;
    Check(APath + ': the failing request raises', LRaised);
  finally
    APool.Release(LClient);
  end;
  Check(APath + ': in use = 0 after releasing the failed client',
        APool.InUseCount = 0, 'InUseCount ' + IntToStr(APool.InUseCount));
  Check(APath + ': the slot is kept, not leaked (TotalCount=1)',
        APool.TotalCount = 1, 'TotalCount ' + IntToStr(APool.TotalCount));

  { re-acquire the SAME key: capped at 1, so this reuses the entry above. The
    pool must revive the torn-down connection, not hand back the dead one. }
  LClient := APool.Acquire('127.0.0.1', GPeerPort);
  try
    LResp.Status := -1;
    LRaised := False;
    try
      LResp := LClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
    except
      on E: Exception do
        LRaised := True;
    end;
    Check(APath + ': re-Acquire yields a usable client (GET /ok = 200)',
          (not LRaised) and (LResp.Status = 200),
          'raised=' + BoolToStr(LRaised, True) + ' status ' + IntToStr(LResp.Status));
    Check(APath + ': still exactly one entry after recovery (TotalCount=1)',
          APool.TotalCount = 1, 'TotalCount ' + IntToStr(APool.TotalCount));
  finally
    APool.Release(LClient);
  end;
end;

{ ── Part B: adverse peer (needs client-failure-peer.py) ───────────────────── }
procedure RunAdverse;
var
  LPool:   TNghttp2ClientPool;
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
begin
  { peer /ok sanity through the pool - trust the peer before its failures }
  LPool := TNghttp2ClientPool.Create(OnePerKeyConfig);
  try
    LClient := LPool.Acquire('127.0.0.1', GPeerPort);
    try
      LResp := LClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
      Check('B peer control: GET /ok via pool returns 200', LResp.Status = 200,
            'status ' + IntToStr(LResp.Status));
    finally
      LPool.Release(LClient);
    end;
  finally
    LPool.Free;
  end;

  { /abrupt - socket closes before any response }
  LPool := TNghttp2ClientPool.Create(OnePerKeyConfig);
  try
    PoolRecovers(LPool, '/abrupt');
  finally
    LPool.Free;
  end;

  { /truncated - HEADERS + partial DATA, then the socket closes }
  LPool := TNghttp2ClientPool.Create(OnePerKeyConfig);
  try
    PoolRecovers(LPool, '/truncated');
  finally
    LPool.Free;
  end;
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;

begin
  WriteLn('Nghttp2ClientPoolFailure - CL5.5 pool reliability: failure under the pool');
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

  GPeerPort := PeerPortArg;

  { ── Part A: in-process control (always runs) ─────────────────────────────── }
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
        WriteLn('  FAIL  control server did not start: ', E.ClassName, ': ', E.Message);
        ExitCode := EXIT_FAIL;
        Exit;
      end;
    end;
    Check('A control server started on port ' + IntToStr(PORT), True);

    RunControl;

    GServer.Stop;
  finally
    GServer.Free;
  end;

  { ── Part B: adverse peer (needs client-failure-peer.py) ──────────────────── }
  if GPeerPort <= 0 then
  begin
    Skip('B /abrupt recovery under the pool', 'no peer= port; python h2 peer not started');
    Skip('B /truncated recovery under the pool', 'no peer= port');
  end
  else
    RunAdverse;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GSkip > 0 then
  begin
    WriteLn('        ', GSkip, ' check(s) did NOT run - the adverse peer was not');
    WriteLn('        started, so the pool-level failure paths were NOT exercised.');
  end;
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
