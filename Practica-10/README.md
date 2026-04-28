# Práctica 10: Migración de Servicios Esenciales a Contenedores

Esta práctica consiste en la migración de un servidor web, una base de datos PostgreSQL y un servidor de archivos FTP hacia contenedores Docker, implementando buenas prácticas de seguridad (sin usuario root, sin *server tokens*), límites de recursos (RAM y CPU), y persistencia de datos mediante volúmenes.

## Arquitectura

- **Red Personalizada:** `infra_red` (172.20.0.0/16).
- **Servidor Web (Nginx en Alpine):** Corre bajo el usuario no administrativo `nginx`, deshabilitando firmas (server tokens) y sirviendo una web estática en el puerto 80.
- **Base de Datos (PostgreSQL):** Base de datos persistente con un sidecar container (`db_backup`) que realiza un volcado de la información al host cada 24 horas.
- **Servidor FTP (vsftpd):** Comparte el mismo volumen que el servidor web (`web_content`), de modo que los archivos/instaladores subidos vía FTP son inmediatamente visibles desde el navegador.

## Cómo Iniciar

1. Abre una terminal en esta carpeta (`Practica-10`).
2. Ejecuta:
   ```bash
   docker-compose up -d --build
   ```
3. Verifica que los servicios estén corriendo:
   ```bash
   docker-compose ps
   ```

---

# Protocolo de Pruebas (Guía de Validación)

El estudiante debe ejecutar y documentar las siguientes 4 pruebas para validar el correcto funcionamiento de los servicios y las políticas aplicadas.

### Prueba 10.1 (Persistencia de BD)
**Objetivo:** Verificar que la base de datos mantiene su información incluso si el contenedor es destruido.
1. Ingresa a la consola de PostgreSQL:
   ```bash
   docker exec -it postgres_db psql -U admin -d userdb
   ```
2. Crea una tabla de prueba e inserta datos:
   ```sql
   CREATE TABLE prueba_persistencia (id SERIAL, nombre VARCHAR(50));
   INSERT INTO prueba_persistencia (nombre) VALUES ('Dato Critico 1');
   \q
   ```
3. Elimina forzosamente el contenedor de la base de datos:
   ```bash
   docker rm -f postgres_db
   ```
4. Vuelve a levantar los contenedores:
   ```bash
   docker-compose up -d
   ```
5. Ingresa nuevamente a PostgreSQL y verifica que los datos siguen ahí:
   ```bash
   docker exec -it postgres_db psql -U admin -d userdb -c "SELECT * FROM prueba_persistencia;"
   ```
   **Criterio de éxito:** La consulta devuelve la tabla con el registro "Dato Critico 1".

### Prueba 10.2 (Aislamiento de Red)
**Objetivo:** Verificar que los servicios están comunicados internamente en su propia red `infra_red` por resolución de nombres DNS de Docker.
1. Ingresa a la terminal del servidor web interactivo:
   ```bash
   docker exec -it web_server /bin/sh
   ```
2. Ejecuta un ping hacia el nombre del contenedor de la base de datos (`postgres_db` o el servicio `db`):
   ```bash
   ping -c 4 db
   ```
   **Criterio de éxito:** Obtienes respuesta PING desde la IP interna (segmento `172.20.X.X`), confirmando que la red Bridge personalizada conecta exitosamente los contenedores.

### Prueba 10.3 (Permisos FTP y Volumen Compartido)
**Objetivo:** Validar la carga de archivos vía FTP (`web_content`) y su visibilidad en el Servidor Web.
1. Desde tu equipo Host (o cliente FileZilla), conéctate al servidor FTP usando:
   - **Host:** `localhost` (o IP de tu máquina)
   - **Usuario:** `administrador`
   - **Contraseña:** `admin123`
   - **Puerto:** `21`
2. Sube un archivo de prueba (ej. `instalador.exe` o `imagen.png`).
3. Abre tu navegador web y dirígete a: `http://localhost/instalador.exe`
   **Criterio de éxito:** El navegador logra descargar/visualizar el archivo que subiste por FTP, comprobando que ambos contenedores comparten el mismo volumen y los permisos son correctos.

### Prueba 10.4 (Límites de Recursos)
**Objetivo:** Validar que las restricciones de Memoria RAM (512MB/256MB) y CPU están activas, previniendo que un proceso malicioso afecte al host.
1. Ejecuta el comando de monitoreo de Docker:
   ```bash
   docker stats --no-stream
   ```
2. **Criterio de éxito:** Se debe evidenciar en la columna `MEM USAGE / LIMIT` que el contenedor `web_server` y `postgres_db` tienen un límite estricto fijado en **512MiB**, y el `ftp_server` en **256MiB**, coincidiendo con lo estipulado en el archivo `docker-compose.yml`. Captura esta pantalla para el reporte.
