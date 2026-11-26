#Requires -Version 5.1
Set-StrictMode -Version 3.0

# Реестр проверок. Его заполняют файлы из Checks\ вызовом Register-PcDiagCheck.
$script:Checks = [System.Collections.Generic.List[object]]::new()

# Core загружается первым: в нём Register-PcDiagCheck, который вызывают файлы проверок.
foreach ($folder in @('Core', 'Checks')) {
    $folderPath = Join-Path $PSScriptRoot $folder
    foreach ($file in @(Get-ChildItem -LiteralPath $folderPath -Filter '*.ps1' | Sort-Object Name)) {
        . $file.FullName
    }
}

Export-ModuleMember -Function @(
    'Get-PcDiagCheck'
    'Invoke-PcDiagCheck'
    'Format-PcDiagSummary'
    'Write-PcDiagReport'
)
