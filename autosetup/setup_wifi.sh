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

# ─── Detectar gestor de paquetes ───────────────────────────────────
info "Detectando gestor de paquetes..."
if command -v apt &>/dev/null; then
    PKG_MANAGER="apt"
    INSTALL_CMD="apt install -y"
    NETWORKMANAGER="network-manager"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
    NETWORKMANAGER="NetworkManager"
elif command -v pacman &>/dev/null; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="pacman -S --noconfirm"
    NETWORKMANAGER="networkmanager"
elif command -v zypper &>/dev/null; then
    PKG_MANAGER="zypper"
    INSTALL_CMD="zypper install -y"
    NETWORKMANAGER="NetworkManager"
else
    error "No se pudo detectar el gestor de paquetes. Compatibles: apt, dnf, pacman, zypper."
    exit 1
fi
ok "Gestor: $PKG_MANAGER"

# ─── 1. Descargar paquetes ANTES de tocar servicios ─────────────────
info "Instalando NetworkManager (y backend iwd si aplica)..."
case "$PKG_MANAGER" in
    apt)
        $INSTALL_CMD network-manager
        # En Debian/Ubuntu iwd no viene por defecto, pero si está se evita conflicto después
        ;;
    dnf)
        $INSTALL_CMD NetworkManager NetworkManager-wifi
        ;;
    pacman)
        $INSTALL_CMD networkmanager iwd  # iwd como backend opcional
        ;;
    zypper)
        $INSTALL_CMD NetworkManager NetworkManager-wifi
        ;;
esac
ok "Paquetes instalados."

# ─── 2. Resolver conflicto iwd ↔ NetworkManager ────────────────────
# iwd y NetworkManager pueden pelear si ambos intentan gestionar wifi.
# Estrategia: si iwd está activo, configuramos NetworkManager para usar iwd como backend.
# Así no se desinstala ni se mata iwd, y ambos conviven.

IWD_ACTIVE=false
if systemctl is-active --quiet iwd.service 2>/dev/null; then
    IWD_ACTIVE=true
    info "iwd está activo. Configurando NetworkManager para usarlo como backend wifi..."
fi

NM_CONF_D="/etc/NetworkManager/conf.d"
mkdir -p "$NM_CONF_D"

if $IWD_ACTIVE; then
    cat > "$NM_CONF_D/wifi-backend-iwd.conf" << 'EOF'
[device]
match-device=type:wifi
wifi.backend=iwd
EOF
    ok "NetworkManager usará iwd como backend wifi -> no hay conflicto."
else
    # Si existe el conf de iwd pero iwd ya no está activo, lo limpiamos
    rm -f "$NM_CONF_D/wifi-backend-iwd.conf"
fi

# ─── 3. Desactivar servicios que compiten con NM ────────────────────
# systemd-networkd suele estar en distros con iwd y puede interferir
if systemctl is-active --quiet systemd-networkd.service 2>/dev/null; then
    warn "systemd-networkd está activo. Deteniéndolo para evitar conflictos..."
    systemctl stop systemd-networkd.service
    systemctl disable systemd-networkd.service 2>/dev/null || true
    ok "systemd-networkd detenido y deshabilitado."
fi

# dhcpcd también puede interferir
if systemctl is-active --quiet dhcpcd.service 2>/dev/null; then
    warn "dhcpcd está activo. Deteniéndolo..."
    systemctl stop dhcpcd.service
    systemctl disable dhcpcd.service 2>/dev/null || true
    ok "dhcpcd detenido."
fi

# ─── 4. Habilitar e iniciar NetworkManager ──────────────────────────
info "Habilitando e iniciando NetworkManager..."
systemctl enable NetworkManager.service 2>/dev/null || true
systemctl start NetworkManager.service 2>/dev/null || true

# Pequeña pausa para que NM termine de iniciar
sleep 2

if systemctl is-active --quiet NetworkManager.service; then
    ok "NetworkManager activo."
else
    error "NetworkManager no se inició. Revisa: systemctl status NetworkManager"
    exit 1
fi

# ─── 5. Pedir credenciales WiFi ─────────────────────────────────────
echo ""
read -r -p "$(echo -e "${AZUL}[?]${SIN_COLOR} SSID (nombre de la red): ")" SSID
read -r -s -p "$(echo -e "${AZUL}[?]${SIN_COLOR} Contraseña: ")" PASS
echo ""

if [[ -z "$SSID" ]]; then
    error "El SSID no puede estar vacío."
    exit 1
fi

# ─── 6. Conectar ────────────────────────────────────────────────────
info "Conectando a '$SSID'..."
# Eliminar conexión previa con ese SSID para evitar duplicados
nmcli connection delete id "$SSID" 2>/dev/null || true

if [[ -z "$PASS" ]]; then
    # Red abierta
    nmcli device wifi connect "$SSID" 2>/tmp/nm_error.txt || {
        error "Falló la conexión. Detalles:"
        cat /tmp/nm_error.txt
        exit 1
    }
else
    nmcli device wifi connect "$SSID" password "$PASS" 2>/tmp/nm_error.txt || {
        error "Falló la conexión. Detalles:"
        cat /tmp/nm_error.txt
        exit 1
    }
fi

ok "Conectado a '$SSID'."

# ─── 7. Mostrar resultado ───────────────────────────────────────────
echo ""
info "Estado de la conexión:"
nmcli connection show --active 2>/dev/null | grep -E "(NAME|wifi|802-11)" | sed 's/^/  /'
echo ""
ip -4 addr show 2>/dev/null | grep -E "inet " | grep -v "127.0.0.1" | sed 's/^/  /' || true

echo ""
ok "¡Todo listo! Ya tienes WiFi con NetworkManager."
echo "  Para gestionar redes: nmtui (interfaz TUI) o nm-connection-editor (GUI)"
