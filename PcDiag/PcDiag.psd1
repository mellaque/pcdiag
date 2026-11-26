@{
    RootModule           = 'PcDiag.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '3e5a3d9d-78f6-41db-a75f-fed92300a9ba'
    Author               = 'mellaque'
    Copyright            = '(c) 2026 mellaque. MIT License.'
    Description          = 'Диагностика Windows-ПК для заявок: только чтение, сводка и подробный отчёт.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Get-PcDiagCheck'
        'Invoke-PcDiagCheck'
        'Format-PcDiagSummary'
        'Write-PcDiagReport'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('Windows', 'Diagnostics', 'Helpdesk')
        }
    }
}
