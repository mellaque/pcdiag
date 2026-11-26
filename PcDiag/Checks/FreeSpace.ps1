Register-PcDiagCheck -Id 'FreeSpace' -Title 'Свободное место'

# Для системного диска важен абсолютный запас: обновлениям, файлу подкачки и временным
# файлам нужны гигабайты, а 10 % от 120 ГБ и от 1 ТБ — очень разные цифры.
# Для остальных дисков достаточно процента: они просто заполняются данными.
$script:FreeSpaceRule = @{
    SystemFailGB     = 3
    SystemWarnGB     = 10
    OtherWarnPercent = 5
}

function Get-FreeSpaceData {
    [CmdletBinding()]
    param()
    # DriveType 3 — локальные диски: без флешек, сетевых дисков и CD.
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop)
    $volumes = @(foreach ($disk in $disks) {
            # Метку тома не берём: в ней бывают имена людей, а для диагностики она не нужна.
            [ordered]@{
                Drive      = [string]$disk.DeviceID
                FileSystem = [string]$disk.FileSystem
                SizeBytes  = [int64]$disk.Size
                FreeBytes  = [int64]$disk.FreeSpace
            }
        })
    [ordered]@{
        SystemDrive = [string]$env:SystemDrive
        Volumes     = $volumes
    }
}

function Test-FreeSpace {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Data)

    $rule = $script:FreeSpaceRule
    # Том без размера (пустой кардридер, отключённый диск) пропускаем.
    $volumes = @($Data.Volumes | Where-Object { $_.SizeBytes -gt 0 })
    if ($volumes.Count -eq 0) {
        return New-PcDiagVerdict -Status Skipped -Summary 'локальные диски не найдены'
    }

    $worst = 'OK'
    $all = [System.Collections.Generic.List[string]]::new()
    $bad = [System.Collections.Generic.List[string]]::new()
    $details = [System.Collections.Generic.List[string]]::new()

    foreach ($volume in $volumes) {
        $freeGB = $volume.FreeBytes / 1GB
        $percent = 100 * $volume.FreeBytes / $volume.SizeBytes
        $text = '{0} {1} из {2} ГБ' -f $volume.Drive,
            (Format-PcDiagNumber -Value $freeGB),
            (Format-PcDiagNumber -Value ($volume.SizeBytes / 1GB) -Decimals 0)
        $all.Add($text)

        $level = 'OK'
        $reason = $null
        if ($volume.Drive -eq $Data.SystemDrive) {
            if ($freeGB -lt $rule.SystemFailGB) {
                $level = 'Fail'
                $reason = "системный диск, меньше $($rule.SystemFailGB) ГБ: возможны зависания, сбои обновлений и профилей"
            }
            elseif ($freeGB -lt $rule.SystemWarnGB) {
                $level = 'Warn'
                $reason = "системный диск, меньше $($rule.SystemWarnGB) ГБ: может не хватить места для обновлений Windows"
            }
        }
        elseif ($percent -lt $rule.OtherWarnPercent) {
            $level = 'Warn'
            $reason = "свободно меньше $($rule.OtherWarnPercent) %"
        }

        if ($level -ne 'OK') {
            $bad.Add($text)
            $details.Add(('{0} {1}' -f $volume.Drive, $reason))
            $worst = Get-PcDiagWorstLevel -Current $worst -Candidate $level
        }
    }

    if ($worst -eq 'OK') {
        return New-PcDiagVerdict -Status OK -Summary ('свободно: ' + ($all -join ', '))
    }
    New-PcDiagVerdict -Status $worst -Summary ('мало места: ' + ($bad -join ', ')) -Details $details.ToArray()
}
