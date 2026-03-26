# p7_functions_windows.ps1
# Funciones auxiliares para Menu Windows - Practica 7

# Forzar el uso de TLS 1.2 para evitar rechazos en servidores HTTPS modernos (GitHub, Nginx, etc)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Global:USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"

function fn_info { Write-Host "[INFO] $($args)" -ForegroundColor Yellow }
function fn_ok { Write-Host "[OK] $($args)" -ForegroundColor Green }
function fn_err { Write-Host "[ERROR] $($args)" -ForegroundColor Red }

function fn_check_admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        fn_err "Por favor, ejecuta PowerShell como Administrador."
        Start-Sleep 5
        exit
    }
}

function fn_show_header {
    Clear-Host
    Write-Host " +============================================================+" -ForegroundColor Blue
    Write-Host " |      APROVISIONAMIENTO DE SERVIDORES WEB (WINDOWS)         |" -ForegroundColor Blue
    Write-Host " |      Practica 7 - Automatizacion FTP/Web e Hibridos        |" -ForegroundColor Blue
    Write-Host " +============================================================+" -ForegroundColor Blue
    Write-Host ""
}


function fn_configurar_ftp_windows {
    echo ""
    Write-Host "=== CONFIGURACION FTPS (Windows Server) ===" -ForegroundColor Cyan
    fn_info "Realizando limpieza profunda y reset de FTP..."

    Install-WindowsFeature Web-Server,Web-Mgmt-Tools,Web-Scripting-Tools,Web-FTP-Server,Web-FTP-Service,Web-FTP-Ext -IncludeManagementTools | Out-Null
    Import-Module WebAdministration -ErrorAction Stop

    $SiteName    = "Practica7_FTP"
    $Root        = "C:\Practica7_FTP"
    $AnonRoot    = Join-Path $Root "LocalUser\Public"
    $Repo        = Join-Path $AnonRoot "pub\windows"
    $PassiveLow  = 50000
    $PassiveHigh = 50050
    $appcmd      = "$env:windir\System32\inetsrv\appcmd.exe"

    if (-not (Test-Path $appcmd)) {
        throw "No se encontro appcmd.exe en $appcmd"
    }

    # Estructura correcta para IIS FTP anonimo
    New-Item -Path $Repo -ItemType Directory -Force | Out-Null
    New-Item -Path "$Repo\iis"    -ItemType Directory -Force | Out-Null
    New-Item -Path "$Repo\apache" -ItemType Directory -Force | Out-Null
    New-Item -Path "$Repo\nginx"  -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $AnonRoot "README.txt") -Value "Repositorio FTP Practica 7" -Force

    # Limpieza segura
    if (Test-Path "IIS:\Sites\$SiteName") {
        try { Stop-WebSite -Name $SiteName -ErrorAction SilentlyContinue } catch {}
        try { Remove-Website -Name $SiteName -ErrorAction SilentlyContinue } catch {}
    } else {
        & $appcmd delete site /site.name:"$SiteName" 2>$null | Out-Null
    }

    if (Test-Path "IIS:\Sites\Default FTP Site") {
        try { Stop-WebSite -Name "Default FTP Site" -ErrorAction SilentlyContinue } catch {}
        try { Remove-Website -Name "Default FTP Site" -ErrorAction SilentlyContinue } catch {}
    } else {
        & $appcmd delete site /site.name:"Default FTP Site" 2>$null | Out-Null
    }

    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    # Crear sitio FTP limpio
    New-WebFtpSite -Name $SiteName -Port 21 -PhysicalPath $Root -Force | Out-Null

    # Configuracion del sitio FTP
    & $appcmd set config -section:system.applicationHost/sites "/[name='$SiteName'].ftpServer.userIsolation.mode:StartInUsersDirectory" /commit:apphost | Out-Null
    & $appcmd set config -section:system.applicationHost/sites "/[name='$SiteName'].ftpServer.security.authentication.anonymousAuthentication.enabled:True" /commit:apphost | Out-Null
    & $appcmd set config -section:system.applicationHost/sites "/[name='$SiteName'].ftpServer.security.authentication.anonymousAuthentication.userName:IUSR" /commit:apphost | Out-Null
    & $appcmd set config -section:system.applicationHost/sites "/[name='$SiteName'].ftpServer.security.authentication.basicAuthentication.enabled:False" /commit:apphost | Out-Null

    # Reglas de autorizacion del sitio
    Clear-WebConfiguration -Filter /system.ftpServer/security/authorization -PSPath 'IIS:\' -Location $SiteName -ErrorAction SilentlyContinue
    Add-WebConfiguration -Filter /system.ftpServer/security/authorization -PSPath 'IIS:\' -Location $SiteName -Value @{accessType='Allow';users='?';permissions='Read'} | Out-Null

    # Rango pasivo global para FileZilla
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.ftpServer/firewallSupport' -Name 'lowDataChannelPort' -Value $PassiveLow
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.ftpServer/firewallSupport' -Name 'highDataChannelPort' -Value $PassiveHigh

    fn_ok "Autenticacion anonima y reglas FTP configuradas correctamente"

    # Permisos NTFS
    fn_info "Aplicando permisos NTFS correctos para IUSR..."
    foreach ($p in @($Root, (Join-Path $Root 'LocalUser'), $AnonRoot, (Join-Path $AnonRoot 'pub'), $Repo)) {
        if (Test-Path $p) {
            icacls $p /grant 'IUSR:(OI)(CI)RX' /T /C /Q | Out-Null
            icacls $p /grant 'IIS_IUSRS:(OI)(CI)RX' /T /C /Q | Out-Null
            icacls $p /grant 'Users:(OI)(CI)RX' /T /C /Q | Out-Null
        }
    }

    # SSL opcional
    $ftpCert = New-SelfSignedCertificate -DnsName 'windows.ftp.local' -CertStoreLocation 'cert:\LocalMachine\My' -ErrorAction SilentlyContinue
    if ($ftpCert) {
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name 'ftpServer.security.ssl.serverCertHash' -Value $ftpCert.GetCertHashString()
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name 'ftpServer.security.ssl.serverCertStoreName' -Value 'My'
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name 'ftpServer.security.ssl.controlChannelPolicy' -Value 'SslAllow'
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name 'ftpServer.security.ssl.dataChannelPolicy' -Value 'SslAllow'
        fn_ok 'Certificado SSL auto-firmado configurado (FTPS permitido)'
    } else {
        fn_info 'No se pudo crear certificado SSL -> FTP seguira permitido sin requerir TLS'
    }

    # Firewall
    if (-not (Get-NetFirewallRule -DisplayName 'Practica7 FTP Control 21' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'Practica7 FTP Control 21' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 21 | Out-Null
    }
    if (-not (Get-NetFirewallRule -DisplayName 'Practica7 FTP Passive 50000-50050' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'Practica7 FTP Passive 50000-50050' -Direction Inbound -Action Allow -Protocol TCP -LocalPort "$PassiveLow-$PassiveHigh" | Out-Null
    }

    Start-Service ftpsvc -ErrorAction SilentlyContinue
    Start-WebSite -Name $SiteName -ErrorAction SilentlyContinue

    fn_ok 'FTP reiniciado correctamente.'

    fn_info 'Descargando instaladores oficiales a las carpetas FTP...'
    try {
        if (-not (Test-Path "$Repo\apache\httpd.zip")) {
            Invoke-WebRequest 'https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-win64-VS17.zip' -UserAgent $Global:USER_AGENT -OutFile "$Repo\apache\httpd.zip" -ErrorAction Stop
        }
        if (-not (Test-Path "$Repo\nginx\nginx.zip")) {
            Invoke-WebRequest 'https://nginx.org/download/nginx-1.26.2.zip' -UserAgent $Global:USER_AGENT -OutFile "$Repo\nginx\nginx.zip" -ErrorAction Stop
        }
        if (-not (Test-Path "$Repo\iis\iis_web.zip")) {
            Set-Content -Path "$env:TEMP\dummy_iis.txt" -Value 'Dummy IIS'
            Compress-Archive -Path "$env:TEMP\dummy_iis.txt" -DestinationPath "$Repo\iis\iis_web.zip" -Force
        }
        fn_ok 'Instaladores descargados correctamente.'
    } catch {
        fn_err "Error al descargar algunos archivos (verifica internet). $($_.Exception.Message)"
    }

    Write-Host ''
    Write-Host 'Prueba en FileZilla con:' -ForegroundColor Cyan
    Write-Host '  Host: <IP_DEL_SERVER>' -ForegroundColor White
    Write-Host '  Puerto: 21' -ForegroundColor White
    Write-Host '  Usuario: anonymous' -ForegroundColor White
    Write-Host '  Contrasena: cualquier correo o texto' -ForegroundColor White
    Write-Host '  Cifrado: FTP explicito sobre TLS si esta disponible' -ForegroundColor White
    Write-Host '  Ruta esperada: /pub/windows/' -ForegroundColor White

    Read-Host 'Presiona ENTER para continuar'
}

function fn_generar_certificado_ssl {
    param($NombreApp)
    $SSL_DIR = "C:\ssl\$NombreApp"
    New-Item -Path $SSL_DIR -ItemType Directory -Force | Out-Null

    if (-not (Test-Path "C:\ssl\openssl.exe")) {
        Write-Host "Preparando instalacion de OpenSSL dinamica..." -ForegroundColor Yellow
        Invoke-WebRequest "https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-win64-VS17.zip" -UserAgent $Global:USER_AGENT -OutFile "$env:TEMP\tmp_ap.zip" -ErrorAction SilentlyContinue
        Expand-Archive "$env:TEMP\tmp_ap.zip" -DestinationPath "$env:TEMP\tmp_ap" -Force -ErrorAction SilentlyContinue
        Copy-Item "$env:TEMP\tmp_ap\Apache24\bin\openssl.exe" -Destination "C:\ssl\" -ErrorAction SilentlyContinue
        Copy-Item "$env:TEMP\tmp_ap\Apache24\bin\libcrypto*.dll" -Destination "C:\ssl\" -ErrorAction SilentlyContinue
        Copy-Item "$env:TEMP\tmp_ap\Apache24\bin\libssl*.dll" -Destination "C:\ssl\" -ErrorAction SilentlyContinue
    }

    Write-Host ">> Generando certificado PEM (cert y key) para $NombreApp..." -ForegroundColor Magenta
    try {
        if (Test-Path "C:\ssl\openssl.exe") {
            # Se usa una configuracion por defecto silenciosa
            $config = "[req]`ndistinguished_name=req_distinguished_name`nprompt=no`n[req_distinguished_name]`nC=MX`nCN=$script:DOMINIO"
            Set-Content -Path "C:\ssl\openssl.cnf" -Value $config
            $p = Start-Process -FilePath "C:\ssl\openssl.exe" -ArgumentList "req -x509 -nodes -days 365 -newkey rsa:2048 -keyout `"$SSL_DIR\server.key`" -out `"$SSL_DIR\server.crt`" -config `"C:\ssl\openssl.cnf`"" -NoNewWindow -PassThru -Wait
            fn_ok "Certificado PEM OK!"
        } else {
            fn_err "OpenSSL fallo en extraerse. SSL no se completara."
        }
    } catch { fn_err "Fallo la creacion ssl" }
}

function fn_instalar_servicio_hibrido {
    param($Servicio, $Display)
    
    echo ""
    Write-Host "====== INSTALACION DE $Display (WINDOWS) ======" -ForegroundColor Cyan
    Write-Host "Origen? [1] WEB (Internet)  [2] FTP (Local)" -ForegroundColor Yellow
    $O = Read-Host "Elige"
    $Origen = if ($O -eq "1") { "web" } elseif ($O -eq "2") { "ftp" } else { return }

    Write-Host "Ingresa puerto (ej: 8080, 5051):" -ForegroundColor Yellow
    $Puerto = Read-Host "Puerto"

    Write-Host "Deseas instalar con certificado SSL (HTTPS)? (s/n)" -ForegroundColor Yellow
    $SSL = Read-Host "SSL"
    if ($SSL -eq "s") {
        Write-Host "Dominio para certificado (ej: reprobados.com):" -ForegroundColor Yellow
        $script:DOMINIO = Read-Host "Dominio"
    } else { $script:DOMINIO = "localhost" }

    switch ($Servicio) {
        "IIS"    { fn_iis_install $Origen $Puerto $SSL }
        "Apache" { fn_apache_install $Origen $Puerto $SSL }
        "Nginx"  { fn_nginx_install $Origen $Puerto $SSL }
    }
    Read-Host "Presiona ENTER para continuar"
}

function fn_iis_install {
    param($Origen, $Puerto, $SSL)
    fn_info "Desplegando IIS en Windows Server..."
    Install-WindowsFeature Web-Server | Out-Null
    Import-Module WebAdministration
    
    if ($Origen -eq "ftp") {
        fn_info "Descargando modulos desde FTP interno 127.0.0.1..."
        try { Invoke-WebRequest "ftp://localhost/pub/windows/iis/iis_web.zip" -OutFile "$env:TEMP\iis.zip" } catch { fn_err "IIS en FTP no encontrado, asegura haber corrido [4] Configurar FTP primero."}
    } else {
        fn_info "Simulando descarga modulos WEB..."
    }

    $site = "Default Web Site"
    Get-WebBinding -Name $site | Remove-WebBinding -ErrorAction SilentlyContinue

    if ($SSL -eq "s") {
        New-WebBinding -Name $site -Protocol https -Port $Puerto -IPAddress "*"
        $cert = New-SelfSignedCertificate -DnsName $script:DOMINIO -CertStoreLocation "cert:\LocalMachine\My" -ErrorAction SilentlyContinue
        $path = "IIS:\SslBindings\0.0.0.0!$Puerto"
        $cert | New-Item -Path $path -ErrorAction SilentlyContinue
    } else {
        New-WebBinding -Name $site -Protocol http -Port $Puerto -IPAddress "*"
    }
    
    $HTML = @"
<!DOCTYPE html>
<html>
<body style="background:#1a1a2e;color:white;text-align:center;padding-top:100px;font-family:sans-serif;">
    <h1 style="color:#e94560;">IIS Windows</h1>
    <p>Servidor activo en puerto $Puerto</p>
    <p>Dominio: $script:DOMINIO | SSL: $SSL</p>
    <p>Instalado desde $Origen</p>
</body>
</html>
"@
    Set-Content "C:\inetpub\wwwroot\index.html" $HTML -Force
    Remove-Item "C:\inetpub\wwwroot\iisstart.htm" -ErrorAction SilentlyContinue
    Restart-Service W3SVC
    fn_ok "IIS iniciado y funcionando en puerto $Puerto."
}

function fn_apache_install {
    param($Origen, $Puerto, $SSL)

    fn_info "Limpiando servicios previos de Apache..."
    Stop-Service Apache24 -Force -ErrorAction SilentlyContinue
    Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force
    sc.exe delete Apache24 2>$null | Out-Null

    $destZip = "$env:TEMP\apache.zip"
    Remove-Item $destZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\Apache24" -ErrorAction SilentlyContinue

    if ($Origen -eq "ftp") {
        fn_info "Buscando Apache en repositorio FTP/local..."

        $candidatos = @(
            "C:\Practica7_FTP\LocalUser\Public\pub\windows\apache\httpd.zip",
            "C:\Practica7_FTP\pub\windows\apache\httpd.zip",
            "C:\inetpub\ftproot\LocalUser\Public\pub\windows\apache\httpd.zip",
            "C:\inetpub\ftproot\pub\windows\apache\httpd.zip"
        )

        $zipLocal = $candidatos | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($zipLocal) {
            fn_ok "Apache encontrado en: $zipLocal"
            Copy-Item $zipLocal $destZip -Force
        }
        else {
            fn_info "No se encontro por ruta local. Intentando por FTP..."
            try {
                Invoke-WebRequest "ftp://127.0.0.1/pub/windows/apache/httpd.zip" -OutFile $destZip -ErrorAction Stop
            } catch {
                fn_err "No hay Apache en FTP."
                Read-Host "Presiona ENTER para continuar"
                return
            }
        }
    }
    else {
        fn_info "Descargando Apache desde WEB..."
        try {
            Invoke-WebRequest "https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-win64-VS17.zip" `
                -UserAgent $Global:USER_AGENT `
                -OutFile $destZip `
                -ErrorAction Stop
        } catch {
            fn_err "No se pudo descargar Apache desde internet: $($_.Exception.Message)"
            Read-Host "Presiona ENTER para continuar"
            return
        }
    }

    if (-not (Test-Path $destZip)) {
        fn_err "No existe el archivo $destZip. Se cancela la instalacion."
        Read-Host "Presiona ENTER para continuar"
        return
    }

    fn_info "Descomprimiendo Apache en C:\ ..."
    try {
        Expand-Archive $destZip -DestinationPath "C:\" -Force -ErrorAction Stop
    } catch {
        fn_err "Fallo al descomprimir Apache: $($_.Exception.Message)"
        Read-Host "Presiona ENTER para continuar"
        return
    }

    if (-not (Test-Path "C:\Apache24")) {
        $extraida = Get-ChildItem "C:\" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^Apache24" } | Select-Object -First 1
        if ($extraida -and $extraida.FullName -ne "C:\Apache24") {
            Rename-Item $extraida.FullName "C:\Apache24" -Force
        }
    }

    if (-not (Test-Path "C:\Apache24\conf\httpd.conf")) {
        fn_err "No se encontro C:\Apache24\conf\httpd.conf despues de extraer Apache."
        Read-Host "Presiona ENTER para continuar"
        return
    }

    $conf = "C:\Apache24\conf\httpd.conf"

    (Get-Content $conf) -replace '^Listen\s+\d+', "Listen $Puerto" | Set-Content $conf
    (Get-Content $conf) -replace '#ServerName www.example.com:80', "ServerName $($script:DOMINIO):$Puerto" | Set-Content $conf
    (Get-Content $conf) -replace '^ServerName\s+localhost:80', "ServerName $($script:DOMINIO):$Puerto" | Set-Content $conf

    $SSL_DIR = "C:/ssl/apache"
    if ($SSL -eq "s") {
        fn_info "Preparando SSL para Apache..."
        fn_generar_certificado_ssl "apache"

        if ((Test-Path "$SSL_DIR/server.crt") -and (Test-Path "$SSL_DIR/server.key")) {
            $sslBlock = @"

LoadModule ssl_module modules/mod_ssl.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
Include conf/extra/httpd-ssl.conf

<VirtualHost *:$Puerto>
    ServerName $script:DOMINIO
    DocumentRoot "C:/Apache24/htdocs"
    SSLEngine on
    SSLCertificateFile "$SSL_DIR/server.crt"
    SSLCertificateKeyFile "$SSL_DIR/server.key"
</VirtualHost>
"@

            Add-Content $conf $sslBlock
        }
        else {
            fn_err "No se encontraron los archivos del certificado SSL. Apache seguira sin SSL."
        }
    }

    if (-not (Test-Path "C:\Apache24\htdocs")) {
        New-Item -Path "C:\Apache24\htdocs" -ItemType Directory -Force | Out-Null
    }

    $HTML = @"
<!DOCTYPE html>
<html>
<body style="background:#1a1a2e;color:white;text-align:center;padding-top:100px;font-family:sans-serif;">
    <h1 style="color:#e94560;">Apache Windows</h1>
    <p>Servidor activo en puerto $Puerto</p>
    <p>Dominio: $script:DOMINIO | SSL: $SSL</p>
    <p>Instalado desde $Origen</p>
</body>
</html>
"@
    Set-Content "C:\Apache24\htdocs\index.html" $HTML -Force

    if (-not (Test-Path "C:\Apache24\bin\httpd.exe")) {
        fn_err "No existe C:\Apache24\bin\httpd.exe. La instalacion de Apache quedo incompleta."
        Read-Host "Presiona ENTER para continuar"
        return
    }

    & "C:\Apache24\bin\httpd.exe" -k install -n Apache24 | Out-Null
    Start-Service Apache24 -ErrorAction SilentlyContinue

    if (-not (Get-NetFirewallRule -DisplayName "Practica7 Apache $Puerto" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Practica7 Apache $Puerto" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Puerto | Out-Null
    }

    Start-Sleep -Seconds 2

    $svc = Get-Service Apache24 -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        fn_ok "Apache levantado correctamente en el puerto $Puerto."
    } else {
        fn_err "Apache no inicio correctamente."
    }
}

function fn_nginx_install {
    param($Origen, $Puerto, $SSL)
    fn_info "Limpiando procesos de Nginx anteriores..."
    Stop-Service Nginx -Force -ErrorAction SilentlyContinue
    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force

    $destZip = "$env:TEMP\nginx.zip"
    if ($Origen -eq "ftp") {
        fn_info "Descargando desde FTP 127.0.0.1..."
        try { Invoke-WebRequest "ftp://localhost/pub/windows/nginx/nginx.zip" -OutFile $destZip } catch { fn_err "No hay Nginx en FTP." }
    } else {
        fn_info "Descargando de internet WEB..."
        Invoke-WebRequest "https://nginx.org/download/nginx-1.26.2.zip" -OutFile $destZip
    }

    fn_info "Descomprimiendo en C:\nginx..."
    Remove-Item -Recurse -Force "C:\nginx" -ErrorAction SilentlyContinue
    Expand-Archive $destZip -DestinationPath "C:\" -Force
    Rename-Item "C:\nginx-1.26.2" "nginx" -ErrorAction SilentlyContinue

    $conf = "C:\nginx\conf\nginx.conf"
    
    $SSL_ON = ""
    $SSL_CERTS = ""
    if ($SSL -eq "s") {
        fn_generar_certificado_ssl "nginx"
        $SSL_DIR = "C:/ssl/nginx"
        $SSL_ON = "ssl"
        $SSL_CERTS = @"
        ssl_certificate     $SSL_DIR/server.crt;
        ssl_certificate_key $SSL_DIR/server.key;
"@
    }

    $c = @"
events { worker_connections 1024; }
http {
    include mime.types;
    server {
        listen $Puerto $SSL_ON;
        server_name $script:DOMINIO;
        $SSL_CERTS
        root html;
        index index.html;
    }
}
"@
    Set-Content $conf $c -Force

    $HTML = @"
<!DOCTYPE html>
<html>
<body style="background:#1a1a2e;color:white;text-align:center;padding-top:100px;font-family:sans-serif;">
    <h1 style="color:#e94560;">Nginx Windows</h1>
    <p>Servidor activo en puerto $Puerto</p>
    <p>Dominio: $script:DOMINIO | SSL: $SSL</p>
    <p>Instalado desde $Origen</p>
</body>
</html>
"@
    Set-Content "C:\nginx\html\index.html" $HTML -Force

    Start-Process "C:\nginx\nginx.exe" -WorkingDirectory "C:\nginx" -WindowStyle Hidden
    fn_ok "Nginx operando silenciosamente en puerto $Puerto."
}

function fn_estado_servicios {
    echo ""
    Write-Host "=== ESTADO DE SERVICIOS WEB/FTP ===" -ForegroundColor Cyan
    Get-Service -Name W3SVC, Apache24, Nginx, ftpsvc -ErrorAction SilentlyContinue | Format-Table -AutoSize
    Read-Host "Presiona ENTER para continuar"
}

function fn_mostrar_resumen {
    echo ""
    Write-Host "=== ESCANER DE SERVICIOS EN TIEMPO REAL (WINDOWS) ===" -ForegroundColor Cyan
    Write-Host "Buscando servicios web y calculando origen FTP/WEB..." -ForegroundColor Yellow
    echo ""
    $found = $false
    
    $connections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object -Unique -Property LocalPort, OwningProcess
    
    foreach ($conn in $connections) {
        $puerto = $conn.LocalPort
        if ($puerto -eq 21) { continue } # ignora FTP
        if ($puerto -gt 1000 -or $puerto -eq 80 -or $puerto -eq 443) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($null -eq $proc) { continue }

            $pname = $proc.Name.ToLower()

            if ($pname -match "httpd") {
                $found = $true
                $html = Get-Content "C:\Apache24\htdocs\index.html" -ErrorAction SilentlyContinue
                if ($html -match "desde ftp") {
                    Write-Host " 🌐 [Apache] Puerto: $puerto | Origen: FTP (Privado)" -ForegroundColor Magenta
                } else {
                    Write-Host " 🌐 [Apache] Puerto: $puerto | Origen: WEB (Internet)" -ForegroundColor Green
                }
            } elseif ($pname -match "nginx") {
                $found = $true
                $html = Get-Content "C:\nginx\html\index.html" -ErrorAction SilentlyContinue
                if ($html -match "desde ftp") {
                    Write-Host " 🚀 [Nginx]  Puerto: $puerto | Origen: FTP (Privado)" -ForegroundColor Magenta
                } else {
                    Write-Host " 🚀 [Nginx]  Puerto: $puerto | Origen: WEB (Internet)" -ForegroundColor Green
                }
            }
        }
    }
    
    # Revisar bindings explicitos de IIS si esta instalado
    if (Get-Module -ListAvailable WebAdministration) {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $iisBindings = Get-WebBinding -Name "Default Web Site" -ErrorAction SilentlyContinue
        if ($iisBindings) {
            $found = $true
            foreach ($b in $iisBindings) {
                $puertoIIS = ($b.bindingInformation -split ':')[1]
                $html = Get-Content "C:\inetpub\wwwroot\index.html" -ErrorAction SilentlyContinue
                if ($html -match "desde ftp") {
                    Write-Host " 💠 [IIS]    Puerto: $puertoIIS | Origen: FTP (Privado)" -ForegroundColor Magenta
                } else {
                    Write-Host " 💠 [IIS]    Puerto: $puertoIIS | Origen: WEB (Internet)" -ForegroundColor Green
                }
            }
        }
    }

    if (-not $found) {
        Write-Host " No hay ningun servicio web corriendo." -ForegroundColor Yellow
    }
    echo ""
    Read-Host "Presiona ENTER para continuar"
}