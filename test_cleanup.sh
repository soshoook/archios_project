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

# ---------- Тест 1: заполненность ниже порога ----------
test_below_threshold() {
    echo "=== Тест 1: папка заполнена меньше X% ==="
    prepare_env

    # Здесь потом создадим файлы так, чтобы было < X%
    # Пока заглушка

    # Запуск cleanup.sh
    # Проверка: архивов нет, файлы на месте

    print_pass "Тест 1 (заглушка) — ниже порога"
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