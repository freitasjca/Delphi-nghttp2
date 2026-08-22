unit Nghttp2.Compat;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Compat
//  Compiler-compatibility shims. Empty on every toolchain that does not need
//  one — including Delphi and FPC trunk — so adding it to a uses clause is
//  free where it is not required.
//
//  ── TInterlocked on FPC 3.2.2 ─────────────────────────────────────────────
//  Delphi declares TInterlocked in System.SyncObjs, and FPC trunk (3.3.1)
//  added it to SyncObjs to match. **FPC 3.2.2 does not have it at all**, which
//  is what stopped this library building on the compiler Horse's CI installs
//  via `apt-get install -y fpc`:
//
//    Nghttp2.Session.pas(1180,3) Error: Identifier not found "TInterlocked"
//
//  3.2.2 does provide the underlying operations, as plain functions in System,
//  with argument orders identical to the Delphi class methods. So the fix is a
//  declaration, not a rewrite: 48 call sites across five units keep their
//  existing `TInterlocked.X(...)` form and this unit supplies the class where
//  the RTL does not.
//
//  Guarded to FPC < 3.3.1 precisely so that on Delphi and on trunk the RTL's
//  own TInterlocked continues to win. Nothing about the validated trunk
//  configuration changes — this cannot alter behaviour on a compiler that
//  never compiles it.
//
//  Integer only, no Int64 overloads. That mirrors what the callers actually
//  use, and is deliberate: FPC's 64-bit interlocked support is not uniform
//  across the platforms this library targets (see the note at
//  Horse.Provider.Nghttp2.pas:73-74). Adding an Int64 overload here would
//  invite call sites that then fail to build on 32-bit targets.
// ============================================================================

interface

{$IF DEFINED(FPC) AND (FPC_FULLVERSION < 30301)}
type
  { Minimal stand-in for System.SyncObjs.TInterlocked, supplying only the four
    operations this library uses. Signatures match Delphi's exactly so callers
    are identical on every compiler. }
  TInterlocked = class
  public
    class function Increment(var ATarget: Integer): Integer; static; inline;
    class function Decrement(var ATarget: Integer): Integer; static; inline;
    class function Exchange(var ATarget: Integer; const AValue: Integer): Integer; static; inline;
    class function CompareExchange(var ATarget: Integer;
      const AValue, AComparand: Integer): Integer; static; inline;
  end;
{$IFEND}

{ ── CPU count ───────────────────────────────────────────────────────────────
  Returns the number of usable cores, and is the ONLY thing this library should
  ask — never TThread.ProcessorCount directly.

  FPC 3.2.2 on Linux returns **1** from TThread.ProcessorCount regardless of the
  machine. That is not a performance detail; it silently reduces the worker pool
  to a single thread and the epoll engine to a single loop, so the server accepts
  one request at a time and sheds everything else under load. Measured
  2026-08-22 on a 28-core host:

    trunk 3.3.1 : threads 30 -> 30, h2load 180/180 succeeded
    3.2.2       : threads  3 ->  3, h2load   0/100 succeeded

  A one-thread pool looks identical to a healthy one in a log, which is why the
  test server prints its resolved thread count.

  On Linux the kernel exposes the answer directly in /sys, so read it rather
  than trusting the RTL. Everywhere else — Delphi, FPC trunk, FPC on Windows,
  where TThread.ProcessorCount is correct — this is a straight pass-through. }
function Nghttp2CpuCount: Integer;

implementation

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$IFEND}

const
  { Used only when every detection route fails. Four is deliberately modest:
    enough concurrency that the pool is not a bottleneck, small enough to be
    harmless on a genuinely small machine. }
  CPU_COUNT_FALLBACK = 4;

{$IF DEFINED(FPC) AND (FPC_FULLVERSION < 30301) AND DEFINED(UNIX)}

{ Parses the kernel's online-CPU list: "0-27", "0", or "0-1,3" — a
  comma-separated list of single indices and inclusive ranges. Summing the
  ranges is correct for all three forms, where taking the highest index would
  over-count a sparse list. }
function ParseCpuList(const AList: string): Integer;
var
  LParts: TStringList;
  I, LDash, LLo, LHi: Integer;
  LItem: string;
begin
  Result := 0;
  LParts := TStringList.Create;
  try
    LParts.Delimiter := ',';
    LParts.StrictDelimiter := True;
    LParts.DelimitedText := Trim(AList);
    for I := 0 to LParts.Count - 1 do
    begin
      LItem := Trim(LParts[I]);
      if LItem = '' then Continue;
      LDash := Pos('-', LItem);
      if LDash > 0 then
      begin
        LLo := StrToIntDef(Copy(LItem, 1, LDash - 1), -1);
        LHi := StrToIntDef(Copy(LItem, LDash + 1, MaxInt), -1);
        if (LLo >= 0) and (LHi >= LLo) then
          Inc(Result, LHi - LLo + 1);
      end
      else if StrToIntDef(LItem, -1) >= 0 then
        Inc(Result);
    end;
  finally
    LParts.Free;
  end;
end;

function ReadFirstLine(const APath: string; out ALine: string): Boolean;
var
  LLines: TStringList;
begin
  Result := False;
  ALine := '';
  if not FileExists(APath) then Exit;
  LLines := TStringList.Create;
  try
    try
      LLines.LoadFromFile(APath);
      if LLines.Count > 0 then
      begin
        ALine := LLines[0];
        Result := ALine <> '';
      end;
    except
      { A /sys read can fail in a restricted container. Falling through to the
        next strategy is the whole point of reporting failure rather than
        raising. }
      Result := False;
    end;
  finally
    LLines.Free;
  end;
end;

function CountCpuInfoProcessors: Integer;
var
  LLines: TStringList;
  I: Integer;
begin
  Result := 0;
  if not FileExists('/proc/cpuinfo') then Exit;
  LLines := TStringList.Create;
  try
    try
      LLines.LoadFromFile('/proc/cpuinfo');
      for I := 0 to LLines.Count - 1 do
        if Copy(LowerCase(Trim(LLines[I])), 1, 9) = 'processor' then
          Inc(Result);
    except
      Result := 0;
    end;
  finally
    LLines.Free;
  end;
end;

function Nghttp2CpuCount: Integer;
var
  LLine: string;
begin
  { /sys first — it reflects CPUs actually online, so a container restricted to
    a subset reports the subset rather than the host's total. }
  if ReadFirstLine('/sys/devices/system/cpu/online', LLine) then
  begin
    Result := ParseCpuList(LLine);
    if Result >= 1 then Exit;
  end;

  Result := CountCpuInfoProcessors;
  if Result >= 1 then Exit;

  Result := CPU_COUNT_FALLBACK;
end;

{$ELSE}

function Nghttp2CpuCount: Integer;
begin
  Result := TThread.ProcessorCount;
  if Result < 1 then
    Result := CPU_COUNT_FALLBACK;
end;

{$IFEND}

{$IF DEFINED(FPC) AND (FPC_FULLVERSION < 30301)}

{ Each forwards to the System-unit function of the same meaning. FPC declares
  them for every supported target, so no per-platform branching is needed.

  Left unqualified deliberately: `System.InterlockedIncrement` would also
  resolve, but unit-qualified RTL access is one more thing that can behave
  differently on an older compiler, and these four names are unique — there is
  nothing here for them to collide with. }

class function TInterlocked.Increment(var ATarget: Integer): Integer;
begin
  Result := InterlockedIncrement(ATarget);
end;

class function TInterlocked.Decrement(var ATarget: Integer): Integer;
begin
  Result := InterlockedDecrement(ATarget);
end;

class function TInterlocked.Exchange(var ATarget: Integer; const AValue: Integer): Integer;
begin
  Result := InterlockedExchange(ATarget, AValue);
end;

{ Argument order is (Target, NewValue, Comparand) in BOTH Delphi's
  TInterlocked.CompareExchange and FPC's System.InterlockedCompareExchange, so
  this is a straight pass-through. Worth stating explicitly: getting this pair
  reversed compiles cleanly and fails only under contention, which is the
  hardest possible way to find a bug. }
class function TInterlocked.CompareExchange(var ATarget: Integer;
  const AValue, AComparand: Integer): Integer;
begin
  Result := InterlockedCompareExchange(ATarget, AValue, AComparand);
end;

{$IFEND}

end.
