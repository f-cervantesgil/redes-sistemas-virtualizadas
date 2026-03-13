# ==============================================================================
# Practica-06: main.ps1 - VERSION FINAL (ANTI-BLOQUEOS Y CONECTIVIDAD TOTAL)
# ==============================================================================

$OutputEncoding = [System.Text.Encoding]::UTF8
$TargetIP = "192.168.222.197"

# --- FUNCION DE LIMPIEZA DE PERMISOS ---

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

# --- PROCESO IIS (MODO APAGADO TOTAL) ---

function Install-IIS {
    param([int]$Port)
    $ip = $TargetIP
    Write-Host "`n[*] Iniciando aprovisionamiento de IIS (Limpieza de bloqueos)..." -ForegroundColor Blue
    
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-RequestFiltering" -NoRestart | Out-Null
        Import-Module WebAdministration
        $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
        
        # 1. MATAR TODO LO QUE BLOQUEA EL ARCHIVO
        Write-Host "[*] Liberando archivo de configuracion..." -ForegroundColor Yellow
        Stop-Process -Name "inetmgr", "w3wp", "appcmd" -Force -ErrorAction SilentlyContinue
        iisreset /stop | Out-Null
        Stop-Service AppHostSvc, WAS, W3SVC, IISADMIN -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3 # Tiempo vital para que Windows suelte el archivo
        
        # Quitar atributos de solo lectura por si acaso
        $confPath = "$env:SystemRoot\system32\inetsrv\config\applicationHost.config"
        attrib -r $confPath

        # 2. CONFIGURACION (Solo arrancamos lo minimo necesario para configurar)
        Start-Service AppHostSvc -ErrorAction SilentlyContinue
        
        Write-Host "[*] Aplicando enlace en ${ip}:${Port}..." -ForegroundColor Cyan
        # Borrar y agregar para evitar errores de "llave duplicada" o "diccionario"
        & $appcmd delete site "Default Web Site" /commit:apphost 2>$null
        & $appcmd add site /name:"Default Web Site" /id:1 /bindings:http/${ip}:${Port}: /physicalPath:C:\inetpub\wwwroot /commit:apphost | Out-Null

        # 3. HARDENING (HEADERS SEGURIDAD)
        Write-Host "[*] Aplicando Hardening..." -ForegroundColor Yellow
        & $appcmd set config /section:httpProtocol /-"customHeaders.[name='X-Powered-By']" /commit:apphost 2>$null
        & $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Frame-Options',value='SAMEORIGIN']" /commit:apphost 2>$null
        & $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Content-Type-Options',value='nosniff']" /commit:apphost 2>$null
        
        # Bloquear Verbos (DELETE, TRACE)
        & $appcmd set config /section:requestFiltering /+"verbs.[verb='TRACE',allowed='false']" /commit:apphost 2>$null
        & $appcmd set config /section:requestFiltering /+"verbs.[verb='DELETE',allowed='false']" /commit:apphost 2>$null

        # 4. SEGURIDAD NTFS E INDEX
        Set-FolderSecurity -Path "C:\inetpub\wwwroot" -User "web_service_user"
        $html = "<html><body style='font-family:Arial;text-align:center;'><h1>IIS SEGURO</h1><hr><h3>IP: $ip - Puerto: $Port</h3></body></html>"
        Set-Content -Path "C:\inetpub\wwwroot\index.html" -Value $html -Force

        # 5. REINICIO FINAL Y FIREWALL (CLAVE PARA EL NAVEGADOR)
        Write-Host "[*] Abriendo Firewall y encendiendo servidor..." -ForegroundColor Yellow
        Remove-NetFirewallRule -DisplayName "HTTP-P6-*" -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule -Name "HTTP-P6-$Port" -DisplayName "HTTP-P6-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null
        
        iisreset /start | Out-Null
        Start-Service WAS, W3SVC -ErrorAction SilentlyContinue
        & $appcmd start site "Default Web Site" | Out-Null

        # 6. VALIDACION REAL
        Write-Host "[*] Verificando conectividad externa..." -ForegroundColor Gray
        Start-Sleep -Seconds 3
        if ((Test-NetConnection -ComputerName $ip -Port $Port).TcpTestSucceeded) {
            Write-Host "[OK] IIS Funcionando perfectamente en http://${ip}:${Port}" -ForegroundColor Green
        } else {
            Write-Host "[!] El servidor esta listo, pero el puerto no responde. Prueba en el navegador." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[!] Error Critico: $_" -ForegroundColor Red
        iisreset /start | Out-Null
    }
}

# --- APACHE Y NGINX ---

function Install-ApacheWindows {
    param([int]$Port)
    $ip = $TargetIP
    Write-Host "`n[*] Instalando Apache en $ip : $Port..." -ForegroundColor Blue
    choco install apache-httpd --version 2.4.58 -y | Out-Null
    $conf = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $conf) {
        (Get-Content $conf) -replace "^Listen\s+\d+", "Listen ${ip}:${Port}" | Set-Content $conf
    }
    Restart-Service Apache2.4 -ErrorAction SilentlyContinue
    Write-Host "[OK] Apache listo." -ForegroundColor Green
}

function Install-NginxWindows {
    param([int]$Port)
    $ip = $TargetIP
    Write-Host "`n[*] Instalando Nginx en $ip : $Port..." -ForegroundColor Blue
    choco install nginx --version 1.24.0 -y | Out-Null
    $conf = "C:\tools\nginx\conf\nginx.conf"
    if (Test-Path $conf) {
        (Get-Content $conf) -replace "listen\s+\d+;", "listen ${ip}:${Port};" | Set-Content $conf
    }
    Stop-Process -Name nginx -ErrorAction SilentlyContinue
    Start-Process -FilePath "C:\tools\nginx\nginx.exe" -WorkingDirectory "C:\tools\nginx"
    Write-Host "[OK] Nginx listo." -ForegroundColor Green
}

# --- MENU ---

while ($true) {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   GESTOR DE SERVIDORES (SOLUCION FINAL)  " -ForegroundColor Cyan
    Write-Host "   IP: $TargetIP" -ForegroundColor Yellow
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
