program Nghttp2ClientAsyncComplete;

// ============================================================================
//  Nghttp2ClientAsyncComplete - CL6c: completion callback + 100 in flight.
//
//  The last CL6 slice closes the async model. The pieces already exist:
//  BeginRequest (non-blocking submit), Pump (bounded cooperative pump,
//  CL6a), TakeResponse (reap), CancelRequest (CL6a) and per-request deadlines
//  (CL6b). This adds OnComplete: an opt-in callback fired once, on the pump
//  thread, as each stream reaches a terminal state (completed, errored,
//  cancelled or timed out) during Pump/PumpAll - push-style completion instead
//  of polling. A plain procedure (FPC 3.2.2-clean), given the client so it can
//  TakeResponse the finished stream.
//
//  All in-process against our own TNghttp2Server: "100 in flight from one
//  thread" and the callback are COOPERATIVE DISPATCH, not protocol behaviour,
//  so our own server is the right peer (same reasoning as the CL5 pool gate).
//  No external peer; always runs (skips only without libnghttp2).
//
//    1 - poll: submit 100, Pump until none pending, TakeResponse each -> 100x200,
//        no leak. The plan's "100 in-flight requests from one thread".
//    2 - push: the same 100 with OnComplete set - it fires EXACTLY once per
//        stream (nothing before the first Pump: the pump drives it), the
//        callback reaps each to 200, and nothing leaks. Over/under-firing is
//        caught (a double fire makes the 2nd TakeResponse raise).
//    3 - terminal, not just success: OnComplete also fires for a cancelled
//        stream (its TakeResponse raises), beside a completed one.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped (libnghttp2 absent)
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientAsyncComplete.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientAsyncComplete.dpr
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
  Nghttp2.Client;

const
  PORT = 19337;   { in-process server }

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  NREQ        = 100;     { in-flight streams from one thread }
  PUMP_MS     = 2000;    { per-pass read budget }
  OVERALL_MS  = 20000;   { wall-clock safety cap on the Pump loop }

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSkip: Integer = 0;

  { Callback counters (single-threaded: the callback runs on this thread). }
  GFired: Integer = 0;   { OnComplete calls }
  GOk:    Integer = 0;   { reaped to 200 + 'ok' }
  GErr:   Integer = 0;   { terminal but not 200 (raised, or wrong body) }

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
  else
  begin
    AStream.StatusCode := 404;
    AStream.Send(TEncoding.UTF8.GetBytes('nope'));
  end;
end;

{ [CL6c] OnComplete: reap the finished stream and tally. A cancelled/errored
  stream raises in TakeResponse - that is a terminal completion too. }
procedure HandleComplete(AClient: TNghttp2Client; AStreamId: Int32);
var
  LResp: TNghttp2Response;
begin
  Inc(GFired);
  try
    LResp := AClient.TakeResponse(AStreamId);
    if (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok') then
      Inc(GOk)
    else
      Inc(GErr);
  except
    on E: Exception do
      Inc(GErr);
  end;
end;

{ Drive the pump from one thread until nothing is pending or the safety cap. }
procedure PumpToIdle(AClient: TNghttp2Client);
var
  LStart: TDateTime;
begin
  LStart := Now;
  while (AClient.Pump(PUMP_MS) > 0) and (ElapsedMS(LStart) < OVERALL_MS) do
    ;
end;

{ ── 1 - 100 in flight from one thread, polled with TakeResponse ───────────── }
procedure RunPoll;
var
  LC:    TNghttp2Client;
  LIds:  array of Int32;
  LResp: TNghttp2Response;
  LOk:   Integer;
  I:     Integer;
begin
  LC := TNghttp2Client.Create;
  try
    LC.Connect('127.0.0.1', PORT);
    SetLength(LIds, NREQ);
    for I := 0 to NREQ - 1 do
      LIds[I] := LC.BeginRequest('GET', '/ok', nil, nil);

    PumpToIdle(LC);
    Check(Format('poll: all %d submitted streams reached done (PendingStreams=0)',
            [NREQ]),
          LC.PendingStreams = 0, 'PendingStreams ' + IntToStr(LC.PendingStreams));

    LOk := 0;
    for I := 0 to NREQ - 1 do
    begin
      LResp := LC.TakeResponse(LIds[I]);
      if (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok') then
        Inc(LOk);
    end;
    Check(Format('poll: every one delivered 200 + ''ok'' (%d/%d)', [LOk, NREQ]),
          LOk = NREQ, IntToStr(LOk) + ' ok');
    Check('poll: nothing left after reaping (PendingStreams=0)',
          LC.PendingStreams = 0, 'PendingStreams ' + IntToStr(LC.PendingStreams));
  finally
    LC.Free;
  end;
end;

{ ── 2 - the same 100, delivered push-style through OnComplete ─────────────── }
procedure RunPush;
var
  LC: TNghttp2Client;
  I:  Integer;
begin
  GFired := 0; GOk := 0; GErr := 0;
  LC := TNghttp2Client.Create;
  try
    LC.Connect('127.0.0.1', PORT);
    LC.OnComplete := HandleComplete;
    for I := 0 to NREQ - 1 do
      LC.BeginRequest('GET', '/ok', nil, nil);

    { The instrument must be seen to fire, and to fire BECAUSE of the pump:
      nothing has pumped yet, so no completion can have been delivered. }
    Check('push: OnComplete has not fired before the first Pump',
          GFired = 0, 'GFired ' + IntToStr(GFired));

    PumpToIdle(LC);

    Check(Format('push: OnComplete fired exactly once per stream (%d/%d)',
            [GFired, NREQ]),
          GFired = NREQ, 'GFired ' + IntToStr(GFired));
    Check(Format('push: the callback reaped every one to 200 (%d/%d, %d err)',
            [GOk, NREQ, GErr]),
          (GOk = NREQ) and (GErr = 0), Format('ok %d err %d', [GOk, GErr]));
    Check('push: nothing leaked - the callback reaped all (PendingStreams=0)',
          LC.PendingStreams = 0, 'PendingStreams ' + IntToStr(LC.PendingStreams));
  finally
    LC.Free;
  end;
end;

{ ── 3 - OnComplete fires for a terminal stream that did NOT succeed ───────── }
procedure RunTerminalNonSuccess;
var
  LC:  TNghttp2Client;
  LOk, LCancel: Int32;
begin
  GFired := 0; GOk := 0; GErr := 0;
  LC := TNghttp2Client.Create;
  try
    LC.Connect('127.0.0.1', PORT);
    LC.OnComplete := HandleComplete;
    LOk     := LC.BeginRequest('GET', '/ok', nil, nil);
    LCancel := LC.BeginRequest('GET', '/ok', nil, nil);
    LC.CancelRequest(LCancel);   { terminal before it could complete }

    PumpToIdle(LC);

    Check('terminal: OnComplete fired for BOTH the completed and the cancelled stream',
          GFired = 2, 'GFired ' + IntToStr(GFired));
    Check('terminal: one reaped to 200, one raised (cancelled)',
          (GOk = 1) and (GErr = 1), Format('ok %d err %d', [GOk, GErr]));
    Check('terminal: nothing leaked (PendingStreams=0)',
          LC.PendingStreams = 0, 'PendingStreams ' + IntToStr(LC.PendingStreams));
    if LOk = LCancel then ;   { silence "assigned and never used" on some setups }
  finally
    LC.Free;
  end;
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;

begin
  WriteLn('Nghttp2ClientAsyncComplete - CL6c: completion callback + 100 in flight');
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

    RunPoll;
    RunPush;
    RunTerminalNonSuccess;

    GServer.Stop;
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
