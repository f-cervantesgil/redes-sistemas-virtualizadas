# ============================================================================
# menu_windows.ps1
# Practica 6 - Windows Server 2022 - Aprovisionamiento HTTP
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Paeth
$FunctionsFile = Join-Path $ScriptDir 'http_functions.ps1'
$script:LibraryLoaded = $false

function Import-FunctionsLibrary {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No se encontro el archivo de funciones: $Path"
    }

    if (Get-Command Unblock-File -ErrorAction SilentlyContinue) {
        try { Unblock-File -LiteralPath $Path -ErrorAction SilentlyContinue } catch {}
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'El archivo de funciones esta vacio.'
        }

        . ([scriptblock]::Create($raw))
    } catch {
        throw "No se pudo cargar la biblioteca de funciones '$Path'. Detalle: $($_.Exception.Message)"
    }

    $required = @(
        'Assert-Admin',
        'Write-Info',
        'Write-Ok',
        'Write-Warn',
        'Write-Section',
        'Get-ServiceStateSummary',
        'Get-ServiceConfiguredPort',
        'Get-ListeningTable',
        'Get-PortFromUser',
        'Install-IIS',
        'Install-ApacheWindows',
        'Install-NginxWindows',
        'Invoke-ServiceAction',
        'Show-ServiceLogs',
        'Set-IISPort',
        'Configure-Apache',
        'Set-NginxConfig',
        'Restart-NginxManaged',
        'Test-HttpHeaders',
        'Stop-ListeningServiceByPort',
        'Select-Version'
    )

    $missing = @($required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        throw "La biblioteca se cargo de forma incompleta. Faltan funciones: $($missing -join ', ')"
    }

    $script:LibraryLoaded = $true
}

function Write-ErrLocal {
    param([string]$Text)
    Write-Host "[ERR]  $Text" -ForegroundColor Red
}

try {
    Import-FunctionsLibrary -Path $FunctionsFile
    Assert-Admin
} catch {
    Write-ErrLocal $_.Exception.Message
    Write-Host ''
    Read-Host 'Presiona ENTER para salir' | Out-Null
    exit 1
}

function Show-ServiceStatus {
    Write-Host '  Estado actual de servicios:' -ForegroundColor White

    if (-not $script:LibraryLoaded) {
        Write-Host '    [!] Biblioteca de funciones no cargada.' -ForegroundColor Yellow
        return
    }

    foreach ($svc in @('IIS','Apache','Nginx')) {
        try {
            $st = Get-ServiceStateSummary -Servicio $svc
            if ($st.Running) {
                Write-Host ("    [+] {0,-7} activo   puerto real: {1}" -f $svc, $st.RealPort) -ForegroundColor Green
            } elseif ($st.ConfiguredPort) {
                Write-Host ("    [-] {0,-7} inactivo/configurado puerto: {1}" -f $svc, $st.ConfiguredPort) -ForegroundColor Yellow
                if ($st.Detail) {
                    Write-Host ("        {0}" -f $st.Detail) -ForegroundColor DarkYellow
                }
            } else {
                Write-Host ("    [-] {0,-7} no instalado / sin config" -f $svc) -ForegroundColor Red
            }
        } catch {
            Write-Host ("    [!] {0,-7} error al consultar estado: {1}" -f $svc, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

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

    foreach ($svc in @('IIS','Apache','Nginx')) {
        $port = Get-ServiceConfiguredPort -Servicio $svc
        Write-Host ("  {0,-7}: puerto {1}" -f $svc, $(if ($port) { $port } else { '?' })) -ForegroundColor White
    }

    Write-Host ''
    Write-Host 'Puertos en escucha (red):' -ForegroundColor Cyan
    $rows = Get-ListeningTable

    if (-not $rows -or $rows.Count -eq 0) {
        Write-Warn 'No se detectaron listeners para IIS/Apache/Nginx.'
        return
    }

    '{0,-8} {1,-8} {2,-8} {3}' -f 'Servicio','Puerto','PID','Proceso' | Write-Host -ForegroundColor White
    '{0,-8} {1,-8} {2,-8} {3}' -f '--------','------','---','-------' | Write-Host -ForegroundColor White

    foreach ($r in $rows) {
        '{0,-8} {1,-8} {2,-8} {3}' -f $r.Servicio, $r.Puerto, $r.PID, $r.Proceso | Write-Host
    }
}

function Flow-InstallIIS {
    Write-Section 'Flujo de instalacion: IIS'
    Write-Info 'IIS se instala con la version incluida en Windows Server 2022 (IIS 10).'
    $puerto = Get-PortFromUser -Servicio 'IIS' -Default 8080
    Install-IIS -Puerto $puerto
}

function Flow-InstallApache {
    Write-Section 'Flujo de instalacion: Apache'
    $version = Select-Version -Paquete 'Apache'
    $puerto = Get-PortFromUser -Servicio 'Apache' -Default 8081
    Install-ApacheWindows -Version $version -Puerto $puerto
}

function Flow-InstallNginx {
    Write-Section 'Flujo de instalacion: Nginx'
    $version = Select-Version -Paquete 'Nginx'
    $puerto = Get-PortFromUser -Servicio 'Nginx' -Default 8082
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
            $actual = Get-ServiceConfiguredPort -Servicio 'IIS'
            $puerto = Get-PortFromUser -Servicio 'IIS' -Default $(if ($actual) { $actual } else { 8080 })
            Set-IISPort -Puerto $puerto
        }
        'Apache' {
            $actual = Get-ServiceConfiguredPort -Servicio 'Apache'
            $puerto = Get-PortFromUser -Servicio 'Apache' -Default $(if ($actual) { $actual } else { 8081 })
            Configure-Apache -Puerto $puerto
        }
        'Nginx' {
            $actual = Get-ServiceConfiguredPort -Servicio 'Nginx'
            $puerto = Get-PortFromUser -Servicio 'Nginx' -Default $(if ($actual) { $actual } else { 8082 })
            Set-NginxConfig -Puerto $puerto
            Restart-NginxManaged -Puerto $puerto -PuertoAnterior $(if ($actual) { $actual } else { 0 })
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
        if (-not $ok) {
            Write-Warn 'Ingresa solo numeros.'
        }
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
        Write-Host "[ERR]  $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ''
    Read-Host 'Presiona ENTER para volver al menu' | Out-Null
}
