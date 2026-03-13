#requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$TargetIP = "192.168.222.197"
$script:IisSitePath = "C:\inetpub\wwwroot"
$script:ApachePath = "C:\tools\apache24"
$script:NginxPath = "C:\tools\nginx"

function Info   { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Exito  { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Aviso  { param([string]$Msg) Write-Host "[AVISO] $Msg" -ForegroundColor Yellow }

# --- REQUERIMIENTO: FIREWALL ---
function Open-PortFirewall {
    param([int]$Port, [string]$Srv)
    $RuleName = "Regla-P6-$Srv-$Port"
    Info "Abriendo puerto $Port en el Firewall de Windows..."
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -LocalPort $Port -Protocol TCP -Action Allow -Profile Any | Out-Null
}

# --- REQUERIMIENTO: SEGURIDAD NTFS ---
function Set-RestrictedSecurity {
    param([string]$Path, [string]$User = "web_dedicated_user")
    Info "Configurando permisos NTFS en $Path..."
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $pass = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force
        New-LocalUser -Name $User -Password $pass -Description "User P6" | Out-Null
    }
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($User,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl $Path $acl
}

function Create-IndexHtml {
    param([string]$Path, [string]$Srv, [string]$Ver, [int]$Port)
    $html = "<html><body style='font-family:Arial;text-align:center;'><h1>Servidor: [$Srv] - Version: [$Ver] - Puerto: [$Port]</h1><h3>IP: $TargetIP</h3><hr><p>Hardening y NTFS OK</p></body></html>"
    Set-Content -Path (Join-Path $Path "index.html") -Value $html -Force
}

# --- CONFIGURACION IIS ---
function Set-IIS {
    param([int]$Port)
    Info "Iniciando configuracion de IIS en puerto $Port..."
    if (-not (Get-WindowsFeature -Name Web-Server).Installed) { Install-WindowsFeature -Name Web-Server | Out-Null }
    Import-Module WebAdministration
    
    # 1. Limpieza y Reconstruccion del Sitio
    iisreset /stop | Out-Null
    if (Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue) { Remove-Website -Name "Default Web Site" | Out-Null }
    New-Website -Name "Default Web Site" -Port $Port -PhysicalPath $script:IisSitePath -Force | Out-Null
    
    # 2. Binding e IP (Fuerza escucha en todas las IPs)
    $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
    & $appcmd set site "Default Web Site" /bindings:http/*:${Port}: | Out-Null
    
    # 3. Hardening de Seguridad
    & $appcmd set config /section:httpProtocol /-"customHeaders.[name='X-Powered-By']" /commit:apphost 2>$null
    & $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Frame-Options',value='SAMEORIGIN']" /commit:apphost 2>$null
    & $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Content-Type-Options',value='nosniff']" /commit:apphost 2>$null
    
    # 4. Contenido y Seguridad
    Create-IndexHtml -Path $script:IisSitePath -Srv "IIS" -Ver "LTS" -Port $Port
    Set-RestrictedSecurity -Path $script:IisSitePath
    
    # 5. Firewall y Arranque
    Open-PortFirewall -Port $Port -Srv "IIS"
    iisreset /start | Out-Null
    Start-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
}

# --- CONFIGURACION APACHE ---
function Set-Apache {
    param([int]$Port)
    Info "Iniciando configuracion de Apache..."
    if (-not (Test-Path $script:ApachePath)) { choco install apache-httpd --version 2.4.58 -y | Out-Null }
    
    $conf = Join-Path $script:ApachePath "conf\httpd.conf"
    (Get-Content $conf) -replace "^Listen\s+\d+", "Listen $Port" | Set-Content $conf
    
    Create-IndexHtml -Path (Join-Path $script:ApachePath "htdocs") -Srv "Apache" -Ver "2.4.58" -Port $Port
    Set-RestrictedSecurity -Path (Join-Path $script:ApachePath "htdocs")
    
    Open-PortFirewall -Port $Port -Srv "Apache"
    Restart-Service Apache* -ErrorAction SilentlyContinue
}

# --- CONFIGURACION NGINX ---
function Set-Nginx {
    param([int]$Port)
    Info "Iniciando configuracion de Nginx..."
    if (-not (Test-Path $script:NginxPath)) { choco install nginx -y | Out-Null }
    
    $conf = Join-Path $script:NginxPath "conf\nginx.conf"
    (Get-Content $conf) -replace "listen\s+\d+;", "listen $Port;" | Set-Content $conf
    
    Create-IndexHtml -Path (Join-Path $script:NginxPath "html") -Srv "Nginx" -Ver "1.24.0" -Port $Port
    Set-RestrictedSecurity -Path (Join-Path $script:NginxPath "html")
    
    Open-PortFirewall -Port $Port -Srv "Nginx"
    Stop-Process -Name nginx -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath (Join-Path $script:NginxPath "nginx.exe") -WorkingDirectory $script:NginxPath
}

# --- MENU ---
while ($true) {
    Clear-Host
    Write-Host "============================" -ForegroundColor Cyan
    Write-Host "   GESTOR WEB P6 DEFINITIVO" -ForegroundColor Cyan
    Write-Host "   IP: $TargetIP" -ForegroundColor Yellow
    Write-Host "============================"
    Write-Host "1) IIS (Puerto + Firewall + Hardening)"
    Write-Host "2) Apache"
    Write-Host "3) Nginx"
    Write-Host "4) Salir"
    
    $op = Read-Host "`nOpcion"
    if ($op -eq "4") { exit }
    
    $p = [int](Read-Host "Puerto")
    
    switch ($op) {
        "1" { Set-IIS -Port $p }
        "2" { Set-Apache -Port $p }
        "3" { Set-Nginx -Port $p }
    }
    
    Info "Validando conectividad en http://$TargetIP : $p..."
    Start-Sleep -Seconds 3 # Tiempo para que el servicio levante el socket
    $res = Test-NetConnection -ComputerName $TargetIP -Port $p
    if ($res.TcpTestSucceeded) {
        Exito "CONEXION EXITOSA. Ya puedes entrar desde el navegador."
    } else {
        Aviso "TCP Failed. El servicio esta listo pero algo mas bloquea el trafico externo."
    }
    Read-Host "`nEnter para continuar..."
}