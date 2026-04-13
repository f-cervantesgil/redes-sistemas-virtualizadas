# p8_functions_windows.ps1
# Funciones para Practica 08 - GPO, FSRM y AppLocker
# Cubre: Estructura AD, Logon Hours, FSRM, AppLocker, Dominio

function fn_info { Write-Host "[INFO] $($args)" -ForegroundColor Yellow }
function fn_ok   { Write-Host "[OK]   $($args)" -ForegroundColor Green  }
function fn_err  { Write-Host "[ERROR] $($args)" -ForegroundColor Red   }

# ─────────────────────────────────────────────────────────────────────────────
# 1. VERIFICAR ADMIN
# ─────────────────────────────────────────────────────────────────────────────
function fn_check_admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        fn_err "Por favor, ejecuta PowerShell como Administrador."
        Start-Sleep 5
        exit
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. INSTALAR ROL/FEATURES (AD DS, RSAT, FSRM, GPMC)
# ─────────────────────────────────────────────────────────────────────────────
function fn_install_features {
    fn_info "Instalando caracteristicas necesarias (AD DS, RSAT, FSRM, GPMC)..."
    $features = @("AD-Domain-Services", "RSAT-AD-PowerShell", "FS-Resource-Manager", "GPMC")
    foreach ($f in $features) {
        if (-not (Get-WindowsFeature $f -ErrorAction SilentlyContinue).Installed) {
            fn_info "Instalando $f..."
            Install-WindowsFeature $f -IncludeManagementTools | Out-Null
        }
    }
    fn_ok "Caracteristicas listas."
}

function fn_check_dc {
    if ((Get-WindowsFeature AD-Domain-Services).InstallState -ne "Installed") {
        fn_err "El rol AD DS no esta instalado. Instala AD DS y promueve el servidor a DC."
        return $false
    }
    try {
        $null = Get-ADDomain -ErrorAction Stop
        return $true
    } catch {
        fn_err "No se detecto un dominio activo. Promueve el servidor a Controlador de Dominio primero."
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. UNION AL DOMINIO (WINDOWS) — Add-Computer
# ─────────────────────────────────────────────────────────────────────────────
function fn_join_domain_windows {
    param(
        [string]$DomainName   = "",
        [string]$OUPath       = "",
        [string]$AdminUser    = ""
    )

    if ($DomainName -eq "") { $DomainName = Read-Host "Nombre del dominio (ej: redes.local)" }
    if ($AdminUser  -eq "") { $AdminUser  = Read-Host "Usuario Administrador del dominio" }

    fn_info "Solicitando credenciales de dominio para '$AdminUser'..."
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
        fn_ok "Equipo unido al dominio '$DomainName'. Se requerira reinicio para aplicar cambios."
        fn_info "Ejecuta 'Restart-Computer' cuando estes listo."
    } catch {
        fn_err "No se pudo unir al dominio: $($_.Exception.Message)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. ESTRUCTURA AD (UOs y Grupos)
# ─────────────────────────────────────────────────────────────────────────────
function fn_setup_ad_structure {
    fn_info "Configurando estructura de Active Directory (UOs y Grupos)..."
    Import-Module ActiveDirectory

    $Domain = (Get-ADDomain).DistinguishedName

    # Crear UOs Cuates y No Cuates
    foreach ($uoName in @("Cuates", "No Cuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$uoName'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $uoName -Path $Domain -ProtectedFromAccidentalDeletion $false
            fn_ok "UO '$uoName' creada."
        } else {
            fn_info "UO '$uoName' ya existe."
        }
    }

    # Crear Grupos
    foreach ($gDef in @(@{Name="G_Cuates"; OU="Cuates"}, @{Name="G_NoCuates"; OU="No Cuates"})) {
        if (-not (Get-ADGroup -Filter "Name -eq '$($gDef.Name)'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $gDef.Name -GroupScope Global -Path "OU=$($gDef.OU),$Domain"
            fn_ok "Grupo '$($gDef.Name)' creado en UO '$($gDef.OU)'."
        } else {
            fn_info "Grupo '$($gDef.Name)' ya existe."
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. CALCULAR LOGON HOURS (array 21 bytes, UTC-aware)
# ─────────────────────────────────────────────────────────────────────────────
function Get-LogonHoursBytes {
    param([int]$startHour, [int]$endHour)
    # AD almacena las horas en UTC. Convertimos offset local.
    $offset = [System.TimeZone]::CurrentTimeZone.GetUtcOffset([DateTime]::Now).Hours
    $bytes   = New-Object Byte[] 21

    for ($day = 0; $day -lt 7; $day++) {
        for ($localHour = 0; $localHour -lt 24; $localHour++) {
            $isAllowed = $false
            if ($startHour -lt $endHour) {
                $isAllowed = ($localHour -ge $startHour -and $localHour -lt $endHour)
            } else {
                # Cruza media noche (ej: 15 -> 2)
                $isAllowed = ($localHour -ge $startHour -or $localHour -lt $endHour)
            }

            if ($isAllowed) {
                # Convertir a UTC
                $utcHour = ($localHour - $offset + 24) % 24
                $bitIndex  = ($day * 24) + $utcHour
                $byteIndex = [Math]::Floor($bitIndex / 8)
                $bitPos    = $bitIndex % 8
                $bytes[$byteIndex] = $bytes[$byteIndex] -bor ([byte](1 -shl $bitPos))
            }
        }
    }
    return $bytes
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. IMPORTAR USUARIOS DESDE CSV
#    CSV esperado: Nombre, Username, Password, Tipo  (Tipo = "Cuates" | "NoCuates")
# ─────────────────────────────────────────────────────────────────────────────
function fn_import_users_csv {
    param([string]$csvPath)
    if (-not (Test-Path $csvPath)) { fn_err "No se encontro el CSV en: $csvPath"; return }

    fn_info "Importando usuarios desde $csvPath..."
    Import-Module ActiveDirectory
    $users  = Import-Csv $csvPath
    $Domain = (Get-ADDomain).DistinguishedName

    # Horarios locales → bytes AD
    $hoursCuates   = Get-LogonHoursBytes 8  15   # 08:00 – 15:00
    $hoursNoCuates = Get-LogonHoursBytes 15  2   # 15:00 – 02:00 (cruza media noche)

    foreach ($u in $users) {
        $tipo = $u.Tipo.Trim()
        # Aceptar "Cuates" o "NoCuates" (con o sin espacio)
        $esCuate = ($tipo -ieq "Cuates")
        $uo      = if ($esCuate) { "Cuates"    } else { "No Cuates" }
        $group   = if ($esCuate) { "G_Cuates"  } else { "G_NoCuates" }
        $logonHours = if ($esCuate) { $hoursCuates } else { $hoursNoCuates }
        $homePath = "C:\Users\$($u.Username)"

        # Crear directorio personal si no existe
        if (-not (Test-Path $homePath)) {
            New-Item -Path $homePath -ItemType Directory -Force | Out-Null
        }

        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Username)'" -ErrorAction SilentlyContinue)) {
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
                Description       = "P8 - $tipo"
            }
            New-ADUser @params
            fn_ok "Usuario '$($u.Username)' creado → UO=$uo"
        } else {
            Set-ADUser -Identity $u.Username -LogonHours $logonHours -HomeDirectory $homePath -HomeDrive "H:"
            fn_info "Usuario '$($u.Username)' ya existe — horario y home actualizados."
        }

        # Agregar al grupo correspondiente
        try {
            Add-ADGroupMember -Identity $group -Members $u.Username -ErrorAction Stop
        } catch {
            fn_info "Usuario '$($u.Username)' ya pertenece a '$group'."
        }
    }
    fn_ok "Importacion de usuarios completada."
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. GPO — "Cerrar sesión al expirar horario de inicio de sesión"
#    Network security: Force logoff when logon hours expire
#    Registry: HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters!EnableForcedLogOff = 1
# ─────────────────────────────────────────────────────────────────────────────
function fn_setup_logon_gpo {
    fn_info "Configurando GPO para forzar cierre de sesion al expirar horario..."
    Import-Module GroupPolicy -ErrorAction Stop

    $gpoName = "P8_LogonRestrictions"
    $domain  = Get-ADDomain

    # Crear GPO si no existe
    if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
        New-GPO -Name $gpoName -Comment "P8: Forzar cierre de sesion segun horario AD" | Out-Null
        fn_ok "GPO '$gpoName' creada."
    } else {
        fn_info "GPO '$gpoName' ya existe."
    }

    # Vincular GPO al dominio
    try {
        New-GPLink -Name $gpoName -Target $domain.DistinguishedName -LinkEnabled Yes -ErrorAction Stop | Out-Null
        fn_ok "GPO vinculada al dominio '$($domain.DNSRoot)'."
    } catch {
        fn_info "GPO ya estaba vinculada (normal en re-ejecucion)."
    }

    # Configurar la clave de seguridad de red via Set-GPRegistryValue:
    # HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters
    # EnableForcedLogOff (DWORD) = 1
    $regParams = @{
        Name      = $gpoName
        Key       = "HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters"
        ValueName = "EnableForcedLogOff"
        Type      = "DWord"
        Value     = 1
    }
    Set-GPRegistryValue @regParams | Out-Null
    fn_ok "Politica 'Cerrar sesion al expirar horario' habilitada en GPO."

    # Forzar actualización de politicas en este equipo
    gpupdate /force | Out-Null
    fn_ok "GPO aplicada. Ejecuta 'gpupdate /force' en los clientes para propagar."
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. FSRM — Cuotas POR USUARIO + Active Screening
# ─────────────────────────────────────────────────────────────────────────────
function fn_setup_fsrm {
    fn_info "Configurando FSRM (Cuotas por usuario y Filtros Activos)..."
    try {
        Import-Module FileServerResourceManager -ErrorAction Stop
    } catch {
        fn_err "No se pudo cargar FileServerResourceManager. Verifica que FS-Resource-Manager este instalado."
        return
    }

    # ── a) Grupo de archivos prohibidos ──────────────────────────────────────
    $fgName = "Prohibidos_P8"
    if (-not (Get-FsrmFileGroup -Name $fgName -ErrorAction SilentlyContinue)) {
        New-FsrmFileGroup -Name $fgName -IncludePattern @("*.mp3", "*.mp4", "*.exe", "*.msi") | Out-Null
        fn_ok "Grupo de archivos '$fgName' creado (mp3, mp4, exe, msi)."
    } else {
        fn_info "Grupo '$fgName' ya existe."
    }

    # ── b) Leer CSV y configurar cuotas + screening por usuario ──────────────
    $csvPath = Join-Path $PSScriptRoot "..\..\data\usuarios.csv"
    if (-not (Test-Path $csvPath)) {
        fn_err "No se encontro usuarios.csv en $csvPath. Ejecuta la opcion 3 primero."
        return
    }
    $users = Import-Csv $csvPath

    foreach ($u in $users) {
        $tipo    = $u.Tipo.Trim()
        $esCuate = ($tipo -ieq "Cuates")
        $quotaMB = if ($esCuate) { 10MB } else { 5MB }
        $label   = if ($esCuate) { "10 MB (Cuates)" } else { "5 MB (No Cuates)" }

        $userHome = "C:\Users\$($u.Username)"

        # Crear directorio si no existe
        if (-not (Test-Path $userHome)) {
            New-Item -Path $userHome -ItemType Directory -Force | Out-Null
            fn_info "Carpeta creada: $userHome"
        }

        # ── Cuota por carpeta personal ────────────────────────────────────
        if (-not (Get-FsrmQuota -Path $userHome -ErrorAction SilentlyContinue)) {
            New-FsrmQuota -Path $userHome -Size $quotaMB -Description "P8 Cuota $label para $($u.Username)" | Out-Null
            fn_ok "Cuota $label aplicada a $userHome"
        } else {
            # Actualizar cuota si cambio
            Set-FsrmQuota -Path $userHome -Size $quotaMB | Out-Null
            fn_info "Cuota de $userHome actualizada a $label."
        }

        # ── Active Screening en carpeta personal ─────────────────────────
        if (-not (Get-FsrmFileScreen -Path $userHome -ErrorAction SilentlyContinue)) {
            New-FsrmFileScreen -Path $userHome -IncludeGroup $fgName -Active | Out-Null
            fn_ok "Active Screening aplicado en $userHome (mp3, mp4, exe, msi bloqueados)."
        } else {
            fn_info "File Screen en $userHome ya existe."
        }
    }
    fn_ok "Configuracion FSRM completada para todos los usuarios."
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. APPLOCKER — Cuates: Permitir Notepad (Publisher/Path)
#                NoCuates: Bloquear Notepad por HASH
# ─────────────────────────────────────────────────────────────────────────────
function fn_setup_applocker {
    fn_info "Configurando AppLocker (Notepad: Permitido Cuates / Bloqueado por Hash NoCuates)..."

    # Asegurar que el servicio AppID este activo
    Set-Service  AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service AppIDSvc -ErrorAction SilentlyContinue

    $notepadPath = "$env:SystemRoot\System32\notepad.exe"
    if (-not (Test-Path $notepadPath)) {
        fn_err "No se encontro notepad.exe en $notepadPath"
        return
    }

    # Obtener hash criptografico via AppLocker
    $fileInfo = Get-AppLockerFileInformation -Path $notepadPath
    $hashObj  = $fileInfo.Hash
    $hashVal  = $hashObj.HashDataString   # ej: 0x<hex>
    $hashLen  = (Get-Item $notepadPath).Length

    fn_info "Hash AppLocker de notepad.exe: $hashVal (len: $hashLen bytes)"

    # ── Obtener SIDs de los grupos AD ────────────────────────────────────────
    try {
        $sidCuates   = (Get-ADGroup "G_Cuates"   -ErrorAction Stop).SID.Value
        $sidNoCuates = (Get-ADGroup "G_NoCuates" -ErrorAction Stop).SID.Value
    } catch {
        fn_err "No se pudo obtener los SIDs de G_Cuates / G_NoCuates. Asegurate de haber ejecutado la opcion 2 y 3."
        return
    }

    # ── Construir XML de politica AppLocker ──────────────────────────────────
    # Regla 1: Permitir Notepad a G_Cuates (por Path + Publisher — evita restricción innecesaria)
    # Regla 2: Denegar Notepad a G_NoCuates por Hash (el hash persiste aunque se renombre el exe)
    # Regla 3: Regla de "permitir todo" para Administradores (buena práctica obligatoria)
    $applockerXml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enforced">
    <!-- Regla base: Administradores pueden ejecutar todo -->
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2"
                  Name="(Default) Allow Admins - All files"
                  Description="Permitir a Administradores ejecutar cualquier archivo"
                  UserOrGroupSid="S-1-5-32-544"
                  Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>

    <!-- Regla para G_Cuates: Permitir Notepad por PATH -->
    <FilePathRule Id="a2c05e42-4d1b-4e96-9e5f-1b2c3d4e5f60"
                  Name="P8 - Cuates: Permitir Notepad"
                  Description="Grupo Cuates tiene acceso a Bloc de Notas"
                  UserOrGroupSid="$sidCuates"
                  Action="Allow">
      <Conditions>
        <FilePathCondition Path="%SYSTEM32%\notepad.exe" />
      </Conditions>
    </FilePathRule>

    <!-- Regla para G_NoCuates: Denegar Notepad por HASH (resiste renombrado) -->
    <FileHashRule Id="b3d16f53-5e2c-4f07-af6a-2c3d4e5f6a71"
                  Name="P8 - NoCuates: Bloquear Notepad por Hash"
                  Description="Bloqueo por hash criptografico - resiste renombrado del ejecutable"
                  UserOrGroupSid="$sidNoCuates"
                  Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256"
                    Data="$hashVal"
                    SourceFileLength="$hashLen"
                    SourceFileName="notepad.exe" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
  </RuleCollection>
</AppLockerPolicy>
"@

    # Guardar XML temporal y aplicar
    $xmlPath = "$env:TEMP\P8_AppLockerPolicy.xml"
    $applockerXml | Out-File -FilePath $xmlPath -Encoding UTF8

    try {
        Set-AppLockerPolicy -XmlPolicy $xmlPath -Merge -ErrorAction Stop
        fn_ok "Politica AppLocker aplicada:"
        fn_ok "  • G_Cuates   → Notepad PERMITIDO (por Path)"
        fn_ok "  • G_NoCuates → Notepad BLOQUEADO (por Hash SHA-256 — resiste renombrado)"
    } catch {
        fn_err "Error al aplicar AppLockerPolicy: $($_.Exception.Message)"
        fn_info "El XML generado esta en: $xmlPath"
    }

    # Vincular la politica AppLocker a la GPO existente (si GPMC disponible)
    try {
        $gpoName = "P8_LogonRestrictions"
        if (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue) {
            $gpo = Get-GPO -Name $gpoName
            Set-AppLockerPolicy -XmlPolicy $xmlPath -Ldap "LDAP://CN={$($gpo.Id)},CN=Policies,CN=System,$((Get-ADDomain).DistinguishedName)"
            fn_ok "Politica AppLocker vinculada a GPO '$gpoName'."
        }
    } catch {
        fn_info "No se pudo vincular AppLocker a GPO (requiere GPMC/AD conectado). La politica local fue aplicada."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. VERIFICACION
# ─────────────────────────────────────────────────────────────────────────────
function fn_verificar_p8 {
    fn_info "========= VERIFICACION PRACTICA 8 ========="

    # 1. Cuotas
    fn_info "-- Cuotas FSRM por usuario --"
    try {
        Get-FsrmQuota | Select-Object Path,
            @{N="Limite(MB)"; E={[Math]::Round($_.Size/1MB,1)}},
            @{N="Usado(MB)";  E={[Math]::Round($_.Usage/1MB,2)}},
            @{N="Uso(%)";     E={if($_.Size -gt 0){[Math]::Round($_.Usage/$_.Size*100,1)}else{0}}} |
            Format-Table -AutoSize
    } catch { fn_err "No se pudo obtener cuotas: $($_.Exception.Message)" }

    # 2. Logon Hours de usuarios
    fn_info "-- Logon Hours por usuario --"
    try {
        $users = Get-ADUser -Filter * -Properties LogonHours, Description | Where-Object { $_.Description -like "P8*" }
        foreach ($u in $users) {
            $hasHours = ($null -ne $u.LogonHours -and $u.LogonHours.Count -eq 21)
            $status   = if ($hasHours) { "[OK] Configurado (21 bytes)" } else { "[WARN] Sin horario" }
            Write-Host "  $($u.SamAccountName) | $($u.Description) | $status"
        }
    } catch { fn_err "Error obteniendo usuarios AD: $($_.Exception.Message)" }

    # 3. File Screening
    fn_info "-- File Screening activo --"
    try {
        Get-FsrmFileScreen | Select-Object Path, Active, IncludeGroup | Format-Table -AutoSize
    } catch { fn_err "Error obteniendo File Screens." }

    # 4. Probar bloqueo multimedia (en primer directorio con quota)
    fn_info "-- Prueba de bloqueo FSRM (escritura MP3) --"
    $firstQuota = (Get-FsrmQuota | Select-Object -First 1).Path
    if ($firstQuota) {
        $testFile = "$firstQuota\test_prohibido.mp3"
        try {
            "test" | Set-Content $testFile -ErrorAction Stop
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            fn_err "FSRM NO bloqueo el MP3 en $firstQuota (revisar configuracion)."
        } catch {
            fn_ok "FSRM bloqueo correctamente la escritura de .mp3 en $firstQuota"
        }
    }

    # 5. AppLocker
    fn_info "-- Politica AppLocker activa --"
    try {
        Get-AppLockerPolicy -Effective -Xml | Select-String "notepad" | ForEach-Object { Write-Host "  $_" }
    } catch { fn_err "No se pudo leer la politica AppLocker efectiva." }

    fn_ok "========= FIN DE VERIFICACION ========="
}

# ─────────────────────────────────────────────────────────────────────────────
# HEADER
# ─────────────────────────────────────────────────────────────────────────────
function fn_show_header {
    Clear-Host
    Write-Host " +============================================================+" -ForegroundColor Blue
    Write-Host " |      GESTION DE RECURSOS Y GOBERNANZA (WINDOWS)            |" -ForegroundColor Blue
    Write-Host " |      Practica 8 - GPO, FSRM y AppLocker                    |" -ForegroundColor Blue
    Write-Host " +============================================================+" -ForegroundColor Blue
    Write-Host ""
}
