program Nghttp2InventoryClient;

// ============================================================================
//  The warehouse sample's client, on its own (B2 client plan, GC7).
//
//  Calls GetProduct, CreateShipment and WatchStock through the generated
//  stubs (Sample.Inventory.Client) against ANY server that implements
//  inventory.proto, and checks every answer:
//
//    Nghttp2InventoryClient [host] [port]        default 127.0.0.1 19010
//
//  Against Nghttp2InventoryServer it repeats that program's self-check from a
//  separate process. Against inventory_server.py - python grpcio, which shares
//  none of this library's code - it shows the client follows the protocol and
//  not merely its own server. The exit code is the number of failed checks.
//
//  Build (Delphi):
//    dcc64 -U..\..\src Nghttp2InventoryClient.dpr
//
//  Build (FPC trunk 3.3.1):
//    fpc -MDelphi -Fu../../src Nghttp2InventoryClient.dpr
//
//  The client never reaches TRttiMethod.Invoke, so it needs no libffi.
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
  Sample.Inventory.Messages in 'Sample.Inventory.Messages.pas',
  Sample.Inventory.Client in 'Sample.Inventory.Client.pas',
  Sample.Inventory.ClientDemo in 'Sample.Inventory.ClientDemo.pas';

const
  DEFAULT_PORT = 19010;

var
  GHost: string;
  GPort: Integer;

begin
  GHost := '127.0.0.1';
  GPort := DEFAULT_PORT;
  if ParamCount >= 1 then
    GHost := ParamStr(1);
  if ParamCount >= 2 then
    GPort := StrToIntDef(ParamStr(2), -1);
  if (GPort < 1) or (GPort > 65535) then
  begin
    WriteLn('usage: Nghttp2InventoryClient [host] [port]');
    ExitCode := 2;
    Exit;
  end;

  { The channel would raise on the first call anyway; failing here first says
    WHY in one line instead of three failed checks. }
  if not NghttpLoad then
  begin
    WriteLn('libnghttp2 not loaded: ', NghttpLoadError);
    ExitCode := 2;
    Exit;
  end;

  try
    ExitCode := RunInventoryClient(GHost, Word(GPort));
  except
    on E: Exception do
    begin
      WriteLn('client: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
