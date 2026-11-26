#Requires -Version 5.1
<#
.SYNOPSIS
    Диагностика Windows-ПК для заявок. Только читает систему, ничего не меняет.

.DESCRIPTION
    Запускает проверки из PcDiag\Checks, печатает сводку, копирует её в буфер обмена
    и сохраняет summary.txt и result.json в папку reports рядом со скриптом.
    Если туда записать нельзя (например, общая папка только для чтения) — в %TEMP%.

    Коды выхода: 0 — отчёт сохранён; 1 — не то окружение (нет прав, 32-битная PowerShell);
    2 — неверные параметры.

.PARAMETER Only
    Запустить только перечисленные проверки, через запятую: -Only Uptime,FreeSpace

.PARAMETER OutputPath
    Папка, в которой создать папку отчёта. По умолчанию reports рядом со скриптом.

.PARAMETER NoClipboard
    Не копировать сводку в буфер обмена.

.EXAMPLE
    .\Run.cmd
    Все проверки, сводка в буфере обмена.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PcDiag.ps1 -Only FreeSpace
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Интерактивный цветной вывод для оператора в консоли')]
[CmdletBinding()]
param(
    [string[]]$Only,
    [string]$OutputPath,
    [switch]$NoClipboard
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# При запуске через -File массив приходит одной строкой ("Uptime,FreeSpace"), поэтому делим вручную.
function Split-ListArgument {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$Value)
    $result = @(foreach ($item in $Value) {
            foreach ($part in ($item -split '[,;\s]+')) { if ($part) { $part.Trim() } }
        })
    , $result
}

# --- Окружение -------------------------------------------------------------
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-Host 'Запущена 32-битная PowerShell: она видит реестр и диски через WOW64 и даст неверную картину.' -ForegroundColor Red
    Write-Host 'Запустите через Run.cmd или из 64-битной Windows PowerShell.' -ForegroundColor Red
    exit 1
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Нужны права администратора: запустите Run.cmd через «Запуск от имени администратора».' -ForegroundColor Red
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'PcDiag\PcDiag.psd1') -Force
$toolVersion = (Get-Module -Name PcDiag).Version.ToString()

# --- Параметры -------------------------------------------------------------
$ids = Split-ListArgument -Value $Only
try {
    $checks = @(Get-PcDiagCheck -Id $ids)
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 2
}

$folderName = 'pcdiag_{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss')
if ($OutputPath) {
    # [IO.File] не знает текущую папку PowerShell, поэтому сразу делаем путь абсолютным.
    $baseDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
}
else {
    $baseDir = Join-Path $PSScriptRoot 'reports'
}
$target = Join-Path $baseDir $folderName
try {
    $null = New-Item -ItemType Directory -Path $target -Force
}
catch {
    $fallback = Join-Path $env:TEMP $folderName
    Write-Host ('Не удалось создать {0}: {1}' -f $target, $_.Exception.Message) -ForegroundColor Yellow
    Write-Host "Сохраняю отчёт в $fallback" -ForegroundColor Yellow
    $target = $fallback
    $null = New-Item -ItemType Directory -Path $target -Force
}

# --- Проверки ----------------------------------------------------------------
Write-Host ('pcdiag {0}: проверок {1}, только чтение' -f $toolVersion, $checks.Count) -ForegroundColor Cyan
$results = @(Invoke-PcDiagCheck -Id $ids)

$meta = [ordered]@{
    ToolVersion  = $toolVersion
    ComputerName = $env:COMPUTERNAME
    CollectedAt  = (Get-Date).ToString('s')
    PSVersion    = $PSVersionTable.PSVersion.ToString()
    PSEdition    = [string]$PSVersionTable.PSEdition
}
$summary = Write-PcDiagReport -Result $results -Meta $meta -Path $target

# --- Вывод -----------------------------------------------------------------
$colors = [ordered]@{ '[FAIL]' = 'Red'; '[WARN]' = 'Yellow'; '[ERR ]' = 'Magenta'; '[SKIP]' = 'DarkGray'; '[ OK ]' = 'Green' }
Write-Host ''
foreach ($line in ($summary -split "`r?`n")) {
    $color = $null
    foreach ($mark in $colors.Keys) { if ($line.StartsWith($mark)) { $color = $colors[$mark] } }
    if ($color) { Write-Host $line -ForegroundColor $color } else { Write-Host $line }
}
Write-Host ''

if (-not $NoClipboard) {
    try {
        Set-Clipboard -Value $summary
        Write-Host 'Сводка скопирована в буфер обмена.' -ForegroundColor Cyan
    }
    catch {
        Write-Host ('Буфер обмена недоступен: {0}' -f $_.Exception.Message) -ForegroundColor DarkGray
    }
}
Write-Host "Отчёт: $target" -ForegroundColor Cyan
exit 0
