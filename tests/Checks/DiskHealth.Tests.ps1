BeforeDiscovery {
    $onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $root 'PcDiag/PcDiag.psd1') -Force

    function New-TestDisk {
        param(
            [int]$Number = 0, [string]$Model = 'Test NVMe 512', [string]$Bus = 'NVMe', [string]$Media = 'SSD',
            [double]$SizeGB = 476.9, [string]$Health = 'Healthy', [string]$Operational = 'OK',
            [bool]$Counters = $true, $Temperature = 45, $Wear = 0, $ReadErrors = $null, $WriteErrors = $null
        )
        [ordered]@{
            Number = $Number; Model = $Model; BusType = $Bus; MediaType = $Media; SizeBytes = [long]($SizeGB * 1GB)
            HealthStatus = $Health; OperationalStatus = $Operational; IsSystem = ($Number -eq 0); IsBoot = ($Number -eq 0)
            CountersAvailable = $Counters; Temperature = $Temperature; Wear = $Wear; PowerOnHours = $null
            ReadErrorsUncorrected = $ReadErrors; WriteErrorsUncorrected = $WriteErrors
        }
    }

    function New-TestEventGroup {
        param([string]$Provider = 'disk', [int]$Id, $DiskNumber = $null, [string]$Drive = '', [int]$Total = 1, [string]$Last = '2026-11-20T10:00:00')
        [ordered]@{ Provider = $Provider; Id = $Id; DiskNumber = $DiskNumber; Drive = $Drive; Total = $Total; Last = $Last }
    }

    function Invoke-TestDisk {
        param([object[]]$Disks = @(), [object[]]$Events = @(), [object[]]$Volumes = @([ordered]@{ Drive = 'C:'; DiskNumber = 0 }))
        $data = [ordered]@{ Days = 30; SystemDrive = 'C:'; Disks = @($Disks); Volumes = @($Volumes); EventGroups = @($Events) }
        InModuleScope PcDiag -Parameters @{ Data = $data } { Test-DiskHealth -Data $Data }
    }

    # USB-диски так, как их видит Windows через мост: нули и пустые счётчики.
    $usbFlash = New-TestDisk -Number 1 -Model 'Generic Flash Disk' -Bus 'USB' -Media 'Unspecified' -SizeGB 7.5 -Temperature $null -Wear 0
    $usbHdd = New-TestDisk -Number 2 -Model 'External HDD' -Bus 'USB' -Media 'Unspecified' -SizeGB 465.8 -Temperature $null -Wear 0
}

Describe 'Test-DiskHealth' {
    It 'сценарий рабочего ПК: NVMe в порядке, ошибки журнала только у съёмных дисков' {
        $verdict = Invoke-TestDisk -Disks @((New-TestDisk), $usbFlash, $usbHdd) `
            -Volumes @(
                [ordered]@{ Drive = 'C:'; DiskNumber = 0 }
                [ordered]@{ Drive = 'D:'; DiskNumber = 1 }
                [ordered]@{ Drive = 'F:'; DiskNumber = 2 }
            ) `
            -Events @(
                (New-TestEventGroup -Id 51 -DiskNumber 1 -Total 130)
                (New-TestEventGroup -Id 51 -DiskNumber 2 -Total 7)
                (New-TestEventGroup -Id 153 -DiskNumber 1 -Total 15)
                (New-TestEventGroup -Id 11 -DiskNumber 2 -Total 10)
                (New-TestEventGroup -Provider 'Microsoft-Windows-Ntfs' -Id 98 -Drive 'D:')
            )
        $verdict.Status | Should -Be 'OK'
        $verdict.Summary | Should -Be 'Test NVMe 512 (NVMe SSD, 477 ГБ): исправен, 45 °C, износ 0 %; USB-дисков без S.M.A.R.T.: 2; событий съёмных дисков в журнале: 163'
    }

    It 'повторы ввода-вывода на внутреннем диске — предупреждение с пояснением' {
        $verdict = Invoke-TestDisk -Disks @(New-TestDisk) -Events @(New-TestEventGroup -Id 153 -DiskNumber 0 -Total 4 -Last '2026-11-12T15:54:00')
        $verdict.Status | Should -Be 'Warn'
        $verdict.Summary | Should -Match 'проблем: 1'
        $verdict.Details[0] | Should -Be 'Test NVMe 512: в журнале повторы операций ввода-вывода: 4 (disk 153), последнее 12.11.2026'
    }

    It 'повреждённые блоки — проблема' {
        (Invoke-TestDisk -Disks @(New-TestDisk) -Events @(New-TestEventGroup -Id 7 -DiskNumber 0)).Status | Should -Be 'Fail'
    }

    It 'события NTFS относятся к диску по букве тома' {
        $verdict = Invoke-TestDisk -Disks @((New-TestDisk), (New-TestDisk -Number 1 -Model 'Test SATA HDD' -Bus 'SATA' -Media 'HDD' -Temperature 35 -Wear $null)) `
            -Volumes @([ordered]@{ Drive = 'C:'; DiskNumber = 0 }, [ordered]@{ Drive = 'D:'; DiskNumber = 1 }) `
            -Events @(New-TestEventGroup -Provider 'Microsoft-Windows-Ntfs' -Id 98 -Drive 'D:')
        $verdict.Status | Should -Be 'Warn'
        $verdict.Details | Should -HaveCount 1
        $verdict.Details[0] | Should -Match '^Test SATA HDD: в журнале том требует проверки'
    }

    It 'повреждение файловой системы на системном томе — проблема' {
        (Invoke-TestDisk -Disks @(New-TestDisk) -Events @(New-TestEventGroup -Provider 'Ntfs' -Id 55 -Drive 'C:')).Status | Should -Be 'Fail'
    }

    It 'сбросы контроллера относятся ко всем внутренним дискам' {
        $verdict = Invoke-TestDisk -Disks @((New-TestDisk), $usbFlash) -Events @(New-TestEventGroup -Provider 'stornvme' -Id 129 -Total 3)
        $verdict.Status | Should -Be 'Warn'
        $verdict.Details[0] | Should -Match 'сбросы NVMe-диска контроллером'
    }

    It 'незнакомые коды событий игнорируются' {
        (Invoke-TestDisk -Disks @(New-TestDisk) -Events @(New-TestEventGroup -Id 999 -DiskNumber 0)).Status | Should -Be 'OK'
    }

    It 'событие на диске, которого сейчас нет, считается съёмным' {
        $verdict = Invoke-TestDisk -Disks @(New-TestDisk) -Events @(New-TestEventGroup -Id 7 -DiskNumber 5 -Total 2)
        $verdict.Status | Should -Be 'OK'
        $verdict.Summary | Should -Match 'событий съёмных дисков в журнале: 2$'
    }

    It 'состояние по оценке Windows: <Health> / <Operational> -> <Expected>' -ForEach @(
        @{ Health = 'Warning'; Operational = 'OK'; Expected = 'Warn' }
        @{ Health = 'Unhealthy'; Operational = 'OK'; Expected = 'Fail' }
        @{ Health = 'Healthy'; Operational = 'Predictive Failure'; Expected = 'Fail' }
    ) {
        (Invoke-TestDisk -Disks @(New-TestDisk -Health $Health -Operational $Operational)).Status | Should -Be $Expected
    }

    It 'неисправленные ошибки чтения — проблема, пустой счётчик — не ошибка' {
        (Invoke-TestDisk -Disks @(New-TestDisk -ReadErrors 3)).Status | Should -Be 'Fail'
        (Invoke-TestDisk -Disks @(New-TestDisk -ReadErrors $null -WriteErrors $null)).Status | Should -Be 'OK'
    }

    It 'износ SSD <Wear> % -> <Expected>' -ForEach @(
        @{ Wear = 79; Expected = 'OK' }
        @{ Wear = 85; Expected = 'Warn' }
        @{ Wear = 96; Expected = 'Fail' }
    ) {
        (Invoke-TestDisk -Disks @(New-TestDisk -Wear $Wear)).Status | Should -Be $Expected
    }

    It 'износ у HDD не оценивается' {
        (Invoke-TestDisk -Disks @(New-TestDisk -Bus 'SATA' -Media 'HDD' -Wear 99 -Temperature 40)).Status | Should -Be 'OK'
    }

    It 'температура: SSD от 70 °C и HDD от 55 °C — предупреждение' {
        (Invoke-TestDisk -Disks @(New-TestDisk -Temperature 72)).Status | Should -Be 'Warn'
        (Invoke-TestDisk -Disks @(New-TestDisk -Temperature 60)).Status | Should -Be 'OK'
        (Invoke-TestDisk -Disks @(New-TestDisk -Bus 'SATA' -Media 'HDD' -Wear $null -Temperature 56)).Status | Should -Be 'Warn'
    }

    It 'без счётчиков так и пишет, без температуры и износа' {
        $verdict = Invoke-TestDisk -Disks @(New-TestDisk -Bus 'SATA' -Media 'HDD' -Counters $false -Temperature $null -Wear $null)
        $verdict.Summary | Should -Be 'Test NVMe 512 (SATA HDD, 477 ГБ): исправен, счётчики S.M.A.R.T. недоступны'
    }

    It 'только USB-диски — Skipped, а не OK' {
        $verdict = Invoke-TestDisk -Disks @($usbFlash)
        $verdict.Status | Should -Be 'Skipped'
        $verdict.Summary | Should -Be 'внутренних дисков нет; USB-дисков без S.M.A.R.T.: 1'
    }

    It 'нет дисков — Skipped' {
        (Invoke-TestDisk -Disks @()).Status | Should -Be 'Skipped'
    }
}

Describe 'Get-DiskHealthData' -Skip:(-not $onWindows) {
    BeforeAll {
        function New-FakeDiskEvent {
            param([string]$Provider, [int]$Id, [datetime]$Time, [string[]]$Unnamed = @(), [hashtable]$Named = @{})
            $xml = '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData>'
            foreach ($value in $Unnamed) { $xml += '<Data>{0}</Data>' -f [Security.SecurityElement]::Escape($value) }
            foreach ($name in $Named.Keys) { $xml += '<Data Name="{0}">{1}</Data>' -f $name, [Security.SecurityElement]::Escape([string]$Named[$name]) }
            $xml += '</EventData></Event>'
            $fake = [pscustomobject]@{ ProviderName = $Provider; Id = $Id; TimeCreated = $Time; Xml = $xml }
            $fake | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }
            $fake
        }

        # Мокаем обёртки, а не сами командлеты Storage: те сгенерированы из CDXML и не мокаются.
        Mock -ModuleName PcDiag Get-DiskHealthDisk {
            [pscustomobject]@{ Number = 0; IsSystem = $true; IsBoot = $true }
            [pscustomobject]@{ Number = 1; IsSystem = $false; IsBoot = $false }
            [pscustomobject]@{ Number = 2; IsSystem = $false; IsBoot = $false }
        }
        Mock -ModuleName PcDiag Get-DiskHealthPhysicalDisk {
            [pscustomobject]@{ DeviceId = '1'; FriendlyName = 'Generic Flash Disk'; BusType = 'USB'; MediaType = 'Unspecified'; Size = 8GB; HealthStatus = 'Healthy'; OperationalStatus = @('OK'); SerialNumber = 'SECRET123' }
            [pscustomobject]@{ DeviceId = '0'; FriendlyName = 'Test NVMe 512'; BusType = 'NVMe'; MediaType = 'SSD'; Size = 512GB; HealthStatus = 'Healthy'; OperationalStatus = @('OK'); SerialNumber = 'SECRET456' }
            [pscustomobject]@{ DeviceId = '2'; FriendlyName = 'Test SATA HDD'; BusType = 'SATA'; MediaType = 'HDD'; Size = 1TB; HealthStatus = 'Healthy'; OperationalStatus = @('OK'); SerialNumber = 'SECRET789' }
        }
        Mock -ModuleName PcDiag Get-DiskHealthCounter {
            if ($PhysicalDisk.DeviceId -eq '2') { throw 'Not supported' }
            [pscustomobject]@{ Temperature = 45; Wear = 0; PowerOnHours = $null; ReadErrorsUncorrected = $null; WriteErrorsUncorrected = $null }
        }
        Mock -ModuleName PcDiag Get-DiskHealthPartition {
            [pscustomobject]@{ DriveLetter = 'C'; DiskNumber = 0 }
            [pscustomobject]@{ DriveLetter = [char]0; DiskNumber = 0 }
            [pscustomobject]@{ DriveLetter = 'd'; DiskNumber = 1 }
        }
        Mock -ModuleName PcDiag Get-WinEvent { }
        Mock -ModuleName PcDiag Get-WinEvent -ParameterFilter { $FilterHashtable[0].ProviderName -eq 'disk' } {
            New-FakeDiskEvent -Provider 'disk' -Id 51 -Time '2026-11-24T10:00:00' -Unnamed @('\Device\Harddisk1\DR22', '0301800001')
            New-FakeDiskEvent -Provider 'disk' -Id 51 -Time '2026-11-25T10:01:00' -Unnamed @('\Device\Harddisk1\DR22', '0301800001')
            New-FakeDiskEvent -Provider 'disk' -Id 153 -Time '2026-11-12T15:54:00' -Unnamed @('\Device\Harddisk1\DR14', '0xa0', '1', '\Device\00000116')
        }
        Mock -ModuleName PcDiag Get-WinEvent -ParameterFilter { $FilterHashtable[0].ProviderName -eq 'Microsoft-Windows-Ntfs' } {
            New-FakeDiskEvent -Provider 'Microsoft-Windows-Ntfs' -Id 98 -Time '2026-10-29T12:36:00' -Named @{ DriveName = 'd:'; DeviceName = '\Device\HarddiskVolume8' }
        }
        # Так Get-WinEvent отвечает про источник, который не пишет в журнал «Система».
        Mock -ModuleName PcDiag Get-WinEvent -ParameterFilter { $FilterHashtable[0].ProviderName -eq 'iaStorA' } {
            throw [System.Management.Automation.ErrorRecord]::new([Exception]::new('no overlap'),
                'LogsAndProvidersDontOverlap,Microsoft.PowerShell.Commands.GetWinEventCommand',
                [System.Management.Automation.ErrorCategory]::InvalidArgument, $null)
        }

        $data = InModuleScope PcDiag { Get-DiskHealthData }
    }

    It 'диски упорядочены по номеру и связаны с Get-Disk' {
        $data.Disks[0].Number | Should -Be 0
        $data.Disks[0].IsSystem | Should -BeTrue
        $data.Disks[1].BusType | Should -Be 'USB'
    }

    It 'счётчики надёжности читаются' {
        $data.Disks[0].CountersAvailable | Should -BeTrue
        $data.Disks[0].Temperature | Should -Be 45
    }

    It 'у USB-диска счётчики не запрашиваются вовсе: через мост это бывает очень долго' {
        $data.Disks[1].CountersAvailable | Should -Be $false
        Should -Invoke -ModuleName PcDiag Get-DiskHealthCounter -Times 0 -Exactly -Scope Describe -ParameterFilter { $PhysicalDisk.DeviceId -eq '1' }
    }

    It 'сбой чтения счётчиков у внутреннего диска не роняет сбор' {
        $data.Disks[2].CountersAvailable | Should -Be $false
        $data.Disks[2].Model | Should -Be 'Test SATA HDD'
    }

    It 'серийные номера в данные не попадают' {
        ($data | ConvertTo-Json -Depth 6) | Should -Not -Match 'SECRET'
    }

    It 'тома: только с буквой, буква в верхнем регистре' {
        @($data.Volumes).Count | Should -Be 2
        $data.Volumes[1].Drive | Should -Be 'D:'
    }

    It 'события группируются по коду и номеру диска из безымянного поля' {
        $group51 = @($data.EventGroups | Where-Object { $_.Id -eq 51 })
        $group51 | Should -HaveCount 1
        $group51[0].DiskNumber | Should -Be 1
        $group51[0].Total | Should -Be 2
        $group51[0].Last | Should -Be '2026-11-25T10:01:00'
    }

    It 'у Ntfs берётся буква тома из именованного поля' {
        $ntfs = @($data.EventGroups | Where-Object { $_.Id -eq 98 })
        $ntfs[0].Drive | Should -Be 'D:'
        $ntfs[0].DiskNumber | Should -BeNullOrEmpty
    }

    It 'журнал фильтруется по уровню прямо в запросе' {
        Should -Invoke -ModuleName PcDiag Get-WinEvent -Scope Describe -ParameterFilter {
            $FilterHashtable[0].ProviderName -eq 'disk' -and @($FilterHashtable[0].Level) -contains 2 -and $null -ne $FilterHashtable[0].StartTime
        }
    }
}
