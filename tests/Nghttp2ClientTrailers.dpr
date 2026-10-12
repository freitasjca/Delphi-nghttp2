program Nghttp2ClientTrailers;

// ============================================================================
//  Nghttp2ClientTrailers - GC1 of the B2 gRPC client plan
//  (plans/grpc-client-b2.md): TNghttp2Response.Trailers and .HeadersOnly.
//
//  ── Why this exists ──
//
//  Before GC1 the client put every non-pseudo header field into
//  Response.Headers, whichever HEADERS block it arrived in. A gRPC client has
//  to know WHERE grpc-status came from: in the trailer section after a body,
//  or in a headers-only ("Trailers-Only") response. A status found anywhere
//  else, or none at all, is a protocol error rather than a status. Headers
//  alone cannot say which.
//
//  GC1 adds Trailers (the fields of a HEADERS block after the final response
//  headers) and HeadersOnly (one HEADERS block that ended the stream), and
//  leaves Headers exactly as it was. Every part of that sentence is checked
//  here, the "exactly as it was" half included.
//
//  ── Two servers, on purpose ──
//
//  Part A - our own TNghttp2Server, in process. Always runs. Covers buffered
//  and streamed bodies with and without trailers, and two concurrent streams
//  on one connection so a trailer cannot land on the wrong stream.
//
//  Part B - client-trailers-peer.py, an independent HTTP/2 implementation
//  (python h2). Needed, not just nice: TNghttp2Server always sends a DATA
//  frame, even for an empty body, so it cannot produce a headers-only
//  response or a 1xx informational block at all. Pass peer=<port> to run it;
//  without it Part B prints SKIP - a skip is not a pass.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ClientTrailers.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ClientTrailers.dpr
//  Run:              Nghttp2ClientTrailers [peer=19322]
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  { cthreads first on Unix: the server starts a thread per connection. }
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
  { Clear of the other library stages: smoke 19311, ALPN 19312/19313, read
    timeout 19314, stream read 19315, connect timeout 19317/19318. The Python
    peer's port is chosen by the runner (19322 by convention). }
  PORT = 19321;

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  READ_SIZE       = 64;
  READ_TIMEOUT_MS = 5000;

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSkip: Integer = 0;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    Inc(GPass);
    WriteLn('  PASS  ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('  FAIL  ', AName, '  <- ', ADetail)
    else
      WriteLn('  FAIL  ', AName);
  end;
end;

procedure Skip(const AName, AReason: string);
begin
  Inc(GSkip);
  WriteLn('  SKIP  ', AName, '  [', AReason, ']');
end;

// ── helpers over TNghttp2Headers ────────────────────────────────────────────

function FindValue(const AList: TNghttp2Headers; const AName: string;
  out AValue: string): Boolean;
var
  I: Integer;
begin
  AValue := '';
  for I := 0 to High(AList) do
    if SameText(AList[I].Name, AName) then
    begin
      AValue := AList[I].Value;
      Exit(True);
    end;
  Result := False;
end;

function Has(const AList: TNghttp2Headers; const AName: string): Boolean;
var
  LIgnored: string;
begin
  Result := FindValue(AList, AName, LIgnored);
end;

function ValueIs(const AList: TNghttp2Headers; const AName, AExpected: string): Boolean;
var
  LValue: string;
begin
  Result := FindValue(AList, AName, LValue) and (LValue = AExpected);
end;

{ For failure details: the fields as name=value, comma separated. }
function Dump(const AList: TNghttp2Headers): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AList) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + AList[I].Name + '=' + AList[I].Value;
  end;
  Result := '[' + Result + ']';
end;

function BodyText(const AResp: TNghttp2Response): string;
begin
  Result := TEncoding.UTF8.GetString(AResp.Body);
end;

// ── Part A server ───────────────────────────────────────────────────────────

{ A PLAIN procedure: the only OnRequest shape that compiles on FPC without
  FUNCTIONREFERENCES (same rule as Nghttp2ServerSmoke). }
procedure HandleRequest(const AStream: INghttp2Stream);
var
  LPath: string;
  LEmpty: TBytes;
  I: Integer;
begin
  LPath := AStream.Header[':path'];
  if LPath = '/trailers' then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'application/grpc';
    AStream.AddTrailer('grpc-status', '0');
    AStream.AddTrailer('grpc-message', 'done');
    AStream.Send(TEncoding.UTF8.GetBytes('body'));
  end
  else if LPath = '/plain' then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain';
    AStream.Send(TEncoding.UTF8.GetBytes('plain'));
  end
  else if LPath = '/empty-with-trailer' then
  begin
    AStream.StatusCode := 200;
    AStream.AddTrailer('x-trailer', 'only');
    SetLength(LEmpty, 0);
    AStream.Send(LEmpty);
  end
  else if LPath = '/stream-trailers' then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain';
    AStream.BeginStreaming;
    for I := 1 to 3 do
    begin
      if not AStream.IsStreamAlive then Break;
      AStream.PushStreamData(TEncoding.UTF8.GetBytes('chunk' + IntToStr(I) + ';'));
    end;
    { Added after the data, before EndStreaming: the gRPC order, where the
      status is only known once the last message has been produced. }
    AStream.AddTrailer('grpc-status', '0');
    AStream.EndStreaming;
  end
  else
  begin
    AStream.StatusCode := 404;
    AStream.Send(TEncoding.UTF8.GetBytes('nope'));
  end;
end;

procedure PartA(AClient: TNghttp2Client);
var
  LResp:   TNghttp2Response;
  LId1:    Int32;
  LId2:    Int32;
  LBuf:    TBytes;
  LGot:    Integer;
  LText:   string;
  LBody:   TBytes;
begin
  WriteLn;
  WriteLn('-- A1  body + trailer section (our server)');
  LResp := AClient.SubmitRequest('GET', '/trailers', nil, nil);
  Check('status 200 and the body', (LResp.Status = 200) and (BodyText(LResp) = 'body'),
    Format('status %d, body "%s"', [LResp.Status, BodyText(LResp)]));
  Check('Trailers holds exactly grpc-status and grpc-message',
    (Length(LResp.Trailers) = 2) and ValueIs(LResp.Trailers, 'grpc-status', '0')
    and ValueIs(LResp.Trailers, 'grpc-message', 'done'), Dump(LResp.Trailers));
  Check('a response header (content-type) is NOT in Trailers',
    not Has(LResp.Trailers, 'content-type'), Dump(LResp.Trailers));
  Check('Headers still carries content-type',
    ValueIs(LResp.Headers, 'content-type', 'application/grpc'), Dump(LResp.Headers));
  Check('Headers STILL carries the trailer fields too (pre-GC1 behaviour kept)',
    ValueIs(LResp.Headers, 'grpc-status', '0')
    and ValueIs(LResp.Headers, 'grpc-message', 'done'), Dump(LResp.Headers));
  Check('HeadersOnly is False when a body was sent', not LResp.HeadersOnly);

  WriteLn;
  WriteLn('-- A2  no trailers (control)');
  LResp := AClient.SubmitRequest('GET', '/plain', nil, nil);
  Check('status 200 and the body', (LResp.Status = 200) and (BodyText(LResp) = 'plain'),
    Format('status %d, body "%s"', [LResp.Status, BodyText(LResp)]));
  Check('Trailers is empty', Length(LResp.Trailers) = 0, Dump(LResp.Trailers));
  Check('HeadersOnly is False (our server always sends DATA)', not LResp.HeadersOnly);

  WriteLn;
  WriteLn('-- A3  empty body + trailer');
  LResp := AClient.SubmitRequest('GET', '/empty-with-trailer', nil, nil);
  Check('status 200, empty body', (LResp.Status = 200) and (Length(LResp.Body) = 0),
    Format('status %d, %d body bytes', [LResp.Status, Length(LResp.Body)]));
  Check('the trailer arrives in Trailers',
    (Length(LResp.Trailers) = 1) and ValueIs(LResp.Trailers, 'x-trailer', 'only'),
    Dump(LResp.Trailers));
  Check('HeadersOnly is False: a trailer section is not a headers-only response',
    not LResp.HeadersOnly);

  WriteLn;
  WriteLn('-- A4  streamed body (ReadChunk) + trailer');
  SetLength(LBody, 0);
  LId1 := AClient.BeginRequest('GET', '/stream-trailers', nil, LBody, True);
  LText := '';
  repeat
    LGot := AClient.ReadChunk(LId1, LBuf, READ_SIZE, READ_TIMEOUT_MS);
    if LGot > 0 then
      LText := LText + TEncoding.UTF8.GetString(LBuf);
  until LGot <= 0;
  Check('the streamed body arrived whole', LText = 'chunk1;chunk2;chunk3;',
    Format('got "%s", last ReadChunk %d', [LText, LGot]));
  LResp := AClient.TakeResponse(LId1);
  Check('Trailers holds the trailer added after the data',
    (Length(LResp.Trailers) = 1) and ValueIs(LResp.Trailers, 'grpc-status', '0'),
    Dump(LResp.Trailers));
  Check('content-type stayed out of Trailers on the streaming path',
    not Has(LResp.Trailers, 'content-type'), Dump(LResp.Trailers));

  WriteLn;
  WriteLn('-- A5  two streams at once: each keeps its own trailers');
  LId1 := AClient.BeginRequest('GET', '/trailers', nil, LBody);
  LId2 := AClient.BeginRequest('GET', '/plain', nil, LBody);
  AClient.PumpAll(READ_TIMEOUT_MS);
  LResp := AClient.TakeResponse(LId2);
  Check('the stream without trailers has none',
    (BodyText(LResp) = 'plain') and (Length(LResp.Trailers) = 0), Dump(LResp.Trailers));
  LResp := AClient.TakeResponse(LId1);
  Check('the stream with trailers has exactly its two',
    (BodyText(LResp) = 'body') and (Length(LResp.Trailers) = 2), Dump(LResp.Trailers));
end;

// ── Part B: the independent peer ────────────────────────────────────────────

procedure PartB(APeerPort: Integer);
var
  LClient: TNghttp2Client;
  LResp:   TNghttp2Response;
begin
  WriteLn;
  WriteLn('-- B   independent peer (python h2) on port ', APeerPort);
  LClient := TNghttp2Client.Create;
  try
    LClient.Connect('127.0.0.1', APeerPort);
    Check('connected to the peer over h2c', LClient.Connected);

    WriteLn;
    WriteLn('-- B1  headers-only response (gRPC Trailers-Only)');
    LResp := LClient.SubmitRequest('GET', '/trailers-only', nil, nil);
    Check('status 200, no body', (LResp.Status = 200) and (Length(LResp.Body) = 0),
      Format('status %d, %d body bytes', [LResp.Status, Length(LResp.Body)]));
    Check('HeadersOnly is True', LResp.HeadersOnly);
    Check('Trailers is empty: the status came in the HEADERS block',
      Length(LResp.Trailers) = 0, Dump(LResp.Trailers));
    Check('grpc-status and grpc-message are in Headers',
      ValueIs(LResp.Headers, 'grpc-status', '12')
      and ValueIs(LResp.Headers, 'grpc-message', 'not%20here'), Dump(LResp.Headers));

    WriteLn;
    WriteLn('-- B2  HEADERS, empty DATA(END_STREAM): no body, but NOT headers-only');
    LResp := LClient.SubmitRequest('GET', '/empty-data', nil, nil);
    Check('status 200, no body', (LResp.Status = 200) and (Length(LResp.Body) = 0),
      Format('status %d, %d body bytes', [LResp.Status, Length(LResp.Body)]));
    Check('HeadersOnly is False: the stream ended on DATA, not on HEADERS',
      not LResp.HeadersOnly);
    Check('Trailers is empty', Length(LResp.Trailers) = 0, Dump(LResp.Trailers));

    WriteLn;
    WriteLn('-- B3  1xx informational block before the final headers');
    LResp := LClient.SubmitRequest('GET', '/informational', nil, nil);
    Check('final status 200 and the body', (LResp.Status = 200) and (BodyText(LResp) = 'ok'),
      Format('status %d, body "%s"', [LResp.Status, BodyText(LResp)]));
    Check('the final headers are NOT in Trailers',
      not Has(LResp.Trailers, 'x-final'), Dump(LResp.Trailers));
    Check('Trailers holds exactly the real trailer',
      (Length(LResp.Trailers) = 1) and ValueIs(LResp.Trailers, 'x-trailer', 't'),
      Dump(LResp.Trailers));
    Check('HeadersOnly is False', not LResp.HeadersOnly);

    WriteLn;
    WriteLn('-- B4  body + trailer section, framed by another implementation');
    LResp := LClient.SubmitRequest('GET', '/trailers', nil, nil);
    Check('status 200 and the body', (LResp.Status = 200) and (BodyText(LResp) = 'body'),
      Format('status %d, body "%s"', [LResp.Status, BodyText(LResp)]));
    Check('Trailers holds exactly grpc-status and grpc-message',
      (Length(LResp.Trailers) = 2) and ValueIs(LResp.Trailers, 'grpc-status', '0')
      and ValueIs(LResp.Trailers, 'grpc-message', 'done'), Dump(LResp.Trailers));
    Check('content-type is NOT in Trailers', not Has(LResp.Trailers, 'content-type'),
      Dump(LResp.Trailers));
    Check('HeadersOnly is False', not LResp.HeadersOnly);
  finally
    LClient.Free;
  end;
end;

function PeerPortFromArgs: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to ParamCount do
    if SameText(Copy(ParamStr(I), 1, 5), 'peer=') then
      Result := StrToIntDef(Copy(ParamStr(I), 6, MaxInt), 0);
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;
  GClient: TNghttp2Client;
  GPeer:   Integer;

begin
  WriteLn('Nghttp2ClientTrailers - GC1: Response.Trailers and HeadersOnly');

  if not NghttpLoad then
  begin
    WriteLn;
    WriteLn('  SKIPPED - libnghttp2 is not present on this machine.');
    WriteLn('  ', NghttpLoadError);
    WriteLn('  Nothing in this stage ran. A skip is not a pass.');
    ExitCode := EXIT_SKIP;
    Exit;
  end;

  GServer := TNghttp2Server.Create;
  try
    GServer.OnRequest := HandleRequest;
    GConfig      := TNghttp2Config.Default;
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

    GClient := TNghttp2Client.Create;
    try
      try
        GClient.Connect('127.0.0.1', PORT);
        PartA(GClient);
      except
        on E: Exception do
          Check('Part A ran to the end', False, E.ClassName + ': ' + E.Message);
      end;
    finally
      GClient.Free;
    end;
    GServer.Stop;
  finally
    GServer.Free;
  end;

  GPeer := PeerPortFromArgs;
  if GPeer > 0 then
  begin
    try
      PartB(GPeer);
    except
      on E: Exception do
        Check('Part B ran to the end', False, E.ClassName + ': ' + E.Message);
    end;
  end
  else
  begin
    WriteLn;
    Skip('Part B: headers-only, 1xx and foreign-framed trailers',
      'no peer=<port> given - run client-trailers-peer.py (needs python h2)');
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GSkip > 0 then
    WriteLn('        Part B did NOT run: headers-only and 1xx handling are UNTESTED.');
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
