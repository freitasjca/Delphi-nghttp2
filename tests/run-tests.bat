@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  run-tests.bat — build and run this library's test programs with dcc64.
REM
REM  The Windows counterpart to build-codec-fpc.sh. Same stages, same gating:
REM
REM    1  Nghttp2ProtobufTests            build + run   (gates)
REM    2  Nghttp2ProtobufNegativeTests    build + run   (gates)
REM    2b Nghttp2GrpcFramingTests         build + run   (gates) - gRPC framing
REM                                                     + reassembly chunking
REM    2c ProtoOptionalProbe              build + run   (gates) - what this
REM                                                     compiler permits as a
REM                                                     published property
REM    2d ProtoStructProbe                build + run   (reports) - can the
REM                                                     RTTI layer carry the
REM                                                     Struct family here
REM   C6b ProtogenOptionalCompileCheck    build + run   (gates) - compiles AND
REM                                                     runs generated
REM                                                     `optional` code
REM    3  Nghttp2AllocBench               build + run   (reports, never gates)
REM    4  Nghttp2ProtobufConformance      build + run   (gates on BROKEN only)
REM    4b Nghttp2ServerSmoke              build + run   (gates; the only stage
REM                                       that starts a server. Skips LOUDLY
REM                                       when libnghttp2 is absent.)
REM    4c Nghttp2AlpnMismatch             build + run   (gates; the only stage
REM                                       whose PEER is openssl rather than our
REM                                       own server. Skips LOUDLY without it.)
REM    5  ProtogenParserTests             build + run   (gates) - in
REM                                                     ..\tools\protogen
REM    6  ProtogenEmitTests               build + run   (gates) - same dir
REM    7  ProtogenInterfaceTests          build + run   (gates) - same dir
REM    8  ProtogenRunnerTests             build + run   (gates) - same dir
REM    9  Protogen.dpr                    compile only  (gates) - same dir
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
set "SKIPPED=0"
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

REM Stage 2b. gRPC length-prefix framing and, more to the point, reassembly
REM under adversarial chunk boundaries. StreamReader's own header warns that
REM per-frame decoding "works perfectly against a test client that sends one
REM message per frame and corrupts against every real one"; nothing tested that
REM until 2026-09-06. The variable under test is the chop pattern, and the
REM suite asserts the patterns genuinely differed rather than trusting them to.
set "STAGE=Nghttp2GrpcFramingTests"
set "GATES=1"
call :build_run

REM Stage 2c. What may a published property BE on this compiler? Every proto
REM field must be one (Nghttp2.Protobuf.Rtti filters on mvPublished), so this
REM bounds what the codec can express - and it is NOT the same on both
REM compilers: a published record is accepted here and refused by FPC 3.3.1,
REM which is what killed the obvious TProtoOptional<T> design for PRESENCE-1.
REM Gates because a compiler upgrade withdrawing read-only published properties
REM would break PRESENCE-1, and one refusing generic class properties would
REM break the submessage path.
set "STAGE=ProtoOptionalProbe"
set "GATES=1"
call :build_run

REM Stage 2d. The sibling probe, and it was FPC-only until 2026-09-10 - so the
REM Windows suite silently covered less than the Linux one while both reported
REM ALL STAGES PASSED. That asymmetry is the reason to run it here, not the
REM probe's original question: 2c exists precisely BECAUSE the two compilers
REM disagree about what a published property may be, and a capability probe
REM that runs on only one of them answers half the question it was written for.
REM
REM Reports rather than gates, matching the FPC side. It measures a capability,
REM and the Struct family it probes now ships (STRUCT-1), so a NO here is a
REM finding to read rather than a build to stop - the behaviour itself is
REM gated by stages 1 and C6b, which assert what the bundle actually does.
set "STAGE=ProtoStructProbe"
set "GATES=0"
call :build_run

set "STAGE=Nghttp2AllocBench"
set "GATES=0"
call :build_run

set "STAGE=Nghttp2ProtobufConformance"
set "GATES=1"
call :build_run

REM -- Stage 4b. The only stage here that STARTS A SERVER. ------------------
REM
REM Until this existed, `grep -rl TNghttp2Server tests\ tools\` returned
REM nothing: every stage was codec or codegen, and ProtogenGeneratedCompileCheck
REM only REGISTERS services. This suite therefore passed, for years, on a
REM machine with no nghttp2.dll on it - which is exactly what happened, and how
REM the gap was found. "ALL STAGES PASSED" did not mean the transport worked.
REM
REM Drives the library's own client against its own server in one process, so
REM it needs no curl, no grpcurl and no fixture. Exit 3 means libnghttp2 is
REM absent: reported as a LOUD skip rather than a pass, because a quiet skip is
REM indistinguishable from a green stage and that is the failure being fixed.
set "STAGE=Nghttp2ServerSmoke"
set "GATES=1"
set "SKIPRC=3"
call :build_run

REM -- Stage 4c. ALPN refusal (CL2b). The only stage whose PEER is not ours. --
REM
REM Every other TLS check drives our own server, which always selects h2, so
REM the client's "ALPN did not yield h2" raise had never executed anywhere.
REM openssl is the independent peer our own server cannot be.
REM
REM TWO peers run, because they are NOT the same failure. This was measured
REM after a first version of this gate used the wrong one and would have failed
REM on contact:
REM
REM   noalpn     s_server with NO -alpn. ALPN is disabled, the handshake
REM              COMPLETES, and NegotiatedProtocol is empty. This is the ONLY
REM              peer that reaches the client's empty-ALPN branch, so it is the
REM              only one that gates the CL2b message.
REM   nooverlap  s_server -alpn http/1.1. No overlap with our h2, so OpenSSL
REM              sends a FATAL no_application_protocol alert and SSL_connect
REM              fails BEFORE any ALPN check runs. A peer offering only
REM              http/1.1 does NOT select http/1.1.
REM
REM The trap worth recording: openssl s_client prints "No ALPN negotiated" on
REM the way out of a FAILED handshake too, so that line alone is not evidence a
REM session was established. The exit code is.
REM
REM NOT routed through :build_run - that helper runs a bare exe with no
REM arguments, and this program takes host, port and mode.
REM
REM The peer is started in a TITLED window and killed BY THAT TITLE, never by
REM image name: taskkill /IM openssl.exe would kill every openssl process on the
REM developer's machine, not just this one. -naccept 1 means it normally exits
REM by itself once the single connection closes; the kill is belt-and-braces
REM for a handshake that dies before accept returns, which would otherwise
REM leave the port held against the next run.
REM
REM The cert is generated per run into TEMP and never committed. The provider
REM suite's committed 30-day fixtures expired and took 110 checks down with
REM them, reading like a code regression when it was a calendar. A fixture
REM rebuilt every run cannot expire.
if not exist "Nghttp2AlpnMismatch.dpr" goto :no_alpn_dpr

set "OPENSSL="
for /f "delims=" %%I in ('where openssl.exe 2^>nul') do if not defined OPENSSL set "OPENSSL=%%I"
if not defined OPENSSL goto :no_alpn_openssl

echo -- Nghttp2AlpnMismatch ---------------------------------------------------------------
"!DCC!" -CC -B -U"..\src" "Nghttp2AlpnMismatch.dpr" > "Nghttp2AlpnMismatch.buildlog" 2>&1
if errorlevel 1 goto :alpn_buildfail
if not exist "Nghttp2AlpnMismatch.exe" goto :alpn_buildfail

set "ALPNDIR=%TEMP%\nghttp2-alpn"
if exist "!ALPNDIR!" rmdir /s /q "!ALPNDIR!"
mkdir "!ALPNDIR!"
"!OPENSSL!" req -x509 -newkey rsa:2048 -nodes -keyout "!ALPNDIR!\k.pem" -out "!ALPNDIR!\c.pem" -subj "/CN=127.0.0.1" -days 2 > "!ALPNDIR!\cert.log" 2>&1
if not exist "!ALPNDIR!\c.pem" goto :no_alpn_cert
if not exist "!ALPNDIR!\k.pem" goto :no_alpn_cert

set "ALPNPORT=19312"
set "ALPNMODE=noalpn"
set "ALPNARGS="
call :alpn_case

set "ALPNPORT=19313"
set "ALPNMODE=nooverlap"
set "ALPNARGS=-alpn http/1.1"
call :alpn_case
goto :after_alpn

:alpn_buildfail
echo    FAIL  Nghttp2AlpnMismatch did not compile
findstr /C:"Error" /C:"Fatal" "Nghttp2AlpnMismatch.buildlog"
echo.
echo    Full log: Nghttp2AlpnMismatch.buildlog
set /a FAILED+=1
goto :after_alpn

:no_alpn_dpr
echo -- Nghttp2AlpnMismatch ---------------------------------------------------------------
echo    SKIP  Nghttp2AlpnMismatch.dpr not present
goto :after_alpn

:no_alpn_openssl
echo -- Nghttp2AlpnMismatch ---------------------------------------------------------------
set /a SKIPPED+=1
echo    SKIP  openssl.exe not on PATH - the client's ALPN refusal was NOT
echo          exercised. This is the only stage that can reach that path.
echo          Install OpenSSL for Windows, or add its bin directory to PATH.
goto :after_alpn

:no_alpn_cert
echo    SKIP  could not generate a throwaway cert - see !ALPNDIR!\cert.log
set /a SKIPPED+=1
goto :after_alpn

:after_alpn

REM -- Stage 4d. Read timeout (CL2c). The stage that can HANG. -----------
REM
REM PumpUntilDone always documented a timeout and always checked it, but only
REM BETWEEN reads - DoRead went straight to a blocking recv with no
REM SO_RCVTIMEO anywhere. A peer that accepted and then said nothing parked
REM the client forever and the check never ran again.
REM
REM The peer is a listener that never calls accept(): the kernel completes the
REM handshake from the backlog, so connect succeeds and the client then waits
REM on a socket nobody will ever write to. No thread, no second process.
REM
REM NOTE, and it is a real gap: cmd has no watchdog, so unlike the bash
REM harness this stage cannot convert a hang into a failure. If the suite
REM stops here, THAT IS THE RESULT - the read timeout is not working and
REM DoRead is blocking again. Ctrl+C and read this comment.
if not exist "Nghttp2ReadTimeout.dpr" goto :no_readtimeout
echo -- Nghttp2ReadTimeout ---------------------------------------------------------------
"!DCC!" -CC -B -U"..\src" "Nghttp2ReadTimeout.dpr" > "Nghttp2ReadTimeout.buildlog" 2>&1
if errorlevel 1 goto :readtimeout_buildfail
if not exist "Nghttp2ReadTimeout.exe" goto :readtimeout_buildfail
Nghttp2ReadTimeout.exe < nul
set "RT_RC=!errorlevel!"
echo.
if "!RT_RC!"=="0" goto :readtimeout_pass
if "!RT_RC!"=="3" goto :readtimeout_skip
echo    FAIL  Nghttp2ReadTimeout - the deadline did not behave as specified
set /a FAILED+=1
goto :after_readtimeout

:readtimeout_pass
echo    PASS  Nghttp2ReadTimeout - the deadline fired
goto :after_readtimeout

:readtimeout_skip
set /a SKIPPED+=1
echo    SKIP  Nghttp2ReadTimeout - libnghttp2 absent; timeout NOT exercised
goto :after_readtimeout

:readtimeout_buildfail
echo    FAIL  Nghttp2ReadTimeout did not compile
findstr /C:"Error" /C:"Fatal" "Nghttp2ReadTimeout.buildlog"
echo.
echo    Full log: Nghttp2ReadTimeout.buildlog
set /a FAILED+=1
goto :after_readtimeout

:no_readtimeout
echo -- Nghttp2ReadTimeout ---------------------------------------------------------------
echo    SKIP  Nghttp2ReadTimeout.dpr not present

:after_readtimeout

REM -- Stage 4e. Incremental response delivery (CL3a). ------------------
REM
REM Until CL3 every response was buffered whole into TNghttp2Response.Body,
REM which put SSE and large downloads out of reach. BeginRequest(..., True)
REM opts one stream into incremental delivery through ReadChunk.
REM
REM Proves: the body arrives across several calls, reassembles complete and
REM in order, ends with 0 rather than a timeout, and Response.Body is EMPTY
REM afterwards - the memory claim in checkable form, since it shows the body
REM was DIVERTED rather than buffered and copied.
REM
REM Does NOT prove chunks arrive before END_STREAM: inline dispatch means the
REM handler IS the connection thread, so it returns before the pump runs. The
REM program SKIPs that check with its reason; the provider suite's stage 15
REM times real arrivals with curl -N.
if not exist "Nghttp2StreamRead.dpr" goto :no_streamread
echo -- Nghttp2StreamRead ---------------------------------------------------------------
"!DCC!" -CC -B -U"..\src" "Nghttp2StreamRead.dpr" > "Nghttp2StreamRead.buildlog" 2>&1
if errorlevel 1 goto :streamread_buildfail
if not exist "Nghttp2StreamRead.exe" goto :streamread_buildfail
Nghttp2StreamRead.exe < nul
set "SR_RC=!errorlevel!"
echo.
if "!SR_RC!"=="0" goto :streamread_pass
if "!SR_RC!"=="3" goto :streamread_skip
echo    FAIL  Nghttp2StreamRead - incremental delivery did not behave as specified
set /a FAILED+=1
goto :after_streamread

:streamread_pass
echo    PASS  Nghttp2StreamRead - the body arrived incrementally
goto :after_streamread

:streamread_skip
set /a SKIPPED+=1
echo    SKIP  Nghttp2StreamRead - libnghttp2 absent; ReadChunk NOT exercised
goto :after_streamread

:streamread_buildfail
echo    FAIL  Nghttp2StreamRead did not compile
findstr /C:"Error" /C:"Fatal" "Nghttp2StreamRead.buildlog"
echo.
echo    Full log: Nghttp2StreamRead.buildlog
set /a FAILED+=1
goto :after_streamread

:no_streamread
echo -- Nghttp2StreamRead ---------------------------------------------------------------
echo    SKIP  Nghttp2StreamRead.dpr not present

:after_streamread

REM -- Stage 4f. Loader thread-safety (FIX-LOADRACE-1). ------------------
REM
REM Both FFI loaders were `if GLoaded then Exit(True)` ... an entire library
REM load ... `GLoaded := True`, with no lock between the halves. NghttpsslLoad
REM also carried a Boolean "recursion guard" whose own comment read
REM "single-threaded init assumed", and which answered a second thread arriving
REM mid-load with Exit(False) - telling the caller OpenSSL had FAILED TO LOAD
REM while it was in fact succeeding on the other thread.
REM
REM WHY THIS STAGE LOOPS, where no other stage does. The guarded region is
REM entered exactly ONCE per process: after the first load every caller takes
REM the raceless early return. One execution is therefore one sample, and the
REM sampling has to happen out here. A single green run of a concurrency bug is
REM luck, not evidence - that is what the ALPN race cost us.
REM
REM EXIT CODES: 0 clean, 1 the race was observed, 3 the OpenSSL arm never ran
REM because the library is absent. ALL-3 IS NOT A PASS - it means the only arm
REM that can detect this defect did not execute, and it is reported as a SKIP
REM saying exactly that.
REM
REM Exact string compares below, not "if errorlevel N": errorlevel means >= N,
REM so a crash (a huge exit code) would be miscounted as "OpenSSL absent" and
REM reported as a SKIP. That is the wrong direction to be wrong in.
if not exist "Nghttp2LoaderRace.dpr" goto :no_loaderrace
echo -- Nghttp2LoaderRace ---------------------------------------------------------------
"!DCC!" -CC -B -U"..\src" "Nghttp2LoaderRace.dpr" > "Nghttp2LoaderRace.buildlog" 2>&1
if errorlevel 1 goto :loaderrace_buildfail
if not exist "Nghttp2LoaderRace.exe" goto :loaderrace_buildfail
set "LR_RUNS=20"
set /a LR_RACED=0
set /a LR_NOARM=0
set /a LR_OTHER=0
for /L %%i in (1,1,20) do (
  Nghttp2LoaderRace.exe < nul > "Nghttp2LoaderRace.run%%i.log" 2>&1
  set "LR_RC=!errorlevel!"
  if "!LR_RC!"=="3" ( set /a LR_NOARM+=1 ) else if "!LR_RC!"=="1" ( set /a LR_RACED+=1 ) else if not "!LR_RC!"=="0" ( set /a LR_OTHER+=1 )
)
echo.
echo    !LR_RUNS! fresh processes -- raced: !LR_RACED!, no OpenSSL arm: !LR_NOARM!, other: !LR_OTHER!
if "!LR_NOARM!"=="!LR_RUNS!" goto :loaderrace_skip
if not "!LR_RACED!"=="0" goto :loaderrace_fail
if not "!LR_OTHER!"=="0" goto :loaderrace_fail
echo    PASS  Nghttp2LoaderRace - !LR_RUNS!/!LR_RUNS! clean concurrent first loads
goto :after_loaderrace

:loaderrace_fail
echo    FAIL  Nghttp2LoaderRace - !LR_RACED! of !LR_RUNS! runs saw a PARTIAL load failure
echo          (some threads refused while others succeeded, in the same instant).
echo          That is FIX-LOADRACE-1 - a concurrent first load.
echo          Per-run logs: Nghttp2LoaderRace.run*.log
set /a FAILED+=1
goto :after_loaderrace

:loaderrace_skip
set /a SKIPPED+=1
echo    SKIP  Nghttp2LoaderRace - OpenSSL absent in every run; the ONLY arm
echo          that can detect this race never executed. NOT a pass.
goto :after_loaderrace

:loaderrace_buildfail
echo    FAIL  Nghttp2LoaderRace did not compile
findstr /C:"Error" /C:"Fatal" "Nghttp2LoaderRace.buildlog"
echo.
echo    Full log: Nghttp2LoaderRace.buildlog
set /a FAILED+=1
goto :after_loaderrace

:no_loaderrace
echo -- Nghttp2LoaderRace ---------------------------------------------------------------
echo    SKIP  Nghttp2LoaderRace.dpr not present

:after_loaderrace

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

REM -- protogen emitter (C2). Same directory as the parser tests.
REM    Its units are pure RTL — no Nghttp2 on the path — same rule as stage 5.
if not exist "..\tools\protogen\ProtogenEmitTests.dpr" goto :no_emit
pushd "..\tools\protogen"
set "STAGE=ProtogenEmitTests"
set "GATES=1"
set "STAGEUNITS=."
call :build_run
popd
set "STAGEUNITS=..\src"
goto :after_emit

:no_emit
echo -- ProtogenEmitTests ---------------------------------------------------------------
echo    SKIP  ..\tools\protogen\ProtogenEmitTests.dpr not present

:after_emit

REM -- protogen interface emitter (C3). Same directory as the emitter tests.
REM    Its units are pure RTL + protogen — no Nghttp2 on the path — same rule.
if not exist "..\tools\protogen\ProtogenInterfaceTests.dpr" goto :no_iface
pushd "..\tools\protogen"
set "STAGE=ProtogenInterfaceTests"
set "GATES=1"
set "STAGEUNITS=."
call :build_run
popd
set "STAGEUNITS=..\src"
goto :after_iface

:no_iface
echo -- ProtogenInterfaceTests ---------------------------------------------------------------
echo    SKIP  ..\tools\protogen\ProtogenInterfaceTests.dpr not present

:after_iface

REM -- protogen runner (C4). Same directory as the interface emitter tests.
REM    Exercises WriteUnits + Run against a real temp directory (file I/O,
REM    no-overwrite, dry-run, error paths). Uses System.IOUtils for TPath.GetTempPath.
if not exist "..\tools\protogen\ProtogenRunnerTests.dpr" goto :no_runner
pushd "..\tools\protogen"
set "STAGE=ProtogenRunnerTests"
set "GATES=1"
set "STAGEUNITS=."
call :build_run
popd
set "STAGEUNITS=..\src"
goto :after_runner

:no_runner
echo -- ProtogenRunnerTests ---------------------------------------------------------------
echo    SKIP  ..\tools\protogen\ProtogenRunnerTests.dpr not present

:after_runner

REM -- protogen binary (compile only). Protogen.dpr is the CLI; running it
REM    without args exits 1, so we only compile. A build failure means the
REM    runner's public API changed without updating the binary.
if not exist "..\tools\protogen\Protogen.dpr" goto :no_protogen_bin
pushd "..\tools\protogen"
set "STAGE=Protogen"
set "STAGEUNITS=."
call :build_only
popd
set "STAGEUNITS=..\src"
goto :after_protogen_bin

:no_protogen_bin
echo -- Protogen (compile only) ---------------------------------------------------------------
echo    SKIP  ..\tools\protogen\Protogen.dpr not present

:after_protogen_bin

REM -- C6a: compile protogen's OUTPUT.
REM    Every other protogen stage compares generated text against expected
REM    text. None of them puts generated Pascal in front of a compiler, so a
REM    language-level defect — a type that does not exist, a method pointer
REM    that is not assignment-compatible, a missing unit in a uses clause — is
REM    invisible to all of them. This stage generates into a scratch directory
REM    and builds the result against the real Nghttp2 units.
REM
REM    The scratch directory is DELETED first: the no-overwrite contract
REM    preserves an existing .Service.pas and writes .Service.new.pas instead,
REM    so a dirty directory would compile the previous run's skeleton and
REM    report a pass that says nothing about this build.
if not exist "..\tools\protogen\ProtogenGeneratedCompileCheck.dpr" goto :no_gencheck
if not exist "..\tools\protogen\Protogen.exe" goto :no_gencheck_bin
if not exist "..\..\horse-provider-nghttp2\samples\grpc\greeter.proto" goto :no_gencheck_proto

echo.
set "GENOUT=%TEMP%\protogen-gencheck"
if exist "%GENOUT%" rmdir /s /q "%GENOUT%"
pushd "..\tools\protogen"
Protogen.exe -i "..\..\..\horse-provider-nghttp2\samples\grpc\greeter.proto" -o "%GENOUT%" --unit-prefix Sample > nul
if errorlevel 1 (
  echo -- ProtogenGeneratedCompileCheck ^(C6a^) ------------------------------------------------
  echo    FAIL  Protogen.exe could not generate into %GENOUT%
  set /a FAILED+=1
  popd
  goto :after_gencheck
)
set "STAGE=ProtogenGeneratedCompileCheck"
set "GATES=1"
set "STAGEUNITS=%GENOUT%;..\..\src"
call :build_run
popd
set "STAGEUNITS=..\src"
goto :after_gencheck

:no_gencheck
echo -- ProtogenGeneratedCompileCheck (C6a) ------------------------------------------------
echo    SKIP  ..\tools\protogen\ProtogenGeneratedCompileCheck.dpr not present
goto :after_gencheck

:no_gencheck_bin
echo -- ProtogenGeneratedCompileCheck (C6a) ------------------------------------------------
echo    SKIP  Protogen.exe not built - run the Protogen compile-only stage first
goto :after_gencheck

:no_gencheck_proto
echo -- ProtogenGeneratedCompileCheck (C6a) ------------------------------------------------
echo    SKIP  greeter.proto not found - needs the horse-provider-nghttp2 sibling checkout

:after_gencheck

REM -- C6b. Compile AND RUN protogen's `optional` output --------------------
REM
REM    C6a above generates from greeter.proto, which has no optional fields,
REM    so PRESENCE-1's emitter checks all compare TEXT TO TEXT - the very hole
REM    C6a exists to close, reopened one feature along. On its first FPC run
REM    this stage caught generated Pascal that did not compile (fields emitted
REM    after a method in the same visibility section) while fourteen C2 checks
REM    were green on that same output.
REM
REM    Unlike C6a this needs no sibling checkout: optional.proto lives here.
REM    It also declares no service, so nothing reaches RegisterService<T>.
REM
REM    Same scratch-directory rule as C6a, and for the same reason: the
REM    no-overwrite contract preserves an existing .Service.pas, so a dirty
REM    directory compiles the previous run's output.
if not exist "..\tools\protogen\ProtogenOptionalCompileCheck.dpr" goto :no_optcheck
if not exist "..\tools\protogen\Protogen.exe" goto :no_optcheck_bin
if not exist "..\tools\protogen\optional.proto" goto :no_optcheck_proto

echo.
set "OPTOUT=%TEMP%\protogen-optcheck"
if exist "%OPTOUT%" rmdir /s /q "%OPTOUT%"
pushd "..\tools\protogen"
Protogen.exe -i "optional.proto" -o "%OPTOUT%" --unit-prefix Sample > nul
if errorlevel 1 (
  echo -- ProtogenOptionalCompileCheck ^(C6b^) ------------------------------------------------
  echo    FAIL  Protogen.exe could not generate from optional.proto
  set /a FAILED+=1
  popd
  goto :after_optcheck
)
set "STAGE=ProtogenOptionalCompileCheck"
set "GATES=1"
set "STAGEUNITS=%OPTOUT%;..\..\src"
call :build_run
popd
set "STAGEUNITS=..\src"
goto :after_optcheck

:no_optcheck
echo -- ProtogenOptionalCompileCheck (C6b) ------------------------------------------------
echo    SKIP  ..\tools\protogen\ProtogenOptionalCompileCheck.dpr not present
goto :after_optcheck

:no_optcheck_bin
echo -- ProtogenOptionalCompileCheck (C6b) ------------------------------------------------
echo    SKIP  Protogen.exe not built - run the Protogen compile-only stage first
goto :after_optcheck

:no_optcheck_proto
echo -- ProtogenOptionalCompileCheck (C6b) ------------------------------------------------
echo    SKIP  ..\tools\protogen\optional.proto not present

:after_optcheck

echo.
echo ===========================================================================
if "!FAILED!"=="0" goto :all_ok
echo  FAILED  - !FAILED! stage^(s^) did not pass
exit /b !FAILED!

:all_ok
if not "!SKIPPED!"=="0" goto :ok_but_skipped
echo  ALL STAGES PASSED
goto :ok_done

:ok_but_skipped
REM The whole point of stage 4b: a run that skipped it has NOT touched the
REM transport, and the last line of the log is the part people read.
echo  ALL STAGES PASSED  --  but !SKIPPED! stage^(s^) SKIPPED
echo.
echo  A skipped stage exercised nothing. If Nghttp2ServerSmoke skipped,
echo  no server was started and the transport is UNTESTED by this run.
echo  See doc/getting-nghttp2-windows.md.

:ok_done
exit /b 0

REM ===========================================================================
:build_run
REM SKIPRC is an OPTIONAL exit code meaning "did not run, and that is not a
REM failure" - captured and cleared immediately so it cannot leak into the
REM next stage, which would silently turn a real failure into a skip.
set "MYSKIP=!SKIPRC!"
set "SKIPRC="
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

if not "!MYSKIP!"=="" if "!RC!"=="!MYSKIP!" goto :br_skip
if "!GATES!"=="0" goto :br_report
if not "!RC!"=="0" goto :br_runfail
echo    PASS  !STAGE!
goto :eof

:br_skip
REM Loud on purpose. A skip that reads like a pass is what let the
REM no-live-server gap survive: every stage was green and none had ever
REM opened a socket.
set /a SKIPPED+=1
echo    SKIP  !STAGE!  -- did not run; see the message above
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
:alpn_case
REM One ALPN peer: start it, drive the client at it, tear it down.
REM Reads !ALPNPORT! !ALPNMODE! !ALPNARGS! !ALPNDIR! !OPENSSL!.
REM
REM ping is the sleep here: `timeout` refuses to run with redirected stdin,
REM which is exactly how this script invokes its test programs.
set "ALPNTITLE=NGHTTP2ALPN-!ALPNMODE!"
start "!ALPNTITLE!" /min "!OPENSSL!" s_server -accept !ALPNPORT! -cert "!ALPNDIR!\c.pem" -key "!ALPNDIR!\k.pem" -naccept 1 -quiet !ALPNARGS!
ping -n 2 127.0.0.1 > nul
Nghttp2AlpnMismatch.exe 127.0.0.1 !ALPNPORT! !ALPNMODE! < nul
set "ALPNRC=!errorlevel!"
taskkill /FI "WINDOWTITLE eq !ALPNTITLE!" /F > nul 2>&1
if "!ALPNRC!"=="0" goto :alpn_case_pass
if "!ALPNRC!"=="3" goto :alpn_case_skip
echo    FAIL  ALPN !ALPNMODE! - the client did not refuse this peer, or said so unusably
set /a FAILED+=1
goto :eof

:alpn_case_pass
echo    PASS  ALPN !ALPNMODE! - the client refused this peer
goto :eof

:alpn_case_skip
REM Loud, for the same reason stage 4b is: a quiet skip is indistinguishable
REM from a green stage, and this is the only place the refusal path runs.
set /a SKIPPED+=1
echo    SKIP  ALPN !ALPNMODE! - client could not load libnghttp2/OpenSSL; NOT exercised
goto :eof

REM ===========================================================================
:build_only
REM Compile only — do not run.  Gates on compile failure; run result is ignored.
echo -- !STAGE! (compile only) ---------------------------------------------------------------
if not exist "!STAGE!.dpr" goto :bo_missing
"!DCC!" -CC -B -U"!STAGEUNITS!" "!STAGE!.dpr" > "!STAGE!.buildlog" 2>&1
if errorlevel 1 goto :bo_buildfail
if not exist "!STAGE!.exe" goto :bo_buildfail
echo    PASS  !STAGE! ^(compile only^)
goto :eof

:bo_buildfail
echo    FAIL  !STAGE! did not compile
findstr /C:"Error" /C:"Fatal" "!STAGE!.buildlog"
echo.
echo    Full log: !STAGE!.buildlog
set /a FAILED+=1
goto :eof

:bo_missing
echo    SKIP  !STAGE!.dpr not present
goto :eof

REM ===========================================================================
:no_dcc
echo ERROR: dcc64.exe not found.
echo        Set DELPHI_ROOT, e.g.
echo            set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
echo        or run this from a shell where rsvars.bat has been called.
exit /b 2
