unit Corpus.S6854.Google.Iam.V3.PrincipalAccessBoundaryPolicyResources.Messages;
interface
type
  TPrincipalAccessBoundaryPolicyRuleEffect = (
    ALLOW = 1
  );
  TPrincipalAccessBoundaryPolicyAnnotationsEntry = class
  end;
  TPrincipalAccessBoundaryPolicy = class
    destructor Destroy; override;
    function  AnnotationsCount: Integer;
    function  HasAnnotations(const AKey: string): Boolean;
    function  GetAnnotations(const AKey: string): string;
    procedure SetAnnotations(const AKey: string; const AValue: string);
    procedure ClearAnnotations;
  end;
  TPrincipalAccessBoundaryPolicyDetails = class
    destructor Destroy; override;
  end;
  TPrincipalAccessBoundaryPolicyRule = class
  end;
implementation
function TPrincipalAccessBoundaryPolicy.AnnotationsCount: Integer;
begin
end;
function TPrincipalAccessBoundaryPolicy.HasAnnotations(const AKey: string): Boolean;
var
  I: Integer;
begin
end;
function TPrincipalAccessBoundaryPolicy.GetAnnotations(const AKey: string): string;
var
  I: Integer;
begin
end;
procedure TPrincipalAccessBoundaryPolicy.SetAnnotations(const AKey: string; const AValue: string);
var
  I: Integer;
begin
end;
procedure TPrincipalAccessBoundaryPolicy.ClearAnnotations;
var
  I: Integer;
begin
end;
destructor TPrincipalAccessBoundaryPolicy.Destroy;
var
  I: Integer;
begin
end;
destructor TPrincipalAccessBoundaryPolicyDetails.Destroy;
var
  I: Integer;
begin
end;
end.
