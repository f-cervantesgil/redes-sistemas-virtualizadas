#!/bin/bash
# p8_client_mint.sh  —  Practica 08  —  Cliente Linux Mint (Ubuntu/Debian)
# Requisitos:
#   1) Union al dominio Active Directory (redes.local)
#   2) Logon Hours:  Cuates 08-15h  |  NoCuates 15-02h  +  Force Logoff
#   3) Bloqueo del editor de texto para G_NoCuates por Hash SHA-256 (fapolicyd)

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
echo "  ║   PRACTICA 08 — CLIENTE LINUX MINT                  ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo " 1) Unir al dominio AD ($DOMAIN)"
echo " 2) Configurar Logon Hours + Force Logoff"
echo " 3) Bloquear editor de texto a NoCuates (Hash SHA-256)"
echo " 4) Ejecutar TODOS los pasos"
echo ""
read -rp " Selecciona una opcion: " opt
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# PASO 1 — UNION AL DOMINIO
# ═══════════════════════════════════════════════════════════════════════════
fn_step1() {
    fn_sep
    fn_info "Instalando dependencias (realmd, sssd, adcli, samba-common)..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        realmd sssd sssd-tools adcli \
        samba-common-bin packagekit \
        libpam-sss libnss-sss \
        oddjob oddjob-mkhomedir \
        krb5-user 2>/dev/null
    fn_ok "Paquetes instalados."

    fn_info "Descubriendo dominio $DOMAIN ..."
    realm discover "$DOMAIN" || { fn_err "No se encontro el dominio. Verifica DNS (debe apuntar al servidor AD)."; exit 1; }

    read -rp " Usuario administrador del dominio (ej: Administrator): " AD_USER
    realm join "$DOMAIN" -U "$AD_USER" || { fn_err "Fallo la union al dominio."; exit 1; }
    fn_ok "Union al dominio exitosa."

    # Permitir inicio de sesion sin @dominio
    sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' /etc/sssd/sssd.conf 2>/dev/null

    # Crear directorio HOME automaticamente en primer login
    pam-auth-update --enable mkhomedir 2>/dev/null || \
        echo "session required pam_mkhomedir.so skel=/etc/skel umask=0022" >> /etc/pam.d/common-session

    systemctl restart sssd
    fn_ok "sssd configurado. Prueba: id usuario@$DOMAIN"
}

# ═══════════════════════════════════════════════════════════════════════════
# PASO 2 — LOGON HOURS (pam_time) + FORCE LOGOFF (cron)
#
#   Cuates    :  08:00 – 15:00  (solo pueden entrar de 8 AM a 3 PM)
#   NoCuates  :  15:00 – 02:00  (solo pueden entrar de 3 PM a 2 AM)
#
# NOTA CRITICA de pam_time:
#   - El formato es:  servicio ; tty ; usuarios/grupos ; horario
#   - Los grupos se escriben con  @nombre  (sin dominio)
#   - La regla NIEGA el acceso FUERA del horario indicado
# ═══════════════════════════════════════════════════════════════════════════
fn_step2() {
    fn_sep
    fn_info "Configurando pam_time (Logon Hours)..."

    # Habilitar pam_time en el archivo de cuentas de Linux Mint (common-account)
    PAM_ACCOUNT="/etc/pam.d/common-account"
    if ! grep -q "pam_time.so" "$PAM_ACCOUNT"; then
        # Insertar ANTES de la linea "account [default=bad]..." para garantizar orden
        sed -i '/^account\s/i account  required  pam_time.so' "$PAM_ACCOUNT"
        fn_ok "pam_time.so habilitado en $PAM_ACCOUNT"
    else
        fn_ok "pam_time.so ya estaba presente."
    fi

    # NOTA: En pam_time, los grupos de AD llegados via sssd tienen nombres en minuscula
    # Verificar los grupos reales con: getent group | grep -i cuates
    CUATES_GROUP=$(getent group | grep -i "g_cuates" | grep -v "no" | head -1 | cut -d: -f1)
    NOCUATES_GROUP=$(getent group | grep -i "g_nocuates" | head -1 | cut -d: -f1)

    # Si sssd aun no resolvio los grupos, usar nombres por defecto en minuscula
    CUATES_GROUP=${CUATES_GROUP:-"g_cuates"}
    NOCUATES_GROUP=${NOCUATES_GROUP:-"g_nocuates"}

    fn_info "Grupo Cuates detectado   : $CUATES_GROUP"
    fn_info "Grupo NoCuates detectado : $NOCUATES_GROUP"

    # Escribir reglas de tiempo
    # FORMATO pam_time:  servicio;tty;usuario_o_grupo;dia+hora-hora
    #   Al = All days (todos los dias)
    #   @grupo = miembros del grupo
    #   El rango indica CUANDO se PERMITE el acceso
    cat > /etc/security/time.conf << EOF
# Practica 08 — Logon Hours por grupo de Active Directory
# Generado automaticamente por p8_client_mint.sh

# Cuates: permitir acceso de 08:00 a 15:00 todos los dias
*  ;  *  ;  @${CUATES_GROUP}    ;  Al0800-1500

# NoCuates: permitir acceso de 15:00 a 02:00 (cruza medianoche)
*  ;  *  ;  @${NOCUATES_GROUP}  ;  Al1500-2359|Al0000-0200
EOF
    fn_ok "Reglas escritas en /etc/security/time.conf"
    fn_info "Cuates   -> Permitido: 08:00-15:00"
    fn_info "NoCuates -> Permitido: 15:00-02:00"

    # ── FORCE LOGOFF: script que verifica cada minuto y expulsa sesiones vencidas ──
    cat > /usr/local/bin/force_logoff_p8.sh << 'SCRIPT'
#!/bin/bash
# force_logoff_p8.sh — Equivalente a ForceLogoffWhenHourExpire (Windows)
# Expulsa sesiones activas cuando el usuario esta fuera de su horario permitido

HORA=$(date +%H)   # Hora actual 00-23
MIN=$(date +%M)    # Minutos actuales
HORAMIN=$((10#$HORA * 100 + 10#$MIN))  # HMM numerico, ej: 1523

log() { logger -t "force_logoff_p8" "$1"; }

while IFS= read -r usuario; do
    [[ -z "$usuario" || "$usuario" == "root" ]] && continue

    grupos=$(id -Gn "$usuario" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr ' ' '\n')

    # ── CUATES: permitido 0800-1500 ─────────────────────────────────────
    if echo "$grupos" | grep -qw "g_cuates"; then
        if [[ $HORAMIN -lt 800 || $HORAMIN -ge 1500 ]]; then
            log "Expulsando $usuario (Cuates) a las $HORA:$MIN — fuera de horario 08:00-15:00"
            pkill -KILL -u "$usuario" 2>/dev/null
        fi
    fi

    # ── NOCUATES: permitido 1500-2359 y 0000-0200 ───────────────────────
    if echo "$grupos" | grep -qw "g_nocuates"; then
        # Bloqueado de 02:01 a 14:59
        if [[ $HORAMIN -ge 201 && $HORAMIN -lt 1500 ]]; then
            log "Expulsando $usuario (NoCuates) a las $HORA:$MIN — fuera de horario 15:00-02:00"
            pkill -KILL -u "$usuario" 2>/dev/null
        fi
    fi

done < <(who | awk '{print $1}' | sort -u)
SCRIPT

    chmod +x /usr/local/bin/force_logoff_p8.sh

    # Registrar en cron del sistema (cada minuto)
    CRON_ENTRY="* * * * * root /usr/local/bin/force_logoff_p8.sh"
    if ! grep -q "force_logoff_p8" /etc/crontab; then
        echo "$CRON_ENTRY" >> /etc/crontab
        fn_ok "Force Logoff registrado en /etc/crontab (cada minuto)."
    else
        # Actualizar la entrada existente
        sed -i '/force_logoff_p8/d' /etc/crontab
        echo "$CRON_ENTRY" >> /etc/crontab
        fn_ok "Force Logoff actualizado en /etc/crontab."
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PASO 3 — BLOQUEO POR HASH (fapolicyd) = AppLocker
#   G_Cuates   : puede abrir el editor de texto (xed / gedit)
#   G_NoCuates : BLOQUEADO por huella SHA-256 (imposible evadir renombrando)
# ═══════════════════════════════════════════════════════════════════════════
fn_step3() {
    fn_sep
    fn_info "Instalando fapolicyd (equivalente AppLocker en Linux)..."
    apt-get install -y fapolicyd 2>/dev/null || {
        fn_err "fapolicyd no disponible en este sistema. Usando alternativa con wrapper."
        fn_step3_wrapper
        return
    }

    # Detectar editor de texto nativo de Linux Mint
    TARGET_APP=""
    for editor in /usr/bin/xed /usr/bin/gedit /usr/bin/mousepad /usr/bin/geany /usr/bin/nano; do
        if [ -f "$editor" ]; then
            TARGET_APP="$editor"
            break
        fi
    done

    if [ -z "$TARGET_APP" ]; then
        fn_err "No se encontro editor de texto. Instala xed: apt install xed"
        return 1
    fi
    fn_info "Editor detectado: $TARGET_APP"

    # Calcular Hash SHA-256 real del editor (igual que Windows extrae el Hash de notepad.exe)
    HASH=$(sha256sum "$TARGET_APP" | awk '{print $1}')
    fn_info "Hash SHA-256: $HASH"

    # Obtener GID real del grupo G_NoCuates desde AD (via sssd)
    NOCUATES_GID=$(getent group 2>/dev/null | grep -i "^g_nocuates:" | cut -d: -f3)
    if [ -z "$NOCUATES_GID" ]; then
        fn_err "No se encontro g_nocuates en el sistema. Une la maquina al dominio primero (Paso 1)."
        return 1
    fi
    fn_info "GID de g_nocuates: $NOCUATES_GID"

    # Crear directorio de reglas y escribir regla de bloqueo
    mkdir -p /etc/fapolicyd/rules.d
    cat > /etc/fapolicyd/rules.d/10-practica08.rules << EOF
# Practica 08 — Bloqueo por Hash SHA-256 (equivalente AppLocker por Hash)
# Bloquea el editor "$TARGET_APP" para G_NoCuates aunque cambien el nombre del archivo

deny_audit perm=execute gid=$NOCUATES_GID trust=0 : sha256hash=$HASH

# Permitir todo lo demas
allow perm=any all : all
EOF

    # Reconstruir base de datos de confianza y arrancar el servicio
    fapolicyd-cli --update 2>/dev/null || true
    systemctl enable --now fapolicyd
    systemctl restart fapolicyd

    fn_ok "Regla de Hash activa via fapolicyd."
    fn_ok "  Aplicacion vetada para NoCuates : $TARGET_APP"
    fn_ok "  Hash SHA-256                     : $HASH"
    fn_ok "  Cuates pueden abrir $TARGET_APP sin restriccion."
}

# Alternativa si fapolicyd no esta disponible: wrapper que bloquea via script
fn_step3_wrapper() {
    fn_info "Instalando bloqueo alternativo mediante wrapper de shell..."
    TARGET_APP=""
    for editor in /usr/bin/xed /usr/bin/gedit /usr/bin/mousepad; do
        [ -f "$editor" ] && { TARGET_APP="$editor"; break; }
    done
    [ -z "$TARGET_APP" ] && { fn_err "No se encontro editor."; return 1; }

    REAL_BIN="${TARGET_APP}.real"
    # Solo mover si no se ha movido antes
    if [ ! -f "$REAL_BIN" ]; then
        mv "$TARGET_APP" "$REAL_BIN"
    fi

    NOCUATES_GROUP=$(getent group | grep -i "^g_nocuates:" | cut -d: -f1)
    NOCUATES_GROUP=${NOCUATES_GROUP:-"g_nocuates"}

    cat > "$TARGET_APP" << WRAPPER
#!/bin/bash
usuario=\$(whoami)
grupos=\$(id -Gn "\$usuario" 2>/dev/null | tr '[:upper:]' '[:lower:]')
if echo "\$grupos" | grep -qw "${NOCUATES_GROUP}"; then
    zenity --error --text="Esta aplicacion ha sido bloqueada por el administrador." 2>/dev/null || \
    echo "ERROR: Aplicacion bloqueada para el grupo NoCuates." >&2
    exit 1
fi
exec "${REAL_BIN}" "\$@"
WRAPPER
    chmod +x "$TARGET_APP"
    fn_ok "Wrapper de bloqueo instalado. NoCuates no pueden abrir $TARGET_APP."
}

# ═══════════════════════════════════════════════════════════════════════════
# DISPATCHER
# ═══════════════════════════════════════════════════════════════════════════
case $opt in
    1) fn_step1 ;;
    2) fn_step2 ;;
    3) fn_step3 ;;
    4)
        fn_step1
        fn_step2
        fn_step3
        ;;
    *)
        fn_err "Opcion invalida: $opt"
        exit 1
        ;;
esac

fn_sep
fn_ok "Script finalizado correctamente."
fn_info "Reinicia la maquina para que todos los cambios de PAM y sssd surtan efecto completo."
echo ""
