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
FTP_SERVER="192.168.56.20"
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
    curl -s --connect-timeout 10 \
        "ftp://${FTP_SERVER}:${FTP_PORT}${RUTA}" \
        --user "${FTP_USER}:${FTP_PASS}" \
        -l 2>/dev/null
}

fn_ftp_descargar() {
    local RUTA_REMOTA="$1"
    local DESTINO="$2"

    fn_info "Descargando desde FTP: ${RUTA_REMOTA}..."
    curl -s --connect-timeout 30 --progress-bar \
        "ftp://${FTP_SERVER}:${FTP_PORT}${RUTA_REMOTA}" \
        --user "${FTP_USER}:${FTP_PASS}" \
        -o "$DESTINO" 2>/dev/null

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
        sed -i '/ssl_enable/d' "$VSFTPD_CONF"
        cat >> "$VSFTPD_CONF" <<FTPSEOF
ssl_enable=YES
rsa_cert_file=${SSL_DIR}/vsftpd/vsftpd.crt
rsa_private_key_file=${SSL_DIR}/vsftpd/vsftpd.key
force_local_data_ssl=YES
force_local_logins_ssl=YES
FTPSEOF
        systemctl restart vsftpd 2>/dev/null
        fn_ok "vsftpd reiniciado con SSL (Mageia)."
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
            fn_ok "Apache reiniciado."
            ;;
        nginx)
            fn_instalar_paquete "nginx" || { fn_err "Fallo la instalacion de Nginx."; return 1; }
            systemctl enable --now nginx 2>/dev/null
            fn_ok "Nginx instalado y activo."
            ;;
        tomcat)
            fn_instalar_paquete "tomcat" || { fn_err "Fallo la instalacion de Tomcat."; return 1; }
            systemctl enable --now tomcat 2>/dev/null
            fn_ok "Tomcat instalado y activo."
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
    read -r ORIGEN

    echo -e "${YELLOW}Puerto:${NC}"
    read -r PUERTO

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
