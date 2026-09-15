#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath,
    [string]$SelectorPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# $PSScriptRoot can be empty inside param defaults under Windows PowerShell 5.1 -File, so resolve here.
$layoutTestRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($CleanerScriptPath)) {
    $CleanerScriptPath = Join-Path $layoutTestRoot '..\scripts\Invoke-360Cleanup.ps1'
}

# Layout and wiring tests for the guided window. Every page and dialog is built from simulated
# outcomes (fixture reports in an isolated temp directory). No child process is started, no form
# is shown with ShowDialog, no Explorer or browser is opened, and nothing outside the temp fixture
# directory is touched.

$uiLayoutTestPath = $PSCommandPath
$helpersPath = Join-Path $layoutTestRoot 'Test-Helpers.ps1'
. $helpersPath

$CleanerScriptPath = [IO.Path]::GetFullPath($CleanerScriptPath)
# Expected version comes from the repository VERSION file so a documented version bump keeps tests valid.
$script:ExpectedToolVersion = ([IO.File]::ReadAllText([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $CleanerScriptPath) '..\VERSION')))).Trim()

if ([string]::IsNullOrWhiteSpace($SelectorPath)) {
    $SelectorPath = Join-Path (Split-Path -Parent $CleanerScriptPath) 'Select-360Cleanup.ps1'
}
$SelectorPath = [IO.Path]::GetFullPath($SelectorPath)
$layoutSelectorPath = $SelectorPath

$layoutPreviousTestMode = $env:WINDOWS_360_CLEANER_TEST_MODE
$env:WINDOWS_360_CLEANER_TEST_MODE = 'ISOLATED-SAFETY-TEST'
try { . $layoutSelectorPath -InternalTestLibraryOnly }
finally {
    if ($null -eq $layoutPreviousTestMode) { Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue }
    else { $env:WINDOWS_360_CLEANER_TEST_MODE = $layoutPreviousTestMode }
}

Initialize-SelectorWinForms
[Windows.Forms.Application]::EnableVisualStyles()
Set-W360UiLanguage -Language zh

$script:LayoutGetState = [Windows.Forms.Control].GetMethod('GetState',
    [Reflection.BindingFlags]'Instance, NonPublic', $null, [Type[]]@([int]), $null)
$script:LayoutCreateControl = [Windows.Forms.Control].GetMethod('CreateControl',
    [Reflection.BindingFlags]'Instance, NonPublic', $null, [Type[]]@([bool]), $null)
# Small-screen contract: every page and dialog must work at the 760x540 minimum with normal and 1.5x fonts.
$script:LayoutScales = @(1.0, 1.5)
$script:LayoutWidth = 760
$script:LayoutHeight = 540
# How many "click X" sentences the page cases checked (see Assert-LayoutQuotedButtons).
$script:LayoutQuotedButtonChecks = 0

# ---------------------------------------------------------------- fixtures

function New-LayoutId {
    param([Parameter(Mandatory = $true)][string]$Seed)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Seed)))).Replace('-', '') }
    finally { $sha256.Dispose() }
}

function New-LayoutFinding {
    param(
        [string]$Kind = 'Path',
        [string]$Name,
        [string]$Target,
        [string]$Confidence = 'Confirmed',
        [string]$RemovalType = 'Path',
        [string]$ValueName = '',
        [string]$Reason = 'Known duohuipingbao installation path.',
        [string]$ProductKey = 'Duohui',
        [bool]$Offline = $false
    )

    $selectable = $Confidence -eq 'Confirmed' -and -not $Offline -and $RemovalType -ne 'None'
    return [pscustomobject][ordered]@{
        Kind                = $Kind
        Name                = $Name
        Target              = $Target
        Confidence          = $Confidence
        Reason              = $Reason
        RemovalType         = $RemovalType
        ValueName           = $ValueName
        IdentityFingerprint = $(if ($selectable) { New-LayoutId -Seed ('fp|' + $Target) } else { '' })
        Offline             = $Offline
        ProductKey          = $ProductKey
        SelectionId         = $(if ($selectable) { New-LayoutId -Seed ($Kind + '|' + $Target + '|' + $ValueName) } else { '' })
    }
}

function Write-LayoutJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
}

# Raw fixture names are the real detector names (they map to plain display names) and contain no banned words.
function New-LayoutFindings {
    $local = 'C:\Users\Fixture User\AppData\Local'
    return @(
        (New-LayoutFinding -Name 'Duohui screen saver' -Target "$local\dhpingbao"),
        (New-LayoutFinding -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' -Target "$local\dhpingbao\uninst.exe" -RemovalType 'VendorUninstaller' `
                -Reason 'Exact Duohui uninstaller under a confirmed dhpingbao root with a valid Beijing Qihu Technology Co., Ltd. signature and Duohui/Huabao metadata. SHA-256: ABCDEF'),
        (New-LayoutFinding -Name 'Duohui temporary package' -Target "$local\Temp\duohuipingbao" -Reason 'Known duohuipingbao staging path.'),
        (New-LayoutFinding -Name '360se6 browser application' -Target "$local\360se6\Application" -ProductKey '360SafeBrowser' `
                -Reason 'Exact 360se6 Application directory with local 360/Qihoo file evidence.'),
        (New-LayoutFinding -Name '360se6 browser profile' -Target "$local\360se6\User Data" -ProductKey '360SafeBrowser' -Confidence 'ReviewOnly' -RemovalType 'None' `
                -Reason '360se6 User Data can contain bookmarks, history, saved sessions, and other user data. Preserved by default; use the separate browser-profile opt-in only after backing up needed data.'),
        (New-LayoutFinding -Name '360 Program Files (x86)' -Target 'C:\Program Files (x86)\360' -ProductKey '360InstallDir' `
                -Reason 'Exact vendor product directory with local 360/Qihoo file evidence.'),
        (New-LayoutFinding -Kind 'Process' -Name '360tray.exe (4242)' -Target '4242' -RemovalType 'Process' -ProductKey '360Security' `
                -ValueName 'C:\Program Files (x86)\360\360Safe\safemon\360tray.exe' -Reason 'Executable path under confirmed target: C:\Program Files (x86)\360'),
        (New-LayoutFinding -Kind 'Driver' -Name '360Box64' -Target 'C:\Windows\System32\drivers\360Box64.sys' -Confidence 'ReviewOnly' -RemovalType 'None' `
                -ProductKey 'Drivers' -Reason 'System driver requires vendor-uninstaller and driver-package review; never auto-delete.'),
        (New-LayoutFinding -Kind 'OfflinePath' -Name 'Offline Windows 360 path' -Target 'D:\Windows.old\Program Files\360' -RemovalType 'None' -Offline $true `
                -ProductKey 'OfflineWindows' -Reason 'Found in another Windows installation; the bundled script is permanently scan-only for offline roots.'),
        (New-LayoutFinding -Kind 'ScheduledTask' -Name '360 更新 任务' -Target '\360 更新 任务' -Confidence 'ReviewOnly' -RemovalType 'None' `
                -ProductKey 'Unattributed' -Reason 'Task name matched, but its action was not under a confirmed target.')
    )
}

# A folder that cannot be deleted inside the deletable 360 installation folder: "select all" must leave the
# outer folder unticked.
function New-LayoutProtectedChildFinding {
    return (New-LayoutFinding -Name '360 Program Files (x86) config' -Target 'C:\Program Files (x86)\360\Config' -ProductKey '360InstallDir' `
            -Confidence 'ReviewOnly' -RemovalType 'None' -Reason 'Ambiguous SoftMgr directory without sufficient markers.')
}

function Get-LayoutScanOutcome {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [AllowEmptyCollection()][object[]]$Findings = @(),
        [bool]$CoverageComplete = $true
    )

    $issues = @()
    if (-not $CoverageComplete) {
        $issues = @([pscustomobject]@{ Area = 'ScheduledTasks'; Target = ''; Detail = 'Scheduled-task inspection stopped before every task was checked.' },
            [pscustomobject]@{ Area = 'Services'; Target = 'SomeService'; Detail = 'The service list could not be read completely.' })
    }
    $path = Join-Path $Directory ('360-cleanup-scan-20260913-100000-{0}.json' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    Write-LayoutJson -Path $path -Value ([pscustomobject][ordered]@{
            SchemaVersion   = 2
            ToolVersion     = '1.0.0'
            Timestamp       = '2026-09-13T10:00:00.0000000+08:00'
            Mode            = 'Scan'
            ApprovalContext = [pscustomobject]@{ UserSid = 'S-1-5-21-1-2-3-1001'; Options = [pscustomobject]@{ IncludeBrowserProfiles = $false } }
            Summary         = $null
            ScanCoverage    = [pscustomobject]@{ Complete = $CoverageComplete; Issues = @($issues) }
            Findings        = @($Findings)
            Actions         = @()
        })
    return (Get-W360ScanOutcome -ExitCode 0 -ReportPath $path)
}

function New-LayoutSummary {
    param([hashtable]$Overrides = @{})

    $summary = [ordered]@{
        TotalItemsRemoved = 12; FilesRemoved = 10; DirectoriesRemoved = 2; LogicalBytesRemoved = 2048; LogicalSizeRemoved = '2.00 KB'
        PathTargetsRemoved = 1; PartiallyCleanedPathTargets = 0; ServicesRemoved = 0; ServicesPendingRemoval = 0; ScheduledTasksRemoved = 0
        RegistryKeysRemoved = 1; RegistryValuesRemoved = 1; ProcessesStopped = 0; VendorUninstallersSucceeded = 0; VendorUninstallersFailed = 0
        VendorUninstallersPending = 0; SkippedActions = 0; FailedActions = 0; PendingActions = 0; RetryAttempts = 0; UnresolvedRetryTargets = 0
        AccessDeniedPathTargets = 0; AclRepairAttempts = 0; AclRepairFailures = 0; UnresolvedPathTargets = 0; PathAccountingComplete = $true
        UnmeasuredPathTargets = 0; PostVendorMutationBlocked = $false; ImmediateRescanComplete = $true; ImmediateRemainingConfirmed = 0
        NoImmediateConfirmedFindings = $true; ApprovedConfirmed = 3; EligibleApproved = 3; NewSinceApproval = 0; MissingSinceApproval = 0
        NoLongerConfirmed = 0; SelectionApplied = $true; SelectedConfirmedFindings = 3; UnselectedConfirmedFindings = 1
        ImmediateRemainingSelected = 0; NoImmediateSelectedFindings = $true
        ImmediateSelectedConfirmedAbsent = 3; ImmediateSelectedStillPresent = 0; ImmediateSelectedUnknown = 0
    }
    foreach ($key in @($Overrides.Keys)) { $summary[$key] = $Overrides[$key] }
    return [pscustomobject]$summary
}

function New-LayoutAction {
    param([string]$Action, [string]$Target, [string]$Result, [string]$Detail = '')
    return [pscustomobject]@{ Time = '2026-09-13T10:05:00.0000000+08:00'; Action = $Action; Target = $Target; Result = $Result; Detail = $Detail }
}

function Get-LayoutRemoveOutcome {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [hashtable]$SummaryOverrides = @{},
        [AllowEmptyCollection()][object[]]$Actions = @(),
        [switch]$NoReport,
        [AllowEmptyCollection()][object[]]$Events = @(),
        [object]$ExitCode = 0,
        [AllowEmptyCollection()][object[]]$SelectedFindings = @(),
        [AllowEmptyCollection()][string[]]$StderrLines = @('Fixture stderr line')
    )

    $hash = 'AB' * 32
    $path = Join-Path $Directory ('360-cleanup-remove-20260913-100500-{0}.json' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    if (-not $NoReport) {
        Write-LayoutJson -Path $path -Value ([pscustomobject][ordered]@{
                SchemaVersion = 2; ToolVersion = '1.0.0'; Timestamp = '2026-09-13T10:05:00.0000000+08:00'; Mode = 'Remove'
                ApprovalContext = [pscustomobject]@{ UserSid = 'S-1-5-21-1-2-3-1001' }; ApprovedReportHash = $hash; OutcomeRunId = ('CD' * 16)
                Summary = (New-LayoutSummary -Overrides $SummaryOverrides)
                ScanCoverage = [pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'Services'; Target = ''; Detail = 'The service list could not be read completely.' }) }
                Findings = @(); Actions = @($Actions)
            })
    }
    return (Get-W360RemoveOutcome -ExitCode $ExitCode -ReportPath $path -ExpectedApprovedReportHash $hash -Events $Events `
            -StdoutLines @() -StderrLines $StderrLines -SelectedFindings $SelectedFindings)
}

function New-LayoutItemStatus {
    param(
        [string]$Category,
        [string]$State,
        [string]$Kind = 'Path',
        [string]$Name = 'Duohui screen saver',
        [string]$Target = 'C:\Users\Fixture User\AppData\Local\dhpingbao',
        [string]$ProductKey = 'Duohui',
        [string]$DetailCode = 'ProbeAbsent'
    )

    return [pscustomobject][ordered]@{
        Category = $Category; State = $State; Kind = $Kind; Name = $Name; Target = $Target; ValueName = ''; RemovalType = 'Path'
        ProductKey = $ProductKey; SelectionId = (New-LayoutId -Seed ($Kind + $Target)); CurrentConfidence = ''
        DetailCode = $DetailCode; Detail = ('English detail for ' + $DetailCode)
    }
}

function New-LayoutTaskVerification {
    param(
        [string]$Status,
        [AllowEmptyCollection()][object[]]$Selected = @(),
        [AllowEmptyCollection()][object[]]$Preserved = @(),
        [AllowEmptyCollection()][object[]]$New = @(),
        [string]$UnavailableReason = ''
    )

    return [pscustomobject][ordered]@{
        Status = $Status; UnavailableReason = $UnavailableReason; UnavailableDetail = ''
        RemoveReportPath = 'C:\Reports\360-cleanup-remove-20260913-100500-abcdef12.json'; RemoveReportHash = ('CD' * 32)
        RemoveReportTimestamp = '2026-09-13T10:05:00.0000000+08:00'; RemoveToolVersion = '1.0.0'; ApprovedReportHash = ('EF' * 32)
        SelectionApplied = $true
        Counts = [pscustomobject][ordered]@{
            SelectedTotal = @($Selected).Count; SelectedAbsent = @($Selected | Where-Object { $_.State -eq 'Absent' }).Count
            SelectedRemaining = @($Selected | Where-Object { $_.State -eq 'Remaining' }).Count
            SelectedChanged = @($Selected | Where-Object { $_.State -eq 'Changed' }).Count
            SelectedUnknown = @($Selected | Where-Object { $_.State -eq 'Unknown' }).Count
            PreservedTotal = @($Preserved).Count; PreservedPresent = @($Preserved | Where-Object { $_.State -eq 'Present' }).Count
            PreservedAbsent = @($Preserved | Where-Object { $_.State -eq 'Absent' }).Count; PreservedChanged = 0; PreservedUnknown = 0
            NewConfirmed = @($New).Count
        }
        Selected = @($Selected); Preserved = @($Preserved); New = @($New)
    }
}

function Get-LayoutVerifyOutcome {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [AllowNull()][object]$TaskVerification = $null,
        [AllowEmptyCollection()][object[]]$Findings = @(),
        [bool]$CoverageComplete = $true,
        [int]$ExitCode = 0
    )

    $issues = @()
    if (-not $CoverageComplete) { $issues = @([pscustomobject]@{ Area = 'Services'; Target = ''; Detail = 'The service list could not be read completely.' }) }
    $path = Join-Path $Directory ('360-cleanup-verify-20260914-090000-{0}.json' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    Write-LayoutJson -Path $path -Value ([pscustomobject][ordered]@{
            SchemaVersion = 2; ToolVersion = '1.0.0'; Timestamp = '2026-09-14T09:00:00.0000000+08:00'; Mode = 'Verify'
            ApprovalContext = $null; Summary = $null; ScanCoverage = [pscustomobject]@{ Complete = $CoverageComplete; Issues = @($issues) }
            TaskVerification = $TaskVerification; Findings = @($Findings); Actions = @()
        })
    return (Get-W360VerifyOutcome -ExitCode $ExitCode -ReportPath $path -StdoutLines @() -StderrLines @())
}

function New-LayoutTaskState {
    param([AllowNull()][object]$Restarted = $false, [int]$NewerUnusable = 0)

    return [pscustomobject]@{
        TaskInfo = [pscustomobject]@{ Path = 'C:\Reports\360-cleanup-task-1.json'; CreatedAt = (Get-Date '2026-09-13 10:05');
            Record = [pscustomobject]@{ RemoveReportPath = 'C:\Reports\360-cleanup-remove-1.json' } }
        RemoveReportExists = $true; RemoveReportValid = $true; RemoveReportIssue = ''; RemoveTimestamp = (Get-Date '2026-09-13 10:05')
        RestartedSinceRemove = $Restarted; SelectedCount = 3; PreservedCount = 1; NewerUnusableCount = $NewerUnusable
    }
}

function New-LayoutFakeChildState {
    return [pscustomobject]@{
        Process                  = [pscustomobject]@{ HasExited = $false; ExitCode = 0 }
        FilePath                 = 'fixture'
        ArgumentList             = [string[]]@('-Mode', 'Scan')
        Stopwatch                = [Diagnostics.Stopwatch]::StartNew()
        StdoutLines              = New-Object System.Collections.ArrayList
        StderrLines              = New-Object System.Collections.ArrayList
        StdoutLineCount          = [long]0
        StderrLineCount          = [long]0
        Events                   = New-Object System.Collections.ArrayList
        OutTask                  = $null
        ErrTask                  = $null
        OutEof                   = $true
        ErrEof                   = $true
        ExitCode                 = $null
        Completed                = $false
        Cancelled                = $false
        ProgressFileOffset       = [long]0
        ExitObservedMilliseconds = $null
        StreamsAbandoned         = $false
    }
}

# ---------------------------------------------------------------- layout helpers

function Get-LayoutControls {
    param([Parameter(Mandatory = $true)][object]$Root)

    $Root
    foreach ($child in $Root.Controls) { Get-LayoutControls -Root $child }
}

function Test-LayoutShown {
    param(
        [Parameter(Mandatory = $true)][object]$Control,
        [Parameter(Mandatory = $true)][object]$Top
    )

    $current = $Control
    while ($null -ne $current -and -not [object]::ReferenceEquals($current, $Top)) {
        if (-not [bool]$script:LayoutGetState.Invoke($current, @([int]2))) { return $false }
        $current = $current.Parent
    }
    return ($null -ne $current)
}

# Bounds of a control in the client coordinates of Top, or $null when a parent clips it.
function Get-LayoutRectangle {
    param(
        [Parameter(Mandatory = $true)][object]$Control,
        [Parameter(Mandatory = $true)][object]$Top
    )

    $rect = New-Object Drawing.Rectangle($Control.Left, $Control.Top, $Control.Width, $Control.Height)
    $parent = $Control.Parent
    while ($true) {
        if ($null -eq $parent) { return $null }
        $client = $parent.ClientSize
        if ($rect.Left -lt 0 -or $rect.Top -lt 0 -or $rect.Right -gt $client.Width -or $rect.Bottom -gt $client.Height) { return $null }
        if ([object]::ReferenceEquals($parent, $Top)) { break }
        $rect.Offset($parent.Left, $parent.Top)
        $parent = $parent.Parent
    }
    return $rect
}

function Assert-LayoutInside {
    param(
        [Parameter(Mandatory = $true)][object]$Control,
        [Parameter(Mandatory = $true)][object]$Top,
        [Parameter(Mandatory = $true)][string]$What
    )

    Assert-TestTrue (Test-LayoutShown -Control $Control -Top $Top) "$What is not visible."
    $rect = New-Object Drawing.Rectangle($Control.Left, $Control.Top, $Control.Width, $Control.Height)
    $parent = $Control.Parent
    while ($true) {
        Assert-TestNotNull $parent "$What is not attached to the window."
        $client = $parent.ClientSize
        if ($rect.Left -lt 0 -or $rect.Top -lt 0 -or $rect.Right -gt $client.Width -or $rect.Bottom -gt $client.Height) {
            throw ("{0} is clipped by {1} '{2}': bounds {3} inside client {4}." -f $What, $parent.GetType().Name, $parent.Name, $rect, $client)
        }
        if ([object]::ReferenceEquals($parent, $Top)) { break }
        $rect.Offset($parent.Left, $parent.Top)
        $parent = $parent.Parent
    }
}

function Invoke-LayoutPass {
    param([Parameter(Mandatory = $true)][object]$Form)

    $Form.Size = New-Object Drawing.Size($script:LayoutWidth, $script:LayoutHeight)
    try { [void]$script:LayoutCreateControl.Invoke($Form, @($true)) } catch {}
    $Form.PerformLayout()
    foreach ($control in @(Get-LayoutControls -Root $Form)) {
        if ($control -is [Windows.Forms.TableLayoutPanel] -or $control -is [Windows.Forms.FlowLayoutPanel] -or $control -is [Windows.Forms.Panel]) {
            $control.PerformLayout()
        }
    }
    $Form.PerformLayout()
}

# Every text a user of the window could come across: the window title, every control (hidden ones too),
# accessible names, grid headers, every cell of every row (collapsed rows too), cell tooltips and the
# selection-note tooltip.
function Get-LayoutWindowTexts {
    param(
        [Parameter(Mandatory = $true)][object]$Form,
        [AllowNull()][object]$Page = $null
    )

    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($control in @(Get-LayoutControls -Root $Form)) {
        $texts.Add([string]$control.Text)
        $texts.Add([string]$control.AccessibleName)
        if ($control -is [Windows.Forms.DataGridView]) {
            foreach ($column in $control.Columns) {
                $texts.Add([string]$column.HeaderText)
                $texts.Add([string]$column.ToolTipText)
            }
            foreach ($row in $control.Rows) {
                foreach ($cell in $row.Cells) {
                    if ($null -ne $cell.Value -and -not ($cell.Value -is [bool])) { $texts.Add([string]$cell.Value) }
                    $texts.Add([string]$cell.ToolTipText)
                }
            }
        }
    }
    if ($null -ne $Page -and $Page.Data.ContainsKey('SelectionNoteTip') -and $null -ne $Page.Data['SelectionNoteTip']) {
        $texts.Add([string]$Page.Data['SelectionNoteTip'].GetToolTip($Page.Data['SelectionNote']))
    }
    return [string[]]@($texts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-LayoutPlainTexts {
    param(
        [AllowEmptyCollection()][string[]]$Texts,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $language = Get-W360UiLanguage
    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($text in @($Texts)) {
        foreach ($word in @(Get-W360MainUiBannedWords -Text $text -Language $language)) {
            $violations.Add(("'{0}' in: {1}" -f $word, $text))
        }
    }
    Assert-TestEqual 0 $violations.Count ("{0}: banned words on a main window:`r`n{1}" -f $Label, ($violations.ToArray() -join "`r`n"))
}

# The short description area of a list page, after clicking every row (product, section and item rows).
function Get-LayoutDescriptionTexts {
    param([Parameter(Mandatory = $true)][object]$Page)

    $texts = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Page.Grid -or $null -eq $Page.DetailBox) { return [string[]]@() }
    if (@('ScanResult', 'VerifyResult') -notcontains [string]$Page.Kind) { return [string[]]@() }
    foreach ($row in $Page.Grid.Rows) {
        if ([string]$Page.Kind -eq 'ScanResult') { Update-SelectorScanDetail -Page $Page -RowIndex $row.Index }
        else { Update-SelectorVerifyDetail -Page $Page -RowIndex $row.Index }
        $texts.Add([string]$Page.DetailBox.Text)
    }
    return [string[]]$texts.ToArray()
}

# Rows of a page (headline, lists, description area, counters, button bar) must never overlap, even when
# the window is small and the font is large.
function Assert-LayoutRowsDoNotOverlap {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][object]$Form,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $root = $Page.Root
    $rows = @($root.Controls | Where-Object { Test-LayoutShown -Control $_ -Top $Form } | Sort-Object -Property Top)
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $current = $rows[$index]
        Assert-TestTrue ($current.Bottom -le $root.ClientSize.Height) ("{0}: '{1}' ends below the page ({2} > {3})." -f $Label, $current.Name, $current.Bottom, $root.ClientSize.Height)
        if ($index -gt 0) {
            $previous = $rows[$index - 1]
            Assert-TestTrue ($previous.Bottom -le $current.Top) ("{0}: '{1}' (bottom {2}) overlaps '{3}' (top {4})." -f $Label, $previous.Name, $previous.Bottom, $current.Name, $current.Top)
        }
    }
}

function Assert-LayoutCommon {
    param(
        [Parameter(Mandatory = $true)][object]$Form,
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$MainWindow
    )

    Assert-TestTrue ($Form.ClientSize.Width -gt 0 -and $Form.ClientSize.Height -gt 0) "$Label has no client area."
    $shownButtons = New-Object System.Collections.ArrayList
    foreach ($control in @(Get-LayoutControls -Root $Form)) {
        $shown = Test-LayoutShown -Control $control -Top $Form
        if ($control -is [Windows.Forms.Label] -and $shown -and -not [string]::IsNullOrEmpty($control.Text)) {
            Assert-TestTrue ($control.Width -gt 0 -and $control.Height -gt 0) ("{0}: label '{1}' is clipped to zero size." -f $Label, $control.Name)
        }
        if ($control -is [Windows.Forms.LinkLabel] -and $shown) {
            Assert-LayoutInside -Control $control -Top $Form -What ("{0}: link '{1}'" -f $Label, $control.Name)
        }
        if ($control -is [Windows.Forms.Button] -and $shown) {
            $buttonName = if ($control.Name) { $control.Name } else { $control.Text }
            Assert-TestTrue ($control.Width -ge 96 -and $control.Height -ge 32) ("{0}: button '{1}' is smaller than 96x32." -f $Label, $buttonName)
            $needed = [Windows.Forms.TextRenderer]::MeasureText($control.Text, $control.Font).Width
            Assert-TestTrue ($control.Width -ge $needed) ("{0}: button '{1}' text is clipped ({2} < {3})." -f $Label, $buttonName, $control.Width, $needed)
            Assert-TestFalse ([string]::IsNullOrWhiteSpace($control.AccessibleName)) ("{0}: button '{1}' has no accessible name." -f $Label, $buttonName)
            Assert-LayoutInside -Control $control -Top $Form -What ("{0}: button '{1}'" -f $Label, $buttonName)
            [void]$shownButtons.Add([pscustomobject]@{ Name = $buttonName; Rect = (Get-LayoutRectangle -Control $control -Top $Form) })
        }
        if ($control -is [Windows.Forms.DataGridView]) {
            foreach ($column in $control.Columns) {
                Assert-TestFalse ([string]$column.HeaderText -match '安全级别') "$Label has a grid column called 安全级别."
            }
            if ($shown) {
                Assert-TestTrue ($control.Height -ge 120) ("{0}: grid '{1}' is only {2} px tall." -f $Label, $control.Name, $control.Height)
            }
        }
        if ($control -is [Windows.Forms.Control]) {
            Assert-TestFalse ([string]$control.Text -match '安全级别') ("{0}: control text '{1}' mentions 安全级别." -f $Label, $control.Text)
        }
        # The only select-all is the shrink-only "select everything that can be deleted" button of the scan page.
        if ($control -is [Windows.Forms.Control] -and -not ($control -is [Windows.Forms.TextBox])) {
            $isSelectAllButton = $control -is [Windows.Forms.Button] -and $control.Name -ceq 'SelectAllDeletable'
            if (-not $isSelectAllButton) {
                Assert-TestFalse ([string]$control.Text -match '全选|(?i)select all') ("{0}: control text '{1}' is not allowed." -f $Label, $control.Text)
            }
        }
    }
    for ($i = 0; $i -lt $shownButtons.Count; $i++) {
        for ($j = $i + 1; $j -lt $shownButtons.Count; $j++) {
            Assert-TestFalse ($shownButtons[$i].Rect.IntersectsWith($shownButtons[$j].Rect)) ("{0}: buttons '{1}' and '{2}' overlap." -f $Label, $shownButtons[$i].Name, $shownButtons[$j].Name)
        }
    }
    if ($null -ne $Page.PrimaryButton) {
        Assert-LayoutInside -Control $Page.PrimaryButton -Top $Form -What "$Label primary button"
    }
    Assert-LayoutRowsDoNotOverlap -Page $Page -Form $Form -Label $Label
    if ($MainWindow) {
        Assert-LayoutPlainTexts -Texts (Get-LayoutWindowTexts -Form $Form -Page $Page) -Label $Label
    }
}

# Every "click X" in the detail and the next step of a page names a button of that page ("…" ignored). A sentence
# that asks to open the tool again may name a button of the home page instead; Windows' own Yes and No are allowed.
function Assert-LayoutQuotedButtons {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $trim = { param([string]$Text) $Text.TrimEnd([char]0x2026, '.').Trim() }
    $buttonTexts = @($Page.Buttons.Values | ForEach-Object { & $trim ([string]$_.Text) })
    $homeTexts = @((Get-SelectorText -Key 'Ui.Button.VerifyTask'), (Get-SelectorText -Key 'Ui.Button.Rescan'))
    $windowsTexts = @((Get-SelectorText -Key 'Common.Yes'), (Get-SelectorText -Key 'Common.No'))
    $checked = 0
    foreach ($name in @('Detail', 'NextSteps')) {
        foreach ($control in @(Get-LayoutNamedControl -Root $Page.Root -Name $name)) {
            $text = [string]$control.Text
            $quotePattern = if ((Get-W360UiLanguage) -eq 'zh') { [string][char]0x70B9 + [char]0x201C + '([^' + [char]0x201D + ']+)' + [char]0x201D } else { '(?i)click "([^"]+)"' }
            foreach ($match in [regex]::Matches($text, $quotePattern)) {
                $quoted = & $trim $match.Groups[1].Value
                $allowed = ($buttonTexts -contains $quoted) -or ($windowsTexts -contains $quoted) -or
                    (($text.Contains('打开本工具') -or $text -match '(?i)open this tool') -and $homeTexts -contains $quoted)
                Assert-TestTrue $allowed ("{0}: '{1}' names a button that is not on the page: {2}" -f $Label, $quoted, $text)
                $checked++
            }
        }
    }
    return $checked
}

# Main-window pages: layout at every scale, plain-language walk of every control, and of the description
# area after clicking every row (at the first scale; the texts do not depend on the scale).
function Invoke-LayoutPageCase {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Build,
        [scriptblock]$Check
    )

    $first = $true
    foreach ($scale in $script:LayoutScales) {
        Set-SelectorFontScale -Scale $scale
        $shell = New-SelectorMainForm
        try {
            $page = & $Build
            Set-SelectorPage -Shell $shell -Page $page
            Invoke-LayoutPass -Form $shell.Form
            $caseLabel = '{0} @{1}x' -f $Label, $scale
            Assert-LayoutCommon -Form $shell.Form -Page $page -Label $caseLabel -MainWindow
            Assert-LayoutInside -Control $shell.VersionLabel -Top $shell.Form -What "$caseLabel version label"
            $script:LayoutQuotedButtonChecks += [int](Assert-LayoutQuotedButtons -Page $page -Label $caseLabel)
            if ($null -ne $Check) { & $Check $page $shell.Form $caseLabel }
            if ($first) {
                Assert-LayoutPlainTexts -Texts (Get-LayoutDescriptionTexts -Page $page) -Label "$caseLabel description area"
                $first = $false
            }
        }
        finally {
            $shell.Form.Dispose()
            Set-SelectorFontScale -Scale 1.0
        }
    }
}

# Dialogs. -MainWindow marks the confirmation and selection-adjust dialogs, which follow the plain-language
# policy; More info, Details, Get help and the technical text window may keep technical words.
function Invoke-LayoutDialogCase {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Build,
        [scriptblock]$Check,
        [switch]$MainWindow
    )

    foreach ($scale in $script:LayoutScales) {
        Set-SelectorFontScale -Scale $scale
        $dialog = $null
        try {
            $dialog = & $Build
            $form = $dialog.Data['Form']
            Invoke-LayoutPass -Form $form
            $caseLabel = '{0} @{1}x' -f $Label, $scale
            Assert-LayoutCommon -Form $form -Page $dialog -Label $caseLabel -MainWindow:$MainWindow
            if ($null -ne $Check) { & $Check $dialog $form $caseLabel }
        }
        finally {
            if ($null -ne $dialog) { $dialog.Data['Form'].Dispose() }
            Set-SelectorFontScale -Scale 1.0
        }
    }
}

function Get-LayoutButtonOrder {
    param([Parameter(Mandatory = $true)][object]$Page)
    return ('/' + (@($Page.Buttons.Keys) -join '/'))
}

function Get-LayoutNamedControl {
    param(
        [Parameter(Mandatory = $true)][object]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return @(Get-LayoutControls -Root $Root | Where-Object { [string]$_.Name -ceq $Name })
}

function Get-LayoutGridHeaderTexts {
    param([Parameter(Mandatory = $true)][object]$Grid, [int]$TextColumn = 1)

    foreach ($row in $Grid.Rows) {
        if ($null -ne $row.Tag -and [string]$row.Tag.Type -eq 'Group') { [string]$row.Cells[$TextColumn].Value }
    }
}

function Get-LayoutFindingRowIndex {
    param([Parameter(Mandatory = $true)][object]$Page, [Parameter(Mandatory = $true)][string]$Name)

    foreach ($row in $Page.Grid.Rows) {
        if ($null -ne $row.Tag -and [string]$row.Tag.Type -eq 'Finding' -and [string]$row.Tag.Finding.Name -eq $Name) { return $row.Index }
    }
    throw "Finding row not found: $Name"
}

function Get-LayoutGroupRowIndex {
    param([Parameter(Mandatory = $true)][object]$Page, [Parameter(Mandatory = $true)][string]$Key)

    foreach ($row in $Page.Grid.Rows) {
        if ($null -ne $row.Tag -and [string]$row.Tag.Type -eq 'Group' -and [string]$row.Tag.Group.Key -eq $Key) { return $row.Index }
    }
    throw "Group row not found: $Key"
}

function Get-LayoutSortedIds {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Ids)
    return ((@(@($Ids) | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() }) | Sort-Object) -join ',')
}

function Test-LayoutColor {
    param(
        [Parameter(Mandatory = $true)][object]$Color,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return ($Color.ToArgb() -eq (Get-SelectorColor -Name $Name).ToArgb())
}

# ---------------------------------------------------------------- tests

$run = New-TestRun -Name 'UI layout tests'
$fixtureDirectory = New-TestDirectory
try {
    $findings = New-LayoutFindings
    $scanOutcome = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings $findings -CoverageComplete $false
    $scanComplete = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings $findings -CoverageComplete $true
    $protectedFindings = @($findings) + @(New-LayoutProtectedChildFinding)
    $scanProtected = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings $protectedFindings -CoverageComplete $true
    $idOf = @{}
    foreach ($finding in $findings) { $idOf[[string]$finding.Name] = [string]$finding.SelectionId }

    Invoke-TestCase -Run $run -Name 'selector and layout suite satisfy the PowerShell file contract' -Test {
        Assert-TestPowerShellFileContract -Path $layoutSelectorPath
        Assert-TestPowerShellFileContract -Path $uiLayoutTestPath
        $source = [IO.File]::ReadAllText($layoutSelectorPath, [Text.Encoding]::UTF8)
        Assert-TestTrue ($source.Contains('if ($InternalTestLibraryOnly) {')) 'The selector must keep the InternalTestLibraryOnly guard.'
        $guardIndex = $source.IndexOf('if ($InternalTestLibraryOnly) {')
        foreach ($builder in @('function New-SelectorMainForm', 'function New-SelectorHomePage', 'function New-SelectorProgressPage',
                'function New-SelectorScanResultPage', 'function New-SelectorNoMatchPage', 'function New-SelectorPlanProblemDialog',
                'function New-SelectorConfirmDialog', 'function New-SelectorRemoveResultPage', 'function New-SelectorRemoveDetailsDialog',
                'function New-SelectorVerifyResultPage', 'function New-SelectorErrorPage', 'function New-SelectorHelpSummaryDialog',
                'function New-SelectorItemInfoDialog', 'function New-SelectorTechnicalTextDialog', 'function New-SelectorCoverageDialog',
                'function Get-SelectorOutcomeColor', 'function Invoke-SelectorSelectAllDeletable', 'function Switch-SelectorGroupSelection',
                'function Test-FindingSelectable')) {
            $index = $source.IndexOf($builder)
            Assert-TestTrue ($index -ge 0 -and $index -lt $guardIndex) "$builder must be defined before the test guard."
        }
        foreach ($forbidden in @('Restart-Computer', 'Stop-Computer', 'shutdown.exe', 'RunAs', 'ForceLockedTargets', 'IncludeBrowserProfiles',
                'AllowExplorerRestart', 'Invoke-WebRequest', 'Invoke-RestMethod', 'UploadString', 'DownloadString', 'Remove-Item', '安全级别',
                'CurrentVersion\Run', 'Register-ScheduledTask', 'ThreeState = $true')) {
            Assert-TestFalse ($source.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) "The selector must not contain '$forbidden'."
        }
        # Replaced builders and parameters are gone for good.
        foreach ($removed in @('function Get-SelectorStateColor', 'function Get-SelectorCompletedPhaseText', 'function New-SelectorActionLogDialog',
                'ReviewOnlyCount', 'PhaseList', 'TechnicalText''')) {
            Assert-TestFalse ($source.Contains($removed)) "The selector still contains '$removed'."
        }
        Assert-TestTrue ($source.Contains("'Local\Windows360CleanerSelector'")) 'The single-instance mutex name changed.'
        $keys = @([regex]::Matches($source, "-Key '([A-Za-z0-9.]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        Assert-TestTrue ($keys.Count -gt 50) 'Text key discovery found too few keys.'
        foreach ($key in $keys) { Assert-TestTrue (Test-W360TextKey -Key $key) "The selector uses a text key that does not exist: $key" }
    }

    Invoke-TestCase -Run $run -Name 'window-only Gui texts follow the plain-language policy and are all used' -Test {
        $source = [IO.File]::ReadAllText($layoutSelectorPath, [Text.Encoding]::UTF8)
        $violations = New-Object System.Collections.Generic.List[string]
        $scanned = 0
        foreach ($key in @($script:SelectorTexts.Keys | Sort-Object)) {
            $pair = $script:SelectorTexts[$key]
            if (-not $key.StartsWith('Gui.', [StringComparison]::Ordinal)) { $violations.Add("$key is a window text key without the Gui. prefix.") }
            # Every key lives in exactly one table: the library copy must be the one registered from this table.
            Assert-TestTrue (Test-W360TextKey -Key $key) "The window text key $key was not registered."
            foreach ($language in @('zh', 'en')) {
                $text = [string]$pair[$(if ($language -eq 'zh') { 0 } else { 1 })]
                if ($text -match '全选|(?i)select all') { $violations.Add("[$language] $key offers select-all wording.") }
            }
            if ([regex]::Matches($source, [regex]::Escape("'" + $key + "'")).Count -lt 2) { $violations.Add("$key is defined but never used.") }
            # Keys of secondary windows (More info, Details, Get help, the fatal error box) may keep technical words;
            # the whitelist and its reasons live in the library.
            if (-not [string]::IsNullOrEmpty((Get-W360SecondaryTextKeyReason -Key $key))) { continue }
            $scanned++
            foreach ($word in @(Get-W360MainUiBannedWords -Text ([string]$pair[0]) -Language zh)) { $violations.Add("[zh] $key contains $word") }
            foreach ($word in @(Get-W360MainUiBannedWords -Text ([string]$pair[1]) -Language en)) { $violations.Add("[en] $key contains $word") }
        }
        Assert-TestTrue ($scanned -ge 25) "Too few main-window Gui keys were scanned ($scanned)."
        Assert-TestEqual 0 $violations.Count ("Gui text violations:`r`n" + ($violations.ToArray() -join "`r`n"))
        foreach ($removedKey in @('Ui.Button.GlobalVerify', 'Ui.Button.KeepReportAndClose', 'Ui.Button.NewScan', 'Gui.Progress.CompletedPhases',
                'Gui.Verify.GlobalCounts', 'Gui.Scan.TooMany', 'Ui.Confirm.Preserved', 'Ui.Confirm.KeptVendorCaveat')) {
            Assert-TestFalse (Test-W360TextKey -Key $removedKey) "The unused text key $removedKey must be removed."
        }
        $duringRemove = Get-SelectorText -Key 'Gui.Error.UnexpectedDuringRemove'
        Assert-TestTrue ($duringRemove.Contains('删除还在进行') -and $duringRemove.Contains('不要关机')) 'An interface problem during a deletion must say the deletion is still running.'
        Assert-TestTrue ($source.Contains("-Key 'Gui.Error.UnexpectedDuringRemove'")) 'A running deletion must use the still-running message.'
    }

    Invoke-TestCase -Run $run -Name 'Test-FindingSelectable delegates to the library rule' -Test {
        Assert-TestTrue (Test-FindingSelectable ([pscustomobject]@{ Confidence = 'Confirmed'; Offline = $false; RemovalType = 'Path'; SelectionId = ('A1' * 32) })) 'Confirmed item must be selectable.'
        Assert-TestFalse (Test-FindingSelectable ([pscustomobject]@{ Confidence = 'ReviewOnly'; Offline = $false; RemovalType = 'None'; SelectionId = '' })) 'ReviewOnly item must not be selectable.'
        Assert-TestFalse (Test-FindingSelectable ([pscustomobject]@{ Confidence = 'Confirmed'; Offline = $true; RemovalType = 'Path'; SelectionId = ('A1' * 32) })) 'Offline item must not be selectable.'
        Assert-TestFalse (Test-FindingSelectable ([pscustomobject]@{ Confidence = 'Confirmed'; Offline = $false; RemovalType = 'Path'; SelectionId = '' })) 'An item without SelectionId must not be selectable.'
    }

    Invoke-TestCase -Run $run -Name 'window size follows the working area with the 760x540 minimum' -Test {
        $large = Get-SelectorWindowSize -WorkingArea (New-Object Drawing.Rectangle(0, 0, 1920, 1040))
        Assert-TestEqual 1180 $large.Width 'Large screen width.'
        Assert-TestEqual 800 $large.Height 'Large screen height.'
        $medium = Get-SelectorWindowSize -WorkingArea (New-Object Drawing.Rectangle(0, 0, 1200, 700))
        Assert-TestEqual 1104 $medium.Width 'Medium width is 92% of the working area.'
        Assert-TestEqual 644 $medium.Height 'Medium height is 92% of the working area.'
        $small = Get-SelectorWindowSize -WorkingArea (New-Object Drawing.Rectangle(0, 0, 800, 560))
        Assert-TestEqual 760 $small.Width 'Small width keeps the minimum.'
        Assert-TestEqual 540 $small.Height 'Small height keeps the minimum.'
        $shell = New-SelectorMainForm
        try {
            Assert-TestEqual ('Windows 360 清理工具 v' + $script:ExpectedToolVersion) $shell.Form.Text 'Chinese window title.'
            Assert-TestEqual 760 $shell.Form.MinimumSize.Width 'Minimum width.'
            Assert-TestEqual 540 $shell.Form.MinimumSize.Height 'Minimum height.'
            Assert-TestEqual 'Microsoft YaHei UI' $shell.Form.Font.Name 'Chinese font.'
            Assert-TestEqual 9.5 ([double]$shell.Form.Font.SizeInPoints) 'Base font size.'
            Assert-TestEqual ('v' + $script:ExpectedToolVersion) $shell.VersionLabel.Text 'Version is visible in the header.'
        }
        finally { $shell.Form.Dispose() }
    }

    Invoke-TestCase -Run $run -Name 'loading and home pages: checking the last deletion comes first and a manual restart is advised' -Test {
        Invoke-LayoutPageCase -Label 'Loading' -Build { New-SelectorLoadingPage }
        $restartCases = @(
            @{ Restarted = $false; Text = '重启电脑后再检查结果'; Color = 'Warning' },
            @{ Restarted = $true; Text = '电脑已经重启过'; Color = 'Success' },
            @{ Restarted = $null; Text = '不确定电脑有没有重启过'; Color = 'MutedText' }
        )
        foreach ($restartCase in $restartCases) {
            $taskState = New-LayoutTaskState -Restarted $restartCase.Restarted -NewerUnusable 2
            Invoke-LayoutPageCase -Label ('Home restarted=' + [string]$restartCase.Restarted) -Build { New-SelectorHomePage -TaskState $taskState } -Check {
                param($page, $form, $label)
                Assert-TestEqual 'VerifyTask' $page.PrimaryButton.Name "$label primary button."
                Assert-TestEqual '检查上次删除的结果' $page.PrimaryButton.Text "$label primary text."
                Assert-TestTrue $page.PrimaryButton.Enabled "$label primary must be enabled."
                Assert-TestTrue ([object]::ReferenceEquals($page.AcceptButton, $page.PrimaryButton)) "$label Enter starts the read-only check of the last deletion."
                Assert-TestEqual '/VerifyTask/NewScan/Close' (Get-LayoutButtonOrder -Page $page) "$label button order."
                Assert-TestEqual '重新检查电脑' $page.Buttons['NewScan'].Text "$label new check text."
                Assert-TestTrue ($page.Data['RestartLabel'].Text.Contains($restartCase.Text)) ("{0} restart text: {1}" -f $label, $page.Data['RestartLabel'].Text)
                Assert-TestTrue (Test-LayoutColor -Color $page.Data['RestartLabel'].ForeColor -Name $restartCase.Color) "$label restart colour."
                # The counts describe what was selected, never what was proven deleted.
                $counts = @(Get-LayoutNamedControl -Root $form -Name 'TaskCounts')[0].Text
                Assert-TestEqual '上次选了 3 项要删除，保留了 1 项' $counts "$label counts."
                $newer = @(Get-LayoutNamedControl -Root $form -Name 'NewerUnusable')[0].Text
                Assert-TestTrue ($newer.Contains('2 次删除没拿到结果') -and $newer.Contains('不确定删了多少')) "$label unfinished attempts never sound harmless: $newer"
                Assert-TestTrue ($newer.Contains('“' + $page.Buttons['NewScan'].Text + '”')) "$label unfinished attempts point to the new check button."
                Assert-TestEqual '检查不会删除任何东西。' @(Get-LayoutNamedControl -Root $form -Name 'ReadOnlyNote')[0].Text "$label read-only note."
            }
        }
        Assert-TestEqual 'C:\Reports\360-cleanup-remove-1.json' (Get-SelectorTaskRemoveReportPath -TaskState (New-LayoutTaskState)) 'Task report path.'
    }

    Invoke-TestCase -Run $run -Name 'progress pages: checks can be stopped, a deletion cannot, one current step and elapsed time' -Test {
        foreach ($progressCase in @(
                @{ Kind = 'Scan'; Global = $false; Title = '正在检查电脑…' },
                @{ Kind = 'Verify'; Global = $false; Title = '正在检查上次删除的结果…' },
                @{ Kind = 'Verify'; Global = $true; Title = '正在检查电脑…' })) {
            Invoke-LayoutPageCase -Label ('Progress {0} global={1}' -f $progressCase.Kind, $progressCase.Global) -Build {
                New-SelectorProgressPage -Kind ([string]$progressCase.Kind) -Global:([bool]$progressCase.Global)
            } -Check {
                param($page, $form, $label)
                Assert-TestEqual $progressCase.Title $page.HeadlineLabel.Text "$label title."
                $cancel = $page.Data['CancelButton']
                Assert-TestNotNull $cancel "$label must have a stop button."
                Assert-TestEqual 'Cancel' $cancel.Name "$label stop button name."
                Assert-TestEqual '停止检查' $cancel.Text "$label stop button text."
                Assert-TestTrue $cancel.Enabled "$label stop must be enabled."
                Assert-TestTrue ([object]::ReferenceEquals($page.InitialFocus, $cancel)) "$label focus is on the stop button."
                Assert-TestEqual '/Cancel' (Get-LayoutButtonOrder -Page $page) "$label buttons."
                Assert-LayoutInside -Control $cancel -Top $form -What "$label stop button"
                $note = @(Get-LayoutNamedControl -Root $form -Name 'ProgressNote')[0].Text
                Assert-TestTrue ($note.Contains('不会删除任何东西') -and $note.Contains('可以随时停止')) "$label read-only note: $note"
                $state = New-LayoutFakeChildState
                foreach ($phase in @('ScanStart', 'ScanProductFolders', 'ScanServices')) {
                    [void]$state.Events.Add([pscustomobject]@{ Phase = $phase; Detail = ''; Source = 'Stdout'; Time = (Get-Date) })
                }
                Update-SelectorProgressPage -Page $page -State $state
                Assert-TestEqual '正在查找在后台运行的 360 服务…' $page.Data['PhaseLabel'].Text "$label current step."
                Assert-TestEqual (Get-W360PhaseText -Phase 'ScanServices') $page.Data['PhaseLabel'].Text "$label current step text comes from the library."
                Assert-TestEqual 'ScanServices' ([string]$page.Data['CurrentPhase']) "$label current phase."
                Assert-TestEqual 3 ([int]$page.Data['RenderedEventCount']) "$label rendered events."
                Assert-TestFalse ($page.Data.ContainsKey('PhaseList')) "$label must not list finished steps any more."
                Assert-TestTrue ([string]$page.Data['ElapsedLabel'].Text -match '^已用时间 \d\d:\d\d$') "$label elapsed text."
                Assert-TestNotNull $page.Data['ProgressBar'] "$label progress bar."
                Assert-TestEqual ([Windows.Forms.ProgressBarStyle]::Marquee) $page.Data['ProgressBar'].Style "$label shows no fake percentage."
            }
        }
        Invoke-LayoutPageCase -Label 'Progress Remove' -Build { New-SelectorProgressPage -Kind Remove } -Check {
            param($page, $form, $label)
            # Before Windows allowed it, the page never says "deleting"; its note is true whatever happened so far.
            Assert-TestEqual '正在准备删除…' $page.HeadlineLabel.Text "$label title before anything started."
            Assert-TestNull $page.Data['CancelButton'] "$label must not offer stopping."
            Assert-TestEqual 0 $page.Buttons.Count "$label must not have any action button."
            $noteLabel = @(Get-LayoutNamedControl -Root $form -Name 'ProgressNote')[0]
            Assert-TestTrue ($noteLabel.Text.Contains('点“是”以后，才会开始删除') -and $noteLabel.Text.Contains('不要关闭窗口')) "$label note before deleting: $($noteLabel.Text)"
            Assert-TestFalse ($noteLabel.Text.Contains('正在删除')) "$label does not claim to be deleting yet."
            $state = New-LayoutFakeChildState
            [void]$state.Events.Add([pscustomobject]@{ Phase = 'ValidatingApproval'; Detail = ''; Source = 'Stdout'; Time = (Get-Date) })
            [void]$state.Events.Add([pscustomobject]@{ Phase = 'WaitingForElevation'; Detail = ''; Source = 'Stdout'; Time = (Get-Date) })
            Update-SelectorProgressPage -Page $page -State $state
            Assert-TestEqual '请在 Windows 弹出的窗口里点“是”' $page.HeadlineLabel.Text "$label title while Windows asks."
            Assert-TestTrue ($page.Data['PhaseLabel'].Text.Contains('请点“是”') -and $page.Data['PhaseLabel'].Text.Contains('不会删除任何东西')) "$label Windows prompt step: $($page.Data['PhaseLabel'].Text)"
            Assert-TestFalse ($noteLabel.Text.Contains('正在删除')) "$label still does not claim to be deleting while Windows asks."
            Assert-LayoutPlainTexts -Texts (Get-LayoutWindowTexts -Form $form -Page $page) -Label "$label while Windows asks"
            [void]$state.Events.Add([pscustomobject]@{ Phase = 'ElevatedStarted'; Detail = ''; Source = 'File'; Time = (Get-Date) })
            Update-SelectorProgressPage -Page $page -State $state
            Assert-TestEqual '正在删除…' $page.HeadlineLabel.Text "$label title once deleting started."
            Assert-TestTrue ($noteLabel.Text.Contains('不能中途停止')) "$label must explain that it cannot be stopped."
            Assert-TestTrue ($noteLabel.Text.Contains('不要关闭窗口') -and $noteLabel.Text.Contains('不要关机')) "$label must ask not to close or shut down."
            [void]$state.Events.Add([pscustomobject]@{ Phase = 'WaitingForElevation'; Detail = ''; Source = 'Stdout'; Time = (Get-Date) })
            Update-SelectorProgressPage -Page $page -State $state
            Assert-TestEqual '正在删除…' $page.HeadlineLabel.Text "$label never moves back once deleting started."
        }
        # An already elevated core goes straight to the checks before deleting: that is "deleting" too.
        $adminPage = New-SelectorProgressPage -Kind Remove
        try {
            $adminState = New-LayoutFakeChildState
            [void]$adminState.Events.Add([pscustomobject]@{ Phase = 'RescanBeforeRemoval'; Detail = ''; Source = 'Stdout'; Time = (Get-Date) })
            Update-SelectorProgressPage -Page $adminPage -State $adminState
            Assert-TestEqual '正在删除…' $adminPage.HeadlineLabel.Text 'Without a Windows prompt the first started phase means deleting.'
            # Every phase text the page can show follows the plain-language policy.
            foreach ($phase in @($script:W360KnownPhases) + @('SomethingNew')) {
                [void]$adminState.Events.Add([pscustomobject]@{ Phase = $phase; Detail = ''; Source = 'File'; Time = (Get-Date) })
                Update-SelectorProgressPage -Page $adminPage -State $adminState
                Assert-LayoutPlainTexts -Texts @([string]$adminPage.Data['PhaseLabel'].Text, [string]$adminPage.HeadlineLabel.Text, [string]$adminPage.Data['NoteLabel'].Text) -Label "Phase $phase"
            }
        }
        finally { $adminPage.Root.Dispose() }
        Assert-TestNull (Get-Command -Name 'Get-SelectorCompletedPhaseText' -ErrorAction SilentlyContinue) 'The finished-steps list is gone.'
        Assert-TestEqual '01:05' (Format-SelectorElapsed -Elapsed ([TimeSpan]::FromSeconds(65))) 'Elapsed format.'
        Assert-TestEqual '1:00:01' (Format-SelectorElapsed -Elapsed ([TimeSpan]::FromSeconds(3601))) 'Elapsed format with hours.'
    }

    Invoke-TestCase -Run $run -Name 'outcome colours: failures, unknown, incomplete and restart results never use the success colour' -Test {
        Assert-TestNull (Get-Command -Name 'Get-SelectorStateColor' -ErrorAction SilentlyContinue) 'The state-only colour helper is replaced.'
        $expected = @(
            @('Scan', 'NoMatches', $true, 'Success'), @('Scan', 'NoMatchesIncomplete', $false, 'Warning'), @('Scan', 'Findings', $true, 'Text'),
            @('Scan', 'Cancelled', $null, 'Neutral'), @('Scan', 'Failed', $null, 'Error'), @('Scan', 'InvalidReport', $null, 'Error'),
            @('Remove', 'Completed', $null, 'Success'), @('Remove', 'NeedsRestart', $null, 'Warning'), @('Remove', 'Partial', $null, 'Error'),
            @('Remove', 'Unknown', $null, 'Warning'), @('Remove', 'NotStarted', $null, 'Neutral'),
            @('Verify', 'TaskCompleted', $true, 'Success'), @('Verify', 'TaskCompleted', $false, 'Warning'), @('Verify', 'GlobalClean', $true, 'Success'),
            @('Verify', 'TaskCompletedWithNew', $true, 'Warning'), @('Verify', 'GlobalRemaining', $true, 'Warning'), @('Verify', 'GlobalIncomplete', $false, 'Warning'),
            @('Verify', 'TaskUnavailable', $true, 'Warning'), @('Verify', 'TaskUnknown', $true, 'Warning'), @('Verify', 'TaskRemaining', $true, 'Error'),
            @('Verify', 'GlobalKeptOnly', $true, 'Text'), @('Verify', 'SomethingNew', $true, 'Warning')
        )
        foreach ($entry in $expected) {
            $outcome = [pscustomobject]@{ State = $entry[1]; CoverageComplete = $entry[2] }
            $color = Get-SelectorOutcomeColor -Outcome $outcome
            Assert-TestEqual $entry[3] $color ("{0} {1} (coverage {2}) colour." -f $entry[0], $entry[1], $entry[2])
        }
        # Finished results where kept items are gone or may have changed are never green.
        Assert-TestEqual 'Warning' (Get-SelectorOutcomeColor -Outcome ([pscustomobject]@{ State = 'TaskCompleted'; CoverageComplete = $true; PreservedGoneCount = 1 })) 'A kept item that is gone.'
        Assert-TestEqual 'Warning' (Get-SelectorOutcomeColor -Outcome ([pscustomobject]@{ State = 'Completed'; PreservedNotConfirmedPresent = 1; VendorUninstallerRan = $false })) 'A kept item not seen after deleting.'
        Assert-TestEqual 'Warning' (Get-SelectorOutcomeColor -Outcome ([pscustomobject]@{ State = 'Completed'; PreservedNotConfirmedPresent = 0; VendorUninstallerRan = $true })) 'An uninstaller that came with 360 ran.'
        Assert-TestEqual 'Success' (Get-SelectorOutcomeColor -Outcome ([pscustomobject]@{ State = 'Completed'; PreservedNotConfirmedPresent = 0; VendorUninstallerRan = $false })) 'A plain completed removal.'
        foreach ($notSuccess in @('Success', 'Info', 'Text')) {
            Assert-TestFalse ((Get-SelectorColor -Name 'Warning').ToArgb() -eq (Get-SelectorColor -Name $notSuccess).ToArgb()) "Warning must look different from $notSuccess."
            Assert-TestFalse ((Get-SelectorColor -Name 'Error').ToArgb() -eq (Get-SelectorColor -Name $notSuccess).ToArgb()) "Error must look different from $notSuccess."
            Assert-TestFalse ((Get-SelectorColor -Name 'Neutral').ToArgb() -eq (Get-SelectorColor -Name 'Success').ToArgb()) 'Neutral must look different from Success.'
        }
    }

    Invoke-TestCase -Run $run -Name 'scan result page: collapsed products, delete-or-keep column, nothing pre-checked, coverage banner' -Test {
        Invoke-LayoutPageCase -Label 'ScanResult' -Build { New-SelectorScanResultPage -Outcome $scanOutcome } -Check {
            param($page, $form, $label)
            Assert-LayoutInside -Control $page.Grid -Top $form -What "$label grid"
            Assert-TestEqual 'FindingGrid' $page.Grid.Name "$label grid name."
            Assert-TestEqual '/Select/Item/Decision' ('/' + (@($page.Grid.Columns | ForEach-Object { $_.Name }) -join '/')) "$label column names."
            Assert-TestEqual '/勾选/内容/删不删' ('/' + (@($page.Grid.Columns | ForEach-Object { $_.HeaderText }) -join '/')) "$label columns."
            Assert-TestFalse $page.Grid.Columns[0].ThreeState "$label check cells stay two-state (the mixed product state is painted)."
            Assert-TestEqual '找到 4 个可以删除的 360 软件' $page.HeadlineLabel.Text "$label headline counts products."
            Assert-TestTrue (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Text') "$label a list of findings is not a success."
            Assert-TestEqual '勾选要删除的，再点“删除选中的内容”。没勾选的，本工具不会去删。' $page.DetailLabel.Text "$label detail."
            Assert-TestEqual 'CleanSelected' $page.PrimaryButton.Name "$label primary."
            Assert-TestEqual 'Danger' ([string]$page.PrimaryButton.Tag) "$label delete button is red."
            Assert-TestFalse $page.PrimaryButton.Enabled "$label delete button must be disabled while nothing is selected."
            Assert-TestEqual '删除选中的内容…' $page.PrimaryButton.Text "$label delete text."
            Assert-TestNull $page.AcceptButton "$label must not make deletion the default button."
            Assert-TestNull $form.AcceptButton "$label Enter must never start a deletion."
            Assert-TestEqual '/CleanSelected/SelectAllDeletable/ClearSelection/HelpSummary/Close' (Get-LayoutButtonOrder -Page $page) "$label buttons."
            Assert-TestEqual '全选可以删除的' $page.Buttons['SelectAllDeletable'].Text "$label select-all text."
            Assert-TestTrue $page.Buttons['SelectAllDeletable'].Enabled "$label select-all is enabled when something can be deleted."
            Assert-TestEqual '全部不选' $page.Buttons['ClearSelection'].Text "$label clear text."
            Assert-TestFalse $page.Buttons['ClearSelection'].Enabled "$label clearing is offered only when something is ticked."
            Assert-TestEqual '获取帮助' $page.Buttons['HelpSummary'].Text "$label help text."
            Assert-TestFalse $page.Buttons.Contains('OpenReportFolder') "$label has no records-folder button on the page."
            Assert-TestNotNull $page.Data['Banner'] "$label must show the not-fully-checked banner."
            $bannerText = @(Get-LayoutNamedControl -Root $form -Name 'CoverageBannerText')[0]
            Assert-TestTrue ($bannerText.Text.Contains('有些地方没检查完，结果可能不全')) "$label banner text."
            Assert-TestEqual $bannerText.Text ([string]$page.Data['SelectionNoteTip'].GetToolTip($bannerText)) "$label the full banner text is in the tooltip."
            Assert-TestEqual $page.Data['Counter'].Text ([string]$page.Data['SelectionNoteTip'].GetToolTip($page.Data['Counter'])) "$label the full counter text is in the tooltip."
            Assert-TestEqual 'CoverageDetails' $page.Data['CoverageLink'].Name "$label banner link."
            Assert-TestEqual '看看是哪些' $page.Data['CoverageLink'].Text "$label banner link text."
            Assert-TestEqual 'FindingDetail' $page.DetailBox.Name "$label description box."
            Assert-TestEqual '点任意一行，这里会告诉你它是什么、删除后会怎样。' $page.DetailBox.Text "$label description placeholder."
            Assert-TestTrue $page.DetailBox.ReadOnly "$label description is read-only."
            Assert-TestFalse ([bool]$page.Data['DetailAreaHidden']) "$label the Chinese description area fits even on a small screen."
            Assert-LayoutInside -Control $page.DetailBox -Top $form -What "$label description box"
            Assert-TestEqual 'MoreInfo' $page.Data['MoreInfoLink'].Name "$label more info link."
            Assert-TestFalse $page.Data['MoreInfoLink'].Enabled "$label more info waits for an item row."
            Assert-TestEqual (-1) ([int]$page.Data['InfoRowIndex']) "$label no info row yet."
            Assert-TestEqual 0 $page.Data['Selection'].Count "$label must start with an empty selection."
            Assert-TestTrue ($page.Data['Counter'].Text.StartsWith('已选 0 项要删除')) ("{0} counter: {1}" -f $label, $page.Data['Counter'].Text)
            Assert-TestFalse $page.Data['SelectionNote'].Visible "$label shows no selection note."
            $headers = @(Get-LayoutGridHeaderTexts -Grid $page.Grid)
            Assert-TestEqual 7 $headers.Count "$label product rows."
            foreach ($row in $page.Grid.Rows) {
                Assert-TestTrue ($row.Cells[0].Value -is [bool]) "$label row $($row.Index) check value must stay a bool."
                Assert-TestFalse ([bool]$row.Cells[0].Value) "$label row $($row.Index) is pre-checked."
                if ([string]$row.Tag.Type -eq 'Finding') {
                    Assert-TestFalse $row.Visible "$label item rows start hidden under collapsed products."
                    Assert-TestTrue ([object]::ReferenceEquals($row.Tag.GroupInfo, $page.Grid.Rows[$row.Tag.GroupInfo.HeaderIndex].Tag)) "$label item row knows its product row."
                    continue
                }
                $info = $row.Tag
                Assert-TestTrue ([bool]$info.Collapsed) "$label products start collapsed."
                Assert-TestTrue ([string]$row.Cells[1].Value).StartsWith([string][char]0x25B6 + ' ') "$label collapsed arrow."
                Assert-TestEqual ([string]$info.Group.DecisionText) ([string]$row.Cells[2].Value) "$label product decision text."
                $expectedState = if (@($info.Group.SelectableIds).Count -gt 0) { 'Unchecked' } else { 'Disabled' }
                Assert-TestEqual $expectedState ([string]$info.CheckState) "$label product check state."
                Assert-TestEqual ($expectedState -ne 'Disabled') ([bool]$info.Selectable) "$label product selectable flag."
            }
            $duohui = $page.Grid.Rows[(Get-LayoutGroupRowIndex -Page $page -Key 'Duohui')]
            Assert-TestTrue ([string]$duohui.Cells[1].Value).Contains('360 画报 / 多绘屏保') "$label Duohui product row."
            Assert-TestEqual '可以删除（3 项）' ([string]$duohui.Cells[2].Value) "$label Duohui decision."
            Assert-TestEqual '可以删除（1 项），1 项不删除' ([string]$page.Grid.Rows[(Get-LayoutGroupRowIndex -Page $page -Key '360SafeBrowser')].Cells[2].Value) "$label browser decision."
            Assert-TestEqual '不删除：系统驱动' ([string]$page.Grid.Rows[(Get-LayoutGroupRowIndex -Page $page -Key 'Drivers')].Cells[2].Value) "$label driver decision."
            Assert-TestTrue ($headers[$headers.Count - 1].Contains('其他 Windows 系统里的内容')) "$label offline group must be last."
            $profile = $page.Grid.Rows[(Get-LayoutFindingRowIndex -Page $page -Name '360se6 browser profile')]
            Assert-TestEqual '不删除：书签和历史记录' ([string]$profile.Cells[2].Value) "$label kept item says why."
            Assert-TestEqual '可以删除' ([string]$page.Grid.Rows[(Get-LayoutFindingRowIndex -Page $page -Name '360se6 browser application')].Cells[2].Value) "$label deletable item."
            Assert-TestEqual '定时自动运行的任务：360 更新 任务' ([string]$page.Grid.Rows[(Get-LayoutFindingRowIndex -Page $page -Name '360 更新 任务')].Cells[1].Value) "$label raw names get a plain kind."
        }
    }

    Invoke-TestCase -Run $run -Name 'scan result variants fit a small screen: expanded list, keep-only result and the skipped note' -Test {
        Invoke-LayoutPageCase -Label 'ScanResult expanded' -Build {
            $expanded = New-SelectorScanResultPage -Outcome $scanComplete
            foreach ($groupInfo in @($expanded.Data['Groups'])) { [void](Switch-SelectorGroupCollapse -Page $expanded -RowIndex $groupInfo.HeaderIndex) }
            [void](Switch-SelectorFindingSelection -Page $expanded -RowIndex (Get-LayoutFindingRowIndex -Page $expanded -Name 'Duohui screen saver'))
            Update-SelectorScanDetail -Page $expanded -RowIndex (Get-LayoutFindingRowIndex -Page $expanded -Name 'Duohui screen saver')
            $expanded
        } -Check {
            param($page, $form, $label)
            Assert-TestNull $page.Data['Banner'] "$label has no banner when everything was checked."
            $duohui = $page.Grid.Rows[(Get-LayoutGroupRowIndex -Page $page -Key 'Duohui')]
            Assert-TestEqual 'Indeterminate' ([string]$duohui.Tag.CheckState) "$label partly ticked product."
            Assert-TestFalse ([bool]$duohui.Cells[0].Value) "$label a partly ticked product cell stays false."
            Assert-TestTrue ([string]$duohui.Cells[1].Value).StartsWith([string][char]0x25BC + ' ') "$label expanded arrow."
            $ticked = $page.Grid.Rows[(Get-LayoutFindingRowIndex -Page $page -Name 'Duohui screen saver')]
            Assert-TestTrue ([bool]$ticked.Cells[0].Value) "$label ticked row."
            Assert-TestEqual '要删除' ([string]$ticked.Cells[2].Value) "$label ticked row says it will be deleted."
            Assert-TestTrue (Test-LayoutColor -Color $ticked.Cells[2].Style.ForeColor -Name 'Danger') "$label delete is red."
            Assert-TestTrue $page.Buttons['CleanSelected'].Enabled "$label delete button enabled."
            Assert-TestTrue (Test-LayoutColor -Color $page.Buttons['CleanSelected'].BackColor -Name 'Danger') "$label enabled delete button is red."
            Assert-TestTrue $page.Data['MoreInfoLink'].Enabled "$label more info for the current item."
            Assert-LayoutInside -Control $page.Data['MoreInfoLink'] -Top $form -What "$label more info link"
            Assert-LayoutInside -Control $page.DetailBox -Top $form -What "$label description box"
            Assert-TestTrue ($page.DetailBox.Text.Contains('删除后：')) "$label description of a deletable item."
        }
        $keepOnlyFindings = @($findings | Where-Object { -not (Test-W360FindingSelectable -Finding $_) })
        $keepOnly = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings $keepOnlyFindings -CoverageComplete $true
        Invoke-LayoutPageCase -Label 'ScanResult keep-only' -Build { New-SelectorScanResultPage -Outcome $keepOnly } -Check {
            param($page, $form, $label)
            Assert-TestEqual '找到了一些 360 相关的内容，但都不删除' $page.HeadlineLabel.Text "$label headline."
            Assert-TestEqual '原因写在每一行后面。可以直接关闭。' $page.DetailLabel.Text "$label detail."
            # Nothing can be ticked, so the page offers nothing to tick, clear or delete; closing leads.
            Assert-TestEqual '/Close/HelpSummary' (Get-LayoutButtonOrder -Page $page) "$label buttons."
            Assert-TestEqual 'Close' $page.PrimaryButton.Name "$label close leads."
            Assert-TestNull $page.Data['Counter'] "$label has no selection counter."
            Assert-TestEqual 0 @(Get-LayoutNamedControl -Root $form -Name 'SelectionCounter').Count "$label shows no selection counter."
            Assert-TestNull $page.AcceptButton "$label Enter does nothing."
            Assert-TestFalse (Invoke-SelectorSelectAllDeletable -Page $page) "$label select-all does nothing."
            Assert-TestEqual 0 $page.Data['Selection'].Count "$label nothing can be ticked."
            foreach ($groupInfo in @($page.Data['Groups'])) {
                Assert-TestEqual 'Disabled' ([string]$groupInfo.CheckState) "$label product rows are disabled."
                Assert-TestFalse (Switch-SelectorGroupSelection -Page $page -RowIndex $groupInfo.HeaderIndex) "$label product rows cannot be ticked."
            }
        }
        # The note is left for the rare case of a product click that depends on another product: the 360 folder holds
        # the running 360tray program of another product, so the folder alone is not ticked.
        Invoke-LayoutPageCase -Label 'ScanResult skipped note' -Build {
            $noted = New-SelectorScanResultPage -Outcome $scanOutcome
            [void](Switch-SelectorGroupSelection -Page $noted -RowIndex (Get-LayoutGroupRowIndex -Page $noted -Key '360InstallDir'))
            $noted
        } -Check {
            param($page, $form, $label)
            Assert-TestTrue (Test-LayoutShown -Control $page.Data['SelectionNote'] -Top $form) "$label shows the note."
            Assert-LayoutInside -Control $page.Data['SelectionNote'] -Top $form -What "$label selection note"
            Assert-LayoutInside -Control $page.Data['Counter'] -Top $form -What "$label counter"
            # With large fonts the description area gives up its height before the list does (the list keeps three rows).
            if (-not [bool]$page.Data['DetailAreaHidden']) { Assert-LayoutInside -Control $page.DetailBox -Top $form -What "$label description box" }
            elseif ($label.EndsWith('@1x')) { throw "$label the description area must fit at normal font size." }
            Assert-TestEqual '“360 程序文件夹（32 位）”没有帮你选上：里面还有没勾选的东西。' $page.Data['SelectionNote'].Text "$label note text."
            Assert-TestEqual $page.Data['SelectionNote'].Text ([string]$page.Data['SelectionNoteTip'].GetToolTip($page.Data['SelectionNote'])) "$label the full note is in the tooltip."
            Assert-TestTrue ($page.Data['Banner'].Bottom -le $page.Grid.Top) "$label banner above the list."
        }
    }

    Invoke-TestCase -Run $run -Name 'scan selection: item rows, product checkbox toggle rule, tri-state and collapse' -Test {
        $page = New-SelectorScanResultPage -Outcome $scanOutcome
        try {
            $profileRow = Get-LayoutFindingRowIndex -Page $page -Name '360se6 browser profile'
            Assert-TestFalse (Switch-SelectorFindingSelection -Page $page -RowIndex $profileRow) 'A protected profile row must not toggle.'
            Assert-TestEqual 0 $page.Data['Selection'].Count 'Profile click must not select anything.'
            [void](Invoke-SelectorScanGridActivate -Page $page -RowIndex $profileRow -ColumnIndex 0)
            Assert-TestEqual 0 $page.Data['Selection'].Count 'Clicking the checkbox of a kept row selects nothing.'

            $appRow = Get-LayoutFindingRowIndex -Page $page -Name '360se6 browser application'
            Assert-TestTrue (Switch-SelectorFindingSelection -Page $page -RowIndex $appRow) 'A deletable row toggles.'
            Assert-TestTrue ([bool]$page.Grid.Rows[$appRow].Cells[0].Value) 'The row mirrors the selection.'
            Assert-TestEqual '要删除' ([string]$page.Grid.Rows[$appRow].Cells[2].Value) 'A ticked row says it will be deleted.'
            Assert-TestTrue $page.Buttons['CleanSelected'].Enabled 'Delete button enables with one selection.'
            Assert-TestTrue $page.Buttons['ClearSelection'].Enabled 'Clearing is offered once something is ticked.'
            Assert-TestTrue ($page.Data['Counter'].Text.StartsWith('已选 1 项')) 'Counter follows the selection.'

            $browserGroup = Get-LayoutGroupRowIndex -Page $page -Key '360SafeBrowser'
            Assert-TestEqual 'Checked' ([string]$page.Grid.Rows[$browserGroup].Tag.CheckState) 'Every deletable browser item is ticked.'
            Assert-TestTrue ([bool]$page.Grid.Rows[$browserGroup].Cells[0].Value) 'A fully ticked product cell is true.'
            Assert-TestTrue (Switch-SelectorGroupSelection -Page $page -RowIndex $browserGroup) 'Product checkbox toggles.'
            Assert-TestEqual 0 $page.Data['Selection'].Count 'A fully ticked product unticks on the next click.'
            Assert-TestEqual '可以删除' ([string]$page.Grid.Rows[$appRow].Cells[2].Value) 'An unticked row says it can be deleted.'

            # A product click adds exactly its deletable items and leaves other products alone.
            [void](Switch-SelectorFindingSelection -Page $page -RowIndex $appRow)
            $duohuiGroup = Get-LayoutGroupRowIndex -Page $page -Key 'Duohui'
            Assert-TestTrue (Switch-SelectorGroupSelection -Page $page -RowIndex $duohuiGroup) 'Duohui product toggles.'
            Assert-TestEqual 4 $page.Data['Selection'].Count 'The product click adds its three items to the existing selection.'
            foreach ($name in @('Duohui screen saver', 'Duohui vendor uninstaller', 'Duohui temporary package', '360se6 browser application')) {
                Assert-TestTrue $page.Data['Selection'].ContainsKey($idOf[$name]) "Selection must include $name."
            }
            Assert-TestEqual 'Checked' ([string]$page.Grid.Rows[$duohuiGroup].Tag.CheckState) 'Duohui is fully ticked.'
            Assert-TestTrue ([bool]$page.Grid.Rows[$duohuiGroup].Cells[0].Value) 'Duohui cell is true.'
            [void](Switch-SelectorGroupSelection -Page $page -RowIndex $duohuiGroup)
            Assert-TestEqual 1 $page.Data['Selection'].Count 'Unticking a product keeps other products ticked.'
            Assert-TestTrue $page.Data['Selection'].ContainsKey($idOf['360se6 browser application']) 'The browser item stays ticked.'

            # Tri-state: one ticked item makes the product mixed; the next product click completes it.
            [void](Switch-SelectorFindingSelection -Page $page -RowIndex (Get-LayoutFindingRowIndex -Page $page -Name 'Duohui temporary package'))
            Assert-TestEqual 'Indeterminate' ([string]$page.Grid.Rows[$duohuiGroup].Tag.CheckState) 'One ticked Duohui item makes the product mixed.'
            Assert-TestTrue ($page.Grid.Rows[$duohuiGroup].Cells[0].Value -is [bool]) 'The mixed product cell value stays a bool.'
            Assert-TestFalse ([bool]$page.Grid.Rows[$duohuiGroup].Cells[0].Value) 'The mixed product cell value is false.'
            [void](Switch-SelectorGroupSelection -Page $page -RowIndex $duohuiGroup)
            Assert-TestEqual 'Checked' ([string]$page.Grid.Rows[$duohuiGroup].Tag.CheckState) 'A mixed product click ticks the rest of the product.'
            Assert-TestEqual 4 $page.Data['Selection'].Count 'The mixed product is completed.'
            [void](Switch-SelectorGroupSelection -Page $page -RowIndex $duohuiGroup)
            Assert-TestEqual 'Unchecked' ([string]$page.Grid.Rows[$duohuiGroup].Tag.CheckState) 'The next click unticks the product (the toggle never locks up).'
            Assert-TestEqual 1 $page.Data['Selection'].Count 'Only the browser item remains.'

            foreach ($readOnlyKey in @('Drivers', 'Unattributed', 'OfflineWindows')) {
                $readOnlyGroup = Get-LayoutGroupRowIndex -Page $page -Key $readOnlyKey
                Assert-TestFalse (Switch-SelectorGroupSelection -Page $page -RowIndex $readOnlyGroup) "The $readOnlyKey product has nothing that can be deleted."
                Assert-TestEqual 'Disabled' ([string]$page.Grid.Rows[$readOnlyGroup].Tag.CheckState) "The $readOnlyKey product checkbox is drawn disabled."
                Assert-TestFalse ([bool]$page.Grid.Rows[$readOnlyGroup].Cells[0].Value) "The $readOnlyKey product checkbox stays unticked."
            }
            Assert-TestEqual 1 $page.Data['Selection'].Count 'Read-only products change nothing.'
            foreach ($row in $page.Grid.Rows) {
                if ([string]$row.Tag.Type -eq 'Finding' -and -not [bool]$row.Tag.Selectable) {
                    Assert-TestFalse ([bool]$row.Cells[0].Value) "A kept item is never ticked: $($row.Tag.Finding.Name)"
                }
            }

            # Collapsing and expanding never changes the selection.
            $browserChildren = @($page.Grid.Rows[$browserGroup].Tag.RowIndexes)
            Assert-TestTrue (Switch-SelectorGroupCollapse -Page $page -RowIndex $browserGroup) 'The first product-name click expands.'
            Assert-TestFalse ([bool]$page.Grid.Rows[$browserGroup].Tag.Collapsed) 'Expanded state.'
            foreach ($childIndex in $browserChildren) { Assert-TestTrue $page.Grid.Rows[$childIndex].Visible 'Expanded rows are visible.' }
            Assert-TestTrue ([string]$page.Grid.Rows[$browserGroup].Cells[1].Value).StartsWith([string][char]0x25BC) 'Expanded arrow.'
            Assert-TestTrue (Switch-SelectorGroupCollapse -Page $page -RowIndex $browserGroup) 'The second click collapses.'
            foreach ($childIndex in $browserChildren) { Assert-TestFalse $page.Grid.Rows[$childIndex].Visible 'Collapsed rows are hidden.' }
            Assert-TestTrue ([string]$page.Grid.Rows[$browserGroup].Cells[1].Value).StartsWith([string][char]0x25B6) 'Collapsed arrow.'
            Assert-TestEqual 1 $page.Data['Selection'].Count 'Collapsing never changes the selection.'
            [void](Invoke-SelectorScanGridActivate -Page $page -RowIndex $browserGroup -ColumnIndex 1)
            Assert-TestFalse ([bool]$page.Grid.Rows[$browserGroup].Tag.Collapsed) 'Clicking the product name expands it.'
            Assert-TestEqual 1 $page.Data['Selection'].Count 'Clicking the product name does not tick anything.'
            Assert-TestFalse (Switch-SelectorGroupCollapse -Page $page -RowIndex $appRow) 'Item rows do not collapse.'

            # Description area and More info.
            Update-SelectorScanDetail -Page $page -RowIndex $appRow
            foreach ($part in @('360 安全浏览器程序文件', '删除后：', '由你决定', '回收站')) {
                Assert-TestTrue ($page.DetailBox.Text.Contains($part)) "The description of a deletable item must contain '$part'."
            }
            Assert-TestEqual 1 ([regex]::Matches($page.DetailBox.Text, '回收站').Count) 'The description says the Recycle Bin once.'
            Assert-TestTrue $page.Data['MoreInfoLink'].Enabled 'More info is available for an item row.'
            Assert-TestEqual $appRow ([int]$page.Data['InfoRowIndex']) 'More info describes the current item row.'
            $infoText = Get-SelectorItemInfoText -Page $page
            foreach ($part in @('删不删', '为什么列出来', '删除后会怎样', '属于哪个软件', '技术信息', 'SelectionId', $idOf['360se6 browser application'])) {
                Assert-TestTrue ($infoText.Contains($part)) "More info must contain '$part'."
            }
            $infoDialog = New-SelectorItemInfoDialog -Page $page
            try {
                Assert-TestEqual 'ItemInfoDialog' $infoDialog.Kind 'More info dialog kind.'
                Assert-TestEqual '更多信息' $infoDialog.Data['Form'].Text 'More info dialog title.'
                Assert-TestEqual $infoText $infoDialog.DetailBox.Text 'More info dialog body.'
            }
            finally { $infoDialog.Data['Form'].Dispose() }
            Update-SelectorScanDetail -Page $page -RowIndex (Get-LayoutFindingRowIndex -Page $page -Name 'Duohui screen saver')
            Assert-TestTrue ($page.DetailBox.Text.StartsWith('多绘屏保安装文件夹，属于“360 画报 / 多绘屏保”。')) ('A name that says folder is not followed by the kind again: ' + $page.DetailBox.Text)
            Update-SelectorScanDetail -Page $page -RowIndex $profileRow
            Assert-TestTrue ($page.DetailBox.Text.Contains('为什么不删除：')) 'The description of a kept item says why.'
            Assert-TestFalse ($page.DetailBox.Text.Contains('删除后：')) 'A kept item does not describe deleting.'
            Update-SelectorScanDetail -Page $page -RowIndex $duohuiGroup
            Assert-TestTrue ($page.DetailBox.Text.Contains('可以删除 3 项，不删除 0 项。')) ('Product description: ' + $page.DetailBox.Text)
            Assert-TestFalse $page.Data['MoreInfoLink'].Enabled 'More info is not offered for a product row.'
            Assert-TestNull (New-SelectorItemInfoDialog -Page $page) 'No More info window for a product row.'

            Clear-SelectorSelection -Page $page
            Assert-TestEqual 0 $page.Data['Selection'].Count 'Clear selection empties the dictionary.'
            Assert-TestFalse $page.Buttons['CleanSelected'].Enabled 'Delete button disables after clearing.'
            foreach ($groupInfo in @($page.Data['Groups'])) { Assert-TestTrue (@('Unchecked', 'Disabled') -contains [string]$groupInfo.CheckState) 'Clearing unticks every product.' }

            $manyIds = @(1..65 | ForEach-Object { New-LayoutId -Seed "many$_" })
            Set-SelectorSelectedIds -Page $page -Ids $manyIds
            Assert-TestEqual 0 $page.Data['Selection'].Count 'Unknown IDs are never selected in the grid.'
            $allSelectable = @($page.Data['SelectableById'].Keys)
            $tooMany = @($allSelectable) + @($manyIds)
            Set-SelectorSelectedIds -Page $page -Ids $tooMany
            Assert-TestEqual $allSelectable.Count $page.Data['Selection'].Count 'Only known deletable IDs are kept.'
        }
        finally { $page.Root.Dispose() }
    }

    Invoke-TestCase -Run $run -Name 'select everything that can be deleted: shrink-only, never a kept item, never on open' -Test {
        $page = New-SelectorScanResultPage -Outcome $scanProtected
        try {
            Assert-TestEqual 0 $page.Data['Selection'].Count 'The page opens with nothing selected.'
            foreach ($row in $page.Grid.Rows) { Assert-TestFalse ([bool]$row.Cells[0].Value) "Row $($row.Index) is pre-checked." }
            # Select-all offers exactly the shrink result of every item the core rule allows: the effective set.
            $coreSelectable = @($protectedFindings | Where-Object { Test-W360FindingSelectable -Finding $_ } | ForEach-Object { [string]$_.SelectionId })
            $expected = Get-W360DeletableSelection -Findings $protectedFindings -CandidateIds ([string[]]$coreSelectable) -SelectedIds @()
            Assert-TestTrue (@($expected.Removed).Count -ge 1) 'The fixture needs an item that can never pass the selection check.'
            Assert-TestEqual (Get-LayoutSortedIds -Ids $expected.Ids) (Get-LayoutSortedIds -Ids @($page.Data['SelectableById'].Keys)) 'Only the effectively deletable items can be ticked on the page.'
            Assert-TestFalse $page.Data['SelectableById'].ContainsKey($idOf['360 Program Files (x86)']) 'A folder with a protected item inside is not tickable.'

            Assert-TestTrue (Invoke-SelectorSelectAllDeletable -Page $page) 'Select-all runs.'
            Assert-TestEqual (Get-LayoutSortedIds -Ids $expected.Ids) (Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)) 'Select-all ticks exactly the shrink-only set.'
            foreach ($id in @(Get-SelectorSelectedIds -Page $page)) {
                Assert-TestTrue $page.Data['SelectableById'].ContainsKey($id) "Select-all ticked an item that cannot be deleted: $id"
            }
            foreach ($row in $page.Grid.Rows) {
                if ([string]$row.Tag.Type -eq 'Finding' -and -not [bool]$row.Tag.Selectable) {
                    Assert-TestFalse ([bool]$row.Cells[0].Value) "Select-all ticked a kept item: $($row.Tag.Finding.Name)"
                }
            }
            Assert-TestFalse $page.Data['Selection'].ContainsKey($idOf['360 Program Files (x86)']) 'A folder with a protected item inside stays unticked.'
            Assert-TestFalse $page.Data['SelectionNote'].Visible 'Nothing needs a note: the folder was never offered.'
            $plan = Get-W360SelectionPlan -Findings $protectedFindings -SelectedIds (Get-SelectorSelectedIds -Page $page)
            Assert-TestTrue ([bool]$plan.CanSubmit) ('The select-all result passes the selection check: ' + ((@($plan.Problems) | ForEach-Object { $_.Code }) -join ','))
            Assert-TestEqual 'Disabled' ([string]$page.Grid.Rows[(Get-LayoutGroupRowIndex -Page $page -Key '360InstallDir')].Tag.CheckState) 'The product of the folder has nothing to tick.'
            $before = Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)
            [void](Invoke-SelectorSelectAllDeletable -Page $page)
            Assert-TestEqual $before (Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)) 'Select-all is stable when clicked again.'
            Clear-SelectorSelection -Page $page
            Assert-TestEqual 0 $page.Data['Selection'].Count 'Clear unticks everything.'

            # Items the user ticked by hand are never unticked by select-all.
            [void](Switch-SelectorFindingSelection -Page $page -RowIndex (Get-LayoutFindingRowIndex -Page $page -Name 'Duohui temporary package'))
            [void](Invoke-SelectorSelectAllDeletable -Page $page)
            Assert-TestTrue $page.Data['Selection'].ContainsKey($idOf['Duohui temporary package']) 'A hand-ticked item stays ticked.'
            $expectedWithBase = Get-W360DeletableSelection -Findings $protectedFindings -CandidateIds ([string[]]@($page.Data['SelectableById'].Keys)) -SelectedIds @($idOf['Duohui temporary package'])
            Assert-TestEqual (Get-LayoutSortedIds -Ids $expectedWithBase.Ids) (Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)) 'Select-all with a hand-ticked item follows the library.'
        }
        finally { $page.Root.Dispose() }

        # The note still explains a product click that depends on another product.
        $notePage = New-SelectorScanResultPage -Outcome $scanComplete
        try {
            $installGroup = Get-LayoutGroupRowIndex -Page $notePage -Key '360InstallDir'
            Assert-TestTrue (Switch-SelectorGroupSelection -Page $notePage -RowIndex $installGroup) 'The install folder product click runs.'
            Assert-TestEqual 0 $notePage.Data['Selection'].Count 'A folder that holds an unticked item of another product is not ticked.'
            Assert-TestTrue $notePage.Data['SelectionNote'].Visible 'The product click explains what was skipped.'
            Assert-TestEqual '“360 程序文件夹（32 位）”没有帮你选上：里面还有没勾选的东西。' $notePage.Data['SelectionNote'].Text 'One skipped item is named without "for example".'
            [void](Switch-SelectorFindingSelection -Page $notePage -RowIndex (Get-LayoutFindingRowIndex -Page $notePage -Name 'Duohui temporary package'))
            Assert-TestFalse $notePage.Data['SelectionNote'].Visible 'Any other selection change clears the note.'
            [void](Switch-SelectorGroupSelection -Page $notePage -RowIndex $installGroup)
            Assert-TestTrue $notePage.Data['SelectionNote'].Visible 'The note comes back with the next skipped product click.'
            Clear-SelectorSelection -Page $notePage
            Assert-TestFalse $notePage.Data['SelectionNote'].Visible 'Clear hides the skipped note.'
        }
        finally { $notePage.Root.Dispose() }

        $plainPage = New-SelectorScanResultPage -Outcome $scanOutcome
        try {
            [void](Invoke-SelectorSelectAllDeletable -Page $plainPage)
            $plainExpected = Get-W360DeletableSelection -Findings $findings -CandidateIds ([string[]]@($plainPage.Data['SelectableById'].Keys)) -SelectedIds @()
            Assert-TestEqual (Get-LayoutSortedIds -Ids $plainExpected.Ids) (Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $plainPage)) 'Select-all without skipped items.'
            Assert-TestEqual @($plainPage.Data['SelectableById'].Keys).Count $plainPage.Data['Selection'].Count 'Every deletable item is ticked when nothing needs skipping.'
            Assert-TestFalse $plainPage.Data['SelectionNote'].Visible 'No note when nothing was skipped.'
            foreach ($groupInfo in @($plainPage.Data['Groups'])) {
                $expectedState = if (@($groupInfo.Group.SelectableIds).Count -gt 0) { 'Checked' } else { 'Disabled' }
                Assert-TestEqual $expectedState ([string]$groupInfo.CheckState) "Product $($groupInfo.Group.Key) after select-all."
            }
        }
        finally { $plainPage.Root.Dispose() }
    }

    Invoke-TestCase -Run $run -Name 'product checkbox on a product that is only partly safe: shrinks, unticks, never grows or locks up' -Test {
        $local = 'C:\Users\Fixture User\AppData\Local'
        # Both folders can be deleted, but "Program Files\360" holds a running program of another product: ticking the
        # product alone ticks only the other folder (the shrink), and a second click unticks it.
        $partFindings = @(
            (New-LayoutFinding -Name '360 Program Files (x86)' -Target 'C:\Program Files (x86)\360' -ProductKey '360InstallDir' -Reason 'Exact vendor product directory with local 360/Qihoo file evidence.'),
            (New-LayoutFinding -Name '360 Program Files' -Target 'C:\Program Files\360' -ProductKey '360InstallDir' -Reason 'Exact vendor product directory with local 360/Qihoo file evidence.'),
            (New-LayoutFinding -Kind 'Process' -Name '360sd.exe (5150)' -Target '5150' -RemovalType 'Process' -ProductKey '360Security' `
                    -ValueName 'C:\Program Files\360\360sd\360sd.exe' -Reason 'Executable path under confirmed target: C:\Program Files\360'),
            (New-LayoutFinding -Name 'Duohui temporary package' -Target "$local\Temp\duohuipingbao" -Reason 'Known duohuipingbao staging path.')
        )
        $partOutcome = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings $partFindings -CoverageComplete $true
        $page = New-SelectorScanResultPage -Outcome $partOutcome
        try {
            $installGroup = Get-LayoutGroupRowIndex -Page $page -Key '360InstallDir'
            $groupIds = @($page.Grid.Rows[$installGroup].Tag.Group.SelectableIds)
            Assert-TestEqual 2 $groupIds.Count 'The fixture product has two deletable folders.'
            $expected = Get-W360DeletableSelection -Findings $partFindings -CandidateIds ([string[]]$groupIds) -SelectedIds @()
            Assert-TestEqual 1 @($expected.Ids).Count 'The fixture product shrinks to one safe folder.'
            $safeIds = Get-LayoutSortedIds -Ids $expected.Ids
            foreach ($round in 1..2) {
                Assert-TestTrue (Switch-SelectorGroupSelection -Page $page -RowIndex $installGroup) "Click 1 of round $round runs."
                Assert-TestEqual $safeIds (Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)) "Click 1 of round $round ticks exactly the safe folder."
                Assert-TestEqual 'Indeterminate' ([string]$page.Grid.Rows[$installGroup].Tag.CheckState) "Click 1 of round $round leaves the product mixed."
                Assert-TestTrue $page.Data['SelectionNote'].Visible "Click 1 of round $round explains the skipped folder."
                Assert-TestTrue ([bool](Get-W360SelectionPlan -Findings $partFindings -SelectedIds (Get-SelectorSelectedIds -Page $page)).CanSubmit) "Click 1 of round $round passes the selection check."
                Assert-TestTrue (Switch-SelectorGroupSelection -Page $page -RowIndex $installGroup) "Click 2 of round $round runs."
                Assert-TestEqual 0 $page.Data['Selection'].Count "Click 2 of round $round unticks the product (it never locks up)."
                Assert-TestEqual 'Unchecked' ([string]$page.Grid.Rows[$installGroup].Tag.CheckState) "Click 2 of round $round leaves the product unticked."
            }
            # With another product ticked, the product click still adds exactly the safe folder and keeps the other one.
            [void](Switch-SelectorFindingSelection -Page $page -RowIndex (Get-LayoutFindingRowIndex -Page $page -Name 'Duohui temporary package'))
            [void](Switch-SelectorGroupSelection -Page $page -RowIndex $installGroup)
            $withOther = Get-W360DeletableSelection -Findings $partFindings -CandidateIds ([string[]]$groupIds) -SelectedIds @($partFindings[3].SelectionId)
            Assert-TestEqual (Get-LayoutSortedIds -Ids $withOther.Ids) (Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)) 'The product click follows the library with another product ticked.'
            [void](Switch-SelectorGroupSelection -Page $page -RowIndex $installGroup)
            Assert-TestEqual (Get-LayoutSortedIds -Ids @($partFindings[3].SelectionId)) (Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)) 'Unticking the product keeps the other product.'
        }
        finally { $page.Root.Dispose() }
    }

    Invoke-TestCase -Run $run -Name 'an item that can never pass the selection check reads as kept and is never ticked by row, product, select-all or the add button' -Test {
        # The 32-bit 360 folder holds a kept folder, and an uninstaller inside it needs that folder: both can be deleted
        # by the core rule, but never in this check result.
        $vendorInside = New-LayoutFinding -Kind 'VendorUninstaller' -Name '360 uninstaller' -Target 'C:\Program Files (x86)\360\uninst.exe' -RemovalType 'VendorUninstaller' `
            -ProductKey '360InstallDir' -Reason 'Exact Duohui uninstaller under a confirmed dhpingbao root with a valid Beijing Qihu Technology Co., Ltd. signature and Duohui/Huabao metadata. SHA-256: ABCDEF'
        $neverFindings = @($protectedFindings) + @($vendorInside)
        $folderId = [string]$idOf['360 Program Files (x86)']
        $vendorId = [string]$vendorInside.SelectionId
        $neverOutcome = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings $neverFindings -CoverageComplete $true
        Assert-TestSequenceEqual @($folderId, $vendorId) @($neverOutcome.EffectiveDeletable.Removed | ForEach-Object { [string]$_.SelectionId }) 'The fixture has two items that can never pass.'
        Assert-TestTrue ((Test-W360FindingSelectable -Finding $neverFindings[5]) -and (Test-W360FindingSelectable -Finding $vendorInside)) 'The core rule still allows both items.'

        # Building the page reuses the set the scan outcome carries: the selection check is not run again for the rows.
        $originalShrink = ${function:Get-W360DeletableSelection}
        $originalEffective = ${function:Get-W360EffectiveDeletableIds}
        $page = $null
        try {
            Set-Item -Path function:script:Get-W360DeletableSelection -Value { throw 'The scan page ran the selection check again.' }
            Set-Item -Path function:script:Get-W360EffectiveDeletableIds -Value { throw 'The scan page worked out the effective set again.' }
            $page = New-SelectorScanResultPage -Outcome $neverOutcome -SelectedIds @($folderId, $vendorId)
        }
        finally {
            Set-Item -Path function:script:Get-W360DeletableSelection -Value $originalShrink
            Set-Item -Path function:script:Get-W360EffectiveDeletableIds -Value $originalEffective
        }
        try {
            Assert-TestTrue ([object]::ReferenceEquals($page.Data['Effective'], $neverOutcome.EffectiveDeletable)) 'The page keeps the set of its scan outcome.'
            Assert-TestEqual 0 $page.Data['Selection'].Count 'A handed-back selection of items that can never pass is dropped.'
            foreach ($id in @($folderId, $vendorId)) { Assert-TestFalse $page.Data['SelectableById'].ContainsKey($id) "An item that can never pass is tickable: $id" }
            foreach ($id in @($page.Data['SelectableById'].Keys)) {
                Assert-TestTrue ($neverOutcome.EffectiveDeletable.IdSet.Contains([string]$id)) "The page offers an item outside the effective set: $id"
                $finding = @($neverFindings | Where-Object { [string]$_.SelectionId -eq $id })
                Assert-TestTrue ($finding.Count -eq 1 -and (Test-W360FindingSelectable -Finding $finding[0])) "The page offers an item the core rule refuses: $id"
            }

            # The rows: grey "won't delete" with the reason and a disabled checkbox.
            $folderRow = $page.Grid.Rows[(Get-LayoutFindingRowIndex -Page $page -Name '360 Program Files (x86)')]
            $vendorRow = $page.Grid.Rows[(Get-LayoutFindingRowIndex -Page $page -Name '360 uninstaller')]
            Assert-TestEqual '不删除：里面有要保留的东西' ([string]$folderRow.Cells[2].Value) 'The folder row says why it is kept.'
            Assert-TestEqual '不删除：要和它所在的文件夹一起删' ([string]$vendorRow.Cells[2].Value) 'The uninstaller row says why it is kept.'
            foreach ($row in @($folderRow, $vendorRow)) {
                Assert-TestFalse ([bool]$row.Tag.Selectable) "Row $($row.Index) is marked tickable."
                Assert-TestEqual '' ([string]$row.Tag.SelectionId) "Row $($row.Index) carries an ID."
                Assert-TestTrue (Test-LayoutColor -Color $row.DefaultCellStyle.ForeColor -Name 'ReviewText') "Row $($row.Index) is not grey."
                Assert-TestTrue ([string]$row.Cells[0].ToolTipText).StartsWith('不删除') "Row $($row.Index) checkbox tooltip."
                Assert-TestFalse (Switch-SelectorFindingSelection -Page $page -RowIndex $row.Index) "Row $($row.Index) toggles."
                [void](Invoke-SelectorScanGridActivate -Page $page -RowIndex $row.Index -ColumnIndex 0)
                Assert-TestEqual 0 $page.Data['Selection'].Count "Clicking the checkbox of row $($row.Index) ticks something."
            }
            Update-SelectorScanDetail -Page $page -RowIndex $folderRow.Index
            Assert-TestTrue ($page.DetailBox.Text.Contains('为什么不删除：') -and $page.DetailBox.Text.Contains('一起删掉')) ('The description says why the folder is kept: ' + $page.DetailBox.Text)
            Assert-TestFalse ($page.DetailBox.Text.Contains('删除后：')) 'The description of a kept folder does not describe deleting.'
            $info = Get-SelectorItemInfoText -Page $page
            Assert-TestTrue ($info.Contains('不删除：里面有要保留的东西') -and $info.Contains('不会删除。')) 'More info tells the same.'

            # The product: all its deletable items are outside the set, so it reads as kept and its checkbox is disabled.
            $installGroup = Get-LayoutGroupRowIndex -Page $page -Key '360InstallDir'
            $groupInfo = $page.Grid.Rows[$installGroup].Tag
            Assert-TestEqual 0 @($groupInfo.Group.SelectableIds).Count 'The product offers no IDs.'
            Assert-TestEqual 'Disabled' ([string]$groupInfo.CheckState) 'The product checkbox is disabled.'
            Assert-TestFalse ([bool]$groupInfo.Selectable) 'The product is not tickable.'
            Assert-TestEqual '不删除' ([string]$page.Grid.Rows[$installGroup].Cells[2].Value) 'Different reasons in one product fall back to the plain keep text.'
            Assert-TestTrue (Test-LayoutColor -Color $page.Grid.Rows[$installGroup].Cells[2].Style.ForeColor -Name 'ReviewText') 'The product decision is grey.'
            Assert-TestFalse (Switch-SelectorGroupSelection -Page $page -RowIndex $installGroup) 'The product checkbox toggles.'
            [void](Invoke-SelectorScanGridActivate -Page $page -RowIndex $installGroup -ColumnIndex 0)
            Assert-TestEqual 0 $page.Data['Selection'].Count 'The product checkbox ticks something.'
            Update-SelectorScanDetail -Page $page -RowIndex $installGroup
            Assert-TestTrue ($page.DetailBox.Text.Contains('可以删除 0 项，不删除 3 项。')) ('The product description counts them as kept: ' + $page.DetailBox.Text)

            # Select-all ticks every other deletable item and never these two; no note is needed.
            Assert-TestTrue (Invoke-SelectorSelectAllDeletable -Page $page) 'Select-all runs.'
            foreach ($id in @($folderId, $vendorId)) { Assert-TestFalse $page.Data['Selection'].ContainsKey($id) "Select-all ticked an item that can never pass: $id" }
            Assert-TestEqual (Get-LayoutSortedIds -Ids $neverOutcome.EffectiveDeletable.Ids) (Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)) 'Select-all ticks exactly the effective set.'
            Assert-TestFalse $page.Data['SelectionNote'].Visible 'Select-all needs no note.'
            Assert-TestTrue ([bool](Get-W360SelectionPlan -Findings $neverFindings -SelectedIds (Get-SelectorSelectedIds -Page $page)).CanSubmit) 'The select-all result passes the selection check.'
            Assert-TestEqual (Get-LayoutSortedIds -Ids @($page.Data['SelectableById'].Keys)) (Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)) 'Select-all ticks every tickable item.'

            # The add button: a plan that names the folder to add (the uninstaller needs it) offers nothing to add.
            $vendorPlan = Get-W360SelectionPlan -Findings $neverFindings -SelectedIds @($vendorId)
            $vendorProblem = @($vendorPlan.Problems | Where-Object { $_.Code -eq 'VendorUninstallerNeedsInstallRoot' })
            Assert-TestSequenceEqual @($folderId) @($vendorProblem[0].AddSelectionIds) 'The plan names the folder to add.'
            $deletableIds = [string[]]@($page.Data['SelectableById'].Keys)
            Assert-TestEqual 0 @(Get-SelectorPlanAddIds -Plan $vendorPlan -DeletableIds $deletableIds).Count 'The folder is never offered for adding.'
            $before = Get-LayoutSortedIds -Ids (Get-SelectorSelectedIds -Page $page)
            $added = @(Add-SelectorPlanChildren -Page $page -Plan $vendorPlan -SelectedIds (Get-SelectorSelectedIds -Page $page))
            Assert-TestEqual $before (Get-LayoutSortedIds -Ids $added) 'The add step adds nothing that can never pass.'
            Assert-TestFalse (@($added) -contains $folderId) 'The add step added the folder.'
            Invoke-LayoutDialogCase -Label 'PlanNeverAdd' -MainWindow -Build { New-SelectorPlanProblemDialog -Plan $vendorPlan -DeletableIds $deletableIds } -Check {
                param($dialog, $form, $label)
                Assert-TestFalse $dialog.Buttons.Contains('AddChildren') "$label must not offer adding an item that can never pass."
                Assert-TestEqual 0 ([int]$dialog.Data['AddCount']) "$label add count."
                Assert-TestEqual '/BackToEdit' (Get-LayoutButtonOrder -Page $dialog) "$label buttons."
            }
            # A plan that mixes a tickable child with one that can never pass offers only the tickable one.
            $mixedPlan = [pscustomobject]@{
                SelectedIds = [string[]]@()
                Problems    = @([pscustomobject]@{ Code = 'ParentContainsSelectableChild'; Message = 'm'; Resolution = 'r'; AddSelectionIds = [string[]]@($folderId, $idOf['360tray.exe (4242)'].ToLowerInvariant(), $vendorId) })
            }
            Assert-TestSequenceEqual @($idOf['360tray.exe (4242)']) @(Get-SelectorPlanAddIds -Plan $mixedPlan -DeletableIds $deletableIds) 'Only the tickable child is offered.'
            Clear-SelectorSelection -Page $page
            Assert-TestSequenceEqual @($idOf['360tray.exe (4242)']) @(Add-SelectorPlanChildren -Page $page -Plan $mixedPlan -SelectedIds @()) 'Only the tickable child is added.'
            Set-SelectorSelectedIds -Page $page -Ids @($folderId, $vendorId)
            Assert-TestEqual 0 $page.Data['Selection'].Count 'Setting the IDs of items that can never pass ticks nothing.'
        }
        finally { if ($null -ne $page) { $page.Root.Dispose() } }
    }

    Invoke-TestCase -Run $run -Name 'ticking an uninstaller that came with 360 removes every promise that unticked items stay' -Test {
        foreach ($scale in $script:LayoutScales) {
            Set-SelectorFontScale -Scale $scale
            $shell = New-SelectorMainForm
            try {
                $page = New-SelectorScanResultPage -Outcome $scanComplete
                Set-SelectorPage -Shell $shell -Page $page
                Invoke-LayoutPass -Form $shell.Form
                Assert-TestEqual (Get-SelectorText -Key 'Scan.Findings.Detail') $page.DetailLabel.Text 'Without an uninstaller the plain subtitle shows.'
                $vendorRow = Get-LayoutFindingRowIndex -Page $page -Name 'Duohui vendor uninstaller'
                $folderRow = Get-LayoutFindingRowIndex -Page $page -Name 'Duohui screen saver'
                [void](Switch-SelectorFindingSelection -Page $page -RowIndex $folderRow)
                [void](Switch-SelectorFindingSelection -Page $page -RowIndex $vendorRow)
                Invoke-LayoutPass -Form $shell.Form
                $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds (Get-SelectorSelectedIds -Page $page)
                Assert-TestTrue ([bool]$plan.CanSubmit -and [bool]$plan.VendorUninstallerSelected) 'The fixture ticks a submittable uninstaller.'
                Assert-TestEqual (Get-SelectorText -Key 'Scan.Findings.DetailVendor') $page.DetailLabel.Text 'The subtitle names the uninstaller risk.'
                $pageTexts = @(Get-LayoutWindowTexts -Form $shell.Form -Page $page) + @(Get-LayoutDescriptionTexts -Page $page)
                foreach ($promise in @('不会去删', '都会保留', '就会保留', '没勾选的本工具不会删除')) {
                    $offending = @($pageTexts | Where-Object { $_.Contains($promise) })
                    Assert-TestEqual 0 $offending.Count ("@{0}x: a kept promise is on the page while an uninstaller is ticked: {1}" -f $scale, ($offending -join ' | '))
                }
                Assert-LayoutCommon -Form $shell.Form -Page $page -Label ('Vendor subtitle @{0}x' -f $scale) -MainWindow
                [void](Switch-SelectorFindingSelection -Page $page -RowIndex $vendorRow)
                Assert-TestEqual (Get-SelectorText -Key 'Scan.Findings.Detail') $page.DetailLabel.Text 'Unticking the uninstaller brings the plain subtitle back.'
            }
            finally {
                $shell.Form.Dispose()
                Set-SelectorFontScale -Scale 1.0
            }
        }
    }

    Invoke-TestCase -Run $run -Name 'result pages open without a highlighted row in a shown window' -Test {
        $previousApp = $script:SelectorApp
        $app = New-SelectorApp -ReportDirectory $fixtureDirectory -CoreScriptPath (Join-Path $fixtureDirectory 'no-core.ps1') -PowerShellPath (Join-Path $fixtureDirectory 'no-powershell.exe')
        $script:SelectorApp = $app
        try {
            $app.Form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
            $app.Form.Location = New-Object Drawing.Point(20, 20)
            $app.Form.ShowInTaskbar = $false
            $app.Form.Show()
            for ($i = 0; $i -lt 10; $i++) { [Windows.Forms.Application]::DoEvents() }
            # The real order: a progress page first, then the result page replaces it.
            Show-SelectorPage -Page (New-SelectorProgressPage -Kind Scan)
            for ($i = 0; $i -lt 10; $i++) { [Windows.Forms.Application]::DoEvents() }
            $scanPage = New-SelectorScanResultPage -Outcome $scanComplete
            Show-SelectorPage -Page $scanPage
            for ($i = 0; $i -lt 30; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 5 }
            Assert-TestEqual 0 $scanPage.Grid.SelectedRows.Count 'The scan result list opens without a highlighted row.'
            Assert-TestEqual 0 $scanPage.Data['Selection'].Count 'The scan result list opens with nothing ticked.'
            $verifyPage = New-SelectorVerifyResultPage -Outcome (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 2 -Findings @($findings))
            Show-SelectorPage -Page $verifyPage
            for ($i = 0; $i -lt 30; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 5 }
            Assert-TestEqual 0 $verifyPage.Grid.SelectedRows.Count 'The verify result list opens without a highlighted row.'
        }
        finally {
            $app.Timer.Dispose()
            $app.Form.Dispose()
            $script:SelectorApp = $previousApp
        }
    }

    Invoke-TestCase -Run $run -Name 'scan keyboard: Space toggles, Left and Right collapse or expand, Enter is not bound' -Test {
        $shell = New-SelectorMainForm
        try {
            $page = New-SelectorScanResultPage -Outcome $scanComplete
            Set-SelectorPage -Shell $shell -Page $page
            Invoke-LayoutPass -Form $shell.Form
            Assert-TestNull $shell.Form.AcceptButton 'The scan page has no default button.'
            $duohui = Get-LayoutGroupRowIndex -Page $page -Key 'Duohui'
            $page.Grid.CurrentCell = $page.Grid.Rows[$duohui].Cells[1]
            $key = New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Right)
            Invoke-SelectorScanGridKey -Page $page -KeyInfo $key
            Assert-TestTrue ($key.Handled -and -not [bool]$page.Grid.Rows[$duohui].Tag.Collapsed) 'Right expands a product.'
            $key = New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Space)
            Invoke-SelectorScanGridKey -Page $page -KeyInfo $key
            Assert-TestTrue ($key.Handled -and $page.Data['Selection'].Count -eq 3) 'Space on a product toggles the product.'
            $child = Get-LayoutFindingRowIndex -Page $page -Name 'Duohui temporary package'
            $page.Grid.CurrentCell = $page.Grid.Rows[$child].Cells[1]
            $key = New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Space)
            Invoke-SelectorScanGridKey -Page $page -KeyInfo $key
            Assert-TestEqual 2 $page.Data['Selection'].Count 'Space on an item toggles the item.'
            $key = New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Enter)
            Invoke-SelectorScanGridKey -Page $page -KeyInfo $key
            Assert-TestFalse $key.Handled 'Enter is not bound.'
            Assert-TestEqual 2 $page.Data['Selection'].Count 'Enter changes nothing.'
            $page.Grid.CurrentCell = $page.Grid.Rows[$duohui].Cells[1]
            $key = New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Left)
            Invoke-SelectorScanGridKey -Page $page -KeyInfo $key
            Assert-TestTrue ($key.Handled -and [bool]$page.Grid.Rows[$duohui].Tag.Collapsed) 'Left collapses a product.'
            Assert-TestEqual 2 $page.Data['Selection'].Count 'Left keeps the selection.'
            # Paint every row state once (mixed, ticked, disabled glyphs) without the default error dialog.
            $bitmap = New-Object Drawing.Bitmap($script:LayoutWidth, $script:LayoutHeight)
            try { $shell.Form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $script:LayoutWidth, $script:LayoutHeight))) }
            finally { $bitmap.Dispose() }
        }
        finally { $shell.Form.Dispose() }
    }

    Invoke-TestCase -Run $run -Name 'scan page with a pre-existing selection keeps the grid in sync' -Test {
        Invoke-LayoutPageCase -Label 'ScanResultSelected' -Build {
            New-SelectorScanResultPage -Outcome $scanOutcome -SelectedIds @($idOf['Duohui screen saver'].ToLowerInvariant(), ('FF' * 32))
        } -Check {
            param($page, $form, $label)
            Assert-TestEqual 1 $page.Data['Selection'].Count "$label selection."
            Assert-TestTrue $page.PrimaryButton.Enabled "$label delete button must be enabled."
            $row = Get-LayoutFindingRowIndex -Page $page -Name 'Duohui screen saver'
            Assert-TestTrue ([bool]$page.Grid.Rows[$row].Cells[0].Value) "$label row check."
            Assert-TestEqual 'Indeterminate' ([string]$page.Grid.Rows[(Get-LayoutGroupRowIndex -Page $page -Key 'Duohui')].Tag.CheckState) "$label product is mixed."
        }
    }

    Invoke-TestCase -Run $run -Name 'no-match pages: nothing found and not fully checked stay different' -Test {
        $clean = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings @() -CoverageComplete $true
        Invoke-LayoutPageCase -Label 'NoMatches' -Build { New-SelectorNoMatchPage -Outcome $clean } -Check {
            param($page, $form, $label)
            Assert-TestEqual '没有找到 360 的内容' $page.HeadlineLabel.Text "$label headline."
            Assert-TestEqual '电脑上没有发现本工具认识的 360 软件。' $page.DetailLabel.Text "$label detail."
            Assert-TestTrue (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Success') "$label colour."
            Assert-TestEqual 'Close' $page.PrimaryButton.Name "$label primary."
            Assert-TestEqual '/Close/Rescan/HelpSummary' (Get-LayoutButtonOrder -Page $page) "$label buttons."
            Assert-TestNull $page.Data['CoverageLink'] "$label has no not-fully-checked link."
            Assert-TestNull $page.DetailBox "$label has no text box."
        }
        $incomplete = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings @() -CoverageComplete $false
        Invoke-LayoutPageCase -Label 'NoMatchesIncomplete' -Build { New-SelectorNoMatchPage -Outcome $incomplete } -Check {
            param($page, $form, $label)
            Assert-TestEqual '没有找到 360 的内容，但有些地方没检查完' $page.HeadlineLabel.Text "$label headline."
            Assert-TestTrue (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Warning') "$label colour."
            Assert-TestEqual 'Rescan' $page.PrimaryButton.Name "$label primary."
            Assert-TestEqual '/Rescan/Close/HelpSummary' (Get-LayoutButtonOrder -Page $page) "$label buttons."
            Assert-TestNull $page.DetailBox "$label has no text box."
            Assert-TestEqual 'CoverageDetails' $page.Data['CoverageLink'].Name "$label link."
            Assert-TestEqual '看看是哪些' $page.Data['CoverageLink'].Text "$label link text."
        }
        $coverage = New-SelectorCoverageDialog -Issues @($incomplete.CoverageIssues)
        try {
            Assert-TestEqual '没检查完的地方' $coverage.Data['Form'].Text 'Coverage window title.'
            Assert-TestTrue ($coverage.DetailBox.Text.Contains('定时自动运行的任务')) ('Coverage list: ' + $coverage.DetailBox.Text)
        }
        finally { $coverage.Data['Form'].Dispose() }
    }

    Invoke-TestCase -Run $run -Name 'selection-adjust dialog: nothing deleted yet, explicit add button only when the plan names items to add' -Test {
        $parentPlan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($idOf['360 Program Files (x86)'])
        Assert-TestFalse $parentPlan.CanSubmit 'Parent without child must not be submittable.'
        # The dialog offers only items that can be ticked on the scan page (its effectively deletable IDs).
        $pageDeletableIds = [string[]]@($scanOutcome.EffectiveDeletable.Ids)
        $dialogParameter = (Get-Command -Name New-SelectorPlanProblemDialog).Parameters['DeletableIds']
        Assert-TestTrue (@($dialogParameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -eq 1) 'The selection-adjust dialog needs the tickable IDs of the page.'
        Invoke-LayoutDialogCase -Label 'PlanAdd' -MainWindow -Build { New-SelectorPlanProblemDialog -Plan $parentPlan -DeletableIds $pageDeletableIds } -Check {
            param($dialog, $form, $label)
            Assert-TestEqual 'PlanDialog' $dialog.Kind "$label kind."
            Assert-TestEqual '还需要调整一下' $form.Text "$label title."
            Assert-TestEqual '还需要调整一下' $dialog.HeadlineLabel.Text "$label headline."
            Assert-TestEqual '还没有删除任何东西。' $dialog.DetailLabel.Text "$label says nothing was deleted."
            Assert-TestEqual '/AddChildren/BackToEdit' (Get-LayoutButtonOrder -Page $dialog) "$label buttons."
            Assert-TestEqual '把这 1 项也选上' $dialog.Buttons['AddChildren'].Text "$label add text says how many items are added."
            Assert-TestEqual 1 ([int]$dialog.Data['AddCount']) "$label add count."
            Assert-TestEqual ([Windows.Forms.DialogResult]::Yes) $dialog.Buttons['AddChildren'].DialogResult "$label add result."
            Assert-TestEqual '返回修改' $dialog.Buttons['BackToEdit'].Text "$label back text."
            Assert-TestEqual ([Windows.Forms.DialogResult]::Cancel) $dialog.Buttons['BackToEdit'].DialogResult "$label back result."
            Assert-TestTrue ([object]::ReferenceEquals($form.CancelButton, $dialog.Buttons['BackToEdit'])) "$label back is Cancel."
            Assert-TestTrue ([object]::ReferenceEquals($form.AcceptButton, $dialog.Buttons['BackToEdit'])) "$label back is the default."
            Assert-TestTrue ([object]::ReferenceEquals($dialog.InitialFocus, $dialog.Buttons['BackToEdit'])) "$label focus starts on back."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('可以把它们也勾上，或者不删“360 程序文件夹（32 位）”')) "$label resolution text."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('“360 程序文件夹（32 位）”里面还有你没勾选的“正在运行的程序：360tray”（共 1 项）')) ("$label problem text: " + $dialog.DetailBox.Text)
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('怎么办：')) "$label names what to do."
            Assert-LayoutInside -Control $dialog.Buttons['BackToEdit'] -Top $form -What "$label back button"
        }
        $page = New-SelectorScanResultPage -Outcome $scanOutcome
        try {
            $ids = @(Add-SelectorPlanChildren -Page $page -Plan $parentPlan -SelectedIds @($idOf['360 Program Files (x86)']))
            Assert-TestEqual (Get-LayoutSortedIds -Ids @($idOf['360 Program Files (x86)'], $idOf['360tray.exe (4242)'])) (Get-LayoutSortedIds -Ids $ids) 'The add step adds exactly the named child.'
            Set-SelectorSelectedIds -Page $page -Ids $ids
            Assert-TestEqual 2 $page.Data['Selection'].Count 'The explicit add selects parent and child.'
            $replan = Get-W360SelectionPlan -Findings $findings -SelectedIds (Get-SelectorSelectedIds -Page $page)
            Assert-TestTrue $replan.CanSubmit 'The re-run plan is submittable after adding the child.'
        }
        finally { $page.Root.Dispose() }

        $protectedPlan = Get-W360SelectionPlan -Findings $protectedFindings -SelectedIds @($idOf['360 Program Files (x86)'])
        Invoke-LayoutDialogCase -Label 'PlanProtected' -MainWindow -Build { New-SelectorPlanProblemDialog -Plan $protectedPlan -DeletableIds ([string[]]@($scanProtected.EffectiveDeletable.Ids)) } -Check {
            param($dialog, $form, $label)
            Assert-TestFalse ([bool]$protectedPlan.CanSubmit) "$label must not be submittable."
            Assert-TestSequenceEqual @($idOf['360tray.exe (4242)']) @($dialog.Data['AddIds']) "$label offers only the tickable child, never the protected item."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('要保留的')) "$label explains the protected item."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('请不要勾选')) "$label resolution."
            Assert-TestTrue ([object]::ReferenceEquals($form.AcceptButton, $dialog.Buttons['BackToEdit'])) "$label back is the default."
        }

        $tooMany = Get-W360SelectionPlan -Findings $findings -SelectedIds @(1..65 | ForEach-Object { New-LayoutId -Seed "too-many$_" })
        Invoke-LayoutDialogCase -Label 'PlanTooMany' -MainWindow -Build { New-SelectorPlanProblemDialog -Plan $tooMany -DeletableIds $pageDeletableIds } -Check {
            param($dialog, $form, $label)
            Assert-TestFalse $dialog.Buttons.Contains('AddChildren') "$label must not offer adding."
            Assert-TestEqual '/BackToEdit' (Get-LayoutButtonOrder -Page $dialog) "$label buttons."
            Assert-TestEqual 'BackToEdit' $dialog.PrimaryButton.Name "$label primary is back."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('一次最多只能删除 64 项')) "$label explains the limit."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('先取消一部分勾选')) "$label resolution."
            # 65 identical "does not match" problems are one numbered line with a count.
            $unknownMessage = Get-SelectorText -Key 'Plan.UnknownId.Message'
            Assert-TestEqual 1 ([regex]::Matches($dialog.DetailBox.Text, [regex]::Escape($unknownMessage)).Count) "$label repeats an identical problem only once."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('（这样的有 65 项）')) "$label counts the identical problems."
            Assert-TestEqual 2 @([regex]::Matches($dialog.DetailBox.Text, '(?m)^\d+\. ')).Count "$label has two numbered problems."
        }
    }

    Invoke-TestCase -Run $run -Name 'confirmation dialog: Cancel is the default, Delete is red, kept list and uninstaller warning' -Test {
        $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($idOf['Duohui screen saver'], $idOf['Duohui vendor uninstaller'], $idOf['Duohui temporary package'])
        Assert-TestTrue $plan.CanSubmit 'Duohui root + uninstaller + temp is submittable.'
        Assert-TestTrue ([bool]$plan.VendorUninstallerSelected) 'The fixture selects an uninstaller that came with 360.'
        Assert-TestThrows { New-SelectorConfirmDialog -Plan $plan -ReviewOnlyCount 4 } 'The confirmation needs every finding, not a count.'
        Invoke-LayoutDialogCase -Label 'Confirm' -MainWindow -Build { New-SelectorConfirmDialog -Plan $plan -AllFindings $findings } -Check {
            param($dialog, $form, $label)
            $back = $dialog.Buttons['BackToEdit']
            $confirm = $dialog.Buttons['ConfirmRemove']
            Assert-TestEqual 'ConfirmDialog' $dialog.Kind "$label kind."
            Assert-TestEqual '确定要删除吗？' $form.Text "$label title."
            Assert-TestEqual '确定要删除吗？' $dialog.HeadlineLabel.Text "$label headline."
            Assert-TestTrue (Test-LayoutColor -Color $dialog.HeadlineLabel.ForeColor -Name 'Danger') "$label headline is red."
            Assert-TestEqual '/BackToEdit/ConfirmRemove' (Get-LayoutButtonOrder -Page $dialog) "$label buttons."
            Assert-TestEqual '取消' $back.Text "$label cancel text."
            Assert-TestEqual '删除' $confirm.Text "$label delete text."
            Assert-TestTrue ([object]::ReferenceEquals($form.AcceptButton, $back)) "$label Enter must cancel."
            Assert-TestTrue ([object]::ReferenceEquals($form.CancelButton, $back)) "$label Esc must cancel."
            Assert-TestTrue ([object]::ReferenceEquals($dialog.AcceptButton, $back)) "$label default button is cancel."
            Assert-TestTrue ([object]::ReferenceEquals($dialog.InitialFocus, $back)) "$label focus starts on cancel."
            Assert-TestTrue ([object]::ReferenceEquals($dialog.PrimaryButton, $back)) "$label cancel is the highlighted button."
            Assert-TestFalse ([object]::ReferenceEquals($form.AcceptButton, $confirm)) "$label delete must never be the default."
            Assert-TestEqual ([Windows.Forms.DialogResult]::Cancel) $back.DialogResult "$label cancel result."
            Assert-TestEqual ([Windows.Forms.DialogResult]::OK) $confirm.DialogResult "$label delete result."
            Assert-TestEqual 'Danger' ([string]$confirm.Tag) "$label delete style."
            Assert-TestTrue $confirm.Enabled "$label delete enabled."
            Assert-TestTrue (Test-LayoutColor -Color $confirm.BackColor -Name 'Danger') "$label delete button is red."
            Assert-LayoutInside -Control $confirm -Top $form -What "$label delete button"
            Assert-TestTrue ($back.TabIndex -lt $confirm.TabIndex) "$label cancel comes first in tab order."
            Assert-TestNotNull $dialog.Data['VendorWarning'] "$label uninstaller warning."
            Assert-TestTrue ($dialog.Data['VendorWarning'].Text.Contains('你没选的部分也一起删掉')) "$label uninstaller warning text."
            Assert-TestTrue (Test-LayoutColor -Color $dialog.Data['VendorWarning'].ForeColor -Name 'Danger') "$label uninstaller warning is red."
            $boxText = $dialog.DetailBox.Text
            Assert-TestEqual 'ConfirmItems' $dialog.DetailBox.Name "$label list box."
            Assert-TestTrue $dialog.DetailBox.ReadOnly "$label list is read-only."
            $allText = (@(Get-LayoutControls -Root $form | ForEach-Object { [string]$_.Text }) -join "`n")
            foreach ($part in @('删除后不能恢复，也不会放进回收站', (Get-SelectorText -Key 'Ui.Confirm.KeptOther'), '360 安全浏览器（你没选）',
                    '360 系统驱动（系统驱动）', '说不清属于哪个 360 软件（不能确定是 360 的）', '删除前请先关闭 360 的软件', '请点“是”', '要删除的（3 项）：', '● 360 画报 / 多绘屏保（3 项）',
                    '运行多绘屏保自带的卸载程序', '删除后：', '多绘屏保安装文件夹：')) {
                Assert-TestTrue ($allText.Contains($part)) "$label must contain '$part'."
            }
            # With an uninstaller selected, nothing is promised to be kept; other products are only not deleted by this tool.
            Assert-TestFalse ($boxText.Contains('会保留的：')) "$label must not promise kept items while an uninstaller runs."
            Assert-TestFalse ($boxText.Contains((Get-SelectorText -Key 'Ui.Confirm.KeptSameProduct'))) "$label has no unticked parts of the uninstaller product."
            Assert-TestFalse ($boxText.Contains('不删除：')) "$label kept lines give the reason only."
            Assert-TestFalse ($boxText.Contains('C:\Users\Fixture User')) "$label lists names, not paths."
            Assert-TestEqual 1 ([regex]::Matches($allText, '回收站').Count) "$label says the Recycle Bin once."
        }
        # An uninstaller with an unticked part of its own product: that part is never promised to be kept.
        $splitPlan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($idOf['Duohui screen saver'], $idOf['Duohui vendor uninstaller'])
        Assert-TestTrue ([bool]$splitPlan.CanSubmit -and [bool]$splitPlan.VendorUninstallerSelected) 'The split fixture ticks the uninstaller and its folder.'
        Invoke-LayoutDialogCase -Label 'ConfirmVendorSplit' -MainWindow -Build { New-SelectorConfirmDialog -Plan $splitPlan -AllFindings $findings } -Check {
            param($dialog, $form, $label)
            $lines = @($dialog.DetailBox.Text -split "`r`n")
            $sameIndex = [Array]::IndexOf($lines, (Get-SelectorText -Key 'Ui.Confirm.KeptSameProduct'))
            $otherIndex = [Array]::IndexOf($lines, (Get-SelectorText -Key 'Ui.Confirm.KeptOther'))
            Assert-TestTrue ($sameIndex -ge 0 -and $otherIndex -gt $sameIndex) "$label has both kept sections, the uninstaller product first."
            $sameLines = @($lines[($sameIndex + 1)..($otherIndex - 1)] | Where-Object { $_.StartsWith([string][char]0x00B7 + ' ') })
            Assert-TestSequenceEqual @(([string][char]0x00B7 + ' 多绘屏保临时安装包（你没选）')) $sameLines "$label same-product section lists only the unticked Duohui part."
            $otherLines = @($lines[($otherIndex + 1)..($lines.Count - 1)] | Where-Object { $_.StartsWith([string][char]0x00B7 + ' ') })
            Assert-TestTrue ((@($otherLines) -join "`n").Contains('360 安全浏览器（你没选）')) "$label other products are in the other section."
            Assert-TestFalse ((@($otherLines) -join "`n").Contains('多绘屏保')) "$label no Duohui part is promised as not deleted."
            Assert-TestFalse ($dialog.DetailBox.Text.Contains('会保留的：')) "$label never says kept while an uninstaller runs."
        }
        $plainPlan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($idOf['Duohui temporary package'])
        Invoke-LayoutDialogCase -Label 'ConfirmPlain' -MainWindow -Build { New-SelectorConfirmDialog -Plan $plainPlan -AllFindings $findings } -Check {
            param($dialog, $form, $label)
            Assert-TestNull $dialog.Data['VendorWarning'] "$label has no uninstaller warning."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('会保留的：')) "$label kept title."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('多绘屏保安装文件夹（你没选）')) "$label lists unticked items of a partly ticked product."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('360 安全浏览器（你没选）')) "$label lists unticked products."
            Assert-TestTrue ([object]::ReferenceEquals($form.AcceptButton, $dialog.Buttons['BackToEdit'])) "$label Enter must cancel."
        }
        # The kept list stays short: at most ten lines plus a "more" line.
        $manyKept = @($findings) + @(1..12 | ForEach-Object { New-LayoutFinding -Name ('Duohui extra part ' + $_) -Target ('C:\Users\Fixture User\AppData\Local\duohui-extra-' + $_) })
        $keptText = Get-SelectorConfirmText -Plan $plainPlan -AllFindings $manyKept
        $keptTextLines = @($keptText -split "`r`n")
        $keptTitleIndex = [Array]::IndexOf($keptTextLines, (Get-SelectorText -Key 'Ui.Confirm.KeptTitle'))
        $keptLines = @($keptTextLines[($keptTitleIndex + 1)..($keptTextLines.Count - 1)] | Where-Object { $_.StartsWith([string][char]0x00B7 + ' ') })
        Assert-TestEqual 10 $keptLines.Count 'The kept list is capped at ten lines.'
        Assert-TestTrue ($keptText.Contains('……还有')) 'The kept list says how many more are not listed.'
        # Items with the same effect share one line that names them.
        $sharedImpact = Get-SelectorConfirmText -Plan (Get-W360SelectionPlan -Findings $manyKept -SelectedIds @($manyKept | Where-Object { [string]$_.Name -like 'Duohui extra part*' } | ForEach-Object { $_.SelectionId })) -AllFindings $manyKept
        Assert-TestEqual 1 @($sharedImpact -split "`r`n" | Where-Object { $_.Contains('等 12 项：') }).Count ('Twelve items with one effect are one line: ' + $sharedImpact)
    }

    Invoke-TestCase -Run $run -Name 'remove result pages: headline, counts, next step, short problem list and state buttons' -Test {
        $selectedForRemove = @($findings | Where-Object { [string]$_.ProductKey -eq '360InstallDir' })
        $completed = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -Actions @((New-LayoutAction -Action 'DeletePath' -Target 'C:\Users\Fixture User\AppData\Local\dhpingbao' -Result 'Success'))
        $restart = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ ServicesPendingRemoval = 1 } -Actions @((New-LayoutAction -Action 'DeleteService' -Target '360rp' -Result 'PendingRemoval'))
        $partialActions = @(1..9 | ForEach-Object { New-LayoutAction -Action 'DeletePath' -Target ("C:\Program Files (x86)\360\part$_") -Result 'Failed' -Detail 'ReasonCode=AccessDenied; Access to the path is denied.' })
        $partial = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ FailedActions = 9; ImmediateRemainingSelected = 2; ImmediateSelectedStillPresent = 2; ImmediateSelectedConfirmedAbsent = 1 } `
            -Actions $partialActions -ExitCode 2 -SelectedFindings $selectedForRemove
        $unknown = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ ImmediateRescanComplete = $false; ImmediateRemainingSelected = $null
            ImmediateSelectedConfirmedAbsent = $null; ImmediateSelectedStillPresent = $null; ImmediateSelectedUnknown = $null }
        $unknownNoReport = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -NoReport -ExitCode 0 -Events @([pscustomobject]@{ Phase = 'ElevatedStarted'; Detail = '' })
        $notStarted = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -NoReport -ExitCode 5 -Events @([pscustomobject]@{ Phase = 'ElevationCancelled'; Detail = '' })
        $vendorRan = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -Actions @((New-LayoutAction -Action 'RunVendorUninstaller' -Target 'C:\Users\Fixture User\AppData\Local\dhpingbao\uninst.exe' -Result 'Success'))
        $partialByCode = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -ExitCode 2
        $expected = @(
            @{ Name = 'Completed'; Outcome = $completed; State = 'Completed'; Primary = 'Close'; Color = 'Success'; Buttons = '/Close/VerifyNow/ViewDetails/HelpSummary'; Details = $true; Counts = $true },
            @{ Name = 'CompletedVendorRan'; Outcome = $vendorRan; State = 'Completed'; Primary = 'Close'; Color = 'Warning'; Buttons = '/Close/VerifyNow/ViewDetails/HelpSummary'; Details = $true; Counts = $true },
            @{ Name = 'NeedsRestart'; Outcome = $restart; State = 'NeedsRestart'; Primary = 'Close'; Color = 'Warning'; Buttons = '/Close/VerifyNow/ViewDetails/HelpSummary'; Details = $true; Counts = $false },
            @{ Name = 'Partial'; Outcome = $partial; State = 'Partial'; Primary = 'VerifyNow'; Color = 'Error'; Buttons = '/VerifyNow/ViewDetails/HelpSummary/Close'; Details = $true; Counts = $true },
            @{ Name = 'PartialByExitCode'; Outcome = $partialByCode; State = 'Partial'; Primary = 'VerifyNow'; Color = 'Error'; Buttons = '/VerifyNow/ViewDetails/HelpSummary/Close'; Details = $true; Counts = $false },
            @{ Name = 'Unknown'; Outcome = $unknown; State = 'Unknown'; Primary = 'VerifyNow'; Color = 'Warning'; Buttons = '/VerifyNow/ViewDetails/HelpSummary/Close'; Details = $true; Counts = $false },
            @{ Name = 'UnknownNoReport'; Outcome = $unknownNoReport; State = 'Unknown'; Primary = 'Rescan'; Color = 'Warning'; Buttons = '/Rescan/HelpSummary/Close'; Details = $false; Counts = $false },
            @{ Name = 'NotStarted'; Outcome = $notStarted; State = 'NotStarted'; Primary = 'Rescan'; Color = 'Neutral'; Buttons = '/Rescan/HelpSummary/Close'; Details = $false; Counts = $false }
        )
        $headlines = @{}
        foreach ($case in $expected) {
            Assert-TestEqual $case.State ([string]$case.Outcome.State) ('Fixture outcome state for ' + $case.Name + '.')
            $headlines[$case.State] = [string]$case.Outcome.Headline
            # The counts line backs only a finished result; it never sits under an uncertain or unfinished headline.
            Assert-TestEqual $case.Counts (-not [string]::IsNullOrWhiteSpace([string]$case.Outcome.CountsText)) ('Counts shown for ' + $case.Name + '.')
            Invoke-LayoutPageCase -Label ('Remove ' + $case.Name) -Build { New-SelectorRemoveResultPage -Outcome $case.Outcome } -Check {
                param($page, $form, $label)
                Assert-TestEqual 'RemoveResult' $page.Kind "$label kind."
                Assert-TestEqual $case.Primary $page.PrimaryButton.Name "$label primary."
                Assert-TestTrue $page.PrimaryButton.Enabled "$label primary enabled."
                Assert-TestEqual $case.Buttons (Get-LayoutButtonOrder -Page $page) "$label buttons."
                Assert-TestTrue (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name $case.Color) "$label headline colour."
                if ($case.Color -ne 'Success') {
                    Assert-TestFalse (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Success') "$label must not look like success."
                }
                if ($page.Buttons.Contains('ViewDetails')) { Assert-TestEqual $case.Details $page.Buttons['ViewDetails'].Enabled "$label details button." }
                Assert-TestFalse $page.Buttons.Contains('OpenReportFolder') "$label has no records-folder button on the page."
                Assert-TestEqual 1 @(Get-LayoutNamedControl -Root $form -Name 'Detail').Count "$label detail."
                Assert-TestEqual 1 @(Get-LayoutNamedControl -Root $form -Name 'NextSteps').Count "$label tells what to do next."
                Assert-TestTrue ($page.Data['NextStepsLabel'].Text.StartsWith('接下来：')) "$label next step prefix."
                Assert-TestEqual 0 @(Get-LayoutNamedControl -Root $form -Name 'StatsText').Count "$label statistics live in the Details window."
                Assert-TestEqual 0 @(Get-LayoutNamedControl -Root $form -Name 'ProblemGrid').Count "$label the full problem table lives in the Details window."
                Assert-LayoutInside -Control $page.Data['NextStepsLabel'] -Top $form -What "$label next step"
                if ([string]$case.Outcome.CountsText) { Assert-TestEqual 1 @(Get-LayoutNamedControl -Root $form -Name 'RemoveCounts').Count "$label counts." }
                else { Assert-TestNull $page.Data['CountsLabel'] "$label shows no counts without recorded numbers." }
            }
        }
        Assert-TestEqual 5 @($headlines.Values | Sort-Object -Unique).Count 'Every remove state has its own headline.'
        # The remaining detail variants are rendered too, so no text reaches the page without the plain-language walk.
        $variants = @(
            (Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ ImmediatePreservedNotConfirmedPresent = 1 }),
            (Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ ImmediatePreservedNotConfirmedPresent = 1; VendorUninstallersSucceeded = 1 }),
            (Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ ImmediateSelectedUnknown = 1; ImmediateRemainingSelected = 1 }),
            (Get-LayoutRemoveOutcome -Directory $fixtureDirectory -NoReport -ExitCode 1 -Events @([pscustomobject]@{ Phase = 'ValidatingApproval'; Detail = '' }) -StderrLines @()),
            (Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ ServicesPendingRemoval = 1; VendorUninstallersPending = 1 } -Actions @(
                    (New-LayoutAction -Action 'RunVendorUninstaller' -Target 'C:\x\uninst.exe' -Result 'Pending'),
                    (New-LayoutAction -Action 'DeletePath' -Target 'C:\x\y' -Result 'Skipped' -Detail 'ReasonCode=ReparsePoint; x'),
                    (New-LayoutAction -Action 'DeletePath' -Target 'C:\x\z' -Result 'Failed' -Detail 'ReasonCode=UnknownInspectionError; x'),
                    (New-LayoutAction -Action 'RepairPathAcl' -Target 'C:\x\w' -Result 'Failed' -Detail 'ReasonCode=AclRepairFailed; x')))
        )
        $variantShell = New-SelectorMainForm
        try {
            foreach ($variant in $variants) {
                $variantPage = New-SelectorRemoveResultPage -Outcome $variant
                Set-SelectorPage -Shell $variantShell -Page $variantPage
                Assert-LayoutPlainTexts -Texts (Get-LayoutWindowTexts -Form $variantShell.Form -Page $variantPage) -Label ('Remove variant ' + $variant.State + ' / ' + $variant.Detail)
                Assert-TestTrue ((Assert-LayoutQuotedButtons -Page $variantPage -Label ('Remove variant ' + $variant.State)) -ge 0) 'Quoted buttons of a remove variant.'
                if ([string]$variant.State -ne 'Completed' -and [string]$variant.State -ne 'Partial') { Assert-TestEqual '' ([string]$variant.CountsText) ('No counts under ' + $variant.State) }
            }
        }
        finally { $variantShell.Form.Dispose() }

        $page = New-SelectorRemoveResultPage -Outcome $completed
        try {
            Assert-TestEqual '删除完成' $page.HeadlineLabel.Text 'Completed headline.'
            Assert-TestTrue ($page.DetailLabel.Text.Contains('你选的 3 项都删掉了')) ('Completed detail: ' + $page.DetailLabel.Text)
            Assert-TestTrue ($page.Data['CountsLabel'].Text.Contains('删掉 3 项')) 'Completed counts.'
            $next = $page.Data['NextStepsLabel'].Text
            Assert-TestTrue ($next.StartsWith('接下来：可以关闭')) "Completed next step: $next"
            Assert-TestTrue ($next.Contains('不会自动重启')) 'Completed next step says the tool never restarts the PC.'
            Assert-TestTrue ($next.Contains('“检查上次删除的结果”')) 'Completed next step quotes the button that checks the last deletion.'
            Assert-TestEqual '检查上次删除的结果' $page.Buttons['VerifyNow'].Text 'The page button has the name the next step quotes.'
            Assert-TestNull $page.Data['ProblemList'] 'Completed has no problem list.'
        }
        finally { $page.Root.Dispose() }
        $page = New-SelectorRemoveResultPage -Outcome $restart
        try {
            Assert-TestTrue ($page.Data['NextStepsLabel'].Text.Contains('手动重启电脑')) 'Restart next step.'
            Assert-TestTrue ($page.Data['NextStepsLabel'].Text.Contains('检查上次删除的结果')) 'Restart next step quotes the home button.'
            Assert-TestNull $page.Data['CountsLabel'] 'A restart-needed page shows no counts.'
        }
        finally { $page.Root.Dispose() }
        $page = New-SelectorRemoveResultPage -Outcome $partial
        try {
            Assert-TestEqual '有些没删掉' $page.HeadlineLabel.Text 'Partial headline.'
            Assert-TestTrue ($page.Data['NextStepsLabel'].Text.Contains('先重启电脑')) 'Partial next step.'
            Assert-TestFalse ($page.Data['NextStepsLabel'].Text.Contains('强行')) 'Partial next step does not hint at forcing.'
            Assert-TestEqual '删掉 1 项 · 没删掉 2 项 · 不确定 0 项' $page.Data['CountsLabel'].Text 'Immediate selected counts are shown.'
            # Nine failures inside the same selected folder are one line, not five identical lines.
            $problemLines = @($page.Data['ProblemList'].Text -split "`r`n")
            Assert-TestEqual 1 $problemLines.Count ('Identical problems are one line: ' + $page.Data['ProblemList'].Text)
            Assert-TestTrue ($problemLines[0].Contains('Windows 不让删除')) ('Plain problem reason: ' + $problemLines[0])
            Assert-TestTrue ($problemLines[0].Contains('“360 程序文件夹（32 位）”') -and $problemLines[0].Contains('（9 处）')) ('Problem names the selected item and the count: ' + $problemLines[0])
        }
        finally { $page.Root.Dispose() }
        $manyActions = @(1..7 | ForEach-Object { New-LayoutAction -Action 'DeleteService' -Target ("Service$_") -Result 'Failed' -Detail 'x' })
        $manyGroups = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ FailedActions = 7 } -Actions $manyActions -ExitCode 2 -SelectedFindings @(
            1..7 | ForEach-Object { New-LayoutFinding -Kind 'Service' -Name ("服务$_") -Target ("Service$_") -RemovalType 'Service' -ProductKey '360Security' })
        $page = New-SelectorRemoveResultPage -Outcome $manyGroups
        try {
            $problemLines = @($page.Data['ProblemList'].Text -split "`r`n")
            Assert-TestEqual 6 $problemLines.Count 'Five different problems plus the more line.'
            Assert-TestTrue ($problemLines[5].Contains('还有 2 项，点“详细信息”查看。')) ('More line: ' + $problemLines[5])
        }
        finally { $page.Root.Dispose() }
        $page = New-SelectorRemoveResultPage -Outcome $vendorRan
        try {
            Assert-TestEqual (Get-SelectorText -Key 'Remove.Completed.VendorRan') $page.DetailLabel.Text 'After an uninstaller nothing unticked is promised.'
            Assert-TestFalse (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Success') 'A deletion that ran an uninstaller is not green.'
        }
        finally { $page.Root.Dispose() }
        $page = New-SelectorRemoveResultPage -Outcome $unknownNoReport
        try {
            Assert-TestTrue ($page.Data['NextStepsLabel'].Text.Contains('重新检查一遍电脑')) 'Without a result, the next step is a new check.'
            Assert-TestFalse ($page.Data['NextStepsLabel'].Text.Contains('检查上次删除的结果')) 'Without a result, the home check is never offered.'
            Assert-TestFalse $page.Buttons.Contains('VerifyNow') 'Without a result, the page does not offer to check a deletion it cannot show.'
        }
        finally { $page.Root.Dispose() }
        $page = New-SelectorRemoveResultPage -Outcome $notStarted
        try {
            Assert-TestEqual '没有删除任何东西' $page.HeadlineLabel.Text 'Not started headline.'
            Assert-TestTrue ($page.DetailLabel.Text.Contains('点了“否”')) ('Not started after the Windows prompt: ' + $page.DetailLabel.Text)
        }
        finally { $page.Root.Dispose() }

        Invoke-LayoutDialogCase -Label 'RemoveDetails' -Build { New-SelectorRemoveDetailsDialog -Outcome $partial } -Check {
            param($dialog, $form, $label)
            Assert-TestEqual 'RemoveDetailsDialog' $dialog.Kind "$label kind."
            Assert-TestEqual '详细信息' $form.Text "$label title."
            Assert-TestEqual 1 $dialog.Data['Tabs'].SelectedIndex "$label opens on what was not deleted."
            Assert-TestEqual 'ProblemsTab' $dialog.Data['Tabs'].TabPages[1].Name "$label second tab lists what was not deleted."
            Assert-TestEqual '/OpenReportFolder/Close' (Get-LayoutButtonOrder -Page $dialog) "$label buttons."
            Assert-TestTrue $dialog.Buttons['OpenReportFolder'].Enabled "$label records folder button."
            Assert-TestEqual '打开记录所在文件夹' $dialog.Buttons['OpenReportFolder'].Text "$label records folder text."
            Assert-TestTrue ([object]::ReferenceEquals($form.AcceptButton, $dialog.Buttons['Close'])) "$label close is Accept."
            Assert-TestTrue ([object]::ReferenceEquals($form.CancelButton, $dialog.Buttons['Close'])) "$label close is Cancel."
            Assert-TestTrue ([object]::ReferenceEquals($dialog.InitialFocus, $dialog.Buttons['Close'])) "$label focus on close."
            $stats = $dialog.Data['StatsText'].Text
            Assert-TestTrue ($stats.Contains('不等于磁盘实际增加的可用空间')) "$label logical size note."
            Assert-TestTrue ($stats.Contains([IO.Path]::GetFileName([string]$partial.ReportPath))) "$label names the record file."
            Assert-TestTrue ($stats.Contains('后台服务')) "$label lists places that were not fully checked."
            Assert-TestEqual 9 $dialog.Data['ProblemGrid'].Rows.Count "$label every problem is listed."
            Assert-TestTrue ([string]$dialog.Data['ProblemGrid'].Rows[8].Cells[3].Value).Contains('Windows 不让删除') "$label plain reason for problems after the fifth."
            Assert-TestTrue ([string]$dialog.Data['ProblemGrid'].Rows[0].Cells[3].ToolTipText).Contains('Access to the path is denied') "$label raw detail tooltip."
            Assert-TestEqual 9 $dialog.Data['ActionGrid'].Rows.Count "$label action log rows."
            Assert-TestTrue ([string]$dialog.Data['ActionGrid'].Rows[0].Cells[1].Value).Contains('(DeletePath)') "$label keeps the raw action."
            foreach ($tabIndex in @(1, 2)) {
                $dialog.Data['Tabs'].SelectedIndex = $tabIndex
                Invoke-LayoutPass -Form $form
                $grid = if ($tabIndex -eq 1) { $dialog.Data['ProblemGrid'] } else { $dialog.Data['ActionGrid'] }
                Assert-TestTrue ($grid.Height -ge 120) ("{0}: grid on tab {1} is only {2} px tall." -f $label, $tabIndex, $grid.Height)
                Assert-LayoutInside -Control $grid -Top $form -What "$label grid on tab $tabIndex"
            }
        }
        $details = New-SelectorRemoveDetailsDialog -Outcome $completed
        try {
            Assert-TestEqual 1 @(Get-LayoutNamedControl -Root $details.Data['Form'] -Name 'ProblemsNone').Count 'A clean deletion says there were no problems.'
            Assert-TestTrue ($details.Data['Tabs'].SelectedIndex -le 0) 'A clean deletion opens on the statistics.'
            $statsText = $details.Data['StatsText'].Text
            Assert-TestEqual 1 ([regex]::Matches($statsText, '文件逻辑大小').Count) ('The logical size label is not repeated: ' + $statsText)
            foreach ($oldLabel in @('选择清理的项目', '系统服务', '计划任务', '注册表', '厂商', '报告文件名')) {
                Assert-TestFalse ($statsText.Contains($oldLabel)) "The Details statistics use the main-window words, not '$oldLabel'."
            }
        }
        finally { $details.Data['Form'].Dispose() }
        Assert-TestNull (Get-Command -Name 'New-SelectorActionLogDialog' -ErrorAction SilentlyContinue) 'The action log lives in the Details window.'
    }

    Invoke-TestCase -Run $run -Name 'verify result pages: only non-empty sections, plain results, colours and primary button' -Test {
        $duohuiSelected = @(
            (New-LayoutItemStatus -Category 'Selected' -State 'Absent'),
            (New-LayoutItemStatus -Category 'Selected' -State 'Absent' -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' -Target 'C:\Users\Fixture User\AppData\Local\dhpingbao\uninst.exe')
        )
        $browserPreserved = New-LayoutItemStatus -Category 'Preserved' -State 'Present' -Name '360se6 browser application' `
            -Target 'C:\Users\Fixture User\AppData\Local\360se6\Application' -ProductKey '360SafeBrowser' -DetailCode 'DetectedSameIdentity'
        $browserGone = New-LayoutItemStatus -Category 'Preserved' -State 'Absent' -Name '360se6 browser application' `
            -Target 'C:\Users\Fixture User\AppData\Local\360se6\Application' -ProductKey '360SafeBrowser' -DetailCode 'ProbeAbsent'
        $newItem = New-LayoutItemStatus -Category 'New' -State 'New' -Name '360 Program Files (x86)' -Target 'C:\Program Files (x86)\360' -ProductKey '360InstallDir' -DetailCode 'NoSuchCode'
        $remainingSelected = @((New-LayoutItemStatus -Category 'Selected' -State 'Remaining' -DetailCode 'DetectedSameIdentity'),
            (New-LayoutItemStatus -Category 'Selected' -State 'Unknown' -Target 'C:\x' -DetailCode 'ProbeUnreadable'))
        $completed = Get-LayoutVerifyOutcome -Directory $fixtureDirectory -TaskVerification (New-LayoutTaskVerification -Status 'Completed' -Selected $duohuiSelected -Preserved @($browserPreserved))
        $cases = @(
            @{ Name = 'TaskCompleted'; Outcome = $completed; State = 'TaskCompleted'; Primary = 'Close'; Success = $true },
            @{ Name = 'TaskCompletedKeptGone'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -TaskVerification (New-LayoutTaskVerification -Status 'Completed' -Selected $duohuiSelected -Preserved @($browserGone))); State = 'TaskCompleted'; Primary = 'Close'; Success = $false },
            @{ Name = 'TaskCompletedIncomplete'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -CoverageComplete $false -ExitCode 3 -TaskVerification (New-LayoutTaskVerification -Status 'Completed' -Selected $duohuiSelected)); State = 'TaskCompleted'; Primary = 'Rescan'; Success = $false },
            @{ Name = 'TaskCompletedWithNew'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -TaskVerification (New-LayoutTaskVerification -Status 'Completed' -Selected $duohuiSelected -New @($newItem))); State = 'TaskCompletedWithNew'; Primary = 'Rescan'; Success = $false },
            @{ Name = 'TaskRemaining'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 2 -TaskVerification (New-LayoutTaskVerification -Status 'Remaining' -Selected $remainingSelected)); State = 'TaskRemaining'; Primary = 'Rescan'; Success = $false },
            @{ Name = 'TaskUnknown'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 3 -TaskVerification (New-LayoutTaskVerification -Status 'Unknown' -Selected @((New-LayoutItemStatus -Category 'Selected' -State 'Unknown' -DetailCode 'ProbeUnreadable')))); State = 'TaskUnknown'; Primary = 'Rescan'; Success = $false },
            @{ Name = 'TaskUnknownNoCount'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 3 -TaskVerification (New-LayoutTaskVerification -Status 'Unknown' -Selected $duohuiSelected)); State = 'TaskUnknown'; Primary = 'Rescan'; Success = $false },
            @{ Name = 'TaskUnavailable'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 3 -CoverageComplete $false -TaskVerification (New-LayoutTaskVerification -Status 'Unavailable' -UnavailableReason 'RemoveReportMissing')); State = 'TaskUnavailable'; Primary = 'Rescan'; Success = $false },
            @{ Name = 'GlobalClean'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory); State = 'GlobalClean'; Primary = 'Close'; Success = $true },
            @{ Name = 'GlobalRemaining'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 2 -Findings @($findings)); State = 'GlobalRemaining'; Primary = 'Rescan'; Success = $false },
            @{ Name = 'GlobalIncomplete'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 3 -CoverageComplete $false); State = 'GlobalIncomplete'; Primary = 'Rescan'; Success = $false },
            @{ Name = 'GlobalKeptOnly'; Outcome = (Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 0 -Findings @($findings | Where-Object { [string]$_.Confidence -ne 'Confirmed' -or [bool]$_.Offline })); State = 'GlobalKeptOnly'; Primary = 'Close'; Success = $false }
        )
        $headlines = @{}
        foreach ($case in $cases) {
            Assert-TestEqual $case.State ([string]$case.Outcome.State) ('Fixture verify state for ' + $case.Name + '.')
            # The kept-item-gone case shares the TaskCompleted headline on purpose; its detail differs.
            if ($case.Name -ne 'TaskCompletedKeptGone') { $headlines[$case.Name] = [string]$case.Outcome.Headline }
            Invoke-LayoutPageCase -Label ('Verify ' + $case.Name) -Build { New-SelectorVerifyResultPage -Outcome $case.Outcome } -Check {
                param($page, $form, $label)
                Assert-TestEqual 'VerifyResult' $page.Kind "$label kind."
                Assert-TestEqual 'VerifyGrid' $page.Grid.Name "$label grid name."
                Assert-TestEqual $case.Primary $page.PrimaryButton.Name "$label primary."
                $other = if ($case.Primary -eq 'Close') { 'Rescan' } else { 'Close' }
                Assert-TestEqual ('/' + $case.Primary + '/' + $other + '/HelpSummary') (Get-LayoutButtonOrder -Page $page) "$label buttons."
                Assert-TestFalse $page.Buttons.Contains('OpenReportFolder') "$label has no records-folder button on the page."
                Assert-TestEqual $case.Success (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Success') "$label success colour only for a clean and complete result."
                Assert-TestEqual '/Item/Result' ('/' + (@($page.Grid.Columns | ForEach-Object { $_.Name }) -join '/')) "$label column names."
                Assert-TestEqual '/内容/结果' ('/' + (@($page.Grid.Columns | ForEach-Object { $_.HeaderText }) -join '/')) "$label columns."
                $sectionKeys = @($page.Grid.Rows | Where-Object { [string]$_.Tag.Type -eq 'Group' } | ForEach-Object { [string]$_.Tag.Key })
                $expectedKeys = @(@($page.Outcome.GridSections) | Where-Object { @($_.Items).Count -gt 0 } | ForEach-Object { [string]$_.Key })
                Assert-TestEqual ($expectedKeys -join ',') ($sectionKeys -join ',') "$label sections."
                Assert-TestEqual $sectionKeys.Count $page.Data['SectionHeaderRows'].Count "$label section rows recorded."
                Assert-TestEqual 0 @($page.Grid.Rows | Where-Object { [string]$_.Tag.Type -eq 'None' }).Count "$label shows no empty sections."
                foreach ($row in $page.Grid.Rows) {
                    if ([string]$row.Tag.Type -eq 'Group') {
                        Assert-TestEqual ('{0}（{1} 项）' -f $row.Tag.Title, $row.Tag.Count) ([string]$row.Cells[0].Value) "$label section title."
                        Assert-TestTrue ([int]$row.Tag.Count -gt 0) "$label section is not empty."
                    }
                }
                Assert-TestEqual 'VerifyDetail' $page.DetailBox.Name "$label description box."
                Assert-TestFalse $page.Data['MoreInfoLink'].Enabled "$label more info waits for an item row."
                if ($null -ne $page.Data['NextStepsLabel']) { Assert-TestTrue ($page.Data['NextStepsLabel'].Text.StartsWith('接下来：')) "$label next step." }
            }
        }
        Assert-TestEqual $headlines.Count @($headlines.Values | Sort-Object -Unique).Count 'Every verify result has its own headline.'

        $page = New-SelectorVerifyResultPage -Outcome $completed
        try {
            Assert-TestEqual '上次选的都删干净了' $page.HeadlineLabel.Text 'Acceptance headline.'
            Assert-TestTrue ($page.DetailLabel.Text.Contains('你保留的内容还在，这是正常的。')) 'Kept items that are still there are normal.'
            $headers = @(Get-LayoutGridHeaderTexts -Grid $page.Grid -TextColumn 0)
            Assert-TestEqual '你保留的（1 项）|已删掉（2 项）' ($headers -join '|') 'Completed sections in order.'
            $rows = @($page.Grid.Rows | Where-Object { [string]$_.Tag.Type -eq 'Item' } | ForEach-Object { '{0}|{1}' -f $_.Cells[0].Value, $_.Cells[1].Value })
            Assert-TestTrue ((@($rows) -join "`n").Contains('360 安全浏览器程序文件|还在')) 'The kept browser is listed as still there.'
            Assert-TestTrue ((@($rows) -join "`n").Contains('多绘屏保安装文件夹|已删掉')) 'Duohui is listed as deleted.'
            $clearedRow = @($page.Grid.Rows | Where-Object { [string]$_.Tag.Type -eq 'Item' -and [string]$_.Tag.Key -eq 'Cleared' })[0].Index
            Update-SelectorVerifyDetail -Page $page -RowIndex $clearedRow
            Assert-TestTrue ($page.DetailBox.Text.Contains('直接查看过，确认它已经不在了')) ('Verify description shows the plain detail: ' + $page.DetailBox.Text)
            Assert-TestFalse ($page.DetailBox.Text.Contains('English detail for ProbeAbsent')) 'The raw English detail is not on the page.'
            Assert-TestTrue $page.Data['MoreInfoLink'].Enabled 'More info for a verify item.'
            Assert-TestTrue ((Get-SelectorItemInfoText -Page $page).Contains('English detail for ProbeAbsent')) 'More info keeps the raw detail.'
            Update-SelectorVerifyDetail -Page $page -RowIndex 0
            Assert-TestFalse $page.Data['MoreInfoLink'].Enabled 'No More info for a section row.'
        }
        finally { $page.Root.Dispose() }

        $page = New-SelectorVerifyResultPage -Outcome $cases[1].Outcome
        try {
            Assert-TestTrue ($page.DetailLabel.Text.Contains('你保留的内容里有 1 项不见了')) ('A kept item that is gone is reported: ' + $page.DetailLabel.Text)
            Assert-TestFalse ($page.DetailLabel.Text.Contains('这是正常的')) 'A gone kept item is never called normal.'
            $headers = @(Get-LayoutGridHeaderTexts -Grid $page.Grid -TextColumn 0)
            Assert-TestEqual '你保留的，但不见了（1 项）|已删掉（2 项）' ($headers -join '|') 'A gone kept item has its own section, never under kept.'
            $goneRow = @($page.Grid.Rows | Where-Object { [string]$_.Tag.Type -eq 'Item' -and [string]$_.Tag.Key -eq 'PreservedGone' })[0]
            Assert-TestTrue (Test-LayoutColor -Color $goneRow.Cells[1].Style.ForeColor -Name 'Warning') 'A gone kept item is shown in the warning colour.'
        }
        finally { $page.Root.Dispose() }
        $page = New-SelectorVerifyResultPage -Outcome $cases[11].Outcome
        try {
            $headers = @(Get-LayoutGridHeaderTexts -Grid $page.Grid -TextColumn 0)
            Assert-TestTrue ($headers[0].StartsWith('不删除的')) ('Kept items are listed: ' + ($headers -join '|'))
            Assert-TestTrue ($page.HeadlineLabel.Text.StartsWith('没有找到可以删除的 360 内容，但还有')) ('Kept-only headline: ' + $page.HeadlineLabel.Text)
            $keptRow = @($page.Grid.Rows | Where-Object { [string]$_.Tag.Type -eq 'Item' })[0]
            Assert-TestTrue ([string]$keptRow.Cells[1].Value).StartsWith('不删除') 'Each kept row says why it is not deleted.'
            Update-SelectorVerifyDetail -Page $page -RowIndex $keptRow.Index
            Assert-TestTrue ($page.DetailBox.Text.Split("`n").Count -ge 2) ('A kept row is explained: ' + $page.DetailBox.Text)
        }
        finally { $page.Root.Dispose() }
        $page = New-SelectorVerifyResultPage -Outcome $cases[4].Outcome
        try {
            $headers = @(Get-LayoutGridHeaderTexts -Grid $page.Grid -TextColumn 0)
            Assert-TestTrue ($headers[0].StartsWith('没删掉')) ('Not deleted comes first: ' + ($headers -join '|'))
            Assert-TestTrue ((@($headers) -join '|').Contains('没法确认或没检查完')) 'Unknown items are listed.'
            Assert-TestTrue (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Error') 'Remaining items are red.'
        }
        finally { $page.Root.Dispose() }
        foreach ($index in @(7, 10)) {
            $page = New-SelectorVerifyResultPage -Outcome $cases[$index].Outcome
            try {
                $headers = @(Get-LayoutGridHeaderTexts -Grid $page.Grid -TextColumn 0)
                Assert-TestEqual 1 $headers.Count ('Only the unfinished checks are listed for ' + $cases[$index].Name + ': ' + ($headers -join '|'))
                Assert-TestTrue ($headers[0].StartsWith('没法确认或没检查完')) ('Unfinished section for ' + $cases[$index].Name + '.')
            }
            finally { $page.Root.Dispose() }
        }
        Assert-TestEqual '上次选的都删干净了，但有些地方没检查完' ([string]$cases[2].Outcome.Headline) 'An incomplete check says so in the headline.'
        Assert-TestEqual '上次选的看起来都删掉了，但这次检查没做完整' ([string]$cases[6].Outcome.Headline) 'Unknown without a count invents no number.'
        Assert-TestEqual '没有找到还需要处理的 360 内容' ([string]$cases[8].Outcome.Headline) 'Global clean headline.'
    }

    Invoke-TestCase -Run $run -Name 'error and stopped pages: say what happened, keep technical text one click away' -Test {
        $cancelledScan = Get-W360ScanOutcome -ExitCode $null -ReportPath '' -Cancelled
        Invoke-LayoutPageCase -Label 'ErrorCancelled' -Build { New-SelectorPageForScanOutcome -Outcome $cancelledScan } -Check {
            param($page, $form, $label)
            Assert-TestEqual 'Error' $page.Kind "$label kind."
            Assert-TestEqual '检查已停止' $page.HeadlineLabel.Text "$label headline."
            Assert-TestEqual '检查没有做完，结果不能用。没有删除任何东西。' $page.DetailLabel.Text "$label says the check did not finish."
            Assert-TestTrue (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Neutral') "$label colour."
            Assert-TestEqual '/Rescan/HelpSummary/Close' (Get-LayoutButtonOrder -Page $page) "$label buttons."
            Assert-TestEqual 'Rescan' $page.PrimaryButton.Name "$label primary."
            Assert-TestEqual 'Scan' $page.Stage "$label stage."
            Assert-TestEqual 1 @(Get-LayoutNamedControl -Root $form -Name 'NextSteps').Count "$label tells what to do next."
            Assert-TestNull $page.Data['TechnicalLink'] "$label has no technical text."
            Assert-TestEqual 0 @(Get-LayoutNamedControl -Root $form -Name 'TechnicalText').Count "$label has no technical text box."
            Assert-TestNull $page.DetailBox "$label has no text box."
        }
        $cancelledVerify = Get-W360VerifyOutcome -ExitCode $null -ReportPath '' -Cancelled
        Invoke-LayoutPageCase -Label 'ErrorVerifyCancelled' -Build { New-SelectorPageForVerifyOutcome -Outcome $cancelledVerify } -Check {
            param($page, $form, $label)
            Assert-TestEqual 'Error' $page.Kind "$label kind."
            Assert-TestEqual 'Verify' $page.Stage "$label stage."
            Assert-TestEqual '检查已停止' $page.HeadlineLabel.Text "$label headline."
            Assert-TestTrue ($page.DetailLabel.Text.Contains('没有做完')) "$label says the check did not finish."
            Assert-TestFalse (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Success') "$label is not a success."
        }
        $failedScan = Get-W360ScanOutcome -ExitCode 1 -ReportPath '' -StderrLines @('boom')
        Invoke-LayoutPageCase -Label 'ErrorScanFailed' -Build { New-SelectorPageForScanOutcome -Outcome $failedScan } -Check {
            param($page, $form, $label)
            Assert-TestEqual '出了点问题' $page.HeadlineLabel.Text "$label headline."
            Assert-TestTrue (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Error') "$label colour."
            Assert-TestTrue ($page.DetailLabel.Text.Contains('没有删除任何东西')) "$label says nothing was deleted."
            Assert-TestEqual 0 @(Get-LayoutNamedControl -Root $form -Name 'NextSteps').Count "$label detail already carries the next step; it must not be repeated."
            Assert-TestTrue ($page.ErrorText.Contains('boom')) "$label keeps the error text."
            Assert-TestNotNull $page.Data['TechnicalLink'] "$label offers the technical text."
            Assert-TestEqual 'TechnicalLink' $page.Data['TechnicalLink'].Name "$label technical link name."
            Assert-TestEqual '更多信息' $page.Data['TechnicalLink'].Text "$label technical link text."
            Assert-TestFalse ((@(Get-LayoutWindowTexts -Form $form -Page $page) -join "`n").Contains('boom')) "$label the technical text is not on the page."
        }
        $technical = New-SelectorTechnicalTextDialog -ErrorText ([string]$failedScan.ErrorText)
        try {
            Assert-TestEqual 'TechnicalTextDialog' $technical.Kind 'Technical text kind.'
            Assert-TestTrue ($technical.DetailBox.Text.Contains('boom')) 'The technical window shows the error text.'
        }
        finally { $technical.Data['Form'].Dispose() }
        $badPath = Join-Path $fixtureDirectory 'bad-scan.json'
        [IO.File]::WriteAllText($badPath, '[1,2]')
        $invalidScan = Get-W360ScanOutcome -ExitCode 0 -ReportPath $badPath
        $failedVerify = Get-W360VerifyOutcome -ExitCode 1 -ReportPath '' -StderrLines @('boom')
        $invalidVerify = Get-W360VerifyOutcome -ExitCode 0 -ReportPath $badPath
        foreach ($errorCase in @(
                @{ Label = 'ErrorScanInvalid'; Build = { New-SelectorPageForScanOutcome -Outcome $invalidScan } },
                @{ Label = 'ErrorVerifyFailed'; Build = { New-SelectorPageForVerifyOutcome -Outcome $failedVerify } },
                @{ Label = 'ErrorVerifyInvalid'; Build = { New-SelectorPageForVerifyOutcome -Outcome $invalidVerify } })) {
            Invoke-LayoutPageCase -Label $errorCase.Label -Build $errorCase.Build -Check {
                param($page, $form, $label)
                Assert-TestEqual 'Error' $page.Kind "$label kind."
                Assert-TestEqual '出了点问题' $page.HeadlineLabel.Text "$label headline."
                Assert-TestTrue (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Error') "$label colour."
                Assert-TestTrue ($page.DetailLabel.Text.Contains('没有删除任何东西')) "$label says nothing was deleted."
                Assert-TestEqual '/Rescan/HelpSummary/Close' (Get-LayoutButtonOrder -Page $page) "$label buttons."
            }
        }
        Invoke-LayoutPageCase -Label 'ErrorReportChanged' -Build {
            New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Gui.Error.ReportChanged.Headline') -Detail (Get-SelectorText -Key 'Ui.Error.ReportChanged') -Stage Scan -NextSteps ''
        } -Check {
            param($page, $form, $label)
            Assert-TestTrue ($page.DetailLabel.Text.Contains('检查结果在你选择的时候被改动了')) "$label text."
            Assert-TestTrue ($page.DetailLabel.Text.Contains('没有删除任何东西')) "$label says nothing was deleted."
            Assert-TestNull $page.Data['TechnicalLink'] "$label has no technical link without technical text."
        }
        $noTechnical = New-SelectorTechnicalTextDialog -ErrorText ''
        try { Assert-TestTrue ($noTechnical.DetailBox.Text.Contains('没有更多技术信息')) 'The technical window placeholder.' }
        finally { $noTechnical.Data['Form'].Dispose() }
        $longError = (@(1..60 | ForEach-Object { "Line $_ of a long stack trace C:\Users\Fixture User\file.ps1" }) -join "`r`n")
        Invoke-LayoutPageCase -Label 'ErrorUnexpected' -Build {
            New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Gui.Error.Unexpected.Headline') -Detail (Get-SelectorText -Key 'Gui.Error.Unexpected.Detail') -ErrorText $longError
        } -Check {
            param($page, $form, $label)
            Assert-TestNotNull $page.Data['TechnicalLink'] "$label technical link."
        }
        foreach ($notDeleted in @(
                @{ Label = 'ErrorStartFailed'; Headline = 'Gui.Error.StartFailed.Headline'; Detail = 'Gui.Error.StartFailed.Detail'; Stage = 'Scan' },
                @{ Label = 'ErrorTaskRecordFailed'; Headline = 'Gui.Error.TaskRecordFailed.Headline'; Detail = 'Gui.Error.TaskRecordFailed.Detail'; Stage = 'Error' },
                @{ Label = 'ErrorRemoveStartFailed'; Headline = 'Remove.NotStarted.Headline'; Detail = 'Gui.Error.RemoveStartFailed.Detail'; Stage = 'Remove' })) {
            Invoke-LayoutPageCase -Label $notDeleted.Label -Build {
                New-SelectorErrorPage -Headline (Get-SelectorText -Key $notDeleted.Headline) -Detail (Get-SelectorText -Key $notDeleted.Detail) -ErrorText 'x' -Stage $notDeleted.Stage
            } -Check {
                param($page, $form, $label)
                Assert-TestTrue ($page.DetailLabel.Text.Contains('没有删除任何东西')) "$label says nothing was deleted."
                Assert-TestFalse (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Success') "$label is not a success."
            }
        }
        # A deletion whose result could not be read is uncertain: never "nothing deleted", never green.
        Invoke-LayoutPageCase -Label 'ErrorRemoveCrashed' -Build {
            New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Remove.Unknown.Headline') `
                -Detail (Get-SelectorText -Key 'Gui.Error.RemoveCrashed.Detail' -Arguments @((Get-SelectorText -Key 'Ui.Button.VerifyTask'))) -ErrorText 'x' -Stage Remove -Tone Warning -NextSteps ''
        } -Check {
            param($page, $form, $label)
            Assert-TestEqual '不确定有没有删干净' $page.HeadlineLabel.Text "$label headline."
            Assert-TestTrue (Test-LayoutColor -Color $page.HeadlineLabel.ForeColor -Name 'Warning') "$label colour."
            Assert-TestFalse ($page.DetailLabel.Text.Contains('没有删除任何东西')) "$label must not claim nothing was deleted."
            Assert-TestTrue ($page.DetailLabel.Text.Contains('检查上次删除的结果')) "$label quotes the home button."
        }
    }

    Invoke-TestCase -Run $run -Name 'Get help, not-fully-checked, technical and More info windows keep their buttons reachable' -Test {
        $helpText = (@('Windows 360 清理工具 · 问题信息') + @(1..80 | ForEach-Object { "- 文件夹 · 条目 $_ · C:\Program Files (x86)\360\item$_" })) -join "`r`n"
        Invoke-LayoutDialogCase -Label 'Help' -Build { New-SelectorHelpSummaryDialog -Text $helpText -SaveDirectory $fixtureDirectory -ReportPath ([string]$scanOutcome.ReportPath) } -Check {
            param($dialog, $form, $label)
            Assert-TestEqual 'HelpDialog' $dialog.Kind "$label kind."
            Assert-TestEqual '获取帮助' $form.Text "$label title."
            Assert-TestEqual '/Copy/SaveText/OpenGitHub/OpenReportFolder/Close' (Get-LayoutButtonOrder -Page $dialog) "$label buttons."
            Assert-TestEqual '/复制/保存成文件/打开求助网页/打开记录所在文件夹/关闭' ('/' + (@($dialog.Buttons.Values | ForEach-Object { $_.Text }) -join '/')) "$label button texts."
            Assert-TestTrue $dialog.Buttons['OpenReportFolder'].Enabled "$label records folder is available with a record."
            Assert-TestFalse $dialog.DetailBox.ReadOnly "$label preview must be editable."
            Assert-TestTrue ($dialog.DetailLabel.Text.Contains('不会自动上传')) "$label says nothing is uploaded."
            Assert-TestTrue ($dialog.DetailLabel.Text.Contains('可能有遗漏')) "$label does not overclaim the privacy clean-up."
            Assert-TestTrue ([object]::ReferenceEquals($form.CancelButton, $dialog.Buttons['Close'])) "$label close is Cancel."
            Assert-TestTrue ($dialog.DetailBox.Height -ge 60) "$label preview height."
        }
        $dialog = New-SelectorHelpSummaryDialog -Text 'summary text' -SaveDirectory $fixtureDirectory
        try {
            Assert-TestFalse $dialog.Buttons['OpenReportFolder'].Enabled 'Without a record the folder button is disabled.'
            # With no record path the action returns before anything is opened.
            Invoke-SelectorHelpDialogAction -Dialog $dialog -Action 'OpenFolder'
            Invoke-SelectorHelpDialogAction -Dialog $dialog -Action 'Save'
            $saved = @(Get-ChildItem -LiteralPath $fixtureDirectory -Filter '360-cleanup-help-*.txt')
            Assert-TestEqual 1 $saved.Count 'Save writes exactly one help file into the chosen directory.'
            Assert-TestTrue ($dialog.Data['StatusLabel'].Text.Contains($saved[0].FullName)) 'Save shows the saved path.'
        }
        finally { $dialog.Data['Form'].Dispose() }
        Assert-TestTrue ($script:SelectorHelpIssueUrl -eq 'https://github.com/LongXL6/windows-360-cleaner/issues/new?template=help.yml') 'Help issue URL.'
        Invoke-LayoutDialogCase -Label 'Coverage' -Build { New-SelectorCoverageDialog -Issues @($scanOutcome.CoverageIssues) } -Check {
            param($dialog, $form, $label)
            Assert-TestEqual '没检查完的地方' $form.Text "$label title."
            # Plain lines only; the raw English detail and names stay in Details and Get help.
            Assert-TestFalse ($dialog.DetailBox.Text.Contains('Scheduled-task inspection stopped')) "$label shows no raw English detail."
            Assert-TestFalse ($dialog.DetailBox.Text.Contains('SomeService')) "$label shows no raw names."
            Assert-TestTrue ($dialog.DetailBox.Text.Contains('后台服务没检查完') -and $dialog.DetailBox.Text.Contains('定时自动运行的任务没检查完')) "$label plain area lines."
            Assert-TestTrue ($dialog.DetailLabel.Text.Contains('已经列出来的结果是准的')) "$label intro says what the incomplete check means."
        }
        Invoke-LayoutDialogCase -Label 'Technical' -Build { New-SelectorTechnicalTextDialog -ErrorText 'boom' } -Check {
            param($dialog, $form, $label)
            Assert-TestTrue ([object]::ReferenceEquals($form.CancelButton, $dialog.Buttons['Close'])) "$label close is Cancel."
        }
        $infoPage = New-SelectorScanResultPage -Outcome $scanComplete
        try {
            Update-SelectorScanDetail -Page $infoPage -RowIndex (Get-LayoutFindingRowIndex -Page $infoPage -Name 'Duohui vendor uninstaller')
            Invoke-LayoutDialogCase -Label 'MoreInfo' -Build { New-SelectorItemInfoDialog -Page $infoPage } -Check {
                param($dialog, $form, $label)
                Assert-TestEqual '更多信息' $form.Text "$label title."
                Assert-TestTrue ($dialog.DetailBox.Text.Contains('SelectionId')) "$label keeps technical fields."
            }
        }
        finally { $infoPage.Root.Dispose() }
    }

    Invoke-TestCase -Run $run -Name 'Get help from every page gets the redacted summary, the record of that page and the fixed help address' -Test {
        $previousApp = $script:SelectorApp
        $originalDialog = ${function:Show-SelectorDialog}
        $originalOpenFolder = ${function:Open-SelectorReportFolder}
        $originalBrowser = ${function:Open-SelectorHelpBrowser}
        $script:LayoutRecorded = New-Object System.Collections.ArrayList
        $script:LayoutLastDialog = $null
        $app = New-SelectorApp -ReportDirectory $fixtureDirectory -CoreScriptPath (Join-Path $fixtureDirectory 'no-core.ps1') -PowerShellPath (Join-Path $fixtureDirectory 'no-powershell.exe')
        $script:SelectorApp = $app
        try {
            # Recorders: nothing is shown, opened or started.
            Set-Item -Path function:script:Show-SelectorDialog -Value {
                param($Dialog)
                [void]$script:LayoutRecorded.Add(('dialog:' + [string]$Dialog.Kind))
                $script:LayoutLastDialog = $Dialog
                return [Windows.Forms.DialogResult]::Cancel
            }
            Set-Item -Path function:script:Open-SelectorReportFolder -Value { param([string]$Path) [void]$script:LayoutRecorded.Add(('open-folder:' + $Path)) }
            Set-Item -Path function:script:Open-SelectorHelpBrowser -Value { param([string]$Target) [void]$script:LayoutRecorded.Add(('browser:' + $Target)) }

            $computer = [Environment]::MachineName
            $userName = [Environment]::UserName
            $profilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
            $privateError = ('Failure on {0} for {1} under {2}\Documents\secret-plan.txt' -f $computer, $userName, $profilePath)
            $removeRecord = [string](Get-LayoutRemoveOutcome -Directory $fixtureDirectory).ReportPath
            $noMatchOutcome = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings @()
            $verifyOutcome = Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 2 -Findings @($findings)
            $pages = @(
                @{ Label = 'scan result'; Page = (New-SelectorScanResultPage -Outcome $scanComplete); Record = [string]$scanComplete.ReportPath },
                @{ Label = 'no match'; Page = (New-SelectorNoMatchPage -Outcome $noMatchOutcome); Record = [string]$noMatchOutcome.ReportPath },
                @{ Label = 'remove result'; Page = (New-SelectorRemoveResultPage -Outcome (Get-W360RemoveOutcome -ExitCode 0 -ReportPath $removeRecord -ExpectedApprovedReportHash ('AB' * 32))); Record = $removeRecord },
                @{ Label = 'verify result'; Page = (New-SelectorVerifyResultPage -Outcome $verifyOutcome); Record = [string]$verifyOutcome.ReportPath },
                @{ Label = 'error'; Page = (New-SelectorErrorPage -Headline 'x' -Detail 'y' -ErrorText $privateError -Stage Error -ReportPath $removeRecord); Record = $removeRecord }
            )
            foreach ($entry in $pages) {
                $page = $entry.Page
                $page.ErrorText = $privateError
                try {
                    $script:LayoutRecorded.Clear()
                    Show-SelectorHelpSummaryForPage -Page $page
                    $dialog = $script:LayoutLastDialog
                    Assert-TestEqual 'HelpDialog' ([string]$dialog.Kind) ($entry.Label + ': Get help opens the help window.')
                    Assert-TestFalse ([string]::IsNullOrWhiteSpace([string]$entry.Record)) ($entry.Label + ': the fixture page has a record.')
                    Assert-TestEqual ([string]$entry.Record) ([string]$dialog.ReportPath) ($entry.Label + ': the help window gets the record of the page.')
                    Assert-TestTrue $dialog.Buttons['OpenReportFolder'].Enabled ($entry.Label + ': the records folder can be opened.')
                    $preview = [string]$dialog.DetailBox.Text
                    foreach ($secret in @($computer, $profilePath)) {
                        if ($secret.Length -ge 3) { Assert-TestFalse ($preview.IndexOf($secret, [StringComparison]::OrdinalIgnoreCase) -ge 0) ($entry.Label + ': the help preview leaked ' + $secret) }
                    }
                    if ($userName.Length -ge 3) {
                        Assert-TestFalse ($preview -match ('(?<![A-Za-z0-9_\-])' + [regex]::Escape($userName) + '(?![A-Za-z0-9_\-])')) ($entry.Label + ': the help preview leaked the user name.')
                    }
                    Assert-TestTrue ($dialog.DetailLabel.Text.Contains('不会自动上传')) ($entry.Label + ': the help window says nothing is uploaded.')
                    Invoke-SelectorHelpDialogAction -Dialog $dialog -Action 'OpenFolder'
                    Invoke-SelectorHelpDialogAction -Dialog $dialog -Action 'Browser'
                    Assert-TestSequenceEqual @('dialog:HelpDialog', ('open-folder:' + $entry.Record), ('browser:' + $script:SelectorHelpIssueUrl)) @($script:LayoutRecorded) `
                        ($entry.Label + ': open folder targets the record and the browser opens only the fixed help address.')
                    $dialog.DetailBox.Text = 'edited preview with https://example.invalid/?q=' + $computer
                    Assert-TestEqual $script:SelectorHelpIssueUrl (Get-SelectorHelpBrowserTarget -Dialog $dialog) ($entry.Label + ': the preview never becomes part of the address.')
                }
                finally {
                    if ($null -ne $script:LayoutLastDialog) { $script:LayoutLastDialog.Data['Form'].Dispose() }
                    $script:LayoutLastDialog = $null
                    $page.Root.Dispose()
                }
            }
        }
        finally {
            Set-Item -Path function:script:Show-SelectorDialog -Value $originalDialog
            Set-Item -Path function:script:Open-SelectorReportFolder -Value $originalOpenFolder
            Set-Item -Path function:script:Open-SelectorHelpBrowser -Value $originalBrowser
            $app.Timer.Dispose()
            $app.Form.Dispose()
            $script:SelectorApp = $previousApp
        }
    }

    Invoke-TestCase -Run $run -Name 'delete request wiring: plan check before confirm, only Delete starts, changed record stops, closing blocked while deleting' -Test {
        $previousApp = $script:SelectorApp
        $originals = @{
            'Show-SelectorDialog'    = ${function:Show-SelectorDialog}
            'Show-SelectorMessage'   = ${function:Show-SelectorMessage}
            'Start-SelectorChildJob' = ${function:Start-SelectorChildJob}
            'New-W360TaskRecord'     = ${function:New-W360TaskRecord}
        }
        $script:LayoutRecorded = New-Object System.Collections.ArrayList
        $script:LayoutDialogAnswers = @{}
        $app = New-SelectorApp -ReportDirectory $fixtureDirectory -CoreScriptPath (Join-Path $fixtureDirectory 'no-core.ps1') -PowerShellPath (Join-Path $fixtureDirectory 'no-powershell.exe')
        $script:SelectorApp = $app
        try {
            # Recorders: no dialog is shown, no task record is written and no child process (let alone UAC) starts.
            Set-Item -Path function:script:Show-SelectorDialog -Value {
                param($Dialog)
                [void]$script:LayoutRecorded.Add(('dialog:' + [string]$Dialog.Kind))
                $answer = $script:LayoutDialogAnswers[[string]$Dialog.Kind]
                try { $Dialog.Data['Form'].Dispose() } catch {}
                if ($null -eq $answer) { return [Windows.Forms.DialogResult]::None }
                return $answer
            }
            Set-Item -Path function:script:Show-SelectorMessage -Value { param([string]$Text, $Icon, $Buttons, [switch]$SecondButtonDefault) [void]$script:LayoutRecorded.Add('message'); return [Windows.Forms.DialogResult]::No }
            Set-Item -Path function:script:Start-SelectorChildJob -Value {
                param($Kind, $CoreArguments, $ReportPath, $ProgressFilePath, $Context, [switch]$Global)
                [void]$script:LayoutRecorded.Add(('CHILD:' + $Kind + ':' + ((@($CoreArguments) -join ' ') -replace '.*-SelectedFindingIds (\S+).*', '$1')))
                return $true
            }
            Set-Item -Path function:script:New-W360TaskRecord -Value { [void]$script:LayoutRecorded.Add('task-record'); return 'task.json' }

            $parentOnly = @($idOf['360 Program Files (x86)'])
            $temp = @($idOf['Duohui temporary package'])
            $cases = @(
                @{ Label = 'Cancel in the confirmation'; Ids = $temp; Answers = @{ ConfirmDialog = [Windows.Forms.DialogResult]::Cancel }; Expected = @('dialog:ConfirmDialog') },
                @{ Label = 'window X on the confirmation'; Ids = $temp; Answers = @{}; Expected = @('dialog:ConfirmDialog') },
                @{ Label = 'Delete in the confirmation'; Ids = $temp; Answers = @{ ConfirmDialog = [Windows.Forms.DialogResult]::OK }; Expected = @('dialog:ConfirmDialog', 'task-record', ('CHILD:Remove:' + $temp[0])) },
                @{ Label = 'a failing plan, back to edit'; Ids = $parentOnly; Answers = @{ PlanDialog = [Windows.Forms.DialogResult]::Cancel; ConfirmDialog = [Windows.Forms.DialogResult]::OK }; Expected = @('dialog:PlanDialog') },
                @{ Label = 'a failing plan, add the named item, then Cancel'; Ids = $parentOnly; Answers = @{ PlanDialog = [Windows.Forms.DialogResult]::Yes; ConfirmDialog = [Windows.Forms.DialogResult]::Cancel }; Expected = @('dialog:PlanDialog', 'dialog:ConfirmDialog') }
            )
            foreach ($case in $cases) {
                $script:LayoutRecorded.Clear()
                $script:LayoutDialogAnswers = $case.Answers
                $page = New-SelectorScanResultPage -Outcome $scanComplete -SelectedIds $case.Ids
                $app.Shell.CurrentPage = $page
                try {
                    Invoke-SelectorCleanRequest -Page $page
                    Assert-TestSequenceEqual @($case.Expected) @($script:LayoutRecorded) ($case.Label + ': recorded steps.')
                    Assert-TestTrue $page.Buttons['CleanSelected'].Enabled ($case.Label + ': the delete button is usable again afterwards.')
                }
                finally { $page.Root.Dispose() }
            }
            # A folder with a protected item inside can never pass: a handed-back selection of it is dropped, and even
            # answering Yes to every dialog never reaches the confirmation or starts a deletion.
            $script:LayoutRecorded.Clear()
            $script:LayoutDialogAnswers = @{ PlanDialog = [Windows.Forms.DialogResult]::Yes; ConfirmDialog = [Windows.Forms.DialogResult]::OK }
            $protectedPage = New-SelectorScanResultPage -Outcome $scanProtected -SelectedIds $parentOnly
            try {
                Assert-TestEqual 0 $protectedPage.Data['Selection'].Count 'A folder with a protected item inside is never ticked on the page.'
                Invoke-SelectorCleanRequest -Page $protectedPage
                Assert-TestFalse (@($script:LayoutRecorded) -contains 'dialog:ConfirmDialog') 'A selection with a protected item inside never reaches the confirmation.'
                Assert-TestEqual 0 @($script:LayoutRecorded | Where-Object { [string]$_ -like 'CHILD:*' }).Count 'A selection with a protected item inside never starts a deletion.'
                Assert-TestEqual 0 $protectedPage.Data['Selection'].Count 'The add step never ticks the folder.'
            }
            finally { $protectedPage.Root.Dispose() }

            # The scan record changed while choosing: the error page shows and nothing starts.
            $script:LayoutRecorded.Clear()
            $changedCopy = Join-Path $fixtureDirectory ('360-cleanup-scan-20260913-100000-{0}.json' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
            [IO.File]::Copy([string]$scanComplete.ReportPath, $changedCopy)
            $changedOutcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $changedCopy
            [IO.File]::AppendAllText($changedCopy, ' ')
            $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds $temp
            Start-SelectorRemove -Plan $plan -ScanOutcome $changedOutcome
            Assert-TestEqual 0 $script:LayoutRecorded.Count 'A changed scan record writes no task record and starts nothing.'
            Assert-TestEqual 'Error' ([string]$app.Shell.CurrentPage.Kind) 'A changed scan record shows the error page.'
            Assert-TestTrue ([string]$app.Shell.CurrentPage.DetailLabel.Text).Contains('被改动了') 'The error page says the record changed.'

            # Closing while a deletion runs is refused; closing while checking asks and keeps running on No.
            $running = New-LayoutFakeChildState
            $app.Job = [pscustomobject]@{ Kind = 'Remove'; State = $running }
            $closing = New-Object Windows.Forms.FormClosingEventArgs([Windows.Forms.CloseReason]::UserClosing, $false)
            Invoke-SelectorFormClosing -ClosingInfo $closing
            Assert-TestTrue $closing.Cancel 'Closing the window during a deletion is refused.'
            $app.Job = [pscustomobject]@{ Kind = 'Scan'; State = $running }
            $closing = New-Object Windows.Forms.FormClosingEventArgs([Windows.Forms.CloseReason]::UserClosing, $false)
            Invoke-SelectorFormClosing -ClosingInfo $closing
            Assert-TestTrue $closing.Cancel 'Closing during a check is refused when the user answers No.'
            Assert-TestNotNull $app.Job 'The check keeps running after No.'
            $app.Job = $null
        }
        finally {
            foreach ($name in @($originals.Keys)) { Set-Item -Path ('function:script:' + $name) -Value $originals[$name] }
            $app.Timer.Dispose()
            $app.Form.Dispose()
            $script:SelectorApp = $previousApp
        }
    }

    Invoke-TestCase -Run $run -Name 'English pages keep the same layout guarantees and plain words' -Test {
        Set-W360UiLanguage -Language en
        try {
            $englishScan = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings $findings -CoverageComplete $false
            Invoke-LayoutPageCase -Label 'EN ScanResult' -Build { New-SelectorScanResultPage -Outcome $englishScan } -Check {
                param($page, $form, $label)
                Assert-TestEqual 'Segoe UI' $form.Font.Name "$label font."
                Assert-TestEqual ('Windows 360 Cleaner v' + $script:ExpectedToolVersion) $form.Text "$label title."
                Assert-TestEqual 'Select all deletable' $page.Buttons['SelectAllDeletable'].Text "$label select-all text."
                Assert-TestEqual "Won't delete: bookmarks and history" ([string]$page.Grid.Rows[(Get-LayoutFindingRowIndex -Page $page -Name '360se6 browser profile')].Cells[2].Value) "$label kept rows say what the tool will not do."
            }
            $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($idOf['Duohui screen saver'], $idOf['Duohui vendor uninstaller'])
            Invoke-LayoutDialogCase -Label 'EN Confirm' -MainWindow -Build { New-SelectorConfirmDialog -Plan $plan -AllFindings $findings } -Check {
                param($dialog, $form, $label)
                Assert-TestEqual 'Cancel' $dialog.Buttons['BackToEdit'].Text "$label cancel text."
                Assert-TestEqual 'Delete' $dialog.Buttons['ConfirmRemove'].Text "$label delete text."
            }
            $remove = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ ServicesPendingRemoval = 1 } -Actions @((New-LayoutAction -Action 'DeleteService' -Target '360rp' -Result 'PendingRemoval'))
            Invoke-LayoutPageCase -Label 'EN Remove' -Build { New-SelectorRemoveResultPage -Outcome $remove }
            $verify = Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 3 -CoverageComplete $false
            Invoke-LayoutPageCase -Label 'EN Verify' -Build { New-SelectorVerifyResultPage -Outcome $verify }
            Invoke-LayoutPageCase -Label 'EN Home' -Build { New-SelectorHomePage -TaskState (New-LayoutTaskState -Restarted $false -NewerUnusable 1) }
        }
        finally { Set-W360UiLanguage -Language zh }
    }

    Invoke-TestCase -Run $run -Name 'lists always show three whole rows on a small screen and never sit behind other rows' -Test {
        foreach ($language in @('zh', 'en')) {
            Set-W360UiLanguage -Language $language
            try {
                $languageScan = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings $protectedFindings -CoverageComplete $false
                # The skipped note appears for a product click that depends on another product (the folder holds 360tray).
                $languageNoteScan = Get-LayoutScanOutcome -Directory $fixtureDirectory -Findings $findings -CoverageComplete $false
                $languageVerify = Get-LayoutVerifyOutcome -Directory $fixtureDirectory -ExitCode 3 -CoverageComplete $false `
                    -TaskVerification (New-LayoutTaskVerification -Status 'Unknown' -Selected @(
                        (New-LayoutItemStatus -Category 'Selected' -State 'Unknown' -DetailCode 'ProbeUnreadable'),
                        (New-LayoutItemStatus -Category 'Selected' -State 'Absent' -Target 'C:\y'),
                        (New-LayoutItemStatus -Category 'Selected' -State 'Remaining' -Target 'C:\z' -DetailCode 'DetectedSameIdentity')))
                $builds = @(
                    @{ Name = 'banner'; Build = { New-SelectorScanResultPage -Outcome $languageScan } },
                    @{ Name = 'banner and note'; Build = {
                            $notePage = New-SelectorScanResultPage -Outcome $languageNoteScan
                            [void](Switch-SelectorGroupSelection -Page $notePage -RowIndex (Get-LayoutGroupRowIndex -Page $notePage -Key '360InstallDir'))
                            if (-not $notePage.Data['SelectionNote'].Visible) { throw 'The note build shows no note.' }
                            $notePage
                        }
                    },
                    @{ Name = 'uninstaller subtitle and note'; Build = {
                            $vendorPage = New-SelectorScanResultPage -Outcome $languageNoteScan
                            [void](Switch-SelectorGroupSelection -Page $vendorPage -RowIndex (Get-LayoutGroupRowIndex -Page $vendorPage -Key 'Duohui'))
                            [void](Switch-SelectorGroupSelection -Page $vendorPage -RowIndex (Get-LayoutGroupRowIndex -Page $vendorPage -Key '360InstallDir'))
                            if (-not $vendorPage.Data['SelectionNote'].Visible -or -not [bool]$vendorPage.Data['VendorSelected']) { throw 'The uninstaller build shows no note or no uninstaller subtitle.' }
                            $vendorPage
                        }
                    },
                    @{ Name = 'kept rows after select-all'; Build = {
                            $keptPage = New-SelectorScanResultPage -Outcome $languageScan
                            [void](Invoke-SelectorSelectAllDeletable -Page $keptPage)
                            $keptPage
                        }
                    },
                    @{ Name = 'verify'; Build = { New-SelectorVerifyResultPage -Outcome $languageVerify } }
                )
                foreach ($build in $builds) {
                    foreach ($scale in $script:LayoutScales) {
                        Set-SelectorFontScale -Scale $scale
                        $shell = New-SelectorMainForm
                        try {
                            $page = & $build.Build
                            Set-SelectorPage -Shell $shell -Page $page
                            Invoke-LayoutPass -Form $shell.Form
                            $label = '{0} {1} @{2}x' -f $language, $build.Name, $scale
                            $grid = $page.Grid
                            Assert-TestTrue (Test-LayoutShown -Control $grid -Top $shell.Form) "$label list is shown."
                            Assert-TestTrue ($grid.DisplayedRowCount($false) -ge 3) ("{0}: only {1} whole rows are visible (list {2} px)." -f $label, $grid.DisplayedRowCount($false), $grid.Height)
                            $gridRect = Get-LayoutRectangle -Control $grid -Top $shell.Form
                            Assert-TestNotNull $gridRect "$label list is not clipped."
                            foreach ($name in @('FindingDetail', 'VerifyDetail', 'CoverageBanner', 'SelectionCounter', 'SelectionNote', 'NextSteps', 'ButtonBar', 'Detail')) {
                                foreach ($other in @(Get-LayoutNamedControl -Root $page.Root -Name $name)) {
                                    if (-not (Test-LayoutShown -Control $other -Top $shell.Form)) { continue }
                                    $otherRect = Get-LayoutRectangle -Control $other -Top $shell.Form
                                    if ($null -eq $otherRect) { continue }
                                    Assert-TestFalse ($gridRect.IntersectsWith($otherRect)) ("{0}: the list overlaps '{1}' ({2} / {3})." -f $label, $name, $gridRect, $otherRect)
                                }
                            }
                            Assert-LayoutCommon -Form $shell.Form -Page $page -Label $label -MainWindow
                        }
                        finally {
                            $shell.Form.Dispose()
                            Set-SelectorFontScale -Scale 1.0
                        }
                    }
                }
            }
            finally { Set-W360UiLanguage -Language zh }
        }
        Assert-TestTrue ($script:LayoutQuotedButtonChecks -ge 20) ("Too few ""click X"" sentences were checked against the page buttons ({0})." -f $script:LayoutQuotedButtonChecks)
    }

    Invoke-TestCase -Run $run -Name 'core arguments: exact read-only scan/verify lines and a bounded remove line' -Test {
        Assert-TestSequenceEqual @('-Mode', 'Scan', '-ReportPath', 'C:\R\scan.json', '-EmitProgress') @(Get-SelectorScanArguments -ReportPath 'C:\R\scan.json') 'Scan arguments.'
        Assert-TestSequenceEqual @('-Mode', 'Verify', '-ReportPath', 'C:\R\v.json', '-EmitProgress') @(Get-SelectorVerifyArguments -ReportPath 'C:\R\v.json') 'Global verify arguments.'
        Assert-TestSequenceEqual @('-Mode', 'Verify', '-ReportPath', 'C:\R\v.json', '-EmitProgress', '-PreviousRemoveReport', 'C:\R\remove.json') `
            @(Get-SelectorVerifyArguments -ReportPath 'C:\R\v.json' -PreviousRemoveReport 'C:\R\remove.json') 'Task verify arguments.'
        $ids = @($idOf['Duohui screen saver'].ToLowerInvariant(), $idOf['Duohui temporary package'])
        $progress = New-W360ProgressFilePath
        $remove = @(Get-SelectorRemoveArguments -ScanReportPath 'C:\R\scan.json' -ScanReportHash ('ab' * 32) -SelectedIds $ids -RemoveReportPath 'C:\R\remove.json' -ProgressFilePath $progress)
        Assert-TestSequenceEqual @('-Mode', 'Remove', '-ConfirmRemoval', '-ConfirmationPhrase', 'REMOVE-CONFIRMED-360', '-ApprovedReport', 'C:\R\scan.json',
            '-ApprovedReportHash', ('AB' * 32), '-SelectedFindingIds', (($idOf['Duohui screen saver'], $idOf['Duohui temporary package']) -join ';'),
            '-ReportPath', 'C:\R\remove.json', '-EmitProgress', '-ElevatedProgressPath', $progress) $remove 'Remove arguments.'
        Assert-TestThrows { Get-SelectorRemoveArguments -ScanReportPath 'C:\R\scan.json' -ScanReportHash ('ab' * 32) -SelectedIds @() -RemoveReportPath 'C:\R\r.json' -ProgressFilePath $progress } 'Empty selection must be refused.'
        Assert-TestThrows { Get-SelectorRemoveArguments -ScanReportPath 'C:\R\scan.json' -ScanReportHash ('ab' * 32) -SelectedIds @(1..65 | ForEach-Object { New-LayoutId -Seed "a$_" }) -RemoveReportPath 'C:\R\r.json' -ProgressFilePath $progress } 'More than 64 IDs must be refused.'
        Assert-TestThrows { Get-SelectorRemoveArguments -ScanReportPath 'C:\R\scan.json' -ScanReportHash 'nothex' -SelectedIds $ids -RemoveReportPath 'C:\R\r.json' -ProgressFilePath $progress } 'A bad hash must be refused.'
        Assert-TestThrows { Get-SelectorRemoveArguments -ScanReportPath 'C:\R\scan.json' -ScanReportHash ('ab' * 32) -SelectedIds @($ids[0], $ids[0]) -RemoveReportPath 'C:\R\r.json' -ProgressFilePath $progress } 'Duplicate IDs must be refused.'
    }

    Invoke-TestCase -Run $run -Name 'scan report re-hash detects a report changed during selection' -Test {
        $path = [string]$scanOutcome.ReportPath
        Assert-TestTrue (Test-SelectorScanReportUnchanged -Path $path -ExpectedHash $scanOutcome.ReportHash) 'Unchanged report passes.'
        $copy = Join-Path $fixtureDirectory 'changed-scan.json'
        [IO.File]::Copy($path, $copy)
        $hash = Get-W360FileSha256 -Path $copy
        [IO.File]::AppendAllText($copy, ' ')
        Assert-TestFalse (Test-SelectorScanReportUnchanged -Path $copy -ExpectedHash $hash) 'A modified report must fail the re-hash.'
        Assert-TestFalse (Test-SelectorScanReportUnchanged -Path (Join-Path $fixtureDirectory 'missing.json') -ExpectedHash $hash) 'A missing report must fail.'
        Assert-TestFalse (Test-SelectorScanReportUnchanged -Path $path -ExpectedHash '') 'A missing expected hash must fail.'
    }

    Invoke-TestCase -Run $run -Name 'closing is blocked during Remove and asks to stop during Scan or Verify' -Test {
        $running = New-LayoutFakeChildState
        $done = New-LayoutFakeChildState
        $done.Completed = $true
        Assert-TestEqual 'Allow' (Get-SelectorCloseDecision -Job $null) 'No job.'
        Assert-TestEqual 'BlockRemove' (Get-SelectorCloseDecision -Job ([pscustomobject]@{ Kind = 'Remove'; State = $running })) 'Running remove.'
        Assert-TestEqual 'AskCancel' (Get-SelectorCloseDecision -Job ([pscustomobject]@{ Kind = 'Scan'; State = $running })) 'Running scan.'
        Assert-TestEqual 'AskCancel' (Get-SelectorCloseDecision -Job ([pscustomobject]@{ Kind = 'Verify'; State = $running })) 'Running verify.'
        Assert-TestEqual 'Allow' (Get-SelectorCloseDecision -Job ([pscustomobject]@{ Kind = 'Remove'; State = $done })) 'Finished remove.'
        Assert-TestThrows { Stop-W360ChildProcess -State ([pscustomobject]@{ ArgumentList = @('-Mode', 'Remove'); Completed = $false }) } 'The runner must refuse to cancel Remove.'
        Assert-TestTrue ((Get-SelectorText -Key 'Ui.Close.BlockedDuringRemove').Contains('不能中途停止')) 'Closing during a deletion explains it cannot be stopped.'
        Assert-TestTrue ((Get-SelectorText -Key 'Ui.Close.CancelFirst').Contains('没做完')) 'Closing during a check says the check has not finished.'
    }

    Invoke-TestCase -Run $run -Name 'timer tick is re-entrancy guarded and reads results only after completion' -Test {
        $previousApp = $script:SelectorApp
        $app = New-SelectorApp -ReportDirectory $fixtureDirectory -CoreScriptPath (Join-Path $fixtureDirectory 'no-core.ps1') -PowerShellPath (Join-Path $fixtureDirectory 'no-powershell.exe')
        $script:SelectorApp = $app
        try {
            $state = New-LayoutFakeChildState
            $progressPage = New-SelectorProgressPage -Kind Scan
            $app.Job = [pscustomobject]@{ Kind = 'Scan'; State = $state; ReportPath = [string]$scanOutcome.ReportPath; ProgressFilePath = ''
                Page = $progressPage; Context = $null; PollFailures = 0; LastPollError = '' }
            Show-SelectorPage -Page $progressPage
            [void]$state.Events.Add([pscustomobject]@{ Phase = 'ScanServices'; Detail = ''; Source = 'Stdout'; Time = (Get-Date) })

            $app.TimerBusy = $true
            Invoke-SelectorTimerTick
            Assert-TestTrue $app.TimerBusy 'A busy tick must return without touching the guard.'
            Assert-TestEqual 0 ([int]$progressPage.Data['RenderedEventCount']) 'A busy tick must not update the page.'

            $app.TimerBusy = $false
            Invoke-SelectorTimerTick
            Assert-TestFalse $app.TimerBusy 'The guard is released after a tick.'
            Assert-TestNotNull $app.Job 'A running job stays attached.'
            Assert-TestEqual 'ProgressScan' $app.Shell.CurrentPage.Kind 'The progress page stays while running.'
            Assert-TestEqual '正在查找在后台运行的 360 服务…' $progressPage.Data['PhaseLabel'].Text 'The tick updates the current step.'
            Assert-TestEqual 'AskCancel' (Get-SelectorCloseDecision -Job $app.Job) 'Close asks to stop while checking.'

            $state.ExitCode = 0
            $state.Completed = $true
            Invoke-SelectorTimerTick
            Assert-TestNull $app.Job 'A completed job is detached.'
            Assert-TestEqual 'ScanResult' $app.Shell.CurrentPage.Kind 'The completed scan shows the result page.'
            Assert-TestEqual 0 $app.Shell.CurrentPage.Data['Selection'].Count 'The result page of a finished check starts with nothing selected.'

            $selectedForRemove = @($findings | Where-Object { [string]$_.ProductKey -eq '360InstallDir' })
            foreach ($withSelection in @($true, $false)) {
                $removeState = New-LayoutFakeChildState
                $removeState.ArgumentList = [string[]]@('-Mode', 'Remove')
                $removeOutcomeFixture = Get-LayoutRemoveOutcome -Directory $fixtureDirectory -SummaryOverrides @{ FailedActions = 1 } `
                    -Actions @((New-LayoutAction -Action 'DeletePath' -Target 'C:\Program Files (x86)\360\part1' -Result 'Failed' -Detail 'ReasonCode=AccessDenied; denied'))
                $removeProgress = New-SelectorProgressPage -Kind Remove
                $context = if ($withSelection) {
                    [pscustomobject]@{ ScanReportHash = ('AB' * 32); ScanReportPath = ''; SelectedFindings = $selectedForRemove }
                }
                else { [pscustomobject]@{ ScanReportHash = ('AB' * 32) } }
                $app.Job = [pscustomobject]@{ Kind = 'Remove'; State = $removeState; ReportPath = [string]$removeOutcomeFixture.ReportPath
                    ProgressFilePath = (New-W360ProgressFilePath); Page = $removeProgress; Context = $context
                    PollFailures = 0; LastPollError = '' }
                Show-SelectorPage -Page $removeProgress
                Invoke-SelectorTimerTick
                Assert-TestEqual 'BlockRemove' (Get-SelectorCloseDecision -Job $app.Job) 'Close is blocked while deleting.'
                Assert-TestEqual 'ProgressRemove' $app.Shell.CurrentPage.Kind 'Remove progress stays while running.'
                Assert-TestEqual 0 $app.Shell.CurrentPage.Buttons.Count 'A running deletion offers no buttons.'
                [void]$removeState.Events.Add([pscustomobject]@{ Phase = 'ElevatedStarted'; Detail = ''; Source = 'File'; Time = (Get-Date) })
                $removeState.ExitCode = 2
                $removeState.Completed = $true
                Invoke-SelectorTimerTick
                Assert-TestNull $app.Job 'Completed remove is detached.'
                Assert-TestEqual 'RemoveResult' $app.Shell.CurrentPage.Kind "The finished deletion shows the result page (selection context: $withSelection)."
                Assert-TestEqual 'Partial' ([string]$app.Shell.CurrentPage.Outcome.State) 'Remove outcome is read from the report.'
                $problemName = [string]@($app.Shell.CurrentPage.Outcome.Problems)[0].DisplayName
                if ($withSelection) {
                    Assert-TestEqual (Get-W360FindingDisplayName -Finding $selectedForRemove[0]) $problemName 'Problems are named after the selected item.'
                }
                else {
                    Assert-TestEqual '一些文件' $problemName 'Without the selected items, a problem is named by what was handled, never by its raw target.'
                }
            }
        }
        finally {
            $app.Timer.Dispose()
            $app.Form.Dispose()
            $script:SelectorApp = $previousApp
        }
    }
}
finally {
    Remove-TestDirectory -Path $fixtureDirectory
}

Complete-TestRun -Run $run
