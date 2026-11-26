# Сводка для заметки к заявке и файлы отчёта.

$script:StatusMark = @{
    Fail    = '[FAIL]'
    Warn    = '[WARN]'
    Error   = '[ERR ]'
    Skipped = '[SKIP]'
    OK      = '[ OK ]'
}

function Format-PcDiagSummary {
    <#
    .SYNOPSIS
        Текст сводки: заголовок, итог по статусам, строки проверок от худших к лучшим.
        Пояснения выводятся только для проверок не в норме.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Result,
        [Parameter(Mandatory)] $Meta
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $when = (ConvertFrom-PcDiagDate -Text $Meta.CollectedAt).ToString('dd.MM.yyyy HH:mm')
    $lines.Add(('Диагностика {0}, {1} (pcdiag {2})' -f $Meta.ComputerName, $when, $Meta.ToolVersion))

    $names = [ordered]@{ Fail = 'проблем'; Warn = 'предупреждений'; Error = 'ошибок проверки'; Skipped = 'пропущено'; OK = 'в норме' }
    # @() обязателен: пустой foreach даёт $null, а @($null).Count равно 1.
    $counts = @(foreach ($status in $names.Keys) {
            $n = @($Result | Where-Object { $_.Status -eq $status }).Count
            if ($n -gt 0) { '{0}: {1}' -f $names[$status], $n }
        })
    if ($counts.Count -eq 0) { $lines.Add('Итог: проверок не было') }
    else { $lines.Add('Итог: ' + ($counts -join ', ')) }
    $lines.Add('')

    # Сортировка по двум ключам вместо стабильной сортировки: -Stable есть только в 7.
    $rows = @(for ($i = 0; $i -lt $Result.Count; $i++) {
            [pscustomobject]@{ Rank = $script:StatusOrder[[string]$Result[$i].Status]; Index = $i; Item = $Result[$i] }
        })
    foreach ($row in @($rows | Sort-Object -Property Rank, Index)) {
        $item = $row.Item
        $mark = $script:StatusMark[[string]$item.Status]
        if (-not $mark) { $mark = '[????]' }
        $lines.Add(('{0} {1}: {2}' -f $mark, $item.Title, $item.Summary))
        if ($item.Status -ne 'OK') {
            foreach ($detail in @($item.Details)) { $lines.Add('       - ' + $detail) }
        }
    }
    $lines -join "`r`n"
}

function Write-PcDiagReport {
    <#
    .SYNOPSIS
        Пишет summary.txt и result.json в папку отчёта и возвращает текст сводки.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Result,
        [Parameter(Mandatory)] $Meta,
        [Parameter(Mandatory)] [string]$Path
    )
    $null = New-Item -ItemType Directory -Path $Path -Force
    $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath

    $summary = Format-PcDiagSummary -Result $Result -Meta $Meta
    $report = [ordered]@{ Meta = $Meta; Checks = @($Result) }
    $json = ConvertTo-Json -InputObject $report -Depth 8

    Write-PcDiagTextFile -Path (Join-Path $fullPath 'summary.txt') -Text $summary
    Write-PcDiagTextFile -Path (Join-Path $fullPath 'result.json') -Text $json
    $summary
}

function Write-PcDiagTextFile {
    <#
    Set-Content -Encoding UTF8 пишет BOM в 5.1 и не пишет в 7.
    Явная кодировка .NET даёт один и тот же файл в обеих версиях.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}
