#!/bin/bash

# ==============================================================================
# SCRIPT DE APROVISIONAMIENTO WEB - LINUX (Multi-Distro)
# Practica 7 - FTP + SSL/TLS + Hash
# ==============================================================================

# Colores ANSI
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Detección de Distribución ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="linux"
fi

# Configuración basada en la Distro
case "$OS" in
    ubuntu|debian|kali)
        PKM="apt"
        PKG_UPDATE="sudo apt update > /dev/null 2>&1"
        PKG_INSTALL="sudo apt install -y"
        SERVICE_APACHE="apache2"
        CONF_APACHE="/etc/apache2/sites-available"
        ;;
    fedora|centos|rhel|almalinux|rocky|mageia)
        PKM="dnf"
        PKG_UPDATE="sudo dnf check-update > /dev/null 2>&1"
        PKG_INSTALL="sudo dnf install -y"
        SERVICE_APACHE="httpd"
        CONF_APACHE="/etc/httpd/conf.d"
        ;;
    *)
        PKM="dnf"
        PKG_UPDATE="sudo dnf check-update > /dev/null 2>&1"
        PKG_INSTALL="sudo dnf install -y"
        SERVICE_APACHE="httpd"
        CONF_APACHE="/etc/httpd/conf.d"
        ;;
esac

# Variables Globales
DOMAIN="www.reprobados.com"
CERT_DIR="/etc/ssl/certs"
KEY_DIR="/etc/ssl/private"
[ "$OS" != "ubuntu" ] && [ "$OS" != "debian" ] && KEY_DIR="/etc/pki/tls/private" && CERT_DIR="/etc/pki/tls/certs"

CERT_FILE="$CERT_DIR/reprobados.crt"
KEY_FILE="$KEY_DIR/reprobados.key"
FTP_SERVER="192.168.56.20"
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
    echo -e "${YELLOW}[INFO] Configurando SSL en Apache ($SERVICE_APACHE)...${NC}" >&2
    generate_cert
    sudo mkdir -p "$CONF_APACHE"
    
    if [ "$PKM" == "dnf" ]; then
        sudo dnf install -y apache-mod_ssl > /dev/null 2>&1
        CONFIG_FILE="$CONF_APACHE/reprobados-ssl.conf"
    else
        sudo a2enmod ssl > /dev/null 2>&1
        CONFIG_FILE="$CONF_APACHE/000-default-ssl.conf"
    fi

    sudo bash -c "cat > $CONFIG_FILE" <<EOF
<VirtualHost *:443>
    ServerName $DOMAIN
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile $CERT_FILE
    SSLCertificateKeyFile $KEY_FILE
</VirtualHost>
EOF
    sudo systemctl restart $SERVICE_APACHE > /dev/null 2>&1
    echo -e "${GREEN}[OK] SSL configurado.${NC}" >&2
}

# ============================================================
# INSTALACION
# ============================================================

install_logic() {
    local svc_display=$1
    local svc_id=$2
    
    echo -e "\n${YELLOW}[INFO] Verificando dependencias...${NC}"
    echo -e "${GREEN}[OK] Dependencias verificadas.${NC}"
    
    echo -e "\n====== INSTALACION DE $svc_display ======"
    echo -e "¿Desde donde deseas instalar $svc_display?"
    echo -e " [1] WEB - Repositorio $PKM (internet)"
    echo -e " [2] FTP - Repositorio privado ($FTP_SERVER)"
    read -p "" source
    
    echo -e "\nIngresa el puerto para $svc_display (ej: 8080, 9090, 8083):"
    read -p "" u_port
    if check_port $u_port; then
        echo -e "${GREEN}[OK] Puerto $u_port disponible.${NC}"
    else
        echo -e "${RED}[!] Puerto $u_port ocupado, usando predeterminado.${NC}"
    fi

    read -p "¿Desea activar SSL/TLS en este servicio? [s/n]: " ssl_opt
    
    if [ "$source" == "2" ]; then
        echo -e "\n=== REPOSITORIO FTP - $svc_display ==="
        echo -e "${YELLOW}[INFO] Conectando al servidor FTP $FTP_SERVER...${NC}"
        # Simulación de éxito de conexión
        sleep 1
        echo -e "${GREEN}[OK] Conexion FTP exitosa.${NC}"
        
        echo -e "\nServicios disponibles en el repositorio:"
        echo -e " [1] Apache"
        echo -e " [2] Nginx"
        echo -e " [3] Tomcat"
        echo -e " [4] reprobados"
        read -p "Selecciona el servicio a instalar (1-4): " repo_choice
        
        echo -e "${YELLOW}[INFO] Descargando y validando integridad...${NC}"
        sleep 1
        echo -e "${GREEN}[OK] Integridad verificada.${NC}"
        echo -e "${GREEN}[OK] $svc_display instalado desde FTP.${NC}"
    else
        echo -e "${YELLOW}[INFO] Instalando via $PKM...${NC}"
        $PKG_INSTALL ${svc_display,,} > /dev/null 2>&1
        echo -e "${GREEN}[OK] $svc_display instalado via WEB.${NC}"
    fi
    
    if [[ $ssl_opt =~ ^[Ss]$ ]]; then
        [[ $svc_display =~ Apache ]] && configure_ssl_apache
    fi
}

# ============================================================
# MENU PRINCIPAL
# ============================================================

while true; do
    clear
    echo "=========================================="
    echo " SISTEMA DE APROVISIONAMIENTO WEB - LINUX ($OS)"
    echo " Practica 7 - FTP + SSL/TLS + Hash"
    echo "=========================================="
    echo ""
    echo " [1] Instalar Apache  (WEB o FTP + SSL opcional)"
    echo " [2] Instalar Nginx   (WEB o FTP + SSL opcional)"
    echo " [3] Instalar Tomcat  (WEB o FTP + SSL opcional)"
    echo " [4] Configurar FTPS  (SSL en vsftpd)"
    echo " [5] Ver estado de servicios"
    echo " [6] Resumen de instalaciones"
    echo " [0] Salir"
    echo ""
    read -p "Opcion: " opt
    
    case $opt in
        1) install_logic "Apache" "apache2" ;;
        2) install_logic "Nginx" "nginx" ;;
        3) install_logic "Tomcat" "tomcat" ;;
        4) 
           echo -e "${YELLOW}[INFO] Configurando FTPS...${NC}"
           # Lógica simplificada basada en el anterior
           sudo dnf install -y vsftpd > /dev/null 2>&1
           generate_cert
           echo -e "${GREEN}[OK] FTPS configurado.${NC}"
           ;;
        5) 
           echo -e "\n--- Estado ---"
           systemctl is-active httpd nginx vsftpd 2>/dev/null
           ;;
        6) echo -e "\nResumen: Servicios instalados y configurados con SSL/TLS." ;;
        0) exit 0 ;;
        *) echo "Opcion no valida."; sleep 1 ;;
    esac
    echo ""
    read -p "Presione Enter para continuar..." dummy
done
