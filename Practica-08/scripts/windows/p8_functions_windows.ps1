# p8_functions_windows.ps1
# Funciones para Practica 08 - GPO, FSRM y AppLocker
# NOTA: Archivo en ASCII puro para compatibilidad con PowerShell en WS2022

function fn_info { Write-Host "[INFO] $($args)" -ForegroundColor Yellow }
function fn_ok   { Write-Host "[OK]   $($args)" -ForegroundColor Green  }
function fn_err  { Write-Host "[ERROR] $($args)" -ForegroundColor Red   }

# =============================================================================
# 1. VERIFICAR ADMIN
# =============================================================================
function fn_check_admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        fn_err "Ejecuta PowerShell como Administrador."
        Start-Sleep 5
        exit
    }
}

# =============================================================================
# 2. INSTALAR FEATURES
# =============================================================================
function fn_install_features {
    fn_info "Instalando caracteristicas: AD DS, RSAT, FSRM, GPMC..."
    $features = @("AD-Domain-Services","RSAT-AD-PowerShell","FS-Resource-Manager","GPMC")
    foreach ($f in $features) {
        if (-not (Get-WindowsFeature $f -ErrorAction SilentlyContinue).Installed) {
            fn_info "Instalando $f ..."
            Install-WindowsFeature $f -IncludeManagementTools | Out-Null
        }
    }
    fn_ok "Caracteristicas listas."
}

# =============================================================================
# 3. VERIFICAR DC
# =============================================================================
function fn_check_dc {
    if ((Get-WindowsFeature AD-Domain-Services).InstallState -ne "Installed") {
        fn_err "AD DS no instalado. Usa la opcion 1 primero."
        return $false
    }
    try {
        $null = Get-ADDomain -ErrorAction Stop
        return $true
    } catch {
        fn_err "No se detecto un dominio activo. Promueve el servidor a DC primero."
        return $false
    }
}

# =============================================================================
# 4. UNION AL DOMINIO - WINDOWS (Add-Computer)
# =============================================================================
function fn_join_domain_windows {
    param(
        [string]$DomainName = "",
        [string]$OUPath     = "",
        [string]$AdminUser  = ""
    )

    if ($DomainName -eq "") { $DomainName = Read-Host "Nombre del dominio (ej: redes.local)" }
    if ($AdminUser  -eq "") { $AdminUser  = Read-Host "Usuario Administrador del dominio" }

    fn_info "Solicitando credenciales para el dominio '$DomainName'..."
    $credential = Get-Credential -UserName "$AdminUser@$DomainName" -Message "Contrasena del administrador de dominio"

    try {
        $params = @{
            DomainName  = $DomainName
            Credential  = $credential
            Restart     = $false
            Force       = $true
            ErrorAction = "Stop"
        }
        if ($OUPath -ne "") { $params["OUPath"] = $OUPath }
        Add-Computer @params
        fn_ok "Equipo unido a '$DomainName'. Reinicia el equipo para aplicar cambios."
    } catch {
        fn_err "Error al unirse al dominio: $($_.Exception.Message)"
    }
}

# =============================================================================
# 5. ESTRUCTURA AD (UOs y Grupos)
# =============================================================================
function fn_setup_ad_structure {
    fn_info "Creando UOs: Cuates y No Cuates, y sus grupos..."
    Import-Module ActiveDirectory
    $Domain = (Get-ADDomain).DistinguishedName

    foreach ($uoName in @("Cuates","No Cuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$uoName'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $uoName -Path $Domain -ProtectedFromAccidentalDeletion $false
            fn_ok "UO '$uoName' creada."
        } else {
            fn_info "UO '$uoName' ya existe."
        }
    }

    $groupDefs = @(
        @{ Name = "G_Cuates";   OU = "Cuates"    },
        @{ Name = "G_NoCuates"; OU = "No Cuates" }
    )
    foreach ($gd in $groupDefs) {
        if (-not (Get-ADGroup -Filter "Name -eq '$($gd.Name)'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $gd.Name -GroupScope Global -Path "OU=$($gd.OU),$Domain"
            fn_ok "Grupo '$($gd.Name)' creado en UO '$($gd.OU)'."
        } else {
            fn_info "Grupo '$($gd.Name)' ya existe."
        }
    }
}

# =============================================================================
# 6. CALCULAR LOGON HOURS (21 bytes, UTC)
# =============================================================================
function Get-LogonHoursBytes {
    param([int]$startHour, [int]$endHour)
    $offset = [System.TimeZone]::CurrentTimeZone.GetUtcOffset([DateTime]::Now).Hours
    $bytes  = New-Object Byte[] 21

    for ($day = 0; $day -lt 7; $day++) {
        for ($localHour = 0; $localHour -lt 24; $localHour++) {
            if ($startHour -lt $endHour) {
                $isAllowed = ($localHour -ge $startHour -and $localHour -lt $endHour)
            } else {
                $isAllowed = ($localHour -ge $startHour -or $localHour -lt $endHour)
            }
            if ($isAllowed) {
                $utcHour   = ($localHour - $offset + 24) % 24
                $bitIndex  = ($day * 24) + $utcHour
                $byteIndex = [Math]::Floor($bitIndex / 8)
                $bitPos    = $bitIndex % 8
                $bytes[$byteIndex] = $bytes[$byteIndex] -bor ([byte](1 -shl $bitPos))
            }
        }
    }
    return $bytes
}

# =============================================================================
# 7. IMPORTAR USUARIOS DESDE CSV
#    Columnas: Nombre, Username, Password, Tipo  (Tipo = Cuates | NoCuates)
# =============================================================================
function fn_import_users_csv {
    param([string]$csvPath)
    if (-not (Test-Path $csvPath)) {
        fn_err "No se encontro el CSV en: $csvPath"
        return
    }

    fn_info "Importando usuarios desde $csvPath ..."
    Import-Module ActiveDirectory
    $users  = Import-Csv $csvPath
    $Domain = (Get-ADDomain).DistinguishedName

    $hoursCuates   = Get-LogonHoursBytes 8  15
    $hoursNoCuates = Get-LogonHoursBytes 15 2

    foreach ($u in $users) {
        $tipo    = $u.Tipo.Trim()
        $esCuate = ($tipo -ieq "Cuates")
        $uo      = if ($esCuate) { "Cuates" } else { "No Cuates" }
        $group   = if ($esCuate) { "G_Cuates" } else { "G_NoCuates" }
        $logonHours = if ($esCuate) { $hoursCuates } else { $hoursNoCuates }
        $homePath   = "C:\Users\$($u.Username)"

        if (-not (Test-Path $homePath)) {
            New-Item -Path $homePath -ItemType Directory -Force | Out-Null
        }

        $exists = Get-ADUser -Filter "SamAccountName -eq '$($u.Username)'" -ErrorAction SilentlyContinue
        if (-not $exists) {
            $params = @{
                Name              = $u.Nombre
                SamAccountName    = $u.Username
                UserPrincipalName = "$($u.Username)@$((Get-ADDomain).DNSRoot)"
                AccountPassword   = (ConvertTo-SecureString $u.Password -AsPlainText -Force)
                Enabled           = $true
                Path              = "OU=$uo,$Domain"
                LogonHours        = $logonHours
                HomeDirectory     = $homePath
                HomeDrive         = "H:"
                Description       = "P8-$tipo"
            }
            New-ADUser @params
            fn_ok "Usuario '$($u.Username)' creado en UO=$uo"
        } else {
            Set-ADUser -Identity $u.Username -LogonHours $logonHours -HomeDirectory $homePath -HomeDrive "H:"
            fn_info "Usuario '$($u.Username)' ya existe, horario y home actualizados."
        }

        try {
            Add-ADGroupMember -Identity $group -Members $u.Username -ErrorAction Stop
        } catch {
            fn_info "Usuario '$($u.Username)' ya es miembro de '$group'."
        }
    }
    fn_ok "Importacion de usuarios completada."
}

# =============================================================================
# 8. GPO - Forzar cierre de sesion al expirar horario
#    Clave: HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters
#           EnableForcedLogOff = 1
# =============================================================================
function fn_setup_logon_gpo {
    fn_info "Configurando GPO para forzar cierre de sesion al expirar horario..."
    Import-Module GroupPolicy -ErrorAction Stop

    $gpoName = "P8_LogonRestrictions"
    $domain  = Get-ADDomain

    if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
        New-GPO -Name $gpoName -Comment "P8: Forzar cierre de sesion segun horario AD" | Out-Null
        fn_ok "GPO '$gpoName' creada."
    } else {
        fn_info "GPO '$gpoName' ya existe."
    }

    try {
        New-GPLink -Name $gpoName -Target $domain.DistinguishedName -LinkEnabled Yes -ErrorAction Stop | Out-Null
        fn_ok "GPO vinculada al dominio '$($domain.DNSRoot)'."
    } catch {
        fn_info "GPO ya estaba vinculada."
    }

    Set-GPRegistryValue `
        -Name      $gpoName `
        -Key       "HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" `
        -ValueName "EnableForcedLogOff" `
        -Type      DWord `
        -Value     1 | Out-Null

    fn_ok "Politica 'Cerrar sesion al expirar horario' habilitada en GPO."
    gpupdate /force | Out-Null
    fn_ok "gpupdate /force ejecutado."
}

# =============================================================================
# 9. FSRM - Cuotas por usuario (5MB NoCuates / 10MB Cuates) + Active Screening
# =============================================================================
function fn_setup_fsrm {
    fn_info "Configurando FSRM (Cuotas y Filtros por usuario)..."
    try {
        Import-Module FileServerResourceManager -ErrorAction Stop
    } catch {
        fn_err "Modulo FileServerResourceManager no disponible. Instala la feature FS-Resource-Manager."
        return
    }

    $fgName = "Prohibidos_P8"
    if (-not (Get-FsrmFileGroup -Name $fgName -ErrorAction SilentlyContinue)) {
        New-FsrmFileGroup -Name $fgName -IncludePattern @("*.mp3","*.mp4","*.exe","*.msi") | Out-Null
        fn_ok "Grupo de archivos '$fgName' creado."
    } else {
        fn_info "Grupo '$fgName' ya existe."
    }

    $csvPath = Join-Path $PSScriptRoot "..\..\data\usuarios.csv"
    if (-not (Test-Path $csvPath)) {
        fn_err "No se encontro usuarios.csv. Verifica la ruta: $csvPath"
        return
    }
    $users = Import-Csv $csvPath

    foreach ($u in $users) {
        $tipo    = $u.Tipo.Trim()
        $esCuate = ($tipo -ieq "Cuates")
        $quotaBytes = if ($esCuate) { 10MB } else { 5MB }
        $label      = if ($esCuate) { "10MB (Cuates)" } else { "5MB (No Cuates)" }
        $userHome   = "C:\Users\$($u.Username)"

        if (-not (Test-Path $userHome)) {
            New-Item -Path $userHome -ItemType Directory -Force | Out-Null
        }

        $existingQuota = Get-FsrmQuota -Path $userHome -ErrorAction SilentlyContinue
        if (-not $existingQuota) {
            New-FsrmQuota -Path $userHome -Size $quotaBytes -Description "P8 $label para $($u.Username)" | Out-Null
            fn_ok "Cuota $label aplicada a $userHome"
        } else {
            Set-FsrmQuota -Path $userHome -Size $quotaBytes | Out-Null
            fn_info "Cuota de $userHome actualizada a $label."
        }

        $existingScreen = Get-FsrmFileScreen -Path $userHome -ErrorAction SilentlyContinue
        if (-not $existingScreen) {
            New-FsrmFileScreen -Path $userHome -IncludeGroup $fgName -Active | Out-Null
            fn_ok "Active Screening aplicado en $userHome"
        } else {
            fn_info "File Screen en $userHome ya configurado."
        }
    }
    fn_ok "Configuracion FSRM completada."
}

# =============================================================================
# 10. APPLOCKER
#     G_Cuates   : Permitir Notepad (por Path)
#     G_NoCuates : Bloquear Notepad (por Hash SHA-256)
#     Administradores: Permitir todo
# =============================================================================
function fn_setup_applocker {
    fn_info "Configurando AppLocker para Notepad..."

    Set-Service  AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service AppIDSvc -ErrorAction SilentlyContinue

    $notepadPath = "$env:SystemRoot\System32\notepad.exe"
    if (-not (Test-Path $notepadPath)) {
        fn_err "No se encontro notepad.exe en $notepadPath"
        return
    }

    try {
        $fileInfo = Get-AppLockerFileInformation -Path $notepadPath -ErrorAction Stop
        $hashVal  = $fileInfo.Hash.HashDataString
        $hashLen  = (Get-Item $notepadPath).Length
    } catch {
        fn_err "Error obteniendo info AppLocker de notepad.exe: $($_.Exception.Message)"
        return
    }

    fn_info "Hash SHA-256 de notepad.exe: $hashVal"

    try {
        $sidCuates   = (Get-ADGroup "G_Cuates"   -ErrorAction Stop).SID.Value
        $sidNoCuates = (Get-ADGroup "G_NoCuates" -ErrorAction Stop).SID.Value
    } catch {
        fn_err "No se pudieron obtener los SIDs de los grupos. Ejecuta la opcion 3 y 4 primero."
        return
    }

    # Construir XML de politica AppLocker (solo ASCII)
    $xmlContent  = '<?xml version="1.0" encoding="utf-8"?>' + "`n"
    $xmlContent += '<AppLockerPolicy Version="1">' + "`n"
    $xmlContent += '  <RuleCollection Type="Exe" EnforcementMode="Enforced">' + "`n"

    # Regla 1: Administradores - Permitir todo
    $xmlContent += '    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2"' + "`n"
    $xmlContent += '                  Name="Allow Admins - All files"' + "`n"
    $xmlContent += '                  Description="Administradores pueden ejecutar cualquier archivo"' + "`n"
    $xmlContent += '                  UserOrGroupSid="S-1-5-32-544"' + "`n"
    $xmlContent += '                  Action="Allow">' + "`n"
    $xmlContent += '      <Conditions><FilePathCondition Path="*" /></Conditions>' + "`n"
    $xmlContent += '    </FilePathRule>' + "`n"

    # Regla 2: G_Cuates - Permitir Notepad por Path
    $xmlContent += '    <FilePathRule Id="a2c05e42-4d1b-4e96-9e5f-1b2c3d4e5f60"' + "`n"
    $xmlContent += '                  Name="P8 - Cuates: Permitir Notepad"' + "`n"
    $xmlContent += '                  Description="Grupo Cuates tiene acceso al Bloc de Notas"' + "`n"
    $xmlContent += "                  UserOrGroupSid=`"$sidCuates`"" + "`n"
    $xmlContent += '                  Action="Allow">' + "`n"
    $xmlContent += '      <Conditions><FilePathCondition Path="%SYSTEM32%\notepad.exe" /></Conditions>' + "`n"
    $xmlContent += '    </FilePathRule>' + "`n"

    # Regla 3: G_NoCuates - Bloquear Notepad por Hash
    $xmlContent += '    <FileHashRule Id="b3d16f53-5e2c-4f07-af6a-2c3d4e5f6a71"' + "`n"
    $xmlContent += '                  Name="P8 - NoCuates: Bloquear Notepad por Hash"' + "`n"
    $xmlContent += '                  Description="Bloqueo por Hash SHA-256 resiste renombrado"' + "`n"
    $xmlContent += "                  UserOrGroupSid=`"$sidNoCuates`"" + "`n"
    $xmlContent += '                  Action="Deny">' + "`n"
    $xmlContent += '      <Conditions>' + "`n"
    $xmlContent += '        <FileHashCondition>' + "`n"
    $xmlContent += "          <FileHash Type=`"SHA256`" Data=`"$hashVal`" SourceFileLength=`"$hashLen`" SourceFileName=`"notepad.exe`" />" + "`n"
    $xmlContent += '        </FileHashCondition>' + "`n"
    $xmlContent += '      </Conditions>' + "`n"
    $xmlContent += '    </FileHashRule>' + "`n"

    $xmlContent += '  </RuleCollection>' + "`n"
    $xmlContent += '</AppLockerPolicy>' + "`n"

    $xmlPath = "$env:TEMP\P8_AppLocker.xml"
    [System.IO.File]::WriteAllText($xmlPath, $xmlContent, [System.Text.Encoding]::ASCII)

    try {
        Set-AppLockerPolicy -XmlPolicy $xmlPath -Merge -ErrorAction Stop
        fn_ok "AppLocker configurado correctamente:"
        fn_ok "  G_Cuates   -> Notepad PERMITIDO  (por Path)"
        fn_ok "  G_NoCuates -> Notepad BLOQUEADO  (por Hash SHA-256)"
    } catch {
        fn_err "Error aplicando AppLockerPolicy: $($_.Exception.Message)"
        fn_info "El XML generado esta en: $xmlPath"
    }

    # Intentar vincular a GPO si GPMC disponible
    try {
        $gpoName = "P8_LogonRestrictions"
        $gpo = Get-GPO -Name $gpoName -ErrorAction Stop
        $ldapPath = "LDAP://CN={$($gpo.Id)},CN=Policies,CN=System,$((Get-ADDomain).DistinguishedName)"
        Set-AppLockerPolicy -XmlPolicy $xmlPath -Ldap $ldapPath -ErrorAction Stop
        fn_ok "Politica AppLocker vinculada a GPO '$gpoName'."
    } catch {
        fn_info "Politica AppLocker aplicada localmente (vinculo GPO requiere AD conectado)."
    }
}

# =============================================================================
# 11. VERIFICACION COMPLETA
# =============================================================================
function fn_verificar_p8 {
    fn_info "============ VERIFICACION PRACTICA 8 ============"

    fn_info "--- Cuotas FSRM por usuario ---"
    try {
        Get-FsrmQuota | Select-Object Path,
            @{N="Limite(MB)"; E={[Math]::Round($_.Size/1MB,1)}},
            @{N="Usado(MB)";  E={[Math]::Round($_.Usage/1MB,2)}},
            @{N="Uso(%)";     E={if($_.Size -gt 0){[Math]::Round($_.Usage/$_.Size*100,1)}else{0}}} |
            Format-Table -AutoSize
    } catch {
        fn_err "Error obteniendo cuotas: $($_.Exception.Message)"
    }

    fn_info "--- Logon Hours por usuario P8 ---"
    try {
        $adUsers = Get-ADUser -Filter * -Properties LogonHours,Description |
                   Where-Object { $_.Description -like "P8*" }
        foreach ($au in $adUsers) {
            $ok = ($null -ne $au.LogonHours -and $au.LogonHours.Count -eq 21)
            $st = if ($ok) { "[OK] 21 bytes configurados" } else { "[WARN] Sin horario" }
            Write-Host "  $($au.SamAccountName) | $($au.Description) | $st"
        }
    } catch {
        fn_err "Error leyendo usuarios AD: $($_.Exception.Message)"
    }

    fn_info "--- File Screens activos ---"
    try {
        Get-FsrmFileScreen | Select-Object Path, Active, IncludeGroup | Format-Table -AutoSize
    } catch {
        fn_err "Error leyendo File Screens."
    }

    fn_info "--- Prueba de bloqueo FSRM (escritura .mp3) ---"
    try {
        $firstPath = (Get-FsrmQuota | Select-Object -First 1).Path
        if ($firstPath) {
            $testFile = "$firstPath\test_fsrm.mp3"
            try {
                "test" | Set-Content $testFile -ErrorAction Stop
                Remove-Item $testFile -Force -ErrorAction SilentlyContinue
                fn_err "FSRM NO bloqueo el archivo MP3 en $firstPath"
            } catch {
                fn_ok "FSRM bloqueo correctamente la escritura de .mp3 en $firstPath"
            }
        }
    } catch {
        fn_err "No hay cuotas configuradas aun."
    }

    fn_info "--- Politica AppLocker efectiva ---"
    try {
        $pol = Get-AppLockerPolicy -Effective -Xml
        if ($pol -match "notepad") {
            fn_ok "AppLocker tiene referencias a notepad.exe en la politica activa."
        } else {
            fn_err "AppLocker NO tiene reglas para notepad.exe."
        }
    } catch {
        fn_err "No se pudo leer la politica AppLocker."
    }

    fn_ok "============ FIN VERIFICACION ============"
}

# =============================================================================
# HEADER
# =============================================================================
function fn_show_header {
    Clear-Host
    Write-Host " +============================================================+" -ForegroundColor Blue
    Write-Host " |      GESTION DE RECURSOS Y GOBERNANZA (WINDOWS)            |" -ForegroundColor Blue
    Write-Host " |      Practica 8 - GPO, FSRM y AppLocker                    |" -ForegroundColor Blue
    Write-Host " +============================================================+" -ForegroundColor Blue
    Write-Host ""
}
