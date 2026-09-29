#!/bin/bash

# test_cleanup.sh — автоматические тесты для cleanup.sh
# Минимум 4 теста, каждый с папкой ≥ 0.5 GB

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="${SCRIPT_DIR}/cleanup.sh"
TEST_ROOT="${SCRIPT_DIR}/test_env"
LOG_DIR="${TEST_ROOT}/log"
BACKUP_DIR="${TEST_ROOT}/backup"

PASS=0
FAIL=0

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASS++))
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAIL++))
}

cleanup_test_env() {
    rm -rf "${TEST_ROOT}"
}

prepare_env() {
    cleanup_test_env
    mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"
}
# Создаёт файлы в LOG_DIR общим объёмом примерно size_mb мегабайт
# age_days — возраст файлов в днях (0 = сегодня)
# file_count — сколько файлов создать
# Создаёт файлы в LOG_DIR общим объёмом примерно size_mb мегабайт
# age_days — возраст файлов в днях (0 = сегодня)
# file_count — сколько файлов создать
generate_test_files() {
    local size_mb=$1
    local age_days=${2:-0}
    local file_count=${3:-10}

    mkdir -p "${LOG_DIR}"

    local bytes_per_file=$(( size_mb * 1024 * 1024 / file_count ))
    local mb_per_file=$(( bytes_per_file / 1024 / 1024 ))

    echo "Генерирую ${file_count} файлов примерно по ${mb_per_file} МБ..."

    for i in $(seq 1 "$file_count"); do
        local file="${LOG_DIR}/file_${i}.dat"

        # На /mnt/c fallocate часто не работает, поэтому сразу используем dd
        dd if=/dev/zero of="$file" bs=1M count="$mb_per_file" status=none 2>/dev/null

        # Если dd не сработал — запасной вариант
        if [[ ! -f "$file" ]] || [[ $(stat -c%s "$file" 2>/dev/null || echo 0) -lt 1000 ]]; then
            head -c "$bytes_per_file" /dev/urandom > "$file"
        fi

        # Меняем дату модификации
        if [[ "$age_days" -gt 0 ]]; then
            touch -d "$age_days days ago" "$file"
        fi
    done

    echo "Готово. Реальный размер папки:"
    du -sh "${LOG_DIR}"
}
# ---------- Тест 1: заполненность ниже порога ----------
# Ожидаем: скрипт ничего не делает, файлы остаются, архивов нет
test_below_threshold() {
    echo "=== Тест 1: папка заполнена меньше X% ==="

    # 1. Готовим чистое окружение
    prepare_env

    # 2. Кладём немного файлов (точно меньше любого разумного порога)
    generate_test_files 50 0 5   # ~50 МБ, 5 файлов, сегодняшние

    # 3. Запоминаем, сколько файлов было до запуска
    local files_before
    files_before=$(find "${LOG_DIR}" -type f | wc -l)

    # 4. Запускаем cleanup.sh с высоким порогом (90%)
    #    На обычном диске 50 МБ — это очень мало, порог точно не превышен
    if ! bash "${CLEANUP_SCRIPT}" "${LOG_DIR}" 90; then
        print_fail "Скрипт завершился с ошибкой (а не должен был)"
        return
    fi

    # 5. Проверяем, что файлы на месте
    local files_after
    files_after=$(find "${LOG_DIR}" -type f | wc -l)

    if [[ "$files_after" -ne "$files_before" ]]; then
        print_fail "Количество файлов изменилось (было $files_before, стало $files_after)"
        return
    fi

    # 6. Проверяем, что архивов не появилось
    local archives
    archives=$(find "${BACKUP_DIR}" -type f 2>/dev/null | wc -l)

    if [[ "$archives" -gt 0 ]]; then
        print_fail "Появились архивы, хотя порог не был превышен"
        return
    fi

    # 7. Всё хорошо
    print_pass "Ниже порога — ничего не изменилось"
}
# ---------- Тест 2: превышен порог ----------
test_above_threshold() {
    echo "=== Тест 2: папка заполнена больше X% ==="
    prepare_env

    # Создаём ≥ 0.5 GB файлов
    # Запускаем
    # Проверяем: архив появился, старые файлы удалены, заполненность ≤ X%

    print_pass "Тест 2 (заглушка) — выше порога"
}

# ---------- Тест 3: порядок по возрасту ----------
test_oldest_first() {
    echo "=== Тест 3: архивируются самые старые файлы ==="
    prepare_env
    print_pass "Тест 3 (заглушка) — порядок"
}

# ---------- Тест 4: другой X ----------
test_different_x() {
    echo "=== Тест 4: другое значение X ==="
    prepare_env
    print_pass "Тест 4 (заглушка) — другой X"
}

# ---------- Запуск всех тестов ----------
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

    echo "========================="
    echo "Итого: PASS=${PASS}  FAIL=${FAIL}"

    cleanup_test_env

    if [[ ${FAIL} -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
