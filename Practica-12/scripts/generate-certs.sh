#!/bin/bash
# ================================================================
# Script de Generación de Certificados TLS - Práctica 12
# ================================================================

# Magia para asegurarnos de que siempre trabajamos en la carpeta correcta (Practica-12)
# sin importar si lo ejecutas desde adentro de scripts/ o desde afuera.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

DOMAIN="reprobados.com"
HOSTNAME="mail"
FQDN="${HOSTNAME}.${DOMAIN}"
SSL_DIR="config/ssl"
CA_DIR="${SSL_DIR}/demoCA"
DAYS=3650   # Válidos por 10 años

VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

echo "================================================================"
echo -e "${AZUL}  Generador de Certificados TLS - Servidor de Correo${NC}"
echo -e "${AZUL}  Directorio base: ${PROJECT_ROOT}${NC}"
echo "================================================================"

# Limpiar errores de ejecuciones previas (como la carpeta en lugares equivocados)
rm -rf "$SSL_DIR" scripts/config

echo -e "${AMARILLO}[1/4] Creando estructura de directorios...${NC}"
mkdir -p "$CA_DIR"

echo -e "${AMARILLO}[2/4] Generando CA (Autoridad Certificadora)...${NC}"
openssl genrsa -out "${CA_DIR}/cakey.pem" 2048 2>/dev/null
openssl req -new -x509 -days ${DAYS} -key "${CA_DIR}/cakey.pem" -out "${CA_DIR}/cacert.pem" -subj "/C=MX/O=Reprobados/CN=CA-reprobados" 2>/dev/null

echo -e "${AMARILLO}[3/4] Generando clave y certificado del servidor...${NC}"
openssl genrsa -out "${SSL_DIR}/${FQDN}-key.pem" 2048 2>/dev/null
openssl req -new -key "${SSL_DIR}/${FQDN}-key.pem" -out "${SSL_DIR}/${FQDN}-req.pem" -subj "/C=MX/O=Reprobados/CN=${FQDN}" 2>/dev/null
# ¡Aquí generamos el archivo con el guion (-) exacto que espera el servidor!
openssl x509 -req -days ${DAYS} -in "${SSL_DIR}/${FQDN}-req.pem" -CA "${CA_DIR}/cacert.pem" -CAkey "${CA_DIR}/cakey.pem" -CAcreateserial -out "${SSL_DIR}/${FQDN}-cert.pem" 2>/dev/null

# Limpieza de temporales
rm -f "${SSL_DIR}/${FQDN}-req.pem"

echo -e "${VERDE}[4/4] ¡Listo! Certificados creados correctamente en ${SSL_DIR}/${NC}"
echo ""
echo -e "${AMARILLO}Ahora ejecuta:${NC}"
echo "docker compose down && docker compose up -d"
echo "================================================================"
