@echo off
setlocal enabledelayedexpansion

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

REM если порог Х не указан/не подходит по условиям
echo %THRESHOLD%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo Error: threshold must be a whole number from 0 to 100.
    exit /b 1
)
if %THRESHOLD% GTR 100 (
    echo Error: threshold must be a whole number from 0 to 100.
    exit /b 1
)

REM определяем режим сжатия gzip или LZMA
if "%LAB1_MAX_COMPRESSION%"=="1" (
    set ARCHIVE_EXT=tar.xz
) else if "%LAB1_MAX_COMPRESSION%"=="" (
    set ARCHIVE_EXT=tar.gz
) else if "%LAB1_MAX_COMPRESSION%"=="0" (
    set ARCHIVE_EXT=tar.gz
) else (
    echo Error: LAB1_MAX_COMPRESSION must be 0 or 1.
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

set /a TARGET_KB=TOTAL_KB*THRESHOLD/100
set /a NEEDED_KB=USED_KB-TARGET_KB

echo Folder: %FOLDER%
echo Usage: %USAGE%%%; threshold: %THRESHOLD%%%

REM считаем сколько надо освободить и выдаем какие файлы можно удалить
if %USAGE% GTR %THRESHOLD% (
    echo Threshold exceeded: cleanup needed.
    
    set FREED_KB=0
    set SELECTED_FILES=

for /f "tokens=1,2 delims=;" %%A in ('powershell -Command "Get-ChildItem '%FOLDER%' -File | Sort-Object LastWriteTime | ForEach-Object { $_.Name + ';' + $_.Length }"') do (
    if !FREED_KB! LSS !NEEDED_KB! (
        set /a SIZE_KB=%%B/1024
        set /a FREED_KB+=SIZE_KB
        set SELECTED_FILES=!SELECTED_FILES!%%A;
        echo Selected: %%A  size_kb=!SIZE_KB!  accumulated_kb=!FREED_KB!
    )
)

if !FREED_KB! LSS !NEEDED_KB! (
    echo Error: not enough files to reach threshold. Nothing deleted.
    exit /b 1
)

echo Files to archive: !SELECTED_FILES!
) else (
    echo Threshold not exceeded: nothing to do.
    exit /b 0
)

REM создаем архив из файлов, которые можно удалить (дата + время)
for /f %%T in ('powershell -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set TIMESTAMP=%%T
set ARCHIVE_NAME=logs_%TIMESTAMP%.%ARCHIVE_EXT%
set BACKUP_DIR=W:\

echo Creating archive: %BACKUP_DIR%%ARCHIVE_NAME%
if "%ARCHIVE_EXT%"=="tar.xz" (
    tar -cf "%BACKUP_DIR%logs_%TIMESTAMP%.tar" -C %FOLDER% !SELECTED_FILES:;= !
    "C:\Program Files\7-Zip\7z.exe" a -txz "%BACKUP_DIR%%ARCHIVE_NAME%" "%BACKUP_DIR%logs_%TIMESTAMP%.tar" >nul
    del "%BACKUP_DIR%logs_%TIMESTAMP%.tar"
) else (
    tar -czf "%BACKUP_DIR%%ARCHIVE_NAME%" -C %FOLDER% !SELECTED_FILES:;= !
)

REM проверяем на ошибки
if not exist "%BACKUP_DIR%%ARCHIVE_NAME%" (
    echo Error: archive was not created. Original files kept.
    exit /b 1
)

if "%ARCHIVE_EXT%"=="tar.xz" (
    "C:\Program Files\7-Zip\7z.exe" t "%BACKUP_DIR%%ARCHIVE_NAME%" >nul
) else (
    tar -tzf "%BACKUP_DIR%%ARCHIVE_NAME%" >nul
)
if errorlevel 1 (
    echo Error: archive is corrupted. Original files kept.
    exit /b 1
)

REM удаляем оригиналы после успешной проверки 
echo Archive verified: %BACKUP_DIR%%ARCHIVE_NAME%

powershell -Command "$files = '!SELECTED_FILES!'.TrimEnd(';').Split(';'); foreach ($file in $files) { Remove-Item -LiteralPath (Join-Path '%FOLDER%' $file) -Force }"

if errorlevel 1 (
    echo Error: failed to delete original files. Archive kept: %BACKUP_DIR%%ARCHIVE_NAME%
    exit /b 1
)

echo Cleanup complete.