#Requires -RunAsAdministrator
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Ok   ($msg) { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function Write-Warn ($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Info ($msg) { Write-Host "  [--]  $msg" -ForegroundColor Cyan   }
function Write-Step ($msg) { Write-Host ""; Write-Host "  >>> $msg" -ForegroundColor Magenta }

$ReportDir = "C:\P09-Auditoria"

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   MODULO 3 - Script de Monitoreo (Auditoria)"               -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1]  Extraer ultimos 10 eventos ID 4625 (Acceso Denegado)"
    Write-Host "  [2]  Extraer ultimos 10 eventos ID 4740 (Bloqueo de cuenta)"
    Write-Host "  [3]  Extraer intentos MFA fallidos (4625, 4740, 4776)"
    Write-Host "  [4]  Generar reporte completo TXT + CSV"
    Write-Host "  [5]  Ver reportes generados en $ReportDir"
    Write-Host "  [0]  Volver"
    Write-Host ""
}

function Ensure-ReportDir {
    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir | Out-Null
        Write-Ok "Directorio creado: $ReportDir"
    }
}

function Get-SecurityEvents {
    param([int[]]$IDs, [int]$Count = 10, [string]$Label = "Evento")
    Write-Step "Extrayendo eventos $($IDs -join ',') - $Label"
    try {
        $evts = Get-WinEvent -FilterHashtable @{ LogName="Security"; Id=$IDs } `
                    -MaxEvents ($Count * 3) -ErrorAction SilentlyContinue |
                Select-Object -First $Count

        if (-not $evts -or $evts.Count -eq 0) {
            Write-Warn "Sin eventos $($IDs -join ',') en el Security Log."
            Write-Info "Habilita auditoria con Modulo 2 opcion 4."
            return $null
        }

        $results = foreach ($e in $evts) {
            $xml  = [xml]$e.ToXml()
            $data = $xml.Event.EventData.Data
            [PSCustomObject]@{
                Fecha       = $e.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                ID          = $e.Id
                Tipo        = $Label
                Usuario     = ($data | Where-Object { $_.Name -eq "TargetUserName"   })."#text"
                Dominio     = ($data | Where-Object { $_.Name -eq "TargetDomainName" })."#text"
                IP          = ($data | Where-Object { $_.Name -eq "IpAddress"        })."#text"
                Workstation = ($data | Where-Object { $_.Name -eq "WorkstationName"  })."#text"
                TipoLogon   = ($data | Where-Object { $_.Name -eq "LogonType"        })."#text"
            }
        }

        Write-Host ""
        Write-Host "  -- Ultimos $($results.Count) eventos: $Label --" -ForegroundColor Yellow
        $results | Format-Table Fecha, ID, Usuario, Dominio, IP -AutoSize | Out-String | Write-Host
        return $results
    } catch {
        Write-Warn "Error consultando Security Log: $_"
        return $null
    }
}

function Export-Event4625 {
    $data = Get-SecurityEvents -IDs @(4625) -Count 10 -Label "Login Fallido"
    if (-not $data) { return }
    Ensure-ReportDir
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $txt = "$ReportDir\reporte_4625_$ts.txt"
    $csv = "$ReportDir\reporte_4625_$ts.csv"
    @"
============================================================
  REPORTE - ACCESOS DENEGADOS (ID 4625)
  Practica 09 - UAS FIM - Grupo 3-02
  Generado : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Servidor : $($env:COMPUTERNAME)
============================================================

"@ | Out-File $txt -Encoding UTF8
    $data | Format-Table -AutoSize | Out-String | Add-Content $txt -Encoding UTF8
    $data | Export-Csv $csv -NoTypeInformation -Encoding UTF8
    Write-Ok "TXT: $txt"
    Write-Ok "CSV: $csv"
}

function Export-Event4740 {
    $data = Get-SecurityEvents -IDs @(4740) -Count 10 -Label "Bloqueo Cuenta"
    if (-not $data) { return }
    Ensure-ReportDir
    $ts  = Get-Date -Format "yyyyMMdd_HHmmss"
    $data | Export-Csv "$ReportDir\reporte_4740_$ts.csv" -NoTypeInformation -Encoding UTF8
    Write-Ok "CSV bloqueos: $ReportDir\reporte_4740_$ts.csv"
}

function Export-MFAFails {
    $data = Get-SecurityEvents -IDs @(4625,4740,4776) -Count 10 -Label "Fallo MFA"
    if (-not $data) { return }
    Ensure-ReportDir
    $ts  = Get-Date -Format "yyyyMMdd_HHmmss"
    $txt = "$ReportDir\reporte_MFA_$ts.txt"
    @"
============================================================
  REPORTE MFA - INTENTOS FALLIDOS
  IDs: 4625 (login), 4740 (bloqueo), 4776 (Kerberos)
  Generado : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
============================================================

"@ | Out-File $txt -Encoding UTF8
    $data | Format-Table -AutoSize | Out-String | Add-Content $txt -Encoding UTF8
    $data | Export-Csv "$ReportDir\reporte_MFA_$ts.csv" -NoTypeInformation -Encoding UTF8
    Write-Ok "TXT: $txt"
    Write-Ok "CSV: $ReportDir\reporte_MFA_$ts.csv"
}

function Export-FullReport {
    Write-Step "Generando reporte completo..."
    Ensure-ReportDir
    $ts   = Get-Date -Format "yyyyMMdd_HHmmss"
    $file = "$ReportDir\REPORTE_COMPLETO_P09_$ts.txt"

    @"
============================================================
  REPORTE COMPLETO DE AUDITORIA - PRACTICA 09
  Administracion de Sistemas - UAS FIM - Grupo 3-02
  Servidor : $($env:COMPUTERNAME)
  Fecha    : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
============================================================

"@ | Out-File $file -Encoding UTF8

    "--- SECCION 1: Logins Fallidos (ID 4625) ---`n" | Add-Content $file
    $e1 = Get-SecurityEvents -IDs @(4625) -Count 10 -Label "Login Fallido"
    if ($e1) { $e1 | Format-Table -AutoSize | Out-String | Add-Content $file }
    else     { "  Sin eventos.`n" | Add-Content $file }

    "`n--- SECCION 2: Bloqueos (ID 4740) ---`n" | Add-Content $file
    $e2 = Get-SecurityEvents -IDs @(4740) -Count 10 -Label "Bloqueo"
    if ($e2) { $e2 | Format-Table -AutoSize | Out-String | Add-Content $file }
    else     { "  Sin eventos.`n" | Add-Content $file }

    "`n--- SECCION 3: Kerberos (ID 4776) ---`n" | Add-Content $file
    $e3 = Get-SecurityEvents -IDs @(4776) -Count 10 -Label "Kerberos"
    if ($e3) { $e3 | Format-Table -AutoSize | Out-String | Add-Content $file }
    else     { "  Sin eventos.`n" | Add-Content $file }

    "`n--- SECCION 4: Estado auditoria ---`n" | Add-Content $file
    auditpol /get /category:"Logon/Logoff","Object Access" 2>&1 |
        ForEach-Object { "  $_" } | Add-Content $file

    Write-Ok "Reporte completo: $file"
    Write-Info "Adjunta este archivo en el reporte tecnico."
}

function Show-Reports {
    Write-Step "Reportes en $ReportDir :"
    if (-not (Test-Path $ReportDir)) { Write-Warn "Sin reportes aun."; return }
    Get-ChildItem $ReportDir | Sort-Object LastWriteTime -Descending |
        Select-Object Name, LastWriteTime, @{N="KB";E={[math]::Round($_.Length/1KB,1)}} |
        Format-Table -AutoSize | Out-String | Write-Host
}

$exit = $false
while (-not $exit) {
    Show-Menu
    $op = Read-Host "  Selecciona"
    switch ($op.Trim()) {
        "1" { Export-Event4625 }
        "2" { Export-Event4740 }
        "3" { Export-MFAFails  }
        "4" { Export-FullReport }
        "5" { Show-Reports }
        "0" { $exit = $true }
        default { Write-Warn "Opcion invalida."; Start-Sleep -Seconds 1 }
    }
    if (-not $exit) { Write-Host ""; Read-Host "  Enter para continuar" | Out-Null }
}
