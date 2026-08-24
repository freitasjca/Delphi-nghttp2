program Nghttp2AllocBench;

// ============================================================================
//  Nghttp2AllocBench - allocation cost of the protobuf codec (backlog item P3)
//
//  Design record: docs/alloc-benchmark-design.md in the horse-crosssocket
//  workspace. Read it before changing what this measures.
//
//  == Why it counts allocations instead of timing them ==
//
//  The obvious instrument is wall clock: run the server, compare req/s with
//  and without a change. That instrument does not work here, and there is a
//  number proving it. On 2026-08-24 the same binary, built twice with
//  byte-identical codegen, differed by 6.2% on this hardware; five runs of
//  identical code spread 17%. A 9-23% "regression" survived three
//  order-reversed sessions and was still noise.
//
//  Allocation work will not move throughput by 20%. dext's argument - the one
//  that put this item in the backlog - is about memory-manager pressure, not
//  wall clock. So a timing harness cannot see the effect being looked for, and
//  worse, it will hand you a confident number anyway.
//
//  Allocations per operation is an integer. It has zero variance. Two runs of
//  the same build MUST produce identical counts, and if they do not, the
//  harness is broken rather than the result being interesting.
//
//  == Why there is no server ==
//
//  TProtoSerializer.Serialize/Deserialize are directly callable. Removing the
//  server removes startup races, run order, TIME_WAIT, scheduler noise and the
//  network path in one move - every confound that cost time on the accept-stall
//  investigation this benchmark's design was written to avoid repeating.
//
//  == How attribution works without instrumenting call sites ==
//
//  A bare "N allocations per message" says nothing about where they come from.
//  So the scenarios sweep one dimension at a time and the report prints the
//  SLOPE between them:
//
//    0,1,2,4,8 string fields    -> allocations per string field, and the
//                                  fixed per-message intercept
//    string length 8..4096      -> whether cost tracks LENGTH or only COUNT
//    0,1,2,4,8 integer fields   -> the control. Integer fields should cost
//                                  nothing. A non-zero slope here is a finding
//                                  before any string work begins.
//
//  == Reading the output ==
//
//  allocs/op is the number. bytes/op is context. ns/op is a sanity check and
//  is NEVER the gate - see the first section of this header.
//
//  Build (Windows) - same pattern as Nghttp2ProtobufTests.dpr, which lives
//  beside this file and has no build script either:
//    dcc64 -CC -B -U"..\src" Nghttp2AllocBench.dpr
//
//  Build (FPC), where no shim is needed - heaptrc does the counting:
//    fpc -MDelphi -gh -Fu../src Nghttp2AllocBench.dpr
//
//  Usage:  Nghttp2AllocBench [iterations]      (default 100000)
//
//  Delphi only for the counting shim. On FPC, build with -gh and read the
//  heaptrc summary instead - it already reports blocks and bytes at exit, so
//  no instrument is needed there. Cross-checking the two is worthwhile before
//  trusting either.
// ============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

{$M+}   // RTTI for the message classes below

{$IF DEFINED(FPC)}
  // FPC: {$M+} alone emits only CLASSIC RTTI. System.Rtti / TRttiType
  // .GetProperties reads EXTENDED RTTI, which Delphi enables implicitly and
  // FPC requires via this directive. Without it GetProperties returns 0.
  {$RTTI EXPLICIT PROPERTIES([vcPublished]) FIELDS([vcPublic]) METHODS([vcPublic])}
{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes, System.Diagnostics,
{$IFEND}
  Nghttp2.Protobuf,
  Nghttp2.Protobuf.Rtti;

const
  DEFAULT_ITERATIONS = 100000;

  // Long enough that per-character cost would be visible against per-call
  // cost, short enough to stay in one allocation bucket on every manager.
  STR_FILLER = 'abcdefghijklmnopqrstuvwxyz012345';   // 32 chars

type
  TDoubleArray = array of Double;

// ---------------------------------------------------------------------------
//  Message classes - one per point on each sweep
//
//  Written out longhand rather than generated. Generics or a variant-bag would
//  put allocations of their own inside the thing being measured, which is the
//  one mistake this program cannot afford.
// ---------------------------------------------------------------------------

type
  [TGrpcMessage]
  TMsgS0 = class
  private
    Fk: Integer;
  published
    [TProtoMember(1)] property k: Integer read Fk write Fk;
  end;

  [TGrpcMessage]
  TMsgS1 = class
  private
    Fk: Integer; Fa: string;
  published
    [TProtoMember(1)] property k: Integer read Fk write Fk;
    [TProtoMember(2)] property a: string read Fa write Fa;
  end;

  [TGrpcMessage]
  TMsgS2 = class
  private
    Fk: Integer; Fa, Fb: string;
  published
    [TProtoMember(1)] property k: Integer read Fk write Fk;
    [TProtoMember(2)] property a: string read Fa write Fa;
    [TProtoMember(3)] property b: string read Fb write Fb;
  end;

  [TGrpcMessage]
  TMsgS4 = class
  private
    Fk: Integer; Fa, Fb, Fc, Fd: string;
  published
    [TProtoMember(1)] property k: Integer read Fk write Fk;
    [TProtoMember(2)] property a: string read Fa write Fa;
    [TProtoMember(3)] property b: string read Fb write Fb;
    [TProtoMember(4)] property c: string read Fc write Fc;
    [TProtoMember(5)] property d: string read Fd write Fd;
  end;

  [TGrpcMessage]
  TMsgS8 = class
  private
    Fk: Integer; Fa, Fb, Fc, Fd, Fe, Ff, Fg, Fh: string;
  published
    [TProtoMember(1)] property k: Integer read Fk write Fk;
    [TProtoMember(2)] property a: string read Fa write Fa;
    [TProtoMember(3)] property b: string read Fb write Fb;
    [TProtoMember(4)] property c: string read Fc write Fc;
    [TProtoMember(5)] property d: string read Fd write Fd;
    [TProtoMember(6)] property e: string read Fe write Fe;
    [TProtoMember(7)] property f: string read Ff write Ff;
    [TProtoMember(8)] property g: string read Fg write Fg;
    [TProtoMember(9)] property h: string read Fh write Fh;
  end;

  // Integer sweep - the control. These should cost nothing per field.
  [TGrpcMessage]
  TMsgI4 = class
  private
    Fk, Fp, Fq, Fr: Integer;
  published
    [TProtoMember(1)] property k: Integer read Fk write Fk;
    [TProtoMember(2)] property p: Integer read Fp write Fp;
    [TProtoMember(3)] property q: Integer read Fq write Fq;
    [TProtoMember(4)] property r: Integer read Fr write Fr;
  end;

  [TGrpcMessage]
  TMsgI8 = class
  private
    Fk, Fp, Fq, Fr, Fs, Ft, Fu, Fv: Integer;
  published
    [TProtoMember(1)] property k: Integer read Fk write Fk;
    [TProtoMember(2)] property p: Integer read Fp write Fp;
    [TProtoMember(3)] property q: Integer read Fq write Fq;
    [TProtoMember(4)] property r: Integer read Fr write Fr;
    [TProtoMember(5)] property s: Integer read Fs write Fs;
    [TProtoMember(6)] property t: Integer read Ft write Ft;
    [TProtoMember(7)] property u: Integer read Fu write Fu;
    [TProtoMember(8)] property v: Integer read Fv write Fv;
  end;

// ---------------------------------------------------------------------------
//  Counting memory manager
//
//  The shim must never allocate: it would count itself and the numbers would
//  be self-referential. Plain increments only - this program is single
//  threaded by construction, so no interlocking is needed and its barrier cost
//  is avoided too.
// ---------------------------------------------------------------------------

{$IF NOT DEFINED(FPC)}
var
  GNextMM:   TMemoryManagerEx;
  GInstalled: Boolean = False;
  GAllocs:   Int64 = 0;
  GFrees:    Int64 = 0;
  GReallocs: Int64 = 0;
  GBytes:    Int64 = 0;

function CountingGetMem(Size: NativeInt): Pointer;
begin
  Inc(GAllocs);
  Inc(GBytes, Size);
  Result := GNextMM.GetMem(Size);
end;

function CountingFreeMem(P: Pointer): Integer;
begin
  Inc(GFrees);
  Result := GNextMM.FreeMem(P);
end;

function CountingReallocMem(P: Pointer; Size: NativeInt): Pointer;
begin
  Inc(GReallocs);
  Inc(GBytes, Size);
  Result := GNextMM.ReallocMem(P, Size);
end;

function CountingAllocMem(Size: NativeInt): Pointer;
begin
  Inc(GAllocs);
  Inc(GBytes, Size);
  Result := GNextMM.AllocMem(Size);
end;

function CountingRegisterLeak(P: Pointer): Boolean;
begin
  Result := GNextMM.RegisterExpectedMemoryLeak(P);
end;

function CountingUnregisterLeak(P: Pointer): Boolean;
begin
  Result := GNextMM.UnregisterExpectedMemoryLeak(P);
end;

procedure InstallCounter;
var
  LMM: TMemoryManagerEx;
begin
  if GInstalled then Exit;
  GetMemoryManager(GNextMM);
  LMM.GetMem                      := CountingGetMem;
  LMM.FreeMem                     := CountingFreeMem;
  LMM.ReallocMem                  := CountingReallocMem;
  LMM.AllocMem                    := CountingAllocMem;
  LMM.RegisterExpectedMemoryLeak  := CountingRegisterLeak;
  LMM.UnregisterExpectedMemoryLeak := CountingUnregisterLeak;
  SetMemoryManager(LMM);
  GInstalled := True;
end;

procedure UninstallCounter;
begin
  if not GInstalled then Exit;
  SetMemoryManager(GNextMM);
  GInstalled := False;
end;

procedure ResetCounters;
begin
  GAllocs := 0; GFrees := 0; GReallocs := 0; GBytes := 0;
end;

{$IFEND}

// ---------------------------------------------------------------------------
//  Reporting
// ---------------------------------------------------------------------------

var
  GIterations: Integer = DEFAULT_ITERATIONS;
  GAllocsPerOp: TDoubleArray;

procedure ReportRow(const ALabel: string; AAllocs, ABytes: Int64; AMs: Double);
var
  LPerOp: Double;
begin
  LPerOp := AAllocs / GIterations;
  WriteLn(Format('  %-34s %10.2f %10.1f %9.0f',
    [ALabel, LPerOp, ABytes / GIterations, AMs * 1000000.0 / GIterations]));
  SetLength(GAllocsPerOp, Length(GAllocsPerOp) + 1);
  GAllocsPerOp[High(GAllocsPerOp)] := LPerOp;
end;

procedure Header(const ATitle: string);
begin
  WriteLn;
  WriteLn('-- ', ATitle);
  WriteLn(Format('  %-34s %10s %10s %9s',
    ['scenario', 'allocs/op', 'bytes/op', 'ns/op']));
end;

{ Slope between two measured points, in allocations per added field. Printed
  rather than eyeballed because the intercept matters as much as the gradient:
  a high intercept with a flat slope means per-MESSAGE overhead, which is a
  different fix from per-FIELD overhead. }
procedure ReportSlope(const AWhat: string; ALo, AHi: Double; AFields: Integer);
begin
  if AFields <= 0 then Exit;
  WriteLn(Format('  -> %s: %.2f allocs per added field (intercept %.2f)',
    [AWhat, (AHi - ALo) / AFields, ALo]));
end;

// ---------------------------------------------------------------------------
//  Scenarios
// ---------------------------------------------------------------------------

{$IF NOT DEFINED(FPC)}
type
  TMsgFactory = function: TObject;

{ One scenario: build a message once, then serialize it AIterations times.
  The message construction is deliberately OUTSIDE the measured region - the
  question is what serialization costs, not what constructing a Delphi object
  costs. A warm-up pass runs first so the RTTI cache and the type-info build
  are already paid for; without it the first scenario absorbs the lazy-init of
  the whole serializer and reads several hundred allocations high. }
procedure BenchSerialize(const ALabel: string; AObj: TObject);
var
  I: Integer;
  LBytes: TBytes;
  LSW: TStopwatch;
  LA, LB: Int64;
begin
  LBytes := TProtoSerializer.Serialize(AObj);    // warm-up, discarded
  SetLength(LBytes, 0);

  ResetCounters;
  LSW := TStopwatch.StartNew;
  for I := 1 to GIterations do
  begin
    LBytes := TProtoSerializer.Serialize(AObj);
    SetLength(LBytes, 0);
  end;
  LSW.Stop;
  // Counters first: nothing between the loop and this read may allocate.
  LA := GAllocs + GReallocs;
  LB := GBytes;
  ReportRow(ALabel, LA, LB, LSW.Elapsed.TotalMilliseconds);
end;

{ Deserialize needs a fresh target each pass or repeated writes to the same
  string property would hit the "assign identical value" fast path and
  under-count. The target's construction IS therefore inside the measured
  region; the S0 row gives the baseline to subtract it. }
procedure BenchDeserialize(const ALabel: string; const AData: TBytes;
  AFactory: TMsgFactory);
var
  I: Integer;
  LObj: TObject;
  LSW: TStopwatch;
  LA, LB: Int64;
begin
  LObj := AFactory;                              // warm-up, discarded
  try
    TProtoSerializer.Deserialize(AData, LObj);
  finally
    LObj.Free;
  end;

  ResetCounters;
  LSW := TStopwatch.StartNew;
  for I := 1 to GIterations do
  begin
    LObj := AFactory;
    try
      TProtoSerializer.Deserialize(AData, LObj);
    finally
      LObj.Free;
    end;
  end;
  LSW.Stop;
  LA := GAllocs + GReallocs;
  LB := GBytes;
  ReportRow(ALabel, LA, LB, LSW.Elapsed.TotalMilliseconds);
end;

function MakeS0: TObject; begin Result := TMsgS0.Create; end;
function MakeS1: TObject; begin Result := TMsgS1.Create; end;
function MakeS2: TObject; begin Result := TMsgS2.Create; end;
function MakeS4: TObject; begin Result := TMsgS4.Create; end;
function MakeS8: TObject; begin Result := TMsgS8.Create; end;

procedure RunAll;
var
  LS0: TMsgS0; LS1: TMsgS1; LS2: TMsgS2; LS4: TMsgS4; LS8: TMsgS8;
  LI4: TMsgI4; LI8: TMsgI8;
  LLong1, LLong2: TMsgS1;
  LD0, LD1, LD2, LD4, LD8: TBytes;
  LBase: Integer;
begin
  LS0 := TMsgS0.Create; LS1 := TMsgS1.Create; LS2 := TMsgS2.Create;
  LS4 := TMsgS4.Create; LS8 := TMsgS8.Create;
  LI4 := TMsgI4.Create; LI8 := TMsgI8.Create;
  LLong1 := TMsgS1.Create; LLong2 := TMsgS1.Create;
  try
    LS0.k := 7;
    LS1.k := 7; LS1.a := STR_FILLER;
    LS2.k := 7; LS2.a := STR_FILLER; LS2.b := STR_FILLER;
    LS4.k := 7; LS4.a := STR_FILLER; LS4.b := STR_FILLER;
                LS4.c := STR_FILLER; LS4.d := STR_FILLER;
    LS8.k := 7; LS8.a := STR_FILLER; LS8.b := STR_FILLER;
                LS8.c := STR_FILLER; LS8.d := STR_FILLER;
                LS8.e := STR_FILLER; LS8.f := STR_FILLER;
                LS8.g := STR_FILLER; LS8.h := STR_FILLER;
    LI4.k := 1; LI4.p := 2; LI4.q := 3; LI4.r := 4;
    LI8.k := 1; LI8.p := 2; LI8.q := 3; LI8.r := 4;
    LI8.s := 5; LI8.t := 6; LI8.u := 7; LI8.v := 8;

    LLong1.k := 1; LLong1.a := StringOfChar('x', 64);
    LLong2.k := 1; LLong2.a := StringOfChar('x', 4096);

    Header('encode - string-field sweep (32-char values)');
    LBase := Length(GAllocsPerOp);
    BenchSerialize('encode, 0 string fields', LS0);
    BenchSerialize('encode, 1 string field',  LS1);
    BenchSerialize('encode, 2 string fields', LS2);
    BenchSerialize('encode, 4 string fields', LS4);
    BenchSerialize('encode, 8 string fields', LS8);
    ReportSlope('encode string field',
      GAllocsPerOp[LBase], GAllocsPerOp[LBase + 4], 8);

    Header('encode - string-length sweep (1 field)');
    BenchSerialize('encode, 1 field x 32 chars',   LS1);
    BenchSerialize('encode, 1 field x 64 chars',   LLong1);
    BenchSerialize('encode, 1 field x 4096 chars', LLong2);
    WriteLn('  -> flat here means cost tracks field COUNT, not string LENGTH');

    Header('encode - integer-field sweep (the control)');
    LBase := Length(GAllocsPerOp);
    BenchSerialize('encode, 1 integer field',  LS0);
    BenchSerialize('encode, 4 integer fields', LI4);
    BenchSerialize('encode, 8 integer fields', LI8);
    ReportSlope('encode integer field',
      GAllocsPerOp[LBase], GAllocsPerOp[LBase + 2], 7);
    WriteLn('  -> a non-zero slope here is a finding on its own');

    LD0 := TProtoSerializer.Serialize(LS0);
    LD1 := TProtoSerializer.Serialize(LS1);
    LD2 := TProtoSerializer.Serialize(LS2);
    LD4 := TProtoSerializer.Serialize(LS4);
    LD8 := TProtoSerializer.Serialize(LS8);

    Header('decode - string-field sweep (includes target construction)');
    LBase := Length(GAllocsPerOp);
    BenchDeserialize('decode, 0 string fields', LD0, MakeS0);
    BenchDeserialize('decode, 1 string field',  LD1, MakeS1);
    BenchDeserialize('decode, 2 string fields', LD2, MakeS2);
    BenchDeserialize('decode, 4 string fields', LD4, MakeS4);
    BenchDeserialize('decode, 8 string fields', LD8, MakeS8);
    ReportSlope('decode string field',
      GAllocsPerOp[LBase], GAllocsPerOp[LBase + 4], 8);
  finally
    LLong2.Free; LLong1.Free;
    LI8.Free; LI4.Free;
    LS8.Free; LS4.Free; LS2.Free; LS1.Free; LS0.Free;
  end;
end;
{$IFEND}

// ---------------------------------------------------------------------------

begin
{$IF DEFINED(FPC)}
  WriteLn('Nghttp2AllocBench: the counting shim is Delphi-only.');
  WriteLn('On FPC, build this with -gh and read the heaptrc summary at exit;');
  WriteLn('it already reports blocks and bytes allocated, so no instrument is');
  WriteLn('needed. Cross-check those numbers against the Delphi run.');
  ExitCode := 0;
{$ELSE}
  if ParamCount >= 1 then
    GIterations := StrToIntDef(ParamStr(1), DEFAULT_ITERATIONS);
  if GIterations < 1000 then GIterations := 1000;

  WriteLn('Nghttp2AllocBench - protobuf codec allocation cost (P3)');
  WriteLn(Format('iterations per scenario: %d', [GIterations]));
  WriteLn;
  WriteLn('allocs/op is the RESULT. bytes/op is context. ns/op is a sanity');
  WriteLn('check and is never the gate - this hardware cannot resolve a');
  WriteLn('throughput difference under ~20%, which is why the metric is a');
  WriteLn('count and not a duration. Two runs of one build must agree exactly.');

  InstallCounter;
  try
    RunAll;
  finally
    UninstallCounter;
  end;

  WriteLn;
  WriteLn('Re-run to confirm the counts are identical. They must be:');
  WriteLn('an allocation count has no variance, so any difference between two');
  WriteLn('runs of the same binary means this harness is wrong, not the codec.');
  ExitCode := 0;
{$IFEND}
end.
