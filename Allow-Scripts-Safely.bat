@echo off
:: Credit of this script goes to FR33THY
powershell -Command "if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Start-Process -FilePath '%~f0' -ArgumentList 'am_admin' -Verb RunAs; exit }"
if not "%1"=="am_admin" (
    exit /B
)
pushd "%CD%"
CD /D "%~dp0"



    :menu
    cls
    echo 1. Scripts: On (Recommended)
    echo 2. Scripts: Off
    set /p choice=:
    if "%choice%"=="1" goto A
    if "%choice%"=="2" goto B
    goto menu
    :A

cls
reg add "HKCR\Applications\powershell.exe\shell\open\command" /ve /t REG_SZ /d "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -ExecutionPolicy unrestricted -File \"%%1\"" /f >nul 2>&1
:: allow powershell scripts
reg add "HKCU\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "Unrestricted" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "Unrestricted" /f >nul 2>&1
cd %~dp0
powershell -Command "Get-ChildItem -Path $PSScriptRoot -Recurse | Unblock-File"
echo Enabled Powershell Scripts + Unblocked Files
pause
exit

    :B

cls
reg delete "HKCR\Applications\powershell.exe" /f >nul 2>&1
reg delete "HKCR\ps1_auto_file" /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "Restricted" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "Restricted" /f >nul 2>&1
echo Disabled Powershell Scripts
pause
exit
