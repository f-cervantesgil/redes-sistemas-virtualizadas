# ==============================================================================
# Practica-06: main.ps1 - VERSION COMPATIBILIDAD TOTAL (FORCE WRITE)
# ==============================================================================

$OutputEncoding = [System.Text.Encoding]::UTF8

# --- UTILIDADES DE SISTEMA ---

function Set-FolderSecurity {
    param([string]$Path, [string]$User)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $pass = ConvertTo-SecureString "P@ssw0rdService2026!" -AsPlainText -Force
        New-LocalUser -Name $User -Password $pass -Description "Servicio Web" | Out-Null
    }
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($User,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl $Path $acl
}

# --- PROCESO IIS (MODO REPARACION) ---

function Install-IIS {
    param([int]$Port)
    Write-Host "`n[*] Iniciando aprovisionamiento de IIS (Modo Reparacion de Bloqueos)..." -ForegroundColor Blue
    try {
        # 1. Asegurar Modulos e Instalacion
        Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-RequestFiltering" -NoRestart | Out-Null
        Import-Module WebAdministration

        # 2. DESBLOQUEO FISICO DEL ARCHIVO CONFIG
        Write-Host "[*] Rompiendo bloqueos de archivos de IIS..." -ForegroundColor Yellow
        $configFile = "$env:SystemRoot\system32\inetsrv\config\applicationHost.config"
        
        # Quitar Solo Lectura y tomar posesion
        attrib -r $configFile
        takeown /f $configFile /a | Out-Null
        icacls $configFile /grant "Administrators:F" | Out-Null

        # Reiniciar servicios de configuracion
        Stop-Service WAS -Force -ErrorAction SilentlyContinue
        Stop-Service AppHostSvc -Force -ErrorAction SilentlyContinue
        iisreset /stop | Out-Null
        Start-Sleep -Seconds 1
        Start-Service AppHostSvc, WAS -ErrorAction SilentlyContinue

        # 3. CONFIGURACION DE PUERTO (METODO DE ALTA DISPONIBILIDAD)
        $sn = "Default Web Site"
        
        # Si el sitio existe, lo borramos para evitar conflictos de bindings bloqueados
        if (Get-Website -Name "$sn" -ErrorAction SilentlyContinue) {
            Remove-Website -Name "$sn" -ErrorAction SilentlyContinue
        }
        
        # Creamos el sitio de nuevo con el puerto ya puesto (esto evita el error de Set-WebBinding)
        New-Website -Name "$sn" -Port $Port -PhysicalPath "C:\inetpub\wwwroot" -IPAddress "*" -Force | Out-Null
        
        # Ejecutar el comando de tu especificacion (Set-WebBinding) como validacion
        Write-Host "[*] Ejecutando Set-WebBinding -Name '$sn' -BindingInformation '*:${Port}:'..." -ForegroundColor Cyan
        Set-WebBinding -Name "$sn" -BindingInformation "*:${Port}:" -PropertyName "Port" -Value $Port -ErrorAction SilentlyContinue

        # 4. HARDENING
        Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "X-Powered-By" -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -filter "system.webServer/httpProtocol/customHeaders" -PSPath "IIS:\Sites\$sn" -Name "." -value @{name='X-Frame-Options';value='SAMEORIGIN'} -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -filter "system.webServer/httpProtocol/customHeaders" -PSPath "IIS:\Sites\$sn" -Name "." -value @{name='X-Content-Type-Options';value='nosniff'} -ErrorAction SilentlyContinue
        
        # Bloquear verbos
        foreach($v in @("TRACE","TRACK","DELETE")){
            Add-WebConfigurationProperty -filter "system.webServer/security/requestFiltering/verbs" -PSPath "IIS:\Sites\$sn" -Name "." -value @{verb=$v;allowed=$false} -ErrorAction SilentlyContinue
        }

        # 5. SEGURIDAD NTFS E INDEX
        Set-FolderSecurity -Path "C:\inetpub\wwwroot" -User "web_service_user"
        $html = "<html><body style='font-family:Arial;text-align:center;'><h1>IIS Seguro en Puerto $Port</h1></body></html>"
        Set-Content -Path "C:\inetpub\wwwroot\index.html" -Value $html -Force

        # 6. REINICIO FINAL
        iisreset /start | Out-Null
        Start-Website -Name "$sn" -ErrorAction SilentlyContinue
        
        # Firewall
        Remove-NetFirewallRule -DisplayName "HTTP-P-*" -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule -Name "HTTP-P-$Port" -DisplayName "HTTP-P-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null

        Write-Host "[OK] IIS configurado perfectamente." -ForegroundColor Green
    } catch {
        Write-Host "[!] Error persistente: $_" -ForegroundColor Red
        Write-Host "[*] Tip: Asegurate de no tener archivos abiertos en $env:SystemRoot\system32\inetsrv\config" -ForegroundColor Gray
    }
}

# --- APACHE Y NGINX ---

function Install-ApacheWindows {
    param([int]$Port)
    Write-Host "`n[*] Instalando Apache..." -ForegroundColor Blue
    choco install apache-httpd --version 2.4.58 -y | Out-Null
    $conf = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $conf) {
        (Get-Content $conf) -replace "^Listen\s+\d+", "Listen $Port" | Set-Content $conf
        Add-Content $conf "`nServerTokens Prod`nServerSignature Off"
    }
    Set-FolderSecurity -Path "C:\tools\apache24\htdocs" -User "web_service_user"
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
    Set-FolderSecurity -Path "C:\tools\nginx\html" -User "web_service_user"
    Stop-Process -Name nginx -ErrorAction SilentlyContinue
    Start-Process -FilePath "C:\tools\nginx\nginx.exe" -WorkingDirectory "C:\tools\nginx"
    Write-Host "[OK] Nginx listo." -ForegroundColor Green
}

# --- MENU ---

while ($true) {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   GESTOR DE SERVIDORES SEGUROS (P6)      " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "1. Instalar IIS (Set-WebBinding + Hardening)"
    Write-Host "2. Instalar Apache (Secured)"
    Write-Host "3. Instalar Nginx (Secured)"
    Write-Host "4. Salir"
    
    $op = Read-Host "`nOpcion"
    switch ($op) {
        "1" { $p = Read-Host "Puerto?"; Install-IIS $p; Read-Host "Enter..." }
        "2" { $p = Read-Host "Puerto?"; Install-ApacheWindows $p; Read-Host "Enter..." }
        "3" { $p = Read-Host "Puerto?"; Install-NginxWindows $p; Read-Host "Enter..." }
        "4" { exit }
    }
}
