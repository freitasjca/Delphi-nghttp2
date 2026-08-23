unit Sample.Echo.Messages;

// ============================================================================
//  Sample.Echo.Messages — proto3 message classes for the standalone gRPC
//  server sample. See echo.proto for the wire contract these mirror.
//
//  Three rules govern this unit, and all three are load-bearing:
//
//    1. {$M+} unit-wide, so the classes carry classic RTTI. Without it the
//       codec finds no properties and every field arrives empty.
//    2. Serialisable fields live in `published`. A private-storage or public
//       property carries no offset information, and TRttiProperty.SetValue
//       access-violates rather than failing cleanly.
//    3. On FPC, {$M+} alone is not enough — the {$RTTI EXPLICIT} directive
//       below is required or GetProperties returns zero. It must sit INSIDE
//       `interface`; FPC rejects it at unit scope.
//
//  Wire tags live in [TProtoMember(N)] and are what compatibility depends on.
//  Delphi property names may differ from the .proto field names where a
//  reserved word collides — the tag is the contract, not the identifier.
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
  TSayRequest = class
  private
    Fname: string;
  published
    [TProtoMember(1)]
    property name: string read Fname write Fname;
  end;

  [TGrpcMessage]
  TSayResponse = class
  private
    Ftext:   string;
    Flength: Integer;
  published
    { proto3 `string message = 1` — renamed to `text` here because `message`
      is a Delphi directive keyword. Same tag, same bytes on the wire. }
    [TProtoMember(1)]
    property text: string read Ftext write Ftext;

    [TProtoMember(2)]
    property length: Integer read Flength write Flength;
  end;

implementation

end.
