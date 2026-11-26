# Движок: выбор и запуск проверок. Систему не трогает, файлы не пишет.

function Get-PcDiagCheck {
    <#
    .SYNOPSIS
        Список зарегистрированных проверок или только перечисленных в -Id.
        Неизвестный Id — исключение со списком допустимых.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string[]]$Id)

    $all = @($script:Checks)
    if (-not $Id) { return $all }
    foreach ($one in $Id) {
        $found = @($all | Where-Object { $_.Id -eq $one })
        if ($found.Count -eq 0) {
            $known = ($all | ForEach-Object { $_.Id }) -join ', '
            throw "Неизвестная проверка: $one. Есть: $known"
        }
        $found[0]
    }
}

function Invoke-PcDiagCheck {
    <#
    .SYNOPSIS
        Запускает проверки и возвращает по объекту на каждую:
        Id, Title, Status, Summary, Details, DurationMs, Data.
    .DESCRIPTION
        Сбой одной проверки не останавливает остальные и не выглядит как «всё хорошо»:
        любое исключение в Get-<Id>Data или Test-<Id> превращается в статус Error с текстом ошибки.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string[]]$Id)

    # Внутри проверок любая ошибка должна прерывать сбор, а не тихо давать пустые данные.
    # Там, где отсутствие данных нормально, проверка сама ставит -ErrorAction SilentlyContinue.
    $ErrorActionPreference = 'Stop'

    foreach ($check in @(Get-PcDiagCheck -Id $Id)) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $data = $null
        try {
            $data = & "Get-$($check.Id)Data"
            $verdict = & "Test-$($check.Id)" -Data $data
            # Частая ошибка: лишний вывод в Test-* превращает вердикт в массив.
            if ($null -eq $verdict -or $verdict -is [array] -or
                $null -eq $verdict.PSObject.Properties['Status'] -or
                -not $script:StatusOrder.ContainsKey([string]$verdict.Status)) {
                throw 'проверка вернула результат неверной формы'
            }
        }
        catch {
            $verdict = New-PcDiagVerdict -Status Error -Summary ('не удалось выполнить: {0}' -f $_.Exception.Message)
        }
        $timer.Stop()

        [pscustomobject][ordered]@{
            Id         = $check.Id
            Title      = $check.Title
            Status     = $verdict.Status
            Summary    = $verdict.Summary
            Details    = @($verdict.Details)
            DurationMs = [int]$timer.ElapsedMilliseconds
            Data       = $data
        }
    }
}
