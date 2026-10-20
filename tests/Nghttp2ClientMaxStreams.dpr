program Nghttp2ClientMaxStreams;

// ============================================================================
//  Nghttp2ClientMaxStreams - CL5.5 MAXSTREAMS-1: the peer's stream limit, seen.
//
//  HTTP/2 stream capacity (how many requests may be open at once on ONE
//  connection) and pool capacity (how many connections) are SEPARATE limits.
//  The client submits its own SETTINGS but never exposed the PEER's advertised
//  SETTINGS_MAX_CONCURRENT_STREAMS - so a pool could not tell whether to open
//  another stream on a leased connection or lease a second one. This gate pins
//  the new accessor TNghttp2Client.PeerMaxConcurrentStreams and the fact that
//  submitting MORE than the limit still completes (nghttp2 queues the excess;
//  it does not fail).
//
//  Decision recorded with this gate: the client EXPOSES the limit and lets
//  nghttp2 queue excess submissions transparently; the pool keeps leasing whole
//  connections and does not cap streams itself. Correctness is already in
//  nghttp2 - this adds the visibility the pool decision needs.
//
//  Entirely in-process: the server advertises MaxConcurrentStreams = 2, and
//  nghttp2 ENFORCES that server-side (a 3rd concurrent inbound stream would be
//  REFUSED_STREAM). So if the client did NOT respect the limit, opening 5 at
//  once would fail; it respects it, so all 5 complete. No python peer needed,
//  so the whole stage always runs.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientMaxStreams.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientMaxStreams.dpr
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
  PORT       = 19319;   { in-process server }
  PEER_LIMIT = 2;       { the server advertises this; the client must read it }
  BURST      = 5;       { more than the limit, to prove excess is queued }

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

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;
  GClient: TNghttp2Client;
  GResp:   TNghttp2Response;
  GPeerMax: Cardinal;
  GIds:    array[0..BURST - 1] of Int32;
  GOkCount: Integer;
  I:       Integer;

begin
  WriteLn('Nghttp2ClientMaxStreams - CL5.5 MAXSTREAMS-1: the peer''s stream limit, seen');
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

  { A client that never connected reports 0, not a dereference of a nil session. }
  GClient := TNghttp2Client.Create;
  try
    Check('a fresh (unconnected) client reports PeerMaxConcurrentStreams = 0',
          GClient.PeerMaxConcurrentStreams = 0,
          'got ' + IntToStr(GClient.PeerMaxConcurrentStreams));
  finally
    GClient.Free;
  end;

  GServer := TNghttp2Server.Create;
  try
    GServer.OnRequest := HandleRequest;
    GConfig := TNghttp2Config.Default;
    GConfig.Port := PORT;
    GConfig.MaxConcurrentStreams := PEER_LIMIT;   { what the client must read back }
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
    Check('server started on port ' + IntToStr(PORT) +
          ' advertising MAX_CONCURRENT_STREAMS = ' + IntToStr(PEER_LIMIT), True);

    GClient := TNghttp2Client.Create;
    try
      GClient.Connect('127.0.0.1', PORT);

      { One request completes the SETTINGS exchange, so the peer's value is known. }
      GResp := GClient.SubmitRequest('GET', '/ok', nil, nil, REQ_TIMEOUT_MS);
      Check('GET /ok returns 200 (SETTINGS now exchanged)', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));

      GPeerMax := GClient.PeerMaxConcurrentStreams;
      Check('PeerMaxConcurrentStreams reads the server''s advertised ' +
            IntToStr(PEER_LIMIT), GPeerMax = PEER_LIMIT,
            'got ' + IntToStr(GPeerMax));

      { Submit BURST (> limit) concurrent streams at once. nghttp2 keeps the
        excess pending and sends them as slots free, so the server never sees
        more than PEER_LIMIT open and never RST_STREAMs one. All must complete. }
      for I := 0 to BURST - 1 do
        GIds[I] := GClient.BeginRequest('GET', '/ok', nil, nil);
      GClient.PumpAll(REQ_TIMEOUT_MS);

      GOkCount := 0;
      for I := 0 to BURST - 1 do
      begin
        GResp := GClient.TakeResponse(GIds[I]);
        if GResp.Status = 200 then
          Inc(GOkCount);
      end;
      Check('all ' + IntToStr(BURST) + ' concurrent requests (> limit) returned 200',
            GOkCount = BURST, IntToStr(GOkCount) + '/' + IntToStr(BURST) + ' ok');
      Check('no stream left open after the burst (PendingStreams=0)',
            GClient.PendingStreams = 0,
            'PendingStreams ' + IntToStr(GClient.PendingStreams));
    finally
      GClient.Free;
    end;

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
