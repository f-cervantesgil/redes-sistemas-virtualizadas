# ==============================================================================
# Practica-06: main.ps1 - VERSION ESTABILIDAD TOTAL (MODO ARRANQUE FORZADO)
# ==============================================================================

$OutputEncoding = [System.Text.Encoding]::UTF8

# --- FUNCIONES DE SEGURIDAD ---

function Set-FolderSecurity {
    param([string]$Path, [string]$User)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $p = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force
        New-LocalUser -Name $User -Password $p -Description "Usuario Web" | Out-Null
    }
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($User,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl $Path $acl
}

# --- PROCESO IIS (MODO BAJO NIVEL) ---

function Install-IIS {
    param([int]$Port)
    Write-Host "`n[*] Aprovisionando IIS con herramientas nativas..." -ForegroundColor Blue
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-RequestFiltering" -NoRestart | Out-Null
        $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
        $sn = "Default Web Site"

        # 1. Preparación y Reseteo
        Write-Host "[*] Limpiando procesos previos..." -ForegroundColor Yellow
        Stop-Process -Name "w3wp" -ErrorAction SilentlyContinue
        iisreset /stop | Out-Null
        Start-Sleep -Seconds 1
        iisreset /start | Out-Null

        # 2. Configuración de Binding
        Write-Host "[*] Aplicando puerto $Port a '$sn'..." -ForegroundColor Cyan
        & $appcmd set site /site.name:"$sn" /bindings:http/*:${Port}: | Out-Null

        # 3. HARDENING (Seguridad de Encabezados)
        Write-Host "[*] Aplicando Hardening de Seguridad..." -ForegroundColor Yellow
        # Quitar X-Powered-By (ignorando si no existe)
        & $appcmd set config /section:httpProtocol /-customHeaders.[name='X-Powered-By'] /commit:apphost 2>$null
        # Agregar Headers P6
        & $appcmd set config /section:httpProtocol /+customHeaders.[name='X-Frame-Options',value='SAMEORIGIN'] /commit:apphost 2>$null
        & $appcmd set config /section:httpProtocol /+customHeaders.[name='X-Content-Type-Options',value='nosniff'] /commit:apphost 2>$null
        # Bloquear Verbos
        & $appcmd set config /section:requestFiltering /+verbs.[verb='TRACE',allowed='false'] /commit:apphost 2>$null
        & $appcmd set config /section:requestFiltering /+verbs.[verb='DELETE',allowed='false'] /commit:apphost 2>$null

        # 4. Seguridad NTFS e Index
        Set-FolderSecurity -Path "C:\inetpub\wwwroot" -User "web_service_user"
        $html = "<html><body style='font-family:Arial;text-align:center;padding:50px;'><h1>IIS SEGURO</h1><hr><h3>Puerto: $Port</h3><p>Práctica 06 - Hardening Completado</p></body></html>"
        Set-Content -Path "C:\inetpub\wwwroot\index.html" -Value $html -Force

        # 5. ARRANQUE FORZADO DEL SITIO
        Write-Host "[*] Reiniciando y despertando el sitio web..." -ForegroundColor Cyan
        iisreset /restart | Out-Null
        Start-Sleep -Seconds 1
        & $appcmd start site /site.name:"$sn" | Out-Null
        
        # 6. Firewall
        Remove-NetFirewallRule -DisplayName "HTTP-P-*" -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule -Name "HTTP-P-$Port" -DisplayName "HTTP-P-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null

        # 7. VALIDACION PACIENTE
        Write-Host "[*] Verificando conexion en puerto $Port (espera un momento)..." -ForegroundColor Gray
        Start-Sleep -Seconds 3
        if ((Test-NetConnection -ComputerName localhost -Port $Port).TcpTestSucceeded) {
            Write-Host "[OK] IIS funcionando y accesible en el puerto $Port." -ForegroundColor Green
        } else {
            Write-Host "[!] El sitio esta configurado pero Windows aun no abre el puerto. Prueba entrar a http://localhost:$Port manualmente." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[!] Error inesperado: $_" -ForegroundColor Red
    }
}

function Install-ApacheWindows {
    param([int]$Port)
    Write-Host "`n[*] Instalando Apache..." -ForegroundColor Blue
    choco install apache-httpd --version 2.4.58 -y | Out-Null
    $conf = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $conf) {
        $c = Get-Content $conf
        $c = $c -replace "^Listen\s+\d+", "Listen $Port"
        $c += "`nServerTokens Prod`nServerSignature Off"
        $c | Set-Content $conf
    }
    Restart-Service Apache2.4 -ErrorAction SilentlyContinue
    Write-Host "[OK] Apache listo." -ForegroundColor Green
}

function Install-NginxWindows {
    param([int]$Port)
    Write-Host "`n[*] Instalando Nginx..." -ForegroundColor Blue
    choco install nginx --version 1.24.0 -y | Out-Null
    $conf = "C:\tools\nginx\conf\nginx.conf"
    if (Test-Path $conf) {
        (Get-Content $conf) -replace "listen\s+\d+;", "listen $Port;" | Set-Content $conf
    }
    Stop-Process -Name nginx -ErrorAction SilentlyContinue
    Start-Process -FilePath "C:\tools\nginx\nginx.exe" -WorkingDirectory "C:\tools\nginx"
    Write-Host "[OK] Nginx listo." -ForegroundColor Green
}

# --- MENU ---

while ($true) {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   SISTEMA DE SERVIDORES (P6 COMPLETO)    " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "1. Configurar IIS (AppCmd + Hardening)"
    Write-Host "2. Instalar Apache (Secured)"
    Write-Host "3. Instalar Nginx (Secured)"
    Write-Host "4. Salir"
    
    $op = Read-Host "`nOpcion?"
    switch ($op) {
        "1" { $p = Read-Host "Puerto?"; Install-IIS $p; Read-Host "Enter..." }
        "2" { $p = Read-Host "Puerto?"; Install-ApacheWindows $p; Read-Host "Enter..." }
        "3" { $p = Read-Host "Puerto?"; Install-NginxWindows $p; Read-Host "Enter..." }
        "4" { exit }
    }
}
