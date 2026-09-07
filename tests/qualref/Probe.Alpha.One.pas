unit Probe.Alpha.One;

// Half of the IMPORT-1 qualified-reference probe. Deliberately declares a type
// with the SAME short name as Probe.Beta.One, because that is the situation
// generated code lands in: `Status`, `Error` and `Metadata` recur across
// googleapis, so two generated units in one uses clause export the same TFoo.

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
  Result := 'alpha';
end;

end.
