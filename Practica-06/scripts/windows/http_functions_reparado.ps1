# ==============================================================================
# http_functions_reparado.ps1
# Practica 6 - Windows Server 2022 - Aprovisionamiento HTTP
# ==============================================================================

$script:RESERVED_PORTS = @(21,22,23,25,53,67,68,69,110,123,135,137,138,139,143,161,162,389,443,445,465,587,636,990,1433,1521,2049,3306,3389,5432,5900,5985,5986,8080)
$script:IIS_SITE       = 'Default Web Site'
$script:IIS_APPPOOL    = 'DefaultAppPool'
$script:IIS_WEBROOT    = 'C:\inetpub\wwwroot'
$script:NGINX_ROOT     = 'C:\nginx'
$script:NGINX_CONF     = 'C:\nginx\conf\nginx.conf'
$script:NGINX_SVC      = 'Nginx'
$script:APACHE_SVC_NAMES = @('Apache2.4','Apache24','ApacheHTTPServer','Apache-httpd')
$script:NSSM_PATHS = @(
    'C:\ProgramData\chocolatey\bin\nssm.exe',
    'C:\tools\nssm\win64\nssm.exe',
    'C:\nssm\win64\nssm.exe'
)
$script:PKG_MANAGER = $null

function Write-Section { param([string]$Text) Write-Host ''; Write-Host ('=' * 58) -ForegroundColor Blue; Write-Host "  $Text" -ForegroundColor Blue; Write-Host ('=' * 58) -ForegroundColor Blue }
function Write-Info    { param([string]$Text) Write-Host "[INFO] $Text" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Text) Write-Host "[OK]   $Text" -ForegroundColor Green }
function Write-Warn    { param([string]$Text) Write-Host "[WARN] $Text" -ForegroundColor Yellow }
function Write-Err     { param([string]$Text) Write-Host "[ERROR] $Text" -ForegroundColor Red }

function Assert-Admin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw 'Este script debe ejecutarse como Administrador.'
    }
}

function Test-ReservedPort {
    param([int]$Puerto, [string]$Servicio = '')
    if ($Puerto -in $script:RESERVED_PORTS) {
        if (($Servicio -in @('IIS','Apache','Nginx')) -and $Puerto -eq 443) { return $false }
        return $true
    }
    return $false
}

function Test-Port {
    param([int]$Puerto, [string]$Servicio = '')
    if ($Puerto -lt 1024 -or $Puerto -gt 65535) { Write-Warn 'El puerto debe estar entre 1024 y 65535.'; return $false }
    if (Test-ReservedPort -Puerto $Puerto -Servicio $Servicio) { Write-Warn "El puerto $Puerto esta reservado."; return $false }
    $existing = Get-NetTCPConnection -State Listen -LocalPort $Puerto -ErrorAction SilentlyContinue
    if ($existing) { Write-Warn "El puerto $Puerto ya esta en uso."; return $false }
    return $true
}

function Get-PortFromUser {
    param([string]$Servicio, [int]$Default)
    do {
        $raw = Read-Host "Puerto para $Servicio [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = "$Default" }
        if ($raw -notmatch '^\d+$') { Write-Warn 'Ingresa solo numeros.'; $ok = $false }
        else { $ok = Test-Port -Puerto ([int]$raw) -Servicio $Servicio }
    } until ($ok)
    return [int]$raw
}

function Initialize-PackageManager {
    if (Get-Command winget -ErrorAction SilentlyContinue) { $script:PKG_MANAGER = 'winget'; return }
    if (Get-Command choco -ErrorAction SilentlyContinue)  { $script:PKG_MANAGER = 'choco'; return }
    $script:PKG_MANAGER = $null
}

function Get-AvailableVersions {
    param([ValidateSet('Apache','Nginx')][string]$Paquete)
    Initialize-PackageManager
    $versions = @()
    if ($Paquete -eq 'Apache') {
        if ($script:PKG_MANAGER -eq 'winget') {
            try { $versions += winget show Apache.Httpd --versions 2>$null | Where-Object { $_ -match '^\d' } } catch {}
        }
        if ($script:PKG_MANAGER -eq 'choco' -or $versions.Count -eq 0) {
            try { $versions += choco list apache-httpd --all --exact 2>$null | Where-Object { $_ -match '^apache-httpd\s+\d' } | ForEach-Object { ($_ -split '\s+')[1] } } catch {}
        }
    }
    if ($Paquete -eq 'Nginx') {
        if ($script:PKG_MANAGER -eq 'winget') {
            try { $versions += winget show Nginx.Nginx --versions 2>$null | Where-Object { $_ -match '^\d' } } catch {}
        }
        if ($script:PKG_MANAGER -eq 'choco' -or $versions.Count -eq 0) {
            try { $versions += choco list nginx --all --exact 2>$null | Where-Object { $_ -match '^nginx\s+\d' } | ForEach-Object { ($_ -split '\s+')[1] } } catch {}
        }
    }
    $versions = @($versions | Where-Object { $_ } | Select-Object -Unique)
    if ($versions.Count -eq 0) { return @('latest') }
    return $versions
}

function Select-Version {
    param([ValidateSet('Apache','Nginx')][string]$Paquete)
    $versions = Get-AvailableVersions -Paquete $Paquete
    Write-Host ''
    Write-Host "Versiones disponibles para $Paquete:" -ForegroundColor White
    for ($i=0; $i -lt $versions.Count; $i++) {
        $tag = if ($i -eq 0) { ' [Latest/Desarrollo]' } elseif ($i -eq ($versions.Count - 1) -and $versions.Count -gt 1) { ' [LTS/Estable]' } else { '' }
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), $versions[$i], $tag)
    }
    do {
        $sel = Read-Host "Selecciona version [1-$($versions.Count)]"
        $ok = ($sel -match '^\d+$') -and ([int]$sel -ge 1) -and ([int]$sel -le $versions.Count)
        if (-not $ok) { Write-Warn 'Seleccion invalida.' }
    } until ($ok)
    return $versions[[int]$sel - 1]
}

function Get-ApacheServiceName {
    foreach ($name in $script:APACHE_SVC_NAMES) { if (Get-Service -Name $name -ErrorAction SilentlyContinue) { return $name } }
    try {
        $svc = Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'httpd\.exe' } | Select-Object -First 1
        if ($svc) { return $svc.Name }
    } catch {}
    return $script:APACHE_SVC_NAMES[0]
}

function Get-ApacheInstallRoot {
    $svcName = Get-ApacheServiceName
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'"
        if ($svc -and $svc.PathName -match '"?([^" ]+httpd\.exe)') { return Split-Path (Split-Path $matches[1] -Parent) -Parent }
    } catch {}
    foreach ($root in @('C:\Apache24','C:\tools\Apache24',"$env:ProgramFiles\Apache24")) { if (Test-Path "$root\bin\httpd.exe") { return $root } }
    return 'C:\Apache24'
}

function Get-ApacheConfPath { Join-Path (Get-ApacheInstallRoot) 'conf\httpd.conf' }
function Get-ApacheWebRoot  { Join-Path (Get-ApacheInstallRoot) 'htdocs' }
function Get-ApacheExePath  { Join-Path (Get-ApacheInstallRoot) 'bin\httpd.exe' }

function Get-ServiceConfiguredPort {
    param([ValidateSet('IIS','Apache','Nginx')][string]$Servicio)
    switch ($Servicio) {
        'IIS' {
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $b = Get-WebBinding -Name $script:IIS_SITE -Protocol 'http' | Select-Object -First 1
                if ($b) { return [int](($b.bindingInformation -split ':')[1]) }
            } catch {}
        }
        'Apache' {
            $conf = Get-ApacheConfPath
            if (Test-Path $conf) {
                $line = Get-Content $conf | Where-Object { $_ -match '^Listen\s+' } | Select-Object -First 1
                if ($line -match ':(\d+)$') { return [int]$matches[1] }
                if ($line -match '^Listen\s+(\d+)$') { return [int]$matches[1] }
            }
        }
        'Nginx' {
            if (Test-Path $script:NGINX_CONF) {
                $line = Get-Content $script:NGINX_CONF | Where-Object { $_ -match '^\s*listen\s+\d+' } | Select-Object -First 1
                if ($line -match 'listen\s+(\d+)') { return [int]$matches[1] }
            }
        }
    }
    return $null
}

function Get-IISRealStatus {
    $result = [ordered]@{ ConfiguredPort = $null; SiteState = 'Unknown'; Listening = $false; ListenerPID = $null; ProcessName = $null; IsActive = $false }
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $site = Get-Website -Name $script:IIS_SITE -ErrorAction Stop
        $result.SiteState = "$($site.State)"
        $binding = Get-WebBinding -Name $script:IIS_SITE -Protocol 'http' | Select-Object -First 1
        if ($binding) {
            $result.ConfiguredPort = [int](($binding.bindingInformation -split ':')[1])
            $listen = Get-NetTCPConnection -State Listen -LocalPort $result.ConfiguredPort -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($listen) {
                $result.Listening = $true
                $result.ListenerPID = $listen.OwningProcess
                if ($listen.OwningProcess -eq 4) { $result.ProcessName = 'System' }
                else {
                    try { $result.ProcessName = (Get-Process -Id $listen.OwningProcess -ErrorAction Stop).ProcessName } catch { $result.ProcessName = 'Desconocido' }
                }
            }
        }
        if ($result.SiteState -eq 'Started' -and $result.Listening) { $result.IsActive = $true }
    } catch {}
    return [pscustomobject]$result
}

function Get-ServiceStateSummary {
    param([ValidateSet('IIS','Apache','Nginx')][string]$Servicio)
    switch ($Servicio) {
        'IIS' {
            $iis = Get-IISRealStatus
            return [pscustomobject]@{ Name='IIS'; ConfiguredPort=$iis.ConfiguredPort; RealPort=$(if($iis.Listening){$iis.ConfiguredPort}else{$null}); Running=$iis.IsActive; Detail=$(if($iis.ConfiguredPort -and -not $iis.IsActive){'Configurado sin escucha real'}else{''}) }
        }
        'Apache' {
            $svcName = Get-ApacheServiceName
            $port = Get-ServiceConfiguredPort -Servicio 'Apache'
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            $listen = $null
            if ($port) { $listen = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1 }
            return [pscustomobject]@{ Name='Apache'; ConfiguredPort=$port; RealPort=$(if($listen){$port}else{$null}); Running=([bool]($svc -and $svc.Status -eq 'Running' -and $listen)); Detail=$(if($svc -and $svc.Status -eq 'Running' -and -not $listen -and $port){'Servicio arriba sin listener real'}else{''}) }
        }
        'Nginx' {
            $port = Get-ServiceConfiguredPort -Servicio 'Nginx'
            $svc = Get-Service -Name $script:NGINX_SVC -ErrorAction SilentlyContinue
            $listen = $null
            if ($port) { $listen = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1 }
            return [pscustomobject]@{ Name='Nginx'; ConfiguredPort=$port; RealPort=$(if($listen){$port}else{$null}); Running=([bool]($svc -and $svc.Status -eq 'Running' -and $listen)); Detail=$(if($svc -and $svc.Status -eq 'Running' -and -not $listen -and $port){'Servicio arriba sin listener real'}else{''}) }
        }
    }
}

function Get-ListeningTable {
    $rows = @()
    foreach ($svc in 'IIS','Apache','Nginx') {
        $port = Get-ServiceConfiguredPort -Servicio $svc
        if ($port) {
            $listen = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($listen) {
                $procName = if ($listen.OwningProcess -eq 4) { 'System' } else { try { (Get-Process -Id $listen.OwningProcess -ErrorAction Stop).ProcessName } catch { 'Desconocido' } }
                $rows += [pscustomobject]@{ Servicio=$svc; Puerto=$port; PID=$listen.OwningProcess; Proceso=$procName }
            }
        }
    }
    return $rows
}

function Set-FirewallRule {
    param([int]$Puerto, [string]$Servicio, [int]$PuertoAnterior = 0)
    if ($PuertoAnterior -gt 0 -and $PuertoAnterior -ne $Puerto) {
        $oldNames = @("$Servicio-Puerto-$PuertoAnterior", "HTTP-Custom-$PuertoAnterior", "$Servicio-$PuertoAnterior")
        foreach ($n in $oldNames) { Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
    }
    $name = "$Servicio-Puerto-$Puerto"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $Puerto -Action Allow -Profile Any | Out-Null
        Write-Ok "Regla de firewall creada para $Servicio en puerto $Puerto."
    }
}

function New-IndexPage {
    param([string]$Servicio,[string]$Version,[int]$Puerto,[string]$Webroot)
    if (-not (Test-Path $Webroot)) { New-Item -ItemType Directory -Path $Webroot -Force | Out-Null }
    $html = @"
<!doctype html>
<html lang="es">
<head><meta charset="utf-8"><title>$Servicio</title></head>
<body style="font-family:Segoe UI;background:#111827;color:#f9fafb;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;">
<div style="background:#1f2937;padding:32px 44px;border-radius:16px;box-shadow:0 12px 30px rgba(0,0,0,.35);text-align:center;">
<h1 style="margin:0 0 12px 0;color:#60a5fa;">$Servicio</h1>
<p>Servidor: <b>$Servicio</b></p>
<p>Version: <b>$Version</b></p>
<p>Puerto: <b>$Puerto</b></p>
<p>Practica 6 - Windows Server 2022</p>
</div>
</body>
</html>
"@
    Set-Content -Path (Join-Path $Webroot 'index.html') -Value $html -Encoding UTF8
    Write-Ok "index.html creado en $Webroot"
}

function Set-WebRootPermissions {
    param([string]$Webroot, [string]$Identity = 'Users')
    if (-not (Test-Path $Webroot)) { New-Item -ItemType Directory -Path $Webroot -Force | Out-Null }
    try {
        & icacls $Webroot /inheritance:e | Out-Null
        & icacls $Webroot /grant:r "$($Identity):(OI)(CI)(RX)" | Out-Null
        Write-Ok "Permisos NTFS aplicados: $Identity lectura/ejecucion en $Webroot"
    } catch {
        Write-Warn "No se pudieron ajustar permisos NTFS: $($_.Exception.Message)"
    }
}

function Ensure-IISInstalled {
    Write-Section 'Instalando / habilitando IIS'
    $features = @('Web-Server','Web-WebServer','Web-Common-Http','Web-Default-Doc','Web-Static-Content','Web-Http-Errors','Web-Health','Web-Http-Logging','Web-Performance','Web-Stat-Compression','Web-Security','Web-Filtering','Web-Mgmt-Console')
    foreach ($f in $features) {
        $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        if ($feat -and -not $feat.Installed) { Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null; Write-Ok "Rol habilitado: $f" }
    }
}

function Configure-IISSecurity {
    Import-Module WebAdministration
    Write-Info 'Aplicando seguridad en IIS...'
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/security/requestFiltering' -Name 'removeServerHeader' -Value $true -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/httpProtocol/customHeaders' -Name '.' -Value @{name='X-Frame-Options';value='SAMEORIGIN'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/httpProtocol/customHeaders' -Name '.' -Value @{name='X-Content-Type-Options';value='nosniff'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/httpProtocol/customHeaders' -Name '.' -Value @{name='X-XSS-Protection';value='1; mode=block'} -ErrorAction SilentlyContinue
    foreach ($verb in @('TRACE','TRACK','DELETE')) {
        Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/security/requestFiltering/verbs' -Name '.' -Value @{verb=$verb;allowed='false'} -ErrorAction SilentlyContinue
    }
    Write-Ok 'Cabeceras de seguridad y filtros HTTP aplicados en IIS.'
}

function Restart-IISStack {
    foreach ($svc in 'HTTP','WAS','W3SVC') {
        try { Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue } catch {}
        try { Start-Service -Name $svc -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Seconds 2
}

function Set-IISPort {
    param([int]$Puerto)
    Import-Module WebAdministration
    $prev = Get-ServiceConfiguredPort -Servicio 'IIS'
    if (-not (Get-Website -Name $script:IIS_SITE -ErrorAction SilentlyContinue)) { New-Website -Name $script:IIS_SITE -PhysicalPath $script:IIS_WEBROOT -Port $Puerto | Out-Null }
    Stop-Website -Name $script:IIS_SITE -ErrorAction SilentlyContinue
    Get-WebBinding -Name $script:IIS_SITE -Protocol 'http' -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
    New-WebBinding -Name $script:IIS_SITE -Protocol 'http' -IPAddress '*' -Port $Puerto | Out-Null
    Restart-IISStack
    try { Start-WebAppPool -Name $script:IIS_APPPOOL -ErrorAction SilentlyContinue } catch {}
    Start-Website -Name $script:IIS_SITE -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $listen = Get-NetTCPConnection -State Listen -LocalPort $Puerto -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listen) {
        Write-Warn "IIS aun no escucha en $Puerto. Se intentara un segundo arranque limpio."
        & iisreset /restart | Out-Null
        Start-Sleep -Seconds 4
        $listen = Get-NetTCPConnection -State Listen -LocalPort $Puerto -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    Set-FirewallRule -Puerto $Puerto -Servicio 'IIS' -PuertoAnterior $(if($prev){$prev}else{0})
    if (-not $listen) { Write-Warn "No se detecto listener activo en puerto $Puerto." }
    else { Write-Ok "IIS escuchando realmente en puerto $Puerto (PID $($listen.OwningProcess))." }
}

function Install-IIS {
    param([int]$Puerto)
    Ensure-IISInstalled
    Configure-IISSecurity
    Set-WebRootPermissions -Webroot $script:IIS_WEBROOT -Identity 'IIS_IUSRS'
    New-IndexPage -Servicio 'IIS' -Version '10.0' -Puerto $Puerto -Webroot $script:IIS_WEBROOT
    Set-IISPort -Puerto $Puerto
    Write-Section 'IIS listo'
    Write-Host "URL     : http://localhost:$Puerto" -ForegroundColor Green
    Write-Host "Webroot : $script:IIS_WEBROOT" -ForegroundColor Green
}

function Install-ApacheWindows {
    param([string]$Version='latest',[int]$Puerto)
    Write-Section 'Instalando Apache HTTP Server'
    Initialize-PackageManager
    if ($script:PKG_MANAGER -eq 'winget') {
        if ($Version -and $Version -ne 'latest') { winget install --id Apache.Httpd --version $Version --silent --accept-package-agreements --accept-source-agreements }
        else { winget install --id Apache.Httpd --silent --accept-package-agreements --accept-source-agreements }
    } elseif ($script:PKG_MANAGER -eq 'choco') {
        if ($Version -and $Version -ne 'latest') { choco install apache-httpd --version $Version -y --no-progress --allow-downgrade }
        else { choco install apache-httpd -y --no-progress }
    } else { throw 'No se detecto winget ni chocolatey para instalar Apache.' }
    Start-Sleep -Seconds 3
    Configure-Apache -Puerto $Puerto -Version $Version
}

function Configure-Apache {
    param([int]$Puerto,[string]$Version='manual')
    $svcName = Get-ApacheServiceName
    $conf = Get-ApacheConfPath
    $prev = Get-ServiceConfiguredPort -Servicio 'Apache'
    if (-not (Test-Path $conf)) { throw "No se encontro httpd.conf en $conf" }
    $content = Get-Content $conf -Raw
    $content = [regex]::Replace($content, '(?m)^Listen\s+\S+', "Listen $Puerto")
    $content = [regex]::Replace($content, '(?m)^#?ServerName\s+.*', "ServerName localhost:$Puerto")
    if ($content -notmatch 'ServerTokens Prod') { $content += "`r`nServerTokens Prod`r`nServerSignature Off`r`nTraceEnable Off`r`n" }
    if ($content -notmatch 'Header always set X-Frame-Options') {
        $content += @"
<IfModule headers_module>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
</IfModule>
<LimitExcept GET POST HEAD>
    Require all denied
</LimitExcept>
"@
    }
    Set-Content -Path $conf -Value $content -Encoding UTF8
    $webroot = Get-ApacheWebRoot
    Set-WebRootPermissions -Webroot $webroot -Identity 'Users'
    New-IndexPage -Servicio 'Apache' -Version $Version -Puerto $Puerto -Webroot $webroot
    $exe = Get-ApacheExePath
    if (Test-Path $exe) { & $exe -t | Out-Null }
    Restart-Service -Name $svcName -Force -ErrorAction SilentlyContinue
    Start-Service -Name $svcName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Set-FirewallRule -Puerto $Puerto -Servicio 'Apache' -PuertoAnterior $(if($prev){$prev}else{0})
    $listen = Get-NetTCPConnection -State Listen -LocalPort $Puerto -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($listen) { Write-Ok "Apache escuchando en puerto $Puerto." } else { Write-Warn "Apache no quedo escuchando en puerto $Puerto." }
}

function Get-NssmPath { foreach ($p in $script:NSSM_PATHS) { if (Test-Path $p) { return $p } }; return $null }

function Ensure-NginxInstalled {
    param([string]$Version='latest')
    if (Test-Path "$($script:NGINX_ROOT)\nginx.exe") { return }
    Write-Section 'Instalando Nginx'
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        if ($Version -and $Version -ne 'latest') { choco install nginx --version $Version -y --no-progress --allow-downgrade }
        else { choco install nginx -y --no-progress }
        Start-Sleep -Seconds 3
        if (Test-Path 'C:\tools\nginx\nginx.exe' -and -not (Test-Path "$($script:NGINX_ROOT)\nginx.exe")) {
            if (Test-Path $script:NGINX_ROOT) { Remove-Item $script:NGINX_ROOT -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-Item 'C:\tools\nginx' $script:NGINX_ROOT -Recurse -Force
        }
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Nginx.Nginx --silent --accept-package-agreements --accept-source-agreements
    } else { throw 'No se detecto winget ni chocolatey para instalar Nginx.' }
}

function Ensure-NginxService {
    $nssm = Get-NssmPath
    if (-not $nssm) { throw 'No se encontro NSSM para registrar Nginx como servicio.' }
    if (-not (Get-Service -Name $script:NGINX_SVC -ErrorAction SilentlyContinue)) {
        & $nssm install $script:NGINX_SVC "$($script:NGINX_ROOT)\nginx.exe" | Out-Null
        & $nssm set $script:NGINX_SVC AppDirectory $script:NGINX_ROOT | Out-Null
        & $nssm set $script:NGINX_SVC AppParameters '-p C:\nginx -c conf\nginx.conf' | Out-Null
        & $nssm set $script:NGINX_SVC Start SERVICE_AUTO_START | Out-Null
    }
}

function Set-NginxConfig {
    param([int]$Puerto)
    $prev = Get-ServiceConfiguredPort -Servicio 'Nginx'
    if (-not (Test-Path $script:NGINX_CONF)) { throw "No se encontro nginx.conf en $($script:NGINX_CONF)" }
    $content = Get-Content $script:NGINX_CONF -Raw
    $content = [regex]::Replace($content, 'listen\s+\d+\s*;', "listen $Puerto;")
    if ($content -notmatch 'add_header X-Frame-Options') {
        $content = $content -replace 'server\s*\{', "server {`r`n        add_header X-Frame-Options SAMEORIGIN always;`r`n        add_header X-Content-Type-Options nosniff always;"
    }
    Set-Content -Path $script:NGINX_CONF -Value $content -Encoding UTF8
    Set-FirewallRule -Puerto $Puerto -Servicio 'Nginx' -PuertoAnterior $(if($prev){$prev}else{0})
}

function Restart-NginxManaged {
    param([int]$Puerto)
    $exe = "$($script:NGINX_ROOT)\nginx.exe"
    if (-not (Test-Path $exe)) { throw 'No se encontro nginx.exe.' }
    & $exe -t -p $script:NGINX_ROOT -c 'conf\nginx.conf' | Out-Null
    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Ensure-NginxService
    Restart-Service -Name $script:NGINX_SVC -Force -ErrorAction SilentlyContinue
    Start-Service -Name $script:NGINX_SVC -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $listen = Get-NetTCPConnection -State Listen -LocalPort $Puerto -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($listen) { Write-Ok "Nginx escuchando en puerto $Puerto." } else { Write-Warn "Nginx no quedo escuchando en puerto $Puerto." }
}

function Install-NginxWindows {
    param([string]$Version='latest',[int]$Puerto)
    Ensure-NginxInstalled -Version $Version
    Ensure-NginxService
    Set-NginxConfig -Puerto $Puerto
    Set-WebRootPermissions -Webroot (Join-Path $script:NGINX_ROOT 'html') -Identity 'Users'
    New-IndexPage -Servicio 'Nginx' -Version $Version -Puerto $Puerto -Webroot (Join-Path $script:NGINX_ROOT 'html')
    Restart-NginxManaged -Puerto $Puerto
}

function Invoke-ServiceAction {
    param([ValidateSet('IIS','Apache','Nginx')][string]$Servicio,[ValidateSet('Start','Stop','Restart')][string]$Action)
    switch ($Servicio) {
        'IIS' {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            switch ($Action) {
                'Start'   { Restart-IISStack; Start-Website -Name $script:IIS_SITE -ErrorAction SilentlyContinue }
                'Stop'    { Stop-Website -Name $script:IIS_SITE -ErrorAction SilentlyContinue }
                'Restart' { Stop-Website -Name $script:IIS_SITE -ErrorAction SilentlyContinue; Restart-IISStack; Start-Website -Name $script:IIS_SITE -ErrorAction SilentlyContinue }
            }
        }
        'Apache' {
            $svc = Get-ApacheServiceName
            if ($Action -eq 'Restart') { Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue } else { & "${Action}-Service" -Name $svc -ErrorAction SilentlyContinue }
        }
        'Nginx' {
            Ensure-NginxService
            if ($Action -eq 'Restart') { Restart-Service -Name $script:NGINX_SVC -Force -ErrorAction SilentlyContinue } else { & "${Action}-Service" -Name $script:NGINX_SVC -ErrorAction SilentlyContinue }
        }
    }
}

function Show-ServiceLogs {
    param([ValidateSet('IIS','Apache','Nginx')][string]$Servicio)
    Write-Section "Logs recientes de $Servicio"
    switch ($Servicio) {
        'IIS' {
            Get-WinEvent -LogName System -MaxEvents 20 | Where-Object { $_.ProviderName -match 'W3SVC|WAS|IIS|HTTP' } | Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message | Format-Table -AutoSize
        }
        'Apache' {
            $err = Join-Path (Get-ApacheInstallRoot) 'logs\error.log'
            if (Test-Path $err) { Get-Content $err -Tail 25 } else { Write-Warn 'No se encontro error.log de Apache.' }
        }
        'Nginx' {
            $err = Join-Path $script:NGINX_ROOT 'logs\error.log'
            if (Test-Path $err) { Get-Content $err -Tail 25 } else { Write-Warn 'No se encontro error.log de Nginx.' }
        }
    }
}

function Test-HttpHeaders {
    param([ValidateSet('IIS','Apache','Nginx')][string]$Servicio)
    $port = Get-ServiceConfiguredPort -Servicio $Servicio
    if (-not $port) { Write-Warn "No se encontro puerto configurado para $Servicio."; return }
    Write-Section "curl -I para $Servicio"
    & curl.exe -I "http://127.0.0.1:$port"
}

function Stop-ListeningServiceByPort {
    param([int]$Puerto)
    $listen = Get-NetTCPConnection -State Listen -LocalPort $Puerto -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listen) { Write-Warn "No hay proceso escuchando en $Puerto."; return }
    if ($listen.OwningProcess -eq 4) { Write-Warn 'El puerto pertenece a System/HTTP.sys. Libera el binding del servicio, no mates PID 4.'; return }
    try {
        Stop-Process -Id $listen.OwningProcess -Force -ErrorAction Stop
        Write-Ok "Proceso PID $($listen.OwningProcess) detenido."
    } catch {
        Write-Err "No se pudo detener el PID $($listen.OwningProcess): $($_.Exception.Message)"
    }
}
