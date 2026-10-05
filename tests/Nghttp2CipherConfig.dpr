program Nghttp2CipherConfig;

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

// ============================================================================
//  Nghttp2CipherConfig - the TLSCIPHER-1 gate (1.22.0)
//  ===================================================
//  Destination: Delphi-nghttp2/tests/Nghttp2CipherConfig.dpr
//
//  ASKS: do TTlsServerContext.SetTls12CipherRules / SetTls13CipherSuites
//  apply what they are given, refuse what they cannot apply, and leave the
//  other generation's list alone? And (MINVER-1, 1.23.0, cases 25-31) does
//  SetMinProtocolVersion set the minimum, leave the cipher lists alone, and
//  refuse when the minimum does not take?
//  And (OSSLVER-1, 1.25.0, case 32) is the exact OpenSSL build reported,
//  not just the generation the file name implies?
//
//  Every assertion reads back the context's EFFECTIVE cipher list through
//  OpenSSL. "The setter did not raise" is never accepted as success on its
//  own: a setter that silently did nothing would pass that.
//
//  This covers three of the four levels of "it works" (API, applied, kept by
//  OpenSSL). The fourth - an external peer negotiating the configured suite -
//  needs a listening server and belongs to the provider's TLS suite.
//
//  The read-back helper below is this program's OWN, not the library's
//  private one, so the test does not agree with the code by construction.
//
//  CONTROL (reported, not gated): the raw OpenSSL call with a typo next to a
//  valid name. On 3.0.13 it returns 1 and drops the typo silently - that is
//  WHY SetTls13CipherSuites reads back. If a future OpenSSL rejects such a
//  list outright, the control line changes, the setter still raises (via
//  the return code instead) and the gate still passes, correctly.
//
//  Needs OpenSSL only - no libnghttp2, no socket, no certificate. Exit 3 =
//  OpenSSL absent: a loud SKIP, which means nothing here was verified.
//  An OpenSSL built without ChaCha20 (some FIPS builds) fails the CHACHA
//  cases by design: the setter is right to refuse a suite the build lacks.
// ============================================================================

uses
{$IF DEFINED(FPC)}
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.OpenSSL,
  Nghttp2.Tls;

const
  EXIT_PASS = 0;
  EXIT_FAIL = 1;
  EXIT_SKIP = 3;

  S_AES256 = 'TLS_AES_256_GCM_SHA384';
  S_CHACHA = 'TLS_CHACHA20_POLY1305_SHA256';
  S_TYPO   = 'TLS_AES_256_GCM_SHA348';        // 348, not 384
  S_LOWER  = 'tls_aes_256_gcm_sha384';        // right name, wrong case
  C12_256  = 'ECDHE-RSA-AES256-GCM-SHA384';
  C12_128  = 'ECDHE-RSA-AES128-GCM-SHA256';

type
  TCipherSetter = (cs12, cs13);

var
  GPass: Integer = 0;
  // MINVER-1 case 31: the real SSL_CTX_ctrl, restored after the fault test.
  GRealCtrl: function(ctx: PSSL_CTX; cmd: Integer; larg: LongInt;
                      parg: Pointer): LongInt; cdecl = nil;
  GFail: Integer = 0;
  GControlSilent: Boolean = False;

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

// ':NAME1:NAME2:...:' - the context's effective list, TLS 1.3 suites first.
function EffectiveNames(ACtx: TTlsServerContext): string;
var
  LStack: POPENSSL_STACK;
  LName:  PAnsiChar;
  I, N:   Integer;
begin
  Result := ':';
  LStack := SSL_CTX_get_ciphers(ACtx.Handle);
  N := OPENSSL_sk_num(LStack);
  for I := 0 to N - 1 do
  begin
    LName := SSL_CIPHER_get_name(OPENSSL_sk_value(LStack, I));
    if LName <> nil then
      Result := Result + string(AnsiString(LName)) + ':';
  end;
end;

function Has(const ANames, AName: string): Boolean;
begin
  Result := Pos(':' + AName + ':', ANames) > 0;
end;

// Runs one setter on ACtx. Returns '' when nothing was raised, else the
// exception's class name, with its message in AMsg. The CLASS is asserted by
// callers, not just "something was raised": an access violation is not a
// refusal.
function ApplyCatch(ACtx: TTlsServerContext; AWhich: TCipherSetter;
  const AValue: string; out AMsg: string): string;
begin
  Result := '';
  AMsg   := '';
  try
    case AWhich of
      cs12: ACtx.SetTls12CipherRules(AValue);
      cs13: ACtx.SetTls13CipherSuites(AValue);
    end;
  except
    on E: Exception do
    begin
      Result := E.ClassName;
      AMsg   := E.Message;
    end;
  end;
end;

// The test's OWN read of the minimum, through the raw call, so it does not
// agree with the library's read-back by construction.
function MinVersionOf(ACtx: TTlsServerContext): LongInt;
begin
  Result := SSL_CTX_ctrl(ACtx.Handle, SSL_CTRL_GET_MIN_PROTO_VERSION, 0, nil);
end;

// Same shape as ApplyCatch, for SetMinProtocolVersion.
function ApplyMin(ACtx: TTlsServerContext; AVersion: TNghttp2TlsMinVersion;
  out AMsg: string): string;
begin
  Result := '';
  AMsg   := '';
  try
    ACtx.SetMinProtocolVersion(AVersion);
  except
    on E: Exception do
    begin
      Result := E.ClassName;
      AMsg   := E.Message;
    end;
  end;
end;

// Case 31's fault: reports success for SET_MIN_PROTO_VERSION but changes
// nothing, which only a read-back can notice. Everything else passes through.
function IgnoringCtrl(ctx: PSSL_CTX; cmd: Integer; larg: LongInt;
  parg: Pointer): LongInt; cdecl;
begin
  if cmd = SSL_CTRL_SET_MIN_PROTO_VERSION then
    Result := 1
  else
    Result := GRealCtrl(ctx, cmd, larg, parg);
end;

var
  LCtx:   TTlsServerContext;
  LCls:   string;
  LMsg:   string;
  LNames: string;
  LAnsi:  AnsiString;
  LRc:    Integer;

begin
  WriteLn('Nghttp2CipherConfig - do the TLS 1.2 / 1.3 cipher setters apply, refuse and stay separate?');

  if not NghttpsslLoad then
  begin
    WriteLn('  ================================================================');
    WriteLn('   SKIPPED - OpenSSL is not present on this machine.');
    WriteLn('   ', NghttpsslLoadError);
    WriteLn('   Nothing below was verified.');
    WriteLn('  ================================================================');
    ExitCode := EXIT_SKIP;
    Exit;
  end;
  WriteLn('  OpenSSL: ', NghttpsslVersion);
  WriteLn;

  // ── 01 · the optional symbols resolved ────────────────────────────────
  // Gate before anything else: every later case calls through them, and a
  // nil one would be an AV, not a FAIL line.
  Check('01 cipher symbols resolved (all six optional ones)',
    Assigned(SSL_CTX_set_cipher_list) and Assigned(SSL_CTX_set_ciphersuites)
    and Assigned(SSL_CTX_get_ciphers) and Assigned(SSL_CIPHER_get_name)
    and Assigned(OPENSSL_sk_num) and Assigned(OPENSSL_sk_value),
    'OpenSSL older than 1.1.1? ' + NghttpsslVersion);
  if GFail > 0 then
  begin
    WriteLn;
    WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed (stopped: no symbols to test)');
    ExitCode := EXIT_FAIL;
    Exit;
  end;

  // ── CONTROL · what raw OpenSSL does with a typo next to a valid name ──
  LCtx := TTlsServerContext.Create;
  try
    LAnsi  := AnsiString(S_TYPO + ':' + S_CHACHA);
    LRc    := SSL_CTX_set_ciphersuites(LCtx.Handle, PAnsiChar(LAnsi));
    LNames := EffectiveNames(LCtx);
    GControlSilent := (LRc = 1) and Has(LNames, S_CHACHA) and not Has(LNames, S_TYPO);
    if GControlSilent then
      WriteLn('  CONTROL  raw set_ciphersuites returned 1 and silently dropped ',
              S_TYPO, ' - the read-back is what catches this')
    else
      WriteLn('  CONTROL  raw set_ciphersuites returned ', LRc,
              ' - this OpenSSL does not silently drop; the return code catches it');
  finally
    LCtx.Free;
  end;
  WriteLn;

  // ── TLS 1.3 ───────────────────────────────────────────────────────────
  LCtx := TTlsServerContext.Create;
  try
    LCls   := ApplyCatch(LCtx, cs13, S_CHACHA, LMsg);
    LNames := EffectiveNames(LCtx);
    Check('02 TLS 1.3 single suite: accepted', LCls = '', LCls + ': ' + LMsg);
    Check('03 TLS 1.3 single suite: KEPT by OpenSSL', Has(LNames, S_CHACHA), LNames);
    Check('04 TLS 1.3 single suite: REPLACED the default (AES-256 gone)',
      not Has(LNames, S_AES256), LNames);
  finally
    LCtx.Free;
  end;

  LCtx := TTlsServerContext.Create;
  try
    LCls := ApplyCatch(LCtx, cs13, S_TYPO + ':' + S_CHACHA, LMsg);
    Check('05 TLS 1.3 typo next to a valid name: refused with ENghttp2Tls',
      LCls = 'ENghttp2Tls', LCls + ': ' + LMsg);
    Check('06 ... and the message names the typo', Pos(S_TYPO, LMsg) > 0, LMsg);
    if GControlSilent then
      Check('07 ... caught by the READ-BACK, not the return code',
        Pos('silently dropped', LMsg) > 0, LMsg)
    else
      WriteLn('  ----  07 not applicable: this OpenSSL rejects the list itself');
  finally
    LCtx.Free;
  end;

  LCtx := TTlsServerContext.Create;
  try
    LCls := ApplyCatch(LCtx, cs13, S_LOWER + ':' + S_CHACHA, LMsg);
    Check('08 TLS 1.3 wrong case: refused with ENghttp2Tls',
      LCls = 'ENghttp2Tls', LCls + ': ' + LMsg);
    Check('09 ... and the message names it', Pos(S_LOWER, LMsg) > 0, LMsg);
  finally
    LCtx.Free;
  end;

  LCtx := TTlsServerContext.Create;
  try
    LCls := ApplyCatch(LCtx, cs13, 'TLS_NO_SUCH_SUITE', LMsg);
    Check('10 TLS 1.3 nothing valid: refused with ENghttp2Tls',
      LCls = 'ENghttp2Tls', LCls + ': ' + LMsg);
  finally
    LCtx.Free;
  end;

  LCtx := TTlsServerContext.Create;
  try
    LCls   := ApplyCatch(LCtx, cs13, S_AES256 + ' : ' + S_CHACHA, LMsg);
    LNames := EffectiveNames(LCtx);
    Check('11 TLS 1.3 spaces around ":" accepted (OpenSSL trims them too)',
      LCls = '', LCls + ': ' + LMsg);
    Check('12 ... and both suites kept', Has(LNames, S_AES256) and Has(LNames, S_CHACHA), LNames);
  finally
    LCtx.Free;
  end;

  LCtx := TTlsServerContext.Create;
  try
    LCls   := ApplyCatch(LCtx, cs13, '', LMsg);
    LNames := EffectiveNames(LCtx);
    Check('13 TLS 1.3 empty: no-op, no raise', LCls = '', LCls + ': ' + LMsg);
    Check('14 ... default suites still present (empty did not disable TLS 1.3)',
      Has(LNames, S_AES256), LNames);
  finally
    LCtx.Free;
  end;

  // ── TLS <= 1.2 ────────────────────────────────────────────────────────
  LCtx := TTlsServerContext.Create;
  try
    LCls   := ApplyCatch(LCtx, cs12, C12_256, LMsg);
    LNames := EffectiveNames(LCtx);
    Check('15 TLS 1.2 rule: accepted', LCls = '', LCls + ': ' + LMsg);
    Check('16 TLS 1.2 rule: KEPT by OpenSSL', Has(LNames, C12_256), LNames);
    Check('17 TLS 1.2 rule: REPLACED the default (AES-128 gone)',
      not Has(LNames, C12_128), LNames);
    Check('18 TLS 1.2 rule did NOT touch the TLS 1.3 suites', Has(LNames, S_AES256), LNames);
  finally
    LCtx.Free;
  end;

  LCtx := TTlsServerContext.Create;
  try
    LCls := ApplyCatch(LCtx, cs12, 'BOGUSCIPHER', LMsg);
    Check('19 TLS 1.2 nothing matches: refused with ENghttp2Tls',
      LCls = 'ENghttp2Tls', LCls + ': ' + LMsg);
  finally
    LCtx.Free;
  end;

  LCtx := TTlsServerContext.Create;
  try
    LCls   := ApplyCatch(LCtx, cs12, '', LMsg);
    LNames := EffectiveNames(LCtx);
    Check('20 TLS 1.2 empty: no-op, no raise', LCls = '', LCls + ': ' + LMsg);
    Check('21 ... default list unchanged', Has(LNames, C12_128), LNames);
  finally
    LCtx.Free;
  end;

  // ── the two together ─────────────────────────────────────────────────
  LCtx := TTlsServerContext.Create;
  try
    LCls := ApplyCatch(LCtx, cs12, C12_256, LMsg);
    if LCls = '' then
      LCls := ApplyCatch(LCtx, cs13, S_CHACHA, LMsg);
    LNames := EffectiveNames(LCtx);
    Check('22 both setters in sequence: accepted', LCls = '', LCls + ': ' + LMsg);
    Check('23 TLS 1.3 setter did NOT touch the TLS 1.2 list',
      Has(LNames, C12_256) and not Has(LNames, C12_128), LNames);
    Check('24 both lists as configured',
      Has(LNames, S_CHACHA) and not Has(LNames, S_AES256), LNames);
  finally
    LCtx.Free;
  end;

  // ── MINVER-1 · minimum protocol version ───────────────────────────────
  Check('25 SSL_CTX_ctrl resolved (minimum-version symbol)',
    Assigned(SSL_CTX_ctrl), NghttpsslVersion);
  if Assigned(SSL_CTX_ctrl) then
  begin
    LCtx := TTlsServerContext.Create;
    try
      LNames := EffectiveNames(LCtx);
      LCls := ApplyMin(LCtx, ntmTls13, LMsg);
      Check('26 minimum TLS 1.3: accepted', LCls = '', LCls + ': ' + LMsg);
      Check('27 ... the context REPORTS minimum TLS 1.3',
        MinVersionOf(LCtx) = TLS1_3_VERSION, Format('$%.4x', [MinVersionOf(LCtx)]));
      Check('28 ... cipher lists untouched by the minimum',
        EffectiveNames(LCtx) = LNames, EffectiveNames(LCtx));
      LCls := ApplyMin(LCtx, ntmTls12, LMsg);
      Check('29 minimum TLS 1.2: accepted', LCls = '', LCls + ': ' + LMsg);
      Check('30 ... the context REPORTS minimum TLS 1.2',
        MinVersionOf(LCtx) = TLS1_2_VERSION, Format('$%.4x', [MinVersionOf(LCtx)]));
    finally
      LCtx.Free;
    end;

    LCtx := TTlsServerContext.Create;
    GRealCtrl := SSL_CTX_ctrl;
    SSL_CTX_ctrl := IgnoringCtrl;
    try
      LCls := ApplyMin(LCtx, ntmTls13, LMsg);
    finally
      SSL_CTX_ctrl := GRealCtrl;
      LCtx.Free;
    end;
    Check('31 a minimum that reports success but does not take: refused by the READ-BACK',
      (LCls = 'ENghttp2Tls') and (Pos('context reports', LMsg) > 0), LCls + ': ' + LMsg);
  end;

  // -- 32 . the exact runtime build is reported (OSSLVER-1, 1.25.0) ---------
  // delphi-tls rule 5: a TLS result must name the OpenSSL build, and
  // "OpenSSL 3.x" is not one version (3.0 and 3.6 word the same failure
  // differently). OpenSSL_version exists in every 1.1.0+ libcrypto the loader
  // accepts, so it must resolve and the label must carry what it returned.
  Check('32 OpenSSL_version resolved: the exact runtime build is reported',
    Assigned(OpenSSL_version) and (Pos(' - OpenSSL ', NghttpsslVersion) > 0),
    NghttpsslVersion);

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed');
  if GFail > 0 then
    ExitCode := EXIT_FAIL
  else
    ExitCode := EXIT_PASS;
end.
