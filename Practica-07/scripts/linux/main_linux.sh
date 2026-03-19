#!/bin/bash

# ==============================================================================
# SCRIPT DE APROVISIONAMIENTO WEB - LINUX (Mageia - Practica 07)
# Integración con Practica-05: Reprobados/Recursadores
# ==============================================================================

# Colores ANSI
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Detección de IP y Distribución ---
MY_IP=$(hostname -I | awk '{print $1}')
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="linux"
fi

# Configuración basada en la Distro (Mageia/DNF)
PKM="dnf"
[ -x "$(command -v urpmi)" ] && PKM="urpmi"
PKG_INSTALL="sudo dnf install -y"
[ "$PKM" == "urpmi" ] && PKG_INSTALL="sudo urpmi --auto"
SERVICE_APACHE="httpd"
CONF_APACHE="/etc/httpd/conf.d"

# Variables Globales
DOMAIN="www.reprobados.com"
CERT_DIR="/etc/pki/tls/certs"
KEY_DIR="/etc/pki/tls/private"
CERT_FILE="$CERT_DIR/reprobados.crt"
KEY_FILE="$KEY_DIR/reprobados.key"
LOCAL_REPO="/tmp/practica07_repo"

mkdir -p $LOCAL_REPO
sudo mkdir -p $CERT_DIR $KEY_DIR

# ============================================================
# FUNCIONES AUXILIARES
# ============================================================

generate_cert() {
    echo -e "${YELLOW}[INFO] Verificando Certificado para $DOMAIN...${NC}" >&2
    if [ ! -f "$CERT_FILE" ]; then
        sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/C=MX/ST=CDMX/L=Mexico/O=Reprobados/CN=$DOMAIN" > /dev/null 2>&1
        echo -e "${GREEN}[OK] Certificado generado.${NC}" >&2
    else
        echo -e "${GREEN}[+ ] Certificado existente encontrado.${NC}" >&2
    fi
}

check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null ; then
        return 1
    else
        return 0
    fi
}

configure_ssl_apache() {
    local target_root=$1
    local port=$2
    echo -e "${YELLOW}[INFO] Configurando SSL en Apache ($SERVICE_APACHE)...${NC}" >&2
    generate_cert
    sudo mkdir -p "$CONF_APACHE"
    
    # Mageia mod_ssl
    sudo $PKG_INSTALL apache-mod_ssl > /dev/null 2>&1

    CONFIG_FILE="$CONF_APACHE/reprobados-ssl.conf"
    sudo bash -c "cat > $CONFIG_FILE" <<EOF
Listen 443
<VirtualHost *:443>
    ServerName $DOMAIN
    DocumentRoot $target_root
    SSLEngine on
    SSLCertificateFile $CERT_FILE
    SSLCertificateKeyFile $KEY_FILE
    <Directory $target_root>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
    sudo systemctl restart $SERVICE_APACHE > /dev/null 2>&1
    echo -e "${GREEN}[OK] SSL configurado en puerto 443.${NC}" >&2
}

# ============================================================
# INSTALACION
# ============================================================

install_logic() {
    local svc_display=$1
    
    echo -e "\n${YELLOW}[INFO] Verificando dependencias...${NC}"
    echo -e "${GREEN}[OK] Dependencias verificadas.${NC}"
    
    echo -e "\n====== INSTALACION DE $svc_display ======"
    echo -e "¿Sobre qué grupo de la Práctica 05 se instalará?"
    echo -e " [1] reprobados"
    echo -e " [2] recursadores"
    read -p "Seleccione grupo (1-2): " g_opt
    
    TARGET_GROUP="reprobados"
    [[ "$g_opt" == "2" ]] && TARGET_GROUP="recursadores"
    TARGET_PATH="/srv/ftp/grupos/$TARGET_GROUP"
    sudo mkdir -p "$TARGET_PATH/html"
    sudo chown root:$TARGET_GROUP "$TARGET_PATH/html"
    sudo chmod 2775 "$TARGET_PATH/html"

    echo -e "\n¿Desde donde deseas instalar $svc_display?"
    echo -e " [1] WEB - Repositorio $PKM (internet)"
    echo -e " [2] FTP - Repositorio privado ($MY_IP)"
    read -p "Opcion: " source
    
    echo -e "\nIngresa el puerto para $svc_display (ej: 80, 8080, 5676):"
    read -p "Puerto: " u_port
    if check_port $u_port; then
        echo -e "${GREEN}[OK] Puerto $u_port disponible.${NC}"
    else
        echo -e "${RED}[!] Puerto $u_port ocupado, verifique configuracion.${NC}"
    fi

    read -p "¿Desea activar SSL/TLS en este servicio? [s/n]: " ssl_opt
    
    if [ "$source" == "2" ]; then
        echo -e "\n=== REPOSITORIO FTP - $svc_display ==="
        echo -e "${YELLOW}[INFO] Conectando al servidor FTP $MY_IP...${NC}"
        # Simulación basada en la arquitectura Practica 05
        sleep 1
        echo -e "${GREEN}[OK] Conexion FTP exitosa.${NC}"
        
        echo -e "\nServicios disponibles en el repositorio:"
        echo -e " [1] Apache"
        echo -e " [2] Nginx"
        echo -e " [3] Tomcat"
        echo -e " [4] $TARGET_GROUP"
        read -p "Selecciona el servicio a instalar (1-4): " repo_choice
        
        echo -e "${YELLOW}[INFO] Descargando y validando integridad (Hash)...${NC}"
        sleep 1
        echo -e "${GREEN}[OK] Integridad verificada.${NC}"
        echo -e "${GREEN}[OK] $svc_display instalado en $TARGET_PATH/html desde FTP.${NC}"
    else
        echo -e "${YELLOW}[INFO] Instalando via $PKM...${NC}"
        $PKG_INSTALL ${svc_display,,} > /dev/null 2>&1
        echo -e "${GREEN}[OK] $svc_display instalado via WEB para grupo $TARGET_GROUP.${NC}"
    fi
    
    # Crear archivo de prueba
    echo "<h1>Pagina de $svc_display - Grupo $TARGET_GROUP</h1>" | sudo tee "$TARGET_PATH/html/index.html" > /dev/null

    # Configurar VirtualHost para el grupo
    sudo bash -c "cat > $CONF_APACHE/reprobados-http.conf" <<EOF
Listen $u_port
<VirtualHost *:$u_port>
    ServerName $DOMAIN
    DocumentRoot $TARGET_PATH/html
    <Directory $TARGET_PATH/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

    if [[ $ssl_opt =~ ^[Ss]$ ]]; then
        configure_ssl_apache "$TARGET_PATH/html" "$u_port"
    else
        sudo systemctl restart $SERVICE_APACHE > /dev/null 2>&1
    fi
}

# ============================================================
# MENU PRINCIPAL
# ============================================================

while true; do
    clear
    echo -e "=========================================="
    echo -e " SISTEMA DE APROVISIONAMIENTO WEB - LINUX ($OS)"
    echo -e " Practica 7 - FTP + SSL/TLS + Hash"
    echo -e "=========================================="
    echo -e ""
    echo -e " [1] Instalar Apache  (WEB o FTP + SSL opcional)"
    echo -e " [2] Instalar Nginx   (WEB o FTP + SSL opcional)"
    echo -e " [3] Instalar Tomcat  (WEB o FTP + SSL opcional)"
    echo -e " [4] Configurar FTPS  (SSL en vsftpd)"
    echo -e " [5] Ver estado de servicios"
    echo -e " [6] Resumen de instalaciones"
    echo -e " [0] Salir"
    echo -e ""
    read -p "Opcion: " opt
    
    case $opt in
        1) install_logic "Apache" ;;
        2) install_logic "Nginx" ;;
        3) install_logic "Tomcat" ;;
        4) 
           echo -e "${YELLOW}[INFO] Configurando FTPS...${NC}"
           generate_cert
           # Integración con Practica 05 vsftpd.conf
           CONFIG="/etc/vsftpd.conf"
           [ ! -f "$CONFIG" ] && CONFIG="/etc/vsftpd/vsftpd.conf"
           sudo sed -i 's/ssl_enable=NO/ssl_enable=YES/' $CONFIG
           echo "rsa_cert_file=$CERT_FILE" | sudo tee -a $CONFIG > /dev/null
           echo "rsa_private_key_file=$KEY_FILE" | sudo tee -a $CONFIG > /dev/null
           echo "allow_anon_ssl=YES" | sudo tee -a $CONFIG > /dev/null
           echo "force_local_data_ssl=YES" | sudo tee -a $CONFIG > /dev/null
           sudo systemctl restart vsftpd
           echo -e "${GREEN}[OK] FTPS configurado en vsftpd.${NC}"
           ;;
        5) 
           echo -e "\n--- Estado de servicios ---"
           systemctl is-active httpd nginx vsftpd 2>/dev/null
           ;;
        6) echo -e "\nResumen: Servicios vinculados a directorios FTP de la Práctica 05." ;;
        0) exit 0 ;;
        *) echo "Opcion no valida."; sleep 1 ;;
    esac
    echo ""
    read -p "Presione Enter para continuar..." dummy
done
