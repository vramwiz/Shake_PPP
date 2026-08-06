@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make_release_zip.ps1"
exit /b %errorlevel%
