#!/bin/bash

# RTSP Stream Manager - TUI для управления трансляцией видео в RTSP
# Версия: 2.0
# Добавлен экспорт в CSV с метаданными видео

# Конфигурация
CONFIG_DIR="$HOME/.rtsp-srv"
CONFIG_FILE="$CONFIG_DIR/config.conf"
STREAMS_FILE="$CONFIG_DIR/streams.conf"
LOG_FILE="$CONFIG_DIR/streams.log"
PID_DIR="$CONFIG_DIR/pids"
REPORT_DIR="$CONFIG_DIR/reports"
CSV_EXPORT="$REPORT_DIR/streams_report_$(date +%Y%m%d_%H%M%S).csv"

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
STREAM_LOOP="true"
RTSP_TRANSPORT="tcp"
USE_PV="true"
USE_LOCAL_FFMPEG="true"
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
USE_PV="$USE_PV"
USE_LOCAL_FFMPEG="$USE_LOCAL_FFMPEG"
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

# Получение метаданных видео через локальный ffmpeg
get_video_metadata() {
    local video_file="$1"
    
    if [ "$USE_LOCAL_FFMPEG" = "true" ] && command -v ffprobe &> /dev/null; then
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
        
        echo "$resolution|$fps|$bitrate|$codec|$duration"
    else
        echo "N/A|N/A|N/A|N/A|N/A"
    fi
}

# Экспорт отчета в CSV
export_to_csv() {
    local streams_data="$1"
    local csv_file="$CSV_EXPORT"
    
    # Создаем заголовки CSV
    echo "Видеофайл,Разрешение,FPS,Битрейт,Кодек,Длительность,RTSP-ссылка,Статус,Дата_запуска" > "$csv_file"
    
    # Добавляем данные
    echo "$streams_data" >> "$csv_file"
    
    # Показываем прогресс сохранения
    if check_pv; then
        cat "$csv_file" | pv -l -s $(wc -l < "$csv_file") > /dev/null
    fi
    
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
    done < <(find "$video_dir" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" \) | sort)
    
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
        IFS='|' read -r resolution fps bitrate codec duration <<< "$metadata"
        
        # Определяем статус потока
        local status="Не запущен"
        local pid_file="$PID_DIR/${mount_point}.pid"
        if [ -f "$pid_file" ] && docker ps | grep -q "$(cat "$pid_file")" 2>/dev/null; then
            status="Запущен"
        fi
        
        # Добавляем строку
        info="${info}\"$video_file\",\"$resolution\",\"$fps\",\"$bitrate\",\"$codec\",\"$duration\",\"$rtsp_url\",\"$status\",\"$(date '+%Y-%m-%d %H:%M:%S')\"\n"
    done | whiptail --title "Сбор информации" --gauge "Анализ видеофайлов..." 8 60 0
    
    echo -e "$info"
}

# Создание отчета с выбором видео
generate_report() {
    local temp_file=$(mktemp)
    local selected_videos=()
    
    # Получаем список видео для отчета
    local video_files=()
    while IFS= read -r file; do
        local filename=$(basename "$file")
        video_files+=("$file" "$filename" "OFF")
    done < <(find "$VIDEO_DIR" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" \) | sort)
    
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
            local all_files=$(find "$VIDEO_DIR" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" \) | sort)
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
                    local found_file=$(find "$VIDEO_DIR" -type f -name "*" | grep -i "$mount_point" | head -1)
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
        IFS='|' read -r resolution fps bitrate codec duration <<< "$metadata"
        
        # Определяем статус потока
        local status="Не запущен"
        local pid_file="$PID_DIR/${mount_point}.pid"
        if [ -f "$pid_file" ] && docker ps | grep -q "$(cat "$pid_file")" 2>/dev/null; then
            status="Запущен"
        fi
        
        info="${info}\"$video_file\",\"$resolution\",\"$fps\",\"$bitrate\",\"$codec\",\"$duration\",\"$rtsp_url\",\"$status\",\"$(date '+%Y-%m-%d %H:%M:%S')\"\n"
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
        
        # Создаем конфиг для MediaMTX
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
        
        # Запускаем MediaMTX
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
        show_progress "Остановка MediaMTX сервера..." 1
        docker stop rtsp-mediamtx > /dev/null 2>&1
        docker rm rtsp-mediamtx > /dev/null 2>&1
        echo "MediaMTX остановлен"
    fi
}

# Запуск потока для одного видео (используя локальный ffmpeg)
start_stream() {
    local video_file="$1"
    local filename=$(basename "$video_file")
    local name_without_ext="${filename%.*}"
    local mount_point=$(echo "$name_without_ext" | sed 's/[^a-zA-Z0-9._-]/_/g')
    local pid_file="$PID_DIR/${mount_point}.pid"
    
    # Проверяем, не запущен ли уже поток
    if [ -f "$pid_file" ] && docker ps | grep -q "$(cat "$pid_file")" 2>/dev/null; then
        return 1
    fi
    
    # Формируем команду ffmpeg
    local loop_flag=""
    [ "$STREAM_LOOP" = "true" ] && loop_flag="-stream_loop -1"
    
    local rtsp_url="rtsp://$RTSP_SERVER_IP:$RTSP_SERVER_PORT/$mount_point"
    local transport_flag=""
    [ "$RTSP_TRANSPORT" = "tcp" ] && transport_flag="-rtsp_transport tcp"
    
    if [ "$USE_LOCAL_FFMPEG" = "true" ] && command -v ffmpeg &> /dev/null; then
        # Используем локальный ffmpeg
        nohup ffmpeg $loop_flag -re \
            -i "$video_file" \
            -c copy \
            $transport_flag \
            -f rtsp "$rtsp_url" > "$CONFIG_DIR/${mount_point}.log" 2>&1 &
        
        local ffmpeg_pid=$!
        echo "$ffmpeg_pid" > "$pid_file"
        echo "$(date): Запущен поток $mount_point (PID: $ffmpeg_pid) -> $rtsp_url" >> "$LOG_FILE"
    else
        # Используем Docker как fallback
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
            echo "$(date): Запущен поток $mount_point (Container: $container_id) -> $rtsp_url" >> "$LOG_FILE"
        fi
    fi
    
    return 0
}

# Остановка потока
stop_stream() {
    local mount_point="$1"
    local pid_file="$PID_DIR/${mount_point}.pid"
    
    if [ -f "$pid_file" ]; then
        local id=$(cat "$pid_file")
        
        if [ "$USE_LOCAL_FFMPEG" = "true" ] && [[ "$id" =~ ^[0-9]+$ ]]; then
            # Убиваем локальный ffmpeg процесс
            kill -9 "$id" 2>/dev/null
        else
            # Останавливаем Docker контейнер
            docker stop "$id" > /dev/null 2>&1
            docker rm "$id" > /dev/null 2>&1
        fi
        
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
        local id=$(cat "$pid_file")
        
        if [ "$USE_LOCAL_FFMPEG" = "true" ] && [[ "$id" =~ ^[0-9]+$ ]]; then
            if kill -0 "$id" 2>/dev/null; then
                echo "running"
                return 0
            fi
        else
            if docker ps | grep -q "$id"; then
                echo "running"
                return 0
            fi
        fi
        
        rm "$pid_file"
        echo "stopped"
        return 1
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
        local metadata=$(get_video_metadata "$file")
        IFS='|' read -r resolution fps bitrate codec duration <<< "$metadata"
        local display_name="$filename [$resolution, $fps fps, $duration]"
        files+=("$file" "$display_name" "OFF")
    done < <(find "$video_dir" -maxdepth 1 -type f \( -iname "*.avi" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.flv" -o -iname "*.wmv" \) | sort)
    
    if [ ${#files[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Видеофайлы не найдены в папке:\n$video_dir" 8 50
        return 1
    fi
    
    local selected=$(whiptail --title "Выбор видео для трансляции" \
        --checklist "Выберите видео для трансляции (ПРОБЕЛ - выбрать, ENTER - подтвердить)\nОтображается информация о каждом видео:" \
        25 90 12 "${files[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$selected" ]; then
        echo "$selected" | tr -d '"'
        return 0
    fi
    return 1
}

# Запуск выбранных потоков с прогресс-баром
start_selected_streams() {
    local selected_files="$1"
    local started=0
    local failed=0
    local total=$(echo "$selected_files" | wc -w)
    local current=0
    
    # Сначала убеждаемся, что MediaMTX запущен
    if ! docker ps | grep -q "rtsp-mediamtx"; then
        start_mediamtx
        sleep 2
    fi
    
    for file in $selected_files; do
        current=$((current + 1))
        percent=$((current * 100 / total))
        
        echo "$percent"
        echo "XXX"
        echo "Запуск потока $current из $total: $(basename "$file")"
        echo "XXX"
        
        if start_stream "$file"; then
            ((started++))
        else
            ((failed++))
        fi
        sleep 1
    done | whiptail --title "Запуск потоков" --gauge "Запуск трансляций..." 8 60 0
    
    whiptail --title "Результат" --msgbox "✅ Запущено потоков: $started\n❌ Ошибок: $failed" 8 40
}

# Остановка всех потоков с прогресс-баром
stop_all_streams() {
    if whiptail --title "Подтверждение" --yesno "Остановить все потоки?" 8 40; then
        local streams=$(ls "$PID_DIR" 2>/dev/null | sed 's/.pid$//')
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
        settings_info="${settings_info}  📊 Использовать pv:      $([ "$USE_PV" = "true" ] && echo "ДА" || echo "НЕТ")\n"
        settings_info="${settings_info}  🎬 Локальный ffmpeg:     $([ "$USE_LOCAL_FFMPEG" = "true" ] && echo "ДА" || echo "НЕТ")\n"
        settings_info="${settings_info}═══════════════════════════════════════"
        
        local choice=$(whiptail --title "⚙️  НАСТРОЙКИ" \
            --menu "$settings_info\n\nВыберите параметр для изменения:" \
            25 75 10 \
            "1" "📡 IP адрес RTSP сервера" \
            "2" "🔌 Порт RTSP сервера" \
            "3" "📁 Папка с видеофайлами" \
            "4" "🔄 Бесконечный цикл (ДА/НЕТ)" \
            "5" "🌐 Транспорт RTSP (TCP/UDP)" \
            "6" "🐳 Образ MediaMTX в Docker" \
            "7" "📊 Использовать pv для прогресс-баров" \
            "8" "🎬 Использовать локальный ffmpeg" \
            "9" "💾 Сохранить и вернуться" \
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
                local new_pv=$(whiptail --radiolist "Использовать pv для прогресс-баров:" 10 50 2 \
                    "true" "Да (красивые прогресс-бары)" $( [ "$USE_PV" = "true" ] && echo ON || echo OFF ) \
                    "false" "Нет (простой текст)" $( [ "$USE_PV" = "false" ] && echo ON || echo OFF ) \
                    3>&1 1>&2 2>&3)
                [ -n "$new_pv" ] && USE_PV="$new_pv"
                ;;
            8)
                local new_local=$(whiptail --radiolist "Использовать локальный ffmpeg:" 12 60 2 \
                    "true" "Да (быстрее, меньше нагрузки)" $( [ "$USE_LOCAL_FFMPEG" = "true" ] && echo ON || echo OFF ) \
                    "false" "Нет (использовать Docker)" $( [ "$USE_LOCAL_FFMPEG" = "false" ] && echo ON || echo OFF ) \
                    3>&1 1>&2 2>&3)
                [ -n "$new_local" ] && USE_LOCAL_FFMPEG="$new_local"
                ;;
            9)
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

# Главное меню
main_menu() {
    while true; do
        local choice=$(whiptail --title "🎬 RTSP STREAM MANAGER v2.0" \
            --menu "Управление RTSP трансляциями видео\n═══════════════════════════════════════" \
            22 70 11 \
            "1" "🚀 Запустить MediaMTX сервер" \
            "2" "🛑 Остановить MediaMTX сервер" \
            "3" "🎥 Выбрать видео и запустить трансляцию" \
            "4" "📁 Выбрать ВСЕ видео и запустить" \
            "5" "⏹️  Остановить все потоки" \
            "6" "📊 Показать статус потоков" \
            "7" "📈 Создать отчет CSV с метаданными" \
            "8" "⚙️  Настройки" \
            "9" "📋 Показать логи" \
            "10" "🧹 Очистить неактивные потоки" \
            "11" "🚪 Выход" \
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
                generate_report
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
                # Очистка неактивных потоков
                local cleaned=0
                for pid_file in "$PID_DIR"/*.pid; do
                    if [ -f "$pid_file" ]; then
                        local mount_point=$(basename "$pid_file" .pid)
                        local status=$(get_stream_status "$mount_point")
                        if [ "$status" != "running" ]; then
                            rm "$pid_file"
                            ((cleaned++))
                        fi
                    fi
                done
                whiptail --title "Очистка" --msgbox "Очищено неактивных записей: $cleaned" 8 40
                ;;
            11)
                if whiptail --title "Выход" --yesno "Вы уверены, что хотите выйти?\n\nПотоки продолжат работать в фоне." 10 50; then
                    exit 0
                fi
                ;;
        esac
    done
}

# Проверка зависимостей
check_dependencies() {
    local deps=("docker" "whiptail")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    # Проверяем ffmpeg/ffprobe если включен локальный режим
    if [ "$USE_LOCAL_FFMPEG" = "true" ]; then
        if ! command -v ffmpeg &> /dev/null; then
            echo "⚠️  ВНИМАНИЕ: ffmpeg не найден в системе"
            echo "Будет использован Docker контейнер с ffmpeg"
            USE_LOCAL_FFMPEG="false"
            save_config
            sleep 2
        fi
        if ! command -v ffprobe &> /dev/null; then
            echo "⚠️  ВНИМАНИЕ: ffprobe не найден в системе"
            echo "Метаданные видео будут недоступны"
        fi
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "❌ Отсутствуют зависимости: ${missing[*]}"
        echo "Пожалуйста, установите:"
        echo "  - docker"
        echo "  - whiptail (пакет whiptail или newt)"
        echo ""
        echo "Для установки на Ubuntu/Debian:"
        echo "  sudo apt install docker.io whiptail"
        echo ""
        echo "Для установки на CentOS/RHEL:"
        echo "  sudo yum install docker newt"
        exit 1
    fi
}

# Показать баннер
show_banner() {
    clear
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   🎬 RTSP Stream Manager v2.0 - Управление RTSP трансляциями${NC}"
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
