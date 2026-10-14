program Nghttp2GrpcUnaryClient;

// ============================================================================
//  Nghttp2GrpcUnaryClient - GC2 of the B2 gRPC client plan
//  (plans/grpc-client-b2.md): TGrpcChannel.Unary and EGrpcClientError.
//
//  ── The contract under test ──
//
//  A unary call returns a decoded response with grpc-status 0, or raises
//  EGrpcClientError carrying a gRPC status code. Every check below asserts
//  one side of that, and every failure case asserts the EXACT code, not just
//  "it raised": a client that turned every problem into 2 UNKNOWN would pass
//  a raise-only test and be useless to the code that has to react to it.
//
//  ── Three peers, on purpose ──
//
//  Part A - our own TNghttp2Server + TGrpcDispatcher, in process. Always runs.
//  Part B - grpc-probe-peer.py on python grpcio: an INDEPENDENT gRPC server
//           (framing, status trailers, grpc-message encoding, protobuf codec).
//           Our client against our server cannot see a bug the two share.
//  Part C - client-trailers-peer.py /gctest.Raw/*: replies no real gRPC
//           server sends (missing status, two messages, compressed flag,
//           wrong content-type, HTTP 503, ...). Each must become a specific
//           code. Neither our server nor grpcio can produce them.
//
//  B and C need python; without the peer the part prints SKIP - a skip is
//  not a pass. All three implement tests/gctest.proto.
//
//  ── GC2b: TLS, with the server VERIFIED ──
//
//  Part D - our own server over TLS (tests/certs-tls, a private CA): the
//           client trusts that CA and must check the certificate's NAME too.
//           Negatives first-class: nothing trusted / the wrong CA trusted
//           (X509_V_ERR 20), a valid chain for the wrong name - by IP (64) and
//           by DNS name (62) - and mTLS without a client certificate, or with
//           one from another issuer (14). One CONTROL: an insecure context
//           accepts the wrong-name certificate, so the refusals above come
//           from verification and not from a server that cannot serve.
//  Part E - grpcio over TLS and mTLS: the same positive and negative cases
//           against a TLS stack (BoringSSL) that is not OpenSSL.
//
//  ── GC3: deadlines and metadata ──
//
//  Part A: a deadline against our server's Slow handler raises 4 within the
//  deadline + 10% (+50 ms clock slack), the SAME channel works right after it
//  (FIX-SLOT-RESET-1), deadline 0 waits as long as CallTimeoutMS, and invalid
//  options raise EArgumentException before anything is sent. Our dispatcher
//  ignores grpc-timeout, so Part A proves LOCAL enforcement only.
//  Part C: /gctest.Raw/EchoHeaders reports the request headers as they
//  arrived, so the exact grpc-timeout value and metadata are asserted ON THE
//  WIRE. Part B: grpcio's application sees the metadata and the deadline
//  (context.time_remaining), and enforces it too.
//
//  The verification failures are asserted by their X509_V_* CODE through
//  TNghttp2Client (ENghttp2TlsCertVerify.VerifyResult), never by the text,
//  which differs between OpenSSL versions; at the gRPC level every TLS
//  failure is 14 UNAVAILABLE.
//
//  Exit codes:  0 = pass   1 = failed   3 = skipped, libnghttp2 absent
//
//  Build (Windows):  dcc64 -CC -B -U..\src Nghttp2GrpcUnaryClient.dpr
//  Build (FPC):      fpc -MDelphi -dNGHTTP2_GRPC_NO_FFI -Fu../src Nghttp2GrpcUnaryClient.dpr
//                    (RegisterMethod only - nothing reaches TRttiMethod.Invoke)
//  Run:              Nghttp2GrpcUnaryClient [grpcio=19324] [raw=19322]
//                      [certs=<tests/certs-tls>] [grpcio-tls=19330 grpcio-mtls=19331]
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}
{$M+}

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
  Nghttp2.Protobuf,
  Nghttp2.Grpc.Registry,
  Nghttp2.Grpc.Dispatcher,
  Nghttp2.Grpc.Framing,
  Nghttp2.Grpc.Client,
  Nghttp2.OpenSSL,
  Nghttp2.Tls,
  Nghttp2.Client;

{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

const
  { Clear of the other library stages (see Nghttp2ClientTrailers). The python
    peers' ports come from the command line; 19324 / 19322 by convention. }
  PORT      = 19323;
  DEAD_PORT = 19329;   // nothing listens here: the connection-refused case
  { GC2b, Part D: our own TLS servers. }
  PORT_TLS       = 19325;   // server.crt
  PORT_MTLS      = 19326;   // server.crt + client certificate required
  PORT_WRONGNAME = 19327;   // wrongname.crt: valid chain, SAN wrong-name.invalid

  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

type
  { gctest.proto. The tag numbers are the contract. }
  [TGrpcMessage]
  TEchoRequest = class
  private
    Ftext: string;
    Fnum:  Integer;
  published
    [TProtoMember(1)] property text: string  read Ftext write Ftext;
    [TProtoMember(2)] property num:  Integer read Fnum  write Fnum;
  end;

  [TGrpcMessage]
  TEchoReply = class
  private
    Ftext: string;
    Fnum:  Integer;
  published
    [TProtoMember(1)] property text: string  read Ftext write Ftext;
    [TProtoMember(2)] property num:  Integer read Fnum  write Fnum;
  end;

  [TGrpcMessage]
  TFailRequest = class
  private
    Fcode: Integer;
    Fmsg:  string;
  published
    { proto field "message" - renamed because message is a Delphi directive
      keyword (same reason as Sample.Echo.Messages). The tag is the contract. }
    [TProtoMember(1)] property code: Integer read Fcode write Fcode;
    [TProtoMember(2)] property msg:  string  read Fmsg  write Fmsg;
  end;

  { Handlers are `of object`; the dispatcher creates and frees both objects. }
  TProbeService = class
  public
    procedure Echo(const AReq: TObject; const AResp: TObject);
    procedure Fail(const AReq: TObject; const AResp: TObject);
    procedure Empty(const AReq: TObject; const AResp: TObject);
    procedure Slow(const AReq: TObject; const AResp: TObject);
  end;

  { GC2b: what a test client context trusts, and which certificate it shows. }
  TTrust      = (trNothing, trCa, trWrongCa, trInsecure);
  TClientCert = (ccNone, ccTrusted, ccUntrusted);

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GSkip: Integer = 0;
  GCertDir:  string = '';   // tests/certs-tls, with a trailing delimiter
  GKeypwDir: string = '';   // tests/certs-keypw: an UNRELATED self-signed cert

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

{ A string from explicit UTF-8 bytes, so the non-ASCII test text does not
  depend on the codepage the compiler reads this file in. }
function Utf8Text(const ABytes: array of Byte): string;
var
  LBytes: TBytes;
  I: Integer;
begin
  SetLength(LBytes, Length(ABytes));
  for I := 0 to High(ABytes) do
    LBytes[I] := ABytes[I];
  Result := TEncoding.UTF8.GetString(LBytes);
end;

{ "boom 100% " + U+00E7: a literal % and a 2-byte character, the two things a
  grpc-message encoder and decoder must agree on. }
function TrickyText: string;
begin
  Result := 'boom 100% ' + Utf8Text([$C3, $A7]);
end;

// ── Part A server ───────────────────────────────────────────────────────────

procedure TProbeService.Echo(const AReq: TObject; const AResp: TObject);
begin
  TEchoReply(AResp).text := 'echo:' + TEchoRequest(AReq).text;
  TEchoReply(AResp).num  := TEchoRequest(AReq).num + 1;
end;

{ Our dispatcher turns any handler exception into 13 INTERNAL with the
  exception's message, so the code is fixed and the message is the test. }
procedure TProbeService.Fail(const AReq: TObject; const AResp: TObject);
begin
  raise Exception.Create(TFailRequest(AReq).msg);
end;

procedure TProbeService.Empty(const AReq: TObject; const AResp: TObject);
begin
  // leave every field at its default: a zero-length message on the wire
end;

{ GC3: sleeps num ms. Our dispatcher ignores grpc-timeout, so this always
  runs to the end - the client's deadline is the only thing that can stop
  the call short. }
procedure TProbeService.Slow(const AReq: TObject; const AResp: TObject);
begin
  Sleep(TEchoRequest(AReq).num);
  TEchoReply(AResp).text := 'slept';
  TEchoReply(AResp).num  := TEchoRequest(AReq).num;
end;

procedure HandleRequest(const AStream: INghttp2Stream);
begin
  if TGrpcDispatcher.TryDispatch(AStream) then
    Exit;
  AStream.StatusCode := 404;
  AStream.Send(TEncoding.UTF8.GetBytes('not grpc'));
end;

// ── call helpers ────────────────────────────────────────────────────────────

{ Runs one call that must SUCCEED. Returns the reply (caller frees) or nil,
  recording a failure with the error if it raised. }
function CallOk(AChannel: TGrpcChannel; const AName, APath: string;
  ARequest: TObject): TEchoReply;
var
  LObj: TObject;
begin
  Result := nil;
  try
    LObj := AChannel.Unary(APath, ARequest, TEchoReply);
    if LObj is TEchoReply then
      Result := TEchoReply(LObj)
    else
    begin
      LObj.Free;
      Check(AName + ': reply is a TEchoReply', False);
    end;
  except
    on E: Exception do
      Check(AName + ': call succeeded', False, E.ClassName + ': ' + E.Message);
  end;
end;

{ Runs one call that must FAIL with exactly AStatus and, when AMessage is not
  empty, exactly that grpc-message. Anything else - success, another code,
  another exception class - is a failure, and says which. }
procedure ExpectStatus(AChannel: TGrpcChannel; const AName, APath: string;
  ARequest: TObject; AStatus: Integer; const AMessage: string = '');
var
  LObj: TObject;
begin
  LObj := nil;
  try
    LObj := AChannel.Unary(APath, ARequest, TEchoReply);
    Check(AName, False, 'returned a reply instead of raising');
  except
    on E: EGrpcClientError do
      if E.Status <> AStatus then
        Check(AName, False, Format('status %d %s, expected %d %s - "%s"',
          [E.Status, GrpcStatusName(E.Status), AStatus, GrpcStatusName(AStatus),
           E.GrpcMessage]))
      else if (AMessage <> '') and (E.GrpcMessage <> AMessage) then
        Check(AName, False, Format('message "%s", expected "%s"',
          [E.GrpcMessage, AMessage]))
      else
        Check(AName, True);
    on E: Exception do
      Check(AName, False, 'raised ' + E.ClassName + ', not EGrpcClientError: ' + E.Message);
  end;
  LObj.Free;
end;

function NewEcho(const AText: string; ANum: Integer): TEchoRequest;
begin
  Result := TEchoRequest.Create;
  Result.text := AText;
  Result.num  := ANum;
end;

function NewFail(ACode: Integer; const AMessage: string): TFailRequest;
begin
  Result := TFailRequest.Create;
  Result.code := ACode;
  Result.msg  := AMessage;
end;

// ── GC3 helpers ─────────────────────────────────────────────────────────────

function MsSince(const AStart: TDateTime): Int64;
begin
  Result := Round((Now - AStart) * 86400.0 * 1000.0);
end;

function Opts(ADeadlineMS: Integer): TGrpcCallOptions;
begin
  Result := TGrpcCallOptions.Default;
  Result.DeadlineMS := ADeadlineMS;
end;

{ A call that must fail with exactly AStatus; returns how long it took (ms),
  or -1 when it did not fail that way. }
function ExpectStatusOpt(AChannel: TGrpcChannel; const AName, APath: string;
  ARequest: TObject; const AOptions: TGrpcCallOptions; AStatus: Integer): Int64;
var
  LObj:   TObject;
  LStart: TDateTime;
begin
  Result := -1;
  LObj := nil;
  LStart := Now;
  try
    LObj := AChannel.Unary(APath, ARequest, TEchoReply, AOptions);
    Check(AName, False, 'returned a reply instead of raising');
  except
    on E: EGrpcClientError do
      if E.Status <> AStatus then
        Check(AName, False, Format('status %d %s, expected %d %s - "%s"',
          [E.Status, GrpcStatusName(E.Status), AStatus, GrpcStatusName(AStatus),
           E.GrpcMessage]))
      else
      begin
        Result := MsSince(LStart);
        Check(AName, True);
      end;
    on E: Exception do
      Check(AName, False, 'raised ' + E.ClassName + ', not EGrpcClientError: ' + E.Message);
  end;
  LObj.Free;
end;

{ A call that must succeed with options; caller frees the reply. }
function CallOkOpt(AChannel: TGrpcChannel; const AName, APath: string;
  ARequest: TObject; const AOptions: TGrpcCallOptions): TEchoReply;
var
  LObj: TObject;
begin
  Result := nil;
  try
    LObj := AChannel.Unary(APath, ARequest, TEchoReply, AOptions);
    if LObj is TEchoReply then
      Result := TEchoReply(LObj)
    else
    begin
      LObj.Free;
      Check(AName + ': reply is a TEchoReply', False);
    end;
  except
    on E: Exception do
      Check(AName, False, E.ClassName + ': ' + E.Message);
  end;
end;

{ Options that must be refused with EArgumentException BEFORE any I/O: the
  channel points at a dead port, so reaching the network would show up as
  14 UNAVAILABLE instead. }
procedure ExpectArgRefused(const AName: string; const AOptions: TGrpcCallOptions);
var
  LChannel: TGrpcChannel;
  LReq:     TEchoRequest;
  LObj:     TObject;
begin
  LObj := nil;
  LChannel := TGrpcChannel.Create('127.0.0.1', DEAD_PORT);
  LReq := NewEcho('x', 1);
  try
    try
      LObj := LChannel.Unary('/gctest.Probe/Echo', LReq, TEchoReply, AOptions);
      Check(AName, False, 'returned a reply');
    except
      on E: EArgumentException do
        Check(AName, True);
      on E: Exception do
        Check(AName, False, 'raised ' + E.ClassName + ' (sent anyway?): ' + E.Message);
    end;
  finally
    LObj.Free;
    LReq.Free;
    LChannel.Free;
  end;
end;

function WithMeta(ADeadlineMS: Integer; const AName, AValue: string): TGrpcCallOptions;
begin
  Result := Opts(ADeadlineMS);
  Result.AddMetadata(AName, AValue);
end;

{ The part every peer that implements gctest.Probe must pass: Echo, Empty,
  an unknown method. Returns nothing; records checks. }
procedure CommonCalls(AChannel: TGrpcChannel; const APrefix: string);
var
  LReq:   TEchoRequest;
  LReply: TEchoReply;
begin
  LReq := NewEcho('hi', 42);
  try
    LReply := CallOk(AChannel, APrefix + ' Echo', '/gctest.Probe/Echo', LReq);
    if LReply <> nil then
    try
      Check(APrefix + ' Echo: text and num came back transformed',
        (LReply.text = 'echo:hi') and (LReply.num = 43),
        Format('text "%s", num %d', [LReply.text, LReply.num]));
    finally
      LReply.Free;
    end;

    { The same channel again: the connection is reused, not reopened. }
    LReply := CallOk(AChannel, APrefix + ' second Echo', '/gctest.Probe/Echo', LReq);
    if LReply <> nil then
    try
      Check(APrefix + ' second call on the same channel works', LReply.num = 43);
    finally
      LReply.Free;
    end;

    LReply := CallOk(AChannel, APrefix + ' Empty', '/gctest.Probe/Empty', LReq);
    if LReply <> nil then
    try
      Check(APrefix + ' Empty: a zero-length message is a reply with defaults',
        (LReply.text = '') and (LReply.num = 0),
        Format('text "%s", num %d', [LReply.text, LReply.num]));
    finally
      LReply.Free;
    end;

    ExpectStatus(AChannel, APrefix + ' unknown method -> 12 UNIMPLEMENTED',
      '/gctest.Probe/Nope', LReq, GRPC_STATUS_UNIMPLEMENTED);
  finally
    LReq.Free;
  end;
end;

// ── the parts ───────────────────────────────────────────────────────────────

{ GC3 against our own server. Our dispatcher ignores grpc-timeout, so every
  deadline here is enforced by the CLIENT alone. }
procedure GC3PartA(AChannel: TGrpcChannel);
const
  DEADLINE = 400;
var
  LSlow, LEcho: TEchoRequest;
  LReply:       TEchoReply;
  LMs:          Int64;
  LOpt:         TGrpcCallOptions;
begin
  WriteLn;
  WriteLn('-- A3  GC3: deadlines (client-enforced) and call options');
  LSlow := NewEcho('', 2000);
  LEcho := NewEcho('after', 1);
  { 3 s rather than the 30 s default: no call here needs more, and a broken
    recovery then costs seconds, not minutes, before it is reported. }
  AChannel.CallTimeoutMS := 3000;
  try
    LMs := ExpectStatusOpt(AChannel, 'A deadline 400 ms vs a 2 s handler -> 4 DEADLINE_EXCEEDED',
      '/gctest.Probe/Slow', LSlow, Opts(DEADLINE), GRPC_STATUS_DEADLINE_EXCEEDED);
    if LMs >= 0 then
      Check('A ... and it gave up between the deadline and deadline + 10% (+50 ms clock slack)',
        (LMs >= DEADLINE - 20) and (LMs <= (DEADLINE * 11) div 10 + 50),
        Format('took %d ms', [LMs]))
    else
      Check('A ... and it gave up between the deadline and deadline + 10% (+50 ms clock slack)',
        False, 'no deadline failure to time');

    { FIX-SLOT-RESET-1: before it, the abandoned stream's slot survived the
      reconnect, so this call waited on it and timed out as well. }
    LReply := CallOkOpt(AChannel, 'A the SAME channel answers right after a deadline',
      '/gctest.Probe/Echo', LEcho, Opts(3000));
    if LReply <> nil then
    try
      Check('A the SAME channel answers right after a deadline', LReply.text = 'echo:after',
        Format('text "%s"', [LReply.text]));
    finally
      LReply.Free;
    end;

    LSlow.num := 300;
    LReply := CallOkOpt(AChannel, 'A deadline 0 = none: a 300 ms handler completes',
      '/gctest.Probe/Slow', LSlow, Opts(0));
    if LReply <> nil then
    try
      Check('A deadline 0 = none: a 300 ms handler completes',
        (LReply.text = 'slept') and (LReply.num = 300));
    finally
      LReply.Free;
    end;

    LSlow.num := 100;
    LReply := CallOkOpt(AChannel, 'A a generous deadline (5 s) does not fire on a 100 ms handler',
      '/gctest.Probe/Slow', LSlow, Opts(5000));
    if LReply <> nil then
    try
      Check('A a generous deadline (5 s) does not fire on a 100 ms handler', LReply.num = 100);
    finally
      LReply.Free;
    end;

    { Without a deadline, CallTimeoutMS is the backstop - and it is 4 too. }
    LSlow.num := 2000;
    AChannel.CallTimeoutMS := 300;
    try
      ExpectStatusOpt(AChannel, 'A no deadline, CallTimeoutMS 300 vs a 2 s handler -> 4',
        '/gctest.Probe/Slow', LSlow, Opts(0), GRPC_STATUS_DEADLINE_EXCEEDED);
    finally
      AChannel.CallTimeoutMS := 3000;
    end;
  finally
    AChannel.CallTimeoutMS := DEFAULT_REQUEST_TIMEOUT_MS;
    LEcho.Free;
    LSlow.Free;
  end;

  ExpectArgRefused('A negative deadline -> EArgumentException, nothing sent', Opts(-1));
  ExpectArgRefused('A metadata name with uppercase -> EArgumentException',
    WithMeta(0, 'X-Trace', 'a'));
  ExpectArgRefused('A reserved name grpc-timeout as metadata -> EArgumentException',
    WithMeta(0, 'grpc-timeout', '1S'));
  ExpectArgRefused('A a value with CR LF -> EArgumentException',
    WithMeta(0, 'x-trace', 'a'#13#10'b'));
  LOpt := WithMeta(0, 'x-blob-bin', 'AAEC');
  ExpectArgRefused('A binary (-bin) metadata -> EArgumentException (not supported yet)', LOpt);
end;

procedure PartA;
var
  LServer:  TNghttp2Server;
  LConfig:  TNghttp2Config;
  LChannel: TGrpcChannel;
  LFail:    TFailRequest;
  LReq:     TEchoRequest;
begin
  WriteLn;
  WriteLn('-- A   our own server (TGrpcDispatcher) on port ', PORT);
  LServer := TNghttp2Server.Create;
  try
    LServer.OnRequest := HandleRequest;
    LConfig      := TNghttp2Config.Default;
    LConfig.Port := PORT;
    LServer.Start(LConfig);

    LChannel := TGrpcChannel.Create('127.0.0.1', PORT);
    try
      CommonCalls(LChannel, 'A');

      LFail := NewFail(0, TrickyText);
      try
        ExpectStatus(LChannel,
          'A handler raises -> 13 INTERNAL, message intact through % and UTF-8',
          '/gctest.Probe/Fail', LFail, GRPC_STATUS_INTERNAL, TrickyText);
      finally
        LFail.Free;
      end;

      GC3PartA(LChannel);
    finally
      LChannel.Free;
    end;
    LServer.Stop;
  finally
    LServer.Free;
  end;

  WriteLn;
  WriteLn('-- A2  nobody listening');
  LChannel := TGrpcChannel.Create('127.0.0.1', DEAD_PORT);
  try
    LReq := NewEcho('x', 1);
    try
      ExpectStatus(LChannel, 'connection refused -> 14 UNAVAILABLE',
        '/gctest.Probe/Echo', LReq, GRPC_STATUS_UNAVAILABLE);
    finally
      LReq.Free;
    end;
  finally
    LChannel.Free;
  end;
end;

{ GC3 against grpcio: its APPLICATION sees what we sent. }
procedure GC3PartB(AChannel: TGrpcChannel);
var
  LReq:   TEchoRequest;
  LReply: TEchoReply;
  LOpt:   TGrpcCallOptions;
begin
  LReq := NewEcho('', 2000);
  try
    LOpt := Opts(1500);
    LOpt.AddMetadata('x-trace', 'abc-123');
    LOpt.AddMetadata('x-tenant', 't1');
    LReply := CallOkOpt(AChannel, 'B GC3 Meta call', '/gctest.Probe/Meta', LReq, LOpt);
    if LReply <> nil then
    try
      Check('B GC3: the metadata reached the grpcio application exactly',
        LReply.text = 'x-tenant=t1;x-trace=abc-123', Format('got "%s"', [LReply.text]));
      Check('B GC3: the grpcio application saw the deadline (0 < time left <= 1500 ms)',
        (LReply.num > 0) and (LReply.num <= 1500), Format('time left %d ms', [LReply.num]));
    finally
      LReply.Free;
    end;

    LReply := CallOkOpt(AChannel, 'B GC3 Meta call without a deadline',
      '/gctest.Probe/Meta', LReq, Opts(0));
    if LReply <> nil then
    try
      Check('B GC3: deadline 0 = the grpcio application sees NO deadline',
        LReply.num = -1, Format('time left %d ms', [LReply.num]));
    finally
      LReply.Free;
    end;

    ExpectStatusOpt(AChannel, 'B GC3: deadline 300 ms vs grpcio Slow(2000) -> 4 DEADLINE_EXCEEDED',
      '/gctest.Probe/Slow', LReq, Opts(300), GRPC_STATUS_DEADLINE_EXCEEDED);
  finally
    LReq.Free;
  end;
end;

procedure PartB(APort: Integer);
var
  LChannel: TGrpcChannel;
  LFail:    TFailRequest;
begin
  WriteLn;
  WriteLn('-- B   independent gRPC server (python grpcio) on port ', APort);
  LChannel := TGrpcChannel.Create('127.0.0.1', APort);
  try
    CommonCalls(LChannel, 'B');

    { grpcio sends an aborted call as a headers-only response, so these also
      take the GC1 HeadersOnly path; Echo above takes the trailer path. }
    LFail := NewFail(GRPC_STATUS_NOT_FOUND, 'not here: ' + TrickyText);
    try
      ExpectStatus(LChannel, 'B abort(NOT_FOUND) -> 5, grpc-message decoded exactly',
        '/gctest.Probe/Fail', LFail, GRPC_STATUS_NOT_FOUND, 'not here: ' + TrickyText);
    finally
      LFail.Free;
    end;
    LFail := NewFail(GRPC_STATUS_PERMISSION_DENIED, 'nope');
    try
      ExpectStatus(LChannel, 'B abort(PERMISSION_DENIED) -> 7',
        '/gctest.Probe/Fail', LFail, GRPC_STATUS_PERMISSION_DENIED, 'nope');
    finally
      LFail.Free;
    end;

    GC3PartB(LChannel);
  finally
    LChannel.Free;
  end;
end;

procedure PartC(APort: Integer);
var
  LChannel: TGrpcChannel;
  LReq:     TEchoRequest;
  LReply:   TEchoReply;

  procedure Raw(const AName: string; AStatus: Integer);
  begin
    ExpectStatus(LChannel, 'C ' + AName + ' -> ' + IntToStr(AStatus) + ' '
      + GrpcStatusName(AStatus), '/gctest.Raw/' + AName, LReq, AStatus);
  end;

begin
  WriteLn;
  WriteLn('-- C   malformed replies (python h2) on port ', APort);
  LChannel := TGrpcChannel.Create('127.0.0.1', APort);
  LReq := NewEcho('x', 1);
  try
    Raw('NoStatus',       GRPC_STATUS_INTERNAL);
    Raw('TwoMessages',    GRPC_STATUS_INTERNAL);
    Raw('Compressed',     GRPC_STATUS_INTERNAL);
    Raw('NotGrpc',        GRPC_STATUS_INTERNAL);
    Raw('Http503',        GRPC_STATUS_UNAVAILABLE);
    Raw('OkNoMessage',    GRPC_STATUS_INTERNAL);
    Raw('TrailersOnlyOk', GRPC_STATUS_INTERNAL);
    Raw('BadStatus',      GRPC_STATUS_UNKNOWN);
    Raw('Truncated',      GRPC_STATUS_INTERNAL);

    { GC3: what actually went on the wire. }
    LReply := CallOkOpt(LChannel, 'C GC3 EchoHeaders',
      '/gctest.Raw/EchoHeaders', LReq, WithMeta(1500, 'x-trace', 'abc-123'));
    if LReply <> nil then
    try
      Check('C GC3: on the wire grpc-timeout is exactly "1500m" and the metadata arrived',
        LReply.text = 'grpc-timeout=1500m|x-trace=abc-123', Format('got "%s"', [LReply.text]));
    finally
      LReply.Free;
    end;
    LReply := CallOkOpt(LChannel, 'C GC3 EchoHeaders without options',
      '/gctest.Raw/EchoHeaders', LReq, Opts(0));
    if LReply <> nil then
    try
      Check('C GC3: deadline 0 sends NO grpc-timeout', LReply.text = 'grpc-timeout=-|',
        Format('got "%s"', [LReply.text]));
    finally
      LReply.Free;
    end;
  finally
    LReq.Free;
    LChannel.Free;
  end;
end;

// ── GC2b: TLS helpers ───────────────────────────────────────────────────────

function NewServerTls(const ACertName, AKeyName, AClientCaName: string): TTlsServerContext;
begin
  Result := TTlsServerContext.Create;
  try
    Result.LoadCertificateFile(GCertDir + ACertName);
    Result.LoadPrivateKeyFile(GCertDir + AKeyName);
    Result.CheckKeyMatch;
    Result.EnableHttp2Alpn;
    if AClientCaName <> '' then
      Result.EnableClientCertVerification(GCertDir + AClientCaName);
  except
    Result.Free;
    raise;
  end;
end;

function StartTlsServer(APort: Integer; ACtx: TTlsServerContext): TNghttp2Server;
var
  LConfig: TNghttp2Config;
begin
  Result := TNghttp2Server.Create;
  try
    Result.OnRequest  := HandleRequest;
    Result.TlsContext := ACtx;          // borrowed; freed by the caller after Stop
    LConfig      := TNghttp2Config.Default;
    LConfig.Port := APort;
    Result.Start(LConfig);
  except
    Result.Free;
    raise;
  end;
end;

procedure StopAndFree(var AServer: TNghttp2Server);
begin
  if AServer = nil then
    Exit;
  try
    AServer.Stop;
  finally
    FreeAndNil(AServer);
  end;
end;

function NewClientTls(ATrust: TTrust; ACert: TClientCert): TTlsClientContext;
begin
  Result := TTlsClientContext.Create;
  try
    case ATrust of
      trNothing:  ;                      // verify ON, nothing trusted: the default
      trCa:       Result.LoadVerifyLocations(GCertDir + 'ca.crt');
      trWrongCa:  Result.LoadVerifyLocations(GKeypwDir + 'cert.pem');
      trInsecure: Result.SetInsecure;
    end;
    case ACert of
      ccNone:      ;
      ccTrusted:   Result.SetClientCertificate(GCertDir + 'client.crt', GCertDir + 'client.key');
      ccUntrusted: Result.SetClientCertificate(GKeypwDir + 'cert.pem', GKeypwDir + 'key-plain.pem');
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ A verified (or, for the control, insecure) Echo over TLS that must succeed. }
procedure EchoTls(const AName, AHost: string; APort: Integer; ATrust: TTrust;
  ACert: TClientCert);
var
  LCtx:     TTlsClientContext;
  LChannel: TGrpcChannel;
  LReq:     TEchoRequest;
  LReply:   TEchoReply;
begin
  LCtx := nil;
  LChannel := nil;
  LReq := nil;
  try
    try
      LCtx := NewClientTls(ATrust, ACert);
      LChannel := TGrpcChannel.Create(AHost, APort, LCtx);
      LChannel.CallTimeoutMS := 5000;
      LReq := NewEcho('tls', 7);
      LReply := CallOk(LChannel, AName, '/gctest.Probe/Echo', LReq);
      if LReply <> nil then
      try
        Check(AName, (LReply.text = 'echo:tls') and (LReply.num = 8),
          Format('text "%s", num %d', [LReply.text, LReply.num]));
      finally
        LReply.Free;
      end;
    except
      on E: Exception do
        Check(AName, False, 'setup raised ' + E.ClassName + ': ' + E.Message);
    end;
  finally
    LReq.Free;
    LChannel.Free;     // before the context it borrows
    LCtx.Free;
  end;
end;

{ A TLS call that must fail as 14 UNAVAILABLE; when AMustName is not empty the
  grpc-message must also name it (the underlying exception class). }
procedure Unavailable(const AName, AHost: string; APort: Integer; ATrust: TTrust;
  ACert: TClientCert; const AMustName: string);
var
  LCtx:     TTlsClientContext;
  LChannel: TGrpcChannel;
  LReq:     TEchoRequest;
  LObj:     TObject;
begin
  LCtx := nil;
  LChannel := nil;
  LReq := nil;
  LObj := nil;
  try
    try
      LCtx := NewClientTls(ATrust, ACert);
      LChannel := TGrpcChannel.Create(AHost, APort, LCtx);
      LChannel.CallTimeoutMS := 5000;
      LReq := NewEcho('tls', 7);
      LObj := LChannel.Unary('/gctest.Probe/Echo', LReq, TEchoReply);
      Check(AName, False, 'returned a reply instead of raising');
    except
      on E: EGrpcClientError do
        if E.Status <> GRPC_STATUS_UNAVAILABLE then
          Check(AName, False, Format('status %d %s, expected 14 UNAVAILABLE - "%s"',
            [E.Status, GrpcStatusName(E.Status), E.GrpcMessage]))
        else if (AMustName <> '') and (Pos(AMustName, E.GrpcMessage) = 0) then
          Check(AName, False, Format('"%s" does not name %s', [E.GrpcMessage, AMustName]))
        else
          Check(AName, True);
      on E: Exception do
        Check(AName, False, 'raised ' + E.ClassName + ', not EGrpcClientError: ' + E.Message);
    end;
  finally
    LObj.Free;
    LReq.Free;
    LChannel.Free;
    LCtx.Free;
  end;
end;

{ The client must refuse the server's certificate with exactly X509_V_* code
  ACode - asserted on TNghttp2Client.Connect, where the class and the code
  are still intact (the gRPC layer folds every TLS failure into 14). }
procedure RefusedCert(const AName, AHost: string; APort: Integer; ATrust: TTrust;
  ACode: Integer);
var
  LCtx:    TTlsClientContext;
  LClient: TNghttp2Client;
begin
  LCtx := nil;
  LClient := nil;
  try
    try
      LCtx := NewClientTls(ATrust, ccNone);
      LClient := TNghttp2Client.Create;
      LClient.TlsContext := LCtx;
      LClient.Connect(AHost, APort);
      Check(AName, False, 'connected - the certificate was ACCEPTED');
    except
      on E: ENghttp2TlsCertVerify do
        Check(AName, E.VerifyResult = ACode,
          Format('X509_V_ERR %d, expected %d - %s', [E.VerifyResult, ACode, E.Message]));
      on E: Exception do
        Check(AName, False, 'raised ' + E.ClassName + ', not ENghttp2TlsCertVerify: ' + E.Message);
    end;
  finally
    LClient.Free;
    LCtx.Free;
  end;
end;

procedure PartD;
var
  LTlsCtx, LMtlsCtx, LWrongCtx: TTlsServerContext;
  LTls, LMtls, LWrong:          TNghttp2Server;
begin
  WriteLn;
  WriteLn('-- D   TLS against our own server: verified ', PORT_TLS, ', mTLS ', PORT_MTLS,
    ', wrong-name certificate ', PORT_WRONGNAME);
  LTlsCtx := nil; LMtlsCtx := nil; LWrongCtx := nil;
  LTls := nil;    LMtls := nil;    LWrong := nil;
  try
    LTlsCtx   := NewServerTls('server.crt',    'server.key',    '');
    LMtlsCtx  := NewServerTls('server.crt',    'server.key',    'ca.crt');
    LWrongCtx := NewServerTls('wrongname.crt', 'wrongname.key', '');
    LTls   := StartTlsServer(PORT_TLS,       LTlsCtx);
    LMtls  := StartTlsServer(PORT_MTLS,      LMtlsCtx);
    LWrong := StartTlsServer(PORT_WRONGNAME, LWrongCtx);

    EchoTls('D verified TLS, by IP 127.0.0.1: Echo',
      '127.0.0.1', PORT_TLS, trCa, ccNone);
    EchoTls('D verified TLS, by name localhost: Echo (DNS name check + SNI)',
      'localhost', PORT_TLS, trCa, ccNone);
    RefusedCert('D nothing trusted -> refused, X509_V_ERR 20',
      '127.0.0.1', PORT_TLS, trNothing, X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY);
    RefusedCert('D another CA trusted -> refused, X509_V_ERR 20',
      '127.0.0.1', PORT_TLS, trWrongCa, X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY);
    RefusedCert('D valid chain, wrong name, by IP -> refused, X509_V_ERR 64',
      '127.0.0.1', PORT_WRONGNAME, trCa, X509_V_ERR_IP_ADDRESS_MISMATCH);
    RefusedCert('D valid chain, wrong name, by DNS name -> refused, X509_V_ERR 62',
      'localhost', PORT_WRONGNAME, trCa, X509_V_ERR_HOSTNAME_MISMATCH);
    EchoTls('D CONTROL: an insecure context accepts that same wrong-name server',
      '127.0.0.1', PORT_WRONGNAME, trInsecure, ccNone);
    Unavailable('D gRPC: wrong-name certificate -> 14 UNAVAILABLE, naming ENghttp2TlsCertVerify',
      '127.0.0.1', PORT_WRONGNAME, trCa, ccNone, 'ENghttp2TlsCertVerify');
    EchoTls('D mTLS with the client certificate: Echo',
      '127.0.0.1', PORT_MTLS, trCa, ccTrusted);
    Unavailable('D mTLS WITHOUT a client certificate -> 14 UNAVAILABLE',
      '127.0.0.1', PORT_MTLS, trCa, ccNone, '');
    Unavailable('D mTLS with a client certificate from another issuer -> 14 UNAVAILABLE',
      '127.0.0.1', PORT_MTLS, trCa, ccUntrusted, '');
  finally
    StopAndFree(LWrong);
    StopAndFree(LMtls);
    StopAndFree(LTls);
    LWrongCtx.Free;
    LMtlsCtx.Free;
    LTlsCtx.Free;
  end;
end;

procedure PartE(ATlsPort, AMtlsPort: Integer);
begin
  WriteLn;
  WriteLn('-- E   TLS against grpcio (BoringSSL): verified ', ATlsPort, ', mTLS ', AMtlsPort);
  EchoTls('E verified TLS, by IP 127.0.0.1: Echo',
    '127.0.0.1', ATlsPort, trCa, ccNone);
  EchoTls('E verified TLS, by name localhost: Echo',
    'localhost', ATlsPort, trCa, ccNone);
  RefusedCert('E nothing trusted -> refused, X509_V_ERR 20',
    '127.0.0.1', ATlsPort, trNothing, X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY);
  EchoTls('E mTLS with the client certificate: Echo',
    '127.0.0.1', AMtlsPort, trCa, ccTrusted);
  Unavailable('E mTLS WITHOUT a client certificate -> 14 UNAVAILABLE',
    '127.0.0.1', AMtlsPort, trCa, ccNone, '');
end;

function ArgValue(const AKey: string): string;
var
  I: Integer;
  LPrefix: string;
begin
  Result := '';
  LPrefix := AKey + '=';
  for I := 1 to ParamCount do
    if SameText(Copy(ParamStr(I), 1, Length(LPrefix)), LPrefix) then
      Result := Copy(ParamStr(I), Length(LPrefix) + 1, MaxInt);
end;

function PortArg(const AKey: string): Integer;
begin
  Result := StrToIntDef(ArgValue(AKey), 0);
end;

var
  GService: TProbeService;

begin
  WriteLn('Nghttp2GrpcUnaryClient - GC2: TGrpcChannel.Unary + EGrpcClientError (+ GC2b TLS, GC3 deadlines/metadata)');

  if not NghttpLoad then
  begin
    WriteLn;
    WriteLn('  SKIPPED - libnghttp2 is not present on this machine.');
    WriteLn('  ', NghttpLoadError);
    WriteLn('  Nothing in this stage ran. A skip is not a pass.');
    ExitCode := EXIT_SKIP;
    Exit;
  end;

  GService := TProbeService.Create;
  try
    TGrpcRegistry.RegisterMethod('/gctest.Probe/Echo',
      TEchoRequest, TEchoReply, GService.Echo);
    TGrpcRegistry.RegisterMethod('/gctest.Probe/Fail',
      TFailRequest, TEchoReply, GService.Fail);
    TGrpcRegistry.RegisterMethod('/gctest.Probe/Empty',
      TEchoRequest, TEchoReply, GService.Empty);
    TGrpcRegistry.RegisterMethod('/gctest.Probe/Slow',
      TEchoRequest, TEchoReply, GService.Slow);
    try
      try
        PartA;
      except
        on E: Exception do
          Check('Part A ran to the end', False, E.ClassName + ': ' + E.Message);
      end;

      if PortArg('grpcio') > 0 then
      try
        PartB(PortArg('grpcio'));
      except
        on E: Exception do
          Check('Part B ran to the end', False, E.ClassName + ': ' + E.Message);
      end
      else
      begin
        WriteLn;
        Skip('Part B: the independent grpcio server',
          'no grpcio=<port> - run grpc-probe-peer.py (needs python grpcio + grpcio-tools)');
      end;

      if PortArg('raw') > 0 then
      try
        PartC(PortArg('raw'));
      except
        on E: Exception do
          Check('Part C ran to the end', False, E.ClassName + ': ' + E.Message);
      end
      else
      begin
        WriteLn;
        Skip('Part C: malformed replies',
          'no raw=<port> - run client-trailers-peer.py (needs python h2)');
      end;

      { GC2b. The fixtures are committed, so a missing certs= is a runner
        problem - but it is still reported as a skip, never a pass. }
      GCertDir := ArgValue('certs');
      if GCertDir = '' then
      begin
        WriteLn;
        Skip('Parts D + E: TLS', 'no certs=<dir> - pass tests/certs-tls');
      end
      else if not NghttpsslLoad then
      begin
        WriteLn;
        Skip('Parts D + E: TLS', 'OpenSSL is not loadable: ' + NghttpsslLoadError);
      end
      else
      begin
        GCertDir  := IncludeTrailingPathDelimiter(GCertDir);
        GKeypwDir := GCertDir + '..' + PathDelim + 'certs-keypw' + PathDelim;
        WriteLn;
        WriteLn('  OpenSSL: ', NghttpsslVersion);
        try
          PartD;
        except
          on E: Exception do
            Check('Part D ran to the end', False, E.ClassName + ': ' + E.Message);
        end;

        if (PortArg('grpcio-tls') > 0) and (PortArg('grpcio-mtls') > 0) then
        try
          PartE(PortArg('grpcio-tls'), PortArg('grpcio-mtls'));
        except
          on E: Exception do
            Check('Part E ran to the end', False, E.ClassName + ': ' + E.Message);
        end
        else
        begin
          WriteLn;
          Skip('Part E: TLS against grpcio',
            'no grpcio-tls=/grpcio-mtls= - run grpc-probe-peer.py with --certs');
        end;
      end;
    finally
      TGrpcRegistry.Shutdown;
    end;
  finally
    GService.Free;
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed, ', GSkip, ' skipped');
  if GSkip > 0 then
    WriteLn('        ', GSkip, ' part(s) did NOT run - see the SKIP lines above.');
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
