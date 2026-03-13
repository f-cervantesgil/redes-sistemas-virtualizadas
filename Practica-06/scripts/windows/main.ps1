# ==============================================================================
# Practica-06: main.ps1 - SOLUCION DEFINITIVA (FORCED WRITE)
# ==============================================================================

$OutputEncoding = [System.Text.Encoding]::UTF8

function New-IndexPage {
    param([string]$Service, [string]$Version, [int]$Port, [string]$Path)
    $html = "Servidor: $Service`nVersion: $Version`nPuerto: $Port"
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    Set-Content -Path (Join-Path $Path "index.html") -Value $html -Force
}

function Install-IIS {
    param([int]$Port)
    Write-Host "`n[*] Aplicando configuracion de IIS (Modo Forzado)..." -ForegroundColor Blue
    try {
        # 1. Habilitar caracteristica básica
        Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-CommonHttpFeatures" -NoRestart | Out-Null
        
        # 2. DETENER IIS POR COMPLETO (Para liberar el archivo applicationHost.config)
        Write-Host "[*] Deteniendo servicios para liberar archivos..." -ForegroundColor Yellow
        Stop-Service W3SVC -ErrorAction SilentlyContinue
        Stop-Service WAS -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        # 3. Realizar cambios con el motor apagado
        Import-Module WebAdministration
        $siteName = (Get-Website | Select-Object -First 1).Name
        if (-not $siteName) { $siteName = "Default Web Site" }

        # Usar apccmd para asegurar la escritura fisica
        $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
        if (Test-Path $appcmd) {
            # Limpiar bindings previos y poner el nuevo
            & $appcmd set site /site.name:"$siteName" /bindings:http/*:${Port}: | Out-Null
        } else {
            # Fallback a PowerShell si no hay appcmd
            if (-not (Get-Website -Name "$siteName" -ErrorAction SilentlyContinue)) {
                New-Website -Name "$siteName" -Port $Port -PhysicalPath "C:\inetpub\wwwroot" -Force | Out-Null
            } else {
                Set-ItemProperty "IIS:\Sites\$siteName" -Name bindings -Value @{protocol="http";bindingInformation="*:${Port}:"}
            }
        }

        # 4. REINICIAR TODO
        Write-Host "[*] Levantando servicios..." -ForegroundColor Cyan
        Start-Service WAS -ErrorAction SilentlyContinue
        Start-Service W3SVC -ErrorAction SilentlyContinue
        iisreset /start | Out-Null
        
        New-IndexPage -Service "IIS" -Version "LTS" -Port $Port -Path "C:\inetpub\wwwroot"
        
        # 5. FIREWALL SIN COMPROMISOS
        $rn = "HTTP-Practice-$Port"
        Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "HTTP-Practice-*" } | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name $rn -DisplayName $rn -LocalPort $Port -Protocol TCP -Action Allow -Direction Inbound -Profile Any | Out-Null
        
        Write-Host "[OK] Configuracion completada exitosamente en puerto $Port" -ForegroundColor Green
    } catch {
        Write-Host "[!] Error critico: $_" -ForegroundColor Red
        Write-Host "[*] Intentando recuperacion automatica (iisreset)..." -ForegroundColor Yellow
        iisreset /restart | Out-Null
    }
}

function Install-ApacheWindows {
    param([string]$Version, [int]$Port)
    Write-Host "`n[*] Instalando Apache $Version..." -ForegroundColor Blue
    choco install apache-httpd --version $Version -y | Out-Null
    $conf = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $conf) {
        (Get-Content $conf) -replace "^Listen\s+\d+", "Listen $Port" | Set-Content $conf
    }
    New-IndexPage -Service "Apache" -Version $Version -Port $Port -Path "C:\tools\apache24\htdocs"
    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "Apache-Practice-*" } | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "Apache-Practice-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null
    Restart-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    Write-Host "[OK] Apache funcionando." -ForegroundColor Green
}

function Install-NginxWindows {
    param([string]$Version, [int]$Port)
    Write-Host "`n[*] Instalando Nginx $Version..." -ForegroundColor Blue
    choco install nginx --version $Version -y | Out-Null
    $conf = "C:\tools\nginx\conf\nginx.conf"
    if (Test-Path $conf) {
        (Get-Content $conf) -replace "listen\s+\d+;", "listen $Port;" | Set-Content $conf
    }
    New-IndexPage -Service "Nginx" -Version $Version -Port $Port -Path "C:\tools\nginx\html"
    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "Nginx-Practice-*" } | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "Nginx-Practice-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null
    Stop-Process -Name nginx -ErrorAction SilentlyContinue
    Start-Process -FilePath "C:\tools\nginx\nginx.exe" -WorkingDirectory "C:\tools\nginx"
    Write-Host "[OK] Nginx funcionando." -ForegroundColor Green
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
        } else {
            if (Get-Process -Name $srv.Binary -ErrorAction SilentlyContinue) { $isRunning = $true }
        }
        
        if ($isRunning) {
            $status = "Corriendo"; $color = "Green"
            $conns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { 
                $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                $proc.Name -match $srv.Binary -or $proc.Name -match $srv.Name
            }
            $ports = ($conns.LocalPort | Select-Object -Unique) -join ","
            if (-not $ports) { $ports = "Activo" }
        }
        Write-Host ("{0,-15} | " -f $srv.Name) -NoNewline
        Write-Host ("{0,-12}" -f $status) -ForegroundColor $color -NoNewline
        Write-Host (" | {0,-10}" -f $ports)
    }
}

while ($true) {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "   GESTOR DE SERVIDORES WEB (P6)          " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "1. Configurar IIS"
    Write-Host "2. Instalar Apache"
    Write-Host "3. Instalar Nginx"
    Write-Host "4. Estado"
    Write-Host "5. Salir"
    
    $op = Read-Host "`nOpcion"
    switch ($op) {
        "1" { $p = Read-Host "Puerto?"; Install-IIS $p; Read-Host "Enter..." }
        "2" { $p = Read-Host "Puerto?"; Install-ApacheWindows "2.4.58" $p; Read-Host "Enter..." }
        "3" { $p = Read-Host "Puerto?"; Install-NginxWindows "1.24.0" $p; Read-Host "Enter..." }
        "4" { Get-ServicesStatus; Read-Host "`nEnter..." }
        "5" { exit }
    }
}
