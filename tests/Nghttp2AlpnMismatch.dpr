program Nghttp2AlpnMismatch;

// ============================================================================
//  Nghttp2AlpnMismatch - CL2b. Does the client REFUSE a TLS peer that cannot
//  speak HTTP/2, and say so usefully?
//
//  ── Why this exists ──
//
//  Nghttp2.Client raises when ALPN does not yield 'h2'. That raise had never
//  executed in any test: every TLS stage points at our own server, which always
//  selects h2. An error path nothing exercises is an error path nobody has
//  read - and this one was wrong in a quiet way. It rendered the common case as
//
//      ALPN negotiation failed - server selected ""
//
//  which blames the server for what is usually "that endpoint is HTTP/1.1".
//
//  ── The two peers are NOT the same failure ──
//
//  This was measured, after an earlier draft of this file asserted the opposite
//  and would have failed on contact:
//
//    noalpn     A peer with ALPN DISABLED (`openssl s_server`, no -alpn flag).
//               It echoes no ALPN extension, the handshake COMPLETES, and
//               NegotiatedProtocol is ''. This is the ONLY peer that reaches
//               the client's empty-ALPN branch. s_client exit 0.
//
//    nooverlap  A peer offering only http/1.1 (`-alpn http/1.1`). There is no
//               overlap with our 'h2', and OpenSSL does NOT complete the
//               handshake selecting nothing - it sends a FATAL
//               no_application_protocol alert (alert 120, RFC 7301 §3.2).
//               SSL_connect fails, so DoHandshake raises BEFORE any ALPN check
//               runs. s_client exit 1.
//
//  The trap that produced the wrong draft: `openssl s_client` prints
//  "No ALPN negotiated" on the way out of a FAILED handshake too. That line is
//  not evidence that a session was established.
//
//  ── What each mode asserts ──
//
//  noalpn    the full CL2b diagnostic: raises, names ALPN, names host and port,
//            says no protocol was negotiated, and does NOT emit the pre-CL2b
//            'selected ""'.
//  nooverlap [B5] the same diagnostic quality: raises, names ALPN, names host
//            and port, names alert 120, and says the peer shares no ALPN
//            protocol with us.
//
//            This arm used to assert only "the client REFUSES", because the
//            message was whatever raw prose OpenSSL had for reason 1120 - and
//            that prose DIFFERS BY VERSION: 3.0.13 says "reason(1120)", 3.6.0
//            says "tlsv1 alert no application protocol". Any wording assertion
//            would have passed on one machine and failed on the next. B5 keys
//            off the reason CODE instead, so the explanation is now stable and
//            can be demanded here. The last check in this arm pins exactly
//            that property rather than either spelling.
//
//  In both modes the client must NOT be left looking connected.
//
//  Usage:  Nghttp2AlpnMismatch <host> <port> <noalpn|nooverlap>
//  Exit:   0 = pass   1 = failed   3 = skipped (libnghttp2 or OpenSSL absent)
//
//  Build (FPC):     fpc -MDelphi -Fu../src Nghttp2AlpnMismatch.dpr
//  Build (Windows): dcc64 -CC -B -U..\src Nghttp2AlpnMismatch.dpr
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
  Nghttp2.Native,
  Nghttp2.OpenSSL,
  Nghttp2.Tls,
  Nghttp2.Client;

const
  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  MODE_NOALPN    = 'noalpn';
  MODE_NOOVERLAP = 'nooverlap';

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

var
  GHost:    string;
  GPort:    Word;
  GMode:    string;
  GClient:  TNghttp2Client;
  GTls:     TTlsClientContext;
  GRaised:  Boolean;
  GMsg:     string;
  GStillConnected: Boolean;

begin
  WriteLn('Nghttp2AlpnMismatch - does the client refuse a non-h2 TLS peer?');

  if ParamCount < 3 then
  begin
    WriteLn('  usage: Nghttp2AlpnMismatch <host> <port> <',
            MODE_NOALPN, '|', MODE_NOOVERLAP, '>');
    ExitCode := EXIT_FAIL;
    Exit;
  end;
  GHost := ParamStr(1);
  GPort := Word(StrToIntDef(ParamStr(2), 0));
  GMode := LowerCase(ParamStr(3));
  if GPort = 0 then
  begin
    WriteLn('  FAIL  port "', ParamStr(2), '" is not a number');
    ExitCode := EXIT_FAIL;
    Exit;
  end;
  if (GMode <> MODE_NOALPN) and (GMode <> MODE_NOOVERLAP) then
  begin
    WriteLn('  FAIL  unknown mode "', ParamStr(3), '"');
    ExitCode := EXIT_FAIL;
    Exit;
  end;
  WriteLn('  peer ', GHost, ':', GPort, '  mode=', GMode);
  WriteLn;

  { Both are runtime dependencies, and a machine may legitimately lack either.
    Skip LOUDLY - a quiet skip here is indistinguishable from a pass, which is
    the failure mode this whole program exists to close. }
  if not NghttpLoad then
  begin
    WriteLn('  ================================================================');
    WriteLn('   SKIPPED - libnghttp2 is not present on this machine.');
    WriteLn('   ', NghttpLoadError);
    WriteLn('  ================================================================');
    ExitCode := EXIT_SKIP;
    Exit;
  end;
  if not NghttpsslLoad then
  begin
    WriteLn('  ================================================================');
    WriteLn('   SKIPPED - OpenSSL is not present on this machine.');
    WriteLn('   ', NghttpsslLoadError);
    WriteLn('  ================================================================');
    ExitCode := EXIT_SKIP;
    Exit;
  end;

  GRaised         := False;
  GMsg            := '';
  GStillConnected := False;

  GTls := TTlsClientContext.Create;
  try
    { Self-signed fixture on the far side, and the point here is ALPN, not
      chain validation. }
    GTls.SetInsecure;

    { Deliberately NOT GTls.EnableHttp2Alpn: Connect must offer h2 by itself
      (CL2b/B1). If it did not, the handshake would fail for the WRONG reason
      and this program would pass while proving nothing. }

    GClient := TNghttp2Client.Create;
    try
      GClient.TlsContext := GTls;
      try
        GClient.Connect(GHost, GPort);
      except
        on E: Exception do
        begin
          GRaised := True;
          GMsg    := E.Message;
        end;
      end;
      GStillConnected := GClient.Connected;
    finally
      GClient.Free;
    end;
  finally
    GTls.Free;
  end;

  WriteLn('  client said: ', GMsg);
  WriteLn;

  { Common to both peers: refuse, and do not look usable afterwards. }
  Check('Connect raised instead of returning a half-built connection', GRaised);
  Check('Connected is False after a refused handshake', not GStillConnected);

  if GMode = MODE_NOALPN then
  begin
    Check('the message names ALPN',
          GRaised and (Pos('ALPN', GMsg) > 0), GMsg);
    Check('the message names the host that failed',
          GRaised and (Pos(GHost, GMsg) > 0), GMsg);
    Check('the message names the port that failed',
          GRaised and (Pos(IntToStr(GPort), GMsg) > 0), GMsg);

    { The two halves of the CL2b diagnostic fix, asserted together.

      POSITIVE: the message has to say that NOTHING was negotiated. That is what
      this peer actually did, and it is the sentence a reader needs.

      NEGATIVE: it must NOT render as 'selected ""'. That is the pre-CL2b
      output, and it is the whole defect - an empty pair of quotes reads as a
      server returning garbage, when the true meaning is "ALPN is off here".
      Asserting the old wording is GONE is what keeps the fix from silently
      regressing; a positive check alone would still pass if both sentences
      were emitted. }
    Check('the message says no protocol was negotiated',
          GRaised and (Pos('no protocol', GMsg) > 0), GMsg);
    Check('the message does NOT render the pre-CL2b ''selected ""''',
          GRaised and (Pos('selected ""', GMsg) = 0), GMsg);
  end
  else
  begin
    { [B5] This peer kills the handshake with alert 120 before any ALPN check
      can run. Until B5 the only honest assertion was "SSL_connect appears in
      the text", because the message was a raw OpenSSL reason string that named
      neither ALPN nor h2 - and worse, named it DIFFERENTLY per OpenSSL version.
      Now the reason code is recognised and the message is uniform, so the same
      diagnostic quality the noalpn arm gets can be demanded here. }
    Check('the message names ALPN',
          GRaised and (Pos('ALPN', GMsg) > 0), GMsg);
    Check('the message names the host that failed',
          GRaised and (Pos(GHost, GMsg) > 0), GMsg);
    Check('the message names the port that failed',
          GRaised and (Pos(IntToStr(GPort), GMsg) > 0), GMsg);
    Check('the message names the alert that caused it',
          GRaised and (Pos('120', GMsg) > 0), GMsg);
    Check('the message says the peer shares no protocol with us',
          GRaised and (Pos('no ALPN protocol', GMsg) > 0), GMsg);

    { THE VERSION-INDEPENDENCE ASSERTION, and the reason B5 exists.

      OpenSSL 3.0.13 renders this reason as "reason(1120)" and 3.6.0 as
      "tlsv1 alert no application protocol" - same error code, different prose.
      A message built from that text says something different on every machine.
      Matching on the reason CODE is what makes the sentence above stable, and
      this check pins the property rather than either spelling: whichever raw
      text OpenSSL appends as evidence, the ALPN explanation must be present.

      Deliberately NOT asserting the raw text is absent - it is kept on purpose
      as evidence, and asserting its absence would forbid that. }
    Check('the diagnosis does not depend on the OpenSSL version''s wording',
          GRaised and (Pos('no ALPN protocol', GMsg) > 0)
                  and ((Pos('reason(1120)', GMsg) > 0)
                    or (Pos('no application protocol', GMsg) > 0)
                    or (Pos('alert', GMsg) > 0)), GMsg);
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed');
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
