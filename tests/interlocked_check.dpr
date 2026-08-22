program interlocked_check;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ELSE}{$APPTYPE CONSOLE}{$ENDIF}

// ============================================================================
//  interlocked_check — validates Nghttp2.Compat's TInterlocked shim against the
//  exact semantics the library depends on.
//
//  Written because streaming hung on FPC 3.2.2 while everything else passed.
//  Nghttp2.Session's stream-resume path is a test-and-clear:
//
//    Nghttp2.Session.pas:1538   if TInterlocked.Exchange(FStreamDataReady, 0) <> 0 then
//
//  which is only correct if Exchange returns the PREVIOUS value. Get that wrong
//  and the deferred stream is never resumed — the server accepts the request,
//  sends nothing, and the client waits forever. No compiler error, no crash,
//  and every non-streaming test still passes.
//
//  So rather than trust the RTL documentation, assert the contract. Run it on
//  both compilers: the shim must behave identically to SyncObjs' own class.
//
//  Build (FPC 3.2.2):
//    fpc -MDelphi -Fu../src -FU/tmp/ic-units interlocked_check.dpr && ./interlocked_check
// ============================================================================

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  Nghttp2.Compat;

var
  GFail: Integer = 0;

procedure Expect(const AName: string; const AGot, AWant: Integer);
begin
  if AGot = AWant then
    WriteLn('  PASS  ', AName, ' = ', AGot)
  else
  begin
    WriteLn('  FAIL  ', AName, ' = ', AGot, '   expected ', AWant);
    Inc(GFail);
  end;
end;

var
  V, R: Integer;
begin
  WriteLn('interlocked_check — TInterlocked semantics');
  WriteLn;

  { Increment/Decrement return the NEW value, matching Delphi. }
  V := 5; R := TInterlocked.Increment(V);
  Expect('Increment -> returned', R, 6);
  Expect('Increment -> target',   V, 6);

  V := 5; R := TInterlocked.Decrement(V);
  Expect('Decrement -> returned', R, 4);
  Expect('Decrement -> target',   V, 4);

  { Exchange returns the PREVIOUS value. This is the one the streaming
    test-and-clear depends on; returning the new value would silently disable
    stream resumption. }
  V := 7; R := TInterlocked.Exchange(V, 9);
  Expect('Exchange -> returned (previous)', R, 7);
  Expect('Exchange -> target (new)',        V, 9);

  { CompareExchange returns the PREVIOUS value and swaps only on a match. }
  V := 3; R := TInterlocked.CompareExchange(V, 8, 3);
  Expect('CompareExchange match -> returned', R, 3);
  Expect('CompareExchange match -> target',   V, 8);

  V := 3; R := TInterlocked.CompareExchange(V, 8, 99);
  Expect('CompareExchange no-match -> returned', R, 3);
  Expect('CompareExchange no-match -> target',   V, 3);

  { The atomic-read idiom used throughout: CompareExchange(x, 0, 0) must return
    x unchanged, whatever x is. Session uses this to read FStopping, FDraining,
    FPendingDispatch and FStreamDataReady without a lock. }
  V := 42; R := TInterlocked.CompareExchange(V, 0, 0);
  Expect('atomic read of 42 -> returned', R, 42);
  Expect('atomic read of 42 -> unchanged', V, 42);

  V := 0; R := TInterlocked.CompareExchange(V, 0, 0);
  Expect('atomic read of 0 -> returned', R, 0);

  { The exact streaming sequence from Nghttp2.Session: set the flag, then
    test-and-clear it. The second clear must report "was already clear". }
  V := 0;
  TInterlocked.Exchange(V, 1);
  R := TInterlocked.Exchange(V, 0);
  Expect('stream wake: set then test-and-clear -> was set', R, 1);
  R := TInterlocked.Exchange(V, 0);
  Expect('stream wake: clear again -> was clear', R, 0);

  WriteLn;
  if GFail = 0 then
    WriteLn('ALL PASS — shim matches the contract the library relies on')
  else
    WriteLn(GFail, ' FAILURES — the shim is wrong; streaming will hang');

  ExitCode := GFail;
end.
