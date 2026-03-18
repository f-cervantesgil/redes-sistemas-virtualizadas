# ==============================================================================
# menu_windows.ps1 - Menu interactivo de aprovisionamiento HTTP
# Practica 6 | Windows Server 2022 | PowerShell como Administrador
# MAIN SCRIPT: solo contiene llamadas a funciones de http_functions.ps1
# ==============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\http_functions.ps1"

# ------------------------------------------------------------------------------
# RUTAS REALES DE CADA SERVICIO (ajustadas a tu servidor)
# ------------------------------------------------------------------------------
$script:APACHE_CONF    = "$env:APPDATA\Apache24\conf\httpd.conf"
$script:APACHE_HTDOCS  = "$env:APPDATA\Apache24\htdocs"
$script:APACHE_BIN     = "$env:APPDATA\Apache24\bin\httpd.exe"
$script:APACHE_SVC     = "Apache24"
$script:NGINX_CONF     = "C:\nginx\conf\nginx.conf"
$script:NGINX_HTML     = "C:\nginx\html"
$script:NGINX_SVC      = "Nginx"
$script:IIS_WEBROOT    = "C:\inetpub\wwwroot"

# ------------------------------------------------------------------------------
# CABECERA Y ESTADO DE SERVICIOS
# ------------------------------------------------------------------------------

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  +============================================================+" -ForegroundColor Blue
    Write-Host "  |      APROVISIONAMIENTO DE SERVIDORES HTTP                  |" -ForegroundColor Blue
    Write-Host "  |      Practica 6 - Windows Server 2022 - PowerShell         |" -ForegroundColor Blue
    Write-Host "  +============================================================+" -ForegroundColor Blue
    Write-Host ""
    Show-ServiceStatus
    Write-Host ""
}

function Show-ServiceStatus {
    Write-Host "  Estado actual de servicios:" -ForegroundColor White

    $svcs = @(
        @{ Nombre = "W3SVC";              Display = "IIS"    },
        @{ Nombre = $script:APACHE_SVC;   Display = "Apache" },
        @{ Nombre = $script:NGINX_SVC;    Display = "Nginx"  }
    )

    foreach ($svc in $svcs) {
        $s = Get-Service -Name $svc.Nombre -ErrorAction SilentlyContinue
        $puerto = Get-ServicePort -Servicio $svc.Nombre
        if ($null -eq $s) {
            Write-Host "    [?] $($svc.Display)   no instalado" -ForegroundColor Yellow
        } elseif ($s.Status -eq "Running") {
            Write-Host "    [+] $($svc.Display)   activo   puerto: $puerto" -ForegroundColor Green
        } else {
            Write-Host "    [-] $($svc.Display)   inactivo puerto: $puerto" -ForegroundColor Red
        }
    }
}

# Obtiene el puerto actual de cada servicio leyendo su archivo de config
function Get-ServicePort {
    param([string]$Servicio)

    switch ($Servicio) {
        "W3SVC" {
            try {
                Import-Module WebAdministration -ErrorAction SilentlyContinue
                $bindings = Get-WebBinding -Name "Default Web Site" -Protocol http -ErrorAction SilentlyContinue
                if ($bindings) { 
                    return ($bindings[0].bindingInformation -split ':')[1]
                }
            } catch {}
            return "80"
        }
        { $_ -eq $script:APACHE_SVC } {
            $conf = if (Test-Path $script:APACHE_CONF) { $script:APACHE_CONF } else { 
                # Buscar dinamicamente si la ruta no coincide
                @(
                    "C:\Apache24\conf\httpd.conf",
                    "C:\tools\Apache24\conf\httpd.conf",
                    "$env:ProgramFiles\Apache24\conf\httpd.conf",
                    "$env:ProgramData\chocolatey\lib\apache-httpd\tools\Apache24\conf\httpd.conf",
                    "$env:APPDATA\Apache24\conf\httpd.conf"
                ) | Where-Object { Test-Path $_ } | Select-Object -First 1
            }
            if ($null -eq $conf) { return "?" }
            $linea = Get-Content $conf | Where-Object { $_ -match '^\s*Listen\s+\d+' } | Select-Object -First 1
            if ($linea -match 'Listen\s+(\d+)') { return $matches[1] }
            return "?"
        }
        { $_ -eq $script:NGINX_SVC } {
            $conf = if (Test-Path $script:NGINX_CONF) { $script:NGINX_CONF } else { "C:\nginx\conf\nginx.conf" }
            if (-not (Test-Path $conf)) { return "?" }
            $linea = Get-Content $conf | Where-Object { $_ -match 'listen\s+\d+' } | Select-Object -First 1
            if ($linea -match 'listen\s+(\d+)') { return $matches[1] }
            return "?"
        }
        default { return "?" }
    }
}

# ------------------------------------------------------------------------------
# MENU PRINCIPAL
# ------------------------------------------------------------------------------

function Show-MainMenu {
    Show-Header
    Write-Host "  ============  MENU PRINCIPAL  ============" -ForegroundColor White
    Write-Host ""
    Write-Host "  -- Instalacion -----------------------------" -ForegroundColor Cyan
    Write-Host "   1)  Instalar IIS (Internet Information Services)" -ForegroundColor Green
    Write-Host "   2)  Instalar Apache HTTP Server (Win64)"          -ForegroundColor Green
    Write-Host "   3)  Instalar Nginx para Windows"                  -ForegroundColor Green
    Write-Host ""
    Write-Host "  -- Gestion de servicios --------------------" -ForegroundColor Cyan
    Write-Host "   4)  Iniciar / Detener / Reiniciar servicio"       -ForegroundColor Green
    Write-Host "   5)  Ver puertos activos de cada servicio"         -ForegroundColor Green
    Write-Host "   6)  Ver logs recientes de un servicio"            -ForegroundColor Green
    Write-Host ""
    Write-Host "  -- Configuracion ---------------------------" -ForegroundColor Cyan
    Write-Host "   7)  Cambiar puerto de un servicio instalado"      -ForegroundColor Green
    Write-Host "   8)  Ver encabezados HTTP (curl -I)"               -ForegroundColor Green
    Write-Host "   9)  Liberar puertos (detener servicios)"          -ForegroundColor Green
    Write-Host ""
    Write-Host "   0)  Salir" -ForegroundColor Red
    Write-Host ""
    Write-Host -NoNewline "  Selecciona una opcion [0-9]: " -ForegroundColor White
}

# ------------------------------------------------------------------------------
# FLUJOS DE INSTALACION
# ------------------------------------------------------------------------------

function Start-FlowIIS {
    Write-Section "Flujo de instalacion: IIS"
    Write-Info "IIS se instala en la version incluida con Windows Server 2022 (IIS 10)."
    $puerto = Get-PortFromUser -Servicio "IIS" -Default 80
    Install-IIS -Puerto $puerto
}

function Start-FlowApache {
    Write-Section "Flujo de instalacion: Apache (Windows)"
    Initialize-PackageManager
    $pkgId   = if ($script:PKG_MANAGER -eq "winget") { "Apache.Httpd" } else { "apache-httpd" }
    $version = Select-Version -Paquete $pkgId
    $puerto  = Get-PortFromUser -Servicio "Apache" -Default 8080
    Install-ApacheWindows -Puerto $puerto -Version $version
}

function Start-FlowNginx {
    Write-Section "Flujo de instalacion: Nginx (Windows)"
    $puerto = Get-PortFromUser -Servicio "Nginx" -Default 8081
    Install-NginxManual -Puerto $puerto
}

# Instalacion de Nginx descargando directamente (sin Chocolatey)
function Install-NginxManual {
    param([int]$Puerto)

    Write-Section "Instalando Nginx (descarga directa)"

    $url     = "https://nginx.org/download/nginx-1.26.3.zip"
    $destZip = "C:\nginx.zip"
    $destDir = "C:\nginx"

    if (-not (Test-Path "$destDir\nginx.exe")) {
        Write-Info "Descargando Nginx 1.26.3..."
        Invoke-WebRequest -Uri $url -OutFile $destZip
        Expand-Archive -Path $destZip -DestinationPath "C:\" -Force
        if (Test-Path "C:\nginx-1.26.3") {
            Rename-Item "C:\nginx-1.26.3" $destDir -ErrorAction SilentlyContinue
        }
    } else {
        Write-Info "Nginx ya descargado en $destDir"
    }

    Set-NginxConfig -Puerto $puerto
    Set-WebRootPermissions -Webroot $script:NGINX_HTML -ServiceUser "NETWORK SERVICE"
    New-IndexPage -Servicio "Nginx" -Version "1.26.3" -Puerto $Puerto -Webroot $script:NGINX_HTML
    Set-FirewallRule -Puerto $Puerto -Servicio "Nginx"
    Register-NginxService -NginxDir $destDir

    Write-Section "Nginx listo"
    Write-Host "  URL: http://localhost:$Puerto" -ForegroundColor Green
}

# Genera nginx.conf sin BOM
function Set-NginxConfig {
    param([int]$Puerto)

    $contenido = @"
worker_processes  1;
events { worker_connections 1024; }

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;
    server_tokens off;

    server {
        listen       $Puerto;
        server_name  localhost;
        root         html;
        index        index.html;

        add_header X-Frame-Options        "SAMEORIGIN"    always;
        add_header X-Content-Type-Options "nosniff"       always;
        add_header X-XSS-Protection       "1; mode=block" always;

        if (`$request_method !~ "^(GET|POST|HEAD|OPTIONS)$" ) {
            return 405;
        }

        location / { try_files `$uri `$uri/ =404; }
        location ~ /\. { deny all; }
    }
}
"@
    # Guardar SIN BOM para evitar error "unknown directive"
    $encoding = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($script:NGINX_CONF, $contenido, $encoding)
    Write-Ok "nginx.conf generado sin BOM en puerto $Puerto."
}

# ------------------------------------------------------------------------------
# SUBMENU: Gestion de servicios
# ------------------------------------------------------------------------------

function Show-ManageMenu {
    Show-Header
    Write-Host "  ============  GESTION DE SERVICIOS  ============" -ForegroundColor White
    Write-Host ""
    Write-Host "   1)  IIS (W3SVC)"              -ForegroundColor Green
    Write-Host "   2)  Apache ($script:APACHE_SVC)" -ForegroundColor Green
    Write-Host "   3)  Nginx"                     -ForegroundColor Green
    Write-Host "   0)  Volver"                    -ForegroundColor Red
    Write-Host ""

    $selSvc = Read-Host "  Servicio [0-3]"
    $svcMap = @{ "1" = "W3SVC"; "2" = $script:APACHE_SVC; "3" = $script:NGINX_SVC }
    if (-not $svcMap.ContainsKey($selSvc)) { return }
    $svcName = $svcMap[$selSvc]

    Write-Host ""
    Write-Host "  Acciones sobre: $svcName" -ForegroundColor White
    Write-Host "   1)  Iniciar"          -ForegroundColor Green
    Write-Host "   2)  Detener"          -ForegroundColor Green
    Write-Host "   3)  Reiniciar"        -ForegroundColor Green
    Write-Host "   4)  Estado detallado" -ForegroundColor Green
    Write-Host "   0)  Volver"           -ForegroundColor Red
    Write-Host ""

    $accion = Read-Host "  Accion [0-4]"
    switch ($accion) {
        "1" { Start-Service   $svcName -ErrorAction SilentlyContinue; Write-Ok "$svcName iniciado."   }
        "2" { Stop-Service    $svcName -Force -ErrorAction SilentlyContinue; Write-Ok "$svcName detenido." }
        "3" { Restart-Service $svcName -ErrorAction SilentlyContinue; Write-Ok "$svcName reiniciado." }
        "4" { Get-Service $svcName -ErrorAction SilentlyContinue | Format-List * }
        "0" { return }
        default { Write-Warn "Opcion invalida." }
    }
}

# ------------------------------------------------------------------------------
# SUBMENU: Ver puertos activos
# ------------------------------------------------------------------------------

function Show-PortsStatus {
    Show-Header
    Write-Host "  ============  PUERTOS ACTIVOS POR SERVICIO  ============" -ForegroundColor White
    Write-Host ""

    # Puertos de cada servicio desde su config
    $apachePuerto = Get-ServicePort -Servicio $script:APACHE_SVC
    $nginxPuerto  = Get-ServicePort -Servicio $script:NGINX_SVC
    $iisPuerto    = Get-ServicePort -Servicio "W3SVC"

    Write-Host "  Configuracion detectada en archivos:" -ForegroundColor Cyan
    Write-Host "   IIS    : puerto $iisPuerto"    -ForegroundColor White
    Write-Host "   Apache : puerto $apachePuerto" -ForegroundColor White
    Write-Host "   Nginx  : puerto $nginxPuerto"  -ForegroundColor White
    Write-Host ""

    # Puertos realmente en escucha en el sistema
    Write-Host "  Puertos en escucha reales (Network Stack):" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor Gray

    $puertosInteres = @(80, 443, 8080, 8081, 9091)
    if ($iisPuerto    -match '^\d+$') { $puertosInteres += [int]$iisPuerto }
    if ($apachePuerto -match '^\d+$') { $puertosInteres += [int]$apachePuerto }
    if ($nginxPuerto  -match '^\d+$') { $puertosInteres += [int]$nginxPuerto }
    $puertosInteres = $puertosInteres | Select-Object -Unique

    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Select-Object LocalPort, OwningProcess |
        ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            [PSCustomObject]@{ 
                Puerto  = $_.LocalPort
                PID     = $_.OwningProcess
                Proceso = if ($proc) { $proc.Name } else { "System/Unknown" }
            }
        } |
        Where-Object { $_.Puerto -in $puertosInteres } |
        Sort-Object Puerto |
        Format-Table -Property Puerto, PID, Proceso -AutoSize
}

# ------------------------------------------------------------------------------
# SUBMENU: Ver logs
# ------------------------------------------------------------------------------

function Show-LogsMenu {
    Show-Header
    Write-Host "  ============  LOGS DE SERVICIOS  ============" -ForegroundColor White
    Write-Host ""
    Write-Host "   1)  IIS - Event Viewer"   -ForegroundColor Green
    Write-Host "   2)  Apache - error.log"   -ForegroundColor Green
    Write-Host "   3)  Nginx  - error.log"   -ForegroundColor Green
    Write-Host "   0)  Volver"               -ForegroundColor Red
    Write-Host ""

    $sel = Read-Host "  Selecciona [0-3]"
    switch ($sel) {
        "1" {
            Write-Info "Ultimas 20 entradas del Event Log para IIS:"
            Get-EventLog -LogName System -Source "W3SVC" -Newest 20 -ErrorAction SilentlyContinue |
                Format-Table TimeGenerated, EntryType, Message -AutoSize -Wrap
        }
        "2" {
            $f = "$env:APPDATA\Apache24\logs\error.log"
            if (Test-Path $f) { Get-Content $f -Tail 30 } else { Write-Warn "No se encontro error.log de Apache en $f" }
        }
        "3" {
            if (Test-Path "C:\nginx\logs\error.log") {
                Get-Content "C:\nginx\logs\error.log" -Tail 30
            } else { Write-Warn "No se encontro error.log de Nginx." }
        }
        "0" { return }
        default { Write-Warn "Opcion invalida." }
    }
}

# ------------------------------------------------------------------------------
# SUBMENU: Cambiar puerto
# ------------------------------------------------------------------------------

function Show-ChangePortMenu {
    Show-Header
    Write-Host "  ============  CAMBIAR PUERTO  ============" -ForegroundColor White
    Write-Host ""
    Write-Host "   Puerto actual de cada servicio:" -ForegroundColor Gray
    Write-Host "   IIS    : $(Get-ServicePort -Servicio 'W3SVC')"                  -ForegroundColor Gray
    Write-Host "   Apache : $(Get-ServicePort -Servicio $script:APACHE_SVC)"       -ForegroundColor Gray
    Write-Host "   Nginx  : $(Get-ServicePort -Servicio $script:NGINX_SVC)"        -ForegroundColor Gray
    Write-Host ""
    Write-Host "   1)  IIS"      -ForegroundColor Green
    Write-Host "   2)  Apache"   -ForegroundColor Green
    Write-Host "   3)  Nginx"    -ForegroundColor Green
    Write-Host "   0)  Volver"   -ForegroundColor Red
    Write-Host ""

    $sel = Read-Host "  Servicio [0-3]"
    switch ($sel) {
        "1" {
            $antiguo = Get-ServicePort -Servicio "W3SVC"
            $p = Get-PortFromUser -Servicio "IIS" -Default 80
            
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            # Eliminar TODOS los bindings http de este sitio para limpiar realmente
            Get-WebBinding -Name "Default Web Site" -Protocol http | Remove-WebBinding -ErrorAction SilentlyContinue
            
            New-WebBinding -Name "Default Web Site" -Protocol http -Port $p -IPAddress "*"
            
            # Actualizar index.html
            $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue).VersionString
            if (-not $iisVer) { $iisVer = "10.0" }
            New-IndexPage -Servicio "IIS" -Version $iisVer -Puerto $p -Webroot $script:IIS_WEBROOT
            
            $pAnt = if ($antiguo -match '^\d+$') { [int]$antiguo } else { 0 }
            Set-FirewallRule -Puerto $p -PuertoAnterior $pAnt -Servicio "IIS"
            Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
            Write-Ok "Puerto IIS cambiado de $antiguo a $p."
            curl.exe -I "http://localhost:$p"
        }
        "2" {
            $antiguo = Get-ServicePort -Servicio $script:APACHE_SVC
            $p = Get-PortFromUser -Servicio "Apache" -Default 8080
            
            if (Test-Path $script:APACHE_CONF) {
                # Detener procesos viejos para facilitar cambios
                Stop-Service $script:APACHE_SVC -Force -ErrorAction SilentlyContinue
                Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force
                
                (Get-Content $script:APACHE_CONF) -replace "^Listen \d+", "Listen $p" | Set-Content $script:APACHE_CONF
                
                $ver = Get-InstalledVersion -Servicio "apache-httpd"
                New-IndexPage -Servicio "Apache" -Version $ver -Puerto $p -Webroot $script:APACHE_HTDOCS
                
                $pAnt = if ($antiguo -match '^\d+$') { [int]$antiguo } else { 0 }
                Set-FirewallRule -Puerto $p -PuertoAnterior $pAnt -Servicio "Apache"
                Start-Service $script:APACHE_SVC -ErrorAction SilentlyContinue
                Write-Ok "Puerto Apache cambiado de $antiguo a $p."
                curl.exe -I "http://localhost:$p"
            } else { Write-Err "httpd.conf no encontrado." }
        }
        "3" {
            $antiguo = Get-ServicePort -Servicio $script:NGINX_SVC
            $p = Get-PortFromUser -Servicio "Nginx" -Default 8081
            
            # Detener procesos viejos
            Stop-Service $script:NGINX_SVC -Force -ErrorAction SilentlyContinue
            Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
            
            Set-NginxConfig -Puerto $p
            
            $ver = Get-InstalledVersion -Servicio "nginx"
            New-IndexPage -Servicio "Nginx" -Version $ver -Puerto $p -Webroot $script:NGINX_HTML
            
            $pAnt = if ($antiguo -match '^\d+$') { [int]$antiguo } else { 0 }
            Set-FirewallRule -Puerto $p -PuertoAnterior $pAnt -Servicio "Nginx"
            Start-Service $script:NGINX_SVC -ErrorAction SilentlyContinue
            Write-Ok "Puerto Nginx cambiado de $antiguo a $p."
            curl.exe -I "http://localhost:$p"
        }
        "0" { return }
        default { Write-Warn "Opcion invalida." }
    }
}

# ------------------------------------------------------------------------------
# SUBMENU: Ver encabezados HTTP
# ------------------------------------------------------------------------------

function Show-HttpHeaders {
    Show-Header
    Write-Host "  ============  ENCABEZADOS HTTP  ============" -ForegroundColor White
    Write-Host "  Equivalente a: curl -I http://localhost:PUERTO" -ForegroundColor Gray
    Write-Host ""

    $userInput = Read-Host "  URL o puerto [ej: 80  o  http://localhost:8080]"
    if ($userInput -match '^\d+$') {
        $url = "http://localhost:$userInput"
    } else {
        $url = $userInput
    }

    if (-not (Test-InputSafe -Valor $url -Campo "URL")) { return }

    Write-Host ""
    Write-Host "  Consultando: $url" -ForegroundColor Cyan
    Write-Host "  ------------------------------------------" -ForegroundColor Gray
    curl.exe -I --max-time 5 $url
}

# ------------------------------------------------------------------------------
# SUBMENU: Liberar puertos (detener servicios)
# ------------------------------------------------------------------------------

function Show-FreePortsMenu {
    Show-Header
    Write-Host "  ============  LIBERAR PUERTOS  ============" -ForegroundColor White
    Write-Host ""
    Write-Host "  Esto detiene los servicios para liberar sus puertos." -ForegroundColor Gray
    Write-Host ""
    Write-Host "   1)  Detener IIS"                -ForegroundColor Green
    Write-Host "   2)  Detener Apache"              -ForegroundColor Green
    Write-Host "   3)  Detener Nginx"               -ForegroundColor Green
    Write-Host "   4)  Detener TODOS"               -ForegroundColor Yellow
    Write-Host "   5)  Ver puertos en uso ahora"    -ForegroundColor Cyan
    Write-Host "   0)  Volver"                      -ForegroundColor Red
    Write-Host ""

    $sel = Read-Host "  Selecciona [0-5]"
    switch ($sel) {
        "1" {
            Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
            Write-Ok "IIS detenido."
        }
        "2" {
            Stop-Service $script:APACHE_SVC -Force -ErrorAction SilentlyContinue
            Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force
            Write-Ok "Apache detenido."
        }
        "3" {
            Stop-Service $script:NGINX_SVC -Force -ErrorAction SilentlyContinue
            Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
            Write-Ok "Nginx detenido."
        }
        "4" {
            Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
            Stop-Service $script:APACHE_SVC -Force -ErrorAction SilentlyContinue
            Stop-Service $script:NGINX_SVC -Force -ErrorAction SilentlyContinue
            Get-Process httpd, nginx -ErrorAction SilentlyContinue | Stop-Process -Force
            Write-Ok "Todos los servicios detenidos."
        }
        "5" {
            Write-Host ""
            Write-Host "  Puertos en uso actualmente:" -ForegroundColor Cyan
            Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Select-Object LocalPort, OwningProcess |
                ForEach-Object {
                    $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                    [PSCustomObject]@{ Puerto=$_.LocalPort; PID=$_.OwningProcess; Proceso=$proc.Name }
                } |
                Where-Object { $_.Puerto -lt 10000 } |
                Sort-Object Puerto -Unique |
                Format-Table -AutoSize
        }
        "0" { return }
        default { Write-Warn "Opcion invalida." }
    }
}

# ------------------------------------------------------------------------------
# MAIN - solo llamadas a funciones
# ------------------------------------------------------------------------------

function Main {
    Test-Admin

    while ($true) {
        Show-MainMenu
        $opcion = Read-Host

        if ($opcion -notmatch '^[0-9]$') {
            Write-Warn "Opcion invalida. Ingresa un numero del 0 al 9."
            Start-Sleep -Seconds 1
            continue
        }

        Write-Host ""

        switch ($opcion) {
            "1" { Start-FlowIIS        }
            "2" { Start-FlowApache     }
            "3" { Start-FlowNginx      }
            "4" { Show-ManageMenu      }
            "5" { Show-PortsStatus     }
            "6" { Show-LogsMenu        }
            "7" { Show-ChangePortMenu  }
            "8" { Show-HttpHeaders     }
            "9" { Show-FreePortsMenu   }
            "0" {
                Write-Host ""
                Write-Host "  Hasta luego!" -ForegroundColor Green
                Write-Host ""
                exit 0
            }
        }

        Write-Host ""
        Read-Host "  Presiona ENTER para volver al menu"
    }
}

Main