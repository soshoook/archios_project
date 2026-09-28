@echo off

set FOLDER=%1
set THRESHOLD=%2

REM случаи, если папка не существует/пустая
if "%FOLDER%"=="" (
    echo Error: folder path isn't specified.
    echo Example: cleanup.bat C:\log 70
    exit /b 1
)

if not exist "%FOLDER%\" (
    echo Error: folder "%FOLDER%" isn't found.
    exit /b 1
)

REM если порог Х не указан
if "%THRESHOLD%"=="" (
    echo Error: threshold X isn't specified.
    exit /b 1
)

REM проверка
echo Folder: %FOLDER%
echo Threshold: %THRESHOLD%%%
echo Arguments accepted correctly.