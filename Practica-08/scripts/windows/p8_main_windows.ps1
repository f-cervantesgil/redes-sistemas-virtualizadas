# p8_main_windows.ps1
# Menu Practica 08 Final - Reintegración de Opción 1

$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\p8_functions_windows.ps1"

fn_check_admin
Clear-Host
Write-Host " +============================================================+" -ForegroundColor Blue
Write-Host " |      GESTION DE RECURSOS Y GOBERNANZA - PRACTICA 08        |" -ForegroundColor Blue
Write-Host " +============================================================+" -ForegroundColor Blue

$Running = $true
while ($Running) {
    Write-Host ""
    Write-Host " [1] PASO 1: Instalar Roles (AD, FSRM, GPMC)" -ForegroundColor Green
    Write-Host " [2] PASO 2: Promover Servidor a Dominio (redes.local)" -ForegroundColor White
    Write-Host " [3] PASO 3: Unir este equipo al Dominio (Solo Cliente)" -ForegroundColor Yellow
    Write-Host " [4] PASO 4: Configurar Estructura AD (UOs, Grupos, Usuarios)" -ForegroundColor Cyan
    Write-Host " [5] PASO 5: Servidor de Archivos (FSRM, Cuotas, SMB)" -ForegroundColor Cyan
    Write-Host " [6] PASO 6: Control de Aplicaciones (AppLocker Hash)" -ForegroundColor Cyan
    Write-Host " [7] EJECUTAR TODO el Servidor (Pasos 1 al 6)" -ForegroundColor Yellow
    Write-Host " [8] Salir" -ForegroundColor Red
    Write-Host ""
    $op = Read-Host "Opcion"
    $pausa = $true

    switch ($op) {
        "1" { fn_install_features }
        "2" { fn_promote_dc }
        "3" { fn_join_domain }
        "4" { if (fn_check_dc) { fn_setup_ad_structure; fn_import_users_csv } }
        "5" { if (fn_check_dc) { fn_setup_fsrm_and_shares } }
        "6" { if (fn_check_dc) { fn_setup_applocker } }
        "7" { 
            fn_install_features
            if (fn_check_dc) {
                fn_setup_ad_structure
                fn_import_users_csv
                fn_setup_fsrm_and_shares
                fn_setup_applocker
                fn_ok "Instalacion completa finalizada."
            }
        }
        "8" { $Running = $false; $pausa = $false }
    }

    if ($pausa) {
        Read-Host "Presiona ENTER para continuar"
        Clear-Host
    }
}