#!/bin/bash

# ==============================================================================
# Practica-07: http_functions.sh
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

# Función para validar que el puerto no sea reservado
is_reserved_port() {
    local port=$1
    # Lista de puertos reservados y el 444 solicitado para la demostración
    local reserved=(21 22 23 25 53 110 143 443 444 3306 5432)
    for p in "${reserved[@]}"; do
        if [ "$port" -eq "$p" ]; then
            return 0 # Es reservado/bloqueado
        fi
    done
    return 1 # No es reservado
}

# Listar versiones dinámicamente
get_versions() {
    local service=$1
    echo -e "${BLUE}Consultando versiones disponibles para $service...${NC}"
    if command -v apt-cache &> /dev/null; then
        apt-cache madison "$service" | awk '{print $3}' | head -n 5
    elif command -v apt &> /dev/null; then
        apt list -a "$service" 2>/dev/null | grep -v "Listing" | awk '{print $2}' | head -n 5
    else
        echo -e "${RED}[ERROR] No se encontró apt-cache ni apt para listar versiones.${NC}"
        echo "Usando versión por defecto: latest"
    fi
}

# Configuración de Seguridad General (Headers y Ocultación)
apply_security_config() {
    local service=$1
    local web_root=$2
    
    echo -e "${BLUE}Aplicando configuraciones de seguridad para $service...${NC}"
    
    case $service in
        apache2)
            # Ocultar versión y firma
            sed -i "s/ServerTokens .*/ServerTokens Prod/" /etc/apache2/conf-available/security.conf
            sed -i "s/ServerSignature .*/ServerSignature Off/" /etc/apache2/conf-available/security.conf
            
            # Encabezados de Seguridad
            if ! grep -q "X-Frame-Options" /etc/apache2/conf-available/security.conf; then
                echo "Header set X-Frame-Options \"SAMEORIGIN\"" >> /etc/apache2/conf-available/security.conf
                echo "Header set X-Content-Type-Options \"nosniff\"" >> /etc/apache2/conf-available/security.conf
            fi
            
            # Deshabilitar métodos TRACE
            echo "TraceEnable Off" >> /etc/apache2/apache2.conf
            
            a2enmod headers
            systemctl restart apache2
            ;;
        nginx)
            # Ocultar versión
            sed -i "s/# server_tokens off;/server_tokens off;/" /etc/nginx/nginx.conf
            
            # Agregar headers de seguridad en el bloque server (esto se hace en el sitio específico habitualmente)
            # Lo ideal es agregarlo al snippet de configuración general
            ;;
    esac
}

# Crear página index.html personalizada
create_custom_index() {
    local service=$1
    local version=$2
    local port=$3
    local path=$4
    
    cat <<EOF > "$path/index.html"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Servidor $service</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f0f2f5; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .card { background: white; padding: 2rem; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); text-align: center; }
        h1 { color: #1a73e8; }
        .info { font-size: 1.2rem; margin: 10px 0; color: #5f6368; }
        .badge { background: #e8f0fe; color: #1967d2; padding: 5px 12px; border-radius: 20px; font-weight: bold; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Servidor Provisionado</h1>
        <p class="info">Servidor: <span class="badge">$service</span></p>
        <p class="info">Versión: <span class="badge">$version</span></p>
        <p class="info">Puerto: <span class="badge">$port</span></p>
    </div>
</body>
</html>
EOF
    chown -R www-data:www-data "$path"
}

# Instalación y configuración de Apache
install_apache() {
    local version=$1
    local port=$2
    
    echo -e "${BLUE}Instalando Apache2 versión $version...${NC}"
    apt-get install -y "apache2=$version"
    
    # Cambiar puerto
    sed -i "s/Listen 80/Listen $port/" /etc/apache2/ports.conf
    sed -i "s/<VirtualHost \*:80>/<VirtualHost \*:$port>/" /etc/apache2/sites-available/000-default.conf
    
    # Seguridad
    apply_security_config "apache2" "/var/www/html"
    create_custom_index "Apache2" "$version" "$port" "/var/www/html"
    
    # Firewall
    ufw allow "$port/tcp"
    systemctl restart apache2
    echo -e "${GREEN}Apache2 configurado correctamente en el puerto $port.${NC}"
}

# Instalación y configuración de Nginx
install_nginx() {
    local version=$1
    local port=$2
    
    echo -e "${BLUE}Instalando Nginx versión $version...${NC}"
    apt-get install -y "nginx=$version"
    
    # Cambiar puerto en default config
    sed -i "s/listen 80 default_server;/listen $port default_server;/" /etc/nginx/sites-available/default
    sed -i "s/listen \[::\]:80 default_server;/listen \[::\]:$port default_server;/" /etc/nginx/sites-available/default
    
    # Seguridad y Headers (Injectar en el server block)
    sed -i "/server_name _;/a \    add_header X-Frame-Options SAMEORIGIN;\n    add_header X-Content-Type-Options nosniff;" /etc/nginx/sites-available/default
    
    apply_security_config "nginx" "/var/www/html"
    create_custom_index "Nginx" "$version" "$port" "/var/www/html"
    
    # Firewall
    ufw allow "$port/tcp"
    systemctl restart nginx
    echo -e "${GREEN}Nginx configurado correctamente en el puerto $port.${NC}"
}

# Instalación y configuración de Tomcat
install_tomcat() {
    local port=$1
    echo -e "${BLUE}Instalando Tomcat (Manual deployment)...${NC}"
    
    # Crear usuario dedicado
    if ! id "tomcat" &>/dev/null; then
        useradd -m -U -d /opt/tomcat -s /bin/false tomcat
    fi
    
    # Descargar última versión de Tomcat 9 por ejemplo (dinámico)
    local tomcat_url=$(curl -s https://api.github.com/repos/apache/tomcat/releases/latest | grep "browser_download_url.*zip" | cut -d : -f 2,3 | tr -d \" | xargs)
    # Por temas de la práctica usaremos una versión estable de repositorio si está disponible o descarga directa
    # Tomcat suele ser manual o vía apt. Usaremos apt para simplicidad de versión.
    apt-get install -y tomcat9
    
    # Puerto
    sed -i "s/Connector port=\"8080\"/Connector port=\"$port\"/" /etc/tomcat9/server.xml
    
    # Seguridad y Permisos
    chown -R tomcat:tomcat /var/lib/tomcat9/webapps
    chmod -R 750 /var/lib/tomcat9/webapps
    
    # Cortafuegos
    ufw allow "$port/tcp"
    systemctl restart tomcat9
    
    # Nota: Index en Tomcat es distinto, se genera en ROOT/index.jsp o html
    create_custom_index "Tomcat" "9.x" "$port" "/var/lib/tomcat9/webapps/ROOT"
    
    echo -e "${GREEN}Tomcat 9 configurado correctamente en el puerto $port.${NC}"
}
