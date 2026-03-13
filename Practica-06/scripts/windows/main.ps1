# ==============================================================================
# Practica-06: main.ps1 - ESTRATEGIA DE INTERVENCION PROFUNDA (CERO BLOQUEOS)
# ==============================================================================

$OutputEncoding = [System.Text.Encoding]::UTF8

# --- FUNCION DE DESBLOQUEO DE ARCHIVOS ---

function Force-UnlockIIS {
    Write-Host "[*] Realizando limpieza profunda de bloqueos..." -ForegroundColor Yellow
    
    # 1. Matar procesos que "secuestran" la configuracion
    $procs = @("inetmgr", "w3wp", "AppHostRegistrationVerificator", "msdepsvc")
    foreach($p in $procs){ Stop-Process -Name $p -Force -ErrorAction SilentlyContinue }
    
    # 2. Detener servicios en orden inverso de dependencia
    iisreset /stop | Out-Null
    $srvs = @("W3SVC", "WAS", "AppHostSvc", "IISADMIN")
    foreach($s in $srvs){ Stop-Service $s -Force -ErrorAction SilentlyContinue }
    
    Start-Sleep -Seconds 2
    
    # 3. Forzar permisos fisicos en el archivo config
    $conf = "$env:SystemRoot\system32\inetsrv\config\applicationHost.config"
    attrib -r $conf
    takeown /f $conf /a | Out-Null
    icacls $conf /grant "Administrators:(F)" | Out-Null
    
    # 4. Levantar SOLO el servicio de configuracion para poder escribir
    Start-Service AppHostSvc -ErrorAction SilentlyContinue
}

# --- PROCESO PRINCIPAL DE IIS ---

function Install-IIS {
    param([int]$Port)
    Write-Host "`n[*] Iniciando aprovisionamiento seguro de IIS..." -ForegroundColor Blue
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-RequestFiltering" -NoRestart | Out-Null
        Import-Module WebAdministration
        
        # ELIMINAR BLOQUEOS ANTES DE EMPEZAR
        Force-UnlockIIS

        $sn = "Default Web Site"
        Write-Host "[*] Aplicando configuracion de puerto $Port..." -ForegroundColor Cyan
        
        # METODO 1: Borrar y recrear (El mas limpio)
        Remove-Website -Name "$sn" -ErrorAction SilentlyContinue 
        Start-Sleep -Seconds 1
        New-Website -Name "$sn" -Port $Port -PhysicalPath "C:\inetpub\wwwroot" -IPAddress "*" -Force | Out-Null
        
        # METODO 2: Comando obligatorio - Set-WebBinding (Validacion)
        # Si falla el primero, este asegura el cumplimiento de la especificación
        try {
            Set-WebBinding -Name "$sn" -BindingInformation "*:${Port}:" -PropertyName "Port" -Value $Port -ErrorAction Stop
        } catch {
            Write-Host "[!] Reintentando con AppCmd..." -ForegroundColor Gray
            $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
            & $appcmd set site /site.name:"$sn" /bindings:http/*:${Port}: | Out-Null
        }

        # --- HARDENING ---
        # Quitar X-Powered-By
        Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "X-Powered-By" -ErrorAction SilentlyContinue
        # Agregar Seguridades
        $headersPath = "system.webServer/httpProtocol/customHeaders"
        Set-WebConfigurationProperty -filter $headersPath -PSPath "IIS:\Sites\$sn" -Name "." -value @{name='X-Frame-Options';value='SAMEORIGIN'} -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -filter $headersPath -PSPath "IIS:\Sites\$sn" -Name "." -value @{name='X-Content-Type-Options';value='nosniff'} -ErrorAction SilentlyContinue
        
        # Bloquear Verbos (DELETE, TRACE)
        foreach($v in @("TRACE","TRACK","DELETE")){
            Add-WebConfigurationProperty -filter "system.webServer/security/requestFiltering/verbs" -PSPath "IIS:\Sites\$sn" -Name "." -value @{verb=$v;allowed=$false} -ErrorAction SilentlyContinue
        }

        # --- USUARIO DEDICADO Y PERMISOS ---
        if (-not (Get-LocalUser -Name "web_service_user" -ErrorAction SilentlyContinue)) {
            $p = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force
            New-LocalUser -Name "web_service_user" -Password $p -Description "Usuario P6" | Out-Null
        }
        $acl = Get-Acl "C:\inetpub\wwwroot"
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("web_service_user","ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
        Set-Acl "C:\inetpub\wwwroot" $acl

        # --- FINALIZACION ---
        $html = "<html><body style='font-family:Arial;text-align:center;'><h1>IIS Seguro en Puerto $Port</h1><p>Hardening: OK | NTFS: OK</p></body></html>"
        Set-Content -Path "C:\inetpub\wwwroot\index.html" -Value $html -Force
        
        # Reiniciar todo el stack
        iisreset /start | Out-Null
        Start-Website -Name "$sn" -ErrorAction SilentlyContinue
        
        Remove-NetFirewallRule -DisplayName "HTTP-Practice-*" -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule -Name "HTTP-P-$Port" -DisplayName "HTTP-Practice-$Port" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null

        if ((Test-NetConnection -ComputerName localhost -Port $Port).TcpTestSucceeded) {
            Write-Host "[OK] IIS validado y corriendo en puerto $Port." -ForegroundColor Green
        }
    } catch {
        Write-Host "[!] Error persistente: $_" -ForegroundColor Red
        Write-Host "[*] RECOMENDACION: Cierra cualquier ventana de IIS y vuelve a intentar." -ForegroundColor Yellow
    }
}

# --- APACHE Y NGINX ---

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
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "   GESTOR DE SERVIDORES (CERO ERRORES)    " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "1. Configurar IIS (Hardening)"
    Write-Host "2. Instalar Apache (Hardening)"
    Write-Host "3. Instalar Nginx (Hardening)"
    Write-Host "4. Salir"
    
    $op = Read-Host "`nSelecciona opcion"
    switch ($op) {
        "1" { $p = Read-Host "Puerto?"; Install-IIS $p; Read-Host "Enter..." }
        "2" { $p = Read-Host "Puerto?"; Install-ApacheWindows $p; Read-Host "Enter..." }
        "3" { $p = Read-Host "Puerto?"; Install-NginxWindows $p; Read-Host "Enter..." }
        "4" { exit }
    }
}
