BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $skip = '[\\/](\.git|out|reports)[\\/]'

    $psFiles = @(Get-ChildItem -Path $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName -notmatch $skip } |
            ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } })

    $cmdFiles = @(Get-ChildItem -Path $root -Recurse -File -Include '*.cmd', '*.bat' |
            Where-Object { $_.FullName -notmatch $skip } |
            ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } })
}

Describe 'Кодировка: файлы PowerShell' {
    # Без BOM Windows PowerShell 5.1 читает файл в ANSI-кодировке и портит кириллицу.
    It '<Name> начинается с UTF-8 BOM' -ForEach $psFiles {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $bytes.Count | Should -BeGreaterThan 3
        ($bytes[0..2] -join ',') | Should -Be '239,187,191'
    }
}

Describe 'Кодировка: файлы cmd' {
    # cmd.exe читает .cmd в OEM-кодировке и принимает BOM за часть первой команды.
    It '<Name> содержит только ASCII' -ForEach $cmdFiles {
        $bytes = [IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    # С одиночными LF cmd.exe теряет метки goto в длинных файлах.
    It '<Name> использует переводы строк CRLF' -ForEach $cmdFiles {
        $text = [IO.File]::ReadAllText($Path)
        $text | Should -Not -Match "(?<!`r)`n"
    }
}
