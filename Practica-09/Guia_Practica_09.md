# Guía de Implementación — Práctica 09
# Seguridad de Identidad, Delegación y MFA

## ¿Qué vamos a construir?

Un sistema de **identidad corporativa segura** sobre Active Directory con tres capas de protección:

| Capa | Componente | Descripción |
|------|-----------|-------------|
| **1 — RBAC** | Delegación AD | Cada admin solo puede hacer lo que le corresponde |
| **2 — FGPP** | Password Policy | Contraseñas más estrictas para cuentas privilegiadas |
| **3 — MFA** | MultiOTP + TOTP | Segundo factor con Google Authenticator en el login |

## 🖥️ Infraestructura del Laboratorio

| Máquina | SO | IP | Rol |
|---------|----|----|-----|
| **WS2022-DC** | Windows Server 2022 | `192.168.56.10` | Controlador de Dominio |
| **WIN10-CLI** | Windows 10 Pro | `192.168.56.30` | Cliente unido al dominio |
| **MINT-CLI** | Linux Mint 21 | `192.168.56.20` | Cliente Linux unido al dominio |

**Dominio:** `redes.local`  
**NetBIOS:** `REDES`  
**Admin principal:** `Administrador / Admin@Redes2026!`

---

## 📁 Archivos del Proyecto

```
Practica-09/
├── Guia_Practica_09.md          ← Este archivo
└── scripts/
    ├── p09_deploy.ps1           ← Instalador automático
    ├── p09_menu.ps1             ← Menú principal
    ├── p09_modulo1_rbac.ps1     ← Delegación RBAC en AD
    ├── p09_modulo2_fgpp_audit.ps1  ← FGPP + Auditoría
    ├── p09_modulo3_monitoreo.ps1   ← Reportes de seguridad
    ├── p09_modulo4_mfa_guia.ps1    ← Guía MFA + bloqueo
    ├── p09_modulo5_tests.ps1       ← Protocolo de pruebas
    └── P09_PROTOCOLO_PRUEBA.txt    ← Protocolo detallado
```

---

## FASE 0 — PREPARACIÓN DE LA RED VIRTUAL

> ⚠️ Realiza esto ANTES de encender las máquinas virtuales.

### 0.1 — Crear la red host-only en VirtualBox

1. Abre **VirtualBox** → menú **Archivo** → **Administrador de red de host**
2. Haz clic en **Crear** → aparece `vboxnet0` (o similar)
3. Configura:
   - **Dirección IPv4:** `192.168.56.1`
   - **Máscara:** `255.255.255.0`
   - **DHCP:** **desactivado** (IPs manuales)
4. Clic en **Aplicar** y cierra

### 0.2 — Asignar adaptadores a cada VM

Para **cada** máquina virtual:
1. Selecciona la VM → **Configuración** → **Red**
2. Adaptador 1: `NAT` (para internet)
3. Adaptador 2: `Solo-anfitrión (Host-only)` → selecciona `vboxnet0`
4. Clic en **Aceptar**

---

## FASE 1 — CONFIGURAR WINDOWS SERVER 2022 (DC)

### 1.1 — Configuración de red estática

1. Inicia sesión en Windows Server 2022 como **Administrador**
2. Abre **Panel de control** → **Centro de redes** → **Cambiar configuración del adaptador**
3. Clic derecho en el adaptador **Ethernet 2** (el host-only) → **Propiedades**
4. Selecciona **Protocolo de Internet versión 4 (TCP/IPv4)** → **Propiedades**
5. Configura:

```
Dirección IP:      192.168.56.10
Máscara de subred: 255.255.255.0
Puerta de enlace:  (dejar vacío)
DNS preferido:     127.0.0.1
DNS alternativo:   (dejar vacío)
```

6. Clic en **Aceptar** en todos los cuadros

### 1.2 — Cambiar el nombre del servidor

Abre **PowerShell como Administrador** y ejecuta:

```powershell
Rename-Computer -NewName "WS2022-DC" -Force
Restart-Computer
```

Después del reinicio, inicia sesión de nuevo como Administrador.

### 1.3 — Instalar Active Directory Domain Services

```powershell
# Instalar el rol AD DS
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Verificar que se instaló
Get-WindowsFeature AD-Domain-Services
```

### 1.4 — Promover el servidor a Controlador de Dominio

```powershell
# Crear el nuevo bosque y dominio redes.local
Install-ADDSForest `
    -DomainName "redes.local" `
    -DomainNetbiosName "REDES" `
    -SafeModeAdministratorPassword (ConvertTo-SecureString "Admin@Redes2026!" -AsPlainText -Force) `
    -InstallDns:$true `
    -Force:$true
```

> El servidor se reiniciará automáticamente. Espera 3-5 minutos.

### 1.5 — Verificar que el dominio funciona

Inicia sesión como `REDES\Administrador` y ejecuta:

```powershell
# Ver información del dominio
Get-ADDomain

# Ver el servidor DNS
Get-DnsServerZone

# Ver la política de contraseñas por defecto
Get-ADDefaultDomainPasswordPolicy
```

**Resultado esperado:** Verás `redes.local` como DomainName y el servidor listado como DNS.

📸 **Captura:** La salida de `Get-ADDomain` mostrando `redes.local`

### 1.6 — Crear usuarios de prueba en el dominio

```powershell
# Crear Unidades Organizativas base
New-ADOrganizationalUnit -Name "Cuates"   -Path "DC=redes,DC=local" -ProtectedFromAccidentalDeletion $false
New-ADOrganizationalUnit -Name "NoCuates" -Path "DC=redes,DC=local" -ProtectedFromAccidentalDeletion $false

# Crear usuarios de prueba en OU Cuates
$pass = ConvertTo-SecureString "Usuario@2026!" -AsPlainText -Force

New-ADUser -Name "Juan Garcia"   -SamAccountName "jgarcia"   -UserPrincipalName "jgarcia@redes.local"   -Path "OU=Cuates,DC=redes,DC=local"   -AccountPassword $pass -Enabled $true -PasswordNeverExpires $true
New-ADUser -Name "Maria Lopez"   -SamAccountName "mlopez"    -UserPrincipalName "mlopez@redes.local"    -Path "OU=Cuates,DC=redes,DC=local"   -AccountPassword $pass -Enabled $true -PasswordNeverExpires $true
New-ADUser -Name "Pedro Ramos"   -SamAccountName "pramos"    -UserPrincipalName "pramos@redes.local"    -Path "OU=NoCuates,DC=redes,DC=local" -AccountPassword $pass -Enabled $true -PasswordNeverExpires $true

# Verificar
Get-ADUser -Filter * -SearchBase "DC=redes,DC=local" | Select-Object Name, SamAccountName, Enabled
```

---

## FASE 2 — DESPLEGAR SCRIPTS DE LA PRÁCTICA 09

### 2.1 — Copiar los scripts al servidor

Desde tu **PC con Windows** (o directamente en el servidor), abre PowerShell:

```powershell
# Si copias desde tu PC hacia el servidor por SCP:
scp -r "C:\Users\alfre\Desktop\redes-sistemas-virtualizadas\Practica-09\scripts\*" Administrador@192.168.56.10:C:\P09\
```

**O bien**, en el servidor directamente:

```powershell
# Crear carpeta destino
New-Item -ItemType Directory -Path "C:\P09" -Force

# Si tienes los archivos en una carpeta compartida accesible como Z:\
# Copia todos los scripts p09_*.ps1 a C:\P09\
Copy-Item "Z:\scripts\p09_*.ps1" -Destination "C:\P09\" -Force
Copy-Item "Z:\scripts\P09_PROTOCOLO_PRUEBA.txt" -Destination "C:\P09\" -Force
```

### 2.2 — Ejecutar el script de despliegue

```powershell
# Habilitar ejecución de scripts
Set-ExecutionPolicy Bypass -Scope Process -Force

# Ejecutar desde C:\P09
cd C:\P09
.\p09_menu.ps1
```

Verás el menú principal con los 5 módulos.

---

## FASE 3 — MÓDULO 1: DELEGACIÓN RBAC

> **¿Qué hace?** Crea 4 roles administrativos con permisos mínimos necesarios sobre Active Directory. El principio de mínimo privilegio aplicado.

### 3.1 — Abrir el Módulo 1

Desde el menú P09 → selecciona **Módulo 1 — RBAC**  
**O directamente:**

```powershell
cd C:\P09
.\p09_modulo1_rbac.ps1
```

### 3.2 — Ejecutar TODO automáticamente

En el menú del Módulo 1 → escribe `7` → Enter

Esto crea automáticamente:

| Usuario | Rol | Permisos |
|---------|-----|---------|
| `admin_identidad` | Operador IAM | Reset password, desbloquear cuentas, editar atributos en OU Cuates y NoCuates |
| `admin_storage` | Operador Storage | **SIN** permiso de Reset Password (denegado explícitamente) |
| `admin_politicas` | Admin GPO | Lectura del dominio + miembro de "Group Policy Creator Owners" |
| `admin_auditoria` | Auditor | Solo lectura + miembro de "Event Log Readers" |

**Contraseña de todos:** `Admin@Practica09!`

### 3.3 — Verificar la delegación manualmente

```powershell
# Ver resumen de usuarios (opción 8 del menú)
# O directamente:
Get-ADUser -Filter "SamAccountName -like 'admin_*'" -Properties Description | 
    Select-Object SamAccountName, Description, Enabled

# Ver miembros de Event Log Readers
Get-ADGroupMember -Identity "Event Log Readers" | Select-Object Name, SamAccountName
```

📸 **Captura:** La lista de los 4 usuarios delegados creados

---

## FASE 4 — MÓDULO 2: FGPP + AUDITORÍA

> **¿Qué hace?** Fine-Grained Password Policies: contraseñas con requisitos distintos según el tipo de cuenta. Los administradores necesitan contraseñas más largas.

### 4.1 — Ejecutar Módulo 2 completo

En el menú del Módulo 2 → escribe `7` → Enter  
**O directamente:**

```powershell
.\p09_modulo2_fgpp_audit.ps1
# Seleccionar opción 7
```

Esto crea:

| PSO (FGPP) | Mín. chars | Lockout | Aplica a |
|-----------|-----------|---------|---------|
| `PSO-Admins-P09` | **12** | 5 intentos / 30 min | GrupoAdminsP09 (los 4 admin_*) |
| `PSO-Usuarios-P09` | **8** | 5 intentos / 30 min | G_Cuates, G_NoCuates |

### 4.2 — Verificar FGPP creadas

```powershell
# Ver todas las FGPP del dominio
Get-ADFineGrainedPasswordPolicy -Filter * | 
    Sort-Object Precedence | 
    Format-Table Name, MinPasswordLength, LockoutThreshold, Precedence -AutoSize

# Ver FGPP efectiva para admin_identidad
Get-ADUserResultantPasswordPolicy -Identity admin_identidad
```

**Resultado esperado:** `MinPasswordLength: 12`

📸 **Captura:** La salida de `Get-ADFineGrainedPasswordPolicy` con ambas PSO

### 4.3 — Verificar auditoría habilitada

```powershell
auditpol /get /category:"Logon/Logoff","Object Access","Account Management"
```

**Resultado esperado:** Cada subcategoría mostrará `Success and Failure`

---

## FASE 5 — MÓDULO 4: CONFIGURAR MFA (MultiOTP + TOTP)

> **¿Qué hace?** Añade un segundo factor de autenticación al login de Windows. Después de la contraseña, se pide un código de 6 dígitos que cambia cada 30 segundos.

### 5.1 — Descargar MultiOTP

En el servidor (con acceso a internet por NAT):

1. Abre **Microsoft Edge**
2. Ve a: `https://www.multiotp.net/`
3. Descarga: **multiotp-windows-credential-provider** (archivo `.zip`)
4. También descarga **multiotp** (la herramienta de línea de comandos)

**O usa PowerShell:**

```powershell
# Crear carpeta
New-Item -ItemType Directory -Path "C:\multiotp" -Force

# Descargar multiotp (línea de comandos)
Invoke-WebRequest -Uri "https://github.com/multiOTP/multiotp/releases/download/5.9.9.1/multiotp_5.9.9.1_windows.zip" -OutFile "C:\multiotp\multiotp.zip"

# Extraer
Expand-Archive -Path "C:\multiotp\multiotp.zip" -DestinationPath "C:\multiotp\" -Force
```

### 5.2 — Configurar MultiOTP en línea de comandos

```powershell
cd "C:\multiotp"

# Inicializar MultiOTP con el servidor como "localhost"
.\multiotp.exe -config server-ip=127.0.0.1

# Crear usuario MFA para el Administrador
.\multiotp.exe -create Administrador TOTP sha1 1234567890abcdef 6

# Activar el usuario
.\multiotp.exe -set Administrador synchronized=1

# Verificar
.\multiotp.exe -debug -display-log Administrador
```

### 5.3 — Instalar el Credential Provider

```powershell
# Suponiendo que descargaste el credential provider en C:\multiotp\CredProvider\

# Copiar DLL al sistema
Copy-Item "C:\multiotp\CredProvider\MultiotpCredentialProvider.dll" `
          "C:\Windows\System32\" -Force

Copy-Item "C:\multiotp\CredProvider\MultiotpCredentialProvider.ini" `
          "C:\Windows\System32\" -Force

# Registrar el Credential Provider
regsvr32 "C:\Windows\System32\MultiotpCredentialProvider.dll"
```

Aparecerá un cuadro diciendo **"DllRegisterServer en ... tuvo éxito"** → clic en **Aceptar**

### 5.4 — Configurar el secreto compartido en Google Authenticator

```powershell
# Ver el secreto Base32 del usuario Administrador
cd "C:\multiotp"
.\multiotp.exe -qrcode Administrador "C:\multiotp\qr_admin.png"

# Abrir el QR generado
Start-Process "C:\multiotp\qr_admin.png"
```

En tu **celular**:
1. Abre **Google Authenticator** (o Microsoft Authenticator)
2. Pulsa **"+"** → **"Escanear código QR"**
3. Apunta la cámara al QR en pantalla
4. Verás aparecer **"redes.local — Administrador"** con un código de 6 dígitos

### 5.5 — Configurar bloqueo MFA (Módulo 4, opción 2 y 3)

```powershell
.\p09_modulo4_mfa_guia.ps1
# Opción 2: Configurar FGPP bloqueo MFA (3 intentos / 30 min)
# Opción 3: Configurar política dominio
```

**O manualmente:**

```powershell
# Política de dominio: 3 intentos → bloqueo 30 min
net accounts /lockoutthreshold:3
net accounts /lockoutduration:30
net accounts /lockoutwindow:30

# Verificar
net accounts
```

### 5.6 — Verificar el flujo MFA

1. Presiona **Win + L** para bloquear la pantalla
2. Ingresa usuario: `Administrador` y tu contraseña
3. **Debe aparecer un campo adicional** pidiendo el código TOTP
4. Abre Google Authenticator en tu celular → ingresa el código de 6 dígitos
5. El acceso debe concederse

📸 **Captura:** La pantalla de login con el campo TOTP visible  
📸 **Foto:** El celular con Google Authenticator mostrando el código

---

## FASE 6 — CONFIGURAR WINDOWS 10 CLIENTE

### 6.1 — Configurar la red estática en Windows 10

1. Abre **Configuración** → **Red e Internet** → **Ethernet**
2. Clic en el adaptador host-only → **Editar**
3. Cambia a **Manual** y configura:

```
Dirección IP:      192.168.56.30
Máscara de subred: 255.255.255.0
Puerta de enlace:  (vacío)
DNS preferido:     192.168.56.10
```

### 6.2 — Verificar conectividad con el DC

```cmd
ping 192.168.56.10
nslookup redes.local 192.168.56.10
```

**Resultado esperado:** Ping responde y nslookup resuelve `redes.local`

### 6.3 — Unir Windows 10 al dominio redes.local

1. Clic derecho en **Este equipo** → **Propiedades**
2. Clic en **Cambiar configuración** → **Cambiar...**
3. Selecciona **Dominio** → escribe: `redes.local`
4. Clic en **Aceptar**
5. Ingresa credenciales: `Administrador` / `Admin@Redes2026!`
6. Verás: *"Bienvenido al dominio redes.local"*
7. Reinicia la máquina

**O por PowerShell:**

```powershell
Add-Computer -DomainName "redes.local" `
             -Credential (Get-Credential) `
             -Restart -Force
```

### 6.4 — Verificar desde el servidor que WIN10 aparece en AD

```powershell
# En el servidor DC:
Get-ADComputer -Filter * | Select-Object Name, DNSHostName, Enabled
```

**Resultado esperado:** Verás `WIN10-CLI` en la lista.

### 6.5 — Configurar MultiOTP en Windows 10 (para MFA desde cliente)

En Windows 10 (después de unirse al dominio):

```powershell
# Copiar el Credential Provider desde el servidor
$src = "\\192.168.56.10\C$\Windows\System32\MultiotpCredentialProvider.dll"
Copy-Item $src "C:\Windows\System32\" -Force

$src2 = "\\192.168.56.10\C$\Windows\System32\MultiotpCredentialProvider.ini"
Copy-Item $src2 "C:\Windows\System32\" -Force

regsvr32 "C:\Windows\System32\MultiotpCredentialProvider.dll"
```

Inicia sesión con un usuario de dominio (ej. `REDES\jgarcia`) para verificar que el flujo MFA funciona.

---

## FASE 7 — CONFIGURAR LINUX MINT CLIENTE

### 7.1 — Configurar la red estática en Linux Mint

1. Abre **Configuración del sistema** → **Red**
2. Clic en el engranaje del adaptador conectado a la red host-only
3. Selecciona pestaña **IPv4**
4. Método: **Manual**
5. Configura:

```
Dirección:  192.168.56.20
Máscara:    255.255.255.0
Gateway:    (vacío)
DNS:        192.168.56.10
```

6. Guarda y reconecta la interfaz

**O por terminal:**

```bash
# Usando nmcli (NetworkManager CLI)
# Primero identifica el nombre de la conexión
nmcli connection show

# Edita la conexión (reemplaza "Wired connection 2" con tu nombre real)
nmcli connection modify "Wired connection 2" \
    ipv4.method manual \
    ipv4.addresses 192.168.56.20/24 \
    ipv4.dns 192.168.56.10 \
    ipv4.ignore-auto-dns yes

nmcli connection up "Wired connection 2"
```

### 7.2 — Verificar conectividad

```bash
ping -c 4 192.168.56.10
nslookup redes.local 192.168.56.10
```

### 7.3 — Instalar paquetes para unirse al dominio AD

```bash
sudo apt update
sudo apt install -y \
    realmd \
    sssd \
    sssd-tools \
    libnss-sss \
    libpam-sss \
    adcli \
    samba-common-bin \
    oddjob \
    oddjob-mkhomedir \
    packagekit \
    krb5-user
```

Durante la instalación de `krb5-user` te preguntará el realm:  
→ Escribe: `REDES.LOCAL` (en mayúsculas)

### 7.4 — Configurar /etc/hosts y /etc/resolv.conf

```bash
# Agregar el DC al archivo hosts
echo "192.168.56.10  WS2022-DC.redes.local  WS2022-DC" | sudo tee -a /etc/hosts

# Configurar resolución DNS hacia el DC
sudo nano /etc/resolv.conf
```

Contenido de `/etc/resolv.conf`:

```
search redes.local
nameserver 192.168.56.10
```

### 7.5 — Verificar que se descubre el dominio

```bash
realm discover redes.local
```

**Resultado esperado:**

```
redes.local
  type: kerberos
  realm-name: REDES.LOCAL
  domain-name: redes.local
  configured: no
  server-software: active-directory
  client-software: sssd
  required-package: ...
```

### 7.6 — Unir Linux Mint al dominio

```bash
# Solicitar ticket Kerberos del Administrador
kinit Administrador@REDES.LOCAL

# Unirse al dominio
sudo realm join --user=Administrador redes.local
```

Te pedirá la contraseña: `Admin@Redes2026!`

**Resultado esperado:** Sin mensajes de error = éxito.

### 7.7 — Configurar SSSD para inicio de sesión automático

```bash
sudo nano /etc/sssd/sssd.conf
```

Verifica que contenga (o crea el archivo con):

```ini
[sssd]
domains = redes.local
config_file_version = 2
services = nss, pam

[domain/redes.local]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = REDES.LOCAL
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u@%d
ad_domain = redes.local
use_fully_qualified_names = False
ldap_id_mapping = True
access_provider = ad
```

```bash
# Asegurar permisos correctos
sudo chmod 600 /etc/sssd/sssd.conf

# Reiniciar servicios
sudo systemctl restart sssd
sudo systemctl enable sssd

# Habilitar creación automática de directorio home
sudo pam-auth-update --enable mkhomedir
```

### 7.8 — Verificar que Linux Mint ve los usuarios del dominio

```bash
# Buscar usuario del dominio
id jgarcia

# Resultado esperado: uid=...(jgarcia) gid=...(domain users) groups=...

# Listar usuarios del dominio
getent passwd | grep "redes.local\|@redes"
```

### 7.9 — Iniciar sesión con usuario de dominio en Linux Mint

En la pantalla de login de Linux Mint:
- Usuario: `jgarcia` (sin dominio, gracias a `use_fully_qualified_names = False`)
- Contraseña: `Usuario@2026!`

**O por SSH:**

```bash
ssh jgarcia@192.168.56.20
```

📸 **Captura:** Login exitoso en Linux Mint con usuario del dominio `redes.local`

### 7.10 — Instalar cliente MFA en Linux Mint (Google Authenticator PAM)

Para que Linux Mint también requiera TOTP al hacer ssh o login:

```bash
sudo apt install -y libpam-google-authenticator

# Configurar para el usuario actual
google-authenticator
```

Responde a las preguntas:
- `Do you want time-based tokens?` → **y**
- Escanea el QR con Google Authenticator
- Guarda los códigos de recuperación
- Resto de preguntas → **y**

```bash
# Modificar PAM para requerir TOTP en SSH
sudo nano /etc/pam.d/sshd
```

Agrega al inicio del archivo:

```
auth required pam_google_authenticator.so
```

```bash
# Habilitar ChallengeResponseAuthentication en SSH
sudo nano /etc/ssh/sshd_config
```

Cambia/agrega:

```
ChallengeResponseAuthentication yes
UsePAM yes
```

```bash
sudo systemctl restart sshd
```

Verifica desde otra terminal:

```bash
ssh jgarcia@192.168.56.20
# Primero pide contraseña, luego pide código TOTP
```

---

## FASE 8 — MÓDULO 3: REPORTES DE AUDITORÍA

### 8.1 — Generar intentos fallidos de login (para crear eventos)

Desde Windows 10, intenta login con credenciales incorrectas 3 veces para generar eventos 4625 y 4740.

### 8.2 — Ejecutar el reporte completo

En el servidor DC:

```powershell
cd C:\P09
.\p09_modulo3_monitoreo.ps1
# Seleccionar opción 4: Reporte completo TXT + CSV
```

Los reportes se guardan en `C:\P09-Auditoria\`

### 8.3 — Verificación manual

```powershell
# Ver últimos 10 intentos fallidos
Get-WinEvent -FilterHashtable @{LogName="Security"; Id=4625} -MaxEvents 10 |
    Select-Object TimeCreated, @{N="Usuario";E={$_.Properties[5].Value}},
                  @{N="IP";E={$_.Properties[19].Value}} |
    Format-Table -AutoSize

# Ver cuentas bloqueadas
Search-ADAccount -LockedOut | Select-Object Name, SamAccountName, LockedOut
```

📸 **Captura:** El reporte generado en `C:\P09-Auditoria\` con eventos reales

---

## FASE 9 — PROTOCOLO DE PRUEBAS FINALES

Ejecuta el módulo de pruebas automáticas:

```powershell
cd C:\P09
.\p09_modulo5_tests.ps1
# Seleccionar opción 6: Ejecutar TODOS los tests
```

### Resumen de pruebas manuales requeridas

| Test | Qué hacer | Evidencia |
|------|-----------|-----------|
| **Test 1A** | Iniciar como `admin_identidad` → Reset password en ADUC → debe funcionar | Captura del reset exitoso |
| **Test 1B** | Iniciar como `admin_storage` → Reset password en ADUC → debe dar **Acceso Denegado** | Captura del error |
| **Test 2** | `Set-ADAccountPassword -Identity admin_identidad -Reset -NewPassword (ConvertTo-SecureString "Test1234" -AsPlainText -Force)` → debe ser rechazado (8 chars < mínimo 12) | Captura del error de contraseña |
| **Test 3** | Bloquear pantalla Win+L → ingresar credenciales → debe pedir código TOTP | Captura del campo TOTP + foto del celular |
| **Test 4** | Ingresar código TOTP incorrecto 3 veces → cuenta bloqueada 30 min | Captura de la cuenta bloqueada en ADUC |
| **Test 5** | Módulo 3 → Reporte completo → revisar archivo TXT generado | Adjuntar el archivo CSV |

---

## 📋 Referencia Rápida de Comandos

### En el servidor (PowerShell como Admin)

```powershell
# Ver todos los usuarios del dominio
Get-ADUser -Filter * | Select-Object Name, SamAccountName, Enabled

# Ver FGPP efectiva de un usuario
Get-ADUserResultantPasswordPolicy -Identity admin_identidad

# Ver cuentas bloqueadas
Search-ADAccount -LockedOut | Select-Object Name, SamAccountName

# Desbloquear una cuenta
Unlock-ADAccount -Identity admin_identidad

# Ver intentos fallidos de login (ID 4625)
Get-WinEvent -FilterHashtable @{LogName="Security"; Id=4625} -MaxEvents 10

# Ver bloqueos de cuenta (ID 4740)
Get-WinEvent -FilterHashtable @{LogName="Security"; Id=4740} -MaxEvents 10

# Ver política de bloqueo de dominio
net accounts

# Ver estado de auditoría
auditpol /get /category:*

# Verificar Credential Provider MultiOTP registrado
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
```

### En Linux Mint (Terminal)

```bash
# Ver si está unido al dominio
realm list

# Ver información de usuario del dominio
id jgarcia

# Buscar usuarios del dominio
getent passwd jgarcia

# Verificar tickets Kerberos activos
klist

# Ver estado de SSSD
sudo systemctl status sssd

# Renovar ticket Kerberos
kinit jgarcia@REDES.LOCAL
```

---

## 🔧 Solución de Problemas Comunes

### El DC no responde al ping desde los clientes

```powershell
# En el servidor, verificar que el firewall permite ICMP
New-NetFirewallRule -DisplayName "Allow ICMPv4" -Protocol ICMPv4 -IcmpType 8 -Action Allow -Direction Inbound
```

### Linux Mint no puede unirse al dominio ("Insufficient permissions")

```bash
# Verificar que el reloj está sincronizado con el DC (Kerberos es sensible a la hora)
sudo timedatectl set-ntp true

# Sincronizar manualmente
sudo ntpdate 192.168.56.10

# Verificar diferencia de hora
date
```

### "realm join" falla con error de DNS

```bash
# Probar resolución DNS
dig redes.local @192.168.56.10

# Si falla, verificar /etc/resolv.conf
cat /etc/resolv.conf
# Debe tener nameserver 192.168.56.10
```

### MultiOTP no registra el DLL

```powershell
# Verificar que la DLL existe
Test-Path "C:\Windows\System32\MultiotpCredentialProvider.dll"

# Volver a registrar
regsvr32 /u "C:\Windows\System32\MultiotpCredentialProvider.dll"
regsvr32 "C:\Windows\System32\MultiotpCredentialProvider.dll"
```

### FGPP no aparece en Get-ADUserResultantPasswordPolicy

```powershell
# Verificar que el usuario está en el grupo al que se aplicó la FGPP
Get-ADGroupMember -Identity "GrupoAdminsP09" | Select-Object Name, SamAccountName

# Si no está, agregarlo manualmente
Add-ADGroupMember -Identity "GrupoAdminsP09" -Members "admin_identidad"
```

---

## 📊 Diagrama de Flujo MFA

```
[Usuario escribe usuario + contraseña]
         │
         ▼
[LSASS verifica credenciales contra AD (redes.local)]
         │ credenciales válidas
         ▼
[Credential Provider (MultiOTP) intercepta el login]
         │
         ▼
[Pantalla solicita código TOTP de 6 dígitos]
         │
    ┌────┴────┐
    │         │
correcto    incorrecto
    │         │
    ▼         ▼ (intento 1-2)
[Acceso   [Vuelve a
CONCEDIDO] solicitar código]
              │
              ▼ (intento 3 — FGPP lockout)
         [Cuenta BLOQUEADA 30 minutos]
         [Event ID 4740 → Security Log]
         [Admin debe ejecutar Unlock-ADAccount]
```

---

¡Práctica 09 completada! El sistema protege la identidad con tres capas:
1. **RBAC** — Cada admin solo accede a lo que necesita
2. **FGPP** — Contraseñas más fuertes para cuentas privilegiadas  
3. **MFA** — Segundo factor obligatorio en el login de Windows y Linux
