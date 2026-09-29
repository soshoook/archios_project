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

REM выдает насколько занят/свободен вирт диск и превосходит ли это порог
set DRIVE_LETTER=%FOLDER:~0,1%

for /f %%A in ('powershell -Command "(Get-PSDrive %DRIVE_LETTER%).Free"') do set FREE=%%A
for /f %%A in ('powershell -Command "(Get-PSDrive %DRIVE_LETTER%).Used"') do set USED=%%A

set /a FREE_KB=FREE/1024
set /a USED_KB=USED/1024
set /a TOTAL_KB=FREE_KB+USED_KB
set /a USAGE=USED_KB*100/TOTAL_KB

echo Folder: %FOLDER%
echo Usage: %USAGE%%%; threshold: %THRESHOLD%%%

if %USAGE% GTR %THRESHOLD% (
    echo Threshold exceeded: cleanup needed.
) else (
    echo Threshold not exceeded: nothing to do.
    exit /b 0
)