#!/usr/bin/env bash
set -euo pipefail

VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
ROJO='\033[0;31m'
AZUL='\033[0;34m'
SIN_COLOR='\033[0m'

info()  { echo -e "${AZUL}[INFO]${SIN_COLOR} $1"; }
ok()    { echo -e "${VERDE}[OK]${SIN_COLOR} $1"; }
warn()  { echo -e "${AMARILLO}[WARN]${SIN_COLOR} $1"; }
error() { echo -e "${ROJO}[ERROR]${SIN_COLOR} $1"; }

if [[ $EUID -ne 0 ]]; then
   error "Este script debe ejecutarse como root (sudo)."
   exit 1
fi

if ! command -v pacman &>/dev/null; then
    error "Este script solo funciona en Arch Linux."
    exit 1
fi

PACKAGES=(blueman bluez bluez-utils pipewire-pulse)

info "Verificando e instalando paquetes..."
MISSING=()
for pkg in "${PACKAGES[@]}"; do
    pacman -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "Todos los paquetes ya están instalados."
else
    warn "Faltan: ${MISSING[*]}. Instalando..."
    pacman -S --noconfirm "${MISSING[@]}"
    ok "Paquetes instalados correctamente."
fi

info "Habilitando e iniciando el servicio bluetooth..."
systemctl enable bluetooth.service 2>/dev/null || true
systemctl start bluetooth.service 2>/dev/null || true
if systemctl is-active --quiet bluetooth.service; then
    ok "Servicio bluetooth activo."
else
    warn "El servicio bluetooth no se inició. Revisa: systemctl status bluetooth"
fi

info "Configurando pipewire-pulse (audio Bluetooth)..."
if systemctl --user list-unit-files pipewire-pulse.service &>/dev/null 2>&1; then
    systemctl --user enable --now pipewire-pulse.service 2>/dev/null || true
    if systemctl --user is-active --quiet pipewire-pulse.service 2>/dev/null; then
        ok "pipewire-pulse activo."
    fi
else
    warn "pipewire-pulse no encontrado. ¿Seguro que está instalado?"
fi

info "Verificando que el adaptador Bluetooth no esté bloqueado..."
if command -v rfkill &>/dev/null; then
    rfkill unblock bluetooth
    ok "Bloqueos de Bluetooth liberados (si los había)."
fi

info "Estado del adaptador Bluetooth:"
if command -v bluetoothctl &>/dev/null; then
    echo -e "  bluetoothctl show:"
    bluetoothctl show 2>/dev/null | grep -E "(Controller|Powered|Discoverable|Pairable)" | sed 's/^/    /' || echo "  (no se pudo obtener info de bluetoothctl)"
fi

info "Verificando Blueman..."
if command -v blueman-manager &>/dev/null || command -v blueman-applet &>/dev/null; then
    ok "Blueman está instalado y disponible."
    echo -e "  Ejecuta 'blueman-manager' para abrir la interfaz gráfica."
    echo -e "  Ejecuta 'blueman-applet' para el icono en la bandeja del sistema."
else
    warn "Los binarios de Blueman no se encontraron en PATH, aunque el paquete esté instalado."
fi

info "Resumen de servicios:"
systemctl status bluetooth.service --no-pager 2>&1 | head -5 | sed 's/^/  /'
echo ""
ok "Script completado."
