#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath,
    [string]$SummaryScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Tests of scripts/Show-360Summary.ps1, the read-only helper that turns reports into the plain words an agent tells the
# user. Reports come from the real core functions on isolated fixtures with the fake runtime, or are small synthetic
# Scan reports. Nothing here deletes anything outside the temporary test directory, elevates, or touches the registry.
$agentTestPath = $PSCommandPath
$testsRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($CleanerScriptPath)) { $CleanerScriptPath = Join-Path $testsRoot '..\scripts\Invoke-360Cleanup.ps1' }
$CleanerScriptPath = [IO.Path]::GetFullPath($CleanerScriptPath)
if ([string]::IsNullOrWhiteSpace($SummaryScriptPath)) { $SummaryScriptPath = Join-Path (Split-Path -Parent $CleanerScriptPath) 'Show-360Summary.ps1' }
$SummaryScriptPath = [IO.Path]::GetFullPath($SummaryScriptPath)
$libraryPath = Join-Path (Split-Path -Parent $CleanerScriptPath) 'Windows360Cleaner.Library.ps1'
$selectorPath = Join-Path (Split-Path -Parent $CleanerScriptPath) 'Select-360Cleanup.ps1'
. (Join-Path $testsRoot 'Test-Helpers.ps1')

$script:AgentSid = [string][Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function ConvertTo-AgentRun {
    param([AllowEmptyCollection()][object[]]$Lines, [int]$ExitCode)

    $text = (@($Lines | ForEach-Object { [string]$_ }) -join "`r`n")
    $userLines = @(@($Lines | ForEach-Object { [string]$_ }) | Where-Object { -not $_.StartsWith('AGENT:', [StringComparison]::Ordinal) })
    $agentLines = @(@($Lines | ForEach-Object { [string]$_ }) | Where-Object { $_.StartsWith('AGENT:', [StringComparison]::Ordinal) })
    return [pscustomobject]@{ ExitCode = $ExitCode; Text = $text; UserText = ($userLines -join "`r`n"); AgentLines = $agentLines }
}

function Invoke-AgentSummary {
    param([Parameter(Mandatory = $true)][hashtable]$Arguments)

    $global:LASTEXITCODE = 0
    $lines = @(& $SummaryScriptPath @Arguments)
    return (ConvertTo-AgentRun -Lines $lines -ExitCode $global:LASTEXITCODE)
}

# The report-sha256 an agent passes back with -Delete: the SHA-256 of the Scan report file the user saw.
function Get-AgentReportHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-AgentDeleteArguments {
    param([Parameter(Mandatory = $true)][string]$Report, [Parameter(Mandatory = $true)][string]$Choice, [hashtable]$Extra = @{})

    $arguments = @{ Report = $Report; Delete = @($Choice); ScanReportHash = (Get-AgentReportHash -Path $Report) }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    return $arguments
}

# An agent text of the summary script (its own table, which is registered only inside the script run).
function Get-SummaryTestText {
    param([Parameter(Mandatory = $true)][string]$Key, [ValidateSet('zh', 'en')][string]$Language = 'zh', [object[]]$Arguments = @())

    if ($null -eq $script:SummaryTestTexts) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($SummaryScriptPath, [ref]$tokens, [ref]$parseErrors)
        $table = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:SummaryTexts' }, $true)
        $script:SummaryTestTexts = $table.Right.Expression.SafeGetValue()
    }
    $template = [string]@($script:SummaryTestTexts[$Key])[$(if ($Language -eq 'en') { 1 } else { 0 })]
    if ($Arguments.Count -gt 0) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, $template, $Arguments) }
    return $template
}
$script:SummaryTestTexts = $null

# The quoting helpers of the summary script, loaded from its source so the refusal of unsafe characters can be
# tested directly (Windows file names cannot contain a quote or a line break).
function Import-AgentQuotingHelpers {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($SummaryScriptPath, [ref]$tokens, [ref]$parseErrors)
    $assignment = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:SummaryUnsafeCommandCharacters' }, $true)
    $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @('Test-SummaryCommandSafe', 'Format-SummaryQuoted') -contains $node.Name }, $true))
    Assert-TestNotNull -Actual $assignment -Message 'The unsafe character list was not found.'
    Assert-TestEqual -Expected 2 -Actual $functions.Count -Message 'The quoting helpers were not found.'
    return ([scriptblock]::Create((@($assignment.Extent.Text) + @($functions | ForEach-Object { $_.Extent.Text })) -join "`r`n"))
}

function Invoke-AgentSummaryJson {
    param([Parameter(Mandatory = $true)][hashtable]$Arguments)

    $withJson = @{}
    foreach ($key in $Arguments.Keys) { $withJson[$key] = $Arguments[$key] }
    $withJson['Json'] = $true
    $global:LASTEXITCODE = 0
    $raw = (@(& $SummaryScriptPath @withJson) | ForEach-Object { [string]$_ }) -join "`n"
    $code = $global:LASTEXITCODE
    $value = $raw | ConvertFrom-Json
    Add-Member -InputObject $value -NotePropertyName 'ProcessExitCode' -NotePropertyValue $code -Force
    return $value
}

function Get-AgentLineValue {
    param([object[]]$AgentLines, [string]$Key)

    foreach ($line in @($AgentLines)) {
        $prefix = 'AGENT: ' + $Key + '='
        if (([string]$line).StartsWith($prefix, [StringComparison]::Ordinal)) { return ([string]$line).Substring($prefix.Length) }
    }
    return $null
}

function Assert-AgentPlainText {
    param([string]$Text, [string]$Label, [ValidateSet('zh', 'en')][string]$Language = 'zh')

    $words = @(Get-W360MainUiBannedWords -Text $Text -Language $Language)
    # Words SKILL.md tells agents not to say, beyond the window's list (the summary's own "后台服务" and "错误代码" are allowed).
    foreach ($word in @('UAC', '管理员', '退出代码', 'exit code', 'hash', '哈希', 'JSON', 'SHA-256', '计划任务', 'scheduled task', '系统服务', 'Windows service')) {
        if ($Text.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $words += $word }
    }
    Assert-TestEqual -Expected 0 -Actual $words.Count -Message ("{0}: banned words {1} in:`r`n{2}" -f $Label, ($words -join ','), $Text)
    Assert-TestFalse -Condition ($Text -match '[A-Za-z]:\\') -Message "$Label shows a drive path."
    Assert-TestFalse -Condition ($Text -match '\\\\') -Message "$Label shows a network path."
    Assert-TestFalse -Condition ($Text -match 'S-1-5-') -Message "$Label shows a SID."
    Assert-TestFalse -Condition ($Text -match '(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])') -Message "$Label shows a 64-digit identity."
    foreach ($field in @('SelectionId', 'ProductKey', 'Confidence', 'Findings', 'Summary', '.json')) {
        Assert-TestFalse -Condition $Text.Contains($field) -Message "$Label shows the technical field $field."
    }
}

function Assert-AgentNoRemoveCommand {
    param([object]$Run, [string]$Label)

    Assert-TestFalse -Condition ($Run.Text -match '-Mode\s+Remove') -Message "$Label printed a Remove command."
    Assert-TestFalse -Condition ($Run.Text.Contains('REMOVE-CONFIRMED-360')) -Message "$Label printed the confirmation phrase."
    Assert-TestNull -Actual (Get-AgentLineValue -AgentLines $Run.AgentLines -Key 'run-only-after-the-user-explicitly-says-yes') -Message "$Label has a run line."
}

function New-AgentHex {
    param([int]$Seed)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('agent-fixture-' + $Seed)))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function New-AgentFinding {
    param(
        [string]$Name, [string]$Target, [string]$ProductKey = 'Duohui', [string]$Kind = 'Path',
        [string]$Confidence = 'Confirmed', [string]$RemovalType = 'Path', [string]$SelectionId = '', [string]$Reason = 'Known duohuipingbao installation path.'
    )
    if ($Confidence -ne 'Confirmed') { $RemovalType = 'None' }
    return [pscustomobject][ordered]@{
        Kind = $Kind; Name = $Name; Target = $Target; Confidence = $Confidence; Reason = $Reason
        RemovalType = $RemovalType; ValueName = ''; Offline = $false; ProductKey = $ProductKey; SelectionId = $SelectionId; IdentityFingerprint = ''
    }
}

function Write-AgentScanReport {
    param([string]$Directory, [object[]]$Findings, [bool]$IncludeBrowserProfiles = $false)

    $report = [pscustomobject][ordered]@{
        SchemaVersion = 2; ToolVersion = $script:W360ToolVersion; Timestamp = (Get-Date).ToString('o'); Mode = 'Scan'
        ComputerName = $null; User = $null; Summary = $null
        ApprovalContext = [pscustomobject]@{ UserSid = $script:AgentSid; Options = [pscustomobject]@{ IncludeBrowserProfiles = $IncludeBrowserProfiles } }
        ScanCoverage = [pscustomobject]@{ Complete = $true; Issues = @() }
        Findings = @($Findings); Actions = @()
    }
    $path = New-W360ReportPath -Directory $Directory -Kind 'scan'
    [IO.File]::WriteAllText($path, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    return $path
}

function New-AgentCase {
    param([string]$FixtureRoot, [string]$Name)

    $caseRoot = Join-Path $FixtureRoot ('代理 ' + $Name)
    $folders = [ordered]@{
        LocalAppData = Join-Path $caseRoot '本地 应用数据'; RoamingAppData = Join-Path $caseRoot '漫游 应用数据'
        ProgramFiles = Join-Path $caseRoot 'Program Files'; ProgramFilesX86 = Join-Path $caseRoot 'Program Files (x86)'
        ProgramData = Join-Path $caseRoot 'ProgramData'; UserProfile = Join-Path $caseRoot '用户 目录'
        Desktop = Join-Path $caseRoot '用户 目录\桌面'; Temp = Join-Path $caseRoot '临时 文件'; Windows = Join-Path $caseRoot 'Windows'
    }
    foreach ($path in $folders.Values) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $script:KnownFolders = $folders
    $script:CurrentUserRegistryRoot = 'HKCU:'
    $duohuiRoot = Join-Path $folders.LocalAppData 'dhpingbao'
    New-Item -ItemType Directory -Path $duohuiRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $duohuiRoot 'duohuipingbao.exe') -Value 'ISOLATED-DUOHUI'
    Set-Content -LiteralPath (Join-Path $duohuiRoot 'qcnethelp64.dll') -Value 'ISOLATED-DUOHUI-DLL'
    $vendor = Join-Path $duohuiRoot 'huabaosetup.exe'
    Set-Content -LiteralPath $vendor -Value 'ISOLATED-VENDOR'
    $duohuiTemp = Join-Path $folders.Temp 'duohuipingbao'
    New-Item -ItemType Directory -Path (Join-Path $duohuiTemp '360hb_tmp') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $duohuiTemp 'huabaosetup.exe') -Value 'ISOLATED-TEMP'
    $browserApplication = Join-Path $folders.RoamingAppData '360se6\Application'
    New-Item -ItemType Directory -Path $browserApplication -Force | Out-Null
    $browserExe = Join-Path $browserApplication '360se.exe'
    Set-Content -LiteralPath $browserExe -Value 'ISOLATED-BROWSER'
    $profile = Join-Path $folders.RoamingAppData '360se6\User Data'
    New-Item -ItemType Directory -Path $profile -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $profile 'Bookmarks') -Value 'KEEP-BOOKMARKS'
    Set-Content -LiteralPath (Join-Path $folders.Temp '360setup_1.cab') -Value 'ISOLATED-CAB'
    return [pscustomobject]@{
        Root = $caseRoot; Folders = $folders; DuohuiRoot = $duohuiRoot; Vendor = (Get-NormalPath $vendor)
        BrowserApplication = $browserApplication; BrowserExe = $browserExe; BrowserProfile = $profile; ReportDirectory = $folders.Desktop
    }
}

function New-AgentFake {
    param([object]$Case, [hashtable]$PathRemovals = @{})
    return (New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($Case.BrowserExe, $Case.Vendor) `
        -TrustedDuohuiVendorPaths @($Case.Vendor) -PathRemovals $PathRemovals)
}

function Invoke-AgentScan {
    param([object]$Case)

    $fake = New-AgentFake -Case $Case
    Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
    try { $findings = @(Get-360Findings); $coverage = Get-360ScanCoverage }
    finally { Reset-360CleanupRuntimeProvider }
    $findings = @(Add-CleanupSelectionIds -Findings $findings -UserSid $script:AgentSid)
    $reportPath = New-W360ReportPath -Directory $Case.ReportDirectory -Kind 'scan'
    Save-CleanupReport -Path $reportPath -RunMode 'Scan' -Findings $findings -Actions @() `
        -ApprovalContext ([pscustomobject]@{ UserSid = $script:AgentSid }) -ScanCoverage $coverage
    return [pscustomobject]@{ Findings = $findings; ReportPath = $reportPath }
}

function Invoke-AgentRemoval {
    param([object]$Case, [object]$Scan, [string[]]$SelectedIds, [string]$ReportPath, [scriptblock]$RemoveBehavior)

    $pathRemovals = @{}
    foreach ($finding in @($Scan.Findings)) { if ([string]$finding.RemovalType -eq 'Path') { $pathRemovals[[string]$finding.Target] = $RemoveBehavior } }
    $fake = New-AgentFake -Case $Case -PathRemovals $pathRemovals
    $hash = Get-W360FileSha256 -Path $Scan.ReportPath
    Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
    try {
        $current = @(Add-CleanupSelectionIds -Findings @(Get-360Findings) -UserSid $script:AgentSid)
        $comparison = Compare-ApprovedCleanupFindings -Approved $Scan.Findings -Current $current -SID $script:AgentSid
        $resolved = Resolve-CleanupSelection -Approved $Scan.Findings -Eligible @($comparison.Eligible) -Current $current `
            -SelectedIds $SelectedIds -UserSid $script:AgentSid -SelectionApplied $true
        $selection = New-360CleanupSelectionRecord -SelectionApplied $true -ApprovedReportPath $Scan.ReportPath `
            -ApprovedReportHash $hash -SelectedIds $SelectedIds -ResolvedSelection $resolved -ApprovalComparison $comparison -UserSid $script:AgentSid
        $summary = [ordered]@{}
        $actions = @(Remove-ConfirmedFindings -Findings @($resolved.Eligible) -Summary $summary)
        $remaining = @(Add-CleanupSelectionIds -Findings @(Get-360Findings) -UserSid $script:AgentSid)
        $coverage = Get-360ScanCoverage
        $remainingSelected = Complete-360CleanupRemovalSummary -Summary $summary -ApprovalComparison $comparison `
            -ResolvedSelection $resolved -SelectionRecord $selection -SelectionApplied $true -RescanComplete $true `
            -RemainingFindings $remaining -UserSid $script:AgentSid -ApprovedReportHash $hash
    }
    finally { Reset-360CleanupRuntimeProvider }
    Save-CleanupReport -Path $ReportPath -RunMode 'Remove' -Findings $remaining -Actions $actions -Summary $summary `
        -ApprovalContext ([pscustomobject]@{ UserSid = $script:AgentSid }) -ApprovedReportHash $hash `
        -OutcomeRunId ([Guid]::NewGuid().ToString('N')) -ScanCoverage $coverage -Selection $selection
    $exitCode = if (Test-RemovalOutcomeRequiresAttention -Summary $summary -RemainingConfirmed $remainingSelected) { 2 } else { 0 }
    return [pscustomobject]@{ ReportPath = $ReportPath; ExitCode = $exitCode; Fake = $fake }
}

function Invoke-AgentVerify {
    param([object]$Case, [string]$RemoveReportPath, [string]$ReportPath)

    $fake = New-AgentFake -Case $Case
    Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
    try {
        $findings = @(Add-CleanupSelectionIds -Findings @(Get-360Findings) -UserSid $script:AgentSid)
        $coverage = Get-360ScanCoverage
        $previous = Read-360CleanupPreviousRemoveReport -Path $RemoveReportPath -CurrentUserSid $script:AgentSid
        $task = Get-360CleanupTaskVerification -Previous $previous -CurrentFindings $findings -UserSid $script:AgentSid
    }
    finally { Reset-360CleanupRuntimeProvider }
    Save-CleanupReport -Path $ReportPath -RunMode 'Verify' -Findings $findings -Actions @() -ScanCoverage $coverage `
        -TaskVerification $task -IncludeTaskVerification $true
    return [pscustomobject]@{ ReportPath = $ReportPath; ExitCode = (Get-360CleanupVerifyExitCode -Findings $findings -Coverage $coverage -TaskVerification $task); Fake = $fake }
}

$run = New-TestRun -Name 'Agent summary tests'
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
    . ([IO.Path]::GetFullPath($libraryPath))
    Set-W360UiLanguage -Language 'zh'
    $fixtureRoot = New-TestDirectory
    $originalKnownFolders = $script:KnownFolders
    $originalRegistryRoot = $script:CurrentUserRegistryRoot

    Invoke-TestCase -Run $run -Name 'the summary script is read-only by construction and uses the PowerShell 5.1 source contract' -Test {
        Assert-TestPowerShellFileContract -Path $SummaryScriptPath
        Assert-TestPowerShellFileContract -Path $agentTestPath
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($SummaryScriptPath, [ref]$tokens, [ref]$parseErrors)
        $forbiddenCommands = @('Remove-Item', 'Start-Process', 'Invoke-Expression', 'iex', 'Set-ItemProperty', 'New-ItemProperty', 'Stop-Process',
            'Remove-ItemProperty', 'Unregister-ScheduledTask', 'Set-Service', 'Stop-Service', 'Restart-Computer', 'Stop-Computer', 'Start-Job',
            'Invoke-WebRequest', 'Invoke-RestMethod', 'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Copy-Item', 'Move-Item', 'Rename-Item',
            'Clear-Content', 'Add-Type', 'sc.exe', 'sc', 'reg.exe', 'reg', 'schtasks.exe', 'schtasks', 'taskkill', 'cmd.exe', 'cmd', 'powershell.exe',
            'Start-W360ChildProcess', 'Stop-W360ChildProcess', 'Remove-W360ProgressFile', 'Save-W360HelpSummary', 'Write-W360NewTextFile', 'New-W360TaskRecord',
            'Remove-ConfirmedFindings', 'Invoke-360CleanupRemoveElevationBoundary')
        $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        foreach ($command in $commands) {
            Assert-TestFalse -Condition ($forbiddenCommands -contains $command) -Message "The summary script calls the changing command $command."
        }
        $members = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
            ForEach-Object { [string]$_.Member.Extent.Text })
        foreach ($member in $members) {
            Assert-TestFalse -Condition (@('Start', 'Kill', 'Delete', 'WriteAllText', 'WriteAllBytes', 'Create', 'Move', 'Copy', 'SetValue', 'DeleteSubKey', 'DeleteSubKeyTree', 'AppendAllText') -contains $member) `
                -Message "The summary script invokes the changing method $member."
        }
        $code = (@($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
        foreach ($text in @('Diagnostics.Process', 'System.Windows.Forms', 'ProcessStartInfo', 'Microsoft.Win32.Registry', 'WebClient', 'Net.Http', 'Shutdown', 'Invoke-Item')) {
            Assert-TestFalse -Condition ($code.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0) -Message "The summary script mentions $text outside comments."
        }
        # The window shows the same confirmation list: both call the shared library function.
        $selectorSource = [IO.File]::ReadAllText($selectorPath, [Text.Encoding]::UTF8)
        Assert-TestTrue -Condition ($selectorSource.Contains('Get-W360ConfirmText')) -Message 'The window no longer uses the shared confirmation text.'
        Assert-TestTrue -Condition ($commands -contains 'Get-W360ConfirmText') -Message 'The summary script does not use the shared confirmation text.'
        foreach ($name in @('Get-W360DeletableSelection', 'Get-W360SelectionPlan', 'Get-W360RemoveOutcome', 'Get-W360VerifyOutcome', 'Get-W360FindingGroups')) {
            Assert-TestTrue -Condition ($commands -contains $name) -Message "The summary script does not use $name."
        }
    }

    Invoke-TestCase -Run $run -Name 'agent texts use plain words in both languages and every key is used' -Test {
        $source = [IO.File]::ReadAllText($SummaryScriptPath, [Text.Encoding]::UTF8)
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($SummaryScriptPath, [ref]$tokens, [ref]$parseErrors)
        $table = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:SummaryTexts' }, $true)
        Assert-TestNotNull -Actual $table -Message 'The agent text table was not found.'
        $texts = $table.Right.Expression.SafeGetValue()
        Assert-TestTrue -Condition ($texts.Count -ge 40) -Message ('Too few agent texts: ' + $texts.Count)
        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($key in @($texts.Keys | Sort-Object)) {
            $pair = @($texts[$key])
            if (-not ([string]$key).StartsWith('Agent.', [StringComparison]::Ordinal)) { $violations.Add("$key has no Agent. prefix.") }
            if ([string]::IsNullOrWhiteSpace([string]$pair[0]) -or [string]::IsNullOrWhiteSpace([string]$pair[1])) { $violations.Add("$key misses a language.") }
            foreach ($word in @(Get-W360MainUiBannedWords -Text ([string]$pair[0]) -Language zh)) { $violations.Add("[zh] $key contains $word") }
            foreach ($word in @(Get-W360MainUiBannedWords -Text ([string]$pair[1]) -Language en)) { $violations.Add("[en] $key contains $word") }
            foreach ($language in 0, 1) {
                if ([string]$pair[$language] -match '全选|(?i)select all|勾选|(?i)\btick') { $violations.Add("$key uses window-only or select-all wording.") }
                if ([string]$pair[$language] -match '(?i)exit code|退出代码|hash|哈希|SelectionId|registry|注册表') { $violations.Add("$key uses a technical word.") }
            }
            $zhPlaceholders = @([regex]::Matches([string]$pair[0], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            $enPlaceholders = @([regex]::Matches([string]$pair[1], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            if ($zhPlaceholders -ne $enPlaceholders) { $violations.Add("$key has different placeholders.") }
            $uses = [regex]::Matches($source, [regex]::Escape("'" + $key + "'")).Count
            $prefixUse = ([string]$key).StartsWith('Agent.Delete.SkipReason.', [StringComparison]::Ordinal) -and $source.Contains("'Agent.Delete.SkipReason.' +")
            if ($uses -lt 2 -and -not $prefixUse) { $violations.Add("$key is defined but never used.") }
        }
        foreach ($code in @('ParentContainsProtectedChild', 'ParentContainsSelectableChild', 'VendorUninstallerNeedsInstallRoot')) {
            if (-not $texts.Contains('Agent.Delete.SkipReason.' + $code)) { $violations.Add("No agent skip reason for $code.") }
        }
        Assert-TestEqual -Expected 0 -Actual $violations.Count -Message ("Agent text violations:`r`n" + ($violations.ToArray() -join "`r`n"))
    }

    Invoke-TestCase -Run $run -Name 'a real Scan report is numbered stably and told in plain words without technical details' -Test {
        $case = New-AgentCase -FixtureRoot $fixtureRoot -Name 'scan'
        $scan = Invoke-AgentScan -Case $case
        $before = @(Get-ChildItem -LiteralPath $case.ReportDirectory -Force | ForEach-Object { $_.Name } | Sort-Object)
        $text = Invoke-AgentSummary -Arguments @{ Report = $scan.ReportPath }
        Assert-TestEqual -Expected 0 -Actual $text.ExitCode -Message 'The scan summary did not succeed.'
        Assert-AgentPlainText -Text $text.UserText -Label 'Scan text'
        Assert-TestTrue -Condition ($text.UserText.StartsWith('检查完了（检查不会删除任何东西）。找到 2 个可以删除的 360 软件：')) -Message ("The scan text opening changed:`r`n" + $text.UserText)
        Assert-TestTrue -Condition ($text.UserText.Contains('要删除哪几个？')) -Message 'The scan text does not ask which to delete.'
        Assert-TestTrue -Condition ($text.UserText.Contains('这些不删除：')) -Message 'The kept products are not listed separately.'
        Assert-TestTrue -Condition ($text.UserText.Contains('不删除：书签和历史记录（这是你的个人资料）')) -Message 'The kept bookmarks are not named.'
        Assert-TestTrue -Condition ($text.AgentLines.Count -ge 3) -Message 'The AGENT lines are missing.'
        Assert-TestEqual -Expected (Get-FileHash -LiteralPath $scan.ReportPath -Algorithm SHA256).Hash -Actual ([regex]::Match($text.AgentLines[0], 'report-sha256=([0-9A-F]{64})').Groups[1].Value) `
            -Message 'The scan AGENT line has the wrong report hash.'

        $json = Invoke-AgentSummaryJson -Arguments @{ Report = $scan.ReportPath }
        $groups = @(Get-W360FindingGroups -Findings $scan.Findings)
        $expected = @(@($groups | Where-Object { [int]$_.SelectableCount -gt 0 }) + @($groups | Where-Object { [int]$_.SelectableCount -eq 0 }) | ForEach-Object { [string]$_.Key })
        Assert-TestSequenceEqual -Expected $expected -Actual @($json.Groups | ForEach-Object { [string]$_.ProductKey }) -Message 'The numbering does not follow the window order with deletable products first.'
        Assert-TestSequenceEqual -Expected @(1..$expected.Count) -Actual @($json.Groups | ForEach-Object { [int]$_.Number }) -Message 'The numbers are not 1..N.'
        Assert-TestEqual -Expected $text.UserText -Actual ([string]$json.Text) -Message 'The JSON text differs from the plain text.'
        $browser = @($json.Groups | Where-Object { $_.ProductKey -eq '360SafeBrowser' })[0]
        Assert-TestTrue -Condition ([bool]$browser.MayStillBeInUse) -Message 'The browser is not marked as something the user may still use.'

        # The same findings in another order give the same numbers.
        $reportValue = Read-W360JsonFile -Path $scan.ReportPath
        $reportValue.Findings = @($reportValue.Findings)[(@($reportValue.Findings).Count - 1)..0]
        $reorderedPath = New-W360ReportPath -Directory $case.ReportDirectory -Kind 'scan'
        [IO.File]::WriteAllText($reorderedPath, ($reportValue | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $reordered = Invoke-AgentSummaryJson -Arguments @{ Report = $reorderedPath }
        Assert-TestSequenceEqual -Expected @($json.Groups | ForEach-Object { '{0}:{1}' -f $_.Number, $_.ProductKey }) -Actual @($reordered.Groups | ForEach-Object { '{0}:{1}' -f $_.Number, $_.ProductKey }) `
            -Message 'The numbers depend on the order of the findings.'

        $english = Invoke-AgentSummary -Arguments @{ Report = $scan.ReportPath; Language = 'en' }
        Assert-AgentPlainText -Text $english.UserText -Label 'English scan text' -Language en
        Assert-TestTrue -Condition ($english.UserText.Contains('Which ones should be deleted?')) -Message 'The English scan text does not ask.'

        $after = @(Get-ChildItem -LiteralPath $case.ReportDirectory -Force | Where-Object { $_.FullName -ne $reorderedPath } | ForEach-Object { $_.Name } | Sort-Object)
        Assert-TestSequenceEqual -Expected $before -Actual $after -Message 'The summary script wrote a file next to the report.'
    }

    Invoke-TestCase -Run $run -Name 'numbers follow the window product order, deletable products first, whatever the findings order' -Test {
        $directory = Join-Path $fixtureRoot 'synthetic numbering'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $offline = New-AgentFinding -Name 'Offline Windows 360 path' -Target 'F:\Program Files\360' -ProductKey 'OfflineWindows' -Kind 'OfflinePath' -Confidence 'ReviewOnly' -Reason 'Found in another Windows installation; the bundled script is permanently scan-only for offline roots.'
        $offline.Offline = $true
        $findings = @(
            $offline,
            (New-AgentFinding -Name '360 temporary package' -Target 'C:\Users\Fixture\AppData\Local\Temp\360setup.cab' -ProductKey '360Temp' -Confidence 'ReviewOnly' -Reason 'Filename pattern matched, but a CAB name alone is not enough evidence for automatic deletion.'),
            (New-AgentFinding -Name 'Unattributed leftover' -Target 'C:\Users\Fixture\AppData\Local\Unattributed360' -ProductKey 'Unattributed' -SelectionId (New-AgentHex 21)),
            (New-AgentFinding -Name '360GameAssistant' -Target 'C:\Users\Fixture\AppData\Roaming\360GameAssistant' -ProductKey '360GameAssistant' -SelectionId (New-AgentHex 22) -Reason 'Exact current-user path with local 360/Qihoo file evidence.'),
            (New-AgentFinding -Name 'winToolBox updater linked to confirmed SoftMgr bundle' -Target 'C:\Users\Fixture\AppData\Local\winToolBox\updater.exe' -ProductKey 'WinToolBox360' -SelectionId (New-AgentHex 23) -Reason 'Exact third-party updater associated with a locally confirmed 360 SoftMgr/download chain.'),
            (New-AgentFinding -Name 'Roaming SoftMgr cache' -Target 'C:\Users\Fixture\AppData\Roaming\SoftMgr' -ProductKey '360SoftMgr' -SelectionId (New-AgentHex 24) -Reason 'Paired with confirmed 360 SoftMgr evidence.')
        )
        $expected = @('1:360SoftMgr', '2:WinToolBox360', '3:360GameAssistant', '4:Unattributed', '5:360Temp', '6:OfflineWindows')
        foreach ($order in @('as-is', 'reversed')) {
            $ordered = if ($order -eq 'reversed') { @($findings)[($findings.Count - 1)..0] } else { @($findings) }
            $path = Write-AgentScanReport -Directory $directory -Findings $ordered
            $json = Invoke-AgentSummaryJson -Arguments @{ Report = $path }
            Assert-TestSequenceEqual -Expected $expected -Actual @($json.Groups | ForEach-Object { '{0}:{1}' -f $_.Number, $_.ProductKey }) -Message "The numbering ($order) does not follow the window product order."
            $text = Invoke-AgentSummary -Arguments @{ Report = $path }
            Assert-TestEqual -Expected '1:360SoftMgr(can-delete),2:WinToolBox360(can-delete),3:360GameAssistant(can-delete),4:Unattributed(can-delete),5:360Temp(keep),6:OfflineWindows(keep)' `
                -Actual ([string](Get-AgentLineValue -AgentLines $text.AgentLines -Key 'groups')) -Message "The AGENT groups line ($order) is wrong."
            Assert-TestEqual -Expected '1,2,3' -Actual ([string](Get-AgentLineValue -AgentLines $text.AgentLines -Key 'ask-if-still-used')) -Message "The ask-first products ($order) are wrong."
            Assert-TestEqual -Expected '4' -Actual ([string](Get-AgentLineValue -AgentLines $text.AgentLines -Key 'do-not-suggest')) -Message "The products without a suggestion ($order) are wrong."
            Assert-TestTrue -Condition ($text.UserText.Contains('4. 说不清属于哪个 360 软件 —— 可以删除（1 项）') -and $text.UserText.Contains('6. 其他 Windows 系统里的内容 —— 不删除：在另一个 Windows 系统里')) `
                -Message ("The numbered lines ($order):`r`n" + $text.UserText)
            # A deletable item of an unclear product matched the detection; it is not described as "only the name looks like 360".
            Assert-TestTrue -Condition ($text.UserText.Contains('是什么：' + (Get-SummaryTestText -Key 'Agent.Scan.UnattributedWhat'))) -Message ("The unclear deletable product is described as a guess:`r`n" + $text.UserText)
            Assert-AgentPlainText -Text $text.UserText -Label "Synthetic numbering text ($order)"

            # Every number printed in the text is exactly the product -Delete takes for that number.
            foreach ($group in @($json.Groups)) {
                $number = [int]$group.Number
                $lineMatch = [regex]::Match($text.UserText, '(?m)^' + $number + '\. (.+?) —— ')
                Assert-TestTrue -Condition $lineMatch.Success -Message "Number $number is not printed ($order)."
                Assert-TestEqual -Expected ([string]$group.DisplayName) -Actual $lineMatch.Groups[1].Value -Message "The printed name of number $number ($order) is not its product."
                $deleteRun = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $path -Choice ([string]$number))
                Assert-TestSequenceEqual -Expected @($number) -Actual @($deleteRun.ChosenNumbers) -Message "-Delete $number ($order) chose other numbers."
                if ([bool]$group.CanDelete) {
                    Assert-TestTrue -Condition ([bool]$deleteRun.Accepted) -Message "-Delete $number ($order) was refused."
                    Assert-TestSequenceEqual -Expected @($group.SelectionIds) -Actual @($deleteRun.SelectedIds) -Message "-Delete $number ($order) took items of another product."
                    Assert-TestTrue -Condition ([string]$deleteRun.Text).Contains('● ' + [string]$group.DisplayName) -Message ("-Delete $number ($order) confirms another product:`r`n" + $deleteRun.Text)
                }
                else {
                    Assert-TestEqual -Expected 3 -Actual ([int]$deleteRun.ProcessExitCode) -Message "-Delete $number ($order) of a kept product was not refused."
                    Assert-TestTrue -Condition ([string]$deleteRun.Text).Contains(('{0}. {1} 不删除' -f $number, [string]$group.DisplayName)) -Message ("-Delete $number ($order) names another product:`r`n" + $deleteRun.Text)
                    $selectedProperty = $deleteRun.PSObject.Properties['SelectedIds']
                    Assert-TestTrue -Condition ($null -eq $selectedProperty -or @($selectedProperty.Value | Where-Object { $_ }).Count -eq 0) -Message "-Delete $number ($order) selected a kept item."
                }
            }
        }
    }

    Invoke-TestCase -Run $run -Name 'no matches and not fully checked stay different' -Test {
        $directory = Join-Path $fixtureRoot 'empty scans'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $clean = Write-AgentScanReport -Directory $directory -Findings @()
        $cleanRun = Invoke-AgentSummary -Arguments @{ Report = $clean }
        Assert-TestEqual -Expected '检查完了（检查不会删除任何东西）。没有找到 360 的内容。' -Actual $cleanRun.UserText -Message 'The no-match text changed.'
        $value = Read-W360JsonFile -Path $clean
        $value.ScanCoverage = [pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'Services'; Target = ''; Detail = 'Simulated' }) }
        $incomplete = New-W360ReportPath -Directory $directory -Kind 'scan'
        [IO.File]::WriteAllText($incomplete, ($value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $incompleteRun = Invoke-AgentSummary -Arguments @{ Report = $incomplete }
        Assert-TestTrue -Condition ($incompleteRun.UserText.Contains('有些地方没检查完') -and $incompleteRun.UserText.Contains('后台服务')) -Message ("The incomplete no-match text is not distinct:`r`n" + $incompleteRun.UserText)
        Assert-AgentPlainText -Text $incompleteRun.UserText -Label 'Incomplete no-match text'
    }

    Invoke-TestCase -Run $run -Name '-Delete selects exactly the shrink-only deletable set and binds the report file hash' -Test {
        $case = New-AgentCase -FixtureRoot $fixtureRoot -Name 'delete'
        $scan = Invoke-AgentScan -Case $case
        $numbers = Invoke-AgentSummaryJson -Arguments @{ Report = $scan.ReportPath }
        $numberOf = @{}
        foreach ($group in @($numbers.Groups)) { $numberOf[[string]$group.ProductKey] = [int]$group.Number }
        foreach ($choice in @([string]$numberOf['Duohui'], [string]$numberOf['360SafeBrowser'], ('{0},{1}' -f $numberOf['360SafeBrowser'], $numberOf['Duohui']), 'all')) {
            $json = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice $choice)
            Assert-TestEqual -Expected 0 -Actual $json.ProcessExitCode -Message "-Delete $choice was not accepted."
            Assert-TestTrue -Condition ([bool]$json.Accepted) -Message "-Delete $choice is not marked accepted."
            $chosen = @($numbers.Groups | Where-Object { @($json.ChosenNumbers) -contains [int]$_.Number })
            if ($choice -eq 'all') {
                Assert-TestSequenceEqual -Expected @($numbers.Groups | Where-Object { [bool]$_.CanDelete } | ForEach-Object { [int]$_.Number }) -Actual @($json.ChosenNumbers) `
                    -Message '"all" did not mean exactly the products that can be deleted.'
            }
            $candidates = @($chosen | ForEach-Object { @($_.SelectionIds) } | Where-Object { $_ })
            $expected = Get-W360DeletableSelection -Findings $scan.Findings -CandidateIds $candidates -SelectedIds @()
            Assert-TestSequenceEqual -Expected @($expected.Ids) -Actual @($json.SelectedIds) -Message "-Delete $choice differs from the shrink-only helper."
            foreach ($id in @($json.SelectedIds)) {
                $finding = @($scan.Findings | Where-Object { [string]$_.SelectionId -eq $id })
                Assert-TestTrue -Condition ($finding.Count -eq 1 -and (Test-W360FindingSelectable -Finding $finding[0])) -Message "-Delete $choice selected a non-deletable item."
            }
            $text = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice $choice)
            Assert-AgentPlainText -Text $text.UserText -Label "-Delete $choice text"
            $command = Get-AgentLineValue -AgentLines $text.AgentLines -Key 'run-only-after-the-user-explicitly-says-yes'
            Assert-TestNotNull -Actual $command -Message "-Delete $choice has no Remove command."
            $fileHash = (Get-FileHash -LiteralPath $scan.ReportPath -Algorithm SHA256).Hash
            Assert-TestEqual -Expected $fileHash -Actual ([regex]::Match($command, '-ApprovedReportHash ([0-9A-F]{64}) ').Groups[1].Value) -Message 'The command hash is not the SHA-256 of the report file.'
            # The result summary is bound to the same approval.
            $afterRemove = [string](Get-AgentLineValue -AgentLines $text.AgentLines -Key 'after-remove')
            Assert-TestTrue -Condition ($afterRemove.Contains('-ScanReportHash ' + $fileHash + ' ')) -Message ('The after-remove command is not bound to the approved scan: ' + $afterRemove)
            Assert-TestEqual -Expected (@($json.SelectedIds) -join ';') -Actual ([regex]::Match($command, '-SelectedFindingIds "([^"]+)"').Groups[1].Value) -Message 'The command IDs differ from the selection.'
            Assert-TestEqual -Expected ([IO.Path]::GetFullPath($scan.ReportPath)) -Actual ([regex]::Match($command, '-ApprovedReport "([^"]+)"').Groups[1].Value) -Message 'The command names another report.'
            Assert-TestEqual -Expected $CleanerScriptPath -Actual ([regex]::Match($command, '-File "([^"]+)"').Groups[1].Value) -Message 'The command runs another script.'
            foreach ($part in @('-Mode Remove', '-ConfirmRemoval', '-ConfirmationPhrase REMOVE-CONFIRMED-360', '-ReportPath "')) {
                Assert-TestTrue -Condition $command.Contains($part) -Message "The Remove command misses $part."
            }
            foreach ($forbidden in @('-IncludeBrowserProfiles', '-AllowExplorerRestart', '-ForceLockedTargets', '-InternalElevatedChild')) {
                Assert-TestFalse -Condition $command.Contains($forbidden) -Message "The Remove command adds $forbidden."
            }
            $removePath = [regex]::Match($command, '-ReportPath "([^"]+)"').Groups[1].Value
            Assert-TestFalse -Condition (Test-Path -LiteralPath $removePath) -Message 'The planned Remove report path already exists.'
            # The same list the window's confirmation dialog shows.
            $plan = Get-W360SelectionPlan -Findings $scan.Findings -SelectedIds @($json.SelectedIds)
            $confirm = Get-W360ConfirmText -Plan $plan -AllFindings $scan.Findings
            Assert-TestTrue -Condition ($text.UserText.Contains($confirm)) -Message "-Delete $choice does not show the shared confirmation list."
            foreach ($part in @('删除后不能恢复，也不会放进回收站。', '删除前请先关闭 360 的软件', '请点“是”', '确定要删除吗？回复“确定删除”我再开始。')) {
                Assert-TestTrue -Condition ($text.UserText.Contains($part)) -Message "-Delete $choice text misses '$part'."
            }
            Assert-TestEqual -Expected ([bool]$plan.VendorUninstallerSelected) -Actual ($text.UserText.Contains((Get-W360Text -Key 'Ui.Confirm.VendorWarning'))) -Message "-Delete $choice uninstaller warning does not follow the plan."
        }
        $keepNumber = [int]@($numbers.Groups | Where-Object { -not [bool]$_.CanDelete })[0].Number
        $profileFinding = @($scan.Findings | Where-Object { $_.Target -eq (Get-NormalPath $case.BrowserProfile) })[0]
        $browserRun = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice ([string]$numberOf['360SafeBrowser']))
        Assert-TestFalse -Condition (@($browserRun.SelectedIds) -contains [string]$profileFinding.SelectionId -and -not [string]::IsNullOrEmpty([string]$profileFinding.SelectionId)) -Message 'The kept browser profile was selected.'

        # Editing the report file changes the bound hash: it is the file SHA-256, not a value copied from the report.
        $copy = New-W360ReportPath -Directory $case.ReportDirectory -Kind 'scan'
        [IO.File]::WriteAllText($copy, ([IO.File]::ReadAllText($scan.ReportPath, [Text.Encoding]::UTF8) + "`r`n"), (New-Object Text.UTF8Encoding($false)))
        $copyRun = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $copy -Choice ([string]$numberOf['Duohui']))
        $copyHash = [regex]::Match([string](Get-AgentLineValue -AgentLines $copyRun.AgentLines -Key 'run-only-after-the-user-explicitly-says-yes'), '-ApprovedReportHash ([0-9A-F]{64}) ').Groups[1].Value
        Assert-TestEqual -Expected (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -Actual $copyHash -Message 'The edited report was bound to a stale hash.'
        Assert-TestFalse -Condition ($copyHash -eq (Get-FileHash -LiteralPath $scan.ReportPath -Algorithm SHA256).Hash) -Message 'An edited report produced the original hash.'
        Assert-TestFalse -Condition ([IO.File]::ReadAllText($copy, [Text.Encoding]::UTF8).Contains($copyHash)) -Message 'The bound hash appears inside the report content.'

        # Product keys match exactly (case aside); a part of a key, a longer key or a word never picks a product.
        foreach ($case2 in @(
                @{ Choice = '99'; Reason = 'UnknownNumber'; Text = '没有“99”这个编号' },
                @{ Choice = ('{0},99' -f $numberOf['Duohui']); Reason = 'UnknownNumber'; Text = '没有“99”这个编号' },
                @{ Choice = 'NoSuchProduct'; Reason = 'UnknownNumber'; Text = '没有“NoSuchProduct”这个编号' },
                @{ Choice = '360'; Reason = 'UnknownNumber'; Text = '没有“360”这个编号' },
                @{ Choice = '360s'; Reason = 'UnknownNumber'; Text = '没有“360s”这个编号' },
                @{ Choice = 'Duo'; Reason = 'UnknownNumber'; Text = '没有“Duo”这个编号' },
                @{ Choice = '360SafeBrowserX'; Reason = 'UnknownNumber'; Text = '没有“360SafeBrowserX”这个编号' },
                @{ Choice = '1 和 2'; Reason = 'UnknownNumber'; Text = '没有“和”这个编号' },
                @{ Choice = [string]$keepNumber; Reason = 'OnlyKept'; Text = '选的这些都不删除' },
                @{ Choice = ' , '; Reason = 'NoChoice'; Text = '还没说要删除哪几个' })) {
            $rejected = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice $case2.Choice)
            Assert-TestEqual -Expected 3 -Actual $rejected.ExitCode -Message ('-Delete {0} was not refused.' -f $case2.Choice)
            Assert-AgentNoRemoveCommand -Run $rejected -Label ('-Delete ' + $case2.Choice)
            Assert-TestTrue -Condition ($rejected.UserText.Contains($case2.Text) -and $rejected.UserText.Contains('没有删除任何东西。')) -Message ("-Delete {0} text:`r`n{1}" -f $case2.Choice, $rejected.UserText)
            Assert-TestTrue -Condition ($rejected.AgentLines[0].Contains('reason=' + $case2.Reason)) -Message ('-Delete {0} reason: {1}' -f $case2.Choice, $rejected.AgentLines[0])
            Assert-AgentPlainText -Text $rejected.UserText -Label ('-Delete ' + $case2.Choice)
        }
        $exactKey = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice 'duohui')
        Assert-TestSequenceEqual -Expected @($numberOf['Duohui']) -Actual @($exactKey.ChosenNumbers) -Message 'The exact product key (any case) was not accepted.'
        # A number typed with a Chinese input method is the same number.
        $fullWidth = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice ([string][char](0xFF10 + $numberOf['Duohui'])))
        Assert-TestEqual -Expected 0 -Actual ([int]$fullWidth.ProcessExitCode) -Message 'A full-width number was not accepted.'
        Assert-TestSequenceEqual -Expected @($numberOf['Duohui']) -Actual @($fullWidth.ChosenNumbers) -Message 'A full-width number chose another product.'
        $mixed = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice ('{0},{1}' -f $numberOf['Duohui'], $keepNumber))
        Assert-TestTrue -Condition ([bool]$mixed.Accepted) -Message 'A deletable product with a kept product was refused.'
        Assert-TestTrue -Condition ([string]$mixed.Text).Contains('没有算进去') -Message 'The kept product was not said to be left out.'

        # Values outside any parameter ("-Delete 1 2") are refused in plain words, never guessed and never a raw error.
        $global:LASTEXITCODE = 0
        $loose = ConvertTo-AgentRun -Lines @(& $SummaryScriptPath -Report $scan.ReportPath -ScanReportHash (Get-AgentReportHash -Path $scan.ReportPath) -Delete ([string]$numberOf['Duohui']) ([string]$numberOf['360SafeBrowser'])) -ExitCode $global:LASTEXITCODE
        Assert-TestEqual -Expected 2 -Actual $loose.ExitCode -Message 'Loose extra values were accepted.'
        Assert-AgentNoRemoveCommand -Run $loose -Label 'Loose extra values'
        Assert-TestEqual -Expected (Get-SummaryTestText -Key 'Agent.BadArguments') -Actual $loose.UserText -Message 'Loose extra values are not told in plain words.'
        Assert-TestTrue -Condition ($loose.AgentLines[0].Contains('-Delete 1,2')) -Message ('The agent is not told how to pass several numbers: ' + $loose.AgentLines[0])
    }

    Invoke-TestCase -Run $run -Name '-Delete is bound to the Scan summary the user answered and to a Scan that ended normally' -Test {
        $directory = Join-Path $fixtureRoot 'bound deletes'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $browser = New-AgentFinding -Name '360se6 browser application' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser' -SelectionId (New-AgentHex 41) -Reason 'Exact 360se6 Application directory with local 360/Qihoo file evidence.'
        $duohui = New-AgentFinding -Name 'Duohui temporary package' -Target 'C:\Users\Fixture\AppData\Local\Temp\duohuipingbao' -SelectionId (New-AgentHex 42) -Reason 'Known duohuipingbao staging path.'
        # The first check shows 1 = browser, 2 = screen saver. The user uninstalls the browser normally and the agent
        # checks again: now 1 = screen saver. The earlier "delete 1" must never be applied to the new result.
        $first = Write-AgentScanReport -Directory $directory -Findings @($browser, $duohui)
        $second = Write-AgentScanReport -Directory $directory -Findings @($duohui)
        $firstRun = Invoke-AgentSummary -Arguments @{ Report = $first }
        $firstHash = [regex]::Match($firstRun.AgentLines[0], 'report-sha256=([0-9A-F]{64})').Groups[1].Value
        Assert-TestEqual -Expected (Get-AgentReportHash -Path $first) -Actual $firstHash -Message 'The first summary has the wrong hash.'
        $command = [string](Get-AgentLineValue -AgentLines $firstRun.AgentLines -Key 'after-the-user-names-numbers')
        Assert-TestTrue -Condition ($command.Contains('-ScanReportHash ' + $firstHash + ' ') -and $command.Contains('-Report "' + $first + '"')) -Message ('The -Delete command is not bound to the summary: ' + $command)

        $changed = Invoke-AgentSummary -Arguments @{ Report = $second; Delete = @('1'); ScanReportHash = $firstHash }
        Assert-TestEqual -Expected 3 -Actual $changed.ExitCode -Message 'Numbers of another check result were accepted.'
        Assert-AgentNoRemoveCommand -Run $changed -Label 'Another check result'
        Assert-TestTrue -Condition ($changed.AgentLines[0].Contains('reason=ReportChanged')) -Message ('The changed result reason: ' + $changed.AgentLines[0])
        Assert-TestTrue -Condition ($changed.UserText.StartsWith((Get-SummaryTestText -Key 'Agent.Delete.ReportChanged'))) -Message ("The changed result text:`r`n" + $changed.UserText)
        Assert-TestTrue -Condition ([string](Get-AgentLineValue -AgentLines $changed.AgentLines -Key 'show-the-new-list')).Contains('-Report "' + $second + '"') -Message 'The agent is not told to show the new list.'
        Assert-AgentPlainText -Text $changed.UserText -Label 'Changed result text'

        foreach ($missingHash in @($null, '', '<report-sha256>', 'ABC')) {
            $arguments = @{ Report = $first; Delete = @('1') }
            if ($null -ne $missingHash) { $arguments['ScanReportHash'] = $missingHash }
            $unbound = Invoke-AgentSummary -Arguments $arguments
            Assert-TestEqual -Expected 2 -Actual $unbound.ExitCode -Message ('-Delete without a usable -ScanReportHash ({0}) gave a result.' -f $missingHash)
            Assert-AgentNoRemoveCommand -Run $unbound -Label '-Delete without -ScanReportHash'
            Assert-TestTrue -Condition ($unbound.AgentLines[0].Contains('reason=NeedScanReportHash')) -Message ('The missing hash reason: ' + $unbound.AgentLines[0])
            Assert-TestTrue -Condition ($unbound.UserText.Contains('没有删除任何东西。')) -Message 'The missing hash text does not say that nothing was deleted.'
        }
        $bound = Invoke-AgentSummaryJson -Arguments @{ Report = $first; Delete = @('1'); ScanReportHash = $firstHash.ToLowerInvariant() }
        Assert-TestTrue -Condition ([bool]$bound.Accepted) -Message 'The matching hash (any case) was refused.'

        # A Scan whose command did not end normally is never used to delete, and its summary says it cannot be used.
        foreach ($code in @('1', '-1', 'unknown', '3221225786')) {
            $failedScan = Invoke-AgentSummary -Arguments @{ Report = $first; ExitCode = $code }
            Assert-TestTrue -Condition ($failedScan.UserText.Contains((Get-SummaryTestText -Key 'Agent.Scan.Unusable'))) -Message ("Scan exit code $code was ignored:`r`n" + $failedScan.UserText)
            Assert-TestNull -Actual (Get-AgentLineValue -AgentLines $failedScan.AgentLines -Key 'after-the-user-names-numbers') -Message "Scan exit code $code still offers deleting."
            $failedDelete = Invoke-AgentSummary -Arguments @{ Report = $first; Delete = @('1'); ScanReportHash = $firstHash; ExitCode = $code }
            Assert-TestEqual -Expected 3 -Actual $failedDelete.ExitCode -Message "-Delete after Scan exit code $code was accepted."
            Assert-AgentNoRemoveCommand -Run $failedDelete -Label "-Delete after Scan exit code $code"
        }
        $invalidCode = Invoke-AgentSummary -Arguments @{ Report = $first; Delete = @('1'); ScanReportHash = $firstHash; ExitCode = '<exit code>' }
        Assert-TestEqual -Expected 2 -Actual $invalidCode.ExitCode -Message 'An invalid Scan exit code was accepted.'
        Assert-AgentNoRemoveCommand -Run $invalidCode -Label 'Invalid Scan exit code'

        # Findings with checks that did not finish still say so next to the list.
        $value = Read-W360JsonFile -Path $first
        $value.ScanCoverage = [pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'Services'; Target = ''; Detail = 'Simulated' }, [pscustomobject]@{ Area = 'ScheduledTasks'; Target = ''; Detail = 'Simulated' }) }
        $incomplete = New-W360ReportPath -Directory $directory -Kind 'scan'
        [IO.File]::WriteAllText($incomplete, ($value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $incompleteRun = Invoke-AgentSummary -Arguments @{ Report = $incomplete }
        $coverageText = Get-SummaryTestText -Key 'Agent.Scan.Coverage' -Arguments @(((Get-W360Text -Key 'Coverage.Services') + (Get-W360Text -Key 'Common.ListSeparator') + (Get-W360Text -Key 'Coverage.ScheduledTasks')))
        Assert-TestTrue -Condition ($incompleteRun.UserText.Contains($coverageText) -and $incompleteRun.UserText.Contains('要删除哪几个？')) -Message ("The not-fully-checked line is missing next to findings:`r`n" + $incompleteRun.UserText)
        Assert-TestTrue -Condition ($incompleteRun.AgentLines[0].Contains('coverage-complete=false')) -Message 'The AGENT line hides the incomplete check.'
        Assert-AgentPlainText -Text $incompleteRun.UserText -Label 'Incomplete findings text'
    }

    Invoke-TestCase -Run $run -Name 'commands are never printed with paths that a shell would change' -Test {
        # Quote, line break, $, backtick, % and ! are refused by the quoting helper itself.
        . (Import-AgentQuotingHelpers)
        Assert-TestEqual -Expected '"C:\Users\me\Desktop\360-cleanup-scan-1.json"' -Actual (Format-SummaryQuoted -Value 'C:\Users\me\Desktop\360-cleanup-scan-1.json') -Message 'A normal path is not quoted.'
        foreach ($bad in @('C:\a"b', "C:\a`r`nb", 'C:\me$HOME', 'C:\me`tail', 'C:\100%\x', 'C:\wow!\x')) {
            Assert-TestThrows -Operation { Format-SummaryQuoted -Value $bad } -Message ('An unsafe path was quoted: ' + $bad)
        }

        $case = New-AgentCase -FixtureRoot $fixtureRoot -Name 'unsafe'
        $scan = Invoke-AgentScan -Case $case
        $unsafeDirectory = Join-Path $fixtureRoot 'me$HOME`tail 100%'
        [void][IO.Directory]::CreateDirectory($unsafeDirectory)
        $unsafeScan = Join-Path $unsafeDirectory ([IO.Path]::GetFileName($scan.ReportPath))
        [IO.File]::Copy($scan.ReportPath, $unsafeScan)
        $scanRun = Invoke-AgentSummary -Arguments @{ Report = $unsafeScan }
        Assert-TestEqual -Expected 0 -Actual $scanRun.ExitCode -Message 'The list was not shown for an unsafe folder.'
        Assert-TestNull -Actual (Get-AgentLineValue -AgentLines $scanRun.AgentLines -Key 'after-the-user-names-numbers') -Message 'A -Delete command was printed for an unsafe folder.'
        Assert-TestTrue -Condition ($scanRun.UserText.Contains((Get-SummaryTestText -Key 'Agent.UseWindow')) -and -not $scanRun.UserText.Contains('要删除哪几个？')) -Message ("The unsafe folder text:`r`n" + $scanRun.UserText)
        Assert-TestTrue -Condition ($null -ne (Get-AgentLineValue -AgentLines $scanRun.AgentLines -Key 'unsafe-path')) -Message 'The agent is not told why no command is printed.'
        $deleteRun = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $unsafeScan -Choice 'all')
        Assert-TestEqual -Expected 3 -Actual $deleteRun.ExitCode -Message '-Delete in an unsafe folder was accepted.'
        Assert-AgentNoRemoveCommand -Run $deleteRun -Label 'Unsafe folder'
        foreach ($line in @($scanRun.AgentLines + $deleteRun.AgentLines)) {
            Assert-TestFalse -Condition (([string]$line).Contains('powershell.exe')) -Message ('A command was printed for an unsafe folder: ' + $line)
        }
        Assert-AgentPlainText -Text $deleteRun.UserText -Label 'Unsafe folder text'
    }

    Invoke-TestCase -Run $run -Name '-Delete explains skipped items, refuses too many items and never takes items that are not deleted' -Test {
        $directory = Join-Path $fixtureRoot 'synthetic deletes'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $root = 'C:\Users\Fixture\AppData\Local\dhpingbao'
        $findings = @(
            (New-AgentFinding -Name 'Duohui screen saver' -Target $root -SelectionId (New-AgentHex 1)),
            (New-AgentFinding -Name 'Duohui temporary package' -Target 'C:\Users\Fixture\AppData\Local\Temp\duohuipingbao' -SelectionId (New-AgentHex 2) -Reason 'Known duohuipingbao staging path.'),
            (New-AgentFinding -Name '360 temporary package' -Target ($root + '\cache\360setup.cab') -ProductKey 'Unattributed' -Confidence 'ReviewOnly' -Reason 'Filename pattern matched, but a CAB name alone is not enough evidence for automatic deletion.'),
            # A kept profile with a well-formed ID must still never be taken.
            (New-AgentFinding -Name '360se6 browser profile' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\User Data' -ProductKey '360SafeBrowser' -Confidence 'ReviewOnly' -SelectionId (New-AgentHex 3) -Reason '360se6 User Data can contain bookmarks, history, saved sessions, and other user data.'),
            (New-AgentFinding -Name '360se6 browser application' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser' -SelectionId (New-AgentHex 4) -Reason 'Exact 360se6 Application directory with local 360/Qihoo file evidence.')
        )
        $path = Write-AgentScanReport -Directory $directory -Findings $findings
        $json = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $path -Choice 'all')
        Assert-TestTrue -Condition ([bool]$json.Accepted) -Message 'The synthetic select-all was refused.'
        Assert-TestFalse -Condition (@($json.SelectedIds) -contains (New-AgentHex 1)) -Message 'A folder with kept content inside was selected.'
        Assert-TestFalse -Condition (@($json.SelectedIds) -contains (New-AgentHex 3)) -Message 'A kept item with an ID was selected.'
        Assert-TestSequenceEqual -Expected @((New-AgentHex 2), (New-AgentHex 4)) -Actual @($json.SelectedIds) -Message 'The synthetic selection is wrong.'
        # The folder with kept content inside can never be deleted in this result, so it is not even a candidate: it is
        # told as kept with its reason instead of as a skipped item.
        Assert-TestEqual -Expected 0 -Actual @(@($json.SkippedItems) | Where-Object { $null -ne $_ }).Count -Message 'An item that was never offered was reported as skipped.'
        Assert-TestTrue -Condition ([string]$json.Text).Contains('多绘屏保安装文件夹（里面有要保留的东西）') -Message ("The kept folder is not explained:`r`n" + $json.Text)
        Assert-TestFalse -Condition ([string]$json.Text).Contains('这次不能删') -Message ("The kept folder is told as skipped:`r`n" + $json.Text)

        # A product click that depends on another product still explains the item it leaves out.
        $dependent = @(
            (New-AgentFinding -Name 'Duohui screen saver' -Target $root -SelectionId (New-AgentHex 11)),
            (New-AgentFinding -Name 'Unattributed leftover' -Target ($root + '\leftover') -ProductKey 'Unattributed' -SelectionId (New-AgentHex 12)),
            (New-AgentFinding -Name 'Duohui temporary package' -Target 'C:\Users\Fixture\AppData\Local\Temp\duohuipingbao' -SelectionId (New-AgentHex 13) -Reason 'Known duohuipingbao staging path.')
        )
        $dependentPath = Write-AgentScanReport -Directory $directory -Findings $dependent
        $dependentRun = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $dependentPath -Choice 'Duohui')
        Assert-TestTrue -Condition ([bool]$dependentRun.Accepted) -Message 'The dependent product choice was refused.'
        Assert-TestSequenceEqual -Expected @((New-AgentHex 13)) -Actual @($dependentRun.SelectedIds) -Message 'The folder that holds an item of an unchosen product was selected.'
        Assert-TestEqual -Expected 'ParentContainsSelectableChild' -Actual ([string]@($dependentRun.SkippedItems)[0].Code) -Message 'The skipped folder has the wrong reason.'
        Assert-TestTrue -Condition ([string]$dependentRun.Text).Contains('“多绘屏保安装文件夹”这次不能删：里面还有你这次没选的 360 内容。') -Message ("The skipped folder is not explained:`r`n" + $dependentRun.Text)
        Assert-TestTrue -Condition (([string]$dependentRun.Text).Contains('多绘屏保安装文件夹（这次不能单独删）') -and -not ([string]$dependentRun.Text).Contains('多绘屏保安装文件夹（你没选）')) -Message ("The skipped folder of a named product is called not selected:`r`n" + $dependentRun.Text)

        $many = @(1..70 | ForEach-Object { New-AgentFinding -Name '360 unpack temporary files' -Target ('C:\Users\Fixture\AppData\Local\Temp\360UnPackTmp' + $_) -ProductKey '360Temp' -SelectionId (New-AgentHex (100 + $_)) -Reason 'Exact temporary component path with local 360/Qihoo file evidence.' })
        $manyPath = Write-AgentScanReport -Directory $directory -Findings $many
        $tooMany = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $manyPath -Choice '1')
        Assert-TestEqual -Expected 3 -Actual $tooMany.ExitCode -Message 'Seventy items were not refused.'
        Assert-AgentNoRemoveCommand -Run $tooMany -Label 'Too many'
        # One product alone is over the limit: choosing fewer products cannot help, so the window is offered.
        Assert-TestTrue -Condition ($tooMany.UserText.Contains((Get-SummaryTestText -Key 'Agent.Delete.TooManyOneProduct' -Arguments @((Get-W360ProductInfo -ProductKey '360Temp').DisplayName, 70, 64)))) -Message ("The too-many text:`r`n" + $tooMany.UserText)
        Assert-TestTrue -Condition ($tooMany.UserText.Contains('开始检查.cmd') -and -not $tooMany.UserText.Contains('少选几个软件')) -Message ("The too-many advice is impossible:`r`n" + $tooMany.UserText)
        Assert-TestTrue -Condition ($tooMany.AgentLines[0].Contains('reason=TooManyInOneProduct')) -Message ('The too-many reason: ' + $tooMany.AgentLines[0])
        Assert-AgentPlainText -Text $tooMany.UserText -Label 'Too many'
        # Several products that are over the limit only together: choosing fewer products helps.
        $split = @(1..40 | ForEach-Object { New-AgentFinding -Name '360 unpack temporary files' -Target ('C:\Users\Fixture\AppData\Local\Temp\360UnPackTmp' + $_) -ProductKey '360Temp' -SelectionId (New-AgentHex (300 + $_)) -Reason 'Exact temporary component path with local 360/Qihoo file evidence.' }) +
            @(1..40 | ForEach-Object { New-AgentFinding -Name 'Roaming SoftMgr cache' -Target ('C:\Users\Fixture\AppData\Roaming\SoftMgr' + $_) -ProductKey '360SoftMgr' -SelectionId (New-AgentHex (400 + $_)) -Reason 'Paired with confirmed 360 SoftMgr evidence.' })
        $splitPath = Write-AgentScanReport -Directory $directory -Findings $split
        $splitRun = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $splitPath -Choice 'all')
        Assert-TestEqual -Expected 3 -Actual $splitRun.ExitCode -Message 'Eighty items in two products were not refused.'
        Assert-AgentNoRemoveCommand -Run $splitRun -Label 'Too many together'
        Assert-TestTrue -Condition ($splitRun.UserText.Contains('一次最多只能删除 64 项') -and $splitRun.UserText.Contains('少选几个软件')) -Message ("The too-many-together text:`r`n" + $splitRun.UserText)
        Assert-TestFalse -Condition ($splitRun.UserText.Contains('一个软件里就有')) -Message 'Two products under the limit were told as one product over it.'

        $keptOnly = Write-AgentScanReport -Directory $directory -Findings @($findings[2], $findings[3])
        $keptRun = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $keptOnly -Choice 'all')
        Assert-TestEqual -Expected 3 -Actual $keptRun.ExitCode -Message 'all on a report without deletable items was accepted.'
        Assert-AgentNoRemoveCommand -Run $keptRun -Label 'All kept'
        $keptScan = Invoke-AgentSummary -Arguments @{ Report = $keptOnly }
        Assert-TestTrue -Condition ($keptScan.UserText.Contains('但都不删除') -and $keptScan.UserText.Contains('这些都不会删除，不用做什么。')) -Message ("Kept-only scan text:`r`n" + $keptScan.UserText)
        Assert-TestFalse -Condition ($keptScan.UserText.Contains('要删除哪几个')) -Message 'A kept-only scan asks what to delete.'

        # Browser data is taken only with the separate opt-in of both the Scan and this call.
        $profileId = New-AgentHex 5
        $optIn = @(
            (New-AgentFinding -Name '360se6 browser application' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser' -SelectionId (New-AgentHex 4) -Reason 'Exact 360se6 Application directory with local 360/Qihoo file evidence.'),
            (New-AgentFinding -Name '360se6 browser profile' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\User Data' -ProductKey '360SafeBrowser' -SelectionId $profileId -Reason '360se6 User Data can contain bookmarks, history, saved sessions, and other user data.')
        )
        $optInPath = Write-AgentScanReport -Directory $directory -Findings $optIn -IncludeBrowserProfiles $true
        $withoutSwitch = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $optInPath -Choice '1')
        Assert-TestFalse -Condition ($withoutSwitch.Text.Contains($profileId)) -Message 'Browser data was taken without the switch.'
        Assert-TestFalse -Condition ($withoutSwitch.Text.Contains('-IncludeBrowserProfiles')) -Message 'The browser-data flags were added without the switch.'
        Assert-TestTrue -Condition ($withoutSwitch.UserText.Contains('这次不删')) -Message 'Leaving out browser data was not said.'
        $withSwitch = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $optInPath -Choice '1' -Extra @{ IncludeBrowserProfiles = $true })
        $switchCommand = [string](Get-AgentLineValue -AgentLines $withSwitch.AgentLines -Key 'run-only-after-the-user-explicitly-says-yes')
        Assert-TestTrue -Condition ($switchCommand.Contains($profileId) -and $switchCommand.Contains('-IncludeBrowserProfiles -BrowserProfileConfirmation DELETE-360-BROWSER-DATA')) -Message 'The opted-in browser data command is wrong.'
        Assert-TestTrue -Condition ($withSwitch.UserText.Contains((Get-W360Text -Key 'Impact.BrowserProfile'))) -Message 'Deleting browser data does not say what is lost.'
    }

    Invoke-TestCase -Run $run -Name 'items that can never pass the selection check are told as kept, numbered like the window and refused by -Delete' -Test {
        $directory = Join-Path $fixtureRoot 'effective deletes'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $root = 'C:\Users\Fixture\AppData\Local\dhpingbao'
        $folder = New-AgentFinding -Name 'Duohui screen saver' -Target $root -SelectionId (New-AgentHex 61)
        $keptInside = New-AgentFinding -Name '360 temporary package' -Target ($root + '\cache\360setup.cab') -ProductKey 'Unattributed' -Confidence 'ReviewOnly' `
            -Reason 'Filename pattern matched, but a CAB name alone is not enough evidence for automatic deletion.'
        $browser = New-AgentFinding -Name '360se6 browser application' -Target 'C:\Users\Fixture\AppData\Roaming\360se6\Application' -ProductKey '360SafeBrowser' `
            -SelectionId (New-AgentHex 62) -Reason 'Exact 360se6 Application directory with local 360/Qihoo file evidence.'
        $temp = New-AgentFinding -Name 'Duohui temporary package' -Target 'C:\Users\Fixture\AppData\Local\Temp\duohuipingbao' -SelectionId (New-AgentHex 63) -Reason 'Known duohuipingbao staging path.'
        $vendor = New-AgentFinding -Name 'Duohui vendor uninstaller' -Target ($root + '\huabaosetup.exe') -Kind 'VendorUninstaller' -RemovalType 'VendorUninstaller' -SelectionId (New-AgentHex 64) `
            -Reason 'Exact Duohui uninstaller under a confirmed dhpingbao root with a valid Beijing Qihu Technology Co., Ltd. signature and Duohui/Huabao metadata. SHA-256: ABCDEF'

        # The only deletable item of 360 画报 / 多绘屏保 holds a kept item: the whole product is listed under "won't delete".
        $onlyKept = @($folder, $keptInside, $browser)
        $onlyKeptPath = Write-AgentScanReport -Directory $directory -Findings $onlyKept
        $onlyKeptOutcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $onlyKeptPath
        $text = Invoke-AgentSummary -Arguments @{ Report = $onlyKeptPath }
        Assert-TestEqual -Expected 0 -Actual $text.ExitCode -Message 'The effective scan summary did not succeed.'
        Assert-AgentPlainText -Text $text.UserText -Label 'Effective scan text'
        Assert-TestTrue -Condition ($text.UserText.StartsWith('检查完了（检查不会删除任何东西）。找到 1 个可以删除的 360 软件：')) -Message ("The product with only a kept folder is counted as deletable:`r`n" + $text.UserText)
        $keepIndex = $text.UserText.IndexOf('这些不删除：')
        $duohuiLine = '2. 360 画报 / 多绘屏保 —— 不删除：里面有要保留的东西'
        Assert-TestTrue -Condition ($keepIndex -gt 0 -and $text.UserText.IndexOf($duohuiLine) -gt $keepIndex) -Message ("The product is not listed under 这些不删除 with its reason:`r`n" + $text.UserText)
        Assert-TestTrue -Condition ($text.UserText.Contains('要删除吗？要的话回复“删除 1”。')) -Message ("Only the one deletable product is asked about:`r`n" + $text.UserText)
        Assert-TestEqual -Expected '1:360SafeBrowser(can-delete),2:Duohui(keep),3:Unattributed(keep)' -Actual ([string](Get-AgentLineValue -AgentLines $text.AgentLines -Key 'groups')) -Message 'The AGENT groups line does not mark the product as keep.'
        Assert-TestEqual -Expected '1' -Actual ([string](Get-AgentLineValue -AgentLines $text.AgentLines -Key 'ask-if-still-used')) -Message 'A kept product is in ask-if-still-used.'
        Assert-TestEqual -Expected 'none' -Actual ([string](Get-AgentLineValue -AgentLines $text.AgentLines -Key 'do-not-suggest')) -Message 'The do-not-suggest line is wrong.'
        $json = Invoke-AgentSummaryJson -Arguments @{ Report = $onlyKeptPath }
        $duohuiGroup = @($json.Groups | Where-Object { $_.ProductKey -eq 'Duohui' })[0]
        Assert-TestFalse -Condition ([bool]$duohuiGroup.CanDelete) -Message 'The product with only a kept folder can be deleted.'
        Assert-TestEqual -Expected 0 -Actual ([int]$duohuiGroup.DeletableCount) -Message 'Kept-only product deletable count.'
        Assert-TestEqual -Expected 1 -Actual ([int]$duohuiGroup.KeptCount) -Message 'Kept-only product kept count.'
        Assert-TestEqual -Expected '不删除：里面有要保留的东西' -Actual ([string]$duohuiGroup.DecisionText) -Message 'Kept-only product decision.'
        Assert-TestEqual -Expected 0 -Actual @(@($duohuiGroup.SelectionIds) | Where-Object { $_ }).Count -Message 'The kept-only product offers IDs.'
        # The same order and counts as the window's product rows.
        $windowGroups = @(Get-W360FindingGroups -Findings $onlyKeptOutcome.Findings -Effective $onlyKeptOutcome.EffectiveDeletable)
        $windowOrder = @(@($windowGroups | Where-Object { [int]$_.SelectableCount -gt 0 }) + @($windowGroups | Where-Object { [int]$_.SelectableCount -eq 0 }) | ForEach-Object { '{0}:{1}:{2}' -f $_.Key, $_.SelectableCount, $_.ReviewCount })
        Assert-TestSequenceEqual -Expected $windowOrder -Actual @($json.Groups | ForEach-Object { '{0}:{1}:{2}' -f $_.ProductKey, $_.DeletableCount, $_.KeptCount }) -Message 'The agent products differ from the window products.'

        # Every printed number is the product -Delete takes; the kept product is refused as 不删除.
        foreach ($group in @($json.Groups)) {
            $number = [int]$group.Number
            $lineMatch = [regex]::Match($text.UserText, '(?m)^' + $number + '\. (.+?) —— ')
            Assert-TestTrue -Condition $lineMatch.Success -Message "Number $number is not printed."
            Assert-TestEqual -Expected ([string]$group.DisplayName) -Actual $lineMatch.Groups[1].Value -Message "The printed name of number $number is not its product."
            $deleteRun = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $onlyKeptPath -Choice ([string]$number))
            Assert-TestSequenceEqual -Expected @($number) -Actual @($deleteRun.ChosenNumbers) -Message "-Delete $number chose other numbers."
            Assert-TestEqual -Expected ([bool]$group.CanDelete) -Actual ([bool]$deleteRun.Accepted) -Message "-Delete $number acceptance does not follow the list."
        }
        foreach ($choice in @('2', 'Duohui')) {
            $refused = Invoke-AgentSummary -Arguments (New-AgentDeleteArguments -Report $onlyKeptPath -Choice $choice)
            Assert-TestEqual -Expected 3 -Actual $refused.ExitCode -Message "-Delete $choice of a product that can never pass was not refused."
            Assert-AgentNoRemoveCommand -Run $refused -Label "-Delete $choice of a kept product"
            Assert-TestTrue -Condition ($refused.AgentLines[0].Contains('reason=OnlyKept')) -Message ("-Delete $choice reason: " + $refused.AgentLines[0])
            Assert-TestTrue -Condition ($refused.UserText.Contains('2. 360 画报 / 多绘屏保 不删除（里面有要保留的东西），没有算进去。') -and $refused.UserText.Contains('选的这些都不删除')) -Message ("-Delete $choice text:`r`n" + $refused.UserText)
            Assert-AgentPlainText -Text $refused.UserText -Label "-Delete $choice of a kept product"
        }
        $all = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $onlyKeptPath -Choice 'all')
        Assert-TestTrue -Condition ([bool]$all.Accepted) -Message '"all" with one deletable product was refused.'
        Assert-TestSequenceEqual -Expected @(1) -Actual @($all.ChosenNumbers) -Message '"all" took a product that can never pass.'
        Assert-TestSequenceEqual -Expected @((New-AgentHex 62)) -Actual @($all.SelectedIds) -Message '"all" selected an item that can never pass.'
        Assert-TestTrue -Condition ([string]$all.Text).Contains('360 画报 / 多绘屏保（里面有要保留的东西）') -Message ("The confirmation does not list the kept product with its reason:`r`n" + $all.Text)
        $both = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $onlyKeptPath -Choice '1,2')
        Assert-TestTrue -Condition ([bool]$both.Accepted -and ([string]$both.Text).Contains('没有算进去')) -Message 'A deletable product with a product that can never pass is not handled like a kept product.'
        Assert-TestSequenceEqual -Expected @((New-AgentHex 62)) -Actual @($both.SelectedIds) -Message '"1,2" selected an item that can never pass.'

        # A product with items inside and outside the set: counts, words and -Delete use only the items inside.
        $mixed = @($folder, $keptInside, $temp, $vendor)
        $mixedPath = Write-AgentScanReport -Directory $directory -Findings $mixed
        $mixedOutcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $mixedPath
        $mixedText = Invoke-AgentSummary -Arguments @{ Report = $mixedPath }
        Assert-AgentPlainText -Text $mixedText.UserText -Label 'Mixed effective scan text'
        foreach ($part in @('1. 360 画报 / 多绘屏保 —— 可以删除（1 项），2 项不删除', '可以删除：多绘屏保临时安装包',
                '不删除：多绘屏保安装文件夹（里面有要保留的东西）、多绘屏保自带的卸载程序（要和它所在的文件夹一起删）')) {
            Assert-TestTrue -Condition ($mixedText.UserText.Contains($part)) -Message ("The mixed product text misses '{0}':`r`n{1}" -f $part, $mixedText.UserText)
        }
        Assert-TestFalse -Condition ($mixedText.UserText.Contains((Get-W360Text -Key 'Impact.VendorUninstaller.Confirm'))) -Message 'The effect of an uninstaller that can never pass is described.'
        $mixedJson = Invoke-AgentSummaryJson -Arguments @{ Report = $mixedPath }
        $mixedGroup = @($mixedJson.Groups)[0]
        Assert-TestEqual -Expected 'Duohui' -Actual ([string]$mixedGroup.ProductKey) -Message 'The mixed product is not first.'
        Assert-TestTrue -Condition ([bool]$mixedGroup.CanDelete) -Message 'The mixed product cannot be deleted.'
        Assert-TestEqual -Expected 1 -Actual ([int]$mixedGroup.DeletableCount) -Message 'Mixed product deletable count.'
        Assert-TestEqual -Expected 2 -Actual ([int]$mixedGroup.KeptCount) -Message 'Mixed product kept count.'
        Assert-TestEqual -Expected '可以删除（1 项），2 项不删除' -Actual ([string]$mixedGroup.DecisionText) -Message 'Mixed product decision.'
        Assert-TestSequenceEqual -Expected @((New-AgentHex 63)) -Actual @($mixedGroup.SelectionIds) -Message 'Mixed product IDs.'
        $mixedDelete = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $mixedPath -Choice '1')
        Assert-TestTrue -Condition ([bool]$mixedDelete.Accepted) -Message 'The mixed product was refused.'
        Assert-TestSequenceEqual -Expected @((New-AgentHex 63)) -Actual @($mixedDelete.SelectedIds) -Message 'The mixed product selection took an item that can never pass.'
        Assert-TestFalse -Condition ([bool]$mixedDelete.VendorUninstallerSelected) -Message 'The uninstaller that can never pass was selected.'
        Assert-TestEqual -Expected 0 -Actual @(@($mixedDelete.SkippedItems) | Where-Object { $null -ne $_ }).Count -Message 'Items that were never offered were reported as skipped.'
        foreach ($part in @('多绘屏保安装文件夹（里面有要保留的东西）', '多绘屏保自带的卸载程序（要和它所在的文件夹一起删）')) {
            Assert-TestTrue -Condition ([string]$mixedDelete.Text).Contains($part) -Message ("The confirmation misses '{0}':`r`n{1}" -f $part, $mixedDelete.Text)
        }
        Assert-TestFalse -Condition ([string]$mixedDelete.Text).Contains((Get-W360Text -Key 'Ui.Confirm.VendorWarning')) -Message 'The uninstaller warning was shown for an uninstaller that is not deleted.'

        # Never wider: every offered or selected ID is in the effective set, which only holds deletable items.
        foreach ($pair in @(@($onlyKeptOutcome, @($json.Groups), @($all.SelectedIds)), @($mixedOutcome, @($mixedJson.Groups), @($mixedDelete.SelectedIds)))) {
            $effectiveIds = @($pair[0].EffectiveDeletable.Ids)
            foreach ($id in @($effectiveIds)) {
                $finding = @(@($pair[0].Findings) | Where-Object { [string]$_.SelectionId -eq $id })
                Assert-TestTrue -Condition ($finding.Count -eq 1 -and (Test-W360FindingSelectable -Finding $finding[0])) -Message "The effective set holds an item that cannot be deleted: $id"
            }
            $offered = @(@($pair[1]) | ForEach-Object { @($_.SelectionIds) } | Where-Object { $_ }) + @(@($pair[2]) | Where-Object { $_ })
            foreach ($id in $offered) { Assert-TestTrue -Condition ($effectiveIds -contains [string]$id) -Message "An ID outside the effective set was offered or selected: $id" }
        }

        # The whole-product "after deleting" sentence is not told when the folder it is about is not deleted.
        $sharedRoot = 'C:\Program Files (x86)\360'
        $shared = @(
            (New-AgentFinding -Name '360 Program Files (x86)' -Target $sharedRoot -ProductKey '360InstallDir' -SelectionId (New-AgentHex 71) -Reason 'Known 360 installation root.'),
            (New-AgentFinding -Name 'Config' -Target ($sharedRoot + '\Config') -ProductKey '360InstallDir' -Confidence 'ReviewOnly' -Reason 'Name only.'),
            (New-AgentFinding -Name '360 settings' -Target 'HKCU\Software\360' -ProductKey '360InstallDir' -Kind 'RegistryResidue' -RemovalType 'RegistryKey' -SelectionId (New-AgentHex 72) -Reason 'Known 360 settings.')
        )
        $sharedPath = Write-AgentScanReport -Directory $directory -Findings $shared
        $sharedText = Invoke-AgentSummary -Arguments @{ Report = $sharedPath }
        Assert-AgentPlainText -Text $sharedText.UserText -Label 'Kept shared folder scan text'
        $productSentence = [regex]::Replace((Get-W360ProductInfo -ProductKey '360InstallDir').Impact, '^删除后[，,]?\s*', '')
        Assert-TestTrue -Condition ($sharedText.UserText.Contains('可以删除（1 项），2 项不删除') -and $sharedText.UserText.Contains('删除后：' + (Get-W360Text -Key 'Impact.RegistryResidue'))) -Message ("The kept shared folder text does not tell the settings effect:`r`n" + $sharedText.UserText)
        Assert-TestFalse -Condition ($sharedText.UserText.Contains($productSentence) -or $sharedText.UserText.Contains((Get-W360Text -Key 'Impact.SharedInstallDir'))) -Message ("The effect of a folder that is not deleted is told:`r`n" + $sharedText.UserText)
        # Every item deletable: the product sentence stays.
        $sharedAll = Write-AgentScanReport -Directory $directory -Findings @($shared[0], $shared[2])
        $sharedAllText = Invoke-AgentSummary -Arguments @{ Report = $sharedAll }
        Assert-TestTrue -Condition ($sharedAllText.UserText.Contains('删除后：' + $productSentence)) -Message ("The product sentence is missing when the folder is deleted:`r`n" + $sharedAllText.UserText)

        # An uninstaller whose folder belongs to a product the user did not name: the skip note names that product, and
        # the confirmation does not call the named product's item "not selected".
        $crossRoot = 'C:\Users\Fixture\AppData\Local\dhpingbao'
        $cross = @(
            (New-AgentFinding -Name 'Duohui root of another product' -Target $crossRoot -ProductKey '360Security' -SelectionId (New-AgentHex 81) -Reason 'Known 360 path.'),
            (New-AgentFinding -Name 'Duohui vendor uninstaller' -Target ($crossRoot + '\huabaosetup.exe') -Kind 'VendorUninstaller' -RemovalType 'VendorUninstaller' -SelectionId (New-AgentHex 82) `
                -Reason 'Exact Duohui uninstaller under a confirmed dhpingbao root with a valid Beijing Qihu Technology Co., Ltd. signature and Duohui/Huabao metadata. SHA-256: ABCDEF'),
            (New-AgentFinding -Name 'Duohui temporary package' -Target 'C:\Users\Fixture\AppData\Local\Temp\duohuipingbao' -SelectionId (New-AgentHex 83) -Reason 'Known duohuipingbao staging path.')
        )
        $crossPath = Write-AgentScanReport -Directory $directory -Findings $cross
        $crossJson = Invoke-AgentSummaryJson -Arguments @{ Report = $crossPath }
        $securityGroup = @($crossJson.Groups | Where-Object { $_.ProductKey -eq '360Security' })[0]
        $crossRun = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $crossPath -Choice 'Duohui')
        Assert-TestTrue -Condition ([bool]$crossRun.Accepted) -Message 'The Duohui choice was refused.'
        Assert-TestSequenceEqual -Expected @((New-AgentHex 83)) -Actual @($crossRun.SelectedIds) -Message 'The uninstaller was taken without its folder.'
        Assert-TestEqual -Expected 'VendorUninstallerNeedsInstallRoot' -Actual ([string]@($crossRun.SkippedItems)[0].Code) -Message 'The skipped uninstaller has the wrong reason.'
        $crossNote = Get-SummaryTestText -Key 'Agent.Delete.Skipped' -Arguments @('多绘屏保自带的卸载程序',
            (Get-SummaryTestText -Key 'Agent.Delete.FolderInUnchosenProduct' -Arguments @([string]$securityGroup.DisplayName, [int]$securityGroup.Number)))
        Assert-TestTrue -Condition ([string]$crossRun.Text).Contains($crossNote) -Message ("The skip note does not name the product of the folder:`r`n" + $crossRun.Text)
        Assert-TestFalse -Condition ([string]$crossRun.Text).Contains((Get-SummaryTestText -Key 'Agent.Delete.SkipReason.VendorUninstallerNeedsInstallRoot')) -Message ("A deletable folder is told as not deletable:`r`n" + $crossRun.Text)
        Assert-TestTrue -Condition ([string]$crossRun.Text).Contains('多绘屏保自带的卸载程序（这次不能单独删）') -Message ("The skipped uninstaller is not labelled as skipped:`r`n" + $crossRun.Text)
        Assert-TestFalse -Condition ([string]$crossRun.Text).Contains('多绘屏保自带的卸载程序（你没选）') -Message ("An item of a named product is called not selected:`r`n" + $crossRun.Text)
        Assert-AgentPlainText -Text ([string]$crossRun.Text) -Label 'Cross-product delete text'
    }

    Invoke-TestCase -Run $run -Name 'Remove reports: plain headlines, a required exit code, and never "complete" for a non-zero exit code' -Test {
        $case = New-AgentCase -FixtureRoot $fixtureRoot -Name 'remove'
        $scan = Invoke-AgentScan -Case $case
        $numbers = Invoke-AgentSummaryJson -Arguments @{ Report = $scan.ReportPath }
        $browserNumber = [int]@($numbers.Groups | Where-Object { $_.ProductKey -eq '360SafeBrowser' })[0].Number
        $scanHash = Get-AgentReportHash -Path $scan.ReportPath
        $delete = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice ([string]$browserNumber))
        $removal = Invoke-AgentRemoval -Case $case -Scan $scan -SelectedIds @($delete.SelectedIds) -ReportPath ([string]$delete.RemoveReportPath) -RemoveBehavior {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        Assert-TestEqual -Expected 0 -Actual $removal.ExitCode -Message 'The isolated removal needed attention.'
        Assert-TestTrue -Condition (Test-Path -LiteralPath $case.DuohuiRoot) -Message 'An item that was not chosen was removed.'

        $missing = Invoke-AgentSummary -Arguments @{ Report = $removal.ReportPath; ScanReportHash = $scanHash }
        Assert-TestEqual -Expected 2 -Actual $missing.ExitCode -Message 'A Remove report without -ExitCode was summarised.'
        Assert-TestEqual -Expected '还不能确定结果，先不要当作已经完成。' -Actual $missing.UserText -Message 'The missing exit code text changed.'
        Assert-TestNotNull -Actual (Get-AgentLineValue -AgentLines $missing.AgentLines -Key 'rerun') -Message 'The agent is not told how to rerun with the exit code.'
        $placeholder = Invoke-AgentSummary -Arguments @{ Report = $removal.ReportPath; ScanReportHash = $scanHash; ExitCode = '<exit code of the remove command, or unknown>' }
        Assert-TestEqual -Expected 2 -Actual $placeholder.ExitCode -Message 'A placeholder exit code was summarised.'
        Assert-TestEqual -Expected '还不能确定结果，先不要当作已经完成。' -Actual $placeholder.UserText -Message 'A placeholder exit code gave a conclusion.'

        # The after-remove command of -Delete, run as printed with the real exit code.
        $afterRemove = [string]$delete.AfterRemoveCommand
        Assert-TestTrue -Condition ($afterRemove.Contains('-Report "' + $removal.ReportPath + '"') -and $afterRemove.Contains('-ScanReportHash ' + $scanHash + ' ')) -Message ('The after-remove command: ' + $afterRemove)
        $done = Invoke-AgentSummary -Arguments @{ Report = $removal.ReportPath; Mode = 'Remove'; ScanReportHash = $scanHash; ExitCode = '0' }
        Assert-TestEqual -Expected 0 -Actual $done.ExitCode -Message 'The Remove summary failed.'
        Assert-TestTrue -Condition ($done.UserText.StartsWith('删除完成')) -Message ("The completed headline:`r`n" + $done.UserText)
        Assert-TestTrue -Condition ($done.UserText.Contains('删掉 1 项，没删掉 0 项，不确定 0 项。')) -Message 'The counts line is missing.'
        Assert-TestTrue -Condition ($done.UserText.Contains('我不会替你重启')) -Message 'The next step does not say the PC is not restarted automatically.'
        Assert-AgentPlainText -Text $done.UserText -Label 'Completed remove text'
        $verifyCommand = [string](Get-AgentLineValue -AgentLines $done.AgentLines -Key 'after-restart')
        Assert-TestTrue -Condition ($verifyCommand.Contains('-Mode Verify -PreviousRemoveReport "' + $removal.ReportPath + '"')) -Message ('The verify command is wrong: ' + $verifyCommand)
        foreach ($part in @('restart=recommended', 'tone=Success', 'uninstaller-ran=false', 'approval-bound=true', 'kept-unconfirmed=0')) {
            Assert-TestTrue -Condition ($done.AgentLines[0].Contains($part)) -Message ('The completed AGENT line misses {0}: {1}' -f $part, $done.AgentLines[0])
        }

        # A Remove report bound to another Scan report is never this deletion's result.
        $otherApproval = Invoke-AgentSummaryJson -Arguments @{ Report = $removal.ReportPath; ScanReportHash = ('AB' * 32); ExitCode = '0' }
        Assert-TestEqual -Expected 'Unknown' -Actual ([string]$otherApproval.State) -Message 'A Remove report of another approval was told as this result.'
        Assert-TestEqual -Expected 'HashMismatch' -Actual ([string]$otherApproval.ReportIssue) -Message 'The other approval was not found.'
        Assert-TestFalse -Condition ([string]$otherApproval.Text).Contains('删除完成') -Message 'A Remove report of another approval was told as complete.'
        $unbound = Invoke-AgentSummary -Arguments @{ Report = $removal.ReportPath; ExitCode = '0' }
        Assert-TestTrue -Condition ($unbound.AgentLines[0].Contains('approval-bound=false')) -Message 'A summary without the approved hash is not marked as unbound.'

        foreach ($code in @('1', '2', '3', '5', '6', '-1', '3221225786', 'unknown')) {
            $bad = Invoke-AgentSummaryJson -Arguments @{ Report = $removal.ReportPath; ScanReportHash = $scanHash; ExitCode = $code }
            Assert-TestEqual -Expected 0 -Actual ([int]$bad.ProcessExitCode) -Message "Exit code $code was not summarised."
            Assert-TestFalse -Condition ([string]$bad.Text).Contains('删除完成') -Message "Exit code $code was told as complete."
            Assert-TestFalse -Condition ([string]$bad.State -eq 'Completed') -Message "Exit code $code has the Completed state."
            Assert-TestFalse -Condition ([string]$bad.Tone -eq 'Success') -Message "Exit code $code looks like success."
            Assert-TestEqual -Expected 'needed' -Actual ([string]$bad.Restart) -Message "Exit code $code does not ask for the restart."
            Assert-AgentPlainText -Text ([string]$bad.Text) -Label "Remove exit code $code text"
        }
        $lost = Invoke-AgentSummaryJson -Arguments @{ Report = $removal.ReportPath; ScanReportHash = $scanHash; ExitCode = 'unknown' }
        Assert-TestEqual -Expected 'Unknown' -Actual ([string]$lost.State) -Message 'A lost exit code is not "not sure".'
        Assert-TestTrue -Condition ([string]$lost.Text).StartsWith((Get-W360Text -Key 'Remove.Unknown.Headline')) -Message ("A lost exit code headline:`r`n" + $lost.Text)
        Assert-TestTrue -Condition ([string]$lost.Text).Contains((Get-SummaryTestText -Key 'Agent.Remove.EndUnknown')) -Message 'A lost exit code is not explained.'

        $locked = Invoke-AgentRemoval -Case $case -Scan $scan -ReportPath (New-W360ReportPath -Directory $case.ReportDirectory -Kind 'remove') -RemoveBehavior {
            param($Context, $Path)
            throw (New-Object IO.IOException('The process cannot access the file because it is being used by another process.'))
        } -SelectedIds @((Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice 'all')).SelectedIds | Where-Object { @($delete.SelectedIds) -notcontains $_ })
        $lockedRun = Invoke-AgentSummary -Arguments @{ Report = $locked.ReportPath; ScanReportHash = $scanHash; ExitCode = [string]$locked.ExitCode }
        Assert-TestTrue -Condition ($lockedRun.UserText.StartsWith('还差一步：请重启电脑')) -Message ("The locked headline:`r`n" + $lockedRun.UserText)
        Assert-TestTrue -Condition ($lockedRun.UserText.Contains('没删掉或没做完的：') -and $lockedRun.UserText.Contains('重启电脑后再检查一次')) -Message 'The locked items are not listed.'
        # A restart that is needed is told as needed, never as a recommendation for later.
        Assert-TestTrue -Condition ($lockedRun.UserText.Contains('接下来：' + (Get-SummaryTestText -Key 'Agent.Next.RemoveRestart'))) -Message ("The locked next step:`r`n" + $lockedRun.UserText)
        Assert-TestFalse -Condition ($lockedRun.UserText.Contains('找个方便的时候')) -Message 'A needed restart was told as optional.'
        Assert-TestTrue -Condition ($lockedRun.AgentLines[0].Contains('state=NeedsRestart') -and $lockedRun.AgentLines[0].Contains('restart=needed')) -Message ('The locked AGENT line: ' + $lockedRun.AgentLines[0])
        Assert-AgentPlainText -Text $lockedRun.UserText -Label 'Locked remove text'

        # The uninstaller that came with 360 ran: finished, but never a plain success, and the text says what it may have removed.
        $vendorCase = New-AgentCase -FixtureRoot $fixtureRoot -Name 'remove vendor'
        $vendorScan = Invoke-AgentScan -Case $vendorCase
        $vendorDelete = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $vendorScan.ReportPath -Choice 'Duohui')
        $vendorRemoval = Invoke-AgentRemoval -Case $vendorCase -Scan $vendorScan -SelectedIds @($vendorDelete.SelectedIds) -ReportPath ([string]$vendorDelete.RemoveReportPath) -RemoveBehavior {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        $vendorRun = Invoke-AgentSummary -Arguments @{ Report = $vendorRemoval.ReportPath; ScanReportHash = (Get-AgentReportHash -Path $vendorScan.ReportPath); ExitCode = [string]$vendorRemoval.ExitCode }
        Assert-TestTrue -Condition ($vendorRun.UserText.Contains((Get-W360Text -Key 'Remove.Completed.VendorRan'))) -Message ("The uninstaller sentence is missing:`r`n" + $vendorRun.UserText)
        Assert-TestTrue -Condition ($vendorRun.AgentLines[0].Contains('uninstaller-ran=true') -and $vendorRun.AgentLines[0].Contains('tone=Warning')) -Message ('The uninstaller AGENT line: ' + $vendorRun.AgentLines[0])

        # A new conversation after the restart finds this deletion again, read-only.
        $before = @(Get-ChildItem -LiteralPath $case.ReportDirectory -Force | ForEach-Object { $_.Name } | Sort-Object)
        $other = Read-W360JsonFile -Path $locked.ReportPath
        $other.ApprovalContext.UserSid = 'S-1-5-21-1-2-3-4242'
        $other.Timestamp = (Get-Date).AddMinutes(5).ToString('o')
        $otherUserReport = Join-Path $case.ReportDirectory '360-cleanup-remove-20990101-000000-0f0f0f0f.json'
        [IO.File]::WriteAllText($otherUserReport, ($other | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::Copy($scan.ReportPath, (Join-Path $case.ReportDirectory '360-cleanup-report-20990101-000000-1e1e1e1e.json'))
        $found = Invoke-AgentSummaryJson -Arguments @{ FindLastRemove = $true; Directory = $case.ReportDirectory }
        Assert-TestEqual -Expected 0 -Actual ([int]$found.ProcessExitCode) -Message 'The last deletion was not found.'
        Assert-TestEqual -Expected 'Found' -Actual ([string]$found.State) -Message 'The last deletion state.'
        Assert-TestEqual -Expected $locked.ReportPath -Actual ([string]$found.RemoveReportPath) -Message 'Another user''s or an older deletion was picked.'
        Assert-TestEqual -Expected 1 -Actual ([int]$found.OtherRemovals) -Message 'The earlier deletion of this user was not counted.'
        Assert-TestTrue -Condition ([string]$found.CheckCommand).Contains('-Mode Verify -PreviousRemoveReport "' + $locked.ReportPath + '"') -Message ('The check command: ' + $found.CheckCommand)
        Assert-TestFalse -Condition ([string]$found.CheckCommand).Contains('-Mode Remove') -Message 'Finding the last deletion offers a removal.'
        Assert-AgentPlainText -Text ([string]$found.Text) -Label 'Last deletion text'
        $foundText = Invoke-AgentSummary -Arguments @{ FindLastRemove = $true; Directory = $case.ReportDirectory }
        Assert-TestFalse -Condition ($foundText.Text.Contains('REMOVE-CONFIRMED-360')) -Message 'Finding the last deletion printed a removal.'
        $after = @(Get-ChildItem -LiteralPath $case.ReportDirectory -Force | Where-Object { $_.FullName -ne $otherUserReport -and $_.Name -notlike '360-cleanup-report-2099*' } | ForEach-Object { $_.Name } | Sort-Object)
        Assert-TestSequenceEqual -Expected $before -Actual $after -Message 'Finding the last deletion wrote a file.'
        $emptyDirectory = Join-Path $fixtureRoot 'no deletions'
        [void][IO.Directory]::CreateDirectory($emptyDirectory)
        $notFound = Invoke-AgentSummaryJson -Arguments @{ FindLastRemove = $true; Directory = $emptyDirectory }
        Assert-TestEqual -Expected 'NotFound' -Actual ([string]$notFound.State) -Message 'An empty folder found a deletion.'
        Assert-TestFalse -Condition ([string]$notFound.Text).Contains('没有删除任何东西') -Message 'Not finding a record was told as "nothing was deleted".'
        Assert-TestTrue -Condition ([string]$notFound.Text).StartsWith((Get-SummaryTestText -Key 'Agent.Last.NotFound')) -Message ("The not-found text:`r`n" + $notFound.Text)

        # An unexpected problem (here a folder name Windows does not accept) is plain words and no command.
        $broken = Invoke-AgentSummary -Arguments @{ FindLastRemove = $true; Directory = 'C:\bad|folder' }
        Assert-TestEqual -Expected 1 -Actual $broken.ExitCode -Message 'An unexpected problem did not end with exit code 1.'
        Assert-TestEqual -Expected (Get-SummaryTestText -Key 'Agent.Error') -Actual $broken.UserText -Message 'An unexpected problem is not told in plain words.'
        Assert-TestFalse -Condition ($broken.Text.Contains('powershell.exe')) -Message 'An unexpected problem printed a command.'

        # Paths a shell would change never get a next command.
        $unsafeDirectory = Join-Path $fixtureRoot 'remove $x`y'
        [void][IO.Directory]::CreateDirectory($unsafeDirectory)
        $unsafeRemove = Join-Path $unsafeDirectory ([IO.Path]::GetFileName($removal.ReportPath))
        [IO.File]::Copy($removal.ReportPath, $unsafeRemove)
        $unsafeRun = Invoke-AgentSummary -Arguments @{ Report = $unsafeRemove; ScanReportHash = $scanHash; ExitCode = '0' }
        Assert-TestNull -Actual (Get-AgentLineValue -AgentLines $unsafeRun.AgentLines -Key 'after-restart') -Message 'A check command was printed for an unsafe folder.'
        Assert-TestFalse -Condition ($unsafeRun.Text.Contains('powershell.exe')) -Message 'A command was printed for an unsafe Remove report folder.'

        $neverWritten = Join-Path $case.ReportDirectory '360-cleanup-remove-20260914-120000-0a1b2c3d.json'
        foreach ($code in @('0', '1', '5')) {
            $noReport = Invoke-AgentSummaryJson -Arguments @{ Report = $neverWritten; ExitCode = $code }
            Assert-TestEqual -Expected 'Unknown' -Actual ([string]$noReport.State) -Message "A missing Remove report with exit code $code is not unknown."
            Assert-TestFalse -Condition ([string]$noReport.Text).Contains('没有删除任何东西') -Message "A missing Remove report with exit code $code claims nothing was deleted."
            Assert-TestTrue -Condition ([string]$noReport.AfterRestartCommand).Contains('-Mode Scan') -Message 'A missing Remove report does not lead to a new check.'
        }
        $unknownKind = Invoke-AgentSummary -Arguments @{ Report = (Join-Path $case.ReportDirectory 'missing.json'); ExitCode = '0' }
        Assert-TestEqual -Expected 2 -Actual $unknownKind.ExitCode -Message 'A missing report of unknown kind was summarised.'
        $wrongKind = Invoke-AgentSummary -Arguments @{ Report = $scan.ReportPath; Mode = 'Remove'; ExitCode = '0' }
        Assert-TestEqual -Expected 2 -Actual $wrongKind.ExitCode -Message 'A Scan report was accepted as a Remove report.'
        $deleteOnRemove = Invoke-AgentSummary -Arguments @{ Report = $removal.ReportPath; Delete = @('1'); ScanReportHash = $scanHash }
        Assert-TestEqual -Expected 2 -Actual $deleteOnRemove.ExitCode -Message '-Delete on a Remove report was accepted.'
        Assert-AgentNoRemoveCommand -Run $deleteOnRemove -Label '-Delete on a Remove report'
    }

    Invoke-TestCase -Run $run -Name 'Verify reports: plain headlines and sections, a required exit code, and kept items are not failures' -Test {
        $case = New-AgentCase -FixtureRoot $fixtureRoot -Name 'verify'
        $scan = Invoke-AgentScan -Case $case
        $numbers = Invoke-AgentSummaryJson -Arguments @{ Report = $scan.ReportPath }
        $browserNumber = [int]@($numbers.Groups | Where-Object { $_.ProductKey -eq '360SafeBrowser' })[0].Number
        $delete = Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $scan.ReportPath -Choice ([string]$browserNumber))
        $removal = Invoke-AgentRemoval -Case $case -Scan $scan -SelectedIds @($delete.SelectedIds) -ReportPath ([string]$delete.RemoveReportPath) -RemoveBehavior {
            param($Context, $Path)
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        $verify = Invoke-AgentVerify -Case $case -RemoveReportPath $removal.ReportPath -ReportPath (New-W360ReportPath -Directory $case.ReportDirectory -Kind 'verify')
        Assert-TestEqual -Expected 0 -Actual $verify.ExitCode -Message 'The fixture verification did not complete.'
        $missing = Invoke-AgentSummary -Arguments @{ Report = $verify.ReportPath }
        Assert-TestEqual -Expected 2 -Actual $missing.ExitCode -Message 'A Verify report without -ExitCode was summarised.'
        Assert-TestFalse -Condition ($missing.UserText.Contains('删干净')) -Message 'A Verify report without -ExitCode gave a conclusion.'
        $done = Invoke-AgentSummary -Arguments @{ Report = $verify.ReportPath; ExitCode = '0' }
        Assert-TestTrue -Condition ($done.UserText.StartsWith('上次选的都删干净了')) -Message ("The completed verification headline:`r`n" + $done.UserText)
        Assert-TestTrue -Condition ($done.UserText.Contains('你保留的（3 项）：') -and $done.UserText.Contains('已删掉（1 项）：')) -Message ("The verification sections:`r`n" + $done.UserText)
        Assert-TestFalse -Condition ($done.UserText.Contains('没删掉')) -Message 'Kept items were shown as not deleted.'
        Assert-TestTrue -Condition ($done.UserText.EndsWith('接下来：' + (Get-SummaryTestText -Key 'Agent.Next.Done'))) -Message ("The completed next step:`r`n" + $done.UserText)
        Assert-TestTrue -Condition ($done.AgentLines[0].Contains('kept-gone=0') -and $done.AgentLines[0].Contains('tone=Success')) -Message ('The completed AGENT line: ' + $done.AgentLines[0])
        Assert-AgentPlainText -Text $done.UserText -Label 'Completed verification text'
        foreach ($code in @('1', '3221225786', 'unknown')) {
            $failedCode = Invoke-AgentSummaryJson -Arguments @{ Report = $verify.ReportPath; ExitCode = $code }
            Assert-TestEqual -Expected 0 -Actual ([int]$failedCode.ProcessExitCode) -Message "Verify exit code $code was not summarised."
            Assert-TestEqual -Expected 'Failed' -Actual ([string]$failedCode.State) -Message "Verify exit code $code was not a failure."
            Assert-TestFalse -Condition ([string]$failedCode.Text).Contains('删干净') -Message "A failed Verify ($code) said everything is gone."
        }

        # A kept item that disappeared: its own section, a next step about it, and a warning for the agent.
        $goneValue = Read-W360JsonFile -Path $verify.ReportPath
        @($goneValue.TaskVerification.Preserved)[0].State = 'Absent'
        $gonePath = New-W360ReportPath -Directory $case.ReportDirectory -Kind 'verify'
        [IO.File]::WriteAllText($gonePath, ($goneValue | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $goneRun = Invoke-AgentSummary -Arguments @{ Report = $gonePath; ExitCode = '0' }
        $goneTitle = Get-SummaryTestText -Key 'Agent.Verify.SectionTitle' -Arguments @((Get-W360Text -Key 'Verify.Section.PreservedGone'), 1)
        Assert-TestTrue -Condition ($goneRun.UserText.Contains($goneTitle)) -Message ("The kept-but-gone section is missing:`r`n" + $goneRun.UserText)
        Assert-TestTrue -Condition ($goneRun.UserText.EndsWith('接下来：' + (Get-SummaryTestText -Key 'Agent.Next.KeptGone'))) -Message ("A kept item that is gone ends with nothing to do:`r`n" + $goneRun.UserText)
        Assert-TestTrue -Condition ($goneRun.AgentLines[0].Contains('kept-gone=1') -and $goneRun.AgentLines[0].Contains('tone=Warning')) -Message ('The kept-gone AGENT line: ' + $goneRun.AgentLines[0])
        Assert-TestNotNull -Actual (Get-AgentLineValue -AgentLines $goneRun.AgentLines -Key 'kept-gone-note') -Message 'The agent is not warned about kept items that are gone.'
        Assert-AgentPlainText -Text $goneRun.UserText -Label 'Kept-gone verification text'

        # Kept anomalies must reach the user and machine-readable guidance without authorising another deletion.
        foreach ($language in @('zh', 'en')) {
            foreach ($states in @(@('Changed'), @('Unknown'), @('Absent', 'Changed', 'Unknown'))) {
                $attentionValue = Read-W360JsonFile -Path $verify.ReportPath
                for ($index = 0; $index -lt $states.Count; $index++) {
                    $attentionValue.TaskVerification.Preserved[$index].State = $states[$index]
                }
                $attentionPath = New-W360ReportPath -Directory $case.ReportDirectory -Kind 'verify'
                [IO.File]::WriteAllText($attentionPath, ($attentionValue | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
                $attention = Invoke-AgentSummaryJson -Arguments @{ Report = $attentionPath; ExitCode = '0'; Language = $language }
                Assert-TestEqual -Expected 'TaskCompleted' -Actual ([string]$attention.State) -Message 'Confirmed deletion is still completed.'
                Assert-TestEqual -Expected 'Warning' -Actual ([string]$attention.Tone) -Message 'Kept anomalies must warn the agent.'
                Assert-TestEqual -Expected @($states | Where-Object { $_ -eq 'Changed' }).Count -Actual ([int]$attention.KeptChangedCount) -Message 'Changed kept items are counted from the item records.'
                Assert-TestEqual -Expected @($states | Where-Object { $_ -eq 'Unknown' }).Count -Actual ([int]$attention.KeptUnknownCount) -Message 'Unknown kept items are counted from the item records.'
                $normalHeadline = if ($language -eq 'zh') { '上次选的都删干净了' } else { 'Everything selected last time is gone' }
                Assert-TestFalse -Condition ([string]$attention.Headline -eq $normalHeadline) -Message 'The headline must call out kept anomalies.'
                Assert-TestTrue -Condition ([string]$attention.NextStep).Contains((Get-SummaryTestText -Key 'Agent.Next.KeptUnconfirmed' -Language $language)) -Message 'The user gets a kept-item follow-up.'
                Assert-TestFalse -Condition ([string]$attention.NextStep).Contains((Get-SummaryTestText -Key 'Agent.Next.Done' -Language $language)) -Message 'The user must not be told nothing is needed.'
                Assert-TestTrue -Condition ([string]$attention.CheckAgainCommand).Contains('-Mode Scan') -Message 'The offered follow-up is a read-only scan.'
                Assert-TestNotNull -Actual (Get-AgentLineValue -AgentLines $attention.AgentLines -Key 'kept-unconfirmed-note') -Message 'The agent must explain the uncertainty.'
                $attentionText = Invoke-AgentSummary -Arguments @{ Report = $attentionPath; ExitCode = '0'; Language = $language }
                Assert-AgentNoRemoveCommand -Run $attentionText -Label 'Kept anomaly verification'
                Assert-AgentPlainText -Text $attentionText.UserText -Label 'Kept anomaly verification text'
            }
        }

        # Finished, but not every place was checked: never "nothing more to do".
        $incompleteValue = Read-W360JsonFile -Path $verify.ReportPath
        $incompleteValue.ScanCoverage = [pscustomobject]@{ Complete = $false; Issues = @([pscustomobject]@{ Area = 'Services'; Target = ''; Detail = 'Simulated' }) }
        $incompletePath = New-W360ReportPath -Directory $case.ReportDirectory -Kind 'verify'
        [IO.File]::WriteAllText($incompletePath, ($incompleteValue | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $incompleteRun = Invoke-AgentSummaryJson -Arguments @{ Report = $incompletePath; ExitCode = '3' }
        Assert-TestEqual -Expected 'TaskCompleted' -Actual ([string]$incompleteRun.State) -Message 'The incomplete verification state.'
        Assert-TestEqual -Expected (Get-SummaryTestText -Key 'Agent.Next.IncompleteRetry') -Actual ([string]$incompleteRun.NextStep) -Message 'An incomplete verification says there is nothing more to do.'
        Assert-TestFalse -Condition ([string]$incompleteRun.Tone -eq 'Success') -Message 'An incomplete verification looks like success.'
        Assert-TestTrue -Condition (@($incompleteRun.AgentLines | Where-Object { ([string]$_).StartsWith('AGENT: if-the-user-wants-a-new-check=') }).Count -eq 1) -Message 'An incomplete verification does not offer a new check.'

        $lockedCase = New-AgentCase -FixtureRoot $fixtureRoot -Name 'verify locked'
        $lockedScan = Invoke-AgentScan -Case $lockedCase
        $lockedIds = @((Invoke-AgentSummaryJson -Arguments (New-AgentDeleteArguments -Report $lockedScan.ReportPath -Choice 'Duohui')).SelectedIds)
        $locked = Invoke-AgentRemoval -Case $lockedCase -Scan $lockedScan -SelectedIds $lockedIds -ReportPath (New-W360ReportPath -Directory $lockedCase.ReportDirectory -Kind 'remove') -RemoveBehavior {
            param($Context, $Path)
            throw (New-Object IO.IOException('The process cannot access the file because it is being used by another process.'))
        }
        $remaining = Invoke-AgentVerify -Case $lockedCase -RemoveReportPath $locked.ReportPath -ReportPath (New-W360ReportPath -Directory $lockedCase.ReportDirectory -Kind 'verify')
        $remainingRun = Invoke-AgentSummaryJson -Arguments @{ Report = $remaining.ReportPath; ExitCode = [string]$remaining.ExitCode }
        Assert-TestEqual -Expected 'TaskRemaining' -Actual ([string]$remainingRun.State) -Message 'Leftovers were not shown as remaining.'
        Assert-TestTrue -Condition ([string]$remainingRun.Text).StartsWith('还有 ') -Message ("The remaining headline:`r`n" + $remainingRun.Text)
        Assert-TestTrue -Condition ([string]$remainingRun.Text).Contains('没删掉（') -Message 'The remaining section is missing.'
        Assert-TestFalse -Condition ([string]$remainingRun.Text).Contains('删干净') -Message 'Leftovers were called gone.'
        Assert-AgentPlainText -Text (@($remainingRun.Lines) -join "`r`n") -Label 'Remaining verification text'
    }

    Complete-TestRun -Run $run
}
finally {
    if ($libraryLoaded) {
        Reset-360CleanupRuntimeProvider
        if ($null -ne $originalKnownFolders) { $script:KnownFolders = $originalKnownFolders }
        if ($null -ne $originalRegistryRoot) { $script:CurrentUserRegistryRoot = $originalRegistryRoot }
    }
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) { Remove-TestDirectory -Path $fixtureRoot }
    if ($null -eq $previousTestMode) { Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue }
    else { $env:WINDOWS_360_CLEANER_TEST_MODE = $previousTestMode }
}
