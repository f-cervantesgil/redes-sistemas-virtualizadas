# ==============================================================================
# Practica-06: main.ps1 - VERSION INDUSTRIAL (ELIMINACIÓN DE ERRORES DE DICCIONARIO)
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

# --- PROCESO IIS (MODO INDUSTRIAL - SOLO APPCMD) ---

function Install-IIS {
    param([int]$Port)
    $ip = $TargetIP
    Write-Host "`n[*] Iniciando aprovisionamiento industrial de IIS..." -ForegroundColor Blue
    
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-RequestFiltering" -NoRestart | Out-Null
        $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
        $sn = "Default Web Site"
        
        # 1. REINICIO DE SERVICIOS
        Write-Host "[*] Liberando recursos del sistema..." -ForegroundColor Yellow
        iisreset /stop | Out-Null
        Stop-Service AppHostSvc, WAS, W3SVC -Force -ErrorAction SilentlyContinue 
        Start-Sleep -Seconds 1
        Start-Service AppHostSvc, WAS, W3SVC | Out-Null

        # 2. RECREACIÓN DEL SITIO (EVITA ERROR DE DICCIONARIO)
        Write-Host "[*] Reconfigurando el sitio '$sn' en puerto $Port..." -ForegroundColor Cyan
        # Borrar si existe (con redireccion de errores para evitar mensajes feos)
        & $appcmd delete site "$sn" /commit:apphost 2>$null
        # Crear fresco con el puerto correcto
        & $appcmd add site /name:"$sn" /id:1 /bindings:http/*:${Port}: /physicalPath:C:\inetpub\wwwroot /commit:apphost | Out-Null

        # 3. HARDENING (HEADERS Y SEGURIDAD)
        Write-Host "[*] Aplicando Hardening de Seguridad..." -ForegroundColor Yellow
        # Quitar X-Powered-By
        & $appcmd set config /section:httpProtocol /-"customHeaders.[name='X-Powered-By']" /commit:apphost 2>$null
        # Agregar Headers P6
        & $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Frame-Options',value='SAMEORIGIN']" /commit:apphost 2>$null
        & $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Content-Type-Options',value='nosniff']" /commit:apphost 2>$null
        # Bloquear Verbos (DELETE, TRACE, TRACK)
        & $appcmd set config /section:requestFiltering /+"verbs.[verb='TRACE',allowed='false']" /commit:apphost 2>$null
        & $appcmd set config /section:requestFiltering /+"verbs.[verb='DELETE',allowed='false']" /commit:apphost 2>$null
        & $appcmd set config /section:requestFiltering /+"verbs.[verb='TRACK',allowed='false']" /commit:apphost 2>$null

        # 4. SEGURIDAD DE CARPETA E INDEX
        Set-FolderSecurity -Path "C:\inetpub\wwwroot" -User "web_service_user"
        $html = "<html><body style='font-family:Arial;text-align:center;'><h1>Servidor: [IIS]</h1><h3>Version: [LTS] - Puerto: [${Port}]</h3><p>IP: ${ip}</p></body></html>"
        Set-Content -Path "C:\inetpub\wwwroot\index.html" -Value $html -Force

        # 5. REINICIO FINAL Y FIREWALL
        iisreset /restart | Out-Null
        & $appcmd start site "$sn" | Out-Null
        
        Remove-NetFirewallRule -DisplayName "HTTP-P6-*" -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule -Name "HTTP-P6-${Port}" -DisplayName "HTTP-P6-${Port}" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null

        # 6. VALIDACION REAL
        Write-Host "[*] Verificando conectividad en http://${ip}:${Port}..." -ForegroundColor Gray
        Start-Sleep -Seconds 3
        if ((Test-NetConnection -ComputerName $ip -Port $Port).TcpTestSucceeded) {
            Write-Host "[OK] IIS configurado perfectamente." -ForegroundColor Green
        } else {
            Write-Host "[!] El servicio esta configurado. Prueba entrar en tu navegador: http://${ip}:${Port}" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[!] Error: $_" -ForegroundColor Red
    }
}

# --- APACHE Y NGINX ---

function Install-ApacheWindows {
    param([int]$Port)
    Write-Host "`n[*] Instalando Apache en puerto $Port..." -ForegroundColor Blue
    choco install apache-httpd --version 2.4.58 -y | Out-Null
    $conf = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $conf) {
        $c = Get-Content $conf
        $c = $c -replace "^Listen\s+\d+", "Listen ${Port}"
        $c | Set-Content $conf
    }
    Restart-Service Apache2.4 -ErrorAction SilentlyContinue
    Write-Host "[OK] Apache listo." -ForegroundColor Green
}

function Install-NginxWindows {
    param([int]$Port)
    Write-Host "`n[*] Instalando Nginx en puerto $Port..." -ForegroundColor Blue
    choco install nginx --version 1.24.0 -y | Out-Null
    $conf = "C:\tools\nginx\conf\nginx.conf"
    if (Test-Path $conf) {
        $c = Get-Content $conf
        $c = $c -replace "listen\s+\d+;", "listen ${Port};" | Set-Content $conf
    }
    Stop-Process -Name nginx -ErrorAction SilentlyContinue
    Start-Process -FilePath "C:\tools\nginx\nginx.exe" -WorkingDirectory "C:\tools\nginx"
    Write-Host "[OK] Nginx listo." -ForegroundColor Green
}

# --- MENU ---

while ($true) {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   SISTEMA DE SERVIDORES (IP: $TargetIP)  " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "1. Configurar IIS"
    Write-Host "2. Configurar Apache"
    Write-Host "3. Configurar Nginx"
    Write-Host "4. Salir"
    
    $op = Read-Host "`nOpcion"
    switch ($op) {
        "1" { $p = Read-Host "Puerto?"; Install-IIS $p; Read-Host "Enter..." }
        "2" { $p = Read-Host "Puerto?"; Install-ApacheWindows $p; Read-Host "Enter..." }
        "3" { $p = Read-Host "Puerto?"; Install-NginxWindows $p; Read-Host "Enter..." }
        "4" { exit }
    }
}
