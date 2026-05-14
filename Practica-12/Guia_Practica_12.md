# Guía de Implementación - Práctica 12 y 13
# Servidor de Correo Privado + Portal Webmail con Docker

## ¿Qué vamos a construir?

Un servidor de correo electrónico **completamente autónomo** que nunca envía los datos de la empresa a terceros. Incluye un portal web moderno para leer el correo desde el navegador.

| Componente | Función | Protocolo |
|---|---|---|
| **Postfix** | Envía y recibe correos entre servidores | SMTP (puerto 25, 587, 465) |
| **Dovecot** | Gestiona los buzones de cada usuario | IMAP (puerto 993) |
| **Rspamd** | Detecta y bloquea correo spam y malicioso | Interno |
| **Fail2ban** | Bloquea IPs tras múltiples intentos fallidos | Interno (iptables) |
| **OpenDKIM** | Firma digitalmente cada correo saliente | Interno (DNS TXT) |
| **Roundcube** | Portal web para leer correo en el navegador | HTTP (puerto 8090) |

## 📁 Archivos del Proyecto

```
Practica-12/
├── docker-compose.yml    → Definición de todos los servicios
├── .env                  → Variables secretas (dominio, opciones)
├── config/               → Carpeta creada automáticamente por el servidor
└── scripts/
    └── backup.sh         → Respaldo automático diario de buzones
```

---

## 🚀 PASO 1: Subir el proyecto al servidor Linux

**¿Qué hace?** Transfiere los archivos al servidor donde correrá el sistema de correo.

En tu **PC Windows**, abre PowerShell y ejecuta:
```powershell
# Subir toda la carpeta Practica-12 al servidor Linux
scp -r "C:\Users\alfre\Desktop\redes-sistemas-virtualizadas\Practica-12" root@IP_DE_TU_LINUX:~/Files/redes-sistemas-virtualizadas/
```

Luego conéctate al servidor:
```bash
ssh root@IP_DE_TU_LINUX
cd ~/Files/redes-sistemas-virtualizadas/Practica-12
```

---

## 🔧 PASO 2: Verificar el archivo .env

**¿Qué hace?** Este archivo activa todos los módulos de seguridad del servidor sin escribir contraseñas en el código principal. Es el equivalente a la "configuración maestra" del sistema.

```bash
# Verificar que el archivo existe y tiene el contenido correcto
cat .env
```

Deberías ver las variables con `ENABLE_RSPAMD=1`, `ENABLE_FAIL2BAN=1`, etc.

---

## 🏗️ PASO 3: Levantar la infraestructura

**¿Qué hace?** Descarga las imágenes de Docker y arranca todos los servicios: el servidor de correo (con Postfix, Dovecot, Rspamd, Fail2ban, OpenDKIM) y el portal web (Roundcube).

```bash
# Levantar todos los contenedores en segundo plano
docker compose up -d

# Esperar ~60 segundos y verificar que están corriendo
docker compose ps
```

**Resultado esperado:** Dos contenedores en estado `Up`:
- `servidor_correo`
- `portal_webmail`

---

## 👤 PASO 4: Crear cuentas de correo

**¿Qué hace?** Añade los buzones de los dos usuarios que usaremos en las pruebas. Los datos se guardan cifrados dentro del volumen `mail_data`.

```bash
# Crear la cuenta del director
docker exec -it servidor_correo setup email add director@reprobados.com Director2026!

# Crear la cuenta del administrador
docker exec -it servidor_correo setup email add admin@reprobados.com Admin2026!

# Verificar que ambas cuentas se crearon
docker exec -it servidor_correo setup email list
```

---

## 🔑 PASO 5: Generar la clave DKIM

**¿Qué hace?** DKIM es como un sello notarial digital. Genera un par de claves: la **privada** firma cada correo saliente, y la **pública** se publica en el DNS para verificar autenticidad.

```bash
# Generar el par de claves DKIM para el dominio
docker exec -it servidor_correo setup config dkim

# Ver la clave pública (necesaria para el registro DNS TXT)
cat config/opendkim/keys/reprobados.com/mail.txt
```

---

## 🌐 PASO 6: Configurar registros DNS

**¿Qué hace?** Indica a internet qué servidor recibe correos del dominio y quién está autorizado para enviarlos.

```bash
# Añadir resolución local en el servidor Linux
echo "IP_DE_TU_SERVIDOR    mail.reprobados.com" >> /etc/hosts
echo "IP_DE_TU_SERVIDOR    reprobados.com" >> /etc/hosts
```

**Tabla de registros DNS:**

| Tipo | Nombre | Valor |
|------|--------|-------|
| `A` | `mail.reprobados.com` | `IP_DEL_SERVIDOR` |
| `MX` | `reprobados.com` | `10 mail.reprobados.com` |
| `TXT` | `reprobados.com` | `v=spf1 mx -all` |
| `TXT` | `mail._domainkey.reprobados.com` | *(contenido del archivo mail.txt del PASO 5)* |

---

## 💾 PASO 7: Activar el script de respaldo automático

**¿Qué hace?** Programa una copia de seguridad comprimida de todos los buzones cada 24 horas para recuperación ante desastres.

```bash
# Dar permisos de ejecución al script
chmod +x scripts/backup.sh

# Probar el script manualmente
./scripts/backup.sh

# Programar ejecución automática diaria a las 2:00 AM
(crontab -l 2>/dev/null; echo "0 2 * * * $(pwd)/scripts/backup.sh >> /var/log/mail_backup.log 2>&1") | crontab -

# Verificar que el cron se registró
crontab -l
```

---

## 📧 PASO 8: Configurar Thunderbird (cliente de escritorio)

**¿Qué hace?** Thunderbird se conecta a tu servidor privado para enviar (SMTP) y leer correos (IMAP).

1. Instalar **Mozilla Thunderbird**: https://www.thunderbird.net
2. Seleccionar **"Configurar manualmente"**

| Campo | Valor |
|-------|-------|
| **Correo** | director@reprobados.com |
| **Contraseña** | Director2026! |
| **Servidor IMAP** | IP_DEL_SERVIDOR, Puerto 993, SSL/TLS |
| **Servidor SMTP** | IP_DEL_SERVIDOR, Puerto 587, STARTTLS |

> ⚠️ Aceptar la excepción de seguridad del certificado autofirmado.

---

## 🌍 PASO 9: Acceder al Portal Webmail (Roundcube)

**¿Qué hace?** Roundcube es la interfaz web — similar a Gmail pero en tu servidor privado.

Desde tu navegador en Windows:
```
http://IP_DE_TU_SERVIDOR:8090
```

- **Usuario**: `director` *(sin @reprobados.com — se añade automáticamente)*
- **Contraseña**: `Director2026!`

---

## 🧪 PROTOCOLO DE PRUEBAS DE ACEPTACIÓN

### Prueba 12.1: Envío y Recepción Local

**¿Qué demuestra?** Que el servidor de correo funciona y los mensajes viajan entre cuentas.

```bash
# Enviar correo de prueba desde el servidor
docker exec -it servidor_correo swaks \
  --to admin@reprobados.com \
  --from director@reprobados.com \
  --server localhost --port 587 \
  --auth --auth-user director@reprobados.com \
  --auth-password Director2026! \
  --tls \
  --body "Prueba 12.1 - Correo enviado desde el servidor privado"
```

Verificar en Thunderbird o Roundcube que `admin@reprobados.com` recibió el correo.

📸 **Captura**: El correo recibido en la bandeja de entrada.

---

### Prueba 12.2: Auditoría de Registros (Logging)

**¿Qué demuestra?** Trazabilidad completa de cada mensaje: quién lo envió, cuándo y desde qué IP.

```bash
# Ver registros en tiempo real (envía un correo en otra terminal)
docker exec -it servidor_correo tail -f /var/log/mail/mail.log

# Buscar registros de un usuario específico
docker exec servidor_correo grep "director@reprobados.com" /var/log/mail/mail.log
```

**Resultado esperado:**
```
sasl_username=director@reprobados.com
to=<admin@reprobados.com>, status=sent
```

📸 **Captura**: El log mostrando el flujo completo del mensaje.

---

### Prueba 12.3: Verificación de Fail2ban

**¿Qué demuestra?** El sistema bloquea automáticamente las IPs con intentos fallidos de autenticación.

```bash
# Simular 5 intentos fallidos de login
for i in 1 2 3 4 5; do
  docker exec servidor_correo swaks \
    --to admin@reprobados.com \
    --server localhost --port 587 \
    --auth --auth-user fake@reprobados.com \
    --auth-password "MalaClave${i}" 2>&1 | grep -E "reject|AUTH"
  sleep 2
done

# Verificar que la IP fue bloqueada
docker exec servidor_correo fail2ban-client status postfix-sasl
```

📸 **Captura**: La salida de `fail2ban-client status` con la IP bloqueada.

---

### Prueba 12.4 / 13.4: Integridad de Respaldo

**¿Qué demuestra?** Recuperación total de datos después de un desastre.

```bash
# 1. Enviar un correo memorable (asunto "CORREO ANTES DEL DESASTRE")

# 2. Crear el respaldo
./scripts/backup.sh

# 3. Simular desastre — destruir los volúmenes
docker compose down
docker volume rm practica-12_mail_data practica-12_mail_state

# 4. Levantar de nuevo (buzones vacíos)
docker compose up -d

# 5. Restaurar desde el respaldo
ULTIMO=$(ls -t /var/backups/mail/mail_backup_*.tar.gz | head -1)
docker run --rm \
  --volumes-from servidor_correo \
  -v /var/backups/mail:/backup \
  alpine:latest \
  sh -c "cd / && tar xzf /backup/$(basename $ULTIMO)"

# 6. Reiniciar el servidor de correo
docker compose restart mailserver

# 7. Verificar en Thunderbird/Roundcube que el correo reapareció
```

📸 **Captura**: El correo restaurado visible en el cliente.

---

### Prueba 13.5: Inicio de Sesión en el Portal Web

**¿Qué demuestra?** Que Roundcube está integrado con el servidor de correo.

1. Abrir: `http://IP_DEL_SERVIDOR:8090`
2. Usuario: `director` | Contraseña: `Director2026!`
3. Verificar que carga la bandeja de entrada con los correos existentes

📸 **Captura**: La interfaz de Roundcube con la bandeja de entrada.

---

### Prueba 13.6: Envío de Adjuntos desde el Portal

**¿Qué demuestra?** Que el webmail envía archivos adjuntos con integridad.

1. En Roundcube → **Redactar**
2. Destinatario: `admin@reprobados.com`
3. Adjuntar cualquier archivo (imagen, PDF)
4. Enviar y verificar que `admin` puede descargarlo correctamente

📸 **Captura**: El correo recibido con el adjunto en Roundcube.

---

### Prueba 13.7: Persistencia de Preferencias del Webmail

**¿Qué demuestra?** Que el volumen `roundcube_db` guarda las preferencias del usuario.

```bash
# Paso 1: En Roundcube → Configuración → cambiar idioma o agregar contacto

# Paso 2: Reiniciar el contenedor del webmail
docker compose restart roundcube

# Paso 3: Volver a entrar y verificar que el cambio persiste
```

📸 **Captura**: Las preferencias persistiendo después del reinicio.

---

## 📋 Referencia Rápida de Comandos

```bash
# Listar cuentas de correo
docker exec servidor_correo setup email list

# Cambiar contraseña de usuario
docker exec servidor_correo setup email update director@reprobados.com NuevaContra!

# Ver logs en tiempo real
docker exec servidor_correo tail -f /var/log/mail/mail.log

# Ver IPs bloqueadas
docker exec servidor_correo fail2ban-client status postfix-sasl

# Desbloquear una IP
docker exec servidor_correo fail2ban-client set postfix-sasl unbanip IP_A_DESBLOQUEAR

# Ver respaldos disponibles
ls -lh /var/backups/mail/
```

---

¡Listo! Con esto tienes un servidor de correo corporativo completo con cifrado, antispam, protección contra intrusos, auditoría y respaldos — todo bajo control total de la organización.
