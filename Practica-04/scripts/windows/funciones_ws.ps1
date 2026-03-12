# ==========================================
# FUNCIONES MODULARES PARA WINDOWS SERVER
# ==========================================

function Pausa-Tecla {
    Write-Host "`n[<] Presiona [ENTER] para continuar..."
    # ReadHost is standard pause to let user see output
    Read-Host
}

function Validar-IPv4([string]$Ip) {
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    $addr = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$addr)) { return $false }
    return ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

function Ingresar-IP {
    param([string]$Mensaje, [switch]$Opcional)
    while ($true) {
        $ip = (Read-Host $Mensaje).Trim()
        if ($Opcional -and [string]::IsNullOrEmpty($ip)) { return "" }
        if (Validar-IPv4 $ip) { return $ip }
        Write-Host "    [!] Formato de IP (v4) invalido. Intente nuevamente."
    }
}

function Modulo-SSH {
    Clear-Host
    Write-Host "============================================="
    Write-Host "      CONFIGURACION DE SERVICIO SSH (V4)     "
    Write-Host "============================================="
    
    Write-Host "[*] Detectando estado real de OpenSSH..."
    $sshCap = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"
    
    # Reparacion de registro (Si dice instalado pero no hay servicio)
    if ($sshCap.State -eq "Installed" -and -not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
        Write-Host "[!] Instalacion corrupta detectada. Limpiando registros..." -ForegroundColor Yellow
        Remove-WindowsCapability -Online -Name $sshCap.Name | Out-Null
        Start-Sleep -Seconds 2
    }

    # Fuerza de descarga: Saltarse WSUS si existe (Error 0x800f0954)
    Write-Host "[*] Forzando descarga desde Microsoft Update..."
    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $regValue = "UseWUServer"
    $originalValue = $null
    if (Test-Path $regPath) {
        $originalValue = Get-ItemProperty -Path $regPath -Name $regValue -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name $regValue -Value 0 -ErrorAction SilentlyContinue
    }

    try {
        Write-Host "[*] Intentando instalacion limpia..."
        Add-WindowsCapability -Online -Name $sshCap.Name -ErrorAction Stop | Out-Null
        Write-Host "[OK] Instalacion completada." -ForegroundColor Green
    } catch {
        Write-Host "[!] Fallo Add-WindowsCapability. Intentando via DISM Forzado..." -ForegroundColor Yellow
        dism /online /add-capability /capabilityname:$($sshCap.Name) /NoRestart /LimitAccess:$false | Out-Null
    } finally {
        # Restaurar valor original de WSUS
        if ($null -ne $originalValue) {
            Set-ItemProperty -Path $regPath -Name $regValue -Value $originalValue.$regValue -ErrorAction SilentlyContinue
        }
    }

    Write-Host "[*] Verificando servicio..."
    Start-Sleep -Seconds 3
    
    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshd) {
        Write-Host "[OK] Servicio SSH encontrado y listo." -ForegroundColor Green
        Set-Service -Name sshd -StartupType Automatic
        Start-Service sshd -ErrorAction SilentlyContinue
    } else {
        Write-Host "[ERROR] El servicio sigue sin aparecer." -ForegroundColor Red
        Write-Host "[CONSEJO] Intenta instalar Chocolatey (si no lo tienes) corriendo:" -ForegroundColor Cyan
        Write-Host "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
        Pausa-Tecla
        return
    }

    # Firewall
    Write-Host "[*] Asegurando Firewall (Puerto 22)..."
    if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    
    Write-Host "`n[FIN] SSH Activado."
    Pausa-Tecla
}

# ------------------------------------------
# MODULO DHCP
# ------------------------------------------
function Modulo-DHCP {
    while ($true) {
        Clear-Host
        Write-Host "============================================="
        Write-Host "              GESTOR DE DHCP                 "
        Write-Host "============================================="
        Write-Host " A - Verificar estado del rol DHCP"
        Write-Host " B - Instalar e iniciar Servidor DHCP"
        Write-Host " C - Configurar Nuevo Ambito (Scope)"
        Write-Host " R - Regresar al menu principal"
        Write-Host "============================================="
        
        $op = (Read-Host ">> Seleccione una opcion").Trim().ToUpper()

        switch ($op) {
            "A" {
                $estado = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
                if ($estado -and $estado.Installed) {
                    Write-Host "`n[OK] El servidor DHCP local ESTA instalado."
                    Get-Service -Name dhcpserver | Select-Object Name, Status, StartType | Format-Table -AutoSize
                } else {
                    Write-Host "`n[!] El servidor DHCP NO esta instalado."
                }
                Pausa-Tecla
            }
            "B" {
                Write-Host "`n[*] Instalando Rol de DHCP (Esto puede demorar unos minutos)..."
                Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
                Write-Host "[OK] Rol instalado y herramientas de administracion agregadas."
                Set-Service -Name dhcpserver -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service -Name dhcpserver -ErrorAction SilentlyContinue
                Pausa-Tecla
            }
            "C" { Configurar-AmbitoDHCP }
            "R" { return }
            Default { Write-Host "[!] Opcion no valida."; Start-Sleep -Seconds 1 }
        }
    }
}

function Configurar-AmbitoDHCP {
    Write-Host "`n---- Asistente Rapido de Ambito DHCP ----"
    
    # 1. Adaptadores disponibles
    $adaptadores = Get-NetAdapter | Where-Object Status -eq "Up"
    if (-not $adaptadores) {
        Write-Host "[!] No se encontro un adaptador de red activo."
        Pausa-Tecla
        return
    }

    Write-Host "Interfaces del servidor disponibles:"
    for ($i = 0; $i -lt $adaptadores.Count; $i++) {
        Write-Host "  $($i + 1)) [$($adaptadores[$i].Name)] -> [$($adaptadores[$i].InterfaceDescription)]"
    }
    
    $numIf = Read-Host "Seleccione numero de la interfaz a utilizar"
    $idx = [int]$numIf - 1
    if ($idx -lt 0 -or $idx -ge $adaptadores.Count) {
        Write-Host "[!] Seleccion invalida, operacion cancelada."
        Pausa-Tecla
        return
    }
    $iface = $adaptadores[$idx]

    $nombreAmbito = Read-Host "  Nombre del nuevo ambito (Ej. RedLocal)"
    $rangoIni = Ingresar-IP "  Rango Inicial para Clientes (Ej. 192.168.10.100)"
    $rangoFin = Ingresar-IP "  Rango Final para Clientes (Ej. 192.168.10.200)"
    $mascara = Ingresar-IP "  Mascara Subred (Ej. 255.255.255.0) [Opciones: Enter para 255.255.255.0]" -Opcional
    if ([string]::IsNullOrWhiteSpace($mascara)) { $mascara = "255.255.255.0" }
    $gateway = Ingresar-IP "  Puerta de Enlace (Router) [Opcional]" -Opcional
    $dns = Ingresar-IP "  Servidor DNS [Opcional]" -Opcional
    $tiempo = Read-Host "  Tiempo de Concesion en SEGUNDOS (Ej: 86400. Enter por defecto a 691200)"
    if ([string]::IsNullOrWhiteSpace($tiempo)) { $tiempo = 691200 }

    # Preguntar si fijar IP
    $fijar = Read-Host "Desea fijar una IP Base para el Servidor en $($iface.Name)? (S/N)"
    if ($fijar -match "^[sS]") {
        $ipServer = Ingresar-IP "  IP Estatica del Server"
        $prefix = Read-Host "  Prefijo en CIDR (Ej. 24 para 255.255.255.0)"
        Write-Host "[*] Aplicando IP estatica al servidor..."
        
        # Remover IP anterior si la hay
        Get-NetIPAddress -InterfaceAlias $($iface.Name) -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
        
        New-NetIPAddress -InterfaceAlias $($iface.Name) -IPAddress $ipServer -PrefixLength $prefix -AddressFamily IPv4 | Out-Null
        if ($gateway) {
            Get-NetRoute -InterfaceAlias $($iface.Name) -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
            New-NetRoute -InterfaceAlias $($iface.Name) -DestinationPrefix "0.0.0.0/0" -NextHop $gateway | Out-Null
        }
    }

    Write-Host "[*] Registrando nuevo Ambito DHCP..."
    try {
        $leaseSpan = New-TimeSpan -Seconds ([int]$tiempo)
        Add-DhcpServerv4Scope -Name $nombreAmbito -StartRange $rangoIni -EndRange $rangoFin -SubnetMask $mascara -LeaseDuration $leaseSpan -State Active -ErrorAction Stop
        
        $opciones = @{}
        if ([string]::IsNullOrWhiteSpace($gateway) -eq $false) { $opciones["Router"] = @($gateway) }
        if ([string]::IsNullOrWhiteSpace($dns) -eq $false) { $opciones["DnsServer"] = @($dns) }
        
        if ($opciones.Count -gt 0) {
            $scopeNuevo = Get-DhcpServerv4Scope | Where-Object Name -eq $nombreAmbito
            Set-DhcpServerv4OptionValue -ScopeId $scopeNuevo.ScopeId @opciones -ErrorAction SilentlyContinue
        }

        # Autorizar servidor 
        Set-DhcpServerv4Binding -InterfaceAlias $($iface.Name) -BindingState $true -ErrorAction SilentlyContinue
        Restart-Service DHCPServer -ErrorAction SilentlyContinue

        Write-Host "`n[OK] Ambito configurado y DHCP corriendo correctamente."
    }
    catch {
        Write-Host "`n[!] Existio un problema configurando DHCP:"
        Write-Host $_.Exception.Message
    }
    Pausa-Tecla
}

# ------------------------------------------
# MODULO DNS
# ------------------------------------------
function Modulo-DNS {
    while ($true) {
        Clear-Host
        Write-Host "============================================="
        Write-Host "              GESTOR DE DNS                  "
        Write-Host "============================================="
        Write-Host " 1) Preparar e Instalar Rol DNS"
        Write-Host " 2) Administrar Dominios (Zonas)"
        Write-Host " 3) Regresar"
        Write-Host "============================================="
        
        $op = Read-Host ">> Ingrese opcion"

        switch ($op) {
            "1" {
                Write-Host "`n[*] Instalando Rol DNS..."
                Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
                Start-Service DNS -ErrorAction SilentlyContinue
                Write-Host "[OK] Rol de DNS preparado satisfactoriamente."
                Pausa-Tecla
            }
            "2" {
                SubMenu-DominiosDNS
            }
            "3" { return }
            Default { Write-Host "[!] Seleccion erronea."; Start-Sleep -Seconds 1 }
        }
    }
}

function SubMenu-DominiosDNS {
    while ($true) {
        Clear-Host
        Write-Host "--- ADMINISTRADOR DE ZONAS DNS ---"
        Write-Host " 1) Dar de alta un Dominio (Zona Directa)"
        Write-Host " 2) Dar de baja un Dominio"
        Write-Host " 3) Analizar lista de Dominios"
        Write-Host " 4) Hacer consulta rapida (nslookup proxy)"
        Write-Host " 5) Volver"
        
        $sub = Read-Host ">> Opcion"
        switch ($sub) {
            "1" {
                $nombreDom = Read-Host "`n  Dominio nuevo (Ej. mio.com)"
                $ipResol = Ingresar-IP "  Direccion IP raiz a apuntar"
                Write-Host "[*] Registrando zona e insertando registros A..."
                try {
                    Add-DnsServerPrimaryZone -Name $nombreDom -ZoneFile "$nombreDom.dns" -ErrorAction Stop
                    
                    # Registro principal
                    Add-DnsServerResourceRecordA -Name "@" -ZoneName $nombreDom -IPv4Address $ipResol
                    # Registros basicos auxiliares
                    Add-DnsServerResourceRecordA -Name "ns1" -ZoneName $nombreDom -IPv4Address $ipResol
                    Add-DnsServerResourceRecordA -Name "www" -ZoneName $nombreDom -IPv4Address $ipResol
                    
                    Write-Host "[OK] Se creo el dominio" $nombreDom "apuntando a" $ipResol
                } catch {
                    Write-Host "[!] No se pudo registrar: $($_.Exception.Message)"
                }
                Pausa-Tecla
            }
            "2" {
                $delDom = Read-Host "`n  Digite el dominio exacto para eliminar"
                $exite = Get-DnsServerZone | Where-Object ZoneName -eq $delDom -ErrorAction SilentlyContinue
                if ($exite) {
                    Remove-DnsServerZone -Name $delDom -Force
                    Write-Host "[OK] El dominio ha sido purgado del DNS."
                } else {
                    Write-Host "[!] El dominio $delDom no existe en el registro."
                }
                Pausa-Tecla
            }
            "3" {
                Write-Host "`n---- ZONAS REGISTRADAS EN SERVIDOR ----"
                $zonas = Get-DnsServerZone -ErrorAction SilentlyContinue | Where-Object IsAutoCreated -eq $false
                if ($zonas) {
                    $zonas | Format-Table ZoneName, ZoneType, IsPaused -AutoSize
                } else {
                    Write-Host " No existen zonas manuales registradas."
                }
                Pausa-Tecla
            }
            "4" {
                $q = Read-Host "`n  Consulta DNS de dominio"
                try {
                    Resolve-DnsName $q -ErrorAction Stop | Format-Table Name, Type, IPAddress -AutoSize
                } catch {
                    Write-Host "Dominio no encontrado desde este nodo."
                }
                Pausa-Tecla
            }
            "5" { return }
            Default { Write-Host "Seleccion erronea"; Start-Sleep -Seconds 1 }
        }
    }
}
