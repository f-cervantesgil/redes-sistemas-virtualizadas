#!/bin/bash
# ================================================================
# Script de Generación de Certificados TLS - Práctica 12
# Genera los certificados autofirmados necesarios para el
# servidor de correo (Postfix + Dovecot) antes de arrancar.
#
# USO: chmod +x scripts/generate-certs.sh && ./scripts/generate-certs.sh
# ================================================================

DOMAIN="reprobados.com"
HOSTNAME="mail"
FQDN="${HOSTNAME}.${DOMAIN}"
SSL_DIR="./config/ssl"
CA_DIR="${SSL_DIR}/demoCA"
DAYS=3650   # Válidos por 10 años

VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

echo "================================================================"
echo -e "${AZUL}  Generador de Certificados TLS - Servidor de Correo${NC}"
echo -e "${AZUL}  Dominio: ${FQDN}${NC}"
echo "================================================================"
echo ""

# --- PASO 1: Crear estructura de directorios ---
echo -e "${AMARILLO}[1/5] Creando estructura de directorios...${NC}"
mkdir -p "$CA_DIR"
echo -e "${VERDE}      ✓ Directorio ${SSL_DIR} creado${NC}"

# --- PASO 2: Generar clave privada de la CA ---
echo ""
echo -e "${AMARILLO}[2/5] Generando clave privada de la Autoridad Certificadora (CA)...${NC}"
openssl genrsa -out "${CA_DIR}/cakey.pem" 2048 2>/dev/null
echo -e "${VERDE}      ✓ Clave de CA generada: ${CA_DIR}/cakey.pem${NC}"

# --- PASO 3: Generar certificado raíz de la CA ---
echo ""
echo -e "${AMARILLO}[3/5] Generando certificado raíz de la CA (válido ${DAYS} días)...${NC}"
openssl req -new -x509 -days ${DAYS} \
  -key "${CA_DIR}/cakey.pem" \
  -out "${CA_DIR}/cacert.pem" \
  -subj "/C=MX/ST=Estado/L=Ciudad/O=Reprobados Corp/OU=IT/CN=CA-${DOMAIN}" \
  2>/dev/null
echo -e "${VERDE}      ✓ Certificado CA generado: ${CA_DIR}/cacert.pem${NC}"

# --- PASO 4: Generar clave privada del servidor de correo ---
echo ""
echo -e "${AMARILLO}[4/5] Generando clave privada del servidor de correo...${NC}"
openssl genrsa -out "${SSL_DIR}/${FQDN}-key.pem" 2048 2>/dev/null
echo -e "${VERDE}      ✓ Clave del servidor generada: ${SSL_DIR}/${FQDN}-key.pem${NC}"

# --- PASO 5: Generar CSR y firmar el certificado del servidor ---
echo ""
echo -e "${AMARILLO}[5/5] Generando y firmando el certificado del servidor...${NC}"

# Crear solicitud de firma (CSR)
openssl req -new \
  -key "${SSL_DIR}/${FQDN}-key.pem" \
  -out "${SSL_DIR}/${FQDN}-req.pem" \
  -subj "/C=MX/ST=Estado/L=Ciudad/O=Reprobados Corp/OU=IT/CN=${FQDN}" \
  2>/dev/null

# Firmar el CSR con nuestra CA
openssl x509 -req -days ${DAYS} \
  -in "${SSL_DIR}/${FQDN}-req.pem" \
  -CA "${CA_DIR}/cacert.pem" \
  -CAkey "${CA_DIR}/cakey.pem" \
  -CAcreateserial \
  -out "${SSL_DIR}/${FQDN}.cert.pem" \
  2>/dev/null

# Limpiar el CSR temporal
rm -f "${SSL_DIR}/${FQDN}-req.pem"

echo -e "${VERDE}      ✓ Certificado firmado: ${SSL_DIR}/${FQDN}.cert.pem${NC}"

# --- VERIFICACIÓN FINAL ---
echo ""
echo "================================================================"
echo -e "${VERDE}  ✓ Certificados generados exitosamente:${NC}"
echo ""
echo "  $(ls -lh ${SSL_DIR}/${FQDN}-key.pem  | awk '{print $5, $9}')"
echo "  $(ls -lh ${SSL_DIR}/${FQDN}.cert.pem | awk '{print $5, $9}')"
echo "  $(ls -lh ${CA_DIR}/cacert.pem         | awk '{print $5, $9}')"
echo ""
echo -e "${AMARILLO}  Siguiente paso:${NC}"
echo "    docker compose down && docker compose up -d"
echo "================================================================"
