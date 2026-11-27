Register-PcDiagCheck -Id 'Uptime' -Title 'Аптайм и ОС'

# Сколько дней без перезагрузки считать подозрительным.
$script:UptimeWarnDays = 14

function Get-UptimeData {
    [CmdletBinding()]
    param()
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $hibernate = Get-PcDiagHibernateSetting

    [ordered]@{
        Caption          = [string]$os.Caption
        Version          = [string]$os.Version
        BuildNumber      = [string]$os.BuildNumber
        LastBootUpTime   = $os.LastBootUpTime.ToString('s')
        # Время берём у самой ОС, а не Get-Date: так Test-Uptime не зависит от часов того, кто разбирает отчёт.
        LocalDateTime    = $os.LocalDateTime.ToString('s')
        # Быстрый запуск: при «Завершении работы» ядро уходит в гибернацию, аптайм не сбрасывается.
        HiberbootEnabled = $hibernate.HiberbootEnabled
        HibernateEnabled = $hibernate.HibernateEnabled
    }
}

function Test-Uptime {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Data)

    $boot = ConvertFrom-PcDiagDate -Text $Data.LastBootUpTime
    $now = ConvertFrom-PcDiagDate -Text $Data.LocalDateTime
    # Caption локализован: на русской Windows это «Майкрософт Windows 11 Pro».
    $os = '{0}, сборка {1}' -f ($Data.Caption -replace '^(Microsoft|Майкрософт)\s+', ''), $Data.BuildNumber
    $bootText = $boot.ToString('dd.MM.yyyy HH:mm')

    if ($now -lt $boot) {
        return New-PcDiagVerdict -Status Warn `
            -Summary ('{0}; время загрузки ({1}) позже текущего времени ПК' -f $os, $bootText) `
            -Details @('похоже, сбиты часы: проверьте дату и время, батарейку BIOS')
    }

    $uptime = $now - $boot
    $summary = '{0}; без перезагрузки {1} (с {2})' -f $os, (Format-PcDiagDuration -Span $uptime), $bootText
    if ($uptime.TotalDays -lt $script:UptimeWarnDays) {
        return New-PcDiagVerdict -Status OK -Summary $summary
    }

    $details = @("больше $($script:UptimeWarnDays) дн. без перезагрузки: копятся утечки памяти и недоустановленные обновления")
    # Неизвестное значение гибернации считаем включённым: так быстрый запуск работает по умолчанию.
    $fastStartup = ($Data.HiberbootEnabled -eq 1) -and ($Data.HibernateEnabled -ne 0)
    if ($fastStartup) {
        $details += 'включён быстрый запуск: «Завершение работы» не перезапускает ядро, аптайм сбрасывает только «Перезагрузка»'
    }
    New-PcDiagVerdict -Status Warn -Summary $summary -Details $details
}
