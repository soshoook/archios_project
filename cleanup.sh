#!/usr/bin/env bash

if [[ $# -ne 2 ]]; then
    echo "Использование: bash cleanup.sh <папка_логов> <порог_в_процентах>" >&2
    exit 1
fi

log_dir=$1
threshold_input=$2

if [[ ! -d "$log_dir" ]]; then
    echo "Ошибка: папка не существует: $log_dir" >&2
    exit 1
fi

if [[ ! $threshold_input =~ ^[0-9]{1,3}$ ]]; then
    echo "Ошибка: порог X должен быть целым числом от 0 до 100." >&2
    exit 1
fi

threshold=$((10#$threshold_input))
if (( threshold > 100 )); then
    echo "Ошибка: порог X должен быть целым числом от 0 до 100." >&2
    exit 1
fi
#темка как раз для вирт диска
if ! disk_info=$(df -P "$log_dir"); then
    echo "Ошибка: не удалось определить заполненность для $log_dir" >&2
    exit 1
fi

usage=$(printf '%s\n' "$disk_info" | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')
if [[ ! $usage =~ ^[0-9]+$ ]]; then
    echo "Ошибка: df вернул неожиданный результат." >&2
    exit 1
fi

echo "Папка логов: $log_dir"
echo "Заполненность диска для этой папки: $usage%"
echo "Порог X: $threshold%"

if (( usage > threshold )); then
    echo "Порог превышен: требуется очистка."
    echo "Архивирование и удаление файлов будут добавлены на следующем этапе."
else
    echo "Порог не превышен: очистка не требуется."
fi