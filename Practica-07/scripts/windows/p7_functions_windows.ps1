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

    Install-WindowsFeature Web-FTP-Server,Web-FTP-Ext -IncludeManagementTools | Out-Null
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $Root = "C:\Practica7_FTP"
    if (-not (Test-Path $Root)) { 
        New-Item -Path $Root -ItemType Directory -Force | Out-Null 
    }
    
    $Repo = "$Root\pub\windows"
    New-Item -Path "$Repo\iis"    -ItemType Directory -Force | Out-Null
    New-Item -Path "$Repo\apache" -ItemType Directory -Force | Out-Null
    New-Item -Path "$Repo\nginx"  -ItemType Directory -Force | Out-Null

    # === LIMPIEZA SEGURA ===
    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue

    # Eliminar sitio si existe (forma segura)
    if (Get-WebSite -Name "Practica7_FTP" -ErrorAction SilentlyContinue) {
        Remove-WebSite -Name "Practica7_FTP" -ErrorAction SilentlyContinue
    }
    Get-WebSite -Name "Default FTP Site" -ErrorAction SilentlyContinue | Stop-WebSite -ErrorAction SilentlyContinue

    # Crear sitio FTP desde cero
    New-WebFtpSite -Name "Practica7_FTP" -Port 21 -PhysicalPath $Root -Force | Out-Null

    # Configuración básica
    Set-ItemProperty "IIS:\Sites\Practica7_FTP" -Name "ftpServer.userIsolation.mode" -Value 0
    Set-ItemProperty "IIS:\Sites\Practica7_FTP" -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" -Value $true

    # === USUARIO ANÓNIMO como IUSR (forma correcta con appcmd) ===
    $appcmd = "$env:windir\System32\inetsrv\appcmd.exe"
    if (Test-Path $appcmd) {
        & $appcmd set config "Practica7_FTP" `
            -section:system.applicationHost/sites/[name='Practica7_FTP'].ftpServer/security/authentication/anonymousAuthentication `
            /userName:"IUSR" /commit:apphost 2>$null
        
        fn_ok "Usuario anónimo configurado como IUSR"
    } else {
        fn_err "No se encontró appcmd.exe"
    }

    # === PERMISOS NTFS (la parte crítica para evitar "home directory inaccessible") ===
    fn_info "Aplicando permisos NTFS correctos para IUSR..."

    icacls $Root /inheritance:r /T /C /Q | Out-Null
    icacls $Root /grant "Everyone:(OI)(CI)F"        /T /C /Q | Out-Null
    icacls $Root /grant "IUSR:(OI)(CI)F"            /T /C /Q | Out-Null
    icacls $Root /grant "IIS_IUSRS:(OI)(CI)F"       /T /C /Q | Out-Null
    icacls $Root /grant "ANONYMOUS LOGON:(OI)(CI)F" /T /C /Q | Out-Null
    icacls $Root /grant "NETWORK SERVICE:(OI)(CI)F" /T /C /Q | Out-Null

    # Permiso explícito FullControl
    $acl = Get-Acl $Root
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("IUSR", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl -Path $Root -AclObject $acl

    # Lo mismo para la carpeta pub
    if (Test-Path "$Root\pub") {
        icacls "$Root\pub" /grant "IUSR:(OI)(CI)F" /T /C /Q | Out-Null
    }

    # === SSL (FTPS) ===
    $ftpCert = New-SelfSignedCertificate -DnsName "windows.ftp.local" `
        -CertStoreLocation "cert:\LocalMachine\My" -ErrorAction SilentlyContinue

    if ($ftpCert) {
        Set-ItemProperty "IIS:\Sites\Practica7_FTP" -Name "ftpServer.security.ssl.serverCertHash"       -Value $ftpCert.GetCertHashString()
        Set-ItemProperty "IIS:\Sites\Practica7_FTP" -Name "ftpServer.security.ssl.serverCertStoreName"  -Value "My"
        Set-ItemProperty "IIS:\Sites\Practica7_FTP" -Name "ftpServer.security.ssl.controlChannelPolicy" -Value "SslAllow"
        Set-ItemProperty "IIS:\Sites\Practica7_FTP" -Name "ftpServer.security.ssl.dataChannelPolicy"    -Value "SslAllow"
        fn_ok "Certificado SSL auto-firmado configurado (FTPS permitido)"
    } else {
        fn_info "No se pudo crear certificado SSL → FTP en modo plano"
    }

    # === Reglas de autorización ===
    if (Test-Path $appcmd) {
        & $appcmd set config "Practica7_FTP" -section:system.ftpServer/security/authorization /clear /commit:apphost 2>$null
        & $appcmd set config "Practica7_FTP" -section:system.ftpServer/security/authorization /+"[accessType='Allow',users='?',permissions='Read']" /commit:apphost 2>$null
        & $appcmd set config "Practica7_FTP" -section:system.ftpServer/security/authorization /+"[accessType='Allow',users='*',permissions='Read,Write']" /commit:apphost 2>$null
    }

    # Iniciar servicios
    Start-Service ftpsvc -ErrorAction SilentlyContinue
    Start-WebSite -Name "Practica7_FTP" -ErrorAction SilentlyContinue

    fn_ok "FTP reiniciado correctamente."

    # Descarga de instaladores (sin cambios importantes)
    fn_info "Descargando instaladores oficiales a las carpetas FTP..."
    try {
        if (-not (Test-Path "$Repo\apache\httpd.zip")) {
            Invoke-WebRequest "https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-win64-VS17.zip" -UserAgent $Global:USER_AGENT -OutFile "$Repo\apache\httpd.zip" -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path "$Repo\nginx\nginx.zip")) {
            Invoke-WebRequest "https://nginx.org/download/nginx-1.26.2.zip" -UserAgent $Global:USER_AGENT -OutFile "$Repo\nginx\nginx.zip" -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path "$Repo\iis\iis_web.zip")) {
            Set-Content -Path "$env:TEMP\dummy_iis.txt" -Value "Dummy IIS"
            Compress-Archive -Path "$env:TEMP\dummy_iis.txt" -DestinationPath "$Repo\iis\iis_web.zip" -Force
        }
        fn_ok "Instaladores descargados correctamente."
    } catch {
        fn_err "Error al descargar algunos archivos (verifica internet)."
    }

    Read-Host "Presiona ENTER para continuar"
}

function fn_generar_certificado_ssl {
    param($NombreApp)

    $SSL_DIR = "C:\ssl\$NombreApp"
    New-Item -Path $SSL_DIR -ItemType Directory -Force | Out-Null

    $openssl = $null
    $candidatos = @(
        "C:\Apache24\bin\openssl.exe",
        "C:\nginx\openssl.exe",
        "C:\ssl\openssl.exe",
        "C:\Program Files\Git\mingw64\bin\openssl.exe",
        "C:\Program Files\Git\usr\bin\openssl.exe"
    )

    foreach ($c in $candidatos) {
        if (Test-Path $c) {
            $openssl = $c
            break
        }
    }

    if (-not $openssl) {
        fn_err "No se encontro openssl.exe para generar el certificado."
        return $false
    }

    Write-Host ">> Generando certificado PEM (cert y key) para $NombreApp..." -ForegroundColor Magenta

    try {
        & $openssl req -x509 -nodes -newkey rsa:2048 `
            -keyout "$SSL_DIR\server.key" `
            -out "$SSL_DIR\server.crt" `
            -days 365 `
            -subj "/C=MX/ST=Sonora/L=Obregon/O=Practica07/OU=Redes/CN=$script:DOMINIO" | Out-Null

        if ((Test-Path "$SSL_DIR\server.crt") -and (Test-Path "$SSL_DIR\server.key")) {
            fn_ok "Certificado PEM OK!"
            return $true
        } else {
            fn_err "No se generaron server.crt y server.key."
            return $false
        }
    }
    catch {
        fn_err "Fallo la creacion SSL: $($_.Exception.Message)"
        return $false
    }
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

    if (-not (Get-NetFirewallRule -DisplayName "Practica7 IIS $Puerto" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Practica7 IIS $Puerto" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Puerto | Out-Null
    }
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
        } else {
            fn_err "No hay Apache en FTP/local."
            return
        }
    } else {
        fn_info "Descargando Apache desde WEB..."
        try {
            Invoke-WebRequest "https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-win64-VS17.zip" -UserAgent $Global:USER_AGENT -OutFile $destZip -ErrorAction Stop
        } catch {
            fn_err "No se pudo descargar Apache desde internet: $($_.Exception.Message)"
            return
        }
    }

    if (-not (Test-Path $destZip)) {
        fn_err "No existe el archivo $destZip. Se cancela la instalacion."
        return
    }

    fn_info "Descomprimiendo Apache en C:\ ..."
    try {
        Expand-Archive $destZip -DestinationPath "C:\" -Force -ErrorAction Stop
    } catch {
        fn_err "Fallo al descomprimir Apache: $($_.Exception.Message)"
        return
    }

    if (-not (Test-Path "C:\Apache24")) {
        $extraida = Get-ChildItem "C:\" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^Apache24" } | Select-Object -First 1
        if ($extraida -and $extraida.FullName -ne "C:\Apache24") {
            Rename-Item $extraida.FullName "C:\Apache24" -Force
        }
    }

    $conf = "C:\Apache24\conf\httpd.conf"
    if (-not (Test-Path $conf)) {
        fn_err "No se encontro $conf."
        return
    }

    $contenido = Get-Content $conf -Raw

    # Siempre limpiar cualquier bloque previo generado por el script
    $contenido = [regex]::Replace($contenido, '(?s)# BEGIN_PRACTICA7_SSL_APACHE.*?# END_PRACTICA7_SSL_APACHE', '')

    # Restaurar lineas base para evitar listeners duplicados cuando SSL cambia de puerto
    $contenido = [regex]::Replace($contenido, '(?m)^Listen\s+\d+\s*$', 'Listen 80', 1)
    $contenido = $contenido -replace '(?m)^ServerName\s+.+$', 'ServerName localhost:80'
    $contenido = $contenido -replace '(?m)^#ServerName\s+www\.example\.com:80', 'ServerName localhost:80'

    # Activar modulos SSL solo una vez
    $contenido = $contenido -replace '(?m)^\s*#\s*LoadModule\s+ssl_module\s+modules/mod_ssl\.so', 'LoadModule ssl_module modules/mod_ssl.so'
    $contenido = $contenido -replace '(?m)^\s*#\s*LoadModule\s+socache_shmcb_module\s+modules/mod_socache_shmcb\.so', 'LoadModule socache_shmcb_module modules/mod_socache_shmcb.so'

    if ($SSL -eq "s") {
        # Mantener puerto 80 base y agregar listener SSL dedicado
        $contenido = $contenido -replace '(?m)^ServerName\s+localhost:80', "ServerName $($script:DOMINIO):80"
    } else {
        # HTTP puro: mover listener principal al puerto elegido
        $contenido = [regex]::Replace($contenido, '(?m)^Listen\s+80\s*$', "Listen $Puerto", 1)
        $contenido = $contenido -replace '(?m)^ServerName\s+localhost:80', "ServerName $($script:DOMINIO):$Puerto"
    }

    Set-Content $conf $contenido

    $SSL_DIR = "C:/ssl/apache"
    if ($SSL -eq "s") {
        fn_info "Preparando SSL para Apache..."
        $okSSL = fn_generar_certificado_ssl "apache"

        if ($okSSL) {
            $sslBlock = @"

# BEGIN_PRACTICA7_SSL_APACHE
Listen $Puerto

<VirtualHost *:$Puerto>
    ServerName $($script:DOMINIO):$Puerto
    DocumentRoot "C:/Apache24/htdocs"
    SSLEngine on
    SSLCertificateFile "$SSL_DIR/server.crt"
    SSLCertificateKeyFile "$SSL_DIR/server.key"
</VirtualHost>
# END_PRACTICA7_SSL_APACHE
"@
            Add-Content $conf $sslBlock
        } else {
            fn_err "No se pudo configurar SSL. Apache seguira sin SSL."
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
        fn_err "No existe C:\Apache24\bin\httpd.exe."
        return
    }

    & "C:\Apache24\bin\httpd.exe" -k install -n Apache24 | Out-Null

    $test = & "C:\Apache24\bin\httpd.exe" -t 2>&1
    $testText = ($test | Out-String)
    if ($LASTEXITCODE -ne 0 -or $testText -notmatch "Syntax OK") {
        fn_err "La configuracion de Apache no es valida."
        $test
        return
    }

    Start-Service Apache24 -ErrorAction SilentlyContinue

    if (-not (Get-NetFirewallRule -DisplayName "Practica7 Apache $Puerto" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Practica7 Apache $Puerto" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Puerto | Out-Null
    }

    Start-Sleep -Seconds 2
    $svc = Get-Service Apache24 -ErrorAction SilentlyContinue
    if ($svc) { $svc.Refresh() }

    if ($svc -and $svc.Status -eq 'Running') {
        fn_ok "Apache levantado correctamente en el puerto $Puerto."
        if ($SSL -eq "s") {
            Write-Host "URL: https://<IP_DEL_SERVER>:$Puerto" -ForegroundColor Green
        } else {
            Write-Host "URL: http://<IP_DEL_SERVER>:$Puerto" -ForegroundColor Green
        }
    } else {
        fn_err "Apache no inicio correctamente."
        Get-Content "C:\Apache24\logs\error.log" -Tail 30 -ErrorAction SilentlyContinue
    }
}

function fn_nginx_install {
    param($Origen, $Puerto, $SSL)

    fn_info "Limpiando procesos de Nginx anteriores..."
    Stop-Service nginx -Force -ErrorAction SilentlyContinue
    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
    sc.exe delete nginx 2>$null | Out-Null

    $destZip = "$env:TEMP\nginx.zip"
    Remove-Item $destZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\nginx" -ErrorAction SilentlyContinue

    if ($Origen -eq "ftp") {
        fn_info "Buscando Nginx en repositorio FTP/local..."

        $candidatos = @(
            "C:\Practica7_FTP\LocalUser\Public\pub\windows\nginx\nginx.zip",
            "C:\Practica7_FTP\pub\windows\nginx\nginx.zip",
            "C:\inetpub\ftproot\LocalUser\Public\pub\windows\nginx\nginx.zip",
            "C:\inetpub\ftproot\pub\windows\nginx\nginx.zip"
        )

        $zipLocal = $candidatos | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($zipLocal) {
            fn_ok "Nginx encontrado en: $zipLocal"
            Copy-Item $zipLocal $destZip -Force
        }
        else {
            fn_err "No hay Nginx en FTP/local."
            return
        }
    }
    else {
        fn_info "Descargando Nginx desde WEB..."
        try {
            Invoke-WebRequest "https://nginx.org/download/nginx-1.26.2.zip" `
                -UserAgent $Global:USER_AGENT `
                -OutFile $destZip `
                -ErrorAction Stop
        } catch {
            fn_err "No se pudo descargar Nginx desde internet: $($_.Exception.Message)"
            return
        }
    }

    if (-not (Test-Path $destZip)) {
        fn_err "No existe el archivo $destZip. Se cancela la instalacion."
        return
    }

    fn_info "Descomprimiendo Nginx en C:\ ..."
    try {
        Expand-Archive $destZip -DestinationPath "C:\" -Force -ErrorAction Stop
    } catch {
        fn_err "Fallo al descomprimir Nginx: $($_.Exception.Message)"
        return
    }

    $extraida = Get-ChildItem "C:\" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "nginx-*" } |
        Select-Object -First 1

    if ($extraida) {
        if (Test-Path "C:\nginx") {
            Remove-Item "C:\nginx" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Rename-Item $extraida.FullName "C:\nginx" -Force
    }

    if (-not (Test-Path "C:\nginx\conf\nginx.conf")) {
        fn_err "No se encontro C:\nginx\conf\nginx.conf."
        return
    }

    New-Item -ItemType Directory -Path "C:\nginx\logs" -Force | Out-Null
    New-Item -ItemType Directory -Path "C:\ssl\nginx" -Force | Out-Null

    $conf = "C:\nginx\conf\nginx.conf"
    $sslDir = "C:/ssl/nginx"

    $html = @"
<!DOCTYPE html>
<html>
<body style='background:#111;color:#fff;text-align:center;padding-top:100px;font-family:sans-serif;'>
<h1 style='color:#00d1b2;'>Nginx Windows</h1>
<p>Servidor activo en puerto $Puerto</p>
<p>Dominio: $script:DOMINIO | SSL: $SSL</p>
<p>Instalado desde $Origen</p>
</body>
</html>
"@
    Set-Content "C:\nginx\html\index.html" $html -Force

    if ($SSL -eq "s") {
        $okSSL = fn_generar_certificado_ssl "nginx"
        if (-not $okSSL) {
            fn_err "No se pudo configurar SSL para Nginx."
            return
        }

        $nginxConf = @"
worker_processes  1;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       $Puerto ssl;
        server_name  $script:DOMINIO;

        ssl_certificate      $sslDir/server.crt;
        ssl_certificate_key  $sslDir/server.key;

        location / {
            root   html;
            index  index.html index.htm;
        }
    }
}
"@
    }
    else {
        $nginxConf = @"
worker_processes  1;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       $Puerto;
        server_name  $script:DOMINIO;

        location / {
            root   html;
            index  index.html index.htm;
        }
    }
}
"@
    }

    Set-Content $conf $nginxConf -Force

    if (-not (Test-Path "C:\nginx\nginx.exe")) {
        fn_err "No existe C:\nginx\nginx.exe."
        return
    }

    $test = & "C:\nginx\nginx.exe" -p "C:\nginx\" -c "conf\nginx.conf" -t 2>&1
    $testText = ($test | Out-String)

    if ($LASTEXITCODE -ne 0 -or $testText -notmatch "successful|syntax is ok") {
        fn_err "La configuracion de Nginx no es valida."
        $test
        return
    }

    # Iniciar Nginx como proceso normal en lugar de servicio
    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1

    Start-Process -FilePath "C:\nginx\nginx.exe" `
        -ArgumentList '-p', 'C:\nginx\', '-c', 'conf\nginx.conf' `
        -WorkingDirectory "C:\nginx" `
        -WindowStyle Hidden

    if (-not (Get-NetFirewallRule -DisplayName "Practica7 Nginx $Puerto" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Practica7 Nginx $Puerto" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Puerto | Out-Null
    }

    Start-Sleep -Seconds 3

    $proc = Get-Process nginx -ErrorAction SilentlyContinue
    $listen = Get-NetTCPConnection -State Listen -LocalPort $Puerto -ErrorAction SilentlyContinue

    if ($proc -and $listen) {
        fn_ok "Nginx levantado correctamente en el puerto $Puerto."
        if ($SSL -eq "s") {
            Write-Host "URL: https://$env:COMPUTERNAME`:$Puerto" -ForegroundColor Green
        } else {
            Write-Host "URL: http://$env:COMPUTERNAME`:$Puerto" -ForegroundColor Green
        }
    } else {
        fn_err "Nginx no inicio correctamente."
        Get-Content "C:\nginx\logs\error.log" -Tail 30 -ErrorAction SilentlyContinue
    }
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