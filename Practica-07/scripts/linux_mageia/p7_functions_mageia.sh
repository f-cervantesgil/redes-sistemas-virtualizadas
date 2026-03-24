#!/bin/bash
# =============================================================================
# p7_functions_mageia.sh - Libreria de funciones Practica 7
# Sistema Operativo: Linux Mageia
# Integra: Cliente FTP dinamico + SSL/TLS + Verificacion Hash
# =============================================================================

# -----------------------------------------------------------------------------
# COLORES
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# VARIABLES GLOBALES
# -----------------------------------------------------------------------------
FTP_SERVER="192.168.222.139"
FTP_PORT="21"
FTP_USER="anonymous"
FTP_PASS="practica7@reprobados.com"
FTP_BASE_PATH="/http/Linux"
DOMINIO="reprobados.com"
SSL_DIR="/etc/ssl/practica7"
RESUMEN_INSTALACIONES=""
INSTALL_DIR="/opt/p7_instaladores"

# -----------------------------------------------------------------------------
# FUNCIONES DE UTILIDAD
# -----------------------------------------------------------------------------
fn_header_p7() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     SISTEMA DE APROVISIONAMIENTO WEB - MAGEIA LINUX      ║"
    echo "║          Practica 7 - FTP + SSL/TLS + Hash               ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

fn_ok()   { echo -e "${GREEN}[OK] $1${NC}"; }
fn_info() { echo -e "${YELLOW}[INFO] $1${NC}"; }
fn_err()  { echo -e "${RED}[ERROR] $1${NC}"; }
fn_sec()  { echo -e "${MAGENTA}[SSL] $1${NC}"; }

fn_verificar_root_p7() {
    if [ "$(id -u)" -ne 0 ]; then
        fn_err "Este script debe ejecutarse como root."
        exit 1
    fi
}

# Detector de gestor de paquetes (dnf preferido en Mageia moderno, urpmi como fallback)
fn_instalar_paquete() {
    local PKG="$1"
    fn_info "Ejecutando instalacion de: ${PKG}..."
    if command -v dnf &>/dev/null; then
        # dnf puede tardar en sincronizar repositorios. Se quita el silencio para ver el progreso.
        dnf install -y "$PKG"
    elif command -v urpmi &>/dev/null; then
        urpmi --auto "$PKG"
    else
        fn_err "No se detecto gestor de paquetes (dnf/urpmi)."
        return 1
    fi
}

fn_verificar_dependencias() {
    fn_info "Verificando dependencias..."
    local DEPS="curl wget openssl coreutils"
    for DEP in $DEPS; do
        if ! command -v "$DEP" &>/dev/null; then
            fn_info "Instalando $DEP..."
            fn_instalar_paquete "$DEP"
        fi
    done
    # Verificar sha256sum por separado
    if ! command -v sha256sum &>/dev/null; then
        fn_instalar_paquete "coreutils"
    fi
    fn_ok "Dependencias verificadas."
}

# -----------------------------------------------------------------------------
# BLOQUE 1: CLIENTE FTP DINAMICO
# -----------------------------------------------------------------------------

fn_ftp_listar() {
    local RUTA="$1"
    # Se agrega --ftp-pasv para mejorar la conexion y redireccion de error para ver por que falla
    curl -s --connect-timeout 10 --ftp-pasv \
        "ftp://${FTP_SERVER}:${FTP_PORT}${RUTA}" \
        --user "${FTP_USER}:${FTP_PASS}" \
        -l 2>&1
}

# Descargar un archivo del servidor FTP
fn_ftp_descargar() {
    local RUTA_REMOTA="$1"
    local DESTINO="$2"

    fn_info "Descargando desde FTP: ${RUTA_REMOTA}..."
    curl -s --connect-timeout 30 --progress-bar --ftp-pasv \
        "ftp://${FTP_SERVER}:${FTP_PORT}${RUTA_REMOTA}" \
        --user "${FTP_USER}:${FTP_PASS}" \
        -o "$DESTINO" 

    if [ $? -eq 0 ] && [ -s "$DESTINO" ]; then
        fn_ok "Archivo descargado: $DESTINO"
        return 0
    else
        fn_err "No se pudo descargar el archivo."
        return 1
    fi
}

fn_ftp_navegar_y_descargar() {
    local SERVICIO="$1"
    local DESTINO_DIR="$2"

    echo ""
    echo -e "${CYAN}=== REPOSITORIO FTP - ${SERVICIO} ===${NC}"

    fn_info "Conectando al servidor FTP ${FTP_SERVER}..."
    local SERVICIOS
    SERVICIOS=$(fn_ftp_listar "${FTP_BASE_PATH}/")

    if [ -z "$SERVICIOS" ]; then
        fn_err "No se pudo conectar al servidor FTP o el repositorio esta vacio."
        return 1
    fi

    fn_ok "Conexion FTP exitosa."
    echo ""
    echo -e "${CYAN}Servicios disponibles en el repositorio:${NC}"
    local i=1
    local LISTA_SERVICIOS=""
    while IFS= read -r linea; do
        if [ -n "$linea" ]; then
            echo "  [$i] $linea"
            LISTA_SERVICIOS="$LISTA_SERVICIOS $linea"
            i=$((i+1))
        fi
    done <<< "$SERVICIOS"

    local TOTAL=$((i-1))
    local SEL_SVC=0
    while true; do
        echo ""
        echo -e "${YELLOW}Selecciona el servicio a instalar (1-${TOTAL}):${NC}"
        read -r SEL_SVC
        if [[ "$SEL_SVC" =~ ^[0-9]+$ ]] && [ "$SEL_SVC" -ge 1 ] && [ "$SEL_SVC" -le "$TOTAL" ]; then
            break
        fi
        fn_err "Seleccion invalida."
    done

    local SVC_ELEGIDO
    SVC_ELEGIDO=$(echo "$LISTA_SERVICIOS" | awk -v n="$SEL_SVC" '{print $n}')
    fn_ok "Servicio seleccionado: $SVC_ELEGIDO"

    echo ""
    fn_info "Listando versiones disponibles para ${SVC_ELEGIDO}..."
    local ARCHIVOS
    ARCHIVOS=$(fn_ftp_listar "${FTP_BASE_PATH}/${SVC_ELEGIDO}/")

    if [ -z "$ARCHIVOS" ]; then
        fn_err "No hay archivos en el repositorio para ${SVC_ELEGIDO}."
        return 1
    fi

    echo ""
    echo -e "${CYAN}Versiones disponibles:${NC}"
    local j=1
    local LISTA_ARCHIVOS=""
    while IFS= read -r archivo; do
        if [ -n "$archivo" ] && ! echo "$archivo" | grep -q "\.sha256$"; then
            echo "  [$j] $archivo"
            LISTA_ARCHIVOS="$LISTA_ARCHIVOS $archivo"
            j=$((j+1))
        fi
    done <<< "$ARCHIVOS"

    local TOTAL_ARCH=$((j-1))
    if [ "$TOTAL_ARCH" -eq 0 ]; then
        fn_err "No hay instaladores disponibles."
        return 1
    fi

    local SEL_ARCH=0
    while true; do
        echo ""
        echo -e "${YELLOW}Selecciona la version a descargar (1-${TOTAL_ARCH}):${NC}"
        read -r SEL_ARCH
        if [[ "$SEL_ARCH" =~ ^[0-9]+$ ]] && [ "$SEL_ARCH" -ge 1 ] && [ "$SEL_ARCH" -le "$TOTAL_ARCH" ]; then
            break
        fi
        fn_err "Seleccion invalida."
    done

    local ARCH_ELEGIDO
    ARCH_ELEGIDO=$(echo "$LISTA_ARCHIVOS" | awk -v n="$SEL_ARCH" '{print $n}')
    fn_ok "Version seleccionada: $ARCH_ELEGIDO"

    mkdir -p "$DESTINO_DIR"
    local RUTA_REMOTA="${FTP_BASE_PATH}/${SVC_ELEGIDO}/${ARCH_ELEGIDO}"
    local RUTA_SHA256="${RUTA_REMOTA}.sha256"
    local DESTINO_LOCAL="${DESTINO_DIR}/${ARCH_ELEGIDO}"
    local DESTINO_SHA256="${DESTINO_DIR}/${ARCH_ELEGIDO}.sha256"

    fn_ftp_descargar "$RUTA_REMOTA" "$DESTINO_LOCAL" || return 1
    fn_ftp_descargar "$RUTA_SHA256" "$DESTINO_SHA256" || {
        fn_info "No se encontro archivo SHA256, omitiendo verificacion."
    }

    FTP_ARCHIVO_DESCARGADO="$DESTINO_LOCAL"
    FTP_SHA256_DESCARGADO="$DESTINO_SHA256"
    FTP_SERVICIO_ELEGIDO="$SVC_ELEGIDO"
    FTP_ARCHIVO_NOMBRE="$ARCH_ELEGIDO"

    return 0
}

# -----------------------------------------------------------------------------
# BLOQUE 2: VERIFICACION DE INTEGRIDAD SHA256
# -----------------------------------------------------------------------------

fn_verificar_hash() {
    local ARCHIVO="$1"
    local ARCHIVO_SHA256="$2"

    echo ""
    echo -e "${CYAN}=== VERIFICACION DE INTEGRIDAD ===${NC}"

    if [ ! -f "$ARCHIVO" ]; then
        fn_err "Archivo no encontrado: $ARCHIVO"
        return 1
    fi

    if [ ! -f "$ARCHIVO_SHA256" ]; then
        fn_info "No hay archivo SHA256 disponible. Omitiendo verificacion."
        return 0
    fi

    fn_info "Calculando hash SHA256 del archivo descargado..."
    local HASH_LOCAL
    HASH_LOCAL=$(sha256sum "$ARCHIVO" | awk '{print $1}')

    local HASH_REMOTO
    HASH_REMOTO=$(awk '{print $1}' "$ARCHIVO_SHA256")

    echo "  Hash local:  $HASH_LOCAL"
    echo "  Hash remoto: $HASH_REMOTO"

    if [ "$HASH_LOCAL" = "$HASH_REMOTO" ]; then
        fn_ok "Integridad verificada. El archivo no esta corrompido."
        return 0
    else
        fn_err "FALLO DE INTEGRIDAD. Los hashes no coinciden."
        fn_err "El archivo puede estar corrompido. Abortando instalacion."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# BLOQUE 3: GENERACION DE CERTIFICADOS SSL/TLS
# -----------------------------------------------------------------------------

fn_generar_certificado_ssl() {
    local SERVICIO="$1"
    local CERT_DIR="${SSL_DIR}/${SERVICIO}"

    mkdir -p "$CERT_DIR"

    fn_sec "Generando certificado SSL autofirmado para ${DOMINIO}..."

    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" \
        -subj "/C=MX/ST=Sinaloa/L=Los_Mochis/O=Reprobados/OU=Sistemas/CN=${DOMINIO}" \
        2>/dev/null

    if [ $? -eq 0 ]; then
        chmod 600 "${CERT_DIR}/server.key"
        chmod 644 "${CERT_DIR}/server.crt"
        fn_sec "Certificado generado para ${SERVICIO}."
        return 0
    else
        fn_err "No se pudo generar el certificado SSL."
        return 1
    fi
}

fn_preguntar_ssl() {
    echo ""
    echo -e "${CYAN}¿Desea activar SSL/TLS en este servicio? [s/n]:${NC}"
    read -r RESP_SSL
    if echo "$RESP_SSL" | grep -qi "^s"; then
        return 0
    else
        return 1
    fi
}

# -----------------------------------------------------------------------------
# BLOQUE 4: INSTALACION APACHE DESDE FTP
# -----------------------------------------------------------------------------

fn_instalar_apache_ftp() {
    local ARCHIVO="$1"
    local PUERTO="$2"
    local SSL="$3"

    echo ""
    echo -e "${BLUE}====== INSTALACION APACHE DESDE FTP ======${NC}"

    fn_info "Instalando dependencias de compilacion Mageia..."
    fn_instalar_paquete "gcc-c++ glibc-devel make apr-devel apr-util-devel pcre-devel openssl-devel zlib-devel libxml2-devel libcurl-devel"

    local EXTRACT_DIR="${INSTALL_DIR}/apache_src"
    mkdir -p "$EXTRACT_DIR"
    fn_info "Extrayendo ${ARCHIVO}..."
    tar -xzf "$ARCHIVO" -C "$EXTRACT_DIR" 2>/dev/null
    local SRC_DIR
    SRC_DIR=$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "httpd-*" | head -1)

    if [ -z "$SRC_DIR" ]; then
        fn_err "No se pudo extraer el archivo de Apache."
        return 1
    fi

    fn_info "Compilando Apache (Mageia)..."
    cd "$SRC_DIR" || return 1

    local MODULES="--enable-ssl --enable-rewrite --enable-headers --enable-deflate"
    if [ "$SSL" = "si" ]; then
        MODULES="$MODULES --with-ssl"
    fi

    ./configure --prefix=/usr/local/apache2 \
        --enable-so \
        $MODULES \
        --with-mpm=event \
        >/tmp/apache_configure.log 2>&1

    make -j$(nproc) >/tmp/apache_make.log 2>&1
    make install >/tmp/apache_install.log 2>&1

    if [ ! -f "/usr/local/apache2/bin/httpd" ]; then
        fn_err "La compilacion de Apache fallo."
        return 1
    fi

    fn_ok "Apache compilado e instalado en /usr/local/apache2"

    local CONF="/usr/local/apache2/conf/httpd.conf"
    sed -i "s/^Listen .*/Listen ${PUERTO}/" "$CONF"
    sed -i "s/^ServerName .*/ServerName ${DOMINIO}:${PUERTO}/" "$CONF"

    cat >> "$CONF" <<APACHEEOF
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Header always set X-Frame-Options SAMEORIGIN
Header always set X-Content-Type-Options nosniff
APACHEEOF

    if [ "$SSL" = "si" ]; then
        fn_generar_certificado_ssl "apache"
        local CERT_DIR="${SSL_DIR}/apache"
        cat >> "$CONF" <<SSLEOF
LoadModule ssl_module modules/mod_ssl.so
Listen 443
<VirtualHost *:443>
    ServerName ${DOMINIO}
    DocumentRoot "/usr/local/apache2/htdocs"
    SSLEngine on
    SSLCertificateFile    ${CERT_DIR}/server.crt
    SSLCertificateKeyFile ${CERT_DIR}/server.key
</VirtualHost>
<VirtualHost *:${PUERTO}>
    ServerName ${DOMINIO}
    Redirect permanent / https://${DOMINIO}/
</VirtualHost>
SSLEOF
    fi

    mkdir -p /usr/local/apache2/htdocs
    cat > /usr/local/apache2/htdocs/index.html <<HTMLEOF
<!DOCTYPE html>
<html>
<body style="background:#1a1a2e;color:white;text-align:center;padding-top:100px;font-family:sans-serif;">
    <h1 style="color:#e94560;">Apache Mageia</h1>
    <p>Servidor activo en puerto ${PUERTO}</p>
    <p>Dominio: ${DOMINIO} | SSL: ${SSL}</p>
    <p>Instalado desde FTP</p>
</body>
</html>
HTMLEOF

    /usr/local/apache2/bin/apachectl start 2>/dev/null
    fn_ok "Apache iniciado."
    RESUMEN_INSTALACIONES="${RESUMEN_INSTALACIONES}\n[Apache] Puerto: ${PUERTO} | SSL: ${SSL} | Origen: FTP"
    return 0
}

# -----------------------------------------------------------------------------
# BLOQUE 5: INSTALACION NGINX DESDE FTP
# -----------------------------------------------------------------------------

fn_instalar_nginx_ftp() {
    local ARCHIVO="$1"
    local PUERTO="$2"
    local SSL="$3"

    echo ""
    echo -e "${BLUE}====== INSTALACION NGINX DESDE FTP ======${NC}"

    fn_info "Instalando dependencias de compilacion..."
    fn_instalar_paquete "gcc-c++ glibc-devel make pcre-devel openssl-devel zlib-devel"

    local EXTRACT_DIR="${INSTALL_DIR}/nginx_src"
    mkdir -p "$EXTRACT_DIR"
    fn_info "Extrayendo ${ARCHIVO}..."
    tar -xzf "$ARCHIVO" -C "$EXTRACT_DIR" 2>/dev/null
    local SRC_DIR
    SRC_DIR=$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "nginx-*" | head -1)

    if [ -z "$SRC_DIR" ]; then
        fn_err "No se pudo extraer el archivo de Nginx."
        return 1
    fi

    fn_info "Compilando Nginx..."
    cd "$SRC_DIR" || return 1

    ./configure \
        --prefix=/usr/local/nginx \
        --with-http_ssl_module \
        --with-http_v2_module \
        >/tmp/nginx_configure.log 2>&1

    make -j$(nproc) >/tmp/nginx_make.log 2>&1
    make install >/tmp/nginx_install.log 2>&1

    if [ ! -f "/usr/local/nginx/sbin/nginx" ]; then
        fn_err "La compilacion de Nginx fallo."
        return 1
    fi

    fn_ok "Nginx compilado e instalado en /usr/local/nginx"

    local SSL_BLOCK=""
    if [ "$SSL" = "si" ]; then
        fn_generar_certificado_ssl "nginx"
        local CERT_DIR="${SSL_DIR}/nginx"
        SSL_BLOCK="
    server {
        listen 443 ssl;
        server_name ${DOMINIO};
        ssl_certificate     ${CERT_DIR}/server.crt;
        ssl_certificate_key ${CERT_DIR}/server.key;
        root /usr/local/nginx/html;
        index index.html;
    }"
    fi

    cat > /usr/local/nginx/conf/nginx.conf <<NGINXEOF
events { worker_connections 1024; }
http {
    include mime.types;
    server {
        listen ${PUERTO};
        server_name ${DOMINIO};
        root /usr/local/nginx/html;
        index index.html;
        $( [ "$SSL" = "si" ] && echo "return 301 https://\$host\$request_uri;" )
    }
    ${SSL_BLOCK}
}
NGINXEOF

    mkdir -p /usr/local/nginx/html
    cat > /usr/local/nginx/html/index.html <<HTMLEOF
<!DOCTYPE html>
<html>
<body style="background:#1a1a2e;color:white;text-align:center;padding-top:100px;font-family:sans-serif;">
    <h1 style="color:#e94560;">Nginx Mageia</h1>
    <p>Servidor activo en puerto ${PUERTO}</p>
    <p>Dominio: ${DOMINIO} | SSL: ${SSL}</p>
    <p>Instalado desde FTP</p>
</body>
</html>
HTMLEOF

    /usr/local/nginx/sbin/nginx 2>/dev/null
    fn_ok "Nginx iniciado."
    RESUMEN_INSTALACIONES="${RESUMEN_INSTALACIONES}\n[Nginx] Puerto: ${PUERTO} | SSL: ${SSL} | Origen: FTP"
}

# -----------------------------------------------------------------------------
# BLOQUE 6: INSTALACION TOMCAT DESDE FTP
# -----------------------------------------------------------------------------

fn_instalar_tomcat_ftp() {
    local ARCHIVO="$1"
    local PUERTO="$2"
    local SSL="$3"

    echo ""
    echo -e "${BLUE}====== INSTALACION TOMCAT DESDE FTP ======${NC}"

    fn_info "Detectando Java en Mageia..."
    if ! command -v java &>/dev/null; then
        fn_instalar_paquete "java-11-openjdk"
    fi

    local TOMCAT_BASE="/opt/tomcat_p7"
    mkdir -p "$TOMCAT_BASE"
    tar -xzf "$ARCHIVO" -C "$TOMCAT_BASE" --strip-components=1 2>/dev/null

    if [ ! -f "${TOMCAT_BASE}/bin/catalina.sh" ]; then
        fn_err "No se pudo extraer Tomcat."
        return 1
    fi

    sed -i "s/port=\"8080\"/port=\"${PUERTO}\"/" "${TOMCAT_BASE}/conf/server.xml"

    if [ "$SSL" = "si" ]; then
        fn_generar_certificado_ssl "tomcat"
        # Configurar rudimentario en server.xml si se desea
    fi

    if ! id tomcat &>/dev/null; then
        useradd -r -s /sbin/nologin tomcat 2>/dev/null
    fi
    chown -R tomcat:tomcat "$TOMCAT_BASE"
    chmod +x "${TOMCAT_BASE}/bin/"*.sh

    cat > "${TOMCAT_BASE}/webapps/ROOT/index.html" <<HTMLEOF
<!DOCTYPE html>
<html>
<body style="background:#1a1a2e;color:white;text-align:center;padding-top:100px;font-family:sans-serif;">
    <h1 style="color:#e94560;">Tomcat Mageia</h1>
    <p>Servidor activo en puerto ${PUERTO}</p>
    <p>Instalado desde FTP</p>
</body>
</html>
HTMLEOF

    su -s /bin/sh tomcat -c "${TOMCAT_BASE}/bin/startup.sh" 2>/dev/null
    fn_ok "Tomcat iniciado en Mageia."
    RESUMEN_INSTALACIONES="${RESUMEN_INSTALACIONES}\n[Tomcat] Puerto: ${PUERTO} | SSL: ${SSL} | Origen: FTP"
}

# -----------------------------------------------------------------------------
# BLOQUE 7: SSL PARA VSFTPD (FTPS)
# -----------------------------------------------------------------------------

fn_configurar_ftps() {
    echo ""
    echo -e "${CYAN}=== CONFIGURACION FTPS (SSL en vsftpd) ===${NC}"

    mkdir -p "${SSL_DIR}/vsftpd"
    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "${SSL_DIR}/vsftpd/vsftpd.key" \
        -out "${SSL_DIR}/vsftpd/vsftpd.crt" \
        -subj "/C=MX/ST=Sinaloa/L=Los_Mochis/O=Reprobados/OU=FTP/CN=${DOMINIO}" \
        2>/dev/null

    local VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
    [ ! -f "$VSFTPD_CONF" ] && VSFTPD_CONF="/etc/vsftpd.conf"

    if [ -f "$VSFTPD_CONF" ]; then
        fn_info "Generando configuracion limpia de vsftpd para Mageia..."
        cat > "$VSFTPD_CONF" <<FTPSEOF
# Configuración corregida para Mageia
anonymous_enable=YES
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
xferlog_std_format=YES
listen=YES
listen_ipv6=NO
pam_service_name=vsftpd
userlist_enable=YES
tcp_wrappers=YES

# Configuración SSL (FTPS)
ssl_enable=YES
allow_anon_ssl=YES
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH
rsa_cert_file=${SSL_DIR}/vsftpd/vsftpd.crt
rsa_private_key_file=${SSL_DIR}/vsftpd/vsftpd.key
FTPSEOF
        systemctl restart vsftpd 2>/dev/null
        fn_ok "vsftpd reiniciado con configuracion limpia y SSL."
    else
        fn_err "No se encontro vsftpd.conf"
    fi
}

# -----------------------------------------------------------------------------
# BLOQUE 8: INSTALACION WEB (URPMI/DNF) CON SSL OPCIONAL
# -----------------------------------------------------------------------------

fn_instalar_web_con_ssl() {
    local SERVICIO="$1"
    local PUERTO="$2"
    local SSL="$3"

    fn_info "Instalando ${SERVICIO} via DNF/URPMI..."

    case "$SERVICIO" in
        apache)
             # En Mageia el paquete se llama 'apache' y no 'httpd'
            fn_instalar_paquete "apache" || { fn_err "Fallo la instalacion de Apache."; return 1; }
            
            # Configurar puerto en Mageia
            # Tipicamente /etc/httpd/conf/httpd.conf
            local CONF_PATH="/etc/httpd/conf/httpd.conf"
            [ ! -f "$CONF_PATH" ] && CONF_PATH="/etc/apache2/conf/httpd.conf"
            
            if [ -f "$CONF_PATH" ]; then
                # Reemplazo mas agresivo: cualquier linea que empiece con Listen seguira con el puerto elegido
                sed -i "s/^Listen .*/Listen ${PUERTO}/" "$CONF_PATH"
                sed -i "s/^ServerName .*/ServerName ${DOMINIO}:${PUERTO}/" "$CONF_PATH"
                fn_info "Configuracion de puerto ${PUERTO} aplicada en $CONF_PATH"
            else
                fn_err "No se encontro httpd.conf en rutas estandar."
            fi

            if [ "$SSL" = "si" ]; then
                fn_instalar_paquete "apache-mod_ssl" || { fn_err "Fallo la instalacion de mod_ssl."; return 1; }
                fn_generar_certificado_ssl "apache"
                # Path Mageia SSL: /etc/httpd/conf.d/ssl.conf
                if [ -f "/etc/httpd/conf.d/ssl.conf" ]; then
                    sed -i "s|^SSLCertificateFile.*|SSLCertificateFile ${SSL_DIR}/apache/server.crt|" /etc/httpd/conf.d/ssl.conf 2>/dev/null
                    sed -i "s|^SSLCertificateKeyFile.*|SSLCertificateKeyFile ${SSL_DIR}/apache/server.key|" /etc/httpd/conf.d/ssl.conf 2>/dev/null
                fi
            fi
            
            fn_info "Reiniciando el servicio para aplicar cambios..."
            systemctl enable httpd 2>/dev/null || systemctl enable apache2 2>/dev/null
            systemctl restart httpd || systemctl restart apache2
            
            # Crear pagina web dinamica para Apache (Mageia detecta DocumentRoot)
            local REAL_DOCROOT
            REAL_DOCROOT=$(grep "^DocumentRoot" "$CONF_PATH" | awk '{print $2}' | tr -d '"' | sed 's|^/||;s|$|/|;s|^|/|' || echo "/var/www/html")
            [ ! -d "$REAL_DOCROOT" ] && REAL_DOCROOT="/var/www/html"
            
            fn_info "Generando index.html en $REAL_DOCROOT..."
            mkdir -p "$REAL_DOCROOT"
            rm -f "$REAL_DOCROOT/index.html"
            
            cat > "$REAL_DOCROOT/index.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
    <meta http-equiv="Pragma" content="no-cache">
    <meta http-equiv="Expires" content="0">
    <title>Apache - Mageia Linux</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #1a1a2e; color: #eee;
               display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .card { background: #16213e; padding: 40px 60px; border-radius: 12px;
                box-shadow: 0 10px 30px rgba(0,0,0,0.5); text-align: center; width: 450px;
                border-left: 5px solid #e94560; }
        h1 { color: #4ade80; font-size: 2.5em; margin-bottom: 25px; }
        .badge { display: inline-block; background: #0f3460; padding: 8px 18px;
                 border-radius: 8px; margin: 5px; font-weight: bold; }
        .port-badge { background: #e94560; color: white; }
        .footer { font-size: 0.9em; color: #888; margin-top: 30px; border-top: 1px solid #1f4068; padding-top: 15px; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Apache - ACTIVO</h1>
        <div>
            <span class="badge">Servidor: Linux</span>
            <span class="badge">OS: Mageia</span>
            <span class="badge port-badge">Puerto: ${PUERTO}</span>
        </div>
        <div class="footer">
            Aprovisionamiento Automático - Práctica 7 - Mageia Linux
        </div>
    </div>
</body>
</html>
HTMLEOF
            fn_ok "Pagina web de Apache generada en $REAL_DOCROOT para puerto ${PUERTO}."
            fn_ok "Apache reiniciado exitosamente."
            ;;
        nginx)
            fn_instalar_paquete "nginx" || { fn_err "Fallo la instalacion de Nginx."; return 1; }
            
            local NGINX_CONF="/etc/nginx/nginx.conf"
            if [ -f "$NGINX_CONF" ]; then
                # Cambiar puerto predeterminado (listen 80)
                sed -i "s/listen[[:space:]]\+80;/listen ${PUERTO};/" "$NGINX_CONF"
                fn_info "Puerto ${PUERTO} configurado en $NGINX_CONF"
                
                # Configurar SSL si se solicita
                if [ "$SSL" = "si" ]; then
                    fn_generar_certificado_ssl "nginx"
                    # Se busca el bloque server para habilitar ssl_certificate
                    # En Mageia es mas seguro crear un archivo en conf.d
                    cat > /etc/nginx/conf.d/ssl.conf <<NGXSSL
server {
    listen ${PUERTO} ssl;
    server_name ${DOMINIO};
    ssl_certificate ${SSL_DIR}/nginx/server.crt;
    ssl_certificate_key ${SSL_DIR}/nginx/server.key;
    location / {
        root /usr/share/nginx/html;
        index index.html;
    }
}
NGXSSL
                    fn_info "SSL de Nginx configurado en /etc/nginx/conf.d/ssl.conf"
                fi
            fi

            # Crear pagina web dinamica para Nginx
            mkdir -p /usr/share/nginx/html
            cat > /usr/share/nginx/html/index.html <<HTMLEOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Nginx - Mageia Linux</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; background: #0f172a; color: #fff;
               display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .card { background: #1e293b; padding: 40px; border-radius: 12px;
                box-shadow: 0 4px 20px rgba(0,0,0,0.5); text-align: center; border-left: 5px solid #38bdf8; }
        h1 { color: #38bdf8; margin-bottom: 20px; }
        .badge { display: inline-block; background: #334155; padding: 8px 16px;
                 border-radius: 8px; margin: 5px; font-weight: bold; }
        .port-badge { background: #0ea5e9; }
        .footer { font-size: 0.9em; color: #94a3b8; margin-top: 25px; border-top: 1px solid #334155; padding-top: 10px; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Nginx + Mageia - ACTIVO</h1>
        <div>
            <span class="badge">Srv: Linux</span>
            <span class="badge port-badge">Puerto: ${PUERTO}</span>
        </div>
        <div class="footer">Aprovisionamiento Automático - Práctica 7</div>
    </div>
</body>
</html>
HTMLEOF
            
            systemctl enable --now nginx 2>/dev/null
            systemctl restart nginx
            fn_ok "Nginx reiniciado exitosamente en el puerto ${PUERTO}."
            ;;
        tomcat)
            fn_info "Iniciando 'Solución Nuclear Final' para Tomcat (Mageia)..."
            fn_instalar_paquete "tomcat" || { fn_err "Fallo la instalacion de Tomcat."; return 1; }
            
            # Detener el servicio y ELIMINAR CUALQUIER PROCESO JAVA (Limpia la practica anterior)
            systemctl stop tomcat 2>/dev/null
            fn_info "Realizando limpieza de procesos Java y puertos de control (8005)..."
            killall -9 java 2>/dev/null
            pkill -9 -f tomcat 2>/dev/null
            
            local TOMCAT_XML="/etc/tomcat/server.xml"
            fn_info "Generando configuracion MINIMA BLINDADA para Tomcat en puerto ${PUERTO}..."

            # SOLUCION REAL: Buscar y sobreescribir TODOS los server.xml del sistema
            # (Tomcat en Mageia puede leer de /usr/share/tomcat/conf/ en lugar de /etc/tomcat/)
            fn_info "Buscando todos los archivos server.xml en el sistema..."
            local SERVER_XML_LIST
            # Incluir /opt/tomcat explicitamente (donde Practica 6 instalo Tomcat)
            SERVER_XML_LIST=$(find /etc/tomcat /usr/share/tomcat /var/lib/tomcat /opt/tomcat /opt/tomcat* 2>/dev/null -name "server.xml" -type f)

            if [ -z "$SERVER_XML_LIST" ]; then
                fn_err "No se encontro ningun server.xml. Creando en /etc/tomcat/..."
                mkdir -p /etc/tomcat
                SERVER_XML_LIST="/etc/tomcat/server.xml"
            fi

            # Contenido de la nueva configuracion minimalista
            local NEW_CONFIG='<?xml version="1.0" encoding="UTF-8"?>
<Server port="-1" shutdown="SHUTDOWN">
  <Service name="Catalina">
    <Connector port="'"${PUERTO}"'" protocol="HTTP/1.1"
               address="0.0.0.0"
               connectionTimeout="20000"
               redirectPort="8443" />
    <Engine name="Catalina" defaultHost="localhost">
      <Host name="localhost" appBase="webapps" unpackWARs="true" autoDeploy="true">
        <Valve className="org.apache.catalina.valves.AccessLogValve" directory="logs"
               prefix="localhost_access_log" suffix=".txt" pattern="%h %l %u %t &quot;%r&quot; %s %b" />
      </Host>
    </Engine>
  </Service>
</Server>'

            # Sobreescribir TODOS los archivos server.xml encontrados
            echo "$SERVER_XML_LIST" | while IFS= read -r XML_FILE; do
                [ -z "$XML_FILE" ] && continue
                fn_info "Sobreescribiendo: $XML_FILE"
                echo "$NEW_CONFIG" > "$XML_FILE"
                chown tomcat:tomcat "$XML_FILE" 2>/dev/null
                chmod 644 "$XML_FILE"
                fn_ok "Configurado: $XML_FILE"
            done


            # Limpiar cache y asegurar permisos absolutos
            rm -rf /var/lib/tomcat/work/* /usr/share/tomcat/work/* 2>/dev/null
            mkdir -p /var/log/tomcat
            chown -R tomcat:tomcat /etc/tomcat /var/lib/tomcat /var/log/tomcat /usr/share/tomcat 2>/dev/null

            # Detectar CATALINA_BASE/HOME desde el servicio systemd
            local CATALINA_BASE=""
            CATALINA_BASE=$(grep -E "CATALINA_BASE|CATALINA_HOME" /usr/lib/systemd/system/tomcat.service \
                            /etc/systemd/system/tomcat.service 2>/dev/null \
                            | grep -oP '(?<==)[^ ]+' | head -1)
            fn_info "CATALINA_BASE detectado: ${CATALINA_BASE:-no detectado, usando rutas por defecto}"

            # Contenido del nuevo index.jsp (Practica 7)
            local JSP_CONTENT='<%@ page language="java" contentType="text/html; charset=UTF-8" pageEncoding="UTF-8"%>
<!DOCTYPE html>
<html>
<head>
    <title>Tomcat - Practica 7 - Mageia Linux</title>
</head>
<body style="background:#0f172a; color:#e2e8f0; text-align:center; padding-top:100px; font-family:sans-serif;">
    <div style="background:#1e293b; border-radius:15px; display:inline-block; padding:50px 70px; box-shadow:0 20px 40px rgba(0,0,0,0.4); border-top: 6px solid #ef4444;">
        <h1 style="color:#38bdf8; font-size:2.5em; margin-bottom:5px;">Tomcat</h1>
        <p style="color:#94a3b8; margin-bottom:25px;">Servidor Web - Mageia Linux</p>
        <div style="display:flex; gap:12px; justify-content:center; flex-wrap:wrap;">
            <span style="background:#ef4444; color:white; padding:8px 20px; border-radius:20px; font-weight:bold;">Servidor: Linux</span>
            <span style="background:#3b82f6; color:white; padding:8px 20px; border-radius:20px; font-weight:bold;">Version: <%= application.getServerInfo() %></span>
            <span style="background:#ef4444; color:white; padding:8px 20px; border-radius:20px; font-weight:bold;">Puerto: <%= request.getServerPort() %></span>
        </div>
        <p style="margin-top:25px; color:#64748b; font-size:0.85em;">Aprovisionado automaticamente - Practica 7 - Mageia Linux</p>
    </div>
</body>
</html>'

            # Buscar ABSOLUTAMENTE TODOS los index.jsp bajo cualquier directorio webapps
            fn_info "Buscando todos los index.jsp de Tomcat en el sistema (busqueda total)..."
            local JSP_LIST
            JSP_LIST=$(find / -name "index.jsp" -path "*/webapps/*" \
                         -not -path "*/proc/*" -not -path "*/sys/*" 2>/dev/null | tr '\n' ' ')

            # Asegurar rutas base siempre incluidas
            mkdir -p /var/lib/tomcat/webapps/ROOT /usr/share/tomcat/webapps/ROOT 2>/dev/null
            JSP_LIST="$JSP_LIST /var/lib/tomcat/webapps/ROOT/index.jsp /usr/share/tomcat/webapps/ROOT/index.jsp"

            # Añadir /opt/tomcat EXPLICITAMENTE (Practica 6 instalo Tomcat ahi)
            mkdir -p /opt/tomcat/webapps/ROOT 2>/dev/null
            JSP_LIST="$JSP_LIST /opt/tomcat/webapps/ROOT/index.jsp"

            # Añadir ruta de CATALINA_BASE si se detecto
            if [ -n "$CATALINA_BASE" ]; then
                mkdir -p "${CATALINA_BASE}/webapps/ROOT" 2>/dev/null
                JSP_LIST="$JSP_LIST ${CATALINA_BASE}/webapps/ROOT/index.jsp"
            fi


            # Escribir en todos los archivos encontrados
            echo "$JSP_LIST" | tr ' ' '\n' | sort -u | while IFS= read -r JSP_FILE; do
                [ -z "$JSP_FILE" ] && continue
                JSP_DIR=$(dirname "$JSP_FILE")
                mkdir -p "$JSP_DIR"
                echo "$JSP_CONTENT" > "$JSP_FILE"
                chown -R tomcat:tomcat "$JSP_DIR" 2>/dev/null
                fn_ok "JSP actualizado: $JSP_FILE"
            done


            systemctl enable --now tomcat 2>/dev/null
            systemctl start tomcat
            
            # Forzar apertura en el firewall
            if command -v firewall-cmd &>/dev/null; then
                firewall-cmd --permanent --remove-port=8080/tcp 2>/dev/null
                firewall-cmd --permanent --add-port=${PUERTO}/tcp 2>/dev/null
                firewall-cmd --reload 2>/dev/null
                fn_ok "Firewall configurado para puerto ${PUERTO}."
            fi
            
            # Verificacion con patron flexible (no depende de espacio exacto)
            fn_info "Verificando arranque de Tomcat (30 segs max)..."
            local ATTEMPTS=0
            local MAX_ATTEMPTS=15
            local STARTED=false
            while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
                if ss -tlnp 2>/dev/null | grep -qE ":${PUERTO}[[:space:]]|:${PUERTO}$"; then
                    fn_ok "Tomcat esta escuchando en el puerto ${PUERTO}."
                    STARTED=true
                    break
                fi
                sleep 2
                ATTEMPTS=$((ATTEMPTS + 1))
            done

            # Segundo intento: verificar via curl por si ss no muestra bien
            if [ "$STARTED" = "false" ]; then
                if curl -s --max-time 3 "http://localhost:${PUERTO}" &>/dev/null; then
                    fn_ok "Tomcat responde via HTTP en el puerto ${PUERTO}."
                    STARTED=true
                fi
            fi

            if [ "$STARTED" = "false" ]; then
                fn_err "Tomcat sigue sin responder despues de 30s."
                fn_info "Puertos activos de Java en este momento:"
                ss -tlnp | grep java
                fn_info "Causa probable (Logs del sistema):"
                journalctl -u tomcat -n 20 --no-pager
                return 1
            else
                fn_ok "Tomcat listo y desplegado."
            fi
            ;;
    esac
    RESUMEN_INSTALACIONES="${RESUMEN_INSTALACIONES}\n[${SERVICIO}] Puerto: ${PUERTO} | SSL: ${SSL} | Origen: WEB"
}

# -----------------------------------------------------------------------------
# BLOQUE 9: VERIFICACION AUTOMATIZADA
# -----------------------------------------------------------------------------

fn_verificar_servicio_http() {
    local NOMBRE="$1"
    local PUERTO="$2"
    local SSL="$3"
    echo -e "\n${CYAN}Verificando Mageia Service: ${NOMBRE}...${NC}"
    if ss -tlnp 2>/dev/null | grep -q ":${PUERTO} "; then
        fn_ok "${NOMBRE} escuchando en ${PUERTO}."
    else
        fn_err "${NOMBRE} NO responde en puerto ${PUERTO}."
    fi
}

fn_mostrar_resumen() {
    echo -e "\n${CYAN}=== RESUMEN MAGEIA ===${NC}"
    echo -e "$RESUMEN_INSTALACIONES"
}

# -----------------------------------------------------------------------------
# BLOQUE 10: FUNCION PRINCIPAL HIBRIDA
# -----------------------------------------------------------------------------

fn_instalar_servicio_hibrido() {
    local SERVICIO="$1"
    local NOMBRE_DISPLAY="$2"

    echo ""
    echo -e "${CYAN}====== INSTALACION DE ${NOMBRE_DISPLAY} (MAGEIA) ======${NC}"

    echo -e "${YELLOW}¿Origen?${NC}"
    echo "  [1] WEB - DNF/URPMI (internet)"
    echo "  [2] FTP - Repositorio privado"
    
    local ORIGEN=""
    while true; do
        read -r ORIGEN
        case "$ORIGEN" in
            1|2) break ;;
            *) fn_err "Elige 1 (WEB) o 2 (FTP)" ;;
        esac
    done

    # Solicitar puerto
    echo ""
    echo -e "${YELLOW}Ingresa el puerto para ${NOMBRE_DISPLAY} (ej: 8080, 9091, 5051):${NC}"
    local PUERTO=""
    while true; do
        read -r PUERTO
        if [[ "$PUERTO" =~ ^[0-9]+$ ]] && [ "$PUERTO" -ge 1 ] && [ "$PUERTO" -le 65535 ]; then
            if [ "$PUERTO" -eq 21 ]; then
                fn_err "El puerto 21 es de FTP. ¡NO lo uses para servicios web para evitar conflictos!"
                echo -e "${YELLOW}Por favor, elige otro puerto (ej: 80, 8080 o el puerto de tu matricula):${NC}"
                continue
            fi
            
            if ss -tlnp 2>/dev/null | grep -q ":${PUERTO} "; then
                fn_err "Puerto ${PUERTO} ya esta en uso. Elige otro."
            else
                fn_ok "Puerto ${PUERTO} disponible."
                break
            fi
        else
            fn_err "Puerto invalido. Debe ser entre 1 y 65535."
        fi
    done

    local SSL="no"
    fn_preguntar_ssl && SSL="si"

    if [ "$ORIGEN" = "1" ]; then
        fn_instalar_web_con_ssl "$SERVICIO" "$PUERTO" "$SSL"
    else
        fn_ftp_navegar_y_descargar "$NOMBRE_DISPLAY" "$INSTALL_DIR" || return 1
        fn_verificar_hash "$FTP_ARCHIVO_DESCARGADO" "$FTP_SHA256_DESCARGADO" || return 1
        case "$SERVICIO" in
            apache) fn_instalar_apache_ftp "$FTP_ARCHIVO_DESCARGADO" "$PUERTO" "$SSL" ;;
            nginx)  fn_instalar_nginx_ftp  "$FTP_ARCHIVO_DESCARGADO" "$PUERTO" "$SSL" ;;
            tomcat) fn_instalar_tomcat_ftp "$FTP_ARCHIVO_DESCARGADO" "$PUERTO" "$SSL" ;;
        esac
    fi

    # Firewall Mageia
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${PUERTO}/tcp" 2>/dev/null
        [ "$SSL" = "si" ] && firewall-cmd --permanent --add-port="443/tcp" 2>/dev/null
        firewall-cmd --reload 2>/dev/null
        fn_ok "Firewall (firewalld) actualizado."
    fi

    fn_verificar_servicio_http "$NOMBRE_DISPLAY" "$PUERTO" "$SSL"
}
