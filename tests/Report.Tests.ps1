BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'PcDiag/PcDiag.psd1') -Force

    function New-TestResult {
        param([string]$Id, [string]$Status, [string]$Summary, [string[]]$Details = @(), $Data = $null)
        [pscustomobject][ordered]@{
            Id = $Id; Title = "Проверка $Id"; Status = $Status; Summary = $Summary
            Details = @($Details); DurationMs = 5; Data = $Data
        }
    }

    $meta = [ordered]@{
        ToolVersion  = '0.0.0-test'
        ComputerName = 'TEST-PC'
        CollectedAt  = '2026-11-25T14:03:00'
        PSVersion    = '5.1'
        PSEdition    = 'Desktop'
    }
}

Describe 'Format-PcDiagSummary' {
    BeforeAll {
        $results = @(
            New-TestResult -Id 'A' -Status 'OK' -Summary 'всё хорошо' -Details @('не должно попасть в сводку')
            New-TestResult -Id 'B' -Status 'Warn' -Summary 'подозрительно' -Details @('почему')
            New-TestResult -Id 'C' -Status 'Fail' -Summary 'плохо' -Details @('первая причина', 'вторая причина')
            New-TestResult -Id 'D' -Status 'Error' -Summary 'не удалось выполнить: нет доступа'
        )
        $text = Format-PcDiagSummary -Result $results -Meta $meta
        $lines = $text -split "`r`n"
    }

    It 'в заголовке имя ПК, дата в русском формате и версия' {
        $lines[0] | Should -Be 'Диагностика TEST-PC, 25.11.2026 14:03 (pcdiag 0.0.0-test)'
    }

    It 'итог перечисляет только непустые статусы' {
        $lines[1] | Should -Be 'Итог: проблем: 1, предупреждений: 1, ошибок проверки: 1, в норме: 1'
    }

    It 'проверки идут от худших к лучшим' {
        $checkLines = @($lines | Where-Object { $_ -match '^\[' })
        $checkLines[0] | Should -BeLike '`[FAIL`] Проверка C: плохо'
        $checkLines[1] | Should -BeLike '`[WARN`] Проверка B:*'
        $checkLines[2] | Should -BeLike '`[ERR `] Проверка D:*'
        $checkLines[3] | Should -BeLike '`[ OK `] Проверка A:*'
    }

    It 'пояснения выводятся под проверкой не в норме' {
        $text | Should -Match 'плохо\r\n       - первая причина\r\n       - вторая причина'
    }

    It 'у проверок в норме пояснений нет' {
        $text | Should -Not -Match 'не должно попасть'
    }

    It 'пустой список не ломает сводку' {
        Format-PcDiagSummary -Result @() -Meta $meta | Should -Match 'проверок не было'
    }
}

Describe 'Write-PcDiagReport' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'report'
        $data = [ordered]@{ LastBootUpTime = '2026-11-20T08:00:00'; Volumes = @([ordered]@{ Drive = 'C:' }) }
        $one = @(New-TestResult -Id 'Uptime' -Status 'OK' -Summary 'ok' -Data $data)
        $returned = Write-PcDiagReport -Result $one -Meta $meta -Path $dir
        $jsonText = [IO.File]::ReadAllText((Join-Path $dir 'result.json'))
    }

    It 'пишет summary.txt и result.json с BOM' {
        foreach ($name in 'summary.txt', 'result.json') {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $dir $name))
            ($bytes[0..2] -join ',') | Should -Be '239,187,191'
        }
    }

    It 'возвращает тот же текст, что записан в summary.txt' {
        [IO.File]::ReadAllText((Join-Path $dir 'summary.txt')) | Should -BeExactly $returned
    }

    It 'JSON читается и содержит метаданные' {
        $json = $jsonText | ConvertFrom-Json
        $json.Meta.ComputerName | Should -Be 'TEST-PC'
        $json.Checks[0].Id | Should -Be 'Uptime'
    }

    # Ловушка 5.1: массив из одного элемента легко превращается в объект.
    It 'Checks и вложенные массивы остаются массивами при одной записи' {
        $jsonText | Should -Match '"Checks":\s*\['
        $jsonText | Should -Match '"Volumes":\s*\['
    }

    It 'даты в данных остаются строками ISO, без \/Date()\/' {
        $jsonText | Should -Match '"LastBootUpTime":\s*"2026-11-20T08:00:00"'
        $jsonText | Should -Not -Match 'Date\('
    }
}
