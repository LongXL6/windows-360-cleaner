#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath = (Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1'),
    [string]$LibraryPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$uiLibraryTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath

$CleanerScriptPath = [IO.Path]::GetFullPath($CleanerScriptPath)
# Expected version comes from the repository VERSION file so a documented version bump keeps tests valid.
$script:ExpectedToolVersion = ([IO.File]::ReadAllText([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $CleanerScriptPath) '..\VERSION')))).Trim()

if ([string]::IsNullOrWhiteSpace($LibraryPath)) {
    $LibraryPath = Join-Path (Split-Path -Parent $CleanerScriptPath) 'Windows360Cleaner.Library.ps1'
}
$LibraryPath = [IO.Path]::GetFullPath($LibraryPath)
. $LibraryPath

function New-UiId {
    param([Parameter(Mandatory = $true)][string]$Seed)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Seed))
        return ([BitConverter]::ToString($bytes)).Replace('-', '')
    }
    finally { $sha256.Dispose() }
}

function New-UiFinding {
    param(
        [string]$Kind = 'Path',
        [string]$Name = 'Duohui screen saver',
        [string]$Target = 'C:\Users\Fixture\AppData\Local\dhpingbao',
        [string]$Confidence = 'Confirmed',
        [string]$RemovalType = 'Path',
        [string]$ValueName = '',
        [string]$Reason = 'Known duohuipingbao installation path.',
        [string]$ProductKey = 'Duohui',
        [string]$IdentityFingerprint = '',
        [bool]$Offline = $false,
        [string]$SelectionId = $null,
        [switch]$OmitProductKey,
        [switch]$OmitSelectionId
    )

    $fields = [ordered]@{
        Kind                = $Kind
        Name                = $Name
        Target              = $Target
        Confidence          = $Confidence
        Reason              = $Reason
        RemovalType         = $RemovalType
        ValueName           = $ValueName
        IdentityFingerprint = $IdentityFingerprint
        Offline             = $Offline
    }
    if (-not $OmitProductKey) { $fields['ProductKey'] = $ProductKey }
    if (-not $OmitSelectionId) {
        if ([string]::IsNullOrEmpty($SelectionId)) {
            $selectable = $Confidence -eq 'Confirmed' -and -not $Offline -and $RemovalType -ne 'None'
            $SelectionId = if ($selectable) { New-UiId -Seed ($Kind + '|' + $Target + '|' + $ValueName) } else { '' }
        }
        $fields['SelectionId'] = $SelectionId
    }
    return [pscustomobject]$fields
}

function Write-UiJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function New-UiApprovalContext {
    return [pscustomobject]@{
        UserSid      = 'S-1-5-21-111111111-222222222-333333333-1001'
        KnownFolders = [pscustomobject]@{ LocalAppData = 'C:\Users\Fixture\AppData\Local' }
        Options      = [pscustomobject]@{ IncludeBrowserProfiles = $false }
    }
}

function Write-UiScanReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyCollection()][object[]]$Findings = @(),
        [AllowNull()][object]$Coverage = ([pscustomobject]@{ Complete = $true; Issues = @() }),
        [int]$SchemaVersion = 2,
        [string]$Mode = 'Scan',
        [switch]$NoApprovalContext,
        [switch]$NoCoverage
    )

    $fields = [ordered]@{
        SchemaVersion   = $SchemaVersion
        ToolVersion     = '1.0.0'
        Timestamp       = '2026-09-13T10:00:00.0000000+08:00'
        Mode            = $Mode
        ApprovalContext = $(if ($NoApprovalContext) { $null } else { New-UiApprovalContext })
        Summary         = $null
    }
    if (-not $NoCoverage) { $fields['ScanCoverage'] = $Coverage }
    $fields['Findings'] = @($Findings)
    $fields['Actions'] = @()
    Write-UiJson -Path $Path -Value ([pscustomobject]$fields)
}

function New-UiSummary {
    param([hashtable]$Overrides = @{})

    $summary = [ordered]@{
        TotalItemsRemoved = 12; FilesRemoved = 10; DirectoriesRemoved = 2; LogicalBytesRemoved = 2048
        LogicalSizeRemoved = '2.00 KB'; PathTargetsRemoved = 1; PartiallyCleanedPathTargets = 0
        ServicesRemoved = 0; ServicesPendingRemoval = 0; ScheduledTasksRemoved = 0; RegistryKeysRemoved = 1
        RegistryValuesRemoved = 1; ProcessesStopped = 0; VendorUninstallersSucceeded = 0; VendorUninstallersFailed = 0
        VendorUninstallersPending = 0; SkippedActions = 0; FailedActions = 0; PendingActions = 0; RetryAttempts = 0
        UnresolvedRetryTargets = 0; AccessDeniedPathTargets = 0; AclRepairAttempts = 0; AclRepairFailures = 0
        UnresolvedPathTargets = 0; PathAccountingComplete = $true; UnmeasuredPathTargets = 0
        PostVendorMutationBlocked = $false; ImmediateRescanComplete = $true; ImmediateRemainingConfirmed = 0
        NoImmediateConfirmedFindings = $true; ApprovedConfirmed = 3; EligibleApproved = 3; NewSinceApproval = 0
        MissingSinceApproval = 0; NoLongerConfirmed = 0; SelectionApplied = $true; SelectedConfirmedFindings = 2
        UnselectedConfirmedFindings = 1; ImmediateRemainingSelected = 0; NoImmediateSelectedFindings = $true
    }
    foreach ($key in @($Overrides.Keys)) { $summary[$key] = $Overrides[$key] }
    return [pscustomobject]$summary
}

function New-UiAction {
    param(
        [string]$Action,
        [string]$Target,
        [string]$Result,
        [string]$Detail = ''
    )

    return [pscustomobject]@{ Time = '2026-09-13T10:05:00.0000000+08:00'; Action = $Action; Target = $Target; Result = $Result; Detail = $Detail }
}

function Write-UiRemoveReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ApprovedReportHash,
        [object]$Summary = (New-UiSummary),
        [AllowEmptyCollection()][object[]]$Actions = @(),
        [AllowEmptyCollection()][object[]]$Findings = @(),
        [int]$SchemaVersion = 2,
        [string]$Mode = 'Remove',
        [string]$Timestamp = '2026-09-13T10:05:00.0000000+08:00'
    )

    Write-UiJson -Path $Path -Value ([pscustomobject][ordered]@{
        SchemaVersion      = $SchemaVersion
        ToolVersion        = '1.0.0'
        Timestamp          = $Timestamp
        Mode               = $Mode
        ApprovalContext    = New-UiApprovalContext
        ApprovedReportHash = $ApprovedReportHash
        OutcomeRunId       = ('AB' * 16)
        Summary            = $Summary
        ScanCoverage       = [pscustomobject]@{ Complete = $true; Issues = @() }
        Findings           = @($Findings)
        Actions            = @($Actions)
    })
}

function New-UiItemStatus {
    param(
        [string]$Category,
        [string]$State,
        [string]$Kind = 'Path',
        [string]$Name = 'Duohui screen saver',
        [string]$Target = 'C:\Users\Fixture\AppData\Local\dhpingbao',
        [string]$ProductKey = 'Duohui',
        [string]$DetailCode = 'ProbeAbsent',
        [string]$CurrentConfidence = ''
    )

    return [pscustomobject][ordered]@{
        Category = $Category; State = $State; Kind = $Kind; Name = $Name; Target = $Target; ValueName = ''
        RemovalType = $(if ($Kind -eq 'VendorUninstaller') { 'VendorUninstaller' } elseif ($Kind -eq 'RegistryResidue') { 'RegistryKey' } else { 'Path' })
        ProductKey = $ProductKey; SelectionId = (New-UiId -Seed ($Kind + $Target)); CurrentConfidence = $CurrentConfidence
        DetailCode = $DetailCode; Detail = ('English detail for ' + $DetailCode)
    }
}

function Write-UiVerifyReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][object]$TaskVerification = $null,
        [AllowEmptyCollection()][object[]]$Findings = @(),
        [object]$Coverage = ([pscustomobject]@{ Complete = $true; Issues = @() }),
        [switch]$OmitTaskVerification
    )

    $fields = [ordered]@{
        SchemaVersion = 2; ToolVersion = '1.0.0'; Timestamp = '2026-09-14T09:00:00.0000000+08:00'; Mode = 'Verify'
        ApprovalContext = $null; Summary = $null; ScanCoverage = $Coverage
    }
    if (-not $OmitTaskVerification) { $fields['TaskVerification'] = $TaskVerification }
    $fields['Findings'] = @($Findings)
    $fields['Actions'] = @()
    Write-UiJson -Path $Path -Value ([pscustomobject]$fields)
}

function New-UiTaskVerification {
    param(
        [string]$Status,
        [AllowEmptyCollection()][object[]]$Selected = @(),
        [AllowEmptyCollection()][object[]]$Preserved = @(),
        [AllowEmptyCollection()][object[]]$New = @(),
        [string]$UnavailableReason = ''
    )

    $count = { param($Items, $State) @($Items | Where-Object { $_.State -eq $State }).Count }
    return [pscustomobject][ordered]@{
        Status = $Status; UnavailableReason = $UnavailableReason; UnavailableDetail = ''
        RemoveReportPath = 'C:\Reports\360-cleanup-remove-20260913-100500-abcdef12.json'; RemoveReportHash = ('CD' * 32)
        RemoveReportTimestamp = '2026-09-13T10:05:00.0000000+08:00'; RemoveToolVersion = '1.0.0'
        ApprovedReportHash = ('EF' * 32); SelectionApplied = $true
        Counts = [pscustomobject][ordered]@{
            SelectedTotal = @($Selected).Count; SelectedAbsent = (& $count $Selected 'Absent')
            SelectedRemaining = (& $count $Selected 'Remaining'); SelectedChanged = (& $count $Selected 'Changed')
            SelectedUnknown = (& $count $Selected 'Unknown'); PreservedTotal = @($Preserved).Count
            PreservedPresent = (& $count $Preserved 'Present'); PreservedAbsent = (& $count $Preserved 'Absent')
            PreservedChanged = (& $count $Preserved 'Changed'); PreservedUnknown = (& $count $Preserved 'Unknown')
            NewConfirmed = @($New).Count
        }
        Selected = @($Selected); Preserved = @($Preserved); New = @($New)
    }
}

function Wait-UiChild {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [int]$TimeoutSeconds = 20,
        [int]$PumpIntervalMilliseconds = 25,
        [string]$ProgressFilePath = ''
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $State.Completed) {
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            try { if (-not $State.Process.HasExited) { $State.Process.Kill() } } catch {}
            throw "The child process did not complete within $TimeoutSeconds seconds (possible pipe deadlock)."
        }
        [void](Update-W360ChildProcess -State $State -ProgressFilePath $ProgressFilePath)
        if (-not $State.Completed) { Start-Sleep -Milliseconds $PumpIntervalMilliseconds }
    }
    return $watch.Elapsed
}

function Get-CoreReasonLiterals {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ('The core script does not parse: ' + (@($parseErrors | ForEach-Object { $_.Message }) -join '; '))
    }
    $literals = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { @('Get-360Findings', 'Set-360CleanupFindingIdentityFingerprint') -contains $_.Name })
    if ($functions.Count -ne 2) { throw 'Get-360Findings or Set-360CleanupFindingIdentityFingerprint was not found in the core.' }

    foreach ($function in $functions) {
        $body = $function.Body
        $nodes = New-Object System.Collections.ArrayList
        foreach ($command in @($body.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
            if ($command.GetCommandName() -ne 'New-Finding') { continue }
            $elements = $command.CommandElements
            for ($index = 0; $index -lt $elements.Count; $index++) {
                $element = $elements[$index]
                if ($element -is [Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq 'Reason') {
                    if ($null -ne $element.Argument) { [void]$nodes.Add($element.Argument) }
                    elseif ($index + 1 -lt $elements.Count) { [void]$nodes.Add($elements[$index + 1]) }
                }
            }
        }
        foreach ($assignment in @($body.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true))) {
            $left = $assignment.Left
            if ($left -is [Management.Automation.Language.MemberExpressionAst] -and $left.Member.Extent.Text -eq 'Reason') {
                [void]$nodes.Add($assignment.Right)
            }
        }
        foreach ($hashtable in @($body.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true))) {
            foreach ($pair in $hashtable.KeyValuePairs) {
                if ($pair.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and $pair.Item1.Value -eq 'Reason') {
                    [void]$nodes.Add($pair.Item2)
                }
            }
        }

        $assignmentsByVariable = @{}
        foreach ($assignment in @($body.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true))) {
            if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst]) {
                $name = $assignment.Left.VariablePath.UserPath.ToLowerInvariant()
                if (-not $assignmentsByVariable.ContainsKey($name)) { $assignmentsByVariable[$name] = New-Object System.Collections.ArrayList }
                [void]$assignmentsByVariable[$name].Add($assignment.Right)
            }
        }

        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $queue = New-Object System.Collections.Queue
        foreach ($node in $nodes) { $queue.Enqueue(@($node, 0)) }
        while ($queue.Count -gt 0) {
            $entry = $queue.Dequeue()
            $node = $entry[0]
            $depth = [int]$entry[1]
            foreach ($constant in @($node.FindAll({ param($inner) $inner -is [Management.Automation.Language.StringConstantExpressionAst] }, $true))) {
                if ($constant.StringConstantType -notin @('SingleQuoted', 'DoubleQuoted')) { continue }
                $value = [string]$constant.Value
                $spaces = @($value.ToCharArray() | Where-Object { $_ -eq ' ' }).Count
                if ($spaces -ge 2 -and $value -match '[A-Za-z]{3}') { [void]$literals.Add($value) }
            }
            if ($depth -ge 3) { continue }
            foreach ($variable in @($node.FindAll({ param($inner) $inner -is [Management.Automation.Language.VariableExpressionAst] }, $true))) {
                $name = $variable.VariablePath.UserPath.ToLowerInvariant()
                if ($name -in @('_', 'true', 'false', 'null', 'psitem') -or -not $assignmentsByVariable.ContainsKey($name)) { continue }
                if (-not $visited.Add($name)) { continue }
                foreach ($right in $assignmentsByVariable[$name]) { $queue.Enqueue(@($right, ($depth + 1))) }
            }
        }
    }
    return @($literals)
}

$run = New-TestRun -Name 'UI library tests'
$fixtureRoot = $null
$previousTestMode = [Environment]::GetEnvironmentVariable('WINDOWS_360_CLEANER_TEST_MODE', 'Process')
$createdProgressFiles = New-Object System.Collections.ArrayList

try {
    $fixtureRoot = New-TestDirectory
    Set-W360UiLanguage -Language zh

    Invoke-TestCase -Run $run -Name 'library and test files use the PowerShell 5.1 source contract' -Test {
        Assert-TestPowerShellFileContract -Path $LibraryPath
        Assert-TestPowerShellFileContract -Path $uiLibraryTestPath
        $libraryText = [IO.File]::ReadAllText($LibraryPath, (New-Object Text.UTF8Encoding($false, $true)))
        Assert-TestTrue ($libraryText.Contains(("`r`n`$script:W360ToolVersion = '{0}'`r`n" -f $script:ExpectedToolVersion))) 'The exact library version constant line is missing.'
        Assert-TestTrue ($libraryText.StartsWith([string][char]0xFEFF + '#requires -Version 5.1') -or $libraryText.StartsWith('#requires -Version 5.1')) `
            'The library must start with #requires -Version 5.1.'
        Assert-TestFalse ($libraryText -match 'System\.Windows\.Forms|Add-Type\s+-AssemblyName') 'The library must not use WinForms types.'
        foreach ($forbidden in @('Restart-Computer', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Net.WebClient', 'Verb RunAs', 'Register-ScheduledTask', 'CurrentVersion\Run')) {
            Assert-TestFalse ($libraryText.Contains($forbidden)) "The library must not contain '$forbidden'."
        }
    }

    Invoke-TestCase -Run $run -Name 'localisation table has zh and en for every key and throws for unknown keys' -Test {
        foreach ($key in @($script:W360Strings.Keys)) {
            $entry = $script:W360Strings[$key]
            Assert-TestTrue (-not [string]::IsNullOrEmpty([string]$entry['en'])) "English text is missing for $key."
            if ($key -ne 'Common.SentenceSeparator') {
                Assert-TestTrue (-not [string]::IsNullOrEmpty([string]$entry['zh'])) "Chinese text is missing for $key."
            }
            $zhPlaceholders = @([regex]::Matches([string]$entry['zh'], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            $enPlaceholders = @([regex]::Matches([string]$entry['en'], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            Assert-TestEqual -Expected $enPlaceholders -Actual $zhPlaceholders -Message "Placeholders differ between zh and en for $key."
        }
        Assert-TestThrows -Operation { Get-W360Text -Key 'No.Such.Key' } -Message 'An unknown text key must throw.' -ExpectedMessagePattern 'Unknown UI text key'
        Assert-TestEqual -Expected 'Windows 360 清理工具 v1.0.0' -Actual (Get-W360Text -Key 'App.WindowTitle' -Arguments @('1.0.0')) -Message 'Chinese window title.'
        Set-W360UiLanguage -Language en
        try {
            Assert-TestEqual -Expected 'en' -Actual (Get-W360UiLanguage) -Message 'The language override did not apply.'
            Assert-TestEqual -Expected 'Windows 360 Cleaner v1.0.0' -Actual (Get-W360Text -Key 'App.WindowTitle' -Arguments @('1.0.0')) -Message 'English window title.'
        }
        finally { Set-W360UiLanguage -Language zh }
        Assert-TestThrows -Operation { Set-W360UiLanguage -Language 'fr' } -Message 'Only zh and en are valid languages.'
        foreach ($phase in $script:W360KnownPhases) {
            Assert-TestTrue ($script:W360Strings.ContainsKey('Phase.' + $phase)) "Phase $phase has no localised text."
        }
    }

    Invoke-TestCase -Run $run -Name 'main-window texts use plain words: no banned words outside the documented secondary-window keys' -Test {
        # Groups whose texts reach the main window, the confirmation dialog or the selection dialog.
        # Help is not a main-window group, but the help text is read and pasted by beginners, so its plain lines follow the same policy.
        $mainGroups = @('App', 'Common', 'Phase', 'Status', 'Kind', 'Product', 'Name', 'Impact', 'Plan', 'Scan', 'Coverage',
            'Remove', 'RemoveReason', 'Verify', 'VerifyState', 'DetailCode', 'Unavailable', 'Ui', 'Help')
        # The oracle is pinned here: shrinking the banned lists or widening the whitelist needs a test change.
        Assert-TestSequenceEqual -Expected @(
            '识别', '扫描', '复检', '报告', '授权', '提权', '注册表', '计划任务', '系统服务', '厂商', '只读', '逻辑大小', '证据',
            '身份', '标识', '规则', '匹配', '退出代码', '进程', '全局', 'Confidence', 'SelectionId', 'ReviewOnly', '状态码',
            '目录', '组件', '缓存', '权限', '路径', '签名', '残留', '查询') -Actual @($script:W360MainUiBannedWords) -Message 'The Chinese main-window banned words changed.'
        Assert-TestSequenceEqual -Expected @('Confidence', 'SelectionId', 'ReviewOnly', 'read-only', 'report', 'verification', 'elevation', 'registry',
            'scheduled task', 'vendor') -Actual @($script:W360MainUiBannedEnglishWords) -Message 'The English main-window banned words changed.'
        Assert-TestSequenceEqual -Expected @('^Tech\.', '^Reason\.', '^Help\.(ToolVersion|Windows|Bitness32|Bitness64|PowerShell|UiCulture|ErrorText|StdoutTail)$',
            '^Redact\.', '^Stats\.', '^Action\.', '^Result\.', '^Gui\.Fatal$', '^Gui\.Remove\.Log', '^Gui\.Column\.', '^Gui\.Detail\.', '^Gui\.Error\.TechnicalTitle$',
            '^Gui\.Error\.NoTechnical$', '^Gui\.Scan\.CoverageTitle$', '^Gui\.Scan\.CoverageIntro$') `
            -Actual @($script:W360SecondaryTextKeyRules | ForEach-Object { [string]$_.Pattern }) -Message 'The secondary-window whitelist changed.'
        foreach ($rule in $script:W360SecondaryTextKeyRules) {
            Assert-TestFalse ([string]::IsNullOrWhiteSpace([string]$rule.Reason)) ('Every whitelist rule needs a reason: ' + $rule.Pattern)
        }
        foreach ($mainPrefixKey in @('Phase.ScanRegistryResidue', 'Remove.Completed.VendorRan', 'Status.KeepPrefix', 'Name.Problem.Service', 'Verify.Section.CurrentKept')) {
            Assert-TestEqual -Expected '' -Actual (Get-W360SecondaryTextKeyReason -Key $mainPrefixKey) -Message "$mainPrefixKey must stay main-window text."
        }
        Assert-TestTrue ((Get-W360SecondaryTextKeyReason -Key 'Tech.SelectionId') -ne '') 'Tech keys are secondary-window only.'
        foreach ($technicalHelpKey in @('Help.ToolVersion', 'Help.Windows', 'Help.UiCulture', 'Help.ErrorText', 'Redact.PrivatePath')) {
            Assert-TestTrue ((Get-W360SecondaryTextKeyReason -Key $technicalHelpKey) -ne '') "$technicalHelpKey is a technical line of the help text."
        }
        # The help text a beginner reads and pastes uses the window's plain words.
        foreach ($plainHelpKey in @('Help.Title', 'Help.Disclaimer.Redacted', 'Help.Disclaimer.NotApproval', 'Help.Disclaimer.ReportKept', 'Help.Stage.Scan',
                'Help.FindingCounts', 'Help.RemainingFindings', 'Help.SnapshotFindings', 'Help.RemoveStats', 'Help.Problems', 'Ui.Help.Privacy', 'Gui.Help.CopyDone')) {
            Assert-TestEqual -Expected '' -Actual (Get-W360SecondaryTextKeyReason -Key $plainHelpKey) -Message "$plainHelpKey must follow the plain-language policy."
        }
        Assert-TestTrue ((Get-W360SecondaryTextKeyReason -Key 'Gui.Column.Target') -ne '') 'Details grid headers are secondary-window only.'
        foreach ($mainKey in @('Ui.Button.Close', 'Ui.Help', 'Gui.Scan.TooMany', 'Gui.Error.Unexpected.Detail', 'Status.AwaitingChoice.Text', 'Coverage.Services')) {
            Assert-TestEqual -Expected '' -Actual (Get-W360SecondaryTextKeyReason -Key $mainKey) -Message "$mainKey is main-window text."
        }
        Assert-TestSequenceEqual -Expected @('识别', '报告') -Actual @(Get-W360MainUiBannedWords -Text '已识别的报告' -Language zh) -Message 'The Chinese banned-word finder.'
        Assert-TestSequenceEqual -Expected @('registry') -Actual @(Get-W360MainUiBannedWords -Text 'Registry residue' -Language en) -Message 'The English banned-word finder ignores case.'

        $violations = New-Object System.Collections.Generic.List[string]
        $scanned = 0
        foreach ($key in @($script:W360Strings.Keys | Sort-Object)) {
            $entry = $script:W360Strings[$key]
            # The only select-all is the shrink-only "select everything that can be deleted" button.
            $selectAllKey = $key -ceq 'Ui.Button.SelectAllDeletable'
            foreach ($language in @('zh', 'en')) {
                if (-not $selectAllKey -and [string]$entry[$language] -match '全选|(?i)select all') { $violations.Add("[$language] $key offers select-all wording.") }
            }
            if (-not $selectAllKey -and $key -match '(?i)SelectAll') { $violations.Add("$key is a select-all key.") }
            if (-not [string]::IsNullOrEmpty((Get-W360SecondaryTextKeyReason -Key $key))) { continue }
            $group = $key.Split('.')[0]
            if ($mainGroups -notcontains $group) {
                $violations.Add("$key belongs to no scanned group and to no documented secondary-window rule.")
                continue
            }
            $scanned++
            foreach ($word in @(Get-W360MainUiBannedWords -Text ([string]$entry['zh']) -Language zh)) { $violations.Add("[zh] $key contains $word") }
            foreach ($word in @(Get-W360MainUiBannedWords -Text ([string]$entry['en']) -Language en)) { $violations.Add("[en] $key contains $word") }
        }
        Assert-TestTrue ($scanned -ge 300) "Too few main-window keys were scanned ($scanned)."
        Assert-TestEqual -Expected 0 -Actual $violations.Count -Message ("Plain-language violations:`r`n" + ($violations.ToArray() -join "`r`n"))

        # Every protected status reads as "do not delete: reason" and the deletable one as "can be deleted".
        foreach ($code in @('PersonalDataKept', 'OfflineReportOnly', 'DriverReviewOnly', 'BundleKept', 'IdentityUnconfirmed', 'StillInstalled',
                'InsufficientEvidence', 'MissingSelectionId', 'NotRemovable', 'KeptContentInside', 'NeedsItsFolder')) {
            Assert-TestTrue ((Get-W360Text -Key ('Status.' + $code + '.Text')).StartsWith('不删除')) "Status $code must start with 不删除."
            Set-W360UiLanguage -Language en
            try { Assert-TestTrue ((Get-W360Text -Key ('Status.' + $code + '.Text')).StartsWith("Won't delete")) "English status $code must start with Won't delete." }
            finally { Set-W360UiLanguage -Language zh }
        }
        Assert-TestEqual -Expected '不删除：里面有要保留的东西' -Actual (Get-W360Text -Key 'Status.KeptContentInside.Text') -Message 'The kept-content-inside status text.'
        Assert-TestEqual -Expected '不删除：要和它所在的文件夹一起删' -Actual (Get-W360Text -Key 'Status.NeedsItsFolder.Text') -Message 'The needs-its-folder status text.'
        Assert-TestEqual -Expected '可以删除' -Actual (Get-W360Text -Key 'Status.AwaitingChoice.Text') -Message 'The deletable status text.'
        foreach ($buttonKey in @('Ui.Button.ConfirmRemove', 'Ui.Button.Rescan', 'Ui.Button.VerifyTask', 'Ui.Button.VerifyNow', 'Ui.Button.HelpSummary',
                'Ui.Button.OpenReportFolder', 'Ui.Button.ClearSelection', 'Ui.Button.CleanSelected', 'Ui.Button.StopCheck', 'Ui.Button.MoreInfo')) {
            Assert-TestTrue (Test-W360TextKey -Key $buttonKey) "Button text key $buttonKey is missing."
        }
        Assert-TestEqual -Expected '全选可以删除的' -Actual (Get-W360Text -Key 'Ui.Button.SelectAllDeletable') -Message 'The select-all button names only items that can be deleted.'
        Assert-TestEqual -Expected '删除' -Actual (Get-W360Text -Key 'Ui.Button.ConfirmRemove') -Message 'The confirm button says Delete.'
        Assert-TestEqual -Expected '取消' -Actual (Get-W360Text -Key 'Ui.Button.Cancel') -Message 'The confirm dialog default button says Cancel.'
        Assert-TestTrue ((Get-W360Text -Key 'Ui.Progress.RemoveNote').Contains('不能中途停止')) 'The remove progress note must say it cannot be stopped.'
        Assert-TestTrue ((Get-W360Text -Key 'Ui.Confirm.VendorWarning').Contains('你没选的部分也一起删掉')) 'The uninstaller warning must say unselected parts may be deleted.'
        Assert-TestTrue ((Get-W360Text -Key 'Ui.Confirm.KeptSameProduct').Contains('可能')) 'The kept list must not promise safety for the product of an uninstaller.'
        Assert-TestFalse ((Get-W360Text -Key 'Ui.Confirm.KeptSameProduct').Contains('会保留')) 'Unticked parts of the uninstaller product are never called kept.'
        Assert-TestFalse ((Get-W360Text -Key 'Ui.Progress.RemoveBeforeNote').Contains('没有删除')) 'The note before deleting starts never claims that nothing was deleted.'
        foreach ($promiseKey in @('Scan.Findings.Detail', 'Scan.Findings.DetailVendor', 'Status.AwaitingChoice.Explanation', 'Ui.Scan.SelectionCounter')) {
            foreach ($promise in @('都会保留', '就会保留', '不勾选的都')) {
                Assert-TestFalse ((Get-W360Text -Key $promiseKey).Contains($promise)) "$promiseKey must not promise that unticked items are always kept."
            }
        }
        Assert-TestTrue ((Get-W360Text -Key 'Scan.Findings.DetailVendor').Contains('也可能被它删掉')) 'The subtitle with a ticked uninstaller names the risk.'
        Assert-TestEqual -Expected (Get-W360Text -Key 'Ui.Button.VerifyTask') -Actual (Get-W360Text -Key 'Ui.Button.VerifyNow') `
            -Message 'Both buttons that check the last deletion have one name, so next steps always name a button the user can find.'
        Assert-TestTrue ((Get-W360Text -Key 'Ui.Help.Privacy').Contains('可能有遗漏') -and (Get-W360Text -Key 'Ui.Help.Privacy').Contains('不会自动上传')) `
            'The help privacy note must not overclaim the redaction and must say nothing is uploaded.'
    }

    Invoke-TestCase -Run $run -Name 'Confirmed findings are shown as can-be-deleted, never as a recommendation or approval' -Test {
        $finding = New-UiFinding -Kind 'Path' -Name '360se6 browser application' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' `
            -Reason 'Exact 360se6 Application directory with local 360/Qihoo file evidence.' -ProductKey '360SafeBrowser'
        $status = Get-W360FindingStatus -Finding $finding
        Assert-TestEqual -Expected 'AwaitingChoice' -Actual $status.Code -Message 'A selectable Confirmed finding has the wrong status.'
        Assert-TestEqual -Expected '可以删除' -Actual $status.Text -Message 'The Confirmed status text is wrong.'
        Assert-TestTrue $status.Selectable 'The status must report the finding as selectable.'
        # "Can be deleted" must never read as advice or as the user's approval: the user decides. It never promises that
        # unticked items stay (an uninstaller that came with 360 may remove them) and says nothing goes to the Recycle Bin.
        foreach ($phrase in @('由你决定', '回收站')) {
            Assert-TestTrue ($status.Explanation.Contains($phrase)) "The Confirmed explanation is missing: $phrase"
        }
        Assert-TestFalse ($status.Explanation.Contains('保留')) 'The Confirmed explanation must not promise that unticked items are kept.'
        Assert-TestEqual -Expected '360 安全浏览器程序文件' -Actual (Get-W360FindingDisplayName -Finding $finding) -Message 'Browser application display name.'
        Assert-TestEqual -Expected '文件夹' -Actual (Get-W360FindingKindText -Finding $finding) -Message 'A directory target must be shown as a folder.'
        $impact = Get-W360ImpactText -Finding $finding
        Assert-TestFalse ($impact.Contains('回收站')) 'The permanence is said once per window, not in every impact.'
        Assert-TestTrue ($impact.Contains('书签') -and $impact.Contains('默认不删')) 'The browser application impact must explain that personal data is not deleted.'
        $technical = Get-W360FindingTechnicalText -Finding $finding
        Assert-TestTrue ($technical.Contains($finding.Reason) -and $technical.Contains($finding.SelectionId) -and $technical.Contains('360SafeBrowser')) `
            'The technical text must keep the raw evidence.'
        Set-W360UiLanguage -Language en
        try {
            $english = Get-W360FindingStatus -Finding $finding
            Assert-TestTrue ($english.Explanation -match 'You decide' -and $english.Explanation -match 'Recycle Bin') `
                'The English explanation must also say that the user decides and that nothing goes to the Recycle Bin.'
            Assert-TestTrue ((Get-W360FindingStatus -Finding (New-UiFinding -Kind 'Driver' -Name 'x.sys' -Target 'C:\Windows\System32\drivers\x.sys' -Confidence 'ReviewOnly' -RemovalType 'None')).Text.StartsWith("Won't delete")) `
                'English kept statuses say what the tool will not do, not an instruction.'
        }
        finally { Set-W360UiLanguage -Language zh }
    }

    Invoke-TestCase -Run $run -Name 'non-selectable findings get protective statuses and keep-impacts' -Test {
        $profile360 = New-UiFinding -Name '360se6 browser profile' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\User Data' -Confidence 'ReviewOnly' -RemovalType 'None' `
            -Reason '360se6 User Data can contain bookmarks, history, saved sessions, and other user data. Preserved by default; use the separate browser-profile opt-in only after backing up needed data.' `
            -ProductKey '360SafeBrowser'
        $legacy = New-UiFinding -Name '360browser legacy profile' -Target 'C:\Users\Fixture\AppData\Roaming\360browser' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey '360SafeBrowser'
        $offline = New-UiFinding -Kind 'OfflinePath' -Name 'Offline Windows 360 path' -Target 'D:\Program Files\360' -Confidence 'ReviewOnly' -RemovalType 'None' -Offline $true -ProductKey 'OfflineWindows' `
            -Reason 'Found in another Windows installation; the bundled script is permanently scan-only for offline roots.'
        $driver = New-UiFinding -Kind 'Driver' -Name '360AntiHacker64.sys' -Target 'C:\Windows\System32\drivers\360AntiHacker64.sys' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'Drivers' `
            -Reason 'System driver requires vendor-uninstaller and driver-package review; never auto-delete.'
        $bundle = New-UiFinding -Kind 'Bundle' -Name 'Aolande/Huajun winToolBox mixed bundle' -Target 'C:\Users\Fixture\AppData\Local\winToolBox' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'WinToolBox360'
        $identity = New-UiFinding -Kind 'Startup' -Name '360Tray' -Target 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Confidence 'ReviewOnly' -RemovalType 'None' -ValueName '360Tray' `
            -Reason 'Startup executable is under confirmed target: C:\Program Files (x86)\360\360Safe Exact identity fingerprint could not be captured; automatic removal is disabled. The value could not be read.'
        $evidence = New-UiFinding -Kind 'Service' -Name '360rp' -Target '360rp' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'Unattributed' `
            -Reason 'Service name/path matched, but its executable was not under a confirmed target.'
        $expectations = @(
            @($profile360, 'PersonalDataKept', '不删除：书签和历史记录'),
            @($legacy, 'PersonalDataKept', '不删除：书签和历史记录'),
            @($offline, 'OfflineReportOnly', '不删除：在另一个 Windows 系统里'),
            @($driver, 'DriverReviewOnly', '不删除：系统驱动'),
            @($bundle, 'BundleKept', '不删除：这是别的软件'),
            @($identity, 'IdentityUnconfirmed', '不删除：信息不完整'),
            @($evidence, 'InsufficientEvidence', '不删除：不能确定是 360 的')
        )
        foreach ($expectation in $expectations) {
            $status = Get-W360FindingStatus -Finding $expectation[0]
            Assert-TestEqual -Expected $expectation[1] -Actual $status.Code -Message ('Wrong status code for ' + $expectation[0].Name)
            Assert-TestEqual -Expected $expectation[2] -Actual $status.Text -Message ('Wrong status text for ' + $expectation[0].Name)
            Assert-TestTrue ($status.Text.StartsWith('不删除')) ('A protected finding must read as not deleted: ' + $expectation[0].Name)
            Assert-TestFalse $status.Selectable ('A protected finding must not be selectable: ' + $expectation[0].Name)
            Assert-TestTrue ((Get-W360ImpactText -Finding $expectation[0]).StartsWith('不会删除。')) ('A non-selectable impact must say it is kept: ' + $expectation[0].Name)
        }
        Assert-TestTrue ((Get-W360ImpactText -Finding $profile360).Contains('书签')) 'The kept profile impact must mention bookmarks.'
        Assert-TestTrue ((Get-W360FindingStatus -Finding $driver).Explanation.Contains('蓝屏')) 'The driver explanation must say why it is never deleted.'
        Assert-TestEqual -Expected '360 安全浏览器个人资料（书签、历史等）' -Actual (Get-W360FindingDisplayName -Finding $profile360) -Message 'Profile display name.'
        Assert-TestEqual -Expected '其他系统里的文件' -Actual (Get-W360FindingKindText -Finding $offline) -Message 'Offline kind text.'
        Assert-TestEqual -Expected '系统驱动' -Actual (Get-W360FindingKindText -Finding $driver) -Message 'Driver kind text.'
        Assert-TestEqual -Expected '开机自动运行：360Tray' -Actual (Get-W360FindingDisplayName -Finding $identity) -Message 'Startup entries are named by their plain kind and raw name.'
        Assert-TestEqual -Expected '后台服务：360rp' -Actual (Get-W360FindingDisplayName -Finding $evidence) -Message 'Services are named by their plain kind and raw name.'
        Assert-TestEqual -Expected '系统驱动：360AntiHacker64.sys' -Actual (Get-W360FindingDisplayName -Finding $driver) -Message 'Drivers are named by their plain kind and raw name.'
        Assert-TestTrue ((Get-W360ReasonText -Finding $identity).Contains('没能准确记录它的身份信息')) 'The identity suffix must be explained.'
    }

    Invoke-TestCase -Run $run -Name 'old reports without ProductKey or SelectionId are displayed safely' -Test {
        $old = New-UiFinding -OmitProductKey -OmitSelectionId
        Assert-TestFalse (Test-W360FindingSelectable -Finding $old) 'A finding without SelectionId must not be selectable.'
        $status = Get-W360FindingStatus -Finding $old
        Assert-TestEqual -Expected 'MissingSelectionId' -Actual $status.Code -Message 'An old Confirmed finding needs the missing-ID status.'
        Assert-TestEqual -Expected '不删除：请重新检查' -Actual $status.Text -Message 'Missing selection ID text.'
        Assert-TestEqual -Expected 'Unattributed' -Actual (Get-W360ProductInfo -ProductKey '').Key -Message 'A blank product key must map to Unattributed.'
        Assert-TestEqual -Expected 'Unattributed' -Actual (Get-W360ProductInfo -ProductKey 'SomethingElse').Key -Message 'An unknown product key must map to Unattributed.'
        Assert-TestEqual -Expected '说不清属于哪个 360 软件' -Actual (Get-W360ProductInfo -ProductKey $null).DisplayName -Message 'Unattributed display name.'
        $groups = @(Get-W360FindingGroups -Findings @($old))
        Assert-TestEqual -Expected 1 -Actual $groups.Count -Message 'An old finding must still be grouped.'
        Assert-TestEqual -Expected 'Unattributed' -Actual $groups[0].Key -Message 'An old finding must be grouped as Unattributed.'
        $technical = Get-W360FindingTechnicalText -Finding $old
        Assert-TestTrue ($technical.Contains('没有记录')) 'Missing technical fields must be marked as not recorded.'
        $minimal = [pscustomobject]@{ Confidence = 'Confirmed'; Offline = $false; RemovalType = 'Path'; SelectionId = ('A1' * 32) }
        Assert-TestTrue (Test-W360FindingSelectable -Finding $minimal) 'The selector compatibility fixture must stay selectable.'
        Assert-TestFalse (Test-W360FindingSelectable -Finding ([pscustomobject]@{ Confidence = 'Confirmed'; Offline = 'True'; RemovalType = 'Path'; SelectionId = ('A1' * 32) })) `
            'A string Offline flag must still block selection.'
    }

    Invoke-TestCase -Run $run -Name 'display names, kinds and impacts cover the fixed detector names' -Test {
        $vendor = New-UiFinding -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' -Target 'C:\Users\Fixture\AppData\Local\dhpingbao\huabaosetup.exe' -RemovalType 'VendorUninstaller'
        Assert-TestEqual -Expected '多绘屏保自带的卸载程序' -Actual (Get-W360FindingDisplayName -Finding $vendor) -Message 'Vendor uninstaller display name.'
        Assert-TestEqual -Expected '360 自带的卸载程序' -Actual (Get-W360FindingKindText -Finding $vendor) -Message 'Vendor kind text.'
        $vendorImpact = Get-W360ImpactText -Finding $vendor
        Assert-TestTrue ($vendorImpact.Contains('没勾选') -and $vendorImpact.Contains('没法保证')) 'The vendor impact must warn about unticked items.'
        Assert-TestEqual -Expected '多绘屏保安装文件夹' -Actual (Get-W360FindingDisplayName -Finding (New-UiFinding)) -Message 'Duohui folder display name.'
        $installed = New-UiFinding -Kind 'InstalledProduct' -Name '360安全卫士' -Target 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\360Safe' -RemovalType 'RegistryKey' -ProductKey '360Security' -IdentityFingerprint ('9A' * 32)
        Assert-TestEqual -Expected '360安全卫士 的卸载记录' -Actual (Get-W360FindingDisplayName -Finding $installed) -Message 'Installed product display name.'
        Assert-TestTrue ((Get-W360ImpactText -Finding $installed).Contains('Windows“设置 → 应用”列表')) 'Orphan uninstall record impact uses the one name of the Windows apps list.'
        Assert-TestTrue ((Get-W360FindingStatus -Finding (New-UiFinding -Kind 'InstalledProduct' -Name '360se' -Target 'HKLM:\x' -Confidence 'ReviewOnly' -RemovalType 'None' `
                        -Reason '360-family uninstall record still has a live vendor uninstaller.')).Explanation.Contains('Windows“设置 → 应用”')) 'Still installed explanation uses the same name.'
        $file = New-UiFinding -Name '360-signed component inside third-party winToolBox' -Target 'C:\Users\Fixture\AppData\Local\winToolBox\360Base.dll' -ProductKey 'WinToolBox360'
        Assert-TestEqual -Expected '文件' -Actual (Get-W360FindingKindText -Finding $file) -Message 'A DLL target must be shown as a file.'
        Assert-TestEqual -Expected 'winToolBox 工具箱里的 360 程序文件（360Base.dll）' -Actual (Get-W360FindingDisplayName -Finding $file) -Message 'Signed component display name.'
        Assert-TestTrue ((Get-W360ImpactText -Finding $file).Contains('小工具会保留')) 'winToolBox component impact.'
        $updater = New-UiFinding -Name 'winToolBox updater linked to confirmed SoftMgr bundle' -Target 'C:\Users\Fixture\AppData\Local\winToolBox\winToolBoxSrv.exe' -ProductKey 'WinToolBox360'
        Assert-TestTrue ((Get-W360ImpactText -Finding $updater).Contains('自动更新')) 'winToolBox updater impact.'
        $shared = New-UiFinding -Name '360 Program Files (x86)' -Target 'C:\Program Files (x86)\360' -ProductKey '360InstallDir'
        Assert-TestTrue ((Get-W360ImpactText -Finding $shared).Contains('好几个 360 软件')) 'Shared install dir impact.'
        $service = New-UiFinding -Kind 'Service' -Name 'ZhuDongFangYu' -Target 'ZhuDongFangYu' -RemovalType 'Service' -IdentityFingerprint ('8B' * 32)
        Assert-TestTrue ((Get-W360ImpactText -Finding $service).Contains('停止')) 'Service impact.'
        Assert-TestEqual -Expected '后台服务：ZhuDongFangYu' -Actual (Get-W360FindingDisplayName -Finding $service) -Message 'Service display name.'
        $task = New-UiFinding -Kind 'ScheduledTask' -Name '360 Update' -Target '360 Update' -RemovalType 'Task' -ValueName '\'
        Assert-TestTrue ((Get-W360ImpactText -Finding $task).Contains('定时自动运行的任务')) 'Task impact.'
        Assert-TestEqual -Expected '定时自动运行的任务：360 Update' -Actual (Get-W360FindingDisplayName -Finding $task) -Message 'Task display name.'
        $startup = New-UiFinding -Kind 'Startup' -Name 'huabao' -Target 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -RemovalType 'RegistryValue' -ValueName 'huabao'
        Assert-TestTrue ((Get-W360ImpactText -Finding $startup).Contains('只删掉这一条开机自动运行的设置')) 'Startup impact.'
        $screen = New-UiFinding -Kind 'ScreenSaver' -Name 'SCRNSAVE.EXE' -Target 'HKCU:\Control Panel\Desktop' -RemovalType 'RegistryValue' -ValueName 'SCRNSAVE.EXE'
        Assert-TestEqual -Expected '屏幕保护程序设置' -Actual (Get-W360FindingDisplayName -Finding $screen) -Message 'Screen saver display name.'
        Assert-TestTrue ((Get-W360ImpactText -Finding $screen).Contains('无屏幕保护程序')) 'Screen saver impact.'
        $process = New-UiFinding -Kind 'Process' -Name 'dhpingbao.exe' -Target '4242' -RemovalType 'Process' -ValueName 'C:\Users\Fixture\AppData\Local\dhpingbao\dhpingbao.exe'
        Assert-TestTrue ((Get-W360ImpactText -Finding $process).Contains('关掉')) 'Process impact.'
        Assert-TestEqual -Expected '正在运行的程序：dhpingbao' -Actual (Get-W360FindingDisplayName -Finding $process) -Message 'Process display name drops the extension.'
        $trayProcess = New-UiFinding -Kind 'Process' -Name '360tray.exe (4242)' -Target '4242' -RemovalType 'Process' -ValueName 'C:\Program Files (x86)\360\360Safe\safemon\360tray.exe'
        Assert-TestEqual -Expected '正在运行的程序：360tray' -Actual (Get-W360FindingDisplayName -Finding $trayProcess) -Message 'Process display name drops the process ID and the extension.'
        $idOnlyProcess = New-UiFinding -Kind 'Process' -Name '' -Target '4242' -RemovalType 'Process' -ValueName 'C:\x\y.exe'
        Assert-TestEqual -Expected '正在运行的程序' -Actual (Get-W360FindingDisplayName -Finding $idOnlyProcess) -Message 'A process ID alone is never shown as a name.'
        $unnamedPath = New-UiFinding -Name '' -Target 'C:\Users\Fixture\AppData\Local\somewhere\360thing'
        Assert-TestEqual -Expected '文件夹' -Actual (Get-W360FindingDisplayName -Finding $unnamedPath) -Message 'A finding without a name is named by its kind, never by its location.'
        foreach ($plainName in @('多绘屏保安装文件夹', '360 程序文件夹（32 位）', '360 软件管家下载文件夹', 'GreenCore 下载文件夹')) {
            Assert-TestEqual -Expected 0 -Actual @(Get-W360MainUiBannedWords -Text $plainName -Language zh).Count -Message "Item names use plain words: $plainName"
        }
        Assert-TestEqual -Expected '多绘屏保留下的设置' -Actual (Get-W360FindingDisplayName -Finding (New-UiFinding -Kind 'RegistryResidue' -Name 'Duohui registry residue' -Target 'HKCU:\Software\duohuipingbao' -RemovalType 'RegistryKey')) -Message 'Registry residue display name.'
        $temp = New-UiFinding -Name '360 unpack temporary files' -Target 'C:\Users\Fixture\AppData\Local\Temp\360UnPackTmp64' -ProductKey '360Temp'
        Assert-TestTrue ((Get-W360ImpactText -Finding $temp).Contains('临时文件')) 'Temp impact.'
        $unknownName = New-UiFinding -Name 'Some future detector name' -Target 'C:\Fixture\x'
        Assert-TestEqual -Expected 'Some future detector name' -Actual (Get-W360FindingDisplayName -Finding $unknownName) -Message 'Unknown names fall back to the original Name.'
        foreach ($name in @($script:W360FindingNameKeys.Keys)) {
            $display = Get-W360FindingDisplayName -Finding (New-UiFinding -Name $name -Target 'C:\Fixture\leaf.dll')
            Assert-TestTrue ($display -match '[\u4e00-\u9fff]') "The fixed detector name '$name' has no Chinese display name."
        }
    }

    Invoke-TestCase -Run $run -Name 'every Reason literal emitted by the detector has a plain-language mapping' -Test {
        $literals = @(Get-CoreReasonLiterals -Path $CleanerScriptPath)
        Assert-TestTrue ($literals.Count -ge 40) ("Too few Reason literals were found in the core ({0}); the parser no longer sees them." -f $literals.Count)
        $suffixes = @($literals | Where-Object { $_.StartsWith(' ') })
        $prefixes = @($literals | Where-Object { -not $_.StartsWith(' ') -and $_.EndsWith(' ') })
        $bases = @($literals | Where-Object { -not $_.StartsWith(' ') -and -not $_.EndsWith(' ') })
        foreach ($marker in @('Expected product evidence was not found.', 'Preserved by default', 'identity fingerprint could not be captured')) {
            Assert-TestTrue (@($suffixes | Where-Object { $_.Contains($marker) }).Count -eq 1) "The detector suffix containing '$marker' was not found."
        }
        $samples = New-Object System.Collections.Generic.List[string]
        foreach ($base in $bases) { $samples.Add($base) }
        foreach ($prefix in $prefixes) {
            if ($prefix.EndsWith('SHA-256: ')) { $samples.Add($prefix + ('AB' * 32)) }
            elseif ($prefix.EndsWith('Signer: ')) { $samples.Add($prefix + 'CN=Beijing Qihu Technology Co., Ltd., O=Beijing Qihu Technology Co., Ltd., C=CN') }
            elseif ($prefix.EndsWith('target: ')) { $samples.Add($prefix + 'C:\Users\Fixture\AppData\Local\dhpingbao') }
            else {
                $samples.Add($prefix + 'The exact uninstaller path chain was not proven safe.')
                $samples.Add($prefix + 'Access to the path is denied.')
            }
        }
        $withoutSuffix = @($samples.ToArray())
        foreach ($suffix in $suffixes) {
            foreach ($sample in $withoutSuffix) {
                $samples.Add($sample + $suffix)
                if ($suffix.Contains('identity fingerprint')) { $samples.Add($sample + $suffix + ' The registry value could not be read.') }
            }
        }
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($language in @('zh', 'en')) {
            Set-W360UiLanguage -Language $language
            foreach ($sample in $samples) {
                $text = Get-W360ReasonText -Finding ([pscustomobject]@{ Reason = $sample })
                $unmapped = if ($language -eq 'zh') { $text.StartsWith('原始判断依据（英文）') -or $text -notmatch '[\u4e00-\u9fff]' } else { $text.StartsWith('Original reason (English)') }
                if ($unmapped) { $failures.Add(('[{0}] {1}' -f $language, $sample)) }
            }
        }
        Set-W360UiLanguage -Language zh
        Assert-TestEqual -Expected 0 -Actual $failures.Count -Message ("Unmapped detector reasons:`r`n" + ($failures.ToArray() -join "`r`n"))
        $unmappedText = Get-W360ReasonText -Finding ([pscustomobject]@{ Reason = 'A brand new detector sentence.' })
        Assert-TestEqual -Expected '原始判断依据（英文）：A brand new detector sentence.' -Actual $unmappedText -Message 'Unmapped reasons must show the raw English text.'
        $composed = Get-W360ReasonText -Finding ([pscustomobject]@{ Reason = 'Known duohuipingbao installation path. Expected product evidence was not found.' })
        Assert-TestTrue ($composed.Contains('多绘屏保') -and $composed.Contains('只供查看')) 'The missing-evidence suffix must be explained in Chinese.'
        $found = Get-W360ReasonText -Finding ([pscustomobject]@{ Reason = 'Exact temporary component path with local 360/Qihoo file evidence.' })
        Assert-TestEqual -Expected '这是 360 组件的标准临时目录，并且找到了 360（奇虎）的文件证据。' -Actual $found -Message 'Confirmed evidence wording.'
        $missingEvidence = Get-W360ReasonText -Finding ([pscustomobject]@{ Reason = 'Exact temporary component path with local 360/Qihoo file evidence. Expected product evidence was not found.' })
        Assert-TestTrue ($missingEvidence.Contains('没有找到') -and -not $missingEvidence.Contains('并且找到了')) `
            ('A missing-evidence reason must never also claim evidence was found: ' + $missingEvidence)
    }

    Invoke-TestCase -Run $run -Name 'grouping keeps every finding exactly once, orders groups and never selects' -Test {
        $findings = @(
            (New-UiFinding -Kind 'Service' -Name '360rp' -Target '360rp' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'Unattributed'),
            (New-UiFinding -Kind 'OfflinePath' -Name 'Offline user 360 path' -Target 'D:\Users\Old\AppData\Roaming\360Safe' -Confidence 'ReviewOnly' -RemovalType 'None' -Offline $true -ProductKey 'OfflineWindows'),
            (New-UiFinding -Name '360se6 browser profile' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\User Data' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey '360SafeBrowser'),
            (New-UiFinding -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' -Target 'C:\Users\Fixture\AppData\Local\dhpingbao\huabaosetup.exe' -RemovalType 'VendorUninstaller'),
            (New-UiFinding),
            (New-UiFinding -Kind 'Driver' -Name '360Box64.sys' -Target 'C:\Windows\System32\drivers\360Box64.sys' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'Drivers'),
            (New-UiFinding -Name '360se6 browser application' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser')
        )
        $before = $findings | ConvertTo-Json -Depth 5
        $groups = @(Get-W360FindingGroups -Findings $findings)
        $after = $findings | ConvertTo-Json -Depth 5
        Assert-TestEqual -Expected $before -Actual $after -Message 'Grouping must not change any finding.'
        $seen = New-Object System.Collections.ArrayList
        foreach ($group in $groups) { foreach ($finding in @($group.Findings)) { [void]$seen.Add($finding) } }
        Assert-TestEqual -Expected $findings.Count -Actual $seen.Count -Message 'Grouping must keep every finding exactly once.'
        foreach ($finding in $findings) {
            $occurrences = @($seen | Where-Object { [object]::ReferenceEquals($_, $finding) }).Count
            Assert-TestEqual -Expected 1 -Actual $occurrences -Message ('A finding appears the wrong number of times: ' + $finding.Name)
        }
        $keys = @($groups | ForEach-Object { $_.Key })
        Assert-TestSequenceEqual -Expected @('360SafeBrowser', 'Duohui', 'Drivers', 'Unattributed', 'OfflineWindows') -Actual $keys -Message 'Group order is wrong.'
        $duohui = $groups[1]
        Assert-TestEqual -Expected 2 -Actual $duohui.SelectableCount -Message 'Duohui selectable count.'
        Assert-TestEqual -Expected 0 -Actual $duohui.ReviewCount -Message 'Duohui review count.'
        $browser = $groups[0]
        Assert-TestTrue (Test-W360FindingSelectable -Finding @($browser.Findings)[0]) 'Selectable findings must come first inside a group.'
        Assert-TestEqual -Expected '360 安全浏览器' -Actual $browser.DisplayName -Message 'Group display name.'
        foreach ($finding in $findings) {
            Assert-TestFalse ($null -ne $finding.PSObject.Properties['Selected']) 'Grouping must never add a selection flag.'
        }

        # The "delete or not" column of a product row is computed here, once, for the window and the tests.
        Assert-TestSequenceEqual -Expected @($findings[6].SelectionId) -Actual @($browser.SelectableIds) -Message 'Browser SelectableIds.'
        Assert-TestEqual -Expected '可以删除（1 项），1 项不删除' -Actual $browser.DecisionText -Message 'A mixed group names both counts.'
        Assert-TestEqual -Expected '不删除：书签和历史记录' -Actual $browser.KeepReasonText -Message 'The shared keep reason of a mixed group.'
        Assert-TestEqual -Expected '可以删除（2 项）' -Actual $duohui.DecisionText -Message 'A fully deletable group.'
        Assert-TestEqual -Expected '' -Actual $duohui.KeepReasonText -Message 'A group without kept items has no keep reason.'
        Assert-TestSequenceEqual -Expected @($findings[4].SelectionId, $findings[3].SelectionId) -Actual @($duohui.SelectableIds) `
            -Message 'SelectableIds follow the group findings order (folder before uninstaller).'
        Assert-TestEqual -Expected '不删除：系统驱动' -Actual $groups[2].DecisionText -Message 'A group without deletable items shows its single keep reason.'
        Assert-TestEqual -Expected 0 -Actual @($groups[2].SelectableIds).Count -Message 'A kept-only group has no SelectableIds.'
        foreach ($group in $groups) {
            foreach ($id in @($group.SelectableIds)) {
                Assert-TestTrue ($id -cmatch '^[0-9A-F]{64}$') 'SelectableIds must be normalised upper-case IDs.'
            }
            Assert-TestEqual -Expected ([int]$group.SelectableCount) -Actual @($group.SelectableIds).Count -Message ('SelectableIds count for ' + $group.Key)
        }
        $mixedReasons = @(Get-W360FindingGroups -Findings @(
            (New-UiFinding -Name '360se6 browser profile' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\User Data' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey '360SafeBrowser'),
            (New-UiFinding -Kind 'Bundle' -Name 'Aolande/Huajun winToolBox mixed bundle' -Target 'C:\Users\Fixture\AppData\Local\winToolBox' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey '360SafeBrowser')
        ))
        Assert-TestEqual -Expected '不删除' -Actual $mixedReasons[0].DecisionText -Message 'Different keep reasons fall back to the plain keep text.'
    }

    Invoke-TestCase -Run $run -Name 'Test-W360IsUnderPath normalises paths and never matches siblings' -Test {
        Assert-TestTrue (Test-W360IsUnderPath -Candidate 'C:\A\B' -Root 'C:\A\B') 'Equal paths are contained.'
        Assert-TestTrue (Test-W360IsUnderPath -Candidate 'c:\a\b\c.exe' -Root 'C:\A\B\') 'Comparison must ignore case and trailing separators.'
        Assert-TestTrue (Test-W360IsUnderPath -Candidate 'C:\A\B\..\B\x' -Root 'C:\A\B') 'Paths must be normalised.'
        Assert-TestFalse (Test-W360IsUnderPath -Candidate 'C:\A\B2\x' -Root 'C:\A\B') 'A sibling with the same prefix is not contained.'
        Assert-TestTrue (Test-W360IsUnderPath -Candidate 'C:\x\y' -Root 'C:\') 'A drive root contains its children.'
        Assert-TestTrue (Test-W360IsUnderPath -Candidate 'C:\用户 目录\多绘\a b.exe' -Root 'C:\用户 目录\多绘') 'Chinese and space paths must work.'
        Assert-TestFalse (Test-W360IsUnderPath -Candidate 'relative\path' -Root 'C:\') 'Relative paths are invalid.'
        Assert-TestFalse (Test-W360IsUnderPath -Candidate 'C:\bad|name' -Root 'C:\') 'Invalid characters make the path invalid.'
        Assert-TestFalse (Test-W360IsUnderPath -Candidate '' -Root 'C:\') 'Empty paths are invalid.'
    }

    $planRoot = 'C:\Users\测试 用户\AppData\Local\dhpingbao'
    $planParent = New-UiFinding -Target $planRoot
    $planVendor = New-UiFinding -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' -Target ($planRoot + '\huabaosetup.exe') -RemovalType 'VendorUninstaller' -ValueName ('C4' * 32)
    $planProcess = New-UiFinding -Kind 'Process' -Name 'dhpingbao.exe' -Target '5150' -RemovalType 'Process' -ValueName ($planRoot + '\bin\dhpingbao.exe')
    $planReviewChild = New-UiFinding -Name 'Duohui temporary package' -Target ($planRoot + '\cache 缓存') -Confidence 'ReviewOnly' -RemovalType 'None'
    $planSibling = New-UiFinding -Name 'Huabao temporary package' -Target 'C:\Users\测试 用户\AppData\Local\dhpingbao2' -ProductKey 'Duohui'
    $planBrowser = New-UiFinding -Name '360se6 browser application' -Target 'C:\Users\测试 用户\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser'

    Invoke-TestCase -Run $run -Name 'selection plan rejects empty, too many and unknown selections' -Test {
        $findings = @($planParent, $planVendor, $planBrowser)
        $empty = Get-W360SelectionPlan -Findings $findings -SelectedIds @()
        Assert-TestFalse $empty.CanSubmit 'An empty selection cannot be submitted.'
        Assert-TestEqual -Expected 'NothingSelected' -Actual @($empty.Problems)[0].Code -Message 'Empty selection problem code.'

        $many = @(1..65 | ForEach-Object { New-UiFinding -Name 'Roaming SoftMgr cache' -Target ("C:\Users\Fixture\AppData\Roaming\SoftMgr{0}" -f $_) -ProductKey '360SoftMgr' })
        $manyPlan = Get-W360SelectionPlan -Findings $many -SelectedIds @($many | ForEach-Object { $_.SelectionId })
        Assert-TestFalse $manyPlan.CanSubmit '65 selected IDs must be rejected before any UAC.'
        $tooMany = @($manyPlan.Problems | Where-Object { $_.Code -eq 'TooMany' })
        Assert-TestEqual -Expected 1 -Actual $tooMany.Count -Message 'The TooMany problem is missing.'
        Assert-TestTrue ($tooMany[0].Message.Contains('65') -and $tooMany[0].Message.Contains('64')) 'The TooMany message must state the count and the limit.'
        Assert-TestTrue ($tooMany[0].Resolution.Contains('一次只删一个软件') -and $tooMany[0].Resolution.Contains('下一批')) 'The TooMany resolution must explain batching.'

        $unknownPlan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($planParent.SelectionId.ToLowerInvariant(), ('0F' * 32))
        $unknown = @($unknownPlan.Problems | Where-Object { $_.Code -eq 'UnknownId' })
        Assert-TestEqual -Expected 1 -Actual $unknown.Count -Message 'Exactly one unknown ID problem is expected.'
        Assert-TestEqual -Expected ('0F' * 32) -Actual $unknown[0].ParentSelectionId -Message 'The unknown ID must be reported.'
        Assert-TestEqual -Expected 1 -Actual @($unknownPlan.SelectedFindings).Count -Message 'IDs are compared case-insensitively.'
        $reviewPlan = Get-W360SelectionPlan -Findings @($planReviewChild) -SelectedIds @((New-UiId -Seed 'review'))
        Assert-TestFalse $reviewPlan.CanSubmit 'A non-selectable finding can never be submitted.'
    }

    Invoke-TestCase -Run $run -Name 'selection plan offers to add selectable children of a selected parent' -Test {
        $findings = @($planParent, $planVendor, $planProcess, $planSibling, $planBrowser)
        $before = $findings | ConvertTo-Json -Depth 5
        $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($planParent.SelectionId)
        Assert-TestEqual -Expected $before -Actual ($findings | ConvertTo-Json -Depth 5) -Message 'The plan must never mutate findings.'
        Assert-TestFalse $plan.CanSubmit 'A parent with unselected selectable children cannot be submitted.'
        $childProblem = @($plan.Problems | Where-Object { $_.Code -eq 'ParentContainsSelectableChild' })
        Assert-TestEqual -Expected 1 -Actual $childProblem.Count -Message 'The selectable-child problem is missing.'
        Assert-TestSequenceEqual -Expected @($planVendor.SelectionId, $planProcess.SelectionId) -Actual @($childProblem[0].AddSelectionIds) `
            -Message 'AddSelectionIds must list the contained selectable children only (not the sibling).'
        Assert-TestEqual -Expected $planParent.SelectionId -Actual $childProblem[0].ParentSelectionId -Message 'ParentSelectionId.'
        Assert-TestEqual -Expected '可以把它们也勾上，或者不删“多绘屏保安装文件夹”。' -Actual $childProblem[0].Resolution -Message 'Child resolution text.'
        Assert-TestTrue ($childProblem[0].Message.Contains('一起删掉')) 'The child problem must say the unticked inner items would be deleted too.'
        Assert-TestEqual -Expected 4 -Actual @($plan.PreservedFindings).Count -Message 'Preserved findings are the unselected selectable ones.'

        $added = @(Add-W360PlanSelections -SelectedIds @($planParent.SelectionId) -Problem $childProblem[0])
        Assert-TestSequenceEqual -Expected @($planParent.SelectionId, $planVendor.SelectionId, $planProcess.SelectionId) -Actual $added -Message 'Add-W360PlanSelections result.'
        $fixed = Get-W360SelectionPlan -Findings $findings -SelectedIds $added
        Assert-TestTrue $fixed.CanSubmit ('The plan must pass after adding the children: ' + (@($fixed.Problems | ForEach-Object { $_.Code }) -join ','))
        Assert-TestTrue $fixed.VendorUninstallerSelected 'The vendor uninstaller must be reported as selected.'
        Assert-TestSequenceEqual -Expected @('Duohui') -Actual @($fixed.AffectedProductKeys) -Message 'Affected product keys.'
        Assert-TestEqual -Expected 2 -Actual @($fixed.PreservedFindings).Count -Message 'The sibling and browser stay preserved.'
    }

    Invoke-TestCase -Run $run -Name 'selection plan blocks a parent that contains protected content' -Test {
        $findings = @($planParent, $planReviewChild, $planBrowser)
        $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($planParent.SelectionId)
        Assert-TestFalse $plan.CanSubmit 'A parent containing review-only content cannot be submitted.'
        $protected = @($plan.Problems | Where-Object { $_.Code -eq 'ParentContainsProtectedChild' })
        Assert-TestEqual -Expected 1 -Actual $protected.Count -Message 'The protected-child problem is missing.'
        Assert-TestEqual -Expected 0 -Actual @($protected[0].AddSelectionIds).Count -Message 'Protected children can never be added.'
        Assert-TestTrue ([object]::ReferenceEquals(@($protected[0].BlockingFindings)[0], $planReviewChild)) 'The protected child must be listed as blocking.'
        Assert-TestTrue ($protected[0].Resolution.StartsWith('请不要勾选') -and $protected[0].Resolution.Contains('要保留的东西')) 'Protected resolution text.'
    }

    Invoke-TestCase -Run $run -Name 'selection plan requires the install root for a vendor uninstaller' -Test {
        $findings = @($planParent, $planVendor, $planBrowser)
        $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($planVendor.SelectionId, $planBrowser.SelectionId)
        Assert-TestFalse $plan.CanSubmit 'A vendor uninstaller without its root cannot be submitted.'
        $vendorProblem = @($plan.Problems | Where-Object { $_.Code -eq 'VendorUninstallerNeedsInstallRoot' })
        Assert-TestEqual -Expected 1 -Actual $vendorProblem.Count -Message 'The vendor root problem is missing.'
        Assert-TestSequenceEqual -Expected @($planParent.SelectionId) -Actual @($vendorProblem[0].AddSelectionIds) -Message 'The selectable dhpingbao root must be offered.'
        $added = @(Add-W360PlanSelections -SelectedIds @($planVendor.SelectionId, $planBrowser.SelectionId) -Problem $vendorProblem[0])
        Assert-TestTrue (Get-W360SelectionPlan -Findings $findings -SelectedIds $added).CanSubmit 'Adding the root must resolve the problem.'
        $noRoot = Get-W360SelectionPlan -Findings @($planVendor) -SelectedIds @($planVendor.SelectionId)
        $noRootProblem = @($noRoot.Problems | Where-Object { $_.Code -eq 'VendorUninstallerNeedsInstallRoot' })
        Assert-TestEqual -Expected 0 -Actual @($noRootProblem[0].AddSelectionIds).Count -Message 'Nothing can be added when the root is not selectable.'
    }

    Invoke-TestCase -Run $run -Name 'deletable selection only adds selectable candidates and shrinks to the largest safe set' -Test {
        $assertSafe = {
            param([string]$Label, [object[]]$Findings, [string[]]$Candidates, [string[]]$Selected, [object]$Result)
            $normal = { param($Values) @(@($Values) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() }) }
            $selectableIds = @($Findings | Where-Object { Test-W360FindingSelectable -Finding $_ } | ForEach-Object { Get-W360FindingSelectionId -Finding $_ })
            $base = @(& $normal $Selected | Where-Object { $selectableIds -contains $_ })
            $allowed = @($base) + @(& $normal $Candidates)
            foreach ($id in $base) { Assert-TestTrue (@($Result.Ids) -contains $id) "$Label must keep every already selected ID." }
            foreach ($id in @($Result.Ids)) {
                Assert-TestTrue ($allowed -contains $id) "$Label added an ID outside the selection and the candidates: $id"
                Assert-TestTrue ($selectableIds -contains $id) "$Label returned a non-selectable ID: $id"
            }
            foreach ($id in @($Result.AddedIds)) { Assert-TestFalse ($base -contains $id) "$Label reported an already selected ID as added." }
            $plan = Get-W360SelectionPlan -Findings $Findings -SelectedIds @($Result.Ids)
            foreach ($problem in @($plan.Problems)) {
                if (@('NothingSelected', 'TooMany') -contains $problem.Code) { continue }
                Assert-TestTrue ($base -contains $problem.ParentSelectionId) ("$Label left a problem on an added ID: " + $problem.Code)
            }
        }

        # A product row whose folder holds content that must be kept: the folder and then its uninstaller drop out.
        $protectedFindings = @($planParent, $planVendor, $planProcess, $planReviewChild, $planSibling, $planBrowser)
        $before = $protectedFindings | ConvertTo-Json -Depth 5
        $groupIds = @($planParent.SelectionId, $planVendor.SelectionId, $planProcess.SelectionId, $planReviewChild.SelectionId, $planSibling.SelectionId)
        $shrunk = Get-W360DeletableSelection -Findings $protectedFindings -CandidateIds $groupIds -SelectedIds @()
        Assert-TestEqual -Expected $before -Actual ($protectedFindings | ConvertTo-Json -Depth 5) -Message 'The selection helper must never mutate findings.'
        Assert-TestSequenceEqual -Expected @($planProcess.SelectionId, $planSibling.SelectionId) -Actual @($shrunk.Ids) -Message 'Only the safe items stay selected.'
        Assert-TestSequenceEqual -Expected @($planProcess.SelectionId, $planSibling.SelectionId) -Actual @($shrunk.AddedIds) -Message 'AddedIds.'
        Assert-TestSequenceEqual -Expected @('ParentContainsProtectedChild', 'VendorUninstallerNeedsInstallRoot') -Actual @($shrunk.Removed | ForEach-Object { $_.Code }) `
            -Message 'The folder with protected content is removed first, then the uninstaller that needs it.'
        Assert-TestEqual -Expected $planParent.SelectionId -Actual @($shrunk.Removed)[0].SelectionId -Message 'Removed SelectionId.'
        Assert-TestEqual -Expected '多绘屏保安装文件夹' -Actual @($shrunk.Removed)[0].DisplayName -Message 'Removed DisplayName.'
        Assert-TestEqual -Expected '里面有要保留的东西' -Actual @($shrunk.Removed)[0].ReasonText -Message 'Removed ReasonText.'
        Assert-TestTrue ([object]::ReferenceEquals(@($shrunk.Removed)[0].Finding, $planParent)) 'Removed Finding.'
        Assert-TestEqual -Expected '要和它所在的文件夹一起删' -Actual @($shrunk.Removed)[1].ReasonText -Message 'Uninstaller ReasonText.'
        Assert-TestTrue (Get-W360SelectionPlan -Findings $protectedFindings -SelectedIds @($shrunk.Ids)).CanSubmit 'The shrunk selection must pass the selection plan.'
        & $assertSafe 'Protected group' $protectedFindings $groupIds @() $shrunk
        $again = Get-W360DeletableSelection -Findings $protectedFindings -CandidateIds $groupIds -SelectedIds @()
        Assert-TestEqual -Expected ($shrunk | ConvertTo-Json -Depth 3) -Actual ($again | ConvertTo-Json -Depth 3) -Message 'The result must be deterministic.'

        # Without protected content the whole product row is selected.
        $cleanFindings = @($planParent, $planVendor, $planProcess, $planSibling, $planBrowser)
        $cleanIds = @($planParent.SelectionId, $planVendor.SelectionId, $planProcess.SelectionId, $planSibling.SelectionId)
        $whole = Get-W360DeletableSelection -Findings $cleanFindings -CandidateIds $cleanIds
        Assert-TestSequenceEqual -Expected $cleanIds -Actual @($whole.Ids) -Message 'A safe product row is selected completely.'
        Assert-TestEqual -Expected 0 -Actual @($whole.Removed).Count -Message 'Nothing is removed from a safe row.'
        Assert-TestFalse (@($whole.Ids) -contains $planBrowser.SelectionId) 'Another product is never selected.'
        Assert-TestTrue (Get-W360SelectionPlan -Findings $cleanFindings -SelectedIds @($whole.Ids)).CanSubmit 'The whole row must pass the selection plan.'

        # A parent whose selectable children are not candidates is dropped; it is never widened by adding them.
        $parentOnly = Get-W360DeletableSelection -Findings $cleanFindings -CandidateIds @($planParent.SelectionId)
        Assert-TestEqual -Expected 0 -Actual @($parentOnly.Ids).Count -Message 'A parent with unticked selectable children is not selected.'
        Assert-TestEqual -Expected 'ParentContainsSelectableChild' -Actual @($parentOnly.Removed)[0].Code -Message 'Selectable-child removal code.'
        & $assertSafe 'Parent only' $cleanFindings @($planParent.SelectionId) @() $parentOnly

        # IDs the user already selected stay, even with a problem of their own; only candidates are shrunk.
        $kept = Get-W360DeletableSelection -Findings $protectedFindings -CandidateIds @($planBrowser.SelectionId) -SelectedIds @($planParent.SelectionId.ToLowerInvariant())
        Assert-TestSequenceEqual -Expected @($planParent.SelectionId, $planBrowser.SelectionId) -Actual @($kept.Ids) -Message 'Already selected IDs are never removed.'
        Assert-TestSequenceEqual -Expected @($planBrowser.SelectionId) -Actual @($kept.AddedIds) -Message 'Only the candidate counts as added.'
        & $assertSafe 'Kept base' $protectedFindings @($planBrowser.SelectionId) @($planParent.SelectionId) $kept

        # Non-selectable, unknown, blank and differently spelled candidates.
        $odd = @('', $planReviewChild.SelectionId, ('0F' * 32), $planSibling.SelectionId.ToLowerInvariant(), ('  ' + $planBrowser.SelectionId + ' '))
        $normalised = Get-W360DeletableSelection -Findings $protectedFindings -CandidateIds $odd
        Assert-TestSequenceEqual -Expected @($planSibling.SelectionId, $planBrowser.SelectionId) -Actual @($normalised.Ids) -Message 'Only selectable candidates are added, normalised.'
        & $assertSafe 'Odd candidates' $protectedFindings $odd @() $normalised

        # Empty candidates return the selection unchanged.
        $empty = Get-W360DeletableSelection -Findings $protectedFindings -CandidateIds @() -SelectedIds @($planSibling.SelectionId)
        Assert-TestSequenceEqual -Expected @($planSibling.SelectionId) -Actual @($empty.Ids) -Message 'Empty candidates keep the base.'
        Assert-TestEqual -Expected 0 -Actual (@($empty.Removed).Count + @($empty.AddedIds).Count) -Message 'Empty candidates remove and add nothing.'
        $none = Get-W360DeletableSelection -Findings $protectedFindings -CandidateIds $null
        Assert-TestEqual -Expected 0 -Actual @($none.Ids).Count -Message 'No candidates and no selection give an empty result.'

        # Removing one ID can create a problem for another: the loop runs until nothing is left to remove.
        $outer = New-UiFinding -Name 'Some future detector name' -Target 'C:\Users\测试 用户\AppData\Local' -ProductKey 'Duohui'
        $lonelyVendor = New-UiFinding -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' -Target ($planRoot + '\huabaosetup.exe') -RemovalType 'VendorUninstaller' -ValueName ('D7' * 32)
        $chainFindings = @($outer, $lonelyVendor)
        $chain = Get-W360DeletableSelection -Findings $chainFindings -CandidateIds @($outer.SelectionId, $lonelyVendor.SelectionId)
        Assert-TestEqual -Expected 0 -Actual @($chain.Ids).Count -Message 'Both chained items must be removed.'
        Assert-TestSequenceEqual -Expected @($lonelyVendor.SelectionId, $outer.SelectionId) -Actual @($chain.Removed | ForEach-Object { $_.SelectionId }) `
            -Message 'Removed follows round order: the uninstaller first, then the folder that now has an unticked item inside.'
        Assert-TestSequenceEqual -Expected @('VendorUninstallerNeedsInstallRoot', 'ParentContainsSelectableChild') -Actual @($chain.Removed | ForEach-Object { $_.Code }) -Message 'Chain codes.'

        # TooMany is left to the counter: 65 safe candidates stay selected.
        $many = @(1..65 | ForEach-Object { New-UiFinding -Name 'Roaming SoftMgr cache' -Target ("C:\Users\Fixture\AppData\Roaming\SoftMgr{0}" -f $_) -ProductKey '360SoftMgr' })
        $manyResult = Get-W360DeletableSelection -Findings $many -CandidateIds @($many | ForEach-Object { $_.SelectionId })
        Assert-TestEqual -Expected 65 -Actual @($manyResult.Ids).Count -Message 'TooMany is not handled by shrinking.'
    }

    Invoke-TestCase -Run $run -Name 'findings that can never be deleted stay unselectable even when they carry a well-formed SelectionId' -Test {
        # The core never gives these an ID, but the helpers must not rely on that: the agent route passes IDs through them.
        $reviewWithId = New-UiFinding -Kind 'Service' -Name '360rp' -Target '360rp' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'Unattributed' `
            -SelectionId (New-UiId -Seed 'review-with-id')
        $offlineWithId = New-UiFinding -Kind 'OfflinePath' -Name 'Offline Windows 360 path' -Target 'D:\Windows.old\Program Files\360' -Offline $true -ProductKey 'OfflineWindows' `
            -SelectionId (New-UiId -Seed 'offline-with-id')
        $offlineStringWithId = [pscustomobject]@{ Kind = 'Path'; Name = 'Offline user 360 path'; Target = 'D:\Users\Old\AppData\Roaming\360Safe'; Confidence = 'Confirmed'
            Reason = 'x'; RemovalType = 'Path'; ValueName = ''; Offline = 'True'; ProductKey = 'OfflineWindows'; SelectionId = (New-UiId -Seed 'offline-string-with-id') }
        $noRemovalWithId = New-UiFinding -Name 'Duohui temporary package' -Target 'C:\Users\Fixture\AppData\Local\Temp\duohui-none' -RemovalType 'None' `
            -SelectionId (New-UiId -Seed 'none-with-id')
        $never = @($reviewWithId, $offlineWithId, $offlineStringWithId, $noRemovalWithId)
        $neverIds = @($never | ForEach-Object { [string]$_.SelectionId })
        foreach ($id in $neverIds) { Assert-TestTrue ($id -cmatch '^[0-9A-F]{64}$') 'The fixture needs a well-formed SelectionId.' }
        $findings = @($planSibling) + $never
        foreach ($finding in $never) { Assert-TestFalse (Test-W360FindingSelectable -Finding $finding) ('Never selectable: ' + $finding.Name) }

        $helper = Get-W360DeletableSelection -Findings $findings -CandidateIds (@($neverIds) + @($planSibling.SelectionId)) -SelectedIds $neverIds
        Assert-TestSequenceEqual -Expected @($planSibling.SelectionId) -Actual @($helper.Ids) -Message 'Only the deletable candidate is selected.'
        Assert-TestSequenceEqual -Expected @($planSibling.SelectionId) -Actual @($helper.AddedIds) -Message 'Nothing that can never be deleted is added.'
        foreach ($id in $neverIds) { Assert-TestFalse (@($helper.Removed | ForEach-Object { $_.SelectionId }) -contains $id) 'A never-selectable item is not even a candidate.' }

        $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds (@($neverIds) + @($planSibling.SelectionId))
        Assert-TestFalse ([bool]$plan.CanSubmit) 'A plan with never-selectable IDs can never be submitted.'
        Assert-TestSequenceEqual -Expected @($planSibling.SelectionId) -Actual @($plan.SelectedFindings | ForEach-Object { $_.SelectionId }) -Message 'Only the deletable finding is selected.'
        Assert-TestEqual -Expected $neverIds.Count -Actual @($plan.Problems | Where-Object { $_.Code -eq 'UnknownId' }).Count -Message 'Every never-selectable ID is reported.'
        $onlyNever = Get-W360SelectionPlan -Findings $findings -SelectedIds $neverIds
        Assert-TestFalse ([bool]$onlyNever.CanSubmit) 'Only never-selectable IDs can never be submitted.'
        Assert-TestEqual -Expected 0 -Actual @($onlyNever.SelectedFindings).Count -Message 'No never-selectable finding is selected.'
        $groups = @(Get-W360FindingGroups -Findings $never)
        foreach ($group in $groups) { Assert-TestEqual -Expected 0 -Actual @($group.SelectableIds).Count -Message ('A product row of never-selectable items has no IDs: ' + $group.Key) }
    }

    Invoke-TestCase -Run $run -Name 'effectively deletable set: the shrink result of every deletable item, never wider, and shown as kept with its reason' -Test {
        # The folder holds a kept item, and the uninstaller inside it needs the folder: neither can ever pass the check.
        $protectedFindings = @($planParent, $planVendor, $planProcess, $planReviewChild, $planSibling, $planBrowser)
        $before = $protectedFindings | ConvertTo-Json -Depth 5
        $effective = Get-W360EffectiveDeletableIds -Findings $protectedFindings
        Assert-TestEqual -Expected $before -Actual ($protectedFindings | ConvertTo-Json -Depth 5) -Message 'The effective set must never mutate findings.'
        $selectableIds = @($protectedFindings | Where-Object { Test-W360FindingSelectable -Finding $_ } | ForEach-Object { Get-W360FindingSelectionId -Finding $_ })
        Assert-TestEqual -Expected 5 -Actual $selectableIds.Count -Message 'The fixture has five deletable items.'
        $shrunk = Get-W360DeletableSelection -Findings $protectedFindings -CandidateIds $selectableIds -SelectedIds @()
        Assert-TestSequenceEqual -Expected @($shrunk.Ids) -Actual @($effective.Ids) -Message 'The effective set is exactly the shrink result of every deletable item.'
        Assert-TestSequenceEqual -Expected @($planProcess.SelectionId, $planSibling.SelectionId, $planBrowser.SelectionId) -Actual @($effective.Ids) -Message 'Effective IDs.'
        foreach ($id in @($effective.Ids)) { Assert-TestTrue ($selectableIds -contains $id) "The effective set holds an item that cannot be deleted: $id" }
        Assert-TestEqual -Expected 5 -Actual ([int]$effective.SelectableCount) -Message 'SelectableCount counts the deletable items before narrowing.'
        Assert-TestSequenceEqual -Expected @($planParent.SelectionId, $planVendor.SelectionId) -Actual @($effective.Removed | ForEach-Object { $_.SelectionId }) -Message 'Removed items.'
        Assert-TestSequenceEqual -Expected @('ParentContainsProtectedChild', 'VendorUninstallerNeedsInstallRoot') -Actual @($effective.Removed | ForEach-Object { $_.Code }) -Message 'Removed codes.'
        Assert-TestSequenceEqual -Expected @('KeptContentInside', 'NeedsItsFolder') -Actual @($effective.Removed | ForEach-Object { $_.StatusCode }) -Message 'Removed status codes.'
        Assert-TestSequenceEqual -Expected @('里面有要保留的东西', '要和它所在的文件夹一起删') -Actual @($effective.Removed | ForEach-Object { $_.ReasonText }) -Message 'Removed reasons.'
        Assert-TestTrue ([bool](Get-W360SelectionPlan -Findings $protectedFindings -SelectedIds @($effective.Ids)).CanSubmit) 'The whole effective set passes the selection check.'
        Assert-TestEqual -Expected ((Get-W360EffectiveDeletableIds -Findings $protectedFindings).Ids -join ',') -Actual (@($effective.Ids) -join ',') -Message 'The effective set is deterministic.'
        Assert-TestEqual -Expected 0 -Actual @((Get-W360EffectiveDeletableIds -Findings @()).Ids).Count -Message 'No findings give an empty set.'
        Assert-TestEqual -Expected 0 -Actual @((Get-W360EffectiveDeletableIds -Findings @($planReviewChild)).Ids).Count -Message 'Only kept findings give an empty set.'

        # Every selection that passes the check lies inside the set: all 31 selections of the five deletable items.
        $passing = 0
        for ($mask = 1; $mask -lt (1 -shl $selectableIds.Count); $mask++) {
            $subset = @(for ($bit = 0; $bit -lt $selectableIds.Count; $bit++) { if (($mask -band (1 -shl $bit)) -ne 0) { $selectableIds[$bit] } })
            if (-not [bool](Get-W360SelectionPlan -Findings $protectedFindings -SelectedIds $subset).CanSubmit) { continue }
            $passing++
            foreach ($id in $subset) { Assert-TestTrue ($effective.IdSet.Contains($id)) "A selection that passes the check holds an item outside the effective set: $id" }
        }
        Assert-TestEqual -Expected 7 -Actual $passing -Message 'Every non-empty selection of the three effective items passes, and nothing else does.'

        # Statuses: the folder and the uninstaller read as kept with their reason; the core rule itself is unchanged.
        $parentStatus = Get-W360FindingStatus -Finding $planParent -Effective $effective
        Assert-TestEqual -Expected 'KeptContentInside' -Actual $parentStatus.Code -Message 'Folder with kept content status.'
        Assert-TestEqual -Expected '不删除：里面有要保留的东西' -Actual $parentStatus.Text -Message 'Folder with kept content text.'
        Assert-TestTrue ($parentStatus.Explanation.Contains('一起删掉')) ('Folder with kept content explanation: ' + $parentStatus.Explanation)
        Assert-TestTrue ([bool]$parentStatus.Selectable) 'The core rule still calls the folder selectable.'
        Assert-TestFalse ([bool]$parentStatus.Deletable) 'The folder is not deletable in this check result.'
        $vendorStatus = Get-W360FindingStatus -Finding $planVendor -Effective $effective
        Assert-TestEqual -Expected 'NeedsItsFolder' -Actual $vendorStatus.Code -Message 'Uninstaller without its folder status.'
        Assert-TestEqual -Expected '不删除：要和它所在的文件夹一起删' -Actual $vendorStatus.Text -Message 'Uninstaller without its folder text.'
        Assert-TestTrue ($vendorStatus.Explanation.Contains('卸载程序') -and $vendorStatus.Explanation.Contains('文件夹')) ('Uninstaller explanation: ' + $vendorStatus.Explanation)
        Assert-TestFalse ([bool]$vendorStatus.Deletable) 'The uninstaller is not deletable in this check result.'
        $siblingStatus = Get-W360FindingStatus -Finding $planSibling -Effective $effective
        Assert-TestEqual -Expected 'AwaitingChoice' -Actual $siblingStatus.Code -Message 'An effective item can be deleted.'
        Assert-TestTrue ([bool]$siblingStatus.Deletable) 'An effective item is deletable.'
        Assert-TestEqual -Expected 'InsufficientEvidence' -Actual (Get-W360FindingStatus -Finding $planReviewChild -Effective $effective).Code -Message 'Kept items keep their own status.'
        Assert-TestEqual -Expected 'AwaitingChoice' -Actual (Get-W360FindingStatus -Finding $planParent).Code -Message 'Without the set the status is unchanged.'
        Assert-TestTrue (Test-W360FindingSelectable -Finding $planParent) 'Test-W360FindingSelectable is unchanged.'
        Assert-TestEqual -Expected '不会删除。' -Actual (Get-W360ImpactText -Finding $planParent -Effective $effective) -Message 'A kept folder does not describe deleting.'
        Assert-TestFalse ((Get-W360ImpactText -Finding $planParent).StartsWith('不会删除')) 'Without the set the impact is unchanged.'
        Set-W360UiLanguage -Language en
        try {
            Assert-TestEqual -Expected "Won't delete: it holds things that are kept" -Actual (Get-W360FindingStatus -Finding $planParent -Effective $effective).Text -Message 'English kept-content status.'
            Assert-TestEqual -Expected "Won't delete: it goes together with its folder" -Actual (Get-W360FindingStatus -Finding $planVendor -Effective $effective).Text -Message 'English uninstaller status.'
        }
        finally { Set-W360UiLanguage -Language zh }

        # A missing, malformed or too wide set never makes anything deletable.
        $reviewWithId = New-UiFinding -Name 'Duohui temporary package' -Target ($planRoot + '\cache 缓存') -Confidence 'ReviewOnly' -RemovalType 'None' -SelectionId (New-UiId -Seed 'review-effective')
        $wideSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($finding in @($protectedFindings) + @($reviewWithId)) { if (-not [string]::IsNullOrEmpty([string]$finding.SelectionId)) { [void]$wideSet.Add([string]$finding.SelectionId) } }
        $wide = [pscustomobject]@{ IdSet = $wideSet }
        Assert-TestFalse (Test-W360FindingDeletable -Finding $reviewWithId -Effective $wide) 'A set that names a kept item never makes it deletable.'
        foreach ($bogus in @($null, @{ IdSet = $wideSet }, [pscustomobject]@{ IdSet = @($planSibling.SelectionId) }, [pscustomobject]@{ IdSet = [string]$planSibling.SelectionId }, [pscustomobject]@{ Ids = @($planSibling.SelectionId) })) {
            foreach ($finding in $protectedFindings) {
                Assert-TestFalse (Test-W360FindingDeletable -Finding $finding -Effective $bogus) ('A malformed set made an item deletable: ' + $finding.Name)
            }
            $bogusGroups = @(Get-W360FindingGroups -Findings $protectedFindings -Effective ([pscustomobject]@{ IdSet = @($planSibling.SelectionId) }))
            foreach ($group in $bogusGroups) { Assert-TestEqual -Expected 0 -Actual @($group.SelectableIds).Count -Message 'A malformed set offers nothing.' }
        }
        $wideGroups = @(Get-W360FindingGroups -Findings (@($protectedFindings) + @($reviewWithId)) -Effective $wide)
        foreach ($group in $wideGroups) {
            Assert-TestFalse (@($group.SelectableIds) -contains [string]$reviewWithId.SelectionId) 'A too wide set never offers a kept item.'
        }

        # Groups count the items outside the set as kept.
        $groups = @(Get-W360FindingGroups -Findings $protectedFindings -Effective $effective)
        $duohui = @($groups | Where-Object { $_.Key -eq 'Duohui' })[0]
        Assert-TestEqual -Expected 2 -Actual ([int]$duohui.SelectableCount) -Message 'Mixed product deletable count.'
        Assert-TestEqual -Expected 3 -Actual ([int]$duohui.ReviewCount) -Message 'Mixed product kept count.'
        Assert-TestSequenceEqual -Expected @($planSibling.SelectionId, $planProcess.SelectionId) -Actual @($duohui.SelectableIds) -Message 'Mixed product IDs are the effective ones only.'
        Assert-TestEqual -Expected '可以删除（2 项），3 项不删除' -Actual $duohui.DecisionText -Message 'Mixed product decision.'
        Assert-TestEqual -Expected '不删除' -Actual $duohui.KeepReasonText -Message 'Different keep reasons fall back to the plain keep text.'
        Assert-TestTrue ([object]::ReferenceEquals(@($duohui.Findings)[0], $planSibling) -and [object]::ReferenceEquals(@($duohui.Findings)[1], $planProcess)) 'The deletable items come first.'
        $computed = @(Get-W360FindingGroups -Findings $protectedFindings)
        Assert-TestEqual -Expected (@($groups | ForEach-Object { '{0}:{1}:{2}' -f $_.Key, $_.DecisionText, (@($_.SelectableIds) -join ';') }) -join '|') `
            -Actual (@($computed | ForEach-Object { '{0}:{1}:{2}' -f $_.Key, $_.DecisionText, (@($_.SelectableIds) -join ';') }) -join '|') -Message 'Grouping without the set works it out the same way.'
        foreach ($group in $groups) {
            foreach ($id in @($group.SelectableIds)) { Assert-TestTrue ($effective.IdSet.Contains([string]$id)) "A product offers an item outside the effective set: $id" }
        }
        $otherChild = New-UiFinding -Name '360 temporary package' -Target ($planRoot + '\cache\360setup.cab') -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'Unattributed' `
            -Reason 'Filename pattern matched, but a CAB name alone is not enough evidence for automatic deletion.'
        $keptOnly = @(Get-W360FindingGroups -Findings @($planParent, $otherChild))
        Assert-TestSequenceEqual -Expected @('Duohui', 'Unattributed') -Actual @($keptOnly | ForEach-Object { $_.Key }) -Message 'Kept-only products keep the product order.'
        Assert-TestEqual -Expected 0 -Actual @($keptOnly[0].SelectableIds).Count -Message 'A product whose only deletable item is outside the set offers nothing.'
        Assert-TestEqual -Expected '不删除：里面有要保留的东西' -Actual $keptOnly[0].DecisionText -Message 'The product row names the reason.'
        Assert-TestEqual -Expected '不删除：里面有要保留的东西' -Actual $keptOnly[0].KeepReasonText -Message 'The product keep reason.'
        Assert-TestEqual -Expected '不删除：要和它所在的文件夹一起删' -Actual @(Get-W360FindingGroups -Findings @($planVendor))[0].DecisionText -Message 'An uninstaller without its folder reads as kept.'

        # Scan outcomes count products and items with the set, work it out once and carry it.
        $keptPath = Join-Path $fixtureRoot 'scan-effective-kept.json'
        Write-UiScanReport -Path $keptPath -Findings @($planParent, $otherChild)
        $keptOutcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $keptPath
        Assert-TestEqual -Expected 'Findings' -Actual $keptOutcome.State -Message 'Kept-only effective outcome state.'
        Assert-TestEqual -Expected 0 -Actual $keptOutcome.DeletableGroupCount -Message 'A product whose only item can never pass counts as kept.'
        Assert-TestEqual -Expected 0 -Actual $keptOutcome.SelectableCount -Message 'Kept-only effective deletable count.'
        Assert-TestEqual -Expected 2 -Actual $keptOutcome.ReviewCount -Message 'Kept-only effective kept count.'
        Assert-TestEqual -Expected '找到了一些 360 相关的内容，但都不删除' -Actual $keptOutcome.Headline -Message 'The headline never offers an item that can never pass.'
        Assert-TestTrue ([object]::ReferenceEquals((Get-W360OutcomeEffectiveDeletable -Outcome $keptOutcome), $keptOutcome.EffectiveDeletable)) 'The outcome carries its set.'
        $mixedPath = Join-Path $fixtureRoot 'scan-effective-mixed.json'
        Write-UiScanReport -Path $mixedPath -Findings $protectedFindings
        $mixedOutcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $mixedPath
        Assert-TestEqual -Expected 2 -Actual $mixedOutcome.DeletableGroupCount -Message 'Mixed effective products.'
        Assert-TestEqual -Expected 3 -Actual $mixedOutcome.SelectableCount -Message 'Mixed effective deletable count.'
        Assert-TestEqual -Expected 3 -Actual $mixedOutcome.ReviewCount -Message 'Mixed effective kept count.'
        Assert-TestEqual -Expected '找到 2 个可以删除的 360 软件' -Actual $mixedOutcome.Headline -Message 'Mixed effective headline.'
        Assert-TestSequenceEqual -Expected @($effective.Ids) -Actual @($mixedOutcome.EffectiveDeletable.Ids) -Message 'The outcome set equals the set of its findings.'
        $bare = [pscustomobject]@{ State = 'Findings'; Findings = $protectedFindings }
        Assert-TestSequenceEqual -Expected @($effective.Ids) -Actual @((Get-W360OutcomeEffectiveDeletable -Outcome $bare).Ids) -Message 'An outcome without a set gets one worked out from its findings.'

        # The confirmation lists the items outside the set as kept with their reason, never as "not selected".
        $plan = Get-W360SelectionPlan -Findings $protectedFindings -SelectedIds @($planSibling.SelectionId)
        $confirm = Get-W360ConfirmText -Plan $plan -AllFindings $protectedFindings
        foreach ($part in @('多绘屏保安装文件夹（里面有要保留的东西）', '多绘屏保自带的卸载程序（要和它所在的文件夹一起删）')) {
            Assert-TestTrue ($confirm.Contains($part)) ("The confirmation misses '{0}':`r`n{1}" -f $part, $confirm)
        }
        Assert-TestFalse ($confirm.Contains('多绘屏保安装文件夹（你没选）')) 'An item that can never pass is not called "not selected".'
        Assert-TestEqual -Expected $confirm -Actual (Get-W360ConfirmText -Plan $plan -AllFindings $protectedFindings -Effective $effective) -Message 'A passed-in set gives the same confirmation.'
        $help = New-W360HelpSummary -Stage 'Scan' -Outcome $mixedOutcome -ErrorText '' -ReportPath $mixedPath
        Assert-TestTrue ($help.Contains('[不删除：里面有要保留的东西]')) 'The help summary says what the window says.'
        Assert-TestTrue ($help.Contains(('找到的 360 内容：共 {0} 项；可以删除 {1} 项；不删除 {2} 项' -f ($mixedOutcome.SelectableCount + $mixedOutcome.ReviewCount),
                    $mixedOutcome.SelectableCount, $mixedOutcome.ReviewCount))) ("The help count line counts with the set, like the window:`r`n" + $help)
    }

    Invoke-TestCase -Run $run -Name 'scan outcome: cancelled, failed, invalid, no matches and findings' -Test {
        $validPath = Join-Path $fixtureRoot 'scan-valid.json'
        Write-UiScanReport -Path $validPath -Findings @($planParent, $planReviewChild, $planBrowser)
        $cancelled = Get-W360ScanOutcome -ExitCode 0 -ReportPath $validPath -Cancelled -StdoutLines @() -StderrLines @()
        Assert-TestEqual -Expected 'Cancelled' -Actual $cancelled.State -Message 'Cancelled always wins.'
        Assert-TestEqual -Expected '检查已停止' -Actual $cancelled.Headline -Message 'Cancelled scan headline.'
        Assert-TestTrue ($cancelled.Detail.Contains('没有做完') -and $cancelled.Detail.Contains('结果不能用') -and $cancelled.Detail.Contains('没有删除任何东西')) 'Cancelled scan detail.'

        $failed = Get-W360ScanOutcome -ExitCode 1 -ReportPath $validPath -StdoutLines @('W360-PROGRESS|ScanStart|', 'Windows 360 Cleaner - Scan') `
            -StderrLines @('W360-PROGRESS|Error|boom', 'Get-Item : Access is denied.')
        Assert-TestEqual -Expected 'Failed' -Actual $failed.State -Message 'A non-zero exit code is a failure.'
        Assert-TestEqual -Expected '出了点问题' -Actual $failed.Headline -Message 'Failed scan headline.'
        Assert-TestTrue ($failed.Detail.Contains('错误代码 1') -and $failed.Detail.Contains('没有删除任何东西')) 'A failed scan must say nothing was deleted.'
        Assert-TestTrue ($failed.ErrorText.Contains('Access is denied.') -and -not $failed.ErrorText.Contains('W360-PROGRESS')) 'ErrorText must drop progress markers.'
        Assert-TestTrue ($failed.ErrorText.Contains('Windows 360 Cleaner - Scan')) 'A failure must include the stdout tail.'
        $missing = Get-W360ScanOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'missing-scan.json')
        Assert-TestEqual -Expected 'Failed' -Actual $missing.State -Message 'A missing report is a failure.'
        Assert-TestTrue ($missing.Detail.Contains('没有删除任何东西')) 'A scan without a result must say nothing was deleted.'

        $schemaPath = Join-Path $fixtureRoot 'scan-schema1.json'
        Write-UiScanReport -Path $schemaPath -Findings @($planParent) -SchemaVersion 1
        $schemaOutcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $schemaPath
        Assert-TestEqual -Expected 'InvalidReport' -Actual $schemaOutcome.State -Message 'SchemaVersion 1 is invalid.'
        Assert-TestTrue ($schemaOutcome.Detail.Contains('没有删除任何东西') -and -not $schemaOutcome.Detail.Contains('SchemaVersion')) 'The invalid-report page stays plain.'
        Assert-TestTrue ($schemaOutcome.ErrorText.Contains('SchemaVersion is not 2')) 'The technical reason moves to ErrorText.'
        $modePath = Join-Path $fixtureRoot 'scan-mode.json'
        Write-UiScanReport -Path $modePath -Findings @($planParent) -Mode 'Remove'
        Assert-TestEqual -Expected 'InvalidReport' -Actual (Get-W360ScanOutcome -ExitCode 0 -ReportPath $modePath).State -Message 'A Remove report is not a scan.'
        $contextPath = Join-Path $fixtureRoot 'scan-context.json'
        Write-UiScanReport -Path $contextPath -Findings @($planParent) -NoApprovalContext
        Assert-TestEqual -Expected 'InvalidReport' -Actual (Get-W360ScanOutcome -ExitCode 0 -ReportPath $contextPath).State -Message 'A scan without ApprovalContext is invalid.'
        $brokenPath = Join-Path $fixtureRoot 'scan-broken.json'
        [IO.File]::WriteAllBytes($brokenPath, [byte[]]@(0x7B, 0xFF, 0xFE, 0x7D))
        Assert-TestEqual -Expected 'InvalidReport' -Actual (Get-W360ScanOutcome -ExitCode 0 -ReportPath $brokenPath).State -Message 'Invalid UTF-8 is an invalid report.'

        $incompletePath = Join-Path $fixtureRoot 'scan-incomplete.json'
        Write-UiScanReport -Path $incompletePath -Coverage ([pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'ScheduledTasks'; Target = ''; Detail = 'Access denied.' }) })
        $incomplete = Get-W360ScanOutcome -ExitCode 0 -ReportPath $incompletePath
        Assert-TestEqual -Expected 'NoMatchesIncomplete' -Actual $incomplete.State -Message 'Zero findings with incomplete coverage.'
        Assert-TestEqual -Expected '没有找到 360 的内容，但有些地方没检查完' -Actual $incomplete.Headline -Message 'NoMatchesIncomplete headline.'
        Assert-TestEqual -Expected '定时自动运行的任务' -Actual @($incomplete.CoverageIssues)[0].AreaText -Message 'Coverage issue area text.'
        Assert-TestEqual -Expected '定时自动运行的任务没检查完' -Actual @($incomplete.CoverageIssues)[0].Text -Message 'Coverage issue text.'
        $oldPath = Join-Path $fixtureRoot 'scan-old.json'
        Write-UiScanReport -Path $oldPath -NoCoverage
        $old = Get-W360ScanOutcome -ExitCode 0 -ReportPath $oldPath
        Assert-TestEqual -Expected 'NoMatches' -Actual $old.State -Message 'Coverage not recorded is treated as NoMatches.'
        Assert-TestEqual -Expected '没有找到 360 的内容' -Actual $old.Headline -Message 'NoMatches headline.'
        Assert-TestTrue ($old.Detail.Contains('本工具认识的')) 'NoMatches detail must say it is limited to what the tool knows.'

        $found = Get-W360ScanOutcome -ExitCode 0 -ReportPath $validPath
        Assert-TestEqual -Expected 'Findings' -Actual $found.State -Message 'Findings state.'
        Assert-TestEqual -Expected (Get-W360FileSha256 -Path $validPath) -Actual $found.ReportHash -Message 'ReportHash must be the file SHA-256.'
        # The Duohui folder holds a kept item, so it can never be deleted in this result: only the browser counts.
        Assert-TestEqual -Expected 1 -Actual $found.DeletableGroupCount -Message 'Only the browser has items that can be deleted.'
        Assert-TestEqual -Expected '找到 1 个可以删除的 360 软件' -Actual $found.Headline -Message 'Findings headline counts products with effectively deletable items.'
        Assert-TestEqual -Expected 1 -Actual $found.SelectableCount -Message 'The folder with a kept item inside is not counted as deletable.'
        Assert-TestTrue ($found.Detail.Contains('本工具不会去删')) 'Findings detail must say the tool does not delete unticked items.'
        Assert-TestEqual -Expected 3 -Actual @($found.Findings).Count -Message 'Findings must be returned.'

        $incompleteFindingsPath = Join-Path $fixtureRoot 'scan-findings-incomplete.json'
        Write-UiScanReport -Path $incompleteFindingsPath -Findings @($planParent, $planReviewChild, $planBrowser) `
            -Coverage ([pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'Services'; Target = ''; Detail = 'x' }) })
        $incompleteFindings = Get-W360ScanOutcome -ExitCode 0 -ReportPath $incompleteFindingsPath
        Assert-TestEqual -Expected 'Findings' -Actual $incompleteFindings.State -Message 'Incomplete coverage keeps the Findings state.'
        Assert-TestEqual -Expected $false -Actual $incompleteFindings.CoverageComplete -Message 'The banner flag stays available.'
        Assert-TestEqual -Expected $found.Detail -Actual $incompleteFindings.Detail -Message 'The incomplete note moved to the banner, not the detail.'

        $keepOnlyPath = Join-Path $fixtureRoot 'scan-keep-only.json'
        Write-UiScanReport -Path $keepOnlyPath -Findings @($planReviewChild, (New-UiFinding -Kind 'Driver' -Name '360Box64.sys' -Target 'C:\Windows\System32\drivers\360Box64.sys' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'Drivers'))
        $keepOnly = Get-W360ScanOutcome -ExitCode 0 -ReportPath $keepOnlyPath
        Assert-TestEqual -Expected 'Findings' -Actual $keepOnly.State -Message 'Keep-only findings keep the Findings state.'
        Assert-TestEqual -Expected 0 -Actual $keepOnly.DeletableGroupCount -Message 'No product has deletable items.'
        Assert-TestEqual -Expected '找到了一些 360 相关的内容，但都不删除' -Actual $keepOnly.Headline -Message 'Keep-only headline does not count items that the list groups into products.'
        Assert-TestTrue ($keepOnly.Detail.Contains('原因写在每一行后面')) 'Keep-only detail.'
    }

    $approvedHash = 'A7' * 32

    Invoke-TestCase -Run $run -Name 'remove outcome: completed, restart needed and partial' -Test {
        $completedPath = Join-Path $fixtureRoot 'remove-completed.json'
        Write-UiRemoveReport -Path $completedPath -ApprovedReportHash $approvedHash -Actions @(
            (New-UiAction 'DeletePath' 'C:\Users\Fixture\AppData\Local\dhpingbao' 'Success' 'Permanently removed; not sent to Recycle Bin.'))
        $completed = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $completedPath -ExpectedApprovedReportHash $approvedHash.ToLowerInvariant() -Events @()
        $verifyTaskButton = Get-W360Text -Key 'Ui.Button.VerifyTask'
        Assert-TestEqual -Expected 'Completed' -Actual $completed.State -Message 'A clean removal is Completed.'
        Assert-TestEqual -Expected '删除完成' -Actual $completed.Headline -Message 'Completed headline.'
        Assert-TestEqual -Expected '你选的 2 项都删掉了。你没选的，本工具没有动。' -Actual $completed.Detail -Message 'Completed detail uses the selected count.'
        Assert-TestEqual -Expected $false -Actual ([bool]$completed.VendorUninstallerRan) -Message 'No uninstaller ran.'
        Assert-TestEqual -Expected 0 -Actual @($completed.Problems).Count -Message 'A clean removal has no problems.'
        Assert-TestEqual -Expected 1 -Actual @($completed.NextSteps).Count -Message 'The result page shows exactly one next step.'
        Assert-TestTrue (@($completed.NextSteps)[0].Contains('“' + $verifyTaskButton + '”') -and @($completed.NextSteps)[0].Contains('不会自动重启')) `
            'Completed next step must recommend a manual restart and name the exact check button.'
        Assert-TestTrue (@($completed.NextSteps)[0].StartsWith('可以关闭')) 'Completed next step must not read as if the cleanup still needs a restart to finish.'
        Assert-TestEqual -Expected '' -Actual $completed.CountsText -Message 'Counts are hidden when the immediate check numbers were not recorded.'
        Assert-TestEqual -Expected ([long]2) -Actual $completed.Stats.RegistryItemsRemoved -Message 'Registry items combine keys and values.'
        Assert-TestTrue ($completed.Stats.LogicalSizeNote.Contains('不等于磁盘实际增加的可用空间')) 'Logical size note.'
        $exitCodeCompleted = Get-W360RemoveOutcome -ExitCode 2 -ReportPath $completedPath -ExpectedApprovedReportHash $approvedHash
        Assert-TestEqual -Expected 'Partial' -Actual $exitCodeCompleted.State -Message 'A non-zero exit code can never be Completed.'
        Assert-TestTrue ($exitCodeCompleted.Detail.Contains('错误代码 2')) 'The exit-code detail must mention the code.'

        $countsPath = Join-Path $fixtureRoot 'remove-counts.json'
        Write-UiRemoveReport -Path $countsPath -ApprovedReportHash $approvedHash `
            -Summary (New-UiSummary -Overrides @{ ImmediateSelectedConfirmedAbsent = 2; ImmediateSelectedStillPresent = 0; ImmediateSelectedUnknown = 0 })
        Assert-TestEqual -Expected '删掉 2 项 · 没删掉 0 项 · 不确定 0 项' -Actual (Get-W360RemoveOutcome -ExitCode 0 -ReportPath $countsPath -ExpectedApprovedReportHash $approvedHash).CountsText `
            -Message 'CountsText uses the immediate check numbers.'
        # The counts line only backs a finished result: an exit-code failure with the same numbers shows none.
        $countsByExitCode = Get-W360RemoveOutcome -ExitCode 2 -ReportPath $countsPath -ExpectedApprovedReportHash $approvedHash
        Assert-TestEqual -Expected 'Partial' -Actual $countsByExitCode.State -Message 'A non-zero exit code with a clean summary is Partial.'
        Assert-TestEqual -Expected '' -Actual $countsByExitCode.CountsText -Message 'No counts under a Partial result that comes only from the exit code.'
        $countsUnknownPath = Join-Path $fixtureRoot 'remove-counts-unknown.json'
        Write-UiRemoveReport -Path $countsUnknownPath -ApprovedReportHash $approvedHash `
            -Summary (New-UiSummary -Overrides @{ ImmediateSelectedConfirmedAbsent = 1; ImmediateSelectedStillPresent = 0; ImmediateSelectedUnknown = 1; ImmediateRemainingSelected = 1 })
        $countsUnknown = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $countsUnknownPath -ExpectedApprovedReportHash $approvedHash
        Assert-TestEqual -Expected 'Unknown' -Actual $countsUnknown.State -Message 'An unreadable selected item is Unknown.'
        Assert-TestEqual -Expected '' -Actual $countsUnknown.CountsText -Message 'No counts under a result that is not certain.'

        $servicePath = Join-Path $fixtureRoot 'remove-service.json'
        Write-UiRemoveReport -Path $servicePath -ApprovedReportHash $approvedHash `
            -Summary (New-UiSummary -Overrides @{ ServicesPendingRemoval = 1; PendingActions = 1 }) -Actions @(
            (New-UiAction 'DeleteService' 'ZhuDongFangYu' 'PendingRemoval' 'Windows accepted the delete request, but the service still exists and may require a restart.'))
        $serviceFinding = New-UiFinding -Kind 'Service' -Name 'ZhuDongFangYu' -Target 'ZhuDongFangYu' -RemovalType 'Service' -ProductKey '360Security'
        $service = Get-W360RemoveOutcome -ExitCode 2 -ReportPath $servicePath -ExpectedApprovedReportHash $approvedHash -SelectedFindings @($serviceFinding)
        Assert-TestEqual -Expected 'NeedsRestart' -Actual $service.State -Message 'A pending service removal needs a restart.'
        Assert-TestEqual -Expected '还差一步：请重启电脑' -Actual $service.Headline -Message 'NeedsRestart headline.'
        Assert-TestTrue @($service.Problems)[0].RestartMayHelp 'A pending service is restart-may-help.'
        Assert-TestEqual -Expected '要重启电脑后才能删完' -Actual @($service.Problems)[0].ReasonText -Message 'Pending service reason.'
        Assert-TestEqual -Expected '后台服务：ZhuDongFangYu' -Actual @($service.Problems)[0].DisplayName -Message 'A problem is named after the selected finding with the same target.'
        Assert-TestEqual -Expected '' -Actual $service.CountsText -Message 'A restart-needed page shows no "0 not deleted" counts next to a service that waits for the restart.'
        Assert-TestEqual -Expected 1 -Actual @($service.NextSteps).Count -Message 'NeedsRestart has one next step.'
        Assert-TestTrue (@($service.NextSteps)[0].Contains('重启电脑') -and @($service.NextSteps)[0].Contains('“' + $verifyTaskButton + '”') -and
            @($service.NextSteps)[0].Contains('不会自动重启')) 'NeedsRestart next step must ask for a manual restart and name the check button.'

        $lockPath = Join-Path $fixtureRoot 'remove-lock.json'
        $lockTarget = 'C:\Users\Fixture\AppData\Local\dhpingbao'
        Write-UiRemoveReport -Path $lockPath -ApprovedReportHash $approvedHash `
            -Summary (New-UiSummary -Overrides @{ SkippedActions = 2; RetryAttempts = 1; UnresolvedPathTargets = 1; ImmediateRemainingSelected = 1; NoImmediateSelectedFindings = $false }) -Actions @(
            (New-UiAction 'DeletePath' $lockTarget 'RetryRequired' 'ReasonCode=DeleteFailed; The process cannot access the file.'),
            (New-UiAction 'StopModuleHolder' 'explorer (4242)' 'Skipped' 'A normal or system process loaded a target DLL. It was not force-stopped; close the app or reboot, then verify.'),
            (New-UiAction 'DeletePathRetry' $lockTarget 'Skipped' 'Target is held by a normal or system process that the cleaner will not force-stop.'))
        $lockFinding = New-UiFinding -Target $lockTarget
        $lock = Get-W360RemoveOutcome -ExitCode 2 -ReportPath $lockPath -ExpectedApprovedReportHash $approvedHash -SelectedFindings @($lockFinding)
        Assert-TestEqual -Expected 'NeedsRestart' -Actual $lock.State -Message 'A lock skip needs a restart.'
        Assert-TestEqual -Expected 2 -Actual @($lock.Problems).Count -Message 'Each target is judged by its last action only.'
        Assert-TestTrue (@($lock.Problems | Where-Object { -not $_.RestartMayHelp }).Count -eq 0) 'Lock skips are restart-may-help.'
        Assert-TestEqual -Expected '文件正在被别的程序使用，重启电脑后再检查一次' -Actual @($lock.Problems)[1].ReasonText -Message 'Lock skip reason.'
        Assert-TestEqual -Expected '重试删除' -Actual @($lock.Problems)[1].ActionText -Message 'Localised action name.'
        Assert-TestEqual -Expected '一个正在运行的程序' -Actual @($lock.Problems)[0].DisplayName -Message 'A target without a matching selected finding is named by what the action handled, never by its raw name.'
        Assert-TestEqual -Expected '多绘屏保安装文件夹' -Actual @($lock.Problems)[1].DisplayName -Message 'A folder problem is named after the selected folder.'
        Assert-TestEqual -Expected '多绘屏保安装文件夹' -Actual (Get-W360RemoveProblemDisplayName -Target ($lockTarget + '\bin\x.dll') -SelectedFindings @($lockFinding)) `
            -Message 'A target inside a selected folder is named after that folder.'
        Assert-TestEqual -Expected '一些文件' -Actual (Get-W360RemoveProblemDisplayName -Target 'C:\Elsewhere\x.dll' -SelectedFindings @($lockFinding) -Action 'DeletePath') -Message 'Unrelated file targets are some files.'
        Assert-TestEqual -Expected '一个后台服务' -Actual (Get-W360RemoveProblemDisplayName -Target '360rp' -SelectedFindings @($lockFinding) -Action 'DeleteService') -Message 'Unrelated services are a background service.'
        Assert-TestEqual -Expected '其他一项' -Actual (Get-W360RemoveProblemDisplayName -Target 'C:\Elsewhere\x.dll' -SelectedFindings @($lockFinding)) -Message 'Without an action the plain fallback is used.'
        $valueFinding = New-UiFinding -Kind 'Startup' -Name 'huabao' -Target 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -RemovalType 'RegistryValue' -ValueName 'huabao'
        Assert-TestEqual -Expected '开机自动运行：huabao' -Actual (Get-W360RemoveProblemDisplayName -Target 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run :: huabao' -SelectedFindings @($lockFinding, $valueFinding)) `
            -Message 'A registry value problem is matched by key and value name.'
        $taskFinding = New-UiFinding -Kind 'ScheduledTask' -Name '360 Update' -Target '360 Update' -RemovalType 'Task' -ValueName '\'
        Assert-TestEqual -Expected '定时自动运行的任务：360 Update' -Actual (Get-W360RemoveProblemDisplayName -Target '\360 Update' -SelectedFindings @($taskFinding)) `
            -Message 'A task problem is matched by task path and name.'
        $problemLines = @(Get-W360RemoveProblemLines -Outcome $lock -Limit 1)
        Assert-TestSequenceEqual -Expected @('“一个正在运行的程序”：文件正在被别的程序使用，重启电脑后再检查一次', '还有 1 项，点“详细信息”查看。') -Actual $problemLines `
            -Message 'The short problem list names each problem and points to Details for the rest.'
        # Problems with the same plain name and reason are one line with a count, and "more" counts lines, not raw problems.
        $repeated = [pscustomobject]@{ Problems = @(
                1..9 | ForEach-Object { [pscustomobject]@{ DisplayName = '360 程序文件夹（32 位）'; ReasonText = 'Windows 不让删除' } }
                1..6 | ForEach-Object { [pscustomobject]@{ DisplayName = ('名字' + $_); ReasonText = '没删掉' } }) }
        $repeatedLines = @(Get-W360RemoveProblemLines -Outcome $repeated -Limit 5)
        Assert-TestEqual -Expected '“360 程序文件夹（32 位）”：Windows 不让删除（9 处）' -Actual $repeatedLines[0] -Message 'Repeated problems are one line with a count.'
        Assert-TestEqual -Expected 6 -Actual $repeatedLines.Count -Message 'Five lines plus the more line.'
        Assert-TestEqual -Expected '还有 2 项，点“详细信息”查看。' -Actual $repeatedLines[5] -Message 'The more line counts the remaining lines.'

        $partialPath = Join-Path $fixtureRoot 'remove-partial.json'
        Write-UiRemoveReport -Path $partialPath -ApprovedReportHash $approvedHash `
            -Summary (New-UiSummary -Overrides @{ FailedActions = 1; SkippedActions = 1; UnresolvedPathTargets = 1; AccessDeniedPathTargets = 1; ImmediateRemainingSelected = 2 }) -Actions @(
            (New-UiAction 'DeletePath' 'C:\Program Files (x86)\360' 'Skipped' 'ReasonCode=AccessDenied; The tree could not be fully inspected. Ownership and ACLs were not changed.'),
            (New-UiAction 'DeleteRegistryKey' 'HKCU:\Software\duohuipingbao' 'Failed' 'Access to the registry key is denied.'))
        $partial = Get-W360RemoveOutcome -ExitCode 2 -ReportPath $partialPath -ExpectedApprovedReportHash $approvedHash
        Assert-TestEqual -Expected 'Partial' -Actual $partial.State -Message 'Access denied plus a failure is Partial.'
        Assert-TestEqual -Expected '有些没删掉' -Actual $partial.Headline -Message 'Partial headline.'
        Assert-TestEqual -Expected 'Windows 不让删除（可能被 360 的自我保护挡住了）' -Actual @($partial.Problems)[0].ReasonText -Message 'AccessDenied reason text.'
        Assert-TestEqual -Expected 'AccessDenied' -Actual @($partial.Problems)[0].ReasonCode -Message 'The raw reason code must be kept.'
        Assert-TestEqual -Expected 1 -Actual @($partial.NextSteps).Count -Message 'Partial has one next step.'
        Assert-TestTrue (@($partial.NextSteps)[0].Contains('先重启电脑') -and @($partial.NextSteps)[0].Contains('“' + $verifyTaskButton + '”') -and
            @($partial.NextSteps)[0].Contains('“获取帮助”')) 'Partial next steps point to a restart, the last-deletion check and help.'
        Assert-TestFalse (@($partial.NextSteps)[0].Contains('强行')) 'Partial next steps do not hint at a forced deletion the tool does not have.'
    }

    Invoke-TestCase -Run $run -Name 'remove outcome: kept items that may have changed and a vendor uninstaller never look like a clean success' -Test {
        $plainPath = Join-Path $fixtureRoot 'remove-kept-plain.json'
        Write-UiRemoveReport -Path $plainPath -ApprovedReportHash $approvedHash -Summary (New-UiSummary -Overrides @{
                ImmediateSelectedConfirmedAbsent = 2; ImmediateSelectedStillPresent = 0; ImmediateSelectedUnknown = 0; ImmediatePreservedStillPresent = 1; ImmediatePreservedNotConfirmedPresent = 0 })
        $plain = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $plainPath -ExpectedApprovedReportHash $approvedHash
        Assert-TestEqual -Expected 'Success' -Actual (Get-W360OutcomeTone -Outcome $plain) -Message 'A clean removal is green.'

        $unconfirmedPath = Join-Path $fixtureRoot 'remove-kept-unconfirmed.json'
        Write-UiRemoveReport -Path $unconfirmedPath -ApprovedReportHash $approvedHash -Summary (New-UiSummary -Overrides @{
                ImmediateSelectedConfirmedAbsent = 2; ImmediateSelectedStillPresent = 0; ImmediateSelectedUnknown = 0; ImmediatePreservedNotConfirmedPresent = 1 })
        $unconfirmed = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $unconfirmedPath -ExpectedApprovedReportHash $approvedHash
        Assert-TestEqual -Expected 'Completed' -Actual $unconfirmed.State -Message 'Kept items are never a failure.'
        Assert-TestEqual -Expected 'Warning' -Actual (Get-W360OutcomeTone -Outcome $unconfirmed) -Message 'A kept item that may be gone is never green.'
        Assert-TestEqual -Expected (Get-W360Text -Key 'Remove.Completed.PreservedUnconfirmed' -Arguments @(1)) -Actual $unconfirmed.Detail `
            -Message 'Without an uninstaller that ran, the detail does not blame one.'
        Assert-TestFalse ($unconfirmed.Detail.Contains('卸载程序')) 'No uninstaller is blamed when none ran.'

        $affectedPath = Join-Path $fixtureRoot 'remove-kept-vendor.json'
        Write-UiRemoveReport -Path $affectedPath -ApprovedReportHash $approvedHash -Summary (New-UiSummary -Overrides @{
                ImmediateSelectedConfirmedAbsent = 2; ImmediateSelectedStillPresent = 0; ImmediateSelectedUnknown = 0; ImmediatePreservedNotConfirmedPresent = 1; VendorUninstallersSucceeded = 1 }) `
            -Actions @((New-UiAction 'RunVendorUninstaller' 'C:\Users\Fixture\AppData\Local\dhpingbao\huabaosetup.exe' 'Success' 'Exit code 0.'))
        $affected = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $affectedPath -ExpectedApprovedReportHash $approvedHash
        Assert-TestTrue ([bool]$affected.VendorUninstallerRan) 'The uninstaller run is recorded.'
        Assert-TestEqual -Expected (Get-W360Text -Key 'Remove.Completed.PreservedAffected' -Arguments @(1)) -Actual $affected.Detail -Message 'An uninstaller that ran is named as a possible cause.'
        Assert-TestEqual -Expected 'Warning' -Actual (Get-W360OutcomeTone -Outcome $affected) -Message 'Kept items that may be gone after an uninstaller are never green.'

        $vendorPath = Join-Path $fixtureRoot 'remove-vendor-ran.json'
        Write-UiRemoveReport -Path $vendorPath -ApprovedReportHash $approvedHash -Summary (New-UiSummary -Overrides @{
                ImmediateSelectedConfirmedAbsent = 2; ImmediateSelectedStillPresent = 0; ImmediateSelectedUnknown = 0; ImmediatePreservedNotConfirmedPresent = 0 }) `
            -Actions @((New-UiAction 'RunVendorUninstaller' 'C:\Users\Fixture\AppData\Local\dhpingbao\huabaosetup.exe' 'Success' 'Exit code 0.'))
        $vendor = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $vendorPath -ExpectedApprovedReportHash $approvedHash
        Assert-TestEqual -Expected (Get-W360Text -Key 'Remove.Completed.VendorRan') -Actual $vendor.Detail -Message 'After an uninstaller nothing unticked is promised.'
        Assert-TestEqual -Expected 'Warning' -Actual (Get-W360OutcomeTone -Outcome $vendor) -Message 'A removal that ran an uninstaller is never green.'
        Assert-TestEqual -Expected '删掉 2 项 · 没删掉 0 项 · 不确定 0 项' -Actual $vendor.CountsText -Message 'A finished result keeps its counts.'
    }

    Invoke-TestCase -Run $run -Name 'remove outcome: unknown, not started and hash mismatch never claim success' -Test {
        $blockedPath = Join-Path $fixtureRoot 'remove-blocked.json'
        Write-UiRemoveReport -Path $blockedPath -ApprovedReportHash $approvedHash `
            -Summary (New-UiSummary -Overrides @{ PostVendorMutationBlocked = $true; ImmediateRescanComplete = $false; ImmediateRemainingSelected = $null; ImmediateRemainingConfirmed = $null }) -Actions @(
            (New-UiAction 'PostVendorPathPreflight' 'C:\Users\Fixture\AppData\Local\dhpingbao' 'Failed' 'ReasonCode=ReparsePoint; All subsequent mutations were blocked.'))
        $blocked = Get-W360RemoveOutcome -ExitCode 2 -ReportPath $blockedPath -ExpectedApprovedReportHash $approvedHash
        Assert-TestEqual -Expected 'Unknown' -Actual $blocked.State -Message 'A blocked rescan is Unknown.'
        Assert-TestEqual -Expected '不确定有没有删干净' -Actual $blocked.Headline -Message 'Unknown headline.'
        Assert-TestTrue ($blocked.Detail.Contains('不能当作已经删干净')) 'Unknown detail must warn.'
        Assert-TestEqual -Expected 1 -Actual @($blocked.NextSteps).Count -Message 'Unknown has one next step.'
        Assert-TestTrue (@($blocked.NextSteps)[0].Contains('重启电脑') -and @($blocked.NextSteps)[0].Contains('“' + (Get-W360Text -Key 'Ui.Button.VerifyTask') + '”')) `
            'An Unknown run with a valid report points to checking the last deletion after a restart.'

        $events = @(
            [pscustomobject]@{ Phase = 'ValidatingApproval'; Detail = ''; Source = 'Stdout'; Time = [DateTime]::Now },
            [pscustomobject]@{ Phase = 'WaitingForElevation'; Detail = ''; Source = 'Stdout'; Time = [DateTime]::Now },
            [pscustomobject]@{ Phase = 'ElevationCancelled'; Detail = ''; Source = 'Stdout'; Time = [DateTime]::Now }
        )
        $missingPath = Join-Path $fixtureRoot 'remove-never-written.json'
        $cancelled = Get-W360RemoveOutcome -ExitCode 5 -ReportPath $missingPath -ExpectedApprovedReportHash $approvedHash -Events $events
        Assert-TestEqual -Expected 'NotStarted' -Actual $cancelled.State -Message 'ElevationCancelled is NotStarted.'
        Assert-TestEqual -Expected '没有删除任何东西' -Actual $cancelled.Headline -Message 'NotStarted headline.'
        Assert-TestEqual -Expected '你在 Windows 弹出的窗口里点了“否”。' -Actual $cancelled.Detail -Message 'Cancelled elevation detail (the headline already says nothing was deleted).'
        Assert-TestSequenceEqual -Expected @('可以重新检查电脑，或者直接关闭。') -Actual @($cancelled.NextSteps) -Message 'NotStarted next step.'
        Assert-TestEqual -Expected '' -Actual $cancelled.CountsText -Message 'A deletion that never started shows no counts.'

        $early = Get-W360RemoveOutcome -ExitCode 1 -ReportPath $missingPath -ExpectedApprovedReportHash $approvedHash `
            -Events @([pscustomobject]@{ Phase = 'ValidatingApproval'; Detail = ''; Source = 'Stdout'; Time = [DateTime]::Now }) `
            -StderrLines @('Approved cleanup report hash does not match the hash accepted before elevation.')
        Assert-TestEqual -Expected 'NotStarted' -Actual $early.State -Message 'A failure before elevation is NotStarted.'
        Assert-TestTrue ($early.Detail.Contains('原因：Approved cleanup report hash does not match') -and $early.Detail.Contains('没能开始')) 'NotStarted must show the reason.'
        Assert-TestEqual -Expected '没有删除任何东西' -Actual $early.Headline -Message 'The NotStarted headline says nothing was deleted.'
        $noReason = Get-W360RemoveOutcome -ExitCode 1 -ReportPath $missingPath -ExpectedApprovedReportHash $approvedHash -Events @()
        Assert-TestTrue ($noReason.Detail.Contains('错误代码 1')) 'A NotStarted run without a reason names the error code.'

        $startedEvents = @(
            [pscustomobject]@{ Phase = 'WaitingForElevation'; Detail = ''; Source = 'Stdout'; Time = [DateTime]::Now },
            [pscustomobject]@{ Phase = 'ElevatedStarted'; Detail = ''; Source = 'File'; Time = [DateTime]::UtcNow },
            [pscustomobject]@{ Phase = 'RemovingPaths'; Detail = ''; Source = 'File'; Time = [DateTime]::UtcNow }
        )
        $afterStart = Get-W360RemoveOutcome -ExitCode 1 -ReportPath $missingPath -ExpectedApprovedReportHash $approvedHash -Events $startedEvents
        Assert-TestEqual -Expected 'Unknown' -Actual $afterStart.State -Message 'A missing report after elevation started is Unknown.'
        Assert-TestEqual -Expected 1 -Actual @($afterStart.NextSteps).Count -Message 'The no-report page has one next step.'
        Assert-TestTrue (@($afterStart.NextSteps)[0].Contains('重新检查一遍电脑') -and
            -not @($afterStart.NextSteps)[0].Contains((Get-W360Text -Key 'Ui.Button.VerifyTask'))) `
            'Without a valid report the next step points to a new check, never to the last-deletion check that cannot appear.'
        Assert-TestEqual -Expected '' -Actual $afterStart.CountsText -Message 'An unknown result without a report shows no counts.'
        $zeroNoReport = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $missingPath -ExpectedApprovedReportHash $approvedHash -Events @()
        Assert-TestEqual -Expected 'Unknown' -Actual $zeroNoReport.State -Message 'Exit code 0 without a report is Unknown.'

        $completedPath = Join-Path $fixtureRoot 'remove-completed.json'
        $mismatch = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $completedPath -ExpectedApprovedReportHash ('B8' * 32) -Events $startedEvents
        Assert-TestEqual -Expected 'Unknown' -Actual $mismatch.State -Message 'A report bound to another scan is never trusted.'
        Assert-TestEqual -Expected 'HashMismatch' -Actual $mismatch.ReportIssue -Message 'The hash mismatch must be recorded.'
        $noExpected = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $completedPath -ExpectedApprovedReportHash '' -Events @()
        Assert-TestEqual -Expected 'Unknown' -Actual $noExpected.State -Message 'A missing expected hash fails closed.'
    }

    $duohuiSelected = @(
        (New-UiItemStatus -Category 'Selected' -State 'Absent'),
        (New-UiItemStatus -Category 'Selected' -State 'Absent' -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' -Target 'C:\Users\Fixture\AppData\Local\dhpingbao\huabaosetup.exe'),
        (New-UiItemStatus -Category 'Selected' -State 'Absent' -Kind 'RegistryResidue' -Name 'Duohui registry residue' -Target 'HKCU:\Software\duohuipingbao')
    )
    $browserPreserved = New-UiItemStatus -Category 'Preserved' -State 'Present' -Name '360se6 browser application' `
        -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser' -DetailCode 'DetectedSameIdentity' -CurrentConfidence 'Confirmed'
    $browserFinding = New-UiFinding -Name '360se6 browser application' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser'

    Invoke-TestCase -Run $run -Name 'verify outcome: changed or unreadable kept items require attention in both languages' -Test {
        try {
            foreach ($language in @('zh', 'en')) {
                Set-W360UiLanguage -Language $language
                foreach ($keptState in @('Changed', 'Unknown', 'UnexpectedState')) {
                    $path = Join-Path $fixtureRoot ('verify-kept-' + $language + '-' + $keptState + '.json')
                    $keptItem = New-UiItemStatus -Category 'Preserved' -State $keptState -ProductKey '360SafeBrowser' -DetailCode 'ProbeUnreadable'
                    Write-UiVerifyReport -Path $path -TaskVerification (New-UiTaskVerification -Status 'Completed' -Selected $duohuiSelected -Preserved @($keptItem))
                    $outcome = Get-W360VerifyOutcome -ExitCode 0 -ReportPath $path
                    Assert-TestEqual -Expected 'TaskCompleted' -Actual $outcome.State -Message 'Kept anomalies do not undo confirmed selected deletion.'
                    Assert-TestEqual -Expected 'Warning' -Actual (Get-W360OutcomeTone -Outcome $outcome) -Message "$language/$keptState must not be green."
                    Assert-TestFalse ($outcome.Headline -eq (Get-W360Text -Key 'Verify.TaskCompleted.Headline')) 'The headline must mention kept items needing attention.'
                    Assert-TestFalse (@($outcome.NextSteps) -contains (Get-W360Text -Key 'Verify.Next.Done')) 'An unresolved kept item must not end with close now.'
                    Assert-TestFalse ($outcome.Detail.Contains((Get-W360Text -Key 'Verify.TaskCompleted.PreservedKept'))) 'Unconfirmed kept items must not be called normal.'
                    Assert-TestEqual -Expected 1 -Actual ([int]$outcome.PreservedChangedCount + [int]$outcome.PreservedUnknownCount) -Message 'Count the anomaly from items, including an unexpected state.'
                    Assert-TestEqual -Expected 3 -Actual @($outcome.Cleared).Count -Message 'The deleted items remain confirmed.'
                }
            }
        }
        finally { Set-W360UiLanguage -Language zh }

        # Coexisting warnings must all survive, including when new findings or incomplete coverage lead the page.
        $kept = @('Absent', 'Changed', 'Unknown') | ForEach-Object { New-UiItemStatus -Category 'Preserved' -State $_ -Target ('C:\Fixture\' + $_) }
        foreach ($variant in @('Completed', 'Incomplete', 'New', 'Remaining', 'Unknown')) {
            $path = Join-Path $fixtureRoot ('verify-kept-mixed-' + $variant + '.json')
            $selected = $duohuiSelected
            $status = 'Completed'
            $newItems = @()
            $coverage = [pscustomobject]@{ Complete = $true; Issues = @() }
            $code = 0
            if ($variant -eq 'Incomplete') { $coverage.Complete = $false; $code = 3 }
            if ($variant -eq 'New') { $newItems = @((New-UiItemStatus -Category 'New' -State 'New')); $code = 4 }
            if ($variant -in @('Remaining', 'Unknown')) {
                $status = $variant
                $selected = @((New-UiItemStatus -Category 'Selected' -State $variant))
                $code = if ($variant -eq 'Remaining') { 2 } else { 3 }
            }
            Write-UiVerifyReport -Path $path -Coverage $coverage -TaskVerification (New-UiTaskVerification -Status $status -Selected $selected -Preserved @($kept) -New $newItems)
            $outcome = Get-W360VerifyOutcome -ExitCode $code -ReportPath $path
            Assert-TestTrue ($outcome.Detail.Contains('有 1 项不见了') -and $outcome.Detail.Contains('有 1 项发生了变化') -and $outcome.Detail.Contains('有 1 项暂时无法确认')) "$variant must explain every kept anomaly."
            Assert-TestFalse ((Get-W360OutcomeTone -Outcome $outcome) -eq 'Success') "$variant must not be green."
            Assert-TestFalse (($outcome.NextSteps -join ' ').Contains('可以关闭了')) "$variant must not suggest everything is done."
        }
    }

    Invoke-TestCase -Run $run -Name 'verify outcome acceptance: Duohui cleared and the kept browser is not a failure' -Test {
        $path = Join-Path $fixtureRoot 'verify-acceptance.json'
        Write-UiVerifyReport -Path $path -Findings @($browserFinding) -TaskVerification (New-UiTaskVerification -Status 'Completed' -Selected $duohuiSelected -Preserved @($browserPreserved))
        $outcome = Get-W360VerifyOutcome -ExitCode 0 -ReportPath $path
        Assert-TestEqual -Expected 'TaskCompleted' -Actual $outcome.State -Message 'Preserved items must not fail the task.'
        Assert-TestEqual -Expected '上次选的都删干净了' -Actual $outcome.Headline -Message 'TaskCompleted headline.'
        Assert-TestEqual -Expected '上次选的 3 项都确认删掉了。你保留的内容还在，这是正常的。' -Actual $outcome.Detail `
            -Message 'Kept items that are all present are called normal.'
        Assert-TestEqual -Expected 'Success' -Actual (Get-W360OutcomeTone -Outcome $outcome) -Message 'A clean result with every kept item present is green.'
        Assert-TestEqual -Expected 3 -Actual @($outcome.Cleared).Count -Message 'All Duohui items must be listed as cleared.'
        Assert-TestTrue (@($outcome.Cleared | Where-Object { $_.StateText -ne '已删掉' }).Count -eq 0) 'Cleared items are shown as deleted.'
        Assert-TestEqual -Expected 1 -Actual @($outcome.Sections.Preserved).Count -Message 'The browser must be in the Preserved section.'
        $kept = @($outcome.Sections.Preserved)[0]
        Assert-TestEqual -Expected '还在' -Actual $kept.StateText -Message 'Preserved state text.'
        Assert-TestEqual -Expected '360 安全浏览器程序文件' -Actual $kept.DisplayName -Message 'Preserved display name.'
        Assert-TestEqual -Expected '360 安全浏览器' -Actual $kept.ProductName -Message 'Preserved product name.'
        Assert-TestEqual -Expected 0 -Actual @($outcome.Sections.SelectedRemaining).Count -Message 'Nothing remains.'
        Assert-TestEqual -Expected 0 -Actual @($outcome.Sections.NewOrChanged).Count -Message 'Nothing is new.'
        Assert-TestEqual -Expected 0 -Actual @($outcome.Sections.Unknown).Count -Message 'Nothing is unknown.'
        Assert-TestEqual -Expected 0 -Actual @($outcome.Sections.PreservedGone).Count -Message 'Nothing kept is gone.'
        Assert-TestSequenceEqual -Expected @('SelectedRemaining', 'Preserved', 'NewOrChanged', 'Unknown') -Actual @($outcome.SectionInfo | ForEach-Object { $_.Key }) -Message 'Section order.'
        Assert-TestEqual -Expected '你保留的' -Actual @($outcome.SectionInfo)[1].Title -Message 'Section title.'
        Assert-TestSequenceEqual -Expected @('Preserved', 'Cleared') -Actual @($outcome.GridSections | ForEach-Object { $_.Key }) -Message 'The grid shows only non-empty sections, kept before deleted.'
        Assert-TestSequenceEqual -Expected @('你保留的', '已删掉') -Actual @($outcome.GridSections | ForEach-Object { $_.Title }) -Message 'Grid section titles.'
        Assert-TestEqual -Expected 3 -Actual @($outcome.GridSections)[1].Count -Message 'Grid section count.'
        Assert-TestEqual -Expected 3 -Actual @(@($outcome.GridSections)[1].Items).Count -Message 'Grid section items.'
        Assert-TestSequenceEqual -Expected @('可以关闭了。') -Actual @($outcome.NextSteps) -Message 'TaskCompleted next step.'

        # A kept item that is gone is named in its own section, never listed as kept and never green.
        $gonePath = Join-Path $fixtureRoot 'verify-preserved-gone.json'
        $goneKept = New-UiItemStatus -Category 'Preserved' -State 'Absent' -Name '360se6 browser application' `
            -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser'
        Write-UiVerifyReport -Path $gonePath -TaskVerification (New-UiTaskVerification -Status 'Completed' -Selected $duohuiSelected -Preserved @($browserPreserved, $goneKept))
        $gone = Get-W360VerifyOutcome -ExitCode 0 -ReportPath $gonePath
        Assert-TestEqual -Expected 'TaskCompleted' -Actual $gone.State -Message 'A gone kept item does not change the task state.'
        Assert-TestEqual -Expected 'Warning' -Actual (Get-W360OutcomeTone -Outcome $gone) -Message 'A kept item that is gone is never green.'
        Assert-TestEqual -Expected 1 -Actual ([int]$gone.PreservedGoneCount) -Message 'The gone kept item is counted.'
        Assert-TestFalse ($gone.Detail.Contains('还在，这是正常的')) 'A gone kept item must not be described as still there.'
        Assert-TestTrue ($gone.Detail.Contains('你保留的内容里有 1 项不见了') -and $gone.Detail.Contains('请重新安装')) 'A gone kept item must be named.'
        Assert-TestFalse ($gone.Detail.Contains('卸载程序')) 'The uninstaller of another product is not blamed.'
        Assert-TestEqual -Expected 1 -Actual @($gone.Sections.Preserved).Count -Message 'Only the kept item that is still there is under kept.'
        Assert-TestEqual -Expected '不见了' -Actual @($gone.Sections.PreservedGone)[0].StateText -Message 'Gone kept state text without an uninstaller of the same product.'
        Assert-TestSequenceEqual -Expected @('PreservedGone', 'Preserved', 'Cleared') -Actual @($gone.GridSections | ForEach-Object { $_.Key }) -Message 'Gone kept items come before kept ones.'
        Assert-TestEqual -Expected '你保留的，但不见了' -Actual @($gone.GridSections)[0].Title -Message 'Gone kept section title.'
        $sameProductGone = New-UiItemStatus -Category 'Preserved' -State 'Absent' -Name 'Duohui temporary package' -Target 'C:\Users\Fixture\AppData\Local\Temp\duohuipingbao'
        $sameProductPath = Join-Path $fixtureRoot 'verify-preserved-gone-vendor.json'
        Write-UiVerifyReport -Path $sameProductPath -TaskVerification (New-UiTaskVerification -Status 'Completed' -Selected $duohuiSelected -Preserved @($sameProductGone))
        $sameProduct = Get-W360VerifyOutcome -ExitCode 0 -ReportPath $sameProductPath
        Assert-TestEqual -Expected '不见了（可能被 360 自带的卸载程序一起删了）' -Actual @($sameProduct.Sections.PreservedGone)[0].StateText -Message 'The uninstaller of the same product is named.'
        Assert-TestTrue ($sameProduct.Detail.Contains('360 自带的卸载程序')) 'The detail names the uninstaller of the same product.'

        $unknownKeptPath = Join-Path $fixtureRoot 'verify-preserved-unknown.json'
        $unknownKept = New-UiItemStatus -Category 'Preserved' -State 'Unknown' -Name '360se6 browser application' `
            -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser' -DetailCode 'ProbeUnreadable'
        Write-UiVerifyReport -Path $unknownKeptPath -TaskVerification (New-UiTaskVerification -Status 'Completed' -Selected $duohuiSelected -Preserved @($unknownKept))
        $unknownKeptOutcome = Get-W360VerifyOutcome -ExitCode 0 -ReportPath $unknownKeptPath
        Assert-TestTrue ($unknownKeptOutcome.Detail.Contains('你保留的内容里有 1 项暂时无法确认是否还在。')) 'An unconfirmed kept item is explained without promising it is present or gone.'
        Assert-TestSequenceEqual -Expected @('Unknown', 'Cleared') -Actual @($unknownKeptOutcome.GridSections | ForEach-Object { $_.Key }) -Message 'An unconfirmed kept item is listed once, as unconfirmed.'

        # Every result page names kept items that are gone, not only the completed one.
        $remainingGonePath = Join-Path $fixtureRoot 'verify-remaining-kept-gone.json'
        $stillThere = New-UiItemStatus -Category 'Selected' -State 'Remaining' -Kind 'RegistryResidue' -Name 'Duohui registry residue' -Target 'HKCU:\Software\duohuipingbao' -DetailCode 'DetectedSameIdentity'
        Write-UiVerifyReport -Path $remainingGonePath -TaskVerification (New-UiTaskVerification -Status 'Remaining' -Selected @($stillThere) -Preserved @($goneKept))
        $remainingGone = Get-W360VerifyOutcome -ExitCode 2 -ReportPath $remainingGonePath
        Assert-TestEqual -Expected 'TaskRemaining' -Actual $remainingGone.State -Message 'Remaining state.'
        Assert-TestTrue ($remainingGone.Detail.Contains('你保留的内容里有 1 项不见了')) ('A not-deleted result also names gone kept items: ' + $remainingGone.Detail)
        $unknownGonePath = Join-Path $fixtureRoot 'verify-unknown-kept-gone.json'
        Write-UiVerifyReport -Path $unknownGonePath -TaskVerification (New-UiTaskVerification -Status 'Unknown' -Selected @((New-UiItemStatus -Category 'Selected' -State 'Unknown' -DetailCode 'ProbeUnreadable')) -Preserved @($goneKept))
        $unknownGone = Get-W360VerifyOutcome -ExitCode 3 -ReportPath $unknownGonePath
        Assert-TestTrue ($unknownGone.Detail.Contains('你保留的内容里有 1 项不见了')) ('An unknown result also names gone kept items: ' + $unknownGone.Detail)
        Assert-TestFalse ($remainingGone.Detail.Contains('这是正常的') -or $unknownGone.Detail.Contains('这是正常的')) 'Failure pages never call kept items normal.'
    }

    Invoke-TestCase -Run $run -Name 'verify grid sections keep their full order with every section present' -Test {
        $allPath = Join-Path $fixtureRoot 'verify-all-sections.json'
        $allTask = New-UiTaskVerification -Status 'Remaining' -Selected @(
            (New-UiItemStatus -Category 'Selected' -State 'Remaining' -Target 'C:\a' -DetailCode 'DetectedSameIdentity'),
            (New-UiItemStatus -Category 'Selected' -State 'Unknown' -Target 'C:\b' -DetailCode 'ProbeUnreadable'),
            (New-UiItemStatus -Category 'Selected' -State 'Absent' -Target 'C:\c')) -Preserved @(
            (New-UiItemStatus -Category 'Preserved' -State 'Present' -Target 'C:\d' -DetailCode 'DetectedSameIdentity'),
            (New-UiItemStatus -Category 'Preserved' -State 'Absent' -Target 'C:\f')) -New @(
            (New-UiItemStatus -Category 'New' -State 'New' -Target 'C:\e' -DetailCode 'NewFinding'))
        Write-UiVerifyReport -Path $allPath -TaskVerification $allTask
        $all = Get-W360VerifyOutcome -ExitCode 2 -ReportPath $allPath
        Assert-TestSequenceEqual -Expected @('SelectedRemaining', 'Unknown', 'NewOrChanged', 'PreservedGone', 'Preserved', 'Cleared') `
            -Actual @($all.GridSections | ForEach-Object { $_.Key }) -Message 'What went wrong first, then new, gone kept, kept and deleted.'

        $unavailablePath = Join-Path $fixtureRoot 'verify-unavailable-all-sections.json'
        $keptDriver = New-UiFinding -Kind 'Driver' -Name '360Box64.sys' -Target 'C:\Windows\System32\drivers\360Box64.sys' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'Drivers'
        Write-UiVerifyReport -Path $unavailablePath -TaskVerification (New-UiTaskVerification -Status 'Unavailable' -UnavailableReason 'RemoveReportMissing') `
            -Findings @($browserFinding, $keptDriver) -Coverage ([pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'Services'; Target = ''; Detail = 'x' }) })
        $unavailable = Get-W360VerifyOutcome -ExitCode 2 -ReportPath $unavailablePath
        Assert-TestSequenceEqual -Expected @('CurrentIdentified', 'Unknown', 'CurrentKept') -Actual @($unavailable.GridSections | ForEach-Object { $_.Key }) `
            -Message 'Without a usable record: what is still here, what was not fully checked, then what is never deleted.'
        $globalPath = Join-Path $fixtureRoot 'verify-global-all-sections.json'
        Write-UiVerifyReport -Path $globalPath -OmitTaskVerification -Findings @($browserFinding, $keptDriver) `
            -Coverage ([pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'Services'; Target = ''; Detail = 'x' }) })
        Assert-TestSequenceEqual -Expected @('CurrentIdentified', 'Unknown', 'CurrentKept') -Actual @((Get-W360VerifyOutcome -ExitCode 2 -ReportPath $globalPath).GridSections | ForEach-Object { $_.Key }) `
            -Message 'Whole-PC check section order.'
    }

    Invoke-TestCase -Run $run -Name 'verify outcome: new, changed, unknown, inconsistent, unavailable and global states' -Test {
        $newPath = Join-Path $fixtureRoot 'verify-new.json'
        $newItem = New-UiItemStatus -Category 'New' -State 'New' -Name 'Roaming SoftMgr cache' -Target 'C:\Users\Fixture\AppData\Roaming\SoftMgr' -ProductKey '360SoftMgr' -DetailCode 'NewFinding' -CurrentConfidence 'Confirmed'
        Write-UiVerifyReport -Path $newPath -TaskVerification (New-UiTaskVerification -Status 'Completed' -Selected $duohuiSelected -New @($newItem))
        $new = Get-W360VerifyOutcome -ExitCode 4 -ReportPath $newPath
        Assert-TestEqual -Expected 'TaskCompletedWithNew' -Actual $new.State -Message 'New findings state.'
        Assert-TestEqual -Expected '上次选的都删干净了，但又找到 1 项新的 360 内容' -Actual $new.Headline -Message 'New findings headline.'
        Assert-TestEqual -Expected '新找到的' -Actual @($new.Sections.NewOrChanged)[0].StateText -Message 'New item state text.'
        Assert-TestSequenceEqual -Expected @('可以点“重新检查电脑”，再决定删不删。') -Actual @($new.NextSteps) -Message 'New findings next step.'
        Assert-TestSequenceEqual -Expected @('NewOrChanged', 'Cleared') -Actual @($new.GridSections | ForEach-Object { $_.Key }) -Message 'New findings grid sections.'
        Assert-TestEqual -Expected '新找到的或有变化的' -Actual @($new.GridSections)[0].Title -Message 'New-or-changed title.'

        $changedPath = Join-Path $fixtureRoot 'verify-changed.json'
        $changed = New-UiItemStatus -Category 'Selected' -State 'Changed' -DetailCode 'DetectedDifferentIdentity'
        $remaining = New-UiItemStatus -Category 'Selected' -State 'Remaining' -Kind 'RegistryResidue' -Name 'Duohui registry residue' -Target 'HKCU:\Software\duohuipingbao' -DetailCode 'DetectedSameIdentity'
        Write-UiVerifyReport -Path $changedPath -TaskVerification (New-UiTaskVerification -Status 'Remaining' -Selected @($changed, $remaining))
        $changedOutcome = Get-W360VerifyOutcome -ExitCode 2 -ReportPath $changedPath
        Assert-TestEqual -Expected 'TaskRemaining' -Actual $changedOutcome.State -Message 'Changed identity is Remaining.'
        Assert-TestEqual -Expected '还有 2 项没删掉' -Actual $changedOutcome.Headline -Message 'A changed selected item counts toward the not-deleted headline.'
        Assert-TestEqual -Expected '同一个位置还有东西，但和上次的不一样了。' -Actual @($changedOutcome.Sections.NewOrChanged)[0].Detail -Message 'Changed identity detail.'
        Assert-TestEqual -Expected '有变化，可能不是原来那个了' -Actual @($changedOutcome.Sections.NewOrChanged)[0].StateText -Message 'Changed state text.'
        Assert-TestEqual -Expected 1 -Actual @($changedOutcome.Sections.SelectedRemaining).Count -Message 'Remaining section.'
        Assert-TestSequenceEqual -Expected @('SelectedRemaining', 'NewOrChanged') -Actual @($changedOutcome.GridSections | ForEach-Object { $_.Key }) -Message 'Not-deleted items come first.'
        Assert-TestEqual -Expected '没删掉' -Actual @($changedOutcome.GridSections)[0].Title -Message 'Not-deleted title.'
        Assert-TestTrue (@($changedOutcome.NextSteps)[0].Contains('重启电脑后') -and @($changedOutcome.NextSteps)[0].Contains('“获取帮助”') -and
            @($changedOutcome.NextSteps)[0].Contains('“检查上次删除的结果”')) 'Remaining next step names the button that checks the last deletion after reopening the tool.'

        $unknownPath = Join-Path $fixtureRoot 'verify-unknown.json'
        Write-UiVerifyReport -Path $unknownPath -TaskVerification (New-UiTaskVerification -Status 'Unknown' -Selected @((New-UiItemStatus -Category 'Selected' -State 'Unknown' -DetailCode 'ProbeUnreadable')))
        $unknown = Get-W360VerifyOutcome -ExitCode 3 -ReportPath $unknownPath
        Assert-TestEqual -Expected 'TaskUnknown' -Actual $unknown.State -Message 'An unreadable probe is TaskUnknown.'
        Assert-TestEqual -Expected '有 1 项没法确认有没有删掉' -Actual $unknown.Headline -Message 'Unknown headline with a count.'
        Assert-TestEqual -Expected '没法确认' -Actual @($unknown.Sections.Unknown)[0].StateText -Message 'Unknown state text.'
        Assert-TestEqual -Expected '没法确认或没检查完' -Actual @($unknown.GridSections)[0].Title -Message 'Unknown section title.'
        $statusOnlyPath = Join-Path $fixtureRoot 'verify-unknown-status-only.json'
        Write-UiVerifyReport -Path $statusOnlyPath -TaskVerification (New-UiTaskVerification -Status 'Unknown' -Selected $duohuiSelected)
        $statusOnly = Get-W360VerifyOutcome -ExitCode 3 -ReportPath $statusOnlyPath
        Assert-TestEqual -Expected 'TaskUnknown' -Actual $statusOnly.State -Message 'An Unknown status alone is TaskUnknown.'
        Assert-TestEqual -Expected '上次选的看起来都删掉了，但这次检查没做完整' -Actual $statusOnly.Headline -Message 'Without unknown items the headline must not invent a count.'
        Assert-TestEqual -Expected (Get-W360Text -Key 'Verify.TaskUnknown.DetailNoCount') -Actual $statusOnly.Detail -Message 'Without unknown items the detail names the cause.'
        Assert-TestEqual -Expected 'Warning' -Actual (Get-W360OutcomeTone -Outcome $statusOnly) -Message 'An incomplete check is never green.'

        $inconsistentPath = Join-Path $fixtureRoot 'verify-inconsistent.json'
        Write-UiVerifyReport -Path $inconsistentPath -TaskVerification (New-UiTaskVerification -Status 'Completed' -Selected @($remaining))
        Assert-TestEqual -Expected 'TaskRemaining' -Actual (Get-W360VerifyOutcome -ExitCode 0 -ReportPath $inconsistentPath).State `
            -Message 'A Completed status that contradicts its items must fail closed.'

        $unavailablePath = Join-Path $fixtureRoot 'verify-unavailable.json'
        Write-UiVerifyReport -Path $unavailablePath -TaskVerification (New-UiTaskVerification -Status 'Unavailable' -UnavailableReason 'RemoveReportMissing')
        $unavailable = Get-W360VerifyOutcome -ExitCode 3 -ReportPath $unavailablePath
        Assert-TestEqual -Expected 'TaskUnavailable' -Actual $unavailable.State -Message 'Unavailable task state.'
        Assert-TestEqual -Expected '上次删除的记录用不了，已经重新检查了一遍电脑' -Actual $unavailable.Headline -Message 'Unavailable headline.'
        Assert-TestTrue ($unavailable.Detail.Contains('找不到上次删除的记录') -and $unavailable.Detail.Contains('没有找到还需要处理的 360 内容')) 'Unavailable detail must explain the reason and the new result.'
        $differentUserPath = Join-Path $fixtureRoot 'verify-unavailable-user.json'
        Write-UiVerifyReport -Path $differentUserPath -TaskVerification (New-UiTaskVerification -Status 'Unavailable' -UnavailableReason 'DifferentUser') -Findings @($browserFinding)
        $differentUser = Get-W360VerifyOutcome -ExitCode 2 -ReportPath $differentUserPath
        Assert-TestEqual -Expected $unavailable.Headline -Actual $differentUser.Headline -Message 'The unavailable headline fits every reason.'
        Assert-TestTrue ($differentUser.Detail.Contains('另一个 Windows 用户') -and $differentUser.Detail.Contains('电脑上还有 1 项 360 的内容')) 'Different-user detail.'
        Assert-TestSequenceEqual -Expected @('CurrentIdentified') -Actual @($differentUser.GridSections | ForEach-Object { $_.Key }) -Message 'Unavailable grid sections.'

        $globalPath = Join-Path $fixtureRoot 'verify-global-incomplete.json'
        Write-UiVerifyReport -Path $globalPath -OmitTaskVerification -Coverage ([pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'Services'; Target = ''; Detail = 'The service list could not be read completely.' }) })
        $global = Get-W360VerifyOutcome -ExitCode 3 -ReportPath $globalPath
        Assert-TestEqual -Expected 'GlobalIncomplete' -Actual $global.State -Message 'Global incomplete state.'
        Assert-TestEqual -Expected 1 -Actual @($global.Sections.Unknown).Count -Message 'Coverage issues belong in the Unknown section.'
        Assert-TestEqual -Expected '后台服务' -Actual @($global.Sections.Unknown)[0].DisplayName -Message 'Coverage issue display name.'
        Assert-TestEqual -Expected '没检查完' -Actual @($global.Sections.Unknown)[0].StateText -Message 'Coverage issue state text.'
        Assert-TestSequenceEqual -Expected @('Unknown') -Actual @($global.GridSections | ForEach-Object { $_.Key }) -Message 'Global grid sections drop empty ones.'

        $cleanPath = Join-Path $fixtureRoot 'verify-global-clean.json'
        Write-UiVerifyReport -Path $cleanPath -TaskVerification $null
        $clean = Get-W360VerifyOutcome -ExitCode 0 -ReportPath $cleanPath
        Assert-TestEqual -Expected 'GlobalClean' -Actual $clean.State -Message 'Global clean state.'
        Assert-TestEqual -Expected '没有找到还需要处理的 360 内容' -Actual $clean.Headline -Message 'Global clean headline does not claim that no 360 content exists.'
        Assert-TestEqual -Expected 0 -Actual @($clean.GridSections).Count -Message 'A clean result has no grid sections.'

        # Items that are never deleted (a program that is still installed, a driver) never leave a green "nothing left".
        $keptOnlyPath = Join-Path $fixtureRoot 'verify-global-kept-only.json'
        $stillInstalled = New-UiFinding -Kind 'InstalledProduct' -Name '360安全浏览器' -Target 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\360se6' -Confidence 'ReviewOnly' `
            -RemovalType 'None' -ProductKey '360SafeBrowser' -Reason '360-family uninstall record still has a live vendor uninstaller.'
        $keptDriver = New-UiFinding -Kind 'Driver' -Name '360Box64.sys' -Target 'C:\Windows\System32\drivers\360Box64.sys' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey 'Drivers'
        Write-UiVerifyReport -Path $keptOnlyPath -OmitTaskVerification -Findings @($stillInstalled, $keptDriver)
        $keptOnly = Get-W360VerifyOutcome -ExitCode 0 -ReportPath $keptOnlyPath
        Assert-TestEqual -Expected 'GlobalKeptOnly' -Actual $keptOnly.State -Message 'Only kept items is its own state.'
        Assert-TestEqual -Expected '没有找到可以删除的 360 内容，但还有 2 项不删除的内容' -Actual $keptOnly.Headline -Message 'Kept-only headline counts the kept items.'
        Assert-TestEqual -Expected 'Text' -Actual (Get-W360OutcomeTone -Outcome $keptOnly) -Message 'Kept items are neither green nor a failure.'
        Assert-TestSequenceEqual -Expected @('CurrentKept') -Actual @($keptOnly.GridSections | ForEach-Object { $_.Key }) -Message 'The kept items are listed.'
        Assert-TestSequenceEqual -Expected @('不删除：请先正常卸载', '不删除：系统驱动') -Actual @(@($keptOnly.GridSections)[0].Items | ForEach-Object { $_.StateText }) -Message 'Each kept item says why.'
        Assert-TestTrue ((@(@($keptOnly.GridSections)[0].Items)[0].Detail).Contains('设置 → 应用')) 'A kept item carries its plain explanation.'
        Assert-TestEqual -Expected '不删除的' -Actual @($keptOnly.GridSections)[0].Title -Message 'Kept section title.'
        Assert-TestSequenceEqual -Expected @('可以关闭了。想删除这些的话，先按每一行的说明处理，再重新检查电脑。') -Actual @($keptOnly.NextSteps) -Message 'Kept-only next step.'
        $unavailableKeptPath = Join-Path $fixtureRoot 'verify-unavailable-kept-only.json'
        Write-UiVerifyReport -Path $unavailableKeptPath -TaskVerification (New-UiTaskVerification -Status 'Unavailable' -UnavailableReason 'RemoveReportMissing') -Findings @($stillInstalled)
        $unavailableKept = Get-W360VerifyOutcome -ExitCode 3 -ReportPath $unavailableKeptPath
        Assert-TestTrue ($unavailableKept.Detail.Contains('还有 1 项不删除的内容')) ('An unusable record with only kept items does not say nothing is left: ' + $unavailableKept.Detail)
        Assert-TestTrue ($unavailableKept.Detail.EndsWith('。')) 'The unavailable detail ends with a full stop.'
        $remainingPath = Join-Path $fixtureRoot 'verify-global-remaining.json'
        Write-UiVerifyReport -Path $remainingPath -TaskVerification $null -Findings @($browserFinding)
        $globalRemaining = Get-W360VerifyOutcome -ExitCode 2 -ReportPath $remainingPath
        Assert-TestEqual -Expected 'GlobalRemaining' -Actual $globalRemaining.State -Message 'Global remaining state.'
        Assert-TestEqual -Expected '电脑上还有 1 项 360 的内容' -Actual $globalRemaining.Headline -Message 'Global remaining headline.'
        Assert-TestEqual -Expected '现在还有的 360 内容' -Actual @($globalRemaining.GridSections)[0].Title -Message 'Current section title.'

        $incompleteTaskPath = Join-Path $fixtureRoot 'verify-task-incomplete.json'
        Write-UiVerifyReport -Path $incompleteTaskPath -TaskVerification (New-UiTaskVerification -Status 'Completed' -Selected $duohuiSelected) `
            -Coverage ([pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'Processes'; Target = ''; Detail = 'x' }) })
        $incompleteTask = Get-W360VerifyOutcome -ExitCode 3 -ReportPath $incompleteTaskPath
        Assert-TestEqual -Expected 'TaskCompleted' -Actual $incompleteTask.State -Message 'Incomplete global coverage keeps TaskCompleted.'
        Assert-TestEqual -Expected $false -Actual $incompleteTask.CoverageComplete -Message 'The incomplete variant is TaskCompleted with CoverageComplete false.'
        Assert-TestTrue ($incompleteTask.Headline.Contains('有些地方没检查完')) 'The headline must mention the unfinished checks.'
        Assert-TestEqual -Expected 1 -Actual @($incompleteTask.NextSteps).Count -Message 'The incomplete variant has one next step.'

        $cancelledVerify = Get-W360VerifyOutcome -ExitCode 0 -ReportPath $cleanPath -Cancelled
        Assert-TestEqual -Expected 'Cancelled' -Actual $cancelledVerify.State -Message 'Cancelled verify.'
        Assert-TestTrue ($cancelledVerify.Detail.Contains('没有做完') -and $cancelledVerify.Detail.Contains('没有删除任何东西')) 'Cancelled verify detail.'
        $failedVerify = Get-W360VerifyOutcome -ExitCode 1 -ReportPath $cleanPath
        Assert-TestEqual -Expected 'Failed' -Actual $failedVerify.State -Message 'Unexpected exit code.'
        Assert-TestEqual -Expected '出了点问题' -Actual $failedVerify.Headline -Message 'Failed verify headline.'
        $invalidVerify = Get-W360VerifyOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'scan-valid.json')
        Assert-TestEqual -Expected 'InvalidReport' -Actual $invalidVerify.State -Message 'A scan report is not a verify report.'
        Assert-TestTrue ($invalidVerify.Detail.Contains('没有删除任何东西') -and $invalidVerify.ErrorText.Contains('Mode is not Verify')) 'Invalid verify keeps the technical reason out of the page.'
    }

    Invoke-TestCase -Run $run -Name 'every result state has its own headline and failure, unknown and restart never look like success' -Test {
        $toneRoot = Join-Path $fixtureRoot 'tones'
        New-Item -ItemType Directory -Path $toneRoot | Out-Null
        $remove = [ordered]@{
            Completed    = Get-W360RemoveOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'remove-completed.json') -ExpectedApprovedReportHash $approvedHash
            NeedsRestart = Get-W360RemoveOutcome -ExitCode 2 -ReportPath (Join-Path $fixtureRoot 'remove-service.json') -ExpectedApprovedReportHash $approvedHash
            Partial      = Get-W360RemoveOutcome -ExitCode 2 -ReportPath (Join-Path $fixtureRoot 'remove-partial.json') -ExpectedApprovedReportHash $approvedHash
            Unknown      = Get-W360RemoveOutcome -ExitCode 2 -ReportPath (Join-Path $fixtureRoot 'remove-blocked.json') -ExpectedApprovedReportHash $approvedHash
            NotStarted   = Get-W360RemoveOutcome -ExitCode 5 -ReportPath (Join-Path $toneRoot 'none.json') -ExpectedApprovedReportHash $approvedHash `
                -Events @([pscustomobject]@{ Phase = 'ElevationCancelled'; Detail = '' })
        }
        $verify = [ordered]@{
            TaskCompleted           = Get-W360VerifyOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'verify-acceptance.json')
            TaskCompletedIncomplete = Get-W360VerifyOutcome -ExitCode 3 -ReportPath (Join-Path $fixtureRoot 'verify-task-incomplete.json')
            TaskCompletedWithNew    = Get-W360VerifyOutcome -ExitCode 4 -ReportPath (Join-Path $fixtureRoot 'verify-new.json')
            TaskRemaining           = Get-W360VerifyOutcome -ExitCode 2 -ReportPath (Join-Path $fixtureRoot 'verify-changed.json')
            TaskUnknown             = Get-W360VerifyOutcome -ExitCode 3 -ReportPath (Join-Path $fixtureRoot 'verify-unknown.json')
            TaskUnavailable         = Get-W360VerifyOutcome -ExitCode 3 -ReportPath (Join-Path $fixtureRoot 'verify-unavailable.json')
            GlobalClean             = Get-W360VerifyOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'verify-global-clean.json')
            GlobalRemaining         = Get-W360VerifyOutcome -ExitCode 2 -ReportPath (Join-Path $fixtureRoot 'verify-global-remaining.json')
            GlobalIncomplete        = Get-W360VerifyOutcome -ExitCode 3 -ReportPath (Join-Path $fixtureRoot 'verify-global-incomplete.json')
            GlobalKeptOnly          = Get-W360VerifyOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'verify-global-kept-only.json')
            Cancelled               = Get-W360VerifyOutcome -ExitCode 0 -ReportPath '' -Cancelled
            Failed                  = Get-W360VerifyOutcome -ExitCode 1 -ReportPath ''
        }
        $scan = [ordered]@{
            Findings            = Get-W360ScanOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'scan-valid.json')
            FindingsKeepOnly    = Get-W360ScanOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'scan-keep-only.json')
            NoMatches           = Get-W360ScanOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'scan-old.json')
            NoMatchesIncomplete = Get-W360ScanOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'scan-incomplete.json')
            Cancelled           = Get-W360ScanOutcome -ExitCode 0 -ReportPath '' -Cancelled
            Failed              = Get-W360ScanOutcome -ExitCode 1 -ReportPath ''
        }
        foreach ($stage in @(@('remove', $remove), @('verify', $verify), @('scan', $scan))) {
            $table = $stage[1]
            $headlines = @($table.Keys | ForEach-Object { [string]$table[$_].Headline })
            foreach ($name in @($table.Keys)) {
                Assert-TestFalse ([string]::IsNullOrWhiteSpace([string]$table[$name].Headline)) ("{0} {1} has no headline." -f $stage[0], $name)
            }
            Assert-TestEqual -Expected $headlines.Count -Actual @($headlines | Sort-Object -Unique).Count -Message ("Every {0} state needs its own headline: {1}" -f $stage[0], ($headlines -join ' | '))
        }
        Assert-TestEqual -Expected (Get-W360ScanOutcome -ExitCode 1 -ReportPath '').Headline -Actual (Get-W360ScanOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'scan-schema1.json')).Headline `
            -Message 'Failed and invalid results share the plain error headline.'

        $expectedTones = @(
            @($remove.Completed, 'Success'), @($remove.NeedsRestart, 'Warning'), @($remove.Partial, 'Error'), @($remove.Unknown, 'Warning'), @($remove.NotStarted, 'Neutral'),
            @($verify.TaskCompleted, 'Success'), @($verify.TaskCompletedIncomplete, 'Warning'), @($verify.TaskCompletedWithNew, 'Warning'),
            @($verify.TaskRemaining, 'Error'), @($verify.TaskUnknown, 'Warning'), @($verify.TaskUnavailable, 'Warning'), @($verify.GlobalClean, 'Success'),
            @($verify.GlobalRemaining, 'Warning'), @($verify.GlobalIncomplete, 'Warning'), @($verify.GlobalKeptOnly, 'Text'), @($verify.Cancelled, 'Neutral'), @($verify.Failed, 'Error'),
            @($scan.NoMatches, 'Success'), @($scan.NoMatchesIncomplete, 'Warning'), @($scan.Cancelled, 'Neutral'), @($scan.Failed, 'Error'),
            @((Get-W360ScanOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'scan-schema1.json')), 'Error')
        )
        foreach ($pair in $expectedTones) {
            Assert-TestEqual -Expected $pair[1] -Actual (Get-W360OutcomeTone -Outcome $pair[0]) -Message ('Tone of ' + $pair[0].State + ' / ' + $pair[0].Headline)
        }
        $successStates = New-Object System.Collections.Generic.List[string]
        foreach ($table in @($remove, $verify, $scan)) {
            foreach ($name in @($table.Keys)) {
                if ((Get-W360OutcomeTone -Outcome $table[$name]) -eq 'Success') { $successStates.Add($name) }
            }
        }
        Assert-TestSequenceEqual -Expected @('Completed', 'TaskCompleted', 'GlobalClean', 'NoMatches') -Actual $successStates.ToArray() -Message 'Only complete, finished results may use the success colour.'
        Assert-TestEqual -Expected 'Warning' -Actual (Get-W360OutcomeTone -Outcome ([pscustomobject]@{ State = 'SomethingNew' })) -Message 'Unknown states never look like success.'
    }

    Invoke-TestCase -Run $run -Name 'task records are written without BOM and the newest valid record is found' -Test {
        $taskRoot = Join-Path $fixtureRoot 'tasks'
        New-Item -ItemType Directory -Path $taskRoot | Out-Null
        $scanPath = Join-Path $taskRoot 'scan.json'
        Write-UiScanReport -Path $scanPath -Findings @($planParent, $planBrowser)
        $scanHash = Get-W360FileSha256 -Path $scanPath
        $removePath = Join-Path $taskRoot 'remove.json'
        Write-UiRemoveReport -Path $removePath -ApprovedReportHash $scanHash.ToLowerInvariant() -Timestamp '2026-09-13T10:05:00.0000000+08:00'

        $first = New-W360TaskRecord -Directory $taskRoot -ScanReportPath $scanPath -ScanReportHash $scanHash -RemoveReportPath $removePath `
            -SelectedFindings @($planParent) -PreservedFindings @($planBrowser)
        Start-Sleep -Milliseconds 30
        $second = New-W360TaskRecord -Directory $taskRoot -ScanReportPath $scanPath -ScanReportHash $scanHash -RemoveReportPath $removePath `
            -SelectedFindings @($planParent, $planVendor) -PreservedFindings @($planBrowser)
        Assert-TestTrue ((Split-Path -Leaf $second) -match '^360-cleanup-task-\d{8}-\d{6}-[0-9a-f]{8}\.json$') 'Task record file name contract.'
        $bytes = [IO.File]::ReadAllBytes($second)
        Assert-TestFalse ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) 'Task records must be UTF-8 without BOM.'

        $damaged = Join-Path $taskRoot '360-cleanup-task-20990101-000000-deadbeef.json'
        [IO.File]::WriteAllText($damaged, '{ "RecordType": "Windows360CleanerTask", broken', (New-Object Text.UTF8Encoding($false)))
        $incompatible = Join-Path $taskRoot '360-cleanup-task-20990101-000001-cafef00d.json'
        $future = Read-W360JsonFile -Path $second
        $future.TaskFormatVersion = 2
        $future.CreatedAt = '2099-01-01T00:00:00.0000000+00:00'
        Write-UiJson -Path $incompatible -Value $future
        (Get-Item -LiteralPath $damaged).LastWriteTime = (Get-Date).AddMinutes(5)
        (Get-Item -LiteralPath $incompatible).LastWriteTime = (Get-Date).AddMinutes(6)

        $latest = Find-W360LatestTask -Directory $taskRoot
        Assert-TestNotNull $latest 'A valid task record must be found.'
        Assert-TestEqual -Expected $second -Actual $latest.Path -Message 'The newest valid record must win; damaged and incompatible records are skipped.'
        Assert-TestEqual -Expected 1 -Actual $latest.InvalidCount -Message 'The damaged record must be counted as invalid.'
        Assert-TestEqual -Expected 1 -Actual $latest.IncompatibleCount -Message 'The future-version record must be counted as incompatible.'
        $record = $latest.Record
        Assert-TestEqual -Expected 'Windows360CleanerTask' -Actual $record.RecordType -Message 'RecordType.'
        Assert-TestEqual -Expected $script:ExpectedToolVersion -Actual $record.ToolVersion -Message 'ToolVersion.'
        Assert-TestTrue ([string]$record.CreatedAt -match '[+-]\d{2}:\d{2}$') 'CreatedAt must carry an offset.'
        Assert-TestEqual -Expected $scanHash -Actual $record.ScanReport.Sha256 -Message 'Scan hash.'
        Assert-TestEqual -Expected 2 -Actual @($record.SelectedTargets).Count -Message 'Selected targets.'
        Assert-TestEqual -Expected 1 -Actual @($record.PreservedTargets).Count -Message 'A single preserved target must stay an array.'
        Assert-TestEqual -Expected $planParent.SelectionId -Actual @($record.SelectedTargets)[0].SelectionId -Message 'TargetRecord SelectionId.'
        Assert-TestEqual -Expected 'Duohui' -Actual @($record.SelectedTargets)[0].ProductKey -Message 'TargetRecord ProductKey.'
        Assert-TestTrue ([string]$record.Notice).Contains('not an approval to remove anything') 'The task notice must disclaim approval.'

        $state = Get-W360TaskState -TaskInfo $latest -LastBootTime ([DateTimeOffset]'2026-09-13T11:00:00+08:00')
        Assert-TestTrue $state.RemoveReportValid ('The bound Remove report must be valid: ' + $state.RemoveReportIssue)
        Assert-TestEqual -Expected $true -Actual $state.RestartedSinceRemove -Message 'A later boot time means restarted.'
        Assert-TestEqual -Expected 2 -Actual $state.SelectedCount -Message 'Selected count.'
        Assert-TestEqual -Expected 1 -Actual $state.PreservedCount -Message 'Preserved count.'
        Assert-TestEqual -Expected $false -Actual (Get-W360TaskState -TaskInfo $latest -LastBootTime ([DateTimeOffset]'2026-09-13T01:00:00+00:00')).RestartedSinceRemove -Message 'An earlier boot means not restarted.'
        Assert-TestNull (Get-W360TaskState -TaskInfo $latest -LastBootTime $null).RestartedSinceRemove 'An unknown boot time must stay unknown.'
        $boot = Get-W360LastBootTime
        Assert-TestTrue ($null -eq $boot -or $boot -is [DateTime]) 'Get-W360LastBootTime returns a DateTime or null.'

        Remove-Item -LiteralPath $removePath
        $missing = Get-W360TaskState -TaskInfo $latest -LastBootTime $null
        Assert-TestFalse $missing.RemoveReportValid 'A missing Remove report is not valid.'
        Assert-TestEqual -Expected 'Missing' -Actual $missing.RemoveReportIssue -Message 'Missing issue code.'

        Write-UiRemoveReport -Path $removePath -ApprovedReportHash ('D1' * 32)
        $mismatch = Get-W360TaskState -TaskInfo $latest -LastBootTime $null
        Assert-TestEqual -Expected 'HashMismatch' -Actual $mismatch.RemoveReportIssue -Message 'A Remove report for another scan must be rejected.'
        Assert-TestFalse $mismatch.RemoveReportValid 'A hash mismatch is not valid.'
        Remove-Item -LiteralPath $removePath
        Write-UiScanReport -Path $removePath -Findings @()
        Assert-TestEqual -Expected 'NotRemoveReport' -Actual (Get-W360TaskState -TaskInfo $latest -LastBootTime $null).RemoveReportIssue -Message 'A Scan report is not a Remove report.'
        Remove-Item -LiteralPath $removePath
        Write-UiRemoveReport -Path $removePath -ApprovedReportHash $scanHash -SchemaVersion 1
        Assert-TestEqual -Expected 'Incompatible' -Actual (Get-W360TaskState -TaskInfo $latest -LastBootTime $null).RemoveReportIssue -Message 'SchemaVersion 1 is incompatible.'

        $onlyBad = Join-Path $fixtureRoot 'tasks-bad'
        New-Item -ItemType Directory -Path $onlyBad | Out-Null
        Copy-Item -LiteralPath $damaged -Destination $onlyBad
        Assert-TestNull (Find-W360LatestTask -Directory $onlyBad) 'Only damaged records must return null.'
        Assert-TestNull (Find-W360LatestTask -Directory (Join-Path $fixtureRoot 'no-such-dir')) 'A missing directory must return null.'
    }

    Invoke-TestCase -Run $run -Name 'help summary is redacted, excludes identifiers and can never become an approved report' -Test {
        $helpRoot = Join-Path $fixtureRoot 'help'
        New-Item -ItemType Directory -Path $helpRoot | Out-Null
        $context = New-W360RedactionContext -UserName 'zhangsan' -UserDomain 'CORPDOMAIN' -ComputerName 'DESKTOP-ABC1234' `
            -UserSid 'S-1-5-21-1111111111-2222222222-3333333333-1001' -PathTokens @(
                [pscustomobject]@{ Path = 'C:\Users\zhangsan\AppData\Local'; Token = '%LOCALAPPDATA%' },
                [pscustomobject]@{ Path = 'C:\Users\zhangsan\AppData\Roaming'; Token = '%APPDATA%' },
                [pscustomobject]@{ Path = 'D:\OneDrive - Contoso'; Token = '%OneDrive%' },
                [pscustomobject]@{ Path = 'C:\Users\zhangsan'; Token = '%USERPROFILE%' }
            )
        Assert-TestEqual -Expected 'C:\Users\zhangsan\AppData\Roaming' -Actual @($context.PathTokens)[0].Path -Message 'Path tokens must be sorted longest first.'

        $profileFinding = New-UiFinding -Name '360se6 browser profile' -Target 'C:\Users\zhangsan\AppData\Roaming\360se6\User Data' -Confidence 'ReviewOnly' -RemovalType 'None' -ProductKey '360SafeBrowser'
        $otherProfile = New-UiFinding -Name 'Roaming SoftMgr cache' -Target 'C:\Users\lisi.wang\AppData\Roaming\SoftMgr' -ProductKey '360SoftMgr'
        $programFiles = New-UiFinding -Name '360 Program Files (x86)' -Target 'C:\Program Files (x86)\360\360Safe' -ProductKey '360InstallDir' -IdentityFingerprint ('E5' * 32)
        $scanPath = Join-Path $helpRoot '360-cleanup-scan-20260913-100000-1a2b3c4d.json'
        Write-UiScanReport -Path $scanPath -Findings @($profileFinding, $otherProfile, $programFiles)
        $hashBefore = Get-W360FileSha256 -Path $scanPath
        $outcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $scanPath
        $errorText = @(
            'Failed on DESKTOP-ABC1234 for CORPDOMAIN\zhangsan (zhangsan@example.com)',
            'SID S-1-5-21-1111111111-2222222222-3333333333-1001 and S-1-12-1-12345-67890',
            'Private D:\Private Files\tax 2026.xlsx and D:\OneDrive - Contoso\Documents\cv.docx',
            'Share \\fileserver\home$\zhangsan\notes.txt',
            ('SelectionId ' + $otherProfile.SelectionId + ' fingerprint ' + ('E5' * 32)),
            'Kept C:\Windows\System32\drivers\360Box64.sys'
        ) -join "`r`n"
        $summary = New-W360HelpSummary -Stage 'Scan' -Outcome $outcome -ErrorText $errorText -ReportPath $scanPath -Context $context

        foreach ($secret in @('zhangsan', 'lisi.wang', 'DESKTOP-ABC1234', 'CORPDOMAIN', '1111111111', '12345-67890', 'example.com',
                'Private Files', 'tax 2026', 'OneDrive - Contoso', 'fileserver', $otherProfile.SelectionId, ('E5' * 32), $helpRoot, 'ApprovalContext')) {
            Assert-TestFalse ($summary.IndexOf($secret, [StringComparison]::OrdinalIgnoreCase) -ge 0) "The help summary leaked: $secret"
        }
        foreach ($expected in @('Windows 360 清理工具 · 问题信息', '尽量去掉了用户名、文件夹名等隐私', '可能有遗漏', '不能用来删除任何东西', '也不代表你同意删除',
                '没有被改动', '不会自动上传', ('工具版本：' + $script:ExpectedToolVersion), '在哪一步：检查电脑',
                '360-cleanup-scan-20260913-100000-1a2b3c4d.json', 'C:\Program Files (x86)\360\360Safe', '%APPDATA%\360se6\User Data',
                'C:\Windows\System32\drivers\360Box64.sys', '<私人路径已隐藏>', '<网络路径已隐藏>', '<计算机名>', '<邮箱>', 'S-1-5-21-<已隐藏>',
                'C:\Users\<用户名>\AppData\Roaming\SoftMgr', '%OneDrive%\Documents\cv.docx', '不删除：书签和历史记录',
                '找到的 360 内容：共 3 项；可以删除 2 项；不删除 1 项')) {
            Assert-TestTrue ($summary.Contains($expected)) "The help summary is missing: $expected"
        }
        # The plain lines of the help text use the window's words; only the technical lines (versions, error output, paths) may not.
        $allLines = @($summary -split "`r`n")
        $errorIndex = [Array]::IndexOf($allLines, '相关错误信息：')
        Assert-TestTrue ($errorIndex -gt 0) 'The help summary keeps the error text section.'
        $plainText = (@($allLines[0..($errorIndex - 1)] | Where-Object { -not $_.StartsWith('- ') }) -join "`n")
        foreach ($old in @('求助摘要', '脱敏', '批准', '原始报告', '阶段', '已识别', '可选择', '仅供查看', '默认保留', '扫描', '复检', '清理后', '快照')) {
            Assert-TestFalse ($plainText.Contains($old)) "The plain help lines still use the old word: $old"
        }
        Assert-TestEqual -Expected 0 -Actual @(Get-W360MainUiBannedWords -Text $plainText -Language zh).Count `
            -Message ("The plain help lines use banned words:`r`n" + $plainText)
        Assert-TestEqual -Expected $hashBefore -Actual (Get-W360FileSha256 -Path $scanPath) -Message 'Creating a help summary must not modify the report.'

        $saved = Save-W360HelpSummary -Directory $helpRoot -Text $summary
        Assert-TestTrue ((Split-Path -Leaf $saved) -match '^360-cleanup-help-\d{8}-\d{6}-[0-9a-f]{8}\.txt$') 'Help file name contract.'
        $savedBytes = [IO.File]::ReadAllBytes($saved)
        Assert-TestTrue ($savedBytes[0] -eq 0xEF -and $savedBytes[1] -eq 0xBB -and $savedBytes[2] -eq 0xBF) 'The help summary must be UTF-8 with BOM.'

        $jsonCopy = Join-Path $helpRoot 'help-summary-renamed.json'
        Copy-Item -LiteralPath $saved -Destination $jsonCopy
        $previous = [Environment]::GetEnvironmentVariable('WINDOWS_360_CLEANER_TEST_MODE', 'Process')
        $env:WINDOWS_360_CLEANER_TEST_MODE = 'ISOLATED-SAFETY-TEST'
        try {
            $rejections = & {
                . $CleanerScriptPath -InternalTestLibraryOnly
                foreach ($candidate in @($saved, $jsonCopy)) {
                    $rejected = $false
                    try { [void](Read-ApprovedCleanupReport -Path $candidate -ExpectedHash '') }
                    catch { $rejected = $true }
                    $rejected
                }
            }
        }
        finally {
            if ($null -eq $previous) { Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue }
            else { $env:WINDOWS_360_CLEANER_TEST_MODE = $previous }
        }
        Assert-TestSequenceEqual -Expected @($true, $true) -Actual @($rejections) -Message 'Read-ApprovedCleanupReport must reject a saved help summary.'

        $removeSummary = New-W360HelpSummary -Stage 'Remove' -Outcome (Get-W360RemoveOutcome -ExitCode 2 -ReportPath (Join-Path $fixtureRoot 'remove-partial.json') -ExpectedApprovedReportHash $approvedHash) -Context $context
        Assert-TestTrue ($removeSummary.Contains('Windows 不让删除')) 'The Remove help summary must list problems.'
        Assert-TestTrue ($removeSummary.Contains('在哪一步：删除') -and $removeSummary.Contains('没删掉、跳过或没做完的：')) 'The Remove help summary uses the plain step and problem lines.'
        # What is left after deleting is labelled like a new check in the window: a folder that holds a kept item is "won't delete".
        $leftRoot = 'C:\Program Files (x86)\360\360Safe'
        $leftFindings = @(
            [pscustomobject]@{ Kind = 'Path'; Name = '360Safe'; Target = $leftRoot; Confidence = 'Confirmed'; RemovalType = 'Path'; Reason = 'Known 360 path.'; ValueName = ''; Offline = $false; ProductKey = '360Security'; SelectionId = ('A1' * 32); IdentityFingerprint = '' },
            [pscustomobject]@{ Kind = 'Path'; Name = 'Config'; Target = ($leftRoot + '\Config'); Confidence = 'ReviewOnly'; RemovalType = 'None'; Reason = 'Name only.'; ValueName = ''; Offline = $false; ProductKey = '360Security'; SelectionId = ''; IdentityFingerprint = '' },
            [pscustomobject]@{ Kind = 'Path'; Name = '360 unpack temporary files'; Target = 'C:\Windows\Temp\360UnPackTmp'; Confidence = 'Confirmed'; RemovalType = 'Path'; Reason = 'Known 360 path.'; ValueName = ''; Offline = $false; ProductKey = '360Temp'; SelectionId = ('A2' * 32); IdentityFingerprint = '' }
        )
        $leftOutcome = [pscustomobject]@{
            State = 'Partial'; Headline = 'H'; Detail = ''; Problems = @()
            Report = [pscustomobject]@{ Findings = $leftFindings; Summary = [pscustomobject]@{ ImmediateRescanComplete = $true } }
        }
        $leftLines = @((New-W360HelpSummary -Stage 'Remove' -Outcome $leftOutcome -Context $context) -split "`r`n" | Where-Object { $_.StartsWith('- [') })
        Assert-TestEqual -Expected 3 -Actual $leftLines.Count -Message ("The Remove help summary lists what is left:`r`n" + ($leftLines -join "`r`n"))
        Assert-TestTrue ($leftLines[0].StartsWith('- [' + (Get-W360Text -Key 'Status.KeptContentInside.Text') + ']') -and $leftLines[0].Contains($leftRoot)) ('A folder with a kept item inside is labelled deletable: ' + $leftLines[0])
        Assert-TestTrue ($leftLines[2].StartsWith('- [' + (Get-W360Text -Key 'Status.AwaitingChoice.Text') + ']')) ('A deletable item left over is not labelled deletable: ' + $leftLines[2])
        $verifySummary = New-W360HelpSummary -Stage 'Verify' -Outcome (Get-W360VerifyOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'verify-acceptance.json')) -Context $context
        Assert-TestTrue ($verifySummary.Contains('[你保留的] 还在') -and $verifySummary.Contains('已删掉 3 项') -and $verifySummary.Contains('你保留的 1 项') -and
            $verifySummary.Contains('你保留的，但不见了 0 项')) 'The Verify help summary must list the sections with the page names.'
        $goneSummary = New-W360HelpSummary -Stage 'Verify' -Outcome (Get-W360VerifyOutcome -ExitCode 0 -ReportPath (Join-Path $fixtureRoot 'verify-preserved-gone.json')) -Context $context
        Assert-TestTrue ($goneSummary.Contains('[你保留的，但不见了] 不见了') -and $goneSummary.Contains('你保留的，但不见了 1 项')) 'The Verify help summary names gone kept items.'
        Assert-TestFalse ($verifySummary -match '[①②③④]') 'The Verify help summary uses the section titles, not numbered markers.'
        Assert-TestTrue ($verifySummary.Contains('在哪一步：检查上次删除的结果')) 'The Verify help summary names the step with the button name.'
        $errorSummary = New-W360HelpSummary -Stage 'Error' -Outcome $null -ErrorText 'Boom at C:\Users\zhangsan\Desktop\x.ps1' -Context $context
        Assert-TestFalse ($errorSummary.Contains('zhangsan')) 'The error-stage summary must be redacted.'
        Assert-TestTrue ($errorSummary.Contains('结果：没有拿到结果') -and $errorSummary.Contains('不会自动上传') -and $errorSummary.Contains('也不代表你同意删除')) `
            'The error-stage summary keeps the plain no-result line and the not-approval and no-upload notes.'
    }

    Invoke-TestCase -Run $run -Name 'redaction of environment context keeps system paths and hides the real profile' -Test {
        $context = New-W360RedactionContext
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        $text = ConvertTo-W360RedactedText -Text ($localAppData + '\360Chrome\Chrome\Application and C:\Program Files\360') -Context $context
        Assert-TestTrue ($text.StartsWith('%LOCALAPPDATA%\360Chrome\Chrome\Application')) ('LocalAppData must become a token: ' + $text)
        Assert-TestTrue ($text.EndsWith('C:\Program Files\360')) 'Program Files paths are kept.'
        $jsonEscaped = ConvertTo-W360RedactedText -Text ($localAppData.Replace('\', '\\') + '\\dhpingbao') -Context $context
        Assert-TestTrue ($jsonEscaped.StartsWith('%LOCALAPPDATA%')) ('JSON-escaped paths must be redacted too: ' + $jsonEscaped)
        Assert-TestEqual -Expected '' -Actual (ConvertTo-W360RedactedText -Text $null -Context $context) -Message 'Null text redacts to empty.'
    }

    Invoke-TestCase -Run $run -Name 'progress markers, progress file lines and phase texts are parsed strictly' -Test {
        $marker = ConvertFrom-W360ProgressLine -Line 'W360-PROGRESS|ScanComplete|12'
        Assert-TestEqual -Expected 'ScanComplete' -Actual $marker.Phase -Message 'Marker phase.'
        Assert-TestEqual -Expected '12' -Actual $marker.Detail -Message 'Marker detail.'
        Assert-TestEqual -Expected '' -Actual (ConvertFrom-W360ProgressLine -Line "W360-PROGRESS|Done|`r").Detail -Message 'An empty detail is allowed.'
        foreach ($bad in @('W360-PROGRESS|Done', 'W360-PROGRESS||x', 'W360-PROGRESS|Done|a|b', 'progress|Done|x', ('W360-PROGRESS|Done|' + ('x' * 301)), 'W360-PROGRESS|Bad Phase|x')) {
            Assert-TestNull (ConvertFrom-W360ProgressLine -Line $bad) "A malformed marker must be ignored: $bad"
        }
        Assert-TestNull (ConvertFrom-W360ProgressLine -Line $null) 'A null line is not a marker.'
        $fileLine = ConvertFrom-W360ProgressFileLine -Line '2026-09-13T02:03:04.5678901Z|RemovingPaths|C:\x'
        Assert-TestEqual -Expected 'RemovingPaths' -Actual $fileLine.Phase -Message 'File line phase.'
        Assert-TestTrue ($fileLine.Time -is [DateTime]) 'File line time must be a DateTime.'
        Assert-TestNull (ConvertFrom-W360ProgressFileLine -Line 'yesterday|RemovingPaths|x') 'An invalid timestamp is rejected.'
        Assert-TestNull (ConvertFrom-W360ProgressFileLine -Line 'W360-PROGRESS|Done|') 'A stdout marker is not a file line.'
        foreach ($phase in $script:W360KnownPhases) {
            Assert-TestFalse ((Get-W360PhaseText -Phase $phase) -eq (Get-W360Text -Key 'Phase.Unknown')) "Phase $phase needs its own text."
        }
        Assert-TestEqual -Expected '正在处理…' -Actual (Get-W360PhaseText -Phase 'SomethingNew') -Message 'Unknown phases use the generic text.'
        Assert-TestEqual -Expected 'Windows 弹出了一个窗口，请点“是”继续。点“否”就不会删除任何东西。' -Actual (Get-W360PhaseText -Phase 'WaitingForElevation') -Message 'Elevation phase text.'
        Assert-TestEqual -Expected '你点了“否”，没有删除任何东西' -Actual (Get-W360PhaseText -Phase 'ElevationCancelled') -Message 'Declined prompt phase text.'
        # ElevationFailed is also written after the elevated child may have started, so it must never promise that nothing was deleted.
        Assert-TestFalse ((Get-W360PhaseText -Phase 'ElevationFailed').Contains('没有删除')) 'A failed elevation phase must not claim that nothing was deleted.'
    }

    Invoke-TestCase -Run $run -Name 'process arguments are quoted safely and quotes or line breaks are rejected' -Test {
        Assert-TestEqual -Expected 'Scan' -Actual (ConvertTo-W360ProcessArgument -Value 'Scan') -Message 'Plain argument.'
        Assert-TestEqual -Expected '"C:\测试 目录\a.json"' -Actual (ConvertTo-W360ProcessArgument -Value 'C:\测试 目录\a.json') -Message 'Whitespace is quoted.'
        Assert-TestEqual -Expected '"C:\a b\\"' -Actual (ConvertTo-W360ProcessArgument -Value 'C:\a b\') -Message 'Trailing backslashes are doubled inside quotes.'
        Assert-TestEqual -Expected '""' -Actual (ConvertTo-W360ProcessArgument -Value '') -Message 'Empty argument.'
        foreach ($bad in @('a"b', "a`rb", "a`nb")) {
            Assert-TestThrows -Operation { ConvertTo-W360ProcessArgument -Value $bad } -Message 'Unsafe arguments must throw.'
        }
    }

    Invoke-TestCase -Run $run -Name 'progress file path contract and safe removal' -Test {
        $progressPath = New-W360ProgressFilePath
        [void]$createdProgressFiles.Add($progressPath)
        Assert-TestTrue ((Split-Path -Leaf $progressPath) -cmatch '^windows-360-cleaner-progress-[0-9a-f]{32}\.log$') 'Progress file name contract.'
        Assert-TestEqual -Expected ([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')) -Actual (Split-Path -Parent $progressPath).TrimEnd('\') -Message 'Progress files live in the temp folder.'
        [IO.File]::WriteAllText($progressPath, "2026-09-13T02:03:04.0000000Z|ElevatedStarted|`n", (New-Object Text.UTF8Encoding($false)))
        Remove-W360ProgressFile -Path $progressPath
        Assert-TestFalse ([IO.File]::Exists($progressPath)) 'A contract progress file must be deleted.'

        $wrongParent = Join-Path $fixtureRoot ('windows-360-cleaner-progress-' + ('a' * 32) + '.log')
        [IO.File]::WriteAllText($wrongParent, 'x')
        Remove-W360ProgressFile -Path $wrongParent
        Assert-TestTrue ([IO.File]::Exists($wrongParent)) 'A progress-like file outside the temp root must never be deleted.'
        $wrongName = Join-Path $fixtureRoot 'not-a-progress-file.log'
        [IO.File]::WriteAllText($wrongName, 'x')
        Remove-W360ProgressFile -Path $wrongName
        Assert-TestTrue ([IO.File]::Exists($wrongName)) 'A file with another name must never be deleted.'
        Remove-W360ProgressFile -Path $null
        Remove-W360ProgressFile -Path 'C:\bad|path'
    }

    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    $childRoot = Join-Path $fixtureRoot 'child fixtures 子进程'
    New-Item -ItemType Directory -Path $childRoot | Out-Null
    $utf8Bom = New-Object Text.UTF8Encoding($true)

    Invoke-TestCase -Run $run -Name 'runner propagates exit codes, parses stdout markers and decodes UTF-8' -Test {
        $script = Join-Path $childRoot 'markers.ps1'
        [IO.File]::WriteAllText($script, (@(
            '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)',
            '[Console]::Out.WriteLine("W360-PROGRESS|ScanStart|")',
            '[Console]::Out.WriteLine("plain output line")',
            '[Console]::Out.WriteLine("W360-PROGRESS|bad")',
            '[Console]::Out.WriteLine("W360-PROGRESS|ScanComplete|3")',
            '[Console]::Out.WriteLine([string][char]0x5DF2 + [char]0x8BC6 + [char]0x522B)',
            '[Console]::Error.WriteLine("fixture stderr line")',
            'exit 7'
        ) -join "`r`n"), $utf8Bom)
        $state = Start-W360ChildProcess -FilePath $powershellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
        try { [void](Wait-UiChild -State $state -TimeoutSeconds 20) }
        finally { if (-not $state.Completed) { try { $state.Process.Kill() } catch {} } }
        Assert-TestTrue $state.Completed 'The child must complete.'
        Assert-TestEqual -Expected 7 -Actual $state.ExitCode -Message 'The exit code must propagate.'
        Assert-TestFalse $state.Cancelled 'A normal run is not cancelled.'
        Assert-TestSequenceEqual -Expected @('ScanStart', 'ScanComplete') -Actual @($state.Events | ForEach-Object { $_.Phase }) -Message 'Only valid markers become events.'
        Assert-TestEqual -Expected '3' -Actual @($state.Events)[1].Detail -Message 'Marker detail.'
        Assert-TestEqual -Expected 'Stdout' -Actual @($state.Events)[0].Source -Message 'Marker source.'
        Assert-TestTrue (@($state.StdoutLines) -contains '已识别') 'UTF-8 child output must be decoded.'
        Assert-TestTrue (@($state.StderrLines) -contains 'fixture stderr line') 'stderr must be captured.'
        Assert-TestEqual -Expected 0 -Actual (Update-W360ChildProcess -State $state) -Message 'Pumping a completed child is a no-op.'
    }

    Invoke-TestCase -Run $run -Name 'runner survives more than 200 KB on stdout and stderr without deadlock' -Test {
        $script = Join-Path $childRoot 'flood.ps1'
        [IO.File]::WriteAllText($script, (@(
            '$pad = "x" * 190',
            'for ($i = 0; $i -lt 2600; $i++) {',
            '    [Console]::Out.WriteLine(("OUT{0:D6}{1}" -f $i, $pad))',
            '    [Console]::Error.WriteLine(("ERR{0:D6}{1}" -f $i, $pad))',
            '}',
            'exit 3'
        ) -join "`r`n"), $utf8Bom)
        $state = Start-W360ChildProcess -FilePath $powershellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
        try { $elapsed = Wait-UiChild -State $state -TimeoutSeconds 45 -PumpIntervalMilliseconds 250 }
        finally { if (-not $state.Completed) { try { $state.Process.Kill() } catch {} } }
        Assert-TestEqual -Expected 3 -Actual $state.ExitCode -Message 'The flood child exit code.'
        Assert-TestEqual -Expected ([long]2600) -Actual $state.StdoutLineCount -Message 'Every stdout line must be read.'
        Assert-TestEqual -Expected ([long]2600) -Actual $state.StderrLineCount -Message 'Every stderr line must be read.'
        Assert-TestEqual -Expected 2000 -Actual $state.StdoutLines.Count -Message 'Only the last 2000 stdout lines are kept.'
        Assert-TestEqual -Expected 2000 -Actual $state.StderrLines.Count -Message 'Only the last 2000 stderr lines are kept.'
        Assert-TestTrue ([string]$state.StdoutLines[1999]).StartsWith('OUT002599') 'The newest stdout line must be kept.'
        Assert-TestTrue ([string]$state.StderrLines[0]).StartsWith('ERR000600') 'The oldest stderr lines must be dropped.'
        Assert-TestFalse $state.StreamsAbandoned 'Streams must reach EOF normally.'
        Write-Host ("  flood child completed in {0:N1} s with a 250 ms pump" -f $elapsed.TotalSeconds)
    }

    Invoke-TestCase -Run $run -Name 'runner reads the elevated progress file incrementally with shared access' -Test {
        $progressPath = New-W360ProgressFilePath
        [void]$createdProgressFiles.Add($progressPath)
        $script = Join-Path $childRoot 'progress-file.ps1'
        [IO.File]::WriteAllText($script, (@(
            'param([string]$ProgressPath)',
            '$stream = New-Object IO.FileStream($ProgressPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))',
            '$encoding = New-Object Text.UTF8Encoding($false)',
            'foreach ($phase in @("ElevatedStarted", "RemovingPaths", "Done")) {',
            '    $bytes = $encoding.GetBytes(([DateTime]::UtcNow.ToString("o") + "|" + $phase + "|`n"))',
            '    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush(); Start-Sleep -Milliseconds 300',
            '}',
            '$partial = $encoding.GetBytes(([DateTime]::UtcNow.ToString("o") + "|SavingReport|tail"))',
            '$stream.Write($partial, 0, $partial.Length); $stream.Flush(); Start-Sleep -Milliseconds 300',
            '$stream.Dispose()',
            'exit 0'
        ) -join "`r`n"), $utf8Bom)
        $state = Start-W360ChildProcess -FilePath $powershellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-ProgressPath', $progressPath)
        try { [void](Wait-UiChild -State $state -TimeoutSeconds 20 -PumpIntervalMilliseconds 100 -ProgressFilePath $progressPath) }
        finally { if (-not $state.Completed) { try { $state.Process.Kill() } catch {} } }
        Assert-TestEqual -Expected 0 -Actual $state.ExitCode -Message 'Progress child exit code.'
        Assert-TestSequenceEqual -Expected @('ElevatedStarted', 'RemovingPaths', 'Done', 'SavingReport') -Actual @($state.Events | ForEach-Object { $_.Phase }) `
            -Message 'Every progress file line must become exactly one event, including a final unterminated line.'
        Assert-TestTrue (@($state.Events | Where-Object { $_.Source -ne 'File' }).Count -eq 0) 'Progress file events have Source File.'
        Remove-W360ProgressFile -Path $progressPath
        Assert-TestFalse ([IO.File]::Exists($progressPath)) 'The progress file must be removed afterwards.'
    }

    Invoke-TestCase -Run $run -Name 'cancelling a sleeping Scan child completes as Cancelled, and Remove can never be stopped' -Test {
        $script = Join-Path $childRoot 'sleep.ps1'
        [IO.File]::WriteAllText($script, "[Console]::Out.WriteLine('W360-PROGRESS|ScanStart|')`r`nStart-Sleep -Seconds 60`r`nexit 0", $utf8Bom)
        $state = Start-W360ChildProcess -FilePath $powershellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Mode', 'Scan')
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (@($state.Events).Count -eq 0 -and $watch.Elapsed.TotalSeconds -lt 10) {
                [void](Update-W360ChildProcess -State $state)
                Start-Sleep -Milliseconds 50
            }
            Assert-TestFalse $state.Completed 'The sleeping child must still be running before cancellation.'
            Stop-W360ChildProcess -State $state
            Assert-TestTrue $state.Cancelled 'Stop must mark the state as cancelled.'
            [void](Wait-UiChild -State $state -TimeoutSeconds 10)
        }
        finally { if (-not $state.Completed) { try { $state.Process.Kill() } catch {} } }
        Assert-TestTrue $state.Completed 'A cancelled child must complete.'
        Assert-TestTrue $state.Cancelled 'A cancelled child stays cancelled.'
        $outcome = Get-W360ScanOutcome -ExitCode $state.ExitCode -ReportPath (Join-Path $fixtureRoot 'scan-valid.json') -Cancelled:$state.Cancelled -StdoutLines $state.StdoutLines -StderrLines $state.StderrLines
        Assert-TestEqual -Expected 'Cancelled' -Actual $outcome.State -Message 'A cancelled child must produce a Cancelled outcome.'

        $removeState = [pscustomobject]@{
            Process = $null; ArgumentList = [string[]]@('-File', 'x.ps1', '-Mode', 'Remove', '-ConfirmRemoval'); Completed = $false; Cancelled = $false
        }
        Assert-TestThrows -Operation { Stop-W360ChildProcess -State $removeState } -Message 'A Remove child must never be stopped.' -ExpectedMessagePattern 'must never be cancelled'
        Assert-TestFalse $removeState.Cancelled 'A refused stop must not mark Remove as cancelled.'
    }

    Complete-TestRun -Run $run
}
finally {
    foreach ($progressPath in @($createdProgressFiles)) {
        Remove-W360ProgressFile -Path $progressPath
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
