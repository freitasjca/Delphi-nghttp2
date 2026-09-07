unit Protogen.ServiceEmitter;

// =============================================================================
//  Protogen.ServiceEmitter — C3 and C5 of plans/horse-grpc-codegen.md.
//
//  Three emitters:
//
//  TInterfacesEmitter   generates <Prefix>.Interfaces.pas
//    - one [TGrpcService('pkg.Svc')] interface per service
//    - derives from IInvokable
//    - GUID deterministic from pkg.Svc via FNV-1a hash (GuidFromServiceName)
//    - one method per UNARY rpc only. Streaming rpcs are deliberately absent:
//      the dispatcher requires the shape function(const T): TResponse, and a
//      stream is a sequence rather than a return value. They are served
//      through TRegistrationEmitter instead, not through this interface.
//
//  TServiceSkeletonEmitter   generates <Prefix>.Service.pas
//    - TXxxImpl = class(TInterfacedObject, IXxx) skeleton
//    - one stub per rpc of EVERY shape, each raising ENotImplemented. Streaming
//      stubs take TObject message parameters, not the concrete class, because
//      the method pointer must match the registry's handler types exactly.
//    - intended as a starting point for user code; the CLI driver (C4) will
//      emit .Service.new.pas instead of overwriting an existing .Service.pas
//
//  TRegistrationEmitter   generates <Prefix>.Registration.pas   (C5)
//    - one Register<Svc>(AImpl) per service: RegisterService<T> for the unary
//      methods in one call, then an explicit RegisterServerStream /
//      RegisterClientStream / RegisterBidiStream per streaming rpc
//    - ALWAYS regenerated — it holds no user code and must track the .proto
//
//  Dependency: Protogen.Emitter is used for TMessagesEmitter.QualifiedTypeName
//  only — that is the one function shared between the two emitter families.
//  Both emitters stay in the same tools/protogen package and neither references
//  any Nghttp2 unit.
//
//  Dual-compilation: dcc64 (Delphi 10.4+) and fpc trunk 3.3.1 in {$MODE DELPHI}.
// =============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  Protogen.Ast,
  Protogen.FileSet,
  Protogen.Emitter;   // for TMessagesEmitter.QualifiedTypeName

type

  // --------------------------------------------------------------------------
  //  TInterfacesEmitter — emits <Prefix>.Interfaces.pas
  // --------------------------------------------------------------------------

  TInterfacesEmitter = class
  private
    FFile:       TProtoFileNode;
    FUnitPrefix: string;
    FOut:        TStrings;
    // IMPORT-1 / SVCWKT-1 — cross-file and well-known rpc types.
    // Both nil for a single-file generation, in which case TypeRef reduces to
    // the pre-IMPORT-1 behaviour plus the WKT fix.
    FFileSet:     TProtoFileSet;
    FEntry:       TProtoFileEntry;
    FExternUnits: TStringList;
    FNeedsWKT:    Boolean;
    procedure W(const ALine: string = '');
    function  TypeRef(const ATypeName: string): string;
    procedure ScanForExterns;
    procedure EmitBoilerplate;
    procedure EmitUsesClause;
    procedure EmitTypeSection;
    procedure EmitService(ASvc: TProtoServiceNode);
  public
    procedure Emit(AFile: TProtoFileNode;
      const AUnitPrefix: string; ALines: TStrings;
      AFileSet: TProtoFileSet = nil; AEntry: TProtoFileEntry = nil);
    constructor Create;
    destructor Destroy; override;
    class function GuidFromServiceName(const AFullName: string): string;
    class function InterfaceName(const AServiceName: string): string;
    class function ImplClassName(const AServiceName: string): string;
    // 'greeter.Greeter' — package-qualified when a package is declared.
    // Shared with TRegistrationEmitter so the [TGrpcService] attribute and the
    // registered path can never disagree about a service's name.
    class function FullServiceName(AFile: TProtoFileNode;
      ASvc: TProtoServiceNode): string;
    // '/greeter.Greeter/ListGreetings'
    class function RpcPath(AFile: TProtoFileNode; ASvc: TProtoServiceNode;
      ARpc: TProtoRpcNode): string;
  end;

  // The four RPC shapes. Unary is served through the IInvokable interface;
  // the other three cannot be (a stream is a sequence, not a return value)
  // and are registered explicitly against handler method pointers.
  TRpcShape = (rsUnary, rsServerStream, rsClientStream, rsBidiStream);

  // --------------------------------------------------------------------------
  //  TServiceSkeletonEmitter — emits <Prefix>.Service.pas (once; never overwrite)
  // --------------------------------------------------------------------------

  TServiceSkeletonEmitter = class
  private
    FFile:       TProtoFileNode;
    FUnitPrefix: string;
    FOut:        TStrings;
    // IMPORT-1 / SVCWKT-1 — cross-file and well-known rpc types.
    // Both nil for a single-file generation, in which case TypeRef reduces to
    // the pre-IMPORT-1 behaviour plus the WKT fix.
    FFileSet:     TProtoFileSet;
    FEntry:       TProtoFileEntry;
    FExternUnits: TStringList;
    FNeedsWKT:    Boolean;
    FHasStream:  Boolean;
    procedure W(const ALine: string = '');
    function  TypeRef(const ATypeName: string): string;
    procedure ScanForExterns;
    procedure ScanForStreaming;
    procedure EmitBoilerplate;
    procedure EmitUsesClause;
    procedure EmitTypeSection;
    procedure EmitService(ASvc: TProtoServiceNode);
    procedure EmitImplementation;
    procedure EmitServiceImpl(ASvc: TProtoServiceNode);
  public
    procedure Emit(AFile: TProtoFileNode;
      const AUnitPrefix: string; ALines: TStrings;
      AFileSet: TProtoFileSet = nil; AEntry: TProtoFileEntry = nil);
    constructor Create;
    destructor Destroy; override;
    // The method signature for one RPC, without the trailing semicolon.
    // AQualifier is '' for a class declaration or '<ImplClass>.' for the
    // implementing body — emitting both from one function is what stops the
    // two drifting apart, which would compile as an unimplemented method.
    class function MethodSignature(ARpc: TProtoRpcNode;
      const AQualifier: string; AFileSet: TProtoFileSet = nil;
      AEntry: TProtoFileEntry = nil): string;
  end;

  // --------------------------------------------------------------------------
  //  TRegistrationEmitter — emits <Prefix>.Registration.pas (always rewritten)
  //
  //  C5. Registration cannot live in <Prefix>.Service.pas: that file holds user
  //  code and is written once and never overwritten (§6.4), so generated
  //  registration placed there would go stale the moment the .proto changed.
  //  It cannot live in <Prefix>.Interfaces.pas either — it must name the
  //  concrete impl class to take method pointers for the streaming handlers,
  //  and that would invert the dependency, making the interface unit depend on
  //  its own implementation.
  //
  //  So it gets its own always-regenerated unit, which also gives the user a
  //  single call to make instead of one per RPC.
  // --------------------------------------------------------------------------

  TRegistrationEmitter = class
  private
    FFile:       TProtoFileNode;
    FUnitPrefix: string;
    FOut:        TStrings;
    // IMPORT-1 / SVCWKT-1 — cross-file and well-known rpc types.
    // Both nil for a single-file generation, in which case TypeRef reduces to
    // the pre-IMPORT-1 behaviour plus the WKT fix.
    FFileSet:     TProtoFileSet;
    FEntry:       TProtoFileEntry;
    FExternUnits: TStringList;
    FNeedsWKT:    Boolean;
    procedure W(const ALine: string = '');
    function  TypeRef(const ATypeName: string): string;
    procedure ScanForExterns;
    procedure EmitBoilerplate;
    procedure EmitUsesClause;
    procedure EmitInterfaceSection;
    procedure EmitImplementation;
    procedure EmitServiceRegistration(ASvc: TProtoServiceNode);
  public
    procedure Emit(AFile: TProtoFileNode;
      const AUnitPrefix: string; ALines: TStrings;
      AFileSet: TProtoFileSet = nil; AEntry: TProtoFileEntry = nil);
    constructor Create;
    destructor Destroy; override;
    // 'RegisterGreeter'
    class function RegisterProcName(const AServiceName: string): string;
  end;

// Classifies an rpc by which side carries `stream`. Used by every emitter, so
// the interface, skeleton and registration units can never disagree about what
// shape a given rpc is.
function RpcShapeOf(ARpc: TProtoRpcNode): TRpcShape;

implementation

// ── FNV-1a helpers ─────────────────────────────────────────────────────────

function FNV32(const S: string; ASeed: LongWord): LongWord;
const
  FNV_PRIME = LongWord($01000193);
var
  I: Integer;
begin
  Result := LongWord($811C9DC5) xor ASeed;
  for I := 1 to Length(S) do
    Result := (Result xor LongWord(Byte(Ord(S[I])))) * FNV_PRIME;
end;

function HexStr(V: LongWord; N: Integer): string;
const
  HEX = '0123456789ABCDEF';
var
  I: Integer;
begin
  SetLength(Result, N);
  for I := N downto 1 do
  begin
    Result[I] := HEX[(V and $F) + 1];
    V := V shr 4;
  end;
end;

// ── TInterfacesEmitter ──────────────────────────────────────────────────────

class function TInterfacesEmitter.GuidFromServiceName(
  const AFullName: string): string;
var
  H0, H1, H2, H3: LongWord;
begin
  H0 := FNV32(AFullName, 0);
  H1 := FNV32(AFullName, LongWord($B5B5B5B5));
  H2 := FNV32(AFullName, LongWord($CAFECAFE));
  H3 := FNV32(AFullName, LongWord($DEADBEEF));
  // Pack four 32-bit words into GUID layout:
  //   {H0-lo16(H1)-hi16(H1)-lo16(H2)-hi16(H2)H3}
  Result :=
    '{' +
    HexStr(H0, 8) + '-' +
    HexStr(H1 and $FFFF, 4) + '-' +
    HexStr(H1 shr 16, 4) + '-' +
    HexStr(H2 and $FFFF, 4) + '-' +
    HexStr(H2 shr 16, 4) + HexStr(H3, 8) +
    '}';
end;

class function TInterfacesEmitter.InterfaceName(
  const AServiceName: string): string;
begin
  Result := 'I' + AServiceName;
end;

class function TInterfacesEmitter.ImplClassName(
  const AServiceName: string): string;
begin
  Result := 'T' + AServiceName + 'ServiceImpl';
end;

procedure TInterfacesEmitter.W(const ALine: string = '');
begin
  FOut.Add(ALine);
end;

procedure TInterfacesEmitter.EmitBoilerplate;
begin
  W('unit ' + FUnitPrefix + '.Interfaces;');
  W;
  W('// generated from proto');
  W;
  W('{$M+}');
  W('{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}');
  W;
  W('interface');
  W;
  W('{$IF DEFINED(FPC)}');
  W('{$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}');
  W('{$ENDIF}');
end;

constructor TInterfacesEmitter.Create;
begin
  inherited Create;
  FExternUnits := TStringList.Create;
  FExternUnits.Duplicates := dupIgnore;
  FExternUnits.Sorted     := True;   // deterministic uses clause
end;

destructor TInterfacesEmitter.Destroy;
begin
  FExternUnits.Free;
  inherited Destroy;
end;

{ IMPORT-1 / SVCWKT-1. Name one proto type, and record what naming it costs.

  With no file set this is PascalTypeName plus the well-known-type mapping —
  which is itself a fix: an rpc taking google.protobuf.Empty used to emit
  `TGoogleProtobufEmpty`, a type nothing declares. }
function TInterfacesEmitter.TypeRef(const ATypeName: string): string;
var
  LExtern: string;
begin
  Result := TMessagesEmitter.QualifiedTypeName(FFileSet, FEntry, ATypeName,
    LExtern);
  // Unresolved: fall back to the plain mangled name, which is what this
  // emitter always used and is correct for the top-level rpc types that
  // dominate in practice.
  if Result = '' then
    Result := TMessagesEmitter.PascalTypeName(ATypeName);
  if (LExtern <> '') and (LExtern <> FUnitPrefix + '.Messages') then
    FExternUnits.Add(LExtern);
  if WellKnownPascalClass(ATypeName) <> '' then
    FNeedsWKT := True;
end;

{ Walk every rpc for its request and response types, purely for TypeRef's
  bookkeeping. Same reasoning as the messages emitter's ScanForExternUnits:
  reusing the naming function rather than re-deriving the rule is what makes
  the uses clause and the emitted names unable to disagree. }
procedure TInterfacesEmitter.ScanForExterns;
var
  I, J: Integer;
  LSvc: TProtoServiceNode;
begin
  FExternUnits.Clear;
  FNeedsWKT := False;
  for I := 0 to FFile.Services.Count - 1 do
  begin
    LSvc := FFile.Services[I];
    for J := 0 to LSvc.Rpcs.Count - 1 do
    begin
      TypeRef(LSvc.Rpcs[J].RequestType);
      TypeRef(LSvc.Rpcs[J].ResponseType);
    end;
  end;
end;

{ IMPORT-1. The trailing entries of a generated uses clause: the bundled
  well-known types when the schema names one, then every generated unit whose
  types this one references. The caller has already written the entries it
  always needs, ending each with a comma; whichever entry lands last here
  carries the semicolon.

  One routine for all four emitters, because a uses clause that is right in
  three of them and wrong in the fourth is exactly the kind of asymmetry that
  survives review. }
procedure WriteUsesTail(AOut: TStrings; ANeedsWKT: Boolean;
  AExtern: TStringList);
var
  I: Integer;
  LItems: TStringList;
begin
  LItems := TStringList.Create;
  try
    if ANeedsWKT then
    begin
      LItems.Add('Nghttp2.Protobuf');
      LItems.Add('Nghttp2.Protobuf.WellKnown');
    end;
    for I := 0 to AExtern.Count - 1 do
      LItems.Add(AExtern[I]);
    for I := 0 to LItems.Count - 1 do
      if I = LItems.Count - 1 then
        AOut.Add('  ' + LItems[I] + ';')
      else
        AOut.Add('  ' + LItems[I] + ',');
  finally
    LItems.Free;
  end;
end;

function HasUsesTail(ANeedsWKT: Boolean; AExtern: TStringList): Boolean;
begin
  Result := ANeedsWKT or (AExtern.Count > 0);
end;

procedure TInterfacesEmitter.EmitUsesClause;
begin
  W;
  W('uses');
  W('  Nghttp2.Grpc.Attributes,');
  if HasUsesTail(FNeedsWKT, FExternUnits) then
    W('  ' + FUnitPrefix + '.Messages,')
  else
    W('  ' + FUnitPrefix + '.Messages;');
  WriteUsesTail(FOut, FNeedsWKT, FExternUnits);
end;

{ QualifiedTypeName with the unresolved case filled in — shared by the class
  function MethodSignature, which has no instance TypeRef to call. }
function RpcTypeName(AFileSet: TProtoFileSet; AEntry: TProtoFileEntry;
  const ATypeName: string): string;
var
  LExtern: string;
begin
  Result := TMessagesEmitter.QualifiedTypeName(AFileSet, AEntry, ATypeName,
    LExtern);
  if Result = '' then
    Result := TMessagesEmitter.PascalTypeName(ATypeName);
end;

function RpcShapeOf(ARpc: TProtoRpcNode): TRpcShape;
begin
  if ARpc.RequestStream and ARpc.ResponseStream then
    Result := rsBidiStream
  else if ARpc.ResponseStream then
    Result := rsServerStream
  else if ARpc.RequestStream then
    Result := rsClientStream
  else
    Result := rsUnary;
end;

class function TInterfacesEmitter.FullServiceName(AFile: TProtoFileNode;
  ASvc: TProtoServiceNode): string;
begin
  if AFile.PackageName <> '' then
    Result := AFile.PackageName + '.' + ASvc.Name
  else
    Result := ASvc.Name;
end;

class function TInterfacesEmitter.RpcPath(AFile: TProtoFileNode;
  ASvc: TProtoServiceNode; ARpc: TProtoRpcNode): string;
begin
  Result := '/' + FullServiceName(AFile, ASvc) + '/' + ARpc.Name;
end;

procedure TInterfacesEmitter.EmitService(ASvc: TProtoServiceNode);
var
  I: Integer;
  LRPC: TProtoRpcNode;
  LGuid, LFullName: string;
begin
  LFullName := FullServiceName(FFile, ASvc);
  LGuid := GuidFromServiceName(LFullName);
  W;
  W('  [TGrpcService(''' + LFullName + ''')]');
  W('  ' + InterfaceName(ASvc.Name) + ' = interface(IInvokable)');
  W('    [''' + LGuid + ''']');
  for I := 0 to ASvc.Rpcs.Count - 1 do
  begin
    LRPC := ASvc.Rpcs[I];
    if LRPC.RequestStream or LRPC.ResponseStream then
      Continue; // streaming RPCs handled in C5
    W('    function ' + LRPC.Name +
      '(const ARequest: ' + TypeRef(LRPC.RequestType) +
      '): ' + TypeRef(LRPC.ResponseType) + ';');
  end;
  W('  end;');
end;

procedure TInterfacesEmitter.EmitTypeSection;
var
  I: Integer;
begin
  W;
  W('type');
  for I := 0 to FFile.Services.Count - 1 do
    EmitService(FFile.Services[I]);
end;

procedure TInterfacesEmitter.Emit(AFile: TProtoFileNode;
  const AUnitPrefix: string; ALines: TStrings;
  AFileSet: TProtoFileSet; AEntry: TProtoFileEntry);
begin
  FFile       := AFile;
  FUnitPrefix := AUnitPrefix;
  FOut        := ALines;
  FFileSet    := AFileSet;
  FEntry      := AEntry;
  // Must precede EmitUsesClause: the clause names the units, so the
  // set of referenced units has to be known before it is written.
  ScanForExterns;
  EmitBoilerplate;
  EmitUsesClause;
  EmitTypeSection;
  W;
  W('implementation');
  W;
  W('end.');
end;

// ── TServiceSkeletonEmitter ─────────────────────────────────────────────────

procedure TServiceSkeletonEmitter.W(const ALine: string = '');
begin
  FOut.Add(ALine);
end;

procedure TServiceSkeletonEmitter.EmitBoilerplate;
begin
  W('unit ' + FUnitPrefix + '.Service;');
  W;
  W('// generated from proto -- edit freely, never regenerated');
  W;
  W('{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}');
  W;
  W('interface');
end;

procedure TServiceSkeletonEmitter.ScanForStreaming;
var
  I, J: Integer;
begin
  FHasStream := False;
  for I := 0 to FFile.Services.Count - 1 do
    for J := 0 to FFile.Services[I].Rpcs.Count - 1 do
      if RpcShapeOf(FFile.Services[I].Rpcs[J]) <> rsUnary then
      begin
        FHasStream := True;
        Exit;
      end;
end;

constructor TServiceSkeletonEmitter.Create;
begin
  inherited Create;
  FExternUnits := TStringList.Create;
  FExternUnits.Duplicates := dupIgnore;
  FExternUnits.Sorted     := True;   // deterministic uses clause
end;

destructor TServiceSkeletonEmitter.Destroy;
begin
  FExternUnits.Free;
  inherited Destroy;
end;

{ IMPORT-1 / SVCWKT-1. Name one proto type, and record what naming it costs.

  With no file set this is PascalTypeName plus the well-known-type mapping —
  which is itself a fix: an rpc taking google.protobuf.Empty used to emit
  `TGoogleProtobufEmpty`, a type nothing declares. }
function TServiceSkeletonEmitter.TypeRef(const ATypeName: string): string;
var
  LExtern: string;
begin
  Result := TMessagesEmitter.QualifiedTypeName(FFileSet, FEntry, ATypeName,
    LExtern);
  // Unresolved: fall back to the plain mangled name, which is what this
  // emitter always used and is correct for the top-level rpc types that
  // dominate in practice.
  if Result = '' then
    Result := TMessagesEmitter.PascalTypeName(ATypeName);
  if (LExtern <> '') and (LExtern <> FUnitPrefix + '.Messages') then
    FExternUnits.Add(LExtern);
  if WellKnownPascalClass(ATypeName) <> '' then
    FNeedsWKT := True;
end;

{ Walk every rpc for its request and response types, purely for TypeRef's
  bookkeeping. Same reasoning as the messages emitter's ScanForExternUnits:
  reusing the naming function rather than re-deriving the rule is what makes
  the uses clause and the emitted names unable to disagree. }
procedure TServiceSkeletonEmitter.ScanForExterns;
var
  I, J: Integer;
  LSvc: TProtoServiceNode;
begin
  FExternUnits.Clear;
  FNeedsWKT := False;
  for I := 0 to FFile.Services.Count - 1 do
  begin
    LSvc := FFile.Services[I];
    for J := 0 to LSvc.Rpcs.Count - 1 do
    begin
      TypeRef(LSvc.Rpcs[J].RequestType);
      TypeRef(LSvc.Rpcs[J].ResponseType);
    end;
  end;
end;

procedure TServiceSkeletonEmitter.EmitUsesClause;
begin
  W;
  W('uses');
  W('{$IF DEFINED(FPC)}');
  W('  SysUtils,');
  W('{$ELSE}');
  W('  System.SysUtils,');
  W('{$IFEND}');
  W('  ' + FUnitPrefix + '.Interfaces,');
  if FHasStream then
  begin
    W('  ' + FUnitPrefix + '.Messages,');
    // IGrpcStreamReader / IGrpcStreamWriter. Only pulled in when the schema
    // actually streams, so a unary-only service keeps its previous uses list.
    if HasUsesTail(FNeedsWKT, FExternUnits) then
      W('  Nghttp2.Grpc.Registry,')
    else
      W('  Nghttp2.Grpc.Registry;');
  end
  else if HasUsesTail(FNeedsWKT, FExternUnits) then
    W('  ' + FUnitPrefix + '.Messages,')
  else
    W('  ' + FUnitPrefix + '.Messages;');
  WriteUsesTail(FOut, FNeedsWKT, FExternUnits);
end;

{ The streaming handler signatures are fixed by the registry's handler types
  (Nghttp2.Grpc.Registry): TGrpcServerStreamHandler, TGrpcClientStreamHandler
  and TGrpcBidiStreamHandler. Note the message parameters are typed TObject,
  NOT the concrete message class — the method pointer has to match the handler
  type exactly for the assignment in the registration unit to compile, and the
  dispatcher casts internally. The hand-written Sample.Greeter.Service.pas does
  the same. }
class function TServiceSkeletonEmitter.MethodSignature(ARpc: TProtoRpcNode;
  const AQualifier: string; AFileSet: TProtoFileSet;
  AEntry: TProtoFileEntry): string;
begin
  case RpcShapeOf(ARpc) of
    rsServerStream:
      Result := 'procedure ' + AQualifier + ARpc.Name +
        '(const ARequest: TObject; const AWriter: IGrpcStreamWriter)';
    rsClientStream:
      Result := 'procedure ' + AQualifier + ARpc.Name +
        '(const AReader: IGrpcStreamReader; const AResponse: TObject)';
    rsBidiStream:
      Result := 'procedure ' + AQualifier + ARpc.Name +
        '(const AReader: IGrpcStreamReader; const AWriter: IGrpcStreamWriter)';
  else
    Result := 'function ' + AQualifier + ARpc.Name +
      '(const ARequest: ' + RpcTypeName(AFileSet, AEntry, ARpc.RequestType) +
      '): ' + RpcTypeName(AFileSet, AEntry, ARpc.ResponseType);
  end;
end;

procedure TServiceSkeletonEmitter.EmitService(ASvc: TProtoServiceNode);
var
  I: Integer;
  LImplClass, LIfaceName: string;
begin
  LImplClass := TInterfacesEmitter.ImplClassName(ASvc.Name);
  LIfaceName := TInterfacesEmitter.InterfaceName(ASvc.Name);
  W;
  W('  ' + LImplClass + ' = class(TInterfacedObject, ' + LIfaceName + ')');
  W('  public');
  for I := 0 to ASvc.Rpcs.Count - 1 do
    W('    ' + MethodSignature(ASvc.Rpcs[I], '', FFileSet, FEntry) + ';');
  W('  end;');
end;

procedure TServiceSkeletonEmitter.EmitTypeSection;
var
  I: Integer;
begin
  W;
  W('type');
  for I := 0 to FFile.Services.Count - 1 do
    EmitService(FFile.Services[I]);
end;

procedure TServiceSkeletonEmitter.EmitServiceImpl(ASvc: TProtoServiceNode);
var
  I: Integer;
  LRPC: TProtoRpcNode;
  LImplClass: string;
begin
  LImplClass := TInterfacesEmitter.ImplClassName(ASvc.Name);
  for I := 0 to ASvc.Rpcs.Count - 1 do
  begin
    LRPC := ASvc.Rpcs[I];
    W;
    W(MethodSignature(LRPC, LImplClass + '.', FFileSet, FEntry) + ';');
    W('begin');
    W('  raise ENotImplemented.Create(''' + LImplClass + '.' + LRPC.Name + ''');');
    W('end;');
  end;
end;

procedure TServiceSkeletonEmitter.EmitImplementation;
var
  I: Integer;
begin
  W;
  W('implementation');
  for I := 0 to FFile.Services.Count - 1 do
    EmitServiceImpl(FFile.Services[I]);
  W;
  W('end.');
end;

procedure TServiceSkeletonEmitter.Emit(AFile: TProtoFileNode;
  const AUnitPrefix: string; ALines: TStrings;
  AFileSet: TProtoFileSet; AEntry: TProtoFileEntry);
begin
  FFile       := AFile;
  FUnitPrefix := AUnitPrefix;
  FOut        := ALines;
  FFileSet    := AFileSet;
  FEntry      := AEntry;
  ScanForStreaming;
  // Must precede EmitUsesClause: the clause names the units, so the
  // set of referenced units has to be known before it is written.
  ScanForExterns;
  EmitBoilerplate;
  EmitUsesClause;
  EmitTypeSection;
  EmitImplementation;
end;

// ── TRegistrationEmitter ─────────────────────────────────────────────────────

procedure TRegistrationEmitter.W(const ALine: string);
begin
  FOut.Add(ALine);
end;

class function TRegistrationEmitter.RegisterProcName(
  const AServiceName: string): string;
begin
  Result := 'Register' + AServiceName;
end;

procedure TRegistrationEmitter.EmitBoilerplate;
begin
  W('unit ' + FUnitPrefix + '.Registration;');
  W;
  W('// generated from proto -- ALWAYS regenerated, do not edit');
  W;
  W('{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}');
  W;
  W('interface');
end;

constructor TRegistrationEmitter.Create;
begin
  inherited Create;
  FExternUnits := TStringList.Create;
  FExternUnits.Duplicates := dupIgnore;
  FExternUnits.Sorted     := True;   // deterministic uses clause
end;

destructor TRegistrationEmitter.Destroy;
begin
  FExternUnits.Free;
  inherited Destroy;
end;

{ IMPORT-1 / SVCWKT-1. Name one proto type, and record what naming it costs.

  With no file set this is PascalTypeName plus the well-known-type mapping —
  which is itself a fix: an rpc taking google.protobuf.Empty used to emit
  `TGoogleProtobufEmpty`, a type nothing declares. }
function TRegistrationEmitter.TypeRef(const ATypeName: string): string;
var
  LExtern: string;
begin
  Result := TMessagesEmitter.QualifiedTypeName(FFileSet, FEntry, ATypeName,
    LExtern);
  // Unresolved: fall back to the plain mangled name, which is what this
  // emitter always used and is correct for the top-level rpc types that
  // dominate in practice.
  if Result = '' then
    Result := TMessagesEmitter.PascalTypeName(ATypeName);
  if (LExtern <> '') and (LExtern <> FUnitPrefix + '.Messages') then
    FExternUnits.Add(LExtern);
  if WellKnownPascalClass(ATypeName) <> '' then
    FNeedsWKT := True;
end;

{ Walk every rpc for its request and response types, purely for TypeRef's
  bookkeeping. Same reasoning as the messages emitter's ScanForExternUnits:
  reusing the naming function rather than re-deriving the rule is what makes
  the uses clause and the emitted names unable to disagree. }
procedure TRegistrationEmitter.ScanForExterns;
var
  I, J: Integer;
  LSvc: TProtoServiceNode;
begin
  FExternUnits.Clear;
  FNeedsWKT := False;
  for I := 0 to FFile.Services.Count - 1 do
  begin
    LSvc := FFile.Services[I];
    for J := 0 to LSvc.Rpcs.Count - 1 do
    begin
      TypeRef(LSvc.Rpcs[J].RequestType);
      TypeRef(LSvc.Rpcs[J].ResponseType);
    end;
  end;
end;

procedure TRegistrationEmitter.EmitUsesClause;
begin
  W;
  W('uses');
  W('  ' + FUnitPrefix + '.Interfaces,');
  W('  ' + FUnitPrefix + '.Messages,');
  W('  ' + FUnitPrefix + '.Service,');
  if HasUsesTail(FNeedsWKT, FExternUnits) then
    W('  Nghttp2.Grpc.Registry,')
  else
    W('  Nghttp2.Grpc.Registry;');
  WriteUsesTail(FOut, FNeedsWKT, FExternUnits);
end;

procedure TRegistrationEmitter.EmitInterfaceSection;
var
  I: Integer;
  LSvc: TProtoServiceNode;
begin
  W;
  for I := 0 to FFile.Services.Count - 1 do
  begin
    LSvc := FFile.Services[I];
    W('procedure ' + RegisterProcName(LSvc.Name) + '(const AImpl: ' +
      TInterfacesEmitter.ImplClassName(LSvc.Name) + ');');
  end;
end;

procedure TRegistrationEmitter.EmitServiceRegistration(ASvc: TProtoServiceNode);
var
  I: Integer;
  LRPC: TProtoRpcNode;
  LImplClass, LIface, LCall, LReq, LResp: string;
  LAnyUnary: Boolean;
begin
  LImplClass := TInterfacesEmitter.ImplClassName(ASvc.Name);
  LIface     := TInterfacesEmitter.InterfaceName(ASvc.Name);

  LAnyUnary := False;
  for I := 0 to ASvc.Rpcs.Count - 1 do
    if RpcShapeOf(ASvc.Rpcs[I]) = rsUnary then
      LAnyUnary := True;

  W;
  W('procedure ' + RegisterProcName(ASvc.Name) + '(const AImpl: ' +
    LImplClass + ');');
  W('begin');

  if LAnyUnary then
  begin
    W('  // Unary methods: registered in one call. RegisterService<T> walks the');
    W('  // interface via RTTI and derives each path from [TGrpcService].');
    W('  TGrpcRegistry.RegisterService<' + LIface + '>(AImpl);');
  end
  else
  begin
    W('  // No unary methods on this service, so there is nothing for');
    W('  // RegisterService<T> to reflect over.');
  end;

  for I := 0 to ASvc.Rpcs.Count - 1 do
  begin
    LRPC := ASvc.Rpcs[I];
    if RpcShapeOf(LRPC) = rsUnary then
      Continue;
    case RpcShapeOf(LRPC) of
      rsServerStream: LCall := 'RegisterServerStream';
      rsClientStream: LCall := 'RegisterClientStream';
    else
      LCall := 'RegisterBidiStream';
    end;
    LReq  := TypeRef(LRPC.RequestType);
    LResp := TypeRef(LRPC.ResponseType);
    W;
    W('  TGrpcRegistry.' + LCall + '(''' +
      TInterfacesEmitter.RpcPath(FFile, ASvc, LRPC) + ''',');
    W('    ' + LReq + ', ' + LResp + ', AImpl.' + LRPC.Name + ');');
  end;

  W('end;');
end;

procedure TRegistrationEmitter.EmitImplementation;
var
  I: Integer;
begin
  W;
  W('implementation');
  for I := 0 to FFile.Services.Count - 1 do
    EmitServiceRegistration(FFile.Services[I]);
  W;
  W('end.');
end;

procedure TRegistrationEmitter.Emit(AFile: TProtoFileNode;
  const AUnitPrefix: string; ALines: TStrings;
  AFileSet: TProtoFileSet; AEntry: TProtoFileEntry);
begin
  FFile       := AFile;
  FUnitPrefix := AUnitPrefix;
  FOut        := ALines;
  FFileSet    := AFileSet;
  FEntry      := AEntry;
  ALines.Clear;
  // Must precede EmitUsesClause: the clause names the units, so the
  // set of referenced units has to be known before it is written.
  ScanForExterns;
  EmitBoilerplate;
  EmitUsesClause;
  EmitInterfaceSection;
  EmitImplementation;
end;

end.
