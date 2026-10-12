program Nghttp2KeyPassword;

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

// ============================================================================
//  Nghttp2KeyPassword - the KEYPW-1 gate
//  =====================================
//  Destination: Delphi-nghttp2/tests/Nghttp2KeyPassword.dpr
//
//  ASKS: does a password-protected private key load with the right password,
//  get REFUSED with a wrong one, and get refused - promptly, not by asking a
//  terminal - when no password was configured at all? And does a password
//  that is not plain ASCII reach OpenSSL as the UTF-8 bytes the key was
//  encrypted with?
//
//  Until this program, SetPrivateKeyPassword (server) and the password
//  argument of SetClientCertificate (client) had never met an encrypted key.
//
//  Two failure modes this is built to SEE, both found by reading the source:
//   - No password configured: the PEM callback is installed only by
//     SetPrivateKeyPassword, so without it OpenSSL falls back to its own
//     default callback, which prompts on the terminal. A server would then
//     wait at Listen for someone to type a pass phrase. Every load here runs
//     on its own thread with a deadline, so a prompt is reported as a FAIL
//     instead of hanging the suite. Run with stdin from /dev/null or NUL;
//     OpenSSL may still open the terminal directly, which is exactly the
//     case the deadline catches.
//   - Non-ASCII password on Delphi: AnsiString(APassword) converts through
//     the Windows ANSI code page, so "pässwörd" reaches OpenSSL as Latin-1
//     bytes, while keys encrypted by the openssl CLI or on Linux use UTF-8.
//     The fixture key-pkcs8-utf8.pem was verified to REFUSE the Latin-1 bytes.
//
//  Fixtures: tests/certs-keypw/ (regenerate with gen-keypw-fixtures.sh). One
//  key in four forms plus its certificate. Pass the folder as the first
//  argument, or run from tests/ (the default is .\certs-keypw).
//
//  Levels covered: API, applied, kept by OpenSSL (the key loads and matches
//  the certificate, CheckKeyMatch). The wire level - a peer completing a
//  handshake against a server whose key was encrypted - belongs to the
//  provider's TLS suite.
//
//  Exit 0 = pass, 1 = fail, 3 = OpenSSL absent (a loud SKIP), 4 = fixtures
//  missing (nothing verified).
// ============================================================================

uses
{$IF DEFINED(FPC)}
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
{$IFEND}
  Nghttp2.OpenSSL,
  Nghttp2.Tls;

const
  EXIT_PASS     = 0;
  EXIT_FAIL     = 1;
  EXIT_SKIP     = 3;
  EXIT_NOFIX    = 4;
  LOAD_DEADLINE = 5000;   // ms; a key load is microseconds, a prompt is forever

  PW_ASCII = 'horse-keypw-1';
  PW_WRONG = 'not-the-password';
  // "pässwörd". Delphi: UTF-16 code points; the library must send UTF-8.
  // FPC: string is an AnsiString, so the UTF-8 bytes are written directly,
  // which is how a UTF-8 FPC program holds this text.
{$IF DEFINED(FPC)}
  PW_UTF8 = 'p'#$C3#$A4'ssw'#$C3#$B6'rd';
{$ELSE}
  PW_UTF8 = 'p'#$00E4'ssw'#$00F6'rd';
{$IFEND}

type
  TLoadResult = (lrLoaded, lrRefused, lrHung);
  TSide = (sdServer, sdClient);

  // One key load on its own thread, so a load that blocks on a terminal
  // prompt can be timed out and reported instead of hanging the run.
  TLoadThread = class(TThread)
  private
    FSide:     TSide;
    FCertFile: string;
    FKeyFile:  string;
    FSetPwd:   Boolean;
    FPassword: string;
    FDone:     TEvent;
    FLoaded:   Boolean;
    FMessage:  string;
  protected
    procedure Execute; override;
  public
    constructor Create(ASide: TSide; const ACertFile, AKeyFile: string;
      ASetPwd: Boolean; const APassword: string);
    destructor Destroy; override;
  end;

var
  GPass: Integer = 0;
  GFail: Integer = 0;
  GDir:  string;

constructor TLoadThread.Create(ASide: TSide; const ACertFile, AKeyFile: string;
  ASetPwd: Boolean; const APassword: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSide     := ASide;
  FCertFile := ACertFile;
  FKeyFile  := AKeyFile;
  FSetPwd   := ASetPwd;
  FPassword := APassword;
  FDone     := TEvent.Create(nil, True, False, '');
end;

destructor TLoadThread.Destroy;
begin
  FDone.Free;
  inherited;
end;

procedure TLoadThread.Execute;
var
  LServer: TTlsServerContext;
  LClient: TTlsClientContext;
begin
  try
    try
      if FSide = sdServer then
      begin
        LServer := TTlsServerContext.Create;
        try
          // Same order as the provider: password first, then cert, key, match.
          if FSetPwd then
            LServer.SetPrivateKeyPassword(FPassword);
          LServer.LoadCertificateFile(FCertFile);
          LServer.LoadPrivateKeyFile(FKeyFile);
          LServer.CheckKeyMatch;
        finally
          LServer.Free;
        end;
      end
      else
      begin
        LClient := TTlsClientContext.Create;
        try
          // An empty password means "none configured" on this API.
          if FSetPwd then
            LClient.SetClientCertificate(FCertFile, FKeyFile, FPassword)
          else
            LClient.SetClientCertificate(FCertFile, FKeyFile);
        finally
          LClient.Free;
        end;
      end;
      FLoaded := True;
    except
      on E: Exception do
        FMessage := E.ClassName + ': ' + E.Message;
    end;
  finally
    FDone.SetEvent;
  end;
end;

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

procedure Summary;
begin
  WriteLn;
  WriteLn(Format('[Nghttp2KeyPassword] %d passed, %d failed', [GPass, GFail]));
end;

function TryLoad(ASide: TSide; const AKey: string; ASetPwd: Boolean;
  const APassword: string; out AMessage: string): TLoadResult;
var
  LThread: TLoadThread;
begin
  LThread := TLoadThread.Create(ASide, GDir + 'cert.pem', GDir + AKey,
    ASetPwd, APassword);
  LThread.Start;
  if LThread.FDone.WaitFor(LOAD_DEADLINE) <> wrSignaled then
  begin
    // The thread is blocked inside OpenSSL, most likely reading a pass phrase
    // from the terminal. It cannot be cancelled, so it is deliberately
    // leaked; the caller ends the process.
    AMessage := Format('no result after %d ms - OpenSSL is most likely ' +
      'prompting for a pass phrase on the terminal', [LOAD_DEADLINE]);
    Exit(lrHung);
  end;
  LThread.WaitFor;
  AMessage := LThread.FMessage;
  if LThread.FLoaded then
    Result := lrLoaded
  else
    Result := lrRefused;
  LThread.Free;
end;

const
  RESULT_NAMES: array[TLoadResult] of string = ('loaded', 'refused', 'HUNG');

// AExpectLoad: the key must load and match. Otherwise it must be refused,
// within the deadline. A hang ends the run after the summary: the blocked
// thread holds OpenSSL state, so nothing after it would be trustworthy.
procedure Expect(const AName: string; ASide: TSide; const AKey: string;
  ASetPwd: Boolean; const APassword: string; AExpectLoad: Boolean;
  ANoPassword: Boolean = False);
var
  LResult: TLoadResult;
  LMsg:    string;
begin
  LResult := TryLoad(ASide, AKey, ASetPwd, APassword, LMsg);
  if AExpectLoad then
    Check(AName, LResult = lrLoaded, RESULT_NAMES[LResult] + ' - ' + LMsg)
  else
    Check(AName, LResult = lrRefused,
      RESULT_NAMES[LResult] + ' - ' + LMsg);
  if (LResult = lrRefused) and (not AExpectLoad) then
    WriteLn('        refusal: ', LMsg);
  // No password configured: refusing is not enough. On Linux OpenSSL printed
  // "Enter PEM pass phrase:" and failed only because its read hit end of
  // input, so the control run PASSED the bare refusal while prompting. An
  // error from OpenSSL's "UI routines" means its prompt machinery ran.
  if ANoPassword and (LResult = lrRefused) then
  begin
    Check('   ... and OpenSSL did not run its pass-phrase prompt',
      Pos('UI routines', LMsg) = 0, LMsg);
    Check('   ... and the error tells the user to set SSLKeyPassword',
      Pos('SSLKeyPassword', LMsg) > 0, LMsg);
  end;
  if LResult = lrHung then
  begin
    Summary;
    WriteLn('[Nghttp2KeyPassword] stopped at a load that never returned.');
    Halt(EXIT_FAIL);
  end;
end;

begin
  if ParamCount >= 1 then
    GDir := IncludeTrailingPathDelimiter(ParamStr(1))
  else
    GDir := IncludeTrailingPathDelimiter(GetCurrentDir) + 'certs-keypw' + PathDelim;
  if not FileExists(GDir + 'key-pkcs8-ascii.pem') then
  begin
    WriteLn('[Nghttp2KeyPassword] fixtures not found in ', GDir);
    WriteLn('   pass the certs-keypw folder as the first argument');
    Halt(EXIT_NOFIX);
  end;

  if not NghttpsslLoad then
  begin
    WriteLn('[Nghttp2KeyPassword] SKIP - OpenSSL could not be loaded:');
    WriteLn('   ', NghttpsslLoadError);
    WriteLn('   Nothing below was verified.');
    Halt(EXIT_SKIP);
  end;
  WriteLn('[Nghttp2KeyPassword] OpenSSL: ', NghttpsslVersion);
  WriteLn('[Nghttp2KeyPassword] fixtures: ', GDir);
  WriteLn;

  // Server side. Every case that can only end in "loaded" or "refused" runs
  // first; the ones that can HANG run last, so a hang still leaves a full
  // record of everything else.
  WriteLn('-- server (TTlsServerContext) --');
  Expect('P0 control: unencrypted key, no password',
    sdServer, 'key-plain.pem', False, '', True);
  Expect('P1 PKCS#8 AES-256 key + right password',
    sdServer, 'key-pkcs8-ascii.pem', True, PW_ASCII, True);
  Expect('P2 PKCS#8 key + WRONG password is refused',
    sdServer, 'key-pkcs8-ascii.pem', True, PW_WRONG, False);
  Expect('P3 traditional PEM encryption (Proc-Type) + right password',
    sdServer, 'key-trad-ascii.pem', True, PW_ASCII, True);
  Expect('P4 traditional PEM + WRONG password is refused',
    sdServer, 'key-trad-ascii.pem', True, PW_WRONG, False);
  Expect('P5 non-ASCII password reaches OpenSSL as UTF-8',
    sdServer, 'key-pkcs8-utf8.pem', True, PW_UTF8, True);
  Expect('P6 SetPrivateKeyPassword('''') + encrypted key is refused',
    sdServer, 'key-pkcs8-ascii.pem', True, '', False);

  WriteLn;
  WriteLn('-- client (TTlsClientContext.SetClientCertificate) --');
  Expect('C1 client: encrypted key + right password',
    sdClient, 'key-pkcs8-ascii.pem', True, PW_ASCII, True);
  Expect('C2 client: encrypted key + WRONG password is refused',
    sdClient, 'key-pkcs8-ascii.pem', True, PW_WRONG, False);
  Expect('C3 client: non-ASCII password reaches OpenSSL as UTF-8',
    sdClient, 'key-pkcs8-utf8.pem', True, PW_UTF8, True);

  WriteLn;
  WriteLn('-- no password configured (the cases that can hang) --');
  Expect('P7 server: encrypted key, NO password set - refused, no prompt',
    sdServer, 'key-pkcs8-ascii.pem', False, '', False, True);
  Expect('C4 client: encrypted key, NO password - refused, no prompt',
    sdClient, 'key-pkcs8-ascii.pem', False, '', False, True);

  Summary;
  if GFail > 0 then
    Halt(EXIT_FAIL)
  else
    Halt(EXIT_PASS);
end.
