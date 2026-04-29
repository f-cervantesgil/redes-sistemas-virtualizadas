# ==============================================================================
# Script de Preparación para Práctica 09 - Hardening, RBAC y Auditoría
# Ejecutar en el Servidor (Windows Server 2022) como Administrador
# ==============================================================================

Import-Module ActiveDirectory

$DomainName = (Get-ADDomain).DistinguishedName
$Password = Read-Host -AsSecureString "Introduce una contrasena segura para todos los usuarios (ej. P@ssw0rd2026!)"

Write-Host "1. Creando Unidades Organizativas (OUs)..." -ForegroundColor Cyan
$OUs = @("Cuates", "No Cuates", "Admins_Delegados")
foreach ($OU in $OUs) {
    try {
        New-ADOrganizationalUnit -Name $OU -Path $DomainName -ErrorAction Stop
        Write-Host "   [+] OU '$OU' creada exitosamente." -ForegroundColor Green
    } catch {
        Write-Host "   [-] La OU '$OU' ya existe o hubo un error." -ForegroundColor Yellow
    }
}

Write-Host "`n2. Creando usuarios de administración delegada..." -ForegroundColor Cyan
$Users = @(
    @{ Name = "admin_identidad"; Desc = "Operador de Identidad y Acceso" },
    @{ Name = "admin_storage"; Desc = "Operador de Almacenamiento y Recursos" },
    @{ Name = "admin_politicas"; Desc = "Administrador de Cumplimiento y Directivas" },
    @{ Name = "admin_auditoria"; Desc = "Auditor de Seguridad y Eventos" }
)

foreach ($User in $Users) {
    try {
        New-ADUser -Name $User.Name -SamAccountName $User.Name -UserPrincipalName "$($User.Name)@$((Get-ADDomain).Forest.Name)" -Path "OU=Admins_Delegados,$DomainName" -AccountPassword $Password -Enabled $true -Description $User.Desc -PasswordNeverExpires $true -ErrorAction Stop
        Write-Host "   [+] Usuario '$($User.Name)' creado." -ForegroundColor Green
    } catch {
        Write-Host "   [-] El usuario '$($User.Name)' ya existe o hubo un error." -ForegroundColor Yellow
    }
}

Write-Host "`n3. Configurando Grupos Integrados Básicos..." -ForegroundColor Cyan
# Agregar admin_auditoria al grupo de Lectores de registro de eventos
Add-ADGroupMember -Identity "Event Log Readers" -Members "admin_auditoria" -ErrorAction SilentlyContinue
Write-Host "   [+] admin_auditoria agregado a 'Event Log Readers'." -ForegroundColor Green

Write-Host "`n4. Configurando Directivas de Contrasena Ajustada (FGPP)..." -ForegroundColor Cyan
# FGPP para Administradores (12 caracteres)
try {
    New-ADFineGrainedPasswordPolicy -Name "FGPP_Admins_12Chars" -Precedence 10 -ComplexityEnabled $true -Description "Politica estricta para admins" -DisplayName "FGPP_Admins_12Chars" -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00" -LockoutThreshold 3 -MaxPasswordAge "30.00:00:00" -MinPasswordAge "1.00:00:00" -MinPasswordLength 12 -PasswordHistoryCount 5 -ReversibleEncryptionEnabled $false
    Add-ADFineGrainedPasswordPolicySubject -Identity "FGPP_Admins_12Chars" -Subjects "admin_identidad", "admin_storage", "admin_politicas", "admin_auditoria"
    Write-Host "   [+] FGPP de 12 caracteres creada y asignada." -ForegroundColor Green
} catch {
    Write-Host "   [-] FGPP de 12 caracteres ya existe o hubo un error." -ForegroundColor Yellow
}

# FGPP para Usuarios Estándar (8 caracteres)
try {
    New-ADFineGrainedPasswordPolicy -Name "FGPP_Standard_8Chars" -Precedence 20 -ComplexityEnabled $true -Description "Politica estandar" -DisplayName "FGPP_Standard_8Chars" -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00" -LockoutThreshold 5 -MaxPasswordAge "90.00:00:00" -MinPasswordAge "1.00:00:00" -MinPasswordLength 8 -PasswordHistoryCount 3 -ReversibleEncryptionEnabled $false
    # Aplicar a las OUs no funciona directo con FGPP, se requiere un grupo Global. Creamos el grupo y lo asignamos.
    New-ADGroup -Name "Usuarios_Estandar" -GroupCategory Security -GroupScope Global -Path "OU=Cuates,$DomainName" -ErrorAction SilentlyContinue
    Add-ADFineGrainedPasswordPolicySubject -Identity "FGPP_Standard_8Chars" -Subjects "Usuarios_Estandar"
    Write-Host "   [+] FGPP de 8 caracteres creada y asignada al grupo 'Usuarios_Estandar'." -ForegroundColor Green
} catch {
    Write-Host "   [-] FGPP de 8 caracteres ya existe o hubo un error." -ForegroundColor Yellow
}

Write-Host "`n5. Habilitando Auditoría de Inicio de Sesión y Acceso a Objetos..." -ForegroundColor Cyan
auditpol /set /subcategory:"Logon" /success:enable /failure:enable
auditpol /set /subcategory:"File System" /success:enable /failure:enable
Write-Host "   [+] Políticas de auditoría aplicadas." -ForegroundColor Green

Write-Host "`n=============================================================================="
Write-Host "¡Script finalizado! Por favor sigue la Guía para realizar la Delegación (ACLs)"
Write-Host "manualmente y configurar la herramienta de MFA de terceros."
Write-Host "=============================================================================="
