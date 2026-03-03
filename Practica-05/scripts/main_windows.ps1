<#
    Practica-05: Administracion de Servidor FTP en Windows Server 2022
#>

Import-Module WebAdministration

# 1. Instalacion e Idempotencia
Function Install-FTPServer {
    Write-Host "[*] Verificando e Instalando Rol FTP..." -ForegroundColor Cyan
    # Instalamos todos los componentes necesarios para evitar secciones bloqueadas o faltantes
    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service", "Web-Ftp-Ext", "Web-Mgmt-Console")
    foreach ($f in $features) {
        if (!(Get-WindowsFeature $f -ErrorAction SilentlyContinue).Installed) {
            Install-WindowsFeature $f
            Write-Host "[+] Instalado: $f" -ForegroundColor Green
        }
    }
}

# 2. Configuracion de Estructura Base y Grupos
Function Initialize-Environment {
    Write-Host "[*] Inicializando Grupos y Directorios..." -ForegroundColor Cyan
    
    # RELAJAR POLITICAS DE CONTRASEÑA (Para permitir contraseñas simples como 1234)
    Write-Host "[*] Relajando politicas de seguridad de contraseñas..." -ForegroundColor Yellow
    $cfgFile = "$env:TEMP\pwd_policy.inf"
    secedit /export /cfg $cfgFile /quiet
    (Get-Content $cfgFile) | ForEach-Object {
        $_ -replace "PasswordComplexity = 1", "PasswordComplexity = 0" `
           -replace "MinimumPasswordLength = .*", "MinimumPasswordLength = 0"
    } | Set-Content $cfgFile
    secedit /configure /db "$env:TEMP\pwd.sdb" /cfg $cfgFile /areas SECURITYPOLICY /quiet
    Remove-Item $cfgFile -ErrorAction SilentlyContinue

    # Crear Grupos
    $groups = @("reprobados", "recursadores")
    foreach ($g in $groups) {
        if (!(Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $g -Description "Grupo para FTP Practica 05"
            Write-Host "[+] Grupo creado: $g" -ForegroundColor Green
        }
    }

    # Crear Carpetas Raiz
    $basePaths = @("C:\ftp_root", "C:\ftp_root\general", "C:\ftp_root\grupos\reprobados", "C:\ftp_root\grupos\recursadores", "C:\ftp_root\LocalUser")
    foreach ($path in $basePaths) {
        if (!(Test-Path $path)) {
            New-Item -ItemType Directory -Path $path | Out-Null
        }
    }

    # Permisos para carpeta General
    $acl = Get-Acl "C:\ftp_root\general"
    $anonRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone","Read","ContainerInherit,ObjectInherit","None","Allow")
    $authRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Users","Modify","ContainerInherit,ObjectInherit","None","Allow")
    $acl.SetAccessRule($anonRule)
    $acl.SetAccessRule($authRule)
    Set-Acl "C:\ftp_root\general" $acl
}

# 3. Configuracion del Sitio FTP en IIS
Function Setup-FTPSite {
    Write-Host "[*] Desbloqueando secciones de configuracion IIS..." -ForegroundColor Cyan
    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
    & $appcmd unlock config /section:system.ftpServer/security/authentication
    & $appcmd unlock config /section:system.ftpServer/security/authorization

    Write-Host "[*] Configurando Sitio FTP en IIS..." -ForegroundColor Cyan
    
    if (Get-Website -Name "FTP_Practica05" -ErrorAction SilentlyContinue) {
        Remove-Website -Name "FTP_Practica05"
    }
    
    New-WebFtpSite -Name "FTP_Practica05" -Port 21 -PhysicalPath "C:\ftp_root" -Force
    
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.userIsolation.mode -Value "IsolateUsers"
    
    # Limpiar y establecer autenticacion
    Set-WebConfigurationProperty -Filter "/system.ftpServer/security/authentication/basicAuthentication" -Name "enabled" -Value $true -PSPath "IIS:\Sites\FTP_Practica05" -ErrorAction SilentlyContinue
    Set-WebConfigurationProperty -Filter "/system.ftpServer/security/authentication/anonymousAuthentication" -Name "enabled" -Value $true -PSPath "IIS:\Sites\FTP_Practica05" -ErrorAction SilentlyContinue

    # Limpiar reglas de autorizacion previas para evitar error de duplicado
    Clear-WebConfiguration -Filter "/system.ftpServer/security/authorization" -PSPath "IIS:\Sites\FTP_Practica05" -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -Filter "/system.ftpServer/security/authorization" -Name "." -Value @{accessType="Allow"; users="*"; permissions="Read, Write"} -PSPath "IIS:\Sites\FTP_Practica05"
    
    Write-Host "[*] Abriendo Firewall de Windows..." -ForegroundColor Cyan
    if (!(Get-NetFirewallRule -DisplayName "FTP Servidor" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Servidor" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 21, 1024-65535
    }

    Restart-WebItem "IIS:\Sites\FTP_Practica05"
    Write-Host "[+] Sitio FTP configurado exitosamente." -ForegroundColor Green
}

# 4. Gestion Masiva de Usuarios
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
        if (!(Test-Path $userRoot)) {
            New-Item -ItemType Directory -Path $userRoot -Force | Out-Null
        }
        
        $juncGeneral = Join-Path $userRoot "general"
        $juncGroup = Join-Path $userRoot $targetGroup
        
        if (!(Test-Path $juncGeneral)) { cmd /c mklink /j "$juncGeneral" "C:\ftp_root\general" }
        if (!(Test-Path $juncGroup)) { cmd /c mklink /j "$juncGroup" "C:\ftp_root\grupos\$targetGroup" }

        Write-Host "[+] Usuario $user configurado y mapeado a $targetGroup" -ForegroundColor Green
    }
}

# 5. Cambiar de grupo
Function Change-UserGroup {
    $user = Read-Host "Cual usuario desea cambiar de grupo?"
    $newGroup = Read-Host "Nuevo Grupo (1: reprobados, 2: recursadores)"
    $targetGroup = if ($newGroup -eq "1") { "reprobados" } else { "recursadores" }
    $oldGroup = if ($newGroup -eq "1") { "recursadores" } else { "reprobados" }

    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) {
        Remove-LocalGroupMember -Group $oldGroup -Member $user -ErrorAction SilentlyContinue
        Add-LocalGroupMember -Group $targetGroup -Member $user
        
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
        
        Remove-LocalUser -Name $user
        $userRoot = "C:\ftp_root\LocalUser\$user"
        if (Test-Path $userRoot) {
            Get-ChildItem $userRoot | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Remove-Item $userRoot -Force -Recurse
        }

        Write-Host "[+] Usuario y carpetas eliminados." -ForegroundColor Green
    } else {
        Write-Host "[-] Usuario no encontrado." -ForegroundColor Red
    }
}

# 7. Listar Usuarios
Function Get-RegisteredFTPUsers {
    Write-Host ""
    Write-Host "[*] USUARIOS REGISTRADOS EN EL SISTEMA FTP" -ForegroundColor Cyan
    Write-Host "------------------------------------------"
    
    $groups = @("reprobados", "recursadores")
    $anyUser = $false

    foreach ($g in $groups) {
        $members = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue
        if ($members) {
            if (!$anyUser) {
                Write-Output ("{0,-20} {1,-20}" -f "USUARIO", "GRUPO")
                Write-Output ("{0,-20} {1,-20}" -f "-------", "-----")
                $anyUser = $true
            }
            foreach ($m in $members) {
                Write-Output ("{0,-20} {1,-20}" -f $m.Name, $g)
            }
        }
    }

    if (!$anyUser) {
        Write-Host "[!] No hay usuarios registrados actualmente." -ForegroundColor Yellow
    }
    Write-Host "------------------------------------------"
}

# 8. Login Simulado
Function Test-UserLogin {
    Write-Host ""
    Write-Host "--- INICIO DE SESION ---" -ForegroundColor Cyan
    $userLogin = Read-Host "Nombre de usuario"
    
    if (Get-LocalUser -Name $userLogin -ErrorAction SilentlyContinue) {
        $foundGroups = Get-LocalGroup -Name reprobados, recursadores -ErrorAction SilentlyContinue | Get-LocalGroupMember -Member $userLogin -ErrorAction SilentlyContinue
        if ($null -eq $foundGroups) {
            Write-Host "[-] El usuario existe pero no pertenece al sistema FTP." -ForegroundColor Red
            return
        }

        $passInput = Read-Host "Contrasena"
        Write-Host "[+] Login exitoso! Bienvenido, $userLogin." -ForegroundColor Green
        Write-Host "[*] Tus carpetas FTP vinculadas:"
        $loginRoot = "C:\ftp_root\LocalUser\$userLogin"
        if (Test-Path $loginRoot) {
            Get-ChildItem -Path $loginRoot | Select-Object Name
        }
    } else {
        Write-Host "[-] Usuario no encontrado." -ForegroundColor Red
    }
}

# MENU PRINCIPAL
while ($true) {
    cls
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "   ADMINISTRACION DE SERVIDOR FTP (WINDOWS)         " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "1. Instalacion y Configuracion Inicial"
    Write-Host "2. Alta Masiva de Usuarios"
    Write-Host "3. Ver Usuarios Registrados"
    Write-Host "4. Cambiar de Grupo a Usuario"
    Write-Host "5. Eliminar Usuario"
    Write-Host "6. Login de Usuario (Simulado)"
    Write-Host "7. Salir"
    Write-Host "====================================================" -ForegroundColor Cyan

    $choice = Read-Host "Seleccione una opcion"
    $showPause = $true

    switch ($choice) {
        "1" { 
            Install-FTPServer
            Initialize-Environment
            Setup-FTPSite
        }
        "2" { 
            $countSelect = Read-Host "Cuantos usuarios desea crear?"
            if ($countSelect -as [int]) { Add-FTPUsers -n ([int]$countSelect) }
        }
        "3" { Get-RegisteredFTPUsers }
        "4" { Change-UserGroup }
        "5" { Remove-FTPUser }
        "6" { Test-UserLogin }
        "7" { Write-Host "Saliendo..."; exit }
        Default { 
            Write-Host "Opcion no valida." -ForegroundColor Red
            $showPause = $false
            Start-Sleep -Seconds 1
        }
    }
    
    if ($showPause) {
        Write-Host ""
        Read-Host "Presione Enter para volver al menu..."
    }
}
