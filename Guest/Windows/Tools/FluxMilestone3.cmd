@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "OUT=C:\Users\Public\flux_milestone3_evidence.txt"

:: Self-elevation check
net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
    for %%D in (D E F C) do (
        if exist "%%D:\FluxMilestone3.cmd" (
            powershell.exe -NoProfile -Command "Start-Process '%%D:\FluxMilestone3.cmd' -Verb RunAs"
            exit /b 0
        )
    )
    powershell.exe -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b 0
)

> "%OUT%" echo ========================================================
>>"%OUT%" echo FLUX MILESTONE 3 LAUNCHER
>>"%OUT%" echo ========================================================
>>"%OUT%" echo STARTED=YES
>>"%OUT%" echo IS_ADMIN=YES
whoami >> "%OUT%" 2>&1

:: Locate PowerShell script and run with full stdout/stderr capture
set "FOUND_PS1="
for %%D in (D E F C) do (
    if not defined FOUND_PS1 (
        if exist "%%D:\FluxMilestone3.ps1" (
            set "FOUND_PS1=%%D:\FluxMilestone3.ps1"
        )
    )
)

if not defined FOUND_PS1 (
    >>"%OUT%" echo RESULT=FAIL_PS1_NOT_FOUND
    exit /b 2
)

>>"%OUT%" echo EXECUTING_PS1=!FOUND_PS1!
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!FOUND_PS1!" >> "%OUT%" 2>&1
set "PS_EXIT=%ERRORLEVEL%"
>>"%OUT%" echo POWERSHELL_EXIT_CODE=%PS_EXIT%
>>"%OUT%" echo MILESTONE3_LAUNCHER_COMPLETE=YES

for %%D in (D E F) do (
    if exist "%%D:\" (
        copy /y "%OUT%" "%%D:\flux_milestone3_evidence.txt" >nul 2>&1
        if exist "C:\Users\Public\flux_swapchain_status.txt" copy /y "C:\Users\Public\flux_swapchain_status.txt" "%%D:\flux_swapchain_status.txt" >nul 2>&1
    )
)

exit /b %PS_EXIT%
