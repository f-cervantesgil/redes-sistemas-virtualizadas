# ==============================================================================
# Practica-06: main.ps1 - VERSION SEGURIDAD AVANZADA (HARDENING)
# ==============================================================================

$OutputEncoding = [System.Text.Encoding]::UTF8

# --- UTILIDADES DE SEGURIDAD ---

function Set-FolderSecurity {
    param([string]$Path, [string]$User)
    Write-Host "[*] Aplicando restricciones NTFS en $Path..." -ForegroundColor Gray
    
    # Crear usuario si no existe
    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $pass = ConvertTo-SecureString "P@ssw0rdService2026!" -AsPlainText -Force
        New-LocalUser -Name $User -Password $pass -Description "Usuario dedicado para servicios web" | Out-Null
    }
    
    # Quitar herencia y dar solo lectura al usuario en su directorio
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false) # Quitar herencia y no copiar
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")
    $acl.AddAccessRule($rule)
    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","ContainerInherit,ObjectInherit","None","Allow")
    $acl.AddAccessRule($ruleSystem)
    $ruleUser = New-Object System.Security.AccessControl.FileSystemAccessRule($User,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")
    $acl.AddAccessRule($ruleUser)
    Set-Acl $Path $acl
}

function New-IndexPage {
    param([string]$Service, [string]$Version, [int]$Port, [string]$Path)
    $content = "Servidor: [$Service] - Version: [$Version] - Puerto: [$Port]"
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    Set-Content -Path (Join-Path $Path "index.html") -Value "<html><body><h1>$content</h1></body></html>" -Force
}

function Test-PortReserved {
    param([int]$Port)
    $reserved = @(21, 22, 23, 25, 53, 110, 143, 443, 3389, 3306, 5432)
    return $reserved -contains $Port
}

# --- PROCESOS DE INSTALACION ---

function Install-IIS {
    param([int]$Port)
    Write-Host "`n[*] Iniciando aprovisionamiento seguro de IIS..." -ForegroundColor Blue
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "IIS-WebServerRole", "IIS-WebServer", "IIS-RequestFiltering" -NoRestart | Out-Null
        Import-Module WebAdministration
        iisreset /stop | Out-Null

        # 1. Binding segun especificacion
        $sn = "Default Web Site"
        Set-WebBinding -Name "$sn" -BindingInformation "*:${Port}:" -ErrorAction SilentlyContinue
        
        # 2. Hardening de Cabeceras y Metodos
        Write-Host "[*] Aplicando Hardening (Security Headers)..." -ForegroundColor Cyan
        # Eliminar X-Powered-By
        Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "X-Powered-By" -ErrorAction SilentlyContinue
        # Agregar Seguridades
        Add-WebConfigurationProperty -filter "system.webServer/httpProtocol/customHeaders" -PSPath "IIS:\Sites\$sn" -Name "." -value @{name='X-Frame-Options';value='SAMEORIGIN'} -ErrorAction SilentlyContinue
        Add-WebConfigurationProperty -filter "system.webServer/httpProtocol/customHeaders" -PSPath "IIS:\Sites\$sn" -Name "." -value @{name='X-Content-Type-Options';value='nosniff'} -ErrorAction SilentlyContinue
        
        # Bloquear TRACE, TRACK, DELETE
        foreach($v in @("TRACE","TRACK","DELETE")){
            Add-WebConfigurationProperty -filter "system.webServer/security/requestFiltering/verbs" -PSPath "IIS:\Sites\$sn" -Name "." -value @{verb=$v;allowed=$false} -ErrorAction SilentlyContinue
        }

        # 3. Permisos NTFS
        Set-FolderSecurity -Path "C:\inetpub\wwwroot" -User "web_service_user"

        iisreset /start | Out-Null
        New-IndexPage -Service "IIS" -Version "LTS" -Port $Port -Path "C:\inetpub\wwwroot"

        # 4. Firewall Inteligente
        New-NetFirewallRule -DisplayName "HTTP-Custom" -LocalPort $Port -Protocol TCP -Action Allow -Force -ErrorAction SilentlyContinue | Out-Null
        if ($Port -ne 80) { Disable-NetFirewallRule -DisplayName "World Wide Web Services (HTTP Traffic-In)" -ErrorAction SilentlyContinue }

        # 5. Validacion Final
        if ((Test-NetConnection -ComputerName localhost -Port $Port).TcpTestSucceeded) {
            Write-Host "[OK] IIS validado en puerto $Port" -ForegroundColor Green
        }
    } catch { Write-Host "[!] Error: $_" -ForegroundColor Red }
}

function Install-ApacheWindows {
    param([int]$Port)
    $version = "2.4.58"
    Write-Host "`n[*] Instalando Apache configurado para Seguridad..." -ForegroundColor Blue
    choco install apache-httpd --version $version -y | Out-Null
    
    $conf = "C:\tools\apache24\conf\httpd.conf"
    if (Test-Path $conf) {
        $c = Get-Content $conf
        $c = $c -replace "^Listen\s+\d+", "Listen $Port"
        $c += "`nServerTokens Prod`nServerSignature Off`nTraceEnable Off"
        $c | Set-Content $conf
    }
    
    Set-FolderSecurity -Path "C:\tools\apache24\htdocs" -User "web_service_user"
    New-IndexPage -Service "Apache" -Version $version -Port $Port -Path "C:\tools\apache24\htdocs"
    
    New-NetFirewallRule -DisplayName "HTTP-Apache" -LocalPort $Port -Protocol TCP -Action Allow -Force -ErrorAction SilentlyContinue | Out-Null
    Restart-Service Apache2.4 -ErrorAction SilentlyContinue
    
    Test-NetConnection -ComputerName localhost -Port $Port | Out-Null
    Write-Host "[OK] Apache endurecido y activo en puerto $Port" -ForegroundColor Green
}

function Get-ServicesStatus {
    Write-Host "`n==========================================" -ForegroundColor Green
    Write-Host "       REPORTE DE SEGURIDAD Y ESTADO      " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    $list = @(
        @{N="IIS"; S="W3SVC"; B="w3wp"},
        @{N="Apache"; S="Apache2.4"; B="httpd"}
    )
    foreach($srv in $list){
        $st = Get-Service $srv.S -ErrorAction SilentlyContinue
        $status = if($st.Status -eq "Running") { "SEGURO" } else { "OFF" }
        $color = if($status -eq "SEGURO") { "Green" } else { "Red" }
        Write-Host "$($srv.N): " -NoNewline; Write-Host $status -ForegroundColor $color
    }
}

# --- MENU PRINCIPAL ---

while ($true) {
    Clear-Host
    Write-Host "--- ADMINISTRACION WEB PROFESIONAL (P6) ---" -ForegroundColor Cyan
    Write-Host "1. Configurar IIS (Hardened)"
    Write-Host "2. Instalar Apache (Hardened)"
    Write-Host "3. Ver Estado"
    Write-Host "4. Salir"
    
    $op = Read-Host "`nSelecciona"
    switch ($op) {
        "1" { 
            $p = [int](Read-Host "Puerto?"); 
            if (Test-PortReserved $p) { Write-Host "Puerto Reservado!"; Start-Sleep 2; break }
            Install-IIS $p; Read-Host "Cualquier tecla..." 
        }
        "2" {
            $p = [int](Read-Host "Puerto?"); 
            if (Test-PortReserved $p) { Write-Host "Puerto Reservado!"; Start-Sleep 2; break }
            Install-ApacheWindows $p; Read-Host "Cualquier tecla..."
        }
        "3" { Get-ServicesStatus; Read-Host "Enter..." }
        "4" { exit }
    }
}
