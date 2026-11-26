BeforeDiscovery {
    # Сбор данных зовёт Windows-командлеты (Get-CimInstance), на Linux и macOS их нет.
    $onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $root 'PcDiag/PcDiag.psd1') -Force

    function New-UptimeData {
        param(
            [string]$Boot = '2026-11-23T09:00:00',
            [string]$Now = '2026-11-25T12:30:00',
            $Hiberboot = 0,
            $Hibernate = 1
        )
        [ordered]@{
            Caption          = 'Microsoft Windows 10 Pro'
            Version          = '10.0.19045'
            BuildNumber      = '19045'
            LastBootUpTime   = $Boot
            LocalDateTime    = $Now
            HiberbootEnabled = $Hiberboot
            HibernateEnabled = $Hibernate
        }
    }
}

Describe 'Test-Uptime' {
    It 'норма: два дня без перезагрузки' {
        $data = New-UptimeData
        $verdict = InModuleScope PcDiag -Parameters @{ Data = $data } { Test-Uptime -Data $Data }
        $verdict.Status | Should -Be 'OK'
        $verdict.Summary | Should -Be 'Windows 10 Pro, сборка 19045; без перезагрузки 2 дн. 3 ч (с 23.11.2026 09:00)'
    }

    It 'русское название ОС тоже без «Майкрософт»' {
        $data = New-UptimeData
        $data.Caption = 'Майкрософт Windows 11 Pro'
        $verdict = InModuleScope PcDiag -Parameters @{ Data = $data } { Test-Uptime -Data $Data }
        $verdict.Summary | Should -BeLike 'Windows 11 Pro, сборка*'
    }

    It 'меньше суток показывается в часах и минутах' {
        $data = New-UptimeData -Boot '2026-11-25T09:15:00'
        $verdict = InModuleScope PcDiag -Parameters @{ Data = $data } { Test-Uptime -Data $Data }
        $verdict.Summary | Should -Match 'без перезагрузки 3 ч 15 мин'
    }

    It 'меньше часа показывается в минутах' {
        $data = New-UptimeData -Boot '2026-11-25T12:00:00'
        $verdict = InModuleScope PcDiag -Parameters @{ Data = $data } { Test-Uptime -Data $Data }
        $verdict.Summary | Should -Match 'без перезагрузки 30 мин'
    }

    It 'предупреждение после 14 дней' {
        $data = New-UptimeData -Boot '2026-11-01T09:00:00'
        $verdict = InModuleScope PcDiag -Parameters @{ Data = $data } { Test-Uptime -Data $Data }
        $verdict.Status | Should -Be 'Warn'
        $verdict.Details | Should -HaveCount 1
    }

    It 'при быстром запуске подсказывает, что выключение не сбрасывает аптайм' {
        $data = New-UptimeData -Boot '2026-11-01T09:00:00' -Hiberboot 1 -Hibernate 1
        $verdict = InModuleScope PcDiag -Parameters @{ Data = $data } { Test-Uptime -Data $Data }
        $verdict.Details | Should -HaveCount 2
        $verdict.Details[1] | Should -Match 'быстрый запуск'
    }

    It 'быстрый запуск не упоминается, если гибернация выключена' {
        $data = New-UptimeData -Boot '2026-11-01T09:00:00' -Hiberboot 1 -Hibernate 0
        $verdict = InModuleScope PcDiag -Parameters @{ Data = $data } { Test-Uptime -Data $Data }
        $verdict.Details | Should -HaveCount 1
    }

    It 'загрузка позже текущего времени — предупреждение про часы' {
        $data = New-UptimeData -Boot '2026-11-26T09:00:00'
        $verdict = InModuleScope PcDiag -Parameters @{ Data = $data } { Test-Uptime -Data $Data }
        $verdict.Status | Should -Be 'Warn'
        $verdict.Details[0] | Should -Match 'часы'
    }
}

Describe 'Get-UptimeData' -Skip:(-not $onWindows) {
    BeforeAll {
        Mock -ModuleName PcDiag Get-CimInstance {
            [pscustomobject]@{
                Caption        = 'Microsoft Windows 11 Pro'
                Version        = '10.0.26100'
                BuildNumber    = '26100'
                LastBootUpTime = [datetime]'2026-11-20T08:00:00'
                LocalDateTime  = [datetime]'2026-11-25T08:00:00'
            }
        }
        Mock -ModuleName PcDiag Get-ItemProperty -ParameterFilter { $LiteralPath -like '*Session Manager\Power' } {
            [pscustomobject]@{ HiberbootEnabled = 1 }
        }
        # Как на живом ПК с Windows 11: явного HibernateEnabled нет, есть только значение по умолчанию.
        Mock -ModuleName PcDiag Get-ItemProperty -ParameterFilter { $LiteralPath -like '*Control\Power' -and $Name -eq 'HibernateEnabled' } { $null }
        Mock -ModuleName PcDiag Get-ItemProperty -ParameterFilter { $LiteralPath -like '*Control\Power' -and $Name -eq 'HibernateEnabledDefault' } {
            [pscustomobject]@{ HibernateEnabledDefault = 1 }
        }

        $data = InModuleScope PcDiag { Get-UptimeData }
    }

    It 'отдаёт даты строками ISO' {
        $data.LastBootUpTime | Should -Be '2026-11-20T08:00:00'
        $data.LocalDateTime | Should -Be '2026-11-25T08:00:00'
    }

    It 'читает быстрый запуск' {
        $data.HiberbootEnabled | Should -Be 1
    }

    It 'без явного HibernateEnabled берёт HibernateEnabledDefault' {
        $data.HibernateEnabled | Should -Be 1
    }

    It 'спрашивает именно Win32_OperatingSystem' {
        # Вызов был в BeforeAll, поэтому считаем по всему Describe, а не по этому It (по умолчанию -Scope It).
        Should -Invoke -ModuleName PcDiag Get-CimInstance -Times 1 -Exactly -Scope Describe -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
    }
}
