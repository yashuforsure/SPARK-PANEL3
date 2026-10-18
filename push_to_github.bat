@echo off
title Uploading SPARK PANEL to GitHub
color 0A
echo ========================================================
echo        UPLOADING SPARK PANEL TO GITHUB REPO
echo ========================================================
echo.
cd /d "%~dp0"

echo [1/2] Connecting to GitHub and pushing files...
git push -f origin main

if %errorlevel% neq 0 (
    echo.
    echo [!] Push failed. If browser opened for GitHub login, complete login and press any key to retry.
    pause
    git push -f origin main
)

echo.
echo ========================================================
echo        DONE! ALL FILES PUSHED TO GITHUB!
echo ========================================================
pause
