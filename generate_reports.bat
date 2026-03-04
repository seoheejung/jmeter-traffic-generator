@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%"

set "TARGET_DIR=results"
set "PS_SCRIPT=%SCRIPT_DIR%_calc_metrics.ps1"

REM =========================================================
REM 필수 파일 체크
REM =========================================================
if not exist "%TARGET_DIR%" (
    echo [오류] results 폴더가 없습니다: %cd%\%TARGET_DIR%
    popd
    pause
    exit /b 1
)
if not exist "%PS_SCRIPT%" (
    echo [오류] %PS_SCRIPT% 파일이 없습니다.
    popd
    pause
    exit /b 1
)

REM =========================================================
REM 인자 처리
REM   [1] 인자 없음  -> 메뉴 입력
REM   [2] 인자 1개   -> MODE만 지정 (read/write)
REM =========================================================
set "MODE_ARG=%~1"

if not "%MODE_ARG%"=="" goto :PARSE_ARGS

:CHOOSE_TYPE
echo ===========================================
echo   JMeter 리포트 생성 유형 선택
echo ===========================================
echo   1. Read
echo   2. Write
set /p TYPE_CHOICE="번호를 선택하세요: "

if "%TYPE_CHOICE%"=="1" (
    set "MODE=read"
    set "PREFIX=R"
) else if "%TYPE_CHOICE%"=="2" (
    set "MODE=write"
    set "PREFIX=W"
) else (
    cls
    goto CHOOSE_TYPE
)
goto :AFTER_MODE

:PARSE_ARGS
if /i "%MODE_ARG%"=="read" (
    set "MODE=read"
    set "PREFIX=R"
) else if /i "%MODE_ARG%"=="write" (
    set "MODE=write"
    set "PREFIX=W"
) else (
    echo [오류] MODE는 read 또는 write 여야 합니다.
    popd
    exit /b 1
)

:AFTER_MODE
set "SUMMARY_CSV=%TARGET_DIR%\summary_%MODE%.csv"
if not exist "%SUMMARY_CSV%" (
    echo run_id,mode,threads,normal_p95_ms,normal_500_pct,normal_503_pct,normal_429_pct,normal_504_pct,attack_429_pct,attack_504_pct,throughput_rps,total_requests,hikari_timeout_start,hikari_timeout_end,hikari_timeout_delta,cb_open_any,cb_state_end > "%SUMMARY_CSV%"
)

REM =========================================================
REM 전체 스캔 모드
REM =========================================================
set "FOUND_COUNT=0"
for %%F in ("%TARGET_DIR%\%MODE%_*_result.jtl") do (
    set /a FOUND_COUNT+=1
    call :PROCESS_ITEM "%%~nxF"
)

if "!FOUND_COUNT!"=="0" (
    echo [경고] %MODE% 관련 JTL 파일을 찾지 못했습니다.
)

:DONE
echo.
echo [완료] 요약 CSV: %SUMMARY_CSV%
popd

if "%MODE_ARG%"=="" pause
endlocal
exit /b 0


REM =========================================================
REM 서브루틴: 개별 파일 처리
REM =========================================================
:PROCESS_ITEM
setlocal enabledelayedexpansion
set "FILE_NAME=%~1"
set "BASE=%~n1"
set "JTL_WIN=%cd%\%TARGET_DIR%\%FILE_NAME%"

REM RUN_KEY는 "_result" 제거한 값 (예: read_100_12345)
set "RUN_KEY=!BASE:_result=!"

REM threads 추출: read_100_12345 => 100
for /f "tokens=2 delims=_" %%b in ("!RUN_KEY!") do set "THREADS=%%b"
if "!THREADS!"=="" set "THREADS=0"

echo ---------------------------------------
echo [RUN] !RUN_KEY! (Threads: !THREADS!)
echo ---------------------------------------

REM 1) HTML REPORT 생성
REM response_message 컬럼 누락 방지용 옵션 강제 주입
docker run --rm ^
  -v "%cd%:/jmeter" ^
  spring-jmeter ^
  jmeter -Jjmeter.save.saveservice.response_message=true ^
         -g "/jmeter/%TARGET_DIR%/!FILE_NAME!" ^
         -o "/jmeter/%TARGET_DIR%/report_!BASE!"

if errorlevel 1 (
    echo [오류] HTML 리포트 생성 실패 → 이동 안함
    endlocal
    exit /b 0
)

REM 2) 메트릭 계산
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" ^
  -JtlPath "!JTL_WIN!" ^
  -Mode "%MODE%" ^
  -RunKey "!RUN_KEY!" ^
  -Threads "!THREADS!" ^
  -TargetDir "%TARGET_DIR%" ^
  -SummaryCsv "%SUMMARY_CSV%"

if errorlevel 1 (
    echo [오류] 메트릭 계산 실패 → 이동 안함
    endlocal
    exit /b 0
)

REM 3) ARCHIVE 이동
set "ARCHIVE_ROOT=%TARGET_DIR%\archive\%PREFIX%_Threads_!THREADS!"
set "ARCHIVE_RUN=!ARCHIVE_ROOT!\!RUN_KEY!"

if not exist "!ARCHIVE_RUN!" mkdir "!ARCHIVE_RUN!" >nul 2>nul

if exist "%TARGET_DIR%\report_!BASE!" (
    robocopy "%TARGET_DIR%\report_!BASE!" "!ARCHIVE_RUN!\report_!BASE!" /E /MOVE >nul
    if exist "%TARGET_DIR%\report_!BASE!" rmdir /s /q "%TARGET_DIR%\report_!BASE!" >nul 2>nul
)

move /Y "!JTL_WIN!" "!ARCHIVE_RUN!\" >nul 2>nul

if exist "%TARGET_DIR%\!RUN_KEY!_snapshot_start.json" move /Y "%TARGET_DIR%\!RUN_KEY!_snapshot_start.json" "!ARCHIVE_RUN!\" >nul
if exist "%TARGET_DIR%\!RUN_KEY!_snapshot_mid.json"   move /Y "%TARGET_DIR%\!RUN_KEY!_snapshot_mid.json"   "!ARCHIVE_RUN!\" >nul
if exist "%TARGET_DIR%\!RUN_KEY!_snapshot_end.json"   move /Y "%TARGET_DIR%\!RUN_KEY!_snapshot_end.json"   "!ARCHIVE_RUN!\" >nul
if exist "%TARGET_DIR%\!RUN_KEY!_meta.json"           move /Y "%TARGET_DIR%\!RUN_KEY!_meta.json"           "!ARCHIVE_RUN!\" >nul

echo [ARCHIVE 완료] !RUN_KEY! → !ARCHIVE_RUN!

endlocal
exit /b 0