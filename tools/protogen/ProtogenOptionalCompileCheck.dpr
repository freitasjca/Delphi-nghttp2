program ProtogenOptionalCompileCheck;

// ============================================================================
//  C6b — make a COMPILER, and then the RTTI layer, read protogen's `optional`
//  output.
//
//  C6a did this for the greeter path. It generates from greeter.proto, which
//  has no optional fields, so PRESENCE-1 shipped with all 14 of its emitter
//  checks comparing TEXT TO TEXT — the exact hole C6a exists to close.
//
//  Two distinct things are under test here, and the second is the interesting
//  one:
//
//   1. The generated unit COMPILES. A setter declaration that does not match
//      its body, a Default(TEnum) the compiler rejects, a [TProtoHas] that
//      does not resolve — none of that is visible to a text comparison.
//
//   2. The generated class is ACCEPTED BY AttachHasBits at run time, and then
//      behaves. The emitter and the RTTI validator were written to the same
//      contract, by the same author, in the same session; they agree with each
//      other by construction. Nothing had put that agreement in front of a
//      compiler and a live TProtobufRtti. If the emitter ever produced a
//      writable has-bit, or named it something AttachHasBits does not pair to
//      the field, the first Serialize would raise — and every text gate would
//      still be green.
//
//  Usage — generate first, then compile against the output directory:
//
//    Protogen.exe -i optional.proto -o <out> --unit-prefix Sample.Opt
//    dcc64 -B -U"<out>;..\..\src" ProtogenOptionalCompileCheck.dpr
//
//  A successful COMPILE is half the result; the run is the other half.
//  ExitCode is the failure count.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti,
  Sample.Opt.Messages;      // <- generated. The point of the exercise.

var
  GPass: Integer = 0;
  GFail: Integer = 0;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    Inc(GPass);
    WriteLn('  PASS  ', AName);
  end
  else
  begin
    Inc(GFail);
    if ADetail <> '' then
      WriteLn('  FAIL  ', AName, '  <- ', ADetail)
    else
      WriteLn('  FAIL  ', AName);
  end;
end;

{ Does tag ATag appear as a field in AObj's encoding? Decoded with the real
  reader rather than scanned for a tag byte - a byte scan reports a false
  positive whenever a preceding field's VALUE happens to equal the tag byte. }
function EmitsTag(AObj: TObject; ATag: Integer): Boolean;
var
  LReader: TProtoReader;
  LTag: Integer;
  LWire: TProtoWireType;
begin
  Result := False;
  LReader := TProtoReader.Create(TProtoSerializer.Serialize(AObj));
  try
    while LReader.ReadTag(LTag, LWire) do
    begin
      if LTag = ATag then Exit(True);
      LReader.SkipField(LWire);
    end;
  finally
    LReader.Free;
  end;
end;

var
  GMsg, GDst: TOptMsg;
  GBytes: TBytes;
  GOk: Boolean;
  GErr: string;

begin
  WriteLn('ProtogenOptionalCompileCheck - C6b');
  WriteLn('The generated unit compiled. Now: does the RTTI layer accept it?');
  WriteLn;

  { THE assertion. If AttachHasBits rejects anything the emitter produced -
    a writable bit, a non-Boolean bit, a bit whose tag pairs to nothing - this
    raises, and it raises on the very first Serialize. Everything below is
    only reachable once the two layers have been shown to agree. }
  GOk  := False;
  GErr := '';
  GMsg := TOptMsg.Create;
  try
    try
      TProtoSerializer.Serialize(GMsg);
      GOk := True;
    except
      on E: Exception do
        GErr := E.ClassName + ': ' + E.Message;
    end;
  finally
    GMsg.Free;
  end;
  Check('generated class is ACCEPTED by AttachHasBits', GOk, GErr);
  if not GOk then
  begin
    WriteLn;
    WriteLn('Nothing further can be checked - the RTTI layer rejected the');
    WriteLn('emitter''s own output. That is a contract mismatch between');
    WriteLn('Protogen.Emitter and Nghttp2.Protobuf.Rtti.');
    ExitCode := GFail;
    Exit;
  end;

  // ── presence behaviour, on GENERATED code rather than a hand-written class
  GMsg := TOptMsg.Create;
  try
    Check('unset optional int32 is not emitted',    not EmitsTag(GMsg, 2));
    Check('unset optional string is not emitted',   not EmitsTag(GMsg, 3));
    Check('unset optional bool is not emitted',     not EmitsTag(GMsg, 4));
    Check('unset optional enum is not emitted',     not EmitsTag(GMsg, 5));
    Check('implicit-presence field IS emitted',     EmitsTag(GMsg, 1));
    Check('empty repeated field is not emitted',    not EmitsTag(GMsg, 6));
  finally
    GMsg.Free;
  end;

  { Set-to-default is the whole feature: each of these assigns the type's ZERO
    value, which without a has-bit is indistinguishable from never having been
    set. }
  GMsg := TOptMsg.Create;
  try
    GMsg.i32 := 0;
    GMsg.s   := '';
    GMsg.b   := False;
    GMsg.col := OPT_COLOUR_UNSET;
    Check('optional int32 set to 0 IS emitted',       EmitsTag(GMsg, 2));
    Check('optional string set to "" IS emitted',     EmitsTag(GMsg, 3));
    Check('optional bool set to False IS emitted',    EmitsTag(GMsg, 4));
    Check('optional enum set to 0 IS emitted',        EmitsTag(GMsg, 5));

    { The generated setter must have raised each bit. A generated property that
      wrote straight to its backing field would leave these False, and the
      emissions above would not have happened either. }
    Check('generated setter raised HasI32', GMsg.HasI32);
    Check('generated setter raised HasS',   GMsg.HasS);
    Check('generated setter raised HasB',   GMsg.HasB);
    Check('generated setter raised HasCol', GMsg.HasCol);
  finally
    GMsg.Free;
  end;

  // ── the generated Clear methods ──────────────────────────────────────────
  GMsg := TOptMsg.Create;
  try
    GMsg.i32 := 7;
    GMsg.col := OPT_COLOUR_BLUE;
    GMsg.ClearI32;
    GMsg.ClearCol;      // Default(TOptColour) — the enum path
    Check('generated ClearI32 lowered the bit',  not GMsg.HasI32);
    Check('generated ClearCol lowered the bit',  not GMsg.HasCol);
    Check('cleared int32 is not emitted',        not EmitsTag(GMsg, 2));
    Check('cleared enum is not emitted',         not EmitsTag(GMsg, 5));
  finally
    GMsg.Free;
  end;

  { Round trip through generated code. The bit must be raised by the SETTER
    that deserialisation reaches - nothing on the decode side knows about
    presence, so if the generated property wrote to its field directly this
    comes back absent. }
  GMsg := TOptMsg.Create;
  GDst := TOptMsg.Create;
  try
    GMsg.i32 := 0;
    GMsg.s   := '';
    GBytes := TProtoSerializer.Serialize(GMsg);
    TProtoSerializer.Deserialize(GBytes, GDst);
    Check('round-trip: set-to-zero int32 arrives PRESENT', GDst.HasI32);
    Check('round-trip: set-to-zero int32 value is 0',      GDst.i32 = 0);
    Check('round-trip: set-to-empty string arrives PRESENT', GDst.HasS);
    Check('round-trip: untouched bool arrives ABSENT',     not GDst.HasB);
  finally
    GMsg.Free;
    GDst.Free;
  end;

  WriteLn;
  WriteLn(Format('[ProtogenOptional] %d passed, %d failed', [GPass, GFail]));
  if GFail = 0 then
    WriteLn('[ProtogenOptional] Generated `optional` code compiles, registers '
            + 'and behaves.')
  else
    WriteLn('[ProtogenOptional] FAILURES.');
  ExitCode := GFail;
end.
