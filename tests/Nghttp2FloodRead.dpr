program Nghttp2FloodRead;

// ============================================================================
//  Nghttp2FloodRead — CL3b gate.
//
//  Proves that downloading a 64 MB streaming response via ReadChunk keeps the
//  client's peak RSS bounded: the caller's buffer at any point holds one chunk
//  (64 KB), not the whole response (64 MB).
//
//  Why async dispatch is required:
//    The provider's /stream/flood route implements BACKPRESSURE-1
//    (AwaitDrainRoom). Under inline dispatch AwaitDrainRoom is a no-op, so the
//    server queues the whole 64 MB before the pump runs — "inline streaming is
//    unbounded by construction" (Nghttp2.Session). Asserting a client memory
//    ceiling against an inline server would measure a mode that never promised
//    one. Run this gate only against HorseNghttp2TestServer (default worker
//    pool = async dispatch).
//
//  Stage 16 of build-fpc.sh proved the SERVER's RSS bounded (server-side
//  backpressure, curl as slow consumer). This stage adds the CLIENT's half:
//  TNghttp2Client.ReadChunk streams 64 MB through without ever holding more
//  than one recv buffer's worth in process memory.
//
//  Checks:
//    1. connected over h2c
//    2. stream opened for incremental delivery
//    3. ReadChunk returns end-of-stream (0), not a timeout
//    4. response status 200
//    5. all 64 MB received (completeness — nothing dropped)
//    6. client VmHWM growth < 8 MB (Linux only; skipped on other platforms)
//
//  Usage:
//    ./Nghttp2FloodRead                  connects to 127.0.0.1:9010
//    ./Nghttp2FloodRead host port        custom target
//
//  Exit: 0 = pass   1 = fail   3 = skip (library absent or server not reachable)
//
//  Build (FPC):
//    fpc -MDelphi -O1 -Fu../src Nghttp2FloodRead.dpr
//  Build (Windows):
//    dcc64 -CC -B -U..\src Nghttp2FloodRead.dpr
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
  Nghttp2.Native,   { NghttpLoad, NghttpLoadError }
  Nghttp2.Client;   { TNghttp2Client, TNghttp2Headers, TNghttp2Response }

const
  DEFAULT_HOST = '127.0.0.1';
  DEFAULT_PORT = 9010;

  FLOOD_CHUNKS = 1024;
  FLOOD_CHUNK  = 64 * 1024;                { 64 KB per server write }
  FLOOD_TOTAL  = FLOOD_CHUNKS * FLOOD_CHUNK; { 64 MB }

  { One chunk at a time — the point of the gate is that this tiny buffer is
    all the caller ever holds, not 64 MB. }
  READ_SIZE    = 64 * 1024;

  { 60 s is generous on a local server. The server writes at line speed on
    loopback, so even with BACKPRESSURE-1 pacing 64 MB completes in < 10 s. }
  TIMEOUT_MS   = 60000;

  { 8 MB growth is generous: the Inbound buffer holds at most one recv
    (DEFAULT_RECV_BUFFER_SIZE = 16 KB), plus stack, code and working-set
    noise. 64 MB growth would mean the whole flood buffered. Setting the
    ceiling at 1/8 of the flood makes the assertion sensitive to the defect
    it guards while remaining robust on loaded CI machines. }
  PEAK_HWM_LIMIT_KB = 8 * 1024;           { 8 MB }

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSkip: Integer = 0;

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

procedure SkipCheck(const AName, AReason: string);
begin
  WriteLn('  SKIP  ', AName, '  [', AReason, ']');
  Inc(GSkip);
end;

{ Read VmHWM (peak resident set size, kB) from /proc/self/status.
  VmHWM only rises, so the delta between two reads spans the maximum memory
  the process held during that interval. Returns 0 on any error or on
  non-Linux platforms (the caller skips the assertion in that case). }
function SelfHwmKb: Int64;
{$IF DEFINED(LINUX)}
var
  F:    TextFile;
  Line: string;
  I:    Integer;
  Num:  string;
begin
  Result := 0;
  try
    AssignFile(F, '/proc/self/status');
    Reset(F);
    try
      while not EOF(F) do
      begin
        ReadLn(F, Line);
        { "VmHWM:" is 6 characters; digits follow after one or more spaces/tabs }
        if (Length(Line) >= 6) and (Copy(Line, 1, 6) = 'VmHWM:') then
        begin
          Num := '';
          for I := 7 to Length(Line) do
          begin
            if (Line[I] >= '0') and (Line[I] <= '9') then
              Num := Num + Line[I]
            else if Num <> '' then
              Break;
          end;
          Result := StrToInt64Def(Num, 0);
          Break;
        end;
      end;
    finally
      CloseFile(F);
    end;
  except
    Result := 0;
  end;
end;
{$ELSE}
begin
  Result := 0;
end;
{$IFEND}

var
  GHost:      string;
  GPort:      Word;
  GClient:    TNghttp2Client;
  GId:        Int32;
  GHeaders:   TNghttp2Headers;
  GBody:      TBytes;
  GBuf:       TBytes;
  GTotal:     Int64;
  GChunk:     Integer;
  GResp:      TNghttp2Response;
  GHwmBefore: Int64;
  GHwmAfter:  Int64;
  GHwmGrowth: Int64;

begin
  WriteLn('Nghttp2FloodRead — CL3b: client RSS bounded during 64 MB stream');
  WriteLn;

  GHost := DEFAULT_HOST;
  GPort := DEFAULT_PORT;
  if ParamCount >= 1 then GHost := ParamStr(1);
  if ParamCount >= 2 then GPort := Word(StrToIntDef(ParamStr(2), DEFAULT_PORT));

  WriteLn('  Target: ', GHost, ':', GPort, ' GET /stream/flood');
  WriteLn('  Flood:  ', FLOOD_TOTAL div (1024 * 1024), ' MB  (',
          FLOOD_CHUNKS, ' x ', FLOOD_CHUNK div 1024, ' KB server writes,  ',
          READ_SIZE div 1024, ' KB client reads)');
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

  GClient := TNghttp2Client.Create;
  try
    try
      GClient.Connect(GHost, GPort);
    except
      on E: Exception do
      begin
        WriteLn('  ================================================================');
        WriteLn('   SKIPPED — could not connect to ', GHost, ':', GPort, '.');
        WriteLn('   ', E.ClassName, ': ', E.Message);
        WriteLn('   Start HorseNghttp2TestServer before running this gate.');
        WriteLn('   The server must use async dispatch (the default).');
        WriteLn('  ================================================================');
        ExitCode := EXIT_SKIP;
        Exit;
      end;
    end;
    Check('connected to ' + GHost + ':' + IntToStr(GPort) + ' over h2c',
          GClient.Connected);

    { Sample peak RSS before the download begins. }
    GHwmBefore := SelfHwmKb;

    GId := GClient.BeginRequest('GET', '/stream/flood', GHeaders, GBody, True);
    Check('stream opened for incremental delivery (BeginRequest)',
          GId > 0, 'stream id: ' + IntToStr(GId));

    if GId <= 0 then
    begin
      WriteLn;
      WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
      ExitCode := EXIT_FAIL;
      Exit;
    end;

    { ReadChunk loop — the caller allocates READ_SIZE (64 KB) once and drains
      the 64 MB stream in a loop. No large allocation is ever made here: the
      whole point is that this loop is enough. }
    GTotal := 0;
    repeat
      GChunk := GClient.ReadChunk(GId, GBuf, READ_SIZE, TIMEOUT_MS);
      if GChunk > 0 then
        Inc(GTotal, GChunk);
    until GChunk <= 0;

    { VmHWM only rises. Reading it after the full download gives the peak the
      process ever reached — including any transient allocation during recv. }
    GHwmAfter := SelfHwmKb;

    Check('ReadChunk returned end-of-stream (0), not a timeout',
          GChunk = 0, IntToStr(GChunk));

    GResp := GClient.TakeResponse(GId);
    Check('response status 200', GResp.Status = 200, IntToStr(GResp.Status));

    Check('all ' + IntToStr(FLOOD_TOTAL div (1024 * 1024)) + ' MB received ('
          + IntToStr(FLOOD_TOTAL) + ' bytes)',
          GTotal = FLOOD_TOTAL,
          IntToStr(GTotal) + ' of ' + IntToStr(FLOOD_TOTAL) + ' byte(s)');

    { GHwmBefore = 0 means SelfHwmKb returned 0, which means we are not on
      Linux (or /proc/self/status is unavailable). Skip the RSS check rather
      than asserting Growth < LIMIT when Growth is 0 - (-0) = 0, which would
      always pass and prove nothing. }
    if GHwmBefore > 0 then
    begin
      GHwmGrowth := GHwmAfter - GHwmBefore;
      WriteLn('  RSS   VmHWM before = ', GHwmBefore, ' kB,  after = ',
              GHwmAfter, ' kB,  growth = ', GHwmGrowth, ' kB');
      Check('client peak RSS growth < ' + IntToStr(PEAK_HWM_LIMIT_KB)
            + ' kB (stream not buffered whole)',
            GHwmGrowth < PEAK_HWM_LIMIT_KB,
            'VmHWM grew ' + IntToStr(GHwmGrowth) + ' kB while streaming '
            + IntToStr(FLOOD_TOTAL div (1024 * 1024))
            + ' MB — body appears buffered, not streamed');
    end
    else
      SkipCheck('client peak RSS growth bounded',
                '/proc/self/status VmHWM unavailable — not Linux, or /proc absent');

  finally
    GClient.Free;
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GSkip > 0 then
  begin
    WriteLn('        ', GSkip, ' check(s) did NOT run — a skip is NOT a pass.');
    WriteLn('        Read the [reason] above before treating this run as complete.');
  end;
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
