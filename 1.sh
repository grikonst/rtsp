#!/bin/bash

# RTSP Stream Manager - TUI для управления трансляцией видео в RTSP
# Версия: 1.1 (с поддержкой CSV отчётов)
# Автор: System Admin

# Конфигурация
CONFIG_DIR="$HOME/.rtsp-srv"
CONFIG_FILE="$CONFIG_DIR/config.conf"
STREAMS_FILE="$CONFIG_DIR/streams.conf"
LOG_FILE="$CONFIG_DIR/streams.log"
PID_DIR="$CONFIG_DIR/pids"
REPORTS_DIR="$CONFIG_DIR/reports"

# Создание директорий конфигурации
init_config() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$PID_DIR"
    mkdir -p "$REPORTS_DIR"
    touch "$CONFIG_FILE"
    touch "$STREAMS_FILE"
    touch "$LOG_FILE"
    
    # Настройки по умолчанию
    if [ ! -s "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
# RTSP Server Configuration
RTSP_SERVER_IP="localhost"
RTSP_SERVER_PORT="8554"
MEDIAMTX_IMAGE="bluenviron/mediamtx:latest"
VIDEO_DIR="$HOME/Videos"
STREAM_LOOP="true"
RTSP_TRANSPORT="tcp"
EOF
    fi
}

# Загрузка конфигурации
load_config() {
    source "$CONFIG_FILE"
}

# Сохранение конфигурации
save_config() {
    cat > "$CONFIG_FILE" << EOF
# RTSP Server Configuration
RTSP_SERVER_IP="$RTSP_SERVER_IP"
RTSP_SERVER_PORT="$RTSP_SERVER_PORT"
MEDIAMTX_IMAGE="$MEDIAMTX_IMAGE"
VIDEO_DIR="$VIDEO_DIR"
STREAM_LOOP="$STREAM_LOOP"
RTSP_TRANSPORT="$RTSP_TRANSPORT"
EOF
}

# Проверка и запуск MediaMTX
start_mediamtx() {
    if ! docker ps | grep -q "rtsp-mediamtx"; then
        docker stop rtsp-mediamtx 2>/dev/null
        docker rm rtsp-mediamtx 2>/dev/null
        
        cat > "$CONFIG_DIR/mediamtx.yml" << EOF
api: false
rtspAddress: :$RTSP_SERVER_PORT
rtpAddress: :8002
rtcpAddress: :8003
paths:
  all:
    source: publisher
    sourceProtocol: udp
EOF
        
        docker run -d \
            --name rtsp-mediamtx \
            --restart unless-stopped \
            -p $RTSP_SERVER_PORT:$RTSP_SERVER_PORT \
            -v "$CONFIG_DIR/mediamtx.yml:/mediamtx.yml" \
            $MEDIAMTX_IMAGE > /dev/null 2>&1
        
        sleep 2
        echo "MediaMTX запущен"
    else
        echo "MediaMTX уже работает"
    fi
}

# Остановка MediaMTX
stop_mediamtx() {
    if docker ps | grep -q "rtsp-mediamtx"; then
        docker stop rtsp-mediamtx > /dev/null 2>&1
        docker rm rtsp-mediamtx > /dev/null 2>&1
        echo "MediaMTX остановлен"
    fi
}

# Получение метаданных видео с помощью ffprobe
get_video_metadata() {
    local video_file="$1"
    
    # Проверяем существование файла
    if [ ! -f "$video_file" ]; then
        echo "N/A|N/A|N/A|N/A|N/A"
        return
    fi
    
    # Получаем разрешение
    local resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$video_file" 2>/dev/null | head -1)
    if [ -n "$resolution" ]; then
        resolution=$(echo "$resolution" | sed 's/,/x/')
    else
        resolution="N/A"
    fi
    
    # Получаем FPS
    local fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$video_file" 2>/dev/null | head -1)
    if [ -n "$fps" ] && [ "$fps" != "0/0" ]; then
        fps=$(echo "scale=2; $fps" | bc 2>/dev/null || echo "$fps")
    else
        fps="N/A"
    fi
    
    # Получаем битрейт
    local bitrate=$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$video_file" 2>/dev/null | head -1)
    if [ -n "$bitrate" ] && [ "$bitrate" != "N/A" ] && [ "$bitrate" != "0" ]; then
        bitrate=$(echo "scale=2; $bitrate/1000" | bc 2>/dev/null)" kbps"
    else
        # Пробуем получить битрейт из видеопотока
        bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$video_file" 2>/dev/null | head -1)
        if [ -n "$bitrate" ] && [ "$bitrate" != "N/A" ] && [ "$bitrate" != "0" ]; then
            bitrate=$(echo "scale=2; $bitrate/1000" | bc 2>/dev/null)" kbps"
        else
            bitrate="N/A"
        fi
    fi
    
    # Получаем кодек
    local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$video_file" 2>/dev/null | head -1)
    [ -z "$codec" ] && codec="N/A"
    
    # Получаем длительность
    local duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video_file" 2>/dev/null | head -1)
    if [ -n "$duration" ] && [ "$duration" != "N/A" ]; then
        # Конвертируем в формат HH:MM:SS
        duration_seconds=${duration%.*}
        hours=$((duration_seconds / 3600))
        minutes=$(((duration_seconds % 3600) / 60))
        seconds=$((duration_seconds % 60))
        duration=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)
    else
        duration="N/A"
    fi
    
    echo "$resolution|$fps|$bitrate|$codec|$duration"
}

# Генерация RTSP ссылки
get_rtsp_url() {
    local video_file="$1"
    local filename=$(basename "$video_file")
    local name_without_ext="${filename%.*}"
    local mount_point=$(echo "$name_without_ext" | sed 's/[^a-zA-Z0-9._-]/_/g')
    echo "rtsp://$RTSP_SERVER_IP:$RTSP_SERVER_PORT/$mount_point"
}

# Экспорт отчёта в CSV
export_to_csv() {
    local video_dir="$1"
    local output_file="$2"
    local status_filter="$3"  # all, running, stopped
    
    # Заголовки CSV
    echo "Видеофайл (полный путь);Разрешение;FPS;Битрейт;Кодек;Длительность;RTSP-ссылка;Статус" > "$output_file"
    
    # Получаем список видеофайлов
    local video_files=$(find "$video_dir" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" \) | sort)
    
    local count=0
    for video_file in $video_files; do
        # Получаем метаданные
        IFS='|' read -r resolution fps bitrate codec duration <<< "$(get_video_metadata "$video_file")"
        
        # Получаем RTSP ссылку
        local rtsp_url=$(get_rtsp_url "$video_file")
        
        # Получаем статус потока
        local filename=$(basename "$video_file")
        local name_without_ext="${filename%.*}"
        local mount_point=$(echo "$name_without_ext" | sed 's/[^a-zA-Z0-9._-]/_/g')
        local stream_status=$(get_stream_status "$mount_point")
        local status_text=""
        
        case $stream_status in
            "running") status_text="РАБОТАЕТ" ;;
            "stopped") status_text="ОСТАНОВЛЕН" ;;
            *) status_text="НЕ ЗАПУЩЕН" ;;
        esac
        
        # Фильтруем по статусу если нужно
        if [ "$status_filter" = "running" ] && [ "$stream_status" != "running" ]; then
            continue
        fi
        if [ "$status_filter" = "stopped" ] && [ "$stream_status" != "stopped" ]; then
            continue
        fi
        
        # Добавляем строку в CSV (используем точку с запятой как разделитель)
        echo "\"$video_file\";\"$resolution\";\"$fps\";\"$bitrate\";\"$codec\";\"$duration\";\"$rtsp_url\";\"$status_text\"" >> "$output_file"
        ((count++))
    done
    
    echo "$count"
}

# Расширенный экспорт с дополнительной информацией
export_detailed_report() {
    local output_file="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Заголовки с дополнительными полями
    cat > "$output_file" << EOF
═══════════════════════════════════════════════════════════════════════════════
ОТЧЁТ RTSP STREAM MANAGER
═══════════════════════════════════════════════════════════════════════════════
Дата и время: $timestamp
Сервер: $RTSP_SERVER_IP:$RTSP_SERVER_PORT
Папка с видео: $VIDEO_DIR
Режим цикла: $([ "$STREAM_LOOP" = "true" ] && echo "Включен" || echo "Выключен")
Транспорт: $RTSP_TRANSPORT
═══════════════════════════════════════════════════════════════════════════════

EOF
    
    # Экспортируем основной CSV
    local csv_file="$REPORTS_DIR/report_$(date '+%Y%m%d_%H%M%S').csv"
    local count=$(export_to_csv "$VIDEO_DIR" "$csv_file" "all")
    
    # Добавляем статистику в отчет
    cat >> "$output_file" << EOF
СТАТИСТИКА:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Всего видеофайлов: $count
Активных потоков: $(ls "$PID_DIR" 2>/dev/null | wc -l)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ДЕТАЛЬНЫЙ ОТЧЁТ В CSV ФОРМАТЕ:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Файл сохранён: $csv_file

Содержимое отчёта:
EOF
    
    # Добавляем содержимое CSV в отчет
    cat "$csv_file" >> "$output_file"
    
    echo "$csv_file"
}

# Меню экспорта отчётов
export_menu() {
    while true; do
        local choice=$(whiptail --title "📊 ЭКСПОРТ ОТЧЁТОВ" \
            --menu "Выберите тип отчёта:" \
            18 70 7 \
            "1" "📄 Экспорт всех видео в CSV" \
            "2" "▶️  Экспорт только работающих потоков" \
            "3" "⏹️  Экспорт остановленных потоков" \
            "4" "📋 Расширенный отчёт (с метаданными)" \
            "5" "📁 Показать все сохранённые отчёты" \
            "6" "🗑️  Очистить старые отчёты" \
            "7" "🔙 Назад в главное меню" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1)
                local output_file="$REPORTS_DIR/report_all_$(date '+%Y%m%d_%H%M%S').csv"
                whiptail --title "Экспорт" --infobox "Сбор информации о видео..." 5 50
                local count=$(export_to_csv "$VIDEO_DIR" "$output_file" "all")
                whiptail --title "✅ Экспорт завершён" \
                    --msgbox "Отчёт сохранён:\n$output_file\n\nВсего видео: $count\n\nРазделитель: точка с запятой (;)" \
                    12 70
                ;;
            2)
                local output_file="$REPORTS_DIR/report_running_$(date '+%Y%m%d_%H%M%S').csv"
                whiptail --title "Экспорт" --infobox "Сбор информации о работающих потоках..." 5 50
                local count=$(export_to_csv "$VIDEO_DIR" "$output_file" "running")
                whiptail --title "✅ Экспорт завершён" \
                    --msgbox "Отчёт сохранён:\n$output_file\n\nРаботающих потоков: $count" \
                    10 70
                ;;
            3)
                local output_file="$REPORTS_DIR/report_stopped_$(date '+%Y%m%d_%H%M%S').csv"
                whiptail --title "Экспорт" --infobox "Сбор информации об остановленных потоках..." 5 50
                local count=$(export_to_csv "$VIDEO_DIR" "$output_file" "stopped")
                whiptail --title "✅ Экспорт завершён" \
                    --msgbox "Отчёт сохранён:\n$output_file\n\nОстановленных потоков: $count" \
                    10 70
                ;;
            4)
                local output_file="$REPORTS_DIR/detailed_report_$(date '+%Y%m%d_%H%M%S').txt"
                whiptail --title "Расширенный отчёт" --infobox "Формирование детального отчёта..." 5 50
                local report_file=$(export_detailed_report "$output_file")
                whiptail --title "✅ Расширенный отчёт готов" \
                    --msgbox "Отчёт сохранён:\n$report_file\n\nОтчёт включает:\n- Статистику сервера\n- Метаданные видео\n- CSV таблицу\n- Статусы потоков" \
                    12 70
                ;;
            5)
                if [ -d "$REPORTS_DIR" ] && [ -n "$(ls -A $REPORTS_DIR 2>/dev/null)" ]; then
                    local report_list=$(ls -lh "$REPORTS_DIR" | tail -n +2 | awk '{print $9 " (" $5 ")"}')
                    whiptail --title "Сохранённые отчёты" \
                        --msgbox "Директория: $REPORTS_DIR\n\nФайлы:\n$report_list\n\nДля просмотра используйте:\ncat <имя_файла>" \
                        20 70
                else
                    whiptail --title "Информация" --msgbox "Нет сохранённых отчётов" 8 40
                fi
                ;;
            6)
                if whiptail --title "Подтверждение" --yesno "Удалить все отчёты старше 7 дней?" 8 50; then
                    local deleted=$(find "$REPORTS_DIR" -type f -name "*.csv" -o -name "*.txt" -mtime +7 | wc -l)
                    find "$REPORTS_DIR" -type f -name "*.csv" -o -name "*.txt" -mtime +7 -delete
                    whiptail --title "✅ Очистка завершена" --msgbox "Удалено отчётов: $deleted" 8 40
                fi
                ;;
            7)
                break
                ;;
        esac
    done
}

# Запуск потока для одного видео
start_stream() {
    local video_file="$1"
    local filename=$(basename "$video_file")
    local name_without_ext="${filename%.*}"
    local mount_point=$(echo "$name_without_ext" | sed 's/[^a-zA-Z0-9._-]/_/g')
    local pid_file="$PID_DIR/${mount_point}.pid"
    
    if [ -f "$pid_file" ] && docker ps | grep -q "$(cat "$pid_file")" 2>/dev/null; then
        return 1
    fi
    
    local loop_flag=""
    [ "$STREAM_LOOP" = "true" ] && loop_flag="-stream_loop -1"
    
    local rtsp_url="rtsp://$RTSP_SERVER_IP:$RTSP_SERVER_PORT/$mount_point"
    local transport_flag=""
    [ "$RTSP_TRANSPORT" = "tcp" ] && transport_flag="-rtsp_transport tcp"
    
    docker run -d \
        --name "stream-$mount_point" \
        --network host \
        -v "$(dirname "$video_file"):/videos" \
        --restart unless-stopped \
        jrottenberg/ffmpeg:latest \
        ffmpeg $loop_flag -re \
        -i "/videos/$filename" \
        -c copy \
        $transport_flag \
        -f rtsp "$rtsp_url" > /dev/null 2>&1
    
    local container_id=$(docker ps -q --filter "name=stream-$mount_point")
    if [ -n "$container_id" ]; then
        echo "$container_id" > "$pid_file"
        echo "$(date): Запущен поток $mount_point -> $rtsp_url" >> "$LOG_FILE"
        return 0
    else
        return 1
    fi
}

# Остановка потока
stop_stream() {
    local mount_point="$1"
    local pid_file="$PID_DIR/${mount_point}.pid"
    
    if [ -f "$pid_file" ]; then
        local container_id=$(cat "$pid_file")
        docker stop "$container_id" > /dev/null 2>&1
        docker rm "$container_id" > /dev/null 2>&1
        rm "$pid_file"
        echo "$(date): Остановлен поток $mount_point" >> "$LOG_FILE"
        return 0
    fi
    return 1
}

# Получение статуса потока
get_stream_status() {
    local mount_point="$1"
    local pid_file="$PID_DIR/${mount_point}.pid"
    
    if [ -f "$pid_file" ]; then
        local container_id=$(cat "$pid_file")
        if docker ps | grep -q "$container_id"; then
            echo "running"
            return 0
        else
            rm "$pid_file"
            echo "stopped"
            return 1
        fi
    else
        echo "stopped"
        return 1
    fi
}

# Отображение статуса всех потоков
show_status() {
    local streams=$(ls "$PID_DIR" 2>/dev/null | sed 's/.pid$//')
    
    if [ -z "$streams" ]; then
        whiptail --title "Статус потоков" --msgbox "Нет активных потоков" 8 40
        return
    fi
    
    local status_text=""
    local running_count=0
    local stopped_count=0
    
    for stream in $streams; do
        local status=$(get_stream_status "$stream")
        local rtsp_url="rtsp://$RTSP_SERVER_IP:$RTSP_SERVER_PORT/$stream"
        if [ "$status" = "running" ]; then
            status_text="${status_text}\n✅ $stream: РАБОТАЕТ\n   📺 $rtsp_url\n"
            ((running_count++))
        else
            status_text="${status_text}\n❌ $stream: ОСТАНОВЛЕН\n   📺 $rtsp_url\n"
            ((stopped_count++))
        fi
    done
    
    status_text="Всего: $((running_count + stopped_count)) | Работает: $running_count | Остановлено: $stopped_count\n$status_text"
    
    whiptail --title "Статус потоков" --msgbox "$status_text" 20 70
}

# Меню выбора видеофайлов
select_videos() {
    local video_dir="$1"
    local files=()
    
    while IFS= read -r file; do
        local filename=$(basename "$file")
        # Получаем метаданные для отображения
        IFS='|' read -r resolution fps bitrate codec duration <<< "$(get_video_metadata "$file")"
        local info="$filename [$resolution, $fps fps, $duration]"
        files+=("$file" "$info" "OFF")
    done < <(find "$video_dir" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" \) | sort)
    
    if [ ${#files[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Видеофайлы не найдены в папке:\n$video_dir" 8 50
        return 1
    fi
    
    local selected=$(whiptail --title "Выбор видео для трансляции" \
        --checklist "Выберите видео для трансляции (ПРОБЕЛ - выбрать, ENTER - подтвердить)\n\nОтображается: имя [разрешение, FPS, длительность]" \
        22 80 12 "${files[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$selected" ]; then
        echo "$selected" | tr -d '"'
        return 0
    fi
    return 1
}

# Запуск выбранных потоков
start_selected_streams() {
    local selected_files="$1"
    local started=0
    local failed=0
    
    if ! docker ps | grep -q "rtsp-mediamtx"; then
        whiptail --title "Информация" --msgbox "Запускаем MediaMTX сервер..." 8 40
        start_mediamtx
        sleep 2
    fi
    
    for file in $selected_files; do
        local filename=$(basename "$file")
        whiptail --title "Запуск" --infobox "Запускаем поток: $filename" 5 50
        if start_stream "$file"; then
            ((started++))
        else
            ((failed++))
        fi
        sleep 1
    done
    
    whiptail --title "Результат" --msgbox "✅ Запущено потоков: $started\n❌ Ошибок: $failed" 8 40
}

# Остановка всех потоков
stop_all_streams() {
    if whiptail --title "Подтверждение" --yesno "Остановить все потоки?" 8 40; then
        local streams=$(ls "$PID_DIR" 2>/dev/null | sed 's/.pid$//')
        local stopped=0
        
        for stream in $streams; do
            if stop_stream "$stream"; then
                ((stopped++))
            fi
        done
        
        whiptail --title "Результат" --msgbox "Остановлено потоков: $stopped" 8 40
    fi
}

# Меню настроек
settings_menu() {
    while true; do
        local settings_info="═══════════════════════════════════════\n"
        settings_info="${settings_info}  📡 IP адрес сервера:     $RTSP_SERVER_IP\n"
        settings_info="${settings_info}  🔌 Порт сервера:         $RTSP_SERVER_PORT\n"
        settings_info="${settings_info}  📁 Папка с видео:        $VIDEO_DIR\n"
        settings_info="${settings_info}  🔁 Бесконечный цикл:     $([ "$STREAM_LOOP" = "true" ] && echo "ДА" || echo "НЕТ")\n"
        settings_info="${settings_info}  🌐 Транспорт RTSP:       $([ "$RTSP_TRANSPORT" = "tcp" ] && echo "TCP" || echo "UDP")\n"
        settings_info="${settings_info}  🐳 Образ MediaMTX:       $MEDIAMTX_IMAGE\n"
        settings_info="${settings_info}═══════════════════════════════════════"
        
        local choice=$(whiptail --title "⚙️  НАСТРОЙКИ" \
            --menu "$settings_info\n\nВыберите параметр для изменения:" \
            22 70 8 \
            "1" "📡 IP адрес RTSP сервера" \
            "2" "🔌 Порт RTSP сервера" \
            "3" "📁 Папка с видеофайлами" \
            "4" "🔄 Бесконечный цикл (ДА/НЕТ)" \
            "5" "🌐 Транспорт RTSP (TCP/UDP)" \
            "6" "🐳 Образ MediaMTX в Docker" \
            "7" "💾 Сохранить и вернуться" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1)
                local new_ip=$(whiptail --inputbox "Введите IP адрес RTSP сервера:" 8 50 "$RTSP_SERVER_IP" 3>&1 1>&2 2>&3)
                [ -n "$new_ip" ] && RTSP_SERVER_IP="$new_ip"
                ;;
            2)
                local new_port=$(whiptail --inputbox "Введите порт RTSP сервера:" 8 40 "$RTSP_SERVER_PORT" 3>&1 1>&2 2>&3)
                [ -n "$new_port" ] && RTSP_SERVER_PORT="$new_port"
                ;;
            3)
                local new_dir=$(whiptail --inputbox "Введите путь к папке с видео:" 8 60 "$VIDEO_DIR" 3>&1 1>&2 2>&3)
                if [ -n "$new_dir" ]; then
                    if [ -d "$new_dir" ]; then
                        VIDEO_DIR="$new_dir"
                    else
                        whiptail --title "Ошибка" --msgbox "Папка не существует!\nСоздаю папку: $new_dir" 8 50
                        mkdir -p "$new_dir"
                        VIDEO_DIR="$new_dir"
                    fi
                fi
                ;;
            4)
                local new_loop=$(whiptail --radiolist "Режим воспроизведения:" 10 50 2 \
                    "true" "Бесконечный цикл (зациклить видео)" $( [ "$STREAM_LOOP" = "true" ] && echo ON || echo OFF ) \
                    "false" "Однократное воспроизведение" $( [ "$STREAM_LOOP" = "false" ] && echo ON || echo OFF ) \
                    3>&1 1>&2 2>&3)
                [ -n "$new_loop" ] && STREAM_LOOP="$new_loop"
                ;;
            5)
                local new_transport=$(whiptail --radiolist "Протокол транспорта RTSP:" 12 50 2 \
                    "tcp" "TCP (надежнее, медленнее)" $( [ "$RTSP_TRANSPORT" = "tcp" ] && echo ON || echo OFF ) \
                    "udp" "UDP (быстрее, менее надежен)" $( [ "$RTSP_TRANSPORT" = "udp" ] && echo ON || echo OFF ) \
                    3>&1 1>&2 2>&3)
                [ -n "$new_transport" ] && RTSP_TRANSPORT="$new_transport"
                ;;
            6)
                local new_image=$(whiptail --inputbox "Введите имя Docker образа MediaMTX:" 8 70 "$MEDIAMTX_IMAGE" 3>&1 1>&2 2>&3)
                [ -n "$new_image" ] && MEDIAMTX_IMAGE="$new_image"
                ;;
            7)
                save_config
                break
                ;;
        esac
        
        save_config
    done
}

# Главное меню
main_menu() {
    while true; do
        local choice=$(whiptail --title "🎬 RTSP STREAM MANAGER" \
            --menu "Управление RTSP трансляциями видео\n═══════════════════════════════════════" \
            22 70 10 \
            "1" "🚀 Запустить MediaMTX сервер" \
            "2" "🛑 Остановить MediaMTX сервер" \
            "3" "🎥 Выбрать видео и запустить трансляцию" \
            "4" "📁 Выбрать ВСЕ видео и запустить" \
            "5" "⏹️  Остановить все потоки" \
            "6" "📊 Показать статус потоков" \
            "7" "📈 Экспорт отчётов в CSV" \
            "8" "⚙️  Настройки" \
            "9" "📋 Показать логи" \
            "10" "🚪 Выход" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1)
                start_mediamtx
                whiptail --title "Информация" --msgbox "✅ MediaMTX сервер запущен\n🌐 Порт: $RTSP_SERVER_PORT\n📡 IP: $RTSP_SERVER_IP" 10 50
                ;;
            2)
                stop_all_streams
                stop_mediamtx
                whiptail --title "Информация" --msgbox "✅ MediaMTX сервер остановлен" 8 40
                ;;
            3)
                local selected=$(select_videos "$VIDEO_DIR")
                if [ $? -eq 0 ] && [ -n "$selected" ]; then
                    start_selected_streams "$selected"
                fi
                ;;
            4)
                local all_files=$(find "$VIDEO_DIR" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" \) | sort | tr '\n' ' ')
                if [ -n "$all_files" ]; then
                    local count=$(echo "$all_files" | wc -w)
                    if whiptail --title "Подтверждение" --yesno "Запустить трансляцию ВСЕХ видео ($count файлов) из папки:\n$VIDEO_DIR" 10 60; then
                        start_selected_streams "$all_files"
                    fi
                else
                    whiptail --title "Ошибка" --msgbox "❌ Видеофайлы не найдены в папке:\n$VIDEO_DIR" 8 50
                fi
                ;;
            5)
                stop_all_streams
                ;;
            6)
                show_status
                ;;
            7)
                export_menu
                ;;
            8)
                settings_menu
                ;;
            9)
                if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
                    whiptail --title "Журнал событий" --textbox "$LOG_FILE" 25 80
                else
                    whiptail --title "Журнал событий" --msgbox "Журнал пуст" 8 40
                fi
                ;;
            10)
                if whiptail --title "Выход" --yesno "Вы уверены, что хотите выйти?\n\nПотоки продолжат работать в фоне." 10 50; then
                    echo "До свидания!"
                    exit 0
                fi
                ;;
        esac
    done
}

# Проверка зависимостей
check_dependencies() {
    local deps=("docker" "whiptail" "ffprobe" "bc")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "❌ Отсутствуют зависимости: ${missing[*]}"
        echo "Пожалуйста, установите:"
        echo "  - docker"
        echo "  - whiptail (пакет whiptail или newt)"
        echo "  - ffmpeg/ffprobe (пакет ffmpeg)"
        echo "  - bc (калькулятор)"
        exit 1
    fi
}

# Показать баннер
show_banner() {
    clear
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   🎬 RTSP Stream Manager v1.1 - Управление RTSP трансляциями${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}   📁 Конфигурация: $CONFIG_DIR${NC}"
    echo -e "${YELLOW}   📝 Лог-файл: $LOG_FILE${NC}"
    echo -e "${YELLOW}   📊 Отчёты: $REPORTS_DIR${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Основная функция
main() {
    show_banner
    check_dependencies
    init_config
    load_config
    
    if ! docker info &> /dev/null; then
        echo "❌ Docker не запущен. Пожалуйста, запустите Docker сначала."
        exit 1
    fi
    
    if [ ! -d "$VIDEO_DIR" ]; then
        mkdir -p "$VIDEO_DIR"
        echo "✅ Создана папка для видео: $VIDEO_DIR"
        sleep 2
    fi
    
    main_menu
}

# Запуск
main "$@"
