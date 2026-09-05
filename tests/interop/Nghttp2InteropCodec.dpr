program Nghttp2InteropCodec;

// ============================================================================
//  §7.5 cross-language interop — the Pascal half.
//
//  Reads every <cases>/NNN.bin produced by interop_check.py, DECODES it with
//  our codec, RE-ENCODES it, and writes the result to <roundtrip>/NNN.bin.
//  Python then decodes that with the reference implementation and compares
//  field VALUES against what it originally sent.
//
//  This program deliberately makes no assertions of its own. Every judgement
//  belongs to the reference implementation — the entire point is that our
//  opinion of our own bytes is what has failed before. FIX-PROTO-UINT32-1
//  round-tripped perfectly through this very codec for years while putting
//  sign-extended garbage on the wire.
//
//  The message class below is HAND-WRITTEN rather than produced by protogen,
//  on purpose: if a case fails, the fault should be attributable to the codec
//  without also suspecting the generator. Generating it instead is a sensible
//  follow-up once this is green, and would test both layers at once.
//
//  Usage:  Nghttp2InteropCodec <cases-dir> <roundtrip-dir>
//  Exit:   0 on success, non-zero if any case could not be processed.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}
{$M+}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$IFEND}
  // TGrpcMessageAttribute and TProtoMemberAttribute live in Nghttp2.Protobuf,
  // NOT in Nghttp2.Grpc.Attributes — that unit holds only TGrpcServiceAttribute,
  // which is a service-level annotation and irrelevant to a codec test.
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti;

{$IF DEFINED(FPC)}
  // FPC needs the explicit extended-RTTI directive as well as the M+ above,
  // or GetDeclaredProperties comes back empty and every field silently
  // vanishes from the wire. Same rule as the sample message units.
  //
  // Line comments, not a brace comment: a directive's closing brace would
  // terminate a { } comment early and the remaining prose would be compiled.
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

type
  { Ordinals are sequential from zero, matching interop.proto's
    COLOUR_UNSET/RED/BLUE. A sparse proto enum has no Pascal representation,
    which is why the schema keeps them contiguous. }
  TColour = (COLOUR_UNSET, COLOUR_RED, COLOUR_BLUE);

  [TGrpcMessage]
  TScalars = class
  private
    Fi32:    Integer;
    Fi64:    Int64;
    Fu32:    UInt32;
    Fu64:    UInt64;
    Fb:      Boolean;
    Fs:      string;
    Ff32:    Single;
    Ff64:    Double;
    Fblob:   TBytes;
    Fcolour: TColour;
  published
    [TProtoMember(1)]  property i32:    Integer read Fi32    write Fi32;
    [TProtoMember(2)]  property i64:    Int64   read Fi64    write Fi64;
    [TProtoMember(3)]  property u32:    UInt32  read Fu32    write Fu32;
    [TProtoMember(4)]  property u64:    UInt64  read Fu64    write Fu64;
    [TProtoMember(5)]  property b:      Boolean read Fb      write Fb;
    [TProtoMember(6)]  property s:      string  read Fs      write Fs;
    [TProtoMember(7)]  property f32:    Single  read Ff32    write Ff32;
    [TProtoMember(8)]  property f64:    Double  read Ff64    write Ff64;
    [TProtoMember(9)]  property blob:   TBytes  read Fblob   write Fblob;
    [TProtoMember(10)] property colour: TColour read Fcolour write Fcolour;
  end;

function ReadAllBytes(const APath: string): TBytes;
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, LStream.Size);
    if LStream.Size > 0 then
      LStream.ReadBuffer(Result[0], LStream.Size);
  finally
    LStream.Free;
  end;
end;

procedure WriteAllBytes(const APath: string; const AData: TBytes);
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmCreate);
  try
    if Length(AData) > 0 then
      LStream.WriteBuffer(AData[0], Length(AData));
  finally
    LStream.Free;
  end;
end;

var
  GCasesDir, GOutDir, GName, GInPath, GOutPath: string;
  GFound: TSearchRec;
  GMsg: TScalars;
  GIn, GOut: TBytes;
  GCount, GFail: Integer;

begin
  if ParamCount < 2 then
  begin
    WriteLn('usage: Nghttp2InteropCodec <cases-dir> <roundtrip-dir>');
    ExitCode := 2;
    Exit;
  end;

  GCasesDir := IncludeTrailingPathDelimiter(ParamStr(1));
  GOutDir   := IncludeTrailingPathDelimiter(ParamStr(2));
  GCount    := 0;
  GFail     := 0;

  if FindFirst(GCasesDir + '*.bin', faAnyFile, GFound) <> 0 then
  begin
    WriteLn('no case files found in ', GCasesDir);
    ExitCode := 2;
    Exit;
  end;

  try
    repeat
      GName   := GFound.Name;
      GInPath := GCasesDir + GName;
      GOutPath := GOutDir + GName;

      GMsg := TScalars.Create;
      try
        try
          GIn := ReadAllBytes(GInPath);
          { Decode what the reference produced, then re-encode from our own
            in-memory state. Any value the decoder mis-reads, or the encoder
            mis-writes, shows up on the other side as a changed field. }
          TProtoSerializer.Deserialize(GIn, GMsg);
          GOut := TProtoSerializer.Serialize(GMsg);
          WriteAllBytes(GOutPath, GOut);
          Inc(GCount);
        except
          on E: Exception do
          begin
            { Reported, not swallowed: a case our codec REFUSES is a different
              finding from one it silently corrupts, and Python cannot tell
              them apart from a missing output file alone. }
            WriteLn('ERROR ', GName, ': ', E.ClassName, ': ', E.Message);
            Inc(GFail);
          end;
        end;
      finally
        GMsg.Free;
      end;
    until FindNext(GFound) <> 0;
  finally
    FindClose(GFound);
  end;

  WriteLn('round-tripped ', GCount, ' case(s), ', GFail, ' error(s)');
  if GFail > 0 then
    ExitCode := 1;
end.
