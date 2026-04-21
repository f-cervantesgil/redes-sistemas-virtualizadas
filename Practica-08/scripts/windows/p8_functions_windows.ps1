# p8_functions_windows.ps1
# PRACTICA 08 - VERSION FINAL CORREGIDA

function fn_info { Write-Host "[INFO] $($args)" -ForegroundColor Yellow }
function fn_ok   { Write-Host "[OK]   $($args)" -ForegroundColor Green }
function fn_err  { Write-Host "[ERROR] $($args)" -ForegroundColor Red }

function fn_check_admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        fn_err "Ejecuta PowerShell como Administrador."
        Start-Sleep 5; exit
    }
}

# ─── PASO 1: INSTALAR CARACTERISTICAS ───────────────────────────────────────
function fn_install_features {
    fn_info "Instalando Roles (AD, FSRM, GPMC)..."
    try {
        Install-WindowsFeature AD-Domain-Services, FS-Resource-Manager, GPMC, RSAT-AD-PowerShell -IncludeManagementTools -ErrorAction Stop
        fn_ok "Roles instalados."
    } catch {
        fn_err "Fallo instalacion: $($_.Exception.Message)"
    }
}

# ─── PASO 2: PROMOVER DOMINIO ────────────────────────────────────────────────
function fn_promote_dc {
    fn_info "Promoviendo a DC (redes.local)... El equipo SE REINICIARA."
    Start-Sleep 3
    Import-Module ADDSDeployment
    $pass = Read-Host "Contrasena DSRM" -AsSecureString
    Install-ADDSForest -DomainName "redes.local" -InstallDns -SafeModeAdministratorPassword $pass -Force
}

function fn_check_dc {
    try { Get-ADDomain -ErrorAction Stop | Out-Null; return $true }
    catch { fn_err "Dominio no detectado. Ejecuta Paso 2 primero."; return $false }
}

# ─── PASO 4: ESTRUCTURA AD ──────────────────────────────────────────────────
function fn_setup_ad_structure {
    if (-not (fn_check_dc)) { return }
    fn_info "Creando OUs y Grupos..."
    $Domain = (Get-ADDomain).DistinguishedName

    foreach ($uo in @("Cuates","NoCuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$uo'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $uo -Path $Domain -ProtectedFromAccidentalDeletion $false
            fn_ok "OU '$uo' creada."
        }
    }
    foreach ($grp in @("G_Cuates","G_NoCuates")) {
        $ouPath = if ($grp -eq "G_Cuates") { "OU=Cuates,$Domain" } else { "OU=NoCuates,$Domain" }
        if (-not (Get-ADGroup -Filter "Name -eq '$grp'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $grp -GroupScope Global -Path $ouPath
            fn_ok "Grupo '$grp' creado."
        }
    }
    fn_ok "OUs y Grupos listos."
}

# ─── HORARIOS LOCALES USANDO BYTES UTC (METODO INFALIBLE) ───────────────────
# AD almacena logonHours en UTC. Convertimos horas locales a UTC usando el offset real.
function Get-LogonHoursUTC {
    param([int]$StartHourLocal, [int]$EndHourLocal)

    $offset   = [System.TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalHours
    $startUTC = [int]((($StartHourLocal - $offset) % 24 + 24) % 24)
    $endUTC   = [int]((($EndHourLocal   - $offset) % 24 + 24) % 24)

    $bytes = New-Object byte[] 21
    for ($day = 0; $day -lt 7; $day++) {
        for ($h = 0; $h -lt 24; $h++) {
            $allowed = if ($startUTC -le $endUTC) {
                $h -ge $startUTC -and $h -lt $endUTC
            } else {
                $h -ge $startUTC -or $h -lt $endUTC
            }
            if ($allowed) {
                $bit   = [int]($day * 24 + $h)
                $idx   = [int][Math]::Floor($bit / 8)
                $shift = [int]($bit % 8)
                $bytes[$idx] = [byte]($bytes[$idx] -bor (1 -shl $shift))
            }
        }
    }
    return ,$bytes
}

# ─── PASO 4b: IMPORTAR USUARIOS + HORARIOS ──────────────────────────────────
function fn_import_users_csv {
    $csv = "$ScriptDir\..\..\data\usuarios.csv"
    if (-not (Test-Path $csv)) { fn_err "CSV no encontrado: $csv"; return }

    $Domain = (Get-ADDomain).DistinguishedName

    # Calcular bytes de horario UNA sola vez (en UTC)
    $bytesCuates   = Get-LogonHoursUTC -StartHourLocal 8  -EndHourLocal 15
    $bytesNoCuates = Get-LogonHoursUTC -StartHourLocal 15 -EndHourLocal 2

    $horaLocal = (Get-Date).Hour
    fn_info "Hora local actual del servidor: $horaLocal:xx"
    fn_info "  Cuates   permitidos: 08:00-15:00 (offset UTC aplicado)"
    fn_info "  NoCuates permitidos: 15:00-02:00 (offset UTC aplicado)"

    Import-Csv $csv | ForEach-Object {
        $tipo  = $_.Tipo.Trim()
        # NOTA: el CSV usa "Cuates" y "NoCuates" (sin espacio)
        $esCuate   = ($tipo -eq "Cuates")
        $ouName    = if ($esCuate) { "Cuates" } else { "NoCuates" }
        $grupoDest = if ($esCuate) { "G_Cuates" } else { "G_NoCuates" }
        $logonBytes = if ($esCuate) { $bytesCuates } else { $bytesNoCuates }

        # 1. Crear si no existe
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$($_.Username)'" -ErrorAction SilentlyContinue
        if (-not $adUser) {
            $pass = ConvertTo-SecureString $_.Password -AsPlainText -Force
            New-ADUser -Name $_.Nombre -SamAccountName $_.Username `
                       -AccountPassword $pass -Enabled $true `
                       -Path "OU=$ouName,$Domain"
            fn_ok "Creado: $($_.Username) en OU=$ouName"
        }

        # 2. Aplicar logonHours usando el DN real del usuario (evita errores de CN con tildes)
        try {
            $dn = (Get-ADUser -Identity $_.Username).DistinguishedName
            $de = [ADSI]"LDAP://$dn"
            $de.Put("logonHours", [byte[]]$logonBytes)
            $de.SetInfo()
            fn_ok "Horario aplicado: $($_.Username) ($tipo)"
        } catch {
            fn_err "No se pudo aplicar horario a $($_.Username): $_"
        }

        # 3. Agregar al grupo
        Add-ADGroupMember -Identity $grupoDest -Members $_.Username -ErrorAction SilentlyContinue
    }

    # 4. GPO que fuerza cierre de sesion y deshabilita cache de credenciales
    Import-Module GroupPolicy
    $gpoLogon = "GPO_ForceLogoff_Horarios"
    if (Get-GPO -Name $gpoLogon -ErrorAction SilentlyContinue) { Remove-GPO -Name $gpoLogon -ErrorAction SilentlyContinue }
    New-GPO -Name $gpoLogon | Out-Null

    # Forzar logoff cuando expira el horario
    Set-GPRegistryValue -Name $gpoLogon `
        -Key "HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" `
        -ValueName "EnableForcedLogOff" -Type DWord -Value 1 | Out-Null

    # Equivalente exacto a la directiva "Seguridad de red: cerrar sesion cuando expira"
    Set-GPRegistryValue -Name $gpoLogon `
        -Key "HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -ValueName "ForceLogoffWhenHourExpire" -Type String -Value "1" | Out-Null

    # CRITICO: deshabilitar cache de credenciales para que SIEMPRE consulte al DC
    # Sin esto, el cliente puede autenticarse localmente y saltarse las logonHours
    Set-GPRegistryValue -Name $gpoLogon `
        -Key "HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -ValueName "CachedLogonsCount" -Type String -Value "0" | Out-Null

    $dom = (Get-ADDomain).DistinguishedName
    New-GPLink -Name $gpoLogon -Target $dom | Out-Null
    fn_ok "GPO '$gpoLogon' creada. Cache de credenciales DESHABILITADA => logonHours siempre activas."
}

# ─── PASO 5: FSRM + CARPETAS COMPARTIDAS ────────────────────────────────────
function fn_setup_fsrm_and_shares {
    fn_info "Creando carpetas compartidas y aplicando FSRM..."
    Import-Module FileServerResourceManager

    $shares = @(
        @{ Name = "Cuates_Docs";   Path = "C:\Shares\Cuates_Docs";   Group = "G_Cuates";   QuotaMB = 10 },
        @{ Name = "NoCuates_Docs"; Path = "C:\Shares\NoCuates_Docs"; Group = "G_NoCuates"; QuotaMB = 5  }
    )

    foreach ($s in $shares) {
        # 1. Crear carpeta
        New-Item $s.Path -ItemType Directory -Force | Out-Null

        # 2. Permisos NTFS: borrar herencia, dar acceso solo al grupo y a Administrators
        icacls $s.Path /inheritance:r | Out-Null
        icacls $s.Path /grant "Administrators:(OI)(CI)F" | Out-Null
        icacls $s.Path /grant "$($s.Group):(OI)(CI)M"   | Out-Null

        # 3. Compartir SMB
        Get-SmbShare -Name $s.Name -ErrorAction SilentlyContinue | Remove-SmbShare -Force -ErrorAction SilentlyContinue
        New-SmbShare -Name $s.Name -Path $s.Path `
            -FullAccess "Administrators" `
            -ChangeAccess $s.Group | Out-Null
        fn_ok "Share '\\$(hostname)\$($s.Name)' -> solo accede $($s.Group)"

        # 4. Cuota Hard-Limit
        Get-FsrmQuota -Path $s.Path -ErrorAction SilentlyContinue | Remove-FsrmQuota -ErrorAction SilentlyContinue
        New-FsrmQuota -Path $s.Path -Size ($s.QuotaMB * 1MB) | Out-Null
        fn_ok "Cuota $($s.QuotaMB) MB aplicada en $($s.Path)"
    }

    # 5. Grupo de archivos prohibidos
    Get-FsrmFileGroup -Name "Restringidos_P8" -ErrorAction SilentlyContinue | Remove-FsrmFileGroup -ErrorAction SilentlyContinue
    New-FsrmFileGroup -Name "Restringidos_P8" -IncludePattern @("*.mp3","*.mp4","*.exe","*.msi") | Out-Null

    # 6. Apantallamiento ACTIVO en cada carpeta
    foreach ($s in $shares) {
        Get-FsrmFileScreen -Path $s.Path -ErrorAction SilentlyContinue | Remove-FsrmFileScreen -ErrorAction SilentlyContinue
        New-FsrmFileScreen -Path $s.Path -IncludeGroup "Restringidos_P8" -Active | Out-Null
        fn_ok "Apantallamiento ACTIVO en '$($s.Name)': bloquea .mp3 .mp4 .exe .msi"
    }

    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" } | Select-Object -First 1).IPAddress
    fn_ok "======================================================"
    fn_ok " Accede desde el cliente con:"
    fn_ok "   Cuates   -> \\$ip\Cuates_Docs"
    fn_ok "   NoCuates -> \\$ip\NoCuates_Docs"
    fn_ok "======================================================"
}

# ─── PASO 6: APPLOCKER POR GPO ──────────────────────────────────────────────
function fn_setup_applocker {
    fn_info "Configurando AppLocker (GPO para clientes)..."
    Set-Service AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service AppIDSvc -ErrorAction SilentlyContinue

    Import-Module GroupPolicy
    $dom     = (Get-ADDomain).DistinguishedName
    $netbios = (Get-ADDomain).NetBIOSName
    $gpoName = "GPO_AppLocker_Clientes"

    $sidAdmins   = "S-1-5-32-544"
    $sidEvery    = "S-1-1-0"
    $sidCuates   = (Get-ADGroup -Identity "G_Cuates").SID.Value
    $sidNoCuates = (Get-ADGroup -Identity "G_NoCuates").SID.Value

    # Obtener Hash SHA256 real del notepad.exe
    $fileInfo   = Get-AppLockerFileInformation -Path "C:\Windows\System32\notepad.exe"
    $hashXml    = New-AppLockerPolicy -RuleType Hash -User "$netbios\G_NoCuates" -FileInformation $fileInfo -Xml
    [xml]$hdoc  = $hashXml
    $hNode      = $hdoc.AppLockerPolicy.RuleCollection.FileHashRule.Conditions.FileHashCondition.FileHash
    $hData      = $hNode.Data
    $hName      = $hNode.SourceFileName
    $hLen       = $hNode.SourceFileLength
    fn_info "Hash SHA256 de notepad.exe: $hData"

    $xml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="Admin todo" Description="Administradores sin limite" UserOrGroupSid="$sidAdmins" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="Windir todos" Description="Sistema Windows" UserOrGroupSid="$sidEvery" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="ProgramFiles todos" Description="Aplicaciones instaladas" UserOrGroupSid="$sidEvery" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="ProgramFiles x86 todos" Description="Aplicaciones x86" UserOrGroupSid="$sidEvery" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES(X86)%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="Notepad para Cuates" Description="Cuates pueden usar Notepad" UserOrGroupSid="$sidCuates" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\System32\notepad.exe" /></Conditions>
    </FilePathRule>
    <FileHashRule Id="$(([guid]::NewGuid()).ToString())" Name="Bloquear Notepad NoCuates" Description="Hash anti-renombrado para NoCuates" UserOrGroupSid="$sidNoCuates" Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256" Data="$hData" SourceFileName="$hName" SourceFileLength="$hLen" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
  </RuleCollection>
  <RuleCollection Type="Appx" EnforcementMode="Enabled">
    <FilePublisherRule Id="$(([guid]::NewGuid()).ToString())" Name="Todas las Appx" Description="UWP permitidas" UserOrGroupSid="$sidEvery" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="*" ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="0.0.0.0" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
  </RuleCollection>
</AppLockerPolicy>
"@

    $xmlFile = "$env:TEMP\applocker_p8.xml"
    $xml | Out-File -FilePath $xmlFile -Encoding utf8

    # Recrear GPO limpia
    if (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue) { Remove-GPO -Name $gpoName -ErrorAction SilentlyContinue }
    $gpo      = New-GPO -Name $gpoName
    $ldapPath = "LDAP://CN={$($gpo.Id)},CN=Policies,CN=System,$dom"

    Set-AppLockerPolicy -XmlPolicy $xmlFile -Ldap $ldapPath -ErrorAction Stop
    fn_ok "Politica AppLocker inyectada en GPO."

    # Iniciar AppIDSvc en clientes via GPO
    Set-GPRegistryValue -Name $gpoName -Key "HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc" -ValueName "Start" -Type DWord -Value 2 | Out-Null

    # Crear OU de clientes y mover todos los computadores ahi
    $ouClient = "OU=Equipos_Cliente,$dom"
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Equipos_Cliente'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name "Equipos_Cliente" -Path $dom -ProtectedFromAccidentalDeletion $false
    }
    try { redircmp $ouClient 2>&1 | Out-Null } catch {}

    Get-ADComputer -Filter * -SearchBase "CN=Computers,$dom" -ErrorAction SilentlyContinue | ForEach-Object {
        Move-ADObject -Identity $_.DistinguishedName -TargetPath $ouClient -ErrorAction SilentlyContinue
        fn_ok "PC '$($_.Name)' movida a OU=Equipos_Cliente"
    }

    # Vincular GPO
    New-GPLink -Name $gpoName -Target $ouClient -ErrorAction SilentlyContinue | Out-Null
    fn_ok "GPO '$gpoName' vinculada a OU=Equipos_Cliente."
    fn_ok "Cuates pueden abrir Notepad | NoCuates lo tienen BLOQUEADO por Hash SHA256."
}

# ─── SOLO CLIENTE: UNIRSE AL DOMINIO ────────────────────────────────────────
function fn_join_domain {
    $dom  = Read-Host "Nombre del dominio (redes.local)"
    $cred = Get-Credential -UserName "Administrator@$dom" -Message "Ingresa la contrasena del Administrador"

    Set-Service AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service AppIDSvc -ErrorAction SilentlyContinue

    try {
        Add-Computer -DomainName $dom -Credential $cred -Restart -Force
    } catch {
        fn_err "No se pudo unir al dominio: $($_.Exception.Message)"
    }
}
