#requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$script:IisSiteName = "Default Web Site"
$script:IisSitePath = "C:\inetpub\wwwroot"

function Info   { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Exito  { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Aviso  { param([string]$Msg) Write-Host "[AVISO] $Msg" -ForegroundColor Yellow }
function ErrorX { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

function Pause-Enter {
    Read-Host "Presiona Enter para continuar" | Out-Null
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Debes ejecutar este script como Administrador."
    }
}

function Read-ValidatedNumber {
    param(
        [string]$Prompt,
        [int]$Min = 1,
        [int]$Max = [int]::MaxValue
    )

    while ($true) {
        $value = Read-Host $Prompt

        if ([string]::IsNullOrWhiteSpace($value)) {
            Aviso "No puedes dejar el valor vacio."
            continue
        }

        $value = $value.Trim()

        if ($value -notmatch '^\d+$') {
            Aviso "Solo se permiten numeros."
            continue
        }

        $num = [int]$value

        if ($num -lt $Min -or $num -gt $Max) {
            Aviso "El valor debe estar entre $Min y $Max."
            continue
        }

        return $num
    }
}

function Read-MenuOption {
    param([string]$Prompt, [int]$Max)
    return (Read-ValidatedNumber -Prompt $Prompt -Min 1 -Max $Max)
}

function Read-ValidPort {
    return (Read-ValidatedNumber -Prompt "Ingresa el puerto" -Min 1 -Max 65535)
}

function Ensure-Module {
    param([string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "No se encontro el modulo requerido: $Name"
    }

    Import-Module $Name -ErrorAction Stop | Out-Null
}

function Ensure-Chocolatey {
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        return
    }

    Info "Chocolatey no esta instalado. Se instalara automaticamente..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    $installCmd = "Set-ExecutionPolicy Bypass -Scope Process -Force; " +
                  "[System.Net.ServicePointManager]::SecurityProtocol = " +
                  "[System.Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
                  "iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"

    powershell -NoProfile -ExecutionPolicy Bypass -Command $installCmd | Out-Null
    $env:Path += ";$env:ProgramData\chocolatey\bin"

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        throw "No se pudo instalar Chocolatey."
    }

    Exito "Chocolatey instalado correctamente."
}

function Ensure-IISMandatory {
    Ensure-Module -Name ServerManager

    $feature = Get-WindowsFeature -Name Web-Server
    if (-not $feature.Installed) {
        Info "IIS es obligatorio para esta practica. Instalando IIS..."
        $result = Install-WindowsFeature -Name Web-Server -IncludeManagementTools
        if (-not $result.Success) {
            throw "No se pudo instalar IIS."
        }
        Exito "IIS instalado correctamente."
    }

    Ensure-Module -Name WebAdministration

    if (-not (Test-Path $script:IisSitePath)) {
        New-Item -ItemType Directory -Path $script:IisSitePath -Force | Out-Null
    }

    if (-not (Get-Website -Name $script:IisSiteName -ErrorAction SilentlyContinue)) {
        New-Website -Name $script:IisSiteName -Port 80 -PhysicalPath $script:IisSitePath -Force | Out-Null
    }

    Start-Service W3SVC -ErrorAction SilentlyContinue
    Start-Website -Name $script:IisSiteName -ErrorAction SilentlyContinue
}

function Get-IISVersionDisplay {
    try {
        $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction Stop
        if ($reg.VersionString) {
            return $reg.VersionString
        }
    }
    catch { }

    return "IIS integrado en Windows Server"
}

function Get-ServiceCatalog {
    @(
        [pscustomobject]@{ Key = "iis";    Title = "IIS";                PackageId = $null;           Type = "feature" }
        [pscustomobject]@{ Key = "apache"; Title = "Apache HTTP Server"; PackageId = "apache-httpd";  Type = "choco"   }
        [pscustomobject]@{ Key = "nginx";  Title = "NGINX";              PackageId = "nginx-service"; Type = "choco"   }
    )
}

function Get-ChocoVersions {
    param([string]$PackageId)

    Ensure-Chocolatey

    $raw = & choco search $PackageId --exact --all-versions --limit-output 2>$null
    if (-not $raw) {
        return @()
    }

    $text = ($raw | Out-String)

    $versions = $text -split '[\r\n|\s]+' |
        Where-Object { $_ -match '^\d+(?:\.\d+){1,3}$' } |
        Select-Object -Unique

    return @($versions)
}

function Show-InstallableServicesMenu {
    Write-Host ""
    Write-Host "Selecciona el servicio a instalar:"
    Write-Host "1) Apache HTTP Server"
    Write-Host "2) NGINX"
    Write-Host "3) Regresar"
    Write-Host ""

    $opt = Read-MenuOption -Prompt "Opcion" -Max 3
    switch ($opt) {
        1 { return "apache" }
        2 { return "nginx" }
        3 { return $null }
    }
}

function Show-VersionMenu {
    param([string]$ServiceKey)

    $svc = Get-ServiceCatalog | Where-Object Key -eq $ServiceKey
    if (-not $svc) {
        throw "Servicio no soportado."
    }

    if ($svc.Key -eq "iis") {
        return @(
            [pscustomobject]@{
                Index   = 1
                Display = "$(Get-IISVersionDisplay) [integrado]"
                Version = "builtin"
            }
        )
    }

    $versions = @(Get-ChocoVersions -PackageId $svc.PackageId)
    if (-not $versions -or $versions.Count -eq 0) {
        throw "No se encontraron versiones disponibles para $($svc.Title)."
    }

    $items = @()

    for ($i = 0; $i -lt $versions.Count; $i++) {
        $label = $versions[$i]

        if ($i -eq 0) {
            $label += "  [latest disponible]"
        }
        elseif ($i -eq ($versions.Count - 1)) {
            $label += "  [mas antigua disponible]"
        }

        $items += [pscustomobject]@{
            Index   = $i + 1
            Display = $label
            Version = $versions[$i]
        }
    }

    Write-Host ""
    Write-Host "Versiones disponibles para $($svc.Title):"
    foreach ($item in $items) {
        Write-Host "$($item.Index)) $($item.Display)"
    }
    Write-Host ""

    return $items
}

function Install-IIS {
    Ensure-IISMandatory
    Exito "IIS ya esta verificado e instalado."
}

function Install-ChocoPackageVersion {
    param(
        [string]$PackageId,
        [string]$Version
    )

    Ensure-Chocolatey

    Info "Instalando $PackageId version $Version..."
    & choco install $PackageId --version $Version -y --no-progress

    if ($LASTEXITCODE -ne 0) {
        throw "La instalacion de $PackageId version $Version fallo."
    }
}

function Get-ApacheServiceName {
    $svc = Get-CimInstance Win32_Service |
        Where-Object { $.Name -like "Apache*" -or $.DisplayName -like "Apache" } |
        Select-Object -First 1

    if ($svc) { return $svc.Name }
    return $null
}

function Get-NginxServiceName {
    $svc = Get-Service -Name "nginx" -ErrorAction SilentlyContinue
    if ($svc) { return $svc.Name }

    $svc = Get-CimInstance Win32_Service |
        Where-Object { $.Name -like "nginx" -or $.DisplayName -like "nginx" } |
        Select-Object -First 1

    if ($svc) { return $svc.Name }
    return $null
}

function Find-FirstFile {
    param(
        [string[]]$CandidatePaths,
        [string[]]$SearchRoots,
        [string]$Filter
    )

    foreach ($path in $CandidatePaths) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }

    foreach ($root in $SearchRoots) {
        if ($root -and (Test-Path $root)) {
            $item = Get-ChildItem -Path $root -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($item) {
                return $item.FullName
            }
        }
    }

    return $null
}

function Find-ApacheConf {
    $chocoLib = Join-Path $env:ProgramData "chocolatey\lib\apache-httpd"
    $appData   = Join-Path $env:APPDATA "Apache24"

    return Find-FirstFile `
        -CandidatePaths @(
            (Join-Path $appData "conf\httpd.conf"),
            "C:\tools\Apache24\conf\httpd.conf",
            "C:\Apache24\conf\httpd.conf",
            (Join-Path $chocoLib "tools\Apache24\conf\httpd.conf")
        ) `
        -SearchRoots @(
            $appData,
            $chocoLib,
            "C:\tools",
            "C:\Apache24"
        ) `
        -Filter "httpd.conf"
}
function Find-ApacheExe {
    $chocoLib = Join-Path $env:ProgramData "chocolatey\lib\apache-httpd"
    $appData   = Join-Path $env:APPDATA "Apache24"

    return Find-FirstFile `
        -CandidatePaths @(
            (Join-Path $appData "bin\httpd.exe"),
            "C:\tools\Apache24\bin\httpd.exe",
            "C:\Apache24\bin\httpd.exe",
            (Join-Path $chocoLib "tools\Apache24\bin\httpd.exe")
        ) `
        -SearchRoots @(
            $appData,
            $chocoLib,
            "C:\tools",
            "C:\Apache24"
        ) `
        -Filter "httpd.exe"
}
function Find-NginxConf {
    # Retorna el nginx.conf principal (punto de entrada)
    $candidatePaths = @(
        "C:\tools\nginx\conf\nginx.conf",
        "C:\nginx\conf\nginx.conf",
        (Join-Path $env:ProgramData "chocolatey\lib\nginx-service\tools\nginx\conf\nginx.conf"),
        (Join-Path $env:ProgramData "chocolatey\lib\nginx\tools\nginx\conf\nginx.conf")
    )

    foreach ($path in $candidatePaths) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }

    $searchRoots = @(
        (Join-Path $env:ProgramData "chocolatey\lib\nginx-service"),
        (Join-Path $env:ProgramData "chocolatey\lib\nginx"),
        "C:\tools",
        "C:\nginx"
    ) | Select-Object -Unique

    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            $file = Get-ChildItem -Path $root -Filter "nginx.conf" -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($file) {
                return $file.FullName
            }
        }
    }

    return $null
}

function Find-NginxExe {
    $root1 = Join-Path $env:ProgramData "chocolatey\lib\nginx-service"
    $root2 = Join-Path $env:ProgramData "chocolatey\lib\nginx"

    return Find-FirstFile `
        -CandidatePaths @(
            "C:\tools\nginx\nginx.exe",
            "C:\nginx\nginx.exe",
            (Join-Path $root1 "tools\nginx\nginx.exe"),
            (Join-Path $root2 "tools\nginx\nginx.exe")
        ) `
        -SearchRoots @(
            $root1,
            $root2,
            "C:\tools",
            "C:\nginx"
        ) `
        -Filter "nginx.exe"
}

function Test-ChocoPackageInstalled {
    param([string]$PackageId)

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        return $false
    }

    $raw = & choco list --local-only --exact $PackageId --limit-output 2>$null
    foreach ($line in $raw) {
        if ($line -like "$PackageId|*") {
            return $true
        }
    }

    return $false
}

function Test-ServiceInstalled {
    param([string]$ServiceKey)

    switch ($ServiceKey) {
        "iis"    { return [bool]((Get-WindowsFeature -Name Web-Server).Installed) }
        "apache" { return (Test-ChocoPackageInstalled -PackageId "apache-httpd") }
        "nginx"  { return (Test-ChocoPackageInstalled -PackageId "nginx-service") }
        default  { return $false }
    }
}

function Get-IISCurrentPort {
    Ensure-Module -Name WebAdministration

    $binding = Get-WebBinding -Name $script:IisSiteName -Protocol "http" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $binding) { return $null }

    $parts = $binding.bindingInformation.Split(":")
    if ($parts.Count -ge 2) {
        return [int]$parts[1]
    }

    return $null
}

function Get-ApacheCurrentPort {
    $conf = Find-ApacheConf
    if (-not $conf) { return $null }

    $line = Get-Content $conf | Where-Object { $_ -match '^\s*Listen\s+([0-9\.]+:)?\d+\s*$' } | Select-Object -First 1
    if (-not $line) { return $null }

    if ($line -match '^\s*Listen\s+(?:[0-9\.]+:)?(\d+)\s*$') {
        return [int]$Matches[1]
    }

    return $null
}

function Get-NginxCurrentPort {
    $mainConf = Find-NginxConf
    if (-not $mainConf) { return $null }

    $confRoot = Split-Path -Parent $mainConf
    # FIX: buscar tambien en conf.d donde nginx-service pone los server blocks
    $confDDir = Join-Path (Split-Path -Parent $confRoot) "conf.d"

    $confFiles = @(Get-ChildItem -Path $confRoot -Filter "*.conf" -File -Recurse -ErrorAction SilentlyContinue)
    if (Test-Path $confDDir) {
        $confFiles += @(Get-ChildItem -Path $confDDir -Filter "*.conf" -File -Recurse -ErrorAction SilentlyContinue)
    }

    foreach ($file in $confFiles) {
        foreach ($line in (Get-Content $file.FullName -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*#') { continue }

            if ($line -match '^\s*listen\s+(?:[0-9\.]+:)?(\d+)\b.*;') {
                return [int]$Matches[1]
            }

            if ($line -match '^\s*listen\s+\[::\]:(\d+)\b.*;') {
                return [int]$Matches[1]
            }
        }
    }

    return $null
}

function Get-CurrentPortOfService {
    param([string]$ServiceKey)

    switch ($ServiceKey) {
        "iis"    { return Get-IISCurrentPort }
        "apache" { return Get-ApacheCurrentPort }
        "nginx"  { return Get-NginxCurrentPort }
        default  { return $null }
    }
}

function Test-PortListening {
    param([int]$Port)

    $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Add-FirewallRuleForPort {
    param(
        [string]$RuleName,
        [int]$Port
    )

    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName $RuleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Port | Out-Null
    }
}

function Validate-RequestedPort {
    param(
        [string]$ServiceKey,
        [int]$Port
    )

    $current = Get-CurrentPortOfService -ServiceKey $ServiceKey

    if ($current -eq $Port) {
        return $true
    }

    if (Test-PortListening -Port $Port) {
        Aviso "El puerto $Port ya esta ocupado por otro servicio."
        return $false
    }

    return $true
}

function Set-IISPort {
    param([int]$Port)

    Ensure-IISMandatory
    Ensure-Module -Name WebAdministration

    $bindings = @(Get-WebBinding -Name $script:IisSiteName -Protocol "http" -ErrorAction SilentlyContinue)
    foreach ($b in $bindings) {
        $parts = $b.bindingInformation.Split(":")
        $oldPort = [int]$parts[1]
        Remove-WebBinding -Name $script:IisSiteName -Protocol "http" -Port $oldPort -IPAddress "*" -HostHeader "" -ErrorAction SilentlyContinue
    }

    New-WebBinding -Name $script:IisSiteName -Protocol "http" -Port $Port -IPAddress "*" -HostHeader "" | Out-Null
    Add-FirewallRuleForPort -RuleName "HTTP-Practica-IIS-$Port" -Port $Port
    Start-Website -Name $script:IisSiteName -ErrorAction SilentlyContinue
    Restart-Service W3SVC -ErrorAction SilentlyContinue

    Exito "IIS ahora escucha en el puerto $Port."
}

function Set-ApachePort {
    param([int]$Port)

    $conf = Find-ApacheConf
    if (-not $conf) {
        throw "No se encontro httpd.conf de Apache."
    }

    $backup = "$conf.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item $conf $backup -Force

    $content = Get-Content $conf -Raw
    $original = $content

    $content = [regex]::Replace(
        $content,
        '(?im)^\s*Listen\s+([0-9\.]+:)?\d+\s*$',
        "Listen $Port",
        1
    )

    $content = [regex]::Replace(
        $content,
        '(?im)^\s*ServerName\s+localhost:\d+\s*$',
        "ServerName localhost:$Port"
    )

    if ($content -eq $original) {
        throw "No se encontro la directiva Listen en la configuracion de Apache."
    }

    Set-Content -Path $conf -Value $content -Encoding Ascii

    $exe = Find-ApacheExe
    if ($exe) {
        & $exe -t -f $conf | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Copy-Item $backup $conf -Force
            throw "La configuracion de Apache quedo invalida. Se restauro el respaldo."
        }
    }

    $svc = Get-ApacheServiceName
    if ($svc) {
        Restart-Service -Name $svc -Force
    }
    else {
        Aviso "No se encontro el servicio de Apache para reiniciar."
    }

    Add-FirewallRuleForPort -RuleName "HTTP-Practica-Apache-$Port" -Port $Port
    Exito "Apache ahora escucha en el puerto $Port."
}

function Set-NginxPort {
    param([int]$Port)

    $mainConf = Find-NginxConf
    if (-not $mainConf) { throw "No se encontro nginx.conf." }

    $nginxRoot = Split-Path -Parent (Split-Path -Parent $mainConf)
    $confRoot  = Split-Path -Parent $mainConf

    # FIX: incluir conf.d donde nginx-service (Chocolatey) coloca los server blocks reales
    $confDDir = Join-Path (Split-Path -Parent $confRoot) "conf.d"

    $confFiles = @(Get-ChildItem -Path $confRoot -Filter "*.conf" -File -Recurse -ErrorAction SilentlyContinue)
    if (Test-Path $confDDir) {
        $confFiles += @(Get-ChildItem -Path $confDDir -Filter "*.conf" -File -Recurse -ErrorAction SilentlyContinue)
    }

    if (-not $confFiles -or $confFiles.Count -eq 0) {
        throw "No se encontraron archivos .conf de NGINX."
    }

    # Buscar el archivo que contiene la directiva listen
    $targetFile = $null
    foreach ($file in $confFiles) {
        $raw = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($raw -match '(?im)^(?!\s*#)\s*listen\s+(?:[0-9\.]+:)?\d+\b[^\r\n;]*;') {
            $targetFile = $file.FullName
            break
        }
    }

    if (-not $targetFile) {
        throw "No se encontro una directiva listen valida en los archivos de configuracion de NGINX."
    }

    Info "Modificando archivo: $targetFile"

    $backup = "$targetFile.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item $targetFile $backup -Force

    $content = Get-Content $targetFile -Raw
    $original = $content

    # FIX: reemplazar TODAS las ocurrencias de listen (sin limitar a 1)
    $content = [regex]::Replace(
        $content,
        '(?im)^(?!\s*#)(\s*listen\s+)(?:[0-9\.]+:)?(\d+)(\b[^\r\n;]*;)',
        "${1}$Port${3}"
    )

    # Reemplazar listen IPv6 tambien
    $content = [regex]::Replace(
        $content,
        '(?im)^(?!\s*#)(\s*listen\s+\[::\]:)(\d+)(\b[^\r\n;]*;)',
        "${1}$Port${3}"
    )

    if ($content -eq $original) {
        throw "No se pudo modificar la directiva listen de NGINX."
    }

    Set-Content -Path $targetFile -Value $content -Encoding Ascii

    # Detener el servicio y matar todos los procesos nginx reales
    # (Stop-Service solo no es suficiente con nginx-service de Chocolatey)
    $svc = Get-NginxServiceName
    if ($svc) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }
    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $logsDir = Join-Path $nginxRoot "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    # Validar configuracion antes de levantar
    $exe = Find-NginxExe
    if ($exe) {
        $prefix = ($nginxRoot -replace '\\', '/') + "/"
        Push-Location $nginxRoot
        try {
            $testOutput = & $exe -t -p $prefix -c "conf/nginx.conf" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Copy-Item $backup $targetFile -Force
                throw "La configuracion de NGINX quedo invalida: $testOutput. Se restauro el respaldo."
            }
        }
        finally {
            Pop-Location
        }
    }

    if ($svc) {
        Start-Service -Name $svc -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # Si el servicio no levanto en el puerto correcto, forzar un segundo ciclo
    if ($exe -and -not (Test-PortListening -Port $Port)) {
        Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if ($svc) {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    Add-FirewallRuleForPort -RuleName "HTTP-Practica-Nginx-$Port" -Port $Port

    # Verificacion real: confirmar que el puerto esta escuchando
    if (-not (Test-PortListening -Port $Port)) {
        Aviso "NGINX se reinicio pero el puerto $Port no aparece activo en netstat."
        Aviso "Revisa logs en: $nginxRoot\logs\error.log"
    }
    else {
        Exito "NGINX ahora escucha en el puerto $Port."
    }
}

function Install-OptionalServiceMenu {
    $serviceKey = Show-InstallableServicesMenu
    if (-not $serviceKey) { return }

    $svc = Get-ServiceCatalog | Where-Object Key -eq $serviceKey
    $items = @(Show-VersionMenu -ServiceKey $serviceKey)

    $opt = Read-MenuOption -Prompt "Selecciona la version a instalar" -Max $items.Count
    $selected = $items | Where-Object { $_.Index -eq $opt } | Select-Object -First 1

    if (-not $selected) {
        throw "No se pudo determinar la version seleccionada."
    }

    Install-ChocoPackageVersion -PackageId $svc.PackageId -Version $selected.Version

    switch ($serviceKey) {
        "apache" {
            $svcName = Get-ApacheServiceName
            if ($svcName) {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
            }
        }
        "nginx" {
            $svcName = Get-NginxServiceName
            if ($svcName) {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
            }
        }
    }

    Exito "$($svc.Title) instalado correctamente."
}

function Get-InstalledServicesData {
    $items = @()

    if (Test-ServiceInstalled -ServiceKey "iis") {
        $items += [pscustomobject]@{
            Key   = "iis"
            Title = "IIS"
            Port  = (Get-CurrentPortOfService -ServiceKey "iis")
        }
    }

    if (Test-ServiceInstalled -ServiceKey "apache") {
        $items += [pscustomobject]@{
            Key   = "apache"
            Title = "Apache HTTP Server"
            Port  = (Get-CurrentPortOfService -ServiceKey "apache")
        }
    }

    if (Test-ServiceInstalled -ServiceKey "nginx") {
        $items += [pscustomobject]@{
            Key   = "nginx"
            Title = "NGINX"
            Port  = (Get-CurrentPortOfService -ServiceKey "nginx")
        }
    }

    return $items
}

function Show-InstalledServices {
    $items = @(Get-InstalledServicesData)

    Write-Host ""
    Write-Host "Servicios instalados:"
    if (-not $items -or $items.Count -eq 0) {
        Aviso "No hay servicios instalados."
        Write-Host ""
        return
    }

    foreach ($item in $items) {
        $port = if ($null -ne $item.Port) { $item.Port } else { "No detectado" }
        Write-Host "- $($item.Title) | puerto: $port"
    }
    Write-Host ""
}

function Choose-InstalledService {
    $items = @(Get-InstalledServicesData)

    if (-not $items -or $items.Count -eq 0) {
        Aviso "No hay servicios instalados para configurar."
        return $null
    }

    Write-Host ""
    Write-Host "Selecciona el servicio a configurar:"
    for ($i = 0; $i -lt $items.Count; $i++) {
        $portText = if ($null -ne $items[$i].Port) { $items[$i].Port } else { "No detectado" }
        Write-Host "$($i + 1)) $($items[$i].Title) (puerto actual: $portText)"
    }
    Write-Host ""

    $opt = Read-MenuOption -Prompt "Opcion" -Max $items.Count
    return $items[$opt - 1].Key
}

function Configure-PortMenu {
    $serviceKey = Choose-InstalledService
    if (-not $serviceKey) { return }

    $port = Read-ValidPort
    while (-not (Validate-RequestedPort -ServiceKey $serviceKey -Port $port)) {
        $port = Read-ValidPort
    }

    switch ($serviceKey) {
        "iis"    { Set-IISPort -Port $port }
        "apache" { Set-ApachePort -Port $port }
        "nginx"  { Set-NginxPort -Port $port }
        default  { throw "Servicio no soportado." }
    }
}

function Main-Menu {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "  MENU APROVISIONAMIENTO HTTP - WINDOWS"
    Write-Host "========================================"
    Write-Host "1) Verificar / instalar IIS obligatorio"
    Write-Host "2) Instalar servicio opcional"
    Write-Host "3) Configurar puerto de servicio"
    Write-Host "4) Ver servicios instalados"
    Write-Host "5) Salir"
    Write-Host ""
}

function Ensure-NginxRunning {
    Start-Service nginx-service
}

function Main {
    Assert-Admin
    Ensure-IISMandatory
    Ensure-NginxRunning

    while ($true) {
        try {
	    
            Main-Menu
            $opt = Read-MenuOption -Prompt "Opcion" -Max 5
	
            switch ($opt) {
                1 { Install-IIS }
                2 { Install-OptionalServiceMenu }
                3 { Configure-PortMenu }
                4 { Show-InstalledServices }
                5 {
                    Exito "Saliendo..."
                    break
                }
            }
        }
        catch {
            ErrorX $_.Exception.Message
        }

        Pause-Enter
    }
}

Main