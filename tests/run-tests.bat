@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  run-tests.bat — build and run this library's test programs with dcc64.
REM
REM  The Windows counterpart to build-codec-fpc.sh. Same stages, same gating:
REM
REM    1  Nghttp2ProtobufTests            build + run   (gates)
REM    2  Nghttp2ProtobufNegativeTests    build + run   (gates)
REM    3  Nghttp2AllocBench               build + run   (reports, never gates)
REM    4  Nghttp2ProtobufConformance      build + run   (gates on BROKEN only)
REM    5  ProtogenParserTests             build + run   (gates) - in
REM                                                     ..\tools\protogen
REM
REM  The protoc oracle (C1b) is NOT run here. It is a bash script, and the
REM  Windows story for it is `wsl bash protoc-oracle.sh` or running it from the
REM  Linux side. Its verdicts are platform-independent, so once is enough.
REM
REM  Stage 4 is gated even though it is a "report", and that is not an
REM  inconsistency: the program itself decides. It exits 0 when it finds
REM  DEVIATES rows — those are findings about proto3 conformance, not test
REM  failures — and non-zero ONLY when a probe BROKEN s, meaning something that
REM  should have held did not. So GATES=1 here catches exactly the case worth
REM  stopping for. See plans/horse-grpc-codegen.md C0a.
REM
REM  Stage 4 also carries the one path FPC cannot reach. FIX-PROTO-UINT32-1
REM  guards UInt64 differently per compiler — FPC types it tkQWord, Delphi has
REM  no unsigned-64 kind and types it tkInt64, handled by a TypeInfo(UInt64)
REM  comparison inside {$ELSE}. FPC never compiles that arm. THIS is where it
REM  gets exercised.
REM
REM  Exists because until 2026-08-24 these were compiled by hand, every time,
REM  from a command line nobody had written down. A regression suite that only
REM  runs when somebody remembers is one refactor away from being decorative —
REM  and stage 2 is what stops five malformed-input defects coming back.
REM
REM  Usage:
REM    cd tests
REM    run-tests.bat
REM
REM  Override Delphi discovery:
REM    set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
REM
REM  Exit code: number of failing stages. 0 means everything passed.
REM
REM  ---------------------------------------------------------------------
REM  NO PARENTHESISED BLOCKS ANYWHERE IN THIS FILE.
REM
REM  Delphi lives under "C:\Program Files (x86)\...". cmd matches parens BEFORE
REM  expanding variables, so any %VAR% holding that path closes an ( ) block
REM  early and the script fails in a way that looks nothing like its cause. It
REM  is the variable's VALUE that breaks it, not its name. Every branch here
REM  uses goto, and every path variable is read with delayed expansion !VAR!.
REM  The same rule, and the same reason, is documented at length in
REM  horse-provider-nghttp2\scripts\build-dcc-fixed.bat.
REM
REM  -B on every compile, deliberately. A .dcu built with different defines is
REM  NOT invalidated by changing them — dcc compares timestamps, not the define
REM  set — and the failure is silent: you measure or test the wrong binary with
REM  no diagnostic. These suites are small; a full build costs under a second.
REM ===========================================================================

set "FAILED=0"
REM Unit search path for :build_run. Every stage in tests\ wants ..\src; the
REM protogen stage overrides it and restores this afterwards.
set "STAGEUNITS=..\src"

REM -- Locate dcc64 ----------------------------------------------------------
set "DCC="
if not "%DELPHI_ROOT%"=="" if exist "%DELPHI_ROOT%\bin\dcc64.exe" set "DCC=%DELPHI_ROOT%\bin\dcc64.exe"
if not "%BDS%"=="" if exist "%BDS%\bin\dcc64.exe" set "DCC=%BDS%\bin\dcc64.exe"
if not defined DCC for /f "delims=" %%I in ('where dcc64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

echo dcc64:  !DCC!
echo Source: ..\src
echo.

REM -- Stages ----------------------------------------------------------------
set "STAGE=Nghttp2ProtobufTests"
set "GATES=1"
call :build_run

set "STAGE=Nghttp2ProtobufNegativeTests"
set "GATES=1"
call :build_run

set "STAGE=Nghttp2AllocBench"
set "GATES=0"
call :build_run

set "STAGE=Nghttp2ProtobufConformance"
set "GATES=1"
call :build_run

REM -- protogen parser (C1). Lives in ..\tools\protogen, not here, so this is
REM    the one stage that changes directory. Its units are pure RTL and pull in
REM    no Nghttp2 unit, so STAGEUNITS is "." rather than ..\src -- if it ever
REM    stops compiling that way, something has coupled the generator to the
REM    codec, which is worth discovering here.
if not exist "..\tools\protogen\ProtogenParserTests.dpr" goto :no_protogen
pushd "..\tools\protogen"
set "STAGE=ProtogenParserTests"
set "GATES=1"
set "STAGEUNITS=."
call :build_run
popd
set "STAGEUNITS=..\src"
goto :after_protogen

:no_protogen
echo -- ProtogenParserTests ---------------------------------------------------------------
echo    SKIP  ..\tools\protogen not present

:after_protogen

echo.
echo ===========================================================================
if "!FAILED!"=="0" goto :all_ok
echo  FAILED  - !FAILED! stage^(s^) did not pass
exit /b !FAILED!

:all_ok
echo  ALL STAGES PASSED
exit /b 0

REM ===========================================================================
:build_run
echo -- !STAGE! ---------------------------------------------------------------
if not exist "!STAGE!.dpr" goto :br_missing

"!DCC!" -CC -B -U"!STAGEUNITS!" "!STAGE!.dpr" > "!STAGE!.buildlog" 2>&1
if errorlevel 1 goto :br_buildfail
if not exist "!STAGE!.exe" goto :br_buildfail

"!STAGE!.exe" < nul
set "RC=!errorlevel!"
REM The codec suite ends on a ReadLn prompt with no trailing newline, so
REM without this the verdict below lands on the same row as it.
echo.

if "!GATES!"=="0" goto :br_report
if not "!RC!"=="0" goto :br_runfail
echo    PASS  !STAGE!
goto :eof

:br_report
echo    ^(report only - exit code !RC! ignored by design; this stage measures
echo     a NUMBER, and gating it would mean inventing a threshold^)
goto :eof

:br_runfail
echo    FAIL  !STAGE! - !RC! check^(s^) failed
set /a FAILED+=1
goto :eof

:br_buildfail
echo    FAIL  !STAGE! did not compile
findstr /C:"Error" /C:"Fatal" "!STAGE!.buildlog"
echo.
echo    If that says F2039 "Could not create output file", the compile
echo    SUCCEEDED and only the write failed: the exe is still running and
echo    holding its own image. Nothing is wrong with the source.
echo        taskkill /IM !STAGE!.exe /F
echo.
echo    Full log: !STAGE!.buildlog
set /a FAILED+=1
goto :eof

:br_missing
echo    SKIP  !STAGE!.dpr not present
goto :eof

REM ===========================================================================
:no_dcc
echo ERROR: dcc64.exe not found.
echo        Set DELPHI_ROOT, e.g.
echo            set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
echo        or run this from a shell where rsvars.bat has been called.
exit /b 2
