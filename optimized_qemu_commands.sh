#!/bin/bash

# Optimierte QEMU-Befehle für Windows-Image (Manjaro/Arch Linux)
# Erstellt von Manus AI

IMAGE_PATH="/media/vm-extern-ssd/qemu-vms/images/windows-main.img"
COMPRESSED_IMAGE="${IMAGE_PATH}.gz"

echo "╔══════════════════════════════════════════════╗"
echo "║    OPTIMIERTE QEMU WINDOWS BEFEHLE (MANJARO) ║"
echo "╚══════════════════════════════════════════════╝"
echo

# Prüfe ob OVMF verfügbar ist (Manjaro/Arch Pfade)
OVMF_PATHS=(
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
    "/usr/share/ovmf/x64/OVMF_CODE.fd"
    "/usr/share/OVMF/OVMF_CODE.fd"
    "/usr/share/edk2-ovmf/OVMF_CODE.fd"
    "/usr/share/ovmf/OVMF.fd"
    "/usr/share/qemu/OVMF.fd"
)

OVMF_VARS_PATHS=(
    "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd"
    "/usr/share/ovmf/x64/OVMF_VARS.fd"
    "/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/edk2-ovmf/OVMF_VARS.fd"
)

OVMF_CODE=""
OVMF_VARS=""

for path in "${OVMF_PATHS[@]}"; do
    if [[ -f "$path" ]]; then
        OVMF_CODE="$path"
        break
    fi
done

for path in "${OVMF_VARS_PATHS[@]}"; do
    if [[ -f "$path" ]]; then
        OVMF_VARS="$path"
        break
    fi
done

if [[ -z "$OVMF_CODE" ]]; then
    echo "⚠️  WARNUNG: OVMF BIOS nicht gefunden!"
    echo "   Installiere mit: sudo pacman -S edk2-ovmf"
    echo "   Ohne OVMF kann Windows möglicherweise nicht booten!"
    echo
fi

# Audio-System erkennen (PipeWire vs PulseAudio)
AUDIO_SYSTEM=""
if command -v pipewire &> /dev/null && pgrep -x pipewire > /dev/null; then
    AUDIO_SYSTEM="pipewire"
elif command -v pulseaudio &> /dev/null && pgrep -x pulseaudio > /dev/null; then
    AUDIO_SYSTEM="pulse"
else
    AUDIO_SYSTEM="alsa"
fi

echo "🔊 Erkanntes Audio-System: $AUDIO_SYSTEM"
echo

# Funktion für optimierten QEMU-Start
start_windows_vm() {
    local image_file="$1"
    local memory="${2:-4096}"
    local cpus="${3:-4}"
    
    echo "🚀 Starte Windows VM..."
    echo "   Image: $image_file"
    echo "   RAM: ${memory}MB"
    echo "   CPUs: $cpus"
    echo "   OVMF CODE: ${OVMF_CODE:-"Legacy BIOS"}"
    echo "   OVMF VARS: ${OVMF_VARS:-"Nicht verfügbar"}"
    echo "   Audio: $AUDIO_SYSTEM"
    echo

    # Basis-Befehl
    local qemu_cmd="qemu-system-x86_64"
    
    # Image und Format
    qemu_cmd="$qemu_cmd -drive file=$image_file,format=raw,if=virtio,cache=writeback"
    
    # Speicher und CPU
    qemu_cmd="$qemu_cmd -m $memory"
    qemu_cmd="$qemu_cmd -smp $cpus"
    
    # KVM für bessere Performance
    qemu_cmd="$qemu_cmd -enable-kvm -cpu host"
    
    # UEFI/OVMF falls verfügbar (moderne Arch/Manjaro Methode)
    if [[ -n "$OVMF_CODE" && -n "$OVMF_VARS" ]]; then
        # Erstelle eine Kopie der VARS-Datei für diese VM
        local vm_vars="/tmp/OVMF_VARS_$(basename "$image_file").fd"
        if [[ ! -f "$vm_vars" ]]; then
            cp "$OVMF_VARS" "$vm_vars"
            echo "📁 OVMF VARS kopiert nach: $vm_vars"
        fi
        qemu_cmd="$qemu_cmd -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        qemu_cmd="$qemu_cmd -drive if=pflash,format=raw,file=$vm_vars"
    elif [[ -n "$OVMF_CODE" ]]; then
        # Fallback für ältere OVMF-Versionen
        qemu_cmd="$qemu_cmd -bios $OVMF_CODE"
    fi
    
    # Grafik und Input
    qemu_cmd="$qemu_cmd -vga virtio"
    qemu_cmd="$qemu_cmd -device virtio-gpu-pci"
    qemu_cmd="$qemu_cmd -usb -device usb-tablet"
    
    # Netzwerk
    qemu_cmd="$qemu_cmd -netdev user,id=net0 -device virtio-net-pci,netdev=net0"
    
    # Audio basierend auf erkanntem System
    case "$AUDIO_SYSTEM" in
        "pipewire")
            qemu_cmd="$qemu_cmd -audiodev pipewire,id=audio0 -device AC97,audiodev=audio0"
            ;;
        "pulse")
            qemu_cmd="$qemu_cmd -audiodev pulse,id=audio0 -device AC97,audiodev=audio0"
            ;;
        "alsa")
            qemu_cmd="$qemu_cmd -audiodev alsa,id=audio0 -device AC97,audiodev=audio0"
            ;;
    esac
    
    # RTC
    qemu_cmd="$qemu_cmd -rtc base=localtime,clock=host"
    
    # Zusätzliche Manjaro-spezifische Optimierungen
    qemu_cmd="$qemu_cmd -machine type=q35,accel=kvm"
    qemu_cmd="$qemu_cmd -device intel-hda -device hda-duplex"
    
    echo "Ausgeführter Befehl:"
    echo "$qemu_cmd"
    echo
    
    # Befehl ausführen
    eval "$qemu_cmd"
}

# Hauptmenü
echo "Verfügbare Optionen:"
echo

if [[ -f "$COMPRESSED_IMAGE" ]]; then
    echo "1) Komprimiertes Image dekomprimieren und starten"
    echo "   Datei: $COMPRESSED_IMAGE"
fi

if [[ -f "$IMAGE_PATH" ]]; then
    echo "2) Unkomprimiertes Image direkt starten"
    echo "   Datei: $IMAGE_PATH"
fi

echo "3) Benutzerdefinierter Pfad"
echo "4) Image zu qcow2 konvertieren (empfohlen)"
echo "5) Befehl nur anzeigen (nicht ausführen)"
echo

read -p "Wähle Option [1-5]: " choice

case $choice in
    1)
        if [[ -f "$COMPRESSED_IMAGE" ]]; then
            echo "🗜️  Dekomprimiere Image..."
            pigz -d "$COMPRESSED_IMAGE"
            start_windows_vm "$IMAGE_PATH"
        else
            echo "❌ Komprimiertes Image nicht gefunden: $COMPRESSED_IMAGE"
        fi
        ;;
    2)
        if [[ -f "$IMAGE_PATH" ]]; then
            start_windows_vm "$IMAGE_PATH"
        else
            echo "❌ Image nicht gefunden: $IMAGE_PATH"
        fi
        ;;
    3)
        read -p "Gib den Pfad zum Image ein: " custom_path
        if [[ -f "$custom_path" ]]; then
            start_windows_vm "$custom_path"
        else
            echo "❌ Datei nicht gefunden: $custom_path"
        fi
        ;;
    4)
        if [[ -f "$IMAGE_PATH" ]]; then
            echo "🔄 Konvertiere zu qcow2..."
            qemu-img convert -f raw -O qcow2 -p "$IMAGE_PATH" "${IMAGE_PATH%.img}.qcow2"
            echo "✅ Konvertierung abgeschlossen: ${IMAGE_PATH%.img}.qcow2"
            echo "💡 Verwende nun Option 3 mit dem .qcow2 Image für bessere Performance"
        else
            echo "❌ RAW-Image nicht gefunden: $IMAGE_PATH"
        fi
        ;;
    5)
        echo "📋 Optimierter QEMU-Befehl für Manjaro:"
        echo
        if [[ -f "$IMAGE_PATH" ]]; then
            echo "# Für Manjaro optimierter Befehl:"
            echo "qemu-system-x86_64 \\"
            echo "  -drive file=$IMAGE_PATH,format=raw,if=virtio,cache=writeback \\"
            echo "  -m 4096 -smp 4 \\"
            echo "  -enable-kvm -cpu host \\"
            echo "  -machine type=q35,accel=kvm \\"
            if [[ -n "$OVMF_CODE" && -n "$OVMF_VARS" ]]; then
                echo "  -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \\"
                echo "  -drive if=pflash,format=raw,file=/tmp/OVMF_VARS_windows-main.img.fd \\"
            elif [[ -n "$OVMF_CODE" ]]; then
                echo "  -bios $OVMF_CODE \\"
            fi
            echo "  -vga virtio -device virtio-gpu-pci \\"
            echo "  -usb -device usb-tablet \\"
            echo "  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \\"
            case "$AUDIO_SYSTEM" in
                "pipewire")
                    echo "  -audiodev pipewire,id=audio0 -device AC97,audiodev=audio0 \\"
                    ;;
                "pulse")
                    echo "  -audiodev pulse,id=audio0 -device AC97,audiodev=audio0 \\"
                    ;;
                "alsa")
                    echo "  -audiodev alsa,id=audio0 -device AC97,audiodev=audio0 \\"
                    ;;
            esac
            echo "  -device intel-hda -device hda-duplex \\"
            echo "  -rtc base=localtime,clock=host"
            echo
            echo "# Benötigte Pakete installieren:"
            echo "sudo pacman -S qemu-desktop edk2-ovmf"
        fi
        ;;
    *)
        echo "❌ Ungültige Auswahl"
        ;;
esac

echo
echo "💡 Manjaro-spezifische Tipps:"
echo "   • Installiere QEMU: sudo pacman -S qemu-desktop"
echo "   • Installiere OVMF: sudo pacman -S edk2-ovmf"
echo "   • Für bessere Performance: sudo pacman -S qemu-hw-display-virtio-gpu"
echo "   • Audio-Probleme? Prüfe: systemctl --user status pipewire"

