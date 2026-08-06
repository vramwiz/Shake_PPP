@echo off
setlocal

:: --- 設定エリア ---
set "REPO_NAME=Shake_PPP"
set "REMOTE_URL=https://github.com/vramwiz/%REPO_NAME%"
set "GIT_USER_NAME=vramwiz"
set "GIT_USER_EMAIL=vramwiz@gmail.com"
set "BRANCH_NAME=main"

echo === Git 初期化開始 ===

:: .gitignore がなければ生成（Delphi向け）
if not exist ".gitignore" (
    echo *.~* > .gitignore
    echo __history/ >> .gitignore
    echo *.dcu >> .gitignore
    echo *.local >> .gitignore
    echo *.identcache >> .gitignore
    echo *.exe >> .gitignore
    echo *.bat >> .gitignore
    echo *.dll >> .gitignore
    echo *.map >> .gitignore
    echo *.tds >> .gitignore
    echo *.dsk >> .gitignore
    echo .DS_Store >> .gitignore
    echo .gitignore を自動生成しました。
)

:: git init
git init
if %ERRORLEVEL% NEQ 0 (
    echo Git 初期化に失敗しました。
    pause
    exit /b
)

git branch -M %BRANCH_NAME%

:: .git/config に設定を追加
(
echo [user]
echo ^	name = %GIT_USER_NAME%
echo ^	email = %GIT_USER_EMAIL%
echo [remote "origin"]
echo ^	url = %REMOTE_URL%
echo ^	fetch = +refs/heads/*:refs/remotes/origin/*
) >> .git\config

:: git add
git add .
if %ERRORLEVEL% NEQ 0 (
    echo ファイルの追加に失敗しました。
    pause
    exit /b
)

:: git commit
git commit -m "Initial commit"
if %ERRORLEVEL% NEQ 0 (
    echo コミットに失敗しました。ファイルがない、またはすでにコミット済みかもしれません。
    pause
    exit /b
)

git pull --rebase origin main

:: push with upstream tracking
git push --set-upstream origin %BRANCH_NAME%
if %ERRORLEVEL% NEQ 0 (
    echo Push に失敗しました。リモートURL、認証、ブランチ名を確認してください。
    pause
    exit /b
)

echo === Git 初期化と push に成功しました ===
pause
