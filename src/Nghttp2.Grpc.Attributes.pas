unit Nghttp2.Grpc.Attributes;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Grpc.Attributes
//  M4c (2026-08-09): attribute types for the IInvokable-based ergonomic API.
//
//  `[TGrpcService('greeter.Greeter')]` marks an interface as a gRPC service.
//  `THorseGrpc.RegisterService<T>` reads this attribute to compose method
//  paths as `/<Name>/<MethodName>` per gRPC-over-HTTP/2 spec.
//
//  Naming: T-prefix, `Attribute` suffix. Delphi strips ONLY the `Attribute`
//  suffix, NOT the T prefix — so use `[TGrpcService('...')]` (not
//  `[GrpcService('...')]`). See delphi-standards §11 / delphi-pitfalls §14.
//
//  Extracted from horse-provider-nghttp2 on 2026-08-23. The layer never
//  depended on Horse — only its unit name did; the sole input here is an
//  INghttp2Stream. Any host that owns one can serve gRPC with it.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  // FPC 3.2.2: TCustomAttribute is in the Rtti unit (not SysUtils as on Delphi)
  SysUtils, Rtti
{$ELSE}
  System.SysUtils
{$IFEND}
  ;

type
  // Marks an interface as a gRPC service. AName is the full
  // <package>.<Service> path per the gRPC spec (e.g. 'greeter.Greeter').
  // Registry composes method paths as '/' + AName + '/' + MethodName.
  //
  // Example:
  //   [TGrpcService('greeter.Greeter')]
  //   IGreeter = interface(IInvokable)
  //     ['{...GUID...}']
  //     function Greet(const ARequest: TGreetRequest): TGreetResponse;
  //   end;
  //
  // (Comment uses // per line — Delphi block comments {} and (* *) don't
  // nest, and both would fire on the GUID literal above. See memory
  // entry feedback_delphi_brace_comment_nesting.)
  TGrpcServiceAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

implementation

constructor TGrpcServiceAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

end.
