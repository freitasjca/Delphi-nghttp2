program Nghttp2ClientRetrySafety;

// ============================================================================
//  Nghttp2ClientRetrySafety - CL5.5 RETRYSAFE-1: is a failed request replayable?
//
//  Nghttp2ClientFailure (stage 4o) pins that each adverse shape RAISES and
//  leaves no leaked stream. This gate pins the next question: for each failure,
//  does ENghttp2Client.SafeToRetry correctly say whether the server provably did
//  NOT process the request (RFC 7540 8.1.4)? That is the contract a retry policy
//  or a connection pool must read before replaying a non-idempotent request.
//
//  The classification under test:
//    SAFE to retry (SafeToRetry = True)  - the server declared it never
//      processed the stream:
//        /refused  RST_STREAM(REFUSED_STREAM), no prior response
//        /goaway   GOAWAY(last_stream_id=0): our stream is above it, so nghttp2
//                  surfaces it as REFUSED_STREAM
//    UNCERTAIN (SafeToRetry = False) - the server may already have acted, so a
//      non-idempotent request must NOT be auto-retried:
//        /rst        a reset AFTER the response began (HEADERS 200 then RST)
//        /truncated  the socket dropped mid-body
//        /abrupt     the socket dropped before any response byte
//
//  Part A (always runs): an in-process TNghttp2Server control - a normal request
//  succeeds (no exception, so SafeToRetry does not arise).
//
//  Part B (needs the python h2 adverse peer, client-failure-peer.py, passed as
//  peer=PORT): the five shapes above. SKIPS LOUDLY without the peer -
//  TNghttp2Server cannot produce a bare REFUSED_STREAM or a mid-flight drop.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientRetrySafety.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientRetrySafety.dpr
//  Run:              Nghttp2ClientRetrySafety [peer=19333]
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
  PORT = 19318;   { in-process control server (Part A) }

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

{ One fresh client per case: the request must raise ENghttp2Client, and its
  SafeToRetry must match the expected classification for that shape. }
procedure ExpectRetry(const APath: string; AExpected: Boolean);
var
  LClient:    TNghttp2Client;
  LResp:      TNghttp2Response;
  LRaised:    Boolean;
  LWrongType: Boolean;
  LSafe:      Boolean;
  LWhat:      string;
begin
  LClient := TNghttp2Client.Create;
  try
    LClient.Connect('127.0.0.1', GPeerPort);
    LRaised    := False;
    LWrongType := False;
    LSafe      := False;
    LWhat      := '';
    try
      LResp := LClient.SubmitRequest('GET', APath, nil, nil, REQ_TIMEOUT_MS);
    except
      on E: ENghttp2Client do
      begin
        LRaised := True;
        LSafe   := E.SafeToRetry;
      end;
      on E: Exception do
      begin
        LRaised    := True;
        LWrongType := True;
        LWhat      := E.ClassName;
      end;
    end;
    Check(APath + ': raises ENghttp2Client (or a subclass)',
          LRaised and (not LWrongType),
          'raised=' + BoolToStr(LRaised, True) + ' class=' + LWhat);
    if AExpected then
      Check(APath + ': SafeToRetry = True (server did not process it)',
            LSafe, 'SafeToRetry=' + BoolToStr(LSafe, True))
    else
      Check(APath + ': SafeToRetry = False (uncertain - may have been processed)',
            not LSafe, 'SafeToRetry=' + BoolToStr(LSafe, True));
  finally
    LClient.Free;
  end;
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;
  GClient: TNghttp2Client;
  GResp:   TNghttp2Response;

begin
  WriteLn('Nghttp2ClientRetrySafety - CL5.5 RETRYSAFE-1: is a failed request replayable?');
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
      Check('A control: a successful request does not raise (status 200)',
            GResp.Status = 200, 'status ' + IntToStr(GResp.Status));
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
    Skip('B /refused SafeToRetry', 'no peer= port; python h2 peer not started');
    Skip('B /goaway SafeToRetry', 'no peer= port');
    Skip('B /rst SafeToRetry', 'no peer= port');
    Skip('B /truncated SafeToRetry', 'no peer= port');
    Skip('B /abrupt SafeToRetry', 'no peer= port');
  end
  else
  begin
    { peer /ok sanity — the peer answers before we trust its failures }
    GClient := TNghttp2Client.Create;
    try
      GClient.Connect('127.0.0.1', GPeerPort);
      GResp := GClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
      Check('B peer control: GET /ok returns 200', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));
    finally
      GClient.Free;
    end;

    { SAFE: the server declared the stream unprocessed }
    ExpectRetry('/refused', True);
    ExpectRetry('/goaway',  True);

    { UNCERTAIN: the server may already have acted }
    ExpectRetry('/rst',       False);
    ExpectRetry('/truncated', False);
    ExpectRetry('/abrupt',    False);
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GSkip > 0 then
  begin
    WriteLn('        ', GSkip, ' check(s) did NOT run - the adverse peer was not');
    WriteLn('        started, so the retry classification was NOT exercised.');
  end;
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
