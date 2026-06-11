#Requires -RunAsAdministrator
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Ok   ($msg) { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function Write-Warn ($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Err  ($msg) { Write-Host "  [XX]  $msg" -ForegroundColor Red    }
function Write-Info ($msg) { Write-Host "  [--]  $msg" -ForegroundColor Cyan   }

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   PRACTICA 09 - Seguridad de Identidad, Delegacion y MFA"   -ForegroundColor Cyan
    Write-Host "   Administracion de Sistemas - UAS FIM  |  Grupo 3-02"       -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-Requirements {
    $ok = $true
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Warn "Modulo ActiveDirectory no disponible."
        Write-Info "Instala: Install-WindowsFeature RSAT-AD-Tools -IncludeAllSubFeature"
        $ok = $false
    }
    return $ok
}

function Show-MainMenu {
    Show-Header
    Write-Host "  MODULOS DISPONIBLES" -ForegroundColor White
    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [1]  Modulo 1 - Delegacion de Control y RBAC" -ForegroundColor White
    Write-Host "       Crear usuarios delegados + ACL granulares" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [2]  Modulo 2 - FGPP + Auditoria de Eventos" -ForegroundColor White
    Write-Host "       Politicas de contrasena + auditpol" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [3]  Modulo 3 - Script de Monitoreo (Reporte)" -ForegroundColor White
    Write-Host "       Extrae ultimos 10 accesos denegados ID 4625" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [4]  Modulo 4 - Guia MFA + Bloqueo de Cuenta" -ForegroundColor White
    Write-Host "       WinOTP / TOTP + bloqueo 30 min / 3 intentos" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [5]  Modulo 5 - Protocolo de Pruebas (Tests 1-5)" -ForegroundColor White
    Write-Host "       Verificacion automatizada PASS/FAIL" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [0]  Salir" -ForegroundColor DarkGray
    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

function Main {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

    if (-not (Test-Requirements)) {
        Write-Host ""
        Write-Host "  Presiona Enter para continuar de todas formas..." -ForegroundColor DarkGray
        Read-Host | Out-Null
    }

    $exit = $false
    while (-not $exit) {
        Show-MainMenu
        $choice = Read-Host "  Selecciona una opcion"

        switch ($choice.Trim()) {
            "1" { & "$PSScriptRoot\p09_modulo1_rbac.ps1"        }
            "2" { & "$PSScriptRoot\p09_modulo2_fgpp_audit.ps1"  }
            "3" { & "$PSScriptRoot\p09_modulo3_monitoreo.ps1"   }
            "4" { & "$PSScriptRoot\p09_modulo4_mfa_guia.ps1"    }
            "5" { & "$PSScriptRoot\p09_modulo5_tests.ps1"       }
            "0" { $exit = $true }
            default {
                Write-Warn "Opcion invalida. Elige entre 0 y 5."
                Start-Sleep -Seconds 1
            }
        }

        if (-not $exit) {
            Write-Host ""
            Write-Host "  Presiona Enter para volver al menu..." -ForegroundColor DarkGray
            Read-Host | Out-Null
        }
    }
    Write-Host ""
    Write-Info "Sesion terminada. Practica 09 - UAS FIM"
    Write-Host ""
}

Main
