# Practica 07 - Linux Mageia Adaptation

Este directorio contiene los scripts de la Practica 07 adaptados para ejecutarse en **Linux Mageia**.

## Archivos
1. `p7_main_mageia.sh`: Script principal adaptado.
2. `p7_functions_mageia.sh`: Libreria de funciones con comandos especificos para Mageia (dnf/urpmi, systemctl, firewalld).

## Cambios Realizados para Mageia:
- **Gestor de Paquetes**: Se reemplazo `apk` por `dnf` (primario) y `urpmi` (secundario).
- **Gestion de Servicios**: Se reemplazo `openrc` por `systemctl`.
- **Nombres de Servicios**: Se ajusto el nombre de Apache de `apache2` a `httpd`.
- **Firewall**: Se añadio soporte para `firewall-cmd` (firewalld), que es el estándar en Mageia.
- **Dependencias**: Se actualizaron los nombres de los paquetes de desarrollo (ej. `apr-devel`, `pcre-devel`, `openssl-devel`).
- **Rutas de Configuración**: Se ajustaron las rutas tipicas de configuracion para sistemas basados en RPM.

## Requisitos
- Ejecutar como usuario **root**.
- Tener conexion a internet para la instalacion WEB o acceso a la red interna para la instalacion FTP.

## Ejecución
```bash
chmod +x p7_main_mageia.sh
./p7_main_mageia.sh
```
