#!/bin/bash

# ==============================================================================
# Practica-07: main.sh
# Script principal para el aprovisionamiento web en Linux
# ==============================================================================

# Cargar funciones
source "$(dirname "$0")/http_functions.sh"

# Verificar privilegios de root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Este script debe ejecutarse como root (use sudo).${NC}"
   exit 1
fi

show_menu() {
    clear
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}   SISTEMA DE APROVISIONAMIENTO WEB (LINUX)   ${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo "1. Instalar Apache2"
    echo "2. Instalar Nginx"
    echo "3. Instalar Tomcat (v9)"
    echo "4. Salir"
    echo -e "${GREEN}==========================================${NC}"
    read -p "Seleccione una opción: " OPTION
}

while true; do
    show_menu
    
    case $OPTION in
        1)
            service="apache2"
            versions=$(get_versions "$service")
            echo -e "${BLUE}Versiones disponibles:${NC}"
            echo "$versions"
            read -p "Ingrese la versión exacta a instalar: " VERSION
            if ! validate_input "$VERSION"; then echo "Versión inválida"; continue; fi
            ;;
        2)
            service="nginx"
            versions=$(get_versions "$service")
            echo -e "${BLUE}Versiones disponibles:${NC}"
            echo "$versions"
            read -p "Ingrese la versión exacta a instalar: " VERSION
            if ! validate_input "$VERSION"; then echo "Versión inválida"; continue; fi
            ;;
        3)
            service="tomcat"
            VERSION="LTS (Repo)"
            ;;
        4)
            echo "Saliendo..."
            exit 0
            ;;
        *)
            echo "Opción inválida"
            sleep 2
            continue
            ;;
    esac

    # Solicitar puerto con validación y opción de retorno
    while true; do
        read -p "Ingrese el puerto de escucha (ej. 80, 8080): " PORT
        
        # Validar si es numérico
        if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}[ERROR] El puerto debe ser un número.${NC}"
            read -p "¿Deseas intentar con otro puerto? (s/n): " RETRY
            if [[ "$RETRY" =~ ^[nN]$ ]]; then continue 2; fi
            continue
        fi
        
        # Validar si es reservado o está ocupado
        REASON=""
        if is_reserved_port "$PORT"; then
            REASON="está RESERVADO (Puerto Protegido o 444)"
        elif ! check_port "$PORT"; then
            REASON="ya está siendo OCUPADO por otro servicio"
        fi

        if [[ -n "$REASON" ]]; then
            echo -e "${RED}[ALERTA] El puerto $PORT $REASON.${NC}"
            read -p "¿Deseas intentar con otro puerto? (s/n): " RETRY
            if [[ "$RETRY" =~ ^[nN]$ ]]; then 
                continue 2 # Regresa al inicio del bucle del menú
            else
                continue # Vuelve a pedir el puerto
            fi
        fi

        # Si llegamos aquí, el puerto es válido
        break
    done

    # Proceder con la instalación
    case $service in
        apache2)
            install_apache "$VERSION" "$PORT"
            ;;
        nginx)
            install_nginx "$VERSION" "$PORT"
            ;;
        tomcat)
            install_tomcat "$PORT"
            ;;
    esac
    
    read -p "Presione Enter para continuar..." dummy
done
