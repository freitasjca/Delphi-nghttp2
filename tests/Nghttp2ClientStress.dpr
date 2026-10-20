program Nghttp2ClientStress;

// ============================================================================
//  Nghttp2ClientStress - CL5.5 independent-peer stress (STRESS-1, stage 4t).
//
//  Every other CL5.5 gate drives the client/pool against our OWN in-process
//  TNghttp2Server (4n/4o/4p/4q/4r/4s) or a purpose-built python-h2 adverse peer.
//  This project's standing rule is that a concurrency or robustness claim may
//  NOT rest on our own server alone (plans/delphi-nghttp2-client.md, "Validation
//  rules"). This gate closes that gap: it drives the RAW client and the pool
//  against an independent, real HTTP/2 server - nginx, run in a Docker container
//  over h2c - under concurrency, with a large flow-controlled body, and across
//  nginx's own GOAWAY (keepalive_requests), and requires:
//    * every request delivers its COMPLETE expected body (not just a 200);
//    * the pool returns to a clean baseline afterwards - InUseCount 0,
//      TotalCount <= ceiling, Stats.Acquires exact, Stats.ConnectFailures 0;
//    * the client stays usable across a server-initiated GOAWAY, and the GOAWAY
//      is OBSERVED to have fired (an instrument that cannot be seen to fire is
//      void - perf-measurement sec 4).
//
//  Scope note: the adverse signals this peer produces deterministically are
//  CONCURRENCY, FLOW CONTROL (a 4 MiB response body, far past the HTTP/2 window)
//  and GOAWAY (nginx keepalive_requests). Mid-response RST and abrupt socket
//  close are NOT asserted here - stages 4o/4p own those with a python-h2 peer
//  built to produce them on demand; nginx will not do them deterministically.
//
//  The peer is started by the launcher (tests/stress/peer.sh on Linux,
//  tests/stress/peer.ps1 on Windows) and its port passed as peer=PORT. WITHOUT
//  a peer= arg this gate SKIPS LOUDLY (exit 3): there is no in-process control,
//  because our own server is exactly the peer this gate exists NOT to trust.
//
//  Counts, not times (perf-measurement sec 3): the load-bearing assertions are
//  zero-variance integers - total deliveries, Acquires, ConnectFailures, body
//  byte counts. Ceiling-wait durations vary and are reported, never asserted.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped (no peer, or libnghttp2)
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientStress.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientStress.dpr
//  Run:              Nghttp2ClientStress peer=19340 [host=127.0.0.1]
//
//  host= defaults to 127.0.0.1. It exists for the Windows-driving-WSL-Docker
//  case: when the peer runs in WSL and localhost-forwarding does not reach it,
//  pass the WSL IP instead. The launcher normally leaves it at the default.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  { cthreads MUST come first on Unix: this program spawns worker threads. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$IFEND}
  Nghttp2.Types,
  Nghttp2.Native,
  Nghttp2.Client,
  Nghttp2.Client.Pool;

const
  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  BIG_SIZE = 4 * 1024 * 1024;   { 4 MiB - many HTTP/2 windows; exercises WINDOW_UPDATE }

  WORKER_THREADS      = 8;
  REQUESTS_PER_WORKER = 20;
  CONCURRENCY_CEILING = 4;      { < WORKER_THREADS, so threads share + queue }
  BIG_EVERY           = 5;      { every 5th request pulls the big body }

  GOAWAY_REQUESTS = 30;         { >> keepalive_requests (5), so GOAWAY recurs }

  REQ_TIMEOUT_MS     = 15000;   { a loopback 4 MiB transfer is sub-second; a stall fails }
  BIG_TIMEOUT_MS     = 20000;

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSkip: Integer = 0;
  GPeerPort: Integer = 0;
  GPeerHost: string = '127.0.0.1';

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

function HostArg: string;
var
  I: Integer;
begin
  Result := '127.0.0.1';
  for I := 1 to ParamCount do
    if SameText(Copy(ParamStr(I), 1, 5), 'host=') then
      Result := Copy(ParamStr(I), 6, MaxInt);
end;

{ A received body counts as a correct big body only if it is EXACTLY BIG_SIZE
  bytes. The launcher fills it with zeros; a truncated transfer (the classic
  flow-control failure) changes the length, which is the load-bearing check. }
function IsFullBig(const ABody: TBytes): Boolean;
begin
  Result := Length(ABody) = BIG_SIZE;
end;

type
  { One worker hammers the pool on its own thread, alternating a tiny body and
    the 4 MiB body. Per-thread counters are summed by the main thread AFTER
    WaitFor, so the summing needs no lock. }
  TStressWorker = class(TThread)
  private
    FPool:      TNghttp2ClientPool;
    FHost:      string;
    FPort:      Integer;
    FIters:     Integer;
    FOk:        Integer;   { requests whose COMPLETE expected body arrived }
    FErr:       Integer;   { requests that failed EVEN AFTER one retry }
    FRetries:   Integer;   { first-attempt failures that triggered a retry }
    FBigSeen:   Integer;   { big requests attempted }
    FBigFull:   Integer;   { of those, delivered at exactly BIG_SIZE }
    FErrMsg:    string;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TNghttp2ClientPool; const AHost: string;
      APort: Integer; AIters: Integer);
    property Ok:      Integer read FOk;
    property Err:     Integer read FErr;
    property Retries: Integer read FRetries;
    property BigSeen: Integer read FBigSeen;
    property BigFull: Integer read FBigFull;
    property ErrMsg:  string  read FErrMsg;
  end;

constructor TStressWorker.Create(APool: TNghttp2ClientPool; const AHost: string;
  APort: Integer; AIters: Integer);
begin
  inherited Create(True);   { suspended }
  FreeOnTerminate := False;
  FPool := APool;
  FHost := AHost;
  FPort := APort;
  FIters := AIters;
  FOk := 0;
  FErr := 0;
  FRetries := 0;
  FBigSeen := 0;
  FBigFull := 0;
  FErrMsg := '';
end;

procedure TStressWorker.Execute;
var
  I, LAttempt: Integer;
  LClient:  TNghttp2Client;
  LResp:    TNghttp2Response;
  LBig:     Boolean;
  LGood:    Boolean;
  LLastMsg: string;
begin
  for I := 1 to FIters do
  begin
    LBig := (I mod BIG_EVERY) = 0;
    if LBig then
      Inc(FBigSeen);
    LGood := False;
    LLastMsg := '';

    { Up to two attempts. A first-attempt failure is the pool's DOCUMENTED
      stale-connection contract (a peer that closed after GOAWAY without the
      client observing it): the next Acquire health-checks via Connect and
      reopens, so a real caller retries once. Transparent auto-retry is a
      deliberate CL6 non-goal, so the retry lives here, in the caller. }
    for LAttempt := 1 to 2 do
    begin
      try
        LClient := FPool.Acquire(FHost, FPort);
        try
          if LBig then
          begin
            LResp := LClient.SubmitRequest('GET', '/big.bin', nil, nil, BIG_TIMEOUT_MS);
            LGood := (LResp.Status = 200) and IsFullBig(LResp.Body);
          end
          else
          begin
            LResp := LClient.SubmitRequest('GET', '/small', nil, nil, REQ_TIMEOUT_MS);
            LGood := (LResp.Status = 200)
                 and (TEncoding.UTF8.GetString(LResp.Body) = 'ok');
          end;
          if not LGood then
            LLastMsg := Format('status %d len %d', [LResp.Status, Length(LResp.Body)]);
        finally
          FPool.Release(LClient);
        end;
      except
        on E: Exception do
        begin
          LGood := False;
          LLastMsg := E.ClassName + ': ' + E.Message;
        end;
      end;
      if LGood then
        Break;
      if LAttempt = 1 then
        Inc(FRetries);   { count the stale-connection retry }
    end;

    if LGood then
    begin
      Inc(FOk);
      if LBig then
        Inc(FBigFull);
    end
    else
    begin
      Inc(FErr);
      if FErrMsg = '' then
        FErrMsg := LLastMsg;
    end;
  end;
end;

{ ── Phase 1: trust the peer (one plain request before any stress) ─────────── }
procedure RunPeerSanity;
var
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
begin
  LClient := TNghttp2Client.Create;
  try
    LClient.Connect(GPeerHost, GPeerPort);
    LResp := LClient.SubmitRequest('GET', '/small', nil, nil, REQ_TIMEOUT_MS);
    Check('peer sanity: GET /small returns 200 + body ''ok''',
          (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok'),
          Format('status %d body ''%s''',
                 [LResp.Status, TEncoding.UTF8.GetString(LResp.Body)]));
  finally
    LClient.Free;
  end;
end;

{ ── Phase 2: flow control - the full 4 MiB body arrives intact ────────────── }
procedure RunFlowControl;
var
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
  LAllZero: Boolean;
  I:       Integer;
begin
  LClient := TNghttp2Client.Create;
  try
    LClient.Connect(GPeerHost, GPeerPort);
    LResp := LClient.SubmitRequest('GET', '/big.bin', nil, nil, BIG_TIMEOUT_MS);
    Check('flow control: GET /big.bin returns 200', LResp.Status = 200,
          'status ' + IntToStr(LResp.Status));
    Check('flow control: the whole 4 MiB body arrived (length exact)',
          Length(LResp.Body) = BIG_SIZE,
          Format('got %d of %d bytes', [Length(LResp.Body), BIG_SIZE]));
    { content check, done once here (cheap per-request length check elsewhere):
      a corrupt transfer that kept the length would inject non-zero bytes. }
    LAllZero := Length(LResp.Body) = BIG_SIZE;
    if LAllZero then
      for I := 0 to Length(LResp.Body) - 1 do
        if LResp.Body[I] <> 0 then
        begin
          LAllZero := False;
          Break;
        end;
    Check('flow control: body is intact (every byte as sent)', LAllZero);
  finally
    LClient.Free;
  end;
end;

{ ── Phase 3: concurrency - N threads x M requests, mixed small + big ──────── }
procedure RunConcurrency;
var
  LPool:    TNghttp2ClientPool;
  LCfg:     TNghttp2ClientPoolConfig;
  LWorkers: array of TStressWorker;
  LStats:   TNghttp2ClientPoolStats;
  LTotalOk, LTotalErr, LBigSeen, LBigFull, LTotalRetries: Integer;
  LErrMsg:  string;
  LExpectedTotal: Integer;
  I:        Integer;
begin
  LExpectedTotal := WORKER_THREADS * REQUESTS_PER_WORKER;

  LCfg := TNghttp2ClientPoolConfig.Default;
  LCfg.MaxClientsPerKey := CONCURRENCY_CEILING;
  LCfg.AcquireTimeoutMS := 30000;   { generous; contention must never false-fail }
  LCfg.IdleTimeoutMS    := 0;       { no eviction mid-run - keep the baseline clean }
  LPool := TNghttp2ClientPool.Create(LCfg);
  try
    SetLength(LWorkers, WORKER_THREADS);
    for I := 0 to WORKER_THREADS - 1 do
      LWorkers[I] := TStressWorker.Create(LPool, GPeerHost, GPeerPort, REQUESTS_PER_WORKER);
    for I := 0 to WORKER_THREADS - 1 do
      LWorkers[I].Start;

    LTotalOk := 0; LTotalErr := 0; LBigSeen := 0; LBigFull := 0;
    LTotalRetries := 0; LErrMsg := '';
    for I := 0 to WORKER_THREADS - 1 do
    begin
      LWorkers[I].WaitFor;
      Inc(LTotalOk,  LWorkers[I].Ok);
      Inc(LTotalErr, LWorkers[I].Err);
      Inc(LBigSeen,  LWorkers[I].BigSeen);
      Inc(LBigFull,  LWorkers[I].BigFull);
      Inc(LTotalRetries, LWorkers[I].Retries);
      if (LErrMsg = '') and (LWorkers[I].ErrMsg <> '') then
        LErrMsg := LWorkers[I].ErrMsg;
    end;
    for I := 0 to WORKER_THREADS - 1 do
      LWorkers[I].Free;

    LStats := LPool.Stats;

    Check(Format('concurrency: %d threads x %d all delivered (%d/%d ok, %d err)',
            [WORKER_THREADS, REQUESTS_PER_WORKER, LTotalOk, LExpectedTotal, LTotalErr]),
          (LTotalOk = LExpectedTotal) and (LTotalErr = 0), LErrMsg);
    Check(Format('concurrency: every big body full under load (%d/%d)',
            [LBigFull, LBigSeen]),
          (LBigSeen > 0) and (LBigFull = LBigSeen),
          Format('%d of %d big bodies truncated', [LBigSeen - LBigFull, LBigSeen]));
    Check('concurrency: pool back to a clean baseline (InUse 0)',
          LStats.InUse = 0, 'InUse ' + IntToStr(LStats.InUse));
    Check('concurrency: ceiling never exceeded (Total <= ' +
            IntToStr(CONCURRENCY_CEILING) + ')',
          LStats.Total <= CONCURRENCY_CEILING, 'Total ' + IntToStr(LStats.Total));
    { Every logical request Acquires at least once; a stale-connection retry
      Acquires again, so Acquires = requests + retries (not a fixed number -
      the retry count is timing-dependent). The zero-variance load-bearing
      assertion is the delivery count above; this just pins the accounting. }
    Check(Format('concurrency: Acquires account for every request + retry (%d = %d + %d)',
            [LStats.Acquires, LExpectedTotal, LTotalRetries]),
          LStats.Acquires = LExpectedTotal + LTotalRetries,
          Format('Acquires %d, expected %d + %d retries',
                 [LStats.Acquires, LExpectedTotal, LTotalRetries]));
    Check('concurrency: no connect failures against the real peer',
          LStats.ConnectFailures = 0,
          'ConnectFailures ' + IntToStr(LStats.ConnectFailures));

    WriteLn(Format('        [reported] stale-connection retries %d, ceiling waits %d, ' +
            'total wait %d ms, max wait %d ms, big bodies %d x %d bytes',
            [LTotalRetries, LStats.AcquireWaits, LStats.WaitMS, LStats.MaxWaitMS,
             LBigFull, BIG_SIZE]));
  finally
    LPool.Free;
  end;
end;

{ ── Phase 4: GOAWAY - the client survives nginx's keepalive_requests GOAWAY,
     and the GOAWAY is observed to have fired at least once ─────────────────── }
procedure RunGoAway;
var
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
  LOk:     Integer;
  LSeen:   Integer;     { requests after which GoAwayReceived was set (clean path) }
  LRetries: Integer;    { raced close -> Reconnect + retry (the other recovery path) }
  LLastMsg: string;
  LGood:   Boolean;
  I, LAttempt: Integer;
begin
  LClient := TNghttp2Client.Create;
  try
    LClient.Connect(GPeerHost, GPeerPort);
    LOk := 0;
    LSeen := 0;
    LRetries := 0;
    LLastMsg := '';
    for I := 1 to GOAWAY_REQUESTS do
    begin
      LGood := False;
      for LAttempt := 1 to 2 do
      begin
        try
          { SubmitRequest auto-reconnects when the PREVIOUS response carried
            GOAWAY - the clean recovery path, observable via GoAwayReceived. }
          LResp := LClient.SubmitRequest('GET', '/small', nil, nil, REQ_TIMEOUT_MS);
          LGood := (LResp.Status = 200)
               and (TEncoding.UTF8.GetString(LResp.Body) = 'ok');
          if LClient.GoAwayReceived then
            Inc(LSeen);   { read before the next call's auto-reconnect consumes it }
          if not LGood then
            LLastMsg := 'status ' + IntToStr(LResp.Status);
        except
          on E: Exception do
          begin
            LGood := False;
            LLastMsg := E.ClassName + ': ' + E.Message;
          end;
        end;
        if LGood then
          Break;
        { the raced close: nginx shut the socket after GOAWAY before the client
          read the frame, so the send failed. The documented caller-retry is to
          Reconnect and try once more. }
        if LAttempt = 1 then
        begin
          Inc(LRetries);
          try
            LClient.Reconnect;
          except
            { a real reconnect failure surfaces as a missed delivery below }
          end;
        end;
      end;
      if LGood then
        Inc(LOk);
    end;
    Check(Format('GOAWAY: all %d sequential requests delivered, recovering each time (%d/%d)',
            [GOAWAY_REQUESTS, LOk, GOAWAY_REQUESTS]),
          LOk = GOAWAY_REQUESTS, IntToStr(LOk) + ' ok; last: ' + LLastMsg);
    { The instrument must be seen to fire: nginx's keepalive_requests cycled the
      connection at least once, shown EITHER by a GOAWAY the client read
      (LSeen) OR by a raced close that forced a caller-retry (LRetries). If
      neither happened the limit never triggered and recovery was not tested. }
    Check('GOAWAY: the server cycled the connection and the client recovered',
          (LSeen > 0) or (LRetries > 0),
          Format('GoAwayReceived %d, retries %d across %d requests',
                 [LSeen, LRetries, GOAWAY_REQUESTS]));
    WriteLn(Format('        [reported] GoAwayReceived observed %d time(s), ' +
            'raced-close retries %d', [LSeen, LRetries]));
  finally
    LClient.Free;
  end;
end;

begin
  WriteLn('Nghttp2ClientStress - CL5.5 independent-peer stress (nginx h2c, Docker)');
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
  GPeerHost := HostArg;
  if GPeerPort <= 0 then
  begin
    WriteLn('  ================================================================');
    WriteLn('   SKIPPED - no peer= port.');
    WriteLn('   This gate drives the client against an INDEPENDENT nginx peer');
    WriteLn('   (Docker). There is no in-process control: our own server is');
    WriteLn('   exactly the peer this gate exists NOT to trust. Start the peer');
    WriteLn('   with tests/stress/peer.sh (Linux) or peer.ps1 (Windows) and');
    WriteLn('   pass peer=PORT. A suite that skipped this has NOT run the stress.');
    WriteLn('  ================================================================');
    Skip('peer sanity',    'no peer= port');
    Skip('flow control',   'no peer= port');
    Skip('concurrency',    'no peer= port');
    Skip('GOAWAY survival', 'no peer= port');
    WriteLn;
    WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
    ExitCode := EXIT_SKIP;
    Exit;
  end;

  WriteLn('  peer: ', GPeerHost, ':', GPeerPort);
  WriteLn;
  try
    RunPeerSanity;
    RunFlowControl;
    RunConcurrency;
    RunGoAway;
  except
    on E: Exception do
      Check('stress run completed without an unhandled exception', False,
            E.ClassName + ': ' + E.Message);
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
