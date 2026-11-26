# Общие функции для проверок и отчёта.

# Порядок статусов: чем меньше число, тем выше строка в сводке.
$script:StatusOrder = @{ Fail = 0; Warn = 1; Error = 2; Skipped = 3; OK = 4 }

# Числа в сводке всегда с запятой, на любом языке Windows и на раннере CI.
# Берём неизменяемый формат и меняем только разделитель, без зависимости от культуры ru-RU.
$script:NumberFormat = [Globalization.NumberFormatInfo]::InvariantInfo.Clone()
$script:NumberFormat.NumberDecimalSeparator = ','

function Register-PcDiagCheck {
    <#
    .SYNOPSIS
        Добавляет проверку в реестр. Вызывается в начале файла из Checks\.
        Рядом в том же файле должны быть функции Get-<Id>Data и Test-<Id>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Title
    )
    if (@($script:Checks | Where-Object { $_.Id -eq $Id }).Count -gt 0) {
        throw "Проверка '$Id' зарегистрирована дважды"
    }
    $script:Checks.Add([pscustomobject]@{ Id = $Id; Title = $Title })
}

function New-PcDiagVerdict {
    <#
    .SYNOPSIS
        Вердикт проверки: статус, одна строка для сводки и пояснения.
        Возвращается из Test-<Id>; Id, название и данные добавляет движок.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Создаёт объект в памяти, систему не меняет')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('OK', 'Warn', 'Fail', 'Skipped', 'Error')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Summary,

        [string[]]$Details = @()
    )
    [pscustomobject]@{
        Status  = $Status
        Summary = $Summary
        Details = @($Details)
    }
}

function Get-PcDiagWorstLevel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Current,
        [Parameter(Mandatory)] [string]$Candidate
    )
    if ($script:StatusOrder[$Candidate] -lt $script:StatusOrder[$Current]) { return $Candidate }
    $Current
}

function ConvertFrom-PcDiagDate {
    <# Данные проверок хранят даты строками ISO 8601 ('s'), чтобы JSON был одинаковым в 5.1 и 7. #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)] [string]$Text)
    [datetime]::ParseExact($Text, 's', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-PcDiagNumber {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [double]$Value,
        [ValidateRange(0, 3)] [int]$Decimals = 1
    )
    $pattern = '0'
    if ($Decimals -gt 0) { $pattern = '0.' + ('#' * $Decimals) }
    $Value.ToString($pattern, $script:NumberFormat)
}

function Format-PcDiagDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [timespan]$Span)
    if ($Span.TotalDays -ge 1) { return '{0} дн. {1} ч' -f $Span.Days, $Span.Hours }
    if ($Span.TotalHours -ge 1) { return '{0} ч {1} мин' -f $Span.Hours, $Span.Minutes }
    '{0} мин' -f $Span.Minutes
}

function Get-PcDiagRegistryValue {
    <# Значение из реестра или $null, если ключа или значения нет. Отсутствие — не ошибка. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name
    )
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $item.$Name
}
