BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'PcDiag/PcDiag.psd1') -Force
    $checks = @(Get-PcDiagCheck | ForEach-Object { @{ Id = $_.Id } })
}

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'PcDiag/PcDiag.psd1') -Force
}

Describe 'Реестр проверок' {
    It 'зарегистрирована хотя бы одна проверка' {
        @(Get-PcDiagCheck).Count | Should -BeGreaterThan 0
    }

    It 'каждый файл в Checks регистрирует проверку со своим именем' {
        $files = @(Get-ChildItem -Path (Join-Path $root 'PcDiag/Checks') -Filter '*.ps1' | ForEach-Object { $_.BaseName } | Sort-Object)
        $ids = @(Get-PcDiagCheck | ForEach-Object { $_.Id } | Sort-Object)
        ($ids -join ',') | Should -Be ($files -join ',')
    }
}

Describe 'Контракт проверки <Id>' -ForEach $checks {
    It 'есть Get-<Id>Data и Test-<Id>' {
        InModuleScope PcDiag -Parameters @{ Id = $Id } {
            Get-Command -Name "Get-$($Id)Data" -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command -Name "Test-$Id" -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'Test-<Id> принимает параметр Data' {
        InModuleScope PcDiag -Parameters @{ Id = $Id } {
            (Get-Command -Name "Test-$Id").Parameters.Keys | Should -Contain 'Data'
        }
    }
}
