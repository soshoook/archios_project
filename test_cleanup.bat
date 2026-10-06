@echo off
setlocal enabledelayedexpansion

REM счетчики успешного/не успешного проходов тестов
set PASS_COUNT=0
set FAIL_COUNT=0

REM пути к файлам вирт дисков
set LOG_VHD=C:\vhd\test_log.vhd
set BACKUP_VHD=C:\vhd\test_backup.vhd
set LOG_DRIVE=V
set BACKUP_DRIVE=W

call :test_below_threshold
call :test_above_threshold

echo ================================
echo PASS: %PASS_COUNT%  FAIL: %FAIL_COUNT%
if %FAIL_COUNT% GTR 0 (
    exit /b 1
)
exit /b 0


REM подготовка окружения
:prepare_env
echo Preparing test environment...

if not exist C:\vhd mkdir C:\vhd

REM автоматизируем ввод команд
if exist "%LOG_VHD%" (
    > "%TEMP%\detach_log.txt" echo select vdisk file=%LOG_VHD%
    >> "%TEMP%\detach_log.txt" echo detach vdisk
    diskpart /s "%TEMP%\detach_log.txt" >nul 2>nul
    del "%LOG_VHD%" >nul 2>nul
)
if exist "%BACKUP_VHD%" (
    > "%TEMP%\detach_backup.txt" echo select vdisk file=%BACKUP_VHD%
    >> "%TEMP%\detach_backup.txt" echo detach vdisk
    diskpart /s "%TEMP%\detach_backup.txt" >nul 2>nul
    del "%BACKUP_VHD%" >nul 2>nul
)

> "%TEMP%\create_log.txt" echo create vdisk file=%LOG_VHD% maximum=600 type=fixed
>> "%TEMP%\create_log.txt" echo attach vdisk
>> "%TEMP%\create_log.txt" echo create partition primary
>> "%TEMP%\create_log.txt" echo format quick label=logdisk
>> "%TEMP%\create_log.txt" echo assign letter=%LOG_DRIVE%
diskpart /s "%TEMP%\create_log.txt" >nul

> "%TEMP%\create_backup.txt" echo create vdisk file=%BACKUP_VHD% maximum=600 type=fixed
>> "%TEMP%\create_backup.txt" echo attach vdisk
>> "%TEMP%\create_backup.txt" echo create partition primary
>> "%TEMP%\create_backup.txt" echo format quick label=backupdisk
>> "%TEMP%\create_backup.txt" echo assign letter=%BACKUP_DRIVE%
diskpart /s "%TEMP%\create_backup.txt" >nul

goto :eof


REM создание тестовых файлов (с возможностью самому задать время их создания)
:generate_files
set GEN_SIZE_MB=%1
set GEN_COUNT=%2
set GEN_AGE_DAYS=%3
set /a GEN_SIZE_PER_FILE=GEN_SIZE_MB/GEN_COUNT

for /l %%i in (1,1,%GEN_COUNT%) do (
    set /a BYTES=GEN_SIZE_PER_FILE*1048576
    powershell -Command "fsutil file createnew %LOG_DRIVE%:\file_%%i.dat !BYTES!" >nul
    if not "%GEN_AGE_DAYS%"=="" if not "%GEN_AGE_DAYS%"=="0" (
        powershell -Command "(Get-Item '%LOG_DRIVE%:\file_%%i.dat').LastWriteTime = (Get-Date).AddDays(-%GEN_AGE_DAYS%)"
    )
)
goto :eof


REM первый тест
:test_below_threshold
echo === Test 1: usage below threshold ===
call :prepare_env
call :generate_files 50 5

REM сколько файлов в папке
for /f %%A in ('dir /b %LOG_DRIVE%:\ ^| find /c /v ""') do set FILES_BEFORE=%%A

call cleanup.bat %LOG_DRIVE%:\ 90
REM случаи ошибок
if errorlevel 1 (
    echo FAIL: script returned error
    set /a FAIL_COUNT+=1
    goto :eof
)

for /f %%A in ('dir /b %LOG_DRIVE%:\ ^| find /c /v ""') do set FILES_AFTER=%%A

if not "%FILES_BEFORE%"=="%FILES_AFTER%" (
    echo FAIL: file count changed
    set /a FAIL_COUNT+=1
    goto :eof
)

echo PASS: below threshold - nothing changed
set /a PASS_COUNT+=1
goto :eof


REM програма подсчет архивов
:count_archives
set ARCHIVE_COUNT=0
for /f %%A in ('dir /b "%BACKUP_DRIVE%:\" 2^>nul ^| find /c /v ""') do set ARCHIVE_COUNT=%%A
goto :eof


REM второй тест
:test_above_threshold
echo === Test 2: usage above threshold ===
call :prepare_env
call :generate_files 400 4 5

for /f %%A in ('dir /b %LOG_DRIVE%:\ ^| find /c /v ""') do set FILES_BEFORE=%%A
echo Files before: %FILES_BEFORE%

call cleanup.bat %LOG_DRIVE%:\ 50
if errorlevel 1 (
    echo FAIL: script returned error
    set /a FAIL_COUNT+=1
    goto :eof
)

for /f %%A in ('dir /b %LOG_DRIVE%:\ ^| find /c /v ""') do set FILES_AFTER=%%A

if %FILES_AFTER% GEQ %FILES_BEFORE% (
    echo FAIL: files were not deleted was=%FILES_BEFORE% now=%FILES_AFTER%
    set /a FAIL_COUNT+=1
    goto :eof
)

call :count_archives
if %ARCHIVE_COUNT% LSS 1 (
    echo FAIL: archive not created
    set /a FAIL_COUNT+=1
    goto :eof
)

echo Files after: %FILES_AFTER%, archives: %ARCHIVE_COUNT%
echo PASS: above threshold - old files archived and deleted
set /a PASS_COUNT+=1
goto :eof