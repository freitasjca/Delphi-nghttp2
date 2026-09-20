program ProtoOptionalProbe;

// ============================================================================
//  ProtoOptionalProbe - what may a published property BE, on each compiler?
//
//  Written as a one-off feasibility probe for proto3 `optional` (see below),
//  and kept as a GATE, because the thing it measures is an assumption the
//  whole RTTI layer rests on and one that can change under you between
//  compiler versions. Every proto field must be a published property -
//  Nghttp2.Protobuf.Rtti filters on `LProp.Visibility <> mvPublished`
//  deliberately, since public and protected RTTI are unreliable across the two
//  compilers - so "what is publishable" decides what the codec can express.
//
//  It exits non-zero if any construct it expects to be discoverable is not.
//  A compiler upgrade that withdrew read-only published properties, or that
//  started refusing generic class properties, would break PRESENCE-1 and the
//  submessage path respectively; this stage says so in one line instead of
//  leaving it to be re-derived from a confusing downstream failure.
//
//  ROUND 1 RESULT (2026-09-06) - the record design is DEAD:
//
//      Delphi 36.0   published record property: ACCEPTED (tkRecord, attributes
//                    intact, GetValue works - both concrete and generic)
//      FPC 3.3.1     published record property: REJECTED, both forms
//                    "Error: This kind of property cannot be published"
//
//  That kills TProtoOptional<T>-as-a-record AND the "ship nine concrete
//  records" fallback, since the concrete form fails too. Recorded here rather
//  than deleted: without it someone re-proposes the obvious design, tries it
//  on Delphi alone, and gets a green run that means nothing.
//
//  Fields must be published properties - Nghttp2.Protobuf.Rtti filters on
//  `LProp.Visibility <> mvPublished` deliberately, because public/protected
//  RTTI is unreliable across the two compilers. So whatever carries presence
//  has to be a type BOTH compilers accept in a published section.
//
//  ROUND 2 - the three surviving candidates:
//
//    A  paired has-field, read/write
//         property a: Integer;  property hasA: Boolean read FhasA write FhasA;
//       Certain to compile. The hazard is desync: set the value, forget the
//       bit, and the field silently does not go out.
//
//    B  paired has-field, has-bit READ-ONLY and maintained by the value's
//       setter
//         property b: Integer read Fb write SetB;   // SetB sets FhasB
//         property hasB: Boolean read FhasB;        // no writer
//       Removes the desync hazard by construction - the bit is derived, not
//       user-managed. Costs a setter method per optional field. Open question
//       is whether a published READ-ONLY property is legal on FPC.
//
//    C  concrete class box, nil = absent
//         property c: TOptInt32Box read Fc write Fc;
//       Classes are certainly publishable - submessages already are - and the
//       codec ALREADY models absence as nil for submessages, with an
//       established "the message class frees them in its destructor" contract.
//       Costs a heap allocation per optional field, which this project tracks
//       (Nghttp2AllocBench exists for that reason).
//
//    D  generic class box - same as C but TProtoOptionalBox<T>.
//       Worth one line to learn whether FPC's published-property restriction
//       is about records specifically or about generics generally. That answer
//       shapes far more than this feature.
//
//  ROUND 3 - may a NON-CONTIGUOUS enum be a published property? (ENUMRTTI-1)
//
//  A Pascal enum with gaps in its values has no RTTI. FPC trunk says so out
//  loud - "This property will not be published" - and then omits the property,
//  so the codec never sees the field: it is neither encoded nor decoded and
//  nothing is raised. On the googleapis corpus that was 1405 schemas and 5633
//  properties, every one of which still reported COMPILED, because compiling
//  was never what was broken. ENUMRTTI-1 answers it by publishing Int32
//  instead, for EVERY compiler.
//
//  What is NOT known is whether dcc64 needed that. Three possible answers and
//  they do not mean the same thing:
//
//    drops it silently (like FPC)  the defect was equally bad on both, and
//                                  ENUMRTTI-1 is right as written.
//    refuses to COMPILE            then those 1405 schemas never built on
//                                  Delphi at all, and ENUMRTTI-1 is a BUILD
//                                  fix there, not merely a data-loss one.
//                                  Per the note below, that failure is the
//                                  answer - record it here, do not route
//                                  around it.
//    publishes it fine             the defect is FPC-only, and the surrogate
//                                  costs Delphi a well-typed property it did
//                                  not need. The generated .pas is ONE file
//                                  compiled by both, so the likely conclusion
//                                  is still "surrogate everywhere" - but then
//                                  chosen knowingly rather than by accident.
//
//  `dense` is the control and it GATES: a contiguous enum must be publishable
//  on both compilers, or the probe is measuring nothing. `gappy` REPORTS only
//  - on FPC its absence is the expected, already-measured result, so gating it
//  would fail a compiler that is behaving exactly as documented.
//
//  ROUND 3 RESULT (2026-09-20) - BOTH compilers drop it. Answered, settled:
//
//      FPC trunk 3.3.1        dense DISCOVERED, gappy ABSENT
//      Delphi 12 (Studio 23)  dense DISCOVERED, gappy ABSENT
//
//  Neither refuses the declaration - both COMPILE it and then omit the
//  property from RTTI. The first of the three possibilities above, and the
//  one with the widest blast radius: the silent field loss was never
//  FPC-specific, so every Delphi user of a sparse-enum schema was losing
//  fields on the wire too, with nothing to tell them.
//
//  That retires the open question against ENUMRTTI-1: the Int32 surrogate is
//  REQUIRED on both, not a lowest-common-denominator concession to FPC, and
//  it costs Delphi no well-typed property because Delphi was not publishing
//  one either.
//
//  NOT established: whether dcc64 emits any diagnostic. FPC says "This
//  property will not be published"; run-tests.bat does not surface compiler
//  output for a passing stage, so the Delphi side is unknown. If it is
//  silent, the defect was strictly harder to notice there.
//
//  Build (Windows):
//    dcc64 -CC -B -U"..\src" ProtoOptionalProbe.dpr
//
//  Build (FPC trunk) - the -Fu list is from Nghttp2ProtobufNegativeTests.dpr's
//  header; a short one silently resolves against the system 3.2.2 and fails
//  with `PPU Invalid Version 207 expecting 208`. Create the output dir first,
//  -FE/-FU do not:
//    mkdir -p .fpc-out/probe
//
//  Wired as stage 2c of build-codec-fpc.sh and of run-tests.bat.
//
//  A COMPILE FAILURE IS A RESULT, and here it is the MOST informative one: it
//  means a construct this codec depends on is no longer publishable. The line
//  number names which. Do not work around it - the four candidates are on
//  consecutive published lines precisely so the failure localises itself.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}
{$M+}

uses
{$IF DEFINED(FPC)}
  SysUtils, TypInfo, Rtti,
{$ELSE}
  System.SysUtils, System.TypInfo, System.Rtti,
{$IFEND}
  Nghttp2.Protobuf;          // TGrpcMessageAttribute, TProtoMemberAttribute

{$IF DEFINED(FPC)}
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$ENDIF}

type
  { Marks a Boolean as the has-bit for the proto field with this tag. Declared
    locally: if the paired design wins, this graduates into Nghttp2.Protobuf. }
  TProbeHasAttribute = class(TCustomAttribute)
  private
    FTag: Integer;
  public
    constructor Create(ATag: Integer);
    property Tag: Integer read FTag;
  end;

  { Candidate C - concrete class box. nil means absent. }
  TOptInt32Box = class
  private
    FValue: Integer;
  published
    property Value: Integer read FValue write FValue;
  end;

  { Candidate D - generic class box. }
  TProtoOptionalBox<T> = class
  private
    FValue: T;
  public
    property Value: T read FValue write FValue;
  end;

  { ROUND 3. Contiguous from zero - the shape every ordinary proto enum has,
    and the control: if THIS is not discovered, the compiler has withdrawn
    published enums entirely and nothing below it means anything. }
  TProbeDenseEnum = (pdeZero = 0, pdeOne = 1, pdeTwo = 2);

  { Gaps. The shape googleapis produces constantly - 0,1,2,13,14 and
    0,100,150,200 - and the one FPC will not publish. Values spelled out
    rather than left implicit, because it is the VALUES that decide this. }
  TProbeGappyEnum = (pgaZero = 0, pgaFive = 5);

  [TGrpcMessage]
  TProbeEnumMsg = class
  private
    Fdense: TProbeDenseEnum;
    Fgappy: TProbeGappyEnum;
  published
    { Consecutive on purpose, as with the four candidates above: if a compiler
      refuses one, the error names the line and localises itself. }
    [TProtoMember(1)] property dense: TProbeDenseEnum read Fdense write Fdense;
    [TProtoMember(2)] property gappy: TProbeGappyEnum read Fgappy write Fgappy;
  end;

  [TGrpcMessage]
  TProbeMsg = class
  private
    Fplain: Integer;
    Fa:     Integer;
    FhasA:  Boolean;
    Fb:     Integer;
    FhasB:  Boolean;
    Fc:     TOptInt32Box;
    Fd:     TProtoOptionalBox<Integer>;
    procedure SetB(const AValue: Integer);
  public
    destructor Destroy; override;
  published
    { control - if this is not discovered the probe itself is broken }
    [TProtoMember(1)] property plain: Integer read Fplain write Fplain;

    // A - paired, both writable
    [TProtoMember(2)] property a:    Integer read Fa    write Fa;
    [TProbeHas(2)]    property hasA: Boolean read FhasA write FhasA;

    // B - paired, has-bit read-only and maintained by SetB
    [TProtoMember(3)] property b:    Integer read Fb write SetB;
    [TProbeHas(3)]    property hasB: Boolean read FhasB;

    // C - concrete class box
    [TProtoMember(4)] property c: TOptInt32Box read Fc write Fc;

    // D - generic class box
    [TProtoMember(5)] property d: TProtoOptionalBox<Integer> read Fd write Fd;
  end;

constructor TProbeHasAttribute.Create(ATag: Integer);
begin
  inherited Create;
  FTag := ATag;
end;

procedure TProbeMsg.SetB(const AValue: Integer);
begin
  Fb    := AValue;
  FhasB := True;      // the whole point of candidate B
end;

destructor TProbeMsg.Destroy;
begin
  { Same ownership contract the codec already uses for submessages. }
  Fc.Free;
  Fd.Free;
  inherited;
end;

var
  GCtx:   TRttiContext;
  GType:  TRttiType;
  GProp:  TRttiProperty;
  GAttr:  TCustomAttribute;
  GTag:   Integer;
  GRole:  string;
  GKind:  string;
  GSeen:  Integer;
  GObj:   TProbeMsg;
  GVal:   TValue;
  { ROUND 3 }
  GEnumType:  TRttiType;
  GEnumObj:   TProbeEnumMsg;
  GDenseSeen: Boolean;
  GGappySeen: Boolean;

begin
  WriteLn('ProtoOptionalProbe round 2 - paired has-field vs class box');
  WriteLn('(round 1 settled it: published RECORDS are Delphi-only)');
  WriteLn;

  GObj := TProbeMsg.Create;
  { Constructed although round 3 only inspects the TYPE. A class that is never
    instantiated can be stripped by smart linking, and GetType would then
    return nil - which reads as "no RTTI for a gappy enum", the exact false
    negative this probe exists to avoid. Do not delete it as unused. }
  GEnumObj := TProbeEnumMsg.Create;
  GCtx     := TRttiContext.Create;
  GSeen    := 0;
  try
    GType := GCtx.GetType(TProbeMsg);
    if GType = nil then
    begin
      WriteLn('FAIL: no RTTI for TProbeMsg at all.');
      ExitCode := 2;
      Exit;
    end;

    for GProp in GType.GetProperties do
    begin
      { The same filter real discovery applies. A property the codec would skip
        must show as skipped here, or the probe flatters the design. }
      if GProp.Visibility <> mvPublished then
      begin
        WriteLn(Format('  %-6s NOT PUBLISHED - would be skipped', [GProp.Name]));
        Continue;
      end;

      GTag  := -1;
      GRole := '';
      for GAttr in GProp.GetAttributes do
      begin
        if GAttr is TProtoMemberAttribute then
        begin
          GTag  := TProtoMemberAttribute(GAttr).Tag;
          GRole := 'field';
        end
        else if GAttr is TProbeHasAttribute then
        begin
          GTag  := TProbeHasAttribute(GAttr).Tag;
          GRole := 'has-bit';
        end;
      end;

      { A nil PropertyType is a real outcome, not a crash to dodge: RTTI
        knowing the property exists but carrying no type for it is the
        "compiles but undiscoverable" case. }
      if GProp.PropertyType = nil then
        GKind := '<nil PropertyType>'
      else
        GKind := GetEnumName(TypeInfo(TTypeKind),
                             Ord(GProp.PropertyType.TypeKind));

      if GRole = '' then
      begin
        WriteLn(Format('  %-6s kind=%-18s (no attribute)', [GProp.Name, GKind]));
        Continue;
      end;

      Inc(GSeen);
      WriteLn(Format('  %-6s kind=%-18s %-7s tag=%d  IsReadable=%s IsWritable=%s',
        [GProp.Name, GKind, GRole, GTag,
         BoolToStr(GProp.IsReadable, True),
         BoolToStr(GProp.IsWritable, True)]));

      try
        GVal := GProp.GetValue(GObj);
        WriteLn(Format('         GetValue ok (IsEmpty=%s)',
                       [BoolToStr(GVal.IsEmpty, True)]));
      except
        on E: Exception do
          WriteLn('         GetValue RAISED: ', E.ClassName, ': ', E.Message);
      end;
    end;

    WriteLn;
    WriteLn(Format('attributed published properties discovered: %d of 7', [GSeen]));
    WriteLn;
    WriteLn('7 = plain(1) + a(2) + hasA(2) + b(3) + hasB(3) + c(4) + d(5).');
    WriteLn('Anything missing is a candidate THIS compiler refused. Only a');
    WriteLn('candidate that appears on BOTH compilers is available here.');
    WriteLn;
    WriteLn('Watch hasB in particular: it is read-only (IsWritable=False), and');
    WriteLn('whether a published read-only property survives is what decides');
    WriteLn('candidate B - the design where the has-bit cannot be desynced.');
    if GSeen < 7 then
      ExitCode := 1;

    { ── ROUND 3 · ENUMRTTI-1 ─────────────────────────────────────────────
      Reaching this line is itself half the result: if a compiler refuses a
      published non-contiguous enum outright, the unit does not build and the
      answer arrives as a compile error naming the `gappy` line. }
    WriteLn;
    WriteLn('-- round 3: may a NON-CONTIGUOUS enum be published? (ENUMRTTI-1)');
    GDenseSeen := False;
    GGappySeen := False;

    GEnumType := GCtx.GetType(TProbeEnumMsg);
    if GEnumType = nil then
    begin
      WriteLn('  FAIL: no RTTI for TProbeEnumMsg at all.');
      ExitCode := 2;
    end
    else
    begin
      for GProp in GEnumType.GetProperties do
      begin
        if GProp.Visibility <> mvPublished then Continue;
        if GProp.PropertyType = nil then
          GKind := '<nil PropertyType>'
        else
          GKind := GetEnumName(TypeInfo(TTypeKind),
                               Ord(GProp.PropertyType.TypeKind));
        WriteLn(Format('  %-6s kind=%-18s DISCOVERED', [GProp.Name, GKind]));
        if SameText(GProp.Name, 'dense') then GDenseSeen := True;
        if SameText(GProp.Name, 'gappy') then GGappySeen := True;
      end;

      if not GDenseSeen then WriteLn('  dense  ABSENT');
      if not GGappySeen then WriteLn('  gappy  ABSENT');

      WriteLn;
      if GGappySeen then
      begin
        WriteLn('  VERDICT: this compiler DOES publish a non-contiguous enum.');
        WriteLn('  So the silent field loss ENUMRTTI-1 fixes is NOT present here,');
        WriteLn('  and the Int32 surrogate costs this compiler a well-typed');
        WriteLn('  property it did not need. That is a known price, not a bug:');
        WriteLn('  one generated .pas is compiled by BOTH, so the surrogate has');
        WriteLn('  to be applied on the lowest common denominator.');
      end
      else
      begin
        WriteLn('  VERDICT: this compiler does NOT publish a non-contiguous enum.');
        WriteLn('  A field typed as one is absent from RTTI, so the codec never');
        WriteLn('  sees it - neither encoded nor decoded, nothing raised. The');
        WriteLn('  ENUMRTTI-1 Int32 surrogate is REQUIRED on this compiler.');
      end;

      { The control gates, the question does not. `gappy` being absent is the
        expected, already-measured FPC result; failing on it would fail a
        compiler for behaving exactly as documented. `dense` absent means
        published enums are gone altogether and the run measured nothing. }
      if not GDenseSeen then
      begin
        WriteLn;
        WriteLn('  FAIL: the CONTIGUOUS control was not published either, so this');
        WriteLn('        run cannot distinguish "gaps are the problem" from');
        WriteLn('        "enums are not publishable at all".');
        ExitCode := 1;
      end;
    end;
  finally
    GCtx.Free;
    GObj.Free;
    GEnumObj.Free;
  end;
end.
