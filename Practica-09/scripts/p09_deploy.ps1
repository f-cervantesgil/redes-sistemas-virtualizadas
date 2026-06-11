#Requires -RunAsAdministrator
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ZScripts  = "Z:\scripts"
$LocalDest = "C:\P09"
$LogFile   = "C:\P09\deploy_log.txt"

function Write-Ok   ($msg) { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function Write-Warn ($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Err  ($msg) { Write-Host "  [XX]  $msg" -ForegroundColor Red    }
function Write-Info ($msg) { Write-Host "  [--]  $msg" -ForegroundColor Cyan   }

Clear-Host
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   DEPLOY PRACTICA 09 - desde Z:\scripts\"                   -ForegroundColor Cyan
Write-Host "   UAS FIM - Administracion de Sistemas - Grupo 3-02"        -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $ZScripts)) {
    Write-Err "No se puede acceder a '$ZScripts'."
    Write-Warn "Verifica que la carpeta compartida este montada como Z:"
    Write-Info "VirtualBox: Dispositivos -> Carpetas Compartidas"
    exit 1
}
Write-Ok "Carpeta compartida accesible: $ZScripts"

if (-not (Test-Path $LocalDest)) {
    New-Item -ItemType Directory -Path $LocalDest | Out-Null
    Write-Ok "Directorio creado: $LocalDest"
} else {
    Write-Info "Directorio ya existe: $LocalDest"
}

"=== DEPLOY P09 $(Get-Date) ===" | Out-File $LogFile -Encoding UTF8

$scripts = @(
    "p09_menu.ps1",
    "p09_modulo1_rbac.ps1",
    "p09_modulo2_fgpp_audit.ps1",
    "p09_modulo3_monitoreo.ps1",
    "p09_modulo4_mfa_guia.ps1",
    "p09_modulo5_tests.ps1"
)

Write-Host ""
Write-Host "  Copiando scripts de Z:\scripts\ a C:\P09\" -ForegroundColor Yellow
Write-Host ""

$copied  = 0
$missing = @()

foreach ($s in $scripts) {
    $src = Join-Path $ZScripts $s
    $dst = Join-Path $LocalDest $s
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Ok "Copiado: $s"
        $copied++
    } else {
        Write-Warn "No encontrado en Z:\scripts\: $s"
        $missing += $s
    }
}

Write-Host ""
Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
Write-Info "Copiados: $copied / $($scripts.Count) scripts"

if ($missing.Count -gt 0) {
    Write-Warn "Faltantes: $($missing -join ', ')"
    Write-Info "Coloca esos archivos en la carpeta compartida de tu PC."
}

Write-Host ""
$run = Read-Host "  Abrir menu principal ahora? (s/n)"
if ($run.Trim().ToLower() -eq "s") {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    & "$LocalDest\p09_menu.ps1"
} else {
    Write-Host ""
    Write-Info "Para ejecutar manualmente:"
    Write-Host "  cd C:\P09" -ForegroundColor Cyan
    Write-Host "  .\p09_menu.ps1" -ForegroundColor Cyan
}
