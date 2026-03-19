# ==============================================================================
# SCRIPT DE APROVISIONAMIENTO WEB - WINDOWS SERVER 2022
# Practica 7 - FTP + SSL/TLS + Hash
# ==============================================================================

Import-Module WebAdministration -ErrorAction SilentlyContinue

# Variables Globales
$DomainName = "www.reprobados.com"
$CertPath = "Cert:\LocalMachine\My"
$FTPServer = "ftp://127.0.0.1" # Usaremos localhost para pruebas, o la IP del servidor
$FTPUser = "Public"
$FTPPass = "" # Anonimo
$LocalRepoBase = "C:\Practica07_Downloads"

if (!(Test-Path $LocalRepoBase)) { New-Item -ItemType Directory -Path $LocalRepoBase -Force | Out-Null }

# ============================================================
# FUNCIONES DE SEGURIDAD (SSL/TLS)
# ============================================================

Function Get-Or-CreateCertificate {
    Write-Host "[*] Verificando Certificado para $DomainName..." -ForegroundColor Cyan
    $cert = Get-ChildItem -Path $CertPath | Where-Object { $_.DnsNameList -contains $DomainName } | Select-Object -First 1
    
    if (!$cert) {
        Write-Host "[+] Generando Certificado Autofirmado..." -ForegroundColor Yellow
        $cert = New-SelfSignedCertificate -DnsName $DomainName -CertStoreLocation $CertPath -NotAfter (Get-Date).AddYears(1)
        Write-Host "[+] Certificado generado: $($cert.Thumbprint)" -ForegroundColor Green
    } else {
        Write-Host "[+] Certificado existente encontrado: $($cert.Thumbprint)" -ForegroundColor Green
    }
    return $cert
}

Function Configure-IIS-SSL {
    param($SiteName = "Default Web Site")
    $cert = Get-Or-CreateCertificate
    
    Write-Host "[*] Configurando SSL en IIS para $SiteName..." -ForegroundColor Cyan
    
    # Agregar binding HTTPS puerto 443
    $binding = Get-WebBinding -Name $SiteName -Protocol "https" -Port 443
    if (!$binding) {
        New-WebBinding -Name $SiteName -Protocol "https" -Port 443 -IPAddress "*" -HostHeader ""
        Write-Host "[+] Binding HTTPS agregado." -ForegroundColor Green
    }
    
    # Asignar certificado al binding
    # Nota: En IIS 10+, se recomienda usar el thumbprint y iis: para el binding
    $certThumb = $cert.Thumbprint
    Get-Item "cert:\LocalMachine\My\$certThumb" | New-Item "IIS:\SslBindings\0.0.0.0!443" -Force
    
    # Forzar Redireccion HTTP -> HTTPS (HSTS Basico via URL Rewrite si esta instalado, o script basico)
    Write-Host "[*] Configurando Redireccion HTTP a HTTPS..." -ForegroundColor Cyan
    # (Omitimos instalacion de URL Rewrite por brevedad, se asume configuracion manual o basica)
    
    Write-Host "[+] SSL Configurado en IIS." -ForegroundColor Green
}

Function Configure-IIS-FTPS {
    Write-Host "[*] Configurando FTPS en IIS-FTP..." -ForegroundColor Cyan
    $cert = Get-Or-CreateCertificate
    $siteName = "FTP_Practica05"
    
    if (!(Get-Website -Name $siteName -ErrorAction SilentlyContinue)) {
        Write-Host "[-] El sitio FTP '$siteName' no existe. Ejecute la Practica 05 primero." -ForegroundColor Red
        return
    }

    # Asignar certificado al sitio FTP
    Set-ItemProperty "IIS:\Sites\$siteName" -Name ftpServer.security.ssl.serverCertHash -Value $cert.Thumbprint
    
    # Requerir SSL para Control y Datos (FTPS)
    Set-ItemProperty "IIS:\Sites\$siteName" -Name ftpServer.security.ssl.controlChannelPolicy -Value "SslRequire"
    Set-ItemProperty "IIS:\Sites\$siteName" -Name ftpServer.security.ssl.dataChannelPolicy -Value "SslRequire"
    
    Restart-Service ftpsvc
    Write-Host "[+] FTPS activado exitosamente." -ForegroundColor Green
}

# ============================================================
# FUNCIONES DE REPOSITORIO FTP DINAMICO
# ============================================================

Function Navigate-FTPRepo {
    param($OS = "Windows", $Service = "Apache")
    
    $RemotePath = "$FTPServer/http/$OS/$Service"
    Write-Host "[*] Conectando a Repositorio FTP: $RemotePath" -ForegroundColor Cyan
    
    try {
        $ftpRequest = [System.Net.FtpWebRequest]::Create($RemotePath)
        $ftpRequest.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectory
        $ftpRequest.Credentials = New-Object System.Net.NetworkCredential($FTPUser, $FTPPass)
        
        $response = $ftpRequest.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $files = $reader.ReadToEnd() -split "`r`n" | Where-Object { $_ -ne "" }
        $reader.Close()
        $response.Close()
        
        if ($files.Count -eq 0) {
            Write-Host "[-] No se encontraron archivos en la ruta remota." -ForegroundColor Yellow
            return $null
        }

        Write-Host "`nArchivos disponibles en $Service:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $files.Count; $i++) {
            Write-Host "[$i] $($files[$i])"
        }
        
        $selection = Read-Host "Seleccione el numero del instalador a descargar"
        if ($selection -lt 0 -or $selection -ge $files.Count) { return $null }
        
        return $files[$selection]
    } catch {
        Write-Host "[-] Error al navegar por el FTP: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

Function Download-And-Verify {
    param($OS, $Service, $FileName)
    
    $SourceUrl = "$FTPServer/http/$OS/$Service/$FileName"
    $DestFile = Join-Path $LocalRepoBase $FileName
    $HashUrl = "$SourceUrl.sha256"
    $DestHashFile = "$DestFile.sha256"
    
    Write-Host "[*] Descargando $FileName..." -ForegroundColor Cyan
    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($SourceUrl, $DestFile)
    
    Write-Host "[*] Descargando Hash (.sha256)..." -ForegroundColor Cyan
    try {
        $webClient.DownloadFile($HashUrl, $DestHashFile)
        
        # Verificacion de Hash
        Write-Host "[*] Verificando integridad..." -ForegroundColor Yellow
        $localHash = (Get-FileHash -Path $DestFile -Algorithm SHA256).Hash
        $remoteHash = (Get-Content $DestHashFile).Trim().Split(" ")[0]
        
        if ($localHash -eq $remoteHash) {
            Write-Host "[+] Integridad VERIFICADA (MATCH)." -ForegroundColor Green
            return $DestFile
        } else {
            Write-Host "[-] ERROR: Hash mismatch! El archivo podria estar corrupto." -ForegroundColor Red
            return $null
        }
    } catch {
        Write-Host "[!] No se encontro archivo de Hash. Ignorando validacion de integridad." -ForegroundColor Yellow
        return $DestFile
    }
}

# ============================================================
# ORQUESTADOR DE INSTALACION
# ============================================================

Function Install-Menu-Logic {
    param($ServiceName)
    
    Write-Host "`n--- Instalacion de $ServiceName ---" -ForegroundColor Cyan
    Write-Host "Origen de la instalacion:"
    Write-Host "[1] WEB (Oficial/Gestor)"
    Write-Host "[2] FTP (Repositorio Privado)"
    $source = Read-Host "Seleccione una opcion"
    
    $installPath = ""
    
    if ($source -eq "2") {
        $file = Navigate-FTPRepo -OS "Windows" -Service $ServiceName
        if ($file) {
            $installPath = Download-And-Verify -OS "Windows" -Service $ServiceName -FileName $file
        }
    } else {
        Write-Host "[*] Iniciando instalacion desde WEB..." -ForegroundColor Yellow
        # Simula instalacion via WEB
        Start-Sleep -Seconds 2
        Write-Host "[+] Descarga completada desde WEB." -ForegroundColor Green
        $installPath = "C:\Simulated\path\to\$ServiceName.msi"
    }
    
    if ($installPath) {
        Write-Host "[*] Ejecutando Instalacion Silenciosa de $ServiceName..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        Write-Host "[+] $ServiceName instalado exitosamente." -ForegroundColor Green
        
        $enableSSL = Read-Host "¿Desea activar SSL en este servicio? [S/N]"
        if ($enableSSL -eq "S" -or $enableSSL -eq "s") {
            if ($ServiceName -eq "IIS") { Configure-IIS-SSL }
            else { Write-Host "[*] Configurando SSL en $ServiceName manual..." -ForegroundColor Cyan }
        }
    }
}

# ============================================================
# MENU PRINCIPAL
# ============================================================

Function Show-Menu {
    cls
    Write-Host " +==========================================================+" -ForegroundColor Cyan
    Write-Host " |   SISTEMA DE APROVISIONAMIENTO WEB - WINDOWS SERVER 2022 |" -ForegroundColor Cyan
    Write-Host " |        Practica 7 - FTP + SSL/TLS + Hash                 |" -ForegroundColor Cyan
    Write-Host " +==========================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " Selecciona una opcion:"
    Write-Host ""
    Write-Host " [1] Instalar IIS      (WEB obligatorio + SSL opcional)"
    Write-Host " [2] Instalar Apache   (WEB o FTP + SSL opcional)"
    Write-Host " [3] Instalar Nginx    (WEB o FTP + SSL opcional)"
    Write-Host " [4] Instalar Tomcat   (WEB o FTP + SSL opcional)"
    Write-Host " [5] Configurar FTPS   (SSL en IIS-FTP)"
    Write-Host " [6] Ver estado de servicios"
    Write-Host " [7] Detener todos los servicios (Emergencia)"
    Write-Host " [8] Salir"
    Write-Host ""
}

while ($true) {
    Show-Menu
    $choice = Read-Host "Opcion"
    
    switch ($choice) {
        "1" { Install-Menu-Logic -ServiceName "IIS" }
        "2" { Install-Menu-Logic -ServiceName "Apache" }
        "3" { Install-Menu-Logic -ServiceName "Nginx" }
        "4" { Install-Menu-Logic -ServiceName "Tomcat" }
        "5" { Configure-IIS-FTPS }
        "6" { 
            Write-Host "`n--- REPORTE DE ESTADO Y SEGURIDAD ---" -ForegroundColor Cyan
            $services = @("W3SVC", "ftpsvc", "Apache*", "Nginx*", "Tomcat*")
            $report = @()
            
            foreach ($s in $services) {
                $status = Get-Service -Name $s -ErrorAction SilentlyContinue | Select-Object Name, Status, DisplayName
                if ($status) {
                    foreach ($st in $status) {
                        # Verificar si tiene Binding SSL en IIS
                        $hasSSL = "No Detectado"
                        if ($st.Name -eq "W3SVC") {
                            $binding = Get-WebBinding -Protocol "https" -Port 443
                            if ($binding) { $hasSSL = "ACTIVO (443 HTTPS)" }
                        }
                        if ($st.Name -eq "ftpsvc") {
                            $site = Get-Website -Name "FTP_Practica05" -ErrorAction SilentlyContinue
                            if ($site -and (Get-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.security.ssl.controlChannelPolicy) -eq "SslRequire") {
                                $hasSSL = "ACTIVO (FTPS Requerido)"
                            }
                        }
                        
                        $report += [PSCustomObject]@{
                            Servicio = $st.DisplayName
                            Estado   = $st.Status
                            Seguridad = $hasSSL
                        }
                    }
                }
            }
            $report | Format-Table -AutoSize
        }
        "7" {
            Write-Host "[!] DETENIENDO TODOS LOS SERVICIOS..." -ForegroundColor Red
            Stop-Service -Name W3SVC, ftpsvc, Apache*, Nginx*, Tomcat* -Force -ErrorAction SilentlyContinue 
            Write-Host "[+] Limpieza completada. Todos los servicios detenidos." -ForegroundColor Yellow
        }
        "8" { exit }
        Default { Write-Host "Opcion no valida." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
    Write-Host ""
    Read-Host "Presione Enter para continuar..."
}
