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
call :test_oldest_first
call :test_different_x
call :test_bad_path
call :test_bad_x
call :test_archive_fail_keeps_files

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


REM первый тест - использование меньше порога
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


REM второй тест - использование больше порога
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

REM третий тест - порядок по возрасту
:test_oldest_first
echo === Test 3: oldest files archived first ===
call :prepare_env

REM создаем 6 файлов с разными датами и проверяем
powershell -Command "fsutil file createnew %LOG_DRIVE%:\old_1.dat 73400320" >nul
powershell -Command "(Get-Item '%LOG_DRIVE%:\old_1.dat').LastWriteTime = (Get-Date).AddDays(-10)"

powershell -Command "fsutil file createnew %LOG_DRIVE%:\old_2.dat 73400320" >nul
powershell -Command "(Get-Item '%LOG_DRIVE%:\old_2.dat').LastWriteTime = (Get-Date).AddDays(-9)"

powershell -Command "fsutil file createnew %LOG_DRIVE%:\old_3.dat 73400320" >nul
powershell -Command "(Get-Item '%LOG_DRIVE%:\old_3.dat').LastWriteTime = (Get-Date).AddDays(-8)"

powershell -Command "fsutil file createnew %LOG_DRIVE%:\new_1.dat 73400320" >nul
powershell -Command "(Get-Item '%LOG_DRIVE%:\new_1.dat').LastWriteTime = (Get-Date).AddDays(-1)"

powershell -Command "fsutil file createnew %LOG_DRIVE%:\new_2.dat 73400320" >nul
powershell -Command "(Get-Item '%LOG_DRIVE%:\new_2.dat').LastWriteTime = (Get-Date).AddHours(-2)"

powershell -Command "fsutil file createnew %LOG_DRIVE%:\new_3.dat 73400320" >nul

call cleanup.bat %LOG_DRIVE%:\ 40
if errorlevel 1 (
    echo FAIL: script returned error
    set /a FAIL_COUNT+=1
    goto :eof
)

set OLD_LEFT=0
if exist %LOG_DRIVE%:\old_1.dat set /a OLD_LEFT+=1
if exist %LOG_DRIVE%:\old_2.dat set /a OLD_LEFT+=1
if exist %LOG_DRIVE%:\old_3.dat set /a OLD_LEFT+=1

set NEW_LEFT=0
if exist %LOG_DRIVE%:\new_1.dat set /a NEW_LEFT+=1
if exist %LOG_DRIVE%:\new_2.dat set /a NEW_LEFT+=1
if exist %LOG_DRIVE%:\new_3.dat set /a NEW_LEFT+=1

call :count_archives

echo Old files left: %OLD_LEFT%, new files left: %NEW_LEFT%, archives: %ARCHIVE_COUNT%

if %OLD_LEFT% GTR 0 (
    echo FAIL: old files were not deleted
    set /a FAIL_COUNT+=1
    goto :eof
)

if %NEW_LEFT% LSS 2 (
    echo FAIL: too many new files were deleted
    set /a FAIL_COUNT+=1
    goto :eof
)

if %ARCHIVE_COUNT% LSS 1 (
    echo FAIL: archive not created
    set /a FAIL_COUNT+=1
    goto :eof
)

echo PASS: oldest files archived first
set /a PASS_COUNT+=1
goto :eof


REM четвертый тест - другое значение порога
:test_different_x
echo === Test 4: different threshold values ===
call :prepare_env
call :generate_files 350 7 3

for /f %%A in ('dir /b %LOG_DRIVE%:\ ^| find /c /v ""') do set FILES_BEFORE=%%A

call cleanup.bat %LOG_DRIVE%:\ 95
if errorlevel 1 (
    echo FAIL: script returned error at high threshold
    set /a FAIL_COUNT+=1
    goto :eof
)

for /f %%A in ('dir /b %LOG_DRIVE%:\ ^| find /c /v ""') do set FILES_AFTER_HIGH=%%A

if not "%FILES_BEFORE%"=="%FILES_AFTER_HIGH%" (
    echo FAIL: files changed at high threshold
    set /a FAIL_COUNT+=1
    goto :eof
)

call cleanup.bat %LOG_DRIVE%:\ 30
if errorlevel 1 (
    echo FAIL: script returned error at low threshold
    set /a FAIL_COUNT+=1
    goto :eof
)

for /f %%A in ('dir /b %LOG_DRIVE%:\ ^| find /c /v ""') do set FILES_AFTER_LOW=%%A

if %FILES_AFTER_LOW% GEQ %FILES_BEFORE% (
    echo FAIL: files not deleted at low threshold
    set /a FAIL_COUNT+=1
    goto :eof
)

call :count_archives
if %ARCHIVE_COUNT% LSS 1 (
    echo FAIL: archive not created at low threshold
    set /a FAIL_COUNT+=1
    goto :eof
)

echo Before: %FILES_BEFORE%, after high X: %FILES_AFTER_HIGH%, after low X: %FILES_AFTER_LOW%
echo PASS: different threshold values work correctly
set /a PASS_COUNT+=1
goto :eof


REM пятый тест - несуществующая папка
:test_bad_path
echo === Test 5: invalid path ===

call cleanup.bat C:\YaPridumalaPapku 50
if errorlevel 1 (
    echo PASS: invalid path - error handled
    set /a PASS_COUNT+=1
) else (
    echo FAIL: script should have failed on invalid path
    set /a FAIL_COUNT+=1
)
goto :eof


REM шестой тест - неверный порог
:test_bad_x
echo === Test 6: invalid threshold ===
call :prepare_env
call :generate_files 50 3

call cleanup.bat %LOG_DRIVE%:\ abc
if not errorlevel 1 (
    echo FAIL: script should reject non-numeric threshold
    set /a FAIL_COUNT+=1
    goto :eof
)

call cleanup.bat %LOG_DRIVE%:\ 150
if not errorlevel 1 (
    echo FAIL: script should reject threshold over 100
    set /a FAIL_COUNT+=1
    goto :eof
)

echo PASS: invalid threshold - error handled
set /a PASS_COUNT+=1
goto :eof


REM седьмой тест - проверка сохранности файлов в архивек
:test_archive_fail_keeps_files
echo === Test 7: archive failure keeps originals ===
call :prepare_env
call :generate_files 400 4 5

for /f %%A in ('dir /b %LOG_DRIVE%:\ ^| find /c /v ""') do set FILES_BEFORE=%%A

> "%TEMP%\detach_backup_only.txt" echo select vdisk file=%BACKUP_VHD%
>> "%TEMP%\detach_backup_only.txt" echo detach vdisk
diskpart /s "%TEMP%\detach_backup_only.txt" >nul

call cleanup.bat %LOG_DRIVE%:\ 50
if not errorlevel 1 (
    echo FAIL: script should have failed when backup disk unavailable
    set /a FAIL_COUNT+=1
    goto :eof
)

for /f %%A in ('dir /b %LOG_DRIVE%:\ ^| find /c /v ""') do set FILES_AFTER=%%A

if not "%FILES_BEFORE%"=="%FILES_AFTER%" (
    echo FAIL: files changed despite archive failure was=%FILES_BEFORE% now=%FILES_AFTER%
    set /a FAIL_COUNT+=1
    goto :eof
)

echo PASS: archive failure - originals kept
set /a PASS_COUNT+=1
goto :eof