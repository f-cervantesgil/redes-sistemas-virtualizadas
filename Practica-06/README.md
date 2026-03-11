# Práctica 06: Sistema de Aprovisionamiento Web Automatizado (Mageia & Windows)

Esta solución integral destaca por su capacidad de desplegar servidores HTTP profesionales de forma silenciosa, gestionando dinámicamente versiones y aplicando políticas de seguridad avanzadas.

## Características Principales
- **Modularidad Extrema**: Uso obligatorio de librerías de funciones independientes para Linux y Windows.
- **Despliegue Dinámico**: Consulta en tiempo real de versiones mediante `dnf` (Mageia) y `Chocolatey` (Windows).
- **Seguridad y Hardening**:
  - **Ocultación de Banner**: Configuración de `ServerTokens Prod` y eliminación de cabeceras `X-Powered-By`.
  - **Security Headers**: Inyección automática de `X-Frame-Options` y `X-Content-Type-Options`.
  - **Tomcat Manual**: Despliegue profesional mediante binarios `.tar.gz`, creación de servicios `systemd` y control de variables de entorno (JAVA_HOME).
- **Validación de Puertos**: Lógica inteligente de detección de puertos ocupados o reservados con opción de redirección o retorno al menú.

## Estructura del Proyecto
```text
Practica-07/
├── scripts/
│   ├── linux/
│   │   ├── main.sh            # Interfaz de usuario interactiva
│   │   └── http_functions.sh  # Motor de aprovisionamiento Mageia
│   └── windows/
│       ├── main.ps1           # Interfaz de usuario interactiva
│       └── http_functions.ps1 # Motor de aprovisionamiento Windows
└── README.md
```

## Formas de Ejecución
### Linux (Mageia)
1. Conéctese a Mageia vía SSH o terminal local.
2. Navegue al directorio: `cd Practica-07/scripts/linux`
3. Ejecute con privilegios de root: `sudo ./main.sh`
   - *El script detectará automáticamente si requiere DNF o URPMI.*

### Windows (Server)
1. Abra PowerShell como **Administrador**.
2. Navegue al directorio: `cd Practica-06\scripts\windows`
3. Ejecute: `.\main.ps1`
   - *Asegúrese de tener Chocolatey instalado para el despliegue de Apache y Nginx.*

## Verificación de Seguridad
Puede confirmar los encabezados de seguridad y el puerto configurado usando:
`curl -I http://[IP-DEL-SERVIDOR]:[PUERTO-ELEGIDO]`

Debe observar la ausencia de versiones detalladas y la presencia de encabezados `SAMEORIGIN`.
