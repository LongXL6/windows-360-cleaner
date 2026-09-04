#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath = (Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$elevationTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath

$run = New-TestRun -Name 'Elevation tests'
$libraryLoaded = $false
$previousTestMode = [Environment]::GetEnvironmentVariable('WINDOWS_360_CLEANER_TEST_MODE', 'Process')

try {
    $env:WINDOWS_360_CLEANER_TEST_MODE = 'ISOLATED-SAFETY-TEST'
    try {
        . $CleanerScriptPath -InternalTestLibraryOnly
        $libraryLoaded = $true
    }
    finally {
        if ($null -eq $previousTestMode) {
            Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue
        }
        else {
            $env:WINDOWS_360_CLEANER_TEST_MODE = $previousTestMode
        }
    }

    Invoke-TestCase -Run $run -Name 'test files use the PowerShell 5.1 source contract' -Test {
        Assert-TestPowerShellFileContract -Path $helpersPath
        Assert-TestPowerShellFileContract -Path $elevationTestPath
    }

    Invoke-TestCase -Run $run -Name 'fake runtime providers implement the complete seam' -Test {
        $fake = New-Fake360CleanupRuntimeProvider
        $expectedOperations = @(
            'IsAdministrator',
            'Is360File',
            'Processes',
            'RegistryPathExists',
            'RegistrySubKeys',
            'RegistryValues',
            'ScheduledTasks',
            'Services',
            'StartElevatedProcess',
            'StopProcess'
        ) | Sort-Object
        Assert-TestSequenceEqual -Expected $expectedOperations -Actual @($fake.Provider.Keys | Sort-Object) `
            -Message 'The fake runtime provider does not implement the complete production seam.'
        Assert-TestNotNull -Actual $fake.Context `
            -Message 'The fake runtime provider must expose an explicit context object.'
    }

    Invoke-TestCase -Run $run -Name 'incomplete runtime providers fail closed' -Test {
        Assert-TestThrows -Operation {
            Set-360CleanupRuntimeProvider -Provider @{
                IsAdministrator = { return $false }
            }
        } -Message 'A partial fake provider must not fall back to live machine operations.'
    }

    Invoke-TestCase -Run $run -Name 'administrator checks use the injected runtime provider' -Test {
        $fake = New-Fake360CleanupRuntimeProvider -IsAdministrator $false
        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $result = Test-IsAdministrator
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestFalse -Condition $result -Message 'The fake administrator result was not returned.'
        $calls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'IsAdministrator')
        Assert-TestEqual -Expected 1 -Actual $calls.Count `
            -Message 'The administrator provider operation must be called exactly once.'
        Assert-TestEqual -Expected 0 -Actual $calls[0].Arguments.Count `
            -Message 'The administrator provider operation received unexpected arguments.'
    }

    Invoke-TestCase -Run $run -Name 'elevated process startup preserves arguments and exit code' -Test {
        $fake = New-Fake360CleanupRuntimeProvider -ElevatedExitCode 23
        $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Fixture\cleanup.ps1" -Mode Remove'
        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $result = Start-360CleanupElevatedProcess -FilePath 'powershell.exe' -ArgumentLine $argumentLine
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 23 -Actual $result.ExitCode `
            -Message 'The injected elevated process exit code was not preserved.'
        $calls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'StartElevatedProcess')
        Assert-TestEqual -Expected 1 -Actual $calls.Count `
            -Message 'The elevated process provider operation must be called exactly once.'
        Assert-TestSequenceEqual -Expected @('powershell.exe', $argumentLine) -Actual @($calls[0].Arguments) `
            -Message 'The elevated process provider received different arguments.'
    }

    Invoke-TestCase -Run $run -Name 'reset restores the default administrator implementation' -Test {
        $fake = New-Fake360CleanupRuntimeProvider -IsAdministrator $false
        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        [void](Test-IsAdministrator)
        Reset-360CleanupRuntimeProvider

        $defaultResult = Test-IsAdministrator
        Assert-TestTrue -Condition ($defaultResult -is [bool]) `
            -Message 'The reset administrator implementation did not return a Boolean.'
        $calls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'IsAdministrator')
        Assert-TestEqual -Expected 1 -Actual $calls.Count `
            -Message 'Reset did not detach the fake administrator provider.'
    }

    Complete-TestRun -Run $run
}
finally {
    if ($libraryLoaded) {
        Reset-360CleanupRuntimeProvider
    }
}
