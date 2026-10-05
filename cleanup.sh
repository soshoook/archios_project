#!/usr/bin/env bash
set -o pipefail
export LC_ALL=C

error() {
    printf 'Ошибка: %s\n' "$*" >&2
}

if [[ $# -ne 2 ]]; then
    error "Использование: bash cleanup.sh <папка_логов> <порог_в_процентах>"
    exit 1
fi
log_dir=$1
threshold_input=$2
backup_dir=${BACKUP_DIR:-/backup}

if [[ ! -d "$log_dir" ]]; then
    error "папка не существует: $log_dir"
    exit 1
fi
if [[ ! $threshold_input =~ ^[0-9]+$ ]]; then
    error "порог X должен быть целым числом от 0 до 100"
    exit 1
fi
while [[ ${#threshold_input} -gt 1 && $threshold_input == 0* ]]; do
    threshold_input=${threshold_input#0}
done
if (( ${#threshold_input} > 3 )); then
    error "порог X должен быть целым числом от 0 до 100"
    exit 1
fi
threshold=$((10#$threshold_input))
if (( threshold > 100 )); then
    error "порог X должен быть целым числом от 0 до 100"
    exit 1
fi
if [[ ! -d "$backup_dir" || ! -w "$backup_dir" || ! -x "$backup_dir" ]]; then
    error "папка архива недоступна для записи: $backup_dir"
    exit 1
fi
log_dir=$(cd "$log_dir" && pwd -P) || exit 1
backup_dir=$(cd "$backup_dir" && pwd -P) || exit 1
if [[ ! -r "$log_dir" || ! -w "$log_dir" || ! -x "$log_dir" ]]; then
    error "недостаточно прав для чтения и очистки: $log_dir"
    exit 1
fi
for tool in df awk stat du tar gzip cmp mktemp mv rm mkdir rmdir uname date; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        error "не найдена программа: $tool"
        exit 1
    fi
done

disk_device() {
    local output
    output=$(df -Pk "$1") || return 1
    printf '%s\n' "$output" | awk 'NR==2 {print $1}'
}
log_device=$(disk_device "$log_dir") || exit 1
parent_device=$(disk_device "$(dirname "$log_dir")") || exit 1
backup_device=$(disk_device "$backup_dir") || exit 1
if [[ -z $log_device || $log_device == "$parent_device" ]]; then
    error "папка логов должна быть точкой монтирования отдельного диска"
    exit 1
fi
if [[ -z $backup_device || $log_device == "$backup_device" ]]; then
    error "архив должен храниться на другой файловой системе"
    exit 1
fi

read_disk() {
    local output values
    output=$(df -Pk "$log_dir") || return 1
    values=$(printf '%s\n' "$output" | awk 'NR==2 {print $2, $3, $4, $5}')
    read -r total_kb used_kb available_kb usage <<< "$values"
    usage=${usage%%%}
    [[ $total_kb =~ ^[0-9]+$ && $used_kb =~ ^[0-9]+$ &&
       $available_kb =~ ^[0-9]+$ && $usage =~ ^[0-9]+$ ]] || return 1
    (( total_kb > 0 && used_kb + available_kb > 0 ))
}
#выбор между gzip и lzma
configure_archive() {
    case "${LAB1_MAX_COMPRESSION:-0}" in
        0) archive_ext=tar.gz; return 0 ;;
        1) archive_ext=tar.xz; return 0 ;;
        *) error "LAB1_MAX_COMPRESSION должен быть 0 или 1"; return 1 ;;
    esac
}
#добавила проверку если мы в режиме lzma
create_archive() {
    local destination=$1
    shift
    if [[ $archive_ext == tar.xz ]]; then
        tar -cJf "$destination" -C "$log_dir" -- "$@"
    else
        tar -czf "$destination" -C "$log_dir" -- "$@"
    fi
}
#проверка на целостность
check_archive() {
    if [[ $archive_ext == tar.xz ]]; then
        xz -t "$1" && tar -tJf "$1" >/dev/null
    else
        gzip -t "$1" && tar -tzf "$1" >/dev/null
    fi
}
extract_archived_file() {
    tar -xOf "$1" "$2"
}

if ! configure_archive || ! read_disk; then
    error "не удалось подготовить режим архива или прочитать заполненность"
    exit 1
fi
printf 'Заполненность диска с логами: %s%%; порог: %s%%.\n' "$usage" "$threshold"
if (( usage <= threshold )); then
    printf 'Порог не превышен: ничего делать не нужно.\n'
    exit 0
fi
lock_dir="$backup_dir/.cleanup.lock"
if ! mkdir "$lock_dir"; then
    error "папка архива занята другим запуском; проверьте $lock_dir"
    exit 1
fi
temp_archive=
release_resources() {
    [[ -z $temp_archive ]] || rm -f -- "$temp_archive"
    rmdir "$lock_dir" 2>/dev/null || true
}
trap release_resources EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$(uname -s)" in
    Darwin|FreeBSD) stat_style=bsd ;;
    *) stat_style=gnu ;;
esac
file_time() {
    if [[ $stat_style == bsd ]]; then
        stat -f %m "$1"
    else
        stat -c %Y "$1"
    fi
}
shopt -s nullglob dotglob
files=()
times=()
for file in "$log_dir"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    time=$(file_time "$file") || { error "не прочитана дата: $file"; exit 1; }
    [[ $time =~ ^-?[0-9]+$ ]] || { error "неверная дата: $file"; exit 1; }
    i=${#files[@]}
    while (( i > 0 && time < times[i-1] )); do
        files[i]=${files[i-1]}
        times[i]=${times[i-1]}
        ((i--))
    done
    files[i]=$file
    times[i]=$time
done
if (( ${#files[@]} == 0 )); then
    error "подходящих файлов нет; порог превышен"
    exit 1
fi

cursor=0
archived_count=0
round=0
while (( usage > threshold )); do
    target_kb=$(((used_kb + available_kb) * threshold / 100))
    needed_kb=$((used_kb - target_kb))
    selected=()
    relative=()
    estimated_kb=0
    while (( cursor < ${#files[@]} )); do
        file=${files[cursor]}
        ((cursor++))
        if [[ ! -f "$file" || -L "$file" ]]; then
            error "набор файлов изменился во время очистки: $file"
            exit 1
        fi
        size_output=$(du -k "$file") || { error "не прочитан размер: $file"; exit 1; }
        size_kb=${size_output%%[[:space:]]*}
        [[ $size_kb =~ ^[0-9]+$ ]] || { error "неверный размер: $file"; exit 1; }
        selected+=("$file")
        relative+=("./${file##*/}")
        estimated_kb=$((estimated_kb + size_kb))
        (( estimated_kb >= needed_kb )) && break
    done
    if (( ${#selected[@]} == 0 )); then
        error "файлы закончились, но заполненность $usage% всё ещё выше $threshold%"
        exit 1
    fi
    temp_archive=$(mktemp "$backup_dir/.cleanup.XXXXXXXX") || exit 1
    if ! create_archive "$temp_archive" "${relative[@]}" || ! check_archive "$temp_archive"; then
        error "архив не создан или не прошёл проверку; выбранные оригиналы сохранены"
        exit 1
    fi
    for i in "${!selected[@]}"; do
        if [[ ! -f ${selected[i]} || -L ${selected[i]} ]] ||
           ! extract_archived_file "$temp_archive" "${relative[i]}" | cmp - "${selected[i]}"; then
            error "архив не совпадает с оригиналом; выбранные файлы сохранены"
            exit 1
        fi
    done
    ((round++))
    archive="$backup_dir/logs_$(date +%Y%m%d_%H%M%S)_${temp_archive##*.}_${round}.${archive_ext}"
    if ! mv -- "$temp_archive" "$archive"; then
        error "архив не сохранён; выбранные оригиналы сохранены"
        exit 1
    fi
    temp_archive=
    printf 'Проверенный архив: %s; файлов: %s.\n' "$archive" "${#selected[@]}"
    for i in "${!selected[@]}"; do
        if [[ ! -f ${selected[i]} || -L ${selected[i]} ]] ||
           ! extract_archived_file "$archive" "${relative[i]}" | cmp - "${selected[i]}"; then
            error "файл изменился перед удалением: ${selected[i]}; архив сохранён"
            exit 1
        fi
        if ! rm -- "${selected[i]}"; then
            error "файл не удалён: ${selected[i]}; архив сохранён: $archive"
            exit 1
        fi
        ((archived_count++))
    done
    if ! read_disk; then
        error "не удалось проверить заполненность после очистки; архив сохранён"
        exit 1
    fi
    printf 'После очистки заполненность: %s%%.\n' "$usage"
done
printf 'Готово: заполненность %s%% <= %s%%; архивировано файлов: %s.\n' "$usage" "$threshold" "$archived_count"
exit 0
