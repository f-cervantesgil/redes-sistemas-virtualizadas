# p8_main_windows.ps1
# Menu Principal Practica 08 - Versión Consolidada

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
    Write-Host " [1] PASO 1: Promover Servidor a Dominio (redes.local)" -ForegroundColor White
    Write-Host " [2] SOLO CLIENTE: Unir este equipo al Dominio" -ForegroundColor Green
    Write-Host " [3] PASO 2: Configurar AD (UOs, Grupos y Usuarios CSV)" -ForegroundColor Cyan
    Write-Host " [4] PASO 3: Configurar FSRM, Cuotas y SMB Shares" -ForegroundColor Cyan
    Write-Host " [5] PASO 4: Configurar AppLocker (Regla de Hash)" -ForegroundColor Cyan
    Write-Host " [6] EJECUTAR TODO el Servidor (3 al 5)" -ForegroundColor Yellow
    Write-Host " [7] Salir" -ForegroundColor Red
    Write-Host ""
    $op = Read-Host "Selecciona una opcion"
    $pausa = $true

    switch ($op) {
        "1" { fn_promote_dc }
        "2" { fn_join_domain }
        "3" { if (fn_check_dc) { fn_setup_ad_structure; fn_import_users_csv } }
        "4" { if (fn_check_dc) { fn_setup_fsrm_and_shares } }
        "5" { if (fn_check_dc) { fn_setup_applocker } }
        "6" { 
            if (fn_check_dc) {
                fn_setup_ad_structure
                fn_import_users_csv
                fn_setup_fsrm_and_shares
                fn_setup_applocker
                fn_ok "Configuracion completa realizada."
            }
        }
        "7" { $Running = $false; $pausa = $false }
    }

    if ($pausa) {
        Read-Host "Presiona ENTER para continuar"
        Clear-Host
    }
}

function fn_join_domain {
    $dom = Read-Host "Ingresa el nombre del dominio (ej: redes.local)"
    fn_info "Uniendose al dominio $dom... Te pedira credenciales."
    try {
        Add-Computer -DomainName $dom -Restart -Force
    } catch {
        fn_err "Fallo la union al dominio: $($_.Exception.Message)"
    }
}