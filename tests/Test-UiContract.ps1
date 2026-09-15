#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath = (Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1'),
    [string]$LibraryPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Contract tests: reports produced by the real core functions must be understood by the UI library.
$contractTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath
if ([string]::IsNullOrWhiteSpace($LibraryPath)) {
    $LibraryPath = Join-Path (Split-Path -Parent $CleanerScriptPath) 'Windows360Cleaner.Library.ps1'
}

# Expected version comes from the repository VERSION file so a documented version bump keeps tests valid.
$script:ExpectedToolVersion = ([IO.File]::ReadAllText([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $CleanerScriptPath) '..\VERSION')))).Trim()
$script:ContractSid = [string][Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function New-ContractCase {
    param(
        [string]$FixtureRoot,
        [string]$Name
    )

    $caseRoot = Join-Path $FixtureRoot ('契约 ' + $Name)
    $folders = [ordered]@{
        LocalAppData    = Join-Path $caseRoot '本地 应用数据'
        RoamingAppData  = Join-Path $caseRoot '漫游 应用数据'
        ProgramFiles    = Join-Path $caseRoot 'Program Files'
        ProgramFilesX86 = Join-Path $caseRoot 'Program Files (x86)'
        ProgramData     = Join-Path $caseRoot 'ProgramData'
        UserProfile     = Join-Path $caseRoot '用户 目录'
        Desktop         = Join-Path $caseRoot '用户 目录\桌面'
        Temp            = Join-Path $caseRoot '临时 文件'
        Windows         = Join-Path $caseRoot 'Windows'
    }
    foreach ($path in $folders.Values) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $script:KnownFolders = $folders
    $script:CurrentUserRegistryRoot = 'HKCU:'
    $duohuiRoot = Join-Path $folders.LocalAppData 'dhpingbao'
    $browserApplication = Join-Path $folders.RoamingAppData '360se6\Application'
    New-Item -ItemType Directory -Path $duohuiRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $duohuiRoot 'duohuipingbao.exe') -Value 'ISOLATED-DUOHUI'
    Set-Content -LiteralPath (Join-Path $duohuiRoot 'qcnethelp64.dll') -Value 'ISOLATED-DUOHUI-DLL'
    New-Item -ItemType Directory -Path $browserApplication -Force | Out-Null
    $browserExe = Join-Path $browserApplication '360se.exe'
    Set-Content -LiteralPath $browserExe -Value 'ISOLATED-BROWSER'
    $profile = Join-Path $folders.RoamingAppData '360se6\User Data'
    New-Item -ItemType Directory -Path $profile -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $profile 'Bookmarks') -Value 'KEEP-BOOKMARKS'
    return [pscustomobject]@{
        Root = $caseRoot; Folders = $folders; DuohuiRoot = $duohuiRoot
        BrowserApplication = $browserApplication; BrowserExe = $browserExe; BrowserProfile = $profile
        ReportDirectory = $folders.Desktop
    }
}

function Invoke-ContractScan {
    param(
        [object]$Case,
        [object]$Fake
    )

    Set-360CleanupRuntimeProvider -Provider $Fake.Provider -Context $Fake.Context
    try {
        $findings = @(Get-360Findings)
        $coverage = Get-360ScanCoverage
    }
    finally { Reset-360CleanupRuntimeProvider }
    $findings = @(Add-CleanupSelectionIds -Findings $findings -UserSid $script:ContractSid)
    $reportPath = New-W360ReportPath -Directory $Case.ReportDirectory -Kind 'scan'
    Save-CleanupReport -Path $reportPath -RunMode 'Scan' -Findings $findings -Actions @() `
        -ApprovalContext ([pscustomobject]@{ UserSid = $script:ContractSid }) -ScanCoverage $coverage
    return [pscustomobject]@{ Findings = $findings; Coverage = $coverage; ReportPath = $reportPath }
}

function Invoke-ContractRemoval {
    param(
        [object]$Case,
        [object]$Scan,
        [string[]]$SelectedIds,
        [scriptblock]$RemoveBehavior
    )

    $pathRemovals = @{}
    $pathRemovals[(Get-NormalPath $Case.DuohuiRoot)] = $RemoveBehavior
    $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($Case.BrowserExe) -PathRemovals $pathRemovals
    $hash = Get-W360FileSha256 -Path $Scan.ReportPath
    Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
    try {
        $current = @(Add-CleanupSelectionIds -Findings @(Get-360Findings) -UserSid $script:ContractSid)
        $comparison = Compare-ApprovedCleanupFindings -Approved $Scan.Findings -Current $current -SID $script:ContractSid
        $resolved = Resolve-CleanupSelection -Approved $Scan.Findings -Eligible @($comparison.Eligible) -Current $current `
            -SelectedIds $SelectedIds -UserSid $script:ContractSid -SelectionApplied $true
        $selection = New-360CleanupSelectionRecord -SelectionApplied $true -ApprovedReportPath $Scan.ReportPath `
            -ApprovedReportHash $hash -SelectedIds $SelectedIds -ResolvedSelection $resolved `
            -ApprovalComparison $comparison -UserSid $script:ContractSid
        $summary = [ordered]@{}
        $actions = @(Remove-ConfirmedFindings -Findings @($resolved.Eligible) -Summary $summary)
        $remaining = @(Add-CleanupSelectionIds -Findings @(Get-360Findings) -UserSid $script:ContractSid)
        $coverage = Get-360ScanCoverage
        $remainingSelected = Complete-360CleanupRemovalSummary -Summary $summary -ApprovalComparison $comparison `
            -ResolvedSelection $resolved -SelectionRecord $selection -SelectionApplied $true -RescanComplete $true `
            -RemainingFindings $remaining -UserSid $script:ContractSid -ApprovedReportHash $hash
    }
    finally { Reset-360CleanupRuntimeProvider }
    $reportPath = New-W360ReportPath -Directory $Case.ReportDirectory -Kind 'remove'
    Save-CleanupReport -Path $reportPath -RunMode 'Remove' -Findings $remaining -Actions $actions -Summary $summary `
        -ApprovalContext ([pscustomobject]@{ UserSid = $script:ContractSid }) -ApprovedReportHash $hash `
        -OutcomeRunId ([Guid]::NewGuid().ToString('N')) -ScanCoverage $coverage -Selection $selection
    $exitCode = if (Test-RemovalOutcomeRequiresAttention -Summary $summary -RemainingConfirmed $remainingSelected) { 2 } else { 0 }
    return [pscustomobject]@{
        ReportPath = $reportPath; Hash = $hash; ExitCode = $exitCode; Summary = $summary; Actions = $actions
        Fake = $fake; Preserved = @($resolved.UnselectedCurrent)
    }
}

function Invoke-ContractVerify {
    param(
        [object]$Case,
        [object]$Fake,
        [string]$RemoveReportPath
    )

    Set-360CleanupRuntimeProvider -Provider $Fake.Provider -Context $Fake.Context
    try {
        $findings = @(Add-CleanupSelectionIds -Findings @(Get-360Findings) -UserSid $script:ContractSid)
        $coverage = Get-360ScanCoverage
        $task = $null
        if (-not [string]::IsNullOrWhiteSpace($RemoveReportPath)) {
            $previous = Read-360CleanupPreviousRemoveReport -Path $RemoveReportPath -CurrentUserSid $script:ContractSid
            $task = Get-360CleanupTaskVerification -Previous $previous -CurrentFindings $findings -UserSid $script:ContractSid
        }
    }
    finally { Reset-360CleanupRuntimeProvider }
    $reportPath = New-W360ReportPath -Directory $Case.ReportDirectory -Kind 'verify'
    Save-CleanupReport -Path $reportPath -RunMode 'Verify' -Findings $findings -Actions @() -ScanCoverage $coverage `
        -TaskVerification $task -IncludeTaskVerification $true
    $exitCode = Get-360CleanupVerifyExitCode -Findings $findings -Coverage $coverage -TaskVerification $task
    return Get-W360VerifyOutcome -ExitCode $exitCode -ReportPath $reportPath
}

$run = New-TestRun -Name 'UI contract tests'
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
        if ($null -eq $previousTestMode) { Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:WINDOWS_360_CLEANER_TEST_MODE = $previousTestMode }
    }
    . ([IO.Path]::GetFullPath($LibraryPath))
    Set-W360UiLanguage -Language 'zh'

    $fixtureRoot = New-TestDirectory
    $originalKnownFolders = $script:KnownFolders
    $originalRegistryRoot = $script:CurrentUserRegistryRoot

    Invoke-TestCase -Run $run -Name 'contract test file uses the PowerShell 5.1 source contract' -Test {
        Assert-TestPowerShellFileContract -Path $contractTestPath
        Assert-TestPowerShellFileContract -Path $LibraryPath
        Assert-TestEqual -Expected $script:ToolVersion -Actual $script:W360ToolVersion `
            -Message 'The UI library and core report different tool versions.'
    }

    Invoke-TestCase -Run $run -Name 'a real Scan report is presented, grouped, and pre-checked by the UI library' -Test {
        $case = New-ContractCase -FixtureRoot $fixtureRoot -Name 'scan'
        $scan = Invoke-ContractScan -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $outcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $scan.ReportPath -StdoutLines @() -StderrLines @()
        Assert-TestEqual -Expected 'Findings' -Actual $outcome.State -Message 'A real scan report was not accepted.'
        Assert-TestEqual -Expected (Get-FileHash -LiteralPath $scan.ReportPath -Algorithm SHA256).Hash -Actual $outcome.ReportHash `
            -Message 'The UI bound the wrong Scan report hash.'

        $duohui = @($outcome.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.DuohuiRoot) })[0]
        $profile = @($outcome.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.BrowserProfile) })[0]
        Assert-TestEqual -Expected 'AwaitingChoice' -Actual (Get-W360FindingStatus -Finding $duohui).Code -Message 'A real Confirmed finding was not shown as awaiting choice.'
        Assert-TestEqual -Expected 'PersonalDataKept' -Actual (Get-W360FindingStatus -Finding $profile).Code -Message 'A real browser profile was not shown as personal data.'
        foreach ($finding in @($outcome.Findings)) {
            Assert-TestFalse -Condition ((Get-W360ReasonText -Finding $finding) -match '^原始判断依据') `
                -Message ("A real detector reason has no Chinese explanation: {0}" -f $finding.Reason)
        }
        $groups = @(Get-W360FindingGroups -Findings $outcome.Findings)
        Assert-TestEqual -Expected @($outcome.Findings).Count -Actual (@($groups | ForEach-Object { @($_.Findings) }).Count) `
            -Message 'Grouping lost or duplicated real findings.'
        Assert-TestTrue -Condition (@($groups | Where-Object { $_.Key -eq 'Duohui' }).Count -eq 1) -Message 'The real Duohui group is missing.'

        $plan = Get-W360SelectionPlan -Findings $outcome.Findings -SelectedIds @([string]$duohui.SelectionId)
        Assert-TestTrue -Condition ([bool]$plan.CanSubmit) -Message 'Selecting only the real Duohui root was blocked.'
        Assert-TestEqual -Expected 1 -Actual @($plan.PreservedFindings).Count -Message 'The UI did not report the kept browser before confirmation.'

        # Ticking a real product row selects only its deletable items and passes the selection plan unchanged.
        $browserGroup = @($groups | Where-Object { $_.Key -eq '360SafeBrowser' })[0]
        Assert-TestEqual -Expected '可以删除（1 项），1 项不删除' -Actual $browserGroup.DecisionText -Message 'The real browser row does not say what is deleted and what is kept.'
        $rowSelection = Get-W360DeletableSelection -Findings $outcome.Findings -CandidateIds @($browserGroup.SelectableIds) -SelectedIds @([string]$duohui.SelectionId)
        Assert-TestEqual -Expected 0 -Actual @($rowSelection.Removed).Count -Message 'The real browser row was shrunk without a reason.'
        Assert-TestEqual -Expected 2 -Actual @($rowSelection.Ids).Count -Message 'The Duohui root and the browser program were not both selected.'
        # The real profile has no SelectionId, so give a copy a well-formed one: it must still never be selectable.
        $profileWithId = $profile.PSObject.Copy()
        $profileWithId.SelectionId = ('C3' * 32)
        $withProfileCopy = @($outcome.Findings | Where-Object { -not [object]::ReferenceEquals($_, $profile) }) + @($profileWithId)
        $everyId = @($withProfileCopy | ForEach-Object { [string]$_.SelectionId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-TestTrue -Condition ($everyId -contains $profileWithId.SelectionId) -Message 'The profile copy must offer its SelectionId.'
        $everyRow = Get-W360DeletableSelection -Findings $withProfileCopy -CandidateIds $everyId
        Assert-TestFalse -Condition (@($everyRow.Ids) -contains $profileWithId.SelectionId) -Message 'The browser profile became selectable through select-all.'
        $everyPlan = Get-W360SelectionPlan -Findings $withProfileCopy -SelectedIds $everyId
        Assert-TestFalse -Condition ([bool]$everyPlan.CanSubmit) -Message 'A plan with the profile ID was accepted.'
        Assert-TestFalse -Condition (@($everyPlan.SelectedFindings | ForEach-Object { [string]$_.SelectionId }) -contains $profileWithId.SelectionId) `
            -Message 'The browser profile became a selected finding of the plan.'
        Assert-TestTrue -Condition ([bool](Get-W360SelectionPlan -Findings $outcome.Findings -SelectedIds @($rowSelection.Ids)).CanSubmit) `
            -Message 'A row selection from the helper did not pass the selection plan.'
        Assert-TestEqual -Expected 2 -Actual ([int]$outcome.DeletableGroupCount) -Message 'The real scan headline counts the wrong number of products.'
        Assert-TestEqual -Expected (Get-W360Text -Key 'Scan.Findings.Headline' -Arguments @(2)) -Actual $outcome.Headline -Message 'The real scan headline changed.'

        # The window and the agent offer only the effectively deletable items of the real report: exactly the shrink
        # result of every item the core rule allows, and never an item outside it.
        $realSelectable = @($outcome.Findings | Where-Object { Test-W360FindingSelectable -Finding $_ } | ForEach-Object { Get-W360FindingSelectionId -Finding $_ })
        $realShrink = Get-W360DeletableSelection -Findings $outcome.Findings -CandidateIds $realSelectable -SelectedIds @()
        Assert-TestNotNull -Actual $outcome.EffectiveDeletable -Message 'The real scan outcome does not carry the effective set.'
        Assert-TestSequenceEqual -Expected @($realShrink.Ids) -Actual @($outcome.EffectiveDeletable.Ids) -Message 'The real effective set is not the shrink result of every deletable item.'
        foreach ($id in @($outcome.EffectiveDeletable.Ids)) {
            Assert-TestTrue -Condition ($realSelectable -contains $id) -Message "The real effective set holds an item the core rule refuses: $id"
        }
        foreach ($group in $groups) {
            foreach ($id in @($group.SelectableIds)) {
                Assert-TestTrue -Condition ($outcome.EffectiveDeletable.IdSet.Contains([string]$id)) -Message "The real product row offers an item outside the effective set: $id"
            }
        }
        Assert-TestTrue -Condition ([bool](Get-W360SelectionPlan -Findings $outcome.Findings -SelectedIds @($outcome.EffectiveDeletable.Ids)).CanSubmit) `
            -Message 'The whole real effective set does not pass the selection plan.'
        Assert-TestEqual -Expected 'AwaitingChoice' -Actual (Get-W360FindingStatus -Finding $duohui -Effective $outcome.EffectiveDeletable).Code -Message 'The real Duohui root reads as kept.'

        # A real folder that holds a kept item: the core rule allows the folder, but it is shown as kept and never offered.
        $keptInside = [pscustomobject]@{
            Kind = 'Path'; Name = '360 temporary package'; Target = (Join-Path (Get-NormalPath $case.DuohuiRoot) 'cache\360setup.cab'); Confidence = 'ReviewOnly'
            Reason = 'Filename pattern matched, but a CAB name alone is not enough evidence for automatic deletion.'; RemovalType = 'None'; ValueName = ''
            IdentityFingerprint = ''; Offline = $false; ProductKey = 'Unattributed'; SelectionId = ''
        }
        $withKept = @($outcome.Findings) + @($keptInside)
        $keptEffective = Get-W360EffectiveDeletableIds -Findings $withKept
        Assert-TestTrue -Condition (Test-W360FindingSelectable -Finding $duohui) -Message 'The core rule changed for the real Duohui root.'
        Assert-TestFalse -Condition ($keptEffective.IdSet.Contains([string]$duohui.SelectionId)) -Message 'A real folder with a kept item inside is offered.'
        Assert-TestEqual -Expected '不删除：里面有要保留的东西' -Actual (Get-W360FindingStatus -Finding $duohui -Effective $keptEffective).Text -Message 'A real folder with a kept item inside does not say why it is kept.'
        $keptGroups = @(Get-W360FindingGroups -Findings $withKept -Effective $keptEffective)
        Assert-TestFalse -Condition (@($keptGroups | ForEach-Object { @($_.SelectableIds) }) -contains [string]$duohui.SelectionId) -Message 'A real product row offers the folder with a kept item inside.'
    }

    Invoke-TestCase -Run $run -Name 'real Remove reports map to Completed and NeedsRestart result pages' -Test {
        $case = New-ContractCase -FixtureRoot $fixtureRoot -Name 'remove states'
        $scan = Invoke-ContractScan -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $duohui = @($scan.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.DuohuiRoot) })[0]

        $taskPath = New-W360TaskRecord -Directory $case.ReportDirectory -ScanReportPath $scan.ReportPath `
            -ScanReportHash (Get-W360FileSha256 -Path $scan.ReportPath) `
            -RemoveReportPath (Join-Path $case.ReportDirectory 'planned.json') -SelectedFindings @($duohui) -PreservedFindings @()
        Assert-TestTrue -Condition (Test-Path -LiteralPath $taskPath) -Message 'The task record was not written.'

        $removal = Invoke-ContractRemoval -Case $case -Scan $scan -SelectedIds @([string]$duohui.SelectionId) -RemoveBehavior {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        $outcome = Get-W360RemoveOutcome -ExitCode $removal.ExitCode -ReportPath $removal.ReportPath `
            -ExpectedApprovedReportHash $removal.Hash -Events @() -StdoutLines @() -StderrLines @()
        Assert-TestEqual -Expected 0 -Actual $removal.ExitCode -Message 'The isolated removal needed attention.'
        Assert-TestEqual -Expected 'Completed' -Actual $outcome.State -Message 'A real completed removal was not shown as completed.'
        Assert-TestEqual -Expected 1 -Actual ([int]$outcome.Stats.Selected) -Message 'The selected count was not shown.'
        Assert-TestEqual -Expected 1 -Actual ([int]$outcome.Stats.Preserved) -Message 'The kept browser count was not shown.'
        Assert-TestEqual -Expected 1 -Actual ([int]$outcome.Stats.SelectedConfirmedAbsent) -Message 'The proven-removed count was not shown.'
        Assert-TestEqual -Expected 0 -Actual @($outcome.Problems).Count -Message 'A completed removal listed problems.'
        Assert-TestTrue -Condition (Test-Path -LiteralPath $case.BrowserApplication) -Message 'The unselected browser fixture was removed.'

        $lockedCase = New-ContractCase -FixtureRoot $fixtureRoot -Name 'remove locked'
        $lockedScan = Invoke-ContractScan -Case $lockedCase -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($lockedCase.BrowserExe))
        $lockedDuohui = @($lockedScan.Findings | Where-Object { $_.Target -eq (Get-NormalPath $lockedCase.DuohuiRoot) })[0]
        $locked = Invoke-ContractRemoval -Case $lockedCase -Scan $lockedScan -SelectedIds @([string]$lockedDuohui.SelectionId) -RemoveBehavior {
            param($Context, $Path)
            throw (New-Object IO.IOException('The process cannot access the file because it is being used by another process.'))
        }
        $lockedOutcome = Get-W360RemoveOutcome -ExitCode $locked.ExitCode -ReportPath $locked.ReportPath `
            -ExpectedApprovedReportHash $locked.Hash -Events @() -StdoutLines @() -StderrLines @() -SelectedFindings @($lockedDuohui)
        Assert-TestEqual -Expected 2 -Actual $locked.ExitCode -Message 'A locked removal did not require attention.'
        Assert-TestEqual -Expected 1 -Actual ([int]$locked.Summary.ImmediateRemainingSelected) -Message 'The locked selected target was not counted as remaining.'
        Assert-TestEqual -Expected 'NeedsRestart' -Actual $lockedOutcome.State -Message 'A locked file was not presented as needing a restart and verification.'
        Assert-TestTrue -Condition (@($lockedOutcome.Problems | Where-Object { $_.RestartMayHelp }).Count -ge 1) `
            -Message 'The locked target was not listed as a restart-resolvable problem.'
        Assert-TestTrue -Condition (@($lockedOutcome.Problems | Where-Object { $_.DisplayName -eq (Get-W360FindingDisplayName -Finding $lockedDuohui) }).Count -ge 1) `
            -Message 'The locked problem was not named after the selected Duohui folder.'
        Assert-TestEqual -Expected '' -Actual $lockedOutcome.CountsText `
            -Message 'A restart-needed page showed counts although the deletion is not finished.'
        Assert-TestEqual -Expected (Get-W360Text -Key 'Ui.Remove.Counts' -Arguments @(1, 0, 0)) -Actual $outcome.CountsText `
            -Message 'The real immediate check numbers of a completed removal were not shown as one counts line.'
        Assert-TestTrue -Condition ((@($lockedOutcome.NextSteps) -join ' ').Contains((Get-W360Text -Key 'Ui.Button.VerifyTask'))) `
            -Message 'The restart page does not name the button that checks the last deletion.'
        Assert-TestTrue -Condition (Test-Path -LiteralPath $lockedCase.DuohuiRoot) -Message 'The locked fixture disappeared.'

        $unknownSummary = Read-W360JsonFile -Path $removal.ReportPath
        $unknownSummary.Summary.ImmediateSelectedUnknown = 1
        $unknownSummary.Summary.ImmediateRemainingSelected = 1
        $unknownPath = New-W360ReportPath -Directory $case.ReportDirectory -Kind 'remove'
        [IO.File]::WriteAllText($unknownPath, ($unknownSummary | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $unknownOutcome = Get-W360RemoveOutcome -ExitCode 2 -ReportPath $unknownPath -ExpectedApprovedReportHash $removal.Hash `
            -Events @() -StdoutLines @() -StderrLines @()
        Assert-TestEqual -Expected 'Unknown' -Actual $unknownOutcome.State -Message 'An unconfirmed selected target was not shown as unknown.'
    }

    Invoke-TestCase -Run $run -Name 'after a restart the task record leads to a read-only verification with the kept browser' -Test {
        $case = New-ContractCase -FixtureRoot $fixtureRoot -Name 'restart verify'
        $scanFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe)
        $scan = Invoke-ContractScan -Case $case -Fake $scanFake
        $duohui = @($scan.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.DuohuiRoot) })[0]
        $browser = @($scan.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.BrowserApplication) })[0]
        $removal = Invoke-ContractRemoval -Case $case -Scan $scan -SelectedIds @([string]$duohui.SelectionId) -RemoveBehavior {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        [void](New-W360TaskRecord -Directory $case.ReportDirectory -ScanReportPath $scan.ReportPath -ScanReportHash $removal.Hash `
            -RemoveReportPath $removal.ReportPath -SelectedFindings @($duohui) -PreservedFindings @($browser))

        $taskInfo = Find-W360LatestTask -Directory $case.ReportDirectory
        Assert-TestNotNull -Actual $taskInfo -Message 'The latest task was not found after a restart.'
        $state = Get-W360TaskState -TaskInfo $taskInfo -LastBootTime ((Get-Date).AddMinutes(10))
        Assert-TestTrue -Condition ([bool]$state.RemoveReportValid) -Message ("The real Remove report was not accepted for the task: {0}" -f $state.RemoveReportIssue)
        Assert-TestTrue -Condition ($state.RestartedSinceRemove -eq $true) -Message 'The restart after cleanup was not recognised.'
        $notRestarted = Get-W360TaskState -TaskInfo $taskInfo -LastBootTime ((Get-Date).AddDays(-1))
        Assert-TestTrue -Condition ($notRestarted.RestartedSinceRemove -eq $false) -Message 'A boot before cleanup was reported as a restart.'

        $verifyFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe)
        $outcome = Invoke-ContractVerify -Case $case -Fake $verifyFake -RemoveReportPath ([string]$taskInfo.Record.RemoveReportPath)
        Assert-TestEqual -Expected 'TaskCompleted' -Actual $outcome.State -Message 'The acceptance example did not verify as completed in the UI.'
        Assert-TestEqual -Expected '上次选的都删干净了' -Actual $outcome.Headline -Message 'The completed verification headline changed.'
        Assert-TestTrue -Condition $outcome.Detail.Contains((Get-W360Text -Key 'Verify.TaskCompleted.PreservedKept')) `
            -Message 'The kept browser that is still present was not called normal.'
        Assert-TestEqual -Expected 'Success' -Actual (Get-W360OutcomeTone -Outcome $outcome) -Message 'A complete verification did not use the success tone.'
        Assert-TestEqual -Expected 1 -Actual @($outcome.Cleared).Count -Message 'The removed Duohui item was not listed as cleared.'
        Assert-TestEqual -Expected 1 -Actual @($outcome.Sections.Preserved).Count -Message 'The kept browser was not listed as preserved.'
        Assert-TestEqual -Expected 0 -Actual @($outcome.Sections.SelectedRemaining).Count -Message 'The kept browser was shown as a leftover.'
        Assert-TestEqual -Expected 0 -Actual @($outcome.Sections.NewOrChanged).Count -Message 'The kept browser was shown as new.'
        foreach ($operation in @('RemovePath', 'RepairPathAcl', 'StopProcess', 'StartVendorUninstaller', 'StartElevatedProcess')) {
            Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $verifyFake -Operation $operation).Count `
                -Message "UI verification reached the mutating operation $operation."
        }
    }

    Invoke-TestCase -Run $run -Name 'real Verify reports map to remaining, new, unknown, unavailable, and incomplete pages' -Test {
        $case = New-ContractCase -FixtureRoot $fixtureRoot -Name 'verify states'
        $scan = Invoke-ContractScan -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $duohui = @($scan.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.DuohuiRoot) })[0]
        $removal = Invoke-ContractRemoval -Case $case -Scan $scan -SelectedIds @([string]$duohui.SelectionId) -RemoveBehavior {
            param($Context, $Path)
            throw (New-Object IO.IOException('The process cannot access the file because it is being used by another process.'))
        }
        $remaining = Invoke-ContractVerify -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe)) `
            -RemoveReportPath $removal.ReportPath
        Assert-TestEqual -Expected 'TaskRemaining' -Actual $remaining.State -Message 'A leftover selected target was not shown as remaining.'
        Assert-TestEqual -Expected 1 -Actual @($remaining.Sections.SelectedRemaining).Count -Message 'The leftover was not listed in section 1.'

        Remove-Item -LiteralPath $case.DuohuiRoot -Recurse -Force
        $greenCore = Join-Path $case.Folders.RoamingAppData 'greencore'
        New-Item -ItemType Directory -Path $greenCore -Force | Out-Null
        $greenMarker = Join-Path $greenCore '360greencore.exe'
        Set-Content -LiteralPath $greenMarker -Value 'NEW'
        $newOutcome = Invoke-ContractVerify -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($case.BrowserExe, $greenMarker)) -RemoveReportPath $removal.ReportPath
        Assert-TestEqual -Expected 'TaskCompletedWithNew' -Actual $newOutcome.State -Message 'A new finding after cleanup was not surfaced.'
        Assert-TestEqual -Expected 1 -Actual @($newOutcome.Sections.NewOrChanged).Count -Message 'The new finding was not listed in section 3.'
        Assert-TestEqual -Expected 1 -Actual @($newOutcome.Sections.Preserved).Count -Message 'The kept browser disappeared from section 2.'

        $unknownFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe)
        $unknownFake.Provider['PathChildren'] = { param($Context, $Path) throw (New-Object UnauthorizedAccessException('Simulated denied listing.')) }
        $unknownOutcome = Invoke-ContractVerify -Case $case -Fake $unknownFake -RemoveReportPath $removal.ReportPath
        Assert-TestEqual -Expected 'TaskUnknown' -Actual $unknownOutcome.State -Message 'An unprovable absence was not shown as unknown.'
        Assert-TestTrue -Condition (@($unknownOutcome.Sections.Unknown).Count -ge 1) -Message 'The unknown item was not listed in section 4.'

        $oldReport = Read-W360JsonFile -Path $removal.ReportPath
        [void]$oldReport.PSObject.Properties.Remove('Selection')
        $oldPath = New-W360ReportPath -Directory $case.ReportDirectory -Kind 'remove'
        [IO.File]::WriteAllText($oldPath, ($oldReport | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $unavailable = Invoke-ContractVerify -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads) -RemoveReportPath $oldPath
        Assert-TestEqual -Expected 'TaskUnavailable' -Actual $unavailable.State -Message 'An old Remove report without a selection was not shown as unavailable.'

        $emptyCase = New-ContractCase -FixtureRoot $fixtureRoot -Name 'global incomplete'
        Remove-Item -LiteralPath $emptyCase.DuohuiRoot -Recurse -Force
        Remove-Item -LiteralPath (Split-Path -Parent $emptyCase.BrowserApplication) -Recurse -Force
        $incompleteFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads
        $incompleteFake.Provider['Services'] = { param($Context) throw 'Simulated service query failure.' }
        $incomplete = Invoke-ContractVerify -Case $emptyCase -Fake $incompleteFake -RemoveReportPath ''
        Assert-TestEqual -Expected 'GlobalIncomplete' -Actual $incomplete.State -Message 'No matches with incomplete checks was shown as clean.'
        $clean = Invoke-ContractVerify -Case $emptyCase -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads) -RemoveReportPath ''
        Assert-TestEqual -Expected 'GlobalClean' -Actual $clean.State -Message 'A clean complete global verification was not shown as clean.'
    }

    Invoke-TestCase -Run $run -Name 'a help summary from real reports is redacted, separate, and cannot approve removal' -Test {
        $case = New-ContractCase -FixtureRoot $fixtureRoot -Name 'help summary'
        $scan = Invoke-ContractScan -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $originalHash = (Get-FileHash -LiteralPath $scan.ReportPath -Algorithm SHA256).Hash
        $outcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $scan.ReportPath -StdoutLines @() `
            -StderrLines @(("Access denied: {0}\secret.txt for {1}" -f $case.Folders.UserProfile, $script:ContractSid))
        $context = New-W360RedactionContext
        $summary = New-W360HelpSummary -Stage 'Scan' -Outcome $outcome -ErrorText ("Failure under {0}" -f $case.Root) `
            -ReportPath $scan.ReportPath -Context $context

        Assert-TestTrue -Condition $summary.Contains($script:ExpectedToolVersion) -Message 'The help summary does not show the tool version.'
        Assert-TestFalse -Condition $summary.Contains($script:ContractSid) -Message 'The help summary leaked the user SID.'
        Assert-TestFalse -Condition ($summary -match [regex]::Escape($case.Root)) -Message 'The help summary leaked a private fixture path.'
        Assert-TestFalse -Condition ($summary -match '(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])') -Message 'The help summary leaked a selection identity.'
        $userName = [Environment]::UserName
        if ($userName.Length -ge 3) {
            Assert-TestFalse -Condition ($summary -match ('(?<![A-Za-z0-9_\-])' + [regex]::Escape($userName) + '(?![A-Za-z0-9_\-])')) `
                -Message 'The help summary leaked the Windows user name.'
        }
        $computerName = [Environment]::MachineName
        if ($computerName.Length -ge 3) {
            Assert-TestFalse -Condition ($summary -match ('(?<![A-Za-z0-9_\-])' + [regex]::Escape($computerName) + '(?![A-Za-z0-9_\-])')) `
                -Message 'The help summary leaked the computer name.'
        }

        $savedPath = Save-W360HelpSummary -Directory $case.ReportDirectory -Text $summary
        Assert-TestTrue -Condition ($savedPath -like '*.txt') -Message 'The help summary was not saved as a separate text file.'
        Assert-TestEqual -Expected $originalHash -Actual (Get-FileHash -LiteralPath $scan.ReportPath -Algorithm SHA256).Hash `
            -Message 'Creating a help summary changed the original Scan report.'
        Assert-TestThrows -Operation { [void](Read-ApprovedCleanupReport -Path $savedPath) } `
            -Message 'A redacted help summary was accepted as a removal approval.'
        $jsonCopy = [IO.Path]::ChangeExtension($savedPath, '.json')
        [IO.File]::WriteAllText($jsonCopy, $summary, (New-Object Text.UTF8Encoding($false)))
        Assert-TestThrows -Operation { [void](Read-ApprovedCleanupReport -Path $jsonCopy) } `
            -Message 'A help summary renamed to .json was accepted as a removal approval.'
    }

    Invoke-TestCase -Run $run -Name 'a newer cleanup attempt without a report does not hide the earlier cleanup that needs verification' -Test {
        $case = New-ContractCase -FixtureRoot $fixtureRoot -Name 'newest verifiable'
        $scan = Invoke-ContractScan -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $duohui = @($scan.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.DuohuiRoot) })[0]
        $removal = Invoke-ContractRemoval -Case $case -Scan $scan -SelectedIds @([string]$duohui.SelectionId) -RemoveBehavior {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        [void](New-W360TaskRecord -Directory $case.ReportDirectory -ScanReportPath $scan.ReportPath -ScanReportHash $removal.Hash `
            -RemoveReportPath $removal.ReportPath -SelectedFindings @($duohui) -PreservedFindings @())
        Start-Sleep -Milliseconds 30
        # A later attempt whose UAC prompt was declined: the task record exists but no Remove report was ever written.
        [void](New-W360TaskRecord -Directory $case.ReportDirectory -ScanReportPath $scan.ReportPath -ScanReportHash $removal.Hash `
            -RemoveReportPath (New-W360ReportPath -Directory $case.ReportDirectory -Kind 'remove') -SelectedFindings @($duohui) -PreservedFindings @())

        $latest = Find-W360LatestTask -Directory $case.ReportDirectory
        Assert-TestFalse -Condition ([bool](Get-W360TaskState -TaskInfo $latest -LastBootTime $null).RemoveReportValid) `
            -Message 'The fixture should make the newest record unusable.'
        $found = Find-W360LatestVerifiableTask -Directory $case.ReportDirectory -LastBootTime ((Get-Date).AddMinutes(5))
        Assert-TestNotNull -Actual $found -Message 'The earlier verifiable cleanup was hidden by a newer unfinished attempt.'
        Assert-TestEqual -Expected ([IO.Path]::GetFullPath($removal.ReportPath)) -Actual ([string]$found.TaskState.TaskInfo.Record.RemoveReportPath) `
            -Message 'The wrong task was chosen for verification.'
        Assert-TestEqual -Expected 1 -Actual ([int]$found.NewerUnusableCount) -Message 'The newer unfinished attempt was not counted.'
    }

    Invoke-TestCase -Run $run -Name 'result pages never promise what the reports cannot back' -Test {
        $case = New-ContractCase -FixtureRoot $fixtureRoot -Name 'honest wording'
        $scan = Invoke-ContractScan -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $duohui = @($scan.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.DuohuiRoot) })[0]
        $removal = Invoke-ContractRemoval -Case $case -Scan $scan -SelectedIds @([string]$duohui.SelectionId) -RemoveBehavior {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        $plain = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $removal.ReportPath -ExpectedApprovedReportHash $removal.Hash -Events @() -StdoutLines @() -StderrLines @()
        Assert-TestEqual -Expected 'Completed' -Actual $plain.State -Message 'The plain removal did not complete.'
        Assert-TestEqual -Expected (Get-W360Text -Key 'Remove.Completed.Detail' -Arguments @(1)) -Actual $plain.Detail -Message 'The plain completed detail changed.'
        Assert-TestEqual -Expected 1 -Actual ([int]$removal.Summary.ImmediatePreservedStillPresent) -Message 'The kept browser was not re-checked after cleaning.'

        $vendorReport = Read-W360JsonFile -Path $removal.ReportPath
        $vendorReport.Summary.VendorUninstallersSucceeded = 1
        $vendorPath = New-W360ReportPath -Directory $case.ReportDirectory -Kind 'remove'
        [IO.File]::WriteAllText($vendorPath, ($vendorReport | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $vendor = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $vendorPath -ExpectedApprovedReportHash $removal.Hash -Events @() -StdoutLines @() -StderrLines @()
        Assert-TestEqual -Expected (Get-W360Text -Key 'Remove.Completed.VendorRan') -Actual $vendor.Detail `
            -Message 'After a vendor uninstaller the page still claimed unticked items were untouched.'
        Assert-TestEqual -Expected 'Warning' -Actual (Get-W360OutcomeTone -Outcome $vendor) -Message 'A removal that ran a vendor uninstaller looked like a clean success.'
        Assert-TestEqual -Expected 'Success' -Actual (Get-W360OutcomeTone -Outcome $plain) -Message 'A plain real removal was not green.'

        $affectedReport = Read-W360JsonFile -Path $removal.ReportPath
        $affectedReport.Summary.ImmediatePreservedNotConfirmedPresent = 1
        $affectedPath = New-W360ReportPath -Directory $case.ReportDirectory -Kind 'remove'
        [IO.File]::WriteAllText($affectedPath, ($affectedReport | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $affected = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $affectedPath -ExpectedApprovedReportHash $removal.Hash -Events @() -StdoutLines @() -StderrLines @()
        Assert-TestTrue -Condition ($affected.Detail -eq (Get-W360Text -Key 'Remove.Completed.PreservedUnconfirmed' -Arguments @(1))) `
            -Message 'A kept item that changed after cleaning was not mentioned, or an uninstaller that never ran was blamed.'
        Assert-TestEqual -Expected 'Warning' -Actual (Get-W360OutcomeTone -Outcome $affected) -Message 'A removal with a kept item not seen afterwards looked like a clean success.'

        $noReport = Get-W360RemoveOutcome -ExitCode 1 -ReportPath (Join-Path $case.ReportDirectory 'never-written.json') -ExpectedApprovedReportHash $removal.Hash `
            -Events @([pscustomobject]@{ Phase = 'WaitingForElevation'; Detail = '' }, [pscustomobject]@{ Phase = 'ElevationFailed'; Detail = 'x' }) -StdoutLines @() -StderrLines @()
        Assert-TestEqual -Expected 'Unknown' -Actual $noReport.State -Message 'A failed elevation without a report must stay unknown.'
        Assert-TestFalse -Condition ((@($noReport.NextSteps) -join ' ').Contains((Get-W360Text -Key 'Ui.Button.VerifyTask'))) `
            -Message 'The no-report page pointed to a verify button that cannot appear for this run.'
        Assert-TestTrue -Condition ((@($noReport.NextSteps) -join ' ').Contains('重新检查')) `
            -Message 'The no-report page does not point to a new check of the PC.'
        Assert-TestEqual -Expected '' -Actual $noReport.CountsText -Message 'The no-report page showed counts.'
        Assert-TestFalse -Condition ((Get-W360OutcomeTone -Outcome $noReport) -eq 'Success') -Message 'An unknown removal used the success tone.'
        $cancelled = Get-W360RemoveOutcome -ExitCode 5 -ReportPath (Join-Path $case.ReportDirectory 'never-written-2.json') -ExpectedApprovedReportHash $removal.Hash `
            -Events @([pscustomobject]@{ Phase = 'WaitingForElevation'; Detail = '' }, [pscustomobject]@{ Phase = 'ElevationCancelled'; Detail = '' }) -StdoutLines @() -StderrLines @()
        Assert-TestEqual -Expected 'NotStarted' -Actual $cancelled.State -Message 'A declined administrator prompt was not shown as not started.'

        $globalFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe)
        $global = Invoke-ContractVerify -Case $case -Fake $globalFake -RemoveReportPath ''
        Assert-TestEqual -Expected 'GlobalRemaining' -Actual $global.State -Message 'The kept browser should still be identified globally.'
        Assert-TestEqual -Expected 0 -Actual @($global.Sections.NewOrChanged).Count -Message 'A global verify labelled current items as new.'
        Assert-TestEqual -Expected 1 -Actual @($global.Sections.CurrentIdentified).Count -Message 'The current item was not listed neutrally.'
    }

    Invoke-TestCase -Run $run -Name 'help summaries keep the real error and redact wrapped and non-ASCII network paths' -Test {
        $context = New-W360RedactionContext -UserName 'zhangsan' -UserDomain 'CORP' -ComputerName 'DESKTOP-9Z' -UserSid 'S-1-5-21-1-2-3-1001' `
            -PathTokens @([pscustomobject]@{ Path = 'C:\Users\zhangsan\OneDrive - Contoso Secret Holdings'; Token = '%OneDrive%' },
                [pscustomobject]@{ Path = 'C:\Users\zhangsan'; Token = '%USERPROFILE%' })
        $longStdout = @(1..45 | ForEach-Object { 'progress line ' + $_ })
        $wrapped = 'Approved cleanup report was not found: C:\Users\zhangsan\OneDrive - Contoso Secret Holdings\Desktop\360-cleanup-scan-20260913-1' +
            '00000-1a2b3c4d.json'
        $errorLines = @(
            'Remove failed: the approved report hash changed.',
            $wrapped.Substring(0, 120),
            $wrapped.Substring(120),
            'Access denied: \\张三的电脑\共享\合同\secret.docx',
            '    + CategoryInfo          : OperationStopped: (Approved cleanup report was not found: C:\Users\zhangsan\OneDrive - Contoso Secret',
            '   Holdings\Desktop\x.json:String) [], RuntimeException'
        )
        $outcome = [pscustomobject]@{
            State = 'Failed'; Headline = 'x'; Detail = ''; ErrorText = (Get-W360ErrorText -StderrLines $errorLines -StdoutLines $longStdout -IncludeStdout)
        }
        $summary = New-W360HelpSummary -Stage 'Error' -Outcome $outcome -ErrorText '' -ReportPath '' -Context $context
        Assert-TestTrue -Condition $summary.Contains('Remove failed: the approved report hash changed.') -Message 'The real error line was pushed out by program output.'
        foreach ($secret in @('Contoso', 'Secret Holdings', '张三的电脑', 'zhangsan', 'Holdings\Desktop')) {
            Assert-TestFalse -Condition $summary.Contains($secret) -Message "The help summary leaked: $secret"
        }
        Assert-TestTrue -Condition $summary.Contains((Get-W360Text -Key 'Redact.NetworkPath')) -Message 'The non-ASCII network path was not replaced.'
    }

    Invoke-TestCase -Run $run -Name 'a still-installed 360 program is explained as installed, not as missing evidence' -Test {
        $case = New-ContractCase -FixtureRoot $fixtureRoot -Name 'still installed'
        $uninstaller = Join-Path $case.Folders.ProgramFiles '360\360se6\uninst.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $uninstaller) -Force | Out-Null
        Set-Content -LiteralPath $uninstaller -Value 'SAMPLE'
        $root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        $keyPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\360se6'
        $subKeys = @{}
        $subKeys[$root] = @([pscustomobject]@{ PSPath = $keyPath; PSChildName = '360se6' })
        $values = @{}
        $values[$keyPath] = [pscustomobject]@{ DisplayName = '360安全浏览器'; Publisher = '360安全中心'; UninstallString = ('"{0}"' -f $uninstaller) }
        $scan = Invoke-ContractScan -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -RegistrySubKeys $subKeys -RegistryValues $values)
        $record = @($scan.Findings | Where-Object { $_.Kind -eq 'InstalledProduct' })
        Assert-TestEqual -Expected 1 -Actual $record.Count -Message 'The installed-program fixture was not detected.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $record[0].Confidence -Message 'A still-installed program record became removable.'
        Assert-TestEqual -Expected '360SafeBrowser' -Actual $record[0].ProductKey -Message 'The installed-program record lost its product.'
        Assert-TestEqual -Expected 'StillInstalled' -Actual (Get-W360FindingStatus -Finding $record[0]).Code `
            -Message 'A still-installed program was described as missing evidence.'
    }

    Invoke-TestCase -Run $run -Name 'texts built from real reports for the main window contain no banned words' -Test {
        $case = New-ContractCase -FixtureRoot $fixtureRoot -Name 'plain words'
        $scan = Invoke-ContractScan -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $scanOutcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $scan.ReportPath -StdoutLines @() -StderrLines @()
        $duohui = @($scan.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.DuohuiRoot) })[0]
        $locked = Invoke-ContractRemoval -Case $case -Scan $scan -SelectedIds @([string]$duohui.SelectionId) -RemoveBehavior {
            param($Context, $Path)
            throw (New-Object IO.IOException('The process cannot access the file because it is being used by another process.'))
        }
        $removeOutcome = Get-W360RemoveOutcome -ExitCode $locked.ExitCode -ReportPath $locked.ReportPath -ExpectedApprovedReportHash $locked.Hash `
            -Events @() -StdoutLines @() -StderrLines @() -SelectedFindings @($duohui)
        $verifyOutcome = Invoke-ContractVerify -Case $case -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe)) `
            -RemoveReportPath $locked.ReportPath

        $texts = New-Object System.Collections.Generic.List[string]
        foreach ($outcome in @($scanOutcome, $removeOutcome, $verifyOutcome)) {
            $texts.Add([string]$outcome.Headline)
            $texts.Add([string]$outcome.Detail)
            foreach ($step in @(Get-W360ArrayProperty -Object $outcome -Name 'NextSteps')) { $texts.Add([string]$step) }
        }
        foreach ($group in @(Get-W360FindingGroups -Findings $scanOutcome.Findings)) {
            foreach ($value in @($group.DisplayName, $group.Description, $group.DecisionText, $group.KeepReasonText)) { $texts.Add([string]$value) }
        }
        foreach ($finding in @($scanOutcome.Findings)) {
            $status = Get-W360FindingStatus -Finding $finding -Effective $scanOutcome.EffectiveDeletable
            foreach ($value in @($status.Text, $status.Explanation, (Get-W360FindingDisplayName -Finding $finding), (Get-W360FindingKindText -Finding $finding),
                    (Get-W360ImpactText -Finding $finding), (Get-W360ImpactText -Finding $finding -Effective $scanOutcome.EffectiveDeletable))) {
                $texts.Add([string]$value)
            }
        }
        $texts.Add([string]$removeOutcome.CountsText)
        foreach ($line in @(Get-W360RemoveProblemLines -Outcome $removeOutcome)) { $texts.Add($line) }
        foreach ($section in @($verifyOutcome.GridSections)) {
            $texts.Add([string]$section.Title)
            foreach ($item in @($section.Items)) {
                $texts.Add([string]$item.DisplayName)
                $texts.Add([string]$item.StateText)
                if (-not [string]::IsNullOrWhiteSpace([string]$item.DetailCode)) { $texts.Add([string]$item.Detail) }
            }
        }
        Assert-TestTrue -Condition ($texts.Count -ge 20) -Message 'Too few real main-window texts were collected.'
        Assert-TestTrue -Condition (@($verifyOutcome.GridSections).Count -ge 1) -Message 'The real verification produced no grid sections.'
        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($text in $texts) {
            foreach ($word in @(Get-W360MainUiBannedWords -Text $text -Language zh)) { $violations.Add(('{0} <- {1}' -f $word, $text)) }
        }
        Assert-TestEqual -Expected 0 -Actual $violations.Count -Message ("Banned words in real main-window texts:`r`n" + ($violations.ToArray() -join "`r`n"))
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
    if ($null -eq $previousTestMode) { Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue }
    else { $env:WINDOWS_360_CLEANER_TEST_MODE = $previousTestMode }
}
