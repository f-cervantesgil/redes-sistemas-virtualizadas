#requires -RunAsAdministrator
$ErrorActionPreference = "Continue"

$TargetIP = "192.168.222.197"
$IisPath = "C:\inetpub\wwwroot"
$appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"

Write-Host "============================" -ForegroundColor Red
Write-Host "   P6   " -ForegroundColor Red
Write-Host "============================" -ForegroundColor Red

# 1. DESACTIVAR TODO BLOQUEO
Write-Host "[*] Desactivando Firewall para asegurar conexion..." -ForegroundColor Yellow
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# 2. REINICIO MAESTRO DE IIS
Write-Host "[*] Reiniciando servicios de red..." -ForegroundColor Cyan
Stop-Service W3SVC, WAS -Force -ErrorAction SilentlyContinue
iisreset /stop | Out-Null

# 3. CONFIGURAR PUERTO
$p = Read-Host "Ingresa el puerto (ej. 8081)"

# Limpiar bindings viejos y crear nuevo
Import-Module WebAdministration
if (Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue) {
    Remove-Website -Name "Default Web Site"
}
New-Website -Name "Default Web Site" -Port $p -PhysicalPath $IisPath -IPAddress "*" -Force

# Fuerza el binding con AppCmd para que escuche en todas las interfaces
& $appcmd set site "Default Web Site" /bindings:http/*:${p}: 2>$null

# 4. HARDENING (Sin errores de duplicado)
& $appcmd set config /section:httpProtocol /-"customHeaders.[name='X-Powered-By']" /commit:apphost 2>$null
& $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Frame-Options',value='SAMEORIGIN']" /commit:apphost 2>$null
& $appcmd set config /section:httpProtocol /+"customHeaders.[name='X-Content-Type-Options',value='nosniff']" /commit:apphost 2>$null

# 5. INDEX HTML
$html = "<html><body style='background:#000;color:#0f0;text-align:center;padding:50px;'><h1>IIS OPERATIVO</h1><hr><h2>IP: ${TargetIP} - Puerto: ${p}</h2></body></html>"
Set-Content -Path "$IisPath\index.html" -Value $html -Force

# 6. ARRANQUE Y ESPERA DE CONEXION
Write-Host "[*] Arrancando servidor y esperando puerto..." -ForegroundColor Green
Start-Service WAS, W3SVC -ErrorAction SilentlyContinue
iisreset /start | Out-Null
& $appcmd start site "Default Web Site" 2>$null

# Esperar hasta 5 segundos a que el puerto abra
$ready = $false
for ($i=1; $i -le 5; $i++) {
    Write-Host "." -NoNewline
    if (Test-NetConnection -ComputerName $TargetIP -Port $p -InformationLevel Quiet) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 1
}

if ($ready) {
    Write-Host "`n[OK] CONEXION EXITOSA EN http://${TargetIP}:${p}" -ForegroundColor Green
} else {
    Write-Host "`n[!] El puerto no abrio a tiempo. REINICIA TU VM e intenta de nuevo." -ForegroundColor Red
}

Read-Host "`nPresiona Enter para finalizar..."