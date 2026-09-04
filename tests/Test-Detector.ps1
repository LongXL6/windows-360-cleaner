#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath = (Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$detectorTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath

$run = New-TestRun -Name 'Detector tests'
$fixtureRoot = $null
$originalKnownFolders = $null
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

    $originalKnownFolders = $script:KnownFolders
    $fixtureRoot = New-TestDirectory
    $script:KnownFolders = [ordered]@{
        LocalAppData    = Join-Path $fixtureRoot 'LocalAppData'
        RoamingAppData  = Join-Path $fixtureRoot 'RoamingAppData'
        ProgramFiles    = Join-Path $fixtureRoot 'ProgramFiles'
        ProgramFilesX86 = Join-Path $fixtureRoot 'ProgramFilesX86'
        ProgramData     = Join-Path $fixtureRoot 'ProgramData'
        UserProfile     = Join-Path $fixtureRoot 'UserProfile'
        Desktop         = Join-Path $fixtureRoot 'Desktop'
        Temp            = Join-Path $fixtureRoot 'Temp'
        Windows         = Join-Path $fixtureRoot 'Windows'
    }
    foreach ($path in $script:KnownFolders.Values) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    Invoke-TestCase -Run $run -Name 'test files use the PowerShell 5.1 source contract' -Test {
        Assert-TestPowerShellFileContract -Path $helpersPath
        Assert-TestPowerShellFileContract -Path $detectorTestPath
    }

    Invoke-TestCase -Run $run -Name 'finding construction and de-duplication stay deterministic' -Test {
        $finding = New-Finding -Kind 'Startup' -Name 'Fixture startup' `
            -Target 'HKCU:\Software\Fixture\Run' -Confidence 'ReviewOnly' `
            -Reason 'Isolated fixture' -ValueName 'FixtureValue'
        Assert-TestSequenceEqual `
            -Expected @('Kind', 'Name', 'Target', 'Confidence', 'Reason', 'RemovalType', 'ValueName', 'Offline') `
            -Actual @($finding.PSObject.Properties.Name) `
            -Message 'Finding schema changed unexpectedly.'
        Assert-TestEqual -Expected 'None' -Actual $finding.RemovalType `
            -Message 'Review-only findings must default to a non-removing action.'
        Assert-TestFalse -Condition $finding.Offline -Message 'Live findings must not be marked offline by default.'

        $items = New-Object System.Collections.ArrayList
        Add-Finding -List $items -Finding $finding
        Add-Finding -List $items -Finding $finding
        Assert-TestEqual -Expected 1 -Actual $items.Count `
            -Message 'An identical detector result was added more than once.'

        $separateValue = New-Finding -Kind 'Startup' -Name 'Fixture startup 2' `
            -Target 'HKCU:\Software\Fixture\Run' -Confidence 'ReviewOnly' `
            -Reason 'Isolated fixture' -ValueName 'OtherValue'
        Add-Finding -List $items -Finding $separateValue
        Assert-TestEqual -Expected 2 -Actual $items.Count `
            -Message 'Distinct registry value findings were incorrectly de-duplicated.'
    }

    Invoke-TestCase -Run $run -Name 'command executable parsing is deterministic' -Test {
        $quoted = Get-CommandExecutable '"C:\Program Files\Fixture\fixture.exe" --quiet'
        $bare = Get-CommandExecutable 'C:\Fixture\fixture.exe --quiet'
        Assert-TestEqual -Expected 'C:\Program Files\Fixture\fixture.exe' -Actual $quoted `
            -Message 'Quoted executable parsing changed.'
        Assert-TestEqual -Expected 'C:\Fixture\fixture.exe' -Actual $bare `
            -Message 'Bare executable parsing changed.'
        Assert-TestNull -Actual (Get-CommandExecutable 'not-an-executable --quiet') `
            -Message 'A command without an executable extension should not produce a path.'
    }

    Invoke-TestCase -Run $run -Name 'detectors consume the injected discovery provider' -Test {
        $uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        $uninstallKey = $uninstallRoot + '\FixtureProduct'
        $task = [pscustomobject]@{
            TaskName = '360 Fixture Review Task'
            TaskPath = '\Fixture\'
            Actions  = @([pscustomobject]@{ Execute = 'C:\Fixture\ordinary-task.exe' })
        }
        $service = [pscustomobject]@{
            Name     = '360FixtureReviewService'
            PathName = '"C:\Fixture\ordinary-service.exe" --service'
        }
        $fake = New-Fake360CleanupRuntimeProvider `
            -RegistrySubKeys @{
                $uninstallRoot = @([pscustomobject]@{ PSPath = $uninstallKey })
            } `
            -RegistryValues @{
                $uninstallKey = [pscustomobject]@{
                    DisplayName     = 'Unrelated Fixture Product'
                    Publisher       = 'Fixture Publisher'
                    InstallLocation = 'C:\Fixture\Product'
                }
            } `
            -ScheduledTasks @($task) -Services @($service) -Processes @()

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $taskFinding = @($findings | Where-Object {
            $_.Kind -eq 'ScheduledTask' -and $_.Name -eq $task.TaskName
        })
        Assert-TestEqual -Expected 1 -Actual $taskFinding.Count `
            -Message 'The fake scheduled task was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $taskFinding[0].Confidence `
            -Message 'A name-only scheduled task match must stay review-only.'

        $serviceFinding = @($findings | Where-Object {
            $_.Kind -eq 'Service' -and $_.Name -eq $service.Name
        })
        Assert-TestEqual -Expected 1 -Actual $serviceFinding.Count `
            -Message 'The fake service was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $serviceFinding[0].Confidence `
            -Message 'A name-only service match must stay review-only.'

        $subKeyCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RegistrySubKeys')
        $valueCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RegistryValues')
        Assert-TestEqual -Expected 1 -Actual $subKeyCalls.Count `
            -Message 'The configured uninstall root must be enumerated once.'
        Assert-TestEqual -Expected $uninstallRoot -Actual $subKeyCalls[0].Arguments[0] `
            -Message 'The detector enumerated the wrong registry root.'
        Assert-TestEqual -Expected 1 -Actual $valueCalls.Count `
            -Message 'The configured uninstall record must be read once.'
        Assert-TestEqual -Expected $uninstallKey -Actual $valueCalls[0].Arguments[0] `
            -Message 'The detector read the wrong registry record.'

        foreach ($operation in @('ScheduledTasks', 'Services', 'Processes')) {
            $calls = @(Get-Fake360CleanupCalls -Fake $fake -Operation $operation)
            Assert-TestEqual -Expected 1 -Actual $calls.Count `
                -Message ("The {0} provider operation must be called once per scan." -f $operation)
            Assert-TestEqual -Expected 0 -Actual $calls[0].Arguments.Count `
                -Message ("The {0} provider operation received unexpected arguments." -f $operation)
        }
    }

    Invoke-TestCase -Run $run -Name 'startup and process discovery use the injected provider data' -Test {
        $confirmedRoot = Join-Path $script:KnownFolders.Temp 'duohuipingbao'
        New-Item -ItemType Directory -Path $confirmedRoot -Force | Out-Null
        $executable = Join-Path $confirmedRoot 'duohuipingbao.exe'
        Set-Content -LiteralPath $executable -Value 'ISOLATED-MARKER'
        Set-Content -LiteralPath (Join-Path $confirmedRoot 'huabaosetup.exe') -Value 'ISOLATED-MARKER'

        $runRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $process = [pscustomobject]@{
            Name           = 'duohuipingbao.exe'
            ProcessId      = 4242
            ExecutablePath = $executable
        }
        $fake = New-Fake360CleanupRuntimeProvider `
            -RegistryValues @{
                $runRoot = [pscustomobject]@{
                    FixtureStartup = ('"{0}" --background' -f $executable)
                }
            } `
            -Processes @($process)

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $startupFinding = @($findings | Where-Object {
            $_.Kind -eq 'Startup' -and $_.ValueName -eq 'FixtureStartup'
        })
        Assert-TestEqual -Expected 1 -Actual $startupFinding.Count `
            -Message 'The fake Run value was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $startupFinding[0].Confidence `
            -Message 'A Run executable under a confirmed fixture root was not confirmed.'
        Assert-TestEqual -Expected 'RegistryValue' -Actual $startupFinding[0].RemovalType `
            -Message 'The fake Run value did not preserve its removal type.'

        $processFinding = @($findings | Where-Object {
            $_.Kind -eq 'Process' -and $_.Target -eq '4242'
        })
        Assert-TestEqual -Expected 1 -Actual $processFinding.Count `
            -Message 'The fake process was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $processFinding[0].Confidence `
            -Message 'A process under a confirmed fixture root was not confirmed.'
        Assert-TestEqual -Expected 'Process' -Actual $processFinding[0].RemovalType `
            -Message 'The fake process did not preserve its removal type.'

        $runValueCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RegistryValues' | Where-Object {
            $_.Arguments[0] -eq $runRoot
        })
        Assert-TestEqual -Expected 1 -Actual $runValueCalls.Count `
            -Message 'The configured Run root must be read once.'
        $processCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'Processes')
        Assert-TestEqual -Expected 1 -Actual $processCalls.Count `
            -Message 'The process provider operation must be called once per scan.'
    }

    Complete-TestRun -Run $run
}
finally {
    if ($libraryLoaded) {
        Reset-360CleanupRuntimeProvider
    }
    if ($null -ne $originalKnownFolders) {
        $script:KnownFolders = $originalKnownFolders
    }
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
        Remove-TestDirectory -Path $fixtureRoot
    }
}
