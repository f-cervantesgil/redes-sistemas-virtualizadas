# p8_functions_windows.ps1
# VERSION DEFINITIVA 100% - PRACTICA 08

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

# PASO 1: INSTALAR CARACTERISTICAS
function fn_install_features {
    fn_info "Instalando Roles de Servidor y Herramientas (AD, FSRM, GPMC)..."
    try {
        Install-WindowsFeature AD-Domain-Services, FS-Resource-Manager, GPMC, RSAT-AD-PowerShell -IncludeManagementTools -ErrorAction Stop
        fn_ok "Instalacion de roles completada con exito."
    } catch {
        fn_err "Fallo la instalacion de roles: $($_.Exception.Message)"
    }
}

# PASO 2: PROMOVER DOMINIO
function fn_promote_dc {
    fn_info "Iniciando Forest (redes.local)... El equipo se REINICIARA solo."
    Start-Sleep -Seconds 3
    Import-Module ADDSDeployment
    $pass = Read-Host "Ingresa Contrasena de Restauracion (DSRM)" -AsSecureString
    Install-ADDSForest -DomainName "redes.local" -InstallDns -SafeModeAdministratorPassword $pass -Force
}

function fn_check_dc {
    try {
        $dom = Get-ADDomain -ErrorAction Stop
        return $true
    } catch {
        fn_err "No se detecta un dominio. Ejecuta la promocion (Paso 2) primero."
        return $false
    }
}

# PASO 4: ESTRUCTURA AD
function fn_setup_ad_structure {
    if (-not (fn_check_dc)) { return }
    fn_info "Configurando UOs y Grupos..."
    $Domain = (Get-ADDomain).DistinguishedName
    
    foreach ($uo in @("Cuates", "No Cuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$uo'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $uo -Path $Domain -ProtectedFromAccidentalDeletion $false
        }
    }
    foreach ($grpName in @("G_Cuates", "G_NoCuates")) {
        if (-not (Get-ADGroup -Filter "Name -eq '$grpName'" -ErrorAction SilentlyContinue)) {
            $path = if ($grpName -match "Cuates") { "OU=Cuates,$Domain" } else { "OU=No Cuates,$Domain" }
            New-ADGroup -Name $grpName -GroupScope Global -Path $path
        }
    }
    fn_ok "UOs y Grupos (G_Cuates, G_NoCuates) listos."
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
    if (-not (Test-Path $csv)) { fn_err "No se encontro el archivo CSV en $csv"; return }
    
    $users = Import-Csv $csv
    $hC = Get-LogonHoursBytes 8 15
    $hN = Get-LogonHoursBytes 15 2
    $Domain = (Get-ADDomain).DistinguishedName

    foreach ($u in $users) {
        $tipo = $u.Tipo.Trim()
        $uoName = if ($tipo -eq "Cuates") { "Cuates" } else { "No Cuates" }
        $grpIdentity = if ($tipo -eq "Cuates") { "G_Cuates" } else { "G_NoCuates" }
        $hours = if ($tipo -eq "Cuates") { $hC } else { $hN }

        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Username)'" -ErrorAction SilentlyContinue)) {
            $pass = ConvertTo-SecureString $u.Password -AsPlainText -Force
            New-ADUser -Name $u.Nombre -SamAccountName $u.Username -AccountPassword $pass -Enabled $true -Path "OU=$uoName,$Domain"
        }
        
        # Usar ADSI nativo para asegurar que LogonHours se aplique sin fallas de schema de powershell
        try {
            $userDE = [ADSI]"LDAP://CN=$($u.Nombre),OU=$uoName,$Domain"
            $userDE.Properties["logonHours"].Clear()
            $userDE.Properties["logonHours"].Value = [byte[]]$hours
            $userDE.CommitChanges()
        } catch {}
        
        Add-ADGroupMember -Identity $grpIdentity -Members $u.Username -ErrorAction SilentlyContinue
        fn_ok "Usuario $($u.Username) ($tipo) - Configurado con exito."
    }

    # Crear GPO para forzar el cierre de sesion al expirar Logon Hours
    Import-Module GroupPolicy
    $gpoNameLogon = "GPO_ForceLogoff_Horarios"
    if (Get-GPO -Name $gpoNameLogon -ErrorAction SilentlyContinue) { Remove-GPO -Name $gpoNameLogon -ErrorAction SilentlyContinue }
    New-GPO -Name $gpoNameLogon | Out-Null
    Set-GPRegistryValue -Name $gpoNameLogon -Key "HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" -ValueName "EnableForcedLogOff" -Type DWord -Value 1 | Out-Null
    Set-GPRegistryValue -Name $gpoNameLogon -Key "HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" -ValueName "ForceLogoffWhenHourExpire" -Type String -Value "1" | Out-Null
    New-GPLink -Name $gpoNameLogon -Target $Domain | Out-Null
    fn_ok "GPO '$gpoNameLogon' creada y enlazada. Cierre de sesion forzado habilitado."
}

# PASO 5: FSRM Y CARPETAS COMPARTIDAS
function fn_setup_fsrm_and_shares {
    fn_info "Configurando FSRM, Carpetas y Permisos SMB..."
    Import-Module FileServerResourceManager

    $paths = @{ "Documentos_Cuates"="C:\Users\Public\Cuates_Docs"; "Documentos_NoCuates"="C:\Users\Public\NoCuates_Docs" }
    foreach ($shareName in $paths.Keys) {
        $fullPath = $paths[$shareName]
        if (-not (Test-Path $fullPath)) { New-Item $fullPath -ItemType Directory -Force | Out-Null }
        if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name $shareName -Path $fullPath -FullAccess "Everyone" -ErrorAction SilentlyContinue | Out-Null
        }
        # Permisos Estrictos por Grupo
        icacls $fullPath /inheritance:r | Out-Null
        $grp = if ($shareName -match "Cuates") { "G_Cuates" } else { "G_NoCuates" }
        icacls $fullPath /grant "${grp}:(OI)(CI)F" /grant "Administrators:(OI)(CI)F" | Out-Null
    }

    # Cuotas y Filtros
    # Auto Quota aplica per-folder a carpetas de usuarios
    if (-not (Get-FsrmQuotaTemplate -Name "Plantilla_Cuates" -ErrorAction SilentlyContinue)) {
        New-FsrmQuotaTemplate -Name "Plantilla_Cuates" -Size 10MB -ErrorAction SilentlyContinue | Out-Null
        New-FsrmQuotaTemplate -Name "Plantilla_NoCuates" -Size 5MB -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-FsrmAutoQuota -Path "C:\Users\Public\Cuates_Docs" -ErrorAction SilentlyContinue)) {
        New-FsrmAutoQuota -Path "C:\Users\Public\Cuates_Docs" -Template "Plantilla_Cuates" -ErrorAction SilentlyContinue | Out-Null
        New-FsrmAutoQuota -Path "C:\Users\Public\NoCuates_Docs" -Template "Plantilla_NoCuates" -ErrorAction SilentlyContinue | Out-Null
    }
    # Aseguramos un limite general a los shares tambien
    if (-not (Get-FsrmQuota -Path "C:\Users\Public\Cuates_Docs" -ErrorAction SilentlyContinue)) {
        New-FsrmQuota -Path "C:\Users\Public\Cuates_Docs" -Size 10MB -ErrorAction SilentlyContinue | Out-Null
        New-FsrmQuota -Path "C:\Users\Public\NoCuates_Docs" -Size 5MB -ErrorAction SilentlyContinue | Out-Null
    }

    if (-not (Get-FsrmFileGroup -Name "Restringidos_P8" -ErrorAction SilentlyContinue)) {
        New-FsrmFileGroup -Name "Restringidos_P8" -IncludePattern @("*.mp3", "*.mp4", "*.exe", "*.msi") | Out-Null
    }
    if (-not (Get-FsrmFileScreen -Path "C:\Users\Public\Cuates_Docs" -ErrorAction SilentlyContinue)) {
        New-FsrmFileScreen -Path "C:\Users\Public\Cuates_Docs" -IncludeGroup "Restringidos_P8" -Active | Out-Null
        New-FsrmFileScreen -Path "C:\Users\Public\NoCuates_Docs" -IncludeGroup "Restringidos_P8" -Active | Out-Null
    }
    fn_ok "Servidor de Archivos (FSRM) cuotas por usuario y apantallamiento activo."
}

# PASO 6: APPLOCKER (HASH)
function fn_setup_applocker {
    fn_info "Configurando AppLocker a traves de GPO para los Clientes..."
    
    Set-Service AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service AppIDSvc -ErrorAction SilentlyContinue

    Import-Module GroupPolicy
    $dom = (Get-ADDomain).DistinguishedName
    $netbios = (Get-ADDomain).NetBIOSName
    $gpoName = "GPO_AppLocker_Clientes"

    # Obtener SIDs reales de los grupos del dominio
    $sidCuates   = (Get-ADGroup -Identity "G_Cuates").SID.Value
    $sidNoCuates = (Get-ADGroup -Identity "G_NoCuates").SID.Value
    $sidAdmins   = "S-1-5-32-544"  # Builtin Administrators (siempre seguro)
    $sidEvery    = "S-1-1-0"       # Everyone

    # Obtener hash SHA256 del notepad.exe del SERVIDOR para la regla Hash
    $fileInfo    = Get-AppLockerFileInformation -Path "C:\Windows\System32\notepad.exe"
    $hashXmlObj  = New-AppLockerPolicy -RuleType Hash -User "$netbios\G_NoCuates" -FileInformation $fileInfo -Xml
    # Extraer el nodo FileHash del xml generado
    [xml]$hashDoc   = $hashXmlObj
    $hashNode       = $hashDoc.AppLockerPolicy.RuleCollection.FileHashRule.Conditions.FileHashCondition.FileHash
    $hashData       = $hashNode.Data
    $hashFileName   = $hashNode.SourceFileName
    $hashFileLength = $hashNode.SourceFileLength

    # Construir un XML completo y definitivo con todas las reglas en un solo bloque
    $fullXml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">

    <!-- REGLA 1: Administradores tienen acceso total siempre -->
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="Permitir todo a Administradores" Description="Admin sin restricciones" UserOrGroupSid="$sidAdmins" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>

    <!-- REGLA 2: Permitir Windows System a todos -->
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="Permitir WINDIR a todos" Description="Rutas del sistema" UserOrGroupSid="$sidEvery" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>

    <!-- REGLA 3: Permitir Program Files a todos -->
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="Permitir ProgramFiles a todos" Description="Aplicaciones instaladas" UserOrGroupSid="$sidEvery" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="Permitir ProgramFiles x86 a todos" Description="Aplicaciones instaladas x86" UserOrGroupSid="$sidEvery" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES(X86)%\*" /></Conditions>
    </FilePathRule>

    <!-- REGLA 4 (CLAVE): Allow EXPLICITO del notepad.exe para el grupo G_Cuates -->
    <FilePathRule Id="$(([guid]::NewGuid()).ToString())" Name="Permitir Notepad a Cuates" Description="Cuates pueden usar Bloc de Notas" UserOrGroupSid="$sidCuates" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\System32\notepad.exe" /></Conditions>
    </FilePathRule>

    <!-- REGLA 5 (CLAVE): Deny por HASH del notepad.exe para G_NoCuates (anti-rename) -->
    <FileHashRule Id="$(([guid]::NewGuid()).ToString())" Name="Bloquear Notepad a NoCuates por Hash" Description="Hash impide renombrar el exe" UserOrGroupSid="$sidNoCuates" Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256" Data="$hashData" SourceFileName="$hashFileName" SourceFileLength="$hashFileLength" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>

  </RuleCollection>
  <RuleCollection Type="Appx" EnforcementMode="Enabled">
    <!-- Permitir TODAS las Appx a todos (Buscador, Menu Inicio, Calculadora, etc.) -->
    <FilePublisherRule Id="$(([guid]::NewGuid()).ToString())" Name="Permitir todas las Appx" Description="Apps UWP permitidas" UserOrGroupSid="$sidEvery" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="*" ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="0.0.0.0" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
  </RuleCollection>
</AppLockerPolicy>
"@

    $tempFile = "$env:TEMP\applocker_completo.xml"
    $fullXml | Out-File -FilePath $tempFile -Encoding utf8

    # Recrear la GPO limpia
    if (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue) {
        Remove-GPO -Name $gpoName -ErrorAction SilentlyContinue
    }
    $gpo = New-GPO -Name $gpoName
    $ldapPath = "LDAP://CN={$($gpo.Id)},CN=Policies,CN=System,$dom"

    # Inyectar el XML completo de una sola vez (sin merge, sin conflictos)
    Set-AppLockerPolicy -XmlPolicy $tempFile -Ldap $ldapPath -ErrorAction Stop

    # Iniciar AppIDSvc automaticamente en los clientes via GPO
    Set-GPRegistryValue -Name $gpoName -Key "HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc" -ValueName "Start" -Type DWord -Value 2 | Out-Null
    
    # Crear OU Equipos_Cliente y redirigir los nuevos equipos alli
    $ouClient = "OU=Equipos_Cliente,$dom"
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Equipos_Cliente'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name "Equipos_Cliente" -Path $dom -ProtectedFromAccidentalDeletion $false
        try { redircmp $ouClient | Out-Null } catch { }
    }
    
    # Mover todas las PCs del contenedor generico a la UO Equipos_Cliente automaticamente
    $comps = Get-ADComputer -Filter * -SearchBase "CN=Computers,$dom" -ErrorAction SilentlyContinue
    foreach ($comp in $comps) {
        Move-ADObject -Identity $comp.DistinguishedName -TargetPath $ouClient -ErrorAction SilentlyContinue
    }
    
    # Vincular GPO a la OU de Clientes
    New-GPLink -Name $gpoName -Target $ouClient | Out-Null


    fn_ok "AppLocker inyectado correctamente en GPO y enlazado a 'Equipos_Cliente'."
    fn_ok "El Servidor no recibe el bloqueo. Todo equipo nuevo ira a esta OU."
}

function fn_join_domain {
    $dom = Read-Host "Nombre del dominio (redes.local)"
    fn_info "Uniendose a $dom..."
    
    # Solicitar credenciales correctamente
    $cred = Get-Credential -UserName "Administrator@$dom" -Message "Ingresa la contrasena del Administrador del Dominio"
    
    # Asegurar el servicio AppIDSvc localmente por si la GPO tarda
    Set-Service AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service AppIDSvc -ErrorAction SilentlyContinue

    try {
        Add-Computer -DomainName $dom -Credential $cred -Restart -Force
    } catch {
        fn_err "No se pudo unir al dominio: $($_.Exception.Message)"
    }
}
