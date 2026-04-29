# ==============================================================================
# Script de Monitoreo de Eventos - Practica 09 (Rol 4: Security Auditor)
# ==============================================================================

$OutputFile = "$env:USERPROFILE\Desktop\Reporte_Accesos_Denegados.csv"

Write-Host "Buscando los ultimos 10 eventos de Acceso Denegado (ID 4625)..." -ForegroundColor Cyan

# Obtener eventos del Visor de Eventos (Event Viewer) de Seguridad
$Events = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625} -MaxEvents 10 -ErrorAction SilentlyContinue

if ($Events) {
    $ReportData = @()
    foreach ($Event in $Events) {
        # Extraer detalles relevantes del XML del evento
        $EventXml = [xml]$Event.ToXml()
        $AccountName = ($EventXml.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
        $Workstation = ($EventXml.Event.EventData.Data | Where-Object { $_.Name -eq 'WorkstationName' }).'#text'
        $IpAddress = ($EventXml.Event.EventData.Data | Where-Object { $_.Name -eq 'IpAddress' }).'#text'

        $ReportData += [PSCustomObject]@{
            Fecha = $Event.TimeCreated
            ID_Evento = $Event.Id
            Usuario = $AccountName
            Equipo = $Workstation
            IP_Origen = $IpAddress
            Mensaje = "Acceso Denegado (Fallo de Autenticacion / MFA)"
        }
    }
    
    # Exportar a CSV
    $ReportData | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Reporte generado exitosamente en: $OutputFile" -ForegroundColor Green
    
    # Mostrar en consola
    $ReportData | Format-Table -AutoSize
} else {
    Write-Host "No se encontraron eventos de acceso denegado (ID 4625) en los registros recientes." -ForegroundColor Yellow
}
