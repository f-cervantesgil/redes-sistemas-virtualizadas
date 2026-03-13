# ==============================================================================
# Practica-06: main.ps1 - V. FINAL PROFESIONAL (CERO BLOQUEOS Y CERO ERRORES)
# ==============================================================================

$OutputEncoding = [System.Text.Encoding]::UTF8
$TargetIP = "192.168.222.197"

# --- SEGURIDAD NTFS ---

function Set-FolderSecurity {
    param([string]$Path, [string]$User)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $p = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force
        New-LocalUser -Name $User -Password $p -Description "Usuario Web P6" | Out-Null
    }
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($User,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl $Path $acl
}

# --- PROCESO IIS (MODO REPARACION TOTAL) ---

function Install-IIS {
    param([int]$Port)
    # Usamos la variable de nivel superior directamente
    $ip = $TargetIP
    Write-Host "`n[*] Configurando IIS en http://${ip}:${Port}..." -ForegroundColor Blue
    
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-RequestFiltering" -NoRestart | Out-Null
        $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
        
        # 1. PARADA TOTAL PARA EVITAR BLOQUEOS
        Write-Host "[*] Liberando archivos de sistema..." -ForegroundColor Yellow
        iisreset /stop | Out-Null
        Stop-Service AppHostSvc, WAS, W3SVC -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2 # Tiempo para que Windows suelte el .config

        # 2. CONFIGURACION DE PUERTO E IP (USAREMOS APPCMD QUE ES INFALIBLE)
        # Iniciamos solo el servicio de configuracion
        Start-Service AppHostSvc -ErrorAction SilentlyContinue
        
        Write-Host "[*] Aplicando Binding en ${ip}:${Port}..." -ForegroundColor Cyan
        & $appcmd set site "Default Web Site" /bindings:http/${ip}:${Port}: | Out-Null

        # 3. HARDENING (HEADERS Y SEGURIDAD)
        Write-Host "[*] Aplicando Hardening de Seguridad..." -ForegroundColor Yellow
        # Quitar X-Powered-By
        & $appcmd set config /section:httpProtocol /-customHeaders.[name='X-Powered-By'] /commit:apphost 2>$null
        # Agregar Headers P6
        & $appcmd set config /section:httpProtocol /+customHeaders.[name='X-Frame-Options',value='SAMEORIGIN'] /commit:apphost 2>$null
        & $appcmd set config /section:httpProtocol /+customHeaders.[name='X-Content-Type-Options',value='nosniff'] /commit:apphost 2>$null
        # Bloquear Verbos (TRACE, DELETE)
        & $appcmd set config /section:requestFiltering /+verbs.[verb='TRACE',allowed='false'] /commit:apphost 2>$null
        & $appcmd set config /section:requestFiltering /+verbs.[verb='DELETE',allowed='false'] /commit:apphost 2>$null

        # 4. SEGURIDAD DE CARPETA E INDEX
        Set-FolderSecurity -Path "C:\inetpub\wwwroot" -User "web_service_user"
        $html = "<html><body style='font-family:Arial;text-align:center;'><h1>Servidor: [IIS]</h1><h3>Version: [LTS] - Puerto: [${Port}]</h3><p>IP: ${ip}</p></body></html>"
        Set-Content -Path "C:\inetpub\wwwroot\index.html" -Value $html -Force

        # 5. REINICIO FINAL Y FIREWALL
        iisreset /start | Out-Null
        & $appcmd start site "Default Web Site" | Out-Null
        
        Remove-NetFirewallRule -DisplayName "HTTP-P6-*" -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule -Name "HTTP-P6-${Port}" -DisplayName "HTTP-P6-${Port}" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null

        # 6. VALIDACION
        Write-Host "[*] Verificando conectividad..." -ForegroundColor Gray
        Start-Sleep -Seconds 2
        if ((Test-NetConnection -ComputerName $ip -Port $Port).TcpTestSucceeded) {
            Write-Host "[OK] IIS Corriendo perfectamente en http://${ip}:${Port}" -ForegroundColor Green
        }
    } catch {
        Write-Host "[!] Error critico: $_" -ForegroundColor Red
    }
}

# --- APACHE Y NGINX ---

function Install-ApacheWindows {
    param([int]$Port)
    $ip = $TargetIP
    Write-Host "`n[*] Instalando Apache en ${ip}:${Port}..." -ForegroundColor Blue
    choco install apache-httpd --version 2.4.58 -y | Out-Null
    $conf = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $conf) {
        $content = Get-Content $conf
        $content = $content -replace "^Listen\s+\d+", "Listen ${ip}:${Port}"
        $content | Set-Content $conf
    }
    Restart-Service Apache2.4 -ErrorAction SilentlyContinue
    Write-Host "[OK] Apache listo." -ForegroundColor Green
}

function Install-NginxWindows {
    param([int]$Port)
    $ip = $TargetIP
    Write-Host "`n[*] Instalando Nginx en ${ip}:${Port}..." -ForegroundColor Blue
    choco install nginx --version 1.24.0 -y | Out-Null
    $conf = "C:\tools\nginx\conf\nginx.conf"
    if (Test-Path $conf) {
        $content = Get-Content $conf
        $content = $content -replace "listen\s+\d+;", "listen ${ip}:${Port};"
        $content | Set-Content $conf
    }
    Stop-Process -Name nginx -ErrorAction SilentlyContinue
    Start-Process -FilePath "C:\tools\nginx\nginx.exe" -WorkingDirectory "C:\tools\nginx"
    Write-Host "[OK] Nginx listo." -ForegroundColor Green
}

# --- MENU ---

while ($true) {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   SISTEMA DE SERVIDORES (P6 DEFINITIVO)  " -ForegroundColor Cyan
    Write-Host "   IP OBJETIVO: $TargetIP" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "1. Instalar/Configurar IIS"
    Write-Host "2. Instalar/Configurar Apache"
    Write-Host "3. Instalar/Configurar Nginx"
    Write-Host "4. Salir"
    
    $op = Read-Host "`nSelecciona una opcion"
    switch ($op) {
        "1" { $p = Read-Host "Puerto?"; Install-IIS $p; Read-Host "Enter..." }
        "2" { $p = Read-Host "Puerto?"; Install-ApacheWindows $p; Read-Host "Enter..." }
        "3" { $p = Read-Host "Puerto?"; Install-NginxWindows $p; Read-Host "Enter..." }
        "4" { exit }
    }
}
