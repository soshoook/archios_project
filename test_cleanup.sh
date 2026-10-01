#!/bin/bash
# test_cleanup.sh — автоматические тесты для cleanup.sh
# Минимум 4 теста, каждый с папкой ≥ 0.5 GB

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="${SCRIPT_DIR}/cleanup.sh"
TEST_ROOT="${SCRIPT_DIR}/test_env"

LOG_DIR="${TEST_ROOT}/log"
BACKUP_DIR="${TEST_ROOT}/backup"
LOG_LOOP=""
BACKUP_LOOP=""

PASS=0
FAIL=0

# Цвета
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASS++)) || true
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAIL++)) || true
}

# Безопасный подсчёт файлов (игнорируем lost+found)
count_files() {
    find "$1" -path '*/lost+found' -prune -o -type f -print 2>/dev/null | wc -l
}

count_archives() {
    find "$1" -path '*/lost+found' -prune -o -name "*.tar.gz" -print 2>/dev/null | wc -l
}

# ============================================================
# Вспомогательные функции
# ============================================================

cleanup_test_env() {
    if mountpoint -q "${TEST_ROOT}/log" 2>/dev/null; then
        sudo umount "${TEST_ROOT}/log" 2>/dev/null || true
    fi
    if mountpoint -q "${TEST_ROOT}/backup" 2>/dev/null; then
        sudo umount "${TEST_ROOT}/backup" 2>/dev/null || true
    fi

    if [[ -n "${LOG_LOOP}" ]]; then
        sudo losetup -d "${LOG_LOOP}" 2>/dev/null || true
        LOG_LOOP=""
    fi
    if [[ -n "${BACKUP_LOOP}" ]]; then
        sudo losetup -d "${BACKUP_LOOP}" 2>/dev/null || true
        BACKUP_LOOP=""
    fi

    rm -rf "${TEST_ROOT}"
}

create_virtual_disk() {
    local size_mb=$1
    local mount_point=$2
    local image_file="${TEST_ROOT}/$(basename "${mount_point}").img"

    mkdir -p "${mount_point}"
    mkdir -p "${TEST_ROOT}"

    echo "  → создаю образ ${size_mb} МБ..."
    dd if=/dev/zero of="${image_file}" bs=1M count="${size_mb}" status=none

    local loop_dev
    loop_dev=$(sudo losetup -f --show "${image_file}")

    sudo mkfs.ext4 -q "${loop_dev}"
    sudo mount "${loop_dev}" "${mount_point}"
    sudo chown "$(whoami):$(whoami)" "${mount_point}"
    sudo chmod 777 "${mount_point}"

    echo "${loop_dev}"
}

setup_test_disks() {
    local log_size_mb=${1:-1024}
    local backup_size_mb=${2:-512}

    cleanup_test_env
    mkdir -p "${TEST_ROOT}"

    LOG_DIR="${TEST_ROOT}/log"
    BACKUP_DIR="${TEST_ROOT}/backup"

    echo "Создаю диск для логов (${log_size_mb} МБ)..."
    LOG_LOOP=$(create_virtual_disk "${log_size_mb}" "${LOG_DIR}")

    echo "Создаю диск для архивов (${backup_size_mb} МБ)..."
    BACKUP_LOOP=$(create_virtual_disk "${backup_size_mb}" "${BACKUP_DIR}")

    export BACKUP_DIR
}

generate_test_files() {
    local size_mb=$1
    local age_days=${2:-0}
    local file_count=${3:-10}

    mkdir -p "${LOG_DIR}"

    local mb_per_file=$(( size_mb / file_count ))
    if (( mb_per_file < 1 )); then
        mb_per_file=1
    fi

    echo "Генерирую ${file_count} файлов примерно по ${mb_per_file} МБ..."

    for i in $(seq 1 "${file_count}"); do
        local file="${LOG_DIR}/file_${i}.dat"
        dd if=/dev/zero of="${file}" bs=1M count="${mb_per_file}" status=none 2>/dev/null

        if [[ "${age_days}" -gt 0 ]]; then
            touch -d "${age_days} days ago" "${file}"
        fi
    done

    echo "Готово. Реальный размер:"
    du -sh "${LOG_DIR}" 2>/dev/null || true
}

# ============================================================
# Тесты
# ============================================================

test_below_threshold() {
    echo "=== Тест 1: папка заполнена меньше X% ==="

    setup_test_disks 1024 512
    generate_test_files 100 0 5

    local files_before
    files_before=$(count_files "${LOG_DIR}")

    if ! BACKUP_DIR="${BACKUP_DIR}" bash "${CLEANUP_SCRIPT}" "${LOG_DIR}" 50; then
        print_fail "Скрипт завершился с ошибкой"
        cleanup_test_env
        return
    fi

    local files_after
    files_after=$(count_files "${LOG_DIR}")

    if [[ "${files_after}" -ne "${files_before}" ]]; then
        print_fail "Количество файлов изменилось (было ${files_before}, стало ${files_after})"
        cleanup_test_env
        return
    fi

    local archives
    archives=$(count_archives "${BACKUP_DIR}")

    if [[ "${archives}" -gt 0 ]]; then
        print_fail "Появились архивы, хотя порог не был превышен"
        cleanup_test_env
        return
    fi

    print_pass "Ниже порога — ничего не изменилось"
    cleanup_test_env
}

test_above_threshold() {
    echo "=== Тест 2: папка заполнена больше X% ==="

    setup_test_disks 1024 512
    generate_test_files 800 5 8

    local files_before
    files_before=$(count_files "${LOG_DIR}")
    echo "Файлов до очистки: ${files_before}"

    if ! BACKUP_DIR="${BACKUP_DIR}" bash "${CLEANUP_SCRIPT}" "${LOG_DIR}" 50; then
        print_fail "Скрипт завершился с ошибкой"
        cleanup_test_env
        return
    fi

    local files_after
    files_after=$(count_files "${LOG_DIR}")

    if [[ "${files_after}" -ge "${files_before}" ]]; then
        print_fail "Файлы не были удалены (было ${files_before}, стало ${files_after})"
        cleanup_test_env
        return
    fi

    local archives
    archives=$(count_archives "${BACKUP_DIR}")

    if [[ "${archives}" -lt 1 ]]; then
        print_fail "Архив не создан"
        cleanup_test_env
        return
    fi

    echo "Файлов после очистки: ${files_after}, архивов: ${archives}"
    print_pass "Выше порога — старые файлы архивированы и удалены"
    cleanup_test_env
}

test_oldest_first() {
    echo "=== Тест 3: архивируются самые старые файлы ==="

    # Диск 1 ГБ
    setup_test_disks 1024 512

    # Создаём 6 файлов вручную с разным возрастом
    # Старые (должны удалиться):
    dd if=/dev/zero of="${LOG_DIR}/old_1.dat" bs=1M count=150 status=none
    touch -d "10 days ago" "${LOG_DIR}/old_1.dat"

    dd if=/dev/zero of="${LOG_DIR}/old_2.dat" bs=1M count=150 status=none
    touch -d "9 days ago" "${LOG_DIR}/old_2.dat"

    dd if=/dev/zero of="${LOG_DIR}/old_3.dat" bs=1M count=150 status=none
    touch -d "8 days ago" "${LOG_DIR}/old_3.dat"

    # Новые (должны остаться):
    dd if=/dev/zero of="${LOG_DIR}/new_1.dat" bs=1M count=150 status=none
    touch -d "1 day ago" "${LOG_DIR}/new_1.dat"

    dd if=/dev/zero of="${LOG_DIR}/new_2.dat" bs=1M count=150 status=none
    touch -d "2 hours ago" "${LOG_DIR}/new_2.dat"

    dd if=/dev/zero of="${LOG_DIR}/new_3.dat" bs=1M count=150 status=none
    # сегодняшний

    echo "Созданные файлы:"
    ls -l --time-style=long-iso "${LOG_DIR}" 2>/dev/null || ls -l "${LOG_DIR}"

    # Запускаем с порогом 40% (нужно будет удалить часть файлов)
    if ! BACKUP_DIR="${BACKUP_DIR}" bash "${CLEANUP_SCRIPT}" "${LOG_DIR}" 40; then
        print_fail "Скрипт завершился с ошибкой"
        cleanup_test_env
        return
    fi

    # Проверяем: старые файлы должны исчезнуть
    local old_left=0
    for f in old_1.dat old_2.dat old_3.dat; do
        if [[ -f "${LOG_DIR}/${f}" ]]; then
            ((old_left++)) || true
        fi
    done

    # Новые файлы должны остаться
    local new_left=0
    for f in new_1.dat new_2.dat new_3.dat; do
        if [[ -f "${LOG_DIR}/${f}" ]]; then
            ((new_left++)) || true
        fi
    done

    local archives
    archives=$(count_archives "${BACKUP_DIR}")

    echo "Старых файлов осталось: ${old_left}, новых: ${new_left}, архивов: ${archives}"

    if [[ "${old_left}" -gt 0 ]]; then
        print_fail "Старые файлы не были удалены (осталось ${old_left})"
        cleanup_test_env
        return
    fi

    if [[ "${new_left}" -lt 2 ]]; then
        print_fail "Слишком много новых файлов удалено (осталось ${new_left})"
        cleanup_test_env
        return
    fi

    if [[ "${archives}" -lt 1 ]]; then
        print_fail "Архив не создан"
        cleanup_test_env
        return
    fi

    print_pass "Удалены именно самые старые файлы"
    cleanup_test_env
}

test_different_x() {
    echo "=== Тест 4: другое значение X ==="

    setup_test_disks 1024 512
    generate_test_files 700 3 7

    local files_before
    files_before=$(count_files "${LOG_DIR}")

    # 1. Высокий порог (95%) — ничего не должно удалиться
    if ! BACKUP_DIR="${BACKUP_DIR}" bash "${CLEANUP_SCRIPT}" "${LOG_DIR}" 95; then
        print_fail "Скрипт завершился с ошибкой при высоком пороге"
        cleanup_test_env
        return
    fi

    local files_after_high
    files_after_high=$(count_files "${LOG_DIR}")

    if [[ "${files_after_high}" -ne "${files_before}" ]]; then
        print_fail "При высоком пороге файлы изменились"
        cleanup_test_env
        return
    fi

    # 2. Низкий порог (30%) — должно что-то удалиться
    if ! BACKUP_DIR="${BACKUP_DIR}" bash "${CLEANUP_SCRIPT}" "${LOG_DIR}" 30; then
        print_fail "Скрипт завершился с ошибкой при низком пороге"
        cleanup_test_env
        return
    fi

    local files_after_low
    files_after_low=$(count_files "${LOG_DIR}")

    local archives
    archives=$(count_archives "${BACKUP_DIR}")

    if [[ "${files_after_low}" -ge "${files_before}" ]]; then
        print_fail "При низком пороге файлы не удалились"
        cleanup_test_env
        return
    fi

    if [[ "${archives}" -lt 1 ]]; then
        print_fail "Архив не создан при низком пороге"
        cleanup_test_env
        return
    fi

    echo "Было файлов: ${files_before}, после высокого X: ${files_after_high}, после низкого X: ${files_after_low}"
    print_pass "Разные значения X работают правильно"
    cleanup_test_env
}

# ============================================================
# Запуск
# ============================================================

main() {
    echo "Запуск тестов cleanup.sh"
    echo "========================="

    if [[ ! -f "${CLEANUP_SCRIPT}" ]]; then
        echo "Ошибка: не найден ${CLEANUP_SCRIPT}"
        exit 1
    fi

    test_below_threshold
    test_above_threshold
    test_oldest_first
    test_different_x
    test_bad_path
    test_bad_x
	
    echo "========================="
    echo "Итого: PASS=${PASS}  FAIL=${FAIL}"

    cleanup_test_env

    if [[ ${FAIL} -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

test_bad_path() {
    echo "=== Тест: неверный путь ==="
    if bash "$CLEANUP_SCRIPT" "/net/takoy/papki" 50 2>/dev/null; then
        print_fail "Скрипт не должен был успешно завершиться на несуществующем пути"
    else
        print_pass "Неверный путь — ошибка обработана"
    fi
}

test_bad_x() {
    echo "=== Тест: неверный X ==="
    setup_test_disks 512 256
    generate_test_files 50 0 3

    if BACKUP_DIR="$BACKUP_DIR" bash "$CLEANUP_SCRIPT" "$LOG_DIR" abc 2>/dev/null; then
        print_fail "Скрипт не должен был принять нечисловой X"
        cleanup_test_env
        return
    fi

    if BACKUP_DIR="$BACKUP_DIR" bash "$CLEANUP_SCRIPT" "$LOG_DIR" 150 2>/dev/null; then
        print_fail "Скрипт не должен был принять X > 100"
        cleanup_test_env
        return
    fi

    print_pass "Неверный X — ошибка обработана"
    cleanup_test_env
}

main "$@"
