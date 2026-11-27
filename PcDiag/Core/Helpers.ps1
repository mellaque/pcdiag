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

function Get-PcDiagHibernateSetting {
    <#
    .SYNOPSIS
        Флаги быстрого запуска и гибернации. Быстрый запуск реально работает,
        только если включены оба: без гибернации ядру некуда сохраняться.
    #>
    [CmdletBinding()]
    param()
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    $hibernate = Get-PcDiagRegistryValue -Path $powerKey -Name 'HibernateEnabled'
    # На части систем явного значения нет (гибернацию не переключали через powercfg /h),
    # тогда действует значение по умолчанию.
    if ($null -eq $hibernate) { $hibernate = Get-PcDiagRegistryValue -Path $powerKey -Name 'HibernateEnabledDefault' }
    [ordered]@{
        HiberbootEnabled = Get-PcDiagRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled'
        HibernateEnabled = $hibernate
    }
}

function Get-PcDiagWinEvent {
    <#
    .SYNOPSIS
        Get-WinEvent, у которого «событий нет» и «нет такого источника» — пустой результат, а не ошибка.
        Остальные ошибки (нет журнала, нет доступа) пробрасываются: движок покажет их как ERR.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable]$Filter)
    try {
        @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop)
    }
    catch {
        # Пустой результат: под фильтр ничего не попало, или такого источника на этом ПК нет
        # (например, драйвера iaStorA или провайдера, не пишущего в этот журнал).
        $id = [string]$_.FullyQualifiedErrorId
        if ($id -like 'NoMatchingEventsFound*' -or $id -like 'NoMatchingProvidersFound*' -or $id -like 'LogsAndProvidersDontOverlap*') { return }
        throw
    }
}

function ConvertFrom-PcDiagEventData {
    <#
    .SYNOPSIS
        Именованные поля EventData события в виде словаря Name -> текст.
        Безымянные поля (как у EventLog 6008) пропускаются: их смысл зависит от позиции и языка.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record)
    $result = @{}
    $xml = [xml]$Record.ToXml()
    # local-name(): у событий есть пространство имён, а обращение через точки падает в StrictMode, если узла нет.
    foreach ($node in @($xml.SelectNodes("//*[local-name()='EventData']/*[local-name()='Data']"))) {
        if ($node.HasAttribute('Name')) { $result[$node.GetAttribute('Name')] = $node.InnerText }
    }
    $result
}

function ConvertTo-PcDiagInt64 {
    <# Десятичное число из текста поля события; пустое или нечисловое значение — 0. #>
    [CmdletBinding()]
    [OutputType([long])]
    param([AllowNull()] $Value)
    $number = [long]0
    if ([long]::TryParse([string]$Value, [ref]$number)) { return $number }
    [long]0
}

function Get-PcDiagLeafName {
    <# Имя файла из пути Windows. Split-Path на Linux и macOS не понимает обратную косую черту. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [AllowEmptyString()] [string]$Path)
    if (-not $Path) { return '' }
    ($Path -split '[\\/]')[-1]
}

function Get-PcDiagField {
    <#
    .SYNOPSIS
        Поле данных проверки или $null, если его нет. В StrictMode обращение через точку
        к отсутствующему ключу [ordered]-словаря или свойству объекта бросает исключение.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Data,
        [Parameter(Mandatory)] [string]$Name
    )
    if ($null -eq $Data) { return $null }
    if ($Data -is [System.Collections.IDictionary]) {
        if ($Data.Contains($Name)) { return , $Data[$Name] }
        return $null
    }
    $property = $Data.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    , $property.Value
}
