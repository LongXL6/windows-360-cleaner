[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Invoke-360Cleanup.ps1'
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error $_.Message }
    throw 'PowerShell parser validation failed.'
}

$report = Join-Path ([IO.Path]::GetTempPath()) ('windows-360-cleaner-test-{0}.json' -f [Guid]::NewGuid().ToString('N'))
try {
    & $scriptPath -Mode Scan -ReportPath $report
    if (-not (Test-Path -LiteralPath $report)) {
        throw 'Scan did not create a report.'
    }

    $json = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if (-not $json.Timestamp -or -not $json.Mode -or $null -eq $json.Findings) {
        throw 'Report schema is incomplete.'
    }

    Write-Host 'Syntax and read-only scan test passed.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
}

