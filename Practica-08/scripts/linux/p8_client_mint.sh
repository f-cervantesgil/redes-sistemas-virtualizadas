#!/bin/bash
# p8_client_mint.sh  —  Practica 08  —  Cliente Linux Mint (Ubuntu/Debian)
# Requisitos:
#   1) Union al dominio Active Directory (redes.local)
#   2) Logon Hours:  Cuates 08-15h  |  NoCuates 15-02h  +  Force Logoff
#   3) Bloqueo del editor de texto para G_NoCuates por Hash SHA-256 (fapolicyd) / Wrapper

# ─── Colores ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
fn_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
fn_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
fn_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
fn_sep()  { echo -e "${CYAN}----------------------------------------------------------${NC}"; }

[[ $EUID -ne 0 ]] && { fn_err "Ejecuta como root:  sudo bash $0"; exit 1; }

DOMAIN="redes.local"

echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   PRACTICA 08 — CLIENTE LINUX MINT (VERSION FINAL)  ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo " 1) Unir al dominio AD ($DOMAIN)"
echo " 2) Configurar Logon Hours + Force Logoff (Metodo Absoluto)"
echo " 3) Bloquear editor de texto a NoCuates (Metodo Infalible)"
echo " 4) Ejecutar TODOS los pasos"
echo ""
read -rp " Selecciona una opcion: " opt
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# PASO 1 — UNION AL DOMINIO
# ═══════════════════════════════════════════════════════════════════════════
fn_step1() {
    fn_sep
    fn_info "Saltando paso 1. (El dominio ya se unio usando el otro script)."
}

# ═══════════════════════════════════════════════════════════════════════════
# PASO 2 — LOGON HOURS + FORCE LOGOFF (METODO SCRIPT ABSOLUTO)
# pam_time a veces falla con los nombres del dominio (@redes.local).
# Moveremos el control al inicio de sesion exacto.
# ═══════════════════════════════════════════════════════════════════════════
fn_step2() {
    fn_sep
    fn_info "Configurando Logon Hours y Cierre Forzado..."

    # 1. Crear el script unificado de control de tiempo y expulsion
    SCRIPT_LOGOFF="/usr/local/bin/force_logoff_p8.sh"
    cat > "$SCRIPT_LOGOFF" << 'SCRIPT'
#!/bin/bash
# Comprobador y expulsor de sesiones.
HORA=$(date +%H)
MIN=$(date +%M)
HORAMIN=$((10#$HORA * 100 + 10#$MIN))

while IFS= read -r usuario; do
    [[ -z "$usuario" || "$usuario" == "root" || "$usuario" == "angel" ]] && continue

    grupos=$(id -Gn "$usuario" 2>/dev/null | tr '[:upper:]' '[:lower:]')

    # CUATES: 08:00 a 15:00
    if echo "$grupos" | grep -q "g_cuates"; then
        if [[ $HORAMIN -lt 800 || $HORAMIN -ge 1500 ]]; then
            pkill -KILL -u "$usuario" 2>/dev/null
        fi
    fi

    # NOCUATES: 15:00 a 02:00
    if echo "$grupos" | grep -q "g_nocuates"; then
        if [[ $HORAMIN -ge 201 && $HORAMIN -lt 1500 ]]; then
            pkill -KILL -u "$usuario" 2>/dev/null
        fi
    fi
done < <(who | awk '{print $1}' | sort -u)
SCRIPT
    chmod +x "$SCRIPT_LOGOFF"

    # 2. Programar expulsion cada minuto en CRON
    CRON_ENTRY="* * * * * root $SCRIPT_LOGOFF"
    sed -i '/force_logoff_p8/d' /etc/crontab
    echo "$CRON_ENTRY" >> /etc/crontab

    # 3. Validar al INICIAR SESION (Bloquear login)
    SCRIPT_LOGIN="/usr/local/bin/login_hours_check.sh"
    cat > "$SCRIPT_LOGIN" << 'SCRIPT2'
#!/bin/bash
# Bloquea el login en tiempo real
usuario=$PAM_USER
[[ "$usuario" == "root" || "$usuario" == "angel" ]] && exit 0

grupos=$(id -Gn "$usuario" 2>/dev/null | tr '[:upper:]' '[:lower:]')
HORA=$(date +%H)
MIN=$(date +%M)
HORAMIN=$((10#$HORA * 100 + 10#$MIN))

if echo "$grupos" | grep -q "g_cuates"; then
    if [[ $HORAMIN -lt 800 || $HORAMIN -ge 1500 ]]; then
        exit 1 # Denegado
    fi
fi

if echo "$grupos" | grep -q "g_nocuates"; then
    if [[ $HORAMIN -ge 201 && $HORAMIN -lt 1500 ]]; then
        exit 1 # Denegado
    fi
fi

exit 0 # Permitido
SCRIPT2
    chmod +x "$SCRIPT_LOGIN"

    # Activar la barrera de tiempo real en lightdm y su
    PAM_AUTH="/etc/pam.d/common-auth"
    sed -i '/login_hours_check/d' "$PAM_AUTH"
    echo "auth required pam_exec.so quiet $SCRIPT_LOGIN" >> "$PAM_AUTH"

    fn_ok "Logon Hours absoluto activado."
    fn_info "Cuates: 08:00 a 15:00"
    fn_info "NoCuates: 15:00 a 02:00"
}

# ═══════════════════════════════════════════════════════════════════════════
# PASO 3 — BLOQUEO DEL EDITOR (WRAPPER INFALIBLE)
# Fapolicyd puede congelar la interfaz grafica. Este wrapper intercepta
# la ejecucion de 'xed' directamente leyendo loss grupos de AD.
# ═══════════════════════════════════════════════════════════════════════════
fn_step3() {
    fn_sep
    fn_info "Instalando barrera de editor (XED) para NoCuates..."

    TARGET_APP="/usr/bin/xed"
    if [ ! -f "$TARGET_APP" ]; then
        fn_err "No se encontro 'xed'. ¿Seguro que es Linux Mint Tiena?"
        return
    fi

    REAL_BIN="/usr/bin/xed.real"
    # Mover el archivo original solo la primera vez
    if [ ! -f "$REAL_BIN" ]; then
        mv "$TARGET_APP" "$REAL_BIN"
    fi

    # Escribir script de bloqueo absoluto:
    # Usar grep SIN -w para que encuentre "nocuates" incluso dentro de "@redes.local"
    cat > "$TARGET_APP" << 'WRAPPER'
#!/bin/bash
usuario=$(whoami)
grupos=$(id -Gn "$usuario" 2>/dev/null | tr '[:upper:]' '[:lower:]')

# Si es NoCuate, denegar la ejecucion y matar
if echo "$grupos" | grep -q "g_nocuates"; then
    zenity --error --text="Politica de Seguridad: El grupo NoCuates tiene prohibido usar notas." 2>/dev/null || \
    echo "Bloqueado por Active Directory."
    exit 1
fi

# Si no esta prohibido, abrir el programa de verdad
exec /usr/bin/xed.real "$@"
WRAPPER

    chmod +x "$TARGET_APP"

    fn_ok "Bloqueo configurado."
    fn_ok " -> CUATES SI pueden abrir xed."
    fn_ok " -> NOCUATES seran rechazados al dar clic."
}

# ═══════════════════════════════════════════════════════════════════════════
# DISPATCHER
# ═══════════════════════════════════════════════════════════════════════════
case $opt in
    1) fn_step1 ;;
    2) fn_step2 ;;
    3) fn_step3 ;;
    4)
        fn_step2
        fn_step3
        ;;
    *) fn_err "Opcion invalida." ;;
esac

echo ""
fn_ok "Instalacion finalizada. ¡Haz las pruebas ahora!"
