#!/bin/bash
# ================================================================
# Script de Respaldo de Buzones de Correo - Práctica 12
# Actividad: Resiliencia y Respaldos (Prueba 12.4 / 13.4)
#
# INSTALACIÓN EN CRON (ejecución diaria a las 2:00 AM):
#   crontab -e
#   Añadir: 0 2 * * * /root/Files/redes-sistemas-virtualizadas/Practica-12/scripts/backup.sh >> /var/log/mail_backup.log 2>&1
# ================================================================

BACKUP_DIR="/var/backups/mail"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CONTAINER="servidor_correo"
MAX_BACKUPS=7   # Conservar solo los últimos 7 respaldos (1 semana)

# --- Colores para la salida en consola ---
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
NC='\033[0m' # Sin color

echo "================================================================"
echo -e "${AMARILLO}[$(date '+%Y-%m-%d %H:%M:%S')] Iniciando respaldo de buzones de correo...${NC}"
echo "================================================================"

# Paso 1: Crear el directorio de respaldo si no existe
mkdir -p "$BACKUP_DIR"
echo "[INFO] Directorio de respaldo: $BACKUP_DIR"

# Paso 2: Verificar que el contenedor de correo está activo
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo -e "${ROJO}[ERROR] El contenedor '${CONTAINER}' no está corriendo. Abortando respaldo.${NC}"
    exit 1
fi
echo -e "${VERDE}[OK] Contenedor '${CONTAINER}' activo.${NC}"

# Paso 3: Crear la copia de seguridad comprimida
# Se usa un contenedor Alpine temporal que monta los volúmenes del servidor
echo "[INFO] Creando archivo de respaldo comprimido..."
docker run --rm \
    --volumes-from "$CONTAINER" \
    -v "$BACKUP_DIR":/backup \
    alpine:latest \
    tar czf "/backup/mail_backup_${TIMESTAMP}.tar.gz" \
        /var/mail \
        /var/mail-state \
    2>/dev/null

# Paso 4: Verificar que el respaldo fue exitoso
if [ $? -eq 0 ]; then
    TAMANIO=$(du -sh "${BACKUP_DIR}/mail_backup_${TIMESTAMP}.tar.gz" | cut -f1)
    echo -e "${VERDE}[OK] Respaldo creado exitosamente:${NC}"
    echo "     Archivo : mail_backup_${TIMESTAMP}.tar.gz"
    echo "     Tamaño  : ${TAMANIO}"
    echo "     Ruta    : ${BACKUP_DIR}/"
else
    echo -e "${ROJO}[ERROR] Falló la creación del respaldo. Revisa el estado del contenedor.${NC}"
    exit 1
fi

# Paso 5: Limpiar respaldos antiguos (conservar solo los últimos MAX_BACKUPS)
TOTAL_RESPALDOS=$(ls "${BACKUP_DIR}"/mail_backup_*.tar.gz 2>/dev/null | wc -l)
if [ "$TOTAL_RESPALDOS" -gt "$MAX_BACKUPS" ]; then
    echo "[INFO] Eliminando respaldos antiguos (conservando los últimos ${MAX_BACKUPS})..."
    ls -t "${BACKUP_DIR}"/mail_backup_*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm --
    echo -e "${VERDE}[OK] Limpieza completada.${NC}"
fi

# Paso 6: Listar todos los respaldos disponibles
echo ""
echo "[INFO] Respaldos disponibles actualmente:"
ls -lh "${BACKUP_DIR}"/mail_backup_*.tar.gz 2>/dev/null | awk '{print "     " $5 "  " $9}'

echo ""
echo "================================================================"
echo -e "${VERDE}[$(date '+%Y-%m-%d %H:%M:%S')] Respaldo completado exitosamente.${NC}"
echo "================================================================"
