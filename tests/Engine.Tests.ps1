BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    # -Force перезагружает модуль: подменённый ниже реестр проверок не утечёт в другие файлы тестов.
    Import-Module (Join-Path $root 'PcDiag/PcDiag.psd1') -Force

    InModuleScope PcDiag {
        $script:Checks.Clear()
        Register-PcDiagCheck -Id 'FakeOk' -Title 'Тест: норма'
        Register-PcDiagCheck -Id 'FakeBroken' -Title 'Тест: сбор падает'
        Register-PcDiagCheck -Id 'FakeNoisy' -Title 'Тест: лишний вывод'

        function script:Get-FakeOkData { @{ Value = 42 } }
        function script:Test-FakeOk { param($Data) New-PcDiagVerdict -Status OK -Summary "значение $($Data.Value)" }

        function script:Get-FakeBrokenData { throw 'WMI недоступен' }
        function script:Test-FakeBroken { param($Data) New-PcDiagVerdict -Status OK -Summary 'сюда не дойдёт' }

        function script:Get-FakeNoisyData { @{} }
        function script:Test-FakeNoisy { param($Data) 'забытый отладочный вывод'; New-PcDiagVerdict -Status OK -Summary 'ok' }
    }
}

Describe 'Invoke-PcDiagCheck' {
    It 'возвращает результат по каждой проверке в порядке регистрации' {
        $result = @(Invoke-PcDiagCheck)
        ($result | ForEach-Object { $_.Id }) -join ',' | Should -Be 'FakeOk,FakeBroken,FakeNoisy'
    }

    It 'передаёт данные из Get в Test и сохраняет их в результате' {
        $result = Invoke-PcDiagCheck -Id 'FakeOk'
        $result.Status | Should -Be 'OK'
        $result.Summary | Should -Be 'значение 42'
        $result.Data.Value | Should -Be 42
        $result.Title | Should -Be 'Тест: норма'
    }

    It 'ошибка сбора даёт статус Error, а не «всё хорошо»' {
        $result = Invoke-PcDiagCheck -Id 'FakeBroken'
        $result.Status | Should -Be 'Error'
        $result.Summary | Should -Match 'WMI недоступен'
    }

    It 'сбой одной проверки не мешает остальным' {
        $result = @(Invoke-PcDiagCheck -Id 'FakeBroken', 'FakeOk')
        $result.Count | Should -Be 2
        $result[1].Status | Should -Be 'OK'
    }

    It 'лишний вывод в Test-* ловится как ошибка формы' {
        $result = Invoke-PcDiagCheck -Id 'FakeNoisy'
        $result.Status | Should -Be 'Error'
        $result.Summary | Should -Match 'неверной формы'
    }

    It 'одинаковый Id нельзя зарегистрировать дважды' {
        { InModuleScope PcDiag { Register-PcDiagCheck -Id 'FakeOk' -Title 'дубль' } } |
            Should -Throw -ExpectedMessage "*'FakeOk' зарегистрирована дважды*"
    }

    It 'неизвестный Id — исключение со списком проверок' {
        { Invoke-PcDiagCheck -Id 'Nope' } | Should -Throw -ExpectedMessage '*Неизвестная проверка: Nope*FakeOk*'
    }
}
