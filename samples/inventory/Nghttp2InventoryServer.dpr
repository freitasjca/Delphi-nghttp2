program Nghttp2InventoryServer;

// ============================================================================
//  A warehouse inventory service over gRPC, on this library alone.
//
//  Covers the three shapes a real service actually needs:
//
//    GetProduct      unary          one message in, one out
//    CreateShipment  unary          a repeated field on the way in
//    WatchStock      server stream  many messages out over one call
//
//  ---------------------------------------------------------------------
//  THE OWNERSHIP RULE IS NOT THE SAME FOR BOTH SHAPES. Read this once.
//  ---------------------------------------------------------------------
//
//    UNARY      The dispatcher creates BOTH the request and the response and
//               frees BOTH. Your handler fills the response in and frees
//               nothing. Freeing either one here is a double free.
//
//    STREAMING  IGrpcStreamWriter.Send TAKES OWNERSHIP of each message you
//               hand it, and frees it even if serialisation raises. So a
//               streaming handler allocates one message per iteration and
//               never frees it. Reusing a single instance across sends is a
//               use-after-free on the second Send.
//
//  The asymmetry is deliberate: a unary response has one owner for its whole
//  life, while a streamed message is handed off and forgotten immediately.
//
//  ---------------------------------------------------------------------
//  THE CLIENT HALF (B2 client plan, GC7)
//  ---------------------------------------------------------------------
//
//  Once the server is up, this program calls its own three RPCs from Pascal
//  through the GENERATED stubs (Sample.Inventory.Client, protogen --client)
//  and checks every answer - see Sample.Inventory.ClientDemo. The contract is
//  exercised from both ends in one process. Nghttp2InventoryClient.dpr runs
//  the same checks against any server, including inventory_server.py, an
//  independent python grpcio implementation.
//
//    Nghttp2InventoryServer               serve, self-check, then wait for
//                                         ENTER (drive it with grpcurl)
//    Nghttp2InventoryServer --self-test   serve, self-check, stop; the exit
//                                         code is the number of failed checks
//
//  Build (Delphi):
//    dcc64 -U..\..\src Nghttp2InventoryServer.dpr
//
//  Build (FPC trunk 3.3.1 - the gRPC layer needs trunk, see README):
//    fpc -MDelphi -dNGHTTP2_GRPC_NO_FFI -Fu../../src Nghttp2InventoryServer.dpr
//
//  NGHTTP2_GRPC_NO_FFI is safe here because this sample registers with
//  RegisterMethod / RegisterServerStream, which never reach
//  TRttiMethod.Invoke. Drop the define if you switch to RegisterService<T>.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  { cthreads MUST come first on Unix, before anything that might start a
    thread - the server does, on its first connection. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Types,
  Nghttp2.Server,
  Nghttp2.Grpc.Registry,
  Nghttp2.Grpc.Dispatcher,
  Sample.Inventory.Messages in 'Sample.Inventory.Messages.pas',
  Sample.Inventory.Client in 'Sample.Inventory.Client.pas',
  Sample.Inventory.ClientDemo in 'Sample.Inventory.ClientDemo.pas';

const
  PORT = 19010;

  { A linear catalogue rather than a dictionary, on purpose: it keeps the
    sample free of the Generics.Collections / System.Generics.Collections
    unit-name split, so the same source compiles on both compilers with no
    conditional. Real services put a database behind this. }
  CATALOGUE: array[0..3] of record
    Id: Int64; Barcode, Name: string; Stock: Integer;
  end = (
    (Id: 1001; Barcode: 'ABC123'; Name: 'Mechanical keyboard'; Stock: 17),
    (Id: 1002; Barcode: 'ABC456'; Name: 'Laser mouse';         Stock:  4),
    (Id: 1003; Barcode: 'XYZ001'; Name: '27-inch monitor';     Stock:  0),
    (Id: 1004; Barcode: 'XYZ002'; Name: 'USB-C dock';          Stock: 42)
  );

type
  { Handlers are `of object`, so they need an instance to hang on. This is
    where a real implementation would hold its database connection, its
    logging sink and its configuration. }
  TInventoryService = class
  private
    FShipmentSeq: Int64;
    function IndexOfBarcode(const ABarcode: string): Integer;
  public
    // unary
    procedure GetProduct(const ARequest, AResponse: TObject);
    procedure CreateShipment(const ARequest, AResponse: TObject);
    // server streaming
    procedure WatchStock(const ARequest: TObject;
      const AWriter: IGrpcStreamWriter);
  end;

var
  GService:  TInventoryService;
  GServer:   TNghttp2Server;
  GConfig:   TNghttp2Config;
  GSelfTest: Boolean;
  GFailed:   Integer;
  GArg:      Integer;

function TInventoryService.IndexOfBarcode(const ABarcode: string): Integer;
var
  I: Integer;
begin
  for I := Low(CATALOGUE) to High(CATALOGUE) do
    if SameText(CATALOGUE[I].Barcode, ABarcode) then
      Exit(I);
  Result := -1;
end;

{ UNARY. Both objects belong to the dispatcher - fill the response, free
  nothing. The nested TProduct is the one exception: it is a field of the
  response, so the response's destructor frees it, which is why
  TGetProductResponse has a destructor at all. }
procedure TInventoryService.GetProduct(const ARequest, AResponse: TObject);
var
  LReq:  TGetProductRequest;
  LResp: TGetProductResponse;
  LIdx:  Integer;
begin
  LReq  := TGetProductRequest(ARequest);
  LResp := TGetProductResponse(AResponse);

  LIdx := IndexOfBarcode(LReq.barcode);
  if LIdx < 0 then
  begin
    { Not an error. A barcode that does not exist is an ordinary answer, and
      reporting it through `found` keeps the RPC successful - a client
      distinguishes "no such product" from "the call failed" without having to
      inspect a status code. }
    LResp.found := False;
    WriteLn(Format('  GetProduct(%s) -> not found', [LReq.barcode]));
    Exit;
  end;

  LResp.found   := True;
  LResp.product := TProduct.Create;
  LResp.product.id      := CATALOGUE[LIdx].Id;
  LResp.product.barcode := CATALOGUE[LIdx].Barcode;
  LResp.product.name    := CATALOGUE[LIdx].Name;
  LResp.product.stock   := CATALOGUE[LIdx].Stock;

  WriteLn(Format('  GetProduct(%s) -> %s, stock %d',
    [LReq.barcode, CATALOGUE[LIdx].Name, CATALOGUE[LIdx].Stock]));
end;

{ UNARY, with a repeated field arriving. An empty product_ids is normal, not
  an error: proto3 cannot distinguish an absent repeated field from an empty
  one, so a shipment with no lines and a shipment whose lines were omitted
  look identical on the wire. Decide which one you mean at this layer. }
procedure TInventoryService.CreateShipment(const ARequest, AResponse: TObject);
var
  LReq:  TCreateShipmentRequest;
  LResp: TCreateShipmentResponse;
begin
  LReq  := TCreateShipmentRequest(ARequest);
  LResp := TCreateShipmentResponse(AResponse);

  Inc(FShipmentSeq);
  LResp.shipment_id := 9000 + FShipmentSeq;
  LResp.line_count  := Length(LReq.product_ids);

  WriteLn(Format('  CreateShipment(%d line(s)) -> shipment %d',
    [Length(LReq.product_ids), LResp.shipment_id]));
end;

{ SERVER STREAMING. One message allocated per iteration, handed to Send, and
  never freed here - Send owns it from that moment.

  IsConnected is checked every iteration rather than trusted once. A warehouse
  terminal that walks out of Wi-Fi range leaves this loop running against a
  dead stream, and without the check a long feed keeps serialising messages
  nobody will read. }
procedure TInventoryService.WatchStock(const ARequest: TObject;
  const AWriter: IGrpcStreamWriter);
var
  LReq: TGetProductRequest;
  LIdx, I, LStock: Integer;
  LMsg: TProduct;
begin
  LReq := TGetProductRequest(ARequest);
  LIdx := IndexOfBarcode(LReq.barcode);
  if LIdx < 0 then
  begin
    { Nothing sent, stream closed cleanly. A server-streaming RPC that yields
      zero messages is legal and is the honest answer here. }
    WriteLn(Format('  WatchStock(%s) -> unknown barcode, 0 updates',
      [LReq.barcode]));
    Exit;
  end;

  LStock := CATALOGUE[LIdx].Stock;
  WriteLn(Format('  WatchStock(%s) -> streaming from stock %d',
    [LReq.barcode, LStock]));

  for I := 1 to 5 do
  begin
    if not AWriter.IsConnected then
    begin
      WriteLn(Format('    peer went away after %d update(s)', [AWriter.Count]));
      Exit;
    end;

    LMsg := TProduct.Create;
    LMsg.id      := CATALOGUE[LIdx].Id;
    LMsg.barcode := CATALOGUE[LIdx].Barcode;
    LMsg.name    := CATALOGUE[LIdx].Name;
    LMsg.stock   := LStock;
    AWriter.Send(LMsg);          // Send frees LMsg - do NOT touch it after this

    if LStock > 0 then
      Dec(LStock);
    Sleep(400);                  // stand-in for "something changed the stock"
  end;

  WriteLn(Format('    sent %d update(s)', [AWriter.Count]));
end;

{ OnRequest is a PLAIN procedure type - not `of object`, not an anonymous
  method - because that is the only shape which compiles on FPC without
  FUNCTIONREFERENCES. It reaches the service instance through a global, which
  is what a trampoline like this is for. }
procedure HandleRequest(const AStream: INghttp2Stream);
begin
  { TryDispatch answers anything registered above and returns True. Whatever
    it does not recognise falls through to ordinary HTTP, so a gRPC server can
    still serve a health probe on the same port. }
  if TGrpcDispatcher.TryDispatch(AStream) then
    Exit;

  if AStream.Header[':path'] = '/healthz' then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain; charset=utf-8';
    AStream.Send(TEncoding.UTF8.GetBytes('ok'));
    Exit;
  end;

  AStream.StatusCode := 404;
  AStream.Header['content-type'] := 'text/plain; charset=utf-8';
  AStream.Send(TEncoding.UTF8.GetBytes('no such route'));
end;

begin
  GSelfTest := False;
  for GArg := 1 to ParamCount do
    if SameText(ParamStr(GArg), '--self-test') then
      GSelfTest := True;
  GFailed   := 0;
  GService := TInventoryService.Create;
  try
    { The path is `/<proto package>.<service>/<rpc>`, exactly as it appears in
      inventory.proto. Get it wrong and the call 404s at the dispatcher with
      no hint that a service exists - the path IS the routing key. }
    TGrpcRegistry.RegisterMethod('/inventory.InventoryService/GetProduct',
      TGetProductRequest, TGetProductResponse, GService.GetProduct);

    TGrpcRegistry.RegisterMethod('/inventory.InventoryService/CreateShipment',
      TCreateShipmentRequest, TCreateShipmentResponse, GService.CreateShipment);

    { AResponseClass is the type of EACH streamed message, not a wrapper. }
    TGrpcRegistry.RegisterServerStream('/inventory.InventoryService/WatchStock',
      TGetProductRequest, TProduct, GService.WatchStock);

    GServer := TNghttp2Server.Create;
    try
      GServer.OnRequest := HandleRequest;

      GConfig      := TNghttp2Config.Default;
      GConfig.Port := PORT;

      { Start loads libnghttp2 and raises if it is missing, then binds. }
      GServer.Start(GConfig);

      WriteLn('inventory service on h2c port ', PORT);
      WriteLn('  /inventory.InventoryService/GetProduct      unary');
      WriteLn('  /inventory.InventoryService/CreateShipment  unary');
      WriteLn('  /inventory.InventoryService/WatchStock      server streaming');
      WriteLn('  /healthz                                    plain HTTP/2');
      WriteLn;

      { The client half: the same three RPCs, called from Pascal through the
        generated stubs, against the server this process just started. The
        server log lines above and the client's PASS lines interleave, which
        is the point - both ends of every call are visible. }
      GFailed := RunInventoryClient('127.0.0.1', PORT);
      WriteLn;

      if not GSelfTest then
      begin
        WriteLn('Server still running - drive it with grpcurl too, see document.md.');
        WriteLn('ENTER to stop.');
        ReadLn;
      end;

      GServer.Stop;
    finally
      GServer.Free;
    end;
  finally
    { Order matters. The registry holds method pointers INTO GService, so it
      must be cleared before the instance those pointers target goes away. }
    TGrpcRegistry.Shutdown;
    GService.Free;
  end;
  ExitCode := GFailed;
end.
