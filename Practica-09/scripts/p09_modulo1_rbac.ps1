#Requires -RunAsAdministrator
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module ActiveDirectory

function Write-Ok   ($msg) { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function Write-Warn ($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Err  ($msg) { Write-Host "  [XX]  $msg" -ForegroundColor Red    }
function Write-Info ($msg) { Write-Host "  [--]  $msg" -ForegroundColor Cyan   }
function Write-Step ($msg) { Write-Host ""             ; Write-Host "  >>> $msg" -ForegroundColor Magenta }

$Domain      = (Get-ADDomain).DistinguishedName
$DomainDNS   = (Get-ADDomain).DNSRoot
$NetBIOSName = (Get-ADDomain).NetBIOSName
$OUCuates    = "OU=Cuates,$Domain"
$OUNoCuates  = "OU=NoCuates,$Domain"
$SecurePass  = ConvertTo-SecureString "Admin@Practica09!" -AsPlainText -Force

$Users = @(
    @{ Name = "admin_identidad"; Full = "Operador IAM";        Desc = "Rol 1 - Gestion ciclo de vida usuarios" }
    @{ Name = "admin_storage";   Full = "Operador Storage";    Desc = "Rol 2 - Cuotas FSRM" }
    @{ Name = "admin_politicas"; Full = "Admin GPO Compliance"; Desc = "Rol 3 - GPO y FGPP" }
    @{ Name = "admin_auditoria"; Full = "Auditor Seguridad";   Desc = "Rol 4 - Solo lectura logs" }
)

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   MODULO 1 - Delegacion de Control y RBAC"                  -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1]  Crear OUs (Cuates y NoCuates) si no existen"
    Write-Host "  [2]  Crear los 4 usuarios de administracion delegada"
    Write-Host "  [3]  ACL Rol 1 (admin_identidad) - Reset Password + atributos"
    Write-Host "  [4]  ACL Rol 2 (admin_storage)   - DENEGAR Reset Password"
    Write-Host "  [5]  ACL Rol 3 (admin_politicas) - Lectura dominio + GPO"
    Write-Host "  [6]  ACL Rol 4 (admin_auditoria) - Solo lectura"
    Write-Host "  [7]  Ejecutar TODO (pasos 1 al 6)"
    Write-Host "  [8]  Mostrar resumen de usuarios delegados"
    Write-Host "  [0]  Volver al menu principal"
    Write-Host ""
}

function New-RequiredOUs {
    Write-Step "Verificando/creando Unidades Organizativas..."
    foreach ($ou in @("Cuates","NoCuates")) {
        $ouDN = "OU=$ou,$Domain"
        try {
            Get-ADOrganizationalUnit -Identity $ouDN | Out-Null
            Write-Ok "OU '$ou' ya existe."
        } catch {
            New-ADOrganizationalUnit -Name $ou -Path $Domain -ProtectedFromAccidentalDeletion $false
            Write-Ok "OU '$ou' creada."
        }
    }
}

function New-DelegatedUsers {
    Write-Step "Creando usuarios de administracion delegada..."
    foreach ($u in $Users) {
        try {
            Get-ADUser -Identity $u.Name | Out-Null
            Write-Warn "Usuario '$($u.Name)' ya existe. Omitiendo."
        } catch {
            New-ADUser `
                -Name              $u.Full `
                -SamAccountName    $u.Name `
                -UserPrincipalName "$($u.Name)@$DomainDNS" `
                -Description       $u.Desc `
                -Path              $OUCuates `
                -AccountPassword   $SecurePass `
                -Enabled           $true `
                -PasswordNeverExpires $true
            Write-Ok "Usuario '$($u.Name)' creado."
        }
    }
}

function Set-ACL-Rol1 {
    Write-Step "ACL Rol 1 (admin_identidad) - permisos en Cuates y NoCuates..."
    $user = "$NetBIOSName\admin_identidad"
    foreach ($ou in @($OUCuates, $OUNoCuates)) {
        dsacls $ou /G "${user}:CCDC;user"                         | Out-Null
        dsacls $ou /G "${user}:CA;Reset Password;user"            | Out-Null
        dsacls $ou /G "${user}:WP;lockoutTime;user"               | Out-Null
        dsacls $ou /G "${user}:WP;telephoneNumber;user"           | Out-Null
        dsacls $ou /G "${user}:WP;physicalDeliveryOfficeName;user" | Out-Null
        dsacls $ou /G "${user}:WP;mail;user"                      | Out-Null
        Write-Ok "Rol 1 applied en: $ou"
    }
    Write-Info "Restriccion: NO puede modificar grupos Domain Admin."
}

function Set-ACL-Rol2 {
    Write-Step "ACL Rol 2 (admin_storage) - DENEGAR Reset Password..."
    $user = "$NetBIOSName\admin_storage"
    foreach ($ou in @($OUCuates, $OUNoCuates)) {
        dsacls $ou /D "${user}:CA;Reset Password;user" | Out-Null
        Write-Ok "DENEGADO Reset Password para admin_storage en: $ou"
    }
    Write-Info "admin_storage solo gestiona FSRM (cuotas, apantallamiento)."
}

function Set-ACL-Rol3 {
    Write-Step "ACL Rol 3 (admin_politicas) - Lectura dominio + GPO..."
    $user = "$NetBIOSName\admin_politicas"
    dsacls $Domain /G "${user}:GR" | Out-Null
    Write-Ok "Lectura global en dominio aplicada a admin_politicas."
    try {
        Add-ADGroupMember -Identity "Group Policy Creator Owners" -Members "admin_politicas"
        Write-Ok "admin_politicas agregado a 'Group Policy Creator Owners'."
    } catch {
        Write-Warn "No se pudo agregar al grupo GPO: $_"
    }
}

function Set-ACL-Rol4 {
    Write-Step "ACL Rol 4 (admin_auditoria) - Solo lectura..."
    $user = "$NetBIOSName\admin_auditoria"
    dsacls $Domain /G "${user}:GR" | Out-Null
    Write-Ok "Lectura global en dominio aplicada a admin_auditoria."
    try {
        Add-ADGroupMember -Identity "Event Log Readers" -Members "admin_auditoria" -ErrorAction Stop
        Write-Ok "admin_auditoria agregado a 'Event Log Readers' de dominio."
    } catch {
        try {
            Add-LocalGroupMember -Group "Event Log Readers" -Member "$NetBIOSName\admin_auditoria" -ErrorAction SilentlyContinue
            Write-Ok "admin_auditoria agregado a local 'Event Log Readers'."
        } catch {
            Write-Warn "Ejecuta esto en el DC para agregar a Event Log Readers: $_"
        }
    }
    Write-Info "Restriccion: estrictamente de solo lectura."
}

function Set-ConsoleLogonRights {
    Write-Step "Configurando permisos de inicio de sesion local y RDP en el DC..."
    
    # Obtener SIDs de los usuarios delegados
    $sids = @()
    foreach ($u in $Users) {
        try {
            $sid = (Get-ADUser -Identity $u.Name).SID.Value
            $sids += $sid
        } catch {
            Write-Warn "No se pudo obtener SID para $($u.Name)"
        }
    }

    if ($sids.Count -eq 0) {
        Write-Warn "No hay usuarios delegados disponibles para asignar derechos."
        return
    }

    $tempInf = "$env:TEMP\secedit_logon.inf"
    $dbFile  = "$env:TEMP\secedit_logon.sdb"

    # Exportar directivas de derechos de usuario
    secedit /export /cfg $tempInf /areas USER_RIGHTS | Out-Null

    if (Test-Path $tempInf) {
        $cfgText = Get-Content $tempInf -Raw
        $modified = $false

        # SeInteractiveLogonRight (Local) y SeRemoteInteractiveLogonRight (RDP)
        foreach ($right in @("SeInteractiveLogonRight", "SeRemoteInteractiveLogonRight")) {
            if ($cfgText -match "$right\s*=\s*(.*)") {
                $line = $matches[0].Trim()
                $updatedLine = $line
                foreach ($sid in $sids) {
                    if ($updatedLine -notmatch [regex]::Escape($sid)) {
                        $updatedLine += ",*$sid"
                        $modified = $true
                    }
                }
                if ($modified) {
                    $cfgText = $cfgText -replace [regex]::Escape($line), $updatedLine
                }
            } else {
                $newLine = "$right = " + ($sids | ForEach-Object { "*$_" } -join ",")
                $cfgText = $cfgText -replace "\[Privilege Rights\]", "[Privilege Rights]`r`n$newLine"
                $modified = $true
            }
        }

        if ($modified) {
            $cfgText | Out-File $tempInf -Encoding utf8
            secedit /configure /db $dbFile /cfg $tempInf /areas USER_RIGHTS | Out-Null
            gpupdate /force | Out-Null
            Write-Ok "Derechos de inicio de sesion local y RDP concedidos a usuarios delegados."
        } else {
            Write-Ok "Los usuarios delegados ya cuentan con derechos de inicio de sesion."
        }
    } else {
        Write-Warn "No se pudo exportar la configuracion de seguridad con secedit."
    }
}

function Show-UserSummary {
    Write-Step "Resumen de usuarios delegados:"
    Write-Host ""
    foreach ($u in $Users) {
        try {
            $adUser = Get-ADUser -Identity $u.Name -Properties Description, Enabled
            Write-Host "  Usuario     : " -NoNewline -ForegroundColor White
            Write-Host $adUser.SamAccountName -ForegroundColor Green
            Write-Host "  Descripcion : $($adUser.Description)"
            Write-Host "  Habilitado  : $($adUser.Enabled)"
            Write-Host "  ----------------------------------------------------" -ForegroundColor DarkGray
        } catch {
            Write-Warn "No encontrado en AD: $($u.Name)"
        }
    }
}

$exit = $false
while (-not $exit) {
    Show-Menu
    $op = Read-Host "  Selecciona"
    switch ($op.Trim()) {
        "1" { New-RequiredOUs }
        "2" { New-DelegatedUsers; Set-ConsoleLogonRights }
        "3" { Set-ACL-Rol1 }
        "4" { Set-ACL-Rol2 }
        "5" { Set-ACL-Rol3 }
        "6" { Set-ACL-Rol4 }
        "7" { New-RequiredOUs; New-DelegatedUsers; Set-ConsoleLogonRights; Set-ACL-Rol1; Set-ACL-Rol2; Set-ACL-Rol3; Set-ACL-Rol4; Write-Ok "=== RBAC completado ===" }
        "8" { Show-UserSummary }
        "0" { $exit = $true }
        default { Write-Warn "Opcion invalida."; Start-Sleep -Seconds 1 }
    }
    if (-not $exit) { Write-Host ""; Read-Host "  Enter para continuar" | Out-Null }
}
