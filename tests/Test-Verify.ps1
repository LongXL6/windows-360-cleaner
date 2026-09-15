#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath = (Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$verifyTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath

# Expected version comes from the repository VERSION file so a documented version bump keeps tests valid.
$script:ExpectedToolVersion = ([IO.File]::ReadAllText([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $CleanerScriptPath) '..\VERSION')))).Trim()
$script:VerifySid = 'S-1-5-21-111111111-222222222-333333333-1001'
$script:MutatingOperations = @('RemovePath', 'RepairPathAcl', 'StopProcess', 'StartVendorUninstaller', 'StartElevatedProcess')

function New-VerifyCase {
    param(
        [string]$FixtureRoot,
        [string]$Name
    )

    $caseRoot = Join-Path $FixtureRoot ('案例 ' + $Name)
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
    return [pscustomobject]@{
        Root               = $caseRoot
        Folders            = $folders
        DuohuiRoot         = $duohuiRoot
        DuohuiExe          = Join-Path $duohuiRoot 'duohuipingbao.exe'
        BrowserApplication = $browserApplication
        BrowserExe         = Join-Path $browserApplication '360se.exe'
        BrowserProfile     = Join-Path $folders.RoamingAppData '360se6\User Data'
        GreenCoreRoot      = Join-Path $folders.RoamingAppData 'greencore'
        ToolboxUpdater     = Join-Path $folders.LocalAppData 'winToolBox\winToolBoxSrv.exe'
    }
}

function Add-DuohuiFixture {
    param([object]$Case)

    New-Item -ItemType Directory -Path $Case.DuohuiRoot -Force | Out-Null
    Set-Content -LiteralPath $Case.DuohuiExe -Value 'ISOLATED-DUOHUI'
    Set-Content -LiteralPath (Join-Path $Case.DuohuiRoot 'qcnethelp64.dll') -Value 'ISOLATED-DUOHUI-DLL'
}

function Add-BrowserFixture {
    param([object]$Case)

    New-Item -ItemType Directory -Path $Case.BrowserApplication -Force | Out-Null
    Set-Content -LiteralPath $Case.BrowserExe -Value 'ISOLATED-BROWSER'
    New-Item -ItemType Directory -Path $Case.BrowserProfile -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Case.BrowserProfile 'Bookmarks') -Value 'KEEP-BOOKMARKS'
}

function Add-GreenCoreFixture {
    param([object]$Case)

    New-Item -ItemType Directory -Path $Case.GreenCoreRoot -Force | Out-Null
    $marker = Join-Path $Case.GreenCoreRoot '360greencore.exe'
    Set-Content -LiteralPath $marker -Value 'ISOLATED-GREENCORE'
    return $marker
}

function New-VerifyServiceItem {
    param(
        [string]$Name,
        [string]$Executable,
        [string]$StartMode = 'Auto'
    )

    return [pscustomobject]@{
        Name = $Name; PathName = ('"{0}" --run' -f $Executable)
        StartName = 'LocalSystem'; ServiceType = 'Own Process'; StartMode = $StartMode
    }
}

function Invoke-VerifyFixtureScan {
    param([object]$Fake)

    Set-360CleanupRuntimeProvider -Provider $Fake.Provider -Context $Fake.Context
    try {
        $findings = @(Get-360Findings)
        $coverage = Get-360ScanCoverage
    }
    finally { Reset-360CleanupRuntimeProvider }
    $findings = @(Add-CleanupSelectionIds -Findings $findings -UserSid $script:VerifySid)
    return [pscustomobject]@{ Findings = $findings; Coverage = $coverage }
}

function New-VerifyApprovalContext {
    param([string]$UserSid = $script:VerifySid)

    return [pscustomobject]@{
        UserSid      = $UserSid
        KnownFolders = [pscustomobject]$script:KnownFolders
        Options      = [pscustomobject]@{ IncludeBrowserProfiles = $false }
    }
}

function Write-VerifyRemoveReport {
    param(
        [string]$Path,
        [object[]]$Approved,
        [object[]]$CurrentAtRemoval,
        [string[]]$SelectedIds = @(),
        [bool]$SelectionApplied = $true,
        [string]$UserSid = $script:VerifySid
    )

    $comparison = Compare-ApprovedCleanupFindings -Approved $Approved -Current $CurrentAtRemoval -SID $UserSid
    $resolved = Resolve-CleanupSelection -Approved $Approved -Eligible @($comparison.Eligible) `
        -Current $CurrentAtRemoval -SelectedIds $SelectedIds -UserSid $UserSid -SelectionApplied $SelectionApplied
    $hash = 'A1' * 32
    $selection = New-360CleanupSelectionRecord -SelectionApplied $SelectionApplied `
        -ApprovedReportPath 'C:\测试 报告\scan.json' -ApprovedReportHash $hash -SelectedIds $SelectedIds `
        -ResolvedSelection $resolved -ApprovalComparison $comparison -UserSid $UserSid
    Save-CleanupReport -Path $Path -RunMode 'Remove' -Findings @() -Actions @() `
        -Summary ([ordered]@{ SelectionApplied = $SelectionApplied }) -ApprovalContext (New-VerifyApprovalContext -UserSid $UserSid) `
        -ApprovedReportHash $hash -OutcomeRunId ('B2' * 16) -Selection $selection
    return $selection
}

function Invoke-VerifyTask {
    param(
        [object]$Fake,
        [string]$RemoveReportPath,
        [string]$UserSid = $script:VerifySid
    )

    Set-360CleanupRuntimeProvider -Provider $Fake.Provider -Context $Fake.Context
    try {
        $findings = @(Get-360Findings)
        $coverage = Get-360ScanCoverage
        $findings = @(Add-CleanupSelectionIds -Findings $findings -UserSid $UserSid)
        $previous = Read-360CleanupPreviousRemoveReport -Path $RemoveReportPath -CurrentUserSid $UserSid
        $task = Get-360CleanupTaskVerification -Previous $previous -CurrentFindings $findings -UserSid $UserSid
    }
    finally { Reset-360CleanupRuntimeProvider }
    return [pscustomobject]@{
        Findings       = $findings
        Coverage       = $coverage
        Previous       = $previous
        Task           = $task
        ExitCode       = Get-360CleanupVerifyExitCode -Findings $findings -Coverage $coverage -TaskVerification $task
        GlobalExitCode = Get-360CleanupVerifyExitCode -Findings $findings -Coverage $coverage
    }
}

function Assert-NoMutatingCalls {
    param([object]$Fake)

    foreach ($operation in $script:MutatingOperations) {
        Assert-TestEqual -Expected 0 -Actual @(Get-Fake360CleanupCalls -Fake $Fake -Operation $operation).Count `
            -Message "Verification called the mutating runtime operation $operation."
    }
}

function Get-VerifyFinding {
    param(
        [object[]]$Findings,
        [string]$Target
    )

    return @($Findings | Where-Object { [string]$_.Target -eq (Get-NormalPath $Target) })
}

function Invoke-VerifyChildProcess {
    param([string]$ArgumentLine)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $CleanerScriptPath + '" ' + $ArgumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(240000)) {
        try { $process.Kill() } catch {}
        throw "The isolated child process did not finish in time: $ArgumentLine"
    }
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout   = $stdoutTask.Result
        Stderr   = $stderrTask.Result
    }
}

function Read-VerifyJson {
    param([string]$Path)

    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    return $utf8.GetString([IO.File]::ReadAllBytes($Path)) | ConvertFrom-Json
}

$run = New-TestRun -Name 'Verify tests'
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

    Invoke-TestCase -Run $run -Name 'verify test file uses the PowerShell 5.1 source contract' -Test {
        Assert-TestPowerShellFileContract -Path $verifyTestPath
        Assert-TestPowerShellFileContract -Path $CleanerScriptPath
        $versionLine = @(Get-Content -LiteralPath $CleanerScriptPath -Encoding UTF8 | Where-Object {
            $_ -ceq ("`$script:ToolVersion = '{0}'" -f $script:ExpectedToolVersion)
        })
        Assert-TestEqual -Expected 1 -Actual $versionLine.Count -Message 'The core must declare exactly one tool version constant.'
    }

    Invoke-TestCase -Run $run -Name 'product keys group findings without changing selection identity' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'product keys'
        Add-DuohuiFixture $case
        Add-BrowserFixture $case
        $runRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $registryValues = @{}
        $registryValues[$runRoot] = [pscustomobject]@{
            duohuipingbao = ('"{0}" /autorun' -f $case.DuohuiExe)
            Unrelated360Helper = 'C:\Unrelated\360helper.exe'
        }
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe) `
            -RegistryValues $registryValues
        $scan = Invoke-VerifyFixtureScan -Fake $fake

        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $browser = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.BrowserApplication)
        $profile = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.BrowserProfile)
        $startup = @($scan.Findings | Where-Object { $_.Kind -eq 'Startup' -and $_.ValueName -eq 'duohuipingbao' })
        $unrelated = @($scan.Findings | Where-Object { $_.Kind -eq 'Startup' -and $_.ValueName -eq 'Unrelated360Helper' })
        Assert-TestEqual -Expected 'Duohui' -Actual $duohui[0].ProductKey -Message 'The Duohui root was not grouped as Duohui.'
        Assert-TestEqual -Expected '360SafeBrowser' -Actual $browser[0].ProductKey -Message 'The 360se6 application was not grouped as 360 Secure Browser.'
        Assert-TestEqual -Expected '360SafeBrowser' -Actual $profile[0].ProductKey -Message 'The 360se6 profile was not grouped with its browser.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $startup[0].Confidence -Message 'The fixture startup value was not confirmed.'
        Assert-TestEqual -Expected 'Duohui' -Actual $startup[0].ProductKey -Message 'A startup value did not inherit the product of its confirmed root.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $unrelated[0].Confidence -Message 'A name-only startup match became removable.'
        Assert-TestEqual -Expected 'Unattributed' -Actual $unrelated[0].ProductKey -Message 'A name-only match guessed a product.'

        $withoutProductKey = $duohui[0] | Select-Object Kind, Name, Target, Confidence, Reason, RemovalType, ValueName, IdentityFingerprint, Offline
        Assert-TestEqual -Expected (Get-FindingSelectionId -Finding $withoutProductKey -UserSid $script:VerifySid) `
            -Actual $duohui[0].SelectionId -Message 'ProductKey changed the approval selection identity.'

        $expectedKeys = [ordered]@{
            '360安全卫士' = '360Security'; '360杀毒' = '360Security'; '360安全浏览器' = '360SafeBrowser'
            '360极速浏览器X' = '360ChromeXBrowser'; '360极速浏览器' = '360ChromeBrowser'; '360软件管家' = '360SoftMgr'
            '360压缩' = '360Zip'; '360驱动大师' = '360DriverMaster'; '多绘屏保' = 'Duohui'; '某个 奇虎 产品' = 'Unattributed'
        }
        foreach ($name in $expectedKeys.Keys) {
            Assert-TestEqual -Expected $expectedKeys[$name] -Actual (Get-360InstalledProductKey -DisplayName $name) `
                -Message "Installed-product grouping changed for $name."
        }
        Assert-TestEqual -Expected 'Duohui' -Actual (Get-360InstalledProductKey -DisplayName 'x' -IsExactDuohuiRecord $true) `
            -Message 'The exact Duohui uninstall record was not grouped as Duohui.'
    }

    Invoke-TestCase -Run $run -Name 'scan coverage is complete when every check succeeds' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'coverage complete'
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads
        $scan = Invoke-VerifyFixtureScan -Fake $fake
        Assert-TestTrue -Condition ([bool]$scan.Coverage.Complete) -Message 'A fully successful scan reported incomplete coverage.'
        Assert-TestEqual -Expected 0 -Actual @($scan.Coverage.Issues).Count -Message 'A fully successful scan reported coverage issues.'
        Assert-TestEqual -Expected 0 -Actual (Get-360CleanupVerifyExitCode -Findings $scan.Findings -Coverage $scan.Coverage) `
            -Message 'A clean complete global verification did not pass.'
    }

    Invoke-TestCase -Run $run -Name 'failed global queries are reported as incomplete instead of silently empty' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'coverage failed queries'
        Add-DuohuiFixture $case
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads
        $fake.Provider['ScheduledTasks'] = { param($Context) throw 'Simulated scheduled-task query failure.' }
        $fake.Provider['Services'] = { param($Context) throw 'Simulated service query failure.' }
        $fake.Provider['Processes'] = { param($Context) throw 'Simulated process query failure.' }
        $scan = Invoke-VerifyFixtureScan -Fake $fake

        Assert-TestFalse -Condition ([bool]$scan.Coverage.Complete) -Message 'Failed global queries were reported as complete coverage.'
        foreach ($area in @('ScheduledTasks', 'Services', 'Processes')) {
            Assert-TestEqual -Expected 1 -Actual @($scan.Coverage.Issues | Where-Object { $_.Area -eq $area }).Count `
                -Message "The failed $area query was not recorded exactly once."
        }
        Assert-TestEqual -Expected 1 -Actual @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot).Count `
            -Message 'Independent path findings were lost when a global query failed.'

        $emptyCase = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'coverage empty incomplete'
        $emptyFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads
        $emptyFake.Provider['Services'] = { param($Context) throw 'Simulated service query failure.' }
        $emptyScan = Invoke-VerifyFixtureScan -Fake $emptyFake
        Assert-TestEqual -Expected 0 -Actual @($emptyScan.Findings).Count -Message 'The empty incomplete fixture produced findings.'
        Assert-TestEqual -Expected 3 -Actual (Get-360CleanupVerifyExitCode -Findings $emptyScan.Findings -Coverage $emptyScan.Coverage) `
            -Message 'No matches with incomplete checks must not be reported as a passed verification.'
    }

    Invoke-TestCase -Run $run -Name 'a COM-handler scheduled task no longer hides later tasks from the scan' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'com handler task'
        Add-DuohuiFixture $case
        $taskPath = '\Windows360CleanerTests\'
        $comTask = [pscustomobject]@{
            TaskName = 'FixtureComHandlerTask'; TaskPath = $taskPath
            Actions = @([pscustomobject]@{ ClassId = '{00000000-0000-0000-0000-000000000000}'; Data = '' })
        }
        $targetTask = [pscustomobject]@{
            TaskName = 'SoftMgrUpdateFixture'; TaskPath = $taskPath
            Actions = @([pscustomobject]@{
                Execute = (Join-Path $case.DuohuiRoot 'update.exe'); Arguments = '--fixture'; WorkingDirectory = $case.DuohuiRoot
            })
        }
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ScheduledTasks @($comTask, $targetTask))
        $taskFinding = @($scan.Findings | Where-Object { $_.Kind -eq 'ScheduledTask' -and $_.Target -eq 'SoftMgrUpdateFixture' })
        Assert-TestEqual -Expected 1 -Actual $taskFinding.Count -Message 'A task after a COM-handler task was skipped.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $taskFinding[0].Confidence -Message 'The later target task was not confirmed.'
        Assert-TestEqual -Expected 'Duohui' -Actual $taskFinding[0].ProductKey -Message 'The later task did not inherit its root product.'
        Assert-TestTrue -Condition ([bool]$scan.Coverage.Complete) -Message 'A COM-handler action was reported as an incomplete check.'
    }

    Invoke-TestCase -Run $run -Name 'unreadable product evidence is recorded instead of looking like missing evidence' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'unreadable evidence'
        $product = Join-Path $case.Folders.RoamingAppData '360Safe'
        $locked = Join-Path $product '受限 子目录'
        New-Item -ItemType Directory -Path $locked -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $locked 'fixture.dll') -Value 'LOCKED-FIXTURE'
        $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($userSid,
            [Security.AccessControl.FileSystemRights]::ListDirectory, [Security.AccessControl.AccessControlType]::Deny)
        $acl = Get-Acl -LiteralPath $locked
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $locked -AclObject $acl
        try {
            $listingDenied = $false
            try { Get-ChildItem -LiteralPath $locked -Force -ErrorAction Stop | Out-Null }
            catch { $listingDenied = $true }
            Assert-TestTrue -Condition $listingDenied -Message 'The isolated deny-list ACL fixture did not take effect.'

            $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads
            $scan = Invoke-VerifyFixtureScan -Fake $fake
            $finding = @(Get-VerifyFinding -Findings $scan.Findings -Target $product)
            Assert-TestEqual -Expected 'ReviewOnly' -Actual $finding[0].Confidence `
                -Message 'An unreadable product folder became removable.'
            $issues = @($scan.Coverage.Issues | Where-Object { $_.Area -eq 'ProductEvidence' -and $_.Target -eq $product })
            Assert-TestEqual -Expected 1 -Actual $issues.Count `
                -Message 'An unreadable product-evidence folder was not recorded as an incomplete check.'
            Assert-TestFalse -Condition ([bool]$scan.Coverage.Complete) -Message 'Unreadable evidence was reported as complete coverage.'
        }
        finally {
            $restore = Get-Acl -LiteralPath $locked
            [void]$restore.RemoveAccessRule($rule)
            Set-Acl -LiteralPath $locked -AclObject $restore
        }
    }

    Invoke-TestCase -Run $run -Name 'acceptance: cleaning Duohui while keeping 360 Secure Browser verifies as completed' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'acceptance'
        Add-DuohuiFixture $case
        Add-BrowserFixture $case
        $scanFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe)
        $scan = Invoke-VerifyFixtureScan -Fake $scanFake
        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $browser = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.BrowserApplication)
        Assert-TestEqual -Expected 'Confirmed' -Actual $duohui[0].Confidence -Message 'The Duohui fixture was not confirmed.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $browser[0].Confidence -Message 'The browser fixture was not confirmed.'

        $removePath = Join-Path $case.Root '清理 结果.json'
        $selection = Write-VerifyRemoveReport -Path $removePath -Approved $scan.Findings -CurrentAtRemoval $scan.Findings `
            -SelectedIds @([string]$duohui[0].SelectionId)
        Assert-TestEqual -Expected 1 -Actual @($selection.SelectedTargets).Count -Message 'The selection record did not keep the chosen target.'
        Assert-TestEqual -Expected 1 -Actual @($selection.PreservedTargets).Count -Message 'The selection record did not keep the preserved browser.'

        # Simulate the approved removal inside the isolated fixture only.
        Remove-Item -LiteralPath $case.DuohuiRoot -Recurse -Force

        $verifyFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe)
        $result = Invoke-VerifyTask -Fake $verifyFake -RemoveReportPath $removePath
        $task = $result.Task
        Assert-TestEqual -Expected 'Completed' -Actual $task.Status -Message 'Keeping the browser made the Duohui cleanup task fail.'
        Assert-TestEqual -Expected 1 -Actual $task.Counts.SelectedAbsent -Message 'The removed Duohui target was not confirmed absent.'
        Assert-TestEqual -Expected 1 -Actual $task.Counts.PreservedPresent -Message 'The preserved browser was not reported as kept.'
        Assert-TestEqual -Expected '360SafeBrowser' -Actual $task.Preserved[0].ProductKey -Message 'The preserved item lost its product.'
        Assert-TestEqual -Expected 'Absent' -Actual $task.Selected[0].State -Message 'The selected item state is wrong.'
        Assert-TestEqual -Expected 'ProbeAbsent' -Actual $task.Selected[0].DetailCode -Message 'Absence was not proven by a direct probe.'
        Assert-TestEqual -Expected 0 -Actual $task.Counts.NewConfirmed -Message 'The preserved browser was misreported as a new finding.'
        Assert-TestEqual -Expected 0 -Actual $result.ExitCode -Message 'A completed task with a preserved target did not pass.'
        Assert-TestEqual -Expected 2 -Actual $result.GlobalExitCode `
            -Message 'The fixture no longer reproduces the old global-verify failure caused by the preserved browser.'
        Assert-NoMutatingCalls -Fake $verifyFake
        Assert-TestTrue -Condition (Test-Path -LiteralPath (Join-Path $case.BrowserProfile 'Bookmarks')) `
            -Message 'Browser profile fixture content changed.'

        $verifyReport = Join-Path $case.Root '复检 报告.json'
        Save-CleanupReport -Path $verifyReport -RunMode 'Verify' -Findings $result.Findings -Actions @() `
            -ScanCoverage $result.Coverage -TaskVerification $task -IncludeTaskVerification $true
        $roundTrip = Read-VerifyJson -Path $verifyReport
        Assert-TestEqual -Expected $script:ExpectedToolVersion -Actual ([string]$roundTrip.ToolVersion) -Message 'The verify report did not record the tool version.'
        Assert-TestEqual -Expected 1 -Actual @($roundTrip.TaskVerification.Selected).Count -Message 'Selected statuses were lost in JSON.'
        Assert-TestEqual -Expected 1 -Actual @($roundTrip.TaskVerification.Preserved).Count -Message 'Preserved statuses were lost in JSON.'
        Assert-TestTrue -Condition ($roundTrip.TaskVerification.Selected -is [array]) -Message 'A single selected status was not serialized as an array.'
        Assert-TestTrue -Condition ([bool]$roundTrip.ScanCoverage.Complete) -Message 'Coverage was not serialized.'
    }

    Invoke-TestCase -Run $run -Name 'a selected target that is still detected remains a cleanup problem' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'still detected'
        Add-DuohuiFixture $case
        Add-BrowserFixture $case
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $removePath = Join-Path $case.Root 'remove.json'
        [void](Write-VerifyRemoveReport -Path $removePath -Approved $scan.Findings -CurrentAtRemoval $scan.Findings `
            -SelectedIds @([string]$duohui[0].SelectionId))

        $result = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe)) `
            -RemoveReportPath $removePath
        Assert-TestEqual -Expected 'Remaining' -Actual $result.Task.Status -Message 'A still-present selected target did not fail the task.'
        Assert-TestEqual -Expected 'Remaining' -Actual $result.Task.Selected[0].State -Message 'The selected target state is wrong.'
        Assert-TestEqual -Expected 'DetectedSameIdentity' -Actual $result.Task.Selected[0].DetailCode -Message 'The detail code is wrong.'
        Assert-TestEqual -Expected 2 -Actual $result.ExitCode -Message 'A remaining selected target did not return exit code 2.'
    }

    Invoke-TestCase -Run $run -Name 'a selected path that changed or no longer matches is never reported as removed' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'changed path'
        Add-DuohuiFixture $case
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads)
        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $removePath = Join-Path $case.Root 'remove.json'
        $selection = Write-VerifyRemoveReport -Path $removePath -Approved $scan.Findings -CurrentAtRemoval $scan.Findings `
            -SelectedIds @([string]$duohui[0].SelectionId)

        # Partial cleanup: evidence files gone, directory still present and now review-only.
        Remove-Item -LiteralPath $case.DuohuiExe -Force
        $result = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads) -RemoveReportPath $removePath
        Assert-TestEqual -Expected 'Changed' -Actual $result.Task.Selected[0].State -Message 'A partially removed path was not reported as changed.'
        Assert-TestEqual -Expected 'DetectedDifferentIdentity' -Actual $result.Task.Selected[0].DetailCode -Message 'The changed detail code is wrong.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $result.Task.Selected[0].CurrentConfidence -Message 'The current confidence was not recorded.'
        Assert-TestEqual -Expected 'Remaining' -Actual $result.Task.Status -Message 'A changed selected target did not keep the task open.'

        # A recorded path that the detector no longer lists at all but still exists.
        New-Item -ItemType Directory -Path (Split-Path -Parent $case.ToolboxUpdater) -Force | Out-Null
        Set-Content -LiteralPath $case.ToolboxUpdater -Value 'UPDATER-STILL-HERE'
        $report = Read-VerifyJson -Path $removePath
        $report.Selection.SelectedTargets = @([pscustomobject]@{
            SelectionId = ('C3' * 32); Kind = 'Path'; Name = 'winToolBox updater linked to confirmed SoftMgr bundle'
            Target = $case.ToolboxUpdater; ValueName = ''; RemovalType = 'Path'; IdentityFingerprint = ''; ProductKey = 'WinToolBox360'
        })
        $editedPath = Join-Path $case.Root 'remove-updater.json'
        [IO.File]::WriteAllText($editedPath, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $updaterResult = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads) -RemoveReportPath $editedPath
        Assert-TestEqual -Expected 'Changed' -Actual $updaterResult.Task.Selected[0].State `
            -Message 'An undetected but existing selected path was treated as removed.'
        Assert-TestEqual -Expected 'PathPresentNotDetected' -Actual $updaterResult.Task.Selected[0].DetailCode `
            -Message 'The present-but-undetected path detail code is wrong.'
    }

    Invoke-TestCase -Run $run -Name 'a leftover service is Remaining even after its selection ID stops matching' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'service identity'
        Add-DuohuiFixture $case
        $serviceName = 'FixtureVerifySvc-' + [Guid]::NewGuid().ToString('N')
        $serviceExe = Join-Path $case.DuohuiRoot 'service.exe'
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -Services @((New-VerifyServiceItem -Name $serviceName -Executable $serviceExe)))
        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $service = @($scan.Findings | Where-Object { $_.Kind -eq 'Service' -and $_.Target -eq $serviceName })
        Assert-TestEqual -Expected 'Confirmed' -Actual $service[0].Confidence -Message 'The service fixture was not confirmed.'
        Assert-TestEqual -Expected 'Duohui' -Actual $service[0].ProductKey -Message 'The service did not inherit its root product.'
        $removePath = Join-Path $case.Root 'remove.json'
        [void](Write-VerifyRemoveReport -Path $removePath -Approved $scan.Findings -CurrentAtRemoval $scan.Findings `
            -SelectedIds @([string]$duohui[0].SelectionId, [string]$service[0].SelectionId))
        Remove-Item -LiteralPath $case.DuohuiRoot -Recurse -Force

        $sameService = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -Services @((New-VerifyServiceItem -Name $serviceName -Executable $serviceExe))) -RemoveReportPath $removePath
        $serviceStatus = @($sameService.Task.Selected | Where-Object { $_.Kind -eq 'Service' })
        Assert-TestEqual -Expected 0 -Actual @($sameService.Findings | Where-Object { $_.Kind -eq 'Service' }).Count `
            -Message 'The fixture should no longer detect the service after its root is gone.'
        Assert-TestEqual -Expected 'Remaining' -Actual $serviceStatus[0].State `
            -Message 'An undetected leftover service with the same identity was treated as removed.'
        Assert-TestEqual -Expected 'PresentNotDetected' -Actual $serviceStatus[0].DetailCode -Message 'The leftover service detail code is wrong.'
        Assert-TestEqual -Expected 'Remaining' -Actual $sameService.Task.Status -Message 'A leftover service did not keep the task open.'

        $changedService = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -Services @((New-VerifyServiceItem -Name $serviceName -Executable $serviceExe -StartMode 'Manual'))) -RemoveReportPath $removePath
        $changedStatus = @($changedService.Task.Selected | Where-Object { $_.Kind -eq 'Service' })
        Assert-TestEqual -Expected 'Changed' -Actual $changedStatus[0].State -Message 'A changed service identity was not reported as changed.'

        $goneService = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads) -RemoveReportPath $removePath
        Assert-TestEqual -Expected 'Completed' -Actual $goneService.Task.Status -Message 'A task whose service and root are gone did not complete.'
        Assert-TestEqual -Expected 2 -Actual $goneService.Task.Counts.SelectedAbsent -Message 'The gone service and root were not both proven absent.'

        # A leftover whose name still looks like 360 is listed as review-only: still not cleaned.
        $namedReport = Read-VerifyJson -Path $removePath
        $namedServiceName = '360FixtureVerifySvc-' + [Guid]::NewGuid().ToString('N')
        foreach ($record in @($namedReport.Selection.SelectedTargets | Where-Object { $_.Kind -eq 'Service' })) {
            $record.Target = $namedServiceName
            $record.Name = $namedServiceName
        }
        $namedPath = Join-Path $case.Root 'remove-named-service.json'
        [IO.File]::WriteAllText($namedPath, ($namedReport | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $namedService = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -Services @((New-VerifyServiceItem -Name $namedServiceName -Executable $serviceExe))) -RemoveReportPath $namedPath
        $namedStatus = @($namedService.Task.Selected | Where-Object { $_.Kind -eq 'Service' })
        Assert-TestEqual -Expected 'Changed' -Actual $namedStatus[0].State -Message 'A review-only leftover service was treated as removed.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $namedStatus[0].CurrentConfidence -Message 'The leftover service confidence was not recorded.'
        Assert-TestEqual -Expected 'Remaining' -Actual $namedService.Task.Status -Message 'A review-only leftover service did not keep the task open.'
    }

    Invoke-TestCase -Run $run -Name 'unreadable resources make the task Unknown instead of passed' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'unknown probe'
        Add-DuohuiFixture $case
        $serviceName = 'FixtureUnknownSvc-' + [Guid]::NewGuid().ToString('N')
        $serviceExe = Join-Path $case.DuohuiRoot 'service.exe'
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -Services @((New-VerifyServiceItem -Name $serviceName -Executable $serviceExe)))
        $service = @($scan.Findings | Where-Object { $_.Kind -eq 'Service' })
        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $removePath = Join-Path $case.Root 'remove.json'
        [void](Write-VerifyRemoveReport -Path $removePath -Approved $scan.Findings -CurrentAtRemoval $scan.Findings `
            -SelectedIds @([string]$duohui[0].SelectionId, [string]$service[0].SelectionId))
        Remove-Item -LiteralPath $case.DuohuiRoot -Recurse -Force

        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads
        $fake.Provider['Services'] = { param($Context) throw 'Simulated service query failure during verification.' }
        $result = Invoke-VerifyTask -Fake $fake -RemoveReportPath $removePath
        $serviceStatus = @($result.Task.Selected | Where-Object { $_.Kind -eq 'Service' })
        Assert-TestEqual -Expected 'Unknown' -Actual $serviceStatus[0].State -Message 'An unreadable service was not reported as unknown.'
        Assert-TestEqual -Expected 'QueryFailed' -Actual $serviceStatus[0].DetailCode -Message 'The unknown service detail code is wrong.'
        Assert-TestEqual -Expected 'Unknown' -Actual $result.Task.Status -Message 'An unknown selected target did not make the task unknown.'
        Assert-TestEqual -Expected 3 -Actual $result.ExitCode -Message 'An unknown task did not return exit code 3.'
        Assert-TestFalse -Condition ([bool]$result.Coverage.Complete) -Message 'The failed query was hidden from coverage.'
        Assert-NoMutatingCalls -Fake $fake
    }

    Invoke-TestCase -Run $run -Name 'new confirmed findings are reported separately from the finished task' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'new finding'
        Add-DuohuiFixture $case
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads)
        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $removePath = Join-Path $case.Root 'remove.json'
        [void](Write-VerifyRemoveReport -Path $removePath -Approved $scan.Findings -CurrentAtRemoval $scan.Findings `
            -SelectedIds @([string]$duohui[0].SelectionId))
        Remove-Item -LiteralPath $case.DuohuiRoot -Recurse -Force
        $marker = Add-GreenCoreFixture $case

        $result = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($marker)) `
            -RemoveReportPath $removePath
        Assert-TestEqual -Expected 'Completed' -Actual $result.Task.Status -Message 'A new unrelated finding changed the task verdict.'
        Assert-TestEqual -Expected 1 -Actual $result.Task.Counts.NewConfirmed -Message 'The new confirmed finding was hidden.'
        Assert-TestEqual -Expected 'GreenCore' -Actual $result.Task.New[0].ProductKey -Message 'The new finding lost its product.'
        Assert-TestEqual -Expected 4 -Actual $result.ExitCode -Message 'A completed task with new findings did not return exit code 4.'
    }

    Invoke-TestCase -Run $run -Name 'preserved targets that disappear do not fail the task' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'preserved absent'
        Add-DuohuiFixture $case
        Add-BrowserFixture $case
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $removePath = Join-Path $case.Root 'remove.json'
        [void](Write-VerifyRemoveReport -Path $removePath -Approved $scan.Findings -CurrentAtRemoval $scan.Findings `
            -SelectedIds @([string]$duohui[0].SelectionId))
        Remove-Item -LiteralPath $case.DuohuiRoot -Recurse -Force
        Remove-Item -LiteralPath $case.BrowserApplication -Recurse -Force

        $result = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads) -RemoveReportPath $removePath
        Assert-TestEqual -Expected 'Completed' -Actual $result.Task.Status -Message 'A preserved target that disappeared failed the task.'
        Assert-TestEqual -Expected 'Absent' -Actual $result.Task.Preserved[0].State -Message 'The disappeared preserved target state is wrong.'
        Assert-TestEqual -Expected 0 -Actual $result.ExitCode -Message 'A completed task with an absent preserved target did not pass.'
    }

    Invoke-TestCase -Run $run -Name 'missing, damaged, incompatible, old, or foreign reports are unavailable for task verification' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'unusable reports'
        Add-DuohuiFixture $case
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads)
        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $validPath = Join-Path $case.Root '有效 清理报告.json'
        [void](Write-VerifyRemoveReport -Path $validPath -Approved $scan.Findings -CurrentAtRemoval $scan.Findings `
            -SelectedIds @([string]$duohui[0].SelectionId))
        $utf8 = New-Object Text.UTF8Encoding($false)

        $damagedPath = Join-Path $case.Root 'damaged.json'
        [IO.File]::WriteAllText($damagedPath, '{ "SchemaVersion": 2, "Mode": ', $utf8)
        $futurePath = Join-Path $case.Root 'future.json'
        [IO.File]::WriteAllText($futurePath, '{ "SchemaVersion": 3, "Mode": "Remove" }', $utf8)
        $scanModePath = Join-Path $case.Root 'scan-mode.json'
        [IO.File]::WriteAllText($scanModePath, '{ "SchemaVersion": 2, "Mode": "Scan", "Findings": [] }', $utf8)
        $oldReport = Read-VerifyJson -Path $validPath
        [void]$oldReport.PSObject.Properties.Remove('Selection')
        $oldPath = Join-Path $case.Root 'old-version-remove.json'
        [IO.File]::WriteAllText($oldPath, ($oldReport | ConvertTo-Json -Depth 8), $utf8)
        $unboundReport = Read-VerifyJson -Path $validPath
        $unboundReport.Selection.ApprovedReportHash = 'D4' * 32
        $unboundPath = Join-Path $case.Root 'unbound.json'
        [IO.File]::WriteAllText($unboundPath, ($unboundReport | ConvertTo-Json -Depth 8), $utf8)
        $textPath = Join-Path $case.Root 'not-json.txt'
        [IO.File]::WriteAllText($textPath, 'NOT A REPORT', $utf8)

        $cases = @(
            @{ Path = (Join-Path $case.Root 'missing.json'); Reason = 'RemoveReportMissing'; Sid = $script:VerifySid },
            @{ Path = $damagedPath; Reason = 'RemoveReportUnreadable'; Sid = $script:VerifySid },
            @{ Path = $futurePath; Reason = 'RemoveReportIncompatible'; Sid = $script:VerifySid },
            @{ Path = $scanModePath; Reason = 'RemoveReportInvalid'; Sid = $script:VerifySid },
            @{ Path = $oldPath; Reason = 'SelectionNotRecorded'; Sid = $script:VerifySid },
            @{ Path = $unboundPath; Reason = 'RemoveReportInvalid'; Sid = $script:VerifySid },
            @{ Path = $textPath; Reason = 'RemoveReportInvalid'; Sid = $script:VerifySid },
            @{ Path = $validPath; Reason = 'DifferentUser'; Sid = 'S-1-5-21-999999999-888888888-777777777-1002' }
        )
        foreach ($item in $cases) {
            $previous = Read-360CleanupPreviousRemoveReport -Path $item.Path -CurrentUserSid $item.Sid
            Assert-TestFalse -Condition ([bool]$previous.Usable) -Message ("An unusable report was accepted: {0}" -f $item.Path)
            Assert-TestEqual -Expected $item.Reason -Actual $previous.Reason -Message ("Wrong unavailable reason for {0}." -f $item.Path)
            $task = Get-360CleanupTaskVerification -Previous $previous -CurrentFindings @() -UserSid $item.Sid
            Assert-TestEqual -Expected 'Unavailable' -Actual $task.Status -Message 'An unusable report produced a task verdict.'
            $cleanCoverage = [pscustomobject]@{ Complete = $true; Issues = @() }
            Assert-TestEqual -Expected 3 -Actual (Get-360CleanupVerifyExitCode -Findings @() -Coverage $cleanCoverage -TaskVerification $task) `
                -Message 'An unavailable task must never return a passing exit code.'
        }
        $validPrevious = Read-360CleanupPreviousRemoveReport -Path $validPath -CurrentUserSid $script:VerifySid
        Assert-TestTrue -Condition ([bool]$validPrevious.Usable) -Message 'A valid Chinese-named Remove report was rejected.'
        Assert-TestEqual -Expected (Get-FileHash -LiteralPath $validPath -Algorithm SHA256).Hash -Actual $validPrevious.Hash `
            -Message 'The previous report hash does not match its exact bytes.'
    }

    Invoke-TestCase -Run $run -Name 'the removal selection record keeps only deliberate choices and stays an array in JSON' -Test {
        $sid = $script:VerifySid
        $pathA = New-Finding -Kind 'Path' -Name 'Duohui screen saver' -Target 'C:\测试 夹具\本地\dhpingbao' -Confidence 'Confirmed' `
            -Reason 'fixture' -RemovalType 'Path' -ProductKey 'Duohui'
        $pathB = New-Finding -Kind 'Path' -Name '360se6 browser application' -Target 'C:\测试 夹具\漫游\360se6\Application' `
            -Confidence 'Confirmed' -Reason 'fixture' -RemovalType 'Path' -ProductKey '360SafeBrowser'
        $pathC = New-Finding -Kind 'Path' -Name 'GreenCore' -Target 'C:\测试 夹具\漫游\greencore' -Confidence 'Confirmed' `
            -Reason 'fixture' -RemovalType 'Path' -ProductKey 'GreenCore'
        $processFirst = New-Finding -Kind 'Process' -Name 'duohuipingbao.exe' -Target '100' -Confidence 'Confirmed' `
            -Reason 'fixture' -RemovalType 'Process' -ValueName 'C:\测试 夹具\本地\dhpingbao\duohuipingbao.exe' -ProductKey 'Duohui'
        $processSecond = New-Finding -Kind 'Process' -Name 'duohuipingbao.exe' -Target '200' -Confidence 'Confirmed' `
            -Reason 'fixture' -RemovalType 'Process' -ValueName 'C:\测试 夹具\本地\dhpingbao\duohuipingbao.exe' -ProductKey 'Duohui'
        $approved = @(Add-CleanupSelectionIds -Findings @($pathA, $pathB, $processFirst) -UserSid $sid)
        $current = @(Add-CleanupSelectionIds -Findings @(
            ($pathA | Select-Object *), ($pathB | Select-Object *), ($processFirst | Select-Object *),
            ($processSecond | Select-Object *), ($pathC | Select-Object *)) -UserSid $sid)
        $selectedIds = @([string]$approved[0].SelectionId, [string]$approved[2].SelectionId)
        $comparison = Compare-ApprovedCleanupFindings -Approved $approved -Current $current -SID $sid
        $resolved = Resolve-CleanupSelection -Approved $approved -Eligible @($comparison.Eligible) -Current $current `
            -SelectedIds $selectedIds -UserSid $sid -SelectionApplied $true
        $record = New-360CleanupSelectionRecord -SelectionApplied $true -ApprovedReportPath 'C:\测试 报告\scan.json' `
            -ApprovedReportHash ('A1' * 32) -SelectedIds $selectedIds -ResolvedSelection $resolved `
            -ApprovalComparison $comparison -UserSid $sid

        Assert-TestEqual -Expected 3 -Actual @($resolved.Eligible).Count -Message 'Both PIDs of the selected executable should be eligible.'
        Assert-TestEqual -Expected 2 -Actual @($record.SelectedTargets).Count -Message 'Selected process identities were not de-duplicated.'
        Assert-TestEqual -Expected 1 -Actual @($record.PreservedTargets).Count -Message 'Preserved targets must contain only deliberately unselected approved targets.'
        Assert-TestEqual -Expected '360SafeBrowser' -Actual $record.PreservedTargets[0].ProductKey -Message 'The wrong target was preserved.'
        Assert-TestEqual -Expected 1 -Actual @($record.UnapprovedTargets).Count -Message 'The unapproved new target was not recorded separately.'
        Assert-TestEqual -Expected 'GreenCore' -Actual $record.UnapprovedTargets[0].ProductKey -Message 'The wrong unapproved target was recorded.'

        $reportPath = Join-Path $fixtureRoot '选择 记录.json'
        Save-CleanupReport -Path $reportPath -RunMode 'Remove' -Findings @() -Actions @() -Summary ([ordered]@{}) `
            -ApprovalContext ([pscustomobject]@{ UserSid = $sid }) -ApprovedReportHash ('A1' * 32) -OutcomeRunId ('B2' * 16) -Selection $record
        $json = Read-VerifyJson -Path $reportPath
        Assert-TestTrue -Condition ($json.Selection.PreservedTargets -is [array]) -Message 'A single preserved target was not serialized as an array.'
        Assert-TestTrue -Condition ($json.Selection.UnapprovedTargets -is [array]) -Message 'A single unapproved target was not serialized as an array.'
        Assert-TestEqual -Expected 2 -Actual @($json.Selection.SelectedFindingIds).Count -Message 'Selected IDs were not recorded.'
    }

    Invoke-TestCase -Run $run -Name 'verification code paths contain no mutating operations' -Test {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($CleanerScriptPath, [ref]$tokens, [ref]$parseErrors)
        $forbidden = '(?i)\b(Remove-ConfirmedFindings|Remove-360CleanupPath|Repair-360CleanupPathAcl|Stop-360CleanupProcess|' +
            'Invoke-ApprovedDuohuiVendorUninstaller|Start-360CleanupVendorUninstaller|Invoke-360CleanupRemoveElevationBoundary|' +
            'Invoke-ElevatedCleanup|Remove-Item|Remove-ItemProperty|Unregister-ScheduledTask|Stop-Service|Stop-Process|Set-Acl|sc\.exe|takeown|icacls)\b'
        foreach ($name in @('Read-360CleanupPreviousRemoveReport', 'Get-360CleanupPathPresenceByListing', 'Get-360CleanupTargetProbe',
            'Get-360CleanupTargetStatus', 'Get-360CleanupTaskVerification', 'Get-360CleanupVerifyExitCode', 'Show-TaskVerification')) {
            $functionAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            Assert-TestNotNull -Actual $functionAst -Message "Verification function $name was not found."
            Assert-TestFalse -Condition ($functionAst.Body.Extent.Text -match $forbidden) `
                -Message "Verification function $name references a mutating operation."
        }
        $verifyBranch = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Clauses.Count -gt 0 -and $node.Clauses[0].Item1.Extent.Text -eq "`$Mode -eq 'Verify'"
        }, $true)
        Assert-TestNotNull -Actual $verifyBranch -Message 'The Verify branch was not found.'
        Assert-TestFalse -Condition ($verifyBranch.Extent.Text -match $forbidden) -Message 'The Verify branch references a mutating operation.'
    }

    Invoke-TestCase -Run $run -Name 'progress files follow the create-new naming contract and sanitize details' -Test {
        $progressDirectory = Join-Path $fixtureRoot '进度 文件'
        New-Item -ItemType Directory -Path $progressDirectory -Force | Out-Null
        $validPath = Join-Path $progressDirectory ('windows-360-cleaner-progress-' + ('a1' * 16) + '.log')
        Assert-TestTrue -Condition (Test-360CleanupProgressPathFormat $validPath) -Message 'A valid progress path was rejected.'
        foreach ($invalid in @(
            (Join-Path $progressDirectory ('windows-360-cleaner-progress-' + ('A1' * 16) + '.log')),
            (Join-Path $progressDirectory ('other-progress-' + ('a1' * 16) + '.log')),
            (Join-Path $progressDirectory ('windows-360-cleaner-progress-' + ('a1' * 16) + '.txt')),
            ('windows-360-cleaner-progress-' + ('a1' * 16) + '.log'),
            ('\\server\share\windows-360-cleaner-progress-' + ('a1' * 16) + '.log'),
            ''
        )) {
            Assert-TestFalse -Condition (Test-360CleanupProgressPathFormat $invalid) -Message "An invalid progress path was accepted: $invalid"
        }

        $stream = Open-360CleanupProgressFile $validPath
        Assert-TestNotNull -Actual $stream -Message 'A new valid progress file could not be created.'
        $script:ProgressStream = $stream
        try {
            Write-360CleanupProgress 'ScanStart' ("line one`r`nline two|" + ('x' * 400))
            Assert-TestNull -Actual (Open-360CleanupProgressFile $validPath) -Message 'An existing progress file was opened a second time.'
        }
        finally { Close-360CleanupProgressFile }
        $lines = @([IO.File]::ReadAllLines($validPath, (New-Object Text.UTF8Encoding($false))))
        Assert-TestEqual -Expected 1 -Actual $lines.Count -Message 'The progress file did not contain exactly one line.'
        $parts = $lines[0].Split('|')
        Assert-TestEqual -Expected 3 -Actual $parts.Count -Message 'A progress detail leaked a field separator.'
        Assert-TestEqual -Expected 'ScanStart' -Actual $parts[1] -Message 'The progress phase was not written.'
        Assert-TestTrue -Condition ($parts[2].Length -le 300 -and $parts[2].StartsWith('line one line two')) `
            -Message 'The progress detail was not sanitized and truncated.'

        $argumentLine = New-ElevatedCleanupArgumentLine -ScriptPath 'C:\测试 工具\Invoke-360Cleanup.ps1' `
            -ApprovedReport 'C:\扫描 报告\scan.json' -ApprovedReportHash ('A1' * 32) -OutcomeRunId ('B2' * 16) `
            -ReportPath 'C:\结果 报告\remove.json' -ElevatedProgressPath $validPath
        Assert-TestTrue -Condition $argumentLine.Contains(('-ElevatedProgressPath "{0}"' -f $validPath)) `
            -Message 'The elevated command line did not carry the quoted progress path.'
        Assert-TestThrows -Operation {
            [void](New-ElevatedCleanupArgumentLine -ScriptPath 'C:\x.ps1' -ApprovedReport 'C:\a.json' `
                -ApprovedReportHash ('A1' * 32) -OutcomeRunId ('B2' * 16) -ReportPath 'C:\b.json' `
                -ElevatedProgressPath 'C:\Windows\System32\drivers\etc\hosts')
        } -Message 'An arbitrary elevated progress path was accepted.'
    }

    Invoke-TestCase -Run $run -Name 'cancelled administrator approval is distinguishable and never reports success' -Test {
        $progressPath = Join-Path $fixtureRoot ('windows-360-cleaner-progress-' + ('c3' * 16) + '.log')
        foreach ($scenario in @(
            @{ Name = 'cancel'; Expected = 'ElevationCancelled'; Unexpected = 'ElevationFailed' },
            @{ Name = 'failure'; Expected = 'ElevationFailed'; Unexpected = 'ElevationCancelled' }
        )) {
            $fake = New-Fake360CleanupRuntimeProvider
            if ($scenario.Name -eq 'cancel') {
                $fake.Provider['StartElevatedProcess'] = {
                    param($Context, $FilePath, $ArgumentLine, $Hidden)
                    [void]$Context.Calls.Add([pscustomobject]@{ Operation = 'StartElevatedProcess'; Arguments = @($FilePath, $ArgumentLine, $Hidden) })
                    # Same shape as [Diagnostics.Process]::Start when the user declines the UAC prompt.
                    throw (New-Object Management.Automation.MethodInvocationException('Exception calling "Start" with "1" argument(s): "The operation was canceled by the user"',
                        (New-Object ComponentModel.Win32Exception(1223))))
                }
            }
            else {
                $fake.Provider['StartElevatedProcess'] = {
                    param($Context, $FilePath, $ArgumentLine, $Hidden)
                    [void]$Context.Calls.Add([pscustomobject]@{ Operation = 'StartElevatedProcess'; Arguments = @($FilePath, $ArgumentLine, $Hidden) })
                    throw 'Simulated elevation infrastructure failure.'
                }
            }
            $memory = New-Object IO.MemoryStream
            $script:ProgressStream = $memory
            Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
            try {
                $items = @(Invoke-ElevatedCleanup -ScriptPath $CleanerScriptPath `
                    -ApprovedReport (Join-Path $fixtureRoot 'approved.json') -ApprovedReportHash ('A1' * 32) `
                    -OutcomeRunId ('B2' * 16) -ReportPath (Join-Path $fixtureRoot ("elevation-{0}.json" -f $scenario.Name)) `
                    -ElevatedProgressPath $progressPath 2>&1 3>&1 6>&1)
            }
            finally {
                Reset-360CleanupRuntimeProvider
                $script:ProgressStream = $null
            }
            $exitCode = @($items | Where-Object { $_ -is [int] })[-1]
            Assert-TestEqual -Expected 5 -Actual $exitCode -Message "An elevation $($scenario.Name) did not return exit code 5."
            $progressText = (New-Object Text.UTF8Encoding($false)).GetString($memory.ToArray())
            Assert-TestTrue -Condition $progressText.Contains('|WaitingForElevation|') -Message 'The waiting-for-elevation phase was not reported.'
            Assert-TestTrue -Condition $progressText.Contains(('|{0}|' -f $scenario.Expected)) -Message "The $($scenario.Expected) phase was not reported."
            Assert-TestFalse -Condition $progressText.Contains(('|{0}|' -f $scenario.Unexpected)) -Message "The $($scenario.Unexpected) phase was reported."
            $calls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'StartElevatedProcess')
            Assert-TestEqual -Expected 1 -Actual $calls.Count -Message 'Elevation was attempted more than once.'
            Assert-TestTrue -Condition ([bool]$calls[0].Arguments[2]) -Message 'The guided-UI elevation did not request a hidden worker window.'
        }
    }

    Invoke-TestCase -Run $run -Name 'the default elevation start keeps the Win32 error that identifies a declined UAC prompt' -Test {
        $coreText = [IO.File]::ReadAllText($CleanerScriptPath, (New-Object Text.UTF8Encoding($false)))
        $startFunction = [regex]::Match($coreText, '(?s)function Start-360CleanupElevatedProcess \{.*?\r?\n\}\r?\n')
        Assert-TestTrue -Condition $startFunction.Success -Message 'The elevation start function was not found.'
        $codeLines = @($startFunction.Value -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' })
        Assert-TestFalse -Condition (@($codeLines | Where-Object { $_ -match '(?i)\bStart-Process\b' }).Count -gt 0) `
            -Message 'Start-Process drops the UAC cancel error on Windows PowerShell 5.1.'
        Assert-TestTrue -Condition ($startFunction.Value -match "Verb = 'runas'" -and $startFunction.Value -match '\[Diagnostics\.Process\]::Start') `
            -Message 'The elevation must use Process.Start with the runas verb.'

        # Real API shape: ShellExecute of a missing file fails before any prompt and keeps its Win32Exception.
        $missing = Join-Path $fixtureRoot ('missing-' + [Guid]::NewGuid().ToString('N') + '.exe')
        $realError = $null
        try {
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $missing
            $startInfo.UseShellExecute = $true
            $startInfo.Verb = 'runas'
            [void][Diagnostics.Process]::Start($startInfo)
        }
        catch { $realError = $_ }
        Assert-TestNotNull -Actual $realError -Message 'Starting a missing executable did not fail.'
        $inner = $realError.Exception
        $foundWin32 = $false
        while ($null -ne $inner) {
            if ($inner -is [ComponentModel.Win32Exception]) { $foundWin32 = $true }
            $inner = $inner.InnerException
        }
        Assert-TestTrue -Condition $foundWin32 -Message 'Process.Start did not keep the Win32Exception in the error chain.'
        Assert-TestFalse -Condition (Test-360CleanupElevationCancelled $realError) -Message 'A missing file was mistaken for a declined prompt.'

        $declined = New-Object Management.Automation.MethodInvocationException('Exception calling "Start"', (New-Object ComponentModel.Win32Exception(1223)))
        Assert-TestTrue -Condition (Test-360CleanupElevationCancelled $declined) -Message 'A declined UAC prompt from Process.Start was not recognised.'
        $messageOnly = New-Object InvalidOperationException('The operation was canceled by the user.')
        Assert-TestFalse -Condition (Test-360CleanupElevationCancelled $messageOnly) -Message 'A message-only exception must not be trusted as a declined prompt.'
    }

    Invoke-TestCase -Run $run -Name 'a non-administrator check never proves hidden tasks, services, or unreadable processes gone' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'limited visibility'
        Add-DuohuiFixture $case
        $taskPath = '\Windows360CleanerTests\'
        $serviceName = 'FixtureLimitedSvc-' + [Guid]::NewGuid().ToString('N')
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -Processes @(
                [pscustomobject]@{ Name = 'duohuipingbao.exe'; ProcessId = 4100; ExecutablePath = $case.DuohuiExe }) `
            -Services @((New-VerifyServiceItem -Name $serviceName -Executable (Join-Path $case.DuohuiRoot 'svc.exe'))) `
            -ScheduledTasks @([pscustomobject]@{
                TaskName = 'SoftMgrUpdateLimited'; TaskPath = $taskPath
                Actions = @([pscustomobject]@{ Execute = (Join-Path $case.DuohuiRoot 'update.exe'); Arguments = ''; WorkingDirectory = '' })
            }))
        $selectable = @($scan.Findings | Where-Object { [string]$_.SelectionId -match '^[0-9A-F]{64}$' })
        Assert-TestEqual -Expected 4 -Actual $selectable.Count -Message 'The limited-visibility fixture did not confirm root, process, service, and task.'
        $comparison = Compare-ApprovedCleanupFindings -Approved $scan.Findings -Current $scan.Findings -SID $script:VerifySid
        $selectedIds = @($selectable | ForEach-Object { [string]$_.SelectionId })
        $resolved = Resolve-CleanupSelection -Approved $scan.Findings -Eligible @($comparison.Eligible) -Current $scan.Findings `
            -SelectedIds $selectedIds -UserSid $script:VerifySid -SelectionApplied $true
        Remove-Item -LiteralPath $case.DuohuiRoot -Recurse -Force

        foreach ($scenario in @(
            @{ Name = 'elevated scan'; Elevated = $true; TaskState = 'Unknown'; ServiceState = 'Unknown'; ServiceKey = $true },
            @{ Name = 'elevated scan, service key gone'; Elevated = $true; TaskState = 'Unknown'; ServiceState = 'Absent'; ServiceKey = $false },
            @{ Name = 'non-elevated scan'; Elevated = $false; TaskState = 'Absent'; ServiceState = 'Absent'; ServiceKey = $true }
        )) {
            $selection = New-360CleanupSelectionRecord -SelectionApplied $true -ApprovedReportPath 'C:\fixture\scan.json' `
                -ApprovedReportHash ('A1' * 32) -SelectedIds $selectedIds -ResolvedSelection $resolved -ApprovalComparison $comparison `
                -UserSid $script:VerifySid -ApprovedScanElevated $scenario.Elevated
            Assert-TestEqual -Expected $scenario.Elevated -Actual $selection.ApprovedScanElevated -Message 'The selection record did not keep the scan elevation.'
            $existing = @()
            if ($scenario.ServiceKey) { $existing = @('HKLM:\SYSTEM\CurrentControlSet\Services\' + $serviceName) }
            $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -IsAdministrator $false -ExistingRegistryPaths $existing -Processes @(
                [pscustomobject]@{ Name = 'notepad.exe'; ProcessId = 50; ExecutablePath = 'C:\Windows\notepad.exe' })
            Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
            try {
                $task = Get-360CleanupTaskVerification -Previous (New-360CleanupPreviousReportState -Usable $true -Report ([pscustomobject]@{
                    Selection = $selection; Timestamp = ''; ToolVersion = ''; ApprovedReportHash = ('A1' * 32) })) `
                    -CurrentFindings @() -UserSid $script:VerifySid
            }
            finally { Reset-360CleanupRuntimeProvider }
            $taskStatus = @($task.Selected | Where-Object { $_.Kind -eq 'ScheduledTask' })[0]
            $serviceStatus = @($task.Selected | Where-Object { $_.Kind -eq 'Service' })[0]
            Assert-TestEqual -Expected $scenario.TaskState -Actual $taskStatus.State -Message ("Task state wrong for {0}." -f $scenario.Name)
            Assert-TestEqual -Expected $scenario.ServiceState -Actual $serviceStatus.State -Message ("Service state wrong for {0}." -f $scenario.Name)
            if ($scenario.Elevated) {
                Assert-TestEqual -Expected 'Unknown' -Actual $task.Status -Message 'A hidden task must keep the task result unknown.'
            }
        }

        $processSelection = New-360CleanupSelectionRecord -SelectionApplied $true -ApprovedReportPath 'C:\fixture\scan.json' `
            -ApprovedReportHash ('A1' * 32) -SelectedIds $selectedIds -ResolvedSelection $resolved -ApprovalComparison $comparison `
            -UserSid $script:VerifySid -ApprovedScanElevated $false
        $hiddenPathFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -Processes @(
            [pscustomobject]@{ Name = 'duohuipingbao.exe'; ProcessId = 4200; ExecutablePath = $null })
        Set-360CleanupRuntimeProvider -Provider $hiddenPathFake.Provider -Context $hiddenPathFake.Context
        try {
            $processTask = Get-360CleanupTaskVerification -Previous (New-360CleanupPreviousReportState -Usable $true -Report ([pscustomobject]@{
                Selection = $processSelection; Timestamp = ''; ToolVersion = ''; ApprovedReportHash = ('A1' * 32) })) `
                -CurrentFindings @() -UserSid $script:VerifySid
        }
        finally { Reset-360CleanupRuntimeProvider }
        $processStatus = @($processTask.Selected | Where-Object { $_.Kind -eq 'Process' })[0]
        Assert-TestEqual -Expected 'Unknown' -Actual $processStatus.State -Message 'A same-name process with an unreadable path was treated as gone.'
    }

    Invoke-TestCase -Run $run -Name 'reopening a kept browser after the restart is not a new finding' -Test {
        $case = New-VerifyCase -FixtureRoot $fixtureRoot -Name 'kept browser running'
        Add-DuohuiFixture $case
        Add-BrowserFixture $case
        $scan = Invoke-VerifyFixtureScan -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe))
        $duohui = @(Get-VerifyFinding -Findings $scan.Findings -Target $case.DuohuiRoot)
        $removePath = Join-Path $case.Root 'remove.json'
        [void](Write-VerifyRemoveReport -Path $removePath -Approved $scan.Findings -CurrentAtRemoval $scan.Findings `
            -SelectedIds @([string]$duohui[0].SelectionId))
        Remove-Item -LiteralPath $case.DuohuiRoot -Recurse -Force

        $result = Invoke-VerifyTask -Fake (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($case.BrowserExe) -Processes @(
                [pscustomobject]@{ Name = '360se.exe'; ProcessId = 7788; ExecutablePath = $case.BrowserExe })) -RemoveReportPath $removePath
        Assert-TestEqual -Expected 1 -Actual @($result.Findings | Where-Object { $_.Kind -eq 'Process' -and $_.Confidence -eq 'Confirmed' }).Count `
            -Message 'The fixture should detect the running kept browser.'
        Assert-TestEqual -Expected 'Completed' -Actual $result.Task.Status -Message 'The kept browser running again changed the task verdict.'
        Assert-TestEqual -Expected 0 -Actual $result.Task.Counts.NewConfirmed -Message 'The running kept browser was reported as new.'
        Assert-TestEqual -Expected 0 -Actual $result.ExitCode -Message 'The acceptance example must still pass while the kept browser is open.'
    }

    Invoke-TestCase -Run $run -Name 'real read-only scan emits progress and records version, coverage, and products' -Test {
        $reportPath = Join-Path $fixtureRoot '真实 只读 扫描.json'
        $result = Invoke-VerifyChildProcess ('-Mode Scan -EmitProgress -ReportPath "{0}"' -f $reportPath)
        Assert-TestEqual -Expected 0 -Actual $result.ExitCode -Message ("The read-only scan failed: {0}" -f $result.Stderr)
        foreach ($marker in @('W360-PROGRESS|ScanStart|', 'W360-PROGRESS|ScanServices|', 'W360-PROGRESS|ScanComplete|',
            'W360-PROGRESS|SavingReport|', 'W360-PROGRESS|Done|0')) {
            Assert-TestTrue -Condition $result.Stdout.Contains($marker) -Message "The read-only scan did not emit $marker"
        }
        $report = Read-VerifyJson -Path $reportPath
        Assert-TestEqual -Expected $script:ExpectedToolVersion -Actual ([string]$report.ToolVersion) -Message 'The scan report did not record the tool version.'
        Assert-TestTrue -Condition ($report.ScanCoverage.Complete -is [bool]) -Message 'The scan report did not record coverage.'
        foreach ($finding in @($report.Findings)) {
            Assert-TestFalse -Condition ([string]::IsNullOrWhiteSpace([string]$finding.ProductKey)) `
                -Message 'A real scan finding had no ProductKey.'
        }
    }

    Invoke-TestCase -Run $run -Name 'real Verify stays read-only and reports a missing previous report as unavailable' -Test {
        $reportPath = Join-Path $fixtureRoot '真实 复检 缺少任务.json'
        $missing = Join-Path $fixtureRoot '不存在的 清理报告.json'
        $result = Invoke-VerifyChildProcess ('-Mode Verify -EmitProgress -PreviousRemoveReport "{0}" -ReportPath "{1}"' -f $missing, $reportPath)
        Assert-TestTrue -Condition ($result.ExitCode -in @(2, 3)) -Message ("An unavailable task returned exit code {0}." -f $result.ExitCode)
        Assert-TestTrue -Condition $result.Stdout.Contains('W360-PROGRESS|VerifyReadingPreviousReport|') -Message 'Verify did not report reading the previous report.'
        $report = Read-VerifyJson -Path $reportPath
        Assert-TestEqual -Expected 'Verify' -Actual ([string]$report.Mode) -Message 'The verify report mode is wrong.'
        Assert-TestEqual -Expected 'Unavailable' -Actual ([string]$report.TaskVerification.Status) -Message 'A missing report produced a task verdict.'
        Assert-TestEqual -Expected 'RemoveReportMissing' -Actual ([string]$report.TaskVerification.UnavailableReason) -Message 'The unavailable reason is wrong.'
        Assert-TestEqual -Expected 0 -Actual @($report.Actions).Count -Message 'Verify recorded an action.'
    }

    Invoke-TestCase -Run $run -Name 'real Verify with a recorded task verifies the task separately from global findings' -Test {
        $currentSid = [string][Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $removedTarget = Join-Path $fixtureRoot '已经 删除 的目标'
        $removePath = Join-Path $fixtureRoot '真实 复检 任务.json'
        $hash = 'E5' * 32
        $report = [pscustomobject]@{
            SchemaVersion = 2; ToolVersion = '1.0.0'; Timestamp = '2026-09-13T10:00:00.0000000+08:00'
            ComputerName = $null; User = $null; Mode = 'Remove'
            ApprovalContext = [pscustomobject]@{ UserSid = $currentSid }
            ApprovedReportHash = $hash; OutcomeRunId = ('F6' * 16); Summary = [pscustomobject]@{}; ScanCoverage = $null
            Selection = [pscustomobject]@{
                SelectionApplied = $true; ApprovedReportPath = 'C:\fixture\scan.json'; ApprovedReportHash = $hash
                SelectedFindingIds = @(('C3' * 32))
                SelectedTargets = @([pscustomobject]@{
                    SelectionId = ('C3' * 32); Kind = 'Path'; Name = 'Isolated removed target'; Target = $removedTarget
                    ValueName = ''; RemovalType = 'Path'; IdentityFingerprint = ''; ProductKey = 'Duohui'
                })
                PreservedTargets = @(); UnapprovedTargets = @()
            }
            Findings = @(); Actions = @()
        }
        [IO.File]::WriteAllText($removePath, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $verifyPath = Join-Path $fixtureRoot '真实 复检 结果.json'
        $result = Invoke-VerifyChildProcess ('-Mode Verify -PreviousRemoveReport "{0}" -ReportPath "{1}"' -f $removePath, $verifyPath)
        Assert-TestTrue -Condition ($result.ExitCode -in @(0, 3, 4)) -Message ("A completed task returned exit code {0}. {1}" -f $result.ExitCode, $result.Stderr)
        $verify = Read-VerifyJson -Path $verifyPath
        Assert-TestEqual -Expected 'Completed' -Actual ([string]$verify.TaskVerification.Status) -Message 'The recorded task was not verified as completed.'
        Assert-TestEqual -Expected 1 -Actual ([int]$verify.TaskVerification.Counts.SelectedAbsent) -Message 'The absent task target was not proven absent.'
        $globalConfirmed = @($verify.Findings | Where-Object { $_.Confidence -eq 'Confirmed' }).Count
        Assert-TestEqual -Expected $globalConfirmed -Actual ([int]$verify.TaskVerification.Counts.NewConfirmed) `
            -Message 'Global confirmed findings outside the task were not surfaced as new findings.'
    }

    Invoke-TestCase -Run $run -Name 'elevated worker errors reach the progress file before any removal work' -Test {
        $progressPath = Join-Path $fixtureRoot ('windows-360-cleaner-progress-' + ('d4' * 16) + '.log')
        $reportPath = Join-Path $fixtureRoot 'elevated-worker-error.json'
        # -ConfirmRemoval is deliberately omitted so the worker must stop at parameter validation.
        $result = Invoke-VerifyChildProcess ('-Mode Remove -InternalElevatedChild -ElevatedProgressPath "{0}" -ApprovedReport "{1}" -ApprovedReportHash {2} -OutcomeRunId {3} -ReportPath "{4}"' -f `
            $progressPath, (Join-Path $fixtureRoot 'missing-approved.json'), ('A1' * 32), ('B2' * 16), $reportPath)
        Assert-TestEqual -Expected 1 -Actual $result.ExitCode -Message 'The invalid elevated worker did not fail.'
        Assert-TestFalse -Condition (Test-Path -LiteralPath $reportPath) -Message 'The invalid elevated worker wrote a report.'
        $lines = @([IO.File]::ReadAllLines($progressPath, (New-Object Text.UTF8Encoding($false))))
        Assert-TestTrue -Condition (@($lines | Where-Object { $_ -match '\|ElevatedStarted\|' }).Count -eq 1) -Message 'The worker start was not recorded.'
        Assert-TestTrue -Condition (@($lines | Where-Object { $_ -match '\|Error\|.*ConfirmRemoval' }).Count -eq 1) `
            -Message 'The worker failure reason was not recorded in the progress file.'
        Assert-TestEqual -Expected 0 -Actual @($lines | Where-Object { $_ -match '\|(Preflight|Removing|Scan)' }).Count `
            -Message 'The invalid worker reached scan or removal phases.'
    }

    Invoke-TestCase -Run $run -Name 'Scan and Remove reject verification-only and progress-only parameters' -Test {
        $scanReport = Join-Path $fixtureRoot 'rejected-scan.json'
        $scanResult = Invoke-VerifyChildProcess ('-Mode Scan -PreviousRemoveReport "{0}" -ReportPath "{1}"' -f (Join-Path $fixtureRoot 'x.json'), $scanReport)
        Assert-TestTrue -Condition ($scanResult.ExitCode -ne 0 -and ($scanResult.Stderr + $scanResult.Stdout).Contains('PreviousRemoveReport is valid only for Verify mode')) `
            -Message 'Scan accepted a previous Remove report.'
        Assert-TestFalse -Condition (Test-Path -LiteralPath $scanReport) -Message 'A rejected Scan wrote a report.'
        $verifyReport = Join-Path $fixtureRoot 'rejected-verify.json'
        $progressPath = Join-Path $fixtureRoot ('windows-360-cleaner-progress-' + ('e5' * 16) + '.log')
        $verifyResult = Invoke-VerifyChildProcess ('-Mode Verify -ElevatedProgressPath "{0}" -ReportPath "{1}"' -f $progressPath, $verifyReport)
        Assert-TestTrue -Condition ($verifyResult.ExitCode -ne 0 -and ($verifyResult.Stderr + $verifyResult.Stdout).Contains('ElevatedProgressPath is valid only for Remove mode')) `
            -Message 'Verify accepted an elevated progress path.'
        Assert-TestFalse -Condition (Test-Path -LiteralPath $progressPath) -Message 'A rejected Verify created a progress file.'
    }

    Complete-TestRun -Run $run
}
finally {
    if ($libraryLoaded) {
        Reset-360CleanupRuntimeProvider
        $script:ProgressStream = $null
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
