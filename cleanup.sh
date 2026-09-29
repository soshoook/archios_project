#!/usr/bin/env bash

if [[ $# -ne 2 ]]; then
    echo "Использование: bash cleanup.sh <папка_логов> <порог_в_процентах>" >&2
    exit 1
fi
log_dir=$1
threshold_input=$2
backup_dir=${BACKUP_DIR:-/backup}
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
if [[ ! -d "$backup_dir" || ! -w "$backup_dir" ]]; then
    echo "Ошибка: папка архива недоступна для записи: $backup_dir" >&2
    exit 1
fi

log_dir=$(cd "$log_dir" && pwd -P) || exit 1
backup_dir=$(cd "$backup_dir" && pwd -P) || exit 1
log_device=$(df -P "$log_dir" | awk 'NR==2 {print $1}')
parent_device=$(df -P "$(dirname "$log_dir")" | awk 'NR==2 {print $1}')
backup_device=$(df -P "$backup_dir" | awk 'NR==2 {print $1}')
if [[ -z $log_device || $log_device == "$parent_device" ]]; then
    echo "Ошибка: папка логов должна быть точкой монтирования отдельного диска." >&2
    exit 1
fi
if [[ -z $backup_device || $log_device == "$backup_device" ]]; then
    echo "Ошибка: архив должен храниться на другом диске." >&2
    exit 1
fi

read_disk() {
    local line
    line=$(df -Pk "$log_dir" | awk 'NR==2 {print $2, $3, $5}') || return 1
    read -r total_kb used_kb usage <<< "$line"
    usage=${usage%%%}
    [[ $total_kb =~ ^[0-9]+$ && $used_kb =~ ^[0-9]+$ && $usage =~ ^[0-9]+$ ]]
}
if ! read_disk; then
    echo "Ошибка: не удалось определить заполненность диска." >&2
    exit 1
fi
echo "Заполненность диска с логами: $usage%; порог: $threshold%."
if (( usage <= threshold )); then
    echo "Порог не превышен: ничего делать не нужно."
    exit 0
fi

files=()
times=()
while IFS= read -r -d '' file; do
    if time=$(stat -f %m "$file" 2>/dev/null); then
        : # macOS
    elif time=$(stat -c %Y "$file" 2>/dev/null); then
        : # Linux
    else
        echo "Ошибка: не удалось прочитать дату файла: $file" >&2
        exit 1
    fi
    i=${#files[@]}
    while (( i > 0 && time < times[i-1] )); do
        files[i]=${files[i-1]}
        times[i]=${times[i-1]}
        ((i--))
    done
    files[i]=$file
    times[i]=$time
done < <(find "$log_dir" -maxdepth 1 -type f -print0)
if (( ${#files[@]} == 0 )); then
    echo "Ошибка: подходящих файлов нет. Ничего не удалено." >&2
    exit 1
fi

target_kb=$((total_kb * threshold / 100))
needed_kb=$((used_kb - target_kb))
selected=()
freed_kb=0
for file in "${files[@]}"; do
    selected+=("$file")
    size_kb=$(du -sk "$file" | awk '{print $1}')
    if [[ ! $size_kb =~ ^[0-9]+$ ]]; then
        echo "Ошибка: не удалось определить размер файла: $file" >&2
        exit 1
    fi
    freed_kb=$((freed_kb + size_kb))
    (( freed_kb >= needed_kb )) && break
done
if (( freed_kb < needed_kb )); then
    echo "Ошибка: файлов недостаточно для достижения порога. Ничего не удалено." >&2
    exit 1
fi

relative=()
for file in "${selected[@]}"; do
    relative+=("./${file##*/}")
done
temp_archive=$(mktemp "$backup_dir/.cleanup.XXXXXXXX") || exit 1
if ! tar -czf "$temp_archive" -C "$log_dir" -- "${relative[@]}"; then
    rm -f "$temp_archive"
    echo "Ошибка: архив не создан. Оригиналы сохранены." >&2
    exit 1
fi
if ! gzip -t "$temp_archive" || ! tar -tzf "$temp_archive" >/dev/null; then
    rm -f "$temp_archive"
    echo "Ошибка: архив повреждён. Оригиналы сохранены." >&2
    exit 1
fi
for i in "${!selected[@]}"; do
    if ! tar -xOf "$temp_archive" "${relative[i]}" | cmp - "${selected[i]}"; then
        rm -f "$temp_archive"
        echo "Ошибка: архив не совпадает с оригиналом. Оригиналы сохранены." >&2
        exit 1
    fi
done
archive="$backup_dir/logs_$(date +%Y%m%d_%H%M%S)_$$.tar.gz"
if ! mv "$temp_archive" "$archive"; then
    rm -f "$temp_archive"
    echo "Ошибка: архив не сохранён. Оригиналы сохранены." >&2
    exit 1
fi
echo "Проверенный архив: $archive; файлов: ${#selected[@]}."
for file in "${selected[@]}"; do
    if ! rm -- "$file"; then
        echo "Ошибка: файл не удалён: $file. Архив сохранён: $archive" >&2
        exit 1
    fi
done
if read_disk; then
    echo "После очистки заполненность: $usage%."
fi
