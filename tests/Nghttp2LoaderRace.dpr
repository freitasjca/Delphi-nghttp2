program Nghttp2LoaderRace;

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$IFEND}

// ============================================================================
//  Nghttp2LoaderRace - the FIX-LOADRACE-1 gate
//  ==========================================
//  Destination: Delphi-nghttp2/tests/Nghttp2LoaderRace.dpr
//
//  ASKS: when N threads call a library loader for the FIRST time at the same
//  instant, does every one of them get a loaded library?
//
//  Before FIX-LOADRACE-1 the answer was no. Both loaders were
//
//      if GLoaded then Exit(True);
//      ... open the library, resolve ~50 symbols ...
//      GLoaded := True;
//
//  - a check-then-set with an entire library load between the two halves and
//  no lock around it. NghttpsslLoad additionally carried a Boolean "recursion
//  guard" whose comment read "single-threaded init assumed", and which turned
//  a second thread arriving mid-load into `Exit(False)`: the caller was told
//  OpenSSL had FAILED TO LOAD while the load was in fact succeeding on the
//  other thread.
//
//  WHY A FRESH PROCESS, AND ONLY ONE ROUND PER LIBRARY
//  ---------------------------------------------------
//  The guarded region is entered exactly once per process. After the first
//  successful load every caller takes the `if GLoaded then Exit(True)` early
//  return, which is correct and raceless - so a second round inside the same
//  process would pass on broken code. Sampling therefore happens by running
//  this binary repeatedly, not by looping inside it.
//
//  Resetting with NghttpsslUnload to get more rounds was considered and
//  rejected: repeatedly dlclose-ing libssl is fragile for reasons that have
//  nothing to do with this defect, and a gate that fails for unrelated reasons
//  is worse than one that samples less often.
//
//  The two libraries have INDEPENDENT globals, so one process gets one genuine
//  first-load race for each.
//
//  READING THE RESULT - THE THREE OUTCOMES ARE NOT SYMMETRIC
//  ---------------------------------------------------------
//    every racer True   -> PASS.
//    every racer False  -> SKIP. No thread could load it at all, which means
//                          the library is absent on this machine. That is a
//                          missing dependency, NOT a race, and reporting it as
//                          a failure would train everyone to ignore this gate.
//    MIXED              -> FAIL. This is the signature. Some threads were told
//                          the library could not be loaded while others loaded
//                          it in the same instant. Nothing but the race
//                          produces that.
//
//  WHAT THIS GATE DOES NOT PROVE - read before trusting it
//  --------------------------------------------------------
//  The libnghttp2 arm is NOT discriminating and is labelled as such in the
//  output. NghttpLoad had no re-entry guard at all, so before the fix both
//  threads simply did the work twice and both returned True: the damage was a
//  doubled dlopen refcount and ~50 function pointers written twice, neither of
//  which is observable through the public API. That arm is a crash-and-
//  robustness check only. Treating it as evidence about the race would be
//  exactly the "a check that cannot fail reads as a pass" trap.
//
//  The OpenSSL arm is the one with teeth.
//
//  Neither arm exercises Unload under contention. Racing Unload against Load
//  has no correct answer to assert - a thread may legitimately observe either
//  state - so it is left out rather than asserted wrongly.
// ============================================================================

uses
{$IF DEFINED(FPC)}
  {$IF DEFINED(UNIX)}
  cthreads,   { MUST be first on FPC/Unix - this program is nothing but
                threads, and without the pthreads driver it aborts on the
                first TThread.Create. }
  {$IFEND}
  SysUtils, Classes, SyncObjs,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs,
{$IFEND}
  Nghttp2.Native,
  Nghttp2.OpenSSL;

const
  RACERS       = 8;
  GATE_WAIT_MS = 30000;   { a racer that never reaches the gate is itself a fault }

type
  TLoaderKind = (lkOpenSsl, lkNghttp2);

  TRaceSlot = record
    Ok:      Boolean;
    Reached: Boolean;   { got past the starting gate at all }
    Err:     string;
  end;
  PRaceSlot = ^TRaceSlot;

  TRacer = class(TThread)
  private
    FGate: TEvent;
    FKind: TLoaderKind;
    FSlot: PRaceSlot;
  protected
    procedure Execute; override;
  public
    constructor Create(AGate: TEvent; AKind: TLoaderKind; ASlot: PRaceSlot);
  end;

var
  GPassed:  Integer = 0;
  GFailed:  Integer = 0;
  GSkipped: Integer = 0;

  { Did the arm that can actually DETECT the race run? If OpenSSL is absent
    this binary can still exit 0 having proved nothing about the defect, and
    both harnesses would read that as a pass. Exit code 3 exists so they can
    say SKIP instead - the same convention Nghttp2ReadTimeout uses. }
  GDiscriminatingArmRan: Boolean = False;

procedure Check(const AName: string; ACondition: Boolean; const ADetail: string = '');
begin
  if ACondition then
  begin
    Inc(GPassed);
    WriteLn('  PASS  ', AName);
  end
  else
  begin
    Inc(GFailed);
    WriteLn('  FAIL  ', AName);
    if ADetail <> '' then
      WriteLn('        ', ADetail);
  end;
end;

procedure Skip(const AName, AReason: string);
begin
  Inc(GSkipped);
  WriteLn('  SKIP  ', AName, '  [', AReason, ']');
  WriteLn('        NOT a pass: this check did not run.');
end;

{ ─── TRacer ────────────────────────────────────────────────────────────── }

constructor TRacer.Create(AGate: TEvent; AKind: TLoaderKind; ASlot: PRaceSlot);
begin
  inherited Create(True);   { suspended - every racer waits for the gate }
  FreeOnTerminate := False; { the caller joins and frees }
  FGate := AGate;
  FKind := AKind;
  FSlot := ASlot;
end;

procedure TRacer.Execute;
begin
  { The starting gun, and the reason this gate works at all. Without it the
    racers begin staggered by however long TThread.Start takes each one, the
    first finishes the load before the last has started, and every later thread
    takes the raceless early return. }
  if FGate.WaitFor(GATE_WAIT_MS) <> wrSignaled then
  begin
    FSlot^.Err := 'never reached the starting gate';
    Exit;
  end;
  FSlot^.Reached := True;

  try
    if FKind = lkOpenSsl then
    begin
      FSlot^.Ok := NghttpsslLoad;
      if not FSlot^.Ok then FSlot^.Err := NghttpsslLoadError;
    end
    else
    begin
      FSlot^.Ok := NghttpLoad;
      if not FSlot^.Ok then FSlot^.Err := NghttpLoadError;
    end;
  except
    { A loader is not allowed to raise. If one does, that is the finding. }
    on E: Exception do
    begin
      FSlot^.Ok  := False;
      FSlot^.Err := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

{ ─── one race ──────────────────────────────────────────────────────────── }

procedure RaceOneLoader(AKind: TLoaderKind; const ALib: string;
  ADiscriminating: Boolean);
var
  LGate:     TEvent;
  LSlots:    array[0..RACERS - 1] of TRaceSlot;
  LThreads:  array[0..RACERS - 1] of TRacer;
  I, LOk, LBad, LUnreached: Integer;
  LFirstErr: string;
begin
  WriteLn;
  WriteLn(Format('-- %s: %d threads race the FIRST load', [ALib, RACERS]));
  if not ADiscriminating then
    WriteLn('   (robustness only - see the header: this arm cannot detect the race)');

  { Everything below assumes this is a genuine first load. If the library is
    already loaded the guarded region is never entered, every racer takes the
    early return, and the run would pass on broken code. That must be shouted,
    not quietly tolerated. }
  if ((AKind = lkOpenSsl) and NghttpsslIsLoaded)
  or ((AKind = lkNghttp2) and NghttpIsLoaded) then
  begin
    Skip(ALib + ': every racer loaded the library',
         'already loaded before the race started - this run proves nothing');
    Exit;
  end;

  LOk := 0; LBad := 0; LUnreached := 0; LFirstErr := '';
  for I := 0 to RACERS - 1 do
  begin
    LSlots[I].Ok      := False;
    LSlots[I].Reached := False;
    LSlots[I].Err     := '';
  end;

  LGate := TEvent.Create(nil, True, False, '');   { manual reset: one set releases all }
  try
    for I := 0 to RACERS - 1 do
      LThreads[I] := TRacer.Create(LGate, AKind, @LSlots[I]);
    try
      for I := 0 to RACERS - 1 do
        LThreads[I].Start;

      { Every racer is now parked on the gate. Release them together. }
      LGate.SetEvent;

      for I := 0 to RACERS - 1 do
        LThreads[I].WaitFor;
    finally
      for I := 0 to RACERS - 1 do
        LThreads[I].Free;
    end;
  finally
    LGate.Free;
  end;

  for I := 0 to RACERS - 1 do
  begin
    if not LSlots[I].Reached then
      Inc(LUnreached)
    else if LSlots[I].Ok then
      Inc(LOk)
    else
    begin
      Inc(LBad);
      if LFirstErr = '' then LFirstErr := LSlots[I].Err;
    end;
  end;

  WriteLn(Format('     %d loaded, %d refused, %d never started',
                 [LOk, LBad, LUnreached]));
  if LFirstErr <> '' then
    WriteLn('     first refusal: ', LFirstErr);

  Check(ALib + ': every racer reached the starting gate',
        LUnreached = 0,
        Format('%d thread(s) timed out waiting %d ms on the gate',
               [LUnreached, GATE_WAIT_MS]));

  { The three outcomes, and why the all-False one is a SKIP. If not one thread
    could load the library then the library is not here - a missing dependency,
    not a race. Calling that a failure would make this gate red on every
    machine without OpenSSL, and a gate that is always red gets ignored. }
  if (LOk = 0) and (LBad = RACERS) then
    Skip(ALib + ': every racer loaded the library',
         'no thread loaded it at all, so the library is absent here - a '
       + 'missing dependency, not a race')
  else
  begin
    if ADiscriminating then
      GDiscriminatingArmRan := True;
    Check(ALib + ': every racer loaded the library',
          LBad = 0,
          Format('%d of %d racers were told the library could not be loaded '
               + 'while %d loaded it in the same instant. A PARTIAL failure is '
               + 'the signature of the check-then-set race - see FIX-LOADRACE-1.',
                 [LBad, RACERS, LOk]));
  end;
end;

{ ─── main ──────────────────────────────────────────────────────────────── }

begin
  WriteLn('Nghttp2LoaderRace - does a concurrent FIRST load succeed on every thread?');
  WriteLn('FIX-LOADRACE-1. One genuine first-load race per library, per process.');

  try
    { OpenSSL first: it is the arm that can actually fail. }
    RaceOneLoader(lkOpenSsl,  'OpenSSL',    True);
    RaceOneLoader(lkNghttp2, 'libnghttp2', False);
  except
    on E: Exception do
    begin
      Inc(GFailed);
      WriteLn('  FAIL  the race itself raised: ', E.ClassName, ': ', E.Message);
    end;
  end;

  WriteLn;
  WriteLn(Format('Result: %d passed, %d failed, %d skipped',
                 [GPassed, GFailed, GSkipped]));
  if GSkipped > 0 then
  begin
    WriteLn('        Skipped checks verified NOTHING - read the [reason] on each');
    WriteLn('        SKIP line above before reading this run as complete.');
  end;
  if GFailed = 0 then
    WriteLn('        A single clean run is weak evidence for a race. This binary')
  else
    WriteLn('        A partial failure above is the race. This binary');
  WriteLn('        is meant to be run repeatedly - the harness samples it.');

  { 1 = the race was observed. 3 = the discriminating arm never ran, so this
    run says NOTHING about the defect and the harness must report SKIP rather
    than pass. 0 = every racer on every arm got its library. }
  if GFailed > 0 then
    ExitCode := 1
  else if not GDiscriminatingArmRan then
  begin
    WriteLn('        OpenSSL arm did not run - exit 3, NOT a pass.');
    ExitCode := 3;
  end
  else
    ExitCode := 0;
end.
