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

# --- SEGURIDAD NTFS (REQUERIMIENTO) ---
function Set-RestrictedSecurity {
    param([string]$Path, [string]$User = "web_dedicated_user")
    Info "Aplicando restricciones NTFS en $Path para $User..."
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $pass = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force
        New-LocalUser -Name $User -Password $pass -Description "Usuario dedicado web" | Out-Null
    }
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($User,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl $Path $acl
}

# --- INDEX PERSONALIZADO ---
function Create-IndexHtml {
    param([string]$Path, [string]$Srv, [string]$Ver, [int]$Port)
    $html = "<html><body style='font-family:Arial;text-align:center;'><h1>Servidor: [$Srv] - Version: [$Ver] - Puerto: [$Port]</h1></body></html>"
    Set-Content -Path (Join-Path $Path "index.html") -Value $html -Force
}

# --- CONFIGURACION IIS ---
function Set-IIS {
    param([int]$Port)
    Info "Configurando IIS..."
    if (-not (Get-WindowsFeature -Name Web-Server).Installed) { Install-WindowsFeature -Name Web-Server | Out-Null }
    Import-Module WebAdministration
    iisreset /stop | Out-Null
    
    # Requerimiento: Set-WebBinding
    Get-WebBinding -Name "Default Web Site" | Remove-WebBinding -ErrorAction SilentlyContinue
    New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port $Port -Protocol "http" | Out-Null
    
    # Hardening
    $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
    & $appcmd set config /section:httpProtocol /-"customHeaders.[name='X-Powered-By']" /commit:apphost 2>$null
    & $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Frame-Options',value='SAMEORIGIN']" /commit:apphost 2>$null
    
    Create-IndexHtml -Path $script:IisSitePath -Srv "IIS" -Ver "LTS" -Port $Port
    Set-RestrictedSecurity -Path $script:IisSitePath
    
    iisreset /start | Out-Null
    Exito "IIS listo en puerto $Port"
}

# --- CONFIGURACION APACHE ---
function Set-Apache {
    param([int]$Port)
    Info "Configurando Apache..."
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) }
    if (-not (Test-Path $script:ApachePath)) { choco install apache-httpd --version 2.4.58 -y | Out-Null }
    
    $conf = Join-Path $script:ApachePath "conf\httpd.conf"
    (Get-Content $conf) -replace "^Listen\s+\d+", "Listen $Port" | Set-Content $conf
    
    Create-IndexHtml -Path (Join-Path $script:ApachePath "htdocs") -Srv "Apache" -Ver "2.4.58" -Port $Port
    Set-RestrictedSecurity -Path (Join-Path $script:ApachePath "htdocs")
    
    Restart-Service Apache* -ErrorAction SilentlyContinue
    Exito "Apache listo en puerto $Port"
}

# --- CONFIGURACION NGINX ---
function Set-Nginx {
    param([int]$Port)
    Info "Configurando Nginx..."
    if (-not (Test-Path $script:NginxPath)) { choco install nginx -y | Out-Null }
    
    $conf = Join-Path $script:NginxPath "conf\nginx.conf"
    (Get-Content $conf) -replace "listen\s+\d+;", "listen $Port;" | Set-Content $conf
    
    Create-IndexHtml -Path (Join-Path $script:NginxPath "html") -Srv "Nginx" -Ver "1.24.0" -Port $Port
    Set-RestrictedSecurity -Path (Join-Path $script:NginxPath "html")
    
    Stop-Process -Name nginx -ErrorAction SilentlyContinue
    Start-Process -FilePath (Join-Path $script:NginxPath "nginx.exe") -WorkingDirectory $script:NginxPath
    Exito "Nginx listo en puerto $Port"
}

# --- MENU ---
while ($true) {
    Clear-Host
    Write-Host "============================" -ForegroundColor Cyan
    Write-Host "   MENU WEB WINDOWS (P6)" -ForegroundColor Cyan
    Write-Host "   IP: $TargetIP"
    Write-Host "============================"
    Write-Host "1) Configurar IIS"
    Write-Host "2) Configurar Apache"
    Write-Host "3) Configurar Nginx"
    Write-Host "4) Salir"
    
    $op = Read-Host "`nOpcion"
    if ($op -eq "4") { exit }
    
    $pString = Read-Host "Puerto"
    $p = [int]$pString # Conversion limpia para evitar errores
    
    switch ($op) {
        "1" { Set-IIS -Port $p }
        "2" { Set-Apache -Port $p }
        "3" { Set-Nginx -Port $p }
    }
    
    Info "Validando conectividad en $TargetIP : $p..."
    Test-NetConnection -ComputerName $TargetIP -Port $p
    Read-Host "`nEnter para volver al menu..."
}