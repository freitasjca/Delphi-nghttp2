program Nghttp2ServerSmoke;

// ============================================================================
//  Nghttp2ServerSmoke - A4. The first stage in this repository that STARTS a
//  server.
//
//  ── Why this exists ──
//
//  `grep -rl TNghttp2Server tests/ tools/` returned nothing until this file.
//  Every other stage is codec or codegen: ProtogenGeneratedCompileCheck only
//  REGISTERS services, and the FPC harness lists samples/grpc-server as
//  compile-only. So "ALL STAGES PASSED" has never meant the transport works.
//
//  That was not noticed by audit. A sample was run on Windows, died with
//  "libnghttp2 could not be loaded", and there was no nghttp2.dll anywhere on
//  the machine - while the suite had been reporting green all day. Both facts
//  were true at once, because nothing here had ever needed the library.
//
//  This is the smallest thing that would have caught it: bind, answer one
//  request over h2c, shut down.
//
//  ── Why it needs no external tool ──
//
//  The library ships both halves. TNghttp2Server serves, TNghttp2Client speaks
//  h2c with prior knowledge, and this program drives one against the other in
//  a single process. No curl, no grpcurl, no fixture server.
//
//  ── The skip must be LOUD ──
//
//  libnghttp2 is a runtime dependency and a machine may legitimately not have
//  it. Absent it, this exits EXIT_SKIP and prints a block that cannot be
//  mistaken for a pass. A silent skip is precisely what let the gap survive:
//  a stage that quietly does nothing reads exactly like a stage that passed.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2ServerSmoke.dpr
//  Build (FPC):      fpc -MDelphi -Fu../src Nghttp2ServerSmoke.dpr
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  { cthreads MUST come first on Unix: the server starts threads on its first
    connection, and this program makes one. }
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
  { High and specific, to avoid colliding with anything else a developer may
    have listening - samples use 19000 and 50051, the provider suite 9000. }
  PORT = 19311;

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

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

{ A skipped check did not run and did not pass. It is printed on its own line
  with a reason, counted separately, and repeated in the summary - the one
  thing it must never do is look like a PASS. }
procedure Skip(const AName, AReason: string);
begin
  WriteLn('  SKIP  ', AName, '  [', AReason, ']');
  Inc(GSkip);
end;

{ OnRequest is a PLAIN procedure type - not `of object`, not an anonymous
  method - because that is the only shape which compiles on FPC without
  FUNCTIONREFERENCES. }
procedure HandleRequest(const AStream: INghttp2Stream);
begin
  if AStream.Header[':path'] = '/smoke' then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes('ok'));
  end
  else if AStream.Header[':path'] = '/authority' then
  begin
    { [B4] Echo what the CLIENT put in :authority. This connection runs on a
      NON-default port, so the provable case here is that the port survives;
      the omit-the-default and bracket-IPv6 rules are gated as pure-function
      checks, since this server binds AF_INET on 19311 and can reach neither. }
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes(AStream.Header[':authority']));
  end
  else if AStream.Header[':path'] = '/scheme' then
  begin
    { [CL2] Echo back the :scheme pseudo-header the CLIENT advertised. This
      server is h2c, so the only value provable here is "http"; the https half
      is proven by the provider's TLS stages, which echo the same header. }
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes(AStream.Header[':scheme']));
  end
  else
  begin
    { A second path, so the test proves the request REACHED the handler and was
      routed - not merely that something answered. A server that returned 200
      to everything would pass a one-path check. }
    AStream.StatusCode := 404;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes('nope'));
  end;
end;

var
  GServer: TNghttp2Server;
  GConfig: TNghttp2Config;
  GClient: TNghttp2Client;
  GResp:   TNghttp2Response;
  GByName: TNghttp2Client;   // CL1 - a second client, connected by name
  GRaised: Boolean;
  GErrMsg: string;

begin
  WriteLn('Nghttp2ServerSmoke - does the transport actually run here?');
  WriteLn;

  { The skip decision, made by ASKING rather than by catching. NghttpLoad is
    idempotent and returns False instead of raising, so the absent-library case
    is an ordinary branch rather than an exception path. }
  if not NghttpLoad then
  begin
    WriteLn('  ================================================================');
    WriteLn('   SKIPPED - libnghttp2 is not present on this machine.');
    WriteLn('   ', NghttpLoadError);
    WriteLn;
    WriteLn('   This stage is the ONLY one here that starts a server. Every');
    WriteLn('   other stage passes without the library, so a green run that');
    WriteLn('   skipped this one has NOT exercised the transport at all.');
    WriteLn;
    WriteLn('   Windows: see doc/getting-nghttp2-windows.md - the bitness must');
    WriteLn('   match the compiler (dcc64 needs the Win64 DLL).');
    WriteLn('  ================================================================');
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
    Check('server bound and started on port ' + IntToStr(PORT), True);

    GClient := TNghttp2Client.Create;
    try
      GClient.Connect('127.0.0.1', PORT);
      Check('client connected over h2c (prior knowledge)', GClient.Connected);

      GResp := GClient.SubmitRequest('GET', '/smoke', nil, nil);
      Check('GET /smoke returned 200', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));
      Check('GET /smoke returned the handler''s body',
            TEncoding.UTF8.GetString(GResp.Body) = 'ok',
            TEncoding.UTF8.GetString(GResp.Body));

      { Routing, not just liveness. }
      GResp := GClient.SubmitRequest('GET', '/nothing-here', nil, nil);
      Check('an unrouted path returned 404', GResp.Status = 404,
            'status ' + IntToStr(GResp.Status));

      { [CL2] The client must advertise the scheme it is actually using. Over
        h2c that is "http" - the value this connection can prove. The TLS half
        ("https") is asserted by the provider's 114-check suite, which runs the
        same echo against a TLS server. }
      GResp := GClient.SubmitRequest('GET', '/scheme', nil, nil);
      Check('client advertised :scheme = http on h2c',
            TEncoding.UTF8.GetString(GResp.Body) = 'http',
            TEncoding.UTF8.GetString(GResp.Body));

      { [B4] End to end: a NON-default port must still appear. The rule is
        "omit the default", not "omit the port", and a builder that dropped it
        unconditionally would pass every check below while breaking every real
        request. }
      GResp := GClient.SubmitRequest('GET', '/authority', nil, nil);
      Check('client advertised :authority with its non-default port',
            TEncoding.UTF8.GetString(GResp.Body) = '127.0.0.1:' + IntToStr(PORT),
            TEncoding.UTF8.GetString(GResp.Body));

      { [B4] The two RFC rules, as pure-function checks. They cannot be reached
        end to end here: this server binds AF_INET on a non-default port, so
        neither a default port nor an IPv6 peer exists to talk to. }
      Check('https + 443 omits the default port (RFC 9110 §4.2)',
            Nghttp2BuildAuthority('example.com', 443, True) = 'example.com',
            Nghttp2BuildAuthority('example.com', 443, True));
      Check('http + 80 omits the default port',
            Nghttp2BuildAuthority('example.com', 80, False) = 'example.com',
            Nghttp2BuildAuthority('example.com', 80, False));
      Check('https + 8443 KEEPS a non-default port',
            Nghttp2BuildAuthority('example.com', 8443, True) = 'example.com:8443',
            Nghttp2BuildAuthority('example.com', 8443, True));

      { 443 is default for https ONLY. Over cleartext it is an ordinary port
        and must survive - the discriminating case for a builder that compares
        against a constant instead of the scheme's default. }
      Check('http + 443 keeps the port (443 is default for https only)',
            Nghttp2BuildAuthority('example.com', 443, False) = 'example.com:443',
            Nghttp2BuildAuthority('example.com', 443, False));

      Check('an IPv6 literal is bracketed (RFC 3986 §3.2.2)',
            Nghttp2BuildAuthority('::1', 9010, False) = '[::1]:9010',
            Nghttp2BuildAuthority('::1', 9010, False));
      Check('a bracketed IPv6 literal on its default port drops the port',
            Nghttp2BuildAuthority('::1', 80, False) = '[::1]',
            Nghttp2BuildAuthority('::1', 80, False));
      Check('an ALREADY-bracketed host is not bracketed twice',
            Nghttp2BuildAuthority('[::1]', 9010, False) = '[::1]:9010',
            Nghttp2BuildAuthority('[::1]', 9010, False));
      Check('an IPv4 literal is never bracketed',
            Nghttp2BuildAuthority('127.0.0.1', 443, True) = '127.0.0.1',
            Nghttp2BuildAuthority('127.0.0.1', 443, True));
    finally
      GClient.Free;
    end;

    { ── CL1 - peer addressing ──────────────────────────────────────────── }

    { A host NAME. This is the check the whole milestone exists for, so on FPC
      it must SKIP loudly rather than quietly not happen: the resolver there is
      still unimplemented and ConnectToHost says so. }
{$IF DEFINED(FPC) AND NOT DEFINED(UNIX)}
    { FPC/Windows only: netdb is Unix-only and winsock2 has no getaddrinfo. }
    Skip('connect by name "localhost" answers 200',
         'no resolver on FPC/Windows - see ConnectToHost (CL1)');
    Skip('Nghttp2Get by host name returns 200',
         'no resolver on FPC/Windows - see ConnectToHost (CL1)');
{$ELSE}
    GByName := TNghttp2Client.Create;
    try
      GByName.Connect('localhost', PORT);
      GResp := GByName.SubmitRequest('GET', '/smoke', nil, nil);
      Check('connect by name "localhost" answers 200', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));
      Check('connect by name returns the handler''s body',
            TEncoding.UTF8.GetString(GResp.Body) = 'ok',
            TEncoding.UTF8.GetString(GResp.Body));
    finally
      GByName.Free;
    end;

    { The URL path, which parses host/port itself and used to document
      "IPv4 literal only". }
    GResp := Nghttp2Get('http://localhost:' + IntToStr(PORT) + '/smoke');
    Check('Nghttp2Get by host name returns 200', GResp.Status = 200,
          'status ' + IntToStr(GResp.Status));
{$IFEND}

    { A name that cannot resolve must RAISE, and the message must name the
      host - a bare errno sends the reader hunting through socket code. Runs on
      both compilers: FPC raises its "must be an IPv4 literal" error here, which
      also names the host. ".invalid" is reserved by RFC 2606, so this check
      cannot start passing because somebody registered a domain. }
    GRaised := False;
    GErrMsg := '';
    GByName := TNghttp2Client.Create;
    try
      try
        GByName.Connect('no-such-host.invalid', PORT);
      except
        on E: Exception do
        begin
          GRaised := True;
          GErrMsg := E.Message;
        end;
      end;
    finally
      GByName.Free;
    end;
    Check('an unresolvable name raises, naming the host',
          GRaised and (Pos('no-such-host.invalid', GErrMsg) > 0), GErrMsg);

    { ── CL4 - connection reuse, PING keepalive, explicit Reconnect ───────── }

    GClient := TNghttp2Client.Create;
    try
      GClient.Connect('127.0.0.1', PORT);

      { [CL4] A second Connect call to the same host:port must be a no-op — the
        live session is reused without tearing it down. }
      GClient.Connect('127.0.0.1', PORT);
      Check('[CL4] double Connect to same endpoint keeps the connection alive',
            GClient.Connected);
      GResp := GClient.SubmitRequest('GET', '/smoke', nil, nil);
      Check('[CL4] request on reused connection returns 200', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));
      Check('[CL4] request on reused connection returns correct body',
            TEncoding.UTF8.GetString(GResp.Body) = 'ok',
            TEncoding.UTF8.GetString(GResp.Body));

      { [CL4] PING round-trip: send a PING frame, wait for the ACK that fires
        OnFrameRecvCb and clears FPingPending. True = ACK received in time. }
      Check('[CL4] Ping returns True within 5 s (connection is alive)',
            GClient.Ping(5000));

      { [CL4] GoAwayReceived is False on a healthy session that received no GOAWAY. }
      Check('[CL4] GoAwayReceived is False on a healthy connection',
            not GClient.GoAwayReceived);

      { [CL4] Explicit Reconnect: closes the old session and opens a new one to
        the same endpoint. The next request must succeed on the fresh session. }
      GClient.Reconnect;
      Check('[CL4] Reconnect leaves the client connected', GClient.Connected);
      Check('[CL4] GoAwayReceived is False after Reconnect', not GClient.GoAwayReceived);
      GResp := GClient.SubmitRequest('GET', '/smoke', nil, nil);
      Check('[CL4] first request after Reconnect returns 200', GResp.Status = 200,
            'status ' + IntToStr(GResp.Status));
      Check('[CL4] first request after Reconnect returns correct body',
            TEncoding.UTF8.GetString(GResp.Body) = 'ok',
            TEncoding.UTF8.GetString(GResp.Body));
    finally
      GClient.Free;
    end;

    { IPv6 end-to-end: the server now binds AF_INET6 alongside AF_INET, so a
      connection to ::1 exercises both the server's IPv6 accept path and the
      client's IPv6 connect path. Skip gracefully when ::1 is not reachable
      (IPv6 disabled on the host — the IPv4 checks above already passed). }
    GClient := TNghttp2Client.Create;
    try
      try
        GClient.Connect('::1', PORT);
        GResp := GClient.SubmitRequest('GET', '/smoke', nil, nil);
        Check('connect to "::1" answers 200', GResp.Status = 200,
              IntToStr(GResp.Status));
        Check('connect to "::1" returns correct body',
              TEncoding.UTF8.GetString(GResp.Body) = 'ok',
              TEncoding.UTF8.GetString(GResp.Body));
      except
        on E: Exception do
          Skip('connect to "::1" answers 200',
               '::1 not reachable: ' + E.ClassName + ': ' + E.Message);
      end;
    finally
      GClient.Free;
    end;

    GServer.Stop;
    Check('server stopped cleanly', True);
  finally
    GServer.Free;
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GSkip > 0 then
  begin
    WriteLn('        ', GSkip, ' check(s) did NOT run - read the [reason] on each');
    WriteLn('        SKIP line above before reading this run as complete.');
  end;
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
