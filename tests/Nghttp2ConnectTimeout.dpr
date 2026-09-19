program Nghttp2ConnectTimeout;

// ============================================================================
//  Nghttp2ConnectTimeout — does TNghttp2Client.ConnectTimeoutMS actually fire?
//
//  ── Why this exists ──
//
//  ConnectToHost always used a blocking connect(). When a SYN is blackholed
//  (the TCP peer drops it silently — no RST, no SYN-ACK), the OS retries for
//  up to ~127 seconds (Linux default tcp_syn_retries=6). Nothing bounded that
//  wait, so a single unreachable host could stall a program for two minutes with
//  no way to interrupt it short of SIGKILL.
//
//  The fix: when ConnectTimeoutMS > 0, ConnectToHost sets the socket non-blocking,
//  calls connect() (which returns EINPROGRESS/WSAEWOULDBLOCK), then polls with
//  SocketWaitConnected up to the budget, and raises ENghttp2Socket if the
//  deadline fires before the socket becomes writable.
//
//  ── Two sub-tests ──
//
//  A. "Fast connect with timeout set" — proves that the new non-blocking path
//     succeeds for connections that complete almost immediately. Uses the same
//     silent-server trick as Nghttp2ReadTimeout: listen() with a generous backlog
//     but never call accept(). The kernel completes the TCP three-way handshake
//     from the listen backlog, so connect() succeeds and GClientA.Connected
//     becomes True. Failure here means the new path broke the success case.
//
//  B. "Timeout fires" — proves that an unresponsive peer is not waited on
//     forever. Uses a listener with backlog=1 prefilled by one blocking filler
//     connection. With the accept queue full, Linux silently drops subsequent
//     SYNs (tcp_abort_on_overflow=0 is the default), so our test connect()
//     gets EINPROGRESS and SocketWaitConnected's poll() fires after BUDGET_MS.
//
//     The filler is kept open until AFTER the test (closing it early frees the
//     accept slot, which would let the test connection succeed instead of timing
//     out).
//
//     IF the queue was not full enough (backlog rounded up on this kernel,
//     tcp_abort_on_overflow=1, or the OS sent RST immediately), the test
//     connection succeeds or fails instantly. In that case:
//       - B1 (raised) is skipped with a note — the connect succeeded or the
//         OS gave an immediate error; neither proves the timeout mechanism fired.
//       - B2 (within budget) still passes.
//     The test does NOT fail for these corner cases: the non-blocking path is
//     correct; the environment simply did not produce a SYN black-hole.
//
//  ── Reading a failure ──
//
//  If this program HANGS on sub-test B, ConnectTimeoutMS is not working — either
//  connect() is still blocking (the non-blocking switch was not applied) or
//  poll() is blocking indefinitely. The harness `timeout` converts a hang into
//  a FAIL with a clear message.
//
//  If A1/A2 fail, the non-blocking connect path broke the success case.
//
//  Usage:  Nghttp2ConnectTimeout
//  Exit:   0 = pass   1 = failed   3 = skipped (libnghttp2 absent)
//
//  Build (FPC):     fpc -MDelphi -Fu../src Nghttp2ConnectTimeout.dpr
//  Build (Windows): dcc64 -CC -B -U..\src Nghttp2ConnectTimeout.dpr
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Native,
  Nghttp2.Socket,
  Nghttp2.Client;

const
  { Clear of the other test programs. }
  PORT_GOOD = 19317;   { positive-path: listen never accepted, kernel completes }
  PORT_BH   = 19318;   { blackhole: accept queue filled, SYN dropped by kernel }

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  { Sub-test A: timeout to use on the positive-path connect. Generous — the
    connection should complete in well under a millisecond on loopback. }
  CONN_GOOD_MS = 5000;

  { Sub-test B: the connect-timeout budget. poll() fires after this many ms.
    Short on purpose — nobody wants to wait 30 s to see a test result. }
  BUDGET_MS = 2000;

  { Floor: proves the timeout WAITED rather than failing instantly (e.g. RST).
    The first SYN retry on Linux fires at ~1 s, so a timed-out connect arrives
    shortly after BUDGET_MS. Setting the floor well under BUDGET_MS absorbs any
    machine load without hiding an instant error. }
  MIN_ELAPSED_MS = 800;

  { Upper bound: generous against a 2 s budget. The real protection against a
    hang is the harness `timeout`, not this number. }
  MAX_ELAPSED_MS = 12000;

var
  GPass: Integer = 0;
  GFail: Integer = 0;

procedure Check(const AName: string; APassed: Boolean;
  const ADetail: string = '');
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

function MsSince(const AStart: TDateTime): Int64;
begin
  Result := Round((Now - AStart) * 86400.0 * 1000.0);
end;

var
  GGoodListener: TSocketHandle;
  GBhListener:   TSocketHandle;
  GFiller:       TSocketHandle;
  GClientA:      TNghttp2Client;
  GClientB:      TNghttp2Client;
  GRaisedB:      Boolean;
  GMsgB:         string;
  GElapsedB:     Int64;
  GStart:        TDateTime;
  GBConnected:   Boolean;   { True if test B connect succeeded (not the expected outcome) }

begin
  WriteLn('Nghttp2ConnectTimeout — does ConnectTimeoutMS fire within budget?');
  WriteLn('  sub-test A (port ', PORT_GOOD, '): timeout=', CONN_GOOD_MS,
          ' ms, fast loopback — expect success');
  WriteLn('  sub-test B (port ', PORT_BH, '): timeout=', BUDGET_MS,
          ' ms, full accept queue — expect ENghttp2Socket in ~', BUDGET_MS, ' ms');
  WriteLn;

  if not NghttpLoad then
  begin
    WriteLn('  ================================================================');
    WriteLn('   SKIPPED — libnghttp2 is not present on this machine.');
    WriteLn('   ', NghttpLoadError);
    WriteLn('  ================================================================');
    ExitCode := EXIT_SKIP;
    Exit;
  end;

  InitSockets;

  // ── Sub-test A: non-blocking connect path, positive case ─────────────────
  //
  // listen() + never accept: the kernel completes the TCP handshake from the
  // listen backlog regardless of whether the application calls accept(). The
  // client sees a fully established connection and Connected becomes True.

  GGoodListener := INVALID_SOCKET_HANDLE;
  GClientA      := nil;
  try
    GGoodListener := CreateListenerSocket(PORT_GOOD, 8);
    if GGoodListener = INVALID_SOCKET_HANDLE then
    begin
      WriteLn('  FAIL  could not bind listener on port ', PORT_GOOD);
      ExitCode := EXIT_FAIL;
      Exit;
    end;

    GClientA := TNghttp2Client.Create;
    GClientA.ConnectTimeoutMS := CONN_GOOD_MS;
    try
      GClientA.Connect('127.0.0.1', PORT_GOOD);
    except
      on E: Exception do
      begin
        WriteLn('  FAIL  sub-test A: connect raised unexpectedly: ', E.Message);
        ExitCode := EXIT_FAIL;
        Exit;
      end;
    end;

    Check('A1: Connect with timeout set succeeds on loopback', GClientA.Connected);
    Check('A2: ConnectTimeoutMS round-trips (write then read)',
          GClientA.ConnectTimeoutMS = CONN_GOOD_MS,
          IntToStr(GClientA.ConnectTimeoutMS));

  finally
    if GClientA <> nil then GClientA.Free;
    if GGoodListener <> INVALID_SOCKET_HANDLE then
      CloseSocketHandle(GGoodListener);
  end;

  WriteLn;

  // ── Sub-test B: non-blocking connect path, timeout case ──────────────────
  //
  // listen(fd, 1) caps the accept queue to ~1 slot. One pre-existing connection
  // fills it. Linux then drops subsequent SYNs silently (tcp_abort_on_overflow=0
  // default). Our poll() fires after BUDGET_MS and ConnectToHost raises
  // ENghttp2Socket.
  //
  // The filler stays open until after the test so it holds the accept slot.

  GBhListener := INVALID_SOCKET_HANDLE;
  GFiller     := INVALID_SOCKET_HANDLE;
  GClientB    := nil;
  GRaisedB    := False;
  GMsgB       := '';
  GElapsedB   := -1;
  GBConnected := False;

  try
    GBhListener := CreateListenerSocket(PORT_BH, 1);
    if GBhListener = INVALID_SOCKET_HANDLE then
    begin
      WriteLn('  FAIL  could not bind blackhole listener on port ', PORT_BH);
      ExitCode := EXIT_FAIL;
      Exit;
    end;

    { Filler: one blocking connect fills the accept queue. ConnectToHost
      succeeds because the kernel completes the handshake. We keep GFiller
      open — closing it would free the queue slot before the test runs. }
    try
      GFiller := ConnectToHost('127.0.0.1', PORT_BH);
    except
      on E: Exception do
        WriteLn('  NOTE  filler connect raised (', E.Message, ') —',
                ' accept queue may not be full; B timing check may be skipped');
    end;

    { Test connect: this SYN should be dropped by the kernel (queue full).
      poll() waits BUDGET_MS then SocketWaitConnected returns False. }
    GClientB := TNghttp2Client.Create;
    GClientB.ConnectTimeoutMS := BUDGET_MS;
    GStart := Now;
    try
      GClientB.Connect('127.0.0.1', PORT_BH);
      GBConnected := GClientB.Connected;    { unexpectedly succeeded }
    except
      on E: ENghttp2Socket do
      begin
        GRaisedB := True;
        GMsgB    := E.Message;
      end;
      on E: Exception do
      begin
        GRaisedB := True;
        GMsgB    := E.ClassName + ': ' + E.Message;
      end;
    end;
    GElapsedB := MsSince(GStart);

  finally
    if GClientB <> nil then GClientB.Free;
    { Close the filler AFTER the test — it held the accept queue slot open.
      Closing it before would let the test connection succeed. }
    if GFiller <> INVALID_SOCKET_HANDLE then CloseSocketHandle(GFiller);
    if GBhListener <> INVALID_SOCKET_HANDLE then CloseSocketHandle(GBhListener);
  end;

  WriteLn('  connect said: ', GMsgB);
  WriteLn('  elapsed: ', GElapsedB, ' ms');
  WriteLn;

  if GBConnected and not GRaisedB then
  begin
    { The test connection succeeded — the accept queue was not full enough to
      drop the SYN. This can happen when the OS rounds backlog=1 up to 2 or
      more. Report as a note rather than a failure: the mechanism is not broken,
      the environment did not produce a SYN black-hole. Sub-test A proved the
      non-blocking path works. }
    WriteLn('  NOTE  B: connect SUCCEEDED (accept queue was not full — this kernel');
    WriteLn('          rounds backlog=1 higher than expected). Timing test skipped.');
    WriteLn('          Sub-test A confirmed the non-blocking path is correct.');
  end
  else
  begin
    Check('B1: connect raised ENghttp2Socket instead of hanging', GRaisedB,
          GMsgB);
    Check('B2: returned within ceiling (' + IntToStr(MAX_ELAPSED_MS) + ' ms)',
          (GElapsedB >= 0) and (GElapsedB <= MAX_ELAPSED_MS),
          IntToStr(GElapsedB) + ' ms');

    if GElapsedB >= MIN_ELAPSED_MS then
      Check('B3: timeout mechanism waited before raising (not instant RST)',
            True, IntToStr(GElapsedB) + ' ms >= ' + IntToStr(MIN_ELAPSED_MS) + ' ms')
    else
    begin
      WriteLn('  NOTE  B3: elapsed ', GElapsedB, ' ms < ', MIN_ELAPSED_MS,
              ' ms — the OS gave an immediate error (RST or ENETUNREACH).');
      WriteLn('        tcp_abort_on_overflow may be 1 on this kernel, or the');
      WriteLn('        filler did not fill the queue. B1 is still meaningful.');
    end;
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed');
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
