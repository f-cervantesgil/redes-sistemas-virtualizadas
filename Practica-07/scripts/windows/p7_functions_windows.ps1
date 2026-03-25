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
    fn_info "Activando rol de FTP Server en IIS..."
    Install-WindowsFeature Web-FTP-Server,Web-FTP-Ext -IncludeManagementTools | Out-Null
    Import-Module WebAdministration 

    $Root = "C:\inetpub\ftproot\pub\windows"
    New-Item -Path "$Root\iis" -ItemType Directory -Force | Out-Null
    New-Item -Path "$Root\apache" -ItemType Directory -Force | Out-Null
    New-Item -Path "$Root\nginx" -ItemType Directory -Force | Out-Null

    if (-not (Get-WebSite -Name "Practica7_FTP" -ErrorAction SilentlyContinue)) {
        New-WebFtpSite -Name "Practica7_FTP" -Port 21 -PhysicalPath "C:\inetpub\ftproot" -Force
        Set-ItemProperty "IIS:\Sites\Practica7_FTP" -Name "ftpServer.security.authentication.anonymousAuthentication.enabled" -Value $true
    }

    # ACL Permissions for Anonymous
    $acl = Get-Acl "C:\inetpub\ftproot"
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("IUSR", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl "C:\inetpub\ftproot" $acl
    fn_ok "Estructura Base C:\inetpub\ftproot FTP Anonymous (Permisos RW) configurada."

    fn_info "Descargando instaladores oficiales a las carpetas FTP desde Internet (esto puede tardar)..."
    try {
        if (-not (Test-Path "$Root\apache\httpd.zip")) {
            Write-Host ">> Descargando Apache HTTPD Windows (10MB)..." -ForegroundColor Yellow
            Invoke-WebRequest "https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-win64-VS17.zip" -UserAgent $Global:USER_AGENT -OutFile "$Root\apache\httpd.zip"
        }
        if (-not (Test-Path "$Root\nginx\nginx.zip")) {
            Write-Host ">> Descargando Nginx Windows (1.5MB)..." -ForegroundColor Yellow
            Invoke-WebRequest "https://nginx.org/download/nginx-1.26.2.zip" -UserAgent $Global:USER_AGENT -OutFile "$Root\nginx\nginx.zip"
        }
        if (-not (Test-Path "$Root\iis\iis_web.zip")) {
            Write-Host ">> Descargando IIS Pack (Mock)..." -ForegroundColor Yellow
            Set-Content -Path "C:\Users\Public\dummy_iis.txt" -Value "IIS Modulo descargado de FTP local."
            Compress-Archive -Path "C:\Users\Public\dummy_iis.txt" -DestinationPath "$Root\iis\iis_web.zip" -Force
        }
        fn_ok "Instaladores web guardados en el Repositorio FTP exitosamente."
    } catch {
        fn_err "Error descargando binarios. Verifica conexión a Internet."
    }
    Read-Host "Presiona ENTER para continuar"
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
            # Se usa una configuración por defecto silenciosa
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
    Write-Host "¿Origen? [1] WEB (Internet)  [2] FTP (Local)" -ForegroundColor Yellow
    $O = Read-Host "Elige"
    $Origen = if ($O -eq "1") { "web" } elseif ($O -eq "2") { "ftp" } else { return }

    Write-Host "Ingresa puerto (ej: 8080, 5051):" -ForegroundColor Yellow
    $Puerto = Read-Host "Puerto"

    Write-Host "¿Deseas instalar con certificado SSL (HTTPS)? (s/n)" -ForegroundColor Yellow
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

    $destZip = "$env:TEMP\apache.zip"
    if ($Origen -eq "ftp") {
        fn_info "Descargando desde FTP 127.0.0.1..."
        try { Invoke-WebRequest "ftp://localhost/pub/windows/apache/httpd.zip" -OutFile $destZip } catch { fn_err "No hay Apache en FTP." }
    } else {
        fn_info "Descargando desde WEB internet..."
        Invoke-WebRequest "https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-win64-VS17.zip" -UserAgent $Global:USER_AGENT -OutFile $destZip
    }

    fn_info "Descomprimiendo Apache en C:\Apache24..."
    Remove-Item -Recurse -Force "C:\Apache24" -ErrorAction SilentlyContinue
    Expand-Archive $destZip -DestinationPath "C:\" -Force

    $conf = "C:\Apache24\conf\httpd.conf"
    
    (Get-Content $conf) -replace "^Listen \d+", "Listen $Puerto" | Set-Content $conf
    (Get-Content $conf) -replace "^ServerName localhost:80", "ServerName $($script:DOMINIO):$Puerto" | Set-Content $conf

    $SSL_DIR = "C:/ssl/apache"
    if ($SSL -eq "s") {
        fn_generar_certificado_ssl "apache"
        $sslBlock = @"
LoadModule ssl_module modules/mod_ssl.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so

<VirtualHost *:$Puerto>
    ServerName $script:DOMINIO
    DocumentRoot "C:/Apache24/htdocs"
    SSLEngine on
    SSLCertificateFile    "$SSL_DIR/server.crt"
    SSLCertificateKeyFile "$SSL_DIR/server.key"
</VirtualHost>
"@
        Add-Content $conf $sslBlock
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

    C:\Apache24\bin\httpd.exe -k install -n Apache24 > $null 2>&1
    Start-Service Apache24
    fn_ok "Apache levantado en el puerto $Puerto."
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
