#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath = (Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$vendorTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath

function Set-VendorTestKnownFolders {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureRoot,
        [Parameter(Mandatory = $true)][string]$CaseName
    )

    $caseRoot = Join-Path $FixtureRoot $CaseName
    $script:KnownFolders = [ordered]@{
        LocalAppData    = Join-Path $caseRoot 'LocalAppData'
        RoamingAppData  = Join-Path $caseRoot 'RoamingAppData'
        ProgramFiles    = Join-Path $caseRoot 'ProgramFiles'
        ProgramFilesX86 = Join-Path $caseRoot 'ProgramFilesX86'
        ProgramData     = Join-Path $caseRoot 'ProgramData'
        UserProfile     = Join-Path $caseRoot 'UserProfile'
        Desktop         = Join-Path $caseRoot 'Desktop'
        Temp            = Join-Path $caseRoot 'Temp'
        Windows         = Join-Path $caseRoot 'Windows'
    }
    foreach ($path in $script:KnownFolders.Values) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function New-VendorTestFixture {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureRoot,
        [Parameter(Mandatory = $true)][string]$CaseName
    )

    Set-VendorTestKnownFolders -FixtureRoot $FixtureRoot -CaseName $CaseName
    $installRoot = Join-Path $script:KnownFolders.LocalAppData 'dhpingbao'
    $vendorPath = Join-Path $installRoot 'huabaosetup.exe'
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    [IO.File]::WriteAllText($vendorPath, ('ISOLATED-VENDOR-' + $CaseName), (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{
        InstallRoot = Get-NormalPath $installRoot
        VendorPath  = Get-NormalPath $vendorPath
        Hash        = (Get-FileHash -LiteralPath $vendorPath -Algorithm SHA256).Hash
    }
}

function New-VendorTestFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Hash
    )

    return [pscustomobject]@{
        Kind = 'VendorUninstaller'; Name = 'Duohui vendor uninstaller'; Target = $Target
        Confidence = 'Confirmed'; Reason = 'Isolated vendor fixture'
        RemovalType = 'VendorUninstaller'; ValueName = $Hash
        IdentityFingerprint = ''; Offline = $false
    }
}

function New-VendorRootFinding {
    param([Parameter(Mandatory = $true)][string]$Target)

    return [pscustomobject]@{
        Kind = 'Path'; Name = 'Duohui screen saver'; Target = $Target
        Confidence = 'Confirmed'; Reason = 'Isolated paired-root fixture'
        RemovalType = 'Path'; ValueName = ''; IdentityFingerprint = ''; Offline = $false
    }
}

function New-VendorProcessFinding {
    param(
        [int]$ProcessId = 4242,
        [string]$Executable = 'C:\IndependentFixture\worker.exe'
    )

    return [pscustomobject]@{
        Kind = 'Process'; Name = 'Independent fixture process'; Target = [string]$ProcessId
        Confidence = 'Confirmed'; Reason = 'Isolated independent mutation fixture'
        RemovalType = 'Process'; ValueName = $Executable; IdentityFingerprint = ''; Offline = $false
    }
}

function New-VendorRegistryKeyFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$IdentityFingerprint = ''
    )

    return [pscustomobject]@{
        Kind = 'RegistryResidue'; Name = 'Isolated vendor-removed residue'; Target = $Target
        Confidence = 'Confirmed'; Reason = 'Isolated post-vendor absence fixture'
        RemovalType = 'RegistryKey'; ValueName = ''
        IdentityFingerprint = $IdentityFingerprint; Offline = $false
    }
}

function New-VendorServiceFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$IdentityFingerprint = ''
    )

    return [pscustomobject]@{
        Kind = 'Service'; Name = $Name; Target = $Name
        Confidence = 'Confirmed'; Reason = 'Isolated service identity fixture'
        RemovalType = 'Service'; ValueName = ''
        IdentityFingerprint = $IdentityFingerprint; Offline = $false
    }
}

function New-VendorTaskFinding {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [string]$IdentityFingerprint = ''
    )

    return [pscustomobject]@{
        Kind = 'ScheduledTask'; Name = $TaskName; Target = $TaskName
        Confidence = 'Confirmed'; Reason = 'Isolated task identity fixture'
        RemovalType = 'Task'; ValueName = $TaskPath
        IdentityFingerprint = $IdentityFingerprint; Offline = $false
    }
}

function New-VendorRegistryValueFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ValueName,
        [string]$IdentityFingerprint = ''
    )

    return [pscustomobject]@{
        Kind = 'Startup'; Name = $ValueName; Target = $Target
        Confidence = 'Confirmed'; Reason = 'Isolated registry-value identity fixture'
        RemovalType = 'RegistryValue'; ValueName = $ValueName
        IdentityFingerprint = $IdentityFingerprint; Offline = $false
    }
}

function Set-VendorTestIdentityFingerprint {
    param([Parameter(Mandatory = $true)][object]$Finding)

    $identity = Get-360CleanupNonPathIdentityState $Finding
    if ($identity.State -ne 'Present' -or
        [string]$identity.Fingerprint -notmatch '^[0-9A-F]{64}$') {
        throw ("The isolated {0} fixture did not expose a stable identity: {1} {2}" -f `
            $Finding.RemovalType, $identity.State, $identity.Detail)
    }
    $Finding.IdentityFingerprint = [string]$identity.Fingerprint
    return $Finding
}

function Get-VendorCallIndex {
    param(
        [Parameter(Mandatory = $true)][object]$Fake,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    for ($index = 0; $index -lt $Fake.Calls.Count; $index++) {
        if ($Fake.Calls[$index].Operation -eq $Operation) { return $index }
    }
    return -1
}

$run = New-TestRun -Name 'Vendor uninstaller tests'
$fixtureRoot = $null
$libraryLoaded = $false
$originalKnownFolders = $null
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

    Invoke-TestCase -Run $run -Name 'vendor tests keep the PowerShell 5.1 contract and timeout never kills' -Test {
        Assert-TestPowerShellFileContract -Path $helpersPath
        Assert-TestPowerShellFileContract -Path $vendorTestPath

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $CleanerScriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        Assert-TestEqual -Expected 0 -Actual $parseErrors.Count `
            -Message 'The production cleaner did not parse while inspecting the vendor timeout contract.'
        $vendorStartFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Start-360CleanupVendorUninstaller'
        }, $true)
        Assert-TestNotNull -Actual $vendorStartFunction `
            -Message 'The vendor-uninstaller start wrapper was not found.'
        $functionText = $vendorStartFunction.Extent.Text
        Assert-TestTrue -Condition ($functionText -match 'WaitForExit') `
            -Message 'The vendor wrapper no longer has a bounded wait.'
        Assert-TestFalse -Condition ($functionText -match '(?i)(?:\.Kill\s*\(|\bStop-Process\b)') `
            -Message 'The vendor timeout path must not forcibly terminate the vendor process.'

        $trustedVendorFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Test-IsTrustedDuohuiVendorFile'
        }, $true)
        Assert-TestNotNull -Actual $trustedVendorFunction `
            -Message 'The exact signed-vendor trust gate was not found.'
        $trustedVendorText = $trustedVendorFunction.Extent.Text
        Assert-TestTrue -Condition ($trustedVendorText -match 'Get-AuthenticodeSignature' -and
            $trustedVendorText -match "Status[\s\S]*'Valid'" -and
            $trustedVendorText -match 'X509NameType[\s\S]*SimpleName' -and
            $trustedVendorText.Contains('Beijing Qihu Technology Co., Ltd.') -and
            $trustedVendorText -match '(?i)duohui|huabao|\u591a\u7ed8|\u753b\u62a5') `
            -Message 'The default vendor trust gate lost its exact signature and Duohui metadata requirements.'

        $approvedVendorFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Invoke-ApprovedDuohuiVendorUninstaller'
        }, $true)
        Assert-TestNotNull -Actual $approvedVendorFunction `
            -Message 'The approved vendor launch function was not found.'
        $approvedVendorText = $approvedVendorFunction.Extent.Text
        $launchOpenIndex = $approvedVendorText.IndexOf('[IO.File]::Open(')
        $launchTrustIndex = $approvedVendorText.IndexOf('Test-IsTrustedDuohuiVendorFile $approvedPath')
        $launchHashIndex = $approvedVendorText.IndexOf('Get-360CleanupStreamSha256 $lockState.Stream')
        $launchStartIndex = $approvedVendorText.IndexOf('Start-360CleanupVendorUninstaller')
        Assert-TestTrue -Condition ($launchOpenIndex -ge 0 -and $launchTrustIndex -gt $launchOpenIndex -and
            $launchHashIndex -gt $launchTrustIndex -and $launchStartIndex -gt $launchHashIndex) `
            -Message 'Launch must lock, verify trust, hash that locked stream, and only then start the vendor process.'
        Assert-TestTrue -Condition ($approvedVendorText -match '(?s)\[IO\.FileShare\]::Read[\s\S]*-OnStarted\s+\$releaseFileHandle') `
            -Message 'The launch lock is not held through the Start-Process callback boundary.'
        Assert-TestFalse -Condition $approvedVendorText.Contains('Get-360CleanupFileSha256') `
            -Message 'Launch reintroduced a separate unlocked file-hash read.'

        $detectorFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-360Findings'
        }, $true)
        Assert-TestNotNull -Actual $detectorFunction `
            -Message 'The detector function was not found for locked identity inspection.'
        $detectorText = $detectorFunction.Extent.Text
        $scanVendorIndex = $detectorText.IndexOf('$duohuiVendorPath = Get-DuohuiVendorUninstallerPath')
        Assert-TestTrue -Condition ($scanVendorIndex -ge 0) `
            -Message 'The exact Duohui vendor scan block was not found.'
        $scanVendorText = $detectorText.Substring($scanVendorIndex)
        $scanOpenIndex = $scanVendorText.IndexOf('[IO.File]::Open(')
        $scanTrustIndex = $scanVendorText.IndexOf('Test-IsTrustedDuohuiVendorFile $duohuiVendorPath')
        $scanHashIndex = $scanVendorText.IndexOf('Get-360CleanupStreamSha256 $identityStream')
        Assert-TestTrue -Condition ($scanOpenIndex -ge 0 -and $scanTrustIndex -gt $scanOpenIndex -and
            $scanHashIndex -gt $scanTrustIndex) `
            -Message 'Scan must lock, verify trust, and hash the same locked stream in that order.'
        Assert-TestTrue -Condition ($scanVendorText -match '(?s)\[IO\.FileShare\]::Read[\s\S]*\$identityStream\.Dispose\(\)') `
            -Message 'The scan identity lock does not use the read-only sharing contract with deterministic disposal.'
        Assert-TestFalse -Condition $detectorText.Contains('Get-360CleanupFileSha256') `
            -Message 'Detector reintroduced a separate unlocked file-hash read.'

        $unlockedHashFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-360CleanupFileSha256'
        }, $true)
        Assert-TestNull -Actual $unlockedHashFunction `
            -Message 'An unlocked path-based vendor hash helper was reintroduced.'

        $registryKeyIdentityFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-360CleanupRegistryKeyStableText'
        }, $true)
        Assert-TestNotNull -Actual $registryKeyIdentityFunction `
            -Message 'The recursive registry-key identity function was not found.'
        $registryKeyIdentityText = $registryKeyIdentityFunction.Extent.Text
        Assert-TestFalse -Condition ($registryKeyIdentityText -match "-notmatch\s+'\^PS'") `
            -Message 'Registry-key identity ignored legitimate values merely because their names start with PS.'
        foreach ($providerMetadataName in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) {
            Assert-TestTrue -Condition $registryKeyIdentityText.Contains("'$providerMetadataName'") `
                -Message ("Registry-key identity lost its exact provider metadata exclusion: $providerMetadataName")
        }

        $exactServiceFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-360CleanupExactServiceController'
        }, $true)
        Assert-TestNotNull -Actual $exactServiceFunction `
            -Message 'The exact service-controller lookup helper was not found.'
        $exactServiceText = $exactServiceFunction.Extent.Text
        Assert-TestTrue -Condition ($exactServiceText -match 'Get-Service\s+-ErrorAction\s+Stop' -and
            $exactServiceText -match '\.Equals\(\$Name,\s*\[StringComparison\]::OrdinalIgnoreCase\)' -and
            $exactServiceText -match '\$matches\.Count\s+-gt\s+1') `
            -Message 'Service-controller lookup no longer requires one exact ordinal-ignore-case match.'

        $removeFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Remove-ConfirmedFindings'
        }, $true)
        Assert-TestNotNull -Actual $removeFunction `
            -Message 'The removal function was not found for exact service mutation inspection.'
        $removeFunctionText = $removeFunction.Extent.Text
        Assert-TestTrue -Condition ($removeFunctionText -match
            'Stop-Service\s+-InputObject\s+\$serviceController\s+-ErrorAction\s+Stop') `
            -Message 'Service stop no longer uses the exact controller object.'
        Assert-TestFalse -Condition ($removeFunctionText -match '(?im)Stop-Service[^\r\n]*\s-Name\b') `
            -Message 'Service stop reintroduced wildcard-capable -Name binding.'
        Assert-TestFalse -Condition ($removeFunctionText -match '(?im)Stop-Service[^\r\n]*\s-Force\b') `
            -Message 'Service stop reintroduced forced dependent-service mutation.'
        Assert-TestTrue -Condition (@([regex]::Matches(
            $removeFunctionText,
            'Get-360CleanupExactServiceController\s+\(\[string\]\$finding\.Target\)'
        )).Count -ge 2) -Message 'Service mutation and verification do not both use exact lookup.'
        $serviceBlockStart = $removeFunctionText.IndexOf(
            "foreach (`$finding in @(`$confirmed | Where-Object { `$_.RemovalType -eq 'Service' }))"
        )
        $serviceBlockEnd = $removeFunctionText.IndexOf(
            "foreach (`$finding in @(`$confirmed | Where-Object { `$_.RemovalType -eq 'Task' }))"
        )
        Assert-TestTrue -Condition ($serviceBlockStart -ge 0 -and $serviceBlockEnd -gt $serviceBlockStart) `
            -Message 'The isolated service mutation block could not be identified.'
        $serviceBlockText = $removeFunctionText.Substring(
            $serviceBlockStart,
            $serviceBlockEnd - $serviceBlockStart
        )
        $firstDispositionIndex = $serviceBlockText.IndexOf('Get-360CleanupPostVendorDisposition')
        $stopServiceIndex = $serviceBlockText.IndexOf('Stop-Service -InputObject $serviceController')
        $secondDispositionIndex = $serviceBlockText.IndexOf(
            'Get-360CleanupPostVendorDisposition',
            $firstDispositionIndex + 1
        )
        $deleteServiceIndex = $serviceBlockText.IndexOf('& sc.exe delete $finding.Target')
        Assert-TestTrue -Condition ($firstDispositionIndex -ge 0 -and
            $stopServiceIndex -gt $firstDispositionIndex -and
            $secondDispositionIndex -gt $stopServiceIndex -and
            $deleteServiceIndex -gt $secondDispositionIndex) `
            -Message 'Service identity must be revalidated between exact stop and sc.exe delete.'
        Assert-TestEqual -Expected 2 `
            -Actual @([regex]::Matches($serviceBlockText, 'Get-360CleanupPostVendorDisposition')).Count `
            -Message 'The service block must have exactly pre-stop and pre-delete identity gates.'

        $removeCommands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Remove-ConfirmedFindings'
        }, $true))
        Assert-TestTrue -Condition ($removeCommands.Count -ge 1) `
            -Message 'The top-level removal command was not found for rescan-gate inspection.'
        $topLevelRemove = $removeCommands[$removeCommands.Count - 1]
        $postRemovalScans = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Get-360Findings'
        }, $true) | Where-Object {
            $_.Extent.StartOffset -gt $topLevelRemove.Extent.StartOffset
        })
        Assert-TestEqual -Expected 1 -Actual $postRemovalScans.Count `
            -Message 'The top-level flow must have exactly one possible post-removal discovery scan.'

        $rescanGuard = $postRemovalScans[0].Parent
        while ($null -ne $rescanGuard -and
            -not ($rescanGuard -is [System.Management.Automation.Language.IfStatementAst])) {
            $rescanGuard = $rescanGuard.Parent
        }
        Assert-TestNotNull -Actual $rescanGuard `
            -Message 'The post-removal Get-360Findings call is not guarded by an if statement.'
        $scanOffset = $postRemovalScans[0].Extent.StartOffset
        $scanIsInElse = $null -ne $rescanGuard.ElseClause -and
            $scanOffset -ge $rescanGuard.ElseClause.Extent.StartOffset -and
            $scanOffset -le $rescanGuard.ElseClause.Extent.EndOffset
        if ($scanIsInElse) {
            $conditionText = [string]$rescanGuard.Clauses[0].Item1.Extent.Text
            Assert-TestTrue -Condition ($conditionText -match '(?i)PostVendorMutationBlocked' -and
                $conditionText -notmatch '(?i)-not') `
                -Message 'The rescan else branch is not gated by the positive post-vendor block state.'
        }
        else {
            $matchingClause = @($rescanGuard.Clauses | Where-Object {
                $scanOffset -ge $_.Item2.Extent.StartOffset -and
                    $scanOffset -le $_.Item2.Extent.EndOffset
            })
            Assert-TestEqual -Expected 1 -Actual $matchingClause.Count `
                -Message 'The guarded post-removal scan branch could not be identified.'
            $conditionText = [string]$matchingClause[0].Item1.Extent.Text
            Assert-TestTrue -Condition ($conditionText -match '(?i)-not[\s\S]*PostVendorMutationBlocked' -or
                $conditionText -match '(?i)PostVendorMutationBlocked[\s\S]*(?:-eq\s*\$false|-ne\s*\$true)') `
                -Message 'The post-removal scan branch does not exclude the unsafe blocked state.'
        }
    }

    Invoke-TestCase -Run $run -Name 'success uses only the exact path fixed switch and fixed timeout before other mutations' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'success-order'
        $removeRoot = {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }.GetNewClosure()
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = $removeRoot
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathRemovals $pathRemovals
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot),
                (New-VendorProcessFinding)
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $vendorCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'StartVendorUninstaller')
        Assert-TestEqual -Expected 1 -Actual $vendorCalls.Count `
            -Message 'The exact approved vendor uninstaller was not started exactly once.'
        Assert-TestSequenceEqual -Expected @($fixture.VendorPath, '/uninstall:byUserName', 60000) `
            -Actual @($vendorCalls[0].Arguments) `
            -Message 'The provider did not receive only the literal exact path, fixed switch, and fixed timeout.'
        Assert-TestEqual -Expected 1 -Actual $fake.Context.VendorUninstallerStartedCallbacks `
            -Message 'The provider did not release the launch-boundary file handle exactly once.'

        $vendorIndex = Get-VendorCallIndex -Fake $fake -Operation 'StartVendorUninstaller'
        $processIndex = Get-VendorCallIndex -Fake $fake -Operation 'StopProcess'
        $removeIndex = Get-VendorCallIndex -Fake $fake -Operation 'RemovePath'
        Assert-TestTrue -Condition ($vendorIndex -ge 0 -and $processIndex -gt $vendorIndex -and $removeIndex -gt $vendorIndex) `
            -Message 'The vendor uninstaller did not run before process and path mutations.'
        $vendorAction = @($actions | Where-Object { $_.Action -eq 'RunVendorUninstaller' })
        Assert-TestEqual -Expected 1 -Actual $vendorAction.Count `
            -Message 'The vendor run action was not recorded exactly once.'
        Assert-TestEqual -Expected 'Success' -Actual $vendorAction[0].Result `
            -Message 'A successful vendor exit was not preserved.'
        Assert-TestEqual -Expected 1 -Actual $summary.VendorUninstallersSucceeded `
            -Message 'The successful vendor summary count is wrong.'
        Assert-TestEqual -Expected 0 -Actual $summary.VendorUninstallersFailed `
            -Message 'A successful vendor run was counted as failed.'
        Assert-TestEqual -Expected 0 -Actual $summary.VendorUninstallersPending `
            -Message 'A successful vendor run was counted as pending.'
    }

    Invoke-TestCase -Run $run -Name 'a vendor finding without its paired exact root approval never starts' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'missing-pair'
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath)
        $summary = [ordered]@{}
        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash)
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake `
            -Operation 'StartVendorUninstaller').Count `
            -Message 'A cropped approval without the exact dhpingbao root started the vendor executable.'
        Assert-TestTrue -Condition (@($actions | Where-Object {
            $_.Action -eq 'RunVendorUninstaller' -and $_.Result -ne 'Success'
        }).Count -eq 1) -Message 'The missing paired-root refusal was not recorded.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'A missing paired-root refusal did not require attention.'
    }

    Invoke-TestCase -Run $run -Name 'a changed approved non-path identity blocks vendor and every mutation at entry' -Test {
        foreach ($removalType in @('Service', 'Task', 'RegistryValue', 'RegistryKey')) {
            $caseName = 'approval-identity-mismatch-' + $removalType.ToLowerInvariant()
            $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName $caseName
            $resourceName = 'Windows360CleanerFixture-' + [Guid]::NewGuid().ToString('N')
            $pathRemovals = @{}
            $pathRemovals[$fixture.InstallRoot] = {
                param($Context, $Path)
                Remove-Item -LiteralPath $Path -Recurse -Force
            }
            $fakeArguments = @{
                UseRealPathReads = $true
                ProductEvidencePaths = @($fixture.VendorPath)
                TrustedDuohuiVendorPaths = @($fixture.VendorPath)
                PathRemovals = $pathRemovals
            }

            switch ($removalType) {
                'Service' {
                    $fakeArguments.Services = @([pscustomobject]@{
                        Name = $resourceName
                        PathName = ('"{0}" --service' -f (Join-Path $fixture.InstallRoot 'service.exe'))
                        StartName = 'LocalSystem'; ServiceType = 'Own Process'; StartMode = 'Auto'
                    })
                    $finding = New-VendorServiceFinding -Name $resourceName
                }
                'Task' {
                    $taskPath = '\Windows360CleanerTests\'
                    $fakeArguments.ScheduledTasks = @([pscustomobject]@{
                        TaskName = $resourceName; TaskPath = $taskPath
                        Actions = @([pscustomobject]@{
                            Execute = (Join-Path $fixture.InstallRoot 'task.exe')
                            Arguments = '--fixture'; WorkingDirectory = $fixture.InstallRoot
                        })
                    })
                    $finding = New-VendorTaskFinding -TaskName $resourceName -TaskPath $taskPath
                }
                'RegistryValue' {
                    $registryTarget = 'HKCU:\Software\Windows360CleanerTests\' + $resourceName
                    $registryValues = @{}
                    $registryValues[$registryTarget] = [pscustomobject]@{ FixtureValue = 'original' }
                    $fakeArguments.RegistryValues = $registryValues
                    $finding = New-VendorRegistryValueFinding -Target $registryTarget `
                        -ValueName 'FixtureValue'
                }
                'RegistryKey' {
                    $registryTarget = 'HKCU:\Software\Windows360CleanerTests\' + $resourceName
                    $registryValues = @{}
                    $registryValues[$registryTarget] = [pscustomobject]@{ FixtureValue = 'original' }
                    $registrySubKeys = @{}
                    $registrySubKeys[$registryTarget] = @()
                    $fakeArguments.RegistryValues = $registryValues
                    $fakeArguments.RegistrySubKeys = $registrySubKeys
                    $finding = New-VendorRegistryKeyFinding -Target $registryTarget
                }
            }

            $fake = New-Fake360CleanupRuntimeProvider @fakeArguments
            Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
            try {
                $identity = Get-360CleanupNonPathIdentityState $finding
                Assert-TestEqual -Expected 'Present' -Actual $identity.State `
                    -Message ("The {0} mismatch fixture was not readable." -f $removalType)
                Assert-TestTrue -Condition ([string]$identity.Fingerprint -cmatch '^[0-9A-F]{64}$') `
                    -Message ("The {0} mismatch fixture had no stable fingerprint." -f $removalType)
                $finding.IdentityFingerprint = if ($identity.Fingerprint -eq ('A1' * 32)) {
                    'B2' * 32
                }
                else { 'A1' * 32 }

                Assert-TestThrows -Operation {
                    [void](Remove-ConfirmedFindings -Findings @(
                        (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                        (New-VendorRootFinding -Target $fixture.InstallRoot),
                        $finding,
                        (New-VendorProcessFinding)
                    ) -Summary ([ordered]@{}))
                } -ExpectedMessagePattern ('(?i)Removal preflight could not match the approved ' + $removalType + ' identity') `
                    -Message ("A changed approved {0} identity did not fail before removal." -f $removalType)
            }
            finally {
                Reset-360CleanupRuntimeProvider
            }

            foreach ($operation in @(
                'StartVendorUninstaller', 'StopProcess', 'RemovePath', 'RepairPathAcl'
            )) {
                Assert-TestEqual -Expected 0 `
                    -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation $operation).Count `
                    -Message ("A changed approved {0} identity allowed {1}." -f $removalType, $operation)
            }
        }
    }

    Invoke-TestCase -Run $run -Name 'a registry residue removed by the successful vendor is already absent not failed' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'already-absent-residue'
        $registryTarget = 'HKCU:\Software\Windows360CleanerTests\' + [Guid]::NewGuid().ToString('N')
        $beforeStart = {
            param($Context, $FilePath, $ArgumentLine, $TimeoutMilliseconds)
            [void]$Context.RegistryPaths.Remove($registryTarget)
        }.GetNewClosure()
        $removeRoot = {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }.GetNewClosure()
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = $removeRoot
        $registryValues = @{}
        $registryValues[$registryTarget] = [pscustomobject]@{}
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ExistingRegistryPaths @($registryTarget) -RegistryValues $registryValues `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) `
            -PathRemovals $pathRemovals -BeforeVendorUninstallerStart $beforeStart
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $registryFinding = Set-VendorTestIdentityFingerprint `
                (New-VendorRegistryKeyFinding -Target $registryTarget)
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot),
                $registryFinding
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $registryAction = @($actions | Where-Object {
            $_.Action -eq 'DeleteRegistryKey' -and $_.Target -eq $registryTarget
        })
        Assert-TestEqual -Expected 1 -Actual $registryAction.Count `
            -Message 'The vendor-removed registry residue was not recorded exactly once.'
        Assert-TestEqual -Expected 'AlreadyAbsent' -Actual $registryAction[0].Result `
            -Message 'A registry residue already removed by the vendor was reported as failed or removed again.'
        Assert-TestEqual -Expected 0 -Actual $summary.RegistryKeysRemoved `
            -Message 'An already-absent registry residue inflated the removed-key count.'
        Assert-TestEqual -Expected 0 -Actual $summary.FailedActions `
            -Message 'An already-absent registry residue inflated the failed-action count.'
    }

    Invoke-TestCase -Run $run -Name 'a same-name service replacement after vendor start is never deleted' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'service-identity-change'
        $serviceName = 'Windows360CleanerFixture-' + [Guid]::NewGuid().ToString('N')
        $originalService = [pscustomobject]@{
            Name = $serviceName
            PathName = ('"{0}" --service' -f (Join-Path $fixture.InstallRoot 'original-service.exe'))
            StartName = 'LocalSystem'
            ServiceType = 'Own Process'
            StartMode = 'Auto'
        }
        $replacementService = [pscustomobject]@{
            Name = $serviceName
            PathName = ('"{0}" --service' -f (Join-Path $fixture.InstallRoot 'replacement-service.exe'))
            StartName = 'LocalSystem'
            ServiceType = 'Own Process'
            StartMode = 'Auto'
        }
        $beforeStart = {
            param($Context, $FilePath, $ArgumentLine, $TimeoutMilliseconds)
            $Context.ServiceItems = @($replacementService)
        }.GetNewClosure()
        $removeRoot = {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }.GetNewClosure()
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = $removeRoot
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -Services @($originalService) `
            -PathRemovals $pathRemovals -BeforeVendorUninstallerStart $beforeStart
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $serviceFinding = Set-VendorTestIdentityFingerprint `
                (New-VendorServiceFinding -Name $serviceName)
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot),
                $serviceFinding
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $serviceAction = @($actions | Where-Object {
            $_.Action -eq 'DeleteService' -and $_.Target -eq $serviceName
        })
        Assert-TestEqual -Expected 1 -Actual $serviceAction.Count `
            -Message 'The changed same-name service did not produce exactly one refusal action.'
        Assert-TestEqual -Expected 'Failed' -Actual $serviceAction[0].Result `
            -Message 'The changed same-name service was not failed closed.'
        Assert-TestTrue -Condition ([string]$serviceAction[0].Detail).StartsWith('ReasonCode=PostVendorIdentityChanged;') `
            -Message 'The service replacement refusal did not expose its stable reason code.'
        Assert-TestEqual -Expected 0 -Actual $summary.ServicesRemoved `
            -Message 'A changed same-name service was counted as removed.'
        Assert-TestTrue -Condition (@(Get-Fake360CleanupCalls -Fake $fake -Operation 'Services').Count -ge 2) `
            -Message 'The service identity was not freshly read after the vendor phase.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'A changed same-name service did not require attention.'
    }

    Invoke-TestCase -Run $run -Name 'a same-name task with reordered actions after vendor start is never deleted' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'task-identity-change'
        $taskName = 'Windows360CleanerFixture-' + [Guid]::NewGuid().ToString('N')
        $taskPath = '\Windows360CleanerTests\'
        $firstTaskExecutable = Join-Path $fixture.InstallRoot 'fixture-task-first.exe'
        $secondTaskExecutable = Join-Path $fixture.InstallRoot 'fixture-task-second.exe'
        $originalTask = [pscustomobject]@{
            TaskName = $taskName
            TaskPath = $taskPath
            Actions = @(
                [pscustomobject]@{
                    Execute = $firstTaskExecutable; Arguments = '--first'; WorkingDirectory = $fixture.InstallRoot
                },
                [pscustomobject]@{
                    Execute = $secondTaskExecutable; Arguments = '--second'; WorkingDirectory = $fixture.InstallRoot
                }
            )
        }
        $replacementTask = [pscustomobject]@{
            TaskName = $taskName
            TaskPath = $taskPath
            Actions = @(
                [pscustomobject]@{
                    Execute = $secondTaskExecutable; Arguments = '--second'; WorkingDirectory = $fixture.InstallRoot
                },
                [pscustomobject]@{
                    Execute = $firstTaskExecutable; Arguments = '--first'; WorkingDirectory = $fixture.InstallRoot
                }
            )
        }
        $beforeStart = {
            param($Context, $FilePath, $ArgumentLine, $TimeoutMilliseconds)
            $Context.ScheduledTaskItems = @($replacementTask)
        }.GetNewClosure()
        $removeRoot = {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }.GetNewClosure()
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = $removeRoot
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -ScheduledTasks @($originalTask) `
            -PathRemovals $pathRemovals -BeforeVendorUninstallerStart $beforeStart
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $taskFinding = Set-VendorTestIdentityFingerprint `
                (New-VendorTaskFinding -TaskName $taskName -TaskPath $taskPath)
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot),
                $taskFinding
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $taskTarget = $taskPath + $taskName
        $taskAction = @($actions | Where-Object {
            $_.Action -eq 'DeleteTask' -and $_.Target -eq $taskTarget
        })
        Assert-TestEqual -Expected 1 -Actual $taskAction.Count `
            -Message 'The reordered same-name task did not produce exactly one refusal action.'
        Assert-TestEqual -Expected 'Failed' -Actual $taskAction[0].Result `
            -Message 'The reordered same-name task was not failed closed.'
        Assert-TestTrue -Condition ([string]$taskAction[0].Detail).StartsWith('ReasonCode=PostVendorIdentityChanged;') `
            -Message 'The task replacement refusal did not expose its stable reason code.'
        Assert-TestEqual -Expected 0 -Actual $summary.ScheduledTasksRemoved `
            -Message 'A reordered same-name task was counted as removed.'
        Assert-TestTrue -Condition (@(Get-Fake360CleanupCalls -Fake $fake -Operation 'ScheduledTasks').Count -ge 2) `
            -Message 'The task identity was not freshly read after the vendor phase.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'A reordered same-name task did not require attention.'
    }

    Invoke-TestCase -Run $run -Name 'a registry value with changed byte content after vendor start is never deleted' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'registry-value-identity-change'
        $registryTarget = 'HKCU:\Software\Windows360CleanerTests\' + [Guid]::NewGuid().ToString('N')
        $valueName = 'FixtureBinary'
        $registryValues = @{}
        $registryValues[$registryTarget] = [pscustomobject]@{
            FixtureBinary = [byte[]](0x10, 0x20, 0x30)
        }
        $beforeStart = {
            param($Context, $FilePath, $ArgumentLine, $TimeoutMilliseconds)
            $Context.RegistryValuesByPath[$registryTarget] = [pscustomobject]@{
                FixtureBinary = [byte[]](0x10, 0x20, 0x31)
            }
        }.GetNewClosure()
        $removeRoot = {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }.GetNewClosure()
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = $removeRoot
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ExistingRegistryPaths @($registryTarget) -RegistryValues $registryValues `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathRemovals $pathRemovals `
            -BeforeVendorUninstallerStart $beforeStart
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $registryFinding = Set-VendorTestIdentityFingerprint `
                (New-VendorRegistryValueFinding -Target $registryTarget -ValueName $valueName)
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot),
                $registryFinding
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $registryActionTarget = $registryTarget + ' :: ' + $valueName
        $registryAction = @($actions | Where-Object {
            $_.Action -eq 'DeleteRegistryValue' -and $_.Target -eq $registryActionTarget
        })
        Assert-TestEqual -Expected 1 -Actual $registryAction.Count `
            -Message 'The changed byte[] registry value did not produce exactly one refusal action.'
        Assert-TestEqual -Expected 'Failed' -Actual $registryAction[0].Result `
            -Message 'The changed byte[] registry value was not failed closed.'
        Assert-TestTrue -Condition ([string]$registryAction[0].Detail).StartsWith('ReasonCode=PostVendorIdentityChanged;') `
            -Message 'The registry-value replacement refusal did not expose its stable reason code.'
        Assert-TestEqual -Expected 0 -Actual $summary.RegistryValuesRemoved `
            -Message 'A changed byte[] registry value was counted as removed.'
        Assert-TestTrue -Condition (@(Get-Fake360CleanupCalls -Fake $fake -Operation 'RegistryValues').Count -ge 2) `
            -Message 'The registry-value identity was not freshly read after the vendor phase.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'A changed byte[] registry value did not require attention.'
    }

    Invoke-TestCase -Run $run -Name 'Temp and root-outside vendor targets never execute' -Test {
        foreach ($caseName in @('temp-target', 'outside-target')) {
            $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName $caseName
            $invalidPath = if ($caseName -eq 'temp-target') {
                Join-Path $script:KnownFolders.Temp 'duohuipingbao\huabaosetup.exe'
            }
            else {
                Join-Path $script:KnownFolders.LocalAppData 'OtherProduct\huabaosetup.exe'
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $invalidPath) -Force | Out-Null
            [IO.File]::WriteAllText($invalidPath, ('INVALID-' + $caseName), (New-Object Text.UTF8Encoding($false)))
            $invalidHash = (Get-FileHash -LiteralPath $invalidPath -Algorithm SHA256).Hash
            $pathRemovals = @{}
            $pathRemovals[$fixture.InstallRoot] = { return $null }
            $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
                -ProductEvidencePaths @($fixture.VendorPath, $invalidPath) `
                -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathRemovals $pathRemovals
            $summary = [ordered]@{}

            Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
            try {
                $actions = @(Remove-ConfirmedFindings -Findings @(
                    (New-VendorTestFinding -Target $invalidPath -Hash $invalidHash),
                    (New-VendorRootFinding -Target $fixture.InstallRoot)
                ) -Summary $summary)
            }
            finally {
                Reset-360CleanupRuntimeProvider
            }

            Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake `
                -Operation 'StartVendorUninstaller').Count `
                -Message ("The {0} vendor target reached the start provider." -f $caseName)
            Assert-TestTrue -Condition (@($actions | Where-Object {
                $_.Action -eq 'RunVendorUninstaller' -and $_.Result -eq 'Failed'
            }).Count -eq 1) -Message ("The {0} vendor refusal was not recorded." -f $caseName)
        }
    }

    Invoke-TestCase -Run $run -Name 'a changed vendor hash fails immediately before provider startup' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'hash-change'
        [IO.File]::AppendAllText($fixture.VendorPath, '-CHANGED', (New-Object Text.UTF8Encoding($false)))
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = { throw 'A hash-changed vendor root must remain untouched.' }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathRemovals $pathRemovals
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot)
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake `
            -Operation 'StartVendorUninstaller').Count `
            -Message 'A vendor executable changed after scan approval reached the start provider.'
        Assert-TestTrue -Condition (@($actions | Where-Object {
            $_.Action -eq 'RunVendorUninstaller' -and $_.Result -eq 'Failed'
        }).Count -eq 1) -Message 'The launch-boundary hash mismatch was not recorded.'
        Assert-TestTrue -Condition (Test-Path -LiteralPath $fixture.InstallRoot) `
            -Message 'The related root was removed after the approved vendor hash changed.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'A launch-boundary hash mismatch did not require attention.'
    }

    Invoke-TestCase -Run $run -Name 'a vendor that loses trusted signer status after scan never starts' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'trust-change'
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = { return $null }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathRemovals $pathRemovals

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $scanned = @(Get-360Findings)
            $approvedVendor = @($scanned | Where-Object {
                $_.Kind -eq 'VendorUninstaller' -and $_.Confidence -eq 'Confirmed'
            })
            $approvedRoot = @($scanned | Where-Object {
                $_.RemovalType -eq 'Path' -and $_.Target -eq $fixture.InstallRoot
            })
            Assert-TestEqual -Expected 1 -Actual $approvedVendor.Count `
                -Message 'The trusted scan fixture did not produce one approved vendor finding.'
            Assert-TestEqual -Expected 1 -Actual $approvedRoot.Count `
                -Message 'The trusted scan fixture did not produce its paired root finding.'

            [void]$fake.Context.TrustedDuohuiVendorPaths.Remove($fixture.VendorPath)
            $summary = [ordered]@{}
            $actions = @(Remove-ConfirmedFindings -Findings @($approvedVendor[0], $approvedRoot[0]) `
                -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake `
            -Operation 'StartVendorUninstaller').Count `
            -Message 'A LocalAppData executable that lost trusted signer status was started.'
        Assert-TestTrue -Condition (@(Get-Fake360CleanupCalls -Fake $fake `
            -Operation 'IsTrustedDuohuiVendorFile').Count -ge 2) `
            -Message 'The trusted signer was not checked independently at scan and launch time.'
        Assert-TestTrue -Condition (@($actions | Where-Object {
            $_.Action -eq 'RunVendorUninstaller' -and $_.Result -eq 'Failed'
        }).Count -eq 1) -Message 'The launch-time trusted-signer failure was not recorded.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'A launch-time trusted-signer failure did not require attention.'
    }

    Invoke-TestCase -Run $run -Name 'a paired root that becomes a reparse point blocks vendor startup globally' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'pre-start-reparse'
        $pathItems = @{}
        $pathItems[$fixture.InstallRoot] = [pscustomobject]@{
            FullName = $fixture.InstallRoot
            Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
            PSIsContainer = $true
        }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathItems $pathItems

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            Assert-TestThrows -Operation {
                [void](Remove-ConfirmedFindings -Findings @(
                    (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                    (New-VendorRootFinding -Target $fixture.InstallRoot)
                ))
            } -Message 'A reparse-point paired root did not fail the global preflight.'
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake `
            -Operation 'StartVendorUninstaller').Count `
            -Message 'A reparse-point paired root reached the vendor start provider.'
        foreach ($operation in @('StopProcess', 'RemovePath', 'RepairPathAcl')) {
            Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation $operation).Count `
                -Message ("The reparse-point preflight allowed mutation through {0}." -f $operation)
        }
    }

    Invoke-TestCase -Run $run -Name 'a nonzero vendor exit is failed and requires attention' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'nonzero-exit'
        $vendorResult = [pscustomobject]@{
            Result = 'Failed'; ExitCode = 23; Detail = 'Fixture vendor exit code 23.'
        }
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = { return $null }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathRemovals $pathRemovals `
            -VendorUninstallerResult $vendorResult
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot)
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 1 -Actual @(Get-Fake360CleanupCalls -Fake $fake `
            -Operation 'StartVendorUninstaller').Count `
            -Message 'The nonzero-exit fixture did not reach the vendor provider exactly once.'
        $vendorAction = @($actions | Where-Object { $_.Action -eq 'RunVendorUninstaller' })
        Assert-TestEqual -Expected 'Failed' -Actual $vendorAction[0].Result `
            -Message 'A nonzero vendor exit was not recorded as failed.'
        Assert-TestEqual -Expected 1 -Actual $summary.VendorUninstallersFailed `
            -Message 'The failed vendor summary count is wrong.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'A nonzero vendor exit did not require attention.'
    }

    Invoke-TestCase -Run $run -Name 'a vendor timeout stays pending skips Duohui paths and continues independent work' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'timeout-pending'
        $tempDuohuiRoot = Get-NormalPath (Join-Path $script:KnownFolders.Temp 'duohuipingbao')
        $tempHuabaoRoot = Get-NormalPath (Join-Path $script:KnownFolders.Temp 'huabao_tmp')
        foreach ($relatedRoot in @($tempDuohuiRoot, $tempHuabaoRoot)) {
            New-Item -ItemType Directory -Path $relatedRoot -Force | Out-Null
            [IO.File]::WriteAllText(
                (Join-Path $relatedRoot 'isolated-marker.bin'),
                'ISOLATED-PENDING-ROOT',
                (New-Object Text.UTF8Encoding($false))
            )
        }
        $vendorResult = [pscustomobject]@{
            Result = 'Pending'; ExitCode = $null; Detail = 'Fixture timeout; process was not terminated.'
        }
        $relatedRegistry = 'HKCU:\Software\duohuipingbao'
        $registryValues = @{}
        $registryValues[$relatedRegistry] = [pscustomobject]@{}
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = { throw 'A pending vendor root must not be removed.' }
        $pathRemovals[$tempDuohuiRoot] = { throw 'A pending Duohui Temp root must not be removed.' }
        $pathRemovals[$tempHuabaoRoot] = { throw 'A pending Huabao Temp root must not be removed.' }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ExistingRegistryPaths @($relatedRegistry) -RegistryValues $registryValues `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathRemovals $pathRemovals `
            -VendorUninstallerResult $vendorResult
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $registryFinding = Set-VendorTestIdentityFingerprint `
                (New-VendorRegistryKeyFinding -Target $relatedRegistry)
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot),
                (New-VendorRootFinding -Target $tempDuohuiRoot),
                (New-VendorRootFinding -Target $tempHuabaoRoot),
                $registryFinding,
                (New-VendorProcessFinding -ProcessId 4343)
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 1 -Actual @(Get-Fake360CleanupCalls -Fake $fake `
            -Operation 'StartVendorUninstaller').Count `
            -Message 'The timeout fixture did not start the vendor provider exactly once.'
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RemovePath').Count `
            -Message 'A pending vendor run allowed its related dhpingbao root to be removed.'
        $processCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'StopProcess')
        Assert-TestEqual -Expected 1 -Actual $processCalls.Count `
            -Message 'Independent work did not continue after a pending vendor run.'
        Assert-TestEqual -Expected 4343 -Actual $processCalls[0].Arguments[0] `
            -Message 'The wrong process was handled after a pending vendor run.'
        Assert-TestTrue -Condition ((Get-VendorCallIndex -Fake $fake -Operation 'StartVendorUninstaller') -lt
            (Get-VendorCallIndex -Fake $fake -Operation 'StopProcess')) `
            -Message 'Independent work ran before the vendor-uninstaller attempt.'
        $vendorAction = @($actions | Where-Object { $_.Action -eq 'RunVendorUninstaller' })
        Assert-TestEqual -Expected 'Pending' -Actual $vendorAction[0].Result `
            -Message 'The timeout result was not preserved as pending.'
        Assert-TestEqual -Expected 1 -Actual $summary.VendorUninstallersPending `
            -Message 'The pending vendor summary count is wrong.'
        foreach ($relatedRoot in @($fixture.InstallRoot, $tempDuohuiRoot, $tempHuabaoRoot)) {
            Assert-TestTrue -Condition (Test-Path -LiteralPath $relatedRoot) `
                -Message ("A related Duohui path disappeared after a pending vendor run: $relatedRoot")
        }
        $relatedRegistryAction = @($actions | Where-Object {
            $_.Action -eq 'DeleteRegistryKey' -and $_.Target -eq $relatedRegistry
        })
        Assert-TestEqual -Expected 1 -Actual $relatedRegistryAction.Count `
            -Message 'The pending vendor did not preserve one related registry action.'
        Assert-TestEqual -Expected 'Skipped' -Actual $relatedRegistryAction[0].Result `
            -Message 'A related Duohui registry key was mutated while the vendor remained pending.'
        Assert-TestTrue -Condition ([string]$relatedRegistryAction[0].Detail).StartsWith('ReasonCode=VendorUninstallerPending;') `
            -Message 'The pending related-registry refusal did not expose its stable reason code.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'A pending vendor run did not require attention.'
    }

    Invoke-TestCase -Run $run -Name 'a successful exit with a fresh live Temp Duohui process is downgraded to pending' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'success-live-process'
        $tempHuabaoRoot = Get-NormalPath (Join-Path $script:KnownFolders.Temp 'huabao_tmp')
        New-Item -ItemType Directory -Path $tempHuabaoRoot -Force | Out-Null
        $liveProcess = [pscustomobject]@{
            Name = 'duohuipingbao.exe'
            ProcessId = 4545
            ExecutablePath = (Join-Path $tempHuabaoRoot 'duohuipingbao.exe')
        }
        $beforeStart = {
            param($Context, $FilePath, $ArgumentLine, $TimeoutMilliseconds)
            $Context.ProcessItems = @($liveProcess)
        }.GetNewClosure()
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = { throw 'A root with a live post-vendor process must not be removed.' }
        $pathRemovals[$tempHuabaoRoot] = { throw 'A Temp root with a live post-vendor process must not be removed.' }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathRemovals $pathRemovals `
            -BeforeVendorUninstallerStart $beforeStart
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot),
                (New-VendorRootFinding -Target $tempHuabaoRoot)
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $vendorAction = @($actions | Where-Object { $_.Action -eq 'RunVendorUninstaller' })
        Assert-TestEqual -Expected 1 -Actual $vendorAction.Count `
            -Message 'The live-process verification did not preserve one vendor action.'
        Assert-TestEqual -Expected 'Pending' -Actual $vendorAction[0].Result `
            -Message 'A vendor success with a live exact-root process was not downgraded to pending.'
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'StopProcess').Count `
            -Message 'The live process left by the vendor was forcibly stopped.'
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RemovePath').Count `
            -Message 'A related root was removed while the vendor process remained live.'
        foreach ($relatedRoot in @($fixture.InstallRoot, $tempHuabaoRoot)) {
            Assert-TestTrue -Condition (Test-Path -LiteralPath $relatedRoot) `
                -Message ("A related root disappeared while the vendor process remained live: $relatedRoot")
        }
        Assert-TestEqual -Expected 1 -Actual $summary.VendorUninstallersPending `
            -Message 'The live post-vendor process was not counted as pending.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'A live post-vendor process did not require attention.'
    }

    Invoke-TestCase -Run $run -Name 'post-vendor unsafe recheck returns evidence and blocks every later mutation' -Test {
        $fixture = New-VendorTestFixture -FixtureRoot $fixtureRoot -CaseName 'post-vendor-reparse'
        $rootItem = Get-Item -LiteralPath $fixture.InstallRoot -Force
        $pathItems = @{}
        $pathItems[$fixture.InstallRoot] = {
            param($Context, $Path)
            if (@($Context.PSObject.Properties.Name) -contains 'VendorWasStarted' -and
                [bool]$Context.VendorWasStarted) {
                return [pscustomobject]@{
                    FullName = $Path
                    Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
                    PSIsContainer = $true
                }
            }
            return $rootItem
        }.GetNewClosure()
        $beforeStart = {
            param($Context, $FilePath, $ArgumentLine, $TimeoutMilliseconds)
            Add-Member -InputObject $Context -NotePropertyName VendorWasStarted `
                -NotePropertyValue $true -Force
        }
        $pathRemovals = @{}
        $pathRemovals[$fixture.InstallRoot] = { throw 'Post-vendor global recheck must block removal.' }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($fixture.VendorPath) `
            -TrustedDuohuiVendorPaths @($fixture.VendorPath) -PathItems $pathItems `
            -PathRemovals $pathRemovals -BeforeVendorUninstallerStart $beforeStart
        $summary = [ordered]@{}

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $actions = @(Remove-ConfirmedFindings -Findings @(
                (New-VendorTestFinding -Target $fixture.VendorPath -Hash $fixture.Hash),
                (New-VendorRootFinding -Target $fixture.InstallRoot),
                (New-VendorProcessFinding -ProcessId 4444)
            ) -Summary $summary)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        Assert-TestEqual -Expected 1 -Actual @(Get-Fake360CleanupCalls -Fake $fake `
            -Operation 'StartVendorUninstaller').Count `
            -Message 'The post-vendor reparse fixture did not cross the vendor launch boundary.'
        Assert-TestEqual -Expected 1 -Actual $fake.Context.VendorUninstallerStartedCallbacks `
            -Message 'The vendor launch-boundary callback did not complete.'
        foreach ($operation in @('StopProcess', 'RemovePath', 'RepairPathAcl')) {
            Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $fake -Operation $operation).Count `
                -Message ("The post-vendor global gate allowed mutation through {0}." -f $operation)
        }
        Assert-TestTrue -Condition (@($actions | Where-Object {
            $_.Action -eq 'PostVendorPathPreflight' -and $_.Result -eq 'Failed'
        }).Count -ge 1) `
            -Message 'The post-vendor unsafe recheck did not return a visible failed action.'
        Assert-TestTrue -Condition ($summary.FailedActions -gt 0) `
            -Message 'The post-vendor unsafe recheck was not reflected in the summary.'
        Assert-TestTrue -Condition ([bool]$summary.PostVendorMutationBlocked) `
            -Message 'The post-vendor unsafe recheck did not preserve its global mutation gate.'
        Assert-TestFalse -Condition ([bool]$summary.ImmediateRescanComplete) `
            -Message 'A blocked post-vendor state falsely claimed that the immediate rescan completed.'
        Assert-TestNull -Actual $summary.ImmediateRemainingConfirmed `
            -Message 'A blocked post-vendor state fabricated a remaining-confirmed count.'
        Assert-TestFalse -Condition ([bool]$summary.NoImmediateConfirmedFindings) `
            -Message 'A blocked post-vendor state falsely claimed that no confirmed findings remained.'
        Assert-TestTrue -Condition (Test-RemovalOutcomeRequiresAttention -Summary $summary) `
            -Message 'The post-vendor unsafe recheck did not require attention.'
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
