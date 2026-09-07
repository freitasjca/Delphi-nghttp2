unit Probe.Beta.One;

// The other half. Same short type name as Probe.Alpha.One, on purpose.

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

type
  TFoo = class
  public
    function Who: string;
  end;

implementation

function TFoo.Who: string;
begin
  Result := 'beta';
end;

end.
