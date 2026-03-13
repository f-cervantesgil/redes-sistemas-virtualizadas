#requires -RunAsAdministrator
$ErrorActionPreference = "Continue" # Bajamos la estrictez para que no se pare por avisos tontos

$TargetIP = "192.168.222.197"
$IisPath = "C:\inetpub\wwwroot"
$appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"

Write-Host "==========================================" -ForegroundColor Red
Write-Host "   MODO SUPERVIVENCIA - PRACTICA 06" -ForegroundColor Red
Write-Host "==========================================" -ForegroundColor Red

# 1. DESACTIVAR FIREWALL (Como pediste para que no estorbe)
Write-Host "[*] Desactivando Firewall de Windows..." -ForegroundColor Yellow
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# 2. LIMPIEZA TOTAL DE IIS
Write-Host "[*] Limpiando y reiniciando IIS..." -ForegroundColor Cyan
iisreset /stop
Start-Sleep -Seconds 2

if (-not (Get-WindowsFeature -Name Web-Server).Installed) { Install-WindowsFeature -Name Web-Server }
Import-Module WebAdministration

# Borrar y recrear el sitio para que no haya errores de "Objeto no valido"
if (Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue) {
    Remove-Website -Name "Default Web Site"
}

# 3. PEDIR PUERTO Y CONFIGURAR
$p = Read-Host "Ingresa el puerto (ej. 8081)"

# Crear sitio fresco
New-Website -Name "Default Web Site" -Port $p -PhysicalPath $IisPath -Force
Start-Sleep -Seconds 1

# 4. HARDENING (OCULTAR VERSION Y CABECERAS) - Sin errores de duplicado
Write-Host "[*] Aplicando Hardening..." -ForegroundColor Cyan
& $appcmd set config /section:httpProtocol /-"customHeaders.[name='X-Powered-By']" /commit:apphost 2>$null
& $appcmd set config /section:httpProtocol /-"customHeaders.[name='X-Frame-Options']" /commit:apphost 2>$null
& $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Frame-Options',value='SAMEORIGIN']" /commit:apphost 2>$null
& $appcmd set config /section:httpProtocol /-"customHeaders.[name='X-Content-Type-Options']" /commit:apphost 2>$null
& $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Content-Type-Options',value='nosniff']" /commit:apphost 2>$null

# 5. INDEX Y PERMISOS
$html = "<html><body style='background:#111;color:#0f0;text-align:center;font-family:sans-serif;'><h1>Servidor: [IIS]</h1><h2>Version: [LTS] - Puerto: [$p]</h2><p>FIREWALL DESACTIVADO - HARDENING OK</p></body></html>"
Set-Content -Path "$IisPath\index.html" -Value $html -Force

# Requerimiento de usuario dedicado
if (-not (Get-LocalUser -Name "web_user" -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name "web_user" -NoPassword | Out-Null
}
$acl = Get-Acl $IisPath
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("web_user","ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")))
Set-Acl $IisPath $acl

# 6. ARRANQUE FINAL
Write-Host "[*] Arrancando todo..." -ForegroundColor Green
iisreset /start
& $appcmd start site "Default Web Site" 2>$null

Write-Host "`n[OK] IIS configurado en puerto $p" -ForegroundColor Green
Write-Host "[!] Prueba entrar a: http://$TargetIP:$p" -ForegroundColor White

Write-Host "`nValidando conexion..."
Test-NetConnection -ComputerName $TargetIP -Port $p
Read-Host "`nPresiona Enter para terminar..."