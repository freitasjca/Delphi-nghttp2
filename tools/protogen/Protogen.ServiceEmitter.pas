unit Protogen.ServiceEmitter;

// =============================================================================
//  Protogen.ServiceEmitter — C3 of plans/horse-grpc-codegen.md.
//
//  Two emitters:
//
//  TInterfacesEmitter   generates <Prefix>.Interfaces.pas
//    - one [TGrpcService('pkg.Svc')] interface per service
//    - derives from IInvokable
//    - GUID deterministic from pkg.Svc via FNV-1a hash (GuidFromServiceName)
//    - one method per unary RPC; streaming RPCs are skipped (C5)
//
//  TServiceSkeletonEmitter   generates <Prefix>.Service.pas
//    - TXxxImpl = class(TInterfacedObject, IXxx) skeleton
//    - one stub per unary RPC, each raises ENotImplemented
//    - intended as a starting point for user code; the CLI driver (C4) will
//      emit .Service.new.pas instead of overwriting an existing .Service.pas
//
//  Dependency: Protogen.Emitter is used for TMessagesEmitter.PascalTypeName
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
  Protogen.Emitter;   // for TMessagesEmitter.PascalTypeName

type

  // --------------------------------------------------------------------------
  //  TInterfacesEmitter — emits <Prefix>.Interfaces.pas
  // --------------------------------------------------------------------------

  TInterfacesEmitter = class
  private
    FFile:       TProtoFileNode;
    FUnitPrefix: string;
    FOut:        TStrings;
    procedure W(const ALine: string = '');
    procedure EmitBoilerplate;
    procedure EmitUsesClause;
    procedure EmitTypeSection;
    procedure EmitService(ASvc: TProtoServiceNode);
  public
    procedure Emit(AFile: TProtoFileNode;
      const AUnitPrefix: string; ALines: TStrings);
    class function GuidFromServiceName(const AFullName: string): string;
    class function InterfaceName(const AServiceName: string): string;
    class function ImplClassName(const AServiceName: string): string;
  end;

  // --------------------------------------------------------------------------
  //  TServiceSkeletonEmitter — emits <Prefix>.Service.pas (once; never overwrite)
  // --------------------------------------------------------------------------

  TServiceSkeletonEmitter = class
  private
    FFile:       TProtoFileNode;
    FUnitPrefix: string;
    FOut:        TStrings;
    procedure W(const ALine: string = '');
    procedure EmitBoilerplate;
    procedure EmitUsesClause;
    procedure EmitTypeSection;
    procedure EmitService(ASvc: TProtoServiceNode);
    procedure EmitImplementation;
    procedure EmitServiceImpl(ASvc: TProtoServiceNode);
  public
    procedure Emit(AFile: TProtoFileNode;
      const AUnitPrefix: string; ALines: TStrings);
  end;

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

procedure TInterfacesEmitter.EmitUsesClause;
begin
  W;
  W('uses');
  W('  Nghttp2.Grpc.Attributes,');
  W('  ' + FUnitPrefix + '.Messages;');
end;

procedure TInterfacesEmitter.EmitService(ASvc: TProtoServiceNode);
var
  I: Integer;
  LRPC: TProtoRpcNode;
  LGuid, LFullName: string;
begin
  if FFile.PackageName <> '' then
    LFullName := FFile.PackageName + '.' + ASvc.Name
  else
    LFullName := ASvc.Name;
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
      '(const ARequest: ' + TMessagesEmitter.PascalTypeName(LRPC.RequestType) +
      '): ' + TMessagesEmitter.PascalTypeName(LRPC.ResponseType) + ';');
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
  const AUnitPrefix: string; ALines: TStrings);
begin
  FFile       := AFile;
  FUnitPrefix := AUnitPrefix;
  FOut        := ALines;
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
  W('  ' + FUnitPrefix + '.Messages;');
end;

procedure TServiceSkeletonEmitter.EmitService(ASvc: TProtoServiceNode);
var
  I: Integer;
  LRPC: TProtoRpcNode;
  LImplClass, LIfaceName: string;
begin
  LImplClass := TInterfacesEmitter.ImplClassName(ASvc.Name);
  LIfaceName := TInterfacesEmitter.InterfaceName(ASvc.Name);
  W;
  W('  ' + LImplClass + ' = class(TInterfacedObject, ' + LIfaceName + ')');
  W('  public');
  for I := 0 to ASvc.Rpcs.Count - 1 do
  begin
    LRPC := ASvc.Rpcs[I];
    if LRPC.RequestStream or LRPC.ResponseStream then
      Continue;
    W('    function ' + LRPC.Name +
      '(const ARequest: ' + TMessagesEmitter.PascalTypeName(LRPC.RequestType) +
      '): ' + TMessagesEmitter.PascalTypeName(LRPC.ResponseType) + ';');
  end;
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
    if LRPC.RequestStream or LRPC.ResponseStream then
      Continue;
    W;
    W('function ' + LImplClass + '.' + LRPC.Name +
      '(const ARequest: ' + TMessagesEmitter.PascalTypeName(LRPC.RequestType) +
      '): ' + TMessagesEmitter.PascalTypeName(LRPC.ResponseType) + ';');
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
  const AUnitPrefix: string; ALines: TStrings);
begin
  FFile       := AFile;
  FUnitPrefix := AUnitPrefix;
  FOut        := ALines;
  EmitBoilerplate;
  EmitUsesClause;
  EmitTypeSection;
  EmitImplementation;
end;

end.
