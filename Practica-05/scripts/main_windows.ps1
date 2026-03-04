<#
   Servidor FTP en Windows Server 2022 (IIS)
#>

Import-Module WebAdministration -ErrorAction SilentlyContinue

# ============================================================
# 1. Instalacion de Roles FTP
# ============================================================
Function Install-FTPServer {
    Write-Host "[*] Verificando e Instalando Rol FTP..." -ForegroundColor Cyan
    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service", "Web-Ftp-Ext", "Web-Mgmt-Console")
    foreach ($f in $features) {
        $feat = Get-WindowsFeature $f -ErrorAction SilentlyContinue
        if ($feat -and !$feat.Installed) {
            Install-WindowsFeature $f
            Write-Host "[+] Instalado: $f" -ForegroundColor Green
        }
    }
    Write-Host "[+] Roles FTP verificados." -ForegroundColor Green
}

# ============================================================
# 2. Configuracion Base (Grupos, Directorios, Permisos, Politicas)
# ============================================================
Function Initialize-Environment {
    Write-Host "[*] Inicializando Grupos y Directorios..." -ForegroundColor Cyan

    # --- Relajar Politicas de Contrasena ---
    Write-Host "[*] Relajando politicas de contrasenas..." -ForegroundColor Yellow
    net accounts /minpwlen:0 /maxpwage:unlimited /minpwage:0 /unique:0 2>$null
    $cfgFile = "$env:TEMP\pwd_policy.inf"
    secedit /export /cfg $cfgFile /quiet 2>$null
    if (Test-Path $cfgFile) {
        $content = Get-Content $cfgFile
        $content = $content -replace "PasswordComplexity = 1", "PasswordComplexity = 0"
        $content = $content -replace "MinimumPasswordLength = .*", "MinimumPasswordLength = 0"
        $content = $content -replace "PasswordHistorySize = .*", "PasswordHistorySize = 0"
        $content | Set-Content $cfgFile
        secedit /configure /db "$env:TEMP\pwd.sdb" /cfg $cfgFile /areas SECURITYPOLICY /quiet 2>$null
        Remove-Item $cfgFile -ErrorAction SilentlyContinue
    }
    Write-Host "[+] Politicas de contrasena relajadas." -ForegroundColor Green

    # --- Crear Grupos ---
    $groups = @("reprobados", "recursadores")
    foreach ($g in $groups) {
        if (!(Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $g -Description "Grupo FTP Practica 05"
            Write-Host "[+] Grupo creado: $g" -ForegroundColor Green
        }
    }

    # --- Crear Estructura de Carpetas ---
    # C:\ftp_root\                     -> Raiz del sitio FTP
    # C:\ftp_root\publica              -> Carpeta compartida (todos)
    # C:\ftp_root\grupos\reprobados    -> Solo miembros del grupo
    # C:\ftp_root\grupos\recursadores  -> Solo miembros del grupo
    # C:\ftp_root\LocalUser\<user>\    -> Home aislado de cada usuario
    # C:\ftp_root\personal\<user>\     -> Datos privados de cada usuario
    $dirs = @(
        "C:\ftp_root",
        "C:\ftp_root\publica",
        "C:\ftp_root\grupos\reprobados",
        "C:\ftp_root\grupos\recursadores",
        "C:\ftp_root\personal",
        "C:\ftp_root\LocalUser",
        "C:\ftp_root\LocalUser\Public"
    )
    foreach ($d in $dirs) {
        if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # --- Permisos NTFS ---
    # Raiz: Everyone=Read, Users=FullControl
    $acl = Get-Acl "C:\ftp_root"
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone","Read","ContainerInherit,ObjectInherit","None","Allow")))
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Users","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl "C:\ftp_root" $acl

    # Publica: Everyone=Modify (leer y escribir para todos)
    $acl2 = Get-Acl "C:\ftp_root\publica"
    $acl2.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone","Modify","ContainerInherit,ObjectInherit","None","Allow")))
    Set-Acl "C:\ftp_root\publica" $acl2

    # Grupos: Solo miembros del grupo pueden leer/escribir
    foreach ($g in $groups) {
        $gAcl = Get-Acl "C:\ftp_root\grupos\$g"
        $gAcl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($g,"Modify","ContainerInherit,ObjectInherit","None","Allow")))
        Set-Acl "C:\ftp_root\grupos\$g" $gAcl
    }

    # Carpeta anonima: junctions a todas las carpetas (solo lectura)
    $anonPub = "C:\ftp_root\LocalUser\Public\publica"
    if (!(Test-Path $anonPub)) { cmd /c mklink /j "$anonPub" "C:\ftp_root\publica" }
    $anonRep = "C:\ftp_root\LocalUser\Public\reprobados"
    if (!(Test-Path $anonRep)) { cmd /c mklink /j "$anonRep" "C:\ftp_root\grupos\reprobados" }
    $anonRec = "C:\ftp_root\LocalUser\Public\recursadores"
    if (!(Test-Path $anonRec)) { cmd /c mklink /j "$anonRec" "C:\ftp_root\grupos\recursadores" }

    Write-Host "[+] Entorno base configurado." -ForegroundColor Green
}

# ============================================================
# 3. Configurar Sitio FTP en IIS
# ============================================================
Function Setup-FTPSite {
    Write-Host "[*] Configurando Sitio FTP en IIS..." -ForegroundColor Cyan
    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"

    # Desbloquear secciones de seguridad
    & $appcmd unlock config /section:system.ftpServer/security/authentication 2>$null
    & $appcmd unlock config /section:system.ftpServer/security/authorization 2>$null
    & $appcmd unlock config /section:system.ftpServer/security/ssl 2>$null

    # Detener sitios que puedan estar usando el puerto 21
    Stop-Website -Name "Default Web Site" -ErrorAction SilentlyContinue

    # Eliminar sitio FTP anterior si existe
    if (Get-Website -Name "FTP_Practica05" -ErrorAction SilentlyContinue) {
        Remove-Website -Name "FTP_Practica05"
        Write-Host "[!] Sitio anterior eliminado." -ForegroundColor Yellow
    }

    # Crear nuevo sitio FTP
    New-WebFtpSite -Name "FTP_Practica05" -Port 21 -PhysicalPath "C:\ftp_root" -Force

    # Aislamiento de Usuarios: cada usuario entra a C:\ftp_root\LocalUser\<usuario>
    # Modo 2 = IsolateUsers (para usuarios locales)
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.userIsolation.mode -Value 2

    # Desactivar SSL (Permitir texto plano)
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0

    # Habilitar Autenticacion Basica y Anonima
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\FTP_Practica05" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true

    # Reglas de Autorizacion: Permitir a todos leer y escribir
    Clear-WebConfiguration -Filter "/system.ftpServer/security/authorization" -PSPath "IIS:\Sites\FTP_Practica05" -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -Filter "/system.ftpServer/security/authorization" -Name "." `
        -Value @{accessType="Allow"; users="*"; permissions="Read, Write"} `
        -PSPath "IIS:\Sites\FTP_Practica05" -ErrorAction SilentlyContinue

    # Firewall
    Write-Host "[*] Abriendo Firewall..." -ForegroundColor Cyan
    if (!(Get-NetFirewallRule -DisplayName "FTP Servidor" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP Servidor" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 21, 1024-65535
    }

    # Reiniciar servicio FTP
    Restart-Service ftpsvc -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "[+] Sitio FTP configurado exitosamente." -ForegroundColor Green
    Write-Host "[*] Verificacion:" -ForegroundColor Cyan
    Get-Website -Name "FTP_Practica05" | Format-Table Name, State, PhysicalPath -AutoSize
}

# ============================================================
# 4. Alta Masiva de Usuarios
# ============================================================
Function Add-FTPUsers {
    param([int]$n)

    for ($i = 1; $i -le $n; $i++) {
        $user = Read-Host "Nombre para el usuario $i"
        $passString = Read-Host "Contrasena para $user"
        $pass = ConvertTo-SecureString $passString -AsPlainText -Force

        $groupName = Read-Host "Grupo (1: reprobados, 2: recursadores)"
        $targetGroup = if ($groupName -eq "1") { "reprobados" } else { "recursadores" }

        # -- Crear o actualizar usuario --
        $userExists = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
        if (!$userExists) {
            try {
                New-LocalUser -Name $user -Password $pass -FullName "FTP $user" -Description "Practica 05" -ErrorAction Stop | Out-Null
                Write-Host "[+] Usuario $user creado." -ForegroundColor Green
            } catch {
                Write-Host "[-] ERROR al crear $user. Verifique la contrasena." -ForegroundColor Red
                continue
            }
        } else {
            Write-Host "[!] $user ya existe. Actualizando..." -ForegroundColor Yellow
            Set-LocalUser -Name $user -Password $pass -ErrorAction SilentlyContinue
        }

        # Asegurar membresia de grupos
        Add-LocalGroupMember -Group $targetGroup -Member $user -ErrorAction SilentlyContinue
        Add-LocalGroupMember -Group "Users" -Member $user -ErrorAction SilentlyContinue

        # -- Estructura de Carpetas del Usuario --
        # C:\ftp_root\LocalUser\<user>\publica   -> junction a C:\ftp_root\publica
        # C:\ftp_root\LocalUser\<user>\<grupo>   -> junction a C:\ftp_root\grupos\<grupo>
        # C:\ftp_root\LocalUser\<user>\personal  -> junction a C:\ftp_root\personal\<user>
        $userRoot = "C:\ftp_root\LocalUser\$user"
        if (!(Test-Path $userRoot)) {
            New-Item -ItemType Directory -Path $userRoot -Force | Out-Null
        }

        # Permisos NTFS sobre su carpeta
        $uAcl = Get-Acl $userRoot
        $uAcl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($user,"FullControl","ContainerInherit,ObjectInherit","None","Allow")))
        Set-Acl $userRoot $uAcl

        # Junction: publica
        $jPub = Join-Path $userRoot "publica"
        if (!(Test-Path $jPub)) { cmd /c mklink /j "$jPub" "C:\ftp_root\publica" }

        # Junction: grupo
        $jGrp = Join-Path $userRoot $targetGroup
        if (!(Test-Path $jGrp)) { cmd /c mklink /j "$jGrp" "C:\ftp_root\grupos\$targetGroup" }

        # Carpeta personal
        $personalSrc = "C:\ftp_root\personal\$user"
        if (!(Test-Path $personalSrc)) { New-Item -ItemType Directory -Path $personalSrc -Force | Out-Null }
        # Permisos: solo el usuario puede acceder
        $pAcl = Get-Acl $personalSrc
        $pAcl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($user,"FullControl","ContainerInherit,ObjectInherit","None","Allow")))
        Set-Acl $personalSrc $pAcl

        $jPers = Join-Path $userRoot "personal"
        if (!(Test-Path $jPers)) { cmd /c mklink /j "$jPers" "$personalSrc" }

        Write-Host "[+] $user -> $targetGroup (3 carpetas: publica, $targetGroup, personal)" -ForegroundColor Green
    }
}

# ============================================================
# 5. Cambiar Grupo de Usuario
# ============================================================
Function Change-UserGroup {
    $user = Read-Host "Usuario a cambiar de grupo"
    if (!(Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
        Write-Host "[-] Usuario no encontrado." -ForegroundColor Red
        return
    }

    $opt = Read-Host "Nuevo Grupo (1: reprobados, 2: recursadores)"
    $newGroup = if ($opt -eq "1") { "reprobados" } else { "recursadores" }
    $oldGroup = if ($opt -eq "1") { "recursadores" } else { "reprobados" }

    # Quitar del grupo viejo, agregar al nuevo
    Remove-LocalGroupMember -Group $oldGroup -Member $user -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group $newGroup -Member $user -ErrorAction SilentlyContinue

    $userRoot = "C:\ftp_root\LocalUser\$user"

    # Eliminar junction del grupo viejo
    $oldJunc = Join-Path $userRoot $oldGroup
    if (Test-Path $oldJunc) {
        cmd /c rmdir "$oldJunc"
        Write-Host "[*] Carpeta $oldGroup removida." -ForegroundColor Yellow
    }

    # Crear junction del grupo nuevo
    $newJunc = Join-Path $userRoot $newGroup
    if (!(Test-Path $newJunc)) {
        cmd /c mklink /j "$newJunc" "C:\ftp_root\grupos\$newGroup"
    }

    Write-Host "[+] $user movido de $oldGroup a $newGroup." -ForegroundColor Green
    Write-Host "[*] Ahora ve: publica, $newGroup, personal" -ForegroundColor Cyan
}

# ============================================================
# 6. Eliminar Usuario
# ============================================================
Function Remove-FTPUser {
    $user = Read-Host "Usuario a eliminar"
    if (!(Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
        Write-Host "[-] Usuario no encontrado." -ForegroundColor Red
        return
    }

    Write-Host "[*] Eliminando $user..." -ForegroundColor Yellow

    # Eliminar junctions primero (rmdir no borra el contenido real)
    $userRoot = "C:\ftp_root\LocalUser\$user"
    if (Test-Path $userRoot) {
        Get-ChildItem $userRoot | ForEach-Object {
            if ($_.Attributes -match "ReparsePoint") {
                cmd /c rmdir $_.FullName
            } else {
                Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
        Remove-Item $userRoot -Force -ErrorAction SilentlyContinue
    }

    # Eliminar carpeta personal
    $personalDir = "C:\ftp_root\personal\$user"
    if (Test-Path $personalDir) {
        Remove-Item $personalDir -Force -Recurse -ErrorAction SilentlyContinue
    }

    # Eliminar usuario
    Remove-LocalUser -Name $user
    Write-Host "[+] Usuario $user eliminado." -ForegroundColor Green
}

# ============================================================
# 7. Listar Usuarios Registrados
# ============================================================
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
                Write-Output ("{0,-25} {1,-20}" -f "USUARIO", "GRUPO")
                Write-Output ("{0,-25} {1,-20}" -f "-------", "-----")
                $anyUser = $true
            }
            foreach ($m in $members) {
                $shortName = ($m.Name -split '\\')[-1]
                Write-Output ("{0,-25} {1,-20}" -f $shortName, $g)
            }
        }
    }

    if (!$anyUser) {
        Write-Host "[!] No hay usuarios registrados." -ForegroundColor Yellow
    }
    Write-Host "------------------------------------------"
}

# ============================================================
# 8. Login Simulado
# ============================================================
Function Test-UserLogin {
    Write-Host ""
    Write-Host "--- INICIO DE SESION ---" -ForegroundColor Cyan
    $userLogin = Read-Host "Nombre de usuario"

    $localUser = Get-LocalUser -Name $userLogin -ErrorAction SilentlyContinue
    if (!$localUser) {
        Write-Host "[-] El usuario '$userLogin' no existe." -ForegroundColor Red
        return
    }

    # Verificar grupo
    $inGroup = $false
    foreach ($grpName in @("reprobados", "recursadores")) {
        $members = Get-LocalGroupMember -Group $grpName -ErrorAction SilentlyContinue
        foreach ($m in $members) {
            $shortName = ($m.Name -split '\\')[-1]
            if ($shortName -eq $userLogin) {
                $inGroup = $true
                break
            }
        }
        if ($inGroup) { break }
    }

    if (!$inGroup) {
        Write-Host "[-] '$userLogin' no pertenece a reprobados ni recursadores." -ForegroundColor Red
        return
    }

    $passInput = Read-Host "Contrasena"
    Write-Host "[+] Login exitoso! Bienvenido, $userLogin." -ForegroundColor Green
    Write-Host "[*] Carpetas FTP:" -ForegroundColor Cyan
    $loginRoot = "C:\ftp_root\LocalUser\$userLogin"
    if (Test-Path $loginRoot) {
        Get-ChildItem -Path $loginRoot | ForEach-Object { Write-Host "   - $($_.Name)" }
    } else {
        Write-Host "[!] No se encontro el directorio FTP." -ForegroundColor Yellow
    }
}

# ============================================================
# MENU PRINCIPAL
# ============================================================
while ($true) {
    cls
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "   ADMINISTRACION DE SERVIDOR FTP (WINDOWS SERVER)  " -ForegroundColor Cyan
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

    switch ($choice) {
        "1" {
            Install-FTPServer
            Initialize-Environment
            Setup-FTPSite
        }
        "2" {
            $count = Read-Host "Cuantos usuarios desea crear?"
            if ($count -as [int]) { Add-FTPUsers -n ([int]$count) }
        }
        "3" { Get-RegisteredFTPUsers }
        "4" { Change-UserGroup }
        "5" { Remove-FTPUser }
        "6" { Test-UserLogin }
        "7" { Write-Host "Saliendo..."; exit }
        Default {
            Write-Host "Opcion no valida." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
    }

    Write-Host ""
    Read-Host "Presione Enter para volver al menu..."
}
