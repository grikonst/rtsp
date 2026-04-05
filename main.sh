#!/bin/bash

# RTSP Stream Manager - TUI для управления трансляцией видео в RTSP
# Версия: 3.0
# Исправлены проблемы с артефактами, добавлен выбор режима воспроизведения

# Конфигурация
CONFIG_DIR="$HOME/.rtsp-srv"
CONFIG_FILE="$CONFIG_DIR/config.conf"
STREAMS_FILE="$CONFIG_DIR/streams.conf"
LOG_FILE="$CONFIG_DIR/streams.log"
PID_DIR="$CONFIG_DIR/pids"
REPORT_DIR="$CONFIG_DIR/reports"
CSV_EXPORT="$REPORT_DIR/streams_report_$(date +%Y%m%d_%H%M%S).csv"

# Цвета для вывода (если не в TUI)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Создание директорий конфигурации
init_config() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$PID_DIR"
    mkdir -p "$REPORT_DIR"
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
RTSP_TRANSPORT="tcp"
USE_PV="true"
VIDEO_CODEC="libx264"
PRESET="fast"
CRF="23"
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
RTSP_TRANSPORT="$RTSP_TRANSPORT"
USE_PV="$USE_PV"
VIDEO_CODEC="$VIDEO_CODEC"
PRESET="$PRESET"
CRF="$CRF"
EOF
}

# Проверка наличия pv
check_pv() {
    if [ "$USE_PV" = "true" ] && command -v pv &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Функция для отображения прогресса
show_progress() {
    local message="$1"
    local duration="$2"
    
    if check_pv; then
        echo "$message" | pv -qL 10
        sleep "$duration"
    else
        echo "$message"
        sleep "$duration"
    fi
}

# Получение метаданных видео через ffmpeg
get_video_metadata() {
    local video_file="$1"
    
    # Получаем разрешение
    local resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$video_file" 2>/dev/null | sed 's/,/x/')
    [ -z "$resolution" ] && resolution="N/A"
    
    # Получаем FPS
    local fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$video_file" 2>/dev/null | bc -l 2>/dev/null | xargs printf "%.2f")
    [ -z "$fps" ] && fps="N/A"
    
    # Получаем битрейт
    local bitrate=$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$video_file" 2>/dev/null)
    if [ -n "$bitrate" ] && [ "$bitrate" != "N/A" ]; then
        bitrate=$(echo "scale=2; $bitrate/1000" | bc 2>/dev/null)
        bitrate="${bitrate} kbps"
    else
        bitrate="N/A"
    fi
    
    # Получаем кодек видео
    local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$video_file" 2>/dev/null)
    [ -z "$codec" ] && codec="N/A"
    
    # Получаем длительность
    local duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video_file" 2>/dev/null)
    if [ -n "$duration" ] && [ "$duration" != "N/A" ]; then
        duration=$(printf '%02d:%02d:%02d' $(echo "$duration/3600" | bc) $(echo "($duration%3600)/60" | bc) $(echo "$duration%60" | bc))
    else
        duration="N/A"
    fi
    
    # Получаем профиль и уровень кодекса
    local profile=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of csv=p=0 "$video_file" 2>/dev/null)
    [ -z "$profile" ] && profile="N/A"
    
    echo "$resolution|$fps|$bitrate|$codec|$duration|$profile"
}

# Экспорт отчета в CSV
export_to_csv() {
    local streams_data="$1"
    local csv_file="$CSV_EXPORT"
    
    # Создаем заголовки CSV
    echo "Видеофайл,Разрешение,FPS,Битрейт,Кодек,Профиль,Длительность,RTSP-ссылка,Статус,Режим,Дата_запуска" > "$csv_file"
    
    # Добавляем данные
    echo -e "$streams_data" >> "$csv_file"
    
    # Убираем лишние кавычки
    sed -i 's/"//g' "$csv_file"
    
    echo "$csv_file"
}

# Сбор информации о всех видео
collect_videos_info() {
    local video_dir="$1"
    local info=""
    local total_files=0
    local current=0
    
    # Получаем список видеофайлов
    local video_files=()
    while IFS= read -r file; do
        video_files+=("$file")
    done < <(find "$video_dir" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" \) | sort)
    
    total_files=${#video_files[@]}
    
    if [ $total_files -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Видеофайлы не найдены в папке:\n$video_dir" 8 50
        return 1
    fi
    
    # Показываем прогресс-бар через whiptail
    for video_file in "${video_files[@]}"; do
        current=$((current + 1))
        percent=$((current * 100 / total_files))
        
        echo "XXX"
        echo "$percent"
        echo "Обработка: $(basename "$video_file")..."
        echo "XXX"
        
        local filename=$(basename "$video_file")
        local mount_point=$(echo "${filename%.*}" | sed 's/[^a-zA-Z0-9._-]/_/g')
        local rtsp_url="rtsp://$RTSP_SERVER_IP:$RTSP_SERVER_PORT/$mount_point"
        
        # Получаем метаданные
        local metadata=$(get_video_metadata "$video_file")
        IFS='|' read -r resolution fps bitrate codec duration profile <<< "$metadata"
        
        # Определяем статус потока
        local status="Не запущен"
        local mode="Не указан"
        local pid_file="$PID_DIR/${mount_point}.pid"
        local mode_file="$PID_DIR/${mount_point}.mode"
        
        if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            status="Запущен"
            if [ -f "$mode_file" ]; then
                mode=$(cat "$mode_file")
                [ "$mode" = "loop" ] && mode="Зациклен" || mode="Однократно"
            fi
        fi
        
        # Добавляем строку
        info="${info}\"$video_file\",\"$resolution\",\"$fps\",\"$bitrate\",\"$codec\",\"$profile\",\"$duration\",\"$rtsp_url\",\"$status\",\"$mode\",\"$(date '+%Y-%m-%d %H:%M:%S')\"\n"
    done | whiptail --title "Сбор информации" --gauge "Анализ видеофайлов..." 8 60 0
    
    echo -e "$info"
}

# Создание отчета с выбором видео
generate_report() {
    local selected_videos=()
    
    # Получаем список видео для отчета
    local video_files=()
    while IFS= read -r file; do
        local filename=$(basename "$file")
        video_files+=("$file" "$filename" "OFF")
    done < <(find "$VIDEO_DIR" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" \) | sort)
    
    if [ ${#video_files[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Видеофайлы не найдены в папке:\n$VIDEO_DIR" 8 50
        return 1
    fi
    
    local choice=$(whiptail --title "Выбор видео для отчета" \
        --radiolist "Выберите вариант:" \
        15 60 3 \
        "all" "Все видео в папке" ON \
        "selected" "Выбрать конкретные видео" OFF \
        "running" "Только запущенные потоки" OFF \
        3>&1 1>&2 2>&3)
    
    case $choice in
        "all")
            # Все видео в папке
            local all_files=$(find "$VIDEO_DIR" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" \) | sort)
            for file in $all_files; do
                selected_videos+=("$file")
            done
            ;;
        "selected")
            # Выбор конкретных видео
            local selected=$(whiptail --title "Выберите видео" \
                --checklist "Выберите видео для отчета (ПРОБЕЛ - выбрать)" \
                20 70 10 "${video_files[@]}" \
                3>&1 1>&2 2>&3)
            if [ $? -eq 0 ] && [ -n "$selected" ]; then
                selected=$(echo "$selected" | tr -d '"')
                for file in $selected; do
                    selected_videos+=("$file")
                done
            else
                return 1
            fi
            ;;
        "running")
            # Только запущенные потоки
            for pid_file in "$PID_DIR"/*.pid; do
                if [ -f "$pid_file" ]; then
                    local mount_point=$(basename "$pid_file" .pid)
                    # Ищем файл по mount_point
                    local found_file=$(find "$VIDEO_DIR" -type f -name "*" | grep -i "${mount_point}\." | head -1)
                    if [ -n "$found_file" ]; then
                        selected_videos+=("$found_file")
                    fi
                fi
            done
            ;;
        *)
            return 1
            ;;
    esac
    
    if [ ${#selected_videos[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Не выбрано ни одного видео" 8 40
        return 1
    fi
    
    # Собираем информацию
    local info=""
    local total=${#selected_videos[@]}
    local current=0
    
    for video_file in "${selected_videos[@]}"; do
        current=$((current + 1))
        percent=$((current * 100 / total))
        
        echo "$percent"
        echo "XXX"
        echo "Обработка: $(basename "$video_file")..."
        echo "XXX"
        
        local filename=$(basename "$video_file")
        local mount_point=$(echo "${filename%.*}" | sed 's/[^a-zA-Z0-9._-]/_/g')
        local rtsp_url="rtsp://$RTSP_SERVER_IP:$RTSP_SERVER_PORT/$mount_point"
        
        # Получаем метаданные
        local metadata=$(get_video_metadata "$video_file")
        IFS='|' read -r resolution fps bitrate codec duration profile <<< "$metadata"
        
        # Определяем статус потока
        local status="Не запущен"
        local mode="Не указан"
        local pid_file="$PID_DIR/${mount_point}.pid"
        local mode_file="$PID_DIR/${mount_point}.mode"
        
        if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            status="Запущен"
            if [ -f "$mode_file" ]; then
                mode=$(cat "$mode_file")
                [ "$mode" = "loop" ] && mode="Зациклен" || mode="Однократно"
            fi
        fi
        
        info="${info}\"$video_file\",\"$resolution\",\"$fps\",\"$bitrate\",\"$codec\",\"$profile\",\"$duration\",\"$rtsp_url\",\"$status\",\"$mode\",\"$(date '+%Y-%m-%d %H:%M:%S')\"\n"
    done | whiptail --title "Сбор информации" --gauge "Анализ видеофайлов..." 8 60 0
    
    # Экспортируем в CSV
    local csv_file=$(export_to_csv "$info")
    
    whiptail --title "Отчет создан" \
        --msgbox "✅ Отчет успешно создан!\n\n📊 Файл: $csv_file\n📈 Всего записей: $total\n\nФайл сохранен в формате CSV для открытия в Excel/LibreOffice" \
        12 70
    
    # Спрашиваем, открыть ли файл
    if whiptail --title "Открыть отчет" --yesno "Открыть созданный CSV файл?" 8 40; then
        if command -v xdg-open &> /dev/null; then
            xdg-open "$csv_file"
        elif command -v open &> /dev/null; then
            open "$csv_file"
        else
            whiptail --title "Информация" --msgbox "Файл сохранен:\n$csv_file" 8 50
        fi
    fi
}

# Проверка и запуск MediaMTX
start_mediamtx() {
    if ! docker ps | grep -q "rtsp-mediamtx"; then
        show_progress "Запуск MediaMTX сервера..." 1
        
        # Останавливаем старый контейнер если есть
        docker stop rtsp-mediamtx 2>/dev/null
        docker rm rtsp-mediamtx 2>/dev/null
        
        # Создаем расширенный конфиг для MediaMTX с оптимизациями
        cat > "$CONFIG_DIR/mediamtx.yml" << EOF
# RTSP Configuration
rtspAddress: :$RTSP_SERVER_PORT
rtpAddress: :8002
rtcpAddress: :8003
readTimeout: 10s
writeTimeout: 10s

# Optimization for stable streaming
protocol: tcp
runOnDemand: false

# Path configuration
paths:
  all:
    source: publisher
    sourceProtocol: tcp
    publishUser: ""
    publishPass: ""
    
    # Video settings
    rtspTransport: tcp
    decoders:
      - h264
      - h265
    
    # Override for better compatibility
    fallback: ""
    
    # Disable authentication for simplicity
    publishUser: ""
    publishPass: ""
    readUser: ""
    readPass: ""
EOF
        
        # Запускаем MediaMTX
        docker run -d \
            --name rtsp-mediamtx \
            --restart unless-stopped \
            --network host \
            -v "$CONFIG_DIR/mediamtx.yml:/mediamtx.yml" \
            $MEDIAMTX_IMAGE > /dev/null 2>&1
        
        sleep 3
        echo "MediaMTX запущен"
    else
        echo "MediaMTX уже работает"
    fi
}

# Остановка MediaMTX
stop_mediamtx() {
    if docker ps | grep -q "rtsp-mediamtx"; then
        show_progress "Остановка MediaMTX сервера..." 1
        docker stop rtsp-mediamtx > /dev/null 2>&1
        docker rm rtsp-mediamtx > /dev/null 2>&1
        echo "MediaMTX остановлен"
    fi
}

# Запуск потока для одного видео с исправлением артефактов
start_stream() {
    local video_file="$1"
    local loop_mode="$2"
    local filename=$(basename "$video_file")
    local name_without_ext="${filename%.*}"
    local mount_point=$(echo "$name_without_ext" | sed 's/[^a-zA-Z0-9._-]/_/g')
    local pid_file="$PID_DIR/${mount_point}.pid"
    local mode_file="$PID_DIR/${mount_point}.mode"
    local log_file="$CONFIG_DIR/${mount_point}.log"
    
    # Проверяем, не запущен ли уже поток
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        return 1
    fi
    
    # Сохраняем режим воспроизведения
    echo "$loop_mode" > "$mode_file"
    
    # Формируем параметры цикла для ffmpeg
    local loop_param=""
    [ "$loop_mode" = "loop" ] && loop_param="-stream_loop -1"
    
    # RTSP URL
    local rtsp_url="rtsp://$RTSP_SERVER_IP:$RTSP_SERVER_PORT/$mount_point"
    
    # Определяем транспорт
    local transport_flag="-rtsp_transport tcp"
    
    # Оптимизированные параметры ffmpeg для устранения артефактов
    # Перекодируем видео в стабильный H.264 с фиксированным GOP и ключевыми кадрами
    nohup ffmpeg $loop_param -re \
        -i "$video_file" \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -crf 18 \
        -pix_fmt yuv420p \
        -g 25 \
        -keyint_min 25 \
        -sc_threshold 0 \
        -b:v 2000k \
        -maxrate 2000k \
        -bufsize 4000k \
        -an \
        -f rtsp \
        $transport_flag \
        "$rtsp_url" > "$log_file" 2>&1 &
    
    local ffmpeg_pid=$!
    echo "$ffmpeg_pid" > "$pid_file"
    echo "$(date): Запущен поток $mount_point (PID: $ffmpeg_pid, режим: $loop_mode) -> $rtsp_url" >> "$LOG_FILE"
    
    return 0
}

# Остановка потока
stop_stream() {
    local mount_point="$1"
    local pid_file="$PID_DIR/${mount_point}.pid"
    local mode_file="$PID_DIR/${mount_point}.mode"
    
    if [ -f "$pid_file" ]; then
        local id=$(cat "$pid_file")
        
        # Убиваем ffmpeg процесс и его детей
        pkill -P "$id" 2>/dev/null
        kill -9 "$id" 2>/dev/null
        
        rm "$pid_file"
        [ -f "$mode_file" ] && rm "$mode_file"
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
        local id=$(cat "$pid_file")
        
        if kill -0 "$id" 2>/dev/null; then
            echo "running"
            return 0
        else
            rm "$pid_file"
            rm -f "$PID_DIR/${mount_point}.mode"
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
    local streams=$(ls "$PID_DIR" 2>/dev/null | grep -v '.mode$' | sed 's/.pid$//')
    
    if [ -z "$streams" ]; then
        whiptail --title "Статус потоков" --msgbox "Нет активных потоков" 8 40
        return
    fi
    
    local status_text=""
    local running_count=0
    local stopped_count=0
    
    for stream in $streams; do
        local status=$(get_stream_status "$stream")
        local mode_file="$PID_DIR/${stream}.mode"
        local mode=$( [ -f "$mode_file" ] && cat "$mode_file" )
        local mode_text=""
        
        [ "$mode" = "loop" ] && mode_text="🔄 Зациклен" || mode_text="▶️ Однократно"
        
        local rtsp_url="rtsp://$RTSP_SERVER_IP:$RTSP_SERVER_PORT/$stream"
        if [ "$status" = "running" ]; then
            status_text="${status_text}\n✅ $stream: РАБОТАЕТ ($mode_text)\n   📺 $rtsp_url\n"
            ((running_count++))
        else
            status_text="${status_text}\n❌ $stream: ОСТАНОВЛЕН\n   📺 $rtsp_url\n"
            ((stopped_count++))
        fi
    done
    
    status_text="Всего: $((running_count + stopped_count)) | Работает: $running_count | Остановлено: $stopped_count\n$status_text"
    
    whiptail --title "Статус потоков" --msgbox "$status_text" 20 70
}

# Меню выбора видеофайлов с выбором режима
select_videos_with_mode() {
    local video_dir="$1"
    local files=()
    
    while IFS= read -r file; do
        local filename=$(basename "$file")
        local metadata=$(get_video_metadata "$file")
        IFS='|' read -r resolution fps bitrate codec duration profile <<< "$metadata"
        local display_name="$filename [$resolution, $fps fps, $codec, $duration]"
        files+=("$file" "$display_name" "OFF")
    done < <(find "$video_dir" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" \) | sort)
    
    if [ ${#files[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Видеофайлы не найдены в папке:\n$video_dir" 8 50
        return 1
    fi
    
    local selected=$(whiptail --title "Выбор видео для трансляции" \
        --checklist "Выберите видео для трансляции (ПРОБЕЛ - выбрать, ENTER - подтвердить)\nОтображается информация о каждом видео:" \
        25 90 12 "${files[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$selected" ]; then
        # Для каждого выбранного видео запрашиваем режим воспроизведения
        local selected_files=$(echo "$selected" | tr -d '"')
        local result=""
        
        for file in $selected_files; do
            local filename=$(basename "$file")
            local mode=$(whiptail --title "Режим воспроизведения: $filename" \
                --radiolist "Выберите режим воспроизведения:" \
                12 60 2 \
                "loop" "Бесконечный цикл (зациклить видео)" ON \
                "once" "Однократное воспроизведение" OFF \
                3>&1 1>&2 2>&3)
            
            if [ -n "$mode" ]; then
                result="${result}${file}:${mode}\n"
            else
                return 1
            fi
        done
        
        echo -e "$result"
        return 0
    fi
    return 1
}

# Запуск выбранных потоков с прогресс-баром
start_selected_streams() {
    local selected_data="$1"
    local started=0
    local failed=0
    local total=$(echo "$selected_data" | grep -c '^')
    local current=0
    
    # Сначала убеждаемся, что MediaMTX запущен
    if ! docker ps | grep -q "rtsp-mediamtx"; then
        start_mediamtx
        sleep 3
    fi
    
    while IFS=':' read -r file mode; do
        [ -z "$file" ] && continue
        
        current=$((current + 1))
        percent=$((current * 100 / total))
        
        echo "$percent"
        echo "XXX"
        echo "Запуск потока $current из $total: $(basename "$file") (режим: $mode)"
        echo "XXX"
        
        if start_stream "$file" "$mode"; then
            ((started++))
        else
            ((failed++))
        fi
        sleep 1
    done <<< "$selected_data" | whiptail --title "Запуск потоков" --gauge "Запуск трансляций..." 8 60 0
    
    whiptail --title "Результат" --msgbox "✅ Запущено потоков: $started\n❌ Ошибок: $failed" 8 40
}

# Остановка всех потоков с прогресс-баром
stop_all_streams() {
    if whiptail --title "Подтверждение" --yesno "Остановить все потоки?" 8 40; then
        local streams=$(ls "$PID_DIR" 2>/dev/null | grep -v '.mode$' | sed 's/.pid$//')
        local total=$(echo "$streams" | wc -w)
        local current=0
        local stopped=0
        
        if [ $total -eq 0 ]; then
            whiptail --title "Информация" --msgbox "Нет активных потоков" 8 40
            return
        fi
        
        for stream in $streams; do
            current=$((current + 1))
            percent=$((current * 100 / total))
            
            echo "$percent"
            echo "XXX"
            echo "Остановка потока $current из $total: $stream"
            echo "XXX"
            
            if stop_stream "$stream"; then
                ((stopped++))
            fi
        done | whiptail --title "Остановка потоков" --gauge "Остановка трансляций..." 8 60 0
        
        whiptail --title "Результат" --msgbox "Остановлено потоков: $stopped" 8 40
    fi
}

# Меню настроек (упрощенное)
settings_menu() {
    while true; do
        local settings_info="═══════════════════════════════════════\n"
        settings_info="${settings_info}  📡 IP адрес сервера:     $RTSP_SERVER_IP\n"
        settings_info="${settings_info}  🔌 Порт сервера:         $RTSP_SERVER_PORT\n"
        settings_info="${settings_info}  📁 Папка с видео:        $VIDEO_DIR\n"
        settings_info="${settings_info}  🌐 Транспорт RTSP:       $([ "$RTSP_TRANSPORT" = "tcp" ] && echo "TCP" || echo "UDP")\n"
        settings_info="${settings_info}  🐳 Образ MediaMTX:       $MEDIAMTX_IMAGE\n"
        settings_info="${settings_info}  📊 Использовать pv:      $([ "$USE_PV" = "true" ] && echo "ДА" || echo "НЕТ")\n"
        settings_info="${settings_info}  🎬 Кодек видео:          $VIDEO_CODEC\n"
        settings_info="${settings_info}  ⚡ Preset кодирования:   $PRESET\n"
        settings_info="${settings_info}  🎨 Качество (CRF):       $CRF\n"
        settings_info="${settings_info}═══════════════════════════════════════"
        
        local choice=$(whiptail --title "⚙️  НАСТРОЙКИ" \
            --menu "$settings_info\n\nВыберите параметр для изменения:" \
            28 75 11 \
            "1" "📡 IP адрес RTSP сервера" \
            "2" "🔌 Порт RTSP сервера" \
            "3" "📁 Папка с видеофайлами" \
            "4" "🌐 Транспорт RTSP (TCP/UDP)" \
            "5" "🐳 Образ MediaMTX в Docker" \
            "6" "📊 Использовать pv для прогресс-баров" \
            "7" "🎬 Кодек видео (libx264/libx265)" \
            "8" "⚡ Preset кодирования" \
            "9" "🎨 Качество видео (CRF 0-51)" \
            "10" "💾 Сохранить и вернуться" \
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
                local new_transport=$(whiptail --radiolist "Протокол транспорта RTSP:" 12 50 2 \
                    "tcp" "TCP (надежнее, рекомендуется)" $( [ "$RTSP_TRANSPORT" = "tcp" ] && echo ON || echo OFF ) \
                    "udp" "UDP (быстрее, менее надежен)" $( [ "$RTSP_TRANSPORT" = "udp" ] && echo ON || echo OFF ) \
                    3>&1 1>&2 2>&3)
                [ -n "$new_transport" ] && RTSP_TRANSPORT="$new_transport"
                ;;
            5)
                local new_image=$(whiptail --inputbox "Введите имя Docker образа MediaMTX:" 8 70 "$MEDIAMTX_IMAGE" 3>&1 1>&2 2>&3)
                [ -n "$new_image" ] && MEDIAMTX_IMAGE="$new_image"
                ;;
            6)
                local new_pv=$(whiptail --radiolist "Использовать pv для прогресс-баров:" 10 50 2 \
                    "true" "Да (красивые прогресс-бары)" $( [ "$USE_PV" = "true" ] && echo ON || echo OFF ) \
                    "false" "Нет (простой текст)" $( [ "$USE_PV" = "false" ] && echo ON || echo OFF ) \
                    3>&1 1>&2 2>&3)
                [ -n "$new_pv" ] && USE_PV="$new_pv"
                ;;
            7)
                local new_codec=$(whiptail --radiolist "Видео кодек:" 12 50 2 \
                    "libx264" "H.264 (лучшая совместимость)" ON \
                    "libx265" "H.265 (лучшее сжатие)" OFF \
                    3>&1 1>&2 2>&3)
                [ -n "$new_codec" ] && VIDEO_CODEC="$new_codec"
                ;;
            8)
                local new_preset=$(whiptail --radiolist "Preset кодирования (скорость/качество):" 15 60 4 \
                    "ultrafast" "Очень быстро, низкое качество" OFF \
                    "superfast" "Супер быстро" OFF \
                    "veryfast" "Очень быстро" OFF \
                    "faster" "Быстрее" OFF \
                    "fast" "Быстро" ON \
                    "medium" "Среднее (баланс)" OFF \
                    3>&1 1>&2 2>&3)
                [ -n "$new_preset" ] && PRESET="$new_preset"
                ;;
            9)
                local new_crf=$(whiptail --inputbox "Качество видео (CRF 0-51, меньше = лучше):\n0 - без потерь, 18-28 - хорошее качество, 51 - худшее" 10 60 "$CRF" 3>&1 1>&2 2>&3)
                if [ -n "$new_crf" ] && [ "$new_crf" -ge 0 ] && [ "$new_crf" -le 51 ] 2>/dev/null; then
                    CRF="$new_crf"
                elif [ -n "$new_crf" ]; then
                    whiptail --title "Ошибка" --msgbox "Неверное значение CRF. Должно быть от 0 до 51" 8 40
                fi
                ;;
            10)
                save_config
                break
                ;;
            *)
                break
                ;;
        esac
        
        save_config
    done
}

# Главное меню (упрощенное)
main_menu() {
    while true; do
        local choice=$(whiptail --title "🎬 RTSP STREAM MANAGER v3.0" \
            --menu "Управление RTSP трансляциями видео\n═══════════════════════════════════════" \
            20 70 9 \
            "1" "🚀 Запустить MediaMTX сервер" \
            "2" "🛑 Остановить MediaMTX сервер" \
            "3" "🎥 Выбрать видео и запустить трансляцию" \
            "4" "📁 Выбрать ВСЕ видео и запустить" \
            "5" "⏹️  Остановить все потоки" \
            "6" "📊 Показать статус потоков" \
            "7" "📈 Создать отчет CSV с метаданными" \
            "8" "⚙️  Настройки" \
            "9" "🚪 Выход" \
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
                local selected=$(select_videos_with_mode "$VIDEO_DIR")
                if [ $? -eq 0 ] && [ -n "$selected" ]; then
                    start_selected_streams "$selected"
                fi
                ;;
            4)
                # Для всех видео используем режим loop по умолчанию
                local all_files=$(find "$VIDEO_DIR" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" \) | sort)
                
                if [ -n "$all_files" ]; then
                    local count=$(echo "$all_files" | wc -l)
                    local mode=$(whiptail --title "Режим воспроизведения" \
                        --radiolist "Выберите режим для всех видео:" \
                        12 60 2 \
                        "loop" "Бесконечный цикл (зациклить видео)" ON \
                        "once" "Однократное воспроизведение" OFF \
                        3>&1 1>&2 2>&3)
                    
                    if [ -n "$mode" ] && whiptail --title "Подтверждение" --yesno "Запустить трансляцию ВСЕХ видео ($count файлов) из папки:\n$VIDEO_DIR\nРежим: $([ "$mode" = "loop" ] && echo "Бесконечный цикл" || echo "Однократно")" 12 60; then
                        local selected_data=""
                        for file in $all_files; do
                            selected_data="${selected_data}${file}:${mode}\n"
                        done
                        start_selected_streams "$selected_data"
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
                generate_report
                ;;
            8)
                settings_menu
                ;;
            9)
                if whiptail --title "Выход" --yesno "Вы уверены, что хотите выйти?\n\nПотоки продолжат работать в фоне." 10 50; then
                    exit 0
                fi
                ;;
        esac
    done
}

# Проверка зависимостей
check_dependencies() {
    local deps=("docker" "whiptail" "ffmpeg" "ffprobe")
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
        echo "  - ffmpeg и ffprobe (пакет ffmpeg)"
        echo ""
        echo "Для установки на Ubuntu/Debian:"
        echo "  sudo apt install docker.io whiptail ffmpeg"
        echo ""
        echo "Для установки на CentOS/RHEL:"
        echo "  sudo yum install docker newt ffmpeg"
        exit 1
    fi
}

# Показать баннер
show_banner() {
    clear
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   🎬 RTSP Stream Manager v3.0 - Управление RTSP трансляциями${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}   📁 Конфигурация: $CONFIG_DIR${NC}"
    echo -e "${YELLOW}   📝 Лог-файл: $LOG_FILE${NC}"
    echo -e "${YELLOW}   📊 Отчеты: $REPORT_DIR${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Основная функция
main() {
    show_banner
    check_dependencies
    init_config
    load_config
    
    # Проверка Docker
    if ! docker info &> /dev/null; then
        echo "❌ Docker не запущен. Пожалуйста, запустите Docker сначала."
        echo "  sudo systemctl start docker"
        exit 1
    fi
    
    # Проверка директории с видео
    if [ ! -d "$VIDEO_DIR" ]; then
        mkdir -p "$VIDEO_DIR"
        echo "✅ Создана папка для видео: $VIDEO_DIR"
        sleep 2
    fi
    
    # Проверка pv
    if [ "$USE_PV" = "true" ] && ! command -v pv &> /dev/null; then
        echo "⚠️  pv не установлен. Устанавливаю pv для прогресс-баров..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get install -y pv
        elif command -v yum &> /dev/null; then
            sudo yum install -y pv
        else
            echo "❌ Не удалось установить pv. Отключаю использование pv."
            USE_PV="false"
            save_config
        fi
        sleep 2
    fi
    
    main_menu
}

# Запуск
main "$@"
