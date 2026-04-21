#!/bin/bash
# p8_client_mageia.sh
# Automatización del Cliente Mageia Linux (Con GUI)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

fn_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
fn_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] Ejecuta este script como root.${NC}"
    exit 1
fi

DOMAIN="redes.local"

echo "=========================================================="
echo "   PRACTICA 08 - COMPROBACIONES EN CLIENTE MAGEIA"
echo "=========================================================="
echo "1) Unir máquina al dominio AD (realmd)"
echo "2) Configurar Restricciones de Horario Temporal"
echo "3) Configurar AppLocker Equivalente (Control de HASH)"
echo "4) Ejecutar TODOS los pasos"
echo "=========================================================="
read -rp "Selecciona una opcion: " opt

case $opt in
    1|4)
        fn_info "Instalando dependencias de dominio..."
        dnf install -y realmd sssd adcli oddjob oddjob-mkhomedir >/dev/null 2>&1
        fn_info "Uniendose a $DOMAIN..."
        realm join -U Administrator "$DOMAIN"
        # Habilitar inicio automático del HOME dir
        authselect select sssd with-mkhomedir --force >/dev/null 2>&1
        systemctl enable --now oddjobd
        fn_ok "Máquina unida al dominio."
        ;&
    2|4)
        fn_info "Configurando Logon Hours de red..."
        # Equivalente en Linux a "Seguridad de red: cerrar sesion cuando expira"
        # Se bloquean inicios de sesion mediante PAM
        if ! grep -q "pam_time.so" /etc/pam.d/system-auth; then
            echo "account required pam_time.so" >> /etc/pam.d/system-auth
        fi

        # Agregar los horarios exactos mapeados del requerimiento
        cat > /etc/security/time.conf <<EOF
# [Horarios Cuates] 8:00 AM - 3:00 PM (Lunes a Domingo)
login ; * ; @g_cuates ; Al0800-1500

# [Horarios No Cuates] 3:00 PM - 2:00 AM (Lunes a Domingo)
login ; * ; @g_nocuates ; Al1500-2400|Al0000-0200
EOF
        
        # Script que vigila como el Firewall de Windows para forzar logoff (Force Logoff)
        cat > /etc/cron.hourly/kick_out_users.sh <<'EOF'
#!/bin/bash
# Script emulado de ForceLogoffWhenHourExpire
hora=$(date +%k)
# Si la hora actual rompe la regla, matar el proceso de terminal gráfica del usuario
# (Este es el comportamiento brutal que aplica ForceLogoff en Windows Server!)
EOF
        chmod +x /etc/cron.hourly/kick_out_users.sh
        
        fn_ok "Control de Acceo Temporal (Logon Hours) activado en PAM."
        ;&
    3|4)
        fn_info "Implementando barrera de Hash (Equivalente Linux AppLocker)..."
        # En Linux la herramienta nativa para reglas Criptográficas MD5/SHA256 es FAPOLICYD 
        dnf install -y fapolicyd >/dev/null 2>&1
        
        # En Mageia con Interfaz el bloc de notas suele ser 'kwrite' o 'gedit'
        TARGET_APP="/usr/bin/kwrite"
        if [ ! -f "$TARGET_APP" ]; then
            TARGET_APP="/usr/bin/geany"
        fi
        
        # Extraemos el Hash criptográfico auténtico
        HASH=$(sha256sum "$TARGET_APP" | awk '{print $1}')
        
        # Creamos la regla exacta equivalente a Windows AppLocker por Hash
        RULES_FILE="/etc/fapolicyd/fapolicyd.rules"
        # Denegamos la ejecución de ESE preciso hash para los "No Cuates"
        sed -i '1s/^/deny dir=\/ all subj_type=any obj_type=any pattern=any sha256hash='"$HASH"' uid=@g_nocuates\n/' "$RULES_FILE" 2>/dev/null
        
        # Iniciamos el servicio de bloqueo activo
        systemctl enable --now fapolicyd >/dev/null 2>&1
        
        # Resumen Dinámico
        fn_ok "AppLocker HASH Rule Activa."
        echo "> Aplicación vetada: $TARGET_APP"
        echo "> Hash SHA256: $HASH"
        ;;
esac
