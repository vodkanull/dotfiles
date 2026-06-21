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

info "Detectando gestor de paquetes..."
if command -v apt &>/dev/null; then
    PKG_MANAGER="apt"
    INSTALL_CMD="apt install -y"
    PACKAGES=(blueman bluez bluez-tools rfkill)
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
    PACKAGES=(blueman bluez bluez-tools)
elif command -v pacman &>/dev/null; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="pacman -S --noconfirm"
    PACKAGES=(blueman bluez bluez-utils)
elif command -v zypper &>/dev/null; then
    PKG_MANAGER="zypper"
    INSTALL_CMD="zypper install -y"
    PACKAGES=(blueman bluez bluez-tools)
else
    error "No se pudo detectar el gestor de paquetes. Compatibles: apt, dnf, pacman, zypper."
    exit 1
fi
ok "Gestor detectado: $PKG_MANAGER"

info "Verificando e instalando paquetes necesarios..."
MISSING=()
for pkg in "${PACKAGES[@]}"; do
    case "$PKG_MANAGER" in
        apt)
            dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg") ;;
        dnf)
            rpm -q "$pkg" &>/dev/null || MISSING+=("$pkg") ;;
        pacman)
            pacman -Qi "$pkg" &>/dev/null || MISSING+=("$pkg") ;;
        zypper)
            rpm -q "$pkg" &>/dev/null || MISSING+=("$pkg") ;;
    esac
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    ok "Todos los paquetes ya están instalados."
else
    warn "Faltan: ${MISSING[*]}. Instalando..."
    $INSTALL_CMD "${MISSING[@]}"
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

info "Verificando que el adaptador Bluetooth no esté bloqueado..."
if command -v rfkill &>/dev/null; then
    rfkill unblock bluetooth
    ok "Bloqueos de Bluetooth liberados (si los había)."
fi

info "Estado del adaptador Bluetooth:"
if command -v hciconfig &>/dev/null; then
    hciconfig -a 2>/dev/null | head -5 || echo "  (sin adaptadores visibles vía hciconfig)"
fi

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
ok "Script completado. Si todo está verde, tu Bluetooth debería funcionar."
