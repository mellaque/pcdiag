BeforeDiscovery {
    $onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $root 'PcDiag/PcDiag.psd1') -Force

    function New-TestVolume {
        param([string]$Drive, [double]$FreeGB, [double]$SizeGB)
        [ordered]@{
            Drive      = $Drive
            FileSystem = 'NTFS'
            SizeBytes  = [int64]($SizeGB * 1GB)
            FreeBytes  = [int64]($FreeGB * 1GB)
        }
    }

    function Invoke-TestFreeSpace {
        param([object[]]$Volumes)
        $data = [ordered]@{ SystemDrive = 'C:'; Volumes = @($Volumes) }
        InModuleScope PcDiag -Parameters @{ Data = $data } { Test-FreeSpace -Data $Data }
    }
}

Describe 'Test-FreeSpace' {
    It 'норма: перечисляет все диски, числа с запятой' {
        $verdict = Invoke-TestFreeSpace -Volumes @(
            (New-TestVolume -Drive 'C:' -FreeGB 50.26 -SizeGB 237)
            (New-TestVolume -Drive 'D:' -FreeGB 300 -SizeGB 931)
        )
        $verdict.Status | Should -Be 'OK'
        $verdict.Summary | Should -Be 'свободно: C: 50,3 из 237 ГБ, D: 300 из 931 ГБ'
    }

    It 'системный диск меньше 10 ГБ — предупреждение' {
        $verdict = Invoke-TestFreeSpace -Volumes @(New-TestVolume -Drive 'C:' -FreeGB 7.5 -SizeGB 120)
        $verdict.Status | Should -Be 'Warn'
        $verdict.Summary | Should -Be 'мало места: C: 7,5 из 120 ГБ'
        $verdict.Details[0] | Should -Match 'обновлений'
    }

    It 'системный диск меньше 3 ГБ — проблема' {
        $verdict = Invoke-TestFreeSpace -Volumes @(New-TestVolume -Drive 'C:' -FreeGB 2.5 -SizeGB 120)
        $verdict.Status | Should -Be 'Fail'
    }

    It 'для системного диска важны гигабайты, а не процент' {
        # 9 % свободно, но это 90 ГБ — запаса хватает.
        $verdict = Invoke-TestFreeSpace -Volumes @(New-TestVolume -Drive 'C:' -FreeGB 90 -SizeGB 1000)
        $verdict.Status | Should -Be 'OK'
    }

    It 'другой диск меньше 5 % — предупреждение, системный не трогаем' {
        $verdict = Invoke-TestFreeSpace -Volumes @(
            (New-TestVolume -Drive 'C:' -FreeGB 50 -SizeGB 237)
            (New-TestVolume -Drive 'D:' -FreeGB 20 -SizeGB 931)
        )
        $verdict.Status | Should -Be 'Warn'
        $verdict.Summary | Should -Be 'мало места: D: 20 из 931 ГБ'
    }

    It 'итог — худший из статусов' {
        $verdict = Invoke-TestFreeSpace -Volumes @(
            (New-TestVolume -Drive 'C:' -FreeGB 1 -SizeGB 120)
            (New-TestVolume -Drive 'D:' -FreeGB 20 -SizeGB 931)
        )
        $verdict.Status | Should -Be 'Fail'
        $verdict.Details | Should -HaveCount 2
    }

    It 'тома без размера пропускаются' {
        $verdict = Invoke-TestFreeSpace -Volumes @(
            (New-TestVolume -Drive 'C:' -FreeGB 50 -SizeGB 237)
            (New-TestVolume -Drive 'E:' -FreeGB 0 -SizeGB 0)
        )
        $verdict.Summary | Should -Not -Match 'E:'
    }

    It 'нет дисков — Skipped, а не OK' {
        $verdict = Invoke-TestFreeSpace -Volumes @()
        $verdict.Status | Should -Be 'Skipped'
    }
}

Describe 'Get-FreeSpaceData' -Skip:(-not $onWindows) {
    BeforeAll {
        Mock -ModuleName PcDiag Get-CimInstance {
            [pscustomobject]@{ DeviceID = 'C:'; FileSystem = 'NTFS'; VolumeName = 'Иванов И.И.'; Size = [uint64]128GB; FreeSpace = [uint64]10GB }
        }
        $data = InModuleScope PcDiag { Get-FreeSpaceData }
    }

    It 'один диск — всё равно массив' {
        @($data.Volumes).Count | Should -Be 1
        $data.Volumes[0].Drive | Should -Be 'C:'
        $data.Volumes[0].FreeBytes | Should -Be (10GB)
    }

    It 'метка тома в отчёт не попадает' {
        ($data | ConvertTo-Json -Depth 5) | Should -Not -Match 'Иванов'
    }

    It 'спрашивает только локальные диски' {
        # Вызов был в BeforeAll, поэтому считаем по всему Describe, а не по этому It (по умолчанию -Scope It).
        Should -Invoke -ModuleName PcDiag Get-CimInstance -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $ClassName -eq 'Win32_LogicalDisk' -and $Filter -match 'DriveType\s*=\s*3'
        }
    }
}
