unit Sample.Inventory.ClientDemo;

// ============================================================================
//  Sample.Inventory.ClientDemo - the Pascal client half of the warehouse
//  sample (B2 client plan, GC7).
//
//  One routine, RunInventoryClient, calls the three RPCs of inventory.proto
//  through the GENERATED stubs in Sample.Inventory.Client and checks every
//  answer. Two programs use it:
//
//    Nghttp2InventoryServer   in-process, against its own server
//    Nghttp2InventoryClient   standalone, against any server - including the
//                             python grpcio one in inventory_server.py, which
//                             shares none of this library's code
//
//  The same checks pass against both servers, so this is the contract
//  exercised from both ends: a Pascal client against a Pascal server, and the
//  same client against an independent implementation.
//
//  OWNERSHIP, client side - the mirror image of the server's rule:
//
//    UNARY      The stub returns a NEW reply object. The caller frees it.
//               The request is never freed by the stub; the caller owns it.
//    STREAMING  The stub returns a stream object the caller frees. Each
//               Current belongs to the stream: freed by the next MoveNext and
//               when the stream is freed. Keep a copy of what you need.
//
//  Failure is an exception, not a flag: a call that does not end with
//  grpc-status 0 raises EGrpcClientError carrying the status and message.
//  "No such product" is NOT a failure here - the service answers it with
//  found = False, which is why GetProductResponse wraps the product.
// ============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

{ Runs every call against AHost:APort over h2c and prints one PASS or FAIL
  line per check. Returns the number of failed checks: 0 means the server
  honours inventory.proto as this sample expects. }
function RunInventoryClient(const AHost: string; APort: Word): Integer;

implementation

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Grpc.Client,
  Sample.Inventory.Messages,
  Sample.Inventory.Client;

var
  GFailed: Integer;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string);
begin
  if APassed then
    WriteLn('  PASS  ', AName)
  else
  begin
    WriteLn('  FAIL  ', AName, '  <- ', ADetail);
    Inc(GFailed);
  end;
end;

function Describe(AReply: TGetProductResponse): string;
begin
  if AReply = nil then
    Exit('no reply');
  if AReply.product = nil then
    Exit(Format('found=%s, no product', [BoolToStr(AReply.found, True)]));
  Result := Format('found=%s id=%d barcode=%s name=%s stock=%d',
    [BoolToStr(AReply.found, True), AReply.product.id, AReply.product.barcode,
     AReply.product.name, AReply.product.stock]);
end;

procedure UnaryCalls(AClient: TInventoryServiceClient);
var
  LReq:   TGetProductRequest;
  LReply: TGetProductResponse;
  LOpts:  TGrpcCallOptions;
begin
  LReq := TGetProductRequest.Create;
  try
    // A product that exists.
    LReq.barcode := 'ABC123';
    LReply := AClient.GetProduct(LReq);
    try
      Check('GetProduct(ABC123): found, the catalogue entry',
        LReply.found and (LReply.product <> nil) and (LReply.product.id = 1001)
        and (LReply.product.name = 'Mechanical keyboard')
        and (LReply.product.stock = 17), Describe(LReply));
    finally
      LReply.Free;
    end;

    // A product that does not: still a successful call.
    LReq.barcode := 'NOPE';
    LReply := AClient.GetProduct(LReq);
    try
      Check('GetProduct(NOPE): a successful call that says found=False',
        (not LReply.found) and (LReply.product = nil), Describe(LReply));
    finally
      LReply.Free;
    end;

    // The overload with call options: a deadline the server easily meets.
    LOpts := TGrpcCallOptions.Default;
    LOpts.DeadlineMS := 5000;
    LReq.barcode := 'XYZ002';
    LReply := AClient.GetProduct(LReq, LOpts);
    try
      Check('GetProduct(XYZ002) with a 5 s deadline',
        LReply.found and (LReply.product <> nil) and (LReply.product.stock = 42),
        Describe(LReply));
    finally
      LReply.Free;
    end;
  finally
    LReq.Free;
  end;
end;

procedure ShipmentCalls(AClient: TInventoryServiceClient);
var
  LReq:   TCreateShipmentRequest;
  LReply: TCreateShipmentResponse;
  LIds:   TArray<Int64>;
begin
  LReq := TCreateShipmentRequest.Create;
  try
    // A repeated field on the way OUT.
    SetLength(LIds, 3);
    LIds[0] := 1001;
    LIds[1] := 1002;
    LIds[2] := 1004;
    LReq.product_ids := LIds;
    LReply := AClient.CreateShipment(LReq);
    try
      Check('CreateShipment(3 lines): the server counted 3, numbered from 9001',
        (LReply.line_count = 3) and (LReply.shipment_id >= 9001),
        Format('line_count=%d shipment_id=%d', [LReply.line_count, LReply.shipment_id]));
    finally
      LReply.Free;
    end;

    // An empty repeated field: proto3 sends nothing at all for it.
    SetLength(LIds, 0);
    LReq.product_ids := LIds;
    LReply := AClient.CreateShipment(LReq);
    try
      Check('CreateShipment(no lines): line_count 0, still a shipment',
        (LReply.line_count = 0) and (LReply.shipment_id >= 9001),
        Format('line_count=%d shipment_id=%d', [LReply.line_count, LReply.shipment_id]));
    finally
      LReply.Free;
    end;
  finally
    LReq.Free;
  end;
end;

procedure StreamCalls(AClient: TInventoryServiceClient);
var
  LReq:    TGetProductRequest;
  LStream: TInventoryServiceWatchStockStream;
  LStocks: string;
  LSame:   Boolean;
begin
  LReq := TGetProductRequest.Create;
  try
    // ABC456 has stock 4: five updates counting down to 0, then a clean end.
    LReq.barcode := 'ABC456';
    LStocks := '';
    LSame   := True;
    LStream := AClient.WatchStock(LReq);
    try
      while LStream.MoveNext do
      begin
        if LStocks <> '' then
          LStocks := LStocks + ',';
        LStocks := LStocks + IntToStr(LStream.Current.stock);
        LSame := LSame and (LStream.Current.barcode = 'ABC456');
      end;
      Check('WatchStock(ABC456): five updates 4,3,2,1,0 for that product, clean end',
        (LStocks = '4,3,2,1,0') and LSame and (LStream.Received = 5),
        Format('stocks [%s], %d received', [LStocks, LStream.Received]));
    finally
      LStream.Free;
    end;

    // An unknown barcode: zero messages is a legal, clean answer.
    LReq.barcode := 'UNKNOWN';
    LStream := AClient.WatchStock(LReq);
    try
      Check('WatchStock(UNKNOWN): no update, clean end',
        (not LStream.MoveNext) and (LStream.Received = 0),
        Format('%d received', [LStream.Received]));
    finally
      LStream.Free;
    end;
  finally
    LReq.Free;
  end;
end;

function RunInventoryClient(const AHost: string; APort: Word): Integer;
var
  LChannel: TGrpcChannel;
  LClient:  TInventoryServiceClient;
begin
  GFailed := 0;
  WriteLn(Format('client: calling %s:%d', [AHost, APort]));
  LChannel := TGrpcChannel.Create(AHost, APort);   // h2c; connects lazily
  try
    LClient := TInventoryServiceClient.Create(LChannel);
    try
      { Each group is guarded on its own: a failure raised by one call is
        reported with its gRPC status and the next group still runs. }
      try
        UnaryCalls(LClient);
      except
        on E: Exception do
          Check('GetProduct calls', False, E.ClassName + ': ' + E.Message);
      end;
      try
        ShipmentCalls(LClient);
      except
        on E: Exception do
          Check('CreateShipment calls', False, E.ClassName + ': ' + E.Message);
      end;
      try
        StreamCalls(LClient);
      except
        on E: Exception do
          Check('WatchStock calls', False, E.ClassName + ': ' + E.Message);
      end;
    finally
      LClient.Free;
    end;
  finally
    LChannel.Free;
  end;
  if GFailed = 0 then
    WriteLn('client: every check passed')
  else
    WriteLn(Format('client: %d check(s) FAILED', [GFailed]));
  Result := GFailed;
end;

end.
