#requires -Version 5.1
<#
.SYNOPSIS
    Turns a Windows 360 Cleaner report into the plain words an agent tells the user.

.DESCRIPTION
    Read-only helper for agents that run this skill. It reads one Scan, Remove or Verify JSON report (the Mode
    field decides which) and prints short, plain text that says for every 360 product "can be deleted" or
    "won't delete", using the same text table and outcome logic as the guided window
    (scripts\Windows360Cleaner.Library.ps1), so the agent and the window say the same things.

    The last lines start with "AGENT:". They hold machine details for the agent (report hash, selected IDs, the
    exact next command) and are never read out to the user.

    This script never deletes, never starts a process, never elevates, never restarts the PC, never writes a file
    and never uploads anything. -Delete only prints the confirmation text and the exact Remove command; the agent
    runs that command only after the user explicitly said yes.

.PARAMETER Report
    Scan, Remove or Verify JSON report written by scripts\Invoke-360Cleanup.ps1.

.PARAMETER FindLastRemove
    Instead of -Report: look for the newest Remove report of the current Windows user (for example in a new
    conversation after the restart) and print the read-only check command for it. Nothing is deleted or approved.

.PARAMETER Directory
    With -FindLastRemove only: the folder to look in. Default: the Desktop (where reports are written).

.PARAMETER Language
    zh (default) or en.

.PARAMETER ExitCode
    Exit code of the Remove or Verify command that wrote the report, or unknown when it was lost (for example the
    agent's shell timed out). Required for Remove and Verify reports: without it no conclusion is given. Unknown is
    never told as finished. Optional for Scan reports; a non-zero or unknown value makes the check unusable.

.PARAMETER Delete
    Scan reports only. The numbers the user named (1, 2, ... as printed by this script), product keys
    (for example Duohui), or all (every product that has items that can be deleted). "1,2" and "1 2" in one
    value are both accepted. Items that are not deleted are never included. Needs -ScanReportHash.

.PARAMETER ScanReportHash
    The report-sha256 printed with the Scan summary the user answered. With -Delete it is required and must equal
    the SHA-256 of the -Report file, so numbers are never applied to another check result. With a Remove report it
    must equal the Scan report hash the removal was bound to; without it the Remove report's own copy is used.

.PARAMETER IncludeBrowserProfiles
    With -Delete only: also include browser personal data (bookmarks, history) that the Scan report allows to
    delete. Such items are deletable only in a Scan made with -IncludeBrowserProfiles after the user separately
    approved losing that data. Without this switch they are always left out.

.PARAMETER Mode
    Scan, Remove or Verify. Needed only when the report file is missing or unreadable (for example a Remove that
    stopped before writing its report); otherwise the report's own Mode is used and must match.

.PARAMETER Json
    Print one JSON object instead of text. It contains the same plain text plus technical details.

.NOTES
    Exit codes: 0 = summary printed (for -Delete: the selection passed its checks and the Remove command is
    included); 2 = no conclusion (missing or invalid -ExitCode or -ScanReportHash, a missing or unreadable report
    whose step cannot be told from -Mode or its file name, a report of the wrong kind, unexpected extra values; a
    missing report whose step is known still gives 0 with text that never says finished); 3 = -Delete selection
    not accepted (no Remove command is printed); 1 = unexpected error (plain text, no command).
#>
[CmdletBinding(PositionalBinding = $false, DefaultParameterSetName = 'Report')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Report')][string]$Report,
    [Parameter(Mandatory = $true, ParameterSetName = 'FindLastRemove')][switch]$FindLastRemove,
    [Parameter(ParameterSetName = 'FindLastRemove')][string]$Directory,
    [ValidateSet('zh', 'en')][string]$Language = 'zh',
    [Parameter(ParameterSetName = 'Report')][string]$ExitCode,
    [Parameter(ParameterSetName = 'Report')][string[]]$Delete,
    [Parameter(ParameterSetName = 'Report')][string]$ScanReportHash,
    [Parameter(ParameterSetName = 'Report')][switch]$IncludeBrowserProfiles,
    [Parameter(ParameterSetName = 'Report')][ValidateSet('Scan', 'Remove', 'Verify')][string]$Mode,
    [switch]$Json,
    # Values that belong to no parameter (for example "-Delete 1 2" instead of "-Delete 1,2") are refused in plain
    # words instead of failing with a raw error.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$UnexpectedArguments
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SummaryScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
$script:SummaryScriptPath = [IO.Path]::GetFullPath((Join-Path $script:SummaryScriptRoot 'Show-360Summary.ps1'))
$script:SummaryCorePath = [IO.Path]::GetFullPath((Join-Path $script:SummaryScriptRoot 'Invoke-360Cleanup.ps1'))
$script:SummaryListLimit = 5
$script:SummarySectionLimit = 10
$script:SummaryIndent = '   '
$script:SummaryBoundNames = @($PSBoundParameters.Keys)
# Products whose deletion may take away something the user still uses; the agent asks before suggesting deletion.
$script:SummaryAskFirstProducts = @('360Security', '360InstallDir', '360SafeBrowser', '360ChromeBrowser', '360ChromeXBrowser', '360SoftMgr', 'WinToolBox360', '360GameAssistant', '360DriverMaster', '360Zip')
# Products the agent never suggests deleting even when items can be deleted: it is not clear which product they are.
$script:SummaryNoSuggestionProducts = @('Unattributed')
# Characters that cmd, PowerShell or bash still change inside double quotes (plus the quote and line breaks). A
# command line with any of them in a path could run with a different path, so it is never printed.
$script:SummaryUnsafeCommandCharacters = [char[]]@([char]'"', [char]'$', [char]'`', [char]'%', [char]'!', [char]13, [char]10)
# At most this many report files are opened when looking for the last deletion.
$script:SummaryLastRemoveFileLimit = 100

. (Join-Path $script:SummaryScriptRoot 'Windows360Cleaner.Library.ps1')

# Agent-only texts. The shared library owns the table; these keys are added to it at load time, like the window's
# Gui.* keys. They follow the same plain-language policy as the main window (tests/Test-AgentSummary.ps1).
$script:SummaryTexts = @{
    'Agent.Scan.Checked'                  = @('检查完了（检查不会删除任何东西）。', 'The check is finished (checking never deletes anything).')
    'Agent.Scan.FoundDeletable'           = @('找到 {0} 个可以删除的 360 软件：', 'Found {0} product(s) from 360 with items that can be deleted:')
    'Agent.Scan.FoundKeepOnly'            = @('找到了一些 360 相关的内容，但都不删除：', 'Found some 360-related items, but none of them will be deleted:')
    'Agent.Scan.NoMatches'                = @('没有找到 360 的内容。', 'No 360 content was found.')
    'Agent.Scan.NoMatchesIncomplete'      = @('没有找到 360 的内容，但有些地方没检查完，结果可能不全：{0}。', 'No 360 content was found, but some places were not fully checked, so the result may be incomplete: {0}.')
    'Agent.Scan.GroupLine'                = @('{0}. {1} —— {2}', '{0}. {1} - {2}')
    'Agent.Scan.What'                     = @('是什么：{0}', 'What it is: {0}')
    'Agent.Scan.UnattributedWhat'         = @('是 360 留下的东西，但说不清属于哪个 360 软件。', 'Something 360 left behind, but it is unclear which 360 product it belongs to.')
    'Agent.Scan.After'                    = @('删除后：{0}', 'After deleting: {0}')
    'Agent.Scan.CanDeleteItems'           = @('可以删除：{0}', 'Can be deleted: {0}')
    'Agent.Scan.KeptItems'                = @('不删除：{0}', 'Won''t delete: {0}')
    'Agent.Scan.PersonalDataItem'         = @('书签和历史记录（这是你的个人资料）', 'bookmarks and history (this is your personal data)')
    'Agent.Scan.KeepSection'              = @('这些不删除：', 'These won''t be deleted:')
    'Agent.Scan.Coverage'                 = @('（有些地方没检查完，结果可能不全：{0}。）', '(Some places were not fully checked, so the result may be incomplete: {0}.)')
    'Agent.Scan.AskMany'                  = @('要删除哪几个？回复编号就行，比如“删除 1”或“删除 1 和 2”。没说的都会保留。', 'Which ones should be deleted? Just reply with the numbers, for example "delete 1" or "delete 1 and 2". Anything you do not name is kept.')
    'Agent.Scan.AskOne'                   = @('要删除吗？要的话回复“删除 {0}”。不说就都保留。', 'Delete it? If so, reply "delete {0}". Otherwise everything is kept.')
    'Agent.Scan.KeepOnlyNext'             = @('这些都不会删除，不用做什么。', 'None of these will be deleted, so there is nothing to do.')
    'Agent.Scan.StillInstalledNext'       = @('如果想删掉标着“请先正常卸载”的软件，先在 Windows“设置 → 应用”里卸载它，再让我重新检查。', 'To remove software marked "uninstall it normally first", uninstall it in Windows Settings > Apps, then ask me to check again.')
    'Agent.Scan.Unusable'                 = @('这次检查的结果不能用，没有删除任何东西。可以让我重新检查一次。', 'This check result cannot be used, and nothing was deleted. You can ask me to check again.')
    'Agent.Delete.Intro'                  = @('好的。删除前请再看一眼：', 'OK. Please take one more look before deleting:')
    'Agent.Delete.KeptGroup'              = @('{0}. {1} 不删除（{2}），没有算进去。', '{0}. {1} is not deleted ({2}), so it was left out.')
    'Agent.Delete.Skipped'                = @('“{0}”这次不能删：{1}。', '"{0}" cannot be deleted this time: {1}.')
    'Agent.Delete.MoreSkipped'            = @('还有 {0} 项也不能删，没有列出来。', '{0} more item(s) cannot be deleted either and are not listed.')
    'Agent.Delete.SkipReason.ParentContainsProtectedChild' = @('里面有要保留的东西', 'it contains things that must be kept')
    'Agent.Delete.SkipReason.ParentContainsSelectableChild' = @('里面还有你这次没选的 360 内容', 'it contains 360 items you did not choose this time')
    'Agent.Delete.SkipReason.VendorUninstallerNeedsInstallRoot' = @('它要和它所在的文件夹一起删，但那个文件夹这次不能删', 'it must be deleted together with its folder, and that folder cannot be deleted this time')
    'Agent.Delete.FolderInUnchosenProduct' = @('它要和它所在的文件夹一起删，那个文件夹属于你这次没选的“{0}”（编号 {1}）', 'it must be deleted together with its folder, and that folder belongs to "{0}" (number {1}), which you did not choose this time')
    'Agent.Delete.ProfileKept'            = @('“{0}”里是书签、历史记录等个人资料，这次不删。', '"{0}" holds bookmarks, history and other personal data; it is not deleted this time.')
    'Agent.Delete.UnknownNumber'          = @('没有“{0}”这个编号。请用上面列出的编号再说一次。', 'There is no number "{0}". Please say it again with the numbers listed above.')
    'Agent.Delete.NoChoice'               = @('还没说要删除哪几个。请回复上面列出的编号。', 'No product was named yet. Please reply with the numbers listed above.')
    'Agent.Delete.OnlyKept'               = @('选的这些都不删除，没有可以删除的内容。', 'Everything chosen is kept, so there is nothing to delete.')
    'Agent.Delete.NothingLeft'            = @('选的软件里，这次没有能删除的内容。', 'Nothing in the chosen products can be deleted this time.')
    'Agent.Delete.TooMany'                = @('这次选了 {0} 项，一次最多只能删除 {1} 项。', '{0} items were chosen, but at most {1} can be deleted at a time.')
    'Agent.Delete.TooManyFix'             = @('可以先少选几个软件，删完我再帮你重新检查，再删下一批。', 'Choose fewer products first; after deleting, I will check again and we can delete the next batch.')
    'Agent.Delete.TooManyOneProduct'      = @('“{0}”一个软件里就有 {1} 项，在对话里一次最多只能删除 {2} 项。', '"{0}" alone has {1} items, but at most {2} can be deleted at a time in a conversation.')
    'Agent.Delete.TooManyOneProductFix'   = @('想删掉它的话，请双击工具文件夹里的 开始检查.cmd，在打开的窗口里分几次选择删除。', 'To delete it, double-click Start-Check.cmd in the tool folder and delete it in several smaller batches in the window that opens.')
    'Agent.Delete.ReportChanged'          = @('检查结果和你刚才看到的不一样了，编号可能变了。我先把新的结果告诉你，你再说一次要删除哪几个。', 'The check result is not the one you just saw, so the numbers may have changed. I will show you the new result first; then tell me again which ones to delete.')
    'Agent.Delete.NeedCheckResult'        = @('还没法确认你说的编号对应的是哪一次检查结果。', 'It is not yet clear which check result your numbers belong to.')
    'Agent.Delete.Problem'                = @('这样选不行：{0}', 'This choice does not work: {0}')
    'Agent.Delete.ProblemFix'             = @('请重新说一下要删除哪几个；还是不行的话，我帮你重新检查一遍电脑。', 'Please say again which ones to delete; if that does not help, I will check the PC again.')
    'Agent.Delete.NotUsable'              = @('这次检查的结果不能用来删除。请让我重新检查一遍电脑。', 'This check result cannot be used for deleting. Please ask me to check the PC again.')
    'Agent.Delete.NothingDeleted'         = @('没有删除任何东西。', 'Nothing was deleted.')
    'Agent.Confirm.Uac'                   = @('开始删除时，如果 Windows 弹出窗口问你是否允许，请点“是”。', 'When deleting starts, if Windows asks for permission, click "Yes".')
    'Agent.Confirm.Ask'                   = @('确定要删除吗？回复“确定删除”我再开始。', 'Delete these items? Reply "yes, delete" and I will start.')
    'Agent.Remove.Counts'                 = @('删掉 {0} 项，没删掉 {1} 项，不确定 {2} 项。', '{0} deleted, {1} not deleted, {2} not sure.')
    'Agent.Remove.EndUnknown'             = @('没有拿到删除程序结束时的结果，不能确定全部删掉了。', 'How the deletion program ended is not known, so it is not certain that everything was deleted.')
    'Agent.Remove.ProblemsTitle'          = @('没删掉或没做完的：', 'Not deleted or not finished:')
    'Agent.Remove.MoreProblems'           = @('还有 {0} 项没有列出来。', '{0} more not listed.')
    'Agent.Verify.SectionTitle'           = @('{0}（{1} 项）：', '{0} ({1}):')
    'Agent.Verify.Item'                   = @('{0}：{1}', '{0}: {1}')
    'Agent.Next.RemoveCompleted'          = @('建议找个方便的时候重启一次电脑，重启前先保存好正在做的事（我不会替你重启）。重启好了告诉我，我再检查一遍有没有删干净。', 'When convenient, restart the PC once, after saving your work (I will not restart it for you). Tell me when it has restarted and I will check that everything is gone.')
    'Agent.Next.RemoveRestart'            = @('请先保存好正在做的事，再自己重启电脑（我不会替你重启）。重启好了告诉我，我再检查一遍有没有删干净。', 'Save your work, then restart the PC yourself (I will not restart it for you). Tell me when it has restarted and I will check that everything is gone.')
    'Agent.Next.RemovePartial'            = @('可以先重启电脑。重启好了告诉我，我再检查一遍还剩什么。', 'You can restart the PC first. Tell me when it has restarted and I will check what is left.')
    'Agent.Next.RemoveUnknown'            = @('请重启电脑。重启好了告诉我，我再检查一遍，确认现在还剩什么。', 'Please restart the PC. Tell me when it has restarted and I will check what is left now.')
    'Agent.Next.RemoveNoRecord'           = @('请重启电脑。重启好了告诉我，我重新检查一遍电脑，看看现在还有什么。', 'Please restart the PC. Tell me when it has restarted and I will check the whole PC again to see what is there now.')
    'Agent.Next.Done'                     = @('不用再做什么了。', 'There is nothing more to do.')
    'Agent.Next.KeptGone'                 = @('如果还需要不见了的那些内容，请重新安装；别的不用再做什么了。', 'If you still need the items that are gone, install them again; there is nothing else to do.')
    'Agent.Next.IncompleteRetry'          = @('有些地方没检查完，可以过一会儿让我再检查一次。', 'Some places were not fully checked; you can ask me to check again a little later.')
    'Agent.Next.RescanDecide'             = @('要不要我重新检查一遍电脑，再告诉你哪些建议删除？', 'Shall I check the PC again and tell you which items I suggest deleting?')
    'Agent.Next.RescanLook'               = @('要不要我重新检查一遍电脑，看看现在还有什么？', 'Shall I check the PC again to see what is there now?')
    'Agent.Next.VerifyRemaining'          = @('可以重启电脑后让我再检查一次；还是删不掉的话，告诉我，我再帮你看看。', 'You can restart the PC and ask me to check again; if the items still cannot be deleted, tell me and I will look into it.')
    'Agent.Next.VerifyUnknown'            = @('可以重启电脑后让我再检查一次。', 'You can restart the PC and ask me to check again.')
    'Agent.Next.KeptOnly'                 = @('剩下的都不会删除，不用管。想删掉的话，先按上面的说明处理，再让我重新检查。', 'What is left will not be deleted, so you can leave it. To delete it, first do what is described above, then ask me to check again.')
    'Agent.Next.Retry'                    = @('可以让我再检查一次。', 'You can ask me to check again.')
    'Agent.NeedExitCode'                  = @('还不能确定结果，先不要当作已经完成。', 'The result cannot be told yet, so do not treat it as finished.')
    'Agent.NoResult'                      = @('没有找到这一步的结果，没法下结论，先不要当作已经完成。', 'No result of this step was found, so no conclusion can be given; do not treat it as finished.')
    'Agent.WrongKind'                     = @('这份结果不是这一步要用的，没法下结论。', 'This result does not belong to this step, so no conclusion can be given.')
    'Agent.BadArguments'                  = @('这一步没有看懂，没法下结论，也没有删除任何东西。', 'This step could not be understood, so no conclusion is given and nothing was deleted.')
    'Agent.Error'                         = @('这一步出了点问题，没法下结论，先不要当作已经完成。', 'Something went wrong in this step, so no conclusion is given; do not treat it as finished.')
    'Agent.UseWindow'                     = @('有的文件夹名字里带特殊符号（比如 $ 或 %），我没法在对话里安全地替你删除或检查。想删除的话，请双击工具文件夹里的 开始检查.cmd，在打开的窗口里选。', 'Some folder names contain special characters (such as $ or %), so I cannot safely delete or check anything for you in this conversation. To delete, double-click Start-Check.cmd in the tool folder and choose in the window that opens.')
    'Agent.Last.Found'                    = @('找到了上次删除的记录（{0}，当时选了 {1} 项）。', 'Found the last deletion ({0}; {1} item(s) were chosen).')
    'Agent.Last.Check'                    = @('我现在检查一遍有没有删干净，检查不会删除任何东西。', 'I will now check whether everything is gone; checking never deletes anything.')
    'Agent.Last.NotRestarted'             = @('看起来删除之后电脑还没有重启过；有些东西要重启后才会删掉。可以先重启，也可以现在就检查。', 'The PC does not seem to have restarted since the deletion; some items are only removed after a restart. You can restart first or check now.')
    'Agent.Last.NotFound'                 = @('没有找到上次删除的记录。', 'No earlier deletion was found.')
}

function Register-SummaryTexts {
    foreach ($key in @($script:SummaryTexts.Keys)) {
        $pair = $script:SummaryTexts[$key]
        Add-W360Text -Key $key -Chinese ([string]$pair[0]) -English ([string]$pair[1])
    }
}

function Get-SummaryText {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()][AllowEmptyCollection()][object[]]$Arguments
    )

    if ($null -ne $Arguments -and $Arguments.Count -gt 0) { return (Get-W360Text -Key $Key -Arguments $Arguments) }
    return (Get-W360Text -Key $Key)
}

function Test-SummaryCommandSafe {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Values)

    foreach ($value in @($Values)) {
        if ($null -ne $value -and $value.IndexOfAny($script:SummaryUnsafeCommandCharacters) -ge 0) { return $false }
    }
    return $true
}

# A double-quoted command-line argument. Double quotes keep spaces together in cmd, PowerShell and bash, but those
# shells still expand $, the backtick, % and ! inside them, so a value with such a character (or a quote or a line
# break) is refused rather than printed as a command that would run with another path.
function Format-SummaryQuoted {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if (-not (Test-SummaryCommandSafe -Values @($Value))) {
        throw 'A command argument contains a quote, a line break, or a character that a shell changes inside quotes.'
    }
    return ('"' + $Value + '"')
}

# A path shown only as information in an AGENT line (never part of a command).
function Format-SummaryInfoPath {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    return ('"' + ([string]$Value -replace '[\r\n]', ' ') + '"')
}

function Add-SummaryUnsafePathNote {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Next
    )

    $Result.Data['UnsafePath'] = $true
    Add-SummaryAgentLine -Result $Result -Text ('unsafe-path=true; note=A folder name in these paths contains $, a backtick, %, ! or a quote, which shells change inside quotes, so no command line is printed. Never build one yourself. ' + $Next)
}

function Format-SummaryPowerShellCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentText
    )

    $parts = @('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Format-SummaryQuoted -Value $ScriptPath)) + @($ArgumentText)
    return ($parts -join ' ')
}

function Join-SummaryNames {
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Names,
        [int]$Limit = 3
    )

    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($name in @(Get-W360Items -Value $Names)) {
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $unique.Contains([string]$name)) { $unique.Add([string]$name) }
    }
    $separator = Get-W360Text -Key 'Common.ListSeparator'
    if ($unique.Count -le $Limit) { return ($unique.ToArray() -join $separator) }
    $first = @($unique.ToArray() | Select-Object -First $Limit) -join $separator
    return (Get-W360Text -Key 'Ui.Confirm.NameMore' -Arguments @($first, $unique.Count))
}

# Product impact sentences start with "删除后" / "Afterwards,"; the line label already says that.
function ConvertTo-SummaryAfterSentence {
    param([AllowNull()][AllowEmptyString()][string]$Sentence)

    $text = ([string]$Sentence).Trim()
    if ((Get-W360UiLanguage) -eq 'zh') { return ([regex]::Replace($text, '^删除后[，,]?\s*', '')) }
    $stripped = [regex]::Replace($text, '^Afterwards,\s*', '')
    if ($stripped.Length -gt 0 -and $stripped -cne $text) { $stripped = $stripped.Substring(0, 1).ToUpperInvariant() + $stripped.Substring(1) }
    return $stripped
}

# Deletable groups first, then groups where nothing is deleted; each keeps the window's order. The numbers depend
# only on the report content. "Deletable" means effectively deletable (Get-W360EffectiveDeletableIds), exactly like
# the window: an item that can never pass the selection check in this result counts as kept. The Scan text and
# -Delete both number through this function with the same set, so their numbers are always the same.
function Get-SummaryNumberedGroups {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory = $true)][object]$Effective
    )

    $groups = @(Get-W360FindingGroups -Findings $Findings -Effective $Effective)
    $ordered = @($groups | Where-Object { [int]$_.SelectableCount -gt 0 }) + @($groups | Where-Object { [int]$_.SelectableCount -eq 0 })
    $number = 0
    foreach ($group in $ordered) {
        $number++
        [pscustomobject]@{ Number = $number; Group = $group }
    }
}

# What deleting the deletable items of one product does. The product sentence speaks about the whole product, so it is
# told only when every item of the product can be deleted, or when a deletable item's own effect already says it (a
# program folder of the product, or an uninstaller that came with 360). Otherwise, for example when the folder that
# sentence is about is not deleted, each deletable item's own effect is told instead, like the window's item text.
function Get-SummaryGroupImpact {
    param(
        [Parameter(Mandatory = $true)][object]$Group,
        [Parameter(Mandatory = $true)][object]$Effective
    )

    $key = [string]$Group.Key
    $groupFindings = @($Group.Findings)
    $deletable = @($groupFindings | Where-Object { Test-W360FindingDeletable -Finding $_ -Effective $Effective })
    $wholeProduct = ($deletable.Count -eq $groupFindings.Count)
    $productImpact = if ($key -ne 'Unattributed') { [string](Get-W360ProductInfo -ProductKey $key).Impact } else { '' }
    $uninstallerImpact = Get-W360Text -Key 'Impact.VendorUninstaller.Confirm'
    # Effects the product sentence does not cover and a user must hear before choosing.
    $extraKeys = @('Impact.Process', 'Impact.BrowserProfile')
    if ($key -ne '360InstallDir') { $extraKeys += 'Impact.SharedInstallDir' }
    $extraTexts = @($extraKeys | ForEach-Object { Get-W360Text -Key $_ })

    $tellProduct = ($productImpact.Length -gt 0 -and $wholeProduct)
    $own = New-Object System.Collections.ArrayList
    foreach ($finding in $deletable) {
        if (Test-W360FindingIsUninstaller -Finding $finding) {
            if ($productImpact.Length -gt 0) { $tellProduct = $true }
            [void]$own.Add([pscustomobject]@{ Text = $uninstallerImpact; Extra = $true })
            continue
        }
        $impact = Get-W360ImpactText -Finding $finding -Effective $Effective
        # A program folder's effect ends with the product sentence; the product sentence is told once instead.
        if ($productImpact.Length -gt 0 -and $impact.EndsWith($productImpact, [StringComparison]::Ordinal)) {
            $tellProduct = $true
            continue
        }
        [void]$own.Add([pscustomobject]@{ Text = $impact; Extra = ($extraTexts -ccontains $impact) })
    }

    $sentences = New-Object System.Collections.Generic.List[string]
    if ($tellProduct) { $sentences.Add((ConvertTo-SummaryAfterSentence -Sentence $productImpact)) }
    foreach ($entry in @($own)) {
        # With the product sentence, only the effects it does not cover follow it.
        if ($tellProduct -and -not [bool]$entry.Extra) { continue }
        if (-not $sentences.Contains([string]$entry.Text)) { $sentences.Add([string]$entry.Text) }
    }
    return ($sentences.ToArray() -join (Get-W360Text -Key 'Common.SentenceSeparator'))
}

function Get-SummaryKeptItemText {
    param(
        [Parameter(Mandatory = $true)][object]$Finding,
        [Parameter(Mandatory = $true)][object]$Effective
    )

    $status = Get-W360FindingStatus -Finding $Finding -Effective $Effective
    if ($status.Code -eq 'PersonalDataKept') { return (Get-SummaryText -Key 'Agent.Scan.PersonalDataItem') }
    return (Get-W360Text -Key 'Ui.Confirm.KeptReason' -Arguments @((Get-W360FindingDisplayName -Finding $Finding), (Get-W360KeepReason -StatusText $status.Text)))
}

function Get-SummaryCoverageText {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Issues)

    return (Join-SummaryNames -Names @(@(Get-W360Items -Value $Issues) | ForEach-Object { [string]$_.AreaText }) -Limit 6)
}

function New-SummaryResult {
    param([string]$Kind)

    return [pscustomobject]@{
        Kind       = $Kind
        Lines      = New-Object System.Collections.Generic.List[string]
        AgentLines = New-Object System.Collections.Generic.List[string]
        Data       = [ordered]@{}
        ExitCode   = 0
    }
}

function Add-SummaryAgentLine {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $Result.AgentLines.Add(('AGENT: ' + $Text))
}

function Get-SummaryBool {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'unknown' }
    if ([bool]$Value) { return 'true' }
    return 'false'
}

function New-SummaryReportPath {
    param(
        [Parameter(Mandatory = $true)][string]$NextTo,
        [Parameter(Mandatory = $true)][ValidateSet('scan', 'remove', 'verify')][string]$Kind
    )

    # Only a new file name is worked out here; nothing is created. The core refuses to overwrite an existing file,
    # so running the same command twice stops before it changes anything.
    $directory = [IO.Path]::GetDirectoryName($NextTo)
    if ([string]::IsNullOrWhiteSpace($directory) -or -not [IO.Directory]::Exists($directory)) {
        $directory = Get-W360DefaultReportDirectory
    }
    return (New-W360ReportPath -Directory $directory -Kind $Kind)
}

function Add-SummaryNeedExitCode {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$ReportMode
    )

    $Result.Lines.Add((Get-SummaryText -Key 'Agent.NeedExitCode'))
    $Result.ExitCode = 2
    $Result.Data['State'] = 'NeedExitCode'
    $problem = if ($script:ExitCodeInvalid) {
        "-ExitCode must be a whole number or unknown, not '{0}'" -f ([string]$ExitCode -replace '[\r\n]', ' ')
    }
    else { '-ExitCode is required for {0} reports' -f $ReportMode }
    Add-SummaryAgentLine -Result $Result -Text ('mode={0}; state=NeedExitCode; error={1}; do not tell the user it finished' -f $ReportMode, $problem)
    if ($ReportMode -eq 'Scan') { return }
    if (Test-SummaryCommandSafe -Values @($script:SummaryScriptPath, $ReportPath)) {
        $rerun = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @(
            '-Report', (Format-SummaryQuoted -Value $ReportPath), '-Mode', $ReportMode, '-Language', (Get-W360UiLanguage),
            '-ExitCode', '<exit code of the command that wrote this report, or unknown>')
        Add-SummaryAgentLine -Result $Result -Text ('rerun=' + $rerun)
    }
    else {
        Add-SummaryUnsafePathNote -Result $Result -Next 'Tell the user the result is not known yet.'
    }
}

function Build-ScanSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $code = if ($script:ExitCodeGiven) { $script:ExitCodeValue } else { 0 }
    $outcome = Get-W360ScanOutcome -ExitCode $code -ReportPath $ReportPath -StdoutLines @() -StderrLines @()
    $lines = $Result.Lines
    $checked = (Get-SummaryText -Key 'Agent.Scan.Checked') + (Get-W360Text -Key 'Common.SentenceSeparator')
    $numbered = @()
    $groupData = New-Object System.Collections.ArrayList
    $stillInstalled = $false
    $commandsSafe = Test-SummaryCommandSafe -Values @($script:SummaryScriptPath, $script:SummaryCorePath, $ReportPath)

    switch ($outcome.State) {
        'NoMatches' { $lines.Add(($checked + (Get-SummaryText -Key 'Agent.Scan.NoMatches'))) }
        'NoMatchesIncomplete' {
            $lines.Add(($checked + (Get-SummaryText -Key 'Agent.Scan.NoMatchesIncomplete' -Arguments @((Get-SummaryCoverageText -Issues $outcome.CoverageIssues)))))
            $lines.Add((Get-SummaryText -Key 'Agent.Next.IncompleteRetry'))
        }
        'Findings' {
            $effective = Get-W360OutcomeEffectiveDeletable -Outcome $outcome
            $numbered = @(Get-SummaryNumberedGroups -Findings $outcome.Findings -Effective $effective)
            $deletable = @($numbered | Where-Object { [int]$_.Group.SelectableCount -gt 0 })
            $keepOnly = @($numbered | Where-Object { [int]$_.Group.SelectableCount -eq 0 })
            if ($deletable.Count -gt 0) {
                $lines.Add(($checked + (Get-SummaryText -Key 'Agent.Scan.FoundDeletable' -Arguments @($deletable.Count))))
            }
            else {
                $lines.Add(($checked + (Get-SummaryText -Key 'Agent.Scan.FoundKeepOnly')))
            }
            $lines.Add('')
            foreach ($entry in $deletable) {
                $group = $entry.Group
                $lines.Add((Get-SummaryText -Key 'Agent.Scan.GroupLine' -Arguments @($entry.Number, [string]$group.DisplayName, [string]$group.DecisionText)))
                # The shared product description says "only the name looks like 360", which fits kept items; items
                # that can be deleted matched the detection, so they get their own sentence.
                $what = if ([string]$group.Key -eq 'Unattributed') { Get-SummaryText -Key 'Agent.Scan.UnattributedWhat' } else { [string]$group.Description }
                $lines.Add(($script:SummaryIndent + (Get-SummaryText -Key 'Agent.Scan.What' -Arguments @($what))))
                $deletableNames = @(@($group.Findings) | Where-Object { Test-W360FindingDeletable -Finding $_ -Effective $effective } | ForEach-Object { Get-W360FindingDisplayName -Finding $_ })
                $keptTexts = @(@($group.Findings) | Where-Object { -not (Test-W360FindingDeletable -Finding $_ -Effective $effective) } | ForEach-Object { Get-SummaryKeptItemText -Finding $_ -Effective $effective })
                if ($keptTexts.Count -gt 0) {
                    $lines.Add(($script:SummaryIndent + (Get-SummaryText -Key 'Agent.Scan.CanDeleteItems' -Arguments @((Join-SummaryNames -Names $deletableNames)))))
                }
                $lines.Add(($script:SummaryIndent + (Get-SummaryText -Key 'Agent.Scan.After' -Arguments @((Get-SummaryGroupImpact -Group $group -Effective $effective)))))
                if ($keptTexts.Count -gt 0) {
                    $lines.Add(($script:SummaryIndent + (Get-SummaryText -Key 'Agent.Scan.KeptItems' -Arguments @((Join-SummaryNames -Names $keptTexts)))))
                }
            }
            if ($keepOnly.Count -gt 0) {
                if ($deletable.Count -gt 0) {
                    $lines.Add('')
                    $lines.Add((Get-SummaryText -Key 'Agent.Scan.KeepSection'))
                }
                $plainKeep = Get-W360Text -Key 'Status.NotRemovable.Text'
                foreach ($entry in $keepOnly) {
                    $group = $entry.Group
                    $lines.Add((Get-SummaryText -Key 'Agent.Scan.GroupLine' -Arguments @($entry.Number, [string]$group.DisplayName, [string]$group.KeepReasonText)))
                    if ([string]$group.KeepReasonText -ceq $plainKeep) {
                        $reasons = @(@($group.Findings) | ForEach-Object { Get-SummaryKeptItemText -Finding $_ -Effective $effective })
                        $lines.Add(($script:SummaryIndent + (Join-SummaryNames -Names $reasons)))
                    }
                }
            }
            foreach ($finding in @($outcome.Findings)) {
                if ((Get-W360FindingStatus -Finding $finding).Code -eq 'StillInstalled') { $stillInstalled = $true }
            }
            if ($outcome.CoverageComplete -eq $false) {
                $lines.Add('')
                $lines.Add((Get-SummaryText -Key 'Agent.Scan.Coverage' -Arguments @((Get-SummaryCoverageText -Issues $outcome.CoverageIssues))))
            }
            $lines.Add('')
            if ($deletable.Count -gt 0 -and -not $commandsSafe) { $lines.Add((Get-SummaryText -Key 'Agent.UseWindow')) }
            elseif ($deletable.Count -gt 1) { $lines.Add((Get-SummaryText -Key 'Agent.Scan.AskMany')) }
            elseif ($deletable.Count -eq 1) { $lines.Add((Get-SummaryText -Key 'Agent.Scan.AskOne' -Arguments @($deletable[0].Number))) }
            else { $lines.Add((Get-SummaryText -Key 'Agent.Scan.KeepOnlyNext')) }
            if ($stillInstalled) { $lines.Add((Get-SummaryText -Key 'Agent.Scan.StillInstalledNext')) }

            foreach ($entry in $numbered) {
                $group = $entry.Group
                [void]$groupData.Add([ordered]@{
                    Number         = $entry.Number
                    ProductKey     = [string]$group.Key
                    DisplayName    = [string]$group.DisplayName
                    CanDelete      = ([int]$group.SelectableCount -gt 0)
                    DeletableCount = [int]$group.SelectableCount
                    KeptCount      = [int]$group.ReviewCount
                    DecisionText   = $(if ([int]$group.SelectableCount -gt 0) { [string]$group.DecisionText } else { [string]$group.KeepReasonText })
                    MayStillBeInUse = ($script:SummaryAskFirstProducts -contains [string]$group.Key)
                    ProductUnclear = ($script:SummaryNoSuggestionProducts -contains [string]$group.Key)
                    SelectionIds   = [string[]]@($group.SelectableIds)
                })
            }
        }
        default {
            $lines.Add((Get-W360Text -Key $(if ($outcome.State -eq 'InvalidReport') { 'Scan.Invalid.Headline' } else { 'Scan.Failed.Headline' })))
            $lines.Add((Get-SummaryText -Key 'Agent.Scan.Unusable'))
        }
    }

    $Result.Data['State'] = [string]$outcome.State
    $Result.Data['ReportSha256'] = [string]$outcome.ReportHash
    $Result.Data['CoverageComplete'] = $outcome.CoverageComplete
    $Result.Data['CoverageIssues'] = [string[]]@(@($outcome.CoverageIssues) | ForEach-Object { [string]$_.AreaText })
    $Result.Data['Groups'] = @($groupData)

    Add-SummaryAgentLine -Result $Result -Text ('mode=Scan; state={0}; report={1}; report-sha256={2}; coverage-complete={3}' -f `
            $outcome.State, (Format-SummaryInfoPath -Value $ReportPath), $(if ($outcome.ReportHash) { $outcome.ReportHash } else { 'none' }), (Get-SummaryBool $outcome.CoverageComplete))
    if ($numbered.Count -gt 0) {
        $groupText = @($numbered | ForEach-Object { '{0}:{1}({2})' -f $_.Number, $_.Group.Key, $(if ([int]$_.Group.SelectableCount -gt 0) { 'can-delete' } else { 'keep' }) }) -join ','
        Add-SummaryAgentLine -Result $Result -Text ('groups=' + $groupText)
        $askFirst = @($numbered | Where-Object { [int]$_.Group.SelectableCount -gt 0 -and $script:SummaryAskFirstProducts -contains [string]$_.Group.Key } | ForEach-Object { [string]$_.Number })
        Add-SummaryAgentLine -Result $Result -Text ('ask-if-still-used=' + $(if ($askFirst.Count -gt 0) { $askFirst -join ',' } else { 'none' }))
        $noSuggestion = @($numbered | Where-Object { [int]$_.Group.SelectableCount -gt 0 -and $script:SummaryNoSuggestionProducts -contains [string]$_.Group.Key } | ForEach-Object { [string]$_.Number })
        Add-SummaryAgentLine -Result $Result -Text ('do-not-suggest=' + $(if ($noSuggestion.Count -gt 0) { $noSuggestion -join ',' } else { 'none' }))
    }
    if (@($numbered | Where-Object { [int]$_.Group.SelectableCount -gt 0 }).Count -gt 0) {
        if ($commandsSafe) {
            $next = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @(
                '-Report', (Format-SummaryQuoted -Value $ReportPath), '-Language', (Get-W360UiLanguage), '-ScanReportHash', [string]$outcome.ReportHash,
                '-Delete', '<the numbers the user named, comma-separated>')
            Add-SummaryAgentLine -Result $Result -Text ('after-the-user-names-numbers=' + $next)
            Add-SummaryAgentLine -Result $Result -Text 'note=Nothing is selected yet. You may suggest deleting can-delete products; for numbers in ask-if-still-used, first ask whether the user still uses them (also before "all"); for numbers in do-not-suggest, say they can be deleted but let the user decide. Never suggest deleting keep products. Your suggestion is not approval: only numbers the user names count, and "all" means only products marked can-delete. The numbers belong to this result only: after a new check, show the new list and ask again.'
        }
        else {
            Add-SummaryUnsafePathNote -Result $Result -Next 'Deleting is only possible in the window (开始检查.cmd), where the user chooses.'
        }
    }
    elseif (@('Failed', 'InvalidReport') -contains [string]$outcome.State -or [string]$outcome.State -eq 'NoMatchesIncomplete') {
        $scanPath = New-SummaryReportPath -NextTo $ReportPath -Kind 'scan'
        if (Test-SummaryCommandSafe -Values @($script:SummaryScriptPath, $script:SummaryCorePath, $scanPath)) {
            Add-SummaryAgentLine -Result $Result -Text ('check-again=' + (Format-SummaryPowerShellCommand -ScriptPath $script:SummaryCorePath -ArgumentText @('-Mode', 'Scan', '-ReportPath', (Format-SummaryQuoted -Value $scanPath))))
            Add-SummaryAgentLine -Result $Result -Text ('then=' + (Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @('-Report', (Format-SummaryQuoted -Value $scanPath), '-Language', (Get-W360UiLanguage))))
        }
        else {
            Add-SummaryUnsafePathNote -Result $Result -Next 'A new check is only possible in the window (开始检查.cmd).'
        }
    }
}

function Add-SummaryDeleteRejection {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Messages
    )

    foreach ($message in $Messages) { if (-not [string]::IsNullOrWhiteSpace($message)) { $Result.Lines.Add($message) } }
    $Result.Lines.Add((Get-SummaryText -Key 'Agent.Delete.NothingDeleted'))
    $Result.ExitCode = 3
    $Result.Data['Accepted'] = $false
    $Result.Data['Reason'] = $Reason
    Add-SummaryAgentLine -Result $Result -Text ('mode=Delete; accepted=false; reason={0}; no remove command is given. Do not run a removal; ask the user again.' -f $Reason)
}

function Build-DeleteSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [AllowEmptyCollection()][string[]]$Choices
    )

    $Result.Data['Action'] = 'Delete'
    $Result.Data['Accepted'] = $false
    # A Scan that did not end normally (non-zero or unknown exit code) is never used for deleting.
    $code = if ($script:ExitCodeGiven) { $script:ExitCodeValue } else { 0 }
    $outcome = Get-W360ScanOutcome -ExitCode $code -ReportPath $ReportPath -StdoutLines @() -StderrLines @()
    if ($outcome.State -ne 'Findings') {
        $Result.Data['State'] = [string]$outcome.State
        $message = if (@('NoMatches', 'NoMatchesIncomplete') -contains [string]$outcome.State) { Get-SummaryText -Key 'Agent.Scan.NoMatches' } else { Get-SummaryText -Key 'Agent.Delete.NotUsable' }
        Add-SummaryDeleteRejection -Result $Result -Reason ('Scan' + $outcome.State) -Messages @($message)
        return
    }
    $Result.Data['State'] = 'Findings'
    $commandsSafe = Test-SummaryCommandSafe -Values @($script:SummaryScriptPath, $script:SummaryCorePath, $ReportPath)

    # The numbers belong to the Scan summary the user answered. Its report-sha256 must be passed back and must be the
    # hash of this file, so a newer or other check result (with other numbers) is never used on a guess.
    $expectedHash = ([string]$ScanReportHash).Trim()
    if ($expectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
        Add-SummaryDeleteRejection -Result $Result -Reason 'NeedScanReportHash' -Messages @((Get-SummaryText -Key 'Agent.Delete.NeedCheckResult'))
        $Result.ExitCode = 2
        Add-SummaryAgentLine -Result $Result -Text 'error=-Delete needs -ScanReportHash with the report-sha256 of the Scan summary the user answered. Use the after-the-user-names-numbers command of that summary; never take the hash from another result.'
        return
    }
    if (-not $expectedHash.Equals([string]$outcome.ReportHash, [StringComparison]::OrdinalIgnoreCase)) {
        Add-SummaryDeleteRejection -Result $Result -Reason 'ReportChanged' -Messages @((Get-SummaryText -Key 'Agent.Delete.ReportChanged'))
        if ($commandsSafe) {
            Add-SummaryAgentLine -Result $Result -Text ('show-the-new-list=' + (Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @(
                        '-Report', (Format-SummaryQuoted -Value $ReportPath), '-Language', (Get-W360UiLanguage))))
        }
        Add-SummaryAgentLine -Result $Result -Text 'note=The numbers the user named belong to another check result. Show the current list and ask again; never map the old numbers yourself.'
        return
    }
    if (-not $commandsSafe) {
        Add-SummaryDeleteRejection -Result $Result -Reason 'UnsafePath' -Messages @((Get-SummaryText -Key 'Agent.UseWindow'))
        Add-SummaryUnsafePathNote -Result $Result -Next 'Deleting is only possible in the window (开始检查.cmd), where the user chooses.'
        return
    }
    $findings = @($outcome.Findings)
    # The same effectively deletable set and numbering as the Scan summary the user answered.
    $effective = Get-W360OutcomeEffectiveDeletable -Outcome $outcome
    $numbered = @(Get-SummaryNumberedGroups -Findings $findings -Effective $effective)

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($choice in @(Get-W360Items -Value $Choices)) {
        foreach ($part in ([regex]::Split([string]$choice, '[\s,，、;；]+'))) {
            if (-not [string]::IsNullOrWhiteSpace($part)) { $tokens.Add((ConvertTo-SummaryChoiceToken -Token $part.Trim())) }
        }
    }
    $Result.Data['Requested'] = [string[]]$tokens.ToArray()
    if ($tokens.Count -eq 0) {
        Add-SummaryDeleteRejection -Result $Result -Reason 'NoChoice' -Messages @((Get-SummaryText -Key 'Agent.Delete.NoChoice'))
        return
    }

    $chosenNumbers = New-Object 'System.Collections.Generic.SortedSet[int]'
    foreach ($token in $tokens) {
        $matched = @()
        if ($token -ieq 'all') {
            # "All" means every product that has something that can be deleted; with none, nothing is chosen.
            foreach ($entry in @($numbered | Where-Object { [int]$_.Group.SelectableCount -gt 0 })) { [void]$chosenNumbers.Add([int]$entry.Number) }
            continue
        }
        elseif ($token -match '^[0-9]{1,6}$') {
            $number = 0
            if ([int]::TryParse($token, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                $matched = @($numbered | Where-Object { [int]$_.Number -eq $number })
            }
        }
        else {
            # Product keys match exactly (ignoring case only); a part of a key never picks a product.
            $matched = @($numbered | Where-Object { ([string]$_.Group.Key).Equals($token, [StringComparison]::OrdinalIgnoreCase) })
        }
        if ($matched.Count -eq 0) {
            # A number that is not on the list may be a typo for another product: nothing is deleted on a guess.
            Add-SummaryDeleteRejection -Result $Result -Reason 'UnknownNumber' -Messages @((Get-SummaryText -Key 'Agent.Delete.UnknownNumber' -Arguments @($token)))
            return
        }
        foreach ($entry in $matched) { [void]$chosenNumbers.Add([int]$entry.Number) }
    }

    $chosen = @($numbered | Where-Object { $chosenNumbers.Contains([int]$_.Number) })
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($chosen | Where-Object { [int]$_.Group.SelectableCount -eq 0 })) {
        $notes.Add((Get-SummaryText -Key 'Agent.Delete.KeptGroup' -Arguments @($entry.Number, [string]$entry.Group.DisplayName, (Get-W360KeepReason -StatusText ([string]$entry.Group.KeepReasonText)))))
    }
    $deletableChosen = @($chosen | Where-Object { [int]$_.Group.SelectableCount -gt 0 })
    $Result.Data['ChosenNumbers'] = [int[]]@($chosen | ForEach-Object { [int]$_.Number })
    if ($deletableChosen.Count -eq 0) {
        Add-SummaryDeleteRejection -Result $Result -Reason 'OnlyKept' -Messages (@($notes.ToArray()) + @((Get-SummaryText -Key 'Agent.Delete.OnlyKept')))
        return
    }

    # Browser personal data is deletable only in a Scan made with the separate opt-in, and even then it is left out
    # unless this call also asked for it.
    $scanReport = Get-W360PropertyValue -Object $outcome.Report -Name 'ApprovalContext'
    $scanOptions = Get-W360PropertyValue -Object $scanReport -Name 'Options'
    $scanIncludesProfiles = ConvertTo-W360Bool (Get-W360PropertyValue -Object $scanOptions -Name 'IncludeBrowserProfiles')
    $candidateIds = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $deletableChosen) {
        foreach ($finding in @($entry.Group.Findings)) {
            # Only effectively deletable items are candidates; the others are listed as kept in the confirmation.
            if (-not (Test-W360FindingDeletable -Finding $finding -Effective $effective)) { continue }
            if ((Test-W360FindingIsBrowserProfile -Finding $finding) -and -not $IncludeBrowserProfiles) {
                $notes.Add((Get-SummaryText -Key 'Agent.Delete.ProfileKept' -Arguments @((Get-W360FindingDisplayName -Finding $finding))))
                continue
            }
            $id = Get-W360FindingSelectionId -Finding $finding
            if (-not $candidateIds.Contains($id)) { $candidateIds.Add($id) }
        }
    }

    # Shrink-only: exactly the window's "select all that can be deleted" helper, starting from nothing selected.
    $selection = Get-W360DeletableSelection -Findings $findings -CandidateIds $candidateIds.ToArray() -SelectedIds @()
    $skipped = @($selection.Removed)
    $shownSkipped = [Math]::Min($skipped.Count, $script:SummaryListLimit)
    for ($index = 0; $index -lt $shownSkipped; $index++) {
        $reason = Get-SummaryText -Key ('Agent.Delete.SkipReason.' + [string]$skipped[$index].Code)
        if ([string]$skipped[$index].Code -eq 'VendorUninstallerNeedsInstallRoot') {
            # Every offered item passes the check together with the others, so an uninstaller is usually left out because
            # its folder belongs to a product the user did not name; that product is named instead of "cannot be deleted".
            $folderIds = @(@(Get-W360ArrayProperty -Object $skipped[$index] -Name 'RelatedIds') | ForEach-Object { [string]$_ })
            $folderEntry = @($numbered | Where-Object {
                    $entryIds = @($_.Group.SelectableIds)
                    @($folderIds | Where-Object { $entryIds -contains $_ }).Count -gt 0
                } | Select-Object -First 1)
            if ($folderEntry.Count -eq 1 -and -not $chosenNumbers.Contains([int]$folderEntry[0].Number)) {
                $reason = Get-SummaryText -Key 'Agent.Delete.FolderInUnchosenProduct' -Arguments @([string]$folderEntry[0].Group.DisplayName, $folderEntry[0].Number)
            }
        }
        $notes.Add((Get-SummaryText -Key 'Agent.Delete.Skipped' -Arguments @([string]$skipped[$index].DisplayName, $reason)))
    }
    if ($skipped.Count -gt $shownSkipped) { $notes.Add((Get-SummaryText -Key 'Agent.Delete.MoreSkipped' -Arguments @($skipped.Count - $shownSkipped))) }
    $Result.Data['SkippedItems'] = @($skipped | ForEach-Object { [ordered]@{ DisplayName = [string]$_.DisplayName; Code = [string]$_.Code; SelectionId = [string]$_.SelectionId } })

    $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds @($selection.Ids)
    $Result.Data['SelectedIds'] = [string[]]@($plan.SelectedIds)
    if (-not [bool]$plan.CanSubmit) {
        $messages = New-Object System.Collections.Generic.List[string]
        foreach ($note in $notes) { $messages.Add($note) }
        $codes = @(@($plan.Problems) | ForEach-Object { [string]$_.Code } | Select-Object -Unique)
        $reasonCode = $codes -join '+'
        if ($codes -contains 'NothingSelected') { $messages.Add((Get-SummaryText -Key 'Agent.Delete.NothingLeft')) }
        elseif ($codes -contains 'TooMany') {
            # Choosing fewer products cannot help when one product alone is over the limit: the window, where single
            # items can be chosen, is the only way to delete it in batches.
            $selectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($selectedId in @($plan.SelectedIds)) { [void]$selectedSet.Add([string]$selectedId) }
            $largest = $null
            $largestCount = 0
            foreach ($entry in $deletableChosen) {
                $count = @(@($entry.Group.SelectableIds) | Where-Object { $selectedSet.Contains([string]$_) }).Count
                if ($count -gt $largestCount) { $largest = $entry; $largestCount = $count }
            }
            if ($null -ne $largest -and $largestCount -gt $script:W360MaxSelectedIds) {
                $reasonCode = 'TooManyInOneProduct'
                $Result.Data['TooManyProductKey'] = [string]$largest.Group.Key
                $messages.Add((Get-SummaryText -Key 'Agent.Delete.TooManyOneProduct' -Arguments @([string]$largest.Group.DisplayName, $largestCount, $script:W360MaxSelectedIds)))
                $messages.Add((Get-SummaryText -Key 'Agent.Delete.TooManyOneProductFix'))
            }
            else {
                $messages.Add((Get-SummaryText -Key 'Agent.Delete.TooMany' -Arguments @(@($plan.SelectedIds).Count, $script:W360MaxSelectedIds)))
                $messages.Add((Get-SummaryText -Key 'Agent.Delete.TooManyFix'))
            }
        }
        else {
            foreach ($problem in @($plan.Problems)) { $messages.Add((Get-SummaryText -Key 'Agent.Delete.Problem' -Arguments @([string]$problem.Message))) }
            $messages.Add((Get-SummaryText -Key 'Agent.Delete.ProblemFix'))
        }
        Add-SummaryDeleteRejection -Result $Result -Reason $reasonCode -Messages $messages.ToArray()
        return
    }

    $selectedProfiles = @(@($plan.SelectedFindings) | Where-Object { Test-W360FindingIsBrowserProfile -Finding $_ })
    $useProfiles = ($selectedProfiles.Count -gt 0)
    if ($useProfiles -and -not $scanIncludesProfiles) {
        # A deletable profile needs a Scan made with the opt-in; the core would refuse anyway.
        Add-SummaryDeleteRejection -Result $Result -Reason 'ProfileWithoutOptIn' -Messages @((Get-SummaryText -Key 'Agent.Delete.NotUsable'))
        return
    }

    $lines = $Result.Lines
    $lines.Add((Get-SummaryText -Key 'Agent.Delete.Intro'))
    if ($notes.Count -gt 0) { foreach ($note in $notes) { $lines.Add($note) } }
    $lines.Add('')
    # Items of a named product that were left out are told as "cannot be deleted on its own this time", not "not selected".
    $skippedIds = [string[]]@($skipped | ForEach-Object { [string]$_.SelectionId })
    foreach ($line in ((Get-W360ConfirmText -Plan $plan -AllFindings $findings -KeptLineLimit $script:SummarySectionLimit -Effective $effective -SkippedIds $skippedIds) -split "`r`n")) { $lines.Add($line) }
    $lines.Add('')
    $lines.Add((Get-W360Text -Key 'Ui.Confirm.PermanentDelete'))
    if ([bool]$plan.VendorUninstallerSelected) { $lines.Add((Get-W360Text -Key 'Ui.Confirm.VendorWarning')) }
    $lines.Add((Get-W360Text -Key 'Ui.Confirm.CloseApps'))
    $lines.Add((Get-SummaryText -Key 'Agent.Confirm.Uac'))
    $lines.Add('')
    $lines.Add((Get-SummaryText -Key 'Agent.Confirm.Ask'))

    $hash = [string]$outcome.ReportHash
    $ids = [string[]]@($plan.SelectedIds)
    $idText = $ids -join ';'
    $removePath = New-SummaryReportPath -NextTo $ReportPath -Kind 'remove'
    $removeArguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @('-Mode', 'Remove', '-ApprovedReport', $ReportPath, '-ApprovedReportHash', $hash, '-SelectedFindingIds', $idText,
            '-ConfirmRemoval', '-ConfirmationPhrase', 'REMOVE-CONFIRMED-360', '-ReportPath', $removePath)) { $removeArguments.Add([string]$argument) }
    if ($useProfiles) {
        foreach ($argument in @('-IncludeBrowserProfiles', '-BrowserProfileConfirmation', 'DELETE-360-BROWSER-DATA')) { $removeArguments.Add($argument) }
    }
    $removeText = @(
        '-Mode', 'Remove', '-ApprovedReport', (Format-SummaryQuoted -Value $ReportPath), '-ApprovedReportHash', $hash,
        '-SelectedFindingIds', (Format-SummaryQuoted -Value $idText), '-ConfirmRemoval', '-ConfirmationPhrase', 'REMOVE-CONFIRMED-360',
        '-ReportPath', (Format-SummaryQuoted -Value $removePath))
    if ($useProfiles) { $removeText += @('-IncludeBrowserProfiles', '-BrowserProfileConfirmation', 'DELETE-360-BROWSER-DATA') }
    $removeCommand = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryCorePath -ArgumentText $removeText
    $afterRemove = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @(
        '-Report', (Format-SummaryQuoted -Value $removePath), '-Mode', 'Remove', '-Language', (Get-W360UiLanguage), '-ScanReportHash', $hash,
        '-ExitCode', '<exit code of the remove command, or unknown>')

    $Result.Data['Accepted'] = $true
    $Result.Data['ReportSha256'] = $hash
    $Result.Data['SelectedCount'] = $ids.Count
    $Result.Data['VendorUninstallerSelected'] = [bool]$plan.VendorUninstallerSelected
    $Result.Data['IncludeBrowserProfiles'] = $useProfiles
    $Result.Data['RemoveReportPath'] = $removePath
    $Result.Data['RemoveCommand'] = $removeCommand
    $Result.Data['RemoveScript'] = $script:SummaryCorePath
    $Result.Data['RemoveArguments'] = [string[]]$removeArguments.ToArray()
    $Result.Data['AfterRemoveCommand'] = $afterRemove

    Add-SummaryAgentLine -Result $Result -Text ('mode=Delete; accepted=true; report-sha256={0}; selected-count={1}; include-browser-profiles={2}' -f $hash, $ids.Count, $(if ($useProfiles) { 'true' } else { 'false' }))
    Add-SummaryAgentLine -Result $Result -Text ('selected-ids=' + $idText)
    Add-SummaryAgentLine -Result $Result -Text ('run-only-after-the-user-explicitly-says-yes=' + $removeCommand)
    Add-SummaryAgentLine -Result $Result -Text ('after-remove=' + $afterRemove)
    Add-SummaryAgentLine -Result $Result -Text 'note=Show the text above and wait for an explicit yes. Never edit the IDs or the hash. If the user changes the choice, run -Delete again. Run the removal once, in the foreground, without a short time limit (it waits for the Windows permission prompt); never start it again after a time-out or an unclear end: run after-remove with -ExitCode unknown instead.'
}

# Full-width digits (typed with a Chinese input method) are the same numbers as ASCII digits.
function ConvertTo-SummaryChoiceToken {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Token)

    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Token.ToCharArray()) {
        $value = [int]$character
        if ($value -ge 0xFF10 -and $value -le 0xFF19) { [void]$builder.Append([char](0x30 + $value - 0xFF10)) }
        else { [void]$builder.Append($character) }
    }
    return $builder.ToString()
}

function Build-RemoveSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [AllowNull()][object]$ReportValue
    )

    $selectionRecord = Get-W360PropertyValue -Object $ReportValue -Name 'Selection'
    # The approval the agent showed the user is bound by the hash of that Scan report (-ScanReportHash, printed in the
    # after-remove command). A Remove report bound to any other Scan report is not this deletion's result.
    $approvalBound = $script:SummaryBoundNames -contains 'ScanReportHash'
    if ($approvalBound) {
        $expectedHash = ([string]$ScanReportHash).Trim()
    }
    else {
        $expectedHash = Get-W360StringProperty -Object $ReportValue -Name 'ApprovedReportHash'
        $recordedHash = Get-W360StringProperty -Object $selectionRecord -Name 'ApprovedReportHash'
        # The two copies of the bound hash must agree; a report whose copies differ is not trusted as a result.
        if ($null -ne $selectionRecord -and -not [string]::IsNullOrWhiteSpace($recordedHash) -and
            -not $recordedHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) { $expectedHash = $recordedHash }
    }
    $selectedTargets = @(Get-W360ArrayProperty -Object $selectionRecord -Name 'SelectedTargets')
    # Without the progress events of the window, a missing or unusable report never proves that nothing started:
    # the elevated part may already have run. The outcome therefore stays "not sure", never "nothing was deleted".
    $events = @([pscustomobject]@{ Phase = 'WaitingForElevation'; Detail = '' })
    $outcome = Get-W360RemoveOutcome -ExitCode $script:ExitCodeValue -ReportPath $ReportPath -ExpectedApprovedReportHash $expectedHash `
        -Events $events -StdoutLines @() -StderrLines @() -SelectedFindings $selectedTargets
    $noRecord = -not [string]::IsNullOrWhiteSpace([string]$outcome.ReportIssue)
    $state = [string]$outcome.State
    $headline = [string]$outcome.Headline
    $detail = [string]$outcome.Detail
    $tone = Get-W360OutcomeTone -Outcome $outcome
    if ($null -eq $script:ExitCodeValue -and $state -eq 'Partial' -and
        $detail -ceq (Get-W360Text -Key 'Remove.Partial.ExitCode' -Arguments @((Get-W360Text -Key 'Common.Unknown')))) {
        # The agent lost the exit code (for example a time-out of its shell). Nothing proves that items were left, and
        # nothing proves that the run finished: the result is "not sure", never "finished".
        $state = 'Unknown'
        $headline = Get-W360Text -Key 'Remove.Unknown.Headline'
        $detail = Get-SummaryText -Key 'Agent.Remove.EndUnknown'
        $tone = 'Warning'
    }
    $lines = $Result.Lines
    $lines.Add($headline)
    if (-not [string]::IsNullOrWhiteSpace($detail)) { $lines.Add($detail) }
    $counts = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$outcome.CountsText)) {
        $counts = [ordered]@{
            Deleted    = [long]$outcome.Stats.SelectedConfirmedAbsent
            NotDeleted = [long]$outcome.Stats.SelectedStillPresent
            NotSure    = [long]$outcome.Stats.SelectedUnknown
        }
        $lines.Add((Get-SummaryText -Key 'Agent.Remove.Counts' -Arguments @($counts.Deleted, $counts.NotDeleted, $counts.NotSure)))
    }
    $problemLines = @(Get-W360RemoveProblemLines -Outcome $outcome -Limit 100)
    $moreLine = ''
    if ($problemLines.Count -gt 0) {
        $lines.Add('')
        $lines.Add((Get-SummaryText -Key 'Agent.Remove.ProblemsTitle'))
        $shown = [Math]::Min($problemLines.Count, $script:SummaryListLimit)
        for ($index = 0; $index -lt $shown; $index++) { $lines.Add(([string][char]0x00B7 + ' ' + $problemLines[$index])) }
        if ($problemLines.Count -gt $shown) {
            $moreLine = Get-SummaryText -Key 'Agent.Remove.MoreProblems' -Arguments @($problemLines.Count - $shown)
            $lines.Add($moreLine)
        }
    }

    $nextKey = 'Agent.Next.RemoveUnknown'
    $restart = 'needed'
    switch ($state) {
        'Completed' { $nextKey = 'Agent.Next.RemoveCompleted'; $restart = 'recommended' }
        'NeedsRestart' { $nextKey = 'Agent.Next.RemoveRestart' }
        'Partial' { $nextKey = 'Agent.Next.RemovePartial' }
        default { $nextKey = $(if ($noRecord) { 'Agent.Next.RemoveNoRecord' } else { 'Agent.Next.RemoveUnknown' }) }
    }
    $nextText = Get-SummaryText -Key $nextKey
    $lines.Add('')
    $lines.Add((Get-W360Text -Key 'Ui.NextSteps' -Arguments @($nextText)))

    $keptUnconfirmed = $outcome.PreservedNotConfirmedPresent
    $uninstallerRan = [bool]$outcome.VendorUninstallerRan
    $Result.Data['State'] = $state
    $Result.Data['CommandExitCode'] = $script:ExitCodeValue
    $Result.Data['ReportIssue'] = [string]$outcome.ReportIssue
    $Result.Data['ApprovalBound'] = $approvalBound
    $Result.Data['Headline'] = $headline
    $Result.Data['Detail'] = $detail
    $Result.Data['Counts'] = $counts
    $Result.Data['Problems'] = [string[]]$problemLines
    $Result.Data['Restart'] = $restart
    $Result.Data['KeptNotConfirmedPresent'] = $keptUnconfirmed
    $Result.Data['UninstallerRan'] = $uninstallerRan
    $Result.Data['NextStep'] = $nextText
    $Result.Data['Tone'] = $tone

    # tone, kept-unconfirmed and uninstaller-ran tell a text-only agent what the window shows with its colour: a
    # finished result where unchosen items may have changed is a warning, never a plain success.
    Add-SummaryAgentLine -Result $Result -Text ('mode=Remove; state={0}; exit-code={1}; restart={2}; report-issue={3}; tone={4}; kept-unconfirmed={5}; uninstaller-ran={6}; approval-bound={7}' -f `
            $state, (Get-SummaryExitCodeText), $restart, $(if ($noRecord) { $outcome.ReportIssue } else { 'none' }), $tone,
        $(if ($null -eq $keptUnconfirmed) { 'unknown' } else { [string]$keptUnconfirmed }), $(if ($uninstallerRan) { 'true' } else { 'false' }),
        $(if ($approvalBound) { 'true' } else { 'false' }))
    $scanPath = New-SummaryReportPath -NextTo $ReportPath -Kind 'scan'
    $verifyPath = New-SummaryReportPath -NextTo $ReportPath -Kind 'verify'
    if (-not (Test-SummaryCommandSafe -Values @($script:SummaryScriptPath, $script:SummaryCorePath, $ReportPath, $scanPath, $verifyPath))) {
        Add-SummaryUnsafePathNote -Result $Result -Next 'After the restart, ask the user to open 开始检查.cmd and click 检查上次删除的结果 (it only checks).'
    }
    elseif ($noRecord) {
        $checkCommand = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryCorePath -ArgumentText @('-Mode', 'Scan', '-ReportPath', (Format-SummaryQuoted -Value $scanPath))
        $then = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @('-Report', (Format-SummaryQuoted -Value $scanPath), '-Language', (Get-W360UiLanguage))
        $Result.Data['AfterRestartCommand'] = $checkCommand
        $Result.Data['ThenCommand'] = $then
        Add-SummaryAgentLine -Result $Result -Text ('after-restart=' + $checkCommand)
        Add-SummaryAgentLine -Result $Result -Text ('then=' + $then)
    }
    else {
        $checkCommand = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryCorePath -ArgumentText @(
            '-Mode', 'Verify', '-PreviousRemoveReport', (Format-SummaryQuoted -Value $ReportPath), '-ReportPath', (Format-SummaryQuoted -Value $verifyPath))
        $then = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @(
            '-Report', (Format-SummaryQuoted -Value $verifyPath), '-Mode', 'Verify', '-Language', (Get-W360UiLanguage), '-ExitCode', '<exit code of the check command, or unknown>')
        $Result.Data['AfterRestartCommand'] = $checkCommand
        $Result.Data['ThenCommand'] = $then
        Add-SummaryAgentLine -Result $Result -Text ('after-restart=' + $checkCommand)
        Add-SummaryAgentLine -Result $Result -Text ('then=' + $then)
    }
    Add-SummaryAgentLine -Result $Result -Text 'note=Never restart the PC for the user. Run after-restart only when the user says the PC has restarted (or asks to check now); in a new conversation, Show-360Summary.ps1 -FindLastRemove finds this deletion again. The check is read-only and never approves another removal. Never run the removal again.'
}

function Get-SummaryExitCodeText {
    if ($null -eq $script:ExitCodeValue) { return 'unknown' }
    return [string]$script:ExitCodeValue
}

function Build-VerifySummary {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $outcome = Get-W360VerifyOutcome -ExitCode $script:ExitCodeValue -ReportPath $ReportPath -StdoutLines @() -StderrLines @()
    $lines = $Result.Lines
    $lines.Add([string]$outcome.Headline)
    if (-not [string]::IsNullOrWhiteSpace([string]$outcome.Detail)) { $lines.Add([string]$outcome.Detail) }
    $dot = [string][char]0x00B7
    $sectionData = New-Object System.Collections.ArrayList
    foreach ($section in @($outcome.GridSections)) {
        $items = @($section.Items)
        $lines.Add('')
        $lines.Add((Get-SummaryText -Key 'Agent.Verify.SectionTitle' -Arguments @([string]$section.Title, $items.Count)))
        $shown = [Math]::Min($items.Count, $script:SummarySectionLimit)
        $itemData = New-Object System.Collections.ArrayList
        for ($index = 0; $index -lt $items.Count; $index++) {
            $item = $items[$index]
            $text = switch ([string]$section.Key) {
                'Cleared' { [string]$item.DisplayName }
                'CurrentKept' { Get-W360Text -Key 'Ui.Confirm.KeptReason' -Arguments @([string]$item.DisplayName, (Get-W360KeepReason -StatusText ([string]$item.StateText))) }
                default { Get-SummaryText -Key 'Agent.Verify.Item' -Arguments @([string]$item.DisplayName, [string]$item.StateText) }
            }
            if ($index -lt $shown) { $lines.Add(($dot + ' ' + $text)) }
            [void]$itemData.Add([ordered]@{ Text = $text; State = [string]$item.State; Target = [string]$item.Target })
        }
        if ($items.Count -gt $shown) { $lines.Add((Get-W360Text -Key 'Common.MoreItems' -Arguments @($items.Count - $shown))) }
        [void]$sectionData.Add([ordered]@{ Key = [string]$section.Key; Title = [string]$section.Title; Count = $items.Count; Items = @($itemData) })
    }

    $rescan = $false
    $nextKey = switch ([string]$outcome.State) {
        'TaskCompleted' {
            if ($outcome.CoverageComplete -eq $false) { 'Agent.Next.IncompleteRetry' }
            elseif ([long]$outcome.PreservedGoneCount -gt 0) { 'Agent.Next.KeptGone' }
            else { 'Agent.Next.Done' }
        }
        'GlobalClean' { 'Agent.Next.Done' }
        'GlobalIncomplete' { 'Agent.Next.IncompleteRetry' }
        'GlobalKeptOnly' { 'Agent.Next.KeptOnly' }
        'TaskCompletedWithNew' { $rescan = $true; 'Agent.Next.RescanDecide' }
        'GlobalRemaining' { $rescan = $true; 'Agent.Next.RescanDecide' }
        'TaskUnavailable' {
            $rescan = $true
            if (@($outcome.Sections.CurrentIdentified).Count -gt 0) { 'Agent.Next.RescanDecide' } else { 'Agent.Next.RescanLook' }
        }
        'TaskRemaining' { 'Agent.Next.VerifyRemaining' }
        'TaskUnknown' { 'Agent.Next.VerifyUnknown' }
        default { 'Agent.Next.Retry' }
    }
    $nextText = Get-SummaryText -Key $nextKey
    $lines.Add('')
    $lines.Add((Get-W360Text -Key 'Ui.NextSteps' -Arguments @($nextText)))

    $Result.Data['State'] = [string]$outcome.State
    $Result.Data['CommandExitCode'] = $script:ExitCodeValue
    $Result.Data['TaskStatus'] = [string]$outcome.TaskStatus
    $Result.Data['CoverageComplete'] = $outcome.CoverageComplete
    $Result.Data['Headline'] = [string]$outcome.Headline
    $Result.Data['Detail'] = [string]$outcome.Detail
    $Result.Data['Sections'] = @($sectionData)
    $tone = Get-W360OutcomeTone -Outcome $outcome
    $keptGone = [long]$outcome.PreservedGoneCount
    $Result.Data['NextStep'] = $nextText
    $Result.Data['KeptGoneCount'] = $keptGone
    $Result.Data['Tone'] = $tone

    Add-SummaryAgentLine -Result $Result -Text ('mode=Verify; state={0}; exit-code={1}; task-status={2}; coverage-complete={3}; kept-gone={4}; tone={5}' -f `
            $outcome.State, (Get-SummaryExitCodeText), $(if ($outcome.TaskStatus) { $outcome.TaskStatus } else { 'none' }), (Get-SummaryBool $outcome.CoverageComplete), $keptGone, $tone)
    if ($rescan -or @('Failed', 'InvalidReport', 'GlobalIncomplete') -contains [string]$outcome.State -or
        ([string]$outcome.State -eq 'TaskCompleted' -and $outcome.CoverageComplete -eq $false)) {
        $scanPath = New-SummaryReportPath -NextTo $ReportPath -Kind 'scan'
        if (Test-SummaryCommandSafe -Values @($script:SummaryScriptPath, $script:SummaryCorePath, $scanPath)) {
            $checkCommand = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryCorePath -ArgumentText @('-Mode', 'Scan', '-ReportPath', (Format-SummaryQuoted -Value $scanPath))
            $then = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @('-Report', (Format-SummaryQuoted -Value $scanPath), '-Language', (Get-W360UiLanguage))
            $Result.Data['CheckAgainCommand'] = $checkCommand
            Add-SummaryAgentLine -Result $Result -Text ('if-the-user-wants-a-new-check=' + $checkCommand)
            Add-SummaryAgentLine -Result $Result -Text ('then=' + $then)
        }
        else {
            Add-SummaryUnsafePathNote -Result $Result -Next 'A new check is only possible in the window (开始检查.cmd).'
        }
    }
    if ($keptGone -gt 0) {
        Add-SummaryAgentLine -Result $Result -Text 'kept-gone-note=Items the user kept are gone. Tell the user so (and that the uninstaller that came with 360 may have removed them when the text says so); never call this a clean success.'
    }
    Add-SummaryAgentLine -Result $Result -Text 'note=This check is read-only. Items the user kept are not failures. Any new deletion needs a new check and a new explicit choice.'
}

function Write-SummaryResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    if ($Json) {
        $object = [ordered]@{
            Mode       = $Result.Kind
            Language   = Get-W360UiLanguage
            ReportPath = $script:ReportFullPath
            ExitCode   = $Result.ExitCode
            Text       = [string]($Result.Lines.ToArray() -join "`r`n")
            Lines      = [string[]]$Result.Lines.ToArray()
            AgentLines = [string[]]$Result.AgentLines.ToArray()
        }
        foreach ($key in @($Result.Data.Keys)) { $object[$key] = $Result.Data[$key] }
        Write-Output (([pscustomobject]$object) | ConvertTo-Json -Depth 10)
        return
    }
    foreach ($line in $Result.Lines) { Write-Output $line }
    foreach ($line in $Result.AgentLines) { Write-Output $line }
}

function Get-SummaryLastRemoveCandidate {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][string]$UserSid
    )

    # Only a readable Remove report of this Windows user whose selection is bound to its Scan report hash counts,
    # the same conditions the read-only check needs. Anything else is skipped, never guessed.
    if (($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
    try { $report = (Read-W360JsonBytes -Path $File.FullName).Value }
    catch { return $null }
    if ($null -eq $report -or $report -is [System.Array]) { return $null }
    if ((Get-W360StringProperty -Object $report -Name 'Mode') -cne 'Remove') { return $null }
    if ((ConvertTo-W360NullableInt64 (Get-W360PropertyValue -Object $report -Name 'SchemaVersion')) -ne 2) { return $null }
    $selection = Get-W360PropertyValue -Object $report -Name 'Selection'
    if ($null -eq $selection -or -not (Test-W360HasProperty -Object $selection -Name 'SelectedTargets')) { return $null }
    $topHash = Get-W360StringProperty -Object $report -Name 'ApprovedReportHash'
    if ($topHash -notmatch '^[0-9A-Fa-f]{64}$' -or
        -not $topHash.Equals((Get-W360StringProperty -Object $selection -Name 'ApprovedReportHash'), [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $reportSid = Get-W360StringProperty -Object (Get-W360PropertyValue -Object $report -Name 'ApprovalContext') -Name 'UserSid'
    if ([string]::IsNullOrWhiteSpace($reportSid) -or -not $reportSid.Equals($UserSid, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $created = ConvertTo-W360DateTimeOffset (Get-W360PropertyValue -Object $report -Name 'Timestamp')
    if ($null -eq $created) { $created = [DateTimeOffset]$File.LastWriteTime }
    return [pscustomobject]@{
        Path          = $File.FullName
        Created       = $created
        SelectedCount = @(Get-W360ArrayProperty -Object $selection -Name 'SelectedTargets').Count
    }
}

function Build-LastRemoveSummary {
    param([Parameter(Mandatory = $true)][object]$Result)

    $directory = if ([string]::IsNullOrWhiteSpace($Directory)) { Get-W360DefaultReportDirectory } else { [IO.Path]::GetFullPath($Directory) }
    $userSid = [string][Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $candidates = New-Object System.Collections.ArrayList
    $files = @()
    if ([IO.Directory]::Exists($directory)) {
        try {
            $files = @((New-Object IO.DirectoryInfo($directory)).GetFiles('360-cleanup-*.json', [IO.SearchOption]::TopDirectoryOnly) |
                Where-Object { $_.Name -match '^360-cleanup-(remove|report)-.+\.json$' } |
                Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First $script:SummaryLastRemoveFileLimit)
        }
        catch { $files = @() }
    }
    foreach ($file in $files) {
        $candidate = Get-SummaryLastRemoveCandidate -File $file -UserSid $userSid
        if ($null -ne $candidate) { [void]$candidates.Add($candidate) }
    }
    $sorted = @($candidates | Sort-Object -Property @{ Expression = { $_.Created.UtcDateTime }; Descending = $true })
    $Result.Data['Directory'] = $directory
    $lines = $Result.Lines
    $language = Get-W360UiLanguage

    if ($sorted.Count -eq 0) {
        $Result.Data['State'] = 'NotFound'
        $lines.Add((Get-SummaryText -Key 'Agent.Last.NotFound'))
        $lines.Add('')
        $lines.Add((Get-W360Text -Key 'Ui.NextSteps' -Arguments @((Get-SummaryText -Key 'Agent.Next.RescanLook'))))
        Add-SummaryAgentLine -Result $Result -Text ('mode=FindLastRemove; state=NotFound; directory={0}' -f (Format-SummaryInfoPath -Value $directory))
        $scanPath = if ([IO.Directory]::Exists($directory)) { New-W360ReportPath -Directory $directory -Kind 'scan' } else { New-W360ReportPath -Directory (Get-W360DefaultReportDirectory) -Kind 'scan' }
        if (Test-SummaryCommandSafe -Values @($script:SummaryScriptPath, $script:SummaryCorePath, $scanPath)) {
            Add-SummaryAgentLine -Result $Result -Text ('if-the-user-wants-a-new-check=' + (Format-SummaryPowerShellCommand -ScriptPath $script:SummaryCorePath -ArgumentText @('-Mode', 'Scan', '-ReportPath', (Format-SummaryQuoted -Value $scanPath))))
            Add-SummaryAgentLine -Result $Result -Text ('then=' + (Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @('-Report', (Format-SummaryQuoted -Value $scanPath), '-Language', $language)))
        }
        else {
            Add-SummaryUnsafePathNote -Result $Result -Next 'A new check is only possible in the window (开始检查.cmd).'
        }
        Add-SummaryAgentLine -Result $Result -Text 'note=Nothing was found in this folder for this Windows user. If the reports were saved elsewhere, run -FindLastRemove -Directory <that folder>. Never treat this as "nothing was deleted".'
        return
    }

    $latest = $sorted[0]
    $script:ReportFullPath = [string]$latest.Path
    $restarted = $null
    $boot = ConvertTo-W360DateTimeOffset (Get-W360LastBootTime)
    if ($null -ne $boot) { $restarted = [bool]($boot.UtcDateTime -gt $latest.Created.UtcDateTime) }
    $shownTime = $latest.Created.LocalDateTime.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $lines.Add((Get-SummaryText -Key 'Agent.Last.Found' -Arguments @($shownTime, $latest.SelectedCount)))
    # Without a restart since the deletion the user chooses: restart first or check now.
    if ($restarted -eq $false) { $lines.Add((Get-SummaryText -Key 'Agent.Last.NotRestarted')) }

    $verifyPath = New-SummaryReportPath -NextTo $latest.Path -Kind 'verify'
    $Result.Data['State'] = 'Found'
    $Result.Data['RemoveReportPath'] = [string]$latest.Path
    $Result.Data['CreatedAt'] = $latest.Created.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $Result.Data['SelectedCount'] = [int]$latest.SelectedCount
    $Result.Data['RestartedSinceRemove'] = $restarted
    $Result.Data['OtherRemovals'] = $sorted.Count - 1
    Add-SummaryAgentLine -Result $Result -Text ('mode=FindLastRemove; state=Found; remove-report={0}; created={1}; selected-count={2}; restarted-since={3}; other-removals={4}' -f `
            (Format-SummaryInfoPath -Value $latest.Path), $Result.Data['CreatedAt'], $latest.SelectedCount, (Get-SummaryBool $restarted), ($sorted.Count - 1))
    if (Test-SummaryCommandSafe -Values @($script:SummaryScriptPath, $script:SummaryCorePath, $latest.Path, $verifyPath)) {
        if ($restarted -ne $false) { $lines.Add((Get-SummaryText -Key 'Agent.Last.Check')) }
        else { Add-SummaryAgentLine -Result $Result -Text 'not-restarted-note=Ask whether the user wants to restart first or check now; run check only after the answer.' }
        $checkCommand = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryCorePath -ArgumentText @(
            '-Mode', 'Verify', '-PreviousRemoveReport', (Format-SummaryQuoted -Value $latest.Path), '-ReportPath', (Format-SummaryQuoted -Value $verifyPath))
        $then = Format-SummaryPowerShellCommand -ScriptPath $script:SummaryScriptPath -ArgumentText @(
            '-Report', (Format-SummaryQuoted -Value $verifyPath), '-Mode', 'Verify', '-Language', $language, '-ExitCode', '<exit code of the check command, or unknown>')
        $Result.Data['CheckCommand'] = $checkCommand
        $Result.Data['ThenCommand'] = $then
        Add-SummaryAgentLine -Result $Result -Text ('check=' + $checkCommand)
        Add-SummaryAgentLine -Result $Result -Text ('then=' + $then)
    }
    else {
        $lines.Add((Get-SummaryText -Key 'Agent.UseWindow'))
        Add-SummaryUnsafePathNote -Result $Result -Next 'Ask the user to open 开始检查.cmd and click 检查上次删除的结果 (it only checks).'
    }
    Add-SummaryAgentLine -Result $Result -Text 'note=The check is read-only and never approves another removal. This is the newest deletion of this Windows user in this folder; if the user means another one, ask. Never run a removal from this record.'
}

function New-SummaryErrorResult {
    param([AllowNull()][object]$ErrorRecord)

    $message = if ($null -ne $ErrorRecord) { [string]$ErrorRecord.Exception.Message } else { '' }
    $result = New-SummaryResult -Kind 'Error'
    $result.Lines.Add((Get-SummaryText -Key 'Agent.Error'))
    $result.ExitCode = 1
    $result.Data['State'] = 'Error'
    $result.Data['Error'] = $message
    Add-SummaryAgentLine -Result $result -Text ('mode=Error; state=Error; error={0}; nothing was run and no command is given. Do not tell the user anything finished and never run a removal from an earlier line.' -f ($message -replace '[\r\n]+', ' '))
    return $result
}

function Build-ReportSummary {
    param([Parameter(Mandatory = $true)][object]$Result)

    $script:ExitCodeGiven = $script:SummaryBoundNames -contains 'ExitCode' -and -not [string]::IsNullOrWhiteSpace($ExitCode)
    $script:ExitCodeValue = $null
    $script:ExitCodeInvalid = $false
    if ($script:ExitCodeGiven) {
        $trimmedExitCode = $ExitCode.Trim()
        $parsedExitCode = [long]0
        if ($trimmedExitCode -ieq 'unknown') { $script:ExitCodeValue = $null }
        elseif ([long]::TryParse($trimmedExitCode, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedExitCode)) {
            $script:ExitCodeValue = $parsedExitCode
        }
        else { $script:ExitCodeInvalid = $true }
    }

    $script:ReportFullPath = [IO.Path]::GetFullPath($Report)
    $reportMode = ''
    $reportValue = $null
    if ([IO.File]::Exists($script:ReportFullPath)) {
        try {
            $reportValue = (Read-W360JsonBytes -Path $script:ReportFullPath).Value
            $reportMode = Get-W360StringProperty -Object $reportValue -Name 'Mode'
        }
        catch { $reportValue = $null; $reportMode = '' }
    }
    if (@('Scan', 'Remove', 'Verify') -cnotcontains $reportMode) {
        $reportMode = ''
        $leaf = [IO.Path]::GetFileName($script:ReportFullPath)
        if (-not [string]::IsNullOrWhiteSpace($Mode)) { $reportMode = $Mode }
        elseif ($leaf -match '^360-cleanup-(scan|remove|verify)-') { $reportMode = (Get-Culture).TextInfo.ToTitleCase($Matches[1]) }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Mode) -and $Mode -cne $reportMode) {
        $Result.Kind = $Mode
        $Result.Lines.Add((Get-SummaryText -Key 'Agent.WrongKind'))
        $Result.ExitCode = 2
        $Result.Data['State'] = 'WrongKind'
        Add-SummaryAgentLine -Result $Result -Text ('mode={0}; state=WrongKind; error=the report is a {1} report, not {0}' -f $Mode, $reportMode)
        return
    }

    if ([string]::IsNullOrWhiteSpace($reportMode)) {
        $Result.Kind = 'Unknown'
        $Result.Lines.Add((Get-SummaryText -Key 'Agent.NoResult'))
        $Result.ExitCode = 2
        $Result.Data['State'] = 'NoResult'
        Add-SummaryAgentLine -Result $Result -Text 'mode=Unknown; state=NoResult; error=the report is missing or unreadable and -Mode was not given; do not tell the user anything finished'
        return
    }

    $Result.Kind = $reportMode
    if ($script:ExitCodeInvalid) {
        Add-SummaryNeedExitCode -Result $Result -ReportPath $script:ReportFullPath -ReportMode $reportMode
    }
    elseif ($script:SummaryBoundNames -contains 'Delete') {
        if ($reportMode -ne 'Scan') {
            $Result.Lines.Add((Get-SummaryText -Key 'Agent.WrongKind'))
            $Result.ExitCode = 2
            $Result.Data['State'] = 'WrongKind'
            Add-SummaryAgentLine -Result $Result -Text ('mode=Delete; accepted=false; state=WrongKind; error=-Delete needs a Scan report, not a {0} report' -f $reportMode)
        }
        else {
            $Result.Kind = 'Delete'
            Build-DeleteSummary -Result $Result -ReportPath $script:ReportFullPath -Choices @($Delete)
        }
    }
    elseif ($reportMode -eq 'Scan') {
        Build-ScanSummary -Result $Result -ReportPath $script:ReportFullPath
    }
    elseif (-not $script:ExitCodeGiven) {
        Add-SummaryNeedExitCode -Result $Result -ReportPath $script:ReportFullPath -ReportMode $reportMode
    }
    elseif ($reportMode -eq 'Remove') {
        Build-RemoveSummary -Result $Result -ReportPath $script:ReportFullPath -ReportValue $reportValue
    }
    else {
        Build-VerifySummary -Result $Result -ReportPath $script:ReportFullPath
    }
}

$previousOutputEncoding = $null
$script:ReportFullPath = ''
$script:ExitCodeGiven = $false
$script:ExitCodeValue = $null
$script:ExitCodeInvalid = $false
try {
    try {
        $previousOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    catch { $previousOutputEncoding = $null }

    Register-SummaryTexts
    Set-W360UiLanguage -Language $Language

    $result = New-SummaryResult -Kind 'Unknown'
    try {
        $unexpected = @(@($UnexpectedArguments) | Where-Object { $null -ne $_ })
        if ($unexpected.Count -gt 0) {
            $result.Lines.Add((Get-SummaryText -Key 'Agent.BadArguments'))
            $result.ExitCode = 2
            $result.Data['State'] = 'UnexpectedArguments'
            $shown = (@($unexpected | ForEach-Object { '"' + ([string]$_ -replace '[\r\n"]', ' ') + '"' }) -join ' ')
            Add-SummaryAgentLine -Result $result -Text ('mode=Unknown; state=UnexpectedArguments; error=these values belong to no parameter: {0}. Nothing was run. Put every number in one -Delete value separated by commas (for example -Delete 1,2) and give every other value with its parameter name.' -f $shown)
        }
        elseif ($FindLastRemove) {
            $result.Kind = 'FindLastRemove'
            Build-LastRemoveSummary -Result $result
        }
        else {
            Build-ReportSummary -Result $result
        }
    }
    catch {
        # A half-built result is never printed: no partial text and never a command.
        $result = New-SummaryErrorResult -ErrorRecord $_
    }
    Write-SummaryResult -Result $result
    exit $result.ExitCode
}
finally {
    if ($null -ne $previousOutputEncoding) {
        try { [Console]::OutputEncoding = $previousOutputEncoding }
        catch {}
    }
}
