unit Sample.Inventory.Messages;

// ============================================================================
//  Sample.Inventory.Messages - proto3 message classes for the warehouse
//  sample. Mirrors inventory.proto; that file is the contract, this one is
//  its Pascal shadow.
//
//  This is what `Protogen -i inventory.proto -o . --unit-prefix Sample.Inventory`
//  emits, kept in the repository so the sample builds without running the
//  generator first.
//
//  Three rules govern this unit, and all three are load-bearing:
//
//    1. {$M+} unit-wide, so the classes carry classic RTTI. Without it the
//       codec finds no properties and every field arrives empty - not an
//       error, just silently blank messages.
//    2. Serialisable fields live in `published`. A private-storage or public
//       property carries no offset information, and TRttiProperty.SetValue
//       access-violates rather than failing cleanly.
//    3. On FPC, {$M+} alone is not enough - the {$RTTI EXPLICIT} directive
//       below is required or GetProperties returns zero. It must sit INSIDE
//       `interface`; FPC rejects it at unit scope.
//
//  Wire tags live in [TProtoMember(N)] and are what compatibility depends on.
//  The Pascal property name may differ from the .proto field name where a
//  reserved word collides - the tag is the contract, not the identifier.
// ============================================================================

{$M+}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

uses
  Nghttp2.Protobuf;   // TGrpcMessageAttribute + TProtoMemberAttribute

type
  [TGrpcMessage]
  TProduct = class
  private
    Fid: Int64;
    Fbarcode: string;
    Fname: string;
    Fstock: Integer;
  published
    [TProtoMember(1)]
    property id: Int64 read Fid write Fid;
    [TProtoMember(2)]
    property barcode: string read Fbarcode write Fbarcode;
    [TProtoMember(3)]
    property name: string read Fname write Fname;
    [TProtoMember(4)]
    property stock: Integer read Fstock write Fstock;
  end;

  [TGrpcMessage]
  TGetProductRequest = class
  private
    Fbarcode: string;
  published
    [TProtoMember(1)]
    property barcode: string read Fbarcode write Fbarcode;
  end;

  { A message-typed field is an owned instance: nil means absent on the wire,
    and the destructor frees it. That is why `found` exists as a separate
    Boolean - an absent product and a product with every field at its default
    encode identically, so presence alone cannot carry "not found". }
  [TGrpcMessage]
  TGetProductResponse = class
  private
    Ffound: Boolean;
    Fproduct: TProduct;
  public
    destructor Destroy; override;
  published
    [TProtoMember(1)]
    property found: Boolean read Ffound write Ffound;
    [TProtoMember(2)]
    property product: TProduct read Fproduct write Fproduct;
  end;

  { `repeated int64` becomes TArray<Int64>. An empty array emits nothing at
    all, which is correct proto3: absent and empty are the same thing. }
  [TGrpcMessage]
  TCreateShipmentRequest = class
  private
    Fproduct_ids: TArray<Int64>;
  published
    [TProtoMember(1)]
    property product_ids: TArray<Int64> read Fproduct_ids write Fproduct_ids;
  end;

  [TGrpcMessage]
  TCreateShipmentResponse = class
  private
    Fshipment_id: Int64;
    Fline_count: Integer;
  published
    [TProtoMember(1)]
    property shipment_id: Int64 read Fshipment_id write Fshipment_id;
    [TProtoMember(2)]
    property line_count: Integer read Fline_count write Fline_count;
  end;

implementation

destructor TGetProductResponse.Destroy;
begin
  { The cast is not decoration. A proto field named `free` becomes a published
    property that shadows TObject.Free on that class, and `Fx.Free` then
    resolves to the property rather than the method - "Illegal expression",
    from generated code the user never wrote. Real: migrationcenter/v1 has
    `used` and `free` side by side. protogen emits the cast for the same
    reason. }
  TObject(Fproduct).Free;
  inherited Destroy;
end;

end.
