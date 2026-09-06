unit Nghttp2.Protobuf.Any;

// ============================================================================
//  Nghttp2.Protobuf.Any — packing, unpacking and type resolution for
//  google.protobuf.Any.
//
//  ── Why this is a unit and not two methods on TProtobufAny ──
//
//  TProtobufAny is DATA: a string and a byte array, living in
//  Nghttp2.Protobuf.WellKnown, which depends on nothing but Nghttp2.Protobuf.
//  Packing needs TProtoSerializer, which lives one layer up in
//  Nghttp2.Protobuf.Rtti. Putting the behaviour on the class would drag the
//  whole RTTI serializer into a unit whose entire point is that it is cheap
//  to depend on.
//
//  ── What makes Any different from every other well-known type ──
//
//  Its payload is a SERIALISED MESSAGE and nothing in the bytes says which
//  one. `type_url` is the only evidence, and it arrives from the peer. So the
//  interesting part of this unit is not encoding - that is two fields - it is
//  refusing to decode the wrong thing:
//
//    * UnpackTo checks that type_url names the class you are unpacking INTO,
//      and raises otherwise. Without that check, a peer chooses which class
//      your bytes are interpreted as, which is the whole vulnerability.
//    * An unregistered type name is refused loudly. Returning nil would let a
//      caller treat "I do not know this type" as "the field was absent".
//    * Only the segment after the LAST '/' of type_url is used. The host part
//      is decoration and MUST NEVER be fetched — a type_url is not a URL to
//      retrieve, and treating it as one turns every decode into an outbound
//      request to a peer-controlled address.
//
//  ── Why a registry, and why you have to populate it ──
//
//  Unpacking a type known only at run time means turning 'greeter.GreetRequest'
//  into a Pascal class. Object Pascal has no way to enumerate every class in a
//  program, and RTTI knows a class as TGreetRequest — the proto package and
//  message name are simply not present anywhere in the compiled program. So
//  the mapping has to be stated once, at startup, exactly as gRPC services are
//  registered with TGrpcRegistry:
//
//      TProtoAnyRegistry.RegisterType('greeter.GreetRequest', TGreetRequest);
//
//  Pack can then be called without naming the type, and UnpackNew can resolve
//  an incoming one. Pack with an explicit name works with no registration at
//  all, for a program that only ever produces Any values.
//
//  ── Ownership ──
//
//  Pack COPIES the message into bytes; the caller keeps ownership of what it
//  passed. UnpackNew CREATES an instance and hands it over; the caller frees
//  it. UnpackTo writes into an instance the caller already owns.
// ============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections,
{$IFEND}
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti,
  Nghttp2.Protobuf.WellKnown;

const
  // The conventional prefix. protobuf treats everything before the last '/' as
  // opaque, so any prefix interoperates; this is the one everything else emits.
  PROTO_ANY_DEFAULT_PREFIX = 'type.googleapis.com/';

type
  EProtoAnyError = class(Exception);

  { Process-wide type-name <-> class mapping. Same shape as TGrpcRegistry and
    TProtobufRtti: class vars behind a critical section, lazily initialised,
    torn down in finalization.

    Registration is expected at startup, but the lock is real rather than a
    comment saying "register before serving": gRPC handlers run on arbitrary
    threads, and a lazily-registering program would otherwise corrupt the
    dictionaries rather than merely race. }
  TProtoAnyRegistry = class
  strict private
    class var FByName:  TDictionary<string, TClass>;
    { Keyed by Pointer, not TClass. A class reference as a generic KEY needs a
      default comparer for tkClassRef, which is not dependable across both
      compilers; Pointer is a pointer on both and needs no such faith. }
    class var FByClass: TDictionary<Pointer, string>;
    class var FLock:    TCriticalSection;
    class var FReady:   Boolean;
    class procedure LazyInit;
  public
    { Registers AClass under its proto full name, e.g.
      'google.protobuf.Duration' or 'greeter.GreetRequest' - package and
      message, NOT the Pascal class name and NOT a type_url.

      Re-registering the SAME pair is a no-op, so a unit that registers in its
      initialization section is safe to pull in twice. Registering a conflict -
      one name for two classes, or one class under two names - RAISES: it is
      always a mistake, and the failure it would otherwise cause is a decode
      into the wrong type, arbitrarily later. }
    class procedure RegisterType(const AFullName: string; AClass: TClass);
    class function  TryFullNameOf(AClass: TClass; out AFullName: string): Boolean;
    class function  TryClassOf(const AFullName: string; out AClass: TClass): Boolean;
    class function  Count: Integer;
    class procedure Clear;
    class procedure Shutdown;
  end;

  { Static helpers over TProtobufAny. }
  TProtoAny = class
  public
    { The significant part of a type_url: everything after the LAST '/'.
      A url with no '/' is taken whole - some implementations emit a bare
      name. Returns '' for '' or for a url ending in '/', and callers treat
      that as unusable rather than as a wildcard. }
    class function TypeNameOf(const ATypeUrl: string): string;

    { Builds a type_url from a proto full name using the conventional prefix. }
    class function TypeUrlFor(const AFullName: string): string;

    { Serialises AMsg into ATarget. The overload without a name resolves it
      through the registry and raises if AMsg's class was never registered -
      which is the honest outcome, since the alternative is writing an Any
      whose type_url is a guess. }
    class procedure Pack(ATarget: TProtobufAny; AMsg: TObject); overload;
    class procedure Pack(ATarget: TProtobufAny; AMsg: TObject;
      const AFullName: string); overload;

    { Does ATarget hold a message of AClass? Answers False rather than raising
      for an unregistered class, because "is it a T" is a question a caller
      asks precisely when it does not know. }
    class function IsType(ATarget: TProtobufAny; AClass: TClass): Boolean;

    { Decodes into AMsg, which the caller owns. RAISES unless type_url names
      AMsg's own class - the check that stops a peer choosing how your bytes
      are interpreted. }
    class procedure UnpackTo(ATarget: TProtobufAny; AMsg: TObject);

    { Resolves type_url through the registry, constructs an instance and
      decodes into it. The CALLER OWNS the result. Raises for an unknown type
      rather than returning nil. }
    class function UnpackNew(ATarget: TProtobufAny): TObject;
  end;

implementation

{ ── TProtoAnyRegistry ────────────────────────────────────────────────────── }

class procedure TProtoAnyRegistry.LazyInit;
begin
  if FReady then Exit;
  if FLock = nil then
    FLock := TCriticalSection.Create;
  FLock.Enter;
  try
    if not FReady then
    begin
      FByName  := TDictionary<string, TClass>.Create;
      FByClass := TDictionary<Pointer, string>.Create;
      FReady   := True;
    end;
  finally
    FLock.Leave;
  end;
end;

class procedure TProtoAnyRegistry.RegisterType(const AFullName: string;
  AClass: TClass);
var
  LExistingClass: TClass;
  LExistingName:  string;
begin
  if AClass = nil then
    raise EProtoAnyError.Create(
      'TProtoAnyRegistry.RegisterType: class is nil. A nil registration would '
      + 'resolve a type_url to nothing and fail at unpack time instead of '
      + 'here.');
  if Trim(AFullName) = '' then
    raise EProtoAnyError.CreateFmt(
      'TProtoAnyRegistry.RegisterType: %s was given an empty proto name. The '
      + 'name is the message''s full proto name - package and message, such '
      + 'as ''greeter.GreetRequest'' - not the Pascal class name.',
      [AClass.ClassName]);
  { A type_url where a name belongs is a common and silent mistake: it
    registers, and then never matches an incoming url because THAT one gets
    its prefix stripped and this one does not. }
  if Pos('/', AFullName) > 0 then
    raise EProtoAnyError.CreateFmt(
      'TProtoAnyRegistry.RegisterType: %s looks like a type_url, not a proto '
      + 'name. Register ''%s'' - the prefix is added when packing and stripped '
      + 'when unpacking.',
      [QuotedStr(AFullName), TProtoAny.TypeNameOf(AFullName)]);

  LazyInit;
  FLock.Enter;
  try
    if FByName.TryGetValue(AFullName, LExistingClass) then
    begin
      if LExistingClass = AClass then Exit;      // idempotent
      raise EProtoAnyError.CreateFmt(
        'TProtoAnyRegistry: %s is already registered to %s; refusing to '
        + 'rebind it to %s. Two classes under one proto name means an '
        + 'incoming Any decodes into whichever won the race.',
        [QuotedStr(AFullName), LExistingClass.ClassName, AClass.ClassName]);
    end;
    if FByClass.TryGetValue(Pointer(AClass), LExistingName) then
      raise EProtoAnyError.CreateFmt(
        'TProtoAnyRegistry: %s is already registered as %s; refusing to also '
        + 'register it as %s. One class with two proto names means Pack '
        + 'produces a different type_url depending on which registration is '
        + 'found.',
        [AClass.ClassName, QuotedStr(LExistingName), QuotedStr(AFullName)]);

    FByName.Add(AFullName, AClass);
    FByClass.Add(Pointer(AClass), AFullName);
  finally
    FLock.Leave;
  end;
end;

class function TProtoAnyRegistry.TryFullNameOf(AClass: TClass;
  out AFullName: string): Boolean;
begin
  AFullName := '';
  if AClass = nil then Exit(False);
  LazyInit;
  FLock.Enter;
  try
    Result := FByClass.TryGetValue(Pointer(AClass), AFullName);
  finally
    FLock.Leave;
  end;
end;

class function TProtoAnyRegistry.TryClassOf(const AFullName: string;
  out AClass: TClass): Boolean;
begin
  AClass := nil;
  if AFullName = '' then Exit(False);
  LazyInit;
  FLock.Enter;
  try
    Result := FByName.TryGetValue(AFullName, AClass);
  finally
    FLock.Leave;
  end;
end;

class function TProtoAnyRegistry.Count: Integer;
begin
  LazyInit;
  FLock.Enter;
  try
    Result := FByName.Count;
  finally
    FLock.Leave;
  end;
end;

{ Exists for tests, which need a known-empty registry to assert that an
  unregistered type is REFUSED. Not for production use: clearing while another
  thread unpacks turns a working decode into an "unknown type" error. }
class procedure TProtoAnyRegistry.Clear;
begin
  LazyInit;
  FLock.Enter;
  try
    FByName.Clear;
    FByClass.Clear;
  finally
    FLock.Leave;
  end;
end;

class procedure TProtoAnyRegistry.Shutdown;
begin
  if not FReady then
  begin
    FreeAndNil(FLock);
    Exit;
  end;
  FLock.Enter;
  try
    FreeAndNil(FByName);
    FreeAndNil(FByClass);
    FReady := False;
  finally
    FLock.Leave;
  end;
  FreeAndNil(FLock);
end;

{ ── TProtoAny ────────────────────────────────────────────────────────────── }

class function TProtoAny.TypeNameOf(const ATypeUrl: string): string;
var
  I: Integer;
begin
  Result := ATypeUrl;
  for I := Length(ATypeUrl) downto 1 do
    if ATypeUrl[I] = '/' then
    begin
      Result := Copy(ATypeUrl, I + 1, MaxInt);
      Break;
    end;
end;

class function TProtoAny.TypeUrlFor(const AFullName: string): string;
begin
  Result := PROTO_ANY_DEFAULT_PREFIX + AFullName;
end;

class procedure TProtoAny.Pack(ATarget: TProtobufAny; AMsg: TObject;
  const AFullName: string);
begin
  if ATarget = nil then
    raise EProtoAnyError.Create('TProtoAny.Pack: target Any is nil.');
  if AMsg = nil then
    raise EProtoAnyError.Create(
      'TProtoAny.Pack: message is nil. An Any holding nothing is not the same '
      + 'as an absent Any field - leave the field nil for that.');
  if Trim(AFullName) = '' then
    raise EProtoAnyError.CreateFmt(
      'TProtoAny.Pack: no proto name for %s.', [AMsg.ClassName]);

  { Serialise FIRST. If it raises, ATarget is left exactly as it was rather
    than carrying a type_url that describes bytes it does not hold. }
  ATarget.value    := TProtoSerializer.Serialize(AMsg);
  ATarget.type_url := TypeUrlFor(AFullName);
end;

class procedure TProtoAny.Pack(ATarget: TProtobufAny; AMsg: TObject);
var
  LName: string;
begin
  if AMsg = nil then
    raise EProtoAnyError.Create('TProtoAny.Pack: message is nil.');
  if not TProtoAnyRegistry.TryFullNameOf(AMsg.ClassType, LName) then
    raise EProtoAnyError.CreateFmt(
      '%s has no proto name. Either register it - '
      + 'TProtoAnyRegistry.RegisterType(''<package>.<Message>'', %s) - or '
      + 'call the Pack overload that takes the name. Guessing one from the '
      + 'Pascal class name would produce a type_url no other implementation '
      + 'recognises.',
      [AMsg.ClassName, AMsg.ClassName]);
  Pack(ATarget, AMsg, LName);
end;

class function TProtoAny.IsType(ATarget: TProtobufAny; AClass: TClass): Boolean;
var
  LName: string;
begin
  Result := False;
  if (ATarget = nil) or (AClass = nil) then Exit;
  if not TProtoAnyRegistry.TryFullNameOf(AClass, LName) then Exit;
  Result := (LName <> '') and (TypeNameOf(ATarget.type_url) = LName);
end;

class procedure TProtoAny.UnpackTo(ATarget: TProtobufAny; AMsg: TObject);
var
  LWant, LGot: string;
begin
  if ATarget = nil then
    raise EProtoAnyError.Create('TProtoAny.UnpackTo: Any is nil.');
  if AMsg = nil then
    raise EProtoAnyError.Create('TProtoAny.UnpackTo: destination is nil.');

  LGot := TypeNameOf(ATarget.type_url);
  if LGot = '' then
    raise EProtoAnyError.CreateFmt(
      'TProtoAny.UnpackTo: this Any carries no usable type name (type_url is '
      + '%s). Refusing to decode it as %s - the payload is only interpretable '
      + 'if something says what it is.',
      [QuotedStr(ATarget.type_url), AMsg.ClassName]);

  if not TProtoAnyRegistry.TryFullNameOf(AMsg.ClassType, LWant) then
    raise EProtoAnyError.CreateFmt(
      'TProtoAny.UnpackTo: %s has no proto name, so there is nothing to check '
      + '%s against. Register it with TProtoAnyRegistry.RegisterType.',
      [AMsg.ClassName, QuotedStr(LGot)]);

  { THE check. Without it the PEER decides which Pascal class its bytes are
    interpreted as, and a field-number collision between two unrelated
    messages decodes silently into the wrong one. }
  if LGot <> LWant then
    raise EProtoAnyError.CreateFmt(
      'TProtoAny.UnpackTo: this Any holds %s, not %s. Refusing to decode it '
      + 'as %s - the two are unrelated types that may share field numbers, so '
      + 'the decode would succeed and be wrong. Use IsType to test before '
      + 'unpacking, or UnpackNew to let the type_url choose.',
      [QuotedStr(LGot), QuotedStr(LWant), AMsg.ClassName]);

  TProtoSerializer.Deserialize(ATarget.value, AMsg);
end;

class function TProtoAny.UnpackNew(ATarget: TProtobufAny): TObject;
var
  LName: string;
  LClass: TClass;
begin
  if ATarget = nil then
    raise EProtoAnyError.Create('TProtoAny.UnpackNew: Any is nil.');

  LName := TypeNameOf(ATarget.type_url);
  if LName = '' then
    raise EProtoAnyError.CreateFmt(
      'TProtoAny.UnpackNew: this Any carries no usable type name (type_url is '
      + '%s).', [QuotedStr(ATarget.type_url)]);

  if not TProtoAnyRegistry.TryClassOf(LName, LClass) then
    raise EProtoAnyError.CreateFmt(
      'TProtoAny.UnpackNew: no class is registered for %s. Register it at '
      + 'startup with TProtoAnyRegistry.RegisterType(%s, T...). Returning nil '
      + 'instead would let a caller read "I do not know this type" as "the '
      + 'field was empty".',
      [QuotedStr(LName), QuotedStr(LName)]);

  { Parameterless Create, the same contract the codec uses when it allocates a
    submessage. Message classes declare no constructor, so this is TObject's -
    a message class that grew one would not have it run, and would be wrong
    here for exactly the reason it is wrong there. }
  Result := LClass.Create;
  try
    TProtoSerializer.Deserialize(ATarget.value, Result);
  except
    Result.Free;      // never hand back a half-decoded instance
    raise;
  end;
end;

initialization
  // FReady starts False by class-var default; LazyInit bootstraps on first use.

finalization
  TProtoAnyRegistry.Shutdown;

end.
