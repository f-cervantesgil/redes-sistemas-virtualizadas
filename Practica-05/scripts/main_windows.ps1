<#
    Practica-05: Administracion de Servidor FTP en Windows Server 2022
    
#>

Import-Module WebAdministration

# 1. Instalación e Idempotencia
Function Install-FTPServer {
    Write-Host "[*] Verificando e Instalando Rol FTP..." -ForegroundColor Cyan
    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service", "Web-Mgmt-Console")
    foreach ($f in $features) {
        if (!(Get-WindowsFeature $f).Installed) {
            Install-WindowsFeature $f
            Write-Host "[+] Instalado: $f" -ForegroundColor Green
        }
    }
}

# 2. Configuración de Estructura Base y Grupos
Function Initialize-Environment {
    Write-Host "[*] Inicializando Grupos y Directorios..." -ForegroundColor Cyan
    
    # Crear Grupos
    $groups = @("reprobados", "recursadores")
    foreach ($g in $groups) {
        if (!(Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $g -Description "Grupo para FTP Practica 05"
            Write-Host "[+] Grupo creado: $g" -ForegroundColor Green
        }
    }

    # Crear Carpetas Raíz
    $basePaths = @("C:\ftp_root", "C:\ftp_root\general", "C:\ftp_root\grupos\reprobados", "C:\ftp_root\grupos\recursadores", "C:\ftp_root\LocalUser")
    foreach ($path in $basePaths) {
        if (!(Test-Path $path)) {
            New-Item -ItemType Directory -Path $path | Out-Null
        }
    }

    # Permisos para carpeta General
    # Anonimo: Lectura | Autenticados: Escritura
    $acl = Get-Acl "C:\ftp_root\general"
    $anonRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone","Read","ContainerInherit,ObjectInherit","None","Allow")
    $authRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Users","Modify","ContainerInherit,ObjectInherit","None","Allow")
    $acl.SetAccessRule($anonRule)
    $acl.SetAccessRule($authRule)
    Set-Acl "C:\ftp_root\general" $acl
}

# 3. Configuración del Sitio FTP en IIS
Function Setup-FTPSite {
    Write-Host "[*] Configurando Sitio FTP en IIS..." -ForegroundColor Cyan
    
    if (Test-Path "IIS:\Sites\FTP_Practica05") {
        Remove-WebFtpSite -Name "FTP_Practica05"
    }
    
    New-WebFtpSite -Name "FTP_Practica05" -Port 21 -PhysicalPath "C:\ftp_root" -Force
    
    # Habilitar Aislamiento de Usuarios (Username directory)
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.userIsolation.mode -Value "IsolateUsers"
    
    # Configurar Autenticación
    Set-WebConfigurationProperty -Filter "/system.ftpServer/security/authentication/basicAuthentication" -Name "enabled" -Value $true -PSPath "IIS:\Sites\FTP_Practica05"
    Set-WebConfigurationProperty -Filter "/system.ftpServer/security/authentication/anonymousAuthentication" -Name "enabled" -Value $true -PSPath "IIS:\Sites\FTP_Practica05"

    # Reglas de Autorización Globales
    Add-WebConfigurationProperty -Filter "/system.ftpServer/security/authorization" -Name "." -Value @{accessType="Allow"; users="*"; permissions="Read, Write"} -PSPath "IIS:\Sites\FTP_Practica05"
    
    # Abrir Firewall de Windows
    Write-Host "[*] Abriendo Firewall de Windows para FTP..." -ForegroundColor Cyan
    New-NetFirewallRule -DisplayName "FTP Servidor" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 21, 1024-65535 -ErrorAction SilentlyContinue

    Restart-WebItem "IIS:\Sites\FTP_Practica05"
}

# 4. Gestión Masiva de Usuarios
Function Add-FTPUsers {
    param([int]$n)
    
    for ($i = 1; $i -le $n; $i++) {
        $user = Read-Host "Nombre para el usuario $i"
        $passString = Read-Host "Password para $user"
        $pass = ConvertTo-SecureString $passString -AsPlainText -Force
        
        $groupName = Read-Host "Grupo (1: reprobados, 2: recursadores)"
        $targetGroup = if ($groupName -eq "1") { "reprobados" } else { "recursadores" }

        # Crear Usuario Local
        if (!(Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
            New-LocalUser -Name $user -Password $pass -FullName "FTP User $user" -Description "Usuario Practica 05"
            Add-LocalGroupMember -Group $targetGroup -Member $user
            Add-LocalGroupMember -Group "Users" -Member $user
        }

        # Estructura de carpetas del usuario
        $userRoot = "C:\ftp_root\LocalUser\$user"
        New-Item -ItemType Directory -Path $userRoot -Force | Out-Null
        
        # Crear Atajos (Directory Junctions) para cumplir con la vista requerida
        # -- general
        # -- grupo
        # -- personal (el mismo esta en su raiz)
        
        $juncGeneral = Join-Path $userRoot "general"
        $juncGroup = Join-Path $userRoot $targetGroup
        
        if (!(Test-Path $juncGeneral)) { cmd /c mklink /j "$juncGeneral" "C:\ftp_root\general" }
        if (!(Test-Path $juncGroup)) { cmd /c mklink /j "$juncGroup" "C:\ftp_root\grupos\$targetGroup" }

        Write-Host "[+] Usuario $user configurado y mapeado a $targetGroup" -ForegroundColor Green
    }
}

# 5. Script para cambiar de grupo
Function Change-UserGroup {
    $user = Read-Host "Cual usuario desea cambiar de grupo?"
    $newGroup = Read-Host "Nuevo Grupo (1: reprobados, 2: recursadores)"
    $targetGroup = if ($newGroup -eq "1") { "reprobados" } else { "recursadores" }
    $oldGroup = if ($newGroup -eq "1") { "recursadores" } else { "reprobados" }

    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) {
        # Remover del viejo y agregar al nuevo
        Remove-LocalGroupMember -Group $oldGroup -Member $user -ErrorAction SilentlyContinue
        Add-LocalGroupMember -Group $targetGroup -Member $user
        
        # Actualizar Junction en la carpeta del usuario
        $userRoot = "C:\ftp_root\LocalUser\$user"
        $oldJunc = Join-Path $userRoot $oldGroup
        $newJunc = Join-Path $userRoot $targetGroup
        
        if (Test-Path $oldJunc) { Remove-Item $oldJunc -Force }
        cmd /c mklink /j "$newJunc" "C:\ftp_root\grupos\$targetGroup"
        
        Write-Host "[+] Usuario $user movido a $targetGroup exitosamente." -ForegroundColor Yellow
    } else {
        Write-Error "Usuario no encontrado."
    }
}

# 6. Eliminar Usuario
Function Remove-FTPUser {
    $user = Read-Host "Cual usuario desea eliminar?"
    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) {
        Write-Host "[*] Eliminando usuario $user..." -ForegroundColor Yellow
        
        # Eliminar Usuario y su carpeta de Home (Aislamiento IIS)
        Remove-LocalUser -Name $user
        $userRoot = "C:\ftp_root\LocalUser\$user"
        if (Test-Path $userRoot) {
            # Los junctions a veces dan problemas al borrar la carpeta padre directamente
            Get-ChildItem $userRoot | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Remove-Item $userRoot -Force -Recurse
        }

        Write-Host "[+] Usuario y carpetas eliminados." -ForegroundColor Green
    } else {
        Write-Host "[-] Usuario no encontrado." -ForegroundColor Red
    }
    Read-Host "Presione Enter para continuar..."
}

# 7. Listar Usuarios Registrados
Function Get-RegisteredFTPUsers {
    Write-Host ""
    Write-Host "[*] USUARIOS REGISTRADOS EN EL SISTEMA FTP" -ForegroundColor Cyan
    Write-Host "------------------------------------------"
    Write-Host "{0,-20} {1,-20}" -f "USUARIO", "GRUPO"
    Write-Host "{0,-20} {1,-20}" -f "-------", "-----"
    
    $groups = @("reprobados", "recursadores")
    foreach ($g in $groups) {
        $members = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue
        foreach ($m in $members) {
            Write-Host "{0,-20} {1,-20}" -f $m.Name, $g
        }
    }
    Write-Host "------------------------------------------"
    Read-Host "Presione Enter para continuar..."
}

# 8. Login Simulado
Function Test-UserLogin {
    Write-Host ""
    Write-Host "--- INICIO DE SESIÓN ---" -ForegroundColor Cyan
    $user = Read-Host "Nombre de usuario"
    
    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) {
        $groups = Get-LocalGroup -Name reprobados, recursadores -ErrorAction SilentlyContinue | Get-LocalGroupMember -Member $user -ErrorAction SilentlyContinue
        if ($null -eq $groups) {
            Write-Host "[-] El usuario existe pero no pertenece al sistema FTP." -ForegroundColor Red
            return
        }

        $passString = Read-Host "Contraseña"
        Write-Host "[+] ¡Login exitoso! Bienvenido, $user." -ForegroundColor Green
        Write-Host "[*] Tus carpetas FTP vinculadas:"
        if (Test-Path "C:\ftp_root\LocalUser\$user") {
            Get-ChildItem -Path "C:\ftp_root\LocalUser\$user" | Select-Object Name
        }
    } else {
        Write-Host "[-] Usuario no encontrado." -ForegroundColor Red
    }
    Read-Host "Presione Enter para continuar..."
}

# MENU PRINCIPAL
while ($true) {
    cls
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "   PRACTICA 05: FTP AUTOMATION (WINDOWS SERVER)     " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "1. Instalación y Configuración Inicial"
    Write-Host "2. Alta Masiva de Usuarios"
    Write-Host "3. Ver Usuarios Registrados"
    Write-Host "4. Cambiar de Grupo a Usuario"
    Write-Host "5. Eliminar Usuario"
    Write-Host "6. Login de Usuario (Simulado)"
    Write-Host "7. Salir"
    Write-Host "====================================================" -ForegroundColor Cyan

    $choice = Read-Host "Seleccione una opción"

    switch ($choice) {
        "1" { Install-FTPServer; Initialize-Environment; Setup-FTPSite }
        "2" { 
            $count = Read-Host "Cuantos usuarios desea crear?"
            if ($count -as [int]) { Add-FTPUsers -n ([int]$count) }
        }
        "3" { Get-RegisteredFTPUsers }
        "4" { Change-UserGroup }
        "5" { Remove-FTPUser }
        "6" { Test-UserLogin }
        "7" { Write-Host "Saliendo..."; exit }
        Default { Write-Host "Opción no válida."; Start-Sleep -Seconds 1 }
    }
}
