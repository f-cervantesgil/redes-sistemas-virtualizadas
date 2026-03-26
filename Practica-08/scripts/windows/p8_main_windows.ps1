# p8_main_windows.ps1
# Menu Principal Practica 08

$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. "$ScriptDir\p8_functions_windows.ps1"

fn_check_admin
fn_show_header

function fn_menu {
    Write-Host "1. Instalar Caracteristicas (AD, FSRM, AppLocker, GPO)" -ForegroundColor Cyan
    Write-Host "2. Configurar Estructura AD (UOs y Grupos)" -ForegroundColor Cyan
    Write-Host "3. Importar Usuarios desde CSV (Sistemas=Cuates, Otros=No Cuates)" -ForegroundColor Cyan
    Write-Host "4. Configurar GPO Logon Hours y Cierre de Sesion" -ForegroundColor Cyan
    Write-Host "5. Configurar FSRM (Cuotas y Filtros de Archivos)" -ForegroundColor Cyan
    Write-Host "6. Configurar AppLocker (Reglas de Hash)" -ForegroundColor Cyan
    Write-Host "7. Ejecutar TODO automaticamente" -ForegroundColor Yellow
    Write-Host "8. Salir" -ForegroundColor Red
    echo ""
}

while ($true) {
    fn_menu
    $op = Read-Host "Elige una opcion"
    
    switch ($op) {
        "1" { fn_install_features }
        "2" { if (fn_check_dc) { fn_setup_ad_structure } }
        "3" { if (fn_check_dc) { fn_import_users_csv "$ScriptDir\..\..\data\usuarios.csv" } }
        "4" { if (fn_check_dc) { fn_setup_logon_gpo } }
        "5" { fn_setup_fsrm }
        "6" { fn_setup_applocker }
        "7" { 
            fn_install_features
            if (fn_check_dc) {
                fn_setup_ad_structure
                fn_import_users_csv "$ScriptDir\..\..\data\usuarios.csv"
                fn_setup_logon_gpo
            }
            fn_setup_fsrm
            fn_setup_applocker
            fn_ok "Proceso completo finalizado."
        }
        "8" { break }
        default { fn_err "Opcion no valida." }
    }
    echo ""
    Read-Host "Presiona ENTER para continuar"
    fn_show_header
}
