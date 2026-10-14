unit Sample.Inventory.Client;

// generated from proto -- ALWAYS regenerated, do not edit
// gRPC client stubs over Nghttp2.Grpc.Client (protogen --client).

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  Nghttp2.Grpc.Client,
  Sample.Inventory.Messages;

type

  // The server stream of /inventory.InventoryService/WatchStock.
  // MoveNext is False only on a clean end (grpc-status 0); any other end
  // raises EGrpcClientError, after the messages before it. Current is
  // owned by the stream: freed by the next MoveNext and by Free. Freeing
  // the stream before its end abandons the call.
  TInventoryServiceWatchStockStream = class
  private
    FStream: IGrpcClientStream;
    function GetCurrent: TProduct;
  public
    constructor Create(const AStream: IGrpcClientStream);
    function MoveNext: Boolean;
    function Received: Integer;
    property Current: TProduct read GetCurrent;
  end;

  // Calls inventory.InventoryService. The channel is BORROWED: it must outlive this object.
  // Requests are not freed; a unary reply and a stream belong to the caller.
  TInventoryServiceClient = class
  private
    FChannel: TGrpcChannel;
  public
    constructor Create(AChannel: TGrpcChannel);
    function GetProduct(ARequest: TGetProductRequest): TGetProductResponse; overload;
    function GetProduct(ARequest: TGetProductRequest;
      const AOptions: TGrpcCallOptions): TGetProductResponse; overload;
    function CreateShipment(ARequest: TCreateShipmentRequest): TCreateShipmentResponse; overload;
    function CreateShipment(ARequest: TCreateShipmentRequest;
      const AOptions: TGrpcCallOptions): TCreateShipmentResponse; overload;
    function WatchStock(ARequest: TGetProductRequest): TInventoryServiceWatchStockStream; overload;
    function WatchStock(ARequest: TGetProductRequest;
      const AOptions: TGrpcCallOptions): TInventoryServiceWatchStockStream; overload;
    property Channel: TGrpcChannel read FChannel;
  end;

implementation

constructor TInventoryServiceWatchStockStream.Create(const AStream: IGrpcClientStream);
begin
  inherited Create;
  FStream := AStream;
end;

function TInventoryServiceWatchStockStream.MoveNext: Boolean;
begin
  Result := FStream.MoveNext;
end;

function TInventoryServiceWatchStockStream.GetCurrent: TProduct;
begin
  Result := TProduct(FStream.Current);
end;

function TInventoryServiceWatchStockStream.Received: Integer;
begin
  Result := FStream.Received;
end;

constructor TInventoryServiceClient.Create(AChannel: TGrpcChannel);
begin
  inherited Create;
  FChannel := AChannel;
end;

function TInventoryServiceClient.GetProduct(ARequest: TGetProductRequest): TGetProductResponse;
begin
  Result := TGetProductResponse(FChannel.Unary('/inventory.InventoryService/GetProduct',
    ARequest, TGetProductResponse));
end;

function TInventoryServiceClient.GetProduct(ARequest: TGetProductRequest;
  const AOptions: TGrpcCallOptions): TGetProductResponse;
begin
  Result := TGetProductResponse(FChannel.Unary('/inventory.InventoryService/GetProduct',
    ARequest, TGetProductResponse, AOptions));
end;

function TInventoryServiceClient.CreateShipment(ARequest: TCreateShipmentRequest): TCreateShipmentResponse;
begin
  Result := TCreateShipmentResponse(FChannel.Unary('/inventory.InventoryService/CreateShipment',
    ARequest, TCreateShipmentResponse));
end;

function TInventoryServiceClient.CreateShipment(ARequest: TCreateShipmentRequest;
  const AOptions: TGrpcCallOptions): TCreateShipmentResponse;
begin
  Result := TCreateShipmentResponse(FChannel.Unary('/inventory.InventoryService/CreateShipment',
    ARequest, TCreateShipmentResponse, AOptions));
end;

function TInventoryServiceClient.WatchStock(ARequest: TGetProductRequest): TInventoryServiceWatchStockStream;
begin
  Result := TInventoryServiceWatchStockStream.Create(FChannel.ServerStream('/inventory.InventoryService/WatchStock',
    ARequest, TProduct));
end;

function TInventoryServiceClient.WatchStock(ARequest: TGetProductRequest;
  const AOptions: TGrpcCallOptions): TInventoryServiceWatchStockStream;
begin
  Result := TInventoryServiceWatchStockStream.Create(FChannel.ServerStream('/inventory.InventoryService/WatchStock',
    ARequest, TProduct, AOptions));
end;

end.
