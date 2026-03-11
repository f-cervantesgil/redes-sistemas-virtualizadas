# ==============================================================================
# Practica-07: http_functions.ps1
# Librería de funciones para aprovisionamiento web automatizado en Windows
# ==============================================================================

# Validar entrada
function Validate-InputString {
    param([string]$InputStr)
    if ([string]::IsNullOrWhiteSpace($InputStr) -or $InputStr -match '[^a-zA-Z0-9._-]') {
        return $false
    }
    return $true
}

# Verificar disponibilidad de puerto
function Test-PortAvailability {
    param([int]$Port)
    $connection = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($connection) {
        return $false # Ocupado
    }
    return $true # Libre
}

# Validar que el puerto esté en el rango válido
function Test-IsReservedPort {
    param([int]$Port)
    if ($Port -lt 1 -or $Port -gt 65535) {
        return $true # Inválido
    }
    return $false # Válido
}

# Obtener versiones dinámicamente usando Chocolatey
function Get-ServiceVersions {
    param([string]$PackageName)
    Write-Host "Consultando versiones para $PackageName en Chocolatey..." -ForegroundColor Blue
    $versions = choco search $PackageName --all | Select-String -Pattern "$PackageName\s+([\d\.]+)" | Select-Object -First 5
    return $versions
}

# Crear página index.html simple
function New-IndexPage {
    param(
        [string]$Service,
        [string]$Version,
        [int]$Port,
        [string]$Path
    )
    
    $html = @"
Servidor: `$Service
Versión: `$Version
Puerto: `$Port
"@
    New-Item -Path $Path -Name "index.html" -Value $html -ItemType File -Force
    # Permisos limitados (Solo lectura para el servicio)
    $acl = Get-Acl $Path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS_IUSRS", "ReadAndExecute", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl $Path $acl
}

# Configuración de Seguridad IIS
function Set-IISSecurity {
    param([int]$Port)
    Write-Host "Configurando seguridad de IIS..." -ForegroundColor Cyan
    Import-Module WebAdministration
    
    # Ocultar X-Powered-By
    Remove-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/httpProtocol/customHeaders" -Name "X-Powered-By" -ErrorAction SilentlyContinue
    
    # Agregar Security Headers
    Add-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -Value @{name='X-Frame-Options';value='SAMEORIGIN'}
    Add-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/httpProtocol/customHeaders" -Name "." -Value @{name='X-Content-Type-Options';value='nosniff'}

    # Abrir Firewall
    New-NetFirewallRule -DisplayName "HTTP-Practice-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Force
}

# Instalación de IIS
function Install-IIS {
    param([int]$Port)
    Write-Host "Habilitando IIS (Internet Information Services)..." -ForegroundColor Blue
    Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-CommonHttpFeatures" -NoRestart
    
    Import-Module WebAdministration
    # Cambiar puerto del sitio por defecto
    Set-WebBinding -Name "Default Web Site" -BindingInformation "*:$Port:"
    
    New-IndexPage -Service "IIS" -Version "LTS (Windows Feature)" -Port $Port -Path "C:\inetpub\wwwroot"
    Set-IISSecurity -Port $Port
}

# Instalación de Apache Win64
function Install-ApacheWindows {
    param([string]$Version, [int]$Port)
    Write-Host "Instalando Apache Win64 versión $Version..." -ForegroundColor Blue
    choco install apache-httpd --version $Version -y
    
    $confPath = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $confPath) {
        (Get-Content $confPath) -replace "Listen 80", "Listen $Port" | Set-Content $confPath
        
        # Ocultar tokens
        Add-Content $confPath "`nServerTokens Prod`nServerSignature Off"
    }
    
    # Firewall
    New-NetFirewallRule -DisplayName "Apache-Practice-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Force
    Start-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
}

# Instalación de Nginx Windows
function Install-NginxWindows {
    param([string]$Version, [int]$Port)
    Write-Host "Instalando Nginx para Windows versión $Version..." -ForegroundColor Blue
    choco install nginx --version $Version -y
    
    $confPath = "C:\tools\nginx\conf\nginx.conf"
    if (Test-Path $confPath) {
        (Get-Content $confPath) -replace "listen\s+80;", "listen $Port;" | Set-Content $confPath
        # Ocultar versión
        (Get-Content $confPath) -replace "#server_tokens off;", "server_tokens off;" | Set-Content $confPath
    }
    
    # Firewall
    New-NetFirewallRule -DisplayName "Nginx-Practice-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Force
    # Nginx en windows se suele correr como proceso o servicio nssm
}

# Bajar servicios en Windows
function Stop-WindowsService {
    param([string]$ServiceName)
    Write-Host "Bajando servicio $ServiceName..." -ForegroundColor Cyan
    switch ($ServiceName) {
        "IIS" { Stop-Service -Name "W3SVC" -ErrorAction SilentlyContinue }
        "Apache" { Stop-Service -Name "Apache2.4" -ErrorAction SilentlyContinue }
        "Nginx" { Stop-Process -Name "nginx" -ErrorAction SilentlyContinue }
    }
    Write-Host "Servicio $ServiceName detenido." -ForegroundColor Green
}
