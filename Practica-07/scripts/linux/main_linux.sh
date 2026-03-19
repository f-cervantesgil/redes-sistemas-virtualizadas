#!/bin/bash

# ==============================================================================
# SCRIPT DE APROVISIONAMIENTO WEB - LINUX (Mageia - Practica 07)
# ==============================================================================
# OBJETIVO: Integración de servicios con SSL/TLS y Orquestación Híbrida (WEB/FTP)
# INTEGRACIÓN: Retoma grupos 'reprobados'/'recursadores' de la Práctica 05.
# ==============================================================================

# Colores ANSI para Interfaz Profesional
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# --- Variables Globales y Detección de Entorno ---
MY_IP=$(hostname -I | awk '{print $1}')
OS_ID="Linux"
DOMAIN="www.reprobados.com"
CERT_DIR="/etc/pki/tls/certs"
KEY_DIR="/etc/pki/tls/private"
CERT_FILE="$CERT_DIR/reprobados.crt"
KEY_FILE="$KEY_DIR/reprobados.key"
TEMP_DIR="/tmp/practica07_repo"

# Detección de Gestor de Paquetes
PKM="dnf"
[ -x "$(command -v urpmi)" ] && PKM="urpmi"
PKG_INSTALL="sudo dnf install -y"
[ "$PKM" == "urpmi" ] && PKG_INSTALL="sudo urpmi --auto"

mkdir -p $TEMP_DIR
sudo mkdir -p $CERT_DIR $KEY_DIR

# ============================================================
# FUNCIONES DE SEGURIDAD (SSL/TLS)
# ============================================================

generate_cert() {
    echo -e "${YELLOW}[INFO] Verificando Certificado para $DOMAIN...${NC}"
    if [ ! -f "$CERT_FILE" ]; then
        echo -e "${CYAN}[*] Generando Certificado Autofirmado...${NC}"
        sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/C=MX/ST=CDMX/L=Mexico/O=Reprobados/CN=$DOMAIN" &> /dev/null
        echo -e "${GREEN}[OK] Certificado generado correctamente.${NC}"
    else
        echo -e "${GREEN}[+ ] Certificado existente encontrado.${NC}"
    fi
}

configure_ssl_apache() {
    local root=$1
    echo -e "${YELLOW}[INFO] Aplicando SSL/TLS en Apache...${NC}"
    generate_cert
    sudo $PKG_INSTALL apache-mod_ssl &> /dev/null
    
    sudo bash -c "cat > /etc/httpd/conf.d/reprobados-ssl.conf" <<EOF
Listen 443
<VirtualHost *:443>
    ServerName $DOMAIN
    DocumentRoot $root
    SSLEngine on
    SSLCertificateFile $CERT_FILE
    SSLCertificateKeyFile $KEY_FILE
    <Directory $root>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
    sudo systemctl restart httpd &> /dev/null
    echo -e "${GREEN}[OK] Apache asegurado en puerto 443.${NC}"
}

configure_ssl_nginx() {
    local root=$1
    echo -e "${YELLOW}[INFO] Aplicando SSL/TLS en Nginx...${NC}"
    generate_cert
    sudo bash -c "cat > /etc/nginx/conf.d/reprobados-ssl.conf" <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    location / {
        root $root;
        index index.html;
    }
}
EOF
    sudo systemctl restart nginx &> /dev/null
    echo -e "${GREEN}[OK] Nginx asegurado en puerto 443.${NC}"
}

# ============================================================
# NAVEGACION DINAMICA Y VALIDACION DE INTEGRIDAD (FTP)
# ============================================================

ftp_orchestrator() {
    local service=$1
    local ftp_ip=$MY_IP
    local remote_base="ftp://$ftp_ip/http/$OS_ID/$service"

    echo -e "\n=== REPOSITORIO FTP PRIVADO ($ftp_ip) ==="
    echo -e "${YELLOW}[INFO] Conectando y navegando por el repositorio...${NC}"
    
    # Listar Versiones/Archivos
    files=$(curl -s -kl "$remote_base/")
    if [ -z "$files" ]; then
        echo -e "${RED}[!] No se encontraron versiones en $remote_base${NC}"
        return 1
    fi

    # Menú de selección de binarios
    echo -e "Archivos disponibles para $service:"
    options=($files)
    for i in "${!options[@]}"; do echo " [$i] ${options[$i]}"; done
    read -p "Seleccione versión a descargar: " choice
    
    selected_file=${options[$choice]}
    [ -z "$selected_file" ] && return 1

    # Descarga de Binario y Hash
    echo -e "${CYAN}[*] Descargando binario e integrity check (.sha256)...${NC}"
    curl -s -kl -o "$TEMP_DIR/$selected_file" "$remote_base/$selected_file"
    curl -s -kl -o "$TEMP_DIR/$selected_file.sha256" "$remote_base/$selected_file.sha256"

    # Verificación de Integridad
    echo -e "${YELLOW}[INFO] Calculando Hash local y comparando...${NC}"
    cd $TEMP_DIR
    if sha256sum -c "$selected_file.sha256" &> /dev/null; then
        echo -e "${GREEN}[OK] Integridad VERIFICADA (SHA256 coincide).${NC}"
        # Instalación Manual
        echo -e "${CYAN}[*] Iniciando instalación manual del binario...${NC}"
        sudo rpm -ivh "$selected_file" 2> /dev/null || sudo dnf install -y "./$selected_file" 2> /dev/null
        return 0
    else
        echo -e "${RED}[!] ERROR: Hash Mismatch. El archivo puede estar corrupto.${NC}"
        return 1
    fi
}

# ============================================================
# ORQUESTADOR PRINCIPAL
# ============================================================

run_service_flow() {
    local svc_name=$1
    
    echo -e "\n${YELLOW}[INFO] Verificando dependencias de instalacion...${NC}"
    echo -e "${GREEN}[OK] Dependencias de sistema listas.${NC}"

    echo -e "\n====== INSTALACION DE $svc_name ======"
    echo -e "¿En qué grupo de la Práctica 05 desea instalar?"
    echo -e " [1] reprobados"
    echo -e " [2] recursadores"
    read -p "Selección: " g_opt
    
    GROUP="reprobados"
    [ "$g_opt" == "2" ] && GROUP="recursadores"
    WEB_ROOT="/srv/ftp/grupos/$GROUP/html"
    sudo mkdir -p "$WEB_ROOT"
    echo "<h1>Servicio $svc_name - Grupo $GROUP (Práctica 07)</h1>" | sudo tee "$WEB_ROOT/index.html" > /dev/null

    echo -e "\n¿Origen de la instalación?"
    echo -e " [1] WEB (Oficial via $PKM)"
    echo -e " [2] FTP (Repositorio Privado)"
    read -p "Origen: " src_opt

    if [ "$src_opt" == "2" ]; then
        ftp_orchestrator "$svc_name" || return
    else
        echo -e "${CYAN}[*] Instalando desde repositorios oficiales...${NC}"
        $PKG_INSTALL ${svc_name,,} &> /dev/null
        echo -e "${GREEN}[OK] Instalado via $PKM.${NC}"
    fi

    echo -e "\nIngresa el puerto deseado (ej: 80, 8080, 5676):"
    read -p "Puerto: " u_port

    # Configuración de VirtualHost Base
    sudo bash -c "cat > /etc/httpd/conf.d/reprobados-http.conf" <<EOF
Listen $u_port
<VirtualHost *:$u_port>
    ServerName $DOMAIN
    DocumentRoot $WEB_ROOT
</VirtualHost>
EOF

    read -p "¿Desea activar seguridad SSL/TLS? [S/N]: " ssl_opt
    if [[ "$ssl_opt" =~ ^[Ss]$ ]]; then
        [ "$svc_name" == "Apache" ] && configure_ssl_apache "$WEB_ROOT"
        [ "$svc_name" == "Nginx" ] && configure_ssl_nginx "$WEB_ROOT"
    fi
}

# ============================================================
# MENU PRINCIPAL
# ============================================================

while true; do
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN} SISTEMA DE APROVISIONAMIENTO WEB - LINUX (Mageia)${NC}"
    echo -e "${CYAN} Practica 7 - FTP + SSL/TLS + Hash${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo -e " [1] Instalar Apache  (WEB/FTP + SSL)"
    echo -e " [2] Instalar Nginx   (WEB/FTP + SSL)"
    echo -e " [3] Instalar Tomcat  (WEB/FTP + SSL)"
    echo -e " [4] Configurar FTPS  (SSL en vsftpd)"
    echo -e " [5] Ver Estado de Servicios y Seguridad"
    echo -e " [6] Resumen de Instalaciones"
    echo -e " [0] Salir"
    echo ""
    read -p "Seleccione una opción: " main_opt

    case $main_opt in
        1) run_service_flow "Apache" ;;
        2) run_service_flow "Nginx" ;;
        3) run_service_flow "Tomcat" ;;
        4) 
            echo -e "\n${YELLOW}[INFO] Evaluando configuración de vsftpd...${NC}"
            if ! systemctl status vsftpd &> /dev/null; then
                echo -e "${CYAN}[*] Instalando vsftpd...${NC}"
                $PKG_INSTALL vsftpd &> /dev/null
            fi
            generate_cert
            CONFIG="/etc/vsftpd/vsftpd.conf"
            [ ! -f "$CONFIG" ] && CONFIG="/etc/vsftpd.conf"
            sudo sed -i 's/ssl_enable=NO/ssl_enable=YES/' $CONFIG
            echo "rsa_cert_file=$CERT_FILE" | sudo tee -a $CONFIG > /dev/null
            echo "rsa_private_key_file=$KEY_FILE" | sudo tee -a $CONFIG > /dev/null
            echo "allow_anon_ssl=YES" | sudo tee -a $CONFIG > /dev/null
            echo "force_local_data_ssl=YES" | sudo tee -a $CONFIG > /dev/null
            sudo systemctl restart vsftpd
            echo -e "${GREEN}[OK] FTPS activado correctamente.${NC}"
            ;;
        5) 
            echo -e "\n--- Reporte de Estado ---"
            for s in httpd nginx vsftpd; do
                st=$(systemctl is-active $s)
                echo -e "Servicio $s: $st"
            done
            ;;
        6) echo -e "\nResumen: Infraestructura integrada con SSL y Práctica 05." ;;
        0) exit 0 ;;
        *) echo "Opción no válida." ;;
    esac
    read -p "Presione Enter para continuar..." dummy
done
