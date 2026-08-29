unit Protogen.Ast;

// ============================================================================
//  Protogen.Ast — the parsed shape of a .proto file.
//
//  C1 of plans/horse-grpc-codegen.md. Deliberately dumb: these are records of
//  what was written, not a semantic model. Name resolution, reserved-word
//  renaming and the decision of which Pascal type to emit all belong to C2,
//  because they are questions about the OUTPUT, and keeping them out of here
//  is what lets the parser be tested against the input alone.
//
//  Ownership: TProtoFileNode owns everything reachable from it. Free the file
//  node and the whole tree goes. Nothing here is reference-counted, so do not
//  hold a child past its parent.
// ============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, Generics.Collections;
{$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections;
{$IFEND}

type
  { The proto3 scalar set, complete — including the ones the RTTI serializer
    cannot express. The parser must RECOGNISE every scalar in order to reject
    the unsupported ones by name; a parser that only knew the supported subset
    would report "unknown type sint32", which names the wrong problem. }
  TProtoScalar = (
    psNone,        // not a scalar — TypeName refers to a message or enum
    psDouble, psFloat,
    psInt32, psInt64, psUInt32, psUInt64,
    psSInt32, psSInt64,                       // zigzag — unsupported downstream
    psFixed32, psFixed64, psSFixed32, psSFixed64,  // fixed  — unsupported
    psBool, psString, psBytes
  );

  TProtoLabel = (plNone, plRepeated, plOptional);

  TProtoFieldNode = class
  public
    Name:       string;
    TypeName:   string;        // exactly as written, e.g. 'int32' or 'Address'
    Scalar:     TProtoScalar;  // psNone when TypeName is a message/enum ref
    Number:     Integer;
    FieldLabel: TProtoLabel;
    Line:       Integer;
    Column:     Integer;
    function IsRepeated: Boolean;
  end;

  TProtoEnumValueNode = class
  public
    Name:   string;
    Number: Integer;
    Line:   Integer;
  end;

  TProtoEnumNode = class
  private
    FValues: TObjectList<TProtoEnumValueNode>;
  public
    Name: string;
    Line: Integer;
    constructor Create;
    destructor Destroy; override;
    property Values: TObjectList<TProtoEnumValueNode> read FValues;
  end;

  TProtoMessageNode = class
  private
    FFields: TObjectList<TProtoFieldNode>;
  public
    Name: string;
    Line: Integer;
    constructor Create;
    destructor Destroy; override;
    property Fields: TObjectList<TProtoFieldNode> read FFields;
    { Nil when no field carries this number. Used by the parser to reject
      duplicates, which protoc treats as an error and which would otherwise
      produce two Pascal properties with the same [TProtoMember]. }
    function FindByNumber(ANumber: Integer): TProtoFieldNode;
  end;

  TProtoRpcNode = class
  public
    Name:           string;
    RequestType:    string;
    ResponseType:   string;
    RequestStream:  Boolean;   // `stream` on the request  → client-streaming
    ResponseStream: Boolean;   // `stream` on the response → server-streaming
    Line:           Integer;
  end;

  TProtoServiceNode = class
  private
    FRpcs: TObjectList<TProtoRpcNode>;
  public
    Name: string;
    Line: Integer;
    constructor Create;
    destructor Destroy; override;
    property Rpcs: TObjectList<TProtoRpcNode> read FRpcs;
  end;

  TProtoFileNode = class
  private
    FMessages: TObjectList<TProtoMessageNode>;
    FEnums:    TObjectList<TProtoEnumNode>;
    FServices: TObjectList<TProtoServiceNode>;
    FImports:  TStringList;
  public
    Syntax:      string;   // always 'proto3' — the parser rejects anything else
    PackageName: string;
    constructor Create;
    destructor Destroy; override;
    property Messages: TObjectList<TProtoMessageNode> read FMessages;
    property Enums:    TObjectList<TProtoEnumNode>    read FEnums;
    property Services: TObjectList<TProtoServiceNode> read FServices;
    property Imports:  TStringList                    read FImports;
    function FindMessage(const AName: string): TProtoMessageNode;
    function FindEnum(const AName: string): TProtoEnumNode;
  end;

{ Maps a proto3 scalar keyword to its enum. psNone for anything else, which is
  how the parser tells a scalar from a message reference. }
function ScalarFromKeyword(const AWord: string): TProtoScalar;

{ The keyword for a scalar — used in diagnostics so a rejection quotes the
  user's own spelling back at them. }
function ScalarName(AScalar: TProtoScalar): string;

implementation

// ── TProtoFieldNode ─────────────────────────────────────────────────────────

function TProtoFieldNode.IsRepeated: Boolean;
begin
  Result := FieldLabel = plRepeated;
end;

// ── TProtoEnumNode ──────────────────────────────────────────────────────────

constructor TProtoEnumNode.Create;
begin
  inherited Create;
  FValues := TObjectList<TProtoEnumValueNode>.Create(True);
end;

destructor TProtoEnumNode.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

// ── TProtoMessageNode ───────────────────────────────────────────────────────

constructor TProtoMessageNode.Create;
begin
  inherited Create;
  FFields := TObjectList<TProtoFieldNode>.Create(True);
end;

destructor TProtoMessageNode.Destroy;
begin
  FFields.Free;
  inherited Destroy;
end;

function TProtoMessageNode.FindByNumber(ANumber: Integer): TProtoFieldNode;
var
  I: Integer;
begin
  for I := 0 to FFields.Count - 1 do
    if FFields[I].Number = ANumber then
      Exit(FFields[I]);
  Result := nil;
end;

// ── TProtoServiceNode ───────────────────────────────────────────────────────

constructor TProtoServiceNode.Create;
begin
  inherited Create;
  FRpcs := TObjectList<TProtoRpcNode>.Create(True);
end;

destructor TProtoServiceNode.Destroy;
begin
  FRpcs.Free;
  inherited Destroy;
end;

// ── TProtoFileNode ──────────────────────────────────────────────────────────

constructor TProtoFileNode.Create;
begin
  inherited Create;
  FMessages := TObjectList<TProtoMessageNode>.Create(True);
  FEnums    := TObjectList<TProtoEnumNode>.Create(True);
  FServices := TObjectList<TProtoServiceNode>.Create(True);
  FImports  := TStringList.Create;
end;

destructor TProtoFileNode.Destroy;
begin
  FImports.Free;
  FServices.Free;
  FEnums.Free;
  FMessages.Free;
  inherited Destroy;
end;

function TProtoFileNode.FindMessage(const AName: string): TProtoMessageNode;
var
  I: Integer;
begin
  for I := 0 to FMessages.Count - 1 do
    if SameText(FMessages[I].Name, AName) then
      Exit(FMessages[I]);
  Result := nil;
end;

function TProtoFileNode.FindEnum(const AName: string): TProtoEnumNode;
var
  I: Integer;
begin
  for I := 0 to FEnums.Count - 1 do
    if SameText(FEnums[I].Name, AName) then
      Exit(FEnums[I]);
  Result := nil;
end;

// ── Scalar keyword mapping ──────────────────────────────────────────────────

function ScalarFromKeyword(const AWord: string): TProtoScalar;
begin
  { Case-SENSITIVE on purpose: proto3 scalars are lowercase keywords, and
    `Int32` is a legal message name. Folding case here would silently turn a
    message reference into a scalar. }
  if      AWord = 'double'   then Result := psDouble
  else if AWord = 'float'    then Result := psFloat
  else if AWord = 'int32'    then Result := psInt32
  else if AWord = 'int64'    then Result := psInt64
  else if AWord = 'uint32'   then Result := psUInt32
  else if AWord = 'uint64'   then Result := psUInt64
  else if AWord = 'sint32'   then Result := psSInt32
  else if AWord = 'sint64'   then Result := psSInt64
  else if AWord = 'fixed32'  then Result := psFixed32
  else if AWord = 'fixed64'  then Result := psFixed64
  else if AWord = 'sfixed32' then Result := psSFixed32
  else if AWord = 'sfixed64' then Result := psSFixed64
  else if AWord = 'bool'     then Result := psBool
  else if AWord = 'string'   then Result := psString
  else if AWord = 'bytes'    then Result := psBytes
  else Result := psNone;
end;

function ScalarName(AScalar: TProtoScalar): string;
begin
  case AScalar of
    psDouble:   Result := 'double';
    psFloat:    Result := 'float';
    psInt32:    Result := 'int32';
    psInt64:    Result := 'int64';
    psUInt32:   Result := 'uint32';
    psUInt64:   Result := 'uint64';
    psSInt32:   Result := 'sint32';
    psSInt64:   Result := 'sint64';
    psFixed32:  Result := 'fixed32';
    psFixed64:  Result := 'fixed64';
    psSFixed32: Result := 'sfixed32';
    psSFixed64: Result := 'sfixed64';
    psBool:     Result := 'bool';
    psString:   Result := 'string';
    psBytes:    Result := 'bytes';
  else
    Result := '<not a scalar>';
  end;
end;

end.
