@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

REM ===========================================================================
REM  Where Is My Bus - start the local stack
REM
REM  RUN THIS FROM THE REPOSITORY ROOT:
REM
REM      start-all.bat
REM
REM  or just double-click this file.
REM
REM  What it starts:
REM    1. Docker Desktop, if it is not already running
REM    2. Postgres/PostGIS container "wimb-db" through docker compose
REM    3. The Fastify API on http://127.0.0.1:3000 in its own window
REM    4. The ngrok container "wimb-ngrok" on the fixed dev domain
REM
REM  It reads the database settings and API address from .env.
REM  If the ngrok container does not exist yet, save your authtoken in
REM  .ngrok-token (one line, gitignored) or set NGROK_AUTHTOKEN first.
REM
REM  Stop everything:
REM    - close the "WIMB API" window
REM    - docker stop wimb-ngrok
REM    - docker compose stop db
REM ===========================================================================

echo.
echo [1/4] Checking Docker...
docker info >nul 2>&1
if not errorlevel 1 goto docker_ready

echo       Docker is not running. Starting Docker Desktop...
if exist "C:\Program Files\Docker\Docker\Docker Desktop.exe" (
  start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"
) else (
  echo       Could not find Docker Desktop at the usual path.
  echo       Open Docker Desktop manually, then run this file again.
  pause
  exit /b 1
)

set /a tries=0
:wait_docker
timeout /t 3 /nobreak >nul
docker info >nul 2>&1
if not errorlevel 1 goto docker_ready
set /a tries+=1
if !tries! GEQ 40 (
  echo       Docker did not become ready. Open Docker Desktop and try again.
  pause
  exit /b 1
)
goto wait_docker

:docker_ready
echo       Docker is running.


echo [2/4] Starting Postgres/PostGIS...
docker compose up -d db >nul 2>&1
if errorlevel 1 (
  echo       docker compose could not start the database.
  docker compose logs --tail 20 db
  pause
  exit /b 1
)

set /a tries=0
:wait_db
set "HEALTH="
for /f "tokens=*" %%s in ('docker inspect -f "{{.State.Health.Status}}" wimb-db 2^>nul') do set "HEALTH=%%s"
if /i "!HEALTH!"=="healthy" goto db_ready
set /a tries+=1
if !tries! GEQ 40 (
  echo       Postgres did not become healthy.
  docker compose logs --tail 20 db
  pause
  exit /b 1
)
timeout /t 2 /nobreak >nul
goto wait_db

:db_ready
echo       Postgres is healthy.


echo [3/4] Starting the API...
netstat -ano | findstr "LISTENING" | findstr ":3000" >nul
if not errorlevel 1 (
  echo       API is already listening on port 3000.
  goto api_ready
)

start "WIMB API" cmd /k "npm run api"

set /a tries=0
:wait_api
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:3000/health' -TimeoutSec 2; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
if not errorlevel 1 goto api_ready
set /a tries+=1
if !tries! GEQ 30 (
  echo       The API did not answer. Check the "WIMB API" window.
  pause
  exit /b 1
)
timeout /t 2 /nobreak >nul
goto wait_api

:api_ready
echo       API is answering on http://127.0.0.1:3000.


echo [4/4] Starting ngrok...
docker inspect wimb-ngrok >nul 2>&1
if not errorlevel 1 goto ngrok_exists

set "NGROK_TOKEN="
if exist ".ngrok-token" set /p NGROK_TOKEN=<".ngrok-token"
if not defined NGROK_TOKEN if defined NGROK_AUTHTOKEN set "NGROK_TOKEN=%NGROK_AUTHTOKEN%"
if not defined NGROK_TOKEN goto ngrok_no_token
docker run -d --name wimb-ngrok --restart unless-stopped -p 4040:4040 -e "NGROK_AUTHTOKEN=%NGROK_TOKEN%" ngrok/ngrok:latest http host.docker.internal:3000 >nul 2>&1
if errorlevel 1 goto ngrok_failed
goto start_ngrok_wait

:ngrok_exists
set "RUNNING="
for /f "tokens=*" %%s in ('docker inspect -f "{{.State.Running}}" wimb-ngrok 2^>nul') do set "RUNNING=%%s"
if /i "%RUNNING%"=="true" goto start_ngrok_wait
docker start wimb-ngrok >nul 2>&1
goto start_ngrok_wait

:ngrok_no_token
echo       No ngrok token found.
echo       Save your authtoken in .ngrok-token (one line) and run again.
pause
exit /b 1

:ngrok_failed
echo       Could not start the ngrok container.
pause
exit /b 1

:start_ngrok_wait
if exist "%TEMP%\wimb-ngrok-url.txt" del "%TEMP%\wimb-ngrok-url.txt" >nul 2>&1
set /a tries=0

:wait_ngrok
set "PUBLIC_URL="
powershell -NoProfile -Command "try { $t = Invoke-RestMethod 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 2; $t.tunnels[0].public_url } catch { }" > "%TEMP%\wimb-ngrok-url.txt" 2>nul
if exist "%TEMP%\wimb-ngrok-url.txt" set /p PUBLIC_URL=<"%TEMP%\wimb-ngrok-url.txt"
if defined PUBLIC_URL goto ngrok_ready
set /a tries+=1
if !tries! GEQ 20 (
  echo       ngrok did not come up. Check:
  echo           docker logs wimb-ngrok --tail 20
  pause
  exit /b 1
)
timeout /t 2 /nobreak >nul
goto wait_ngrok

:ngrok_ready
set "API_BASE="
for /f "tokens=1,* delims==" %%A in ('findstr /B /C:"API_BASE=" .env 2^>nul') do set "API_BASE=%%B"

echo.
echo ===========================================================================
echo  Ready.
echo   API:        http://127.0.0.1:3000/health
echo   ngrok:      !PUBLIC_URL!
if defined API_BASE echo   .env:       !API_BASE!
echo.
if defined API_BASE if /i not "!API_BASE!"=="!PUBLIC_URL!" (
  echo  WARNING: API_BASE in .env does not match the ngrok URL.
  echo  Update API_BASE, then rebuild the APK:
  echo      cd app
  echo      flutter build apk --release --dart-define-from-file=../.env
  echo.
)
echo  Stop: close the "WIMB API" window, then run:
echo      docker stop wimb-ngrok
echo      docker compose stop db
echo ===========================================================================
echo.
pause
