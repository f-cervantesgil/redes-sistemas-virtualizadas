# ==============================================================================
# Practica-06: main.ps1
# ==============================================================================

# Forzar codificacion UTF8 para evitar simbolos extraños
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- LIBRERIA DE FUNCIONES INTEGRADAS (PARA EVITAR ERRORES DE RUTA) ---

function Test-PortAvailability {
    param([int]$Port)
    $connection = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($connection) { return $false }
    return $true
}

function Test-IsReservedPort {
    param([int]$Port)
    if ($Port -lt 1 -or $Port -gt 65535) { return $true }
    return $false
}

function Get-ServiceVersions {
    param([string]$PackageName)
    Write-Host "Consultando versiones para $PackageName en Chocolatey..." -ForegroundColor Blue
    $versions = choco search $PackageName --all | Select-String -Pattern "$PackageName\s+([\d\.]+)" | Select-Object -First 5
    return $versions
}

function New-IndexPage {
    param([string]$Service, [string]$Version, [int]$Port, [string]$Path)
    $html = "Servidor: $Service`nVersion: $Version`nPuerto: $Port"
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force }
    Set-Content -Path (Join-Path $Path "index.html") -Value $html -Force
    Write-Host "Pagina de index creada en $Path" -ForegroundColor Gray
}

function Install-IIS {
    param([int]$Port)
    Write-Host "Habilitando IIS (Internet Information Services)..." -ForegroundColor Blue
    Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-CommonHttpFeatures" -NoRestart
    Import-Module WebAdministration
    Set-WebBinding -Name "Default Web Site" -BindingInformation "*:$Port:"
    New-IndexPage -Service "IIS" -Version "LTS" -Port $Port -Path "C:\inetpub\wwwroot"
    New-NetFirewallRule -DisplayName "HTTP-Practice-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Force
    Write-Host "IIS configurado correctamente en el puerto $Port" -ForegroundColor Green
}

function Install-ApacheWindows {
    param([string]$Version, [int]$Port)
    Write-Host "Instalando Apache version $Version..." -ForegroundColor Blue
    choco install apache-httpd --version $Version -y
    $confPath = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $confPath) {
        (Get-Content $confPath) -replace "^Listen\s+\d+", "Listen $Port" | Set-Content $confPath
        Add-Content $confPath "`nServerTokens Prod`nServerSignature Off"
    }
    New-IndexPage -Service "Apache" -Version $Version -Port $Port -Path "C:\tools\apache24\htdocs"
    New-NetFirewallRule -DisplayName "Apache-Practice-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Force
    Start-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    Write-Host "Apache configurado en el puerto $Port" -ForegroundColor Green
}

function Install-NginxWindows {
    param([string]$Version, [int]$Port)
    Write-Host "Instalando Nginx version $Version..." -ForegroundColor Blue
    choco install nginx --version $Version -y
    $confPath = "C:\tools\nginx\conf\nginx.conf"
    if (Test-Path $confPath) {
        (Get-Content $confPath) -replace "listen\s+\d+;", "listen $Port;" | Set-Content $confPath
        (Get-Content $confPath) -replace "server_tokens off;", "server_tokens off;" | Set-Content $confPath
    }
    New-IndexPage -Service "Nginx" -Version $Version -Port $Port -Path "C:\tools\nginx\html"
    New-NetFirewallRule -DisplayName "Nginx-Practice-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Force
    Write-Host "Nginx configurado en el puerto $Port" -ForegroundColor Green
}

function Get-ServicesStatus {
    Write-Host "`n==========================================" -ForegroundColor Blue
    Write-Host "       ESTADO DE LOS SERVICIOS WEB        " -ForegroundColor Blue
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host ("{0,-15} | {1,-12} | {2,-10}" -f "SERVICIO", "ESTADO", "PUERTO(S)")
    $services = @(
        @{Name="IIS"; Binary="w3wp"; SrvName="W3SVC"},
        @{Name="Apache"; Binary="httpd"; SrvName="Apache2.4"},
        @{Name="Nginx"; Binary="nginx"; SrvName=""}
    )
    foreach ($srv in $services) {
        $status = "Detenido"; $color = "Red"; $ports = "-"
        $isRunning = $false
        if ($srv.SrvName -ne "") {
            $s = Get-Service -Name $srv.SrvName -ErrorAction SilentlyContinue
            if ($s -and $s.Status -eq "Running") { $isRunning = $true }
        } else { if (Get-Process -Name $srv.Binary -ErrorAction SilentlyContinue) { $isRunning = $true } }
        if ($isRunning) {
            $status = "Corriendo"; $color = "Green"
            if ($srv.Name -eq "IIS") {
                try {
                    Import-Module WebAdministration
                    $ports = (Get-WebBinding -Protocol "http").bindingInformation.Split(":")[1] -join ","
                } catch { $ports = "Error" }
            } else {
                $conns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name -like "*$($srv.Binary)*" }
                $ports = ($conns.LocalPort | Select-Object -Unique) -join ","
            }
        }
        Write-Host ("{0,-15} | " -f $srv.Name) -NoNewline
        Write-Host ("{0,-12}" -f $status) -ForegroundColor $color -NoNewline
        Write-Host (" | {0,-10}" -f $ports)
    }
}

function Stop-WindowsService {
    param([string]$ServiceName)
    switch ($ServiceName) {
        "IIS" { Stop-Service -Name "W3SVC" -ErrorAction SilentlyContinue }
        "Apache" { Stop-Service -Name "Apache2.4" -ErrorAction SilentlyContinue }
        "Nginx" { Stop-Process -Name "nginx" -ErrorAction SilentlyContinue }
    }
    Write-Host "Servicio $ServiceName detenido." -ForegroundColor Green
}

function Clear-WindowsService {
    param([string]$ServiceName)
    Write-Host "Limpiando rastros de $ServiceName..." -ForegroundColor Red
    switch ($ServiceName) {
        "IIS" { 
            Disable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer" -NoRestart
            if (Test-Path "C:\inetpub\wwwroot\index.html") { Remove-Item "C:\inetpub\wwwroot\index.html" -Force }
        }
        "Apache" { 
            Stop-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
            choco uninstall apache-httpd -y; 
            if (Test-Path "C:\tools\apache24") { Remove-Item "C:\tools\apache24" -Recurse -Force -ErrorAction SilentlyContinue }
        }
        "Nginx" { 
            Stop-Process -Name "nginx" -ErrorAction SilentlyContinue
            choco uninstall nginx -y; 
            if (Test-Path "C:\tools\nginx") { Remove-Item "C:\tools\nginx" -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Host "Limpieza de $ServiceName completada." -ForegroundColor Green
}

# --- LOGICA DEL MENU ---

while ($true) {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "   SISTEMA DE APROVISIONAMIENTO WEB (WIN)   " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "1. Instalar IIS (Obligatorio)"
    Write-Host "2. Instalar Apache"
    Write-Host "3. Instalar Nginx"
    Write-Host "4. Mostrar estado de los servicios"
    Write-Host "5. Bajar un servicio"
    Write-Host "6. Eliminar por completo un servicio (Purge)"
    Write-Host "7. Salir"
    Write-Host "==========================================" -ForegroundColor Green
    
    $opt = Read-Host "Seleccione una opcion"
    
    switch ($opt) {
        "1" {
            $port = Read-Host "Ingrese el puerto para IIS"
            if (Test-IsReservedPort $port) { Write-Host "Puerto invalido"; Start-Sleep 2; continue }
            Install-IIS $port
            Read-Host "Enter para continuar..."
        }
        "2" {
            $port = Read-Host "Ingrese el puerto para Apache"
            if (Test-IsReservedPort $port) { Write-Host "Puerto invalido"; Start-Sleep 2; continue }
            Install-ApacheWindows "2.4.58" $port
            Read-Host "Enter para continuar..."
        }
        "3" {
            $port = Read-Host "Ingrese el puerto para Nginx"
            if (Test-IsReservedPort $port) { Write-Host "Puerto invalido"; Start-Sleep 2; continue }
            Install-NginxWindows "1.24.0" $port
            Read-Host "Enter para continuar..."
        }
        "4" {
            Get-ServicesStatus
            Read-Host "`nPresione Enter para continuar..."
        }
        "5" {
            Write-Host "1.IIS 2.Apache 3.Nginx"
            $s = Read-Host "Opcion"
            if($s -eq "1"){ Stop-WindowsService "IIS" }
            elseif($s -eq "2"){ Stop-WindowsService "Apache" }
            elseif($s -eq "3"){ Stop-WindowsService "Nginx" }
            Read-Host "Enter para continuar..."
        }
        "6" {
            Write-Host "1.IIS 2.Apache 3.Nginx"
            $p = Read-Host "Opcion para eliminacion total"
            if($p -eq "1"){ Clear-WindowsService "IIS" }
            elseif($p -eq "2"){ Clear-WindowsService "Apache" }
            elseif($p -eq "3"){ Clear-WindowsService "Nginx" }
            Read-Host "Enter para continuar..."
        }
        "7" { exit }
        Default { Write-Host "Opcion no valida"; Start-Sleep 1 }
    }
}
