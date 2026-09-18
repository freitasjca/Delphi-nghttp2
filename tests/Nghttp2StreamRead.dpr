program Nghttp2StreamRead;

// ============================================================================
//  Nghttp2StreamRead - CL3a. Does ReadChunk deliver a body incrementally?
//
//  ── What changed ──
//
//  Until CL3 the client buffered every response whole into
//  TNghttp2Response.Body. Right for a request/response exchange, wrong for
//  anything long-lived - SSE, a large download, a streaming gRPC call - where
//  the caller must consume bytes while the peer is still sending.
//
//  BeginRequest(..., AStreamResponse := True) now opts ONE stream out: its
//  DATA goes to a per-stream inbound buffer that ReadChunk drains, and
//  Response.Body stays empty. Opt-in per stream, mirroring INBOUND-1 on the
//  server side; nothing changes for a stream that does not ask.
//
//  ── What this gate PROVES ──
//
//  1. ReadChunk slices one body across several calls.
//  2. The reassembled payload is complete AND in order - each chunk carries its
//     own index, so a reordering or a dropped chunk fails the comparison rather
//     than merely changing a length.
//  3. The terminal call returns 0, distinguishable from a timeout (<0).
//  4. Response.Body is EMPTY on a streaming stream. This is the memory claim in
//     its checkable form: it proves the body was genuinely DIVERTED rather than
//     buffered and copied.
//  5. ReadChunk on a non-streaming stream RAISES, naming the fix.
//  6. TakeResponse REFUSES a streaming stream with bytes still unread, instead
//     of handing back an empty Body that would look exactly like a server which
//     sent nothing.
//
//  ── What it CANNOT prove, by construction ──
//
//  That chunks arrive BEFORE END_STREAM. This server runs inline dispatch:
//  Nghttp2.Session says "under inline dispatch the handler IS the connection
//  thread", so the handler pushes every chunk and returns before the pump runs,
//  and the client receives one burst. Pacing the handler cannot help - a Sleep
//  there stalls the very thread that would deliver the chunks.
//
//  Observing arrival-before-end needs async dispatch, and AsyncDispatch=True
//  does NOT make the library thread anything: OnRequest is called directly
//  (Nghttp2.Session ~1721), WorkerThreads defaults to 0 with "no pool unless
//  the host asks", and the server header says OnRequest "hands off to the
//  HOST's own pool". A gate that built its own pool would be mostly scaffolding
//  under test rather than ReadChunk.
//
//  So that assertion stays where it already works: the provider suite's
//  stage 15, which times real arrivals with `curl -N`. It is SKIPPED here with
//  its reason, never silently omitted.
//
//  ── One more limit, stated so a green run is not oversold ──
//
//  Client and server share a codec in one process. That is the shape which let
//  FIX-PROTO-UINT32-1 survive for months: two halves agreeing with each other
//  is not interoperability. This gate is about the API contract; the
//  independent-peer evidence for streaming is the provider suite.
//
//  Usage:  Nghttp2StreamRead
//  Exit:   0 = pass   1 = failed   3 = skipped (libnghttp2 absent)
//
//  Build (FPC):     fpc -MDelphi -Fu../src Nghttp2StreamRead.dpr
//  Build (Windows): dcc64 -CC -B -U..\src Nghttp2StreamRead.dpr
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  { cthreads MUST come first on Unix: the server starts a thread per
    connection and this program makes one. }
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
  { Clear of the siblings: smoke 19311, ALPN 19312/19313, read timeout 19314. }
  PORT = 19315;

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  CHUNKS    = 64;
  CHUNK_LEN = 12;                      { '[chunk 0001]' }
  TOTAL_LEN = CHUNKS * CHUNK_LEN;      { 768 }

  { Deliberately NOT a multiple of CHUNK_LEN, so reads land mid-chunk and the
    reassembly is doing real work rather than copying whole frames. }
  READ_SIZE = 40;

  READ_TIMEOUT_MS = 5000;

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

procedure Skip(const AName, AReason: string);
begin
  WriteLn('  SKIP  ', AName, '  [', AReason, ']');
  Inc(GSkip);
end;

function ChunkText(AIndex: Integer): string;
begin
  { The index is IN the payload: a dropped or reordered chunk changes the
    bytes, not merely the length. }
  Result := Format('[chunk %.4d]', [AIndex]);
end;

function ExpectedBytes: TBytes;
var
  LAll: string;
  I:    Integer;
begin
  LAll := '';
  for I := 1 to CHUNKS do
    LAll := LAll + ChunkText(I);
  Result := TEncoding.UTF8.GetBytes(LAll);
end;

{ Byte comparison rather than string: TEncoding.UTF8.GetBytes is exercised by
  the existing smoke on both compilers, GetString(TBytes) is not, and a first
  gate for a new API should not rest on an unverified RTL overload. }
function SameBytes(const A: TBytes; ALen: Integer; const B: TBytes): Boolean;
var
  I: Integer;
begin
  if ALen <> Length(B) then Exit(False);
  for I := 0 to ALen - 1 do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

{ OnRequest is a PLAIN procedure type - not `of object`, not anonymous -
  because that is the only shape which compiles on FPC without
  FUNCTIONREFERENCES. Same rule as Nghttp2ServerSmoke. }
procedure HandleRequest(const AStream: INghttp2Stream);
var
  I: Integer;
begin
  if AStream.Header[':path'] = '/stream' then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.BeginStreaming;
    for I := 1 to CHUNKS do
    begin
      { A peer that has gone away will never read these. Checking is the
        documented contract for a streaming handler. }
      if not AStream.IsStreamAlive then Break;
      AStream.PushStreamData(TEncoding.UTF8.GetBytes(ChunkText(I)));
    end;
    AStream.EndStreaming;
  end
  else if AStream.Header[':path'] = '/buffered' then
  begin
    { The control. A second, ordinary route proves the streaming path is a
      CHOICE rather than the only thing this server can now do. }
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes('buffered-ok'));
  end
  else
  begin
    AStream.StatusCode := 404;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes('nope'));
  end;
end;

var
  GServer:  TNghttp2Server;
  GConfig:  TNghttp2Config;
  GClient:  TNghttp2Client;
  GHeaders: TNghttp2Headers;   { nil - no extra request headers }
  GBody:    TBytes;            { nil - GET has no body }
  GResp:    TNghttp2Response;
  GBuf:     TBytes;
  GAcc:     TBytes;
  GAccLen:  Integer;
  GCalls:   Integer;
  GLast:    Integer;
  GId:      Int32;
  GRaised:  Boolean;
  GOverflow: Boolean;   { set if the server out-delivered the accumulator }
  GMsg:     string;

begin
  WriteLn('Nghttp2StreamRead - does ReadChunk deliver a body incrementally?');
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
      Check('client connected over h2c', GClient.Connected);

      // ─── 1. the streaming read ────────────────────────────────────────────
      GId := GClient.BeginRequest('GET', '/stream', GHeaders, GBody, True);

      SetLength(GAcc, TOTAL_LEN + READ_SIZE);   { headroom: never truncate }
      GAccLen   := 0;
      GCalls    := 0;
      GOverflow := False;
      repeat
        GLast := GClient.ReadChunk(GId, GBuf, READ_SIZE, READ_TIMEOUT_MS);
        if GLast > 0 then
        begin
          Inc(GCalls);
          { Stop accumulating once the buffer is full rather than tracking a
            length past its end. GAccLen is what SameBytes indexes with, so
            letting it run beyond Length(GAcc) would turn an over-delivery -
            the very defect this gate exists to catch - into an out-of-bounds
            READ inside the checker. The length assertion below still fails,
            which is the correct way to report it. }
          if GAccLen + GLast <= Length(GAcc) then
          begin
            Move(GBuf[0], GAcc[GAccLen], GLast);
            Inc(GAccLen, GLast);
          end
          else
            GOverflow := True;
        end;
      until GLast <= 0;

      Check('the server did not deliver more than the buffer could hold',
            not GOverflow,
            'over-delivery: more than ' + IntToStr(Length(GAcc)) + ' byte(s)');

      Check('ReadChunk delivered the body across several calls',
            GCalls >= 2, IntToStr(GCalls) + ' call(s)');
      Check('the whole body arrived - nothing lost between chunks',
            GAccLen = TOTAL_LEN, IntToStr(GAccLen) + ' of ' + IntToStr(TOTAL_LEN));
      Check('the terminal call returned 0 (end of stream, not a timeout)',
            GLast = 0, IntToStr(GLast));
      Check('the payload reassembled complete and IN ORDER',
            SameBytes(GAcc, GAccLen, ExpectedBytes));

      GResp := GClient.TakeResponse(GId);
      Check('status 200 on the streamed stream', GResp.Status = 200,
            IntToStr(GResp.Status));

      { The memory claim, in the only form a functional test can check: the
        body was DIVERTED to ReadChunk, not buffered and copied. }
      Check('Response.Body is EMPTY on a streaming stream (body was diverted)',
            Length(GResp.Body) = 0, IntToStr(Length(GResp.Body)) + ' byte(s)');

      // ─── 2. the control: a normal stream is unaffected ────────────────────
      GId := GClient.BeginRequest('GET', '/buffered', GHeaders, GBody);
      GClient.PumpAll(READ_TIMEOUT_MS);

      GRaised := False;
      GMsg    := '';
      try
        GClient.ReadChunk(GId, GBuf, 16, 1000);
      except
        on E: Exception do
        begin
          GRaised := True;
          GMsg    := E.Message;
        end;
      end;
      Check('ReadChunk on a NON-streaming stream raises',
            GRaised and (Pos('not opened for streaming', GMsg) > 0), GMsg);

      GResp := GClient.TakeResponse(GId);
      Check('the buffered control still returns its body whole',
            (GResp.Status = 200) and (Length(GResp.Body) = 11),
            IntToStr(Length(GResp.Body)) + ' byte(s)');

      // ─── 3. TakeResponse must not silently discard unread bytes ──────────
      GId := GClient.BeginRequest('GET', '/stream', GHeaders, GBody, True);
      GClient.PumpAll(READ_TIMEOUT_MS);   { completes; bytes arrive unread }

      GRaised := False;
      GMsg    := '';
      try
        GClient.TakeResponse(GId);
      except
        on E: Exception do
        begin
          GRaised := True;
          GMsg    := E.Message;
        end;
      end;
      Check('TakeResponse refuses a streaming stream with bytes still unread',
            GRaised and (Pos('unread', GMsg) > 0), GMsg);

      repeat
        GLast := GClient.ReadChunk(GId, GBuf, 512, READ_TIMEOUT_MS);
      until GLast <= 0;
      GResp := GClient.TakeResponse(GId);
      Check('after draining to end of stream, TakeResponse succeeds',
            GResp.Status = 200, IntToStr(GResp.Status));

      // ─── 4. what this shape cannot observe ───────────────────────────────
      Skip('chunks arrive BEFORE END_STREAM (timing)',
           'inline dispatch: the handler IS the connection thread, so it '
           + 'returns before the pump runs and the client sees one burst. '
           + 'Timed for real by the provider suite stage 15 (curl -N)');
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
