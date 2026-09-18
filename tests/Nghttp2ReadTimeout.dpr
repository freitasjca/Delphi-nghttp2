program Nghttp2ReadTimeout;

// ============================================================================
//  Nghttp2ReadTimeout - CL2c. Does the client's timeout actually expire?
//
//  ── Why this exists ──
//
//  PumpUntilDone has always taken ATimeoutMS, always checked it, and always
//  raised a good message when it expired. It just never got the chance: DoRead
//  went straight to a blocking recv with no SO_RCVTIMEO set anywhere, so a peer
//  that accepted the connection and then said nothing parked the client inside
//  recv forever and the elapsed check never ran a second time.
//
//  The timeout was real in the source and inert at runtime, which is the worst
//  combination - every caller reasonably believed a 30 s ceiling existed.
//  Nothing tested it, because testing it requires a peer that is deliberately
//  rude rather than merely absent.
//
//  ── The silent peer needs no thread ──
//
//  The kernel completes the TCP handshake from the listen backlog whether or
//  not the application ever calls accept(). So this binds a listener and simply
//  never accepts: connect() succeeds, the client sends its preface and SETTINGS
//  into a socket nobody is reading, and waits for a reply that will never come.
//
//  That is the whole peer. No TThread, no cthreads ordering to get right, no
//  second process - and the same three lines behave identically on every
//  platform this library targets.
//
//  ── What it asserts ──
//
//  1. The connection really was established (otherwise the rest proves nothing
//     - a client that failed to connect also "does not hang").
//  2. SubmitRequest RAISES rather than blocking forever.
//  3. The message names a timeout, and names the budget it was given, so we
//     know THIS deadline fired and not some unrelated failure.
//  4. It waited: an instant failure would satisfy "raised" while meaning the
//     connection broke for another reason entirely.
//  5. It came back near the budget rather than far past it.
//
//  ── Reading a failure ──
//
//  If this program HANGS, that is the regression: the read timeout is not
//  working and the client is back in a blocking recv. The harness stage wraps
//  it in `timeout` for exactly that reason - a hang must be reported as a
//  failed stage, not as a suite that stopped.
//
//  Usage:  Nghttp2ReadTimeout
//  Exit:   0 = pass   1 = failed   3 = skipped (libnghttp2 absent)
//
//  Build (FPC):     fpc -MDelphi -Fu../src Nghttp2ReadTimeout.dpr
//  Build (Windows): dcc64 -CC -B -U..\src Nghttp2ReadTimeout.dpr
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Native,   { NghttpLoad / NghttpLoadError }
  Nghttp2.Socket,   { the silent peer: InitSockets, CreateListenerSocket, … }
  Nghttp2.Client;   { TNghttp2Client, and TNghttp2Headers — which lives HERE,
                      not in Nghttp2.Types, whose only exports are the two
                      server-side stream interfaces this program never touches }

const
  { Clear of the other test programs: the smoke owns 19311, the ALPN gate
    19312 and 19313. }
  PORT = 19314;

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  { Short on purpose. The default is 30 s, and a gate nobody wants to wait for
    is a gate that gets commented out. }
  BUDGET_MS = 1500;

  { Lower bound proves it WAITED rather than failing instantly for an unrelated
    reason. Deliberately well under BUDGET_MS: Now has ~15 ms granularity on
    Windows and a loaded machine can shave a little off either side. }
  MIN_ELAPSED_MS = 700;

  { Upper bound proves it came back. Generous against a 1.5 s budget because
    the real protection against a hang is the harness `timeout`, not this - a
    hung process never reaches this check at all. }
  MAX_ELAPSED_MS = 10000;

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

{ Local rather than DateUtils, matching TNghttp2Client.MilliSecondsSince.
  TDateTime is days since 1899-12-30. }
function MsSince(const AStart: TDateTime): Int64;
begin
  Result := Round((Now - AStart) * 86400.0 * 1000.0);
end;

var
  GListener:  TSocketHandle;
  GClient:    TNghttp2Client;
  GHeaders:   TNghttp2Headers;   { left nil - no extra request headers }
  GBody:      TBytes;            { left nil - GET has no body }
  GStart:     TDateTime;
  GElapsed:   Int64;
  GRaised:    Boolean;
  GMsg:       string;
  GConnected: Boolean;

begin
  WriteLn('Nghttp2ReadTimeout - does the client''s read timeout actually fire?');
  WriteLn('  budget ', BUDGET_MS, ' ms against a peer that accepts and then says nothing');
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

  GRaised    := False;
  GMsg       := '';
  GConnected := False;
  GElapsed   := -1;

  InitSockets;   { no-op off Windows; idempotent }

  { Bind and listen, and then never accept. The backlog completes the handshake
    on our behalf, which is precisely the peer this test needs. }
  GListener := CreateListenerSocket(PORT, 8);
  if GListener = INVALID_SOCKET_HANDLE then
  begin
    WriteLn('  FAIL  could not bind the silent peer on port ', PORT);
    ExitCode := EXIT_FAIL;
    Exit;
  end;

  try
    GClient := TNghttp2Client.Create;
    try
      try
        GClient.Connect('127.0.0.1', PORT);
        GConnected := GClient.Connected;
      except
        on E: Exception do
        begin
          WriteLn('  FAIL  could not connect to the silent peer: ', E.Message);
          ExitCode := EXIT_FAIL;
          Exit;
        end;
      end;

      GStart := Now;
      try
        { Never answered. Pre-CL2c this call does not return. }
        GClient.SubmitRequest('GET', '/never-answered', GHeaders, GBody, BUDGET_MS);
      except
        on E: Exception do
        begin
          GRaised := True;
          GMsg    := E.Message;
        end;
      end;
      GElapsed := MsSince(GStart);
    finally
      GClient.Free;
    end;
  finally
    CloseSocketHandle(GListener);
  end;

  WriteLn('  client said: ', GMsg);
  WriteLn('  elapsed: ', GElapsed, ' ms');
  WriteLn;

  Check('the connection was established (the peer accepted, then went quiet)',
        GConnected);
  Check('SubmitRequest raised instead of blocking forever', GRaised);
  Check('the message names a timeout',
        GRaised and (Pos('timed out', GMsg) > 0), GMsg);

  { Naming the budget is what distinguishes THIS deadline from any other
    failure that might also mention a timeout. }
  Check('the message names the budget it was given',
        GRaised and (Pos(IntToStr(BUDGET_MS), GMsg) > 0), GMsg);

  Check('it waited rather than failing instantly',
        GElapsed >= MIN_ELAPSED_MS, IntToStr(GElapsed) + ' ms');
  Check('it returned near the budget',
        (GElapsed >= 0) and (GElapsed <= MAX_ELAPSED_MS),
        IntToStr(GElapsed) + ' ms');

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed');
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
