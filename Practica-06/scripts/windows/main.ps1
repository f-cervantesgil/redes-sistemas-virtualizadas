# ==============================================================================
# Practica-06: main.ps1 - VERSION FINAL DE ENTREGABLE (SEGURIDAD + CONEXIÓN)
# ==============================================================================

$OutputEncoding = [System.Text.Encoding]::UTF8

# --- FUNCIONES DE SEGURIDAD ---

function Set-FolderSecurity {
    param([string]$Path, [string]$User)
    Write-Host "[*] Aplicando restricciones NTFS en $Path..." -ForegroundColor Gray
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    
    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $pass = ConvertTo-SecureString "P@ssw0rdService2026!" -AsPlainText -Force
        New-LocalUser -Name $User -Password $pass -Description "Usuario dedicado para servicios web" | Out-Null
    }
    
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    $rules = @(
        (New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")),
        (New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","ContainerInherit,ObjectInherit","None","Allow")),
        (New-Object System.Security.AccessControl.FileSystemAccessRule($User,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow"))
    )
    foreach($r in $rules){ $acl.AddAccessRule($r) }
    Set-Acl $Path $acl
}

function New-IndexPage {
    param([string]$Service, [string]$Version, [int]$Port, [string]$Path)
    $content = "Servidor: [$Service] - Version: [$Version] - Puerto: [$Port]"
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    Set-Content -Path (Join-Path $Path "index.html") -Value "<html><body style='font-family:Arial;text-align:center;background:#f4f4f4;'><h1>Configuracion Exitosa</h1><hr><h2>$content</h2></body></html>" -Force
}

function Show-SystemIP {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" }).IPAddress | Select-Object -First 1
    return $ip
}

# --- PROCESOS DE INSTALACION ---

function Install-IIS {
    param([int]$Port)
    Write-Host "`n[*] Iniciando aprovisionamiento seguro de IIS..." -ForegroundColor Blue
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-RequestFiltering" -NoRestart | Out-Null
        Import-Module WebAdministration
        
        # 1. Detencion para liberar bloqueos
        iisreset /stop | Out-Null
        Start-Service WAS, W3SVC -ErrorAction SilentlyContinue

        $sn = "Default Web Site"
        Stop-Website -Name "$sn" -ErrorAction SilentlyContinue

        # 2. Binding según especificación (Usando PropertyName para evitar prompts)
        Write-Host "[*] Aplicando Set-WebBinding en puerto ${Port}..." -ForegroundColor Cyan
        $binding = Get-WebBinding -Name "$sn" | Select-Object -First 1
        $oldInfo = if ($binding) { $binding.bindingInformation } else { "*:80:" }
        
        # Cambiamos el puerto y nos aseguramos que sea universal (*)
        Set-WebBinding -Name "$sn" -BindingInformation "$oldInfo" -PropertyName "Port" -Value $Port -ErrorAction SilentlyContinue
        Set-WebBinding -Name "$sn" -BindingInformation "*:${Port}:" -PropertyName "IPAddress" -Value "*" -ErrorAction SilentlyContinue

        # 3. Hardening (Cabeceras y Verbos)
        Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "X-Powered-By" -ErrorAction SilentlyContinue
        Add-WebConfigurationProperty -filter "system.webServer/httpProtocol/customHeaders" -PSPath "IIS:\Sites\$sn" -Name "." -value @{name='X-Frame-Options';value='SAMEORIGIN'} -ErrorAction SilentlyContinue
        Add-WebConfigurationProperty -filter "system.webServer/httpProtocol/customHeaders" -PSPath "IIS:\Sites\$sn" -Name "." -value @{name='X-Content-Type-Options';value='nosniff'} -ErrorAction SilentlyContinue
        
        foreach($v in @("TRACE","TRACK","DELETE")){
            Add-WebConfigurationProperty -filter "system.webServer/security/requestFiltering/verbs" -PSPath "IIS:\Sites\$sn" -Name "." -value @{verb=$v;allowed=$false} -ErrorAction SilentlyContinue
        }

        # 4. Seguridad de archivos y reinicio
        Set-FolderSecurity -Path "C:\inetpub\wwwroot" -User "web_service_user"
        New-IndexPage -Service "IIS" -Version "LTS" -Port $Port -Path "C:\inetpub\wwwroot"
        iisreset /start | Out-Null
        Start-Website -Name "$sn" -ErrorAction SilentlyContinue

        # 5. Firewall y Validacion
        Remove-NetFirewallRule -DisplayName "HTTP-Custom" -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule -Name "HTTP-Custom" -DisplayName "HTTP-Custom" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null
        
        $myIP = Show-SystemIP
        if ((Test-NetConnection -ComputerName localhost -Port $Port).TcpTestSucceeded) {
            Write-Host "[OK] IIS listo. Prueba en: http://$($myIP):$Port" -ForegroundColor Green
        }
    } catch { Write-Host "[!] Error: $_" -ForegroundColor Red }
}

function Install-ApacheWindows {
    param([int]$Port)
    $version = "2.4.58"
    Write-Host "`n[*] Instalando Apache configurado para Seguridad..." -ForegroundColor Blue
    choco install apache-httpd --version $version -y | Out-Null
    
    $conf = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $conf) {
        $c = Get-Content $conf
        $c = $c -replace "^Listen\s+\d+", "Listen $Port"
        $c += "`nServerTokens Prod`nServerSignature Off`nTraceEnable Off"
        $c | Set-Content $conf
    }
    
    Set-FolderSecurity -Path "C:\tools\apache24\htdocs" -User "web_service_user"
    New-IndexPage -Service "Apache" -Version $version -Port $Port -Path "C:\tools\apache24\htdocs"
    
    Remove-NetFirewallRule -DisplayName "HTTP-Apache" -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "HTTP-Apache" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null
    
    Restart-Service Apache2.4 -ErrorAction SilentlyContinue
    $myIP = Show-SystemIP
    Write-Host "[OK] Apache listo. Prueba en: http://$($myIP):$Port" -ForegroundColor Green
}

function Install-NginxWindows {
    param([int]$Port)
    $version = "1.24.0"
    Write-Host "`n[*] Instalando Nginx con Hardening..." -ForegroundColor Blue
    choco install nginx --version $version -y | Out-Null
    
    $path = "C:\tools\nginx"
    $conf = "$path\conf\nginx.conf"
    if (Test-Path $conf) {
        $c = Get-Content $conf
        $c = $c -replace "listen\s+\d+;", "listen $Port;"
        $c = $c -replace "server_tokens\s+on;", "server_tokens off;"
        if ($c -notmatch "server_tokens off;") {
            $c = $c -replace "http \{", "http {`n    server_tokens off;`n    add_header X-Frame-Options SAMEORIGIN;`n    add_header X-Content-Type-Options nosniff;"
        }
        $c | Set-Content $conf
    }
    
    Set-FolderSecurity -Path "$path\html" -User "web_service_user"
    New-IndexPage -Service "Nginx" -Version $version -Port $Port -Path "$path\html"
    
    Remove-NetFirewallRule -DisplayName "HTTP-Nginx" -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "HTTP-Nginx" -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null
    
    Stop-Process -Name nginx -ErrorAction SilentlyContinue
    Start-Process -FilePath "$path\nginx.exe" -WorkingDirectory $path
    
    $myIP = Show-SystemIP
    Write-Host "[OK] Nginx listo. Prueba en: http://$($myIP):$Port" -ForegroundColor Green
}

function Get-ServicesStatus {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "       REPORTE DE ESTADO Y SEGURIDAD      " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ("{0,-10} | {1,-10} | {2,-15}" -f "SERVICIO", "ESTADO", "URL SUGERIDA")
    
    $ip = Show-SystemIP
    $iis = Get-Service W3SVC -ErrorAction SilentlyContinue
    if($iis.Status -eq "Running"){ 
        $p = (Get-WebBinding -Name "Default Web Site").bindingInformation.Split(":")[1]
        Write-Host ("{0,-10} | {1,-10} | http://{2}:{3}" -f "IIS", "OK", $ip, $p) -ForegroundColor Green
    }
    
    $apa = Get-Service Apache2.4 -ErrorAction SilentlyContinue
    if($apa.Status -eq "Running"){ Write-Host ("{0,-10} | {1,-10} | Apache Activo" -f "Apache", "OK") -ForegroundColor Green }
    
    if(Get-Process nginx -ErrorAction SilentlyContinue){ Write-Host ("{0,-10} | {1,-10} | Nginx Activo" -f "Nginx", "OK") -ForegroundColor Green }
}

# --- MENU ---

while ($true) {
    Clear-Host
    Write-Host "--- ADMINISTRADOR DE SERVIDORES WEB (P6) ---" -ForegroundColor Yellow
    Write-Host "1. IIS (Hardening + Set-WebBinding)"
    Write-Host "2. Apache (Choco + Security)"
    Write-Host "3. Nginx (Choco + Security)"
    Write-Host "4. Ver Estado de Red"
    Write-Host "5. Salir"
    
    $op = Read-Host "`nSelecciona una opcion"
    switch ($op) {
        "1" { $p = Read-Host "Puerto IIS?"; Install-IIS $p; Read-Host "Enter..." }
        "2" { $p = Read-Host "Puerto Apache?"; Install-ApacheWindows $p; Read-Host "Enter..." }
        "3" { $p = Read-Host "Puerto Nginx?"; Install-NginxWindows $p; Read-Host "Enter..." }
        "4" { Get-ServicesStatus; Read-Host "Enter..." }
        "5" { exit }
    }
}
