@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

REM =========================
REM Config
REM =========================
set "TZ=Asia/Seoul"
set "SNAPSHOT_PATH=/api/system/snapshot"
set "MID_SNAPSHOT_DELAY_SEC=30"

set "SLEEP_BETWEEN_RUN_SEC=60"
set "MID_WAIT_MAX_SEC=60"

REM results 폴더 보장
if not exist "results" mkdir "results"

:CHOOSE_TYPE
echo ===========================================
echo   JMeter 부하 테스트 실행 설정
echo ===========================================
echo  1. Read 부하 테스트 (DB 조회)
echo  2. Write 부하 테스트 (DB 쓰기)
set /p TYPE_CHOICE="실행할 테스트 유형을 선택하세요 (1 또는 2): "

if "%TYPE_CHOICE%"=="1" (
    set "MODE=read"
    set "DELAY=200"
) else if "%TYPE_CHOICE%"=="2" (
    set "MODE=write"
    set "DELAY=250"
) else (
    echo [오류] 1 또는 2만 입력 가능합니다.
    goto CHOOSE_TYPE
)

:CHOOSE_TARGET
echo.
echo ===========================================
echo   Target 설정 (1: 로컬 / 2: 서버)
echo ===========================================
set /p TARGET_CHOICE="접속 대상을 선택하세요 (1 또는 2): "

if "%TARGET_CHOICE%"=="1" (
    set "HOST=host.docker.internal"
    set "PORT=8080"
    set "TARGET_NAME=로컬(Local)"
) else if "%TARGET_CHOICE%"=="2" (
    set "HOST=127.0.0.1"
    set "PORT=8082"
    set "TARGET_NAME=서버(Server)"
) else (
    echo [오류] 1 또는 2만 입력 가능합니다.
    goto CHOOSE_TARGET
)

echo.
set /p THREADS="공격 트래픽 동시 실행 스레드 수(ATTACK_THREADS)를 입력하세요: "
if "%THREADS%"=="" (
    echo [오류] 스레드 수를 반드시 입력해야 합니다.
    pause
    exit /b 1
)

:CHOOSE_RUNS
echo.
set "RUNS=1"
set /p RUNS="몇 번 반복 실행할까요? (Enter 입력 시 기본값 1번): "
set "RUNS=!RUNS: =!"

set /a RUNS_NUM=RUNS 2>nul
if errorlevel 1 (
    echo [오류] 반복 횟수는 숫자만 가능합니다.
    goto CHOOSE_RUNS
)
if !RUNS_NUM! LSS 1 (
    echo [오류] 반복 횟수는 1 이상이어야 합니다.
    goto CHOOSE_RUNS
)
set "RUNS=!RUNS_NUM!"

:CHOOSE_DURATION
echo.
set "DURATION_MIN=3"
set /p DURATION_MIN="테스트 진행 시간(분)을 입력하세요 (Enter 입력 시 기본값 3분): "

REM 입력값에서 공백 제거
set "DURATION_MIN=!DURATION_MIN: =!"

REM 에러레벨 초기화
verify >nul

REM 산술 연산 및 에러 체크
set /a DURATION_SEC=!DURATION_MIN! * 60 2>nul || (
    echo [오류] 숫자만 입력 가능합니다.
    goto CHOOSE_DURATION
)

REM 0 이하의 숫자 입력 방지
if !DURATION_SEC! LEQ 0 (
    echo [오류] 1분 이상의 시간을 입력해야 합니다.
    goto CHOOSE_DURATION
)

echo [설정] 테스트를 !DURATION_MIN!분(!DURATION_SEC!초) 동안 진행합니다.

echo.
set /p POOL_MODE="풀 고갈 실험 모드를 활성화하시겠습니까? (y/n): "
set "POOL_MODE=!POOL_MODE: =!"

if /i "!POOL_MODE!"=="y" (
    set "HIKARI_OVERRIDE=-Dspring.datasource.hikari.maximum-pool-size=5 -Dspring.datasource.hikari.connection-timeout=1000"
    set "ATTACK_REPEAT=2000"
    set "NORMAL_REPEAT=1"
    set "RAMP=1"
    set "LOOPS=500"
    set "DELAY=0"
    echo [풀 고갈 모드 활성화]
    echo   maximum-pool-size=5
    echo   repeatCount=2000 ^(attack^)
) else (
    set "HIKARI_OVERRIDE="
    if "!MODE!"=="read" (
        set "ATTACK_REPEAT=5"
    ) else (
        set "ATTACK_REPEAT=5"
    )
    set "NORMAL_REPEAT=1"
    set "RAMP=30"
    set "LOOPS=30"
    echo [기본 풀 설정 사용]
)

echo.
echo ===========================================
echo [반복 실행 설정]
echo   - 테스트 유형 : !MODE!
echo   - Target      : http://!HOST!:!PORT!
echo   - 공격 스레드 : !THREADS!
echo   - 총 반복     : !RUNS!
echo   - 진행 시간   : !DURATION_MIN!분
echo ===========================================
echo.

set "FINAL_EXIT=0"
set "RUN_IDS="

for /l %%i in (1,1,!RUNS!) do (
  call :RUN_ONCE %%i
  if errorlevel 1 (
    set "FINAL_EXIT=!ERRORLEVEL!"
    goto AFTER_RUNS
  )

  if not "%%i"=="!RUNS!" (
    echo [대기] 다음 실행까지 !SLEEP_BETWEEN_RUN_SEC!초 대기...
    timeout /t !SLEEP_BETWEEN_RUN_SEC! >nul
  )
)

:AFTER_RUNS
echo.
echo ===========================================
echo [후처리] MID snapshot 생성 대기 (최대 !MID_WAIT_MAX_SEC!초 / run별)
echo ===========================================
for %%R in (!RUN_IDS!) do (
  call :WAIT_FOR_FILE "results\%%R_snapshot_mid.json" !MID_WAIT_MAX_SEC!
)

echo.
echo ===========================================
echo [후처리] generate_reports.bat 실행 (1회)
echo ===========================================
set "REPORT_BAT=%~dp0generate_reports.bat"
if not exist "%REPORT_BAT%" (
  echo [WARNING] generate_reports.bat를 찾지 못했습니다: %REPORT_BAT%
  echo           리포트 생성은 수동으로 실행하세요.
) else (
  call "%REPORT_BAT%" "!MODE!"
)

echo ===========================================
echo [후처리] 완료 (exit=!FINAL_EXIT!)
echo ===========================================
echo.

pause
exit /b !FINAL_EXIT!


REM =========================================================
REM 1회 실행 서브루틴
REM 실패하면 exit /b 1 로 상위 루프 중단
REM =========================================================
:RUN_ONCE
setlocal enabledelayedexpansion
set "IDX=%~1"

echo.
echo ==========================================================
echo [RUN !IDX!/!RUNS!] 시작
echo ==========================================================

set "RUN_START=%DATE% %TIME%"
set "RAND=%RANDOM%"
set "RUN_ID=!MODE!_!THREADS!_run!IDX!_!RAND!"

set "JTL_FILE=results/!RUN_ID!_result.jtl"
set "META_FILE=results/!RUN_ID!_meta.json"
set "SNAP_START_FILE=results/!RUN_ID!_snapshot_start.json"
set "SNAP_MID_FILE=results/!RUN_ID!_snapshot_mid.json"
set "SNAP_END_FILE=results/!RUN_ID!_snapshot_end.json"

echo [Snapshot] START 수집: http://!HOST!:!PORT!!SNAPSHOT_PATH!
curl -s "http://!HOST!:!PORT!!SNAPSHOT_PATH!" -o "!SNAP_START_FILE!"

echo [Snapshot] !MID_SNAPSHOT_DELAY_SEC!초 후 MID 예약
start "" /b cmd /v:on /c "timeout /t !MID_SNAPSHOT_DELAY_SEC! >nul & curl -s http://!HOST!:!PORT!!SNAPSHOT_PATH! -o ""!SNAP_MID_FILE!"""

echo [JMeter] 시작 (RUN_ID=!RUN_ID!)
call docker run --rm ^
  -e TZ=!TZ! ^
  -e JVM_ARGS="-Duser.timezone=!TZ! !HIKARI_OVERRIDE!" ^
  -v "%cd%:/jmeter" ^
  spring-jmeter ^
  jmeter -n ^
  -t /jmeter/scenarios/attack_!MODE!_vs_normal.jmx ^
  -l /jmeter/!JTL_FILE! ^
  -Jjmeter.save.saveservice.output_format=csv ^
  -Jjmeter.save.saveservice.response_data=false ^
  -Jjmeter.save.saveservice.response_headers=false ^
  -Jjmeter.save.saveservice.requestHeaders=false ^
  -Jjmeter.save.saveservice.samplerData=false ^
  -Jjmeter.save.saveservice.assertion_results=none ^
  -Jjmeter.save.saveservice.bytes=true ^
  -Jjmeter.save.saveservice.latency=true ^
  -Jjmeter.save.saveservice.connect_time=true ^
  -Jjmeter.save.saveservice.response_code=true ^
  -Jjmeter.save.saveservice.response_message=true ^
  -JHOST=!HOST! ^
  -JPORT=!PORT! ^
  -JDURATION=!DURATION_SEC! ^
  -JATTACK_THREADS=!THREADS! ^
  -JATTACK_RAMP=!RAMP! ^
  -JATTACK_DELAY=!DELAY! ^
  -JATTACK_LOOPS=!LOOPS! ^
  -JATTACK_REPEAT=!ATTACK_REPEAT! ^
  -JNORMAL_REPEAT=!NORMAL_REPEAT! ^
  -JNORMAL_THREADS=25 ^
  -JNORMAL_DELAY=1000 ^
  -JNORMAL_LOOPS=!LOOPS!

set "JMETER_EXIT=!ERRORLEVEL!"
echo [JMeter] 종료 exit=!JMETER_EXIT!

if not "!JMETER_EXIT!"=="0" (
  echo [ERROR] JMeter 실패. 반복 실행 중단
  endlocal & exit /b 1
)

set "RUN_END=%DATE% %TIME%"
echo [Snapshot] END 수집: http://!HOST!:!PORT!!SNAPSHOT_PATH!
curl -s "http://!HOST!:!PORT!!SNAPSHOT_PATH!" -o "!SNAP_END_FILE!"

(
  echo {
  echo   "run_id": "!RUN_ID!",
  echo   "run_start": "!RUN_START!",
  echo   "run_end": "!RUN_END!",
  echo   "mode": "!MODE!",
  echo   "pool_mode": "!POOL_MODE!",
  echo   "target": { "host": "!HOST!", "port": !PORT!, "protocol": "http" },
  echo   "attack": { "threads": !THREADS!, "repeat": !ATTACK_REPEAT!, "delay_ms": !DELAY!, "ramp_s": !RAMP!, "loops": !LOOPS! },
  echo   "normal": { "threads": 25, "repeat": !NORMAL_REPEAT!, "delay_ms": 1000, "loops": !LOOPS! },
  echo   "files": {
  echo     "jtl": "!JTL_FILE!",
  echo     "snapshot_start": "!SNAP_START_FILE!",
  echo     "snapshot_mid": "!SNAP_MID_FILE!",
  echo     "snapshot_end": "!SNAP_END_FILE!"
  echo   },
  echo   "jmeter_exit_code": !JMETER_EXIT!
  echo }
) > "!META_FILE!"

endlocal & (
  set "RUN_IDS=%RUN_IDS% %RUN_ID%"
)
echo [완료] RUN %IDX% 종료
exit /b 0


REM =========================================================
REM 파일 생성 대기
REM =========================================================
:WAIT_FOR_FILE
setlocal enabledelayedexpansion
set "FILE=%~1"
set /a "WAIT_LEFT=%~2"
:W_LOOP
if exist "!FILE!" ( endlocal & exit /b 0 )
if !WAIT_LEFT! LEQ 0 ( endlocal & exit /b 0 )
timeout /t 1 >nul
set /a WAIT_LEFT-=1
goto W_LOOP