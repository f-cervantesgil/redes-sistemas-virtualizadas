# p8_main_windows.ps1
# Menu Principal Practica 08 — GPO, FSRM, AppLocker, Union al Dominio

$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\p8_functions_windows.ps1"

fn_check_admin
fn_show_header

function fn_menu {
    Write-Host " Selecciona una opcion:" -ForegroundColor White
    Write-Host ""
    Write-Host "  [1]  Instalar Caracteristicas (AD DS, RSAT, FSRM, GPMC)"   -ForegroundColor Cyan
    Write-Host "  [2]  Unir este equipo al Dominio (Add-Computer)"            -ForegroundColor Cyan
    Write-Host "  [3]  Configurar Estructura AD (UOs: Cuates / No Cuates)"    -ForegroundColor Cyan
    Write-Host "  [4]  Importar 10 Usuarios desde CSV (por columna Tipo)"     -ForegroundColor Cyan
    Write-Host "  [5]  Configurar GPO Logon Hours y Cierre de Sesion"         -ForegroundColor Cyan
    Write-Host "  [6]  Configurar FSRM (Cuotas/usuario + Active Screening)"   -ForegroundColor Cyan
    Write-Host "  [7]  Configurar AppLocker (Notepad: Allow Cuates/Deny NoCuates por Hash)" -ForegroundColor Cyan
    Write-Host "  [8]  VERIFICAR Practica (Cuotas, Filtros, Horarios, AppLocker)" -ForegroundColor Green
    Write-Host "  [9]  Ejecutar TODO automaticamente (3 al 7)"                -ForegroundColor Yellow
    Write-Host "  [0]  Salir"                                                  -ForegroundColor Red
    Write-Host ""
}

$Running = $true
while ($Running) {
    fn_menu
    $op    = Read-Host "  Opcion"
    $pausa = $true

    switch ($op) {
        "1" { fn_install_features }
        "2" { fn_join_domain_windows }
        "3" { if (fn_check_dc) { fn_setup_ad_structure } }
        "4" { if (fn_check_dc) { fn_import_users_csv "$ScriptDir\..\..\data\usuarios.csv" } }
        "5" { if (fn_check_dc) { fn_setup_logon_gpo } }
        "6" { fn_setup_fsrm }
        "7" { if (fn_check_dc) { fn_setup_applocker } }
        "8" { if (fn_check_dc) { fn_verificar_p8 } }
        "9" {
            if (fn_check_dc) {
                fn_setup_ad_structure
                fn_import_users_csv "$ScriptDir\..\..\data\usuarios.csv"
                fn_setup_logon_gpo
                fn_setup_fsrm
                fn_setup_applocker
                fn_ok "===== Proceso automatico completo ====="
            }
        }
        "0" {
            $Running = $false
            $pausa   = $false
            fn_ok "Saliendo..."
        }
        default { fn_err "Opcion no valida. Elige entre 0 y 9." }
    }

    if ($pausa) {
        Write-Host ""
        Read-Host "  Presiona ENTER para continuar"
        fn_show_header
    }
}