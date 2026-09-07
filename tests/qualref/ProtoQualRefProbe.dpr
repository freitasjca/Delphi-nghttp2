program ProtoQualRefProbe;

// =============================================================================
//  ProtoQualRefProbe — settles ONE question before IMPORT-1 Stage B is built
//  on the answer.
//
//  THE QUESTION
//
//  Multi-file generation puts several generated units in one uses clause, and
//  short type names collide constantly in real schemas: `Status`, `Error`,
//  `Metadata`, `Operation` all appear in many googleapis packages. Two units
//  exporting TStatus means a bare `TStatus` in generated code binds to
//  whichever unit comes LAST in the uses clause — silently, and possibly to
//  the wrong type.
//
//  The fix is to qualify every cross-file reference:
//
//      Demo.Google.Rpc.Status.Messages.TStatus
//
//  which is a qualified type reference through a DOTTED unit name. Nothing in
//  this codebase does that today — generated units reference bundled types by
//  bare name (TProtobufTimestamp) — so the mechanism is unproven here on FPC,
//  and most unproven of all inside a generic: `TArray<Unit.Dotted.TFoo>` is
//  exactly what a repeated cross-file field emits.
//
//  WHY A PROBE AND NOT JUST BUILDING IT
//
//  If this does not work, it is not a small fix — it changes the naming scheme
//  for every generated type, i.e. all of Stage B. Three files and one compile
//  is the cheap way to find out. Building first and discovering it at the end
//  is how a wrong premise turns into a rewrite.
//
//  WHAT EACH CHECK MEANS
//
//    Q1  qualified reference resolves at all
//    Q2  it picks the RIGHT unit, not just some unit
//    Q3  bare name binds last-in-uses  <- the hazard, documented not fixed
//    Q4  qualified name works as a VAR / field type
//    Q5  qualified name works inside TArray<> — the repeated-field shape
//    Q6  qualified name works as a generic type argument in a method signature
//
//  Q3 is a control: if it did NOT bind to beta, the collision hazard would be
//  imaginary and qualification unnecessary. Assert the hazard is real before
//  paying to avoid it.
//
//  Build (FPC trunk):
//    fpc -MDelphi -O1 -Fu. ProtoQualRefProbe.dpr
//  Build (Windows):
//    dcc64 -CC -B -U. ProtoQualRefProbe.dpr
// =============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  Probe.Alpha.One,
  Probe.Beta.One;   // LAST in the uses clause — so a bare TFoo should be this

var
  GPass: Integer = 0;
  GFail: Integer = 0;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    WriteLn('  PASS  ', AName);
    Inc(GPass);
  end
  else
  begin
    if ADetail = '' then
      WriteLn('  FAIL  ', AName)
    else
      WriteLn('  FAIL  ', AName, '  [', ADetail, ']');
    Inc(GFail);
  end;
end;

// Q4 — a qualified name as a field type, which is what every generated
// message property declaration needs.
type
  THolder = class
  public
    Alpha: Probe.Alpha.One.TFoo;
    Beta:  Probe.Beta.One.TFoo;
    // Q5 — the repeated-field shape.
    Many:  TArray<Probe.Alpha.One.TFoo>;
    // Q6 — qualified name as a generic argument in a signature.
    function FirstOf(const AItems: TArray<Probe.Alpha.One.TFoo>): string;
  end;

function THolder.FirstOf(const AItems: TArray<Probe.Alpha.One.TFoo>): string;
begin
  if Length(AItems) = 0 then
    Result := '<empty>'
  else
    Result := AItems[0].Who;
end;

var
  LA:    Probe.Alpha.One.TFoo;
  LB:    Probe.Beta.One.TFoo;
  LBare: TFoo;
  LH:    THolder;
begin
  WriteLn('ProtoQualRefProbe — qualified references through dotted unit names');
  WriteLn;

  LA := Probe.Alpha.One.TFoo.Create;
  LB := Probe.Beta.One.TFoo.Create;
  LBare := TFoo.Create;
  LH := THolder.Create;
  try
    Check('Q1  qualified reference compiles and constructs', LA <> nil);
    Check('Q2  qualified reference picks the RIGHT unit',
      LA.Who = 'alpha', LA.Who);
    Check('Q2b second qualified reference picks its own unit',
      LB.Who = 'beta', LB.Who);

    // The control. A bare name is expected to bind to the LAST unit in the
    // uses clause. If this reports 'alpha', the collision hazard does not
    // exist in the way assumed and qualification is not needed.
    Check('Q3  bare name binds to the LAST unit in uses (hazard is real)',
      LBare.Who = 'beta', LBare.Who);

    LH.Alpha := Probe.Alpha.One.TFoo.Create;
    LH.Beta  := Probe.Beta.One.TFoo.Create;
    try
      Check('Q4  qualified name works as a field type',
        (LH.Alpha.Who = 'alpha') and (LH.Beta.Who = 'beta'));

      SetLength(LH.Many, 1);
      LH.Many[0] := LH.Alpha;
      Check('Q5  qualified name works inside TArray<>',
        (Length(LH.Many) = 1) and (LH.Many[0].Who = 'alpha'));

      Check('Q6  qualified name as a generic argument in a signature',
        LH.FirstOf(LH.Many) = 'alpha', LH.FirstOf(LH.Many));
    finally
      LH.Alpha.Free;
      LH.Beta.Free;
    end;
  finally
    LH.Free;
    LBare.Free;
    LB.Free;
    LA.Free;
  end;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed');
  if GFail > 0 then
    ExitCode := 1;
end.
