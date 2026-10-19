program Nghttp2ClientFailure;

// ============================================================================
//  Nghttp2ClientFailure - CL5.5 client reliability: the failure paths.
//
//  What a client does on SUCCESS is already covered. This gate pins what it does
//  when a peer misbehaves - which is where "working" and "production-ready"
//  diverge. For each adverse shape the client must:
//    * raise, rather than hang or return a partial body as success;
//    * leave NO open stream behind (PendingStreams = 0);
//    * free cleanly afterwards (a hung Destroy is caught by the runner's
//      timeout; an AV crashes the process -> non-zero exit -> FAIL).
//
//  Part A (always runs): an in-process TNghttp2Server control - a normal request
//  still succeeds and leaves no open stream. If Part A fails, a raise in Part B
//  means a broken client, not the adverse condition.
//
//  Part B (needs the python h2 adverse peer, client-failure-peer.py, passed as
//  `peer=PORT`): RST mid-response, GOAWAY(last_stream_id=0), a truncated body,
//  and an abrupt mid-request close. SKIPS LOUDLY when no peer port is given -
//  TNghttp2Server cannot produce these shapes, so without the peer the failure
//  paths are NOT exercised.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientFailure.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientFailure.dpr
//  Run:              Nghttp2ClientFailure [peer=19328]
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
  PORT = 19316;   { in-process control server (Part A) }

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

{ One fresh client per adverse case: raise expected, no stream left, clean Free. }
procedure AdverseRaises(const APath: string);
var
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
  LRaised: Boolean;
  LPend:   Integer;
begin
  LClient := TNghttp2Client.Create;
  try
    LClient.Connect('127.0.0.1', GPeerPort);
    LRaised := False;
    try
      LResp := LClient.SubmitRequest('GET', APath, nil, nil, REQ_TIMEOUT_MS);
    except
      on E: Exception do
        LRaised := True;
    end;
    Check(APath + ': raises rather than returning a partial success', LRaised);
    LPend := LClient.PendingStreams;
    Check(APath + ': no open stream left (PendingStreams=0)', LPend = 0,
          'PendingStreams ' + IntToStr(LPend));
  finally
    LClient.Free;
  end;
  Check(APath + ': client freed cleanly after the failure', True);
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;
  GClient: TNghttp2Client;
  GResp:   TNghttp2Response;
  GRaised: Boolean;

begin
  WriteLn('Nghttp2ClientFailure - CL5.5 client reliability: failure paths');
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

    GClient := TNghttp2Client.Create;
    try
      GClient.Connect('127.0.0.1', PORT);
      GResp := GClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
      Check('A control: GET /ok returns 200', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));
      Check('A control: a successful request leaves no open stream',
            GClient.PendingStreams = 0,
            'PendingStreams ' + IntToStr(GClient.PendingStreams));
    finally
      GClient.Free;
    end;

    GServer.Stop;
  finally
    GServer.Free;
  end;

  { ── Part B: adverse peer (needs client-failure-peer.py) ──────────────────── }
  if GPeerPort <= 0 then
  begin
    Skip('B /rst (stream reset mid-response)', 'no peer= port; python h2 peer not started');
    Skip('B /goaway (last_stream_id=0, safe to retry)', 'no peer= port');
    Skip('B /truncated (incomplete body, socket closes)', 'no peer= port');
    Skip('B /abrupt (socket closes before any response)', 'no peer= port');
  end
  else
  begin
    { peer /ok sanity — the peer itself answers before we trust its failures }
    GClient := TNghttp2Client.Create;
    try
      GClient.Connect('127.0.0.1', GPeerPort);
      GResp := GClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
      Check('B peer control: GET /ok returns 200', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));
    finally
      GClient.Free;
    end;

    { /rst — RST_STREAM after the response started }
    AdverseRaises('/rst');

    { /truncated — HEADERS + partial DATA, then the socket closes }
    AdverseRaises('/truncated');

    { /abrupt — socket closes before any response byte }
    AdverseRaises('/abrupt');

    { /goaway — last_stream_id 0: not processed, safe to replay; usable after Reconnect }
    GClient := TNghttp2Client.Create;
    try
      GClient.Connect('127.0.0.1', GPeerPort);
      GRaised := False;
      try
        GResp := GClient.SubmitRequest('GET', '/goaway', nil, nil, REQ_TIMEOUT_MS);
      except
        on E: Exception do
          GRaised := True;
      end;
      Check('/goaway: the refused request raises', GRaised);
      Check('/goaway: GoAwayReceived is set', GClient.GoAwayReceived);
      Check('/goaway: no open stream left (PendingStreams=0)',
            GClient.PendingStreams = 0,
            'PendingStreams ' + IntToStr(GClient.PendingStreams));
      GClient.Reconnect;
      GResp := GClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
      Check('/goaway: usable again after Reconnect (GET /ok = 200)',
            GResp.Status = 200, 'status ' + IntToStr(GResp.Status));
    finally
      GClient.Free;
    end;
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GSkip > 0 then
  begin
    WriteLn('        ', GSkip, ' check(s) did NOT run - the adverse peer was not');
    WriteLn('        started, so the failure paths were NOT exercised.');
  end;
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
