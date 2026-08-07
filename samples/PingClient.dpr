program PingClient;

// ============================================================================
//  Minimal Nghttp2.Client smoke test — cleartext (h2c) and TLS (h2) both.
//
//  Prerequisites:
//    - nghttp2.dll on the runtime DLL search path (next to .exe on Windows)
//    - For https URLs: libssl-3.dll + libcrypto-3.dll (or 1.1.x equivalents)
//      also on the DLL search path
//    - A running HTTP/2 server:
//        h2c:  HorseNghttp2TestServer.exe on 127.0.0.1:9010
//        h2:   HorseNghttp2TlsTestServer.exe on 127.0.0.1:9443 (self-signed cert OK)
//
//  Build (Windows, Delphi):
//    dcc32 -CC -B PingClient.dpr        (or dcc64 for Win64)
//
//  Run:
//    ./PingClient                                       → h2c /ping
//    ./PingClient /methods/get                          → h2c /methods/get
//    ./PingClient http://127.0.0.1:9010/methods/get
//    ./PingClient https://127.0.0.1:9443/ping           → h2 over TLS
//    ./PingClient https://172.18.64.1:9443/info         → h2 over TLS (any host)
//
//  https URLs use the built-in convenience TLS mode: cert verification is
//  SKIPPED (self-signed OK). Do NOT use this for anything but local testing —
//  production clients should construct their own TTlsClientContext with a
//  proper CA store.
//
//  Expected output:
//    status = 200
//    header content-type = ...
//    body   = pong
// ============================================================================

{$APPTYPE CONSOLE}

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}

uses
  {$IF DEFINED(FPC)}SysUtils{$ELSE}System.SysUtils{$IFEND},
  Nghttp2.Client;

const
  DEFAULT_URL = 'http://127.0.0.1:9010/ping';

procedure PrintResponse(const AResp: TNghttp2Response);
var
  I: Integer;
  LBodyStr: string;
begin
  WriteLn('status = ', AResp.Status);
  WriteLn('headers (', Length(AResp.Headers), '):');
  for I := 0 to High(AResp.Headers) do
    WriteLn('  ', AResp.Headers[I].Name, ': ', AResp.Headers[I].Value);
  WriteLn('body   (', Length(AResp.Body), ' bytes):');

  // Print body as UTF-8 if it looks textual, else hex-dump the first 64 bytes.
  if Length(AResp.Body) > 0 then
  begin
    LBodyStr := TEncoding.UTF8.GetString(AResp.Body);
    WriteLn(LBodyStr);
  end
  else
    WriteLn('(empty)');
end;

var
  LURL:  string;
  LResp: TNghttp2Response;
begin
  if ParamCount >= 1 then
    LURL := ParamStr(1)
  else
    LURL := DEFAULT_URL;

  // Accept either a full URL or just a path (defaults to 127.0.0.1:9010).
  if (Length(LURL) > 0) and (LURL[1] = '/') then
    LURL := 'http://127.0.0.1:9010' + LURL;

  WriteLn('[PingClient] GET ', LURL);
  WriteLn;

  try
    LResp := Nghttp2Get(LURL);
    PrintResponse(LResp);
    ExitCode := Ord(not ((LResp.Status >= 200) and (LResp.Status < 400)));
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;

  if ParamCount = 0 then
  begin
    WriteLn;
    Write('Press ENTER to exit...');
    ReadLn;
  end;
end.
