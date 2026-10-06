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

echo ================================
echo PASS: %PASS_COUNT%  FAIL: %FAIL_COUNT%
if %FAIL_COUNT% GTR 0 (
    exit /b 1
)
exit /b 0


REM подготовка окружения
:prepare_env
echo Preparing test environment...

REM проверка на наличие уже сущ VHD файлов (+ их удаление) и создание новых
powershell -Command "if (Test-Path '%LOG_VHD%') { Dismount-VHD -Path '%LOG_VHD%' -ErrorAction SilentlyContinue; Remove-Item '%LOG_VHD%' }"
powershell -Command "if (Test-Path '%BACKUP_VHD%') { Dismount-VHD -Path '%BACKUP_VHD%' -ErrorAction SilentlyContinue; Remove-Item '%BACKUP_VHD%' }"

powershell -Command "New-VHD -Path '%LOG_VHD%' -SizeBytes 600MB -Fixed | Mount-VHD -Passthru | Initialize-Disk -PartitionStyle MBR -PassThru | New-Partition -DriveLetter %LOG_DRIVE% -UseMaximumSize | Format-Volume -FileSystem NTFS -Confirm:$false"
powershell -Command "New-VHD -Path '%BACKUP_VHD%' -SizeBytes 600MB -Fixed | Mount-VHD -Passthru | Initialize-Disk -PartitionStyle MBR -PassThru | New-Partition -DriveLetter %BACKUP_DRIVE% -UseMaximumSize | Format-Volume -FileSystem NTFS -Confirm:$false"

goto :eof


REM создание тестовых файлов
:generate_files
set GEN_SIZE_MB=%1
set GEN_COUNT=%2

REM сколько мб должно быть в каждом файле для получения нужного количества
set /a GEN_SIZE_PER_FILE=GEN_SIZE_MB/GEN_COUNT

for /l %%i in (1,1,%GEN_COUNT%) do (
    set /a BYTES=GEN_SIZE_PER_FILE*1048576
    powershell -Command "fsutil file createnew %LOG_DRIVE%:\file_%%i.dat !BYTES!" >nul
)
goto :eof


REM сам первый тест
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