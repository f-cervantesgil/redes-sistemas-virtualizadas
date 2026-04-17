# p8_functions_windows.ps1
# Funciones para Practica 08 - Versión Final Corregida

function fn_info { Write-Host "[INFO] $($args)" -ForegroundColor Yellow }
function fn_ok { Write-Host "[OK] $($args)" -ForegroundColor Green }
function fn_err { Write-Host "[ERROR] $($args)" -ForegroundColor Red }

function fn_check_admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        fn_err "Por favor, ejecuta PowerShell como Administrador."
        Start-Sleep 5
        exit
    }
}

function fn_install_features {
    fn_info "Instalando Roles de Servidor (AD DS, FSRM, GPMC)..."
    Install-WindowsFeature AD-Domain-Services, FS-Resource-Manager, GPMC, RSAT-AD-PowerShell -IncludeManagementTools
    fn_ok "Instalacion de roles completada."
}

function fn_promote_dc {
    fn_info "Iniciando Promocion a Controlador de Dominio (redes.local)..."
    fn_info "IMPORTANTE: El sistema se REINICIARA solo al terminar."
    Start-Sleep -Seconds 3
    Import-Module ADDSDeployment
    Install-ADDSForest -DomainName "redes.local" -InstallDns -Force
}

function fn_check_dc {
    try {
        $dom = Get-ADDomain -ErrorAction Stop
        return $true
    } catch {
        fn_err "Dominio no detectado. Debes promocionar el servidor a DC primero."
        return $false
    }
}

function fn_setup_ad_structure {
    return if (-not (fn_check_dc))
    fn_info "Configurando UOs y Grupos..."
    $Domain = (Get-ADDomain).DistinguishedName
    
    foreach ($uo in @("Cuates", "No Cuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$uo'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $uo -Path $Domain -ProtectedFromAccidentalDeletion $false
        }
    }
    foreach ($g in @("G_Cuates", "G_NoCuates")) {
        if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
            $path = if ($g -match "Cuates") { "OU=Cuates,$Domain" } else { "OU=No Cuates,$Domain" }
            New-ADGroup -Name $g -GroupScope Global -Path $path
        }
    }
    fn_ok "Estructura AD lista."
}

function Get-LogonHoursBytes {
    param([int]$start, [int]$end)
    $bytes = New-Object Byte[] 21
    for ($d=0;$d -lt 7;$d++) {
        for ($h=0;$h -lt 24;$h++) {
            $isOk = if ($start -lt $end) { $h -ge $start -and $h -lt $end } else { $h -ge $start -or $h -lt $end }
            if ($isOk) {
                $bit = ($d * 24) + $h
                $bytes[[Math]::Floor($bit/8)] = $bytes[[Math]::Floor($bit/8)] -bor (1 -shl ($bit % 8))
            }
        }
    }
    return $bytes
}

function fn_import_users_csv {
    $csv = "$ScriptDir\..\..\data\usuarios.csv"
    if (-not (Test-Path $csv)) { fn_err "No hay CSV en $csv"; return }
    $users = Import-Csv $csv
    $hC = Get-LogonHoursBytes 8 15
    $hN = Get-LogonHoursBytes 15 2
    $Domain = (Get-ADDomain).DistinguishedName

    foreach ($u in $users) {
        $tipo = $u.Tipo.Trim()
        $uoName = if ($tipo -eq "Cuates") { "Cuates" } else { "No Cuates" }
        $group = if ($tipo -eq "Cuates") { "G_Cuates" } else { "G_NoCuates" }
        $hours = if ($tipo -eq "Cuates") { $hC } else { $hN }

        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Username)'")) {
            $pass = ConvertTo-SecureString $u.Password -AsPlainText -Force
            # Crear usuario paso a paso para evitar errores de parametros
            $newUser = New-ADUser -Name $u.Nombre -SamAccountName $u.Username -AccountPassword $pass -Enabled $true -Path "OU=$uoName,$Domain" -PassThru
            # Aplicar LogonHours por separado para mayor estabilidad
            Set-ADUser -Identity $newUser -LogonHours $hours
            Add-ADGroupMember -Identity $group -Members $u.Username
            fn_ok "Usuario $($u.Username) creado y configurado."
        }
    }
}

function fn_setup_fsrm_and_shares {
    fn_info "Configurando FSRM y Carpetas..."
    Import-Module FileServerResourceManager

    $paths = @{ "Documentos_Cuates"="C:\Users\Public\Cuates_Docs"; "Documentos_NoCuates"="C:\Users\Public\NoCuates_Docs" }
    foreach ($name in $paths.Keys) {
        $path = $paths[$name]
        if (-not (Test-Path $path)) { New-Item $path -ItemType Directory -Force | Out-Null }
        if (-not (Get-SmbShare -Name $name -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name $name -Path $path -FullAccess "Everyone" | Out-Null
        }
        icacls $path /inheritance:r | Out-Null
        $grp = if ($name -match "Cuates") { "G_Cuates" } else { "G_NoCuates" }
        icacls $path /grant "${grp}:(OI)(CI)F" /grant "Administrators:(OI)(CI)F" | Out-Null
    }

    if (-not (Get-FsrmQuota -Path "C:\Users\Public\Cuates_Docs" -ErrorAction SilentlyContinue)) {
        New-FsrmQuota -Path "C:\Users\Public\Cuates_Docs" -Size 10MB | Out-Null
        New-FsrmQuota -Path "C:\Users\Public\NoCuates_Docs" -Size 5MB | Out-Null
    }
    if (-not (Get-FsrmFileGroup -Name "Prohibidos_P8" -ErrorAction SilentlyContinue)) {
        New-FsrmFileGroup -Name "Prohibidos_P8" -IncludePattern @("*.mp3", "*.mp4", "*.exe", "*.msi") | Out-Null
    }
    if (-not (Get-FsrmFileScreen -Path "C:\Users\Public" -ErrorAction SilentlyContinue)) {
        New-FsrmFileScreen -Path "C:\Users\Public" -IncludeGroup "Prohibidos_P8" -Active | Out-Null
    }
    fn_ok "FSRM y Carpetas al 100%."
}

function fn_setup_applocker {
    fn_info "Configurando AppLocker..."
    Set-Service AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service AppIDSvc -ErrorAction SilentlyContinue
    $path = "C:\Windows\System32\notepad.exe"
    $policy = Get-AppLockerFileInformation -Path $path | New-AppLockerPolicy -RuleType Hash -User G_NoCuates -Deny
    Set-AppLockerPolicy -PolicyObject $policy -ErrorAction SilentlyContinue
    fn_ok "Notepad bloqueado por Hash para No Cuates."
}

function fn_join_domain {
    $dom = Read-Host "Nombre del dominio (ej: redes.local)"
    fn_info "Uniendose a $dom... Usa Administrator@redes.local"
    try {
        Add-Computer -DomainName $dom -Restart -Force
    } catch {
        fn_err "Error en union: $($_.Exception.Message)"
    }
}
