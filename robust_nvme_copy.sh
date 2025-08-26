#!/bin/bash

# Robustes Windows NVMe Image Creator mit Kühlung und Fehlerbehandlung
# Optimiert für externe NVMe-Gehäuse mit Überhitzungsschutz

set -euo pipefail

# Konfiguration
SOURCE_DEVICE="/dev/nvme1n1"  # KORRIGIERT: Gesamtes NVMe-Laufwerk kopieren, um Boot-Informationen zu erhalten# TARGET_FILE wird dynamisch basierend auf externer SSD gesetzt
EXTERNAL_SSD_PATH=""
VM_COLLECTION_NAME="qemu-vms"
TARGET_FILE=""
TEMP_TARGET=""
PROGRESS_FILE=""
ERROR_LOG=""

# Fan Control Variablen
FAN_BACKUP_FILE="/tmp/fan_backup_$$"
FAN_CONTROL_ACTIVE=false
ORIGINAL_GOVERNOR=""

# Block-Einstellungen
BLOCK_SIZE="1M"           # dd Block-Größe
BLOCKS_PER_CHUNK=256     # 256MB Chunks (256 * 1MB)
COOLING_PAUSE=11         # Sekunden Pause zwischen Chunks
MAX_RETRIES=3            # Maximale Wiederholungsversuche
RETRY_PAUSE=30           # Pause vor Wiederholung (Sekunden)

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Signalbehandlung für sauberen Abbruch
cleanup() {
    echo -e "\n${YELLOW}Script unterbrochen. Fortschritt gespeichert in: $PROGRESS_FILE${NC}"
    
    # Fan-Control wiederherstellen falls aktiv
    if [[ $FAN_CONTROL_ACTIVE == true ]]; then
        log_warn "Stelle Lüftersteuerung wieder her..."
        restore_laptop_fans
    fi
    
    exit 1
}
trap cleanup SIGINT SIGTERM

# Hilfsfunktionen
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "$(date): $1" >> "$ERROR_LOG"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# ===== LAPTOP FAN CONTROL FUNCTIONS =====

# Laptop-Lüfter auf aggressive Kühlung setzen
activate_laptop_cooling() {
    log_info "🌀 Aktiviere aggressive Laptop-Kühlung für NVMe-Intensive Operation..."
    
    # Backup erstellen falls noch nicht vorhanden
    [[ -f "$FAN_BACKUP_FILE" ]] && rm -f "$FAN_BACKUP_FILE"
    
    # 1. CPU-Gouverneur sichern und auf Performance setzen
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        ORIGINAL_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")
        
        if [[ -n "$ORIGINAL_GOVERNOR" ]]; then
            log_info "CPU-Gouverneur: $ORIGINAL_GOVERNOR → performance"
            echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
        fi
    fi
    
    # 2. Alle PWM-Lüfter auf Maximum
    local fans_controlled=0
    for hwmon in /sys/class/hwmon/hwmon*; do
        if [[ -d "$hwmon" ]]; then
            local hwmon_name=$(cat "$hwmon/name" 2>/dev/null || echo "unknown")
            
            # PWM-Enable Dateien sichern und auf manuell setzen
            for enable_file in "$hwmon"/pwm*_enable; do
                if [[ -w "$enable_file" ]]; then
                    local current_enable=$(cat "$enable_file" 2>/dev/null || echo "0")
                    echo "$enable_file:$current_enable" >> "$FAN_BACKUP_FILE"
                    echo 1 | tee "$enable_file" >/dev/null 2>&1 || true  # 1=manual
                fi
            done
            
            # PWM-Werte sichern und auf Maximum setzen
            for pwm_file in "$hwmon"/pwm*; do
                if [[ -w "$pwm_file" && ! "$pwm_file" =~ _enable$ ]]; then
                    local current_pwm=$(cat "$pwm_file" 2>/dev/null || echo "0")
                    echo "$pwm_file:$current_pwm" >> "$FAN_BACKUP_FILE"
                    echo 255 | tee "$pwm_file" >/dev/null 2>&1 || true  # Maximum
                    log_info "Lüfter $(basename $pwm_file): $current_pwm → 255 (Maximum)"
                    ((fans_controlled++))
                fi
            done
        fi
    done
    
    # 3. CPU-Frequenz begrenzen um Wärmeentwicklung zu reduzieren
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
        local cpu_max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "")
        if [[ -n "$cpu_max" && "$cpu_max" -gt 1000000 ]]; then
            local reduced_max=$((cpu_max * 80 / 100))  # 80% für weniger Hitze
            echo "cpu_max_freq:$cpu_max" >> "$FAN_BACKUP_FILE"
            echo "$reduced_max" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq >/dev/null 2>&1 || true
            log_info "CPU-Max-Freq: $(($cpu_max/1000))MHz → $(($reduced_max/1000))MHz (weniger Hitze)"
        fi
    fi
    
    # 4. TLP auf AC-Performance wenn verfügbar
    if command -v tlp &>/dev/null; then
        tlp ac 2>/dev/null || true
        log_info "TLP auf AC-Performance-Modus gesetzt"
    fi
    
    FAN_CONTROL_ACTIVE=true
    
    if [[ $fans_controlled -gt 0 ]]; then
        log_success "🌪️  Aggressive Kühlung aktiviert! ($fans_controlled Lüfter auf Maximum)"
    else
        log_warn "Keine Hardware-Lüftersteuerung gefunden - nur CPU/TLP optimiert"
    fi
}

# Original-Lüftereinstellungen wiederherstellen
restore_laptop_fans() {
    if [[ ! -f "$FAN_BACKUP_FILE" ]]; then
        return 0
    fi
    
    log_info "♻️  Stelle ursprüngliche Laptop-Kühlung wieder her..."
    
    # Gesicherte Werte wiederherstellen
    while IFS=: read -r file_path original_value; do
        if [[ -w "$file_path" && -n "$original_value" ]]; then
            echo "$original_value" | tee "$file_path" >/dev/null 2>&1 || true
            log_info "$(basename "$file_path"): $original_value wiederhergestellt"
        fi
    done < "$FAN_BACKUP_FILE"
    
    # CPU-Gouverneur wiederherstellen
    if [[ -n "$ORIGINAL_GOVERNOR" ]]; then
        echo "$ORIGINAL_GOVERNOR" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
        log_info "CPU-Gouverneur: $ORIGINAL_GOVERNOR wiederhergestellt"
    fi
    
    # TLP wieder normal
    if command -v tlp &>/dev/null; then
        tlp start 2>/dev/null || true
    fi
    
    rm -f "$FAN_BACKUP_FILE"
    FAN_CONTROL_ACTIVE=false
    log_success "✅ Ursprüngliche Kühlung wiederhergestellt"
}

# ===== EXTERNE SSD MANAGEMENT =====

# Externe SSD automatisch erkennen
detect_qemu_ssd() {
    log_info "🔍 Suche nach QEMU-VM SSD..."
    
    # Mounted Devices mit VM-extern-SSD Label suchen
    local qemu_mount=$(mount | grep "VM-extern-SSD\|vm-extern-ssd" | awk '{print $3}' | head -1)
    if [[ -n "$qemu_mount" ]]; then
        EXTERNAL_SSD_PATH="$qemu_mount"
        log_success "VM-extern-SSD gefunden: $qemu_mount"
        return 0
    fi
    
    # md126p1 direkt suchen (falls über UUID gemountet)
    local md_mount=$(mount | grep "md126p1" | awk '{print $3}' | head -1)
    if [[ -n "$md_mount" ]]; then
        EXTERNAL_SSD_PATH="$md_mount"
        log_success "Software-RAID SSD gefunden: $md_mount"
        return 0
    fi
    
    # UUID-basierte Suche
    local uuid_mount=$(mount | grep "dde1defd-0723-404b-bba3-dbc6e43cd375" | awk '{print $3}' | head -1)
    if [[ -n "$uuid_mount" ]]; then
        EXTERNAL_SSD_PATH="$uuid_mount"
        log_success "SSD über UUID gefunden: $uuid_mount"
        return 0
    fi
    
    # Prüfe Standard-Mount-Pfade
    for possible_mount in "/media/vm-extern-ssd" "/media/$USER/VM-extern-SSD" "/mnt/vm-ssd"; do
        if mountpoint -q "$possible_mount" 2>/dev/null; then
            EXTERNAL_SSD_PATH="$possible_mount"
            log_success "SSD am Standard-Pfad gefunden: $possible_mount"
            return 0
        fi
    done
    
    log_warn "Externe VM-SSD nicht automatisch gefunden"
    return 1
}

# Externe SSDs/Festplatten erkennen (Fallback falls keine formatierte SSD)
detect_external_storage() {
    log_info "🔍 Suche nach externen Speichergeräten..."
    
    local external_devices=()
    local device_info=()
    
    # Alle Block-Geräte durchsuchen (außer Loop, RAM, etc.)
    for device in /sys/block/*; do
        local dev_name=$(basename "$device")
        
        # Skip interne/virtuelle Geräte
        [[ "$dev_name" =~ ^(loop|ram|dm-|sr) ]] && continue
        
        # Prüfe ob es sich um ein externes USB/Removable Gerät handelt
        local removable=$(cat "$device/removable" 2>/dev/null || echo "0")
        local dev_path="/dev/$dev_name"
        
        # Zusätzliche Heuristik für USB-Geräte
        local is_usb=false
        if [[ -L "$device" ]]; then
            local real_path=$(readlink -f "$device")
            [[ "$real_path" =~ usb ]] && is_usb=true
        fi
        
        # Ist es ein abnehmbares Gerät oder USB?
        if [[ "$removable" == "1" ]] || [[ "$is_usb" == true ]]; then
            # Größe ermitteln
            local size_sectors=$(cat "$device/size" 2>/dev/null || echo "0")
            local size_gb=$(( size_sectors * 512 / 1024 / 1024 / 1024 ))
            
            # Nur Geräte > 50GB (für VM-Images sinnvoll)
            if [[ $size_gb -gt 50 ]]; then
                # Model-Name versuchen
                local model=$(cat "$device/device/model" 2>/dev/null | tr -s ' ' || echo "Unbekannt")
                local vendor=$(cat "$device/device/vendor" 2>/dev/null | tr -s ' ' || echo "")
                
                external_devices+=("$dev_path")
                device_info+=("$dev_path|${size_gb}GB|${vendor} ${model}|$removable")
                
                log_info "Gefunden: $dev_path (${size_gb}GB) - ${vendor} ${model}"
            fi
        fi
    done
    
    # Mounted externe Geräte anzeigen
    log_info "📂 Bereits gemountete externe Geräte:"
    df -h | grep -E "(media|mnt|usb)" | while read line; do
        echo "   $line"
    done
    
    echo "${#external_devices[@]}"
    printf '%s\n' "${device_info[@]}"
}

# Externe SSD auswählen und mounten
select_external_ssd() {
    echo -e "${BLUE}=== Externe SSD für VM-Images Setup ===${NC}"
    
    # Zuerst: Bereits formatierte QEMU-SSD suchen
    if detect_qemu_ssd; then
        log_success "✅ Formatierte QEMU-SSD automatisch erkannt!"
        log_info "📁 Pfad: $EXTERNAL_SSD_PATH"
        
        # Speicherplatz prüfen
        local free_space_gb=$(df --output=avail -BG "$EXTERNAL_SSD_PATH" | tail -n1 | sed 's/G//')
        log_info "💾 Verfügbarer Platz: ${free_space_gb}GB"
        
        if [[ $free_space_gb -gt 100 ]]; then
            log_success "Genügend Platz für VM-Images verfügbar"
            return 0
        else
            log_warn "Wenig Speicher verfügbar - Kompression wird empfohlen"
            return 0
        fi
    fi
    
    # Fallback: Normale externe Geräte suchen
    log_warn "Keine formatierte QEMU-SSD gefunden"
    echo -e "${YELLOW}💡 Tipp: Führe zuerst das SSD-Setup-Script aus:${NC}"
    echo "   sudo ./ssd_setup_script.sh"
    echo ""
    
    # Externe Geräte erkennen
    local device_info
    mapfile -t device_info < <(detect_external_storage)
    local device_count=${device_info[0]}
    unset device_info[0]  # Remove count from array
    
    if [[ $device_count -eq 0 ]]; then
        log_warn "Keine geeigneten externen Speichergeräte gefunden!"
        echo ""
        echo "Optionen:"
        echo "1. SSD mit dem SSD-Setup-Script formatieren"
        echo "2. Manuell einen vorhandenen Mount-Pfad angeben"
        echo "3. Auf internem Speicher verwenden (falls Platz frei wird)"
        echo ""
        read -p "Wähle Option [1-3]: " fallback_choice
        
        case $fallback_choice in
            1)
                log_info "Starte SSD-Setup-Script..."
                if [[ -f "./ssd_setup_script.sh" ]]; then
                    exec sudo ./ssd_setup_script.sh
                else
                    log_error "SSD-Setup-Script nicht gefunden!"
                    return 1
                fi
                ;;
            2)
                read -p "Gib den Mount-Pfad ein (z.B. /media/user/SSD): " manual_path
                if [[ -d "$manual_path" ]]; then
                    EXTERNAL_SSD_PATH="$manual_path"
                    return 0
                fi
                ;;
            3)
                EXTERNAL_SSD_PATH="$HOME/VM-Images"
                mkdir -p "$EXTERNAL_SSD_PATH"
                log_info "Nutze internen Pfad: $EXTERNAL_SSD_PATH"
                return 0
                ;;
            *)
                return 1
                ;;
        esac
        return 1
    fi
    
    echo -e "\n${YELLOW}Gefundene externe Speichergeräte:${NC}"
    local i=1
    declare -A device_map
    
    for device_line in "${device_info[@]}"; do
        [[ -z "$device_line" ]] && continue
        IFS='|' read -r dev_path size_info model_info removable <<< "$device_line"
        echo "$i) $dev_path - $size_info - $model_info"
        device_map[$i]="$dev_path"
        ((i++))
    done
    
    echo "$i) Manueller Pfad eingeben"
    echo "$((i+1))) Auf internem Speicher verwenden"
    
    echo ""
    read -p "Wähle Gerät [1-$((i+1))]: " choice
    
    if [[ $choice -eq $i ]]; then
        # Manueller Pfad
        read -p "Gib den Mount-Pfad ein (z.B. /media/user/SSD): " manual_path
        if [[ -d "$manual_path" ]]; then
            EXTERNAL_SSD_PATH="$manual_path"
            return 0
        else
            log_error "Pfad nicht gefunden: $manual_path"
            return 1
        fi
    elif [[ $choice -eq $((i+1)) ]]; then
        # Interner Speicher
        EXTERNAL_SSD_PATH="$HOME/VM-Images"
        mkdir -p "$EXTERNAL_SSD_PATH"
        log_info "Nutze internen Pfad: $EXTERNAL_SSD_PATH"
        return 0
    elif [[ -n "${device_map[$choice]}" ]]; then
        local selected_device="${device_map[$choice]}"
        log_info "Gewähltes Gerät: $selected_device"
        
        # Prüfen ob bereits gemountet
        local mount_point=$(mount | grep "$selected_device" | awk '{print $3}' | head -1)
        
        if [[ -n "$mount_point" ]]; then
            log_success "Gerät bereits gemountet: $mount_point"
            EXTERNAL_SSD_PATH="$mount_point"
        else
            log_warn "Gerät nicht gemountet. Automatisches Mounten..."
            
            # Versuche Auto-Mount (udisks2)
            if command -v udisksctl &>/dev/null; then
                # Finde erste Partition
                local partition="${selected_device}1"
                [[ ! -b "$partition" ]] && partition="$selected_device"
                
                local mount_result=$(udisksctl mount -b "$partition" 2>/dev/null || echo "FEHLER")
                
                if [[ "$mount_result" != "FEHLER" ]]; then
                    mount_point=$(echo "$mount_result" | grep -o '/[^.]*')
                    EXTERNAL_SSD_PATH="$mount_point"
                    log_success "Auto-Mount erfolgreich: $mount_point"
                else
                    log_error "Auto-Mount fehlgeschlagen!"
                    return 1
                fi
            else
                log_error "udisksctl nicht verfügbar - manuelles Mounten erforderlich"
                return 1
            fi
        fi
        
        return 0
    else
        log_error "Ungültige Auswahl: $choice"
        return 1
    fi
}

# VM-Verzeichnisstruktur erstellen
setup_vm_directory() {
    local vm_dir="$EXTERNAL_SSD_PATH/$VM_COLLECTION_NAME"
    
    log_info "📁 Erstelle VM-Verzeichnisstruktur auf externer SSD..."
    
    # Hauptverzeichnis
    mkdir -p "$vm_dir"
    mkdir -p "$vm_dir/images"
    mkdir -p "$vm_dir/snapshots" 
    mkdir -p "$vm_dir/scripts"
    mkdir -p "$vm_dir/iso"
    mkdir -p "$vm_dir/shared"
    
    # Berechtigungen setzen
    chown -R "$USER:$USER" "$vm_dir"
    
    # README erstellen
    cat > "$vm_dir/README.md" << EOF
# QEMU VM Collection auf ext4-SSD

Diese VM-Sammlung wurde automatisch erstellt.

## Hardware:
- Device: /dev/md126p1 (Software-RAID)
- Label: VM-extern-SSD  
- Dateisystem: ext4 (optimiert für VMs)
- UUID: dde1defd-0723-404b-bba3-dbc6e43cd375

## Verzeichnisse:
- images/: VM-Images (.img, .qcow2)
- snapshots/: VM-Snapshots und Backups
- scripts/: Start-Scripts und Tools  
- iso/: ISO-Images für Installation
- shared/: Dateien zwischen Host und VMs

## Windows-VM:
- Quelle: nvme1n1p4 (Windows-Hauptpartition)
- Image: windows-main.img
- Start: scripts/start-windows-vm.sh

## Performance-Tipps:
- Software-RAID ist OK für einzelne SSD
- ext4 ist optimal für VM-Images
- USB 3.1+ für beste Performance

Erstellt: $(date)
Von: Manjaro Robust NVMe Copy Script
EOF
    
    # Überprüfe verfügbaren Platz
    local free_space=$(df --output=avail -B1 "$EXTERNAL_SSD_PATH" | tail -n1)
    local free_gb=$(( free_space / 1024 / 1024 / 1024 ))
    
    log_success "VM-Verzeichnis erstellt: $vm_dir"
    log_info "Verfügbarer Platz: ${free_gb}GB"
    
    # Pfad-Variablen setzen
    TARGET_FILE="$vm_dir/images/windows-main.img"
    TEMP_TARGET="${TARGET_FILE}.tmp"
    PROGRESS_FILE="${TARGET_FILE}.progress"
    ERROR_LOG="${TARGET_FILE}.errors"
    
    return 0
}

# Geräte-Informationen prüfen
check_source_device() {
    log_info "Prüfe Quell-Gerät: $SOURCE_DEVICE"
    
    if [[ ! -b "$SOURCE_DEVICE" ]]; then
        log_error "Gerät $SOURCE_DEVICE nicht gefunden!"
        exit 1
    fi
    
    # Größe ermitteln
    local size_bytes=$(blockdev --getsize64 "$SOURCE_DEVICE")
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))
    
    log_success "Gerät gefunden: ${size_gb}GB ($(numfmt --to=iec $size_bytes))"
    
    # NTFS-Check
    if file -s "$SOURCE_DEVICE" | grep -q "NTFS"; then
        log_success "NTFS-Dateisystem bestätigt"
    else
        log_warn "Kein NTFS erkannt - trotzdem fortfahren?"
        read -p "Weiter? (j/n): " confirm
        [[ $confirm != "j" ]] && exit 1
    fi
    
    echo "$size_bytes" > "${PROGRESS_FILE}.total_size"
}

# NVMe-Temperatur prüfen (Laptop-optimiert)
check_nvme_temp() {
    local nvme_dev=$(echo "$SOURCE_DEVICE" | sed 's/p[0-9]*$//')
    local temp_critical=false
    local temp_high=false
    
    # 1. Direkte NVMe-Temperatur (smartctl/nvme tools)
    if command -v nvme &> /dev/null && [[ "$nvme_dev" =~ nvme ]]; then
        local nvme_temp=$(nvme smart-log "$nvme_dev" 2>/dev/null | grep -i "temperature" | head -1 | grep -o '[0-9]*' | head -1 2>/dev/null || echo "")
        
        if [[ -n "$nvme_temp" && "$nvme_temp" -gt 0 ]]; then
            log_info "💾 NVMe-Temp: ${nvme_temp}°C"
            
            if [[ "$nvme_temp" -gt 80 ]]; then
                log_error "🔥 KRITISCHE NVMe-Temperatur: ${nvme_temp}°C!"
                return 2  # Kritisch
            elif [[ "$nvme_temp" -gt 70 ]]; then
                log_warn "🌡️  Hohe NVMe-Temperatur: ${nvme_temp}°C"
                temp_high=true
            fi
        fi
    fi
    
    # 2. System Thermal Zones (Laptop-spezifisch)
    local max_temp=0
    for thermal_zone in /sys/class/thermal/thermal_zone*; do
        if [[ -r "$thermal_zone/type" && -r "$thermal_zone/temp" ]]; then
            local zone_type=$(cat "$thermal_zone/type" 2>/dev/null || echo "")
            local temp_mC=$(cat "$thermal_zone/temp" 2>/dev/null || echo "0")
            local temp_C=$((temp_mC / 1000))
            
            # Relevante Sensoren für NVMe/Storage
            if [[ "$zone_type" =~ (nvme|ssd|thermal|cpu|core) && "$temp_C" -gt 10 && "$temp_C" -lt 120 ]]; then
                [[ $temp_C -gt $max_temp ]] && max_temp=$temp_C
                
                # Kritische Temperaturen per Zone
                if [[ "$temp_C" -gt 85 ]]; then
                    log_error "🔥 KRITISCH: $zone_type = ${temp_C}°C"
                    temp_critical=true
                elif [[ "$temp_C" -gt 75 ]]; then
                    log_warn "🌡️  Hoch: $zone_type = ${temp_C}°C"
                    temp_high=true
                fi
            fi
        fi
    done
    
    # 3. Lüftergeschwindigkeit anzeigen
    local fan_rpm_info=""
    for hwmon in /sys/class/hwmon/hwmon*; do
        for fan_input in "$hwmon"/fan*_input; do
            if [[ -r "$fan_input" ]]; then
                local rpm=$(cat "$fan_input" 2>/dev/null || echo "0")
                [[ $rpm -gt 0 ]] && fan_rpm_info="$fan_rpm_info $(basename ${fan_input/_input/}):${rpm}RPM"
            fi
        done
    done
    [[ -n "$fan_rpm_info" ]] && log_info "🌀 Lüfter:$fan_rpm_info"
    
    # Return-Status für Copy-Script
    if [[ $temp_critical == true ]]; then
        return 2  # Kritisch - lange Pause
    elif [[ $temp_high == true || $max_temp -gt 70 ]]; then
        return 1  # Hoch - normale Pause
    else
        return 0  # OK
    fi
}

# Fortschritt laden
load_progress() {
    if [[ -f "$PROGRESS_FILE" ]]; then
        log_info "Vorherigen Fortschritt gefunden"
        source "$PROGRESS_FILE"
        log_info "Fortsetzen bei Block: $CURRENT_BLOCK von $TOTAL_BLOCKS"
        return 0
    else
        return 1
    fi
}

# Fortschritt speichern
save_progress() {
    cat > "$PROGRESS_FILE" << EOF
CURRENT_BLOCK=$1
TOTAL_BLOCKS=$2
COPIED_BYTES=$3
START_TIME=$4
FAILED_BLOCKS="$5"
EOF
}

# Einzelnen Block kopieren mit Retry-Logik
copy_block_with_retry() {
    local block_num=$1
    local skip_blocks=$2
    local attempt=1
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        if dd if="$SOURCE_DEVICE" of="$TEMP_TARGET" \
           bs="$BLOCK_SIZE" count="$BLOCKS_PER_CHUNK" \
           skip=$skip_blocks seek=$skip_blocks \
           conv=noerror,sync oflag=seek_bytes,direct \
           status=none 2>/dev/null; then
            
            return 0  # Erfolg
        else
            log_warn "Block $block_num Versuch $attempt fehlgeschlagen"
            
            if [[ $attempt -lt $MAX_RETRIES ]]; then
                log_info "Warte ${RETRY_PAUSE}s vor erneutem Versuch..."
                sleep $RETRY_PAUSE
                
                # Extra Kühlung bei Wiederholung
                if ! check_nvme_temp; then
                    log_warn "Hohe Temperatur - erweiterte Kühlung (60s)..."
                    sleep 60
                fi
            fi
            
            ((attempt++))
        fi
    done
    
    return 1  # Fehlgeschlagen
}

# Hauptkopie-Funktion
perform_copy() {
    local total_size=$(cat "${PROGRESS_FILE}.total_size")
    local chunk_size=$((BLOCKS_PER_CHUNK * 1024 * 1024))  # in Bytes
    local total_blocks=$((total_size / chunk_size + 1))
    
    local current_block=0
    local copied_bytes=0
    local start_time=$(date +%s)
    local failed_blocks=""
    
    # Fortschritt laden falls vorhanden
    if load_progress; then
        current_block=$CURRENT_BLOCK
        copied_bytes=$COPIED_BYTES
        start_time=$START_TIME
        failed_blocks="$FAILED_BLOCKS"
        total_blocks=$TOTAL_BLOCKS
    fi
    
    log_info "Starte Copy-Vorgang:"
    log_info "  Quelle: $SOURCE_DEVICE"
    log_info "  Ziel: $TEMP_TARGET"
    log_info "  Chunk-Größe: $(numfmt --to=iec $chunk_size)"
    log_info "  Kühlung: ${COOLING_PAUSE}s zwischen Chunks"
    log_info "  Gesamt-Blocks: $total_blocks"
    
    # Laptop-Lüfter auf Hochtouren wenn gewünscht
    echo ""
    read -p "$(echo -e ${YELLOW}Laptop-Lüfter auf Maximum für optimale Kühlung? [j/n]:${NC}) " fan_control
    if [[ $fan_control == "j" || $fan_control == "J" ]]; then
        activate_laptop_cooling
        echo ""
    fi
    
    # Temporäre Datei initialisieren falls neu
    if [[ $current_block -eq 0 ]]; then
        log_info "Initialisiere Ziel-Datei..."
        truncate -s "$total_size" "$TEMP_TARGET"
    fi
    
    echo -e "${PURPLE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║          ROBUSTE NVMe KOPIERUNG              ║${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════╝${NC}"
    
    while [[ $current_block -lt $total_blocks ]]; do
        local skip_bytes=$((current_block * chunk_size))
        local skip_blocks=$((skip_bytes / 1024 / 1024))  # für dd skip parameter
        
        # Fortschritt anzeigen
        local percent=$((current_block * 100 / total_blocks))
        local elapsed=$(($(date +%s) - start_time))
        local rate=$((copied_bytes / elapsed / 1024 / 1024))  # MB/s
        local eta=$(( (total_size - copied_bytes) / rate / 1024 / 1024 ))
        
        printf "\r${BLUE}Block: %4d/%d (%2d%%) | %3dMB/s | ETA: %dm%02ds | Fehler: %d${NC}" \
               "$current_block" "$total_blocks" "$percent" \
               "$rate" "$((eta/60))" "$((eta%60))" \
               "$(echo "$failed_blocks" | wc -w)"
        
        # Temperatur-Check vor jedem Block mit erweiterte Reaktion
        local temp_status
        check_nvme_temp
        temp_status=$?
        
        if [[ $temp_status -eq 2 ]]; then
            log_error "\n🔥 KRITISCHE TEMPERATUREN! Zwangs-Kühlung (60s)..."
            sleep 60
            # Nochmal prüfen
            check_nvme_temp
            temp_status=$?
            if [[ $temp_status -eq 2 ]]; then
                log_error "Temperaturen immer noch kritisch! Pausiere Copy für 120s..."
                sleep 120
            fi
        elif [[ $temp_status -eq 1 ]]; then
            log_warn "\n🌡️  Hohe Temperaturen - verlängere Kühlung auf 30s..."
            sleep 30
        fi
        
        # Block kopieren
        if copy_block_with_retry "$current_block" "$skip_blocks"; then
            copied_bytes=$((copied_bytes + chunk_size))
        else
            log_error "\nBlock $current_block endgültig fehlgeschlagen - markiert für späteren Retry"
            failed_blocks="$failed_blocks $current_block"
        fi
        
        ((current_block++))
        
        # Fortschritt speichern (alle 10 Blocks)
        if [[ $((current_block % 10)) -eq 0 ]]; then
            save_progress "$current_block" "$total_blocks" "$copied_bytes" "$start_time" "$failed_blocks"
        fi
        
        # Kühlung (außer beim letzten Block)
        if [[ $current_block -lt $total_blocks ]]; then
            sleep $COOLING_PAUSE
        fi
    done
    
    echo  # Neue Zeile nach Progress-Bar
    
    # Fehlgeschlagene Blocks nochmal versuchen
    if [[ -n "$failed_blocks" ]]; then
        log_warn "Versuche fehlgeschlagene Blocks erneut..."
        
        for failed_block in $failed_blocks; do
            local skip_bytes=$((failed_block * chunk_size))
            local skip_blocks=$((skip_bytes / 1024 / 1024))
            
            log_info "Retry Block $failed_block..."
            
            if copy_block_with_retry "$failed_block" "$skip_blocks"; then
                log_success "Block $failed_block erfolgreich im Retry"
                failed_blocks=$(echo "$failed_blocks" | sed "s/ *$failed_block */ /g")
            else
                log_error "Block $failed_block auch im Retry fehlgeschlagen!"
            fi
            
            sleep $((COOLING_PAUSE * 2))  # Längere Pause bei Retry
        done
    fi
    
    # Finalisierung mit Fan-Control Cleanup
    if [[ -z "$(echo $failed_blocks | tr -d ' ')" ]]; then
        log_success "Alle Blocks erfolgreich kopiert!"
        mv "$TEMP_TARGET" "$TARGET_FILE"
        rm -f "$PROGRESS_FILE" "${PROGRESS_FILE}.total_size"
        
        # Fan-Control wiederherstellen
        if [[ $FAN_CONTROL_ACTIVE == true ]]; then
            echo ""
            log_info "🌀 Copy erfolgreich abgeschlossen - stelle Lüftersteuerung wieder her..."
            restore_laptop_fans
        fi
        
        return 0
    else
        log_error "Einige Blocks konnten nicht kopiert werden: $failed_blocks"
        log_error "Image möglicherweise korrupt!"
        
        # Auch bei Fehlern Fan-Control wiederherstellen
        if [[ $FAN_CONTROL_ACTIVE == true ]]; then
            echo ""
            log_warn "🌀 Stelle Lüftersteuerung trotz Fehlern wieder her..."
            restore_laptop_fans
        fi
        
        return 1
    fi

    # Image in qcow2 konvertieren für bessere Performance und Features
    if [[ -f "$TARGET_FILE" ]]; then
        log_info "Konvertiere Image zu qcow2..."
        qemu-img convert -f raw -O qcow2 "$TARGET_FILE" "${TARGET_FILE}.qcow2"
        log_success "Konvertierung zu qcow2 abgeschlossen!"
        log_info "Lösche RAW-Image..."
        rm "$TARGET_FILE"
        TARGET_FILE="${TARGET_FILE}.qcow2"
    fi
}

# Kompression
compress_image() {
    if [[ -f "$TARGET_FILE" ]]; then
        log_info "Komprimiere Image mit pigz..."
        
        local orig_size=$(stat -c%s "$TARGET_FILE")
        pigz -v "$TARGET_FILE"
        local comp_size=$(stat -c%s "${TARGET_FILE}.gz")
        
        local ratio=$((comp_size * 100 / orig_size))
        
        log_success "Kompression abgeschlossen!"
        log_success "Original: $(numfmt --to=iec $orig_size)"
        log_success "Komprimiert: $(numfmt --to=iec $comp_size) (${ratio}%)"
    fi
}

# QEMU-Test Kommandos
show_qemu_commands() {
    echo -e "\n${PURPLE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║               QEMU TEST SETUP                ║${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════╝${NC}"
    
    if [[ -f "${TARGET_FILE}.gz" ]]; then
        echo "Komprimiertes Image testen:"
        echo "pigz -d ${TARGET_FILE}.gz"
        echo "qemu-system-x86_64 -drive file=${TARGET_FILE},format=raw -m 4096 -enable-kvm -cpu host"
    elif [[ -f "$TARGET_FILE" ]]; then
        echo "Image direkt testen:"
        echo "qemu-system-x86_64 -drive file=${TARGET_FILE},format=qcow2,if=virtio -m 4096 -enable-kvm -cpu host -smp 4 -vga virtio -usb -device usb-tablet -net nic,model=virtio -net user -bios /usr/share/ovmf/OVMF.fd"
    fi
}

# Hauptprogramm
main() {
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ROBUSTES NVMe IMAGE CREATOR SCRIPT      ║${NC}"
    echo -e "${GREEN}║   Mit Kühlung und Fehlerbehandlung für      ║${NC}"
    echo -e "${GREEN}║      externe USB-NVMe Gehäuse               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    
    # Berechtigungen prüfen
    if [[ $EUID -ne 0 ]]; then
        log_error "Script muss als root ausgeführt werden!"
        echo "Verwende: sudo $0"
        exit 1
    fi
    
    # Geräte-Check
    check_source_device
    
    # Externe SSD Setup
    log_info "🔍 Externe SSD für VM-Images Setup..."
    if ! select_external_ssd; then
        log_error "Externe SSD Setup fehlgeschlagen!"
        exit 1
    fi
    
    # VM-Verzeichnis erstellen
    if ! setup_vm_directory; then
        log_error "VM-Verzeichnis Setup fehlgeschlagen!"
        exit 1
    fi
    
    log_success "✅ VM-Setup abgeschlossen!"
    log_info "📁 VM-Pfad: $EXTERNAL_SSD_PATH/$VM_COLLECTION_NAME"
    log_info "🎯 Image-Ziel: $TARGET_FILE"
    
    # Speicherplatz prüfen
    local free_space=$(df --output=avail -B1 "$(dirname "$TARGET_FILE")" | tail -n1)
    local needed_space=$(cat "${PROGRESS_FILE}.total_size")
    
    if [[ $free_space -lt $needed_space ]]; then
        log_error "Nicht genügend Speicherplatz!"
        log_error "Benötigt: $(numfmt --to=iec $needed_space)"
        log_error "Verfügbar: $(numfmt --to=iec $free_space)"
        exit 1
    fi
    
    log_success "Speicherplatz ausreichend"
    
    # Benutzer-Bestätigung
    echo -e "\n${YELLOW}KONFIGURATION:${NC}"
    echo "  Quelle: $SOURCE_DEVICE"
    echo "  Ziel: $TARGET_FILE"
    echo "  Chunk-Größe: $((BLOCKS_PER_CHUNK))MB"
    echo "  Kühlung: ${COOLING_PAUSE}s zwischen Chunks"
    echo "  Max-Retries: $MAX_RETRIES"
    
    read -p "$(echo -e ${YELLOW}Fortfahren? [j/n]:${NC}) " confirm
    [[ $confirm != "j" ]] && exit 0
    
    # Kopierung starten
    if perform_copy; then
        log_success "Image-Erstellung erfolgreich abgeschlossen!"
        
        read -p "Image komprimieren? [j/n]: " comp_confirm
        [[ $comp_confirm == "j" ]] && compress_image
        
        show_qemu_commands
    else
        log_error "Image-Erstellung mit Fehlern beendet!"
        echo "Prüfe Error-Log: $ERROR_LOG"
        exit 1
    fi
}

# Script starten
main "$@"