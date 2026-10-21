program Nghttp2ClientAsyncCancel;

// ============================================================================
//  Nghttp2ClientAsyncCancel - CL6a: per-request cancellation (+ the async pump).
//
//  CL6 grows TNghttp2Client into an async client: non-blocking submit
//  (BeginRequest, already there), a bounded cooperative pump (Pump, new here),
//  poll/reap (TakeResponse), and - this slice - per-request CANCELLATION.
//  CancelRequest sends RST_STREAM(CANCEL) for one in-flight stream and flushes
//  it, so nghttp2 closes the stream and discards any response already in flight;
//  the slot is marked done-with-cancel and TakeResponse then raises rather than
//  returning a body. Cooperative, single-threaded: no background thread (the
//  libnghttp2 one-driver rule), so the cancel takes effect on its own flush.
//
//  Part A (always runs): an in-process TNghttp2Server control proves the
//  CLIENT-SIDE contract - a cancelled stream delivers no response (Status 0),
//  PumpAll no longer waits on it, TakeResponse raises, nothing leaks, and the
//  connection stays usable; cancel of an unknown stream raises; cancel of an
//  already-completed stream is a no-op that keeps the real response.
//
//  Part A cannot, by itself, tell a real RST on the wire from a CancelRequest
//  that merely set a local flag - our own server is the peer, and a cancelled
//  stream looks undelivered either way. So Part B (needs the python-h2 peer,
//  client-failure-peer.py, peer=PORT) drives a /hang stream the peer leaves
//  open, cancels it, then asks the peer /rststat: the count of RST_STREAM
//  frames it actually received. >= 1 proves the cancel reached the wire; it is
//  0 if CancelRequest forgot to send the RST. SKIPS LOUDLY without the peer.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped (no peer / libnghttp2)
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientAsyncCancel.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientAsyncCancel.dpr
//  Run:              Nghttp2ClientAsyncCancel [peer=19341]
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
  PORT = 19321;   { in-process control server (Part A) }

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  REQ_TIMEOUT_MS = 5000;

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

{ Reap a stream expected to have been cancelled: TakeResponse must raise, and
  the message must name the cancel. Returns True on the expected raise. }
function TookRaisedCancelled(AClient: TNghttp2Client; AStreamId: Int32): Boolean;
begin
  Result := False;
  try
    AClient.TakeResponse(AStreamId);
  except
    on E: ENghttp2Client do
      Result := Pos('cancel', LowerCase(E.Message)) > 0;
  end;
end;

{ ── Part A: in-process control - the client-side cancel contract ──────────── }
procedure RunControl;
var
  LC:    TNghttp2Client;
  LIds:  array[0..3] of Int32;
  LResp: TNghttp2Response;
  LPeek: TNghttp2Response;
  LId:   Int32;
  LRaised: Boolean;
  I:     Integer;
begin
  LC := TNghttp2Client.Create;
  try
    LC.Connect('127.0.0.1', PORT);

    { A1 - submit four, cancel two BEFORE any pump, then pump to completion. }
    for I := 0 to 3 do
      LIds[I] := LC.BeginRequest('GET', '/ok', nil, nil);
    LC.CancelRequest(LIds[1]);
    LC.CancelRequest(LIds[3]);
    LC.PumpAll(REQ_TIMEOUT_MS);

    LPeek := Default(TNghttp2Response);
    Check('A the live streams delivered (status 200)',
          LC.PeekResponseHeaders(LIds[0], LPeek) and (LPeek.Status = 200),
          'status ' + IntToStr(LPeek.Status));
    LPeek := Default(TNghttp2Response);
    Check('A the second live stream delivered (status 200)',
          LC.PeekResponseHeaders(LIds[2], LPeek) and (LPeek.Status = 200),
          'status ' + IntToStr(LPeek.Status));
    { The load-bearing client-side check: a cancelled stream captured NO
      response - nghttp2 discarded the server's reply for the reset stream. }
    LPeek := Default(TNghttp2Response);
    Check('A a cancelled stream delivered no status (reset discarded it)',
          LC.PeekResponseHeaders(LIds[1], LPeek) and (LPeek.Status = 0),
          'status ' + IntToStr(LPeek.Status));
    LPeek := Default(TNghttp2Response);
    Check('A the second cancelled stream delivered no status',
          LC.PeekResponseHeaders(LIds[3], LPeek) and (LPeek.Status = 0),
          'status ' + IntToStr(LPeek.Status));

    { A2 - reap: the live ones return 200 + body, the cancelled ones raise. }
    LResp := LC.TakeResponse(LIds[0]);
    Check('A TakeResponse on a live stream returns 200 + ''ok''',
          (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok'));
    LResp := LC.TakeResponse(LIds[2]);
    Check('A the second live stream returns 200 + ''ok''',
          (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok'));
    Check('A TakeResponse on a cancelled stream raises (no delivery)',
          TookRaisedCancelled(LC, LIds[1]));
    Check('A the second cancelled stream raises on TakeResponse',
          TookRaisedCancelled(LC, LIds[3]));

    { A3 - nothing leaked: every slot reaped. }
    Check('A no leaked stream after reaping all four (PendingStreams=0)',
          LC.PendingStreams = 0, 'PendingStreams ' + IntToStr(LC.PendingStreams));

    { A4 - cancel of an unknown stream raises. }
    LRaised := False;
    try
      LC.CancelRequest(999999);
    except
      on E: ENghttp2Client do
        LRaised := True;
    end;
    Check('A CancelRequest on an unknown stream raises', LRaised);

    { A5 - cancel of an already-completed stream is a no-op: the real response
      is kept and TakeResponse still returns it. }
    LId := LC.BeginRequest('GET', '/ok', nil, nil);
    LC.PumpAll(REQ_TIMEOUT_MS);
    LRaised := False;
    try
      LC.CancelRequest(LId);
    except
      on E: Exception do
        LRaised := True;
    end;
    Check('A CancelRequest on a completed stream is a no-op (does not raise)',
          not LRaised);
    LResp := LC.TakeResponse(LId);
    Check('A ... and the real response is kept (200 + ''ok'')',
          (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok'));

    { A6 - the connection is still healthy after the cancels. }
    LResp := LC.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
    Check('A the client is still usable after cancelling (GET /ok = 200)',
          (LResp.Status = 200) and (TEncoding.UTF8.GetString(LResp.Body) = 'ok'));
  finally
    LC.Free;
  end;
end;

{ ── Part B: adverse peer - the RST reaches the wire (mutation-resistant) ───── }
procedure RunAdverse;
var
  LC:     TNghttp2Client;
  LResp:  TNghttp2Response;
  LHang:  Int32;
  LCount: Integer;
  LBody:  string;
begin
  LC := TNghttp2Client.Create;
  try
    LC.Connect('127.0.0.1', GPeerPort);

    LResp := LC.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
    Check('B peer control: GET /ok returns 200', LResp.Status = 200,
          'status ' + IntToStr(LResp.Status));

    { Open a stream the peer keeps open (HEADERS 200, no END), pump ONE pass to
      put the request on the wire and read those headers, then cancel it. }
    LHang := LC.BeginRequest('GET', '/hang', nil, nil);
    LC.Pump(REQ_TIMEOUT_MS);
    Check('B the /hang stream is in flight after one pump',
          LC.PendingStreams >= 1,
          'PendingStreams ' + IntToStr(LC.PendingStreams));

    LC.CancelRequest(LHang);

    { Ask the peer how many RST_STREAM frames it has received. This is the
      teeth: 0 if CancelRequest never put the reset on the wire. }
    LResp := LC.SubmitRequest('GET', '/rststat', nil, nil, REQ_TIMEOUT_MS);
    LBody := TEncoding.UTF8.GetString(LResp.Body);
    LCount := StrToIntDef(LBody, -1);
    Check('B the peer received the RST_STREAM on the wire (rststat >= 1)',
          LCount >= 1, 'rststat=' + LBody);

    Check('B TakeResponse on the cancelled /hang stream raises',
          TookRaisedCancelled(LC, LHang));
    Check('B no leaked stream after the cancel (PendingStreams=0)',
          LC.PendingStreams = 0, 'PendingStreams ' + IntToStr(LC.PendingStreams));
  finally
    LC.Free;
  end;
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;

begin
  WriteLn('Nghttp2ClientAsyncCancel - CL6a: per-request cancellation');
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
    Skip('B RST-on-the-wire confirmation', 'no peer= port; python h2 peer not started');
  end
  else
    RunAdverse;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GSkip > 0 then
  begin
    WriteLn('        ', GSkip, ' check(s) did NOT run - the adverse peer was not');
    WriteLn('        started, so the RST-on-the-wire proof was NOT exercised.');
  end;
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
