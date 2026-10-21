program Nghttp2ClientAsyncDeadline;

// ============================================================================
//  Nghttp2ClientAsyncDeadline - CL6b: per-request deadlines.
//
//  BeginRequest gains ADeadlineMS: this ONE stream's time budget. When it
//  passes while the stream is still open, the pump RSTs that stream (CL6a's
//  cancel path) and fails it - TakeResponse raises ENghttp2Timeout - WITHOUT
//  disturbing the other in-flight streams. Distinct from PumpAll's single
//  whole-batch budget: each stream now carries its own deadline. Cooperative
//  and single-threaded, like the rest of the client.
//
//  Part A (always runs): an in-process TNghttp2Server control. /slow sleeps
//  well past a short deadline, so the deadline must FIRE (TakeResponse raises
//  ENghttp2Timeout, and it returns near the deadline, not near the sleep) -
//  that timing gap is the teeth: with no enforcement the stream would instead
//  return 200 near the sleep. A generous deadline and a zero deadline both
//  complete (the deadline must not fire early), nothing leaks, and the client
//  stays usable.
//
//  Part B (needs the python-h2 peer, client-failure-peer.py, peer=PORT): the
//  concurrency case our own inline server cannot show - one connection with a
//  deadlined /hang stream beside a no-deadline /ok. The /hang stream times out
//  while /ok still delivers 200, and the peer's /rststat confirms the deadline's
//  RST_STREAM reached the wire (>= 1). SKIPS LOUDLY without the peer.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped (no peer / libnghttp2)
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientAsyncDeadline.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientAsyncDeadline.dpr
//  Run:              Nghttp2ClientAsyncDeadline [peer=19342]
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
  Nghttp2.Client;

const
  PORT = 19336;   { in-process control server (Part A) }

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  SLOW_SLEEP_MS = 1500;   { /slow handler blocks this long }
  DEADLINE_MS   = 300;    { the short per-request deadline under test }
  BATCH_MS      = 5000;   { PumpAll budget - far above the deadline }

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

function ElapsedMS(const AStart: TDateTime): Int64;
begin
  Result := Round((Now - AStart) * 86400.0 * 1000.0);
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
  else if AStream.Header[':path'] = '/slow' then
  begin
    { Block the handler well past the deadline, so the client's deadline must
      fire before this ever responds. }
  {$IF DEFINED(FPC)}
    Sleep(SLOW_SLEEP_MS);
  {$ELSE}
    TThread.Sleep(SLOW_SLEEP_MS);
  {$IFEND}
    AStream.StatusCode := 200;
    AStream.Send(TEncoding.UTF8.GetBytes('slow'));
  end
  else
  begin
    AStream.StatusCode := 404;
    AStream.Send(TEncoding.UTF8.GetBytes('nope'));
  end;
end;

{ ── Part A: in-process control - the deadline fires, and only when it should ─ }
procedure RunControl;
var
  LC:     TNghttp2Client;
  LC2:    TNghttp2Client;
  LResp:  TNghttp2Response;
  LId:    Int32;
  LStart: TDateTime;
  LElapsed: Int64;
  LRaisedTimeout: Boolean;
  LRaisedOther:   Boolean;
begin
  LC := TNghttp2Client.Create;
  try
    LC.Connect('127.0.0.1', PORT);

    { A1 - a generous deadline must NOT fire on a fast /ok. }
    LId := LC.BeginRequest('GET', '/ok', nil, nil, False, False, BATCH_MS);
    LC.PumpAll(BATCH_MS);
    LResp := LC.TakeResponse(LId);
    Check('A a generous deadline does not fire on a fast request (200 + ''ok'')',
          (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok'));

    { A2 - deadline 0 = no deadline: completes normally. }
    LId := LC.BeginRequest('GET', '/ok', nil, nil, False, False, 0);
    LC.PumpAll(BATCH_MS);
    LResp := LC.TakeResponse(LId);
    Check('A deadline 0 = none: the request completes (200 + ''ok'')',
          (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok'));
  finally
    LC.Free;
  end;

  { A3 - the deadline FIRES on a stream slower than it. A dedicated client, so
    the server's lingering /slow sleep does not stall the checks below. }
  LC2 := TNghttp2Client.Create;
  try
    LC2.Connect('127.0.0.1', PORT);
    LId := LC2.BeginRequest('GET', '/slow', nil, nil, False, False, DEADLINE_MS);
    LStart := Now;
    LC2.PumpAll(BATCH_MS);
    LElapsed := ElapsedMS(LStart);

    { Returned near the deadline, nowhere near the sleep - the teeth: with no
      enforcement PumpAll would wait out the SLOW_SLEEP_MS handler instead. }
    Check('A the deadline returns near its budget, not near the slow handler',
          (LElapsed >= 200) and (LElapsed < SLOW_SLEEP_MS - 200),
          Format('elapsed %d ms (deadline %d, sleep %d)',
                 [LElapsed, DEADLINE_MS, SLOW_SLEEP_MS]));

    LRaisedTimeout := False;
    LRaisedOther := False;
    try
      LC2.TakeResponse(LId);
    except
      on E: ENghttp2Timeout do
        LRaisedTimeout := True;
      on E: ENghttp2Client do
        LRaisedOther := True;
    end;
    Check('A TakeResponse on the deadlined stream raises ENghttp2Timeout',
          LRaisedTimeout,
          'raisedTimeout=' + BoolToStr(LRaisedTimeout, True)
          + ' raisedOther=' + BoolToStr(LRaisedOther, True));
    Check('A no leaked stream after the deadline (PendingStreams=0)',
          LC2.PendingStreams = 0,
          'PendingStreams ' + IntToStr(LC2.PendingStreams));
  finally
    LC2.Free;   { abandons the still-sleeping /slow handler's connection }
  end;

  { A4 - a fresh client is healthy (the deadline path did not wedge anything). }
  LC := TNghttp2Client.Create;
  try
    LC.Connect('127.0.0.1', PORT);
    LResp := LC.SubmitRequest('GET', '/ok', nil, nil, BATCH_MS);
    Check('A the client is usable after a deadline fired (GET /ok = 200)',
          (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok'));
  finally
    LC.Free;
  end;
end;

{ ── Part B: adverse peer - one stream's deadline fires, the sibling does not ─ }
procedure RunAdverse;
var
  LC:     TNghttp2Client;
  LResp:  TNghttp2Response;
  LHang:  Int32;
  LOk:    Int32;
  LOkResp: TNghttp2Response;
  LCount: Integer;
  LBody:  string;
  LRaisedTimeout: Boolean;
begin
  LC := TNghttp2Client.Create;
  try
    LC.Connect('127.0.0.1', GPeerPort);

    LResp := LC.SubmitRequest('GET', '/ok', nil, nil, BATCH_MS);
    Check('B peer control: GET /ok returns 200', LResp.Status = 200,
          'status ' + IntToStr(LResp.Status));

    { A deadlined /hang (peer never ends it) beside a no-deadline /ok on ONE
      connection. The deadline must fire the /hang stream while /ok completes. }
    LHang := LC.BeginRequest('GET', '/hang', nil, nil, False, False, DEADLINE_MS);
    LOk   := LC.BeginRequest('GET', '/ok',   nil, nil);
    LC.PumpAll(BATCH_MS);

    LOkResp := LC.TakeResponse(LOk);
    Check('B the no-deadline sibling still delivered (200 + ''ok'')',
          (LOkResp.Status = 200) and (TEncoding.UTF8.GetString(LOkResp.Body) = 'ok'));

    LRaisedTimeout := False;
    try
      LC.TakeResponse(LHang);
    except
      on E: ENghttp2Timeout do
        LRaisedTimeout := True;
    end;
    Check('B the deadlined stream raises ENghttp2Timeout', LRaisedTimeout);

    { The peer confirms the deadline's RST_STREAM reached the wire. }
    LResp := LC.SubmitRequest('GET', '/rststat', nil, nil, BATCH_MS);
    LBody := TEncoding.UTF8.GetString(LResp.Body);
    LCount := StrToIntDef(LBody, -1);
    Check('B the deadline''s RST_STREAM reached the peer (rststat >= 1)',
          LCount >= 1, 'rststat=' + LBody);

    Check('B no leaked stream after the deadline (PendingStreams=0)',
          LC.PendingStreams = 0, 'PendingStreams ' + IntToStr(LC.PendingStreams));
  finally
    LC.Free;
  end;
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;

begin
  WriteLn('Nghttp2ClientAsyncDeadline - CL6b: per-request deadlines');
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
    Skip('B deadline-with-a-live-sibling', 'no peer= port; python h2 peer not started')
  else
    RunAdverse;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GSkip > 0 then
  begin
    WriteLn('        ', GSkip, ' check(s) did NOT run - the adverse peer was not');
    WriteLn('        started, so the deadline-with-a-live-sibling case was NOT run.');
  end;
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
