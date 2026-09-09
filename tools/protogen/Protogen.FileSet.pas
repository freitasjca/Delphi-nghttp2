unit Protogen.FileSet;

// =============================================================================
//  Protogen.FileSet -- IMPORT-1.  Resolve `import` and load the closure.
//
//  ── What was there before ──
//
//  The parser recorded imports into TProtoFileNode.Imports and NOTHING read
//  that list.  A field whose type lived in another file fell through
//  Protogen.Emitter's type resolution to:
//
//      LBase := PascalTypeName(AField.TypeName);  // best effort for forward refs
//
//  which mangles the name and emits it.  The emitter never failed; it produced
//  an identifier no unit declares, and the error surfaced in a compiler the
//  generator never invoked.  That fallback is why compile-check.sh had to
//  restrict itself to self-contained schemas -- 3019 of 7301 googleapis files,
//  41%.  The other 59% were unreachable, and so was almost every real service
//  API, because a service returns google.rpc.Status or takes a FieldMask.
//
//  ── What a file set is ──
//
//  One root .proto plus the transitive closure of its imports, each entry
//  carrying the three names a file has:
//
//    ImportPath  'google/rpc/status.proto'  -- its IDENTITY.  The spelling in
//                an `import` statement, always forward slashes.  Two files are
//                the same file iff their import paths match, which is what
//                makes deduplication and cycle detection exact rather than
//                heuristic.
//    DiskPath    where it was actually found under an include root
//    UnitPrefix  'Demo.Google.Rpc.Status' -- the per-file Pascal unit prefix
//
//  ── Some imports are satisfied without a file ──
//
//  `import "google/protobuf/timestamp.proto"` is satisfied by
//  Nghttp2.Protobuf.WellKnown, so it is never looked up on disk and never
//  enters the closure.  This is what keeps IMPORT-1 from being a breaking
//  change: every schema that generates today imports nothing else, so today's
//  corpus loads with no include roots configured at all.
//
//  descriptor.proto is satisfied for a different reason -- nothing references
//  it -- see IsImportSatisfiedInternally.
//
//  ── Include roots ──
//
//  protoc semantics: an import path is resolved against the -I roots in order,
//  first hit wins, and is NEVER relative to the importing file.  With no -I
//  given the input file's own directory becomes the single root, which is what
//  makes `protogen -i foo.proto` keep working unchanged.
//
//  Dual-compilation: dcc64 (Delphi 10.4+) and fpc trunk 3.3.1 {$MODE DELPHI}.
// =============================================================================

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections,
{$IFEND}
  Protogen.Ast;

type
  EProtoImportError = class(Exception);

  { One .proto in the closure. Owns its AST. }
  TProtoFileEntry = class
  public
    ImportPath: string;   // identity: 'google/rpc/status.proto'
    DiskPath:   string;   // where it was found
    UnitPrefix: string;   // 'Demo.Google.Rpc.Status'
    Node:       TProtoFileNode;
    IsRoot:     Boolean;
    destructor Destroy; override;
  end;

  { A resolved type reference: which file declares it, and what it is. }
  TProtoTypeRef = record
    Entry:     TProtoFileEntry;  // nil when the type is a bundled WKT
    Msg:       TProtoMessageNode;
    Enum:      TProtoEnumNode;
    WktClass:  string;           // non-empty for a bundled well-known type
    Found:     Boolean;
  end;

  TProtoFileSet = class
  private
    FRoots:      TStringList;
    FFiles:      TObjectList<TProtoFileEntry>;
    FByImport:   TDictionary<string, TProtoFileEntry>;
    FUnitPrefix: string;
    FLoading:    TStringList;   // the current import chain, for cycle reports
    function  ResolveOnRoots(const AImportPath: string): string;
    function  LoadOne(const AImportPath: string; AIsRoot: Boolean): TProtoFileEntry;
    procedure LoadImportsOf(AEntry: TProtoFileEntry);
    function  FullyQualified(AEntry: TProtoFileEntry;
      const AQualifiedName: string): string;
    function  GetRootEntry: TProtoFileEntry;
  public
    constructor Create(const AUnitPrefix: string);
    destructor Destroy; override;

    // Include roots, searched in order. Add none and LoadRoot uses the input
    // file's own directory.
    procedure AddRoot(const ADir: string);

    // Load AInputFile and everything it imports, transitively.
    // Raises EProtoImportError for a missing import or an import cycle.
    procedure LoadRoot(const AInputFile: string);

    // Resolve a type reference as written in AFrom against AFrom and
    // everything it can see. Result.Found is False when nothing matches.
    //
    // AScope is the QualifiedName of the message the reference sits INSIDE
    // ('' at file scope). proto resolution is innermost-outward, and without
    // the scope a bare name cannot be resolved correctly when two messages
    // each nest a type of the same name. google/cloud/gkehub does exactly
    // that: MembershipSpec nests an ENUM called ControlPlaneManagement and
    // MembershipState nests a MESSAGE of the same name, and each refers to
    // its own by the bare name. Picking by simple name alone silently binds
    // one of them to the other's type.
    //
    // (Written with // deliberately -- the proto snippet this replaced put
    // braces inside a brace comment. See tests/brace-scan.py.)
    function ResolveType(AFrom: TProtoFileEntry;
      const ATypeName: string; const AScope: string = ''): TProtoTypeRef;

    // Files AFrom may reference: itself, its direct imports, and anything
    // reachable through a chain of `import public`.
    function VisibleFrom(AFrom: TProtoFileEntry): TArray<TProtoFileEntry>;

    // 'google/rpc/status.proto' -> 'Google.Rpc.Status'. Public because it is
    // the naming contract and its gate test asserts on it directly.
    class function UnitPathPart(const AImportPath: string): string;

    property Files: TObjectList<TProtoFileEntry> read FFiles;
    property Root: TProtoFileEntry read GetRootEntry;
  end;

implementation

uses
  Protogen.Parser;

{ Imports satisfied WITHOUT loading a file. Two groups, for two reasons, and
  the distinction matters:

  1. BUNDLED — this library ships Pascal for every type in them
     (Nghttp2.Protobuf.WellKnown), so an import resolves to that unit rather
     than to generated code. File-level twin of WellKnownPascalClass in
     Protogen.Ast, which is type-level; the two must agree, or a schema
     resolves the import and then fails on the type.

  2. REFERENCED BY NOTHING — google/protobuf/descriptor.proto. It is imported
     only to declare custom options, and a proto3 `extend` block declaring one
     is skipped by the parser, so no type from it is ever named. It is also
     proto2, so parsing it would fail; and it ships with protobuf rather than
     with a schema repository, so it is usually absent from the tree being
     generated. A schema that DOES name DescriptorProto as a field type is
     refused by the parser before any of this, which is what makes ignoring
     the import safe rather than a shortcut.

     Measured: it was the single blocker for 162 of 305 googleapis schemas in
     the first corpus run that followed imports. }
function IsImportSatisfiedInternally(const AImportPath: string): Boolean;
var
  L: string;
begin
  L := LowerCase(StringReplace(AImportPath, '\', '/', [rfReplaceAll]));
  Result :=
    // 1. bundled
    (L = 'google/protobuf/timestamp.proto')  or
    (L = 'google/protobuf/duration.proto')   or
    (L = 'google/protobuf/empty.proto')      or
    (L = 'google/protobuf/field_mask.proto') or
    (L = 'google/protobuf/wrappers.proto')   or
    (L = 'google/protobuf/struct.proto')     or
    (L = 'google/protobuf/any.proto')        or
    // 2. referenced by nothing we emit
    (L = 'google/protobuf/descriptor.proto');
end;

function NormalizeSlashes(const APath: string): string;
begin
  Result := StringReplace(APath, '\', '/', [rfReplaceAll]);
end;

// ── TProtoFileEntry ──────────────────────────────────────────────────────────

destructor TProtoFileEntry.Destroy;
begin
  Node.Free;
  inherited Destroy;
end;

// ── unit naming ──────────────────────────────────────────────────────────────

{ One path segment to one Pascal namespace segment.
  'field_behavior' -> 'FieldBehavior', 'v1beta1' -> 'V1beta1'.

  Three guards, each for a case the googleapis corpus actually contains:
    - a leading digit cannot start a Pascal identifier
    - a reserved word cannot be a namespace segment, and 'type.proto' is a
      real file (google/protobuf/type.proto)
    - anything that is not alphanumeric is dropped rather than emitted }
function SegmentToPascal(const ASegment: string): string;
var
  I: Integer;
  LUpNext: Boolean;
  C: Char;
begin
  Result := '';
  LUpNext := True;
  for I := 1 to Length(ASegment) do
  begin
    C := ASegment[I];
    if (C = '_') or (C = '-') or (C = '.') or (C = ' ') then
    begin
      LUpNext := True;
      Continue;
    end;
    if not ( ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z'))
             or ((C >= '0') and (C <= '9')) ) then
      Continue;
    if LUpNext then
      Result := Result + UpCase(C)
    else
      Result := Result + C;
    LUpNext := False;
  end;
  if Result = '' then
    Exit;
  if (Result[1] >= '0') and (Result[1] <= '9') then
    Result := '_' + Result;
  if IsDelphiReservedWord(LowerCase(Result)) then
    Result := Result + '_';
end;

class function TProtoFileSet.UnitPathPart(const AImportPath: string): string;
var
  LPath: string;
  LParts: TStringList;
  I: Integer;
  LSeg: string;
begin
  LPath := NormalizeSlashes(AImportPath);
  // Drop the .proto extension — it is not part of the identity.
  if (Length(LPath) > 6) and SameText(Copy(LPath, Length(LPath) - 5, 6), '.proto') then
    LPath := Copy(LPath, 1, Length(LPath) - 6);

  Result := '';
  LParts := TStringList.Create;
  try
    LParts.Delimiter := '/';
    LParts.StrictDelimiter := True;
    LParts.DelimitedText := LPath;
    for I := 0 to LParts.Count - 1 do
    begin
      LSeg := SegmentToPascal(LParts[I]);
      if LSeg = '' then
        Continue;
      if Result <> '' then
        Result := Result + '.';
      Result := Result + LSeg;
    end;
  finally
    LParts.Free;
  end;
  if Result = '' then
    Result := 'Proto';
end;

// ── TProtoFileSet ────────────────────────────────────────────────────────────

constructor TProtoFileSet.Create(const AUnitPrefix: string);
begin
  inherited Create;
  FUnitPrefix := AUnitPrefix;
  FRoots      := TStringList.Create;
  FFiles      := TObjectList<TProtoFileEntry>.Create(True);
  FByImport   := TDictionary<string, TProtoFileEntry>.Create;
  FLoading    := TStringList.Create;
end;

destructor TProtoFileSet.Destroy;
begin
  FLoading.Free;
  FByImport.Free;
  FFiles.Free;
  FRoots.Free;
  inherited Destroy;
end;

procedure TProtoFileSet.AddRoot(const ADir: string);
begin
  if ADir <> '' then
    FRoots.Add(ExcludeTrailingPathDelimiter(ADir));
end;

function TProtoFileSet.GetRootEntry: TProtoFileEntry;
var
  I: Integer;
begin
  for I := 0 to FFiles.Count - 1 do
    if FFiles[I].IsRoot then
      Exit(FFiles[I]);
  Result := nil;
end;

function TProtoFileSet.ResolveOnRoots(const AImportPath: string): string;
var
  I: Integer;
  LCandidate: string;
begin
  for I := 0 to FRoots.Count - 1 do
  begin
    LCandidate := IncludeTrailingPathDelimiter(FRoots[I])
      + StringReplace(AImportPath, '/', PathDelim, [rfReplaceAll]);
    if FileExists(LCandidate) then
      Exit(LCandidate);
  end;
  Result := '';
end;

function TProtoFileSet.LoadOne(const AImportPath: string;
  AIsRoot: Boolean): TProtoFileEntry;
var
  LDisk:    string;
  LContent: TStringList;
  LParser:  TProtoParser;
  LEntry:   TProtoFileEntry;
begin
  if FByImport.TryGetValue(AImportPath, Result) then
    Exit;

  LDisk := ResolveOnRoots(AImportPath);
  if LDisk = '' then
    raise EProtoImportError.CreateFmt(
      'import "%s" not found on any include path. Searched %d root(s): %s. ' +
      'Add the directory containing it with -I.',
      [AImportPath, FRoots.Count, FRoots.CommaText]);

  LEntry := TProtoFileEntry.Create;
  try
    LEntry.ImportPath := AImportPath;
    LEntry.DiskPath   := LDisk;
    LEntry.IsRoot     := AIsRoot;
    LEntry.UnitPrefix := FUnitPrefix + '.' + UnitPathPart(AImportPath);

    LContent := TStringList.Create;
    LParser  := nil;
    try
      LContent.LoadFromFile(LDisk);
      LParser := TProtoParser.Create(LContent.Text, LDisk);
      LEntry.Node := LParser.Parse;
    finally
      LParser.Free;
      LContent.Free;
    end;
  except
    LEntry.Free;
    raise;
  end;

  FFiles.Add(LEntry);
  FByImport.Add(AImportPath, LEntry);
  Result := LEntry;
end;

procedure TProtoFileSet.LoadImportsOf(AEntry: TProtoFileEntry);
var
  I: Integer;
  LImport: string;
  LChild: TProtoFileEntry;
begin
  // Cycle detection. protoc forbids import cycles outright, and without this
  // the recursion below simply does not terminate. The chain is reported
  // because "cycle detected" without the path is a puzzle, not a diagnostic.
  if FLoading.IndexOf(AEntry.ImportPath) >= 0 then
    raise EProtoImportError.CreateFmt('import cycle: %s -> %s',
      [StringReplace(FLoading.CommaText, ',', ' -> ', [rfReplaceAll]),
       AEntry.ImportPath]);
  FLoading.Add(AEntry.ImportPath);
  try
    for I := 0 to AEntry.Node.Imports.Count - 1 do
    begin
      LImport := NormalizeSlashes(AEntry.Node.Imports[I]);
      if IsImportSatisfiedInternally(LImport) then
        Continue;
      LChild := LoadOne(LImport, False);
      LoadImportsOf(LChild);
    end;
  finally
    FLoading.Delete(FLoading.IndexOf(AEntry.ImportPath));
  end;
end;

procedure TProtoFileSet.LoadRoot(const AInputFile: string);
var
  LDir:     string;
  LImport:  string;
  I:        Integer;
  LRootDir: string;
  LEntry:   TProtoFileEntry;
begin
  if not FileExists(AInputFile) then
    raise EProtoImportError.CreateFmt('not found: %s', [AInputFile]);

  // No -I given: the input's own directory becomes the single root, so that
  // `protogen -i foo.proto` behaves exactly as it did before IMPORT-1.
  if FRoots.Count = 0 then
    AddRoot(ExtractFileDir(ExpandFileName(AInputFile)));

  // The root's IDENTITY is its path relative to whichever include root
  // contains it — not its basename. Getting this wrong means a file reached
  // once as the root and once as an import is loaded twice under two unit
  // names, which is precisely the duplicate-class hazard the path-derived
  // naming scheme exists to prevent.
  LDir    := NormalizeSlashes(ExpandFileName(AInputFile));
  LImport := '';
  for I := 0 to FRoots.Count - 1 do
  begin
    LRootDir := NormalizeSlashes(
      IncludeTrailingPathDelimiter(ExpandFileName(FRoots[I])));
    if (Length(LDir) > Length(LRootDir))
      and SameText(Copy(LDir, 1, Length(LRootDir)), LRootDir) then
    begin
      LImport := Copy(LDir, Length(LRootDir) + 1, MaxInt);
      Break;
    end;
  end;
  if LImport = '' then
    LImport := ExtractFileName(LDir);

  LEntry := LoadOne(LImport, True);
  LoadImportsOf(LEntry);
end;

// ── visibility ───────────────────────────────────────────────────────────────

function TProtoFileSet.VisibleFrom(AFrom: TProtoFileEntry): TArray<TProtoFileEntry>;
var
  LSeen:  TStringList;
  LQueue: TObjectList<TProtoFileEntry>;
  LOut:   TList<TProtoFileEntry>;
  I, K:   Integer;
  LCur:   TProtoFileEntry;
  LChild: TProtoFileEntry;
  LImp:   string;
begin
  LSeen  := TStringList.Create;
  LOut   := TList<TProtoFileEntry>.Create;
  LQueue := TObjectList<TProtoFileEntry>.Create(False);  // does NOT own
  try
    LQueue.Add(AFrom);
    LSeen.Add(AFrom.ImportPath);
    K := 0;
    while K < LQueue.Count do
    begin
      LCur := LQueue[K];
      Inc(K);
      LOut.Add(LCur);
      for I := 0 to LCur.Node.Imports.Count - 1 do
      begin
        LImp := NormalizeSlashes(LCur.Node.Imports[I]);
        if IsImportSatisfiedInternally(LImp) then
          Continue;
        // A direct import of AFrom is visible; deeper than that only through
        // `import public`, which is what makes a re-export chain work.
        if (LCur <> AFrom) and (LCur.Node.PublicImports.IndexOf(LImp) < 0) then
          Continue;
        if LSeen.IndexOf(LImp) >= 0 then
          Continue;
        if not FByImport.TryGetValue(LImp, LChild) then
          Continue;
        LSeen.Add(LImp);
        LQueue.Add(LChild);
      end;
    end;
    Result := LOut.ToArray;
  finally
    LQueue.Free;
    LOut.Free;
    LSeen.Free;
  end;
end;

// ── type resolution ──────────────────────────────────────────────────────────

function TProtoFileSet.FullyQualified(AEntry: TProtoFileEntry;
  const AQualifiedName: string): string;
begin
  if AEntry.Node.PackageName = '' then
    Result := AQualifiedName
  else
    Result := AEntry.Node.PackageName + '.' + AQualifiedName;
end;

function TProtoFileSet.ResolveType(AFrom: TProtoFileEntry;
  const ATypeName: string; const AScope: string): TProtoTypeRef;
var
  LVisible: TArray<TProtoFileEntry>;
  LName:    string;
  LWkt:     string;
  LEntry:   TProtoFileEntry;
  // Written by the nested Sweep, read after it returns. Locals of the ENCLOSING
  // routine rather than out-params because Sweep is called from three places
  // and threading two out-params through each would say nothing extra.
  LResMsg:  TProtoMessageNode;
  LResEnum: TProtoEnumNode;
  LPkg:     string;
  LTrim:    string;
  LDot:     Integer;
  LFound:   Boolean;

  // Match AWanted — a FULLY QUALIFIED proto name — against one file.
  // Reports through out-params, not through the enclosing Result: inside a
  // nested routine the outer function's own name is a recursive CALL rather
  // than its result variable, so `ResolveType.Msg := ...` would compile to
  // something quite different from what it reads as.
  function TryIn(AEntry2: TProtoFileEntry; const AWanted: string;
    out AMsg: TProtoMessageNode; out AEnum: TProtoEnumNode): Boolean;
  var
    K: Integer;
  begin
    AMsg  := nil;
    AEnum := nil;
    for K := 0 to AEntry2.Node.Messages.Count - 1 do
      if SameText(FullyQualified(AEntry2, AEntry2.Node.Messages[K].QualifiedName),
                  AWanted) then
      begin
        AMsg := AEntry2.Node.Messages[K];
        Exit(True);
      end;
    for K := 0 to AEntry2.Node.Enums.Count - 1 do
      if SameText(FullyQualified(AEntry2, AEntry2.Node.Enums[K].QualifiedName),
                  AWanted) then
      begin
        AEnum := AEntry2.Node.Enums[K];
        Exit(True);
      end;
    Result := False;
  end;

  // One resolution attempt across every visible file, in load order.
  function Sweep(const AWanted: string): Boolean;
  var
    N:     Integer;
    LMsg:  TProtoMessageNode;
    LEnum: TProtoEnumNode;
  begin
    for N := 0 to High(LVisible) do
      if TryIn(LVisible[N], AWanted, LMsg, LEnum) then
      begin
        LEntry := LVisible[N];
        Result := True;
        if LMsg <> nil then
        begin
          LResMsg  := LMsg;
          LResEnum := nil;
        end
        else
        begin
          LResMsg  := nil;
          LResEnum := LEnum;
        end;
        Exit;
      end;
    Result := False;
  end;

begin
  Result := Default(TProtoTypeRef);

  // A bundled well-known type wins before any file is consulted — it is
  // satisfied by Nghttp2.Protobuf.WellKnown, not by generated code. This is
  // also what lets a schema importing only WKTs resolve with no include roots.
  LWkt := WellKnownPascalClass(ATypeName);
  if LWkt <> '' then
  begin
    Result.WktClass := LWkt;
    Result.Found    := True;
    Exit;
  end;

  LName    := ATypeName;
  LVisible := VisibleFrom(AFrom);
  LEntry   := nil;

  if (Length(LName) > 0) and (LName[1] = '.') then
  begin
    // Leading dot: already fully qualified, so no package-relative retry.
    Delete(LName, 1, 1);
    if Sweep(LName) then
    begin
      Result.Entry := LEntry;
      Result.Msg   := LResMsg;
      Result.Enum  := LResEnum;
      Result.Found := True;
    end;
    Exit;
  end;

  { Innermost-outward, the way protoc resolves. For `N` written inside
    `pkg.A.B`, the candidates are pkg.A.B.N, then pkg.A.N, then pkg.N, then N
    as an already-qualified name — first hit wins, so a type nested in the
    ENCLOSING message beats a same-named type nested in a sibling.

    Trying the bare name first (what this did before) inverts that: the
    outermost match wins and a nested reference silently binds to whichever
    declaration the file happens to list first. }
  LPkg   := AFrom.Node.PackageName;
  LTrim  := AScope;
  LFound := False;
  while (not LFound) and (LTrim <> '') do
  begin
    if LPkg <> '' then
      LFound := Sweep(LPkg + '.' + LTrim + '.' + LName)
    else
      LFound := Sweep(LTrim + '.' + LName);
    if LFound then
      Break;
    LDot := LastDelimiter('.', LTrim);
    if LDot > 0 then
      LTrim := Copy(LTrim, 1, LDot - 1)
    else
      LTrim := '';
  end;

  if not LFound then
    if LPkg <> '' then
      LFound := Sweep(LPkg + '.' + LName);

  if not LFound then
    LFound := Sweep(LName);

  if not LFound then
    Exit;

  Result.Entry := LEntry;
  Result.Msg   := LResMsg;
  Result.Enum  := LResEnum;
  Result.Found := True;
end;

end.
