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
            [ ! -f "$CONF" ] && CONF="/etc/apache2/httpd.conf"
            
            # Ocultar versión y firma de forma segura (evita duplicados)
            sed -i "s/^ServerTokens .*/ServerTokens Prod/" "$CONF" 2>/dev/null
            grep -q "^ServerTokens Prod" "$CONF" || echo "ServerTokens Prod" >> "$CONF"
            
            sed -i "s/^ServerSignature .*/ServerSignature Off/" "$CONF" 2>/dev/null
            grep -q "^ServerSignature Off" "$CONF" || echo "ServerSignature Off" >> "$CONF"
            
            grep -q "^TraceEnable Off" "$CONF" || echo "TraceEnable Off" >> "$CONF"
            
            # Verificar sintaxis antes de intentar arrancar
            echo -e "${BLUE}Validando configuración de Apache...${NC}"
            if apachectl configtest &>/dev/null; then
                systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            else
                echo -e "${RED}[ALERTA] Error de sintaxis en httpd.conf detectado:${NC}"
                apachectl configtest
            fi
            ;;
        nginx)
            # Hardening Nginx
            sed -i "s/server_tokens on;/server_tokens off;/" /etc/nginx/nginx.conf
            grep -q "server_tokens off;" /etc/nginx/nginx.conf || sed -i '/http {/a \    server_tokens off;' /etc/nginx/nginx.conf
            
            if nginx -t &>/dev/null; then
                systemctl restart nginx
            else
                echo -e "${RED}[ALERTA] Error de sintaxis en nginx.conf detectado.${NC}"
                nginx -t
            fi
            ;;
    esac
}

# Crear página index.html simple
create_custom_index() {
    local service=$1
    local version=$2
    local port=$3
    local path=$4
    
    # Asegurar que el directorio existe (evita errores tras una purga)
    mkdir -p "$path"
    
    cat <<EOF > "$path/index.html"
Servidor: $service
Versión: $version
Puerto: $port
EOF
    # Ajustar permisos para Mageia (apache) y fallback para otros (www-data)
    chown -R apache:apache "$path" 2>/dev/null || chown -R www-data:www-data "$path" 2>/dev/null
}

# Instalación de Apache (Mageia: apache)
install_apache() {
    local version=$1
    local port=$2
    
    echo -e "${BLUE}Instalando Apache en Mageia...${NC}"
    dnf install -y apache 2>/dev/null || urpmi --auto apache
    
    # [FUERZA BRUTA] Cambiar Listen en TODOS los archivos de configuración
    echo -e "${BLUE}Forzando cambio de puerto en todos los archivos de Apache...${NC}"
    find /etc/httpd -name "*.conf" -exec sed -i "s/^Listen\s\+[0-9]\+/Listen $port/g" {} +
    # Fallback para rutas alternativas
    find /etc/apache2 -name "*.conf" -exec sed -i "s/^Listen\s\+[0-9]\+/Listen $port/g" {} + 2>/dev/null
    
    # Asegurar directorio raíz antes de validar
    mkdir -p /var/www/html
    
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
    
    # [FUERZA BRUTA] Cambiar listen en TODOS los archivos de configuración (v4 y v6)
    echo -e "${BLUE}Forzando cambio de puerto en todos los archivos de Nginx...${NC}"
    find /etc/nginx -name "*.conf" -exec sed -i "s/listen\s\+[0-9]\+/listen $port/g" {} +
    find /etc/nginx -name "*.conf" -exec sed -i "s/listen\s\+\[::\]:[0-9]\+;/listen [::]:$port;/g" {} +
    
    # Asegurar directorio raíz antes de validar
    mkdir -p /var/www/html
    
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
    
    echo -e "${BLUE}Preparando entorno para Tomcat...${NC}"
    
    # 0. Instalar Java (Requisito indispensable)
    if ! command -v java &>/dev/null; then
        echo -e "${BLUE}Instalando Java (OpenJDK)...${NC}"
        dnf install -y java-1.8.0-openjdk-devel 2>/dev/null || urpmi --auto java-1.8.0-openjdk-devel
    fi
    
    # Detectar JAVA_HOME dinámicamente en Mageia
    local java_path=$(readlink -f $(command -v java) | sed "s:/bin/java::")
    echo -e "${BLUE}JAVA_HOME detectado en: $java_path${NC}"
    
    echo -e "${BLUE}Instalando Tomcat $version manualmente (Binarios)...${NC}"
    
    # 1. Crear usuario dedicado
    if ! id "tomcat" &>/dev/null; then
        useradd -m -U -d /opt/tomcat -s /bin/false tomcat 2>/dev/null
    fi
    
    # 2. Descargar y extraer
    cd /tmp
    [ ! -f "apache-tomcat-$version.tar.gz" ] && wget -q https://archive.apache.org/dist/tomcat/tomcat-9/v$version/bin/apache-tomcat-$version.tar.gz
    mkdir -p /opt/tomcat
    tar xzvf apache-tomcat-$version.tar.gz -C /opt/tomcat --strip-components=1 > /dev/null
    
    # 3. Permisos restringidos (Requerimiento de seguridad)
    chown -R tomcat:tomcat /opt/tomcat
    chmod -R 750 /opt/tomcat/conf
    
    # 4. Configurar puerto en server.xml
    sed -i "s/Connector port=\"8080\"/Connector port=\"$port\"/" /opt/tomcat/conf/server.xml
    
    # 5. Crear index personalizado
    create_custom_index "Tomcat" "$version" "$port" "/opt/tomcat/webapps/ROOT"
    
    # 6. Crear servicio systemd
    cat <<EOF > /etc/systemd/system/tomcat.service
[Unit]
Description=Apache Tomcat 9 Web Application Container
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=$java_path"
Environment="CATALINA_PID=/opt/tomcat/temp/tomcat.pid"
Environment="CATALINA_HOME=/opt/tomcat"
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tomcat 2>/dev/null
    systemctl start tomcat
    
    # Firewall Mageia
    firewall-cmd --permanent --add-port=$port/tcp 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    
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

# Función para eliminación total de servicios (Purge)
purge_services() {
    local service=$1
    echo -e "${RED}Eliminando por completo $service (registros, configs y binarios)...${NC}"
    
    case $service in
        apache2|httpd)
            systemctl stop httpd 2>/dev/null
            dnf remove -y apache 2>/dev/null || urpme apache 2>/dev/null
            rm -rf /etc/httpd /var/www/html /var/log/httpd
            ;;
        nginx)
            systemctl stop nginx 2>/dev/null
            dnf remove -y nginx 2>/dev/null || urpme nginx 2>/dev/null
            rm -rf /etc/nginx /var/www/html /var/log/nginx /usr/share/nginx
            ;;
        tomcat)
            systemctl stop tomcat 2>/dev/null
            rm -rf /opt/tomcat /etc/systemd/system/tomcat.service
            systemctl daemon-reload
            if id "tomcat" &>/dev/null; then userdel -r tomcat 2>/dev/null; fi
            ;;
    esac
    echo -e "${GREEN}Limpieza de $service completada.${NC}"
}
