# ==============================================================================
# http_functions.ps1 - Libreria de funciones HTTP para Windows Server
# Practica 6 | Windows Server 2022
# Ejecucion: PowerShell directo como Administrador
# Gestor de paquetes: deteccion automatica Winget -> Chocolatey -> instala Choco
# ==============================================================================

# ------------------------------------------------------------------------------
# FUNCIONES DE SALIDA / LOG
# ------------------------------------------------------------------------------

function Write-Info    { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan    }
function Write-Ok      { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green   }
function Write-Warn    { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow  }
function Write-Err     { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red     }

function Write-Section {
    param($msg)
    Write-Host ""
    Write-Host "  ==================================================" -ForegroundColor Blue
    Write-Host "    $msg"                                              -ForegroundColor Blue
    Write-Host "  ==================================================" -ForegroundColor Blue
    Write-Host ""
}

# ------------------------------------------------------------------------------
# VALIDACIONES
# ------------------------------------------------------------------------------

function Test-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Err "Este script debe ejecutarse como Administrador."
        Write-Host "  Clic derecho en PowerShell -> Ejecutar como administrador" -ForegroundColor Yellow
        exit 1
    }
    Write-Ok "Ejecutando como Administrador en Windows Server 2022."
}

function Test-InputSafe {
    param([string]$Valor, [string]$Campo)
    if ([string]::IsNullOrWhiteSpace($Valor)) {
        Write-Err "El campo '$Campo' no puede estar vacio."
        return $false
    }
    if ($Valor -match '[;|&`<>\"' + "'" + '\\]') {
        Write-Err "El campo '$Campo' contiene caracteres no permitidos."
        return $false
    }
    return $true
}

function Test-Port {
    param([int]$Puerto)

    if ($Puerto -lt 1 -or $Puerto -gt 65535) {
        Write-Err "Puerto $Puerto fuera de rango valido (1-65535)."
        return $false
    }

    $Reservados = @(21, 22, 23, 25, 53, 110, 143, 389, 443, 445,
                    3306, 3389, 5432, 5985, 5986, 6379, 8443, 27017)
    if ($Reservados -contains $Puerto) {
        Write-Err "Puerto $Puerto reservado para otro servicio del sistema."
        return $false
    }

    $enUso = Get-NetTCPConnection -LocalPort $Puerto -ErrorAction SilentlyContinue
    if ($enUso) {
        Write-Err "Puerto $Puerto ya esta en uso por otro proceso."
        return $false
    }

    return $true
}

function Get-PortFromUser {
    param([string]$Servicio, [int]$Default = 80)

    Write-Host ""
    Write-Host "  Configuracion de puerto para: $Servicio" -ForegroundColor White
    Write-Host "  Puertos sugeridos : 80, 8080, 8888"      -ForegroundColor Gray
    Write-Host "  Bloqueados        : 22, 53, 443, 3389, 3306 (entre otros)" -ForegroundColor Gray
    Write-Host ""

    do {
        $raw = Read-Host "  Puerto deseado [default: $Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = "$Default" }

        if ($raw -notmatch '^\d+$') {
            Write-Warn "Solo se permiten numeros enteros."
            $valido = $false
            continue
        }
        $puerto = [int]$raw
        $valido = Test-Port -Puerto $puerto
    } while (-not $valido)

    return $puerto
}

# ------------------------------------------------------------------------------
# GESTOR DE PAQUETES: deteccion automatica
# Orden: Winget -> Chocolatey ya instalado -> instalar Chocolatey
# ------------------------------------------------------------------------------

$script:PKG_MANAGER = $null

function Initialize-PackageManager {
    Write-Info "Detectando gestor de paquetes disponible..."

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $script:PKG_MANAGER = "winget"
        Write-Ok "Winget detectado: $(winget --version)"
        return
    }

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $script:PKG_MANAGER = "choco"
        Write-Ok "Chocolatey detectado: $(choco --version)"
        return
    }

    Write-Warn "Sin gestor de paquetes. Instalando Chocolatey automaticamente..."
    Install-Chocolatey

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $script:PKG_MANAGER = "choco"
        Write-Ok "Chocolatey instalado y listo."
    } else {
        Write-Err "No se pudo inicializar ningun gestor de paquetes."
        exit 1
    }
}

function Install-Chocolatey {
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-Expression (
            (New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')
        )
        $env:PATH             += ";$env:ALLUSERSPROFILE\chocolatey\bin"
        $env:ChocolateyInstall  = "$env:ALLUSERSPROFILE\chocolatey"
    } catch {
        Write-Err "Error instalando Chocolatey: $_"
    }
}

# ------------------------------------------------------------------------------
# CONSULTA DINAMICA DE VERSIONES (sin hardcodear)
# ------------------------------------------------------------------------------

function Get-AvailableVersions {
    param([string]$Paquete)

    Write-Info "Consultando versiones de '$Paquete' ($script:PKG_MANAGER)..."
    $versiones = @()

    if ($script:PKG_MANAGER -eq "winget") {
        try {
            $raw = winget show $Paquete --versions 2>$null | Where-Object { $_ -match '^\d' }
            $versiones = @($raw | Select-Object -Unique)
        } catch {}
    }

    if ($script:PKG_MANAGER -eq "choco" -or $versiones.Count -eq 0) {
        try {
            $raw = choco list $Paquete --all --exact 2>$null |
                   Where-Object  { $_ -match "^\S+ \d" } |
                   ForEach-Object { ($_ -split '\s+')[1] } |
                   Where-Object  { $_ -match '^\d' }
            if ($raw) { $versiones = @($raw | Select-Object -Unique) }
        } catch {}
    }

    if ($versiones.Count -eq 0) {
        Write-Warn "Sin versiones en repositorio para '$Paquete'. Se usara 'latest'."
        return @("latest")
    }

    return $versiones
}

function Select-Version {
    param([string]$Paquete)

    $versiones = Get-AvailableVersions -Paquete $Paquete

    Write-Host ""
    Write-Host "  Versiones disponibles para ${Paquete}:" -ForegroundColor White
    Write-Host "  [Latest] = Mas reciente / Desarrollo     [LTS] = Estable" -ForegroundColor Gray
    Write-Host ""

    $i = 1
    foreach ($ver in $versiones) {
        if ($i -eq 1) {
            Write-Host "    $i) $ver " -NoNewline
            Write-Host "[Latest / Desarrollo]" -ForegroundColor Yellow
        } elseif ($i -eq $versiones.Count -and $versiones.Count -gt 1) {
            Write-Host "    $i) $ver " -NoNewline
            Write-Host "[LTS / Estable]" -ForegroundColor Green
        } else {
            Write-Host "    $i) $ver"
        }
        $i++
    }
    Write-Host ""

    do {
        $sel    = Read-Host "  Selecciona version [1-$($versiones.Count)]"
        $valido = ($sel -match '^\d+$') -and ([int]$sel -ge 1) -and ([int]$sel -le $versiones.Count)
        if (-not $valido) {
            Write-Warn "Seleccion invalida. Ingresa un numero entre 1 y $($versiones.Count)."
        }
    } while (-not $valido)

    $elegida = $versiones[[int]$sel - 1]
    Write-Ok "Version seleccionada: $elegida"
    return $elegida
}

function Install-Package {
    param([string]$Paquete, [string]$Version = "latest")

    # Normalizar: si version es "latest" o no es un numero valido, instalar sin --version
    $usarVersion = ($Version -ne "latest") -and ($Version -match '^\d')

    if ($script:PKG_MANAGER -eq "winget") {
        if ($usarVersion) {
            winget install --id $Paquete --version $Version --silent --accept-package-agreements --accept-source-agreements
        } else {
            winget install --id $Paquete --silent --accept-package-agreements --accept-source-agreements
        }
    } else {
        if ($usarVersion) {
            choco install $Paquete --version $Version --yes --no-progress --allow-downgrade
        } else {
            choco install $Paquete --yes --no-progress
        }
    }
}

# ------------------------------------------------------------------------------
# FIREWALL
# ------------------------------------------------------------------------------

function Set-FirewallRule {
    param([int]$Puerto, [int]$PuertoAnterior = 0, [string]$Servicio = "HTTP")

    Write-Section "Configurando Firewall de Windows"

    if ($PuertoAnterior -gt 0 -and $PuertoAnterior -ne $Puerto) {
        $nombreAnt = "$Servicio-Puerto-$PuertoAnterior"
        if (Get-NetFirewallRule -DisplayName $nombreAnt -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -DisplayName $nombreAnt -ErrorAction SilentlyContinue
            Write-Ok "Regla anterior '$nombreAnt' eliminada."
        }
    }

    $nombreNuevo = "$Servicio-Puerto-$Puerto"
    if (-not (Get-NetFirewallRule -DisplayName $nombreNuevo -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName $nombreNuevo `
            -Direction   Inbound `
            -Protocol    TCP `
            -LocalPort   $Puerto `
            -Action      Allow `
            -Profile     Any `
            -ErrorAction Stop | Out-Null
        Write-Ok "Regla creada: TCP $Puerto abierto para $Servicio."
    } else {
        Write-Ok "Regla de firewall para puerto $Puerto ya existia."
    }
}

# ------------------------------------------------------------------------------
# PAGINA INDEX PERSONALIZADA
# ------------------------------------------------------------------------------

function New-IndexPage {
    param([string]$Servicio, [string]$Version, [int]$Puerto, [string]$Webroot)

    if (-not (Test-Path $Webroot)) {
        New-Item -ItemType Directory -Path $Webroot -Force | Out-Null
    }

    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>$Servicio - Practica 6</title>
    <style>
        body { font-family: Segoe UI, sans-serif; background: #1a1a2e; color: #eee;
               display: flex; justify-content: center; align-items: center;
               height: 100vh; margin: 0; }
        .card { background: #16213e; border-radius: 12px; padding: 40px 60px;
                box-shadow: 0 8px 32px rgba(0,0,0,.5); text-align: center; }
        h1 { color: #4fc3f7; font-size: 2.2em; margin-bottom: .3em; }
        .badge { display: inline-block; background: #e94560; color: #fff;
                 border-radius: 6px; padding: 4px 14px; font-size: .9em; margin: 6px 4px; }
        .info { color: #a8b2d8; margin-top: 1em; font-size: .95em; }
    </style>
</head>
<body>
    <div class="card">
        <h1>$Servicio</h1>
        <div>
            <span class="badge">Servidor: $Servicio</span>
            <span class="badge">Version: $Version</span>
            <span class="badge">Puerto: $Puerto</span>
        </div>
        <p class="info">Aprovisionado automaticamente - Practica 6 - Windows Server 2022</p>
    </div>
</body>
</html>
"@
    Set-Content -Path "$Webroot\index.html" -Value $html -Encoding UTF8
    Write-Ok "index.html creado en $Webroot"
}

# ------------------------------------------------------------------------------
# PERMISOS NTFS RESTRINGIDOS
# ------------------------------------------------------------------------------

function Set-WebRootPermissions {
    param([string]$Webroot, [string]$ServiceUser = "NETWORK SERVICE")

    if (-not (Test-Path $Webroot)) {
        New-Item -ItemType Directory -Path $Webroot -Force | Out-Null
    }
    try {
        $acl = Get-Acl $Webroot
        $acl.SetAccessRuleProtection($true, $true)
        $regla = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $ServiceUser, "ReadAndExecute",
            "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.SetAccessRule($regla)
        Set-Acl -Path $Webroot -AclObject $acl
        Write-Ok "Permisos NTFS: '$ServiceUser' solo lectura en $Webroot"
    } catch {
        Write-Warn "No se pudieron ajustar permisos NTFS: $_"
    }
}

# ------------------------------------------------------------------------------
# UTILIDADES
# ------------------------------------------------------------------------------

function Get-InstalledVersion {
    param([string]$Servicio)
    try {
        if ($script:PKG_MANAGER -eq "choco") {
            $line = choco list --local-only 2>$null |
                    Where-Object { $_ -imatch "^$Servicio\s" } |
                    Select-Object -First 1
            if ($line) { return ($line -split '\s+')[1] }
        }
        if ($script:PKG_MANAGER -eq "winget") {
            $line = winget list --id $Servicio 2>$null |
                    Where-Object { $_ -match '\d+\.\d+' } |
                    Select-Object -First 1
            if ($line -match '(\d[\d.]+)') { return $matches[1] }
        }
    } catch {}
    return "desconocida"
}

# ------------------------------------------------------------------------------
# IIS - Instalacion forzosa (sin gestor de paquetes)
# ------------------------------------------------------------------------------

function Install-IIS {
    param([int]$Puerto)

    Write-Section "Instalando IIS - Internet Information Services"

    $features = @(
        "Web-Server", "Web-Common-Http", "Web-Static-Content",
        "Web-Http-Logging", "Web-Security", "Web-Filtering",
        "Web-Mgmt-Tools", "Web-Mgmt-Console", "Web-Http-Errors"
    )
    foreach ($feat in $features) {
        $r = Install-WindowsFeature -Name $feat -IncludeManagementTools -ErrorAction SilentlyContinue
        if ($r.Success) { Write-Ok "Rol habilitado: $feat" }
    }

    Import-Module WebAdministration -ErrorAction Stop

    $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue).VersionString
    if (-not $iisVer) { $iisVer = "10.0 (WS2022)" }
    Write-Ok "IIS listo. Version: $iisVer"

    if ($Puerto -ne 80) {
        Remove-WebBinding -Name "Default Web Site" -Port 80 -Protocol http -ErrorAction SilentlyContinue
        Write-Ok "Binding default (80) removido."
    }
    Remove-WebBinding -Name "Default Web Site" -Port $Puerto -Protocol http -ErrorAction SilentlyContinue
    New-WebBinding    -Name "Default Web Site" -Protocol http -Port $Puerto -IPAddress "*"
    Write-Ok "Binding IIS en puerto $Puerto configurado."

    Set-IISSecurity        -SiteName "Default Web Site"
    Set-WebRootPermissions -Webroot "C:\inetpub\wwwroot" -ServiceUser "IIS_IUSRS"
    New-IndexPage          -Servicio "IIS" -Version $iisVer -Puerto $Puerto -Webroot "C:\inetpub\wwwroot"
    Set-FirewallRule       -Puerto $Puerto -PuertoAnterior 80 -Servicio "IIS"

    Start-Service W3SVC -ErrorAction SilentlyContinue
    Set-Service   W3SVC -StartupType Automatic
    Write-Ok "Servicio W3SVC activo."

    Write-Section "IIS listo"
    Write-Host "  URL     : http://localhost:$Puerto" -ForegroundColor Green
    Write-Host "  Webroot : C:\inetpub\wwwroot"       -ForegroundColor Green
}

function Set-IISSecurity {
    param([string]$SiteName = "Default Web Site")

    Write-Info "Aplicando seguridad en IIS..."

    try {
        Remove-WebConfigurationProperty `
            -PSPath    "IIS:\Sites\$SiteName" `
            -Filter    "system.webServer/httpProtocol/customHeaders" `
            -Name      "." -AtElement @{name = "X-Powered-By"} `
            -ErrorAction SilentlyContinue
        Write-Ok "Header X-Powered-By eliminado."
    } catch {}

    try {
        Set-WebConfigurationProperty `
            -PSPath  "IIS:\" `
            -Filter  "system.webServer/security/requestFiltering" `
            -Name    "removeServerHeader" -Value $true
        Write-Ok "Header Server ocultado (removeServerHeader = true)."
    } catch { Write-Warn "removeServerHeader: $_" }

    $headers = [ordered]@{
        "X-Frame-Options"        = "SAMEORIGIN"
        "X-Content-Type-Options" = "nosniff"
        "X-XSS-Protection"       = "1; mode=block"
    }
    foreach ($h in $headers.GetEnumerator()) {
        try {
            Remove-WebConfigurationProperty `
                -PSPath    "IIS:\Sites\$SiteName" `
                -Filter    "system.webServer/httpProtocol/customHeaders" `
                -Name      "." -AtElement @{name = $h.Key} -ErrorAction SilentlyContinue
            Add-WebConfigurationProperty `
                -PSPath  "IIS:\Sites\$SiteName" `
                -Filter  "system.webServer/httpProtocol/customHeaders" `
                -Name    "." -Value @{name = $h.Key; value = $h.Value}
            Write-Ok "$($h.Key): $($h.Value)"
        } catch { Write-Warn "No se pudo agregar header $($h.Key): $_" }
    }

    foreach ($m in @("TRACE", "TRACK", "DELETE")) {
        try {
            Add-WebConfigurationProperty `
                -PSPath  "IIS:\Sites\$SiteName" `
                -Filter  "system.webServer/security/requestFiltering/verbs" `
                -Name    "." -Value @{verb = $m; allowed = "false"} `
                -ErrorAction SilentlyContinue
        } catch {}
    }
    Write-Ok "Metodos TRACE, TRACK, DELETE bloqueados en IIS."
}

# ------------------------------------------------------------------------------
# APACHE WINDOWS
# ------------------------------------------------------------------------------

function Install-ApacheWindows {
    param([int]$Puerto, [string]$Version = "latest")

    Write-Section "Instalando Apache HTTP Server (Windows)"

    # Detener procesos existentes para liberar puertos
    Write-Info "Deteniendo servicios y procesos de Apache previos..."
    Stop-Service "Apache24" -Force -ErrorAction SilentlyContinue 2>$null
    Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force 2>$null

    $pkgId = if ($script:PKG_MANAGER -eq "winget") { "Apache.Httpd" } else { "apache-httpd" }
    Write-Info "Instalando Apache $Version via $script:PKG_MANAGER..."
    Install-Package -Paquete $pkgId -Version $Version

    # Buscar httpd.exe en todas las rutas posibles
    Write-Info "Buscando directorio de Apache..."
    $buscarEn = @(
        "C:\Apache24",
        "C:\tools\Apache24",
        "$env:ProgramFiles\Apache24",
        "$env:ProgramFiles\Apache Software Foundation\Apache2.4",
        "$env:ProgramData\chocolatey\lib\apache-httpd\tools\Apache24",
        "$env:APPDATA\Apache24"
    )

    $apacheDir = $buscarEn | Where-Object { Test-Path "$_\bin\httpd.exe" } | Select-Object -First 1

    # Fallback: buscar httpd.exe en todo el sistema
    if (-not $apacheDir) {
        $hit = Get-ChildItem "C:\ProgramData\chocolatey\lib", "C:\tools" `
               -Recurse -Filter "httpd.exe" -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) {
            $apacheDir = Split-Path (Split-Path $hit.FullName -Parent) -Parent
            Write-Info "Apache encontrado en: $apacheDir"
        }
    }

    if (-not $apacheDir) {
        Write-Err "No se encontro httpd.exe. Reinstalacion recomendada."
        return
    }
    Write-Ok "Apache encontrado en: $apacheDir"

    $confFile = "$apacheDir\conf\httpd.conf"
    $webroot  = "$apacheDir\htdocs"

    if (Test-Path $confFile) {
        $conf = Get-Content $confFile
        # Habilitar mod_headers y otros si estan comentados
        $conf = $conf -replace '#LoadModule headers_module', 'LoadModule headers_module'
        $conf = $conf -replace '#LoadModule rewrite_module', 'LoadModule rewrite_module'
        
        # Aplicar puerto
        $conf = $conf -replace '^Listen \d+',    "Listen $Puerto"
        $conf = $conf -replace '^ServerName .*', "ServerName localhost:$Puerto"
        
        Set-Content $confFile $conf
        Write-Ok "Configuracion basica y puerto $Puerto aplicados."
    }

    Set-ApacheSecurity     -ConfFile $confFile
    Set-WebRootPermissions -Webroot $webroot -ServiceUser "NETWORK SERVICE"

    $verInstalada = Get-InstalledVersion -Servicio "apache-httpd"
    New-IndexPage      -Servicio "Apache" -Version $verInstalada -Puerto $Puerto -Webroot $webroot
    Set-FirewallRule   -Puerto $Puerto -PuertoAnterior 80 -Servicio "Apache"

    $httpd = "$apacheDir\bin\httpd.exe"
    if (Test-Path $httpd) {
        Write-Info "Registrando e iniciando servicio Apache24..."
        # Intentar instalar servicio si no existe
        & $httpd -k install -n "Apache24" 2>&1 | Out-Null
        
        # Iniciar servicio
        Start-Service "Apache24" -ErrorAction SilentlyContinue
        Set-Service   "Apache24" -StartupType Automatic -ErrorAction SilentlyContinue
        
        # Verificar si inicio correctamente
        $proceso = Get-Process httpd -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proceso) {
            Write-Ok "Servicio Apache24 activo con PID: $($proceso.Id)."
        } else {
            Write-Warn "Apache no parece estar corriendo. Revisa logs en $apacheDir\logs\error.log"
        }
    }

    Write-Section "Apache listo"
    Write-Host "  URL     : http://localhost:$Puerto" -ForegroundColor Green
    Write-Host "  Webroot : $webroot"                 -ForegroundColor Green
}

function Set-ApacheSecurity {
    param([string]$ConfFile)

    if (-not (Test-Path $ConfFile)) { return }
    $content = Get-Content $ConfFile -Raw
    
    if ($content -match "# ===== Seguridad Practica 6 =====") {
        Write-Ok "Seguridad Apache ya estaba aplicada."
        return
    }

    $bloque = @"

# ===== Seguridad Practica 6 =====
ServerTokens Prod
ServerSignature Off
TraceEnable Off

<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always unset Server
</IfModule>

<Location />
    <LimitExcept GET POST HEAD OPTIONS>
        Require all denied
    </LimitExcept>
</Location>
"@
    Add-Content -Path $ConfFile -Value $bloque
    Write-Ok "Seguridad Apache aplicada (ServerTokens Prod, headers, metodos restringidos)."
}

# ------------------------------------------------------------------------------
# NGINX WINDOWS
# ------------------------------------------------------------------------------

function Install-NginxWindows {
    param([int]$Puerto, [string]$Version = "latest")

    Write-Info "Deteniendo procesos previos de Nginx..."
    Stop-Service "Nginx" -Force -ErrorAction SilentlyContinue 2>$null
    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force 2>$null

    $pkgId = if ($script:PKG_MANAGER -eq "winget") { "Nginx.Nginx" } else { "nginx" }
    Write-Info "Instalando Nginx $Version via $script:PKG_MANAGER..."
    Install-Package -Paquete $pkgId -Version $Version

    $nginxDir = @(
        "C:\tools\nginx",
        "C:\nginx",
        "$env:ProgramFiles\nginx",
        "$env:ProgramData\chocolatey\lib\nginx\tools\nginx"
    ) | Where-Object { Test-Path "$_\nginx.exe" } | Select-Object -First 1

    if (-not $nginxDir) {
        $hit = Get-ChildItem "C:\ProgramData\chocolatey\lib" -Recurse -Filter "nginx.exe" -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { $nginxDir = $hit.DirectoryName }
    }

    if (-not $nginxDir) {
        Write-Err "No se encontro directorio de Nginx tras la instalacion."
        return
    }
    Write-Ok "Nginx encontrado en: $nginxDir"

    $confFile = "$nginxDir\conf\nginx.conf"
    $webroot  = "$nginxDir\html"

    $nginxConf = @"
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
    # Guardar nginx.conf SIN BOM (importante para evitar error "unknown directive" en Windows)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($confFile, $nginxConf, $utf8NoBom)
    Write-Ok "nginx.conf generado (sin BOM) con puerto $Puerto."

    Set-WebRootPermissions -Webroot $webroot -ServiceUser "NETWORK SERVICE"

    $verInstalada = Get-InstalledVersion -Servicio "nginx"
    New-IndexPage        -Servicio "Nginx" -Version $verInstalada -Puerto $Puerto -Webroot $webroot
    Set-FirewallRule     -Puerto $Puerto -PuertoAnterior 80 -Servicio "Nginx"
    Register-NginxService -NginxDir $nginxDir

    Write-Section "Nginx listo"
    Write-Host "  URL     : http://localhost:$Puerto" -ForegroundColor Green
    Write-Host "  Webroot : $webroot"                 -ForegroundColor Green
}

function Register-NginxService {
    param([string]$NginxDir)

    if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
        Write-Info "Instalando NSSM para gestionar Nginx..."
        Install-Package -Paquete "nssm" -Version "latest"
        $env:PATH += ";$env:ChocolateyInstall\bin"
    }

    $serviceName = "Nginx"
    $nginxExe    = "$NginxDir\nginx.exe"

    if (Get-Command nssm -ErrorAction SilentlyContinue) {
        Write-Info "Registrando servicio Nginx mediante NSSM..."
        nssm stop    $serviceName 2>$null | Out-Null
        nssm remove  $serviceName confirm 2>$null | Out-Null
        
        nssm install $serviceName $nginxExe 2>&1 | Out-Null
        nssm set     $serviceName AppDirectory $NginxDir 2>&1 | Out-Null
        nssm set     $serviceName Start SERVICE_AUTO_START 2>&1 | Out-Null
        
        Write-Info "Iniciando servicio Nginx..."
        Start-Service $serviceName -ErrorAction SilentlyContinue
        
        # Verificar estado tras unos segundos
        Start-Sleep -Seconds 2
        $s = Get-Service $serviceName -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq "Running") {
            Write-Ok "Servicio Nginx registrado y ACTIVO con éxito."
        } else {
            Write-Err "Nginx no pudo iniciar correctamente. Revisa logs en $NginxDir\logs\error.log"
            # Fallback: intentar ver el primer error del log
            $log = "$NginxDir\logs\error.log"
            if (Test-Path $log) {
                Write-Host "Ultimas lineas del log de error:" -ForegroundColor White
                Get-Content $log -Tail 5
            }
        }
    } else {
        Write-Warn "NSSM no disponible. Iniciando binario directamente..."
        Start-Process $nginxExe -WorkingDirectory $NginxDir -WindowStyle Hidden
        Write-Ok "Nginx iniciado en segundo plano."
    }
}