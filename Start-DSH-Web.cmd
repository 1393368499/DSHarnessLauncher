@echo off
setlocal
set "DSH_REPO=%~1"
if not defined DSH_REPO exit /b 2
if not exist "%DSH_REPO%\package.json" exit /b 3
cd /d "%DSH_REPO%" || exit /b 4
rem Let GitHub requests started by Harness bypass a stale machine-level loopback
rem proxy. This is process-scoped, preserves every global Git setting, and is
rem inherited by dsh-market plugin install/update jobs.
if defined NO_PROXY (
    set "NO_PROXY=%NO_PROXY%,github.com,api.github.com,raw.githubusercontent.com,codeload.github.com,objects.githubusercontent.com"
) else (
    set "NO_PROXY=github.com,api.github.com,raw.githubusercontent.com,codeload.github.com,objects.githubusercontent.com"
)
rem Harness owns the official browser handoff. The launcher only starts the runtime.
call pnpm.cmd dsh web >> "%DSH_REPO%\dsh-web.log" 2>&1
