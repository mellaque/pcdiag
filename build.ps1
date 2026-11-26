#Requires -Version 5.1
<#
.SYNOPSIS
    Один и тот же сценарий сборки локально и в CI.

.DESCRIPTION
    Deps  — поставить закреплённые версии Pester и PSScriptAnalyzer (в профиль пользователя).
    Lint  — PSScriptAnalyzer по всему репозиторию.
    Test  — Pester с покрытием; результаты в out\.
    Smoke — настоящий запуск Invoke-PcDiag.ps1 на этой машине (нужны права администратора)
            и проверка, что result.json валиден и ни одна проверка не упала с Error.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Task Lint,Test,Smoke

.EXAMPLE
    .\build.ps1                    # Lint и Test
    .\build.ps1 -Task Deps         # один раз на новой машине
    .\build.ps1 -Task Lint, Test, Smoke
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Сценарий сборки пишет в консоль для человека и лога CI')]
[CmdletBinding()]
param(
    # Без ValidateSet: при запуске через -File список приходит одной строкой "Lint,Test",
    # и ValidateSet отклонил бы его до того, как мы успеем его разделить.
    [string[]]$Task = @('Lint', 'Test')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Версии закреплены: новая версия линтера или Pester не должна внезапно ломать CI.
# Обновлять — отдельным коммитом, прочитав changelog.
$Pinned = [ordered]@{
    Pester           = '5.7.1'
    PSScriptAnalyzer = '1.24.0'
}

$knownTasks = @('Deps', 'Lint', 'Test', 'Smoke')
$Task = @(foreach ($item in $Task) { foreach ($part in ($item -split '[,;\s]+')) { if ($part) { $part } } })
foreach ($name in $Task) {
    if ($knownTasks -notcontains $name) { throw "Неизвестная задача: $name. Есть: $($knownTasks -join ', ')" }
}

$root = $PSScriptRoot
$out = Join-Path $root 'out'

# В логах GitHub Actions кириллица из Windows PowerShell иначе превращается в кракозябры.
if ($env:CI -eq 'true') { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) }

function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

function Import-PinnedModule([string]$Name) {
    Import-Module -Name $Name -RequiredVersion $Pinned[$Name] -Force
}

function Install-Dependency {
    Write-Step 'Зависимости'
    # Старые сборки Windows по умолчанию не включают TLS 1.2, а PSGallery без него не отвечает.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ($PSVersionTable.PSEdition -eq 'Desktop' -and -not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    foreach ($name in $Pinned.Keys) {
        $have = @(Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq [version]$Pinned[$name] })
        if ($have.Count -gt 0) { Write-Host "$name $($Pinned[$name]) уже есть"; continue }
        # SkipPublisherCheck: в Windows встроен Pester 3.4 с другим сертификатом подписи.
        Install-Module -Name $name -RequiredVersion $Pinned[$name] -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
        Write-Host "$name $($Pinned[$name]) установлен"
    }
}

function Invoke-Lint {
    Write-Step 'PSScriptAnalyzer'
    Import-PinnedModule PSScriptAnalyzer
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    $testsDir = Join-Path $root 'tests'

    $issues = @()
    $issues += @(Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName -notlike "$testsDir*" -and $_.FullName -notmatch '[\\/](out|reports)[\\/]' } |
            ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settings })

    # В тестах Pester переменные из BeforeAll используются в It, а заглушки не обязаны
    # использовать параметры: эти правила дают там только ложные срабатывания.
    $issues += @(Invoke-ScriptAnalyzer -Path $testsDir -Recurse -Settings $settings -ExcludeRule @(
            'PSUseDeclaredVarsMoreThanAssignments'
            'PSReviewUnusedParameter'
            'PSUseShouldProcessForStateChangingFunctions'
        ))

    if ($issues.Count -gt 0) {
        $issues | Format-Table -AutoSize -Property Severity, RuleName, ScriptName, Line, Message | Out-String -Width 250 | Write-Host
        throw "PSScriptAnalyzer: замечаний $($issues.Count)"
    }
    Write-Host 'Замечаний нет' -ForegroundColor Green
}

function Invoke-Test {
    Write-Step 'Pester'
    Import-PinnedModule Pester
    $null = New-Item -ItemType Directory -Path $out -Force

    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $root 'tests'
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = Join-Path $out ("testResults-{0}.xml" -f $PSVersionTable.PSEdition)
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = Join-Path $root 'PcDiag'
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
    $config.CodeCoverage.OutputPath = Join-Path $out ("coverage-{0}.xml" -f $PSVersionTable.PSEdition)

    $result = Invoke-Pester -Configuration $config
    if ($result.Result -ne 'Passed') { throw "Pester: упало тестов $($result.FailedCount)" }
}

function Invoke-Smoke {
    Write-Step 'Smoke: настоящий запуск на этой машине'
    $smokeDir = Join-Path $out ("smoke-{0}" -f $PSVersionTable.PSEdition)
    if (Test-Path -LiteralPath $smokeDir) { Remove-Item -LiteralPath $smokeDir -Recurse -Force }

    # Отдельный процесс той же редакции PowerShell — как при запуске через Run.cmd.
    $exe = (Get-Process -Id $PID).Path
    & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Invoke-PcDiag.ps1') -OutputPath $smokeDir -NoClipboard
    if ($LASTEXITCODE -ne 0) { throw "Invoke-PcDiag.ps1 завершился с кодом $LASTEXITCODE" }

    $reportDir = @(Get-ChildItem -LiteralPath $smokeDir -Directory)
    if ($reportDir.Count -ne 1) { throw "Ожидалась одна папка отчёта, найдено $($reportDir.Count)" }
    $jsonPath = Join-Path $reportDir[0].FullName 'result.json'
    $report = [IO.File]::ReadAllText($jsonPath) | ConvertFrom-Json

    # Error на настоящей Windows значит, что код проверки не работает на живой системе.
    # Skipped допустим: у виртуальной машины CI нет датчиков и S.M.A.R.T.
    $broken = @($report.Checks | Where-Object { $_.Status -notin 'OK', 'Warn', 'Fail', 'Skipped' })
    if ($broken.Count -gt 0) {
        $broken | ForEach-Object { Write-Host ("{0}: {1} — {2}" -f $_.Id, $_.Status, $_.Summary) -ForegroundColor Red }
        throw "Smoke: проверок с ошибкой $($broken.Count)"
    }
    Write-Host ("Smoke: проверок {0}, ошибок нет" -f @($report.Checks).Count) -ForegroundColor Green
}

foreach ($step in $Task) {
    switch ($step) {
        'Deps' { Install-Dependency }
        'Lint' { Invoke-Lint }
        'Test' { Invoke-Test }
        'Smoke' { Invoke-Smoke }
    }
}
