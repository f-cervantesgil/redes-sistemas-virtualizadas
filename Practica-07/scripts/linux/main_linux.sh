#!/bin/bash

# ==============================================================================
# SCRIPT DE APROVISIONAMIENTO WEB - LINUX (Multi-Distro)
# Practica 7 - FTP + SSL/TLS + Hash
# ==============================================================================

# --- Detección de Distribución y Gestor de Paquetes ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
elif [ -f /etc/debian_version ]; then
    OS="debian"
else
    OS=$(uname -s)
fi

# Configuración basada en la Distro
case "$OS" in
    ubuntu|debian|kali)
        PKM="apt"
        PKG_UPDATE="sudo apt update"
        PKG_INSTALL="sudo apt install -y"
        SERVICE_APACHE="apache2"
        CONF_APACHE="/etc/apache2/sites-available"
        ENABLE_SSL_CMD="sudo a2enmod ssl && sudo a2enmod rewrite"
        ENABLE_SITE_CMD="sudo a2ensite"
        ;;
    fedora|centos|rhel|almalinux|rocky|mageia)
        PKM="dnf"
        [ "$OS" == "mageia" ] && PKM="dnf" || PKM="dnf"
        PKG_UPDATE="sudo $PKM check-update"
        PKG_INSTALL="sudo $PKM install -y"
        SERVICE_APACHE="httpd"
        CONF_APACHE="/etc/httpd/conf.d"
        ENABLE_SSL_CMD="sudo $PKM install -y apache-mod_ssl mod_ssl 2>/dev/null || sudo $PKM install -y mod_ssl"
        ENABLE_SITE_CMD="true"
        ;;
    *)
        echo "[!] Distribución no soportada automáticamente. Intentando modo genérico."
        PKM="apt"
        PKG_UPDATE="sudo apt update"
        PKG_INSTALL="sudo apt install -y"
        SERVICE_APACHE="apache2"
        CONF_APACHE="/etc/apache2/sites-available"
        ;;
esac

# Variables Globales
DOMAIN="www.reprobados.com"
CERT_DIR="/etc/ssl/certs"
KEY_DIR="/etc/ssl/private"
[ "$OS" != "ubuntu" ] && [ "$OS" != "debian" ] && KEY_DIR="/etc/pki/tls/private" && CERT_DIR="/etc/pki/tls/certs"

CERT_FILE="$CERT_DIR/reprobados.crt"
KEY_FILE="$KEY_DIR/reprobados.key"
FTP_SERVER="ftp://127.0.0.1"
LOCAL_REPO="/tmp/practica07_repo"

mkdir -p $LOCAL_REPO
sudo mkdir -p $CERT_DIR $KEY_DIR

# ============================================================
# FUNCIONES DE SEGURIDAD (SSL/TLS)
# ============================================================

generate_cert() {
    echo "[*] Verificando Certificado para $DOMAIN..."
    if [ ! -f "$CERT_FILE" ]; then
        echo "[+] Generando Certificado Autofirmado con OpenSSL..."
        sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/C=MX/ST=CDMX/L=Mexico/O=Reprobados/CN=$DOMAIN"
        echo "[+] Certificado generado."
    else
        echo "[+] Certificado existente encontrado."
    fi
}

configure_ssl_apache() {
    echo "[*] Configurando SSL en Apache ($SERVICE_APACHE)..."
    generate_cert
    eval $ENABLE_SSL_CMD
    
    # Crear VirtualHost 443
    if [ "$PKM" == "apt" ]; then
        CONFIG_FILE="$CONF_APACHE/000-default-ssl.conf"
        HTTP_CONFIG="$CONF_APACHE/000-default.conf"
    else
        CONFIG_FILE="$CONF_APACHE/reprobados-ssl.conf"
        HTTP_CONFIG="$CONF_APACHE/reprobados-http.conf"
    fi

    sudo bash -c "cat > $CONFIG_FILE" <<EOF
<VirtualHost *:443>
    ServerName $DOMAIN
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile $CERT_FILE
    SSLCertificateKeyFile $KEY_FILE
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
    
    sudo bash -c "cat > $HTTP_CONFIG" <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    Redirect permanent / https://$DOMAIN/
</VirtualHost>
EOF

    [ "$PKM" == "apt" ] && $ENABLE_SITE_CMD 000-default-ssl
    sudo systemctl restart $SERVICE_APACHE
    echo "[+] SSL y Redireccion configurados."
}

configure_ssl_nginx() {
    echo "[*] Configurando SSL en Nginx..."
    generate_cert
    
    CONF_NGINX="/etc/nginx/conf.d"
    [ -d "/etc/nginx/sites-available" ] && CONF_NGINX="/etc/nginx/sites-available"
    
    CONFIG_FILE="$CONF_NGINX/default.conf"
    [ "$CONF_NGINX" == "/etc/nginx/sites-available" ] && CONFIG_FILE="$CONF_NGINX/default"

    sudo bash -c "cat > $CONFIG_FILE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    location / {
        root /usr/share/nginx/html;
        [ -d "/var/www/html" ] && root /var/www/html;
        index index.html index.htm;
    }
}
EOF
    sudo systemctl restart nginx
    echo "[+] SSL y Redireccion configurados en Nginx."
}

configure_ftps_vsftpd() {
    echo "[*] Configurando FTPS en vsftpd..."
    generate_cert
    
    CONFIG="/etc/vsftpd.conf"
    [ ! -f "$CONFIG" ] && CONFIG="/etc/vsftpd/vsftpd.conf"

    if [ -f "$CONFIG" ]; then
        sudo sed -i 's/ssl_enable=NO/ssl_enable=YES/' $CONFIG
        grep -q "ssl_enable=YES" $CONFIG || echo "ssl_enable=YES" | sudo tee -a $CONFIG
        echo "rsa_cert_file=$CERT_FILE" | sudo tee -a $CONFIG
        echo "rsa_private_key_file=$KEY_FILE" | sudo tee -a $CONFIG
        echo "allow_anon_ssl=YES" | sudo tee -a $CONFIG
        echo "force_local_data_ssl=YES" | sudo tee -a $CONFIG
        echo "force_local_logins_ssl=YES" | sudo tee -a $CONFIG
        sudo systemctl restart vsftpd
        echo "[+] FTPS activado."
    else
        echo "[-] No se encontró vsftpd.conf"
    fi
}

# ============================================================
# FUNCIONES DE REPOSITORIO FTP DINAMICO
# ============================================================

ftp_browser() {
    local service=$1
    local remote_path="$FTP_SERVER/http/Linux/$service/"
    echo "[*] Conectando a FTP: $remote_path"
    files=$(curl -s -l "$remote_path")
    if [ -z "$files" ]; then return 1; fi
    options=($files)
    for i in "${!options[@]}"; do echo "[$i] ${options[$i]}"; done
    read -p "Seleccion: " choice
    [ "$choice" -ge 0 ] && [ "$choice" -lt "${#options[@]}" ] && echo "${options[$choice]}"
}

download_and_verify() {
    local service=$1
    local filename=$2
    local remote_url="$FTP_SERVER/http/Linux/$service/$filename"
    local local_file="$LOCAL_REPO/$filename"
    curl -s -o "$local_file" "$remote_url"
    curl -s -o "$local_file.sha256" "$remote_url.sha256"
    if [ -f "$local_file.sha256" ]; then
        cd $LOCAL_REPO && sha256sum -c "$filename.sha256" && echo "$local_file"
    else
        echo "$local_file"
    fi
}

# ============================================================
# ORQUESTADOR DE INSTALACION
# ============================================================

install_orchestrator() {
    local svc=$1
    local pkg_name=${svc,,}
    [ "$svc" == "Apache2" ] && pkg_name=$SERVICE_APACHE

    echo -e "\n--- Instalacion de $svc ---"
    echo "[1] WEB ($PKM)"
    echo "[2] FTP (Privado)"
    read -p "Origen: " src
    
    if [ "$src" == "2" ]; then
        file=$(ftp_browser "$svc")
        if [ -n "$file" ]; then
            bin_path=$(download_and_verify "$svc" "$file")
            if [ -n "$bin_path" ]; then
                sudo rpm -ivh "$bin_path" 2>/dev/null || sudo dpkg -i "$bin_path" 2>/dev/null || $PKG_INSTALL "$bin_path"
            fi
        fi
    else
        $PKG_UPDATE && $PKG_INSTALL $pkg_name
    fi
    
    read -p "¿Activar SSL? [S/N]: " ssl_opt
    if [[ $ssl_opt =~ ^[Ss]$ ]]; then
        [[ $svc =~ Apache ]] && configure_ssl_apache
        [[ $svc =~ Nginx ]] && configure_ssl_nginx
    fi
}

# ============================================================
# MENU
# ============================================================

while true; do
    clear
    echo "=========================================================="
    echo "  SISTEMA DE APROVISIONAMIENTO WEB - LINUX ($ID)"
    echo "=========================================================="
    echo " [1] Instalar Apache"
    echo " [2] Instalar Nginx"
    echo " [3] Instalar Tomcat"
    echo " [4] Configurar FTPS"
    echo " [5] Ver estado"
    echo " [6] Salir"
    read -p "Opcion: " opt
    case $opt in
        1) install_orchestrator "Apache2" ;;
        2) install_orchestrator "Nginx" ;;
        3) $PKG_INSTALL tomcat ;;
        4) configure_ftps_vsftpd ;;
        5) sudo systemctl status $SERVICE_APACHE nginx vsftpd 2>/dev/null | grep -E "Active:|Unit" ;;
        6) exit 0 ;;
    esac
    read -p "Enter..." dummy
done
