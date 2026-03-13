#requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$TargetIP = "192.168.222.197"
$script:IisSiteName = "Default Web Site"
$script:IisSitePath = "C:\inetpub\wwwroot"

function Info   { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Exito  { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Aviso  { param([string]$Msg) Write-Host "[AVISO] $Msg" -ForegroundColor Yellow }
function ErrorX { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Debes ejecutar este script como Administrador para configurar IIS."
    }
}

# --- REQUERIMIENTO: SEGURIDAD Y PERMISOS DE USUARIO ---
function Set-RestrictedSecurity {
    param([string]$Path, [string]$User = "web_dedicated_user")
    Info "Restringiendo permisos en $Path para el usuario $User..."
    
    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $pass = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force
        New-LocalUser -Name $User -Password $pass -Description "Usuario dedicado para servicios web" | Out-Null
    }
    
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false) # Bloquear herencia
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($User,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl $Path $acl
}

# --- REQUERIMIENTO: HARDENING (OCULTAR VERSIONES) ---
function Apply-Hardening {
    param([string]$Service)
    Info "Aplicando Hardening para $Service..."
    $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
    
    if ($Service -eq "iis") {
        # Ocultar X-Powered-By y aplicar cabeceras de seguridad
        & $appcmd set config /section:httpProtocol /-"customHeaders.[name='X-Powered-By']" /commit:apphost 2>$null
        & $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Frame-Options',value='SAMEORIGIN']" /commit:apphost 2>$null
        & $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Content-Type-Options',value='nosniff']" /commit:apphost 2>$null
        # Bloquear verbos inseguros
        & $appcmd set config /section:requestFiltering /+"verbs.[verb='TRACE',allowed='false']" /commit:apphost 2>$null
        & $appcmd set config /section:requestFiltering /+"verbs.[verb='DELETE',allowed='false']" /commit:apphost 2>$null
    }
}

function Ensure-IISMandatory {
    Info "Verificando IIS..."
    if (-not (Get-WindowsFeature -Name Web-Server).Installed) {
        Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    }
    Import-Module WebAdministration
    
    # Reparar sitio si esta dañado (Solucion al error 0x800710D8)
    if (-not (Test-Path $script:IisSitePath)) { New-Item -Path $script:IisSitePath -ItemType Directory -Force | Out-Null }
    
    if (-not (Get-Website -Name $script:IisSiteName -ErrorAction SilentlyContinue)) {
        New-Website -Name $script:IisSiteName -Port 80 -PhysicalPath $script:IisSitePath -Force | Out-Null
    }
    
    # Reinicio forzado para asegurar registro de objetos
    iisreset /stop | Out-Null
    Start-Service AppHostSvc, WAS, W3SVC -ErrorAction SilentlyContinue
    iisreset /start | Out-Null
}

function Set-IISPort {
    param([int]$Port)
    Info "Configurando puerto $Port en IIS..."
    
    # REQUERIMIENTO: Set-WebBinding -Name "Default Web Site" -BindingInformation "*:PUERTO:"
    Set-WebBinding -Name $script:IisSiteName -BindingInformation "*:${Port}:" -PropertyName "Port" -Value 80 -ErrorAction SilentlyContinue
    # Si el anterior falla porque no hay un binding en 80, creamos uno limpio
    Get-WebBinding -Name $script:IisSiteName | Remove-WebBinding -ErrorAction SilentlyContinue
    New-WebBinding -Name $script:IisSiteName -IPAddress "*" -Port $Port -Protocol "http" | Out-Null
    
    # REQUERIMIENTO: index.html personalizado
    $htmlContent = "<html><body><h1>Servidor: [IIS] - Version: [LTS] - Puerto: [$Port]</h1><p>Hardening y Seguridad NTFS aplicados.</p></body></html>"
    Set-Content -Path (Join-Path $script:IisSitePath "index.html") -Value $htmlContent -Force
    
    Set-RestrictedSecurity -Path $script:IisSitePath
    Apply-Hardening -Service "iis"
    
    Restart-Website -Name $script:IisSiteName -ErrorAction SilentlyContinue
    
    # REQUERIMIENTO: Validacion con Test-NetConnection
    Info "Validando puerto $Port..."
    $check = Test-NetConnection -ComputerName $TargetIP -Port $Port -InformationLevel Quiet
    if ($check) {
        Exito "IIS operativo en http://${TargetIP}:${Port}"
    } else {
        Aviso "El puerto $Port no responde externamente. Revisa el Firewall."
    }
}

# --- CHOCOLATEY Y OTROS SERVICIOS ---
function Ensure-Chocolatey {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Info "Instalando Chocolatey..."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }
}

# --- MENU PRINCIPAL ---
function Main {
    Assert-Admin
    Ensure-IISMandatory
    Ensure-Chocolatey
    
    while ($true) {
        Clear-Host
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  MENU DE ADMINISTRACION WEB (P6)" -ForegroundColor Cyan
        Write-Host "  IP OBJETIVO: $TargetIP" -ForegroundColor Yellow
        Write-Host "========================================"
        Write-Host "1) Configurar IIS (Puerto + Hardening)"
        Write-Host "2) Info Chocolatey Apache"
        Write-Host "3) Salir"
        Write-Host ""
        
        $choice = Read-Host "Selecciona una opcion"
        switch ($choice) {
            "1" {
                $p = Read-Host "Ingresa el puerto"
                Set-IISPort -Port [int]$p
                Read-Host "Presiona Enter..."
            }
            "2" {
                choco info apache --all
                Read-Host "Presiona Enter..."
            }
            "3" { exit }
        }
    }
}

Main