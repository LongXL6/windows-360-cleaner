#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath = (Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pathSafetyTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath

function New-PathSafetyFinding {
    param([Parameter(Mandatory = $true)][string]$Target)

    return [pscustomobject]@{
        Kind        = 'Path'
        Name        = 'Isolated path-safety fixture'
        Target      = $Target
        Confidence  = 'Confirmed'
        Reason      = 'Synthetic approved finding under a random test root.'
        RemovalType = 'Path'
        ValueName   = ''
        Offline     = $false
    }
}

function New-PathSafetyProcessFinding {
    return [pscustomobject]@{
        Kind        = 'Process'
        Name        = 'isolated-approved-process.exe'
        Target      = '4242'
        Confidence  = 'Confirmed'
        Reason      = 'Synthetic approved non-path action.'
        RemovalType = 'Process'
        ValueName   = 'C:\Fixture\isolated-approved-process.exe'
        Offline     = $false
    }
}

function Remove-PathSafetyTestJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Collections.ArrayList]$TrackedPaths
    )

    try {
        [IO.Directory]::Delete($Path)
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
        if (-not ($exception -is [IO.DirectoryNotFoundException])) { throw }
    }
    [void]$TrackedPaths.Remove($Path)
}

$run = New-TestRun -Name 'Path safety tests'
$fixtureRoot = $null
$originalKnownFolders = $null
$libraryLoaded = $false
$junctionPaths = New-Object System.Collections.ArrayList
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

    Invoke-TestCase -Run $run -Name 'path-safety files and ACL repair keep the PowerShell 5.1 contract' -Test {
        Assert-TestPowerShellFileContract -Path $helpersPath
        Assert-TestPowerShellFileContract -Path $pathSafetyTestPath

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $CleanerScriptPath, [ref]$tokens, [ref]$parseErrors)
        Assert-TestEqual -Expected 0 -Actual $parseErrors.Count `
            -Message 'The production script must parse before its ACL command contract is inspected.'
        $repairFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Repair-360CleanupPathAcl'
        }, $true)
        Assert-TestNotNull -Actual $repairFunction `
            -Message 'The exact-frontier ACL repair function was not found.'
        $repairText = [string]$repairFunction.Extent.Text
        Assert-TestTrue -Condition ($repairText -match '(?i)takeown\.exe' -and $repairText -match '(?i)icacls\.exe') `
            -Message 'The ACL repair function no longer exposes the reviewed takeown/icacls boundary.'
        Assert-TestFalse -Condition ($repairText -match '(?im)(?:^|\s)/(?:R|T)(?=\s|$)') `
            -Message 'ACL repair must never use recursive takeown /R or icacls /T flags.'
        Assert-TestFalse -Condition ($repairText -match '(?i)\((?:OI|CI)\)') `
            -Message 'ACL repair must not add object/container inheritance propagation flags.'
        Assert-TestTrue -Condition ($repairText -match '(?im)(?:^|\s)/L(?=\s|$)') `
            -Message 'icacls must operate on the already observed frontier itself rather than follow a link.'
    }

    Invoke-TestCase -Run $run -Name 'UnauthorizedAccessException is AccessDenied rather than ReparsePoint' -Test {
        $target = Join-Path $script:KnownFolders.LocalAppData 'dhpingbao'
        $deniedFrontier = Join-Path $target 'private'
        New-Item -ItemType Directory -Path $deniedFrontier -Force | Out-Null
        $pathChildren = @{}
        $pathChildren[$deniedFrontier] = New-Object System.UnauthorizedAccessException `
            -ArgumentList 'ISOLATED-ACCESS-DENIED'
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -PathChildren $pathChildren

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $state = Get-RemovalPathSafetyState -Path $target
            $safeWrapper = Test-SafeRemovalTarget -Path $target
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 'AccessDenied' -Actual $state.State `
            -Message 'UnauthorizedAccessException was not classified as AccessDenied.'
        Assert-TestFalse -Condition ($state.State -eq 'ReparsePoint') `
            -Message 'An access-denied enumeration was mislabeled as a reparse point.'
        Assert-TestTrue -Condition $state.Exists `
            -Message 'The existing access-denied target was reported as missing.'
        Assert-TestFalse -Condition $state.TreeScanComplete `
            -Message 'An access-denied target must never claim a complete tree scan.'
        Assert-TestEqual -Expected (Get-NormalPath $deniedFrontier) -Actual $state.BlockedPath `
            -Message 'The denied frontier was not preserved in the structured safety result.'
        Assert-TestTrue -Condition $state.BlockedPathVerifiedNonReparse `
            -Message 'The denied frontier must be repaired only after its own item was observed as non-reparse.'
        Assert-TestFalse -Condition $safeWrapper `
            -Message 'The Boolean safety wrapper must fail closed for AccessDenied.'
    }

    Invoke-TestCase -Run $run -Name 'PathItem access denial is Unsafe and never a repairable frontier' -Test {
        $target = Join-Path $script:KnownFolders.Temp '360UnPackTmp64'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $cases = @(
            [pscustomobject]@{ Name = 'parent chain'; BlockedPath = $script:KnownFolders.Temp },
            [pscustomobject]@{ Name = 'target item'; BlockedPath = $target }
        )

        foreach ($case in $cases) {
            $pathItems = @{}
            $pathItems[$case.BlockedPath] = New-Object System.UnauthorizedAccessException `
                -ArgumentList ('ISOLATED-PATHITEM-DENIED-' + $case.Name)
            $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -PathItems $pathItems
            Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
            try {
                $state = Get-RemovalPathSafetyState -Path $target
            }
            finally {
                Reset-360CleanupRuntimeProvider
            }

            Assert-TestEqual -Expected 'Unsafe' -Actual $state.State `
                -Message ("PathItem denial on the {0} became a repairable state." -f $case.Name)
            Assert-TestEqual -Expected (Get-NormalPath $case.BlockedPath) -Actual $state.BlockedPath `
                -Message ("PathItem denial lost the blocked {0} path." -f $case.Name)
            Assert-TestFalse -Condition $state.BlockedPathVerifiedNonReparse `
                -Message ("An unreadable {0} path was falsely marked verified non-reparse." -f $case.Name)
            Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RepairPathAcl').Count `
                -Message ("Classification unexpectedly repaired the unreadable {0} path." -f $case.Name)
        }
    }

    Invoke-TestCase -Run $run -Name 'AccessDenied skips one path while safe and non-path actions continue' -Test {
        $deniedTarget = Join-Path $script:KnownFolders.Temp 'huabao_tmp'
        $deniedFrontier = Join-Path $deniedTarget 'private'
        $safeTarget = Join-Path $script:KnownFolders.Temp 'duohuipingbao'
        New-Item -ItemType Directory -Path $deniedFrontier -Force | Out-Null
        New-Item -ItemType Directory -Path $safeTarget -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $safeTarget 'payload.tmp') -Value 'ISOLATED-SAFE-PAYLOAD'

        $pathChildren = @{}
        $pathChildren[$deniedFrontier] = New-Object System.UnauthorizedAccessException `
            -ArgumentList 'ISOLATED-ACCESS-DENIED'
        $pathRemovals = @{}
        $pathRemovals[$safeTarget] = {
            param($Context, [string]$Path)
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -PathChildren $pathChildren -PathRemovals $pathRemovals
        $summary = [ordered]@{}
        $findings = @(
            (New-PathSafetyFinding -Target $deniedTarget),
            (New-PathSafetyFinding -Target $safeTarget),
            (New-PathSafetyProcessFinding)
        )

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings $findings -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestTrue -Condition (Test-Path -LiteralPath $deniedTarget) `
            -Message 'The access-denied target was deleted in default mode.'
        Assert-TestFalse -Condition (Test-Path -LiteralPath $safeTarget) `
            -Message 'A separate safe approved target did not continue after AccessDenied.'
        Assert-TestEqual -Expected 1 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'StopProcess').Count `
            -Message 'An approved non-path action was blocked by an unrelated AccessDenied target.'
        Assert-TestEqual -Expected 1 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RemovePath').Count `
            -Message 'Only the independently safe target should reach the path-removal provider.'
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RepairPathAcl').Count `
            -Message 'Default mode must never invoke ACL repair.'

        $deniedActions = @($actions | Where-Object {
            $_.Action -eq 'DeletePath' -and $_.Target -eq $deniedTarget -and $_.Result -eq 'Skipped'
        })
        Assert-TestEqual -Expected 1 -Actual $deniedActions.Count `
            -Message 'The access-denied path was not recorded as an explicit skipped action.'
        Assert-TestTrue -Condition ($deniedActions[0].Detail -match '(?i)access') `
            -Message 'The skipped path action did not explain the access-denied state.'
        Assert-TestEqual -Expected 1 -Actual @($actions | Where-Object {
            $_.Action -eq 'DeletePath' -and $_.Target -eq $safeTarget -and $_.Result -eq 'Success'
        }).Count -Message 'The independent safe path removal was not recorded as successful.'
        Assert-TestFalse -Condition ([bool]$summary.PathAccountingComplete) `
            -Message 'An unmeasured access-denied target incorrectly claimed complete path accounting.'
        Assert-TestTrue -Condition ([int]$summary.UnmeasuredPathTargets -gt 0) `
            -Message 'The unmeasured access-denied target was omitted from the summary.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention `
            -Summary $summary -RemainingConfirmed 0) `
            -Message 'Incomplete path accounting must keep the Remove outcome at exit-code-2 attention state.'
    }

    Invoke-TestCase -Run $run -Name 'a visible junction blocks every mutation during global preflight' -Test {
        $outside = Join-Path $fixtureRoot 'junction-global-canary'
        $reparseTarget = Join-Path $script:KnownFolders.Temp '360gameassistantYyb'
        $safeTarget = Join-Path $script:KnownFolders.Temp '360UnPackTmp64'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
        New-Item -ItemType Directory -Path $safeTarget -Force | Out-Null
        $outsideFile = Join-Path $outside 'keep.txt'
        Set-Content -LiteralPath $outsideFile -Value 'KEEP-GLOBAL-CANARY'
        $outsideHash = (Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash
        Set-Content -LiteralPath (Join-Path $safeTarget 'keep-until-preflight-passes.txt') -Value 'KEEP-SAFE-TARGET'
        $junction = Join-Path $reparseTarget 'escape'
        [void]$junctionPaths.Add($junction)
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null

        $pathRemovals = @{}
        $pathRemovals[$safeTarget] = {
            param($Context, [string]$Path)
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -PathRemovals $pathRemovals
        $blocked = $false
        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            try {
                [void](Remove-ConfirmedFindings -Findings @(
                    (New-PathSafetyFinding -Target $reparseTarget),
                    (New-PathSafetyFinding -Target $safeTarget),
                    (New-PathSafetyProcessFinding)
                ))
            }
            catch { $blocked = $true }
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestTrue -Condition $blocked `
            -Message 'A visible junction did not fail the complete mutation preflight.'
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RemovePath').Count `
            -Message 'A path mutation ran before all targets passed the junction preflight.'
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'StopProcess').Count `
            -Message 'A non-path mutation ran before all targets passed the junction preflight.'
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RepairPathAcl').Count `
            -Message 'Global junction refusal must happen before any ACL mutation.'
        Assert-TestTrue -Condition (Test-Path -LiteralPath $safeTarget) `
            -Message 'The independent safe target changed before the global preflight completed.'
        Assert-TestEqual -Expected $outsideHash `
            -Actual (Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash `
            -Message 'The external junction canary changed.'

        Remove-PathSafetyTestJunction -Path $junction -TrackedPaths $junctionPaths
    }

    Invoke-TestCase -Run $run -Name 'unknown tree-enumeration errors block every mutation' -Test {
        $unknownTarget = Join-Path $script:KnownFolders.ProgramData '360'
        $safeTarget = Join-Path $script:KnownFolders.ProgramData '360safe'
        New-Item -ItemType Directory -Path $unknownTarget -Force | Out-Null
        New-Item -ItemType Directory -Path $safeTarget -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $safeTarget 'keep.txt') -Value 'KEEP-UNKNOWN-ERROR-SAFE-TARGET'

        $pathChildren = @{}
        $pathChildren[$unknownTarget] = New-Object System.IO.IOException `
            -ArgumentList 'ISOLATED-UNKNOWN-ENUMERATION-ERROR'
        $pathRemovals = @{}
        $pathRemovals[$safeTarget] = {
            param($Context, [string]$Path)
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -PathChildren $pathChildren -PathRemovals $pathRemovals
        $blocked = $false
        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $state = Get-RemovalPathSafetyState -Path $unknownTarget
            try {
                [void](Remove-ConfirmedFindings -Findings @(
                    (New-PathSafetyFinding -Target $unknownTarget),
                    (New-PathSafetyFinding -Target $safeTarget),
                    (New-PathSafetyProcessFinding)
                ) -ForceLockedTargets)
            }
            catch { $blocked = $true }
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 'Unsafe' -Actual $state.State `
            -Message 'A non-permission tree-enumeration error did not fail closed as Unsafe.'
        Assert-TestFalse -Condition $state.BlockedPathVerifiedNonReparse `
            -Message 'An unknown tree-enumeration failure became an ACL-repair frontier.'
        Assert-TestTrue -Condition $blocked `
            -Message 'An unknown tree-enumeration error did not stop the complete mutation preflight.'
        foreach ($operation in @('StopProcess', 'RemovePath', 'RepairPathAcl')) {
            Assert-TestEqual -Expected 0 `
                -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation $operation).Count `
                -Message ("The {0} mutation ran after an unknown inspection error." -f $operation)
        }
        Assert-TestTrue -Condition (Test-Path -LiteralPath $safeTarget) `
            -Message 'The separate safe target changed after an unknown inspection error.'
    }

    Invoke-TestCase -Run $run -Name 'Force repairs only the denied frontier and rescans before deletion' -Test {
        $target = Join-Path $script:KnownFolders.RoamingAppData 'secoresdk\360se6'
        $deniedFrontier = Join-Path $target 'private'
        $outside = Join-Path $fixtureRoot 'force-repair-canary'
        New-Item -ItemType Directory -Path $deniedFrontier -Force | Out-Null
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $outsideFile = Join-Path $outside 'keep.txt'
        Set-Content -LiteralPath $outsideFile -Value 'KEEP-FORCE-CANARY'
        $outsideHash = (Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash
        $junction = Join-Path $deniedFrontier 'revealed-after-repair'
        [void]$junctionPaths.Add($junction)

        $pathChildren = @{}
        $pathChildren[$deniedFrontier] = New-Object System.UnauthorizedAccessException `
            -ArgumentList 'ISOLATED-HIDDEN-TREE'
        $pathAclRepairs = @{}
        $pathAclRepairs[$deniedFrontier] = {
            param($Context, [string]$Path)
            [void]$Context.PathChildrenByPath.Remove($Path)
            New-Item -ItemType Junction -Path $Context.RevealedJunction -Target $Context.OutsideTarget | Out-Null
        }
        $pathRemovals = @{}
        $pathRemovals[$target] = {
            param($Context, [string]$Path)
            throw 'RemovePath must not run after the force rescan reveals a junction.'
        }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -PathChildren $pathChildren -PathAclRepairs $pathAclRepairs -PathRemovals $pathRemovals
        Add-Member -InputObject $fake.Context -MemberType NoteProperty -Name RevealedJunction -Value $junction
        Add-Member -InputObject $fake.Context -MemberType NoteProperty -Name OutsideTarget -Value $outside
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-PathSafetyFinding -Target $target)
            ) -ForceLockedTargets -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $repairCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RepairPathAcl')
        Assert-TestEqual -Expected 1 -Actual $repairCalls.Count `
            -Message 'Force did not repair the single verified denied frontier exactly once.'
        Assert-TestSequenceEqual -Expected @($deniedFrontier) -Actual @($repairCalls[0].Arguments) `
            -Message 'Force expanded ACL repair beyond the exact denied frontier.'
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RemovePath').Count `
            -Message 'The target was sent to recursive deletion after the full rescan revealed a junction.'
        Assert-TestTrue -Condition (Test-Path -LiteralPath $target) `
            -Message 'The target containing a newly visible junction was deleted.'
        Assert-TestEqual -Expected $outsideHash `
            -Actual (Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash `
            -Message 'The force-repair junction canary changed.'
        Assert-TestTrue -Condition (@($actions | Where-Object {
            $_.Target -eq $target -and $_.Result -in @('Skipped', 'Failed')
        }).Count -ge 1) -Message 'The post-repair reparse refusal was not reported as unresolved.'
        Assert-TestFalse -Condition ([bool]$summary.PathAccountingComplete) `
            -Message 'A force target that was initially unmeasurable claimed complete path accounting.'
        Assert-TestTrue -Condition ([int]$summary.UnmeasuredPathTargets -gt 0) `
            -Message 'The initially unmeasured force target was omitted from the summary.'

        Remove-PathSafetyTestJunction -Path $junction -TrackedPaths $junctionPaths
    }

    Invoke-TestCase -Run $run -Name 'Force repairs an exact access-denied target then rejects a revealed junction' -Test {
        $target = Join-Path $script:KnownFolders.RoamingAppData '360Safe'
        $outside = Join-Path $fixtureRoot 'force-remove-access-canary'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'locked.bin') -Value 'ISOLATED-ACCESS-DENIED-PAYLOAD'
        $outsideFile = Join-Path $outside 'keep.txt'
        Set-Content -LiteralPath $outsideFile -Value 'KEEP-FORCE-REMOVE-CANARY'
        $outsideHash = (Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash
        $junction = Join-Path $target 'revealed-after-target-repair'
        [void]$junctionPaths.Add($junction)

        $pathRemovals = @{}
        $pathRemovals[$target] = New-Object System.UnauthorizedAccessException `
            -ArgumentList 'ISOLATED-REMOVE-ACCESS-DENIED'
        $pathAclRepairs = @{}
        $pathAclRepairs[$target] = {
            param($Context, [string]$Path)
            New-Item -ItemType Junction -Path $Context.RevealedJunction -Target $Context.OutsideTarget | Out-Null
        }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -PathRemovals $pathRemovals -PathAclRepairs $pathAclRepairs
        Add-Member -InputObject $fake.Context -MemberType NoteProperty -Name RevealedJunction -Value $junction
        Add-Member -InputObject $fake.Context -MemberType NoteProperty -Name OutsideTarget -Value $outside
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-PathSafetyFinding -Target $target)
            ) -ForceLockedTargets -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $repairCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RepairPathAcl')
        Assert-TestEqual -Expected 1 -Actual $repairCalls.Count `
            -Message 'Force did not repair the exact target after RemovePath returned AccessDenied.'
        Assert-TestSequenceEqual -Expected @($target) -Actual @($repairCalls[0].Arguments) `
            -Message 'RemovePath AccessDenied expanded ACL repair beyond the exact observed target.'
        $allCalls = @($fake.Calls)
        $repairIndex = -1
        for ($index = 0; $index -lt $allCalls.Count; $index++) {
            if ($allCalls[$index].Operation -eq 'RepairPathAcl') { $repairIndex = $index; break }
        }
        Assert-TestTrue -Condition ($repairIndex -ge 0) `
            -Message 'The ACL repair call was missing from the ordered provider trace.'
        $removeAfterRepair = @($allCalls | Select-Object -Skip ($repairIndex + 1) | Where-Object {
            $_.Operation -eq 'RemovePath'
        })
        Assert-TestEqual -Expected 0 -Actual $removeAfterRepair.Count `
            -Message 'Recursive deletion ran after the post-repair root rescan exposed a junction.'
        Assert-TestTrue -Condition (Test-Path -LiteralPath $target) `
            -Message 'The exact target was deleted after its repair exposed a junction.'
        Assert-TestEqual -Expected $outsideHash `
            -Actual (Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash `
            -Message 'The target-repair junction canary changed.'
        Assert-TestTrue -Condition (@($actions | Where-Object {
            $_.Action -eq 'DeletePathForceRetry' -and $_.Target -eq $target -and
                $_.Result -eq 'Failed' -and $_.Detail -match 'ReasonCode=ReparsePoint'
        }).Count -ge 1) -Message 'The post-repair reparse refusal was not reported with a reason code.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention `
            -Summary $summary -RemainingConfirmed 0) `
            -Message 'A post-repair reparse refusal must preserve exit-code-2 attention state.'

        Remove-PathSafetyTestJunction -Path $junction -TrackedPaths $junctionPaths
    }

    Invoke-TestCase -Run $run -Name 'Force never treats an ordinary IOException lock as ACL denial' -Test {
        $target = Join-Path $script:KnownFolders.RoamingAppData '360GameAssistant'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'locked.bin') -Value 'ISOLATED-SHARING-LOCK-PAYLOAD'
        $pathRemovals = @{}
        $pathRemovals[$target] = New-Object System.IO.IOException `
            -ArgumentList 'ISOLATED-SHARING-VIOLATION'
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -PathRemovals $pathRemovals
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-PathSafetyFinding -Target $target)
            ) -ForceLockedTargets -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestTrue -Condition (@(Get-Fake360CleanupCalls -Fake $fake -Operation 'RemovePath').Count -gt 0) `
            -Message 'The ordinary lock fixture never reached the isolated removal provider.'
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RepairPathAcl').Count `
            -Message 'An ordinary IOException/sharing lock incorrectly triggered ACL repair.'
        Assert-TestTrue -Condition (Test-Path -LiteralPath $target) `
            -Message 'The ordinary locked target was unexpectedly deleted.'
        Assert-TestTrue -Condition (@($actions | Where-Object {
            $_.Target -eq $target -and $_.Result -in @('Skipped', 'Failed')
        }).Count -ge 1) -Message 'The unresolved ordinary lock was not reported.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention `
            -Summary $summary -RemainingConfirmed 0) `
            -Message 'An unresolved ordinary lock must preserve exit-code-2 attention state.'
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
    $junctionCleanupErrors = New-Object System.Collections.ArrayList
    foreach ($junction in @($junctionPaths)) {
        if (-not $junction) { continue }
        try {
            Remove-PathSafetyTestJunction -Path $junction -TrackedPaths $junctionPaths
        }
        catch {
            [void]$junctionCleanupErrors.Add(("{0}: {1}" -f $junction, $_.Exception.Message))
        }
    }
    if ($junctionCleanupErrors.Count -eq 0 -and $junctionPaths.Count -eq 0 -and
        $fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
        Remove-TestDirectory -Path $fixtureRoot
    }
    if ($junctionCleanupErrors.Count -gt 0 -or $junctionPaths.Count -gt 0) {
        throw ("Junction cleanup failed; recursive fixture cleanup was skipped: {0}" -f `
            (@($junctionCleanupErrors) -join '; '))
    }
}
