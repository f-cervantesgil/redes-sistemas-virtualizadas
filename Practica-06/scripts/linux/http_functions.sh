#!/bin/bash

# ==============================================================================
# Practica-06: http_functions.sh
# Librería de funciones para aprovisionamiento web automatizado en Linux
# ==============================================================================

# Colores para la interfaz
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Función para validar entrada (evitar caracteres especiales y nulos)
validate_input() {
    local input="$1"
    if [[ -z "$input" || "$input" =~ [^a-zA-Z0-9._-] ]]; then
        return 1
    fi
    return 0
}

# Función para verificar si un puerto está ocupado
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null ; then
        return 1 # Puerto ocupado
    else
        return 0 # Puerto libre
    fi
}

# Función para validar que el puerto esté en el rango válido
is_reserved_port() {
    local port=$1
    if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        return 0 # Fuera de rango (inválido)
    fi
    return 1 # En rango (válido)
}

# Listar versiones dinámicamente (Adaptado para Mageia/DNF o URPMI)
get_versions() {
    local service=$1
    echo -e "${BLUE}Consultando versiones en repositorios de Mageia para $service...${NC}"
    
    if command -v dnf &> /dev/null; then
        # DNF es el estándar en Mageia moderno
        dnf --showduplicates list "$service" 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]' | head -n 5
    elif command -v urpmq &> /dev/null; then
        # Respaldo para urpmi
        urpmq -m "$service" | head -n 5
    else
        echo -e "${RED}[AVISO] No se detectó dnf ni urpmi. Escriba 'latest'.${NC}"
    fi
}

# Configuración de Seguridad General (Mageia/RedHat Paths)
apply_security_config() {
    local service=$1
    local web_root=$2
    
    echo -e "${BLUE}Aplicando endurecimiento (security hardening) para $service...${NC}"
    
    case $service in
        apache2|httpd)
            local CONF="/etc/httpd/conf/httpd.conf"
            [ ! -f "$CONF" ] && CONF="/etc/apache2/httpd.conf" # Fallback Mageia
            
            # Ocultar versión y firma
            sed -i "s/^ServerTokens .*/ServerTokens Prod/" "$CONF" 2>/dev/null || echo "ServerTokens Prod" >> "$CONF"
            sed -i "s/^ServerSignature .*/ServerSignature Off/" "$CONF" 2>/dev/null || echo "ServerSignature Off" >> "$CONF"
            echo "TraceEnable Off" >> "$CONF"
            
            systemctl restart httpd
            ;;
        nginx)
            sed -i "s/# server_tokens off;/server_tokens off;/" /etc/nginx/nginx.conf
            systemctl restart nginx
            ;;
    esac
}

# Crear página index.html simple
create_custom_index() {
    local service=$1
    local version=$2
    local port=$3
    local path=$4
    
    cat <<EOF > "$path/index.html"
Servidor: $service
Versión: $version
Puerto: $port
EOF
    chown -R www-data:www-data "$path" 2>/dev/null
}

# Instalación de Apache (Mageia: apache)
install_apache() {
    local version=$1
    local port=$2
    
    echo -e "${BLUE}Instalando Apache en Mageia...${NC}"
    dnf install -y apache 2>/dev/null || urpmi --auto apache
    
    # Cambiar puerto de forma robusta (maneja cualquier cantidad de espacios)
    sed -i "s/^Listen\s\+[0-9]\+/Listen $port/" /etc/httpd/conf/httpd.conf
    
    apply_security_config "httpd" "/var/www/html"
    create_custom_index "Apache/Mageia" "Latest" "$port" "/var/www/html"
    
    # Firewall Mageia (firewalld)
    firewall-cmd --permanent --add-port=$port/tcp 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    
    systemctl enable httpd
    systemctl restart httpd
    echo -e "${GREEN}Apache configurado en el puerto $port.${NC}"
}

# Instalación de Nginx (Mageia)
install_nginx() {
    local version=$1
    local port=$2
    
    echo -e "${BLUE}Instalando Nginx en Mageia...${NC}"
    dnf install -y nginx 2>/dev/null || urpmi --auto nginx
    
    # Cambiar puerto de forma robusta (IPv4 e IPv6, maneja cualquier número de puerto previo)
    sed -i "s/listen\s\+[0-9]\+;/listen $port;/" /etc/nginx/nginx.conf
    sed -i "s/listen\s\+\[::\]:[0-9]\+;/listen [::]:$port;/" /etc/nginx/nginx.conf
    
    apply_security_config "nginx" "/var/www/html"
    create_custom_index "Nginx/Mageia" "Latest" "$port" "/var/www/html"
    
    firewall-cmd --permanent --add-port=$port/tcp 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    
    systemctl enable nginx
    systemctl restart nginx
    echo -e "${GREEN}Nginx configurado en el puerto $port.${NC}"
}

# Instalación y configuración de Tomcat (MANUAL .tar.gz)
install_tomcat() {
    local port=$1
    local version="9.0.86" # Versión manual estable
    
    echo -e "${BLUE}Instalando Tomcat $version manualmente (Binarios)...${NC}"
    
    # 1. Crear usuario dedicado
    if ! id "tomcat" &>/dev/null; then
        useradd -m -U -d /opt/tomcat -s /bin/false tomcat
    fi
    
    # 2. Descargar y extraer
    cd /tmp
    wget -q https://archive.apache.org/dist/tomcat/tomcat-9/v$version/bin/apache-tomcat-$version.tar.gz
    mkdir -p /opt/tomcat
    tar xzvf apache-tomcat-$version.tar.gz -C /opt/tomcat --strip-components=1
    
    # 3. Permisos restringidos (Requerimiento de seguridad)
    chown -R tomcat:tomcat /opt/tomcat
    chmod -R 750 /opt/tomcat/conf
    
    # 4. Configurar puerto en server.xml
    sed -i "s/Connector port=\"8080\"/Connector port=\"$port\"/" /opt/tomcat/conf/server.xml
    
    # 5. Crear index personalizado
    create_custom_index "Tomcat" "$version" "$port" "/opt/tomcat/webapps/ROOT"
    
    # 6. Crear servicio systemd para manejo de variables de entorno
    cat <<EOF > /etc/systemd/system/tomcat.service
[Unit]
Description=Apache Tomcat 9 Web Application Container
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=/usr/lib/jvm/default-java"
Environment="CATALINA_PID=/opt/tomcat/temp/tomcat.pid"
Environment="CATALINA_HOME=/opt/tomcat"
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tomcat
    systemctl start tomcat
    
    ufw allow "$port/tcp" &>/dev/null
    echo -e "${GREEN}Tomcat configurado manualmente en el puerto $port.${NC}"
}

# Función para bajar servicios
stop_linux_service() {
    local service=$1
    echo -e "${BLUE}Bajando servicio $service...${NC}"
    case $service in
        apache2|httpd)
            systemctl stop httpd 2>/dev/null || systemctl stop apache2 2>/dev/null
            ;;
        nginx)
            systemctl stop nginx 2>/dev/null
            ;;
        tomcat)
            systemctl stop tomcat 2>/dev/null
            ;;
    esac
    echo -e "${GREEN}Servicio $service detenido.${NC}"
}

# Función para verificar estado y puertos de los servicios
check_services_status() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}       ESTADO DE LOS SERVICIOS WEB        ${NC}"
    echo -e "${BLUE}==========================================${NC}"
    printf "%-15s | %-12s | %-10s\n" "SERVICIO" "ESTADO" "PUERTO(S)"
    echo "------------------------------------------"

    # Lista de servicios a verificar
    local services=("httpd" "nginx" "tomcat")
    
    for srv in "${services[@]}"; do
        # Verificar estado
        local status=$(systemctl is-active "$srv" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            status_text="${GREEN}Corriendo${NC}"
            # Obtener puerto usando ss
            local ports=$(ss -tulpn 2>/dev/null | grep "$srv" | awk '{print $5}' | cut -d':' -f2 | sort -u | tr '\n' ',' | sed 's/,$//')
            [[ -z "$ports" ]] && ports="Desconocido"
        else
            status_text="${RED}Detenido${NC}"
            ports="-"
        fi
        printf "%-15s | %-21s | %-10s\n" "$srv" "$status_text" "$ports"
    done
    echo -e "${BLUE}==========================================${NC}"
}
