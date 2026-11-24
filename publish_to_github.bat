@echo off
chcp 65001 >nul
echo ============================================
echo   MyGram-iOS: Push to GitHub
echo   Repo: https://github.com/lukovlukin-sketch/MyGram-iOS.git
echo ============================================
echo.
cd /d "%~dp0"
git remote set-url origin https://github.com/lukovlukin-sketch/MyGram-iOS.git
echo Pushing to GitHub (if a browser sign-in window opens, click Authorize)...
echo.
git push -u origin master
echo.
if %ERRORLEVEL%==0 (
    echo.
    echo ============================================
    echo   SUCCESS! Opening GitHub Actions...
    echo ============================================
    start https://github.com/lukovlukin-sketch/MyGram-iOS/actions
) else (
    echo Push failed. Check the error above.
)
pause
