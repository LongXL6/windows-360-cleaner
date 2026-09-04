#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath = (Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$approvalTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath

function New-ApprovalFixtureContext {
    param(
        [string]$UserSid = 'S-1-5-21-111111111-222222222-333333333-1001',
        [bool]$IncludeBrowserProfiles = $false
    )

    return [pscustomobject]@{
        UserSid      = $UserSid
        KnownFolders = [pscustomobject]@{
            LocalAppData    = 'C:\Users\ApprovalFixture\AppData\Local'
            RoamingAppData  = 'C:\Users\ApprovalFixture\AppData\Roaming'
            ProgramFiles    = 'C:\Program Files'
            ProgramFilesX86 = 'C:\Program Files (x86)'
            ProgramData     = 'C:\ProgramData'
            UserProfile     = 'C:\Users\ApprovalFixture'
            Desktop         = 'C:\Users\ApprovalFixture\Desktop'
            Temp            = 'C:\Users\ApprovalFixture\AppData\Local\Temp'
            Windows         = 'C:\Windows'
        }
        Options      = [pscustomobject]@{
            IncludeBrowserProfiles = $IncludeBrowserProfiles
        }
    }
}

function New-ApprovalFixtureFinding {
    param(
        [string]$Kind,
        [string]$Name,
        [string]$Target,
        [string]$Confidence = 'Confirmed',
        [string]$RemovalType = 'Path',
        [string]$ValueName = '',
        [string]$IdentityFingerprint = '',
        [bool]$Offline = $false
    )

    return [pscustomobject]@{
        Kind        = $Kind
        Name        = $Name
        Target      = $Target
        Confidence  = $Confidence
        Reason      = 'Isolated approval fixture'
        RemovalType = $RemovalType
        ValueName   = $ValueName
        IdentityFingerprint = $IdentityFingerprint
        Offline     = $Offline
    }
}

function New-ApprovalFixtureSummary {
    return [pscustomobject]@{
        TotalItemsRemoved            = 0
        FilesRemoved                 = 0
        DirectoriesRemoved           = 0
        LogicalSizeRemoved           = '0 B'
        LogicalBytesRemoved          = 0
        ServicesRemoved              = 0
        ServicesPendingRemoval       = 0
        ScheduledTasksRemoved        = 0
        RegistryKeysRemoved          = 0
        RegistryValuesRemoved        = 0
        ProcessesStopped             = 0
        VendorUninstallersSucceeded  = 0
        VendorUninstallersFailed     = 0
        VendorUninstallersPending    = 0
        PostVendorMutationBlocked    = $false
        ImmediateRescanComplete      = $true
        SkippedActions               = 0
        FailedActions                = 0
        PendingActions               = 0
        RetryAttempts                = 0
        UnresolvedRetryTargets       = 0
        AccessDeniedPathTargets      = 0
        AclRepairAttempts            = 0
        AclRepairFailures            = 0
        UnresolvedPathTargets        = 0
        PathTargetsRemoved           = 0
        PartiallyCleanedPathTargets  = 0
        ImmediateRemainingConfirmed  = 0
        NoImmediateConfirmedFindings = $true
        PathAccountingComplete       = $true
        UnmeasuredPathTargets        = 0
    }
}

function Write-ApprovalFixtureReport {
    param(
        [string]$Path,
        [int]$SchemaVersion = 2,
        [string]$Mode = 'Scan',
        [object]$ApprovalContext = (New-ApprovalFixtureContext),
        [object[]]$Findings = @(),
        [object[]]$Actions = @(),
        [object]$Summary = $null,
        [string]$ApprovedReportHash = $null,
        [string]$OutcomeRunId = $null,
        [string]$ComputerName = $null,
        [string]$User = $null
    )

    $report = [pscustomobject]@{
        SchemaVersion   = $SchemaVersion
        Timestamp       = '2026-09-04T12:00:00.0000000Z'
        ComputerName    = $ComputerName
        User            = $User
        Mode            = $Mode
        ApprovalContext = $ApprovalContext
        ApprovedReportHash = $ApprovedReportHash
        OutcomeRunId    = $OutcomeRunId
        Summary         = $Summary
        Findings        = @($Findings)
        Actions         = @($Actions)
    }
    $json = $report | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
    return $report
}

$run = New-TestRun -Name 'Approval tests'
$fixtureRoot = $null
$libraryLoaded = $false
$originalKnownFolders = $null
$originalRegistryRoot = $null
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

    $fixtureRoot = New-TestDirectory
    $originalKnownFolders = $script:KnownFolders
    $originalRegistryRoot = $script:CurrentUserRegistryRoot

    Invoke-TestCase -Run $run -Name 'approval test files use the PowerShell 5.1 source contract' -Test {
        Assert-TestPowerShellFileContract -Path $helpersPath
        Assert-TestPowerShellFileContract -Path $approvalTestPath
    }

    Invoke-TestCase -Run $run -Name 'approval contexts capture the user, folders, and browser option' -Test {
        $context = New-CleanupApprovalContext -IncludeBrowserProfiles $true
        Assert-TestTrue -Condition ([string]$context.UserSid -match '^S-\d+(?:-\d+)+$') `
            -Message 'The approval context did not capture the current Windows user SID.'
        Assert-TestEqual -Expected $script:KnownFolders.LocalAppData -Actual $context.KnownFolders.LocalAppData `
            -Message 'The approval context did not preserve the scan source folders.'
        Assert-TestTrue -Condition ([bool]$context.Options.IncludeBrowserProfiles) `
            -Message 'The approval context did not preserve browser-profile opt-in.'
    }

    Invoke-TestCase -Run $run -Name 'approval context must match the non-elevated caller before UAC' -Test {
        $validContext = New-CleanupApprovalContext -IncludeBrowserProfiles $false
        Assert-CleanupApprovalContextMatchesCaller -ApprovalContext $validContext

        $wrongSid = ($validContext | ConvertTo-Json -Depth 8) | ConvertFrom-Json
        $wrongSid.UserSid = 'S-1-5-18'
        Assert-TestThrows -Operation {
            Assert-CleanupApprovalContextMatchesCaller -ApprovalContext $wrongSid
        } -Message 'A report for a different Windows SID must fail before elevation.'

        $wrongFolder = ($validContext | ConvertTo-Json -Depth 8) | ConvertFrom-Json
        $wrongFolder.KnownFolders.LocalAppData = 'C:\Users\SomeoneElse\AppData\Local'
        Assert-TestThrows -Operation {
            Assert-CleanupApprovalContextMatchesCaller -ApprovalContext $wrongFolder
        } -Message 'A report that redefines a caller folder must fail before elevation.'

        $expandableFolder = ($validContext | ConvertTo-Json -Depth 8) | ConvertFrom-Json
        $expandableFolder.KnownFolders.LocalAppData = '%LOCALAPPDATA%'
        Assert-TestThrows -Operation {
            Assert-CleanupApprovalContextMatchesCaller -ApprovalContext $expandableFolder
        } -Message 'Environment variables in approved folder roots must not expand differently after UAC.'
    }

    Invoke-TestCase -Run $run -Name 'source context rejects empty critical roots' -Test {
        $context = New-ApprovalFixtureContext
        $context.KnownFolders.UserProfile = ''
        $registryRoot = 'Registry::HKEY_USERS\' + $context.UserSid
        $fake = New-Fake360CleanupRuntimeProvider -ExistingRegistryPaths @($registryRoot)
        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            Assert-TestThrows -Operation {
                Set-CleanupSourceContext -ApprovalContext $context
            } -Message 'An empty user profile root must never redefine the removal allowlist.'

            $expandableContext = New-ApprovalFixtureContext
            $expandableContext.KnownFolders.LocalAppData = '%LOCALAPPDATA%'
            Assert-TestThrows -Operation {
                Set-CleanupSourceContext -ApprovalContext $expandableContext
            } -Message 'The elevated source must reject expandable folder roots.'
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }
    }

    Invoke-TestCase -Run $run -Name 'a missing approved report fails closed' -Test {
        $missingPath = Join-Path $fixtureRoot 'missing-approved-report.json'
        Assert-TestThrows -Operation {
            [void](Read-ApprovedCleanupReport -Path $missingPath)
        } -Message 'A missing approved report must be rejected.'
    }

    Invoke-TestCase -Run $run -Name 'damaged approved report JSON fails closed' -Test {
        $damagedPath = Join-Path $fixtureRoot 'damaged-approved-report.json'
        [IO.File]::WriteAllText($damagedPath, '{ not valid JSON', (New-Object Text.UTF8Encoding($false)))
        Assert-TestThrows -Operation {
            [void](Read-ApprovedCleanupReport -Path $damagedPath)
        } -Message 'Damaged approved report JSON must be rejected.'
    }

    Invoke-TestCase -Run $run -Name 'a non-scan report cannot authorize removal' -Test {
        $removePath = Join-Path $fixtureRoot 'remove-mode-report.json'
        [void](Write-ApprovalFixtureReport -Path $removePath -Mode 'Remove')
        Assert-TestThrows -Operation {
            [void](Read-ApprovedCleanupReport -Path $removePath)
        } -Message 'A Remove report must not be accepted as scan approval.'
    }

    Invoke-TestCase -Run $run -Name 'an older report schema cannot authorize removal' -Test {
        $oldSchemaPath = Join-Path $fixtureRoot 'old-schema-report.json'
        [void](Write-ApprovalFixtureReport -Path $oldSchemaPath -SchemaVersion 1)
        Assert-TestThrows -Operation {
            [void](Read-ApprovedCleanupReport -Path $oldSchemaPath)
        } -Message 'An older report schema must not be accepted as scan approval.'
    }

    Invoke-TestCase -Run $run -Name 'a changed approved report hash fails closed' -Test {
        $changedPath = Join-Path $fixtureRoot 'changed-report.json'
        [void](Write-ApprovalFixtureReport -Path $changedPath)
        Assert-TestThrows -Operation {
            [void](Read-ApprovedCleanupReport -Path $changedPath -ExpectedHash ('0' * 64))
        } -Message 'A report whose exact bytes no longer match the approved hash must be rejected.'
    }

    Invoke-TestCase -Run $run -Name 'the exact approved report bytes retain their SHA-256 identity' -Test {
        $approvedPath = Join-Path $fixtureRoot '同字节 扫描报告.json'
        $finding = New-ApprovalFixtureFinding -Kind 'Path' -Name '已批准目标' `
            -Target 'C:\Program Files\360\Fixture'
        [void](Write-ApprovalFixtureReport -Path $approvedPath -Findings @($finding))
        $expectedHash = (Get-FileHash -LiteralPath $approvedPath -Algorithm SHA256).Hash

        $approved = Read-ApprovedCleanupReport -Path $approvedPath -ExpectedHash $expectedHash.ToLowerInvariant()

        Assert-TestEqual -Expected $expectedHash -Actual $approved.Hash `
            -Message 'The approved report hash was not calculated from its exact bytes.'
        Assert-TestEqual -Expected 'Scan' -Actual $approved.Report.Mode `
            -Message 'The valid scan report was not returned.'
        Assert-TestEqual -Expected (Get-NormalPath $approvedPath) -Actual $approved.Path `
            -Message 'The approved report path was not normalized deterministically.'
    }

    Invoke-TestCase -Run $run -Name 'the approved HKCU source maps to the original user SID' -Test {
        $context = New-ApprovalFixtureContext
        $registryRoot = 'Registry::HKEY_USERS\' + $context.UserSid
        $fake = New-Fake360CleanupRuntimeProvider -ExistingRegistryPaths @($registryRoot)
        try {
            Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
            try {
                Set-CleanupSourceContext -ApprovalContext $context
            }
            finally {
                Reset-360CleanupRuntimeProvider
            }

            Assert-TestEqual -Expected $registryRoot -Actual $script:CurrentUserRegistryRoot `
                -Message 'The elevated source did not select the approved user registry hive.'
            Assert-TestEqual -Expected $context.KnownFolders.UserProfile -Actual $script:KnownFolders.UserProfile `
                -Message 'The elevated source did not retain the approved user profile.'

            $approvedFinding = New-ApprovalFixtureFinding -Kind 'Startup' -Name 'Approved startup' `
                -Target 'HKCU:\Software\Fixture\Run' -RemovalType 'RegistryValue' `
                -ValueName 'FixtureUpdater' -IdentityFingerprint ('A1' * 32)
            $currentFinding = New-ApprovalFixtureFinding -Kind 'Startup' -Name 'Current startup' `
                -Target ($registryRoot + '\Software\Fixture\Run') -RemovalType 'RegistryValue' `
                -ValueName 'FixtureUpdater' -IdentityFingerprint ('A1' * 32)
            $approvedKey = Get-FindingApprovalKey -Finding $approvedFinding -UserSid $context.UserSid
            $currentKey = Get-FindingApprovalKey -Finding $currentFinding -UserSid $context.UserSid
            Assert-TestEqual -Expected $approvedKey -Actual $currentKey `
                -Message 'HKCU and HKEY_USERS findings for the approved SID must share one canonical identity.'
        }
        finally {
            Reset-360CleanupRuntimeProvider
            $script:KnownFolders = $originalKnownFolders
            $script:CurrentUserRegistryRoot = $originalRegistryRoot
        }
    }

    Invoke-TestCase -Run $run -Name 'process approval identity uses executable path instead of PID' -Test {
        $approvedProcess = New-ApprovalFixtureFinding -Kind 'Process' -Name 'Approved process' `
            -Target '4100' -RemovalType 'Process' -ValueName 'C:\Program Files\360\fixture.exe'
        $currentProcess = New-ApprovalFixtureFinding -Kind 'Process' -Name 'Current process' `
            -Target '9876' -RemovalType 'Process' -ValueName 'c:\program files\360\FIXTURE.exe'
        $otherProcess = New-ApprovalFixtureFinding -Kind 'Process' -Name 'Other process' `
            -Target '4100' -RemovalType 'Process' -ValueName 'C:\Program Files\360\other.exe'

        $approvedKey = Get-FindingApprovalKey -Finding $approvedProcess
        Assert-TestEqual -Expected $approvedKey -Actual (Get-FindingApprovalKey -Finding $currentProcess) `
            -Message 'A PID change incorrectly invalidated approval for the same executable.'
        Assert-TestFalse -Condition ($approvedKey -eq (Get-FindingApprovalKey -Finding $otherProcess)) `
            -Message 'Different process executable paths shared one approval identity.'
    }

    Invoke-TestCase -Run $run -Name 'approval identity includes the removal operation' -Test {
        $pathRemoval = New-ApprovalFixtureFinding -Kind 'Path' -Name 'Path removal' `
            -Target 'C:\Program Files\360\Fixture' -RemovalType 'Path'
        $noRemoval = New-ApprovalFixtureFinding -Kind 'Path' -Name 'Review identity' `
            -Target 'C:\Program Files\360\Fixture' -RemovalType 'None'

        Assert-TestFalse -Condition ((Get-FindingApprovalKey -Finding $pathRemoval) -eq
            (Get-FindingApprovalKey -Finding $noRemoval)) `
            -Message 'Different removal operations shared one approval key.'
    }

    Invoke-TestCase -Run $run -Name 'vendor uninstaller approval identity includes the scanned SHA-256' -Test {
        $target = 'C:\Users\ApprovalFixture\AppData\Local\dhpingbao\huabaosetup.exe'
        $approved = New-ApprovalFixtureFinding -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' `
            -Target $target -RemovalType 'VendorUninstaller' -ValueName ('A1' * 32)
        $changed = New-ApprovalFixtureFinding -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' `
            -Target $target -RemovalType 'VendorUninstaller' -ValueName ('B2' * 32)

        Assert-TestFalse -Condition ((Get-FindingApprovalKey -Finding $approved) -eq
            (Get-FindingApprovalKey -Finding $changed)) `
            -Message 'Different vendor-uninstaller hashes shared one approval identity.'

        $comparison = Compare-ApprovedCleanupFindings -Approved @($approved) -Current @($changed) `
            -SID 'S-1-5-21-111111111-222222222-333333333-1001'
        Assert-TestEqual -Expected 0 -Actual @($comparison.Eligible).Count `
            -Message 'A vendor executable whose hash changed after approval remained eligible.'
        Assert-TestEqual -Expected 1 -Actual @($comparison.NewSinceApproval).Count `
            -Message 'The changed vendor executable must require a new scan approval.'
    }

    Invoke-TestCase -Run $run -Name 'non-path approval identity binds the exact approved resource fingerprint' -Test {
        $approvedFingerprint = 'A1' * 32
        $changedFingerprint = 'B2' * 32
        $scenarios = @(
            [pscustomobject]@{
                Kind = 'Service'; RemovalType = 'Service'; Target = 'Fixture360Service'; ValueName = ''
            },
            [pscustomobject]@{
                Kind = 'ScheduledTask'; RemovalType = 'Task'; Target = 'Fixture360Task'; ValueName = '\Fixture\'
            },
            [pscustomobject]@{
                Kind = 'Startup'; RemovalType = 'RegistryValue'
                Target = 'HKCU:\Software\Fixture\Run'; ValueName = 'Fixture360Value'
            },
            [pscustomobject]@{
                Kind = 'RegistryResidue'; RemovalType = 'RegistryKey'
                Target = 'HKCU:\Software\Fixture360'; ValueName = ''
            }
        )

        foreach ($scenario in $scenarios) {
            $approved = New-ApprovalFixtureFinding -Kind $scenario.Kind `
                -Name ('Approved ' + $scenario.RemovalType) -Target $scenario.Target `
                -RemovalType $scenario.RemovalType -ValueName $scenario.ValueName `
                -IdentityFingerprint $approvedFingerprint
            $changed = New-ApprovalFixtureFinding -Kind $scenario.Kind `
                -Name ('Changed ' + $scenario.RemovalType) -Target $scenario.Target `
                -RemovalType $scenario.RemovalType -ValueName $scenario.ValueName `
                -IdentityFingerprint $changedFingerprint

            Assert-TestFalse -Condition ((Get-FindingApprovalKey -Finding $approved) -eq
                (Get-FindingApprovalKey -Finding $changed)) `
                -Message ("A changed {0} identity shared its approved key." -f $scenario.RemovalType)
            $missingFingerprint = New-ApprovalFixtureFinding -Kind $scenario.Kind `
                -Name ('Missing fingerprint ' + $scenario.RemovalType) -Target $scenario.Target `
                -RemovalType $scenario.RemovalType -ValueName $scenario.ValueName
            Assert-TestThrows -Operation {
                [void](Get-FindingApprovalKey -Finding $missingFingerprint)
            } -ExpectedMessagePattern '(?i)missing its uppercase identity fingerprint' `
                -Message ("A {0} approval key accepted a missing fingerprint." -f $scenario.RemovalType)

            $comparison = Compare-ApprovedCleanupFindings -Approved @($approved) -Current @($changed) `
                -SID 'S-1-5-21-111111111-222222222-333333333-1001'
            Assert-TestEqual -Expected 0 -Actual @($comparison.Eligible).Count `
                -Message ("A changed {0} identity remained eligible." -f $scenario.RemovalType)
            Assert-TestEqual -Expected 1 -Actual @($comparison.NewSinceApproval).Count `
                -Message ("A changed {0} identity did not require fresh approval." -f $scenario.RemovalType)
            Assert-TestEqual -Expected 0 -Actual @($comparison.MissingSinceApproval).Count `
                -Message ("A changed {0} identity was mislabeled as an absent resource." -f $scenario.RemovalType)
            Assert-TestEqual -Expected 1 -Actual @($comparison.NoLongerConfirmed).Count `
                -Message ("The approved {0} identity change was not surfaced." -f $scenario.RemovalType)
        }
    }

    Invoke-TestCase -Run $run -Name 'only the exact approved and current confirmed intersection is eligible' -Test {
        $sid = 'S-1-5-21-111111111-222222222-333333333-1001'
        $approvedPath = New-ApprovalFixtureFinding -Kind 'Path' -Name 'Approved path' `
            -Target 'C:\Program Files\360\Approved'
        $currentPath = New-ApprovalFixtureFinding -Kind 'Path' -Name 'Current path' `
            -Target 'c:\program files\360\APPROVED'
        $approvedProcess = New-ApprovalFixtureFinding -Kind 'Process' -Name 'Approved process' `
            -Target '1200' -RemovalType 'Process' -ValueName 'C:\Program Files\360\agent.exe'
        $currentProcess = New-ApprovalFixtureFinding -Kind 'Process' -Name 'Current process' `
            -Target '9900' -RemovalType 'Process' -ValueName 'C:\Program Files\360\agent.exe'
        $secondCurrentProcess = New-ApprovalFixtureFinding -Kind 'Process' -Name 'Second current process' `
            -Target '9901' -RemovalType 'Process' -ValueName 'C:\Program Files\360\agent.exe'
        $missingService = New-ApprovalFixtureFinding -Kind 'Service' -Name 'Missing service' `
            -Target 'Fixture360Service' -RemovalType 'Service' -IdentityFingerprint ('C3' * 32)
        $approvedTask = New-ApprovalFixtureFinding -Kind 'ScheduledTask' -Name 'Downgraded task' `
            -Target 'Fixture360Task' -RemovalType 'Task' -ValueName '\Fixture\' `
            -IdentityFingerprint ('D4' * 32)
        $reviewTask = New-ApprovalFixtureFinding -Kind 'ScheduledTask' -Name 'Downgraded task' `
            -Target 'Fixture360Task' -Confidence 'ReviewOnly' -RemovalType 'Task' -ValueName '\Fixture\' `
            -IdentityFingerprint ('D4' * 32)
        $newStartup = New-ApprovalFixtureFinding -Kind 'Startup' -Name 'New startup' `
            -Target 'HKCU:\Software\Fixture\Run' -RemovalType 'RegistryValue' `
            -ValueName 'New360Value' -IdentityFingerprint ('E5' * 32)

        $comparison = Compare-ApprovedCleanupFindings `
            -Approved @($approvedPath, $approvedProcess, $missingService, $approvedTask) `
            -Current @($currentPath, $currentProcess, $secondCurrentProcess, $reviewTask, $newStartup) -SID $sid

        Assert-TestEqual -Expected 4 -Actual $comparison.ApprovedCount `
            -Message 'The approved confirmed finding count changed.'
        Assert-TestEqual -Expected 3 -Actual @($comparison.Eligible).Count `
            -Message 'Eligibility must be the exact approved/current confirmed intersection.'
        Assert-TestEqual -Expected 2 -Actual @($comparison.Eligible | Where-Object {
            $_.Kind -eq 'Process' -and $_.Target -in @('9900', '9901')
        }).Count -Message 'Every current PID for the approved executable must remain eligible.'
        Assert-TestEqual -Expected 1 -Actual @($comparison.NewSinceApproval).Count `
            -Message 'A new finding was not separated from approved removal.'
        Assert-TestEqual -Expected 'New360Value' -Actual $comparison.NewSinceApproval[0].ValueName `
            -Message 'The wrong finding was classified as new since approval.'
        Assert-TestEqual -Expected 1 -Actual @($comparison.MissingSinceApproval).Count `
            -Message 'A missing approved finding was not reported separately.'
        Assert-TestEqual -Expected 'Fixture360Service' -Actual $comparison.MissingSinceApproval[0].Target `
            -Message 'The wrong finding was classified as missing since approval.'
        Assert-TestEqual -Expected 1 -Actual @($comparison.NoLongerConfirmed).Count `
            -Message 'A downgraded finding was not reported separately.'
        Assert-TestEqual -Expected 'Fixture360Task' -Actual $comparison.NoLongerConfirmed[0].Target `
            -Message 'The wrong finding was classified as no longer confirmed.'
    }

    Invoke-TestCase -Run $run -Name 'an unapproved browser profile never becomes eligible' -Test {
        $browserPath = 'C:\Users\ApprovalFixture\AppData\Local\360Chrome\Chrome\User Data'
        $reviewOnlyBrowser = New-ApprovalFixtureFinding -Kind 'Path' -Name 'Browser profile' `
            -Target $browserPath -Confidence 'ReviewOnly' -RemovalType 'None'
        $currentBrowser = New-ApprovalFixtureFinding -Kind 'Path' -Name 'Browser profile' `
            -Target $browserPath -Confidence 'Confirmed' -RemovalType 'Path'

        $comparison = Compare-ApprovedCleanupFindings -Approved @($reviewOnlyBrowser) `
            -Current @($currentBrowser) -SID 'S-1-5-21-111111111-222222222-333333333-1001'

        Assert-TestEqual -Expected 0 -Actual $comparison.ApprovedCount `
            -Message 'A review-only browser profile was treated as approved.'
        Assert-TestEqual -Expected 0 -Actual @($comparison.Eligible).Count `
            -Message 'A browser profile absent from approved confirmed findings became eligible.'
        Assert-TestEqual -Expected 1 -Actual @($comparison.NewSinceApproval).Count `
            -Message 'The newly confirmed browser profile must require a new approval.'
    }

    Invoke-TestCase -Run $run -Name 'process removal uses the injectable exact-identity stop operation' -Test {
        $finding = New-ApprovalFixtureFinding -Kind 'Process' -Name 'Current process' `
            -Target '4242' -RemovalType 'Process' -ValueName 'C:\Program Files\360\agent.exe'
        $fake = New-Fake360CleanupRuntimeProvider
        $summary = [ordered]@{}
        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @($finding) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $calls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'StopProcess')
        Assert-TestEqual -Expected 1 -Actual $calls.Count `
            -Message 'Process removal did not use the injectable stop operation exactly once.'
        Assert-TestSequenceEqual -Expected @(4242, 'C:\Program Files\360\agent.exe') `
            -Actual @($calls[0].Arguments) -Message 'Process identity changed before the final stop operation.'
        Assert-TestEqual -Expected 'Success' -Actual $actions[0].Result `
            -Message 'The fake exact-identity stop result was not recorded.'
    }

    Invoke-TestCase -Run $run -Name 'elevation passes report paths and hash without embedding JSON' -Test {
        $scriptPath = 'C:\测试 工具\360 清理.ps1'
        $approvedReport = 'C:\扫描 报告\已批准 清单.json'
        $resultReport = 'C:\结果 报告\清理 结果.json'
        $hash = 'A1' * 32
        $runId = 'B2' * 16
        $argumentLine = New-ElevatedCleanupArgumentLine -ScriptPath $scriptPath `
            -ApprovedReport $approvedReport -ApprovedReportHash $hash -OutcomeRunId $runId `
            -ReportPath $resultReport `
            -IncludeBrowserProfiles $true -AllowExplorerRestart $true -ForceLockedTargets $true `
            -IncludeIdentityInReport $true

        Assert-TestTrue -Condition $argumentLine.Contains(('-File "{0}"' -f $scriptPath)) `
            -Message 'The elevated command did not preserve the quoted script path.'
        Assert-TestTrue -Condition $argumentLine.Contains(('-ApprovedReport "{0}"' -f $approvedReport)) `
            -Message 'The elevated command did not preserve the quoted approved report path.'
        Assert-TestTrue -Condition $argumentLine.Contains(('-ApprovedReportHash {0}' -f $hash)) `
            -Message 'The elevated command did not preserve the approved report hash.'
        Assert-TestTrue -Condition $argumentLine.Contains(('-OutcomeRunId {0}' -f $runId)) `
            -Message 'The elevated command did not preserve the removal run identity.'
        Assert-TestTrue -Condition $argumentLine.Contains(('-ReportPath "{0}"' -f $resultReport)) `
            -Message 'The elevated command did not preserve the quoted outcome report path.'
        foreach ($flag in @(
            '-InternalElevatedChild', '-IncludeBrowserProfiles', '-BrowserProfileConfirmation',
            '-AllowExplorerRestart', '-ForceLockedTargets', '-IncludeIdentityInReport'
        )) {
            Assert-TestTrue -Condition $argumentLine.Contains($flag) `
                -Message "The elevated command omitted $flag."
        }
        Assert-TestFalse -Condition ($argumentLine.Contains('{') -or $argumentLine.Contains('SchemaVersion') -or
            $argumentLine.Contains('Findings')) `
            -Message 'The elevated command line must not embed the approved JSON body.'
    }

    Invoke-TestCase -Run $run -Name 'outcome rendering shows results without displaying stored identity' -Test {
        $outcomePath = Join-Path $fixtureRoot 'synthetic-remove-outcome.json'
        $approvedHash = 'C3' * 32
        $runId = 'D4' * 16
        $summary = [pscustomobject]@{
            TotalItemsRemoved           = 2
            FilesRemoved                = 1
            DirectoriesRemoved          = 1
            LogicalSizeRemoved          = '12 B'
            LogicalBytesRemoved         = 12
            ServicesRemoved             = 0
            ServicesPendingRemoval      = 0
            ScheduledTasksRemoved       = 0
            RegistryKeysRemoved         = 0
            RegistryValuesRemoved       = 0
            ProcessesStopped            = 0
            VendorUninstallersSucceeded = 0
            VendorUninstallersFailed    = 0
            VendorUninstallersPending   = 0
            PostVendorMutationBlocked   = $false
            ImmediateRescanComplete     = $true
            SkippedActions              = 0
            FailedActions               = 0
            PendingActions              = 0
            RetryAttempts               = 0
            UnresolvedRetryTargets      = 0
            AccessDeniedPathTargets     = 0
            AclRepairAttempts           = 0
            AclRepairFailures           = 0
            UnresolvedPathTargets       = 0
            PathTargetsRemoved          = 1
            PartiallyCleanedPathTargets = 0
            ImmediateRemainingConfirmed = 1
            NoImmediateConfirmedFindings = $false
            PathAccountingComplete      = $true
            UnmeasuredPathTargets       = 0
        }
        $action = [pscustomobject]@{
            Time   = '2026-09-04T12:01:00.0000000Z'
            Action = 'DeletePath'
            Target = 'C:\Fixture\Removed360'
            Result = 'Success'
            Detail = 'Synthetic action'
        }
        $remaining = New-ApprovalFixtureFinding -Kind 'Service' -Name 'Remaining fixture service' `
            -Target 'Remaining360Service' -RemovalType 'Service' `
            -IdentityFingerprint ('F6' * 32)
        [void](Write-ApprovalFixtureReport -Path $outcomePath -Mode 'Remove' -Summary $summary `
            -Actions @($action) -Findings @($remaining) -ComputerName 'SECRET-COMPUTER' `
            -User 'SECRET-DOMAIN\SECRET-USER' -ApprovedReportHash $approvedHash -OutcomeRunId $runId)

        $renderedItems = @(Show-CleanupReportOutcome -Path $outcomePath `
            -ExpectedApprovedReportHash $approvedHash -ExpectedOutcomeRunId $runId 6>&1)
        $returnedReports = @($renderedItems | Where-Object {
            @($_.PSObject.Properties.Name) -contains 'SchemaVersion' -and
            @($_.PSObject.Properties.Name) -contains 'Mode'
        })
        $displayItems = @($renderedItems | Where-Object {
            -not (@($_.PSObject.Properties.Name) -contains 'SchemaVersion' -and
                @($_.PSObject.Properties.Name) -contains 'Mode')
        })
        $displayText = $displayItems | Out-String -Width 4096

        Assert-TestEqual -Expected 1 -Actual $returnedReports.Count `
            -Message 'The renderer did not return the parsed outcome report exactly once.'
        Assert-TestEqual -Expected 'Remove' -Actual $returnedReports[0].Mode `
            -Message 'The renderer returned the wrong outcome report.'
        foreach ($expectedText in @(
            'Removal actions', 'DeletePath', 'Removal summary', 'Remaining findings', 'Remaining fixture service'
        )) {
            Assert-TestTrue -Condition $displayText.Contains($expectedText) `
                -Message "The renderer did not display $expectedText."
        }
        foreach ($secretText in @('ComputerName', 'SECRET-COMPUTER', 'SECRET-DOMAIN\SECRET-USER')) {
            Assert-TestFalse -Condition $displayText.Contains($secretText) `
                -Message "The renderer displayed stored identity data: $secretText"
        }
    }

    Invoke-TestCase -Run $run -Name 'blocked immediate rescan labels findings as a pre-mutation snapshot' -Test {
        $outcomePath = Join-Path $fixtureRoot 'blocked-rescan-outcome.json'
        $approvedHash = 'A7' * 32
        $runId = 'B8' * 16
        $summary = New-ApprovalFixtureSummary
        $summary.PostVendorMutationBlocked = $true
        $summary.ImmediateRescanComplete = $false
        $summary.ImmediateRemainingConfirmed = $null
        $summary.NoImmediateConfirmedFindings = $false
        $snapshotFinding = New-ApprovalFixtureFinding -Kind 'Path' -Name 'Last safe snapshot fixture' `
            -Target 'C:\Users\ApprovalFixture\AppData\Local\dhpingbao'
        [void](Write-ApprovalFixtureReport -Path $outcomePath -Mode 'Remove' -Summary $summary `
            -Findings @($snapshotFinding) -ApprovedReportHash $approvedHash -OutcomeRunId $runId)

        $renderedItems = @(Show-CleanupReportOutcome -Path $outcomePath `
            -ExpectedApprovedReportHash $approvedHash -ExpectedOutcomeRunId $runId 3>&1 6>&1)
        $displayText = @($renderedItems | Where-Object {
            -not (@($_.PSObject.Properties.Name) -contains 'SchemaVersion' -and
                @($_.PSObject.Properties.Name) -contains 'Mode')
        }) | Out-String -Width 4096

        Assert-TestTrue -Condition ($displayText -match '(?i)last safe pre-mutation') `
            -Message 'The blocked outcome did not label findings as the last safe snapshot.'
        Assert-TestTrue -Condition ($displayText -match '(?i)not proof of current remaining state') `
            -Message 'The blocked outcome mislabeled the snapshot as current remaining-state proof.'
        Assert-TestFalse -Condition $displayText.Contains('Remaining findings:') `
            -Message 'The blocked outcome used the ordinary remaining-findings heading.'
    }

    Invoke-TestCase -Run $run -Name 'outcome rendering rejects incomplete or unbound reports' -Test {
        $approvedHash = 'E5' * 32
        $runId = 'F6' * 16
        $summary = New-ApprovalFixtureSummary

        $wrongModePath = Join-Path $fixtureRoot 'outcome-wrong-mode.json'
        [void](Write-ApprovalFixtureReport -Path $wrongModePath -Mode 'Scan' -Summary $summary `
            -ApprovedReportHash $approvedHash -OutcomeRunId $runId)
        Assert-TestThrows -Operation {
            [void](Show-CleanupReportOutcome -Path $wrongModePath `
                -ExpectedApprovedReportHash $approvedHash -ExpectedOutcomeRunId $runId)
        } -Message 'A non-Remove report must not be rendered as a removal outcome.'

        $wrongHashPath = Join-Path $fixtureRoot 'outcome-wrong-hash.json'
        [void](Write-ApprovalFixtureReport -Path $wrongHashPath -Mode 'Remove' -Summary $summary `
            -ApprovedReportHash ('0' * 64) -OutcomeRunId $runId)
        Assert-TestThrows -Operation {
            [void](Show-CleanupReportOutcome -Path $wrongHashPath `
                -ExpectedApprovedReportHash $approvedHash -ExpectedOutcomeRunId $runId)
        } -Message 'An outcome for a different approval hash must be rejected.'

        $wrongRunPath = Join-Path $fixtureRoot 'outcome-wrong-run.json'
        [void](Write-ApprovalFixtureReport -Path $wrongRunPath -Mode 'Remove' -Summary $summary `
            -ApprovedReportHash $approvedHash -OutcomeRunId ('0' * 32))
        Assert-TestThrows -Operation {
            [void](Show-CleanupReportOutcome -Path $wrongRunPath `
                -ExpectedApprovedReportHash $approvedHash -ExpectedOutcomeRunId $runId)
        } -Message 'An outcome for a different removal run must be rejected.'

        foreach ($missingName in @('Summary', 'Actions', 'Findings')) {
            $missingPath = Join-Path $fixtureRoot ("outcome-missing-{0}.json" -f $missingName.ToLowerInvariant())
            $report = Write-ApprovalFixtureReport -Path $missingPath -Mode 'Remove' -Summary $summary `
                -ApprovedReportHash $approvedHash -OutcomeRunId $runId
            [void]$report.PSObject.Properties.Remove($missingName)
            $json = $report | ConvertTo-Json -Depth 8
            [IO.File]::WriteAllText($missingPath, $json, (New-Object Text.UTF8Encoding($false)))
            Assert-TestThrows -Operation {
                [void](Show-CleanupReportOutcome -Path $missingPath `
                    -ExpectedApprovedReportHash $approvedHash -ExpectedOutcomeRunId $runId)
            } -Message "An outcome missing $missingName must be rejected."
        }
    }

    Invoke-TestCase -Run $run -Name 'elevation preserves child failures but rejects unverifiable success' -Test {
        $hash = 'A7' * 32
        $runId = 'B8' * 16
        $missingFailurePath = Join-Path $fixtureRoot 'missing-failed-child-outcome.json'
        $failedFake = New-Fake360CleanupRuntimeProvider -ElevatedExitCode 23
        Set-360CleanupRuntimeProvider -Provider $failedFake.Provider -Context $failedFake.Context
        try {
            $failedItems = @(Invoke-ElevatedCleanup -ScriptPath $CleanerScriptPath `
                -ApprovedReport (Join-Path $fixtureRoot 'approved.json') -ApprovedReportHash $hash `
                -OutcomeRunId $runId -ReportPath $missingFailurePath 2>&1 3>&1 6>&1)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }
        $failedResult = @($failedItems | Where-Object { $_ -is [int] })[-1]
        Assert-TestEqual -Expected 23 -Actual $failedResult `
            -Message 'A nonzero elevated child exit code was not preserved.'

        $missingSuccessPath = Join-Path $fixtureRoot 'missing-success-child-outcome.json'
        $successFake = New-Fake360CleanupRuntimeProvider -ElevatedExitCode 0
        Set-360CleanupRuntimeProvider -Provider $successFake.Provider -Context $successFake.Context
        try {
            $successItems = @(Invoke-ElevatedCleanup -ScriptPath $CleanerScriptPath `
                -ApprovedReport (Join-Path $fixtureRoot 'approved.json') -ApprovedReportHash $hash `
                -OutcomeRunId $runId -ReportPath $missingSuccessPath 2>&1 3>&1 6>&1)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }
        $successResult = @($successItems | Where-Object { $_ -is [int] })[-1]
        Assert-TestEqual -Expected 6 -Actual $successResult `
            -Message 'A child success without a bound outcome report must become a contract failure.'

        $damagedPath = Join-Path $fixtureRoot 'damaged-success-child-outcome.json'
        [IO.File]::WriteAllText($damagedPath, '{ damaged', (New-Object Text.UTF8Encoding($false)))
        $damagedFake = New-Fake360CleanupRuntimeProvider -ElevatedExitCode 0
        Set-360CleanupRuntimeProvider -Provider $damagedFake.Provider -Context $damagedFake.Context
        try {
            $damagedItems = @(Invoke-ElevatedCleanup -ScriptPath $CleanerScriptPath `
                -ApprovedReport (Join-Path $fixtureRoot 'approved.json') -ApprovedReportHash $hash `
                -OutcomeRunId $runId -ReportPath $damagedPath 2>&1 3>&1 6>&1)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }
        $damagedResult = @($damagedItems | Where-Object { $_ -is [int] })[-1]
        Assert-TestEqual -Expected 6 -Actual $damagedResult `
            -Message 'A child success with a damaged outcome report must become a contract failure.'
    }

    Invoke-TestCase -Run $run -Name 'the non-elevated parent replays a bound child outcome' -Test {
        $hash = 'C9' * 32
        $runId = 'DA' * 16
        $outcomePath = Join-Path $fixtureRoot 'replayed-child-outcome.json'
        [void](Write-ApprovalFixtureReport -Path $outcomePath -Mode 'Remove' `
            -Summary (New-ApprovalFixtureSummary) -ApprovedReportHash $hash -OutcomeRunId $runId)
        $fake = New-Fake360CleanupRuntimeProvider -ElevatedExitCode 17
        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $items = @(Invoke-ElevatedCleanup -ScriptPath $CleanerScriptPath `
                -ApprovedReport (Join-Path $fixtureRoot 'approved.json') -ApprovedReportHash $hash `
                -OutcomeRunId $runId -ReportPath $outcomePath 2>&1 3>&1 6>&1)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $result = @($items | Where-Object { $_ -is [int] })[-1]
        $displayText = @($items | Where-Object { -not ($_ -is [int]) }) | Out-String -Width 4096
        Assert-TestEqual -Expected 17 -Actual $result `
            -Message 'The parent did not preserve the bound child exit code.'
        foreach ($expectedText in @('Removal actions', 'Removal summary', 'Remaining findings')) {
            Assert-TestTrue -Condition $displayText.Contains($expectedText) `
                -Message "The parent did not replay $expectedText."
        }
    }

    Complete-TestRun -Run $run
}
finally {
    if ($libraryLoaded) {
        Reset-360CleanupRuntimeProvider
        if ($null -ne $originalKnownFolders) { $script:KnownFolders = $originalKnownFolders }
        if ($null -ne $originalRegistryRoot) { $script:CurrentUserRegistryRoot = $originalRegistryRoot }
    }
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
        Remove-TestDirectory -Path $fixtureRoot
    }
    if ($null -eq $previousTestMode) {
        Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue
    }
    else {
        $env:WINDOWS_360_CLEANER_TEST_MODE = $previousTestMode
    }
}
