#Requires -RunAsAdministrator
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module ActiveDirectory

function Write-Ok   ($msg) { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function Write-Warn ($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Info ($msg) { Write-Host "  [--]  $msg" -ForegroundColor Cyan   }
function Write-Step ($msg) { Write-Host ""; Write-Host "  >>> $msg" -ForegroundColor Magenta }

$Domain = (Get-ADDomain).DistinguishedName

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   MODULO 2 - FGPP + Auditoria de Eventos"                   -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1]  Crear FGPP para admins (minimo 12 caracteres)"
    Write-Host "  [2]  Crear FGPP para usuarios estandar (minimo 8 caracteres)"
    Write-Host "  [3]  Aplicar FGPP a grupos correspondientes"
    Write-Host "  [4]  Habilitar Auditoria (exito y fallo)"
    Write-Host "  [5]  Ver estado actual de auditoria"
    Write-Host "  [6]  Ver FGPPs configuradas en el dominio"
    Write-Host "  [7]  Ejecutar TODO (pasos 1 al 4)"
    Write-Host "  [0]  Volver"
    Write-Host ""
}

function New-FGPPAdmin {
    Write-Step "FGPP para administradores (minimo 12 caracteres)..."
    $name = "PSO-Admins-P09"
    $exists = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
    $params = @{
        MinPasswordLength        = 12
        ComplexityEnabled        = $true
        ReversibleEncryptionEnabled = $false
        MaxPasswordAge           = ([timespan]"60.00:00:00")
        MinPasswordAge           = ([timespan]"1.00:00:00")
        PasswordHistoryCount     = 10
        LockoutThreshold         = 5
        LockoutDuration          = ([timespan]"0.00:30:00")
        LockoutObservationWindow = ([timespan]"0.00:30:00")
        Precedence               = 10
    }
    if ($exists) {
        Set-ADFineGrainedPasswordPolicy -Identity $name @params
        Write-Ok "PSO-Admins-P09 actualizada (min 12 chars)."
    } else {
        New-ADFineGrainedPasswordPolicy -Name $name -DisplayName "PSO Admins P09" @params
        Write-Ok "PSO-Admins-P09 creada (min 12 chars, precedencia 10)."
    }
}

function New-FGPPStandard {
    Write-Step "FGPP para usuarios estandar (minimo 8 caracteres)..."
    $name = "PSO-Usuarios-P09"
    $exists = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
    $params = @{
        MinPasswordLength        = 8
        ComplexityEnabled        = $true
        ReversibleEncryptionEnabled = $false
        MaxPasswordAge           = ([timespan]"90.00:00:00")
        MinPasswordAge           = ([timespan]"1.00:00:00")
        PasswordHistoryCount     = 5
        LockoutThreshold         = 5
        LockoutDuration          = ([timespan]"0.00:30:00")
        LockoutObservationWindow = ([timespan]"0.00:30:00")
        Precedence               = 20
    }
    if ($exists) {
        Set-ADFineGrainedPasswordPolicy -Identity $name @params
        Write-Ok "PSO-Usuarios-P09 actualizada (min 8 chars)."
    } else {
        New-ADFineGrainedPasswordPolicy -Name $name -DisplayName "PSO Usuarios P09" @params
        Write-Ok "PSO-Usuarios-P09 creada (min 8 chars, precedencia 20)."
    }
}

function Set-FGPPSubjects {
    Write-Step "Aplicando FGPPs a grupos..."
    $grpAdmin = "GrupoAdminsP09"
    try { Get-ADGroup -Identity $grpAdmin | Out-Null; Write-Ok "Grupo '$grpAdmin' ya existe." }
    catch { New-ADGroup -Name $grpAdmin -GroupScope Global -GroupCategory Security -Path $Domain; Write-Ok "Grupo '$grpAdmin' creado." }

    foreach ($u in @("admin_identidad","admin_storage","admin_politicas","admin_auditoria")) {
        try { Add-ADGroupMember -Identity $grpAdmin -Members $u -ErrorAction SilentlyContinue; Write-Ok "  $u -> $grpAdmin" }
        catch { Write-Warn "  No se pudo agregar $u" }
    }

    try { Add-ADFineGrainedPasswordPolicySubject -Identity "PSO-Admins-P09" -Subjects $grpAdmin; Write-Ok "PSO-Admins-P09 aplicada a $grpAdmin." }
    catch { Write-Warn "PSO-Admins-P09 ya aplicada o error: $_" }

    # Para usuarios estandar (grupos G_Cuates y G_NoCuates de P08)
    foreach ($grpName in @("G_Cuates", "G_NoCuates")) {
        try {
            $gc = Get-ADGroup -Filter "Name -eq '$grpName'" -ErrorAction SilentlyContinue
            if (-not $gc) {
                $ouName = if ($grpName -eq "G_Cuates") { "Cuates" } else { "NoCuates" }
                $ouPath = "OU=$ouName,$Domain"
                New-ADGroup -Name $grpName -GroupScope Global -GroupCategory Security -Path $ouPath
                Write-Ok "Grupo $grpName creado."
            }
            Add-ADFineGrainedPasswordPolicySubject -Identity "PSO-Usuarios-P09" -Subjects $grpName
            Write-Ok "PSO-Usuarios-P09 aplicada a $grpName."
        } catch { Write-Warn "PSO-Usuarios-P09 en $grpName: $_" }
    }
}

function Enable-Auditing {
    Write-Step "Habilitando auditoria (exito y fallo)..."

    # Usar GUIDs para que funcione en Windows en cualquier idioma (ES/EN)
    # {GUID} = subcategoria especifica de auditoria
    $subcats = @(
        @{ Name = "Logon";                    GUID = "{0cce9215-69ae-11d9-bed3-505054503030}" }
        @{ Name = "Logoff";                   GUID = "{0cce9216-69ae-11d9-bed3-505054503030}" }
        @{ Name = "Account Lockout";          GUID = "{0cce9217-69ae-11d9-bed3-505054503030}" }
        @{ Name = "Object Access";            GUID = "{0cce9222-69ae-11d9-bed3-505054503030}" }
        @{ Name = "Account Management";       GUID = "{0cce9227-69ae-11d9-bed3-505054503030}" }
        @{ Name = "Policy Change";            GUID = "{0cce922f-69ae-11d9-bed3-505054503030}" }
        @{ Name = "Directory Service Access"; GUID = "{0cce923b-69ae-11d9-bed3-505054503030}" }
        @{ Name = "Credential Validation";    GUID = "{0cce923f-69ae-11d9-bed3-505054503030}" }
    )

    foreach ($s in $subcats) {
        $result = auditpol /set /subcategory:"$($s.GUID)" /success:enable /failure:enable 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Auditoria habilitada: $($s.Name)"
        } else {
            Write-Warn "No se pudo habilitar: $($s.Name) - $result"
        }
    }
    Write-Info "Verificar con: auditpol /get /category:*"
}

function Show-AuditStatus {
    Write-Step "Estado de auditoria actual:"
    Write-Host ""
    auditpol /get /category:"Logon/Logoff","Object Access","Account Management" 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

function Show-FGPPs {
    Write-Step "FGPPs configuradas en el dominio:"
    Write-Host ""
    $list = Get-ADFineGrainedPasswordPolicy -Filter * | Sort-Object Precedence
    if (-not $list) { Write-Warn "No hay FGPPs configuradas aun."; return }
    foreach ($p in $list) {
        Write-Host "  Nombre       : " -NoNewline -ForegroundColor White
        Write-Host $p.Name -ForegroundColor Green
        Write-Host "  Precedencia  : $($p.Precedence)"
        Write-Host "  Min chars    : $($p.MinPasswordLength)"
        Write-Host "  Bloqueo      : $($p.LockoutThreshold) intentos / $($p.LockoutDuration.TotalMinutes) min"
        $subs = Get-ADFineGrainedPasswordPolicySubject -Identity $p.Name -ErrorAction SilentlyContinue
        if ($subs) { Write-Host "  Aplicada a   : $($subs.Name -join ', ')" }
        Write-Host "  ----------------------------------------------------" -ForegroundColor DarkGray
    }
}

$exit = $false
while (-not $exit) {
    Show-Menu
    $op = Read-Host "  Selecciona"
    switch ($op.Trim()) {
        "1" { New-FGPPAdmin }
        "2" { New-FGPPStandard }
        "3" { Set-FGPPSubjects }
        "4" { Enable-Auditing }
        "5" { Show-AuditStatus }
        "6" { Show-FGPPs }
        "7" { New-FGPPAdmin; New-FGPPStandard; Set-FGPPSubjects; Enable-Auditing; Write-Ok "=== FGPP y Auditoria completados ===" }
        "0" { $exit = $true }
        default { Write-Warn "Opcion invalida."; Start-Sleep -Seconds 1 }
    }
    if (-not $exit) { Write-Host ""; Read-Host "  Enter para continuar" | Out-Null }
}
