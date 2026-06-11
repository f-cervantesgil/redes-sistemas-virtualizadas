#Requires -RunAsAdministrator
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module ActiveDirectory

function Write-Ok   ($msg) { Write-Host "  [PASS]  $msg" -ForegroundColor Green  }
function Write-Fail ($msg) { Write-Host "  [FAIL]  $msg" -ForegroundColor Red    }
function Write-Warn ($msg) { Write-Host "  [WARN]  $msg" -ForegroundColor Yellow }
function Write-Info ($msg) { Write-Host "  [INFO]  $msg" -ForegroundColor Cyan   }
function Write-Step ($msg) { Write-Host ""; Write-Host "  === $msg ===" -ForegroundColor Magenta }

$TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param($Test, $Desc, [bool]$Pass, $Notes = "")
    $TestResults.Add([PSCustomObject]@{
        Test = $Test; Descripcion = $Desc
        Resultado = if ($Pass) { "PASS" } else { "FAIL" }
        Notas = $Notes
    })
    if ($Pass) { Write-Ok $Desc } else { Write-Fail $Desc }
    if ($Notes) { Write-Info "  Nota: $Notes" }
}

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   MODULO 5 - Protocolo de Pruebas (Rubrica P09)"             -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1]  Test 1 - Delegacion RBAC (Roles 1 vs 2)"
    Write-Host "  [2]  Test 2 - FGPP (longitud de contrasena)"
    Write-Host "  [3]  Test 3 - MFA (flujo de autenticacion)"
    Write-Host "  [4]  Test 4 - Bloqueo por MFA fallido (30 min)"
    Write-Host "  [5]  Test 5 - Reporte de auditoria automatizado"
    Write-Host "  [6]  Ejecutar TODOS los tests (1 al 5)"
    Write-Host "  [7]  Mostrar resumen de resultados"
    Write-Host "  [8]  Exportar resumen a TXT"
    Write-Host "  [0]  Volver"
    Write-Host ""
}

function Run-Test1 {
    Write-Step "TEST 1 - Verificacion Delegacion RBAC"
    Write-Host ""

    $u1 = Get-ADUser -Filter "SamAccountName -eq 'admin_identidad'" -ErrorAction SilentlyContinue
    Add-Result "T1-a" "admin_identidad existe en AD" ($null -ne $u1)

    $u2 = Get-ADUser -Filter "SamAccountName -eq 'admin_storage'" -ErrorAction SilentlyContinue
    Add-Result "T1-b" "admin_storage existe en AD" ($null -ne $u2)

    $u3 = Get-ADUser -Filter "SamAccountName -eq 'admin_politicas'" -ErrorAction SilentlyContinue
    Add-Result "T1-c" "admin_politicas existe en AD" ($null -ne $u3)

    $u4 = Get-ADUser -Filter "SamAccountName -eq 'admin_auditoria'" -ErrorAction SilentlyContinue
    Add-Result "T1-d" "admin_auditoria existe en AD" ($null -ne $u4)

    $daM = Get-ADGroupMember -Identity "Domain Admins" | Select-Object -ExpandProperty SamAccountName
    Add-Result "T1-e" "admin_storage NO es Domain Admin" (-not ($daM -contains "admin_storage"))

    $ouC = Get-ADOrganizationalUnit -Filter "Name -eq 'Cuates'" -ErrorAction SilentlyContinue
    $ouN = Get-ADOrganizationalUnit -Filter "Name -eq 'NoCuates'" -ErrorAction SilentlyContinue
    Add-Result "T1-f" "OU Cuates existe"   ($null -ne $ouC)
    Add-Result "T1-g" "OU NoCuates existe" ($null -ne $ouN)

    $elr = Get-ADGroupMember -Identity "Event Log Readers" -ErrorAction SilentlyContinue |
           Select-Object -ExpandProperty SamAccountName
    Add-Result "T1-h" "admin_auditoria en Event Log Readers" ($elr -contains "admin_auditoria")

    Write-Host ""
    Write-Info "PRUEBA MANUAL REQUERIDA:"
    Write-Info "  A) Iniciar como admin_identidad -> Reset Password en ADUC -> debe funcionar"
    Write-Info "  B) Iniciar como admin_storage   -> Reset Password en ADUC -> debe dar ACCESO DENEGADO"
}

function Run-Test2 {
    Write-Step "TEST 2 - Directiva de Contrasena Ajustada (FGPP)"
    Write-Host ""

    $psoA = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'PSO-Admins-P09'" -ErrorAction SilentlyContinue
    Add-Result "T2-a" "PSO-Admins-P09 existe" ($null -ne $psoA)
    if ($psoA) {
        Add-Result "T2-b" "PSO admins: min 12 caracteres" ($psoA.MinPasswordLength -ge 12) "Actual: $($psoA.MinPasswordLength)"
    }

    $psoS = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'PSO-Usuarios-P09'" -ErrorAction SilentlyContinue
    Add-Result "T2-c" "PSO-Usuarios-P09 existe" ($null -ne $psoS)
    if ($psoS) {
        Add-Result "T2-d" "PSO estandar: min 8 caracteres" ($psoS.MinPasswordLength -ge 8) "Actual: $($psoS.MinPasswordLength)"
    }

    try {
        $rpp = Get-ADUserResultantPasswordPolicy -Identity "admin_identidad"
        Add-Result "T2-e" "FGPP efectiva en admin_identidad" ($null -ne $rpp) "Min: $($rpp.MinPasswordLength) chars"
    } catch {
        Add-Result "T2-e" "FGPP efectiva en admin_identidad" $false "Error: $_"
    }

    Write-Host ""
    Write-Info "PRUEBA MANUAL:"
    Write-Info "  Set-ADAccountPassword -Identity admin_identidad -Reset -NewPassword (ConvertTo-SecureString 'Test1234' -AsPlainText -Force)"
    Write-Info "  Resultado esperado: error de complejidad/longitud (8 chars no alcanza)"
}

function Run-Test3 {
    Write-Step "TEST 3 - Flujo MFA"
    Write-Host ""

    $nps = Get-WindowsFeature -Name NPAS -ErrorAction SilentlyContinue
    $npsNotes = if ($nps) { $nps.InstallState } else { "No encontrado" }
    Add-Result "T3-a" "NPS (RADIUS) instalado" ($nps -and $nps.InstallState -eq "Installed") $npsNotes

    $dllOk = Test-Path "C:\Windows\System32\MultiotpCredentialProvider.dll"
    Add-Result "T3-b" "MultiotpCredentialProvider.dll registrada" $dllOk

    $dp = Get-ADDefaultDomainPasswordPolicy
    Add-Result "T3-c" "Politica bloqueo dominio configurada" ($dp.LockoutThreshold -gt 0) `
        "Umbral: $($dp.LockoutThreshold)"

    Write-Host ""
    Write-Warn "VERIFICACION MANUAL REQUERIDA (40% rubrica):"
    Write-Info "  1. Bloquea la pantalla del servidor (Win+L)"
    Write-Info "  2. Ingresa usuario + contrasena"
    Write-Info "  3. Debe aparecer campo adicional para el codigo TOTP"
    Write-Info "  4. Ingresa el codigo de Google Authenticator"
    Write-Info "  Evidencia: captura del campo TOTP + foto del celular con el codigo"
}

function Run-Test4 {
    Write-Step "TEST 4 - Bloqueo por MFA fallido"
    Write-Host ""

    $psoMFA = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'PSO-MFA-Lockout-P09'" -ErrorAction SilentlyContinue
    Add-Result "T4-a" "PSO-MFA-Lockout-P09 existe" ($null -ne $psoMFA)
    if ($psoMFA) {
        Add-Result "T4-b" "Umbral = 3 intentos"      ($psoMFA.LockoutThreshold -eq 3) "Actual: $($psoMFA.LockoutThreshold)"
        Add-Result "T4-c" "Bloqueo = 30 minutos"     ($psoMFA.LockoutDuration.TotalMinutes -eq 30) "Actual: $($psoMFA.LockoutDuration.TotalMinutes) min"
    }

    Write-Host ""
    Write-Host "  Cuentas bloqueadas actualmente:" -ForegroundColor Yellow
    $locked = Search-ADAccount -LockedOut -ErrorAction SilentlyContinue
    if ($locked -and $locked.Count -gt 0) {
        $locked | Select-Object Name, SamAccountName | Format-Table -AutoSize | Out-String | Write-Host
    } else {
        Write-Info "No hay cuentas bloqueadas en este momento."
    }

    Write-Host ""
    Write-Warn "PRUEBA MANUAL:"
    Write-Info "  Ingresar codigo TOTP incorrecto 3 veces consecutivas"
    Write-Info "  Resultado: cuenta bloqueada"
    Write-Info "  Verificar: Search-ADAccount -LockedOut | Select Name, LockedOut"
    Write-Info "  En ADUC: propiedades del usuario -> Account -> 'Account is locked out'"
}

function Run-Test5 {
    Write-Step "TEST 5 - Reporte de Auditoria Automatizado"
    Write-Host ""

    $reportDir = "C:\P09-Auditoria"
    Add-Result "T5-a" "Directorio de reportes existe" (Test-Path $reportDir)

    try {
        $evts = Get-WinEvent -FilterHashtable @{LogName="Security";Id=4625} -MaxEvents 10 -ErrorAction SilentlyContinue
        Add-Result "T5-b" "Eventos 4625 disponibles" ($null -ne $evts) "Encontrados: $(if($evts){$evts.Count}else{0})"
    } catch {
        Add-Result "T5-b" "Eventos 4625 disponibles" $false "Habilita auditoria con Modulo 2"
    }

    $auditOut = auditpol /get /subcategory:"Logon" 2>&1 | Out-String
    Add-Result "T5-c" "Auditoria Logon habilitada" ($auditOut -match "Success and Failure")

    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir | Out-Null }
    $ts   = Get-Date -Format "yyyyMMdd_HHmmss"
    $file = "$reportDir\test5_$ts.txt"
    "REPORTE TEST 5 - P09 - $(Get-Date)" | Out-File $file -Encoding UTF8
    if ($evts) {
        $evts | Select-Object TimeCreated, Id |
            ForEach-Object { "[$($_.TimeCreated)] ID:$($_.Id)" } |
            Add-Content $file -Encoding UTF8
    } else {
        "Sin eventos ID 4625 aun." | Add-Content $file
    }
    Add-Result "T5-d" "Archivo de reporte generado" (Test-Path $file) "Archivo: $file"
}

function Show-Summary {
    Write-Step "RESUMEN DE RESULTADOS - Practica 09"
    Write-Host ""
    if ($TestResults.Count -eq 0) { Write-Warn "Sin resultados. Ejecuta los tests primero."; return }

    $TestResults | Format-Table -Property Test, Descripcion, Resultado, Notas -AutoSize -Wrap | Out-String | Write-Host

    $pass  = ($TestResults | Where-Object { $_.Resultado -eq "PASS" }).Count
    $total = $TestResults.Count
    $pct   = [math]::Round(($pass / $total) * 100, 1)

    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  TOTAL: $total  |  " -NoNewline
    Write-Host "PASS: $pass" -NoNewline -ForegroundColor Green
    Write-Host "  |  " -NoNewline
    Write-Host "FAIL: $($total - $pass)" -ForegroundColor Red
    Write-Host ""
    $color = if ($pct -ge 80) { "Green" } elseif ($pct -ge 50) { "Yellow" } else { "Red" }
    Write-Host "  Completitud: $pct%" -ForegroundColor $color
}

function Export-Summary {
    if ($TestResults.Count -eq 0) { Write-Warn "Sin resultados aun."; return }
    $dir = "C:\P09-Auditoria"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $ts   = Get-Date -Format "yyyyMMdd_HHmmss"
    $file = "$dir\RESUMEN_TESTS_P09_$ts.txt"
    @"
============================================================
  RESUMEN PROTOCOLO DE PRUEBAS - PRACTICA 09
  Administracion de Sistemas - UAS FIM - Grupo 3-02
  Fecha: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
============================================================

"@ | Out-File $file -Encoding UTF8
    $TestResults | Format-Table -AutoSize | Out-String | Add-Content $file -Encoding UTF8
    $pass  = ($TestResults | Where-Object { $_.Resultado -eq "PASS" }).Count
    $total = $TestResults.Count
    "`nRESULTADO FINAL: $pass/$total PASS ($([math]::Round(($pass/$total)*100,1))%)" |
        Add-Content $file -Encoding UTF8
    Write-Ok "Exportado: $file"
}

$exit = $false
while (-not $exit) {
    Show-Menu
    $op = Read-Host "  Selecciona"
    switch ($op.Trim()) {
        "1" { Run-Test1 }
        "2" { Run-Test2 }
        "3" { Run-Test3 }
        "4" { Run-Test4 }
        "5" { Run-Test5 }
        "6" { $TestResults.Clear(); Run-Test1; Run-Test2; Run-Test3; Run-Test4; Run-Test5; Write-Host ""; Show-Summary }
        "7" { Show-Summary }
        "8" { Export-Summary }
        "0" { $exit = $true }
        default { Write-Warn "Opcion invalida."; Start-Sleep -Seconds 1 }
    }
    if (-not $exit) { Write-Host ""; Read-Host "  Enter para continuar" | Out-Null }
}
