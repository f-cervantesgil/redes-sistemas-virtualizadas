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
    
    # DESACTIVAR REGLAS DE SEGURIDAD (Para permitir contrasenas simples como 1234)
    Write-Host "[*] Aplicando politicas de contrasenas debiles para la practica..." -ForegroundColor Yellow
    $cfgFile = "$env:TEMP\pwd_policy.inf"
    secedit /export /cfg $cfgFile /quiet
    $content = Get-Content $cfgFile
    $content = $content -replace "PasswordComplexity = 1", "PasswordComplexity = 0"
    $content = $content -replace "MinimumPasswordLength = .*", "MinimumPasswordLength = 0"
    $content = $content -replace "PasswordHistorySize = .*", "PasswordHistorySize = 0"
    $content = $content -replace "MaximumPasswordAge = .*", "MaximumPasswordAge = -1"
    $content | Set-Content $cfgFile
    secedit /configure /db "$env:TEMP\pwd.sdb" /cfg $cfgFile /areas SECURITYPOLICY /quiet
    
    # Tambien usamos net accounts para asegurar la longitud minima
    net accounts /minpwlen:0 /maxpwage:unlimited /minpwage:0 /unique:0
    
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

    # Permisos NTFS amplios para que IIS/FTP pueda acceder
    $acl = Get-Acl "C:\ftp_root"
    $usersRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Users","FullControl","ContainerInherit,ObjectInherit","None","Allow")
    $everyoneRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone","Read","ContainerInherit,ObjectInherit","None","Allow")
    $acl.SetAccessRule($usersRule)
    $acl.SetAccessRule($everyoneRule)
    Set-Acl "C:\ftp_root" $acl

    # Permisos para carpeta General
    $acl2 = Get-Acl "C:\ftp_root\general"
    $anonRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone","Read","ContainerInherit,ObjectInherit","None","Allow")
    $authRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Users","Modify","ContainerInherit,ObjectInherit","None","Allow")
    $acl2.SetAccessRule($anonRule)
    $acl2.SetAccessRule($authRule)
    Set-Acl "C:\ftp_root\general" $acl2
}

# 3. Configuracion del Sitio FTP en IIS
Function Setup-FTPSite {
    Write-Host "[*] Desbloqueando secciones de configuracion IIS..." -ForegroundColor Cyan
    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
    & $appcmd unlock config /section:system.ftpServer/security/authentication
    & $appcmd unlock config /section:system.ftpServer/security/authorization
    & $appcmd unlock config /section:system.ftpServer/security/ssl

    Write-Host "[*] Deteniendo sitios en conflicto (puerto 21)..." -ForegroundColor Yellow
    # Detener el Default Web Site si existe (a veces bloquea el puerto)
    Stop-Website -Name "Default Web Site" -ErrorAction SilentlyContinue

    Write-Host "[*] Configurando Sitio FTP en IIS..." -ForegroundColor Cyan
    
    # Eliminar sitio si ya existe
    if (Get-Website -Name "FTP_Practica05" -ErrorAction SilentlyContinue) {
        Remove-Website -Name "FTP_Practica05"
        Write-Host "[!] Sitio anterior eliminado." -ForegroundColor Yellow
    }
    
    # Crear el nuevo sitio FTP
    New-WebFtpSite -Name "FTP_Practica05" -Port 21 -PhysicalPath "C:\ftp_root" -Force
    
    # NO usar aislamiento de usuarios por ahora (causa 530)
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.userIsolation.mode -Value 0
    
    # Desactivar SSL completamente (Permitir texto plano)
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0
    
    # Configurar Autenticacion via appcmd (mas confiable)
    & $appcmd set config "FTP_Practica05" /section:system.ftpServer/security/authentication/basicAuthentication /enabled:true /commit:apphost
    & $appcmd set config "FTP_Practica05" /section:system.ftpServer/security/authentication/anonymousAuthentication /enabled:true /commit:apphost
    
    # Limpiar y aplicar reglas de autorizacion via appcmd
    & $appcmd set config "FTP_Practica05" /section:system.ftpServer/security/authorization /-"[users='*']" /commit:apphost 2>$null
    & $appcmd set config "FTP_Practica05" /section:system.ftpServer/security/authorization /+"[accessType='Allow',users='*',permissions='Read,Write']" /commit:apphost
    
    # Abrir Firewall
    Write-Host "[*] Abriendo Firewall de Windows..." -ForegroundColor Cyan
    if (!(Get-NetFirewallRule -DisplayName "FTP Servidor" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Servidor" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 21, 1024-65535
    }

    # Reiniciar el sitio
    Stop-Website -Name "FTP_Practica05" -ErrorAction SilentlyContinue
    Start-Website -Name "FTP_Practica05"
    
    # Reiniciar servicio FTP completo
    Restart-Service ftpsvc -ErrorAction SilentlyContinue
    
    Write-Host ""
    Write-Host "[+] Sitio FTP configurado exitosamente." -ForegroundColor Green
    Write-Host "[*] Verificacion:" -ForegroundColor Cyan
    Get-Website -Name "FTP_Practica05" | Format-Table Name, State, PhysicalPath -AutoSize
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

        # Gestion de Usuario Local
        $userExists = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
        if (!$userExists) {
            try {
                New-LocalUser -Name $user -Password $pass -FullName "FTP User $user" -Description "Usuario Practica 05" -ErrorAction Stop | Out-Null
                Write-Host "[+] Usuario $user creado." -ForegroundColor Green
            } catch {
                Write-Host "[-] ERROR: Al crear el usuario $user. Compruebe la contrasena." -ForegroundColor Red
                continue 
            }
        } else {
            Write-Host "[!] El usuario $user ya existe. Actualizando configuracion..." -ForegroundColor Yellow
            # Opcional: Actualizar contrasena si ya existe
            Set-LocalUser -Name $user -Password $pass -ErrorAction SilentlyContinue
        }

        # Asegurar membresia de grupos (esto corre siempre)
        Add-LocalGroupMember -Group $targetGroup -Member $user -ErrorAction SilentlyContinue
        Add-LocalGroupMember -Group "Users" -Member $user -ErrorAction SilentlyContinue
        
        # Gestion de Carpetas y Junctions (esto corre siempre)
        $userRoot = "C:\ftp_root\LocalUser\$user"
        if (!(Test-Path $userRoot)) {
            New-Item -ItemType Directory -Path $userRoot -Force | Out-Null
        }
        
        # Dar permisos NTFS al usuario sobre su carpeta
        $userAcl = Get-Acl $userRoot
        $userPermission = New-Object System.Security.AccessControl.FileSystemAccessRule($user,"FullControl","ContainerInherit,ObjectInherit","None","Allow")
        $userAcl.SetAccessRule($userPermission)
        Set-Acl $userRoot $userAcl
        
        $juncGeneral = Join-Path $userRoot "general"
        $juncGroup = Join-Path $userRoot $targetGroup
        
        if (!(Test-Path $juncGeneral)) { cmd /c mklink /j "$juncGeneral" "C:\ftp_root\general" }
        if (!(Test-Path $juncGroup)) { cmd /c mklink /j "$juncGroup" "C:\ftp_root\grupos\$targetGroup" }

        Write-Host "[+] Usuario $user configurado y mapeado a $targetGroup correctamente." -ForegroundColor Green
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
    
    $localUser = Get-LocalUser -Name $userLogin -ErrorAction SilentlyContinue
    if ($localUser) {
        # Verificar grupos de forma robusta
        $inGroup = $false
        $ftpGroups = @("reprobados", "recursadores")
        foreach ($grpName in $ftpGroups) {
            $members = Get-LocalGroupMember -Group $grpName -ErrorAction SilentlyContinue
            # Buscamos el nombre del usuario al final de la cadena (por si tiene SERVER\ delante)
            if ($members | Where-Object { ($_.Name -split '\\' | Select-Object -Last 1) -eq $userLogin }) {
                $inGroup = $true
                break
            }
        }

        if (!$inGroup) {
            Write-Host "[-] El usuario '$userLogin' existe pero no esta asignado a 'reprobados' o 'recursadores'." -ForegroundColor Red
            return
        }

        $passInput = Read-Host "Contrasena"
        Write-Host "[+] Login exitoso! Bienvenido, $userLogin." -ForegroundColor Green
        Write-Host "[*] Tus carpetas FTP vinculadas:"
        $loginRoot = "C:\ftp_root\LocalUser\$userLogin"
        if (Test-Path $loginRoot) {
            Get-ChildItem -Path $loginRoot | Select-Object Name
        } else {
            Write-Host "[!] Advertencia: La carpeta fisica no fue encontrada en $loginRoot" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[-] El usuario '$userLogin' no existe en este servidor." -ForegroundColor Red
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
