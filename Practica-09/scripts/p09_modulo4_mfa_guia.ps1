#Requires -RunAsAdministrator
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module ActiveDirectory

function Write-Ok   ($msg) { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function Write-Warn ($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Info ($msg) { Write-Host "  [--]  $msg" -ForegroundColor Cyan   }
function Write-Step ($msg) { Write-Host ""; Write-Host "  >>> $msg" -ForegroundColor Magenta }
function Write-Guide($msg) { Write-Host "  |  $msg"   -ForegroundColor White   }

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   MODULO 4 - Implementacion MFA (TOTP / Google Auth)"        -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1]  Guia instalacion WinOTP / MultiOTP"
    Write-Host "  [2]  Configurar FGPP bloqueo MFA (3 intentos / 30 min)"
    Write-Host "  [3]  Configurar politica dominio (net accounts)"
    Write-Host "  [4]  Verificar herramientas MFA instaladas"
    Write-Host "  [5]  Comandos de verificacion rapida"
    Write-Host "  [6]  Ver cuentas bloqueadas en AD"
    Write-Host "  [7]  Desbloquear cuenta manualmente"
    Write-Host "  [0]  Volver"
    Write-Host ""
}

function Show-WinOTPGuide {
    Clear-Host
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "   GUIA: Instalar MFA con TOTP en Windows Server"             -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "  OPCION A: MultiOTP (recomendada para laboratorio)" -ForegroundColor Cyan
    Write-Host ""
    Write-Guide "1. Descarga desde: https://www.multiotp.net/"
    Write-Guide "   Archivo: multiotp-windows-credential-provider-*.zip"
    Write-Guide ""
    Write-Guide "2. Extrae en C:\multiotp\"
    Write-Guide ""
    Write-Guide "3. Copia las DLL:"
    Write-Guide "   copy C:\multiotp\MultiotpCredentialProvider.dll C:\Windows\System32\"
    Write-Guide "   copy C:\multiotp\MultiotpCredentialProvider.ini C:\Windows\System32\"
    Write-Guide ""
    Write-Guide "4. Registra el Credential Provider:"
    Write-Guide "   regsvr32 C:\Windows\System32\MultiotpCredentialProvider.dll"
    Write-Guide ""
    Write-Guide "5. Configura el secreto en MultiotpCredentialProvider.ini"
    Write-Guide ""

    Write-Host ""
    Write-Host "  OPCION B: WinOTP Authenticator" -ForegroundColor Cyan
    Write-Host ""
    Write-Guide "1. Descarga: https://github.com/winauth/winauth/releases"
    Write-Guide "2. Instala y crea entrada tipo Google Authenticator"
    Write-Guide "3. Usa el secreto Base32 en Google Authenticator del celular"
    Write-Guide ""

    Write-Host ""
    Write-Host "  FLUJO DE AUTENTICACION MFA:" -ForegroundColor Magenta
    Write-Host ""
    Write-Guide "  [usuario + contrasena]"
    Write-Guide "         |"
    Write-Guide "         v"
    Write-Guide "  [LSASS valida contra AD]"
    Write-Guide "         |"
    Write-Guide "         v"
    Write-Guide "  [Credential Provider pide codigo TOTP 6 digitos]"
    Write-Guide "         |"
    Write-Guide "    correcto -> Acceso OK"
    Write-Guide "    3 fallos -> Cuenta bloqueada 30 min (Event 4740)"
    Write-Host ""

    Write-Info "Para el reporte: captura la pantalla de login con el campo TOTP"
    Write-Info "y toma foto del celular con Google Authenticator."
}

function Set-MFALockoutPolicy {
    Write-Step "Configurando FGPP bloqueo MFA (3 intentos / 30 min)..."
    $name = "PSO-MFA-Lockout-P09"
    $exists = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
    $params = @{
        MinPasswordLength        = 12
        ComplexityEnabled        = $true
        ReversibleEncryptionEnabled = $false
        MaxPasswordAge           = ([timespan]"60.00:00:00")
        MinPasswordAge           = ([timespan]"1.00:00:00")
        PasswordHistoryCount     = 10
        LockoutThreshold         = 3
        LockoutDuration          = ([timespan]"0.00:30:00")
        LockoutObservationWindow = ([timespan]"0.00:30:00")
        Precedence               = 5
    }
    if ($exists) {
        Set-ADFineGrainedPasswordPolicy -Identity $name -LockoutThreshold 3 `
            -LockoutDuration ([timespan]"0.00:30:00") `
            -LockoutObservationWindow ([timespan]"0.00:30:00")
        Write-Ok "PSO-MFA-Lockout-P09 actualizada."
    } else {
        New-ADFineGrainedPasswordPolicy -Name $name -DisplayName "PSO MFA Lockout P09" @params
        Write-Ok "PSO-MFA-Lockout-P09 creada."
    }
    Write-Ok "Umbral: 3 intentos. Bloqueo: 30 minutos. Precedencia: 5 (maxima)."

    foreach ($u in @("admin_identidad","admin_storage","admin_politicas","admin_auditoria")) {
        try {
            Add-ADFineGrainedPasswordPolicySubject -Identity $name -Subjects $u -ErrorAction SilentlyContinue
            Write-Ok "  FGPP MFA aplicada a: $u"
        } catch { Write-Warn "  $u ya tiene la FGPP aplicada." }
    }
}

function Set-DomainLockoutGPO {
    Write-Step "Configurando bloqueo de dominio via net accounts..."
    net accounts /lockoutthreshold:3  | Out-Null
    net accounts /lockoutduration:30  | Out-Null
    net accounts /lockoutwindow:30    | Out-Null
    Write-Ok "Umbral: 3 intentos"
    Write-Ok "Duracion bloqueo: 30 minutos"
    Write-Ok "Ventana observacion: 30 minutos"
    Write-Host ""
    Write-Host "  Configuracion actual:" -ForegroundColor Yellow
    net accounts 2>&1 | ForEach-Object { Write-Host "  $_" }
}

function Test-MFATools {
    Write-Step "Verificando herramientas MFA..."
    Write-Host ""

    # NPS
    $nps = Get-WindowsFeature -Name NPAS -ErrorAction SilentlyContinue
    if ($nps -and $nps.InstallState -eq "Installed") {
        Write-Ok "NPS (RADIUS) instalado."
    } else {
        Write-Warn "NPS no instalado."
        Write-Info "Instalar: Add-WindowsFeature NPAS -IncludeManagementTools"
    }

    # MultiOTP
    if (Test-Path "C:\Program Files\multiotp") {
        Write-Ok "MultiOTP encontrado."
    } else { Write-Warn "MultiOTP no detectado en C:\Program Files\multiotp" }

    # DLL en System32
    if (Test-Path "C:\Windows\System32\MultiotpCredentialProvider.dll") {
        Write-Ok "MultiotpCredentialProvider.dll en System32."
    } else { Write-Warn "MultiotpCredentialProvider.dll no encontrada." }

    # Credential Providers registrados
    Write-Host ""
    Write-Host "  Credential Providers en el registro:" -ForegroundColor Yellow
    $cpPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
    Get-ChildItem $cpPath -ErrorAction SilentlyContinue |
        ForEach-Object {
            $n = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue)."(default)"
            Write-Host "  - $($_.PSChildName) : $n"
        }
}

function Show-VerificationCmds {
    Write-Step "Comandos de verificacion MFA:"
    Write-Host ""
    @(
        @("Ver cuentas bloqueadas",          "Search-ADAccount -LockedOut | Select Name, SamAccountName")
        @("FGPP efectiva de un usuario",     "Get-ADUserResultantPasswordPolicy -Identity admin_identidad")
        @("Desbloquear cuenta",              "Unlock-ADAccount -Identity <usuario>")
        @("Eventos login fallido (4625)",    "Get-WinEvent -FilterHashtable @{LogName='Security';Id=4625} -MaxEvents 10")
        @("Eventos bloqueo (4740)",          "Get-WinEvent -FilterHashtable @{LogName='Security';Id=4740} -MaxEvents 10")
        @("Politica bloqueo dominio",        "net accounts")
    ) | ForEach-Object {
        Write-Host "  $_[0]" -ForegroundColor Yellow
        Write-Host "  PS> $_[1]" -ForegroundColor Cyan
        Write-Host ""
    }
}

function Show-LockedAccounts {
    Write-Step "Cuentas bloqueadas actualmente:"
    Write-Host ""
    $locked = Search-ADAccount -LockedOut -ErrorAction SilentlyContinue
    if (-not $locked -or $locked.Count -eq 0) {
        Write-Ok "No hay cuentas bloqueadas."
    } else {
        $locked | Select-Object Name, SamAccountName, LockedOut, LastLogonDate |
            Format-Table -AutoSize | Out-String | Write-Host
    }
}

function Unlock-UserAccount {
    Write-Host ""
    $username = Read-Host "  SamAccountName a desbloquear"
    if ([string]::IsNullOrEmpty($username)) { return }
    try {
        $u = Get-ADUser -Identity $username -Properties LockedOut
        if ($u.LockedOut) {
            Unlock-ADAccount -Identity $username
            Write-Ok "Cuenta '$username' desbloqueada."
        } else {
            Write-Info "La cuenta '$username' no estaba bloqueada."
        }
    } catch { Write-Warn "No encontrado: $username" }
}

$exit = $false
while (-not $exit) {
    Show-Menu
    $op = Read-Host "  Selecciona"
    switch ($op.Trim()) {
        "1" { Show-WinOTPGuide }
        "2" { Set-MFALockoutPolicy }
        "3" { Set-DomainLockoutGPO }
        "4" { Test-MFATools }
        "5" { Show-VerificationCmds }
        "6" { Show-LockedAccounts }
        "7" { Unlock-UserAccount }
        "0" { $exit = $true }
        default { Write-Warn "Opcion invalida."; Start-Sleep -Seconds 1 }
    }
    if (-not $exit) { Write-Host ""; Read-Host "  Enter para continuar" | Out-Null }
}
