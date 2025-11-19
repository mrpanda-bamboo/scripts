@echo off
title Show autostart apps
echo ===========================
echo   Overview autostart apps
echo ===========================
echo.

echo --- Autostart directory (User) ---
dir "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
echo.

echo --- Autostart directory (system) ---
dir "%PROGRAMDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
echo.

echo --- Registry HKCU Run ---
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
echo.

echo --- Registry HKLM Run ---
reg query "HKLM\Software\Microsoft\Windows\CurrentVersion\Run"
echo.

echo --- Registry WOW6432Node Run ---
reg query "HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
echo.

echo Finish.
pause
