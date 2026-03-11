# ==============================================================================
# Practica-07: main.ps1
# Script principal para el aprovisionamiento web en Windows
# ==============================================================================

# Cargar funciones
. (Join-Path $PSScriptRoot "http_functions.ps1")

# Verificar permisos de Administrador
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Este script debe ejecutarse como Administrador." -ForegroundColor Red
    exit 1
}

function Show-Menu {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "   SISTEMA DE APROVISIONAMIENTO WEB (WIN)   " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "1. Instalar IIS (Obligatorio)"
    Write-Host "2. Instalar Apache Win64"
    Write-Host "3. Instalar Nginx"
    Write-Host "4. Salir"
    Write-Host "==========================================" -ForegroundColor Green
    $choice = Read-Host "Seleccione una opción"
    return $choice
}

while ($true) {
    $option = Show-Menu
    $gotoMenu = $false
    
    switch ($option) {
        "1" {
            $service = "IIS"
            $version = "Windows Feature"
        }
        "2" {
            $service = "apache-httpd"
            $versions = Get-ServiceVersions -PackageName $service
            Write-Host "Versiones disponibles:"
            $versions
            $version = Read-Host "Ingrese la versión exacta"
        }
        "3" {
            $service = "nginx"
            $versions = Get-ServiceVersions -PackageName $service
            Write-Host "Versiones disponibles:"
            $versions
            $version = Read-Host "Ingrese la versión exacta"
        }
        "4" {
            Write-Host "Saliendo..."
            exit
        }
        Default {
            Write-Host "Opción inválida" -ForegroundColor Red
            Start-Sleep -Seconds 2
            continue
        }
    }

    # Solicitar puerto con validación y confirmación de salida
    $portInputDone = $false
    while (-not $portInputDone) {
        $portStr = Read-Host "Ingrese el puerto de escucha"
        
        # Validar numérico
        if ($portStr -match '^\d+$') {
            $port = [int]$portStr
            
            $reason = ""
            if (Test-IsReservedPort -Port $port) {
                $reason = "está RESERVADO (Puerto Protegido o 444)"
            }
            elseif (-not (Test-PortAvailability -Port $port)) {
                $reason = "ya está siendo OCUPADO por otro servicio"
            }

            if ($reason -ne "") {
                Write-Host "[ALERTA] El puerto $port $reason." -ForegroundColor Red
                $retry = Read-Host "¿Deseas intentar con otro puerto? (s/n)"
                if ($retry -match '^[nN]$') {
                    $gotoMenu = $true
                    break 
                }
                continue # Vuelve a pedir puerto
            }

            $portInputDone = $true
        } else {
            Write-Host "[ERROR] El puerto debe ser numérico." -ForegroundColor Red
            $retry = Read-Host "¿Deseas intentar con otro puerto? (s/n)"
            if ($retry -match '^[nN]$') {
                $gotoMenu = $true
                break 
            }
        }
    }

    if ($gotoMenu) { $gotoMenu = $false; continue }

    # Ejecución
    switch ($service) {
        "IIS" { Install-IIS -Port $port }
        "apache-httpd" { Install-ApacheWindows -Version $version -Port $port }
        "nginx" { Install-NginxWindows -Version $version -Port $port }
    }
    
    Read-Host "Presione Enter para continuar..."
}
