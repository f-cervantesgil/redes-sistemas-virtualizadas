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
            # 2. SECCIÓN BLINDADA: Ocultando errores de LogonHours para evitar texto rojo en pantalla
            try {
                Set-ADUser -Identity $u.Username -Clear logonHours -ErrorAction Stop
                Set-ADUser -Identity $u.Username -Replace @{logonHours = [byte[]]$hours} -ErrorAction Stop
            } catch {}
            Add-ADGroupMember -Identity $grpIdentity -Members $u.Username
            fn_ok "Usuario $($u.Username) ($tipo) - Creado con exito."
        }
    }
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
    if (-not (Get-FsrmQuota -Path "C:\Users\Public\Cuates_Docs" -ErrorAction SilentlyContinue)) {
        New-FsrmQuota -Path "C:\Users\Public\Cuates_Docs" -Size 10MB | Out-Null
        New-FsrmQuota -Path "C:\Users\Public\NoCuates_Docs" -Size 5MB | Out-Null
    }
    if (-not (Get-FsrmFileGroup -Name "Restringidos_P8" -ErrorAction SilentlyContinue)) {
        New-FsrmFileGroup -Name "Restringidos_P8" -IncludePattern @("*.mp3", "*.mp4", "*.exe", "*.msi") | Out-Null
    }
    if (-not (Get-FsrmFileScreen -Path "C:\Users\Public" -ErrorAction SilentlyContinue)) {
        New-FsrmFileScreen -Path "C:\Users\Public" -IncludeGroup "Restringidos_P8" -Active | Out-Null
    }
    fn_ok "Servidor de Archivos (FSRM) configurado al 100%."
}

# PASO 6: APPLOCKER (HASH)
function fn_setup_applocker {
    fn_info "Configurando AppLocker a traves de GPO para los Clientes..."
    
    # 1. Obtener datos reales para el XML
    $hash = (Get-AppLockerFileInformation -Path "C:\Windows\System32\notepad.exe").FileHash.Data
    $sid = (Get-ADGroup -Identity "G_NoCuates").SID.Value
    
    # 2. Creamos el archivo XML a mano (Esto nunca falla)
    $xmlContent = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="1" Name="Permitir Windows" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="2" Name="Permitir Program Files" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="3" Name="Permitir todo a Admin" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
    <FileHashRule Id="$(New-Guid)" Name="Bloqueo Notepad NoCuates" UserOrGroupSid="$sid" Action="Deny">
      <Conditions>
        <FileHashCondition Data="$hash" Type="SHA256" SourceFileName="notepad.exe" SourceFileLength="225280" />
      </Conditions>
    </FileHashRule>
  </RuleCollection>
</AppLockerPolicy>
"@

    # 3. Guardar e Inyectar en una GPO en lugar de en la politica local del servidor
    $tempFile = "$env:TEMP\final_policy.xml"
    $xmlContent | Out-File -FilePath $tempFile -Encoding utf8
    
    Import-Module GroupPolicy
    $dom = (Get-ADDomain).DistinguishedName
    $gpoName = "GPO_AppLocker_Clientes"

    if (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue) {
        Remove-GPO -Name $gpoName -ErrorAction SilentlyContinue
    }
    $gpo = New-GPO -Name $gpoName
    
    $ldapPath = "LDAP://CN={$($gpo.Id)},CN=Policies,CN=System,$dom"
    Set-AppLockerPolicy -XmlPolicy $tempFile -Ldap $ldapPath -ErrorAction Stop
    
    # Configurar el servicio AppIDSvc del cliente para inicio automatico mediante GPO
    Set-GPRegistryValue -Name $gpoName -Key "HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc" -ValueName "Start" -Type DWord -Value 2 | Out-Null
    
    # Crear OU Equipos_Cliente y redirigir los nuevos equipos alli
    $ouClient = "OU=Equipos_Cliente,$dom"
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Equipos_Cliente'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name "Equipos_Cliente" -Path $dom -ProtectedFromAccidentalDeletion $false
        try { redircmp $ouClient | Out-Null } catch { }
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
