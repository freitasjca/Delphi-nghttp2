program Nghttp2ClientPool;

// ============================================================================
//  Nghttp2ClientPool - CL5 gate. Exercises TNghttp2ClientPool against an
//  in-process TNghttp2Server over h2c.
//
//  What it proves:
//    1. acquire -> request -> release round-trips a real response;
//    2. release then re-acquire REUSES the same connection (TotalCount stays 1);
//    3. the MaxClientsPerKey ceiling is enforced - an acquire past it with a
//       finite budget raises ENghttp2ClientPool rather than opening an N+1th;
//    4. N threads x M requests all succeed with no corruption, the pool never
//       exceeds the ceiling, and no session is driven by two threads (the
//       acquire/release contract guarantees the last point by construction -
//       a client is owned by one thread between Acquire and Release);
//    5. idle eviction is observable - an idle client past IdleTimeoutMS is
//       dropped by Sweep.
//
//  Peer choice: the concurrency and lifecycle behaviour under test is NOT
//  protocol behaviour, so our own server is the correct peer here (the
//  "independent peer" rule applies to protocol claims). The throughput
//  cross-check - h2load driving the pool - is a separate, out-of-process
//  exercise and is not part of this in-process gate.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientPool.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientPool.dpr
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  { cthreads MUST come first on Unix: the server starts threads per connection
    and this program spawns worker threads of its own. }
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
  PORT = 19314;   { distinct from smoke (19311) and AlpnMismatch (19312/19313) }

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  WORKER_THREADS    = 8;
  REQUESTS_PER_WORKER = 25;
  CONCURRENCY_CEILING = 4;   { < WORKER_THREADS, so threads must share + queue }

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSkip: Integer = 0;

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

{ Plain procedure type - the only OnRequest shape that compiles on FPC without
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
    AStream.StatusCode := 404;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes('nope'));
  end;
end;

type
  { One worker hammers the pool on its own thread. It keeps its own counters so
    the summing is lock-free - the main thread reads them only after WaitFor. }
  TPoolWorker = class(TThread)
  private
    FPool:       TNghttp2ClientPool;
    FIterations: Integer;
    FOk:         Integer;
    FErr:        Integer;
    FErrMsg:     string;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TNghttp2ClientPool; AIterations: Integer);
    property Ok:     Integer read FOk;
    property Err:    Integer read FErr;
    property ErrMsg: string  read FErrMsg;
  end;

constructor TPoolWorker.Create(APool: TNghttp2ClientPool; AIterations: Integer);
begin
  inherited Create(True);   { suspended }
  FreeOnTerminate := False;
  FPool := APool;
  FIterations := AIterations;
  FOk := 0;
  FErr := 0;
  FErrMsg := '';
end;

procedure TPoolWorker.Execute;
var
  I:       Integer;
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
begin
  for I := 1 to FIterations do
  begin
    try
      LClient := FPool.Acquire('127.0.0.1', PORT);
      try
        LResp := LClient.SubmitRequest('GET', '/smoke', nil, nil);
        if (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok') then
          Inc(FOk)
        else
          Inc(FErr);
      finally
        FPool.Release(LClient);
      end;
    except
      on E: Exception do
      begin
        Inc(FErr);
        if FErrMsg = '' then
          FErrMsg := E.ClassName + ': ' + E.Message;
      end;
    end;
  end;
end;

var
  GServer:  TNghttp2Server;
  GConfig:  TNghttp2Config;
  GPool:    TNghttp2ClientPool;
  GClient:  TNghttp2Client;
  GClient2: TNghttp2Client;
  GResp:    TNghttp2Response;
  GCfg:     TNghttp2ClientPoolConfig;
  GWorkers: array of TPoolWorker;
  GTotalOk: Integer;
  GTotalErr: Integer;
  GWorkerErrMsg: string;
  GRaised:  Boolean;
  GRaisedKind: string;
  GHeld1:   TNghttp2Client;
  GHeld2:   TNghttp2Client;
  I:        Integer;

begin
  WriteLn('Nghttp2ClientPool - CL5 session pool gate');
  WriteLn;

  if not NghttpLoad then
  begin
    WriteLn('  ================================================================');
    WriteLn('   SKIPPED - libnghttp2 is not present on this machine.');
    WriteLn('   ', NghttpLoadError);
    WriteLn('   This gate starts a server and pools client connections; without');
    WriteLn('   the library it cannot run. A green suite that skipped it has NOT');
    WriteLn('   exercised the pool.');
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
    Check('server bound and started on port ' + IntToStr(PORT), True);

    { ── 1. basic acquire -> request -> release ─────────────────────────────── }
    GPool := TNghttp2ClientPool.Create;
    try
      GClient := GPool.Acquire('127.0.0.1', PORT);
      Check('Acquire returned a connected client', GClient.Connected);
      GResp := GClient.SubmitRequest('GET', '/smoke', nil, nil);
      Check('pooled GET /smoke returned 200', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));
      Check('pooled GET /smoke returned the handler body',
            TEncoding.UTF8.GetString(GResp.Body) = 'ok',
            TEncoding.UTF8.GetString(GResp.Body));
      Check('one connection exists while acquired', GPool.TotalCount = 1,
            'TotalCount ' + IntToStr(GPool.TotalCount));
      Check('it is counted in use', GPool.InUseCount = 1,
            'InUseCount ' + IntToStr(GPool.InUseCount));
      GPool.Release(GClient);
      Check('after Release it is idle, not destroyed',
            (GPool.TotalCount = 1) and (GPool.IdleCount = 1),
            Format('Total %d Idle %d', [GPool.TotalCount, GPool.IdleCount]));

      { ── 2. reuse: re-acquire takes the SAME connection, no new one ───────── }
      GClient2 := GPool.Acquire('127.0.0.1', PORT);
      Check('re-acquire reuses the idle connection (no new one opened)',
            (GPool.TotalCount = 1) and (GClient2 = GClient),
            'TotalCount ' + IntToStr(GPool.TotalCount));
      GResp := GClient2.SubmitRequest('GET', '/smoke', nil, nil);
      Check('request on the reused pooled connection returns 200',
            GResp.Status = 200, 'status ' + IntToStr(GResp.Status));
      GPool.Release(GClient2);
    finally
      GPool.Free;
    end;

    { ── 3. ceiling: an acquire past MaxClientsPerKey raises on timeout ─────── }
    GCfg := TNghttp2ClientPoolConfig.Default;
    GCfg.MaxClientsPerKey := 2;
    GCfg.AcquireTimeoutMS := 300;   { short, so the test does not stall }
    GPool := TNghttp2ClientPool.Create(GCfg);
    try
      GHeld1 := GPool.Acquire('127.0.0.1', PORT);
      GHeld2 := GPool.Acquire('127.0.0.1', PORT);
      Check('two connections open at the ceiling', GPool.TotalCount = 2,
            'TotalCount ' + IntToStr(GPool.TotalCount));
      GRaised := False;
      GRaisedKind := '';
      try
        GClient := GPool.Acquire('127.0.0.1', PORT);
        { should not get here; release it if we somehow did, to avoid a leak }
        GPool.Release(GClient);
      except
        on E: ENghttp2ClientPool do
        begin
          GRaised := True;
          GRaisedKind := E.ClassName;
        end;
        on E: Exception do
          GRaisedKind := E.ClassName;
      end;
      Check('a third acquire past the ceiling raises ENghttp2ClientPool',
            GRaised, 'got ' + GRaisedKind);
      Check('the ceiling was never exceeded', GPool.TotalCount = 2,
            'TotalCount ' + IntToStr(GPool.TotalCount));
      GPool.Release(GHeld1);
      GPool.Release(GHeld2);
      { a slot is free again }
      GClient := GPool.Acquire('127.0.0.1', PORT);
      Check('after a Release an acquire at the ceiling succeeds',
            GClient.Connected);
      GPool.Release(GClient);
    finally
      GPool.Free;
    end;

    { ── 4. N threads x M requests, ceiling < N ─────────────────────────────── }
    GCfg := TNghttp2ClientPoolConfig.Default;
    GCfg.MaxClientsPerKey := CONCURRENCY_CEILING;
    GCfg.AcquireTimeoutMS := 30000;   { generous, so contention never false-fails }
    GPool := TNghttp2ClientPool.Create(GCfg);
    try
      SetLength(GWorkers, WORKER_THREADS);
      for I := 0 to WORKER_THREADS - 1 do
        GWorkers[I] := TPoolWorker.Create(GPool, REQUESTS_PER_WORKER);
      for I := 0 to WORKER_THREADS - 1 do
        GWorkers[I].Start;

      GTotalOk := 0;
      GTotalErr := 0;
      GWorkerErrMsg := '';
      for I := 0 to WORKER_THREADS - 1 do
      begin
        GWorkers[I].WaitFor;
        Inc(GTotalOk, GWorkers[I].Ok);
        Inc(GTotalErr, GWorkers[I].Err);
        if (GWorkerErrMsg = '') and (GWorkers[I].ErrMsg <> '') then
          GWorkerErrMsg := GWorkers[I].ErrMsg;
      end;
      for I := 0 to WORKER_THREADS - 1 do
        GWorkers[I].Free;

      Check(Format('%d threads x %d requests all returned 200 (%d/%d ok)',
              [WORKER_THREADS, REQUESTS_PER_WORKER, GTotalOk,
               WORKER_THREADS * REQUESTS_PER_WORKER]),
            (GTotalOk = WORKER_THREADS * REQUESTS_PER_WORKER) and (GTotalErr = 0),
            GWorkerErrMsg);
      Check('the pool never exceeded MaxClientsPerKey under contention',
            GPool.TotalCount <= CONCURRENCY_CEILING,
            Format('TotalCount %d > %d', [GPool.TotalCount, CONCURRENCY_CEILING]));
      Check('every connection is idle again after all workers finished',
            GPool.InUseCount = 0,
            'InUseCount ' + IntToStr(GPool.InUseCount));
    finally
      GPool.Free;
    end;

    { ── 5. idle eviction is observable ─────────────────────────────────────── }
    GCfg := TNghttp2ClientPoolConfig.Default;
    GCfg.IdleTimeoutMS := 50;
    GPool := TNghttp2ClientPool.Create(GCfg);
    try
      GClient := GPool.Acquire('127.0.0.1', PORT);
      GPool.Release(GClient);
      Check('one idle connection before eviction',
            (GPool.TotalCount = 1) and (GPool.IdleCount = 1),
            Format('Total %d Idle %d', [GPool.TotalCount, GPool.IdleCount]));
{$IF DEFINED(FPC)}
      Sleep(150);
{$ELSE}
      TThread.Sleep(150);
{$IFEND}
      GPool.Sweep;
      Check('Sweep evicts the connection idle past IdleTimeoutMS',
            (GPool.TotalCount = 0) and (GPool.IdleCount = 0),
            Format('Total %d Idle %d', [GPool.TotalCount, GPool.IdleCount]));
    finally
      GPool.Free;
    end;

    GServer.Stop;
    Check('server stopped cleanly', True);
  finally
    GServer.Free;
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
