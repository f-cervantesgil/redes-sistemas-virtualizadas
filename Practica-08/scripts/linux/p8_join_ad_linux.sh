#!/bin/bash
# p8_join_ad_linux.sh
# Script para unir cliente Linux al dominio Active Directory (Practica 08)
# Requisitos cubiertos:
#   - Instala: realmd, sssd, adcli
#   - Configura /etc/sssd/sssd.conf (fallback_homedir = /home/%u@%d)
#   - Crea /etc/sudoers.d/ad-admins con permisos para usuarios AD

# ─── Colores ───────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

fn_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
fn_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
fn_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── Verificar root ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fn_err "Este script debe ejecutarse como root: sudo $0"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. INSTALAR DEPENDENCIAS
#    Requisito: instalar realmd, sssd y adcli
# ─────────────────────────────────────────────────────────────────────────────
fn_install_deps() {
    fn_info "Instalando dependencias: realmd, sssd, adcli..."
    if [ -f /etc/debian_version ]; then
        # Debian / Ubuntu
        apt-get update -qq
        apt-get install -y realmd sssd sssd-tools adcli \
            samba-common-bin packagekit libpam-sss libnss-sss krb5-user
    elif [ -f /etc/redhat-release ]; then
        # RHEL / CentOS / AlmaLinux
        yum install -y realmd sssd adcli samba-common-tools \
            oddjob oddjob-mkhomedir authselect-compat krb5-workstation
    else
        fn_err "Distribucion no soportada. Instala realmd y sssd manualmente."
        exit 1
    fi
    fn_ok "Dependencias instaladas."
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. UNIR AL DOMINIO con realm join
#    Requisito: usar realmd + adcli para la union
# ─────────────────────────────────────────────────────────────────────────────
fn_join_domain() {
    read -rp "Nombre del dominio AD (ej: redes.local): " DOMAIN
    read -rp "Usuario Administrador del dominio (ej: Administrator): " ADMIN_USER

    fn_info "Descubriendo dominio '$DOMAIN'..."
    realm discover "$DOMAIN"

    fn_info "Uniendose al dominio '$DOMAIN' como '$ADMIN_USER'..."
    realm join "$DOMAIN" -U "$ADMIN_USER" --install=/

    if [ $? -eq 0 ]; then
        fn_ok "Union al dominio '$DOMAIN' exitosa."
    else
        fn_err "Fallo la union al dominio. Verifica conectividad DNS y credenciales."
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. CONFIGURAR /etc/sssd/sssd.conf
#    Requisito: fallback_homedir = /home/%u@%d
# ─────────────────────────────────────────────────────────────────────────────
fn_config_sssd() {
    fn_info "Configurando /etc/sssd/sssd.conf..."
    SSSD_CONF="/etc/sssd/sssd.conf"

    if [ ! -f "$SSSD_CONF" ]; then
        fn_err "No se encontro $SSSD_CONF. Verifica que realm join se haya completado correctamente."
        exit 1
    fi

    # ── fallback_homedir ─────────────────────────────────────────────────────
    # Si la linea ya existe, reemplazarla; si no, agregarla en la seccion [domain/...]
    if grep -q "fallback_homedir" "$SSSD_CONF"; then
        sed -i 's|^fallback_homedir\s*=.*|fallback_homedir = /home/%u@%d|' "$SSSD_CONF"
        fn_ok "fallback_homedir actualizado a /home/%u@%d"
    else
        # Agregar despues de la primera linea [domain/...] o al final del archivo
        sed -i "/^\[domain\//a fallback_homedir = /home/%u@%d" "$SSSD_CONF"
        fn_ok "fallback_homedir = /home/%u@%d agregado al archivo."
    fi

    # ── use_fully_qualified_names ─────────────────────────────────────────
    # Permitir nombres cortos (sin @dominio) para mayor comodidad (opcional)
    if grep -q "use_fully_qualified_names" "$SSSD_CONF"; then
        sed -i 's/^use_fully_qualified_names\s*=.*/use_fully_qualified_names = False/' "$SSSD_CONF"
    else
        sed -i "/^\[domain\//a use_fully_qualified_names = False" "$SSSD_CONF"
    fi

    # ── Permisos correctos del archivo (sssd requiere 0600) ──────────────
    chmod 0600 "$SSSD_CONF"
    chown root:root "$SSSD_CONF"

    systemctl restart sssd
    fn_ok "sssd reiniciado con la nueva configuracion."
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CONFIGURAR SUDOERS para usuarios de AD
#    Requisito: edicion automatica de /etc/sudoers.d/ad-admins
# ─────────────────────────────────────────────────────────────────────────────
fn_config_sudo() {
    fn_info "Configurando privilegios sudo para usuarios de AD..."
    SUDO_FILE="/etc/sudoers.d/ad-admins"

    # Validar que visudo este disponible para verificar sintaxis
    cat > "$SUDO_FILE" <<'EOF'
# Practica 08 — Permisos sudo para usuarios de Active Directory
# Modificado automaticamente por p8_join_ad_linux.sh

# Administradores del dominio (Group "Domain Admins")
%domain\ admins ALL=(ALL:ALL) ALL

# Grupos especificos de la practica
%G_Cuates   ALL=(ALL:ALL) ALL
%G_NoCuates ALL=(ALL:ALL) ALL
EOF

    # Permisos estrictos requeridos por sudo (0440 = r--r-----)
    chmod 0440 "$SUDO_FILE"

    # Verificar sintaxis con visudo
    if visudo -c -f "$SUDO_FILE" &>/dev/null; then
        fn_ok "Sudoers configurado correctamente en $SUDO_FILE"
    else
        fn_err "Sintaxis invalida en $SUDO_FILE. Revisa el archivo manualmente."
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. HABILITAR CREACION AUTOMATICA DE HOME (/home/%u@%d)
# ─────────────────────────────────────────────────────────────────────────────
fn_enable_mkhomedir() {
    fn_info "Habilitando creacion automatica de directorio home para usuarios AD..."
    if [ -f /etc/debian_version ]; then
        pam-auth-update --enable mkhomedir 2>/dev/null || \
            echo "session required pam_mkhomedir.so skel=/etc/skel umask=0077" >> /etc/pam.d/common-session
    elif [ -f /etc/redhat-release ]; then
        authselect select sssd with-mkhomedir --force 2>/dev/null || \
            echo "session optional pam_oddjob_mkhomedir.so" >> /etc/pam.d/system-auth
        systemctl enable --now oddjobd 2>/dev/null || true
    fi
    fn_ok "Creacion de home directory habilitada."
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   UNION A DOMINIO AD — Practica 08 (Linux)      ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""

fn_install_deps
fn_join_domain
fn_config_sssd
fn_config_sudo
fn_enable_mkhomedir

echo ""
fn_ok "Configuracion completa."
fn_info "Prueba con:  su - usuario@dominio  o  ssh usuario@$(hostname)"
fn_info "Directorio home sera: /home/usuario@dominio"
