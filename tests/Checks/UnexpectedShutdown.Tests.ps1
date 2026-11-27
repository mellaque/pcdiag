BeforeDiscovery {
    $onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $root 'PcDiag/PcDiag.psd1') -Force

    # Данные выдуманы, но повторяют структуру событий с настоящего ноутбука.
    function New-Crash {
        param([string]$Time, [long]$Bugcheck = 0, [string]$Parameter1 = '0x0', [long]$Sleep = 0, [long]$Button = 0, [bool]$LongPress = $false)
        [ordered]@{
            Time = $Time; BugcheckCode = $Bugcheck; BugcheckParameter1 = $Parameter1
            SleepInProgress = $Sleep; PowerButtonTimestamp = $Button; LongPowerButtonPress = $LongPress
        }
    }

    function New-ShutdownData {
        param(
            [object[]]$Crashes = @(),
            [object[]]$BugChecks = @(),
            [object[]]$Shutdowns = @(),
            [object[]]$Minidumps = @(),
            $Hiberboot = 0,
            $Hibernate = 0
        )
        [ordered]@{
            Days = 30; Since = '2026-10-28T12:00:00'
            Crashes = @($Crashes); BugChecks = @($BugChecks); Shutdowns = @($Shutdowns)
            DirtyShutdownCount = @($Crashes).Count; Minidumps = @($Minidumps)
            HiberbootEnabled = $Hiberboot; HibernateEnabled = $Hibernate
        }
    }

    function Invoke-TestShutdown {
        param($Data)
        InModuleScope PcDiag -Parameters @{ Data = $Data } { Test-UnexpectedShutdown -Data $Data }
    }
}

Describe 'Test-UnexpectedShutdown' {
    It 'нет сбоев — OK' {
        $verdict = Invoke-TestShutdown -Data (New-ShutdownData)
        $verdict.Status | Should -Be 'OK'
        $verdict.Summary | Should -Be 'за 30 дн. аварийных перезагрузок нет'
    }

    It 'сценарий ноутбука: синий экран и сбой гибернации после выключения через Пуск' {
        $data = New-ShutdownData -Hiberboot 1 -Hibernate 0 `
            -Crashes @(
                (New-Crash -Time '2026-11-13T12:01:08' -Sleep 4)
                (New-Crash -Time '2026-11-12T15:15:23' -Bugcheck 59 -Parameter1 '0xc0000005')
            ) `
            -BugChecks @([ordered]@{ Time = '2026-11-12T15:15:29'; Text = '0x0000003b (...)'; Dump = '111226-0001-01.dmp' }) `
            -Shutdowns @([ordered]@{ Time = '2026-11-12T16:41:35'; Process = 'StartMenuExperienceHost.exe'; Action = 'Выключение питания'; ReasonCode = '0x0' }) `
            -Minidumps @(
                [ordered]@{ Name = '091926-0001-01.dmp'; Time = '2026-09-19T12:22:00'; SizeKB = 6641 }
                [ordered]@{ Name = '111226-0001-01.dmp'; Time = '2026-11-12T15:15:00'; SizeKB = 6913 }
            )
        $verdict = Invoke-TestShutdown -Data $data

        $verdict.Status | Should -Be 'Fail'
        $verdict.Summary | Should -Be 'за 30 дн. аварийных перезагрузок: 2 (синий экран: 1, сбой сна или гибернации: 1)'
        $verdict.Details | Should -HaveCount 3
        $verdict.Details[0] | Should -Be '12.11.2026 15:15 загрузка после синего экрана 0x3B SYSTEM_SERVICE_EXCEPTION (обращение к недопустимой памяти), дамп 111226-0001-01.dmp'
        $verdict.Details[1] | Should -Be '13.11.2026 12:01 загрузка после сбоя гибернации или быстрого запуска (S4); перед этим 12.11 16:41 «Выключение питания» через Пуск'
        $verdict.Details[2] | Should -Be 'в папке Minidump есть дампы старше 30 дн.: 1, последний от 19.09.2026'
    }

    It 'без синего экрана — предупреждение, а не проблема' {
        $verdict = Invoke-TestShutdown -Data (New-ShutdownData -Crashes @(New-Crash -Time '2026-11-13T12:01:08' -Sleep 4))
        $verdict.Status | Should -Be 'Warn'
    }

    It 'удержание кнопки питания распознаётся и по метке времени, и по флагу' {
        $verdict = Invoke-TestShutdown -Data (New-ShutdownData -Crashes @(
                (New-Crash -Time '2026-11-10T10:00:00' -Button 133000000000000000)
                (New-Crash -Time '2026-11-11T10:00:00' -LongPress $true)
            ))
        $verdict.Summary | Should -Match 'кнопка питания: 2'
        $verdict.Details[0] | Should -Match 'удержанием кнопки питания'
    }

    It 'без признаков — потеря питания или зависание' {
        $verdict = Invoke-TestShutdown -Data (New-ShutdownData -Crashes @(New-Crash -Time '2026-11-10T10:00:00'))
        $verdict.Details[0] | Should -Be '10.11.2026 10:00 загрузка после внезапной потери питания или зависания'
    }

    It 'сбой в обычном сне показывает состояние S3' {
        $verdict = Invoke-TestShutdown -Data (New-ShutdownData -Crashes @(New-Crash -Time '2026-11-10T10:00:00' -Sleep 3))
        $verdict.Details[0] | Should -Match 'сбоя во сне \(S3\)'
    }

    It 'синий экран важнее остальных признаков' {
        $verdict = Invoke-TestShutdown -Data (New-ShutdownData -Crashes @(New-Crash -Time '2026-11-10T10:00:00' -Bugcheck 0x9F -Sleep 4))
        $verdict.Details[0] | Should -Match 'синего экрана 0x9F DRIVER_POWER_STATE_FAILURE'
    }

    It 'неизвестный код синего экрана выводится просто числом' {
        $verdict = Invoke-TestShutdown -Data (New-ShutdownData -Crashes @(New-Crash -Time '2026-11-10T10:00:00' -Bugcheck 0x12345))
        $verdict.Details[0] | Should -Be '10.11.2026 10:00 загрузка после синего экрана 0x12345'
    }

    It 'дамп находится по времени файла, если отчёта WER нет' {
        $data = New-ShutdownData -Crashes @(New-Crash -Time '2026-11-10T10:00:00' -Bugcheck 0x50) `
            -Minidumps @([ordered]@{ Name = '111026-0001-01.dmp'; Time = '2026-11-10T10:01:00'; SizeKB = 500 })
        (Invoke-TestShutdown -Data $data).Details[0] | Should -Match 'дамп 111026-0001-01\.dmp$'
    }

    It 'для синего экрана не пишет, как выключали перед этим' {
        $data = New-ShutdownData -Crashes @(New-Crash -Time '2026-11-10T10:00:00' -Bugcheck 0x50) `
            -Shutdowns @([ordered]@{ Time = '2026-11-09T18:00:00'; Process = 'StartMenuExperienceHost.exe'; Action = 'Выключение питания'; ReasonCode = '0x0' })
        (Invoke-TestShutdown -Data $data).Details[0] | Should -Not -Match 'перед этим'
    }

    It 'неизвестная программа выключения показывается по имени' {
        $data = New-ShutdownData -Crashes @(New-Crash -Time '2026-11-10T10:00:00' -Sleep 3) `
            -Shutdowns @([ordered]@{ Time = '2026-11-09T18:00:00'; Process = 'tool.exe'; Action = ''; ReasonCode = '0x0' })
        (Invoke-TestShutdown -Data $data).Details[0] | Should -Match 'перед этим 09\.11 18:00 «выключение» \(tool\.exe\)$'
    }

    It 'для потери питания не пишет, как выключали перед этим' {
        $data = New-ShutdownData -Crashes @(New-Crash -Time '2026-11-26T15:41:03') `
            -Shutdowns @([ordered]@{ Time = '2026-11-20T04:01:39'; Process = 'TrustedInstaller.exe'; Action = 'Перезапустить'; ReasonCode = '0x80020003' })
        (Invoke-TestShutdown -Data $data).Details[0] | Should -Be '26.11.2026 15:41 загрузка после внезапной потери питания или зависания'
    }

    It 'служба обновлений называется по-человечески' {
        $data = New-ShutdownData -Crashes @(New-Crash -Time '2026-11-12T10:00:00' -Sleep 4) `
            -Shutdowns @([ordered]@{ Time = '2026-11-11T06:44:20'; Process = 'MoUsoCoreWorker.exe'; Action = 'Перезапустить'; ReasonCode = '0x80020010' })
        (Invoke-TestShutdown -Data $data).Details[0] | Should -Match '«Перезапустить» для установки обновлений$'
    }

    It 'при включённом быстром запуске объясняет сбои гибернации' {
        $data = New-ShutdownData -Hiberboot 1 -Hibernate 1 -Crashes @(New-Crash -Time '2026-11-10T10:00:00' -Sleep 4)
        (Invoke-TestShutdown -Data $data).Details[-1] | Should -Match '^включён быстрый запуск'
    }

    It 'если гибернация выключена, про быстрый запуск молчит' {
        $data = New-ShutdownData -Hiberboot 1 -Hibernate 0 -Crashes @(New-Crash -Time '2026-11-10T10:00:00' -Sleep 4)
        (Invoke-TestShutdown -Data $data).Details | Should -Not -Match 'быстрый запуск:'
    }

    It 'длинный список обрезается до последних сбоев' {
        $many = @(for ($i = 1; $i -le 12; $i++) { New-Crash -Time ('2026-11-{0:00}T10:00:00' -f $i) })
        $verdict = Invoke-TestShutdown -Data (New-ShutdownData -Crashes $many)
        $verdict.Details[0] | Should -Be 'показаны последние 8 из 12'
        $verdict.Details[1] | Should -Match '^05\.11\.2026'
        $verdict.Details | Should -HaveCount 9
    }

    It 'старые дампы упоминаются даже без сбоев за период' {
        $data = New-ShutdownData -Minidumps @([ordered]@{ Name = '091926-0001-01.dmp'; Time = '2026-09-19T12:22:00'; SizeKB = 6641 })
        $verdict = Invoke-TestShutdown -Data $data
        $verdict.Status | Should -Be 'OK'
        $verdict.Details[0] | Should -Match 'старше 30 дн\.: 1'
    }

    It 'отсутствующие списки не роняют проверку' {
        $verdict = Invoke-TestShutdown -Data ([ordered]@{ Days = 30; Since = '2026-10-28T12:00:00' })
        $verdict.Status | Should -Be 'OK'
    }
}

Describe 'Get-UnexpectedShutdownData' -Skip:(-not $onWindows) {
    BeforeAll {
        function New-FakeEvent {
            param([string]$Provider, [int]$Id, [datetime]$Time, [hashtable]$Fields = @{}, [string[]]$Unnamed = @())
            $xml = '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData>'
            foreach ($name in $Fields.Keys) {
                $xml += '<Data Name="{0}">{1}</Data>' -f $name, [Security.SecurityElement]::Escape([string]$Fields[$name])
            }
            foreach ($value in $Unnamed) { $xml += '<Data>{0}</Data>' -f [Security.SecurityElement]::Escape($value) }
            $xml += '</EventData></Event>'
            # $event не берём: это автоматическая переменная PowerShell.
            $fake = [pscustomobject]@{ ProviderName = $Provider; Id = $Id; TimeCreated = $Time; Xml = $xml }
            $fake | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }
            $fake
        }
    }

    Context 'события есть' {
        BeforeAll {
            Mock -ModuleName PcDiag Get-WinEvent {
                New-FakeEvent -Provider 'Microsoft-Windows-Kernel-Power' -Id 41 -Time '2026-11-12T15:15:23' -Fields @{
                    BugcheckCode = '59'; BugcheckParameter1 = '0xc0000005'; SleepInProgress = '0'
                    PowerButtonTimestamp = '0'; LongPowerButtonPressDetected = 'false'
                }
                New-FakeEvent -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -Id 1001 -Time '2026-11-12T15:15:29' -Fields @{
                    param1 = '0x0000003b (0x00000000c0000005, 0x0, 0x0, 0x0)'; param2 = 'C:\WINDOWS\Minidump\111226-0001-01.dmp'
                }
                New-FakeEvent -Provider 'User32' -Id 1074 -Time '2026-11-12T16:41:35' -Fields @{
                    param1 = 'C:\Windows\SystemApps\StartMenuExperienceHost.exe (TEST-PC)'; param2 = 'TEST-PC'
                    param4 = '0x0'; param5 = 'Выключение питания'; param7 = 'TEST-PC\Иванов И.И.'
                }
                New-FakeEvent -Provider 'EventLog' -Id 6008 -Time '2026-11-12T15:15:30' -Unnamed @('15:10:01', '12.11.2026')
                # Событие с тем же Id от другого источника не должно учитываться.
                New-FakeEvent -Provider 'Some-Other-Provider' -Id 41 -Time '2026-11-12T15:20:00'
            }
            Mock -ModuleName PcDiag Get-ChildItem -ParameterFilter { $LiteralPath -like '*Minidump' } {
                [pscustomobject]@{ Name = '111226-0001-01.dmp'; LastWriteTime = [datetime]'2026-11-12T15:15:00'; Length = 7MB }
            }
            Mock -ModuleName PcDiag Get-ItemProperty { $null }

            $data = InModuleScope PcDiag { Get-UnexpectedShutdownData }
        }

        It 'разбирает поля Kernel-Power 41' {
            @($data.Crashes).Count | Should -Be 1
            $data.Crashes[0].BugcheckCode | Should -Be 59
            $data.Crashes[0].BugcheckParameter1 | Should -Be '0xc0000005'
            $data.Crashes[0].Time | Should -Be '2026-11-12T15:15:23'
        }

        It 'из отчёта WER берёт только имя файла дампа' {
            $data.BugChecks[0].Dump | Should -Be '111226-0001-01.dmp'
        }

        It 'из события 1074 не сохраняет имя ПК и учётную запись' {
            $data.Shutdowns[0].Process | Should -Be 'StartMenuExperienceHost.exe'
            $json = $data | ConvertTo-Json -Depth 6
            $json | Should -Not -Match 'TEST-PC'
            $json | Should -Not -Match 'Иванов'
        }

        It 'считает 6008, не разбирая безымянные поля' {
            $data.DirtyShutdownCount | Should -Be 1
        }

        It 'перечисляет минидампы с размером в КБ' {
            $data.Minidumps[0].Name | Should -Be '111226-0001-01.dmp'
            $data.Minidumps[0].SizeKB | Should -Be 7168
        }

        It 'фильтрует журнал в самом запросе' {
            Should -Invoke -ModuleName PcDiag Get-WinEvent -Times 1 -Exactly -Scope Context -ParameterFilter {
                # У Get-WinEvent параметр -FilterHashtable — массив таблиц.
                $FilterHashtable[0].LogName -eq 'System' -and $null -ne $FilterHashtable[0].StartTime -and $FilterHashtable[0].Id -contains 41
            }
        }
    }

    Context 'событий нет' {
        BeforeAll {
            # Так Get-WinEvent сообщает, что под фильтр ничего не попало.
            Mock -ModuleName PcDiag Get-WinEvent {
                $exception = [Exception]::new('No events were found that match the specified selection criteria.')
                throw [System.Management.Automation.ErrorRecord]::new($exception,
                    'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
            }
            Mock -ModuleName PcDiag Get-ChildItem -ParameterFilter { $LiteralPath -like '*Minidump' } { }
            Mock -ModuleName PcDiag Get-ItemProperty { $null }
        }

        It '«событий нет» — пустой список, а не ошибка' {
            $data = InModuleScope PcDiag { Get-UnexpectedShutdownData }
            @($data.Crashes).Count | Should -Be 0
            @($data.Minidumps).Count | Should -Be 0
        }
    }

    Context 'журнал недоступен' {
        BeforeAll {
            Mock -ModuleName PcDiag Get-WinEvent { throw 'Access is denied' }
            Mock -ModuleName PcDiag Get-ItemProperty { $null }
        }

        It 'другие ошибки чтения журнала не прячутся' {
            { InModuleScope PcDiag { Get-UnexpectedShutdownData } } | Should -Throw '*Access is denied*'
        }
    }
}
