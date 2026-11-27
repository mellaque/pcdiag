Register-PcDiagCheck -Id 'DiskHealth' -Title 'Диски и S.M.A.R.T.'

$script:DiskLookbackDays = 30

# Пороги для внутренних дисков. USB-диски не оцениваются: мост отдаёт нули и пустые счётчики.
$script:DiskRule = @{
    WearWarnPercent = 80
    WearFailPercent = 95
    SsdTempWarnC    = 70
    HddTempWarnC    = 55
}

# События журнала: какой статус дают и как назвать по-человечески.
# Ключ — «источник/код» в нижнем регистре; Ntfs и Microsoft-Windows-Ntfs сводятся к ntfs.
$script:DiskEventRule = @{
    'disk/7'       = @{ Level = 'Fail'; Text = 'повреждённые блоки' }
    'disk/154'     = @{ Level = 'Fail'; Text = 'отказы ввода-вывода из-за ошибки оборудования' }
    'disk/51'      = @{ Level = 'Warn'; Text = 'ошибки при операциях подкачки' }
    'disk/153'     = @{ Level = 'Warn'; Text = 'повторы операций ввода-вывода' }
    'disk/11'      = @{ Level = 'Warn'; Text = 'ошибки контроллера' }
    'disk/157'     = @{ Level = 'Warn'; Text = 'внезапные отключения диска' }
    'ntfs/55'      = @{ Level = 'Fail'; Text = 'повреждение файловой системы' }
    'ntfs/98'      = @{ Level = 'Warn'; Text = 'том требует проверки (chkdsk)' }
    'ntfs/140'     = @{ Level = 'Warn'; Text = 'сбои записи журнала NTFS' }
    'stornvme/129' = @{ Level = 'Warn'; Text = 'сбросы NVMe-диска контроллером (диск не отвечал)' }
    'storahci/129' = @{ Level = 'Warn'; Text = 'сбросы SATA-диска контроллером (диск не отвечал)' }
    'iastora/129'  = @{ Level = 'Warn'; Text = 'сбросы диска контроллером Intel RST (диск не отвечал)' }
    'iastorac/129' = @{ Level = 'Warn'; Text = 'сбросы диска контроллером Intel RST (диск не отвечал)' }
}

# Источники событий, которые пишут о внутренних контроллерах: у них нет номера диска.
$script:DiskControllerProvider = @('stornvme', 'storahci', 'iastora', 'iastorac')

# Обёртки над командлетами модуля Storage. Сами командлеты Pester замокать не может:
# они сгенерированы из CDXML, и в их параметрах есть типы вида [Get-PhysicalDisk.PhysicalDiskUsage],
# которые не проходят разбор при создании подставной функции. Тесты мокают эти обёртки.
function Get-DiskHealthDisk {
    [CmdletBinding()]
    param()
    Get-Disk -ErrorAction Stop
}

function Get-DiskHealthPhysicalDisk {
    [CmdletBinding()]
    param()
    Get-PhysicalDisk -ErrorAction Stop
}

function Get-DiskHealthPartition {
    [CmdletBinding()]
    param()
    Get-Partition -ErrorAction SilentlyContinue
}

function Get-DiskHealthCounter {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $PhysicalDisk)
    $PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction Stop
}

function Get-DiskHealthData {
    [CmdletBinding()]
    param()

    $since = (Get-Date).AddDays(-$script:DiskLookbackDays)

    # Номер диска N из \Device\HarddiskN — это Get-Disk.Number; он же DeviceId у Get-PhysicalDisk.
    $diskInfo = @{}
    foreach ($disk in @(Get-DiskHealthDisk)) { $diskInfo[[string]$disk.Number] = $disk }

    $disks = @(foreach ($physical in @(Get-DiskHealthPhysicalDisk | Sort-Object -Property { [int]$_.DeviceId })) {
            # USB-диски не спрашиваем: мост всё равно отдаёт нули, а запрос может ждать таймаута
            # (на внешнем диске через USB-мост замерено 90 с из 95 на всю проверку).
            $counter = $null
            if ([string]$physical.BusType -ne 'USB') {
                try { $counter = Get-DiskHealthCounter -PhysicalDisk $physical }
                catch { $counter = $null }
            }

            $info = $diskInfo[[string]$physical.DeviceId]
            $isSystem = $false
            $isBoot = $false
            if ($null -ne $info) { $isSystem = [bool]$info.IsSystem; $isBoot = [bool]$info.IsBoot }

            # 0 °C не бывает: ноль значит «датчик не отдал значение».
            $temperature = $null
            if ($null -ne $counter -and [int]$counter.Temperature -gt 0) { $temperature = [int]$counter.Temperature }

            # Серийный номер не берём: для диагностики не нужен, а в отчёте лишний.
            [ordered]@{
                Number                 = [int]$physical.DeviceId
                Model                  = [string]$physical.FriendlyName
                BusType                = [string]$physical.BusType
                MediaType              = [string]$physical.MediaType
                SizeBytes              = [long]$physical.Size
                HealthStatus           = [string]$physical.HealthStatus
                OperationalStatus      = (@($physical.OperationalStatus) | ForEach-Object { [string]$_ }) -join ', '
                IsSystem               = $isSystem
                IsBoot                 = $isBoot
                CountersAvailable      = ($null -ne $counter)
                Temperature            = $temperature
                Wear                   = $(if ($null -ne $counter) { $counter.Wear } else { $null })
                PowerOnHours           = $(if ($null -ne $counter) { $counter.PowerOnHours } else { $null })
                ReadErrorsUncorrected  = $(if ($null -ne $counter) { $counter.ReadErrorsUncorrected } else { $null })
                WriteErrorsUncorrected = $(if ($null -ne $counter) { $counter.WriteErrorsUncorrected } else { $null })
            }
        })

    # Буква тома -> номер диска: Ntfs пишет в событиях букву, а не номер.
    $volumes = @(Get-DiskHealthPartition | Where-Object { $_.DriveLetter -match '^[A-Za-z]$' } | ForEach-Object {
            [ordered]@{ Drive = ('{0}:' -f $_.DriveLetter).ToUpperInvariant(); DiskNumber = [int]$_.DiskNumber }
        })

    # События группируем сразу: на ПК с капризной флешкой их бывают сотни.
    $groups = @{}
    foreach ($provider in @('disk', 'Microsoft-Windows-Ntfs', 'Ntfs', 'stornvme', 'storahci', 'iaStorA', 'iaStorAC')) {
        $filter = @{ LogName = 'System'; ProviderName = $provider; Level = 1, 2, 3; StartTime = $since }
        foreach ($record in @(Get-PcDiagWinEvent -Filter $filter)) {
            $diskNumber = $null
            $drive = ''
            # Номер диска лежит в безымянном поле (\Device\Harddisk1\DR22), поэтому ищем по тексту всех полей.
            $xml = [xml]$record.ToXml()
            foreach ($node in @($xml.SelectNodes("//*[local-name()='EventData']/*[local-name()='Data']"))) {
                if ($null -eq $diskNumber -and $node.InnerText -match 'Harddisk(\d+)\\DR') { $diskNumber = [int]$Matches[1] }
                if ($node.HasAttribute('Name') -and $node.GetAttribute('Name') -eq 'DriveName') { $drive = $node.InnerText.ToUpperInvariant() }
            }
            $key = '{0}|{1}|{2}|{3}' -f $record.ProviderName, $record.Id, $diskNumber, $drive
            $time = $record.TimeCreated.ToString('s')
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = [ordered]@{
                    Provider = [string]$record.ProviderName; Id = [int]$record.Id
                    DiskNumber = $diskNumber; Drive = $drive; Total = 0; Last = $time
                }
            }
            # Не Count: имя совпадает со свойством самого словаря, при чтении легко перепутать.
            $groups[$key].Total++
            if ($time -gt $groups[$key].Last) { $groups[$key].Last = $time }
        }
    }

    [ordered]@{
        Days        = $script:DiskLookbackDays
        SystemDrive = ([string]$env:SystemDrive).ToUpperInvariant()
        Disks       = $disks
        Volumes     = $volumes
        EventGroups = @($groups.Values | Sort-Object -Property { $_.Provider }, { $_.Id })
    }
}

function Format-DiskHealthName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Disk)
    $kind = $Disk.BusType
    if ($Disk.MediaType -in 'SSD', 'HDD') { $kind = '{0} {1}' -f $Disk.BusType, $Disk.MediaType }
    '{0} ({1}, {2} ГБ)' -f $Disk.Model, $kind, (Format-PcDiagNumber -Value ($Disk.SizeBytes / 1GB) -Decimals 0)
}

function Test-DiskHealth {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Data)

    $rule = $script:DiskRule
    $disks = @((Get-PcDiagField -Data $Data -Name 'Disks') | Where-Object { $null -ne $_ })
    if ($disks.Count -eq 0) { return New-PcDiagVerdict -Status Skipped -Summary 'диски не найдены' }

    $internal = @($disks | Where-Object { $_.BusType -ne 'USB' })
    $usb = @($disks | Where-Object { $_.BusType -eq 'USB' })
    $volumeDisk = @{}
    foreach ($volume in @((Get-PcDiagField -Data $Data -Name 'Volumes') | Where-Object { $null -ne $_ })) {
        $volumeDisk[[string]$volume.Drive] = [int]$volume.DiskNumber
    }

    # Находки по каждому внутреннему диску: номер -> список { Level, Text }.
    $findings = @{}
    foreach ($disk in $internal) { $findings[$disk.Number] = [System.Collections.Generic.List[object]]::new() }
    $removableEvents = 0

    foreach ($group in @((Get-PcDiagField -Data $Data -Name 'EventGroups') | Where-Object { $null -ne $_ })) {
        $provider = ([string]$group.Provider).ToLowerInvariant() -replace '^microsoft-windows-', ''
        $eventRule = $script:DiskEventRule[('{0}/{1}' -f $provider, $group.Id)]
        if ($null -eq $eventRule) { continue }

        # К какому диску относится событие: по номеру, по букве тома или, для контроллеров, ко всем внутренним.
        $targets = @()
        if ($null -ne $group.DiskNumber) { $targets = @($internal | Where-Object { $_.Number -eq $group.DiskNumber }) }
        elseif ($group.Drive -and $volumeDisk.ContainsKey([string]$group.Drive)) {
            $number = $volumeDisk[[string]$group.Drive]
            $targets = @($internal | Where-Object { $_.Number -eq $number })
        }
        elseif ($script:DiskControllerProvider -contains $provider) { $targets = $internal }

        # Номер или буква, которых сейчас нет среди внутренних дисков, — съёмное или уже отключённое устройство.
        # Под тем же номером за месяц могли побывать разные флешки, поэтому статус они не меняют.
        if ($targets.Count -eq 0) { $removableEvents += [int]$group.Total; continue }

        $last = (ConvertFrom-PcDiagDate -Text $group.Last).ToString('dd.MM.yyyy')
        foreach ($target in $targets) {
            $findings[$target.Number].Add([pscustomobject]@{
                    Level = $eventRule.Level
                    Text  = ('в журнале {0}: {1} ({2} {3}), последнее {4}' -f $eventRule.Text, $group.Total, $group.Provider, $group.Id, $last)
                })
        }
    }

    $worst = 'OK'
    $parts = [System.Collections.Generic.List[string]]::new()
    $details = [System.Collections.Generic.List[string]]::new()

    foreach ($disk in $internal) {
        $list = $findings[$disk.Number]
        $isSsd = ($disk.MediaType -eq 'SSD' -or $disk.BusType -eq 'NVMe')

        if ($disk.HealthStatus -eq 'Unhealthy') { $list.Add([pscustomobject]@{ Level = 'Fail'; Text = 'Windows оценивает состояние как Unhealthy' }) }
        elseif ($disk.HealthStatus -eq 'Warning') { $list.Add([pscustomobject]@{ Level = 'Warn'; Text = 'Windows оценивает состояние как Warning' }) }
        if ($disk.OperationalStatus -match 'Predictive Failure') { $list.Add([pscustomobject]@{ Level = 'Fail'; Text = 'диск сам предсказывает отказ (Predictive Failure)' }) }

        $uncorrected = [long](ConvertTo-PcDiagInt64 -Value $disk.ReadErrorsUncorrected) + [long](ConvertTo-PcDiagInt64 -Value $disk.WriteErrorsUncorrected)
        if ($uncorrected -gt 0) { $list.Add([pscustomobject]@{ Level = 'Fail'; Text = "неисправленных ошибок чтения и записи: $uncorrected" }) }

        $wear = $null
        if ($isSsd -and $null -ne $disk.Wear) { $wear = [int]$disk.Wear }
        if ($null -ne $wear -and $wear -ge $rule.WearFailPercent) { $list.Add([pscustomobject]@{ Level = 'Fail'; Text = "износ $wear %: ресурс записи почти исчерпан" }) }
        elseif ($null -ne $wear -and $wear -ge $rule.WearWarnPercent) { $list.Add([pscustomobject]@{ Level = 'Warn'; Text = "износ $wear %" }) }

        $tempLimit = $rule.HddTempWarnC
        if ($isSsd) { $tempLimit = $rule.SsdTempWarnC }
        if ($null -ne $disk.Temperature -and [int]$disk.Temperature -ge $tempLimit) {
            $list.Add([pscustomobject]@{ Level = 'Warn'; Text = ('температура {0} °C (порог {1} °C)' -f $disk.Temperature, $tempLimit) })
        }

        # Короткое описание диска для сводки.
        $facts = [System.Collections.Generic.List[string]]::new()
        $diskWorst = 'OK'
        foreach ($finding in $list) { $diskWorst = Get-PcDiagWorstLevel -Current $diskWorst -Candidate $finding.Level }
        if ($diskWorst -eq 'OK') { $facts.Add('исправен') } else { $facts.Add(('проблем: {0}' -f $list.Count)) }
        if ($null -ne $disk.Temperature) { $facts.Add(('{0} °C' -f $disk.Temperature)) }
        if ($null -ne $wear) { $facts.Add(('износ {0} %' -f $wear)) }
        if (-not $disk.CountersAvailable) { $facts.Add('счётчики S.M.A.R.T. недоступны') }
        $name = Format-DiskHealthName -Disk $disk
        $parts.Add(('{0}: {1}' -f $name, ($facts -join ', ')))

        foreach ($finding in $list) { $details.Add(('{0}: {1}' -f $disk.Model, $finding.Text)) }
        $worst = Get-PcDiagWorstLevel -Current $worst -Candidate $diskWorst
    }

    if ($usb.Count -gt 0) { $parts.Add(('USB-дисков без S.M.A.R.T.: {0}' -f $usb.Count)) }
    if ($removableEvents -gt 0) { $parts.Add(('событий съёмных дисков в журнале: {0}' -f $removableEvents)) }

    if ($internal.Count -eq 0) {
        return New-PcDiagVerdict -Status Skipped -Summary ('внутренних дисков нет; ' + ($parts -join '; '))
    }
    New-PcDiagVerdict -Status $worst -Summary ($parts -join '; ') -Details $details.ToArray()
}
