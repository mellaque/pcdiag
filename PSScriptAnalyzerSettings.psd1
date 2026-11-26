@{
    # Information-замечания (например, PSUseOutputTypeCorrectly) не валят сборку.
    Severity = @('Error', 'Warning')

    Rules    = @{
        # Не даёт незаметно использовать синтаксис только из PowerShell 7 (?? , ?:, &&).
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
