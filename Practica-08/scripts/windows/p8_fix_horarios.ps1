# p8_fix_horarios_windows.ps1
# Corrige los Logon Hours asegurando que se graben con la zona horaria correcta.

Import-Module ActiveDirectory

$offset = [System.TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalHours

function Set-ExactHours ($GroupName, $StartLocal, $EndLocal) {
    $group = Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue
    if (-not $group) { return }

    $users = Get-ADGroupMember -Identity $group
    foreach ($u in $users) {
        $user = Get-ADUser -Identity $u.SamAccountName
        
        # Generar array de 21 bytes todos en cero (bloqueado todo)
        $logonHours = New-Object byte[] 21
        
        # Llenar la matriz basandonos en UTC cruzado
        for ($day = 0; $day -lt 7; $day++) {
            for ($hour = 0; $hour -lt 24; $hour++) {
                $isAllowed = $false
                if ($StartLocal -lt $EndLocal) {
                    if ($hour -ge $StartLocal -and $hour -lt $EndLocal) { $isAllowed = $true }
                } else {
                    if ($hour -ge $StartLocal -or $hour -lt $EndLocal) { $isAllowed = $true }
                }

                if ($isAllowed) {
                    # Convertir a UTC
                    $utcHour = [int]((($hour - $offset) % 24 + 24) % 24)
                    $utcDay = $day
                    if (($hour - $offset) -lt 0) { $utcDay = ($day - 1 + 7) % 7 }
                    if (($hour - $offset) -ge 24) { $utcDay = ($day + 1) % 7 }

                    $byteIndex = $utcDay * 3 + [Math]::Floor($utcHour / 8)
                    $bitIndex = $utcHour % 8
                    $logonHours[$byteIndex] = $logonHours[$byteIndex] -bor (1 -shl $bitIndex)
                }
            }
        }

        Set-ADUser -Identity $user -Replace @{logonhours = $logonHours}
        Write-Host "Horario arreglado para: $($user.SamAccountName)" -ForegroundColor Green
    }
}

Write-Host "Re-calculando y aplicando horarios con tu Zona Horaria actual..." -ForegroundColor Cyan
Set-ExactHours "G_Cuates" 8 15
Set-ExactHours "G_NoCuates" 15 2
Write-Host "¡Horarios actualizados correctamente!" -ForegroundColor Cyan
