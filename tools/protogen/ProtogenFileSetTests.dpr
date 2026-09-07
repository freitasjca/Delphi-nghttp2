program ProtogenFileSetTests;

// =============================================================================
//  ProtogenFileSetTests — IMPORT-1 gate.
//
//  Covers TProtoFileSet: include-root resolution, the transitive closure,
//  unit naming, visibility, and cross-file type resolution.
//
//  Three of these assert on things going WRONG, and they are the point:
//
//    - a missing import must RAISE, not fall through. The defect IMPORT-1
//      fixes is exactly a silent fall-through that produced an undeclared
//      identifier, so a resolver that quietly returns nothing rebuilds it one
//      layer up.
//    - an import CYCLE must raise rather than recurse forever.
//    - a file imported NON-publicly by an import must NOT be visible. Without
//      this the resolver degenerates into "search the whole closure", which
//      accepts schemas protoc rejects and, worse, resolves a name to a type
//      the schema never asked for.
//
//  Build (FPC trunk):
//    fpc -MDelphi -O1 -Fu. ProtogenFileSetTests.dpr
//  Build (Windows):
//    dcc64 -CC -B -U. ProtogenFileSetTests.dpr
// =============================================================================

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$IFEND}

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes, System.IOUtils,
{$IFEND}
  Protogen.Ast,
  Protogen.Lexer,
  Protogen.Parser,
  Protogen.FileSet;

var
  GPass:    Integer = 0;
  GFail:    Integer = 0;
  GTestDir: string;

procedure Section(const S: string);
begin
  WriteLn;
  WriteLn('-- ', S);
end;

procedure Check(const AName: string; APassed: Boolean;
  const ADetail: string = '');
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

// ── Helpers ──────────────────────────────────────────────────────────────────

procedure PutFile(const ARelPath, AContent: string);
var
  LPath: string;
  F: TextFile;
begin
  LPath := IncludeTrailingPathDelimiter(GTestDir)
    + StringReplace(ARelPath, '/', PathDelim, [rfReplaceAll]);
  ForceDirectories(ExtractFileDir(LPath));
  AssignFile(F, LPath);
  Rewrite(F);
  try
    Write(F, AContent);
  finally
    CloseFile(F);
  end;
end;

function AbsPath(const ARelPath: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GTestDir)
    + StringReplace(ARelPath, '/', PathDelim, [rfReplaceAll]);
end;

function EntryFor(AFS: TProtoFileSet; const AImportPath: string): TProtoFileEntry;
var
  I: Integer;
begin
  for I := 0 to AFS.Files.Count - 1 do
    if AFS.Files[I].ImportPath = AImportPath then
      Exit(AFS.Files[I]);
  Result := nil;
end;

function CanSee(AFS: TProtoFileSet; AFrom: TProtoFileEntry;
  const AImportPath: string): Boolean;
var
  LVis: TArray<TProtoFileEntry>;
  I: Integer;
begin
  LVis := AFS.VisibleFrom(AFrom);
  for I := 0 to High(LVis) do
    if LVis[I].ImportPath = AImportPath then
      Exit(True);
  Result := False;
end;

// ── 1. Unit naming ───────────────────────────────────────────────────────────

procedure TestUnitNaming;
begin
  Section('unit naming — one proto path, one Pascal namespace');

  Check('plain stem',
    TProtoFileSet.UnitPathPart('helloworld.proto') = 'Helloworld',
    TProtoFileSet.UnitPathPart('helloworld.proto'));

  Check('nested path',
    TProtoFileSet.UnitPathPart('google/rpc/status.proto') = 'Google.Rpc.Status',
    TProtoFileSet.UnitPathPart('google/rpc/status.proto'));

  Check('snake_case segment PascalCased',
    TProtoFileSet.UnitPathPart('google/api/field_behavior.proto')
      = 'Google.Api.FieldBehavior',
    TProtoFileSet.UnitPathPart('google/api/field_behavior.proto'));

  Check('hyphen is a word break too',
    TProtoFileSet.UnitPathPart('a-b/c.proto') = 'AB.C',
    TProtoFileSet.UnitPathPart('a-b/c.proto'));

  // google/protobuf/type.proto is a REAL file, and `Demo.Type` is not a legal
  // unit name. This is why IsDelphiReservedWord had to move to Protogen.Ast.
  Check('reserved word segment is escaped',
    TProtoFileSet.UnitPathPart('google/protobuf/type.proto')
      = 'Google.Protobuf.Type_',
    TProtoFileSet.UnitPathPart('google/protobuf/type.proto'));

  // A Pascal identifier cannot begin with a digit.
  Check('leading digit is escaped',
    TProtoFileSet.UnitPathPart('v1/2fa.proto') = 'V1._2fa',
    TProtoFileSet.UnitPathPart('v1/2fa.proto'));

  Check('version segment kept as written',
    TProtoFileSet.UnitPathPart('google/api/v1beta1/x.proto')
      = 'Google.Api.V1beta1.X',
    TProtoFileSet.UnitPathPart('google/api/v1beta1/x.proto'));

  Check('backslashes normalise to the same name',
    TProtoFileSet.UnitPathPart('google\rpc\status.proto') = 'Google.Rpc.Status',
    TProtoFileSet.UnitPathPart('google\rpc\status.proto'));
end;

// ── 2. Closure ───────────────────────────────────────────────────────────────

function LeafPrefix(AEntry: TProtoFileEntry): string;
begin
  if AEntry = nil then
    Result := '<not loaded>'
  else
    Result := AEntry.UnitPrefix;
end;

procedure TestClosure;
var
  LFS:   TProtoFileSet;
  LLeaf: TProtoFileEntry;
begin
  Section('transitive closure');

  PutFile('c/root.proto',
    'syntax = "proto3";'#10 +
    'package demo;'#10 +
    'import "c/mid.proto";'#10 +
    'message Root { demo.mid.Mid m = 1; }'#10);
  PutFile('c/mid.proto',
    'syntax = "proto3";'#10 +
    'package demo.mid;'#10 +
    'import "c/leaf.proto";'#10 +
    'message Mid { demo.leaf.Leaf l = 1; }'#10);
  PutFile('c/leaf.proto',
    'syntax = "proto3";'#10 +
    'package demo.leaf;'#10 +
    'message Leaf { string s = 1; }'#10);

  LFS := TProtoFileSet.Create('Demo');
  try
    LFS.AddRoot(GTestDir);
    LFS.LoadRoot(AbsPath('c/root.proto'));

    Check('three files loaded', LFS.Files.Count = 3,
      IntToStr(LFS.Files.Count));
    Check('root identified', (LFS.Root <> nil)
      and (LFS.Root.ImportPath = 'c/root.proto'));
    LLeaf := EntryFor(LFS, 'c/leaf.proto');
    Check('leaf reached transitively', LLeaf <> nil);
    // Bind it first: Check's detail argument is evaluated eagerly, so reading
    // .UnitPrefix off a nil entry would abort the run instead of failing one
    // assertion and carrying on.
    Check('unit prefix is path-derived',
      (LLeaf <> nil) and (LLeaf.UnitPrefix = 'Demo.C.Leaf'),
      LeafPrefix(LLeaf));

    // The root's identity is its path RELATIVE TO THE INCLUDE ROOT, not its
    // basename — otherwise a file reached once as a root and once as an import
    // loads twice under two unit names, which is the duplicate-class hazard
    // the path-derived scheme exists to prevent.
    Check('root identity is root-relative, not a basename',
      LFS.Root.ImportPath = 'c/root.proto', LFS.Root.ImportPath);
  finally
    LFS.Free;
  end;
end;

procedure TestDiamondLoadsOnce;
var
  LFS: TProtoFileSet;
begin
  Section('a diamond loads the shared file once');

  PutFile('d/top.proto',
    'syntax = "proto3";'#10 +
    'import "d/left.proto";'#10 +
    'import "d/right.proto";'#10 +
    'message Top { string s = 1; }'#10);
  PutFile('d/left.proto',
    'syntax = "proto3";'#10 + 'import "d/base.proto";'#10 +
    'message L { string s = 1; }'#10);
  PutFile('d/right.proto',
    'syntax = "proto3";'#10 + 'import "d/base.proto";'#10 +
    'message R { string s = 1; }'#10);
  PutFile('d/base.proto',
    'syntax = "proto3";'#10 + 'message B { string s = 1; }'#10);

  LFS := TProtoFileSet.Create('Demo');
  try
    LFS.AddRoot(GTestDir);
    LFS.LoadRoot(AbsPath('d/top.proto'));
    Check('four files, base not duplicated', LFS.Files.Count = 4,
      IntToStr(LFS.Files.Count));
  finally
    LFS.Free;
  end;
end;

// ── 3. Failures that must be loud ────────────────────────────────────────────

procedure TestMissingImportRaises;
var
  LFS: TProtoFileSet;
  LRaised: Boolean;
  LMsg: string;
begin
  Section('a missing import RAISES (the whole point of IMPORT-1)');

  PutFile('m/root.proto',
    'syntax = "proto3";'#10 +
    'import "m/nope.proto";'#10 +
    'message Root { string s = 1; }'#10);

  LRaised := False;
  LMsg := '';
  LFS := TProtoFileSet.Create('Demo');
  try
    LFS.AddRoot(GTestDir);
    try
      LFS.LoadRoot(AbsPath('m/root.proto'));
    except
      on E: EProtoImportError do
      begin
        LRaised := True;
        LMsg := E.Message;
      end;
    end;
  finally
    LFS.Free;
  end;

  Check('raised EProtoImportError', LRaised);
  // A diagnostic that does not name the file or say how to fix it costs the
  // reader a grep. Assert on both.
  Check('names the missing path', Pos('m/nope.proto', LMsg) > 0, LMsg);
  Check('says how to fix it', Pos('-I', LMsg) > 0, LMsg);
end;

procedure TestCycleRaises;
var
  LFS: TProtoFileSet;
  LRaised: Boolean;
  LMsg: string;
begin
  Section('an import cycle RAISES rather than recursing forever');

  PutFile('y/a.proto',
    'syntax = "proto3";'#10 + 'import "y/b.proto";'#10 +
    'message A { string s = 1; }'#10);
  PutFile('y/b.proto',
    'syntax = "proto3";'#10 + 'import "y/a.proto";'#10 +
    'message B { string s = 1; }'#10);

  LRaised := False;
  LMsg := '';
  LFS := TProtoFileSet.Create('Demo');
  try
    LFS.AddRoot(GTestDir);
    try
      LFS.LoadRoot(AbsPath('y/a.proto'));
    except
      on E: EProtoImportError do
      begin
        LRaised := True;
        LMsg := E.Message;
      end;
    end;
  finally
    LFS.Free;
  end;

  Check('raised on the cycle', LRaised);
  Check('reports the chain', Pos('y/a.proto', LMsg) > 0, LMsg);
end;

// ── 4. Bundled WKTs are never resolved on disk ───────────────────────────────

procedure TestBundledWktNotResolved;
var
  LFS: TProtoFileSet;
  LRef: TProtoTypeRef;
begin
  Section('a bundled WKT import needs no include root and joins no closure');

  PutFile('w/root.proto',
    'syntax = "proto3";'#10 +
    'import "google/protobuf/timestamp.proto";'#10 +
    'message Root { google.protobuf.Timestamp t = 1; }'#10);

  LFS := TProtoFileSet.Create('Demo');
  try
    // Deliberately NO AddRoot for google/protobuf — nothing on disk supplies
    // timestamp.proto. This is what keeps IMPORT-1 from breaking every schema
    // that generates today.
    LFS.AddRoot(GTestDir);
    LFS.LoadRoot(AbsPath('w/root.proto'));

    Check('closure is the root alone', LFS.Files.Count = 1,
      IntToStr(LFS.Files.Count));

    LRef := LFS.ResolveType(LFS.Root, 'google.protobuf.Timestamp');
    Check('WKT resolves', LRef.Found);
    Check('WKT resolves to the bundled class',
      LRef.WktClass = 'TProtobufTimestamp', LRef.WktClass);
    Check('WKT belongs to no generated file', LRef.Entry = nil);
  finally
    LFS.Free;
  end;
end;

// ── 5. Cross-file type resolution ────────────────────────────────────────────

procedure TestCrossFileResolution;
var
  LFS: TProtoFileSet;
  LRef: TProtoTypeRef;
begin
  Section('cross-file type resolution');

  PutFile('r/root.proto',
    'syntax = "proto3";'#10 +
    'package demo;'#10 +
    'import "r/other.proto";'#10 +
    'message Root { other.Thing t = 1; Local l = 2; }'#10 +
    'message Local { string s = 1; }'#10);
  PutFile('r/other.proto',
    'syntax = "proto3";'#10 +
    'package other;'#10 +
    'message Thing { string s = 1; }'#10 +
    'enum Colour { COLOUR_UNSET = 0; RED = 1; }'#10);

  LFS := TProtoFileSet.Create('Demo');
  try
    LFS.AddRoot(GTestDir);
    LFS.LoadRoot(AbsPath('r/root.proto'));

    LRef := LFS.ResolveType(LFS.Root, 'other.Thing');
    Check('imported message resolves', LRef.Found);
    Check('resolves to the DECLARING file',
      LRef.Found and (LRef.Entry <> nil)
      and (LRef.Entry.ImportPath = 'r/other.proto'));
    Check('resolves to the message node',
      LRef.Found and (LRef.Msg <> nil) and (LRef.Msg.Name = 'Thing'));

    LRef := LFS.ResolveType(LFS.Root, 'other.Colour');
    Check('imported enum resolves as an ENUM',
      LRef.Found and (LRef.Enum <> nil) and (LRef.Msg = nil));

    LRef := LFS.ResolveType(LFS.Root, 'Local');
    Check('same-file type still resolves', LRef.Found);
    Check('same-file type resolves to the root file',
      LRef.Found and (LRef.Entry <> nil)
      and (LRef.Entry.ImportPath = 'r/root.proto'));

    LRef := LFS.ResolveType(LFS.Root, '.other.Thing');
    Check('leading-dot fully-qualified form resolves', LRef.Found);

    LRef := LFS.ResolveType(LFS.Root, 'NoSuchType');
    Check('an unknown type does NOT resolve', not LRef.Found);
  finally
    LFS.Free;
  end;
end;

// ── 6. Visibility — the negative case is the one that matters ────────────────

procedure TestVisibility;
var
  LFS: TProtoFileSet;
  LRef: TProtoTypeRef;
begin
  Section('visibility: direct imports, and `public` re-exports only');

  PutFile('v/root.proto',
    'syntax = "proto3";'#10 +
    'package v;'#10 +
    'import "v/direct.proto";'#10 +
    'message Root { string s = 1; }'#10);
  // direct re-exports pub, but keeps hidden to itself
  PutFile('v/direct.proto',
    'syntax = "proto3";'#10 +
    'package vd;'#10 +
    'import public "v/pub.proto";'#10 +
    'import "v/hidden.proto";'#10 +
    'message Direct { string s = 1; }'#10);
  PutFile('v/pub.proto',
    'syntax = "proto3";'#10 + 'package vp;'#10 +
    'message Pub { string s = 1; }'#10);
  PutFile('v/hidden.proto',
    'syntax = "proto3";'#10 + 'package vh;'#10 +
    'message Hidden { string s = 1; }'#10);

  LFS := TProtoFileSet.Create('Demo');
  try
    LFS.AddRoot(GTestDir);
    LFS.LoadRoot(AbsPath('v/root.proto'));

    Check('all four files are in the CLOSURE', LFS.Files.Count = 4,
      IntToStr(LFS.Files.Count));

    Check('root sees itself', CanSee(LFS, LFS.Root, 'v/root.proto'));
    Check('root sees its direct import',
      CanSee(LFS, LFS.Root, 'v/direct.proto'));
    Check('root sees through `import public`',
      CanSee(LFS, LFS.Root, 'v/pub.proto'));

    // THE assertion of this section. Being in the closure is not being
    // visible; a resolver that skips this accepts schemas protoc rejects and
    // can bind a name to a type the schema never asked for.
    Check('root does NOT see a non-public import of its import',
      not CanSee(LFS, LFS.Root, 'v/hidden.proto'));

    LRef := LFS.ResolveType(LFS.Root, 'vp.Pub');
    Check('a publicly re-exported type resolves', LRef.Found);

    LRef := LFS.ResolveType(LFS.Root, 'vh.Hidden');
    Check('a non-visible type does NOT resolve', not LRef.Found);
  finally
    LFS.Free;
  end;
end;

// ── 7. Include roots ─────────────────────────────────────────────────────────

procedure TestIncludeRoots;
var
  LFS: TProtoFileSet;
begin
  Section('include roots');

  PutFile('roots/one/x/a.proto',
    'syntax = "proto3";'#10 + 'import "x/b.proto";'#10 +
    'message A { string s = 1; }'#10);
  PutFile('roots/two/x/b.proto',
    'syntax = "proto3";'#10 + 'message B { string s = 1; }'#10);

  LFS := TProtoFileSet.Create('Demo');
  try
    LFS.AddRoot(AbsPath('roots/one'));
    LFS.AddRoot(AbsPath('roots/two'));
    LFS.LoadRoot(AbsPath('roots/one/x/a.proto'));
    Check('an import resolves against a LATER root', LFS.Files.Count = 2,
      IntToStr(LFS.Files.Count));
    Check('root path is relative to its own include root',
      LFS.Root.ImportPath = 'x/a.proto', LFS.Root.ImportPath);
  finally
    LFS.Free;
  end;
end;

procedure TestNoRootDefaultsToInputDir;
var
  LFS: TProtoFileSet;
begin
  Section('no -I at all — the pre-IMPORT-1 invocation still works');

  PutFile('solo/only.proto',
    'syntax = "proto3";'#10 + 'message Only { string s = 1; }'#10);

  LFS := TProtoFileSet.Create('Demo');
  try
    // No AddRoot: the input's own directory becomes the single root.
    LFS.LoadRoot(AbsPath('solo/only.proto'));
    Check('loads with no include root configured', LFS.Files.Count = 1);
    Check('identity falls back to the basename',
      LFS.Root.ImportPath = 'only.proto', LFS.Root.ImportPath);
    Check('unit prefix still derived', LFS.Root.UnitPrefix = 'Demo.Only',
      LFS.Root.UnitPrefix);
  finally
    LFS.Free;
  end;
end;

// ── main ─────────────────────────────────────────────────────────────────────

begin
{$IF DEFINED(FPC)}
  GTestDir := GetTempDir + 'pgfileset';
{$ELSE}
  GTestDir := TPath.GetTempPath + PathDelim + 'pgfileset';
{$IFEND}
  ForceDirectories(GTestDir);

  WriteLn('ProtogenFileSetTests (IMPORT-1 gate)');
  TestUnitNaming;
  TestClosure;
  TestDiamondLoadsOnce;
  TestMissingImportRaises;
  TestCycleRaises;
  TestBundledWktNotResolved;
  TestCrossFileResolution;
  TestVisibility;
  TestIncludeRoots;
  TestNoRootDefaultsToInputDir;

  WriteLn;
  WriteLn('Result: ', GPass, ' passed, ', GFail, ' failed');
  if GFail > 0 then
    ExitCode := 1;
end.
