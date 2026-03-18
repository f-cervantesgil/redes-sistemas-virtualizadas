# ==============================================================================
# menu_windows_reparado.ps1
# Practica 6 - Windows Server 2022 - Aprovisionamiento HTTP
# ==============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Candidates = @(
    (Join-Path $ScriptDir 'http_functions_reparado.ps1'),
    (Join-Path $ScriptDir 'http_functions_corregido_final.ps1'),
    (Join-Path $ScriptDir 'http_functions.ps1')
)
$FunctionsFile = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $FunctionsFile) {
    Write-Host 'ERROR: No se encontro ningun archivo de funciones compatible.' -ForegroundColor Red
    Write-Host ($Candidates -join "`n") -ForegroundColor DarkYellow
    exit 1
}
. $FunctionsFile

$required = @(
    'Assert-Admin','Write-Section','Write-Info','Write-Warn','Write-Err',
    'Get-PortFromUser','Get-ServiceStateSummary','Get-ServiceConfiguredPort',
    'Get-ListeningTable','Select-Version','Install-IIS','Install-ApacheWindows',
    'Install-NginxWindows','Invoke-ServiceAction','Show-ServiceLogs','Set-IISPort',
    'Configure-Apache','Set-NginxConfig','Restart-NginxManaged','Test-HttpHeaders',
    'Stop-ListeningServiceByPort'
)
$missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missing.Count -gt 0) {
    Write-Host "ERROR: El archivo de funciones cargado no expuso todas las funciones requeridas." -ForegroundColor Red
    Write-Host "Archivo: $FunctionsFile" -ForegroundColor Yellow
    Write-Host "Faltan: $($missing -join ', ')" -ForegroundColor Yellow
    exit 1
}

Assert-Admin

function Show-Header {
    Clear-Host
    Write-Host ''
    Write-Host '  +============================================================+' -ForegroundColor Blue
    Write-Host '  |      APROVISIONAMIENTO DE SERVIDORES HTTP                  |' -ForegroundColor Blue
    Write-Host '  |      Practica 6 - Windows Server 2022 - PowerShell         |' -ForegroundColor Blue
    Write-Host '  +============================================================+' -ForegroundColor Blue
    Write-Host ''
    Show-ServiceStatus
    Write-Host ''
}

function Show-ServiceStatus {
    Write-Host '  Estado actual de servicios:' -ForegroundColor White
    foreach ($svc in 'IIS','Apache','Nginx') {
        $st = Get-ServiceStateSummary -Servicio $svc
        if ($st.Running) {
            Write-Host ("    [+] {0,-7} activo   puerto real: {1}" -f $svc, $st.RealPort) -ForegroundColor Green
        } elseif ($st.ConfiguredPort) {
            Write-Host ("    [-] {0,-7} inactivo/configurado puerto: {1}" -f $svc, $st.ConfiguredPort) -ForegroundColor Yellow
            if ($st.Detail) { Write-Host ("        {0}" -f $st.Detail) -ForegroundColor DarkYellow }
        } else {
            Write-Host ("    [-] {0,-7} no instalado / sin config" -f $svc) -ForegroundColor Red
        }
    }
}

function Show-MainMenu {
    Show-Header
    Write-Host '  ============  MENU PRINCIPAL  ============' -ForegroundColor White
    Write-Host ''
    Write-Host '  -- Instalacion -----------------------------' -ForegroundColor Cyan
    Write-Host '   1)  Instalar IIS (Internet Information Services)' -ForegroundColor Green
    Write-Host '   2)  Instalar Apache HTTP Server (Win64)' -ForegroundColor Green
    Write-Host '   3)  Instalar Nginx para Windows' -ForegroundColor Green
    Write-Host ''
    Write-Host '  -- Gestion de servicios --------------------' -ForegroundColor Cyan
    Write-Host '   4)  Iniciar / Detener / Reiniciar servicio' -ForegroundColor Green
    Write-Host '   5)  Ver puertos activos de cada servicio' -ForegroundColor Green
    Write-Host '   6)  Ver logs recientes de un servicio' -ForegroundColor Green
    Write-Host ''
    Write-Host '  -- Configuracion ---------------------------' -ForegroundColor Cyan
    Write-Host '   7)  Cambiar puerto de un servicio instalado' -ForegroundColor Green
    Write-Host '   8)  Ver encabezados HTTP (curl -I)' -ForegroundColor Green
    Write-Host '   9)  Liberar un puerto en escucha' -ForegroundColor Green
    Write-Host ''
    Write-Host '   0)  Salir' -ForegroundColor Red
    Write-Host ''
    Write-Host -NoNewline '  Selecciona una opcion [0-9]: ' -ForegroundColor White
}

function Select-Service {
    param([string]$Prompt = 'Selecciona servicio')
    Write-Host ''
    Write-Host '  1) IIS' -ForegroundColor Green
    Write-Host '  2) Apache' -ForegroundColor Green
    Write-Host '  3) Nginx' -ForegroundColor Green
    do {
        $sel = Read-Host "  $Prompt [1-3]"
        switch ($sel) {
            '1' { return 'IIS' }
            '2' { return 'Apache' }
            '3' { return 'Nginx' }
            default { Write-Warn 'Seleccion invalida.' }
        }
    } while ($true)
}

function Select-Action {
    Write-Host ''
    Write-Host '  1) Iniciar' -ForegroundColor Green
    Write-Host '  2) Detener' -ForegroundColor Green
    Write-Host '  3) Reiniciar' -ForegroundColor Green
    do {
        $sel = Read-Host '  Accion [1-3]'
        switch ($sel) {
            '1' { return 'Start' }
            '2' { return 'Stop' }
            '3' { return 'Restart' }
            default { Write-Warn 'Seleccion invalida.' }
        }
    } while ($true)
}

function Show-PortsPanel {
    Write-Section 'PUERTOS ACTIVOS POR SERVICIO'
    Write-Host 'Configuracion en archivos / bindings:' -ForegroundColor Cyan
    foreach ($svc in 'IIS','Apache','Nginx') {
        $port = Get-ServiceConfiguredPort -Servicio $svc
        Write-Host ("  {0,-7}: puerto {1}" -f $svc, $(if ($port) { $port } else { '?' })) -ForegroundColor White
    }
    Write-Host ''
    Write-Host 'Puertos en escucha (red):' -ForegroundColor Cyan
    $rows = Get-ListeningTable
    if (-not $rows -or $rows.Count -eq 0) {
        Write-Warn 'No se detectaron listeners para IIS/Apache/Nginx.'
    } else {
        '{0,-8} {1,-8} {2,-8} {3}' -f 'Servicio','Puerto','PID','Proceso' | Write-Host -ForegroundColor White
        '{0,-8} {1,-8} {2,-8} {3}' -f '--------','------','---','-------' | Write-Host -ForegroundColor White
        foreach ($r in $rows) { '{0,-8} {1,-8} {2,-8} {3}' -f $r.Servicio,$r.Puerto,$r.PID,$r.Proceso | Write-Host }
    }
}

function Flow-InstallIIS {
    Write-Section 'Flujo de instalacion: IIS'
    Write-Info 'IIS se instala con la version incluida en Windows Server 2022.'
    $puerto = Get-PortFromUser -Servicio 'IIS' -Default 8081
    Install-IIS -Puerto $puerto
}

function Flow-InstallApache {
    Write-Section 'Flujo de instalacion: Apache'
    $version = Select-Version -Paquete 'Apache'
    $puerto  = Get-PortFromUser -Servicio 'Apache' -Default 8082
    Install-ApacheWindows -Version $version -Puerto $puerto
}

function Flow-InstallNginx {
    Write-Section 'Flujo de instalacion: Nginx'
    $version = Select-Version -Paquete 'Nginx'
    $puerto  = Get-PortFromUser -Servicio 'Nginx' -Default 8083
    Install-NginxWindows -Version $version -Puerto $puerto
}

function Flow-ServiceAction {
    Write-Section 'Gestion de servicios'
    $svc = Select-Service -Prompt 'Servicio'
    $act = Select-Action
    Invoke-ServiceAction -Servicio $svc -Action $act
    Write-Ok "$act aplicado a $svc."
}

function Flow-Logs {
    $svc = Select-Service -Prompt 'Servicio para ver logs'
    Show-ServiceLogs -Servicio $svc
}

function Flow-ChangePort {
    Write-Section 'Cambio de puerto'
    $svc = Select-Service -Prompt 'Servicio a reconfigurar'
    switch ($svc) {
        'IIS' {
            $current = Get-ServiceConfiguredPort -Servicio 'IIS'
            $puerto = Get-PortFromUser -Servicio 'IIS' -Default $(if ($current) { $current } else { 8081 })
            Set-IISPort -Puerto $puerto
        }
        'Apache' {
            $current = Get-ServiceConfiguredPort -Servicio 'Apache'
            $puerto = Get-PortFromUser -Servicio 'Apache' -Default $(if ($current) { $current } else { 8082 })
            Configure-Apache -Puerto $puerto
        }
        'Nginx' {
            $current = Get-ServiceConfiguredPort -Servicio 'Nginx'
            $puerto = Get-PortFromUser -Servicio 'Nginx' -Default $(if ($current) { $current } else { 8083 })
            Set-NginxConfig -Puerto $puerto
            Restart-NginxManaged -Puerto $puerto
        }
    }
}

function Flow-Headers {
    $svc = Select-Service -Prompt 'Servicio para curl -I'
    Test-HttpHeaders -Servicio $svc
}

function Flow-FreePort {
    Write-Section 'Liberar puerto'
    do {
        $raw = Read-Host 'Puerto a liberar'
        $ok = $raw -match '^\d+$'
        if (-not $ok) { Write-Warn 'Ingresa solo numeros.' }
    } until ($ok)
    Stop-ListeningServiceByPort -Puerto ([int]$raw)
}

while ($true) {
    try {
        Show-MainMenu
        $opt = Read-Host
        switch ($opt) {
            '1' { Flow-InstallIIS }
            '2' { Flow-InstallApache }
            '3' { Flow-InstallNginx }
            '4' { Flow-ServiceAction }
            '5' { Show-PortsPanel }
            '6' { Flow-Logs }
            '7' { Flow-ChangePort }
            '8' { Flow-Headers }
            '9' { Flow-FreePort }
            '0' { break }
            default { Write-Warn 'Opcion invalida.' }
        }
    } catch {
        Write-Err $_.Exception.Message
    }
    Write-Host ''
    Read-Host 'Presiona ENTER para volver al menu' | Out-Null
}
