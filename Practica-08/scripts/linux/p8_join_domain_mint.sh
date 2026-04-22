#!/bin/bash
# p8_join_domain_mint.sh
# Script para unir Linux Mint al dominio Windows Server (redes.local)
# Requisitos:
#   - Instala: realmd, sssd, adcli
#   - Configura /etc/sssd/sssd.conf  (fallback_homedir = /home/%u@%d)
#   - Crea /etc/sudoers.d/ad-admins  (sudo para usuarios de AD)

# ─── Colores ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
fn_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
fn_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
fn_err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ─── Verificar root ──────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { fn_err "Ejecuta como root:  sudo bash $0"; }

# ─── Configuracion del dominio ───────────────────────────────────────────────
DOMAIN="redes.local"            # Dominio Windows Server
DC_IP="192.168.222.214"         # IP del Domain Controller (Windows Server)

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗"
echo    "║  UNION A DOMINIO AD — Linux Mint  →  redes.local        ║"
echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# PASO 1 — CONFIGURAR DNS PARA RESOLVER EL DOMINIO
# Sin esto, realm discover falla aunque el servidor responda por IP
# ════════════════════════════════════════════════════════════════════════════
fn_info "Configurando DNS del dominio ($DC_IP)..."

# Detectar el archivo de resolv.conf correcto en Linux Mint (usa systemd-resolved)
if systemctl is-active --quiet systemd-resolved; then
    # Obtener el interfaz de red activo
    IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    resolvectl dns "$IFACE" "$DC_IP" 2>/dev/null && \
        fn_ok "DNS configurado via systemd-resolved en $IFACE" || \
        echo "nameserver $DC_IP" > /etc/resolv.conf
else
    echo "nameserver $DC_IP" > /etc/resolv.conf
    fn_ok "DNS configurado en /etc/resolv.conf -> $DC_IP"
fi

# Verificar que el dominio es accesible por DNS
if nslookup "$DOMAIN" "$DC_IP" &>/dev/null; then
    fn_ok "DNS OK: $DOMAIN resuelve correctamente."
else
    fn_err "No se pudo resolver $DOMAIN. Verifica la conectividad con el servidor ($DC_IP)."
fi

# ════════════════════════════════════════════════════════════════════════════
# PASO 2 — INSTALAR DEPENDENCIAS
# realmd   : descubre y une al dominio
# sssd     : autentica usuarios AD en Linux
# adcli    : herramienta de bajo nivel para AD
# ════════════════════════════════════════════════════════════════════════════
fn_info "Instalando paquetes: realmd, sssd, adcli y dependencias..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    realmd \
    sssd \
    sssd-tools \
    adcli \
    samba-common-bin \
    packagekit \
    libpam-sss \
    libnss-sss \
    oddjob \
    oddjob-mkhomedir \
    krb5-user 2>/dev/null

fn_ok "Paquetes instalados."

# ════════════════════════════════════════════════════════════════════════════
# PASO 3 — DESCUBRIR Y UNIRSE AL DOMINIO
# ════════════════════════════════════════════════════════════════════════════
fn_info "Descubriendo dominio $DOMAIN ..."
realm discover "$DOMAIN" || fn_err "No se encontro el dominio. Verifica red y DNS."

fn_info "Uniendo esta maquina al dominio $DOMAIN ..."
echo ""
echo -e "${CYAN}Ingresa las credenciales del Administrador del dominio:${NC}"
read -rp " Usuario (ej: Administrator): " AD_USER

realm join "$DOMAIN" -U "$AD_USER" --install=/

if realm list | grep -q "$DOMAIN"; then
    fn_ok "Union al dominio '$DOMAIN' exitosa."
else
    fn_err "Fallo la union. Verifica usuario/contrasena y que el servidor sea accesible."
fi

# ════════════════════════════════════════════════════════════════════════════
# PASO 4 — CONFIGURAR /etc/sssd/sssd.conf
# Requisito: fallback_homedir = /home/%u@%d
# ════════════════════════════════════════════════════════════════════════════
fn_info "Configurando /etc/sssd/sssd.conf ..."
SSSD_CONF="/etc/sssd/sssd.conf"

if [ ! -f "$SSSD_CONF" ]; then
    fn_err "$SSSD_CONF no existe. La union al dominio debio crearlo."
fi

# fallback_homedir = /home/%u@%d  (requisito exacto de la practica)
if grep -q "fallback_homedir" "$SSSD_CONF"; then
    sed -i 's|^fallback_homedir\s*=.*|fallback_homedir = /home/%u@%d|' "$SSSD_CONF"
else
    sed -i "/^\[domain\//a fallback_homedir = /home/%u@%d" "$SSSD_CONF"
fi
fn_ok "fallback_homedir = /home/%u@%d  configurado."

# Permitir login sin escribir @dominio (ej: carlos.perez en vez de carlos.perez@redes.local)
if grep -q "use_fully_qualified_names" "$SSSD_CONF"; then
    sed -i 's/^use_fully_qualified_names\s*=.*/use_fully_qualified_names = False/' "$SSSD_CONF"
else
    sed -i "/^\[domain\//a use_fully_qualified_names = False" "$SSSD_CONF"
fi
fn_ok "Nombres cortos habilitados (sin @redes.local)."

# Permisos requeridos por sssd (archivo debe ser 0600)
chmod 0600 "$SSSD_CONF"
chown root:root "$SSSD_CONF"

systemctl restart sssd
fn_ok "sssd reiniciado con la nueva configuracion."

# ════════════════════════════════════════════════════════════════════════════
# PASO 5 — HABILITAR CREACION AUTOMATICA DE HOME (/home/usuario@dominio)
# ════════════════════════════════════════════════════════════════════════════
fn_info "Habilitando creacion automatica de /home/%u@%d en primer login..."

# En Linux Mint (Ubuntu/Debian) se usa pam-auth-update
pam-auth-update --enable mkhomedir 2>/dev/null || \
    echo "session required pam_mkhomedir.so skel=/etc/skel umask=0022" \
    >> /etc/pam.d/common-session

fn_ok "Home directory automatico habilitado."

# ════════════════════════════════════════════════════════════════════════════
# PASO 6 — CONFIGURAR SUDO PARA USUARIOS DE AD
# Requisito: edicion automatica de /etc/sudoers.d/ad-admins
# ════════════════════════════════════════════════════════════════════════════
fn_info "Configurando permisos sudo para usuarios del dominio AD..."
SUDOERS_FILE="/etc/sudoers.d/ad-admins"

cat > "$SUDOERS_FILE" << 'EOF'
# Practica 08 — Permisos sudo para usuarios de Active Directory (redes.local)
# Generado automaticamente por p8_join_domain_mint.sh

# Grupo "Domain Admins" del dominio — acceso total
%domain\ admins ALL=(ALL:ALL) ALL

# Grupo G_Cuates — acceso sudo completo
%g_cuates   ALL=(ALL:ALL) ALL

# Grupo G_NoCuates — acceso sudo completo
%g_nocuates ALL=(ALL:ALL) ALL
EOF

# Permisos obligatorios para sudoers (0440 = r--r-----)
chmod 0440 "$SUDOERS_FILE"

# Validar sintaxis con visudo
if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
    fn_ok "Sudoers configurado correctamente en $SUDOERS_FILE"
else
    fn_err "Sintaxis invalida en $SUDOERS_FILE. Revisalo manualmente."
fi

# ════════════════════════════════════════════════════════════════════════════
# RESUMEN FINAL
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
fn_ok "Configuracion completada. Esta maquina ahora pertenece a:"
fn_ok "  Dominio  : $DOMAIN"
fn_ok "  DC       : $DC_IP"
fn_ok "  Home dir : /home/%u@%d  (creado automaticamente en el login)"
fn_ok "  Sudo     : G_Cuates y G_NoCuates tienen acceso sudo"
echo ""
fn_info "Prueba de login con usuario de AD:"
fn_info "  ssh carlos.perez@$(hostname)"
fn_info "  o inicia sesion grafico como: carlos.perez"
fn_info "  Su home sera: /home/carlos.perez@redes.local"
echo ""
fn_info "IMPORTANTE: Reinicia la maquina para que todos los cambios surtan efecto."
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
