Register-PcDiagCheck -Id 'UnexpectedShutdown' -Title 'Выключения и BSOD'

# За сколько дней смотреть журнал и сколько сбоев перечислять в пояснениях.
$script:ShutdownLookbackDays = 30
$script:ShutdownMaxDetails = 8

# Частые коды синего экрана. Ключ — код в том виде, как его печатает Format-UnexpectedShutdownBugcheck.
$script:BugcheckName = @{
    '0xA'   = 'IRQL_NOT_LESS_OR_EQUAL'
    '0x19'  = 'BAD_POOL_HEADER'
    '0x1A'  = 'MEMORY_MANAGEMENT'
    '0x1E'  = 'KMODE_EXCEPTION_NOT_HANDLED'
    '0x3B'  = 'SYSTEM_SERVICE_EXCEPTION'
    '0x50'  = 'PAGE_FAULT_IN_NONPAGED_AREA'
    '0x7E'  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
    '0x9F'  = 'DRIVER_POWER_STATE_FAILURE'
    '0xC2'  = 'BAD_POOL_CALLER'
    '0xD1'  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
    '0xEF'  = 'CRITICAL_PROCESS_DIED'
    '0x116' = 'VIDEO_TDR_FAILURE'
    '0x124' = 'WHEA_UNCORRECTABLE_ERROR'
    '0x133' = 'DPC_WATCHDOG_VIOLATION'
    '0x139' = 'KERNEL_SECURITY_CHECK_FAILURE'
}

# У этих кодов первый параметр — код исключения; 0xc0000005 значит «обращение к недопустимой памяти».
$script:BugcheckWithExceptionCode = @('0x1E', '0x3B', '0x7E')

# Кто инициировал штатное выключение (событие 1074): имя программы -> по-человечески.
$script:ShutdownInitiator = @{
    'startmenuexperiencehost.exe' = 'через Пуск'
    'explorer.exe'                = 'через Пуск'
    'systemsettings.exe'          = 'из Параметров'
    'trustedinstaller.exe'        = 'для установки обновлений'
    'mousocoreworker.exe'         = 'для установки обновлений'
    'winlogon.exe'                = 'системой'
    'shutdown.exe'                = 'командой shutdown'
}

function Get-UnexpectedShutdownData {
    [CmdletBinding()]
    param()

    $now = Get-Date
    $since = $now.AddDays(-$script:ShutdownLookbackDays)

    # Фильтр прямо в запросе: журнал «Система» целиком не читаем, это долго на слабых ПК.
    $filter = @{ LogName = 'System'; Id = 41, 1001, 1074, 6008; StartTime = $since }
    $records = @(Get-PcDiagWinEvent -Filter $filter)

    $crashes = [System.Collections.Generic.List[object]]::new()
    $bugChecks = [System.Collections.Generic.List[object]]::new()
    $shutdowns = [System.Collections.Generic.List[object]]::new()
    $dirtyCount = 0

    foreach ($record in $records) {
        $time = $record.TimeCreated.ToString('s')
        switch ('{0}/{1}' -f $record.ProviderName, $record.Id) {
            'Microsoft-Windows-Kernel-Power/41' {
                # Загрузка после некорректного выключения. Причину различаем по полям, а не по тексту сообщения.
                $fields = ConvertFrom-PcDiagEventData -Record $record
                $crashes.Add([ordered]@{
                        Time                 = $time
                        BugcheckCode         = ConvertTo-PcDiagInt64 -Value $fields['BugcheckCode']
                        BugcheckParameter1   = [string]$fields['BugcheckParameter1']
                        SleepInProgress      = ConvertTo-PcDiagInt64 -Value $fields['SleepInProgress']
                        PowerButtonTimestamp = ConvertTo-PcDiagInt64 -Value $fields['PowerButtonTimestamp']
                        LongPowerButtonPress = ([string]$fields['LongPowerButtonPressDetected'] -eq 'true')
                    })
            }
            'Microsoft-Windows-WER-SystemErrorReporting/1001' {
                # Отчёт о синем экране: в нём имя файла дампа.
                $fields = ConvertFrom-PcDiagEventData -Record $record
                $bugChecks.Add([ordered]@{
                        Time = $time
                        Text = [string]$fields['param1']
                        Dump = Get-PcDiagLeafName -Path ([string]$fields['param2'])
                    })
            }
            'User32/1074' {
                # Штатное выключение. Берём только программу и действие: в param2 имя ПК,
                # а в param7 учётная запись, в которой бывает название организации.
                $fields = ConvertFrom-PcDiagEventData -Record $record
                $exePath = [string]$fields['param1'] -replace '\s*\([^)]*\)\s*$', ''
                $shutdowns.Add([ordered]@{
                        Time       = $time
                        Process    = Get-PcDiagLeafName -Path $exePath
                        Action     = [string]$fields['param5']
                        ReasonCode = [string]$fields['param4']
                    })
            }
            'EventLog/6008' {
                # Только считаем: время внутри — локализованные строки без имён полей.
                $dirtyCount++
            }
        }
    }

    # Дампы только перечисляем. Их содержимое — фрагменты памяти, в отчёт они не копируются.
    $dumpFolder = Join-Path $env:SystemRoot 'Minidump'
    $dumps = @(Get-ChildItem -LiteralPath $dumpFolder -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime |
            ForEach-Object {
                [ordered]@{ Name = $_.Name; Time = $_.LastWriteTime.ToString('s'); SizeKB = [long][math]::Round($_.Length / 1KB) }
            })

    $hibernate = Get-PcDiagHibernateSetting
    [ordered]@{
        Days               = $script:ShutdownLookbackDays
        Since              = $since.ToString('s')
        Crashes            = $crashes.ToArray()
        BugChecks          = $bugChecks.ToArray()
        Shutdowns          = $shutdowns.ToArray()
        DirtyShutdownCount = $dirtyCount
        Minidumps          = $dumps
        HiberbootEnabled   = $hibernate.HiberbootEnabled
        HibernateEnabled   = $hibernate.HibernateEnabled
    }
}

function Get-UnexpectedShutdownKind {
    <# Порядок важен: синий экран важнее всего остального, кнопка — важнее сна. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Crash)
    if ($Crash.BugcheckCode -ne 0) { return 'Bsod' }
    if ($Crash.PowerButtonTimestamp -ne 0 -or $Crash.LongPowerButtonPress) { return 'Button' }
    if ($Crash.SleepInProgress -ne 0) { return 'Sleep' }
    'Power'
}

function Format-UnexpectedShutdownBugcheck {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [long]$Code,
        [AllowNull()] [AllowEmptyString()] [string]$Parameter1
    )
    $hex = '0x{0:X}' -f $Code
    $text = $hex
    if ($script:BugcheckName.ContainsKey($hex)) { $text += ' ' + $script:BugcheckName[$hex] }
    if ($script:BugcheckWithExceptionCode -contains $hex -and $Parameter1 -eq '0xc0000005') {
        $text += ' (обращение к недопустимой памяти)'
    }
    $text
}

function Find-UnexpectedShutdownDump {
    <#
    Дамп пишется при загрузке после синего экрана. Сначала ищем его в отчёте WER 1001,
    потом по времени файла в Minidump: оба появляются в первые минуты после загрузки.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [datetime]$BootTime,
        [Parameter(Mandatory)] $Data
    )
    $from = $BootTime.AddMinutes(-1)
    $to = $BootTime.AddMinutes(30)
    foreach ($report in @((Get-PcDiagField -Data $Data -Name 'BugChecks') | Where-Object { $null -ne $_ })) {
        $time = ConvertFrom-PcDiagDate -Text $report.Time
        if ($time -ge $from -and $time -le $to -and $report.Dump) { return [string]$report.Dump }
    }
    foreach ($dump in @((Get-PcDiagField -Data $Data -Name 'Minidumps') | Where-Object { $null -ne $_ })) {
        $time = ConvertFrom-PcDiagDate -Text $dump.Time
        if ($time -ge $BootTime.AddMinutes(-10) -and $time -le $to) { return [string]$dump.Name }
    }
    ''
}

function Test-UnexpectedShutdown {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Data)

    # Get-PcDiagField и Where-Object: отсутствующий список ведёт себя как пустой, а не роняет StrictMode.
    $crashes = @((Get-PcDiagField -Data $Data -Name 'Crashes') | Where-Object { $null -ne $_ } | Sort-Object -Property { $_.Time })
    $since = ConvertFrom-PcDiagDate -Text $Data.Since
    $oldDumps = @((Get-PcDiagField -Data $Data -Name 'Minidumps') | Where-Object { $null -ne $_ -and (ConvertFrom-PcDiagDate -Text $_.Time) -lt $since })
    $oldDumpNote = $null
    if ($oldDumps.Count -gt 0) {
        $lastOld = (ConvertFrom-PcDiagDate -Text $oldDumps[-1].Time).ToString('dd.MM.yyyy')
        $oldDumpNote = 'в папке Minidump есть дампы старше {0} дн.: {1}, последний от {2}' -f $Data.Days, $oldDumps.Count, $lastOld
    }

    if ($crashes.Count -eq 0) {
        $summary = 'за {0} дн. аварийных перезагрузок нет' -f $Data.Days
        if ($oldDumpNote) { return New-PcDiagVerdict -Status OK -Summary $summary -Details @($oldDumpNote) }
        return New-PcDiagVerdict -Status OK -Summary $summary
    }

    $kindName = [ordered]@{
        Bsod   = 'синий экран'
        Sleep  = 'сбой сна или гибернации'
        Button = 'кнопка питания'
        Power  = 'потеря питания или зависание'
    }
    $counts = @{}
    $lines = [System.Collections.Generic.List[string]]::new()
    $shutdowns = @((Get-PcDiagField -Data $Data -Name 'Shutdowns') | Where-Object { $null -ne $_ } | Sort-Object -Property { $_.Time })

    foreach ($crash in $crashes) {
        $kind = Get-UnexpectedShutdownKind -Crash $crash
        $counts[$kind] = 1 + [int]$counts[$kind]
        $boot = ConvertFrom-PcDiagDate -Text $crash.Time

        switch ($kind) {
            'Bsod' {
                $text = 'загрузка после синего экрана ' + (Format-UnexpectedShutdownBugcheck -Code $crash.BugcheckCode -Parameter1 $crash.BugcheckParameter1)
                $dump = Find-UnexpectedShutdownDump -BootTime $boot -Data $Data
                if ($dump) { $text += ", дамп $dump" }
            }
            'Sleep' {
                if ($crash.SleepInProgress -eq 4) { $text = 'загрузка после сбоя гибернации или быстрого запуска (S4)' }
                else { $text = 'загрузка после сбоя во сне (S{0})' -f $crash.SleepInProgress }
            }
            'Button' { $text = 'загрузка после выключения удержанием кнопки питания' }
            'Power' { $text = 'загрузка после внезапной потери питания или зависания' }
        }

        # Только для сбоев сна и гибернации важно, как ПК выключили перед этим: «Выключение питания»
        # через Пуск при быстром запуске — это гибернация, и сбой проявится при следующем включении,
        # хоть через неделю. Для потери питания и кнопки давнее выключение ничего не объясняет.
        if ($kind -eq 'Sleep') {
            $before = @($shutdowns | Where-Object { $_.Time -lt $crash.Time })
            if ($before.Count -gt 0) {
                $last = $before[-1]
                $action = $last.Action
                if (-not $action) { $action = 'выключение' }
                $initiator = $script:ShutdownInitiator[([string]$last.Process).ToLowerInvariant()]
                if (-not $initiator) { $initiator = "($($last.Process))" }
                $text += '; перед этим {0} «{1}» {2}' -f (ConvertFrom-PcDiagDate -Text $last.Time).ToString('dd.MM HH:mm'), $action, $initiator
            }
        }
        $lines.Add(('{0} {1}' -f $boot.ToString('dd.MM.yyyy HH:mm'), $text))
    }

    $parts = @(foreach ($kind in $kindName.Keys) { if ($counts[$kind]) { '{0}: {1}' -f $kindName[$kind], $counts[$kind] } })
    $summary = 'за {0} дн. аварийных перезагрузок: {1} ({2})' -f $Data.Days, $crashes.Count, ($parts -join ', ')

    $details = [System.Collections.Generic.List[string]]::new()
    if ($lines.Count -gt $script:ShutdownMaxDetails) {
        $details.Add(('показаны последние {0} из {1}' -f $script:ShutdownMaxDetails, $lines.Count))
        $details.AddRange([string[]]@($lines | Select-Object -Last $script:ShutdownMaxDetails))
    }
    else {
        $details.AddRange([string[]]$lines.ToArray())
    }

    $fastStartup = ((Get-PcDiagField -Data $Data -Name 'HiberbootEnabled') -eq 1) -and ((Get-PcDiagField -Data $Data -Name 'HibernateEnabled') -ne 0)
    if ($counts['Sleep'] -and $fastStartup) {
        $details.Add('включён быстрый запуск: «Выключение питания» отправляет ядро в гибернацию, сбой выхода из неё выглядит как аварийная перезагрузка')
    }
    if ($oldDumpNote) { $details.Add($oldDumpNote) }

    $status = 'Warn'
    if ($counts['Bsod']) { $status = 'Fail' }
    New-PcDiagVerdict -Status $status -Summary $summary -Details $details.ToArray()
}
