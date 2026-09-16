@echo off
setlocal
set "DSH_REPO=%~1"
if not defined DSH_REPO exit /b 2
if not exist "%DSH_REPO%\package.json" exit /b 3
cd /d "%DSH_REPO%" || exit /b 4
rem GitHub requests started by Harness follow the machine's configured network
rem path: Git's http.proxy, or HTTP(S)_PROXY. Set DSH_GITHUB_DIRECT=1 only to
rem force direct access, for a machine whose loopback proxy client has exited
rem while its proxy configuration remains. Injecting NO_PROXY unconditionally
rem makes git reconnect to github.com directly and fail wherever only the
rem proxy reaches GitHub.
if not defined DSH_GITHUB_DIRECT goto :launch
if defined NO_PROXY (
    set "NO_PROXY=%NO_PROXY%,github.com,api.github.com,raw.githubusercontent.com,codeload.github.com,objects.githubusercontent.com"
) else (
    set "NO_PROXY=github.com,api.github.com,raw.githubusercontent.com,codeload.github.com,objects.githubusercontent.com"
)
:launch
rem Harness owns the official browser handoff. The launcher only starts the runtime.
call pnpm.cmd dsh web >> "%DSH_REPO%\dsh-web.log" 2>&1
